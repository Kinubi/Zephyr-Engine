const std = @import("std");
const asset_types = @import("asset_types.zig");

const AssetId = asset_types.AssetId;
const AssetType = asset_types.AssetType;
const AssetState = asset_types.AssetState;
const AssetMetadata = asset_types.AssetMetadata;
const LoadPriority = asset_types.LoadPriority;
const log = @import("../utils/log.zig").log;

/// Central registry for all assets in the system
/// Manages metadata, dependencies, and reference counting
pub const AssetRegistry = struct {
    // Core storage
    assets: std.AutoHashMap(AssetId, AssetMetadata),
    path_to_id: std.StringHashMap(AssetId),

    // String storage for asset paths (owned by registry)
    path_arena: std.heap.ArenaAllocator,

    // Allocator for registry operations
    allocator: std.mem.Allocator,

    // Thread safety
    mutex: std.Thread.Mutex = .{},

    // Statistics
    total_assets: u32 = 0,
    loaded_assets: u32 = 0,
    failed_assets: u32 = 0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .assets = std.AutoHashMap(AssetId, AssetMetadata).init(allocator),
            .path_to_id = std.StringHashMap(AssetId).init(allocator),
            .path_arena = std.heap.ArenaAllocator.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        // Deinit all asset metadata
        var iterator = self.assets.iterator();
        while (iterator.next()) |entry| {
            entry.value_ptr.deinit();
        }

        self.assets.deinit();
        self.path_to_id.deinit();
        self.path_arena.deinit();
    }

    /// Register a new asset with the given path and type
    /// Returns existing asset ID if path is already registered
    pub fn registerAsset(self: *Self, path: []const u8, asset_type: AssetType) !AssetId {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Check if already registered
        if (self.path_to_id.get(path)) |existing_id| {
            return existing_id;
        }

        // Generate new ID and store path in arena
        const asset_id = AssetId.generate();
        const owned_path = try self.path_arena.allocator().dupe(u8, path);

        // Create metadata
        const metadata = AssetMetadata.init(self.allocator, asset_id, asset_type, owned_path);

        // Store in maps
        try self.assets.put(asset_id, metadata);
        try self.path_to_id.put(owned_path, asset_id);

        self.total_assets += 1;
        return asset_id;
    }

    /// Get asset metadata by ID
    pub fn getAsset(self: *Self, asset_id: AssetId) ?*AssetMetadata {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.assets.getPtr(asset_id);
    }

    /// Get asset metadata by path
    pub fn getAssetByPath(self: *Self, path: []const u8) ?*AssetMetadata {
        if (self.path_to_id.get(path)) |asset_id| {
            return self.getAsset(asset_id);
        }
        return null;
    }

    /// Get asset ID from path
    pub fn getAssetId(self: *Self, path: []const u8) ?AssetId {
        return self.path_to_id.get(path);
    }

    /// Add dependency relationship between assets
    pub fn addDependency(self: *Self, asset_id: AssetId, dependency_id: AssetId) !void {
        var asset = self.getAsset(asset_id) orelse return;
        var dependency = self.getAsset(dependency_id) orelse return;

        try asset.addDependency(dependency_id);
        try dependency.addDependent(asset_id);
    }

    /// Remove dependency relationship between assets
    pub fn removeDependency(self: *Self, asset_id: AssetId, dependency_id: AssetId) void {
        if (self.getAsset(asset_id)) |asset| {
            _ = asset.removeDependency(dependency_id);
        }

        if (self.getAsset(dependency_id)) |dependency| {
            _ = dependency.removeDependent(asset_id);
        }
    }

    /// Increment reference count for an asset
    pub fn incrementRef(self: *Self, asset_id: AssetId) void {
        if (self.getAsset(asset_id)) |asset| {
            asset.incrementRef();
        }
    }

    /// Decrement reference count for an asset
    /// Returns true if the asset can now be unloaded (ref count reached zero)
    pub fn decrementRef(self: *Self, asset_id: AssetId) bool {
        if (self.getAsset(asset_id)) |asset| {
            return asset.decrementRef();
        }
        return false;
    }

    /// Mark an asset as loaded
    pub fn markAsLoaded(self: *Self, asset_id: AssetId, file_size: u64) void {
        if (self.getAsset(asset_id)) |asset| {
            const old_state = asset.state;
            asset.state = .loaded;
            asset.load_time = std.time.milliTimestamp();
            asset.file_size = file_size;

            if (old_state != .loaded) {
                self.loaded_assets += 1;
                if (old_state == .failed and self.failed_assets > 0) {
                    self.failed_assets -= 1;
                }
            }
        }
    }

    /// Mark an asset as failed to load
    pub fn markAsFailed(self: *Self, asset_id: AssetId, error_msg: []const u8) void {
        _ = error_msg; // For now, we don't store error messages
        if (self.getAsset(asset_id)) |asset| {
            const old_state = asset.state;
            asset.state = .failed;

            if (old_state != .failed) {
                self.failed_assets += 1;
                if (old_state == .loaded and self.loaded_assets > 0) {
                    self.loaded_assets -= 1;
                }
            }
        }
    }

    /// Force an asset back to the 'unloaded' state so it can be reloaded.
    /// This adjusts counters if the asset was previously marked as loaded/failed.
    pub fn forceMarkUnloaded(self: *Self, asset_id: AssetId) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.assets.getPtr(asset_id)) |asset| {
            const old_state = asset.state;
            asset.state = .unloaded;

            if (old_state == .loaded and self.loaded_assets > 0) {
                self.loaded_assets -= 1;
            }
            if (old_state == .failed and self.failed_assets > 0) {
                self.failed_assets -= 1;
            }
        }
    }

    /// Mark an asset as currently loading
    pub fn markAsLoading(self: *Self, asset_id: AssetId) void {
        if (self.getAsset(asset_id)) |asset| {
            asset.state = .loading;
        }
    }

    /// Atomically mark an asset as loading if not already loading/loaded
    /// Returns true if successfully marked as loading, false if already in progress
    pub fn markAsLoadingAtomic(self: *Self, asset_id: AssetId) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.assets.get(asset_id)) |asset| {
            // Check if asset is already being processed
            switch (asset.state) {
                .loading, .staged, .loaded => {
                    return false;
                },
                .unloaded, .failed => {
                    // Safe to start loading
                    var mutable_asset = asset;
                    mutable_asset.state = .loading;
                    self.assets.put(asset_id, mutable_asset) catch return false;
                    return true;
                },
            }
        }

        return false;
    }

    /// Mark an asset as staged (loaded from disk but not yet processed)
    pub fn markAsStaged(self: *Self, asset_id: AssetId, file_size: u64) void {
        if (self.getAsset(asset_id)) |asset| {
            asset.state = .staged;
            asset.file_size = file_size;
        }
    }

    /// Get all assets of a specific type
    pub fn getAssetsByType(self: *Self, asset_type: AssetType, allocator: std.mem.Allocator) ![]AssetId {
        var result = std.ArrayList(AssetId){};

        var iterator = self.assets.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.asset_type == asset_type) {
                try result.append(allocator, entry.key_ptr.*);
            }
        }

        return result.toOwnedSlice(allocator);
    }

    /// Get all assets that can be unloaded (ref count is zero)
    pub fn getUnloadableAssets(self: *Self, allocator: std.mem.Allocator) ![]AssetId {
        var result = std.ArrayList(AssetId){};

        var iterator = self.assets.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.canUnload()) {
                try result.append(allocator, entry.key_ptr.*);
            }
        }

        return result.toOwnedSlice(allocator);
    }

    /// Get dependency chain for an asset (all assets it depends on, recursively)
    pub fn getDependencyChain(self: *Self, asset_id: AssetId, allocator: std.mem.Allocator) ![]AssetId {
        var visited = std.AutoHashMap(AssetId, void).init(allocator);
        defer visited.deinit();

        var result = std.ArrayList(AssetId){};
        try self.collectDependencies(asset_id, &visited, &result, allocator);

        return result.toOwnedSlice(allocator);
    }

    /// Recursively collect all dependencies for an asset
    fn collectDependencies(self: *Self, asset_id: AssetId, visited: *std.AutoHashMap(AssetId, void), result: *std.ArrayList(AssetId), allocator: std.mem.Allocator) !void {
        // Avoid cycles
        if (visited.contains(asset_id)) return;
        try visited.put(asset_id, {});

        if (self.getAsset(asset_id)) |asset| {
            for (asset.dependencies.items) |dep_id| {
                try result.append(allocator, dep_id);
                try self.collectDependencies(dep_id, visited, result, allocator);
            }
        }
    }

    /// Get statistics about the asset registry
    pub fn getStatistics(self: *Self) AssetStatistics {
        // Prevent integer underflow by ensuring loading_assets is never negative
        const completed_assets = self.loaded_assets + self.failed_assets;
        const loading_assets = if (completed_assets > self.total_assets) 0 else self.total_assets - completed_assets;

        return AssetStatistics{
            .total_assets = self.total_assets,
            .loaded_assets = self.loaded_assets,
            .failed_assets = self.failed_assets,
            .loading_assets = loading_assets,
        };
    }
};

