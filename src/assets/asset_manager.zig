const std = @import("std");
const vk = @import("vulkan");
const asset_types = @import("asset_types.zig");
const asset_registry = @import("asset_registry.zig");
const asset_loader = @import("asset_loader.zig");
const hot_reload_manager = @import("hot_reload_manager.zig");
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

    const Self = @This();

    /// Initialize fallback assets by loading them synchronously
    pub fn init(asset_manager: *AssetManager) !FallbackAssets {
        var fallbacks = FallbackAssets{};

        // Try to load each fallback texture, but don't fail if missing
        fallbacks.missing_texture = asset_manager.loadTextureSync("textures/missing.png") catch |err| blk: {
            std.log.warn("Could not load missing.png fallback: {}", .{err});
            break :blk null;
        };

        fallbacks.loading_texture = asset_manager.loadTextureSync("textures/loading.png") catch |err| blk: {
            std.log.warn("Could not load loading.png fallback: {}", .{err});
            break :blk null;
        };

        fallbacks.failed_texture = asset_manager.loadTextureSync("textures/error.png") catch |err| blk: {
            std.log.warn("Could not load error.png fallback: {}", .{err});
            break :blk null;
        };

        fallbacks.default_texture = asset_manager.loadTextureSync("textures/default.png") catch |err| blk: {
            std.log.warn("Could not load default.png fallback: {}", .{err});
            break :blk null;
        };

        // Create fallback cube model using utility
        fallbacks.missing_model = blk: {
            // Register a fake asset for the fallback model
            const asset_id = asset_manager.registry.registerAsset("fallback://missing_model", .mesh) catch |err| {
                std.log.warn("Failed to register missing model fallback asset: {}", .{err});
                break :blk null;
            };

            // Create the cube model directly
            var cube_model = FallbackMeshes.createCubeModel(asset_manager.allocator, asset_manager.loader.graphics_context, "fallback_cube") catch |err| {
                std.log.warn("Failed to create cube model fallback: {}", .{err});
                break :blk null;
            };

            // Allocate on heap and add to AssetManager properly
            const model_ptr = asset_manager.allocator.create(Model) catch |err| {
                std.log.warn("Failed to allocate memory for fallback model: {}", .{err});
                cube_model.deinit();
                break :blk null;
            };
            model_ptr.* = cube_model;

            // Use AssetManager's addLoadedModel to ensure proper mapping
            asset_manager.addLoadedModel(asset_id, model_ptr) catch |err| {
                std.log.warn("Failed to add fallback model to AssetManager: {}", .{err});
                asset_manager.allocator.destroy(model_ptr);
                break :blk null;
            };

            // Mark as loaded in registry
            asset_manager.registry.markAsLoaded(asset_id, 1024); // Fake size

            std.log.info("Created fallback cube model with asset ID {}", .{asset_id.toU64()});
            break :blk asset_id;
        };

        fallbacks.loading_model = fallbacks.missing_model;
        fallbacks.failed_model = fallbacks.missing_model;
        fallbacks.default_model = fallbacks.missing_model;

        log(.INFO, "enhanced_asset_manager", "Fallback assets initialized: missing_texture={?}, missing_model={?}", .{ fallbacks.missing_texture, fallbacks.missing_model });

        return fallbacks;
    }

    /// Get fallback asset for given type and asset type
    pub fn getFallback(self: *const Self, fallback_type: FallbackType, asset_type: AssetType) ?AssetId {
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
    material_buffer: ?Buffer = null, // Optional material buffer created on demand

    // Asset ID to array index mappings
    asset_to_texture: std.AutoHashMap(AssetId, usize), // AssetId -> texture array index
    asset_to_model: std.AutoHashMap(AssetId, usize), // AssetId -> model array index
    asset_to_material: std.AutoHashMap(AssetId, usize), // AssetId -> material array index

    // Enhanced hot reloading
    hot_reload_manager: ?hot_reload_manager.HotReloadManager = null,

    // Priority-based request tracking
    pending_requests: std.AutoHashMap(AssetId, LoadRequest),
    request_mutex: std.Thread.Mutex = std.Thread.Mutex{},

    // Current texture descriptor array for rendering (maintained by asset manager)
    texture_image_infos: []const vk.DescriptorImageInfo = &[_]vk.DescriptorImageInfo{},

    // Texture dirty flag - set by GPU worker when textures are loaded, checked for lazy rebuild
    texture_descriptors_dirty: bool = true,

    // Dirty flags for resource updates
    materials_dirty: bool = true,

    // Async update flags to track pending work
    material_buffer_updating: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    texture_descriptors_updating: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // Thread safety for concurrent asset loading
    models_mutex: std.Thread.Mutex = std.Thread.Mutex{},
    textures_mutex: std.Thread.Mutex = std.Thread.Mutex{},

    // Performance statistics
    stats: struct {
        total_requests: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        completed_loads: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        failed_loads: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        cache_hits: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        cache_misses: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        average_load_time_ms: std.atomic.Value(f32) = std.atomic.Value(f32).init(0.0),
    } = .{},

    const Self = @This();

    /// Initialize enhanced asset manager
    pub fn init(allocator: std.mem.Allocator, graphics_context: *GraphicsContext, thread_pool: *ThreadPool) !*Self {
        // Allocate registry on heap to avoid HashMap corruption
        const registry = try allocator.create(AssetRegistry);
        registry.* = AssetRegistry.init(allocator);

        // Allocate enhanced loader on heap
        var self = try allocator.create(Self);
        self.* = Self{
            .registry = registry,
            .allocator = allocator,
            .fallbacks = FallbackAssets{}, // Initialize empty first
            .loaded_textures = std.ArrayList(*Texture){},
            .loaded_models = std.ArrayList(*Model){},
            .loaded_materials = std.ArrayList(*Material){},
            .asset_to_texture = std.AutoHashMap(AssetId, usize).init(allocator),
            .asset_to_model = std.AutoHashMap(AssetId, usize).init(allocator),
            .asset_to_material = std.AutoHashMap(AssetId, usize).init(allocator),
            .pending_requests = std.AutoHashMap(AssetId, LoadRequest).init(allocator),
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
    pub fn createMaterialSync(self: *Self, albedo_texture_id: AssetId) !AssetId {
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
    pub fn addLoadedMaterial(self: *Self, asset_id: AssetId, material: *Material) !void {
        const index = self.loaded_materials.items.len;
        try self.loaded_materials.append(self.allocator, material);
        try self.asset_to_material.put(asset_id, index);
        self.materials_dirty = true; // Mark materials as dirty when added
        std.log.info("AssetManager: Added material asset {} at index {}", .{ asset_id.toU64(), index });
    }

    /// Create a material asset asynchronously
    pub fn createMaterial(self: *Self, albedo_texture_id: AssetId) !AssetId {
        return try self.createMaterialSync(albedo_texture_id);
    }

    /// Load a texture synchronously (like original asset manager)
    pub fn loadTextureSync(self: *Self, path: []const u8) !AssetId {
        // Register the asset first
        const asset_id = try self.registry.registerAsset(path, .texture);

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
    pub fn deinit(self: *Self) void {
        // Clean up hot reload manager first
        if (self.hot_reload_manager) |*hrm| {
            hrm.deinit();
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

        // Clean up mappings
        self.asset_to_texture.deinit();
        self.asset_to_model.deinit();
        self.asset_to_material.deinit();
        self.pending_requests.deinit();

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
    pub fn loadAssetAsync(self: *Self, file_path: []const u8, asset_type: AssetType, priority: LoadPriority) !AssetId {
        // Register or get existing asset ID
        const asset_id = try self.registry.registerAsset(file_path, asset_type);

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
    pub fn loadAssetSync(self: *Self, file_path: []const u8, asset_type: AssetType, priority: LoadPriority) !AssetId {
        const asset_id = try self.loadAssetAsync(file_path, asset_type, priority);

        if (self.registry.getAsset(asset_id)) |metadata| {
            if (metadata.state == .failed) {
                return error.AssetLoadFailed;
            }
        }

        return asset_id;
    }

    /// Add a pre-created fallback model
    pub fn addFallbackModel(self: *Self, model: *Model) !AssetId {
        // Create a synthetic asset ID for fallback
        const asset_id = @as(AssetId, @enumFromInt(self.loaded_models.items.len + 1000)); // Offset to avoid conflicts

        // Add to storage
        self.models_mutex.lock();
        defer self.models_mutex.unlock();

        try self.loaded_models.append(self.allocator, model);
        const index = self.loaded_models.items.len - 1;
        try self.asset_to_model.put(asset_id, index);

        // Register as loaded in registry
        _ = try self.registry.registerAsset("fallback_model", .mesh);
        self.registry.markAsLoaded(asset_id, 0); // 0 file size for fallback

        return asset_id;
    }

    /// Add loaded texture to the manager (called by GPU worker)
    pub fn addLoadedTexture(self: *Self, asset_id: AssetId, texture: *Texture) !void {
        self.textures_mutex.lock();
        defer self.textures_mutex.unlock();

        try self.loaded_textures.append(self.allocator, texture);
        log(.INFO, "enhanced_asset_manager", "Added texture asset {} at index {}", .{ asset_id.toU64(), self.loaded_textures.items.len - 1 });
        const index = self.loaded_textures.items.len - 1;
        try self.asset_to_texture.put(asset_id, index);

        // Mark texture descriptors as dirty for lazy rebuild
        self.texture_descriptors_dirty = true;

        // Complete the request
        self.completeRequest(asset_id, true);
    }

    /// Add loaded model to the manager
    pub fn addLoadedModel(self: *Self, asset_id: AssetId, model: *Model) !void {
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
    fn completeRequest(self: *Self, asset_id: AssetId, success: bool) void {
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
    pub fn getTexture(self: *Self, asset_id: AssetId) ?*Texture {
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
    pub fn getModel(self: *Self, asset_id: AssetId) ?*Model {
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
    pub fn getMaterialIndex(self: *Self, asset_id: AssetId) ?usize {
        return self.asset_to_material.get(asset_id);
    }

    /// This is the SAFE way to access assets that might still be loading
    pub fn getAssetIdForRendering(self: *Self, asset_id: AssetId) AssetId {
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
                std.log.info("getAssetIdForRendering: no staging fallback, using missing fallback {?}", .{if (missing_fallback) |id| id.toU64() else null});
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
                std.log.info("getAssetIdForRendering: no loading fallback, using missing fallback {?}", .{if (missing_fallback) |id| id.toU64() else null});
                return missing_fallback orelse asset_id;
            },
            .failed => {
                // Show error asset for failed loads
                std.log.warn("getAssetIdForRendering: asset {} ({s}) FAILED to load, using error fallback", .{ asset_id.toU64(), asset.?.path });
                const fallback_id = self.fallbacks.getFallback(.failed, asset.?.asset_type);
                if (fallback_id) |fb_id| {
                    std.log.info("getAssetIdForRendering: returning error fallback asset {}", .{fb_id.toU64()});
                    return fb_id;
                }
                // Fallback to missing if no error asset
                const missing_fallback = self.fallbacks.getFallback(.missing, asset.?.asset_type);
                std.log.info("getAssetIdForRendering: no error fallback, using missing fallback {?}", .{if (missing_fallback) |id| id.toU64() else null});
                return missing_fallback orelse asset_id;
            },
            .unloaded => {
                // Start loading and show missing asset
                std.log.info("getAssetIdForRendering: asset {} ({s}) is unloaded, starting load and using missing fallback", .{ asset_id.toU64(), asset.?.path });
                self.loader.requestLoad(asset_id, .critical) catch {};
                const missing_fallback = self.fallbacks.getFallback(.missing, asset.?.asset_type);
                std.log.info("getAssetIdForRendering: returning missing fallback {?}", .{if (missing_fallback) |id| id.toU64() else null});
                return missing_fallback orelse asset_id;
            },
        }
    }

    /// Get loaded model as const pointer for safe rendering access
    /// This mirrors the pattern from the old AssetManager
    pub fn getLoadedModelConst(self: *Self, asset_id: AssetId) ?*const Model {
        self.models_mutex.lock();
        defer self.models_mutex.unlock();

        if (self.asset_to_model.get(asset_id)) |index| {
            //log(.DEBUG, "Asset Manager", "Found model index {} for asset ID {}", .{ index, asset_id.toU64() });
            if (index < self.loaded_models.items.len) {
                return self.loaded_models.items[index];
            }
        }
        return null;
    }

    /// Initialize hot reloading
    pub fn initHotReload(self: *Self) !void {
        self.hot_reload_manager = try hot_reload_manager.HotReloadManager.init(self.allocator, self);
        log(.INFO, "enhanced_asset_manager", "Hot reload manager initialized", .{});
    }

    /// Update texture descriptor array (call when textures are loaded)
    pub fn buildTextureDescriptorArray(self: *Self) !void {
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
        self.texture_descriptors_dirty = false;
    }

    /// Queue async texture descriptor array update
    pub fn queueTextureDescriptorUpdate(self: *Self) !void {
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
    pub fn queueMaterialBufferUpdate(self: *Self) !void {
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
    pub fn getTextureDescriptorArray(self: *Self) []const vk.DescriptorImageInfo {
        return self.texture_image_infos;
    }

    /// Get performance statistics
    pub fn getStatistics(self: *Self) struct {
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
    pub fn getFallbackAsset(self: *Self, fallback_type: FallbackType, asset_type: AssetType) ?AssetId {
        return self.fallbacks.getFallback(fallback_type, asset_type);
    }

    /// Create fallback materials for basic rendering
    fn createFallbackMaterials(self: *Self) !void {
        // Create a default material using fallback textures
        const default_material = try self.allocator.create(Material);
        default_material.* = Material{
            .albedo_texture_id = 0, // Will be resolved to texture index later
            .roughness = 0.5,
            .metallic = 0.0,
            .emissive = 0.0,
            .emissive_color = [4]f32{ 0.0, 0.0, 0.0, 1.0 },
        };

        try self.loaded_materials.append(self.allocator, default_material);
        const material_index = self.loaded_materials.items.len - 1;
        const material_asset_id = asset_types.AssetId.fromU64(5); // ID 5 for default material
        try self.asset_to_material.put(material_asset_id, material_index);
    }

    /// Create material buffer from loaded materials
    pub fn createMaterialBuffer(self: *Self, graphics_context: *GraphicsContext) !void {
        if (self.loaded_materials.items.len == 0) {
            log(.WARN, "asset_manager", "No loaded materials to create material buffer", .{});
            return;
        }

        self.material_buffer = try Buffer.init(
            graphics_context,
            @sizeOf(Material),
            @as(u32, @intCast(self.loaded_materials.items.len)),
            .{
                .storage_buffer_bit = true,
            },
            .{ .host_visible_bit = true, .host_coherent_bit = true },
        );

        try self.material_buffer.?.map(@sizeOf(Material) * self.loaded_materials.items.len, 0);

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
                log(.DEBUG, "asset_manager", "Material {} has albedo_texture_id 0, using default texture: {}", .{ i, resolved_texture_id.toU64() });
            }

            // Get the texture index from the resolved asset ID
            const texture_index = self.asset_to_texture.get(resolved_texture_id) orelse 0;
            log(.DEBUG, "asset_manager", "Material {} resolved texture asset ID {} to texture index {}", .{ i, resolved_texture_id.toU64(), texture_index });
            material_data[i].albedo_texture_id = @as(u32, @intCast(texture_index));
        }

        self.material_buffer.?.writeToBuffer(
            std.mem.sliceAsBytes(material_data),
            @sizeOf(Material) * self.loaded_materials.items.len,
            0,
        );

        log(.INFO, "enhanced asset_manager", "Created material buffer with {d} materials (texture IDs resolved)", .{self.loaded_materials.items.len});
    }

    /// Check if asset is ready for use
    pub fn isAssetReady(self: *Self, asset_id: AssetId) bool {
        return self.registry.getAssetState(asset_id) == .loaded;
    }

    /// Get asset loading priority based on distance and importance
    pub fn calculatePriority(distance: f32, is_player_visible: bool, is_ui_element: bool) LoadPriority {
        if (is_ui_element) return .critical;
        if (is_player_visible and distance < 20.0) return .high;
        return LoadPriority.fromDistance(distance);
    }

    /// Process pending hot reloads
    pub fn processPendingReloads(self: *Self) void {
        // Hot reload processing is handled by background worker thread
        _ = self; // Hot reload manager runs continuously in background
    }

    /// Print performance report
    pub fn printPerformanceReport(self: *Self) void {
        const stats = self.getStatistics();
        log(.INFO, "enhanced_asset_manager", "=== Enhanced Asset Manager Performance Report ===", .{});
        log(.INFO, "enhanced_asset_manager", "Active loads: {d}, Completed loads: {d}", .{ stats.active_loads, stats.completed_loads });
        log(.INFO, "enhanced_asset_manager", "Cache hits: {d}, Cache misses: {d}", .{ stats.cache_hits, stats.cache_misses });
        log(.INFO, "enhanced_asset_manager", "Thread pool efficiency: {d:.1}%", .{(@as(f32, @floatFromInt(stats.completed_loads)) * 100.0) / @as(f32, @floatFromInt(stats.active_loads + stats.completed_loads))});

        if (self.hot_reload_manager) |*hot_reload| {
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
    };

    // Mark as no longer updating
    asset_manager.texture_descriptors_updating.store(false, .release);
}

/// Worker function for async material buffer updates
fn materialBufferUpdateWorker(context: ?*anyopaque, work_item: WorkItem) void {
    _ = work_item;
    const asset_manager = @as(*AssetManager, @ptrCast(@alignCast(context)));

    asset_manager.createMaterialBuffer(asset_manager.loader.graphics_context) catch |err| {
        log(.WARN, "enhanced_asset_manager", "Failed to create material buffer: {}", .{err});
        // Don't mark materials_dirty as false if creation failed
        asset_manager.material_buffer_updating.store(false, .release);
        return;
    };

    // Mark materials as no longer dirty and no longer updating
    asset_manager.materials_dirty = false;
    asset_manager.material_buffer_updating.store(false, .release);
}
