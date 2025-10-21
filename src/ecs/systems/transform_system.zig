const std = @import("std");
const World = @import("../world.zig").World;
const View = @import("../view.zig").View;
const Transform = @import("../components/transform.zig").Transform;

/// TransformSystem handles hierarchical transform updates
/// Updates child transforms based on parent transforms
pub const TransformSystem = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TransformSystem {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TransformSystem) void {
        _ = self;
    }

    /// Update all transforms in the world
    /// This updates local-to-world matrices for transforms with parents
    pub fn update(self: *TransformSystem, world: *World) !void {
        _ = self;

        // Get a view of all entities with Transform component
        var view = try world.view(Transform);

        // First pass: update all transforms that are dirty
        var iter = view.iterator();
        while (iter.next()) |entry| {
            const transform = entry.component;
            if (transform.dirty) {
                transform.updateWorldMatrix();
            }
        }

        // Second pass: propagate parent transforms to children
        // For now, this is a simple implementation
        // TODO: Could be optimized with a dependency graph or level-based sorting
        iter = view.iterator();
        while (iter.next()) |entry| {
            const transform = entry.component;
            if (transform.parent) |parent_id| {
                // Try to get parent transform
                if (world.get(Transform, parent_id)) |parent_transform| {
                    // Update child's world matrix based on parent
                    const local_matrix = transform.getLocalMatrix();
                    transform.world_matrix = parent_transform.world_matrix.mul(local_matrix);
                    transform.dirty = false;
                }
            }
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "TransformSystem: basic update" {
    const ecs = @import("../world.zig");
    
    var world = ecs.World.init(std.testing.allocator, null);
    defer world.deinit();

    try world.registerComponent(Transform);

    var system = TransformSystem.init(std.testing.allocator);
    defer system.deinit();

    // Create entity with transform
    const entity = try world.createEntity();
    const transform = Transform.initWithPosition(.{ .x = 1, .y = 2, .z = 3 });
    try world.emplace(Transform, entity, transform);

    // Update system
    try system.update(&world);

    // Verify transform was processed
    if (world.get(Transform, entity)) |t| {
        try std.testing.expect(!t.dirty);
    } else {
        return error.TransformNotFound;
    }
}

test "TransformSystem: parent-child hierarchy" {
    const ecs = @import("../world.zig");
    
    var world = ecs.World.init(std.testing.allocator, null);
    defer world.deinit();

    try world.registerComponent(Transform);

    var system = TransformSystem.init(std.testing.allocator);
    defer system.deinit();

    // Create parent entity
    const parent = try world.createEntity();
    const parent_transform = Transform.initWithPosition(.{ .x = 10, .y = 0, .z = 0 });
    try world.emplace(Transform, parent, parent_transform);

    // Create child entity
    const child = try world.createEntity();
    var child_transform = Transform.initWithPosition(.{ .x = 5, .y = 0, .z = 0 });
    child_transform.setParent(parent);
    try world.emplace(Transform, child, child_transform);

    // Update system
    try system.update(&world);

    // Verify parent transform
    if (world.get(Transform, parent)) |t| {
        try std.testing.expect(!t.dirty);
        // Parent at (10, 0, 0)
        try std.testing.expectApproxEqAbs(@as(f32, 10.0), t.world_matrix.data[12], 0.001);
    }

    // Verify child transform inherited parent's position
    if (world.get(Transform, child)) |t| {
        try std.testing.expect(!t.dirty);
        // Child should be at parent (10, 0, 0) + local (5, 0, 0) = (15, 0, 0)
        try std.testing.expectApproxEqAbs(@as(f32, 15.0), t.world_matrix.data[12], 0.001);
    }
}

test "TransformSystem: multiple children" {
    const ecs = @import("../world.zig");
    
    var world = ecs.World.init(std.testing.allocator, null);
    defer world.deinit();

    try world.registerComponent(Transform);

    var system = TransformSystem.init(std.testing.allocator);
    defer system.deinit();

    // Create parent
    const parent = try world.createEntity();
    const parent_transform = Transform.initWithPosition(.{ .x = 0, .y = 10, .z = 0 });
    try world.emplace(Transform, parent, parent_transform);

    // Create child 1
    const child1 = try world.createEntity();
    var child1_transform = Transform.initWithPosition(.{ .x = 1, .y = 0, .z = 0 });
    child1_transform.setParent(parent);
    try world.emplace(Transform, child1, child1_transform);

    // Create child 2
    const child2 = try world.createEntity();
    var child2_transform = Transform.initWithPosition(.{ .x = -1, .y = 0, .z = 0 });
    child2_transform.setParent(parent);
    try world.emplace(Transform, child2, child2_transform);

    // Update system
    try system.update(&world);

    // Both children should be positioned relative to parent
    if (world.get(Transform, child1)) |t| {
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), t.world_matrix.data[12], 0.001); // x
        try std.testing.expectApproxEqAbs(@as(f32, 10.0), t.world_matrix.data[13], 0.001); // y
    }

    if (world.get(Transform, child2)) |t| {
        try std.testing.expectApproxEqAbs(@as(f32, -1.0), t.world_matrix.data[12], 0.001); // x
        try std.testing.expectApproxEqAbs(@as(f32, 10.0), t.world_matrix.data[13], 0.001); // y
    }
}