/// Statistics about the asset registry state
pub const AssetStatistics = struct {
    total_assets: u32,
    loaded_assets: u32,
    failed_assets: u32,
    loading_assets: u32,

    pub fn getLoadProgress(self: AssetStatistics) f32 {
        if (self.total_assets == 0) return 1.0;
        return @as(f32, @floatFromInt(self.loaded_assets)) / @as(f32, @floatFromInt(self.total_assets));
    }
};

// Tests
test "AssetRegistry basic operations" {
    var registry = AssetRegistry.init(std.testing.allocator);
    defer registry.deinit();

    // Register assets
    const texture_id = try registry.registerAsset("textures/test.png", .texture);
    const mesh_id = try registry.registerAsset("models/test.obj", .mesh);

    try std.testing.expect(texture_id.isValid());
    try std.testing.expect(mesh_id.isValid());
    try std.testing.expect(texture_id != mesh_id);

    // Test retrieval
    const texture_meta = registry.getAsset(texture_id);
    try std.testing.expect(texture_meta != null);
    try std.testing.expectEqualStrings("textures/test.png", texture_meta.?.path);
    try std.testing.expectEqual(AssetType.texture, texture_meta.?.asset_type);

    // Test path lookup
    const lookup_id = registry.getAssetId("textures/test.png");
    try std.testing.expect(lookup_id != null);
    try std.testing.expectEqual(texture_id, lookup_id.?);
}

