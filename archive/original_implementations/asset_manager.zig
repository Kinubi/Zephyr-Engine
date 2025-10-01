const std = @import("std");
const vk = @import("vulkan");
const asset_types = @import("asset_types.zig");
const asset_registry = @import("asset_registry.zig");
const asset_loader = @import("asset_loader.zig");
const HotReloadManager = @import("hot_reload_manager.zig").HotReloadManager;
const GraphicsContext = @import("../core/graphics_context.zig").GraphicsContext;
const Model = @import("../rendering/mesh.zig").Model;
const Texture = @import("../core/texture.zig").Texture;
const Material = @import("../scene/scene.zig").Material;
const Buffer = @import("../core/buffer.zig").Buffer;
const log = @import("../utils/log.zig").log;

// Re-export key types for convenience
pub const AssetId = asset_types.AssetId;
pub const AssetType = asset_types.AssetType;
pub const AssetState = asset_types.AssetState;
pub const AssetMetadata = asset_types.AssetMetadata;
pub const AssetRegistry = asset_registry.AssetRegistry;
pub const AssetLoader = asset_loader.AssetLoader;

/// Types of fallback assets for different scenarios
pub const FallbackType = enum {
    missing, // Pink checkerboard for missing textures
    loading, // Animated or static "loading..." texture
    staged, // Animated or static "loading..." texture
    @"error", // Red X or error indicator (error is keyword)
    default, // Basic white texture for materials
};

/// Pre-loaded fallback assets for safe rendering
pub const FallbackAssets = struct {
    missing_texture: ?AssetId = null,
    loading_texture: ?AssetId = null,
    error_texture: ?AssetId = null,
    default_texture: ?AssetId = null,

    // Fallback models
    missing_model: ?AssetId = null,
    loading_model: ?AssetId = null,
    error_model: ?AssetId = null,
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

        fallbacks.error_texture = asset_manager.loadTextureSync("textures/error.png") catch |err| blk: {
            std.log.warn("Could not load error.png fallback: {}", .{err});
            break :blk null;
        };

        fallbacks.default_texture = asset_manager.loadTextureSync("textures/default.png") catch |err| blk: {
            std.log.warn("Could not load default.png fallback: {}", .{err});
            break :blk null;
        };

        // Create fallback models directly using FallbackMeshes
        const FallbackMeshes = @import("../utils/fallback_meshes.zig").FallbackMeshes;

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

        fallbacks.loading_model = fallbacks.missing_model; // Reuse cube for loading state
        fallbacks.error_model = fallbacks.missing_model; // Reuse cube for error state
        fallbacks.default_model = fallbacks.missing_model; // Reuse cube for default state

        std.log.info("Fallback assets initialized: missing_texture={?}, missing_model={?}", .{ if (fallbacks.missing_texture) |id| id.toU64() else null, if (fallbacks.missing_model) |id| id.toU64() else null });

        return fallbacks;
    }

    /// Get fallback asset ID for given type
    pub fn getAssetId(self: *const Self, fallback_type: FallbackType) ?AssetId {
        const result = switch (fallback_type) {
            .missing => self.missing_texture,
            .loading => self.loading_texture,
            .@"error" => self.error_texture,
            .default => self.default_texture,
            .staged => self.loading_texture, // Reuse loading texture for staged
        };
        std.log.debug("getAssetId({s}) = {?}", .{ @tagName(fallback_type), if (result) |id| id.toU64() else null });
        return result;
    }

    /// Get fallback model asset ID for given type
    pub fn getModelAssetId(self: *const Self, fallback_type: FallbackType) ?AssetId {
        const result = switch (fallback_type) {
            .missing => self.missing_model,
            .loading => self.loading_model,
            .@"error" => self.error_model,
            .default => self.default_model,
            .staged => self.loading_model, // Reuse missing model for staged
        };
        return result;
    }
};

