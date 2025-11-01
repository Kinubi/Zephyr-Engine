const std = @import("std");
const vk = @import("vulkan");
const asset_types = @import("asset_types.zig");
const asset_registry = @import("asset_registry.zig");
const asset_loader = @import("asset_loader.zig");
const hot_reload_manager = @import("hot_reload_manager.zig");
const FileWatcher = @import("../utils/file_watcher.zig").FileWatcher;
const GraphicsContext = @import("../core/graphics_context.zig").GraphicsContext;
const Model = @import("../rendering/mesh.zig").Model;
const Texture = @import("../core/texture.zig").Texture;
const Buffer = @import("../core/buffer.zig").Buffer;
const ThreadPool = @import("../threading/thread_pool.zig").ThreadPool;
const WorkItem = @import("../threading/thread_pool.zig").WorkItem;
const WorkPriority = @import("../threading/thread_pool.zig").WorkPriority;
const GPUWork = @import("../threading/thread_pool.zig").GPUWork;
const log = @import("../utils/log.zig").log;

// Re-export key types for convenience
pub const AssetId = asset_types.AssetId;
pub const AssetType = asset_types.AssetType;
pub const AssetState = asset_types.AssetState;
pub const AssetMetadata = asset_types.AssetMetadata;
pub const AssetRegistry = asset_registry.AssetRegistry;
pub const AssetLoader = asset_loader.AssetLoader;

const FallbackMeshes = @import("../utils/fallback_meshes.zig").FallbackMeshes;

/// Material structure that matches the shader Material layout
pub const Material = struct {
    albedo_texture_id: u32 = 0, // Matches shader: uint albedoTextureIndex
    roughness: f32 = 0.5, // Matches shader: float roughness
    metallic: f32 = 0.0, // Matches shader: float metallic
    emissive: f32 = 0.0, // Matches shader: float emissive
    emissive_color: [4]f32 = [4]f32{ 0.0, 0.0, 0.0, 1.0 }, // Matches shader: vec4/float4 emissive_color
};

/// Holder for script source text owned by AssetManager
const ScriptHolder = struct {
    source: []const u8,
};

/// Enhanced asset loading priority levels
pub const LoadPriority = enum(u8) {
    critical = 0, // UI textures, fallback assets
    high = 1, // Player-visible objects
    normal = 2, // Background objects
    low = 3, // Preloading, optimization

    pub fn fromDistance(distance: f32) LoadPriority {
        if (distance < 10.0) return .critical;
        if (distance < 50.0) return .high;
        if (distance < 200.0) return .normal;
        return .low;
    }
};

/// Asset load request with priority and context
pub const LoadRequest = struct {
    asset_id: AssetId,
    asset_type: AssetType,
    file_path: []const u8,
    priority: LoadPriority,
    timestamp: i64, // For request tracking and timeout
    context: ?*anyopaque = null, // Optional context data
};

/// Types of fallback assets for different scenarios
pub const FallbackType = enum {
    missing, // Pink checkerboard for missing textures
    loading, // Animated or static "loading..." texture
    staged, // Animated or static "loading..." texture
    failed, // Red X or error indicator (error is keyword)
    default, // Basic white texture for materials
};

