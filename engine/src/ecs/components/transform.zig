const std = @import("std");
const math = @import("../../utils/math.zig");
const EntityId = @import("../entity_registry.zig").EntityId;

/// Transform component for ECS entities
/// Supports local transforms with optional parent-child hierarchies
pub const Transform = struct {
    /// Local position relative to parent (or world if no parent)
    position: math.Vec3,

    /// Local rotation (Euler angles in radians)
    rotation: math.Vec3,

    /// Local scale
    scale: math.Vec3,

    /// Optional parent entity for hierarchical transforms
    parent: ?EntityId = null,

    /// Cached world-space matrix (updated by TransformSystem)
    world_matrix: math.Mat4 = math.Mat4.identity(),

    /// Dirty flag - set to true when local transform changes
    dirty: bool = true,

    /// Create a new Transform with default values (identity)
    pub fn init() Transform {
        return .{
            .position = math.Vec3.init(0, 0, 0),
            .rotation = math.Vec3.init(0, 0, 0),
            .scale = math.Vec3.init(1, 1, 1),
            .parent = null,
            .world_matrix = math.Mat4.identity(),
            .dirty = true,
        };
    }

    /// Create a Transform with specific position
    pub fn initWithPosition(pos: math.Vec3) Transform {
        var t = init();
        t.position = pos;
        return t;
    }

    /// Create a Transform with position, rotation, and scale
    pub fn initFull(pos: math.Vec3, rot: math.Vec3, scl: math.Vec3) Transform {
        return .{
            .position = pos,
            .rotation = rot,
            .scale = scl,
            .parent = null,
            .world_matrix = math.Mat4.identity(),
            .dirty = true,
        };
    }

    /// Calculate local transform matrix (TRS: Translation * Rotation * Scale)
    pub fn getLocalMatrix(self: *const Transform) math.Mat4 {
        // Build TRS matrix: Translation * Rotation * Scale
        // Start with identity
        var mat = math.Mat4.identity();

        // Apply scale
        mat.data[0] *= self.scale.x;
        mat.data[5] *= self.scale.y;
        mat.data[10] *= self.scale.z;

        // Apply rotation (would need proper rotation matrix multiplication)
        // For now, just handle translation and scale
        // TODO: Add proper rotation support when needed

        // Apply translation
        mat.data[12] = self.position.x;
        mat.data[13] = self.position.y;
        mat.data[14] = self.position.z;

        return mat;
    }

    /// Update world matrix from local transform (no parent)
    pub fn updateWorldMatrix(self: *Transform) void {
        self.world_matrix = self.getLocalMatrix();
        // NOTE: Don't clear dirty flag here - let RenderSystem clear it after rebuild
        // self.dirty = false;
    }

    /// Update world matrix with parent's world matrix
    pub fn updateWorldMatrixWithParent(self: *Transform, parent_world: math.Mat4) void {
        const local = self.getLocalMatrix();
        self.world_matrix = parent_world.mul(local);
        // NOTE: Don't clear dirty flag here - let RenderSystem clear it after rebuild
        // self.dirty = false;
    }

    /// Set position and mark dirty
    pub fn setPosition(self: *Transform, pos: math.Vec3) void {
        self.position = pos;
        self.dirty = true;
    }

    /// Set rotation and mark dirty
    pub fn setRotation(self: *Transform, rot: math.Vec3) void {
        self.rotation = rot;
        self.dirty = true;
    }

    /// Set scale and mark dirty
    pub fn setScale(self: *Transform, scl: math.Vec3) void {
        self.scale = scl;
        self.dirty = true;
    }

    /// Translate by offset
    pub fn translate(self: *Transform, offset: math.Vec3) void {
        self.position = self.position.add(offset);
        self.dirty = true;
    }

    /// Rotate by delta (in radians)
    pub fn rotate(self: *Transform, delta: math.Vec3) void {
        self.rotation = self.rotation.add(delta);
        self.dirty = true;
    }

    /// Scale by factor
    pub fn scaleBy(self: *Transform, factor: math.Vec3) void {
        self.scale.x *= factor.x;
        self.scale.y *= factor.y;
        self.scale.z *= factor.z;
        self.dirty = true;
    }

    /// Set parent entity (for hierarchical transforms)
    pub fn setParent(self: *Transform, parent_entity: ?EntityId) void {
        self.parent = parent_entity;
        self.dirty = true;
    }

    /// Check if this transform has a parent
    pub fn hasParent(self: *const Transform) bool {
        return self.parent != null;
    }

    /// ECS update method - called by World.update()
    /// For now, just update world matrix if dirty and no parent
    pub fn update(self: *Transform, dt: f32) void {
        _ = dt; // Not used for static transforms
        if (self.dirty and self.parent == null) {
            self.updateWorldMatrix();
        }
    }

    /// Get forward direction vector (local Z-axis after rotation)
    pub fn forward(self: *const Transform) math.Vec3 {
        _ = self;
        // TODO: Calculate from rotation when rotation support is added
        return math.Vec3.init(0, 0, -1);
    }

    /// Get right direction vector (local X-axis after rotation)
    pub fn right(self: *const Transform) math.Vec3 {
        _ = self;
        // TODO: Calculate from rotation when rotation support is added
        return math.Vec3.init(1, 0, 0);
    }

    /// Get up direction vector (local Y-axis after rotation)
    pub fn up(self: *const Transform) math.Vec3 {
        _ = self;
        // TODO: Calculate from rotation when rotation support is added
        return math.Vec3.init(0, 1, 0);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Transform: default init creates identity" {
    const t = Transform.init();

    try std.testing.expectEqual(@as(f32, 0), t.position.x);
    try std.testing.expectEqual(@as(f32, 0), t.position.y);
    try std.testing.expectEqual(@as(f32, 0), t.position.z);

    try std.testing.expectEqual(@as(f32, 1), t.scale.x);
    try std.testing.expectEqual(@as(f32, 1), t.scale.y);
    try std.testing.expectEqual(@as(f32, 1), t.scale.z);

    try std.testing.expect(t.dirty);
    try std.testing.expect(t.parent == null);
}

test "Transform: init with position" {
    const t = Transform.initWithPosition(math.Vec3.init(1, 2, 3));

    try std.testing.expectEqual(@as(f32, 1), t.position.x);
    try std.testing.expectEqual(@as(f32, 2), t.position.y);
    try std.testing.expectEqual(@as(f32, 3), t.position.z);
}

test "Transform: setters mark dirty" {
    var t = Transform.init();
    t.dirty = false;

    t.setPosition(math.Vec3.init(1, 0, 0));
    try std.testing.expect(t.dirty);

    t.dirty = false;
    t.setRotation(math.Vec3.init(0, 1, 0));
    try std.testing.expect(t.dirty);

    t.dirty = false;
    t.setScale(math.Vec3.init(2, 2, 2));
    try std.testing.expect(t.dirty);
}

test "Transform: translate adds to position" {
    var t = Transform.init();
    t.translate(math.Vec3.init(1, 2, 3));

    try std.testing.expectEqual(@as(f32, 1), t.position.x);
    try std.testing.expectEqual(@as(f32, 2), t.position.y);
    try std.testing.expectEqual(@as(f32, 3), t.position.z);

    t.translate(math.Vec3.init(1, 1, 1));
    try std.testing.expectEqual(@as(f32, 2), t.position.x);
    try std.testing.expectEqual(@as(f32, 3), t.position.y);
    try std.testing.expectEqual(@as(f32, 4), t.position.z);
}

test "Transform: updateWorldMatrix clears dirty flag" {
    var t = Transform.init();
    try std.testing.expect(t.dirty);

    t.updateWorldMatrix();
    try std.testing.expect(!t.dirty);
}

test "Transform: parent support" {
    var t = Transform.init();
    try std.testing.expect(!t.hasParent());

    t.setParent(@enumFromInt(42));
    try std.testing.expect(t.hasParent());
    try std.testing.expectEqual(@as(u32, 42), @intFromEnum(t.parent.?));
}

test "Transform: local matrix calculation" {
    var t = Transform.initFull(
        math.Vec3.init(1, 2, 3),
        math.Vec3.init(0, 0, 0),
        math.Vec3.init(1, 1, 1),
    );

    const mat = t.getLocalMatrix();

    // Translation should be in the last column
    try std.testing.expectEqual(@as(f32, 1), mat.data[12]);
    try std.testing.expectEqual(@as(f32, 2), mat.data[13]);
    try std.testing.expectEqual(@as(f32, 3), mat.data[14]);
}
