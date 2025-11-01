const std = @import("std");

/// Unique identifier for assets in the system
/// Uses 64-bit value with generation counter to detect stale references
pub const AssetId = enum(u64) {
    invalid = 0,
    _,

    /// Generate a new unique asset ID
    pub fn generate() AssetId {
        const static = struct {
            var next_id = std.atomic.Value(u64).init(1);
        };
        return @enumFromInt(static.next_id.fetchAdd(1, .monotonic));
    }

    /// Check if this asset ID is valid (not the invalid sentinel)
    pub fn isValid(self: AssetId) bool {
        return self != .invalid;
    }

    /// Get the raw ID value for serialization/debugging
    pub fn toU64(self: AssetId) u64 {
        return @intFromEnum(self);
    }

    /// Create asset ID from raw value (for deserialization)
    pub fn fromU64(value: u64) AssetId {
        return @enumFromInt(value);
    }
};

/// Types of assets supported by the asset manager
pub const AssetType = enum(u8) {
    texture,
    mesh,
    material,
    shader,
    script,
    audio,
    scene,
    animation,

    /// Get string representation for debugging/logging
    pub fn toString(self: AssetType) []const u8 {
        return switch (self) {
            .texture => "texture",
            .mesh => "mesh",
            .material => "material",
            .shader => "shader",
            .script => "script",
            .audio => "audio",
            .scene => "scene",
            .animation => "animation",
        };
    }
};

/// Current loading state of an asset
pub const AssetState = enum(u8) {
    unloaded,
    loading,
    staged, // Loaded from disk but not yet processed for GPU/final form
    loaded,
    failed,

    pub fn toString(self: AssetState) []const u8 {
        return switch (self) {
            .unloaded => "unloaded",
            .loading => "loading",
            .staged => "staged",
            .loaded => "loaded",
            .failed => "failed",
        };
    }
};

/// Priority for asset loading operations
pub const LoadPriority = enum(u8) {
    low = 0,
    normal = 1,
    high = 2,
    critical = 3,

    pub fn toInt(self: LoadPriority) u8 {
        return @intFromEnum(self);
    }
};

/// Metadata about an asset in the system
pub const AssetMetadata = struct {
    id: AssetId,
    asset_type: AssetType,
    path: []const u8,
    state: AssetState,
    reference_count: u32,
    dependencies: std.ArrayList(AssetId),
    dependents: std.ArrayList(AssetId),
    load_time: i64, // timestamp when loaded
    file_size: u64,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, id: AssetId, asset_type: AssetType, path: []const u8) AssetMetadata {
        return AssetMetadata{
            .id = id,
            .asset_type = asset_type,
            .path = path,
            .state = .unloaded,
            .reference_count = 0,
            .load_time = 0,
            .file_size = 0,
            .dependencies = std.ArrayList(AssetId){},
            .dependents = std.ArrayList(AssetId){},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *AssetMetadata) void {
        self.dependencies.deinit(self.allocator);
        self.dependents.deinit(self.allocator);
    }

    /// Add a dependency relationship (this asset depends on another)
    pub fn addDependency(self: *AssetMetadata, dependency_id: AssetId) !void {
        // Avoid duplicate dependencies
        for (self.dependencies.items) |existing_id| {
            if (existing_id == dependency_id) return;
        }
        try self.dependencies.append(self.allocator, dependency_id);
    }

    /// Remove a dependency relationship
    pub fn removeDependency(self: *AssetMetadata, dependency_id: AssetId) bool {
        for (self.dependencies.items, 0..) |dep, i| {
            if (dep == dependency_id) {
                _ = self.dependencies.swapRemove(i);
                return true;
            }
        }
        return false;
    }

    /// Add a dependent relationship (another asset depends on this one)
    pub fn addDependent(self: *AssetMetadata, dependent_id: AssetId) !void {
        // Avoid duplicate dependents
        for (self.dependents.items) |existing_id| {
            if (existing_id == dependent_id) return;
        }
        try self.dependents.append(self.allocator, dependent_id);
    }

    /// Remove a dependent relationship
    pub fn removeDependent(self: *AssetMetadata, dependent_id: AssetId) bool {
        for (self.dependents.items, 0..) |dep, i| {
            if (dep == dependent_id) {
                _ = self.dependents.swapRemove(i);
                return true;
            }
        }
        return false;
    }

    /// Increment reference count
    pub fn incrementRef(self: *AssetMetadata) void {
        self.reference_count += 1;
    }

    /// Decrement reference count, returns true if it reaches zero
    pub fn decrementRef(self: *AssetMetadata) bool {
        if (self.reference_count > 0) {
            self.reference_count -= 1;
        }
        return self.reference_count == 0;
    }

    /// Check if this asset can be unloaded (ref count is zero and not loading)
    pub fn canUnload(self: AssetMetadata) bool {
        return self.reference_count == 0 and self.state != .loading;
    }
};