/// Pre-loaded fallback assets for safe rendering
pub const FallbackAssets = struct {
    missing_texture: ?AssetId = null,
    loading_texture: ?AssetId = null,
    failed_texture: ?AssetId = null,
    default_texture: ?AssetId = null,

    // Fallback models
    missing_model: ?AssetId = null,
    loading_model: ?AssetId = null,
    failed_model: ?AssetId = null,
    default_model: ?AssetId = null,

    /// Initialize fallback assets by loading them synchronously
    pub fn init(asset_manager: *AssetManager) !FallbackAssets {
        var fallbacks = FallbackAssets{};

        // Try to load each fallback texture, but don't fail if missing
        fallbacks.missing_texture = asset_manager.loadTextureSync("assets/textures/missing.png") catch |err| blk: {
            log(.WARN, "asset_manager", "Could not load missing.png fallback: {}", .{err});
            break :blk null;
        };

        fallbacks.loading_texture = asset_manager.loadTextureSync("assets/textures/loading.png") catch |err| blk: {
            log(.WARN, "asset_manager", "Could not load loading.png fallback: {}", .{err});
            break :blk null;
        };

        fallbacks.failed_texture = asset_manager.loadTextureSync("assets/textures/error.png") catch |err| blk: {
            log(.WARN, "asset_manager", "Could not load error.png fallback: {}", .{err});
            break :blk null;
        };

        fallbacks.default_texture = asset_manager.loadTextureSync("textures/default.png") catch |err| blk: {
            log(.WARN, "asset_manager", "Could not load default.png fallback: {}", .{err});
            break :blk null;
        };

        // Create fallback cube model using utility
        fallbacks.missing_model = blk: {
            // Register a fake asset for the fallback model
            const asset_id = asset_manager.registry.registerAsset("fallback://missing_model", .mesh) catch |err| {
                log(.WARN, "asset_manager", "Failed to register missing model fallback asset: {}", .{err});
                break :blk null;
            };

            // Create the cube model directly
            var cube_model = FallbackMeshes.createCubeModel(asset_manager.allocator, asset_manager.loader.graphics_context, "fallback_cube") catch |err| {
                log(.WARN, "asset_manager", "Failed to create cube model fallback: {}", .{err});
                break :blk null;
            };

            // Allocate on heap and add to AssetManager properly
            const model_ptr = asset_manager.allocator.create(Model) catch |err| {
                log(.WARN, "asset_manager", "Failed to allocate memory for fallback model: {}", .{err});
                cube_model.deinit();
                break :blk null;
            };
            model_ptr.* = cube_model;

            // Use AssetManager's addLoadedModel to ensure proper mapping
            asset_manager.addLoadedModel(asset_id, model_ptr) catch |err| {
                log(.WARN, "asset_manager", "Failed to add fallback model to AssetManager: {}", .{err});
                asset_manager.allocator.destroy(model_ptr);
                break :blk null;
            };

            // Mark as loaded in registry
            asset_manager.registry.markAsLoaded(asset_id, 1024); // Fake size

            break :blk asset_id;
        };

        fallbacks.loading_model = fallbacks.missing_model;
        fallbacks.failed_model = fallbacks.missing_model;
        fallbacks.default_model = fallbacks.missing_model;

        try asset_manager.buildTextureDescriptorArray();
        try asset_manager.createMaterialBuffer(asset_manager.loader.graphics_context);
        return fallbacks;
    }

    /// Get fallback asset for given type and asset type
    pub fn getFallback(self: *const FallbackAssets, fallback_type: FallbackType, asset_type: AssetType) ?AssetId {
        return switch (asset_type) {
            .texture => switch (fallback_type) {
                .missing => self.missing_texture,
                .loading => self.loading_texture,
                .staged => self.loading_texture,
                .failed => self.failed_texture,
                .default => self.default_texture,
            },
            .mesh => switch (fallback_type) {
                .missing => self.missing_model,
                .loading => self.loading_model,
                .staged => self.loading_model,
                .failed => self.failed_model,
                .default => self.default_model,
            },
            else => null,
        };
    }
};

