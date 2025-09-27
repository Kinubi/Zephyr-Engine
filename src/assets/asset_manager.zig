const std = @import("std");
const asset_types = @import("asset_types.zig");
const asset_registry = @import("asset_registry.zig");
const asset_loader = @import("asset_loader.zig");

// Re-export key types for convenience
pub const AssetId = asset_types.AssetId;
pub const AssetType = asset_types.AssetType;
pub const AssetState = asset_types.AssetState;
pub const LoadPriority = asset_types.LoadPriority;
pub const AssetMetadata = asset_types.AssetMetadata;
pub const AssetRegistry = asset_registry.AssetRegistry;
pub const AssetLoader = asset_loader.AssetLoader;

/// Central Asset Manager that coordinates all asset operations
/// This is the main interface for the game engine to interact with assets
pub const AssetManager = struct {
    // Core components (using pointers to avoid HashMap moves)
    registry: *AssetRegistry,
    loader: *AssetLoader,
    allocator: std.mem.Allocator,

    // Configuration
    max_loader_threads: u32 = 4,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        // Allocate registry on heap to avoid HashMap corruption
        const registry = try allocator.create(AssetRegistry);
        registry.* = AssetRegistry.init(allocator);

        // Allocate loader on heap
        const loader = try allocator.create(AssetLoader);
        loader.* = try AssetLoader.init(allocator, registry, 4);

        return Self{
            .registry = registry,
            .loader = loader,
            .allocator = allocator,
        };
    }
    pub fn deinit(self: *Self) void {
        self.loader.deinit();
        self.registry.deinit();

        // Free heap allocations
        self.allocator.destroy(self.loader);
        self.allocator.destroy(self.registry);
    }

    // Asset Registration

    /// Register a new asset at the given path
    /// Returns the asset ID for future reference
    pub fn registerAsset(self: *Self, path: []const u8, asset_type: AssetType) !AssetId {
        return try self.registry.registerAsset(path, asset_type);
    }

    /// Register multiple assets from a directory (mock implementation)
    pub fn registerAssetsFromDirectory(self: *Self, directory: []const u8, recursive: bool) ![]AssetId {
        _ = self;
        _ = directory;
        _ = recursive;
        // TODO: Implement directory scanning
        return &[_]AssetId{};
    }

    // Asset Loading

    /// Load an asset synchronously (blocks until complete)
    /// Returns the asset ID if successful
    pub fn loadAsset(self: *Self, path: []const u8, asset_type: AssetType) !AssetId {
        const asset_id = try self.registerAsset(path, asset_type);
        try self.loader.loadSync(asset_id);
        return asset_id;
    }

    /// Load an asset asynchronously with priority
    /// Returns the asset ID immediately, asset loads in background
    pub fn loadAssetAsync(self: *Self, path: []const u8, asset_type: AssetType, priority: LoadPriority) !AssetId {
        const asset_id = try self.registerAsset(path, asset_type);
        try self.loader.requestLoad(asset_id, priority);
        return asset_id;
    }

    /// Load an asset by ID if already registered
    pub fn loadAssetById(self: *Self, asset_id: AssetId, priority: LoadPriority) !void {
        try self.loader.requestLoad(asset_id, priority);
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

    // Memory Management

    /// Unload assets that have zero reference count
    pub fn unloadUnusedAssets(self: *Self) !u32 {
        const unloadable = try self.registry.getUnloadableAssets(self.allocator);
        defer self.allocator.free(unloadable);

        var unloaded_count: u32 = 0;
        for (unloadable) |asset_id| {
            if (self.getAsset(asset_id)) |asset| {
                // TODO: Actually free the asset data
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
            .queued_loads = loader_stats.getTotalQueued(),
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
    queued_loads: usize,

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

// Tests
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