test "AssetRegistry dependency management" {
    var registry = AssetRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const material_id = try registry.registerAsset("materials/test.mat", .material);
    const texture_id = try registry.registerAsset("textures/test.png", .texture);

    // Add dependency
    try registry.addDependency(material_id, texture_id);

    const material = registry.getAsset(material_id).?;
    const texture = registry.getAsset(texture_id).?;

    try std.testing.expectEqual(@as(usize, 1), material.dependencies.items.len);
    try std.testing.expectEqual(texture_id, material.dependencies.items[0]);

    try std.testing.expectEqual(@as(usize, 1), texture.dependents.items.len);
    try std.testing.expectEqual(material_id, texture.dependents.items[0]);

    // Test dependency chain
    const deps = try registry.getDependencyChain(material_id, std.testing.allocator);
    defer std.testing.allocator.free(deps);

    try std.testing.expectEqual(@as(usize, 1), deps.len);
    try std.testing.expectEqual(texture_id, deps[0]);
}

test "AssetRegistry reference counting" {
    var registry = AssetRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const asset_id = try registry.registerAsset("test.png", .texture);

    registry.incrementRef(asset_id);
    registry.incrementRef(asset_id);

    const asset = registry.getAsset(asset_id).?;
    try std.testing.expectEqual(@as(u32, 2), asset.reference_count);
    try std.testing.expect(!asset.canUnload());

    try std.testing.expect(!registry.decrementRef(asset_id));
    try std.testing.expect(registry.decrementRef(asset_id));
    try std.testing.expect(asset.canUnload());
}