/// Enhanced Asset Manager with priority-based loading and improved thread pool integration
pub const AssetManager = struct {
    // Core components
    registry: *AssetRegistry,
    loader: *AssetLoader = undefined,
    allocator: std.mem.Allocator,

    // Fallback assets for safe rendering
    fallbacks: FallbackAssets,

    // Core asset storage - actual loaded assets
    loaded_textures: std.ArrayList(*Texture), // Array of loaded texture pointers
    loaded_models: std.ArrayList(*Model), // Array of loaded model pointers
    loaded_materials: std.ArrayList(*Material), // Array of loaded material pointers
    // Loaded script assets (source text stored in heap-owned buffers)
    loaded_scripts: std.ArrayList(*ScriptHolder),
    material_buffer: ?Buffer = null, // Optional material buffer created on demand
    material_buffer_mutex: std.Thread.Mutex = std.Thread.Mutex{},
    stale_material_buffers: std.ArrayList(Buffer) = std.ArrayList(Buffer){},

    // Asset ID to array index mappings
    asset_to_texture: std.AutoHashMap(AssetId, usize), // AssetId -> texture array index
    asset_to_model: std.AutoHashMap(AssetId, usize), // AssetId -> model array index
    asset_to_material: std.AutoHashMap(AssetId, usize), // AssetId -> material array index
    asset_to_script: std.AutoHashMap(AssetId, usize), // AssetId -> script array index

    // Enhanced hot reloading (heap allocated to avoid move/copy issues)
    hot_reload_manager: ?*hot_reload_manager.HotReloadManager = null,

    // Priority-based request tracking
    pending_requests: std.AutoHashMap(AssetId, LoadRequest),
    request_mutex: std.Thread.Mutex = std.Thread.Mutex{},

    // Current texture descriptor array for rendering (maintained by asset manager)
    texture_image_infos: []const vk.DescriptorImageInfo = &[_]vk.DescriptorImageInfo{},

    // Texture dirty flag - set by GPU worker when textures are loaded, checked for lazy rebuild
    texture_descriptors_dirty: bool = true,

    // Dirty flags for resource updates
    materials_dirty: bool = true,

    // External flags for renderers - signal when buffers/descriptors have been updated
    materials_updated: bool = false,
    texture_descriptors_updated: bool = false,

    // Async update flags to track pending work
    material_buffer_updating: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    texture_descriptors_updating: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // State tracking for transition detection (like scene_bridge pattern)
    last_texture_dirty: bool = false,
    last_texture_updating: bool = false,
    last_material_dirty: bool = false,
    last_material_updating: bool = false,

    // Thread safety for concurrent asset loading
    models_mutex: std.Thread.Mutex = std.Thread.Mutex{},
    textures_mutex: std.Thread.Mutex = std.Thread.Mutex{},
    scripts_mutex: std.Thread.Mutex = std.Thread.Mutex{},

    // Performance statistics
    stats: struct {
        total_requests: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        completed_loads: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        failed_loads: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        cache_hits: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        cache_misses: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        average_load_time_ms: std.atomic.Value(f32) = std.atomic.Value(f32).init(0.0),
    } = .{},

    /// Initialize enhanced asset manager
    pub fn init(allocator: std.mem.Allocator, graphics_context: *GraphicsContext, thread_pool: *ThreadPool) !*AssetManager {
        // Allocate registry on heap to avoid HashMap corruption
        const registry = try allocator.create(AssetRegistry);
        registry.* = AssetRegistry.init(allocator);

        // Allocate enhanced loader on heap
        var self = try allocator.create(AssetManager);
        self.* = AssetManager{
            .registry = registry,
            .allocator = allocator,
            .fallbacks = FallbackAssets{}, // Initialize empty first
            .loaded_textures = std.ArrayList(*Texture){},
            .loaded_models = std.ArrayList(*Model){},
            .loaded_materials = std.ArrayList(*Material){},
            .loaded_scripts = std.ArrayList(*ScriptHolder){},
            .asset_to_texture = std.AutoHashMap(AssetId, usize).init(allocator),
            .asset_to_model = std.AutoHashMap(AssetId, usize).init(allocator),
            .asset_to_material = std.AutoHashMap(AssetId, usize).init(allocator),
            .asset_to_script = std.AutoHashMap(AssetId, usize).init(allocator),
            .pending_requests = std.AutoHashMap(AssetId, LoadRequest).init(allocator),
            .stale_material_buffers = std.ArrayList(Buffer){},
        };
        const loader = try allocator.create(AssetLoader);
        loader.* = try AssetLoader.init(allocator, registry, graphics_context, thread_pool, self);
        self.loader = loader;

        // Initialize fallback assets
        self.fallbacks = try FallbackAssets.init(self);

        log(.INFO, "enhanced_asset_manager", "Enhanced asset manager initialized with thread pool", .{});
        return self;
    }

    /// Create a material synchronously
    /// Creates a material with the given texture asset ID
    pub fn createMaterialSync(self: *AssetManager, albedo_texture_id: AssetId) !AssetId {
        // Create a unique material asset ID by registering it with the asset manager
        const material_path = try std.fmt.allocPrint(self.allocator, "material://{d}", .{albedo_texture_id.toU64()});
        defer self.allocator.free(material_path);

        const material_asset_id = try self.registry.registerAsset(material_path, .material);

        // Create the material object
        const material = try self.allocator.create(Material);
        const texture_id_u64 = albedo_texture_id.toU64();
        const texture_id_u32 = if (texture_id_u64 > std.math.maxInt(u32))
            0 // Use 0 as fallback for oversized IDs
        else
            @as(u32, @intCast(texture_id_u64));

        material.* = Material{
            .albedo_texture_id = texture_id_u32,
        };

        // Add it to the loaded materials
        try self.addLoadedMaterial(material_asset_id, material);

        return material_asset_id;
    }

    /// Add a loaded material to the asset manager
    pub fn addLoadedMaterial(self: *AssetManager, asset_id: AssetId, material: *Material) !void {
        const index = self.loaded_materials.items.len;
        try self.loaded_materials.append(self.allocator, material);
        try self.asset_to_material.put(asset_id, index);
        self.materials_dirty = true; // Mark materials as dirty when added
    }

    /// Add loaded script source to the manager (called by AssetLoader)
    pub fn addLoadedScript(self: *AssetManager, asset_id: AssetId, source: []const u8) !void {
        self.scripts_mutex.lock();
        defer self.scripts_mutex.unlock();

        // Duplicate the source into the asset manager allocator so lifetime is owned
        const dup = try self.allocator.dupe(u8, source);
        const holder = try self.allocator.create(ScriptHolder);
        holder.* = ScriptHolder{ .source = dup };

        const index = self.loaded_scripts.items.len;
        try self.loaded_scripts.append(self.allocator, holder);
        try self.asset_to_script.put(asset_id, index);

        // Mark as loaded in registry and complete pending request
        const size_u64: u64 = @as(u64, dup.len);
        self.registry.markAsLoaded(asset_id, size_u64);
        self.completeRequest(asset_id, true);
    }

    /// Get script source for an asset ID (returns null if not loaded)
    pub fn getScript(self: *AssetManager, asset_id: AssetId) ?[]const u8 {
        self.scripts_mutex.lock();
        defer self.scripts_mutex.unlock();

        if (self.asset_to_script.get(asset_id)) |index| {
            if (index < self.loaded_scripts.items.len) {
                return self.loaded_scripts.items[index].source;
            }
        }
        return null;
    }

    /// Create a material asset asynchronously
    pub fn createMaterial(self: *AssetManager, albedo_texture_id: AssetId) !AssetId {
        return try self.createMaterialSync(albedo_texture_id);
    }

    /// Load a texture synchronously (like original asset manager)
    pub fn loadTextureSync(self: *AssetManager, path: []const u8) !AssetId {
        // Register the asset first
        const asset_id = try self.registry.registerAsset(path, .texture);

        // Register with hot reload manager if available
        if (self.hot_reload_manager) |hot_reload| {
            hot_reload.registerAsset(asset_id, path, .texture) catch |err| {
                log(.WARN, "asset_manager", "Failed to register texture for hot reload: {s} ({})", .{ path, err });
            };
        }

        // Load texture directly using the graphics context
        const texture = try self.allocator.create(Texture);
        texture.* = try Texture.initFromFile(self.loader.graphics_context, self.allocator, path, .rgba8);
        try self.loaded_textures.append(self.allocator, texture);
        try self.asset_to_texture.put(asset_id, @intCast(self.loaded_textures.items.len - 1));

        // Mark as loaded in registry
        self.registry.markAsLoaded(asset_id, 1024); // Dummy file size

        return asset_id;
    }

    /// Clean up resources
    pub fn deinit(self: *AssetManager) void {
        // Clean up hot reload manager first
        if (self.hot_reload_manager) |hrm| {
            hrm.deinit();
            self.allocator.destroy(hrm);
        }

        // Clean up loader and registry
        self.loader.deinit();
        self.allocator.destroy(self.loader);

        self.registry.deinit();
        self.allocator.destroy(self.registry);

        // Clean up loaded assets
        for (self.loaded_textures.items) |texture| {
            texture.deinit();
            self.allocator.destroy(texture);
        }
        self.loaded_textures.deinit(self.allocator);

        for (self.loaded_models.items) |model| {
            model.deinit();
            self.allocator.destroy(model);
        }
        self.loaded_models.deinit(self.allocator);

        for (self.loaded_materials.items) |material| {
            self.allocator.destroy(material);
        }
        self.loaded_materials.deinit(self.allocator);

        // Clean up loaded scripts
        for (self.loaded_scripts.items) |script_holder| {
            // Free the duplicated source buffer
            if (script_holder.source.len > 0) {
                self.allocator.free(script_holder.source);
            }
            self.allocator.destroy(script_holder);
        }
        self.loaded_scripts.deinit(self.allocator);

        // Clean up mappings
        self.asset_to_texture.deinit();
        self.asset_to_model.deinit();
        self.asset_to_material.deinit();
        self.asset_to_script.deinit();
        self.pending_requests.deinit();

        self.flushStaleMaterialBuffers();
        self.stale_material_buffers.deinit(self.allocator);

        // Clean up material buffer
        if (self.material_buffer) |*buffer| {
            buffer.deinit();
        }

        // Clean up texture descriptors
        if (self.texture_image_infos.len > 0) {
            self.allocator.free(self.texture_image_infos);
        }

        log(.INFO, "enhanced_asset_manager", "Enhanced asset manager deinitialized", .{});
    }

    /// Load asset asynchronously with priority
    pub fn loadAssetAsync(self: *AssetManager, file_path: []const u8, asset_type: AssetType, priority: LoadPriority) !AssetId {
        // Register or get existing asset ID
        const asset_id = try self.registry.registerAsset(file_path, asset_type);

        // Register with hot reload manager if available
        if (self.hot_reload_manager) |hot_reload| {
            hot_reload.registerAsset(asset_id, file_path, asset_type) catch |err| {
                log(.WARN, "asset_manager", "Failed to register asset for hot reload: {s} ({})", .{ file_path, err });
            };
        }

        // Check if already loaded
        if (self.registry.getAsset(asset_id)) |metadata| {
            if (metadata.state == .loaded or metadata.state == .staged or metadata.state == .loading) {
                _ = self.stats.cache_hits.fetchAdd(1, .monotonic);
                return asset_id;
            }
        }

        // Track the request
        self.request_mutex.lock();
        defer self.request_mutex.unlock();

        const request = LoadRequest{
            .asset_id = asset_id,
            .asset_type = asset_type,
            .file_path = try self.allocator.dupe(u8, file_path),
            .priority = priority,
            .timestamp = std.time.milliTimestamp(),
        };

        try self.pending_requests.put(asset_id, request);
        _ = self.stats.total_requests.fetchAdd(1, .monotonic);

        // Submit to enhanced loader with priority (convert priority types)
        const work_priority: WorkPriority = switch (priority) {
            .critical => .critical,
            .high => .high,
            .normal => .normal,
            .low => .low,
        };
        try self.loader.requestLoad(asset_id, work_priority);

        return asset_id;
    }

    /// Load asset synchronously (blocks until complete)
    pub fn loadAssetSync(self: *AssetManager, file_path: []const u8, asset_type: AssetType, priority: LoadPriority) !AssetId {
        const asset_id = try self.loadAssetAsync(file_path, asset_type, priority);

        if (self.registry.getAsset(asset_id)) |metadata| {
            if (metadata.state == .failed) {
                return error.AssetLoadFailed;
            }
        }

        return asset_id;
    }

    /// Add loaded texture to the manager (called by GPU worker)
    pub fn addLoadedTexture(self: *AssetManager, asset_id: AssetId, texture: *Texture) !void {
        self.textures_mutex.lock();
        defer self.textures_mutex.unlock();

        try self.loaded_textures.append(self.allocator, texture);
        log(.INFO, "enhanced_asset_manager", "Added texture asset {} at index {}", .{ asset_id.toU64(), self.loaded_textures.items.len - 1 });
        const index = self.loaded_textures.items.len - 1;
        try self.asset_to_texture.put(asset_id, index);

        // Mark texture descriptors as dirty for lazy rebuild
        self.texture_descriptors_dirty = true;
        self.materials_dirty = true; // Recompute material buffer once real texture is available

        // Complete the request
        self.completeRequest(asset_id, true);
    }

    /// Add loaded model to the manager
    pub fn addLoadedModel(self: *AssetManager, asset_id: AssetId, model: *Model) !void {
        self.models_mutex.lock();
        defer self.models_mutex.unlock();

        // Use a local scope to avoid any potential memory corruption
        const safe_asset_id = asset_id;
        const safe_model = model;

        const index = self.loaded_models.items.len;

        // Verify model pointer is valid
        if (safe_model.meshes.items.len == 0) {
            log(.WARN, "asset_manager", "Adding model with no meshes for asset {}", .{safe_asset_id.toU64()});
        }

        // Append model to array first
        try self.loaded_models.append(self.allocator, safe_model);

        // Add new mapping without checking for existing entries to avoid HashMap corruption
        // If there's a duplicate, it will just overwrite the mapping which is fine
        try self.asset_to_model.put(safe_asset_id, index);

        self.completeRequest(asset_id, true);
        log(.INFO, "asset_manager", "Successfully added model asset {} at index {}", .{ safe_asset_id.toU64(), index });
    }

    /// Complete a load request (internal)
    fn completeRequest(self: *AssetManager, asset_id: AssetId, success: bool) void {
        self.request_mutex.lock();
        defer self.request_mutex.unlock();

        if (self.pending_requests.get(asset_id)) |request| {
            const load_time = @as(f32, @floatFromInt(std.time.milliTimestamp() - request.timestamp));

            // Update statistics
            if (success) {
                _ = self.stats.completed_loads.fetchAdd(1, .monotonic);

                // Update average load time (simple moving average)
                const current_avg = self.stats.average_load_time_ms.load(.monotonic);
                const new_avg = (current_avg * 0.9) + (load_time * 0.1);
                self.stats.average_load_time_ms.store(new_avg, .monotonic);
            } else {
                _ = self.stats.failed_loads.fetchAdd(1, .monotonic);
            }

            // Clean up request
            self.allocator.free(request.file_path);
            _ = self.pending_requests.remove(asset_id);
        }
    }

    /// Get texture by asset ID, with fallback
    pub fn getTexture(self: *AssetManager, asset_id: AssetId) ?*Texture {
        self.textures_mutex.lock();
        defer self.textures_mutex.unlock();

        if (self.asset_to_texture.get(asset_id)) |index| {
            return self.loaded_textures.items[index];
        }

        // Return fallback if available
        if (self.fallbacks.getFallback(.missing, .texture)) |fallback_id| {
            if (self.asset_to_texture.get(fallback_id)) |index| {
                return self.loaded_textures.items[index];
            }
        }

        return null;
    }

    /// Get model by asset ID, with fallback
    pub fn getModel(self: *AssetManager, asset_id: AssetId) ?*Model {
        self.models_mutex.lock();
        defer self.models_mutex.unlock();

        if (self.asset_to_model.get(asset_id)) |index| {
            return self.loaded_models.items[index];
        }

        // Return fallback if available
        if (self.fallbacks.getFallback(.missing, .mesh)) |fallback_id| {
            if (self.asset_to_model.get(fallback_id)) |index| {
                return self.loaded_models.items[index];
            }
        }

        return null;
    }

    /// Get material index for a given asset ID
    pub fn getMaterialIndex(self: *AssetManager, asset_id: AssetId) ?usize {
        return self.asset_to_material.get(asset_id);
    }

    /// This is the SAFE way to access assets that might still be loading
    pub fn getAssetIdForRendering(self: *AssetManager, asset_id: AssetId) AssetId {
        const asset = self.registry.getAsset(asset_id);
        switch (asset.?.state) {
            .loaded => {
                // Return actual asset if loaded
                return asset_id;
            },
            .staged => {
                // Show loading indicator while asset loads
                const fallback_id = self.fallbacks.getFallback(.staged, asset.?.asset_type);
                if (fallback_id) |fb_id| {
                    return fb_id;
                }
                // Fallback to missing if no loading asset
                const missing_fallback = self.fallbacks.getFallback(.missing, asset.?.asset_type);
                return missing_fallback orelse asset_id;
            },
            .loading => {
                // Show loading indicator while asset loads
                const fallback_id = self.fallbacks.getFallback(.loading, asset.?.asset_type);
                if (fallback_id) |fb_id| {
                    return fb_id;
                }
                // Fallback to missing if no loading asset
                const missing_fallback = self.fallbacks.getFallback(.missing, asset.?.asset_type);
                return missing_fallback orelse asset_id;
            },
            .failed => {
                // Show error asset for failed loads
                log(.WARN, "asset_manager", "Asset {} ({s}) FAILED to load, using error fallback", .{ asset_id.toU64(), asset.?.path });
                const fallback_id = self.fallbacks.getFallback(.failed, asset.?.asset_type);
                if (fallback_id) |fb_id| {
                    return fb_id;
                }
                // Fallback to missing if no error asset
                const missing_fallback = self.fallbacks.getFallback(.missing, asset.?.asset_type);
                return missing_fallback orelse asset_id;
            },
            .unloaded => {
                // Start loading and show missing asset
                self.loader.requestLoad(asset_id, .critical) catch {};
                const missing_fallback = self.fallbacks.getFallback(.missing, asset.?.asset_type);
                return missing_fallback orelse asset_id;
            },
        }
    }

    /// Get loaded model as const pointer for safe rendering access
    /// This mirrors the pattern from the old AssetManager
    pub fn getLoadedModelConst(self: *AssetManager, asset_id: AssetId) ?*const Model {
        self.models_mutex.lock();
        defer self.models_mutex.unlock();

        if (self.asset_to_model.get(asset_id)) |index| {
            if (index < self.loaded_models.items.len) {
                return self.loaded_models.items[index];
            }
        }
        return null;
    }

    pub fn initHotReload(self: *AssetManager, watcher: *FileWatcher) !void {
        const manager = try self.allocator.create(hot_reload_manager.HotReloadManager);
        manager.* = try hot_reload_manager.HotReloadManager.init(self.allocator, self, watcher);
        self.hot_reload_manager = manager;
        log(.INFO, "enhanced_asset_manager", "Hot reload manager initialized (external watcher)", .{});
        try self.hot_reload_manager.?.start();
    }

    /// Update texture descriptor array (call when textures are loaded)
    pub fn buildTextureDescriptorArray(self: *AssetManager) !void {
        self.textures_mutex.lock();
        defer self.textures_mutex.unlock();

        if (self.loaded_textures.items.len == 0) {
            log(.WARN, "asset_manager", "No textures loaded - using empty descriptor array", .{});
            self.texture_image_infos = &[_]vk.DescriptorImageInfo{};
            return;
        }

        // Build descriptor array directly from the ArrayList
        const image_infos = try self.allocator.alloc(vk.DescriptorImageInfo, self.loaded_textures.items.len);

        for (self.loaded_textures.items, 0..) |texture, i| {
            image_infos[i] = texture.getDescriptorInfo();
        }

        self.texture_image_infos = image_infos;
        // Don't set dirty flag here - the async worker will clear it when complete
    }

    /// Queue async texture descriptor array update
    pub fn queueTextureDescriptorUpdate(self: *AssetManager) !void {
        // Check if we're already updating
        if (self.texture_descriptors_updating.load(.acquire)) {
            return; // Already updating, skip
        }

        // Try to mark as updating (atomic compare-and-swap)
        if (self.texture_descriptors_updating.cmpxchgWeak(false, true, .acquire, .acquire)) |_| {
            return; // Another thread beat us to it
        }

        // Queue the work
        const work_item = WorkItem{
            .id = self.loader.work_id_counter.fetchAdd(1, .monotonic),
            .priority = .high,
            .item_type = .gpu_work,
            .data = .{
                .gpu_work = .{
                    .staging_type = .texture,
                    .asset_id = AssetId.fromU64(0), // Dummy asset ID
                    .data = self,
                },
            },
            .worker_fn = textureDescriptorUpdateWorker,
            .context = self,
        };

        try self.loader.thread_pool.submitWork(work_item);
    }

    /// Queue async material buffer update
    pub fn queueMaterialBufferUpdate(self: *AssetManager) !void {
        // Check if we're already updating
        if (self.material_buffer_updating.load(.acquire)) {
            return; // Already updating, skip
        }

        // Try to mark as updating (atomic compare-and-swap)
        if (self.material_buffer_updating.cmpxchgWeak(false, true, .acquire, .acquire)) |_| {
            return; // Another thread beat us to it
        }

        // Queue the work
        const work_item = WorkItem{
            .id = self.loader.work_id_counter.fetchAdd(1, .monotonic),
            .priority = .high,
            .item_type = .gpu_work,
            .data = .{
                .gpu_work = .{
                    .staging_type = .mesh, // Using mesh for materials
                    .asset_id = AssetId.fromU64(0), // Dummy asset ID
                    .data = self,
                },
            },
            .worker_fn = materialBufferUpdateWorker,
            .context = self,
        };

        try self.loader.thread_pool.submitWork(work_item);
    }

    /// Get the current texture descriptor array for rendering
    pub fn getTextureDescriptorArray(self: *AssetManager) []const vk.DescriptorImageInfo {
        return self.texture_image_infos;
    }

    /// Get performance statistics
    pub fn getStatistics(self: *AssetManager) struct {
        total_requests: u64,
        completed_loads: u64,
        failed_loads: u64,
        cache_hits: u64,
        cache_misses: u64,
        active_loads: u64,
        pending_requests: u64,
        average_load_time_ms: f32,
        loaded_textures: usize,
        loaded_models: usize,
        loaded_materials: usize,
    } {
        self.request_mutex.lock();
        defer self.request_mutex.unlock();

        return .{
            .total_requests = self.stats.total_requests.load(.monotonic),
            .completed_loads = self.stats.completed_loads.load(.monotonic),
            .failed_loads = self.stats.failed_loads.load(.monotonic),
            .cache_hits = self.stats.cache_hits.load(.monotonic),
            .cache_misses = self.stats.cache_misses.load(.monotonic),
            .active_loads = self.pending_requests.count(),
            .pending_requests = self.pending_requests.count(),
            .average_load_time_ms = self.stats.average_load_time_ms.load(.monotonic),
            .loaded_textures = self.loaded_textures.items.len,
            .loaded_models = self.loaded_models.items.len,
            .loaded_materials = self.loaded_materials.items.len,
        };
    }

    /// Get fallback asset for given type
    pub fn getFallbackAsset(self: *AssetManager, fallback_type: FallbackType, asset_type: AssetType) ?AssetId {
        return self.fallbacks.getFallback(fallback_type, asset_type);
    }

    /// Create material buffer from loaded materials
    pub fn createMaterialBuffer(self: *AssetManager, graphics_context: *GraphicsContext) !void {
        if (self.loaded_materials.items.len == 0) {
            log(.WARN, "asset_manager", "No loaded materials to create material buffer", .{});
            return;
        }

        self.material_buffer_mutex.lock();
        defer self.material_buffer_mutex.unlock();

        const required_count: u32 = @intCast(self.loaded_materials.items.len);
        const required_bytes: vk.DeviceSize = @intCast(@sizeOf(Material) * self.loaded_materials.items.len);

        var buffer_ptr: *Buffer = undefined;
        var needs_new_buffer = true;
        var retire_buffer: ?Buffer = null;

        if (self.material_buffer) |*existing| {
            const reusable = existing.instance_size == @sizeOf(Material) and existing.instance_count >= required_count;
            if (reusable) {
                needs_new_buffer = false;
                buffer_ptr = existing;
                if (existing.mapped == null) {
                    try existing.map(existing.buffer_size, 0);
                }
                existing.instance_count = required_count;
            } else {
                retire_buffer = existing.*;
            }
        }

        if (needs_new_buffer) {
            var new_buffer = try Buffer.init(
                graphics_context,
                @sizeOf(Material),
                required_count,
                .{
                    .storage_buffer_bit = true,
                },
                .{ .host_visible_bit = true, .host_coherent_bit = true },
            );

            try new_buffer.map(new_buffer.buffer_size, 0);
            new_buffer.instance_count = required_count;

            self.material_buffer = new_buffer;
            buffer_ptr = &self.material_buffer.?;

            if (retire_buffer) |retired_value| {
                var retired = retired_value;
                if (retired.mapped != null) {
                    retired.unmap();
                }
                try self.stale_material_buffers.append(self.allocator, retired);
            }
        }

        if (!needs_new_buffer) {
            // Ensure descriptor reflects current range when reusing
            buffer_ptr.descriptor_info = .{ .buffer = buffer_ptr.buffer, .offset = 0, .range = vk.WHOLE_SIZE };
        }
        buffer_ptr.instance_count = required_count;

        // Convert material pointers to material data with resolved texture indices
        var material_data = try self.allocator.alloc(Material, self.loaded_materials.items.len);
        defer self.allocator.free(material_data);

        for (self.loaded_materials.items, 0..) |material_ptr, i| {
            // Copy the base material
            material_data[i] = material_ptr.*;

            // Resolve the albedo_texture_id to an actual texture index
            const texture_asset_id = AssetId.fromU64(@as(u64, @intCast(material_ptr.albedo_texture_id)));

            const resolved_texture_id = self.getAssetIdForRendering(texture_asset_id);
            if (texture_asset_id == AssetId.fromU64(11)) {
                // Use default texture if albedo_texture_id is 0
            }

            // Get the texture index from the resolved asset ID
            const texture_index = self.asset_to_texture.get(resolved_texture_id) orelse 0;
            material_data[i].albedo_texture_id = @as(u32, @intCast(texture_index));
        }

        buffer_ptr.writeToBuffer(std.mem.sliceAsBytes(material_data), required_bytes, 0);

        log(.INFO, "enhanced asset_manager", "Created material buffer with {d} materials (texture IDs resolved)", .{self.loaded_materials.items.len});
    }

    pub fn flushStaleMaterialBuffers(self: *AssetManager) void {
        self.material_buffer_mutex.lock();
        defer self.material_buffer_mutex.unlock();

        if (self.stale_material_buffers.items.len == 0) return;

        for (self.stale_material_buffers.items) |*buffer| {
            buffer.deinit();
        }

        self.stale_material_buffers.clearRetainingCapacity();
    }

    /// Begin a new frame - checks for async work completion and queues updates
    /// Uses state transition detection pattern (like scene_bridge) to reliably catch worker completions
    /// Call this at the start of each frame, before checking dirty flags
    pub fn beginFrame(self: *AssetManager) void {
        // Reset the "updated" flags at the start of the frame
        self.materials_updated = false;
        self.texture_descriptors_updated = false;

        // Capture previous state for transition detection
        const prev_tex_dirty = self.last_texture_dirty;
        const prev_mat_dirty = self.last_material_dirty;
        const prev_tex_updating = self.last_texture_updating;
        const prev_mat_updating = self.last_material_updating;

        // Check if we need to queue texture descriptor updates
        const tex_updating = self.texture_descriptors_updating.load(.acquire);
        if (self.texture_descriptors_dirty and !tex_updating) {
            self.queueTextureDescriptorUpdate() catch |err| {
                log(.WARN, "asset_manager", "Failed to queue texture descriptor update: {}", .{err});
            };
        }

        // Check if we need to queue material buffer updates
        const mat_updating = self.material_buffer_updating.load(.acquire);
        if (self.materials_dirty and !mat_updating) {
            self.queueMaterialBufferUpdate() catch |err| {
                log(.WARN, "asset_manager", "Failed to queue material buffer update: {}", .{err});
            };
        }

        // Capture current state
        const curr_tex_dirty = self.texture_descriptors_dirty;
        const curr_mat_dirty = self.materials_dirty;
        const curr_tex_updating = self.texture_descriptors_updating.load(.acquire);
        const curr_mat_updating = self.material_buffer_updating.load(.acquire);

        // Update state tracking for next frame
        self.last_texture_dirty = curr_tex_dirty;
        self.last_material_dirty = curr_mat_dirty;
        self.last_texture_updating = curr_tex_updating;
        self.last_material_updating = curr_mat_updating;

        // Detect transitions: work was in progress (dirty OR updating), now it's done (both false)
        const texture_completed = (prev_tex_dirty or prev_tex_updating) and !curr_tex_dirty and !curr_tex_updating;
        const material_completed = (prev_mat_dirty or prev_mat_updating) and !curr_mat_dirty and !curr_mat_updating;

        // Set update flags when transitions are detected
        if (texture_completed) {
            self.texture_descriptors_updated = true;
        }

        if (material_completed) {
            self.materials_updated = true;
        }
    }

    /// Check if asset is ready for use
    pub fn isAssetReady(self: *AssetManager, asset_id: AssetId) bool {
        return self.registry.getAssetState(asset_id) == .loaded;
    }

    /// Get asset loading priority based on distance and importance
    pub fn calculatePriority(distance: f32, is_player_visible: bool, is_ui_element: bool) LoadPriority {
        if (is_ui_element) return .critical;
        if (is_player_visible and distance < 20.0) return .high;
        return LoadPriority.fromDistance(distance);
    }

    /// Print performance report
    pub fn printPerformanceReport(self: *AssetManager) void {
        const stats = self.getStatistics();
        log(.INFO, "enhanced_asset_manager", "=== Enhanced Asset Manager Performance Report ===", .{});
        log(.INFO, "enhanced_asset_manager", "Active loads: {d}, Completed loads: {d}", .{ stats.active_loads, stats.completed_loads });
        log(.INFO, "enhanced_asset_manager", "Cache hits: {d}, Cache misses: {d}", .{ stats.cache_hits, stats.cache_misses });
        log(.INFO, "enhanced_asset_manager", "Thread pool efficiency: {d:.1}%", .{(@as(f32, @floatFromInt(stats.completed_loads)) * 100.0) / @as(f32, @floatFromInt(stats.active_loads + stats.completed_loads))});

        if (self.hot_reload_manager) |hot_reload| {
            const reload_stats = hot_reload.getStatistics();
            log(.INFO, "enhanced_asset_manager", "Hot reload stats - batched: {d}, successful: {d}, failed: {d}", .{ reload_stats.batched_reloads, reload_stats.successful_reloads, reload_stats.failed_reloads });
        }
    }
};

