const std = @import("std");
const log = @import("../utils/log.zig").log;
const Math = @import("../utils/math.zig");
const Vec3 = Math.Vec3;
const Quat = Math.Quat;

const ecs = @import("../ecs.zig");
const EntityId = ecs.EntityId;
const Transform = ecs.Transform;

// Forward declaration to avoid circular dependency
const Scene = @import("scene.zig").Scene;

/// GameObject is a lightweight handle to an ECS entity
/// Provides Unity-like convenience methods
/// Scene owns the actual GameObject storage to ensure stable pointers
pub const GameObject = struct {
    entity_id: EntityId,
    scene: *const Scene, // Back-reference to access ECS world

    /// Get the entity ID (useful for direct ECS queries)
    pub fn getEntityId(self: GameObject) EntityId {
        return self.entity_id;
    }

    // ==================== Transform Shortcuts ====================

    /// Get world position
    pub fn getPosition(self: GameObject) ?Vec3 {
        const transform = self.scene.ecs_world.get(Transform, self.entity_id) orelse return null;
        return transform.position;
    }

    /// Set world position
    pub fn setPosition(self: GameObject, position: Vec3) !void {
        var transform = self.scene.ecs_world.get(Transform, self.entity_id) orelse return error.ComponentNotFound;
        transform.setPosition(position);
    }

    /// Get rotation (quaternion)
    pub fn getRotation(self: GameObject) ?Quat {
        _ = self;
        // Transform stores Euler angles, not quaternions
        // For now, return identity quaternion
        // TODO: Convert Euler to Quat when needed
        return Quat.identity();
    }

    /// Set rotation (quaternion)
    pub fn setRotation(self: GameObject, rotation: Quat) !void {
        _ = rotation;
        var transform = self.scene.ecs_world.get(Transform, self.entity_id) orelse return error.ComponentNotFound;
        // TODO: Convert Quat to Euler angles
        transform.dirty = true;
    }

    /// Get scale
    pub fn getScale(self: GameObject) ?Vec3 {
        const transform = self.scene.ecs_world.get(Transform, self.entity_id) orelse return null;
        return transform.scale;
    }

    /// Set scale
    pub fn setScale(self: GameObject, scale: Vec3) !void {
        var transform = self.scene.ecs_world.get(Transform, self.entity_id) orelse return error.ComponentNotFound;
        transform.setScale(scale);
    }

    /// Set uniform scale
    pub fn setUniformScale(self: GameObject, scale: f32) !void {
        var transform = self.scene.ecs_world.get(Transform, self.entity_id) orelse return error.ComponentNotFound;
        transform.setScale(Vec3.init(scale, scale, scale));
    }

    /// Translate (move by offset)
    pub fn translate(self: GameObject, offset: Vec3) !void {
        var transform = self.scene.ecs_world.get(Transform, self.entity_id) orelse return error.ComponentNotFound;
        const new_pos = transform.position.add(offset);
        transform.setPosition(new_pos);
    }

    /// Rotate around axis by angle (radians)
    pub fn rotate(self: GameObject, axis: Vec3, angle: f32) !void {
        _ = axis;
        _ = angle;
        var transform = self.scene.ecs_world.get(Transform, self.entity_id) orelse return error.ComponentNotFound;
        // TODO: Implement proper rotation
        transform.dirty = true;
    }

    // ==================== Hierarchy ====================

    /// Set parent (for transform hierarchy)
    pub fn setParent(self: GameObject, parent: ?GameObject) !void {
        var transform = self.scene.ecs_world.get(Transform, self.entity_id) orelse return error.ComponentNotFound;
        transform.parent = if (parent) |p| p.entity_id else null;
    }

    /// Get parent
    pub fn getParent(self: GameObject) ?EntityId {
        const transform = self.scene.ecs_world.get(Transform, self.entity_id) orelse return null;
        return transform.parent;
    }

    // ==================== Component Access ====================

    /// Check if entity has a component
    pub fn hasComponent(self: GameObject, comptime T: type) bool {
        return self.scene.ecs_world.has(T, self.entity_id);
    }

    /// Get component (read-only)
    pub fn getComponent(self: GameObject, comptime T: type) !T {
        const component_ptr = self.scene.ecs_world.get(T, self.entity_id) orelse return error.ComponentNotFound;
        return component_ptr.*;
    }

    /// Get component (mutable)
    pub fn getComponentMut(self: GameObject, comptime T: type) !*T {
        return self.scene.ecs_world.get(T, self.entity_id) orelse return error.ComponentNotFound;
    }

    /// Add component
    pub fn addComponent(self: GameObject, comptime T: type, component: T) !void {
        try self.scene.ecs_world.emplace(T, self.entity_id, component);
    }

    /// Remove component
    pub fn removeComponent(self: GameObject, comptime T: type) !void {
        try self.scene.ecs_world.remove(T, self.entity_id);
    }

    // ==================== Utility ====================

    /// Check if this GameObject is still valid (entity exists)
    pub fn isValid(self: GameObject) bool {
        return self.scene.ecs_world.has(Transform, self.entity_id);
    }

    /// Destroy this GameObject (removes entity from ECS)
    pub fn destroy(self: GameObject) void {
        log(.INFO, "game_object", "Destroying GameObject entity {}", .{@intFromEnum(self.entity_id)});
        self.scene.ecs_world.destroyEntity(self.entity_id);
    }
};