/// Asset loading request for the async loading system
pub const LoadRequest = struct {
    asset_id: AssetId,
    asset_type: AssetType,
    path: []const u8,
    priority: LoadPriority,
    requester: ?[]const u8 = null, // for debugging
    callback: ?LoadCallback = null,

    const LoadCallback = struct {
        context: *anyopaque,
        onComplete: *const fn (context: *anyopaque, asset_id: AssetId, success: bool) void,
    };
};

/// Result of an asset loading operation
pub const LoadResult = struct {
    asset_id: AssetId,
    success: bool,
    error_message: ?[]const u8 = null,
    load_time_ms: f32,
};

/// Placeholder asset types - will be properly defined later
pub const TextureAsset = struct {
    // Placeholder for texture data
    data: []const u8,
};

pub const MeshAsset = struct {
    // Placeholder for mesh data
    data: []const u8,
};

pub const MaterialAsset = struct {
    // Placeholder for material data
    data: []const u8,
};

pub const ShaderAsset = struct {
    // Placeholder for shader data
    data: []const u8,
};

pub const ScriptAsset = struct {
    // Script source text
    source: []const u8,
};

pub const AudioAsset = struct {
    // Placeholder for audio data
    data: []const u8,
};

pub const SceneAsset = struct {
    // Placeholder for scene data
    data: []const u8,
};

pub const AnimationAsset = struct {
    // Placeholder for animation data
    data: []const u8,
};

/// Union of all possible asset data types
pub const AssetData = union(AssetType) {
    texture: TextureAsset,
    mesh: MeshAsset,
    material: MaterialAsset,
    shader: ShaderAsset,
    script: ScriptAsset,
    audio: AudioAsset,
    scene: SceneAsset,
    animation: AnimationAsset,
};

test "AssetId generation and validation" {
    const id1 = AssetId.generate();
    const id2 = AssetId.generate();

    try std.testing.expect(id1.isValid());
    try std.testing.expect(id2.isValid());
    try std.testing.expect(id1 != id2);
    try std.testing.expect(!AssetId.invalid.isValid());
}

test "AssetMetadata dependency management" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var metadata = AssetMetadata.init(allocator, AssetId.generate(), .texture, "test.png");
    defer metadata.deinit();

    const dep1 = AssetId.generate();
    const dep2 = AssetId.generate();

    try metadata.addDependency(dep1);
    try metadata.addDependency(dep2);
    try std.testing.expectEqual(@as(usize, 2), metadata.dependencies.items.len);

    // Adding same dependency should not duplicate
    try metadata.addDependency(dep1);
    try std.testing.expectEqual(@as(usize, 2), metadata.dependencies.items.len);

    // Test removal
    try std.testing.expect(metadata.removeDependency(dep1));
    try std.testing.expectEqual(@as(usize, 1), metadata.dependencies.items.len);
    try std.testing.expect(!metadata.removeDependency(dep1));
}

test "AssetMetadata reference counting" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var metadata = AssetMetadata.init(allocator, AssetId.generate(), .mesh, "test.obj");
    defer metadata.deinit();

    try std.testing.expect(metadata.canUnload());

    metadata.incrementRef();
    try std.testing.expectEqual(@as(u32, 1), metadata.reference_count);
    try std.testing.expect(!metadata.canUnload());

    metadata.incrementRef();
    try std.testing.expectEqual(@as(u32, 2), metadata.reference_count);

    try std.testing.expect(!metadata.decrementRef());
    try std.testing.expectEqual(@as(u32, 1), metadata.reference_count);

    try std.testing.expect(metadata.decrementRef());
    try std.testing.expectEqual(@as(u32, 0), metadata.reference_count);
    try std.testing.expect(metadata.canUnload());
}
