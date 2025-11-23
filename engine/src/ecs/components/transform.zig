const std = @import("std");
const math = @import("../../utils/math.zig");
const log = @import("../../utils/log.zig").log;
const EntityId = @import("../entity_registry.zig").EntityId;
const UuidComponent = @import("uuid.zig").UuidComponent;

/// Transform component for ECS entities
/// Supports local transforms with optional parent-child hierarchies
///
/// TODO(MAINTENANCE): STORE QUATERNION INSTEAD OF EULER - LOW PRIORITY
/// Currently: stores Euler angles (gimbal lock issues, poor interpolation)
/// Required: Store quaternion, add Euler<->Quat conversion in math.zig
/// Files: transform.zig (change rotation field), game_object.zig (implement get/setRotation)
/// Branch: maintenance
pub const Transform = struct {
    pub const json_name = "Transform";
    /// Local position relative to parent (or world if no parent)
    position: math.Vec3,

    /// Local rotation stored as quaternion
    rotation: math.Quat,

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
            .rotation = math.Quat.fromEuler(0, 0, 0),
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

    /// Serialize Transform component
    pub fn jsonSerialize(self: Transform, serializer: anytype, writer: anytype) !void {
        try writer.beginObject();

        try writer.objectField("position");
        try writer.write(self.position);

        try writer.objectField("rotation");
        try writer.write(self.rotation);

        try writer.objectField("scale");
        try writer.write(self.scale);

        if (self.parent) |parent_id| {
            if (serializer.getEntityUuid(parent_id)) |uuid| {
                try writer.objectField("parent");
                var buf: [36]u8 = undefined;
                const uuid_str = try std.fmt.bufPrint(&buf, "{f}", .{uuid});
                try writer.write(uuid_str);
            }
        }

        try writer.endObject();
    }

    /// Deserialize Transform component
    pub fn deserialize(serializer: anytype, value: std.json.Value) !Transform {
        var transform = Transform.init();

        if (value.object.get("position")) |pos_val| {
            const parsed = try std.json.parseFromValue(math.Vec3, serializer.allocator, pos_val, .{});
            transform.position = parsed.value;
            parsed.deinit();
        }

        if (value.object.get("rotation")) |rot_val| {
            const parsed = try std.json.parseFromValue(math.Quat, serializer.allocator, rot_val, .{});
            transform.rotation = parsed.value;
            parsed.deinit();
        }

        if (value.object.get("scale")) |scale_val| {
            const parsed = try std.json.parseFromValue(math.Vec3, serializer.allocator, scale_val, .{});
            transform.scale = parsed.value;
            parsed.deinit();
        }

        if (value.object.get("parent")) |parent_val| {
            if (parent_val == .string) {
                const uuid = try UuidComponent.fromString(parent_val.string);
                const parent_id = serializer.getEntityId(uuid);
                if (parent_id) |pid| {
                    transform.parent = pid;
                } else {
                    log(.WARN, "transform", "Failed to resolve parent UUID: {s}", .{parent_val.string});
                }
            }
        }

        transform.dirty = true;
        return transform;
    }

    /// Create a Transform with position, rotation, and scale
    pub fn initFull(pos: math.Vec3, rot: math.Vec3, scl: math.Vec3) Transform {
        return .{
            .position = pos,
            .rotation = math.Quat.fromEuler(rot.x, rot.y, rot.z),
            .scale = scl,
            .parent = null,
            .world_matrix = math.Mat4.identity(),
            .dirty = true,
        };
    }

    /// Create a Transform with quaternion rotation
    pub fn initFullQuat(pos: math.Vec3, rot: math.Quat, scl: math.Vec3) Transform {
        return .{
            .position = pos,
            .rotation = rot.normalize(),
            .scale = scl,
            .parent = null,
            .world_matrix = math.Mat4.identity(),
            .dirty = true,
        };
    }

    /// Calculate local transform matrix (TRS: Translation * Rotation * Scale)
    pub fn getLocalMatrix(self: *const Transform) math.Mat4 {
        // Build TRS matrix: Translation * Rotation * Scale

        // Use quaternion->matrix conversion for rotation
        var mat = self.rotation.toMat4();

        // Apply scale to the rotation matrix (scale applied per-column)
        // Column 0
        mat.data[0] *= self.scale.x;
        mat.data[1] *= self.scale.x;
        mat.data[2] *= self.scale.x;
        // Column 1
        mat.data[4] *= self.scale.y;
        mat.data[5] *= self.scale.y;
        mat.data[6] *= self.scale.y;
        // Column 2
        mat.data[8] *= self.scale.z;
        mat.data[9] *= self.scale.z;
        mat.data[10] *= self.scale.z;

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

    /// Set position and mark dirty only if changed
    pub fn setPosition(self: *Transform, pos: math.Vec3) void {
        if (self.position.x != pos.x or self.position.y != pos.y or self.position.z != pos.z) {
            self.position = pos;
            self.dirty = true;
        }
    }

    /// Helper function to update rotation if it represents a different rotation
    fn updateRotationIfChanged(self: *Transform, new_rotation: math.Quat) void {
        const q = new_rotation.normalize();
        // Use dot product comparison to handle quaternion double-cover (q and -q represent same rotation)
        const epsilon: f32 = 1e-6;
        if (!self.rotation.isRotationEqual(q, epsilon)) {
            self.rotation = q;
            self.dirty = true;
        }
    }

    /// Set rotation and mark dirty only if changed
    /// Set rotation by Euler angles (keeps compatibility)
    pub fn setRotation(self: *Transform, rot: math.Vec3) void {
        const q = math.Quat.fromEuler(rot.x, rot.y, rot.z);
        self.updateRotationIfChanged(q);
    }

    /// Set rotation directly by quaternion
    pub fn setRotationQuat(self: *Transform, rot: math.Quat) void {
        self.updateRotationIfChanged(rot);
    }

    /// Set scale and mark dirty only if changed
    pub fn setScale(self: *Transform, scl: math.Vec3) void {
        if (self.scale.x != scl.x or self.scale.y != scl.y or self.scale.z != scl.z) {
            self.scale = scl;
            self.dirty = true;
        }
    }

    /// Translate by offset
    pub fn translate(self: *Transform, offset: math.Vec3) void {
        self.position = self.position.add(offset);
        self.dirty = true;
    }

    /// Rotate by delta (in radians)
    /// Rotate by Euler delta (adds rotation expressed as Euler angles)
    pub fn rotate(self: *Transform, delta: math.Vec3) void {
        const dq = math.Quat.fromEuler(delta.x, delta.y, delta.z).normalize();
        self.rotation = dq.mul(self.rotation).normalize();
        self.dirty = true;
    }

    /// Rotate by axis/angle (radians)
    pub fn rotateAxisAngle(self: *Transform, axis: math.Vec3, angle: f32) void {
        const half = angle * 0.5;
        const s = @sin(half);
        const dq = math.Quat.init(axis.x * s, axis.y * s, axis.z * s, @cos(half)).normalize();
        self.rotation = dq.mul(self.rotation).normalize();
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
        // local -Z is forward
        return self.rotation.rotateVec(math.Vec3.init(0, 0, -1));
    }

    /// Get right direction vector (local X-axis after rotation)
    pub fn right(self: *const Transform) math.Vec3 {
        return self.rotation.rotateVec(math.Vec3.init(1, 0, 0));
    }

    /// Get up direction vector (local Y-axis after rotation)
    pub fn up(self: *const Transform) math.Vec3 {
        return self.rotation.rotateVec(math.Vec3.init(0, 1, 0));
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
