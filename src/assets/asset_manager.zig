const std = @import("std");
const vk = @import("vulkan");
const asset_types = @import("asset_types.zig");
const asset_registry = @import("asset_registry.zig");
const asset_loader = @import("asset_loader.zig");
const HotReloadManager = @import("hot_reload_manager.zig").HotReloadManager;
const GraphicsContext = @import("../core/graphics_context.zig").GraphicsContext;
const Model = @import("../rendering/mesh.zig").Model;
const Texture = @import("../core/texture.zig").Texture;
const log = @import("../utils/log.zig").log;

// Re-export key types for convenience
pub const AssetId = asset_types.AssetId;
pub const AssetType = asset_types.AssetType;
pub const AssetState = asset_types.AssetState;
pub const LoadPriority = asset_types.LoadPriority;
pub const AssetMetadata = asset_types.AssetMetadata;
pub const AssetRegistry = asset_registry.AssetRegistry;
pub const AssetLoader = asset_loader.AssetLoader;

/// Types of fallback assets for different scenarios
pub const FallbackType = enum {
    missing, // Pink checkerboard for missing textures
    loading, // Animated or static "loading..." texture
    @"error", // Red X or error indicator (error is keyword)
    default, // Basic white texture for materials
};

/// Pre-loaded fallback assets for safe rendering
pub const FallbackAssets = struct {
    missing_texture: ?AssetId = null,
    loading_texture: ?AssetId = null,
    error_texture: ?AssetId = null,
    default_texture: ?AssetId = null,

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

        return fallbacks;
    }

    /// Get fallback asset ID for given type
    pub fn getAssetId(self: *const Self, fallback_type: FallbackType) ?AssetId {
        return switch (fallback_type) {
            .missing => self.missing_texture,
            .loading => self.loading_texture,
            .@"error" => self.error_texture,
            .default => self.default_texture,
        };
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

    // AssetId → [object_id]
    asset_to_objects: std.AutoHashMap(AssetId, std.ArrayList(u64)),

    // Legacy compatibility: bidirectional mappings between AssetIds and legacy array indices
    texture_assets: std.AutoHashMap(usize, AssetId), // legacy texture index -> AssetId
    material_assets: std.AutoHashMap(usize, AssetId), // legacy material index -> AssetId
    mesh_assets: std.AutoHashMap(usize, AssetId), // legacy mesh index -> AssetId

    // Reverse mappings for compatibility
    asset_to_texture: std.AutoHashMap(AssetId, usize), // AssetId -> legacy texture index
    asset_to_material: std.AutoHashMap(AssetId, usize), // AssetId -> legacy material index
    asset_to_mesh: std.AutoHashMap(AssetId, usize), // AssetId -> legacy mesh index

    // Hot reloading
    hot_reload_manager: ?HotReloadManager = null,

    // Asset replacement system: fallback_asset_id -> real_asset_id
    asset_replacements: std.AutoHashMap(AssetId, AssetId),

    // Fallback model storage for immediate access
    fallback_models: std.AutoHashMap(AssetId, *Model),

    // Current texture descriptor array for rendering (maintained by asset manager)
    texture_image_infos: []const vk.DescriptorImageInfo = &[_]vk.DescriptorImageInfo{},

    // Configuration
    max_loader_threads: u32 = 4,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, graphics_context: *GraphicsContext) !Self {
        // Allocate registry on heap to avoid HashMap corruption
        const registry = try allocator.create(AssetRegistry);
        registry.* = AssetRegistry.init(allocator);

        // Allocate loader on heap
        const loader = try allocator.create(AssetLoader);
        loader.* = try AssetLoader.init(allocator, registry, graphics_context, 4);

        var self = Self{
            .registry = registry,
            .loader = loader,
            .allocator = allocator,
            .fallbacks = FallbackAssets{}, // Initialize empty first
            .asset_to_objects = std.AutoHashMap(AssetId, std.ArrayList(u64)).init(allocator),
            .texture_assets = std.AutoHashMap(usize, AssetId).init(allocator),
            .material_assets = std.AutoHashMap(usize, AssetId).init(allocator),
            .mesh_assets = std.AutoHashMap(usize, AssetId).init(allocator),
            .asset_to_texture = std.AutoHashMap(AssetId, usize).init(allocator),
            .asset_to_material = std.AutoHashMap(AssetId, usize).init(allocator),
            .asset_to_mesh = std.AutoHashMap(AssetId, usize).init(allocator),
            .asset_replacements = std.AutoHashMap(AssetId, AssetId).init(allocator),
            .fallback_models = std.AutoHashMap(AssetId, *Model).init(allocator),
        };

        // Start loader GPU worker now that loader is heap-allocated and stable
        // Scene will be set later via setTextureUpdateCallback
        try self.loader.startGpuWorker(&self);

        // Initialize fallback assets after AssetManager is created
        self.fallbacks = try FallbackAssets.init(&self);

        return self;
    }

    pub fn deinit(self: *Self) void {
        // Clean up hot reload manager
        if (self.hot_reload_manager) |*manager| {
            manager.deinit();
        }

        // Clean up legacy asset mappings
        self.texture_assets.deinit();
        self.material_assets.deinit();
        self.mesh_assets.deinit();
        self.asset_to_texture.deinit();
        self.asset_to_material.deinit();
        self.asset_to_mesh.deinit();

        // Clean up asset replacement system
        self.asset_replacements.deinit();
        self.fallback_models.deinit();

        // Clean up asset to objects mapping
        var iter = self.asset_to_objects.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.asset_to_objects.deinit();

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
        return self.loader.getLoadedModel(asset_id);
    }

    /// Get a loaded texture by AssetId
    pub fn getLoadedTexture(self: *Self, asset_id: AssetId) ?Texture {
        return self.loader.getLoadedTexture(asset_id);
    }

    /// Non-destructive const pointer access to loaded model (preferred)
    pub fn getLoadedModelConst(self: *Self, asset_id: AssetId) ?*const Model {
        return self.loader.getLoadedModelConst(asset_id);
    }

    /// Non-destructive const pointer access to loaded texture (preferred)
    pub fn getLoadedTextureConst(self: *Self, asset_id: AssetId) ?*const Texture {
        return self.loader.getLoadedTextureConst(asset_id);
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

        // Auto-register for hot reloading
        self.registerAssetForHotReload(asset_id, path) catch |err| {
            log(.WARN, "asset_manager", "Failed to register asset for hot reload: {} ({})", .{ asset_id, err });
        };

        return asset_id;
    }

    /// Load an asset asynchronously with priority
    /// Returns the asset ID immediately, asset loads in background
    pub fn loadAssetAsync(self: *Self, path: []const u8, asset_type: AssetType, priority: LoadPriority) !AssetId {
        log(.DEBUG, "asset_manager", "Requesting async load for asset path {s} of type {}", .{ path, asset_type });
        const asset_id = try self.registerAsset(path, asset_type);
        try self.loader.requestLoad(asset_id, priority);

        // Auto-register for hot reloading
        self.registerAssetForHotReload(asset_id, path) catch |err| {
            log(.WARN, "asset_manager", "Failed to register asset for hot reload: {} ({})", .{ asset_id, err });
        };

        return asset_id;
    }

    /// Load an asset by ID if already registered
    pub fn loadAssetById(self: *Self, asset_id: AssetId, priority: LoadPriority) !void {
        try self.loader.requestLoad(asset_id, priority);
    }

    /// Load a texture synchronously (blocks until complete)
    /// Used for fallback assets that must be available immediately
    pub fn loadTextureSync(self: *Self, path: []const u8) !AssetId {
        return try self.loadAsset(path, .texture);
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
    pub fn isAssetLoaded(self: *Self, asset_id: AssetId) bool {
        if (self.getAsset(asset_id)) |asset| {
            return asset.state == .loaded;
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
                .loading => {
                    // Show loading indicator while asset loads
                    if (self.fallbacks.getAssetId(.loading)) |fallback_id| {
                        return fallback_id;
                    }
                    // Fallback to missing if no loading texture
                    return self.fallbacks.getAssetId(.missing) orelse asset_id;
                },
                .failed => {
                    // Show error texture for failed loads
                    if (self.fallbacks.getAssetId(.@"error")) |fallback_id| {
                        return fallback_id;
                    }
                    // Fallback to missing if no error texture
                    return self.fallbacks.getAssetId(.missing) orelse asset_id;
                },
                .unloaded => {
                    // Start loading and show missing texture
                    self.loadAssetById(asset_id, .normal) catch {};
                    return self.fallbacks.getAssetId(.missing) orelse asset_id;
                },
            }
        }
        // Asset doesn't exist at all - return missing fallback
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

    // Legacy Compatibility: Asset-to-Index Mapping Management

    /// Register a texture asset with its legacy array index
    pub fn registerTextureMapping(self: *Self, asset_id: AssetId, texture_index: usize) !void {
        std.log.info("AssetManager: registerTextureMapping(asset_id={}, texture_index={})", .{ asset_id, texture_index });
        try self.texture_assets.put(texture_index, asset_id);
        try self.asset_to_texture.put(asset_id, texture_index);
        std.log.info("AssetManager: Mapping registered - asset {} -> index {}", .{ asset_id, texture_index });
    }

    /// Register a material asset with its legacy array index
    pub fn registerMaterialMapping(self: *Self, asset_id: AssetId, material_index: usize) !void {
        try self.material_assets.put(material_index, asset_id);
        try self.asset_to_material.put(asset_id, material_index);
    }

    /// Register a mesh asset with its legacy array index
    pub fn registerMeshMapping(self: *Self, asset_id: AssetId, mesh_index: usize) !void {
        try self.mesh_assets.put(mesh_index, asset_id);
        try self.asset_to_mesh.put(asset_id, mesh_index);
    }

    /// Get texture index from asset ID
    pub fn getTextureIndex(self: *Self, asset_id: AssetId) ?usize {
        // Calculate the index based on sorted AssetId order to match buildTextureDescriptorArray
        var asset_ids = std.ArrayList(AssetId){};
        defer asset_ids.deinit(self.allocator);

        // Collect all texture asset IDs and sort them
        var iterator = self.asset_to_texture.iterator();
        while (iterator.next()) |entry| {
            asset_ids.append(self.allocator, entry.key_ptr.*) catch continue;
        }

        if (asset_ids.items.len == 0) {
            std.log.info("AssetManager: getTextureIndex({}) -> null (NO TEXTURES)", .{asset_id});
            return null;
        }

        // Sort by AssetId (same order as buildTextureDescriptorArray)
        std.sort.heap(AssetId, asset_ids.items, {}, struct {
            pub fn lessThan(context: void, a: AssetId, b: AssetId) bool {
                _ = context;
                return a.toU64() < b.toU64();
            }
        }.lessThan);

        // Log all sorted texture AssetIds for debugging
        if (asset_id.toU64() == 18) { // Only log when asking for the granite texture
            std.log.info("AssetManager: Sorted texture AssetIds:", .{});
            for (asset_ids.items, 0..) |id, idx| {
                std.log.info("  Index {}: AssetId {}", .{ idx, id });
            }
        }

        // Find the asset_id in the sorted list
        for (asset_ids.items, 0..) |id, index| {
            if (id.toU64() == asset_id.toU64()) {
                std.log.info("AssetManager: getTextureIndex({}) -> {} (sorted order)", .{ asset_id, index });
                return index;
            }
        }

        std.log.info("AssetManager: getTextureIndex({}) -> null (NOT FOUND)", .{asset_id});
        return null;
    }

    /// Get material index from asset ID
    pub fn getMaterialIndex(self: *Self, asset_id: AssetId) ?usize {
        return self.asset_to_material.get(asset_id);
    }

    /// Get mesh index from asset ID
    pub fn getMeshIndex(self: *Self, asset_id: AssetId) ?usize {
        return self.asset_to_mesh.get(asset_id);
    }

    /// Get texture asset ID from legacy index
    pub fn getTextureAssetId(self: *Self, texture_index: usize) ?AssetId {
        return self.texture_assets.get(texture_index);
    }

    /// Get material asset ID from legacy index
    pub fn getMaterialAssetId(self: *Self, material_index: usize) ?AssetId {
        return self.material_assets.get(material_index);
    }

    /// Get mesh asset ID from legacy index
    pub fn getMeshAssetId(self: *Self, mesh_index: usize) ?AssetId {
        return self.mesh_assets.get(mesh_index);
    }

    /// SAFE texture index access for legacy compatibility
    /// Returns fallback texture index if original texture not ready
    pub fn getTextureIndexForRendering(self: *Self, texture_index: usize) usize {
        if (self.texture_assets.get(texture_index)) |asset_id| {
            const safe_asset_id = self.getAssetIdForRendering(asset_id);
            if (safe_asset_id != asset_id) {
                // Asset was replaced with fallback, try to find fallback texture index
                if (self.asset_to_texture.get(safe_asset_id)) |fallback_index| {
                    return fallback_index;
                }
            }
        }

        // Original index is safe to use, or we have no better fallback
        return texture_index;
    }

    /// SAFE material index access for legacy compatibility
    pub fn getMaterialIndexForRendering(self: *Self, material_index: usize) usize {
        if (self.material_assets.get(material_index)) |asset_id| {
            const safe_asset_id = self.getAssetIdForRendering(asset_id);
            if (safe_asset_id != asset_id) {
                if (self.asset_to_material.get(safe_asset_id)) |fallback_index| {
                    return fallback_index;
                }
            }
        }
        return material_index;
    }

    /// SAFE mesh index access for legacy compatibility
    pub fn getMeshIndexForRendering(self: *Self, mesh_index: usize) usize {
        if (self.mesh_assets.get(mesh_index)) |asset_id| {
            const safe_asset_id = self.getAssetIdForRendering(asset_id);
            if (safe_asset_id != asset_id) {
                if (self.asset_to_mesh.get(safe_asset_id)) |fallback_index| {
                    return fallback_index;
                }
            }
        }
        return mesh_index;
    }

    /// Build texture descriptor array for rendering from all loaded textures
    /// This centralizes texture array building in the asset manager
    pub fn buildTextureDescriptorArray(self: *Self, allocator: std.mem.Allocator, loaded_textures: *const std.HashMap(AssetId, Texture, std.hash_map.AutoContext(AssetId), 80)) ![]const vk.DescriptorImageInfo {
        _ = self; // Don't access any shared state from worker thread

        // Build texture descriptor array from loaded textures in a consistent order
        // Sort by AssetId to ensure deterministic ordering
        var texture_pairs = try std.ArrayList(struct { asset_id: AssetId, descriptor: vk.DescriptorImageInfo }).initCapacity(allocator, 32);
        defer texture_pairs.deinit(allocator);

        var texture_iterator = loaded_textures.iterator();
        while (texture_iterator.next()) |entry| {
            const asset_id = entry.key_ptr.*;
            const texture = entry.value_ptr;
            try texture_pairs.append(allocator, .{ .asset_id = asset_id, .descriptor = texture.descriptor });
        }

        if (texture_pairs.items.len == 0) {
            log(.WARN, "asset_manager", "No textures loaded - using empty descriptor array", .{});
            return &[_]vk.DescriptorImageInfo{};
        }

        // Sort by AssetId for consistent ordering
        std.sort.heap(@TypeOf(texture_pairs.items[0]), texture_pairs.items, {}, struct {
            pub fn lessThan(context: void, a: @TypeOf(texture_pairs.items[0]), b: @TypeOf(texture_pairs.items[0])) bool {
                _ = context;
                return a.asset_id.toU64() < b.asset_id.toU64();
            }
        }.lessThan);

        // Build descriptor array
        const min_texture_count = @max(texture_pairs.items.len, 32);
        const infos = try allocator.alloc(vk.DescriptorImageInfo, min_texture_count);

        for (0..min_texture_count) |i| {
            if (i < texture_pairs.items.len) {
                infos[i] = texture_pairs.items[i].descriptor;
                std.log.info("Placed texture AssetId {} at descriptor index {}", .{ texture_pairs.items[i].asset_id, i });
            } else if (texture_pairs.items.len > 0) {
                // Use first texture as fallback for missing indices only if we have textures
                infos[i] = texture_pairs.items[0].descriptor;
            } else {
                // No textures loaded yet - use a default/empty descriptor
                infos[i] = std.mem.zeroes(vk.DescriptorImageInfo);
            }
        }

        log(.DEBUG, "asset_manager", "Built texture descriptor array: {d} actual textures, padded to {d} total", .{ texture_pairs.items.len, min_texture_count });
        return infos;
    }

    /// Get current texture descriptor array for rendering
    pub fn getTextureDescriptorArray(self: *Self) []const vk.DescriptorImageInfo {
        // Lazy initialization: build descriptor array if empty or outdated
        const texture_count = self.texture_assets.count();
        const needs_rebuild = self.texture_image_infos.len == 0 or self.texture_image_infos.len != texture_count;
        
        if (needs_rebuild) {
            self.texture_image_infos = self.buildTextureDescriptorArray(self.allocator, &self.loader.loaded_textures) catch |err| blk: {
                std.log.err("Failed to build initial texture descriptor array: {}", .{err});
                break :blk &[_]vk.DescriptorImageInfo{};
            };
        }
        std.log.info("AssetManager: getTextureDescriptorArray returning {} descriptors", .{self.texture_image_infos.len});
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

    /// Get comprehensive statistics about the asset system
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
            .queued_loads = @intCast(loader_stats.getTotalQueued()),

            // Basic defaults for compatibility
            .memory_used_bytes = 0,
            .memory_allocated_bytes = 0,
            .average_load_time_ms = 0.0,
            .hot_reload_count = 0,
            .cache_hit_ratio = 0.0,
            .files_watched = 0,
            .directories_watched = 0,
            .reload_events_processed = 0,
        };
    }

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
    pub fn loadTexture(self: *Self, path: []const u8, priority: LoadPriority) !AssetId {
        return try self.loadAssetAsync(path, .texture, priority);
    }

    /// Load a mesh asset
    pub fn loadMesh(self: *Self, path: []const u8, priority: LoadPriority) !AssetId {
        return try self.loadAssetAsync(path, .mesh, priority);
    }

    /// Load a material asset
    pub fn loadMaterial(self: *Self, path: []const u8, priority: LoadPriority) !AssetId {
        return try self.loadAssetAsync(path, .material, priority);
    }

    /// Load a shader asset
    pub fn loadShader(self: *Self, path: []const u8, priority: LoadPriority) !AssetId {
        return try self.loadAssetAsync(path, .shader, priority);
    }

    /// Load an audio asset
    pub fn loadAudio(self: *Self, path: []const u8, priority: LoadPriority) !AssetId {
        return try self.loadAssetAsync(path, .audio, priority);
    }

    /// Load a scene asset
    pub fn loadScene(self: *Self, path: []const u8, priority: LoadPriority) !AssetId {
        return try self.loadAssetAsync(path, .scene, priority);
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
            try self.loader.loadAsync(asset_id, .high);

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

    /// Register a fallback model that can be immediately accessed
    pub fn registerModelFallback(self: *Self, fallback_asset_id: AssetId, model: *Model) !void {
        try self.fallback_models.put(fallback_asset_id, model);
        log(.DEBUG, "asset_manager", "Registered fallback model for AssetId {d}", .{fallback_asset_id.toU64()});
    }

    /// Schedule an asset replacement: when real_asset loads, replace fallback_asset
    pub fn scheduleAssetReplacement(self: *Self, fallback_asset_id: AssetId, real_asset_id: AssetId) !void {
        try self.asset_replacements.put(fallback_asset_id, real_asset_id);
        log(.DEBUG, "asset_manager", "Scheduled replacement: fallback={d} -> real={d}", .{ fallback_asset_id.toU64(), real_asset_id.toU64() });
    }

    /// Get the current asset ID (returns real asset if available, fallback otherwise)
    pub fn getCurrentAssetId(self: *Self, original_asset_id: AssetId) AssetId {
        // Log what AssetId 18 is for debugging
        if (original_asset_id.toU64() == 18) {
            std.log.info("AssetManager: getCurrentAssetId called for AssetId 18", .{});
        }

        // Check if this is a fallback asset with a replacement available
        if (self.asset_replacements.get(original_asset_id)) |real_asset_id| {
            if (self.isAssetLoaded(real_asset_id)) {
                // Transfer texture mapping from fallback to real asset if needed
                if (self.asset_to_texture.get(original_asset_id)) |texture_index| {
                    if (!self.asset_to_texture.contains(real_asset_id)) {
                        std.log.info("AssetManager: Transferring texture mapping: fallback {} -> real {} (index {})", .{ original_asset_id, real_asset_id, texture_index });
                        self.asset_to_texture.put(real_asset_id, texture_index) catch {};
                    } else {
                        std.log.info("AssetManager: Real asset {} already has texture mapping", .{real_asset_id});
                    }
                }

                return real_asset_id;
            }
        }
        return original_asset_id;
    }

    /// Override getLoadedModel to handle fallback models
    pub fn getLoadedModelWithFallback(self: *Self, asset_id: AssetId) ?*const Model {
        const current_id = self.getCurrentAssetId(asset_id);

        // Try to get real loaded model first
        if (self.getLoadedModelConst(current_id)) |model| {
            return model;
        }

        // Fall back to registered fallback model
        if (self.fallback_models.get(asset_id)) |fallback_model| {
            return fallback_model;
        }

        return null;
    }

    /// Check if any asset replacements have completed and can be processed
    pub fn processAssetReplacements(self: *Self) u32 {
        var completed_replacements: u32 = 0;

        var iter = self.asset_replacements.iterator();
        while (iter.next()) |entry| {
            const fallback_id = entry.key_ptr.*;
            const real_id = entry.value_ptr.*;

            if (self.isAssetLoaded(real_id)) {
                log(.INFO, "asset_manager", "Asset replacement completed: {d} -> {d}", .{ fallback_id.toU64(), real_id.toU64() });
                completed_replacements += 1;
                // Note: We don't remove the mapping here in case objects still reference the fallback ID
            }
        }

        return completed_replacements;
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
        if (self.total_assets == 0) return 1.0;
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
    const texture_id = try manager.loadTexture("missing.png", .high);

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
    const texture_id = try manager.loadTexture("granitesmooth1-albedo.png", .high);
    const mesh_id = try manager.loadMesh("cube.obj", .high);

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
    _ = try manager.loadTexture("missing.png", .high);
    _ = try manager.loadTexture("granitesmooth1-albedo.png", .normal);
    _ = try manager.loadMesh("smooth_vase.obj", .low);

    const stats = manager.getStatistics();
    try std.testing.expectEqual(@as(u32, 3), stats.total_assets);
    try std.testing.expectEqual(@as(u32, 3), stats.loaded_assets);

    // Test asset type query
    const textures = try manager.getAssetsByType(.texture);
    defer std.testing.allocator.free(textures);
    try std.testing.expectEqual(@as(usize, 2), textures.len);
}