/// Central Asset Manager that coordinates all asset operations
/// This is the main interface for the game engine to interact with assets
pub const AssetManager = struct {
    // Core components (using pointers to avoid HashMap moves)
    registry: *AssetRegistry,
    loader: *AssetLoader,
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

    // Hot reloading
    hot_reload_manager: ?HotReloadManager = null,

    // Current texture descriptor array for rendering (maintained by asset manager)
    texture_image_infos: []const vk.DescriptorImageInfo = &[_]vk.DescriptorImageInfo{},

    // Texture dirty flag - set by GPU worker when textures are loaded, checked for lazy rebuild
    texture_descriptors_dirty: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),

    // Dirty flags for resource updates
    materials_dirty: bool = false,

    // Thread safety for concurrent asset loading
    models_mutex: std.Thread.Mutex = std.Thread.Mutex{},
    textures_mutex: std.Thread.Mutex = std.Thread.Mutex{},

    // Configuration
    max_loader_threads: u32 = 4,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, graphics_context: *GraphicsContext) !Self {
        // Allocate registry on heap to avoid HashMap corruption
        const registry = try allocator.create(AssetRegistry);
        registry.* = AssetRegistry.init(allocator);

        // Allocate loader on heap
        const loader = try allocator.create(AssetLoader);
        loader.* = try AssetLoader.init(allocator, registry, graphics_context, 8);

        var self = Self{
            .registry = registry,
            .loader = loader,
            .allocator = allocator,
            .fallbacks = FallbackAssets{}, // Initialize empty first
            .loaded_textures = std.ArrayList(*Texture){},
            .loaded_models = std.ArrayList(*Model){},
            .loaded_materials = std.ArrayList(*Material){},
            .asset_to_texture = std.AutoHashMap(AssetId, usize).init(allocator),
            .asset_to_model = std.AutoHashMap(AssetId, usize).init(allocator),
            .asset_to_material = std.AutoHashMap(AssetId, usize).init(allocator),
        };

        // Don't start GPU worker here - it will be started after AssetManager is heap-allocated
        // and has a stable address
        // try self.loader.startGpuWorker(&self);

        // Initialize fallback assets after AssetManager is created
        self.fallbacks = try FallbackAssets.init(&self);

        return self;
    }

    /// Start the GPU worker after AssetManager has a stable heap address
    pub fn startGpuWorker(self: *Self) !void {
        try self.loader.startGpuWorker(self);
    }

    pub fn deinit(self: *Self) void {
        // Clean up hot reload manager
        if (self.hot_reload_manager) |*manager| {
            manager.deinit();
        }

        // Clean up loaded asset arrays
        self.loaded_textures.deinit(self.allocator);
        self.loaded_models.deinit(self.allocator);
        self.loaded_materials.deinit(self.allocator);
        self.asset_to_texture.deinit();
        self.asset_to_model.deinit();
        self.asset_to_material.deinit();

        // Stop GPU worker before deinitializing loader to ensure thread exits
        self.loader.stopGpuWorker();
        self.loader.deinit();
        self.registry.deinit();

        // Free heap allocations
        self.allocator.destroy(self.loader);
        self.allocator.destroy(self.registry);
    }

    /// Set callback for ThreadPool running status changes
    pub fn setThreadPoolCallback(self: *Self, callback: *const fn (bool) void) void {
        self.loader.setThreadPoolCallback(callback);
    }

    pub fn registerObjectForAsset(self: *Self, asset_id: AssetId, object_id: u64) void {
        var list = self.asset_to_objects.getPtr(asset_id) orelse blk: {
            const new_list = std.ArrayList(u64).init(self.allocator);
            self.asset_to_objects.put(asset_id, new_list) catch return;
            break :blk self.asset_to_objects.getPtr(asset_id).?;
        };
        list.append(object_id) catch {};
    }

    // pub fn onAssetLoaded(self: *Self, asset_id: AssetId) void {
    //     if (self.asset_to_objects.get(asset_id)) |object_ids| {
    //         for (object_ids.items) |object_id| {
    //             // Notify scene or system to update object with object_id
    //             // (Implement callback or event system as needed)
    //         }
    //     }
    // }

    /// Get a loaded model by AssetId
    pub fn getLoadedModel(self: *Self, asset_id: AssetId) ?Model {
        self.models_mutex.lock();
        defer self.models_mutex.unlock();

        if (self.asset_to_model.get(asset_id)) |index| {
            if (index < self.loaded_models.items.len) {
                return self.loaded_models.items[index].*;
            }
        }
        return null;
    }

    /// Get a loaded texture by AssetId
    pub fn getLoadedTexture(self: *Self, asset_id: AssetId) ?Texture {
        self.textures_mutex.lock();
        defer self.textures_mutex.unlock();

        if (self.asset_to_texture.get(asset_id)) |index| {
            if (index < self.loaded_textures.items.len) {
                return self.loaded_textures.items[index].*;
            }
        }
        return null;
    }

    /// Non-destructive const pointer access to loaded model (preferred)
    pub fn getLoadedModelConst(self: *Self, asset_id: AssetId) ?*const Model {
        self.models_mutex.lock();
        defer self.models_mutex.unlock();

        if (self.asset_to_model.get(asset_id)) |index| {
            if (index < self.loaded_models.items.len) {
                return self.loaded_models.items[index];
            } else {}
        } else {}
        return null;
    }

    /// Non-destructive const pointer access to loaded texture (preferred)
    pub fn getLoadedTextureConst(self: *Self, asset_id: AssetId) ?*const Texture {
        self.textures_mutex.lock();
        defer self.textures_mutex.unlock();

        if (self.asset_to_texture.get(asset_id)) |index| {
            if (index < self.loaded_textures.items.len) {
                return self.loaded_textures.items[index];
            }
        }
        return null;
    }

    /// Add a loaded texture to the asset manager
    pub fn addLoadedTexture(self: *Self, asset_id: AssetId, texture: *Texture) !void {
        self.textures_mutex.lock();
        defer self.textures_mutex.unlock();

        const index = self.loaded_textures.items.len;
        try self.loaded_textures.append(self.allocator, texture);
        try self.asset_to_texture.put(asset_id, index);
        self.materials_dirty = true; // Mark materials as dirty when textures change
        self.texture_descriptors_dirty.store(true, .release); // Mark texture descriptors as dirty
        std.log.info("AssetManager: Added texture asset {} at index {}, marking descriptors dirty", .{ asset_id.toU64(), index });
    }

    /// Add a loaded model to the asset manager (thread-safe)
    pub fn addLoadedModel(self: *Self, asset_id: AssetId, model: *Model) !void {
        self.models_mutex.lock();
        defer self.models_mutex.unlock();

        // Use a local scope to avoid any potential memory corruption
        const safe_asset_id = asset_id;
        const safe_model = model;

        const index = self.loaded_models.items.len;

        // Append and update mapping atomically
        try self.loaded_models.append(self.allocator, safe_model);
        try self.asset_to_model.put(safe_asset_id, index);

        log(.INFO, "asset_manager", "Successfully added model asset {} at index {}", .{ safe_asset_id.toU64(), index });
    }

    /// Non-destructive const pointer access to loaded material (preferred)
    pub fn getLoadedMaterialConst(self: *Self, asset_id: AssetId) ?*const Material {
        if (self.asset_to_material.get(asset_id)) |index| {
            if (index < self.loaded_materials.items.len) {
                return self.loaded_materials.items[index];
            }
        }
        return null;
    }

    /// Add a loaded material to the asset manager
    pub fn addLoadedMaterial(self: *Self, asset_id: AssetId, material: *Material) !void {
        const index = self.loaded_materials.items.len;
        try self.loaded_materials.append(self.allocator, material);
        try self.asset_to_material.put(asset_id, index);
        self.materials_dirty = true; // Mark materials as dirty when added
        std.log.info("AssetManager: Added material asset {} at index {}", .{ asset_id.toU64(), index });
    }

    // Asset Registration

    /// Register a new asset at the given path
    /// Returns the asset ID for future reference
    pub fn registerAsset(self: *Self, path: []const u8, asset_type: AssetType) !AssetId {
        return try self.registry.registerAsset(path, asset_type);
    }

    /// Register multiple assets from a directory
    /// Note: Directory scanning is handled by the hot reload manager
    pub fn registerAssetsFromDirectory(self: *Self, directory: []const u8, recursive: bool) ![]AssetId {
        _ = self;
        _ = directory;
        _ = recursive;
        // Directory scanning is implemented in hot_reload_manager.zig
        return &[_]AssetId{};
    }

    // Asset Loading

    /// Load an asset synchronously (blocks until complete)
    /// Returns the asset ID if successful
    pub fn loadAsset(self: *Self, path: []const u8, asset_type: AssetType) !AssetId {
        const asset_id = try self.registerAsset(path, asset_type);
        try self.loader.loadSync(asset_id);

        // For synchronous loading, we need to process any staging data immediately
        // since the GPU worker thread might not be running or checking the queue
        switch (asset_type) {
            .mesh => {
                if (self.loader.completed_queue.getMesh(asset_id)) |staging| {
                    self.loader.registry.markAsLoading(asset_id);
                    std.log.info("loadAsset: Processing mesh staging for asset {}", .{asset_id.toU64()});
                    const model_ptr = self.loader.processCompletedMeshFromStaging(staging) catch |err| {
                        self.loader.registry.markAsFailed(asset_id, @errorName(err));
                        return err;
                    };
                    self.addLoadedModel(asset_id, model_ptr) catch |err| {
                        self.loader.registry.markAsFailed(asset_id, @errorName(err));
                        return err;
                    };
                    self.loader.registry.markAsLoaded(asset_id, model_ptr.meshes.items.len);
                }
            },
            .texture => {
                if (self.loader.completed_queue.getTexture(asset_id)) |staging| {
                    self.loader.registry.markAsLoading(asset_id);
                    std.log.info("loadAsset: Processing texture staging for asset {}", .{asset_id.toU64()});
                    const texture = self.loader.processCompletedTextureFromStaging(staging) catch |err| {
                        self.loader.registry.markAsFailed(asset_id, @errorName(err));
                        return err;
                    };
                    self.addLoadedTexture(asset_id, texture) catch |err| {
                        self.loader.registry.markAsFailed(asset_id, @errorName(err));
                        return err;
                    };
                }
            },
            else => {
                // Other asset types don't use staging
            },
        }

        // Auto-register for hot reloading
        self.registerAssetForHotReload(asset_id, path) catch |err| {
            log(.WARN, "asset_manager", "Failed to register asset for hot reload: {} ({})", .{ asset_id, err });
        };

        return asset_id;
    }

    /// Load an asset asynchronously
    /// Returns the asset ID immediately, asset loads in background
    pub fn loadAssetAsync(self: *Self, path: []const u8, asset_type: AssetType) !AssetId {
        std.log.warn("AssetManager: Requesting async load for asset path '{s}' of type {s}", .{ path, @tagName(asset_type) });
        const asset_id = try self.registerAsset(path, asset_type);
        std.log.warn("AssetManager: Registered asset '{s}' with ID {}, now requesting load", .{ path, asset_id.toU64() });
        try self.loader.requestLoad(asset_id);
        std.log.warn("AssetManager: Load requested for asset {} ({s})", .{ asset_id.toU64(), path });

        // Auto-register for hot reloading
        self.registerAssetForHotReload(asset_id, path) catch |err| {
            log(.WARN, "asset_manager", "Failed to register asset for hot reload: {} ({})", .{ asset_id, err });
        };

        return asset_id;
    }

    /// Load an asset by ID if already registered
    pub fn loadAssetById(self: *Self, asset_id: AssetId) !void {
        try self.loader.requestLoad(asset_id);
    }

    /// Load a texture synchronously (blocks until complete)
    /// Used for fallback assets that must be available immediately
    pub fn loadTextureSync(self: *Self, path: []const u8) !AssetId {
        return try self.loadAsset(path, .texture);
    }

    /// Load a model synchronously (blocks until complete)
    /// Used for fallback assets that must be available immediately
    pub fn loadModelSync(self: *Self, path: []const u8) !AssetId {
        return try self.loadAsset(path, .mesh);
    }

    /// Create a material synchronously
    /// Creates a material with the given texture asset ID
    pub fn createMaterialSync(self: *Self, albedo_texture_id: AssetId) !AssetId {
        // Create a unique material asset ID by registering it with the asset manager
        const material_path = try std.fmt.allocPrint(self.allocator, "material://{d}", .{albedo_texture_id.toU64()});
        defer self.allocator.free(material_path);

        const material_asset_id = try self.registerAsset(material_path, .material);

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

    // Asset Access

    /// Get asset metadata by ID
    pub fn getAsset(self: *Self, asset_id: AssetId) ?*AssetMetadata {
        return self.registry.getAsset(asset_id);
    }

    /// Get asset metadata by path
    pub fn getAssetByPath(self: *Self, path: []const u8) ?*AssetMetadata {
        return self.registry.getAssetByPath(path);
    }

    /// Get asset ID from path
    pub fn getAssetId(self: *Self, path: []const u8) ?AssetId {
        return self.registry.getAssetId(path);
    }

    /// Check if an asset is loaded and ready for use
    /// Asset is loaded if both: 1) registry says it's loaded AND 2) it exists in our asset array
    pub fn isAssetLoaded(self: *Self, asset_id: AssetId) bool {
        // First check registry state
        if (self.getAsset(asset_id)) |asset| {
            if (asset.state != .loaded) return false;

            // Registry says it's loaded, now check if it's actually in our asset arrays
            switch (asset.asset_type) {
                .texture => return self.asset_to_texture.contains(asset_id),
                .mesh => return self.asset_to_model.contains(asset_id),
                // TODO: Add other asset types as needed
                else => return false, // Unknown types not yet supported
            }
        }
        return false;
    }

    // Safe Asset Access with Fallbacks

    /// Get asset ID for rendering - returns fallback if asset not ready
    /// This is the SAFE way to access assets that might still be loading
    pub fn getAssetIdForRendering(self: *Self, asset_id: AssetId) AssetId {
        if (self.getAsset(asset_id)) |asset| {
            switch (asset.state) {
                .loaded => {
                    // Return actual asset if loaded
                    return asset_id;
                },
                .staged => {
                    // Show loading indicator while asset loads
                    const fallback_id = switch (asset.asset_type) {
                        .mesh => self.fallbacks.getModelAssetId(.loading),
                        else => self.fallbacks.getAssetId(.loading), // textures, materials, etc.
                    };
                    if (fallback_id) |fb_id| {
                        return fb_id;
                    }
                    // Fallback to missing if no loading asset
                    const missing_fallback = switch (asset.asset_type) {
                        .mesh => self.fallbacks.getModelAssetId(.missing),
                        else => self.fallbacks.getAssetId(.missing),
                    };
                    std.log.info("getAssetIdForRendering: no staging fallback, using missing fallback {?}", .{if (missing_fallback) |id| id.toU64() else null});
                    return missing_fallback orelse asset_id;
                },
                .loading => {
                    // Show loading indicator while asset loads
                    const fallback_id = switch (asset.asset_type) {
                        .mesh => self.fallbacks.getModelAssetId(.loading),
                        else => self.fallbacks.getAssetId(.loading), // textures, materials, etc.
                    };
                    if (fallback_id) |fb_id| {
                        return fb_id;
                    }
                    // Fallback to missing if no loading asset
                    const missing_fallback = switch (asset.asset_type) {
                        .mesh => self.fallbacks.getModelAssetId(.missing),
                        else => self.fallbacks.getAssetId(.missing),
                    };
                    std.log.info("getAssetIdForRendering: no loading fallback, using missing fallback {?}", .{if (missing_fallback) |id| id.toU64() else null});
                    return missing_fallback orelse asset_id;
                },
                .failed => {
                    // Show error asset for failed loads
                    std.log.warn("getAssetIdForRendering: asset {} ({s}) FAILED to load, using error fallback", .{ asset_id.toU64(), asset.path });
                    const fallback_id = switch (asset.asset_type) {
                        .mesh => self.fallbacks.getModelAssetId(.@"error"),
                        else => self.fallbacks.getAssetId(.@"error"),
                    };
                    if (fallback_id) |fb_id| {
                        std.log.info("getAssetIdForRendering: returning error fallback asset {}", .{fb_id.toU64()});
                        return fb_id;
                    }
                    // Fallback to missing if no error asset
                    const missing_fallback = switch (asset.asset_type) {
                        .mesh => self.fallbacks.getModelAssetId(.missing),
                        else => self.fallbacks.getAssetId(.missing),
                    };
                    std.log.info("getAssetIdForRendering: no error fallback, using missing fallback {?}", .{if (missing_fallback) |id| id.toU64() else null});
                    return missing_fallback orelse asset_id;
                },
                .unloaded => {
                    // Start loading and show missing asset
                    std.log.info("getAssetIdForRendering: asset {} ({s}) is unloaded, starting load and using missing fallback", .{ asset_id.toU64(), asset.path });
                    self.loadAssetById(asset_id) catch {};
                    const missing_fallback = switch (asset.asset_type) {
                        .mesh => self.fallbacks.getModelAssetId(.missing),
                        else => self.fallbacks.getAssetId(.missing),
                    };
                    std.log.info("getAssetIdForRendering: returning missing fallback {?}", .{if (missing_fallback) |id| id.toU64() else null});
                    return missing_fallback orelse asset_id;
                },
            }
        }
        // Asset doesn't exist at all - return missing fallback (assume texture if unknown)
        std.log.warn("getAssetIdForRendering: asset {} does not exist, using missing fallback", .{asset_id.toU64()});
        return self.fallbacks.getAssetId(.missing) orelse asset_id;
    }

    /// Get fallback asset ID for a specific type
    pub fn getFallbackAssetId(self: *Self, fallback_type: FallbackType) ?AssetId {
        return self.fallbacks.getAssetId(fallback_type);
    }

    // Reference Counting

    /// Increment reference count for an asset (marks as "in use")
    pub fn addRef(self: *Self, asset_id: AssetId) void {
        self.registry.incrementRef(asset_id);
    }

    /// Decrement reference count for an asset
    /// Returns true if asset can be unloaded (ref count reached zero)
    pub fn removeRef(self: *Self, asset_id: AssetId) bool {
        return self.registry.decrementRef(asset_id);
    }

    // Dependency Management

    /// Add a dependency relationship between assets
    /// The dependent asset will not unload while the dependency is referenced
    pub fn addDependency(self: *Self, dependent_id: AssetId, dependency_id: AssetId) !void {
        try self.registry.addDependency(dependent_id, dependency_id);
    }

    /// Remove a dependency relationship
    pub fn removeDependency(self: *Self, dependent_id: AssetId, dependency_id: AssetId) void {
        self.registry.removeDependency(dependent_id, dependency_id);
    }

    /// Get all assets that depend on the given asset
    pub fn getDependents(self: *Self, asset_id: AssetId) ?[]AssetId {
        if (self.getAsset(asset_id)) |asset| {
            return asset.dependents.items;
        }
        return null;
    }

    /// Get all assets that the given asset depends on
    pub fn getDependencies(self: *Self, asset_id: AssetId) ?[]AssetId {
        if (self.getAsset(asset_id)) |asset| {
            return asset.dependencies.items;
        }
        return null;
    }

    // Asset Access by ID

    /// Get texture index from asset ID
    pub fn getTextureIndex(self: *Self, asset_id: AssetId) ?usize {
        return self.asset_to_texture.get(asset_id);
    }

    /// Get model index from asset ID
    pub fn getModelIndex(self: *Self, asset_id: AssetId) ?usize {
        return self.asset_to_model.get(asset_id);
    }

    /// Get material index from asset ID
    pub fn getMaterialIndex(self: *Self, asset_id: AssetId) ?usize {
        return self.asset_to_material.get(asset_id);
    }

    /// Create a material buffer from all loaded materials with resolved texture indices
    /// This function resolves albedo_texture_id to actual available texture indices (real or fallback)
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

            // Get the texture index from the resolved asset ID
            const texture_index = self.asset_to_texture.get(resolved_texture_id) orelse 0;
            material_data[i].albedo_texture_id = @as(u32, @intCast(texture_index));

            log(.DEBUG, "asset_manager", "Material {}: resolved texture {} -> {} (index: {})", .{ i, texture_asset_id.toU64(), resolved_texture_id.toU64(), texture_index });
        }

        self.material_buffer.?.writeToBuffer(
            std.mem.sliceAsBytes(material_data),
            @sizeOf(Material) * self.loaded_materials.items.len,
            0,
        );

        log(.INFO, "asset_manager", "Created material buffer with {d} materials (texture IDs resolved)", .{self.loaded_materials.items.len});
    }

    /// Build texture descriptor array for rendering from all loaded textures
    /// This centralizes texture array building in the asset manager
    pub fn buildTextureDescriptorArray(self: *Self, allocator: std.mem.Allocator) ![]const vk.DescriptorImageInfo {
        self.textures_mutex.lock();
        defer self.textures_mutex.unlock();

        // Build descriptor array from loaded_textures ArrayList
        std.log.info("buildTextureDescriptorArray: Building from {} loaded textures", .{self.loaded_textures.items.len});

        if (self.loaded_textures.items.len == 0) {
            log(.WARN, "asset_manager", "No textures loaded - using empty descriptor array", .{});
            return &[_]vk.DescriptorImageInfo{};
        }

        // Build descriptor array directly from the ArrayList
        const infos = try allocator.alloc(vk.DescriptorImageInfo, self.loaded_textures.items.len);

        for (self.loaded_textures.items, 0..) |texture, i| {
            infos[i] = texture.getDescriptorInfo();
            std.log.info("buildTextureDescriptorArray: Placed texture at descriptor index {}", .{i});
        }

        log(.DEBUG, "asset_manager", "Built texture descriptor array: {} textures", .{self.loaded_textures.items.len});
        return infos;
    }

    /// Get current texture descriptor array for rendering
    pub fn getTextureDescriptorArray(self: *Self) []const vk.DescriptorImageInfo {
        return self.texture_image_infos;
    }

    // Memory Management

    /// Unload assets that have zero reference count
    pub fn unloadUnusedAssets(self: *Self) !u32 {
        const unloadable = try self.registry.getUnloadableAssets(self.allocator);
        defer self.allocator.free(unloadable);

        var unloaded_count: u32 = 0;
        for (unloadable) |asset_id| {
            if (self.getAsset(asset_id)) |asset| {
                // Mark as unloaded - actual GPU resource cleanup happens in renderer
                asset.state = .unloaded;
                asset.file_size = 0;
                unloaded_count += 1;
            }
        }

        return unloaded_count;
    }

    /// Get assets of a specific type
    pub fn getAssetsByType(self: *Self, asset_type: AssetType) ![]AssetId {
        return try self.registry.getAssetsByType(asset_type, self.allocator);
    }

    // Statistics and Debugging

    /// Print detailed debug information about all assets
    pub fn printDebugInfo(self: *Self) void {
        std.debug.print("\n=== Asset Manager Debug Info ===\n");

        const stats = self.getStatistics();
        std.debug.print("Total Assets: {d}\n", .{stats.total_assets});
        std.debug.print("Loaded: {d}, Loading: {d}, Failed: {d}\n", .{ stats.loaded_assets, stats.loading_assets, stats.failed_assets });
        std.debug.print("Active Loads: {d}, Queued: {d}\n", .{ stats.active_loads, stats.queued_loads });

        std.debug.print("\nAssets by Type:\n");
        inline for (std.meta.fields(AssetType)) |field| {
            const asset_type: AssetType = @enumFromInt(field.value);
            if (self.getAssetsByType(asset_type)) |assets| {
                defer self.allocator.free(assets);
                std.debug.print("  {s}: {d}\n", .{ field.name, assets.len });
            } else |_| {}
        }

        std.debug.print("\n");
    }

    /// Wait for all pending asset loads to complete
    pub fn waitForAllLoads(self: *Self) void {
        self.loader.waitForCompletion();
    }

    // Convenience methods for common asset types

    /// Load a texture asset
    pub fn loadTexture(self: *Self, path: []const u8) !AssetId {
        return try self.loadAssetAsync(path, .texture);
    }

    /// Load a mesh asset
    pub fn loadMesh(self: *Self, path: []const u8) !AssetId {
        return try self.loadAssetAsync(path, .mesh);
    }

    /// Load a material asset
    pub fn loadMaterial(self: *Self, path: []const u8) !AssetId {
        return try self.loadAssetAsync(path, .material);
    }

    /// Create a material asset asynchronously
    pub fn createMaterial(self: *Self, albedo_texture_id: AssetId) !AssetId {
        return try self.createMaterialSync(albedo_texture_id);
    }

    /// Load a shader asset
    pub fn loadShader(self: *Self, path: []const u8) !AssetId {
        return try self.loadAssetAsync(path, .shader);
    }

    /// Load an audio asset
    pub fn loadAudio(self: *Self, path: []const u8) !AssetId {
        return try self.loadAssetAsync(path, .audio);
    }

    /// Load a scene asset
    pub fn loadScene(self: *Self, path: []const u8) !AssetId {
        return try self.loadAssetAsync(path, .scene);
    }

    // Hot Reloading

    /// Enable hot reloading for assets
    pub fn enableHotReload(self: *Self) !void {
        if (self.hot_reload_manager == null) {
            self.hot_reload_manager = HotReloadManager.init(self.allocator, self);
        }

        if (self.hot_reload_manager) |*manager| {
            try manager.start();
            const hot_reload_module = @import("hot_reload_manager.zig");
            hot_reload_module.setGlobalHotReloadManager(manager);
        }
    }

    /// Disable hot reloading
    pub fn disableHotReload(self: *Self) void {
        if (self.hot_reload_manager) |*manager| {
            manager.stop();
        }
    }

    /// Process pending hot reloads (call this regularly from main thread)
    pub fn processPendingReloads(self: *Self) void {
        if (self.hot_reload_manager) |*manager| {
            manager.processPendingReloads();
        }
    }

    /// Reload a specific asset from disk
    pub fn reloadAsset(self: *Self, asset_id: AssetId, file_path: []const u8) !void {
        if (self.getAsset(asset_id)) |asset| {
            const previous_state = asset.state;

            log(.INFO, "asset_manager", "Reloading asset {} from {s} (was: {s})", .{ asset_id, file_path, @tagName(previous_state) });

            // Mark asset as loading (this will trigger fallback rendering)
            asset.state = .loading;

            // Queue for async reload with high priority
            try self.loader.loadAsync(asset_id);

            log(.DEBUG, "asset_manager", "Asset {} reload queued", .{asset_id});
        } else {
            log(.WARN, "asset_manager", "Cannot reload asset {}: not found in registry", .{asset_id});
            return error.AssetNotFound;
        }
    }

    /// Register an asset for hot reloading when its file changes
    pub fn registerAssetForHotReload(self: *Self, asset_id: AssetId, file_path: []const u8) !void {
        if (self.hot_reload_manager) |*manager| {
            try manager.registerAsset(asset_id, file_path);
        }
    }

    /// Get detailed performance and memory statistics
    pub fn getDetailedStatistics(self: *Self) AssetManagerStatistics {
        const basic_stats = self.getStatistics();

        // Calculate memory usage (approximation based on loaded assets)
        const memory_per_texture = 4 * 1024 * 1024; // Rough estimate: 4MB per texture

        var memory_used: u64 = 0;
        memory_used += basic_stats.loaded_assets * memory_per_texture; // Simplified calculation

        // Get hot reload statistics if available
        var files_watched: u32 = 0;
        var directories_watched: u32 = 0;
        var reload_events: u32 = 0;
        var total_reloads: u32 = 0;

        if (self.hot_reload_manager) |*manager| {
            // Get basic metrics from hot reload manager
            files_watched = manager.getWatchedFileCount();
            directories_watched = 3; // textures, shaders, models
            reload_events = manager.getProcessedEventCount();
            total_reloads = manager.getTotalReloadCount();
        }

        return AssetManagerStatistics{
            .total_assets = basic_stats.total_assets,
            .loaded_assets = basic_stats.loaded_assets,
            .failed_assets = basic_stats.failed_assets,
            .loading_assets = basic_stats.loading_assets,
            .active_loads = basic_stats.active_loads,
            .completed_loads = basic_stats.completed_loads,
            .failed_loads = basic_stats.failed_loads,
            .queued_loads = basic_stats.queued_loads,

            // Enhanced metrics
            .memory_used_bytes = memory_used,
            .memory_allocated_bytes = memory_used + (basic_stats.loading_assets * memory_per_texture),
            .average_load_time_ms = if (basic_stats.completed_loads > 0)
                @floatFromInt(basic_stats.completed_loads * 25)
            else
                0.0, // Estimated based on completed loads
            .hot_reload_count = total_reloads,
            .cache_hit_ratio = if (basic_stats.completed_loads + basic_stats.failed_loads > 0)
                @as(f32, @floatFromInt(basic_stats.completed_loads)) /
                    @as(f32, @floatFromInt(basic_stats.completed_loads + basic_stats.failed_loads))
            else
                0.0,

            // Hot reload metrics
            .files_watched = files_watched,
            .directories_watched = directories_watched,
            .reload_events_processed = reload_events,
        };
    }

    /// Print comprehensive performance report
    pub fn printPerformanceReport(self: *Self) void {
        const stats = self.getDetailedStatistics();

        log(.INFO, "asset_manager", "=== Asset Manager Performance Report ===", .{});
        log(.INFO, "asset_manager", "Assets: {d} total, {d} loaded, {d} loading, {d} failed", .{ stats.total_assets, stats.loaded_assets, stats.loading_assets, stats.failed_assets });
        log(.INFO, "asset_manager", "Memory: {d:.1} MB used, {d:.1} MB allocated", .{ @as(f64, @floatFromInt(stats.memory_used_bytes)) / (1024.0 * 1024.0), @as(f64, @floatFromInt(stats.memory_allocated_bytes)) / (1024.0 * 1024.0) });
        log(.INFO, "asset_manager", "Performance: {d:.1}ms avg load, {d:.1}% cache hit ratio", .{ stats.average_load_time_ms, stats.cache_hit_ratio * 100.0 });
        log(.INFO, "asset_manager", "Hot Reload: {d} reloads, {d} files watched, {d} dirs watched", .{ stats.hot_reload_count, stats.files_watched, stats.directories_watched });
        log(.INFO, "asset_manager", "ThreadPool: {d} active loads, {d} completed loads", .{ stats.active_loads, stats.completed_loads });
    }

    // === Asset Replacement System ===

    /// Get comprehensive statistics about asset manager state
    pub fn getStatistics(self: *Self) AssetManagerStatistics {
        const registry_stats = self.registry.getStatistics();
        const loader_stats = self.loader.getStatistics();

        return AssetManagerStatistics{
            .total_assets = registry_stats.total_assets,
            .loaded_assets = registry_stats.loaded_assets,
            .failed_assets = registry_stats.failed_assets,
            .loading_assets = registry_stats.loading_assets,
            .active_loads = loader_stats.active_loads,
            .completed_loads = loader_stats.completed_loads,
            .failed_loads = loader_stats.failed_loads,
            .queued_loads = 0, // Priority queues removed
            .memory_used_bytes = 0, // Not available in LoaderStatistics
            .memory_allocated_bytes = 0, // Not available in LoaderStatistics
            .average_load_time_ms = 0.0, // Not available in LoaderStatistics
            .hot_reload_count = 0, // HotReloadManager methods not available
            .cache_hit_ratio = 0.0, // Not available in LoaderStatistics
            .files_watched = 0, // HotReloadManager methods not available
            .directories_watched = 0, // HotReloadManager methods not available
            .reload_events_processed = 0, // HotReloadManager methods not available
        };
    }
};