/// Worker function for async texture descriptor updates
fn textureDescriptorUpdateWorker(context: ?*anyopaque, work_item: WorkItem) void {
    _ = work_item;
    const asset_manager = @as(*AssetManager, @ptrCast(@alignCast(context)));

    asset_manager.buildTextureDescriptorArray() catch |err| {
        log(.WARN, "enhanced_asset_manager", "Failed to build texture descriptor array: {}", .{err});
        asset_manager.texture_descriptors_updating.store(false, .release);
        return;
    };

    // Clear internal dirty flag and set external updated flag for renderers
    asset_manager.texture_descriptors_dirty = false;
    asset_manager.texture_descriptors_updated = true;
    asset_manager.texture_descriptors_updating.store(false, .release);
}

/// Worker function for async material buffer updates
fn materialBufferUpdateWorker(context: ?*anyopaque, work_item: WorkItem) void {
    _ = work_item;
    const asset_manager = @as(*AssetManager, @ptrCast(@alignCast(context)));

    asset_manager.createMaterialBuffer(asset_manager.loader.graphics_context) catch |err| {
        log(.WARN, "enhanced_asset_manager", "Failed to create material buffer: {}", .{err});
        asset_manager.material_buffer_updating.store(false, .release);
        return;
    };

    // Clear internal dirty flag and set external updated flag for renderers
    asset_manager.materials_dirty = false;
    asset_manager.materials_updated = true;
    asset_manager.material_buffer_updating.store(false, .release);
}