// Forward declaration already at top of file

// ==================== Tests ====================

const testing = std.testing;

test "GameObject v2: setPosition updates transform" {
    const World = ecs.World;
    const MeshRenderer = ecs.MeshRenderer;

    var world = World.init(testing.allocator, null);
    defer world.deinit();

    try world.registerComponent(Transform);
    try world.registerComponent(MeshRenderer);

    const AssetManager = @import("../assets/asset_manager.zig").AssetManager;
    var mock_asset_manager: AssetManager = undefined;
    var scene = Scene.init(testing.allocator, &world, &mock_asset_manager, null, "test_scene");
    defer scene.deinit();

    const obj = try scene.spawnEmpty(null);

    // Set position
    const new_pos = Vec3.init(10, 20, 30);
    try obj.setPosition(new_pos);

    // Verify position changed
    const pos = obj.getPosition();
    try testing.expect(pos != null);
    try testing.expectEqual(new_pos, pos.?);
}

test "GameObject v2: translate moves object by offset" {
    const World = ecs.World;
    const MeshRenderer = ecs.MeshRenderer;

    var world = World.init(testing.allocator, null);
    defer world.deinit();

    try world.registerComponent(Transform);
    try world.registerComponent(MeshRenderer);

    const AssetManager = @import("../assets/asset_manager.zig").AssetManager;
    var mock_asset_manager: AssetManager = undefined;
    var scene = Scene.init(testing.allocator, &world, &mock_asset_manager, null, "test_scene");
    defer scene.deinit();

    const obj = try scene.spawnEmpty(null);

    // Set initial position
    try obj.setPosition(Vec3.init(10, 20, 30));

    // Translate by offset
    try obj.translate(Vec3.init(5, -10, 15));

    // Verify new position
    const pos = obj.getPosition();
    try testing.expect(pos != null);
    try testing.expectEqual(Vec3.init(15, 10, 45), pos.?);
}

test "GameObject v2: setParent creates hierarchy" {
    const World = ecs.World;
    const MeshRenderer = ecs.MeshRenderer;

    var world = World.init(testing.allocator, null);
    defer world.deinit();

    try world.registerComponent(Transform);
    try world.registerComponent(MeshRenderer);

    const AssetManager = @import("../assets/asset_manager.zig").AssetManager;
    var mock_asset_manager: AssetManager = undefined;
    var scene = Scene.init(testing.allocator, &world, &mock_asset_manager, null, "test_scene");
    defer scene.deinit();

    const parent = try scene.spawnEmpty(null);
    const child = try scene.spawnEmpty(null);

    // Set parent
    try child.setParent(parent.*);

    // Verify hierarchy
    const parent_id = child.getParent();
    try testing.expect(parent_id != null);
    try testing.expectEqual(parent.entity_id, parent_id.?);
}