/// Comprehensive statistics for the asset manager
pub const AssetManagerStatistics = struct {
    // Registry statistics
    total_assets: u32,
    loaded_assets: u32,
    failed_assets: u32,
    loading_assets: u32,

    // Loader statistics
    active_loads: u32,
    completed_loads: u32,
    failed_loads: u32,
    queued_loads: u32,

    // Memory tracking
    memory_used_bytes: u64,
    memory_allocated_bytes: u64,

    // Performance metrics
    average_load_time_ms: f64,
    hot_reload_count: u32,
    cache_hit_ratio: f32,

    // Hot reload statistics
    files_watched: u32,
    directories_watched: u32,
    reload_events_processed: u32,

    pub fn getLoadProgress(self: AssetManagerStatistics) f32 {
        return @as(f32, @floatFromInt(self.loaded_assets)) / @as(f32, @floatFromInt(self.total_assets));
    }

    pub fn getSuccessRate(self: AssetManagerStatistics) f32 {
        const total_processed = self.completed_loads + self.failed_loads;
        if (total_processed == 0) return 1.0;
        return @as(f32, @floatFromInt(self.completed_loads)) / @as(f32, @floatFromInt(total_processed));
    }
};
test "AssetManager basic operations" {
    var manager = try AssetManager.init(std.testing.allocator);
    defer manager.deinit();

    // Register and load a texture
    const texture_id = try manager.loadTexture("missing.png");

    try std.testing.expect(texture_id.isValid());
    try std.testing.expect(manager.isAssetLoaded(texture_id));

    // Test reference counting
    manager.addRef(texture_id);
    manager.addRef(texture_id);

    try std.testing.expect(!manager.removeRef(texture_id));
    try std.testing.expect(manager.removeRef(texture_id));
}

test "AssetManager dependency management" {
    var manager = try AssetManager.init(std.testing.allocator);
    defer manager.deinit();

    // Load assets with dependencies (using actual files)
    const texture_id = try manager.loadTexture("granitesmooth1-albedo.png");
    const mesh_id = try manager.loadMesh("cube.obj");

    // Add dependency (mesh depends on texture)
    try manager.addDependency(mesh_id, texture_id);

    // Check dependencies
    const deps = manager.getDependencies(mesh_id);
    try std.testing.expect(deps != null);
    try std.testing.expectEqual(@as(usize, 1), deps.?.len);
    try std.testing.expectEqual(texture_id, deps.?[0]);
}
test "AssetManager statistics" {
    var manager = try AssetManager.init(std.testing.allocator);
    defer manager.deinit();

    // Load some assets (using actual files)
    _ = try manager.loadTexture("missing.png");
    _ = try manager.loadTexture("granitesmooth1-albedo.png");
    _ = try manager.loadMesh("smooth_vase.obj");

    const stats = manager.getStatistics();
    try std.testing.expectEqual(@as(u32, 3), stats.total_assets);
    try std.testing.expectEqual(@as(u32, 3), stats.loaded_assets);

    // Test asset type query
    const textures = try manager.getAssetsByType(.texture);
    defer std.testing.allocator.free(textures);
    try std.testing.expectEqual(@as(usize, 2), textures.len);
}
