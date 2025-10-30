const std = @import("std");
const World = @import("../world.zig").World;
const View = @import("../view.zig").View;
const Transform = @import("../components/transform.zig").Transform;
const simd = @import("../../utils/simd.zig");
const math = @import("../../utils/math.zig");

/// TransformSystem handles hierarchical transform updates
/// Updates child transforms based on parent transforms
/// Uses SIMD for batch processing when possible
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
    /// Uses SIMD batch processing for transforms without parents (8 at a time)
    pub fn update(self: *TransformSystem, world: *World) !void {
        _ = self;

        // Get a view of all entities with Transform component
        var view = try world.view(Transform);

        // First pass: batch update all transforms that are dirty and have no parent
        // We can process these in batches of 8 using SIMD
        try updateDirtyTransformsSIMD(&view);

        // Second pass: propagate parent transforms to children (sequential)
        // This must be sequential due to dependencies
        var iter = view.iterator();
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

    /// SIMD-optimized batch update for transforms without parents
    fn updateDirtyTransformsSIMD(view: *View(Transform)) !void {
        // Collect transforms that need updating (dirty, no parent)
        var batch_buffer: [8]*Transform = undefined;
        var batch_count: usize = 0;

        var iter = view.iterator();
        while (iter.next()) |entry| {
            const transform = entry.component;

            // Skip if not dirty or has parent (parent transforms handled separately)
            if (!transform.dirty or transform.parent != null) {
                continue;
            }

            // Add to batch
            batch_buffer[batch_count] = transform;
            batch_count += 1;

            // Process batch when full
            if (batch_count == 8) {
                processBatch(batch_buffer[0..8]);
                batch_count = 0;
            }
        }

        // Process remaining transforms in batch (if any)
        if (batch_count > 0) {
            // Process the partial batch (some lanes will be wasted but that's ok)
            processBatch(batch_buffer[0..batch_count]);
        }
    }

    /// Process a batch of up to 8 transforms
    /// Uses optimized SIMD path for non-rotated transforms, falls back to scalar for rotated ones
    fn processBatch(transforms: []*Transform) void {
        const batch_size = transforms.len;
        if (batch_size == 0) return;

        // Check if any transform in the batch has rotation
        var has_rotation = false;
        for (transforms[0..batch_size]) |t| {
            if (t.rotation.x != 0 or t.rotation.y != 0 or t.rotation.z != 0) {
                has_rotation = true;
                break;
            }
        }

        // If any transform has rotation, use scalar path for all (simpler, still fast enough)
        if (has_rotation) {
            for (transforms[0..batch_size]) |t| {
                t.updateWorldMatrix();
            }
            return;
        }

        // Fast path: SIMD for non-rotated transforms
        var pos_x_data: [8]f32 = undefined;
        var pos_y_data: [8]f32 = undefined;
        var pos_z_data: [8]f32 = undefined;
        var scale_x_data: [8]f32 = undefined;
        var scale_y_data: [8]f32 = undefined;
        var scale_z_data: [8]f32 = undefined;

        // Fill vectors (pad with identity transforms for unused lanes)
        var i: usize = 0;
        while (i < 8) : (i += 1) {
            if (i < batch_size) {
                const t = transforms[i];
                pos_x_data[i] = t.position.x;
                pos_y_data[i] = t.position.y;
                pos_z_data[i] = t.position.z;
                scale_x_data[i] = t.scale.x;
                scale_y_data[i] = t.scale.y;
                scale_z_data[i] = t.scale.z;
            } else {
                // Identity transform for padding
                pos_x_data[i] = 0.0;
                pos_y_data[i] = 0.0;
                pos_z_data[i] = 0.0;
                scale_x_data[i] = 1.0;
                scale_y_data[i] = 1.0;
                scale_z_data[i] = 1.0;
            }
        }

        // Load into SIMD vectors
        const pos_x: simd.F32x8 = @bitCast(pos_x_data);
        const pos_y: simd.F32x8 = @bitCast(pos_y_data);
        const pos_z: simd.F32x8 = @bitCast(pos_z_data);
        const scale_x: simd.F32x8 = @bitCast(scale_x_data);
        const scale_y: simd.F32x8 = @bitCast(scale_y_data);
        const scale_z: simd.F32x8 = @bitCast(scale_z_data);

        // Build 8 TRS matrices in one go using SIMD
        var matrix_buffer: [128]f32 = undefined; // 8 matrices * 16 floats
        simd.batchBuildTRSMatrices(
            pos_x,
            pos_y,
            pos_z,
            scale_x,
            scale_y,
            scale_z,
            matrix_buffer[0..],
        );

        // Copy results back to transform world matrices
        i = 0;
        while (i < batch_size) : (i += 1) {
            const mat_offset = i * 16;
            const matrix_data = matrix_buffer[mat_offset .. mat_offset + 16];

            // Copy to transform's world_matrix
            @memcpy(transforms[i].world_matrix.data[0..16], matrix_data);

            // Note: Don't clear dirty flag - RenderSystem clears it after cache rebuild
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
        // Child at parent (10, 0, 0) + local (5, 0, 0) = (15, 0, 0)
        try std.testing.expectApproxEqAbs(@as(f32, 15.0), t.world_matrix.data[12], 0.001);
    }
}

test "TransformSystem: SIMD batch processing" {
    const ecs = @import("../world.zig");

    var world = ecs.World.init(std.testing.allocator, null);
    defer world.deinit();

    try world.registerComponent(Transform);

    var system = TransformSystem.init(std.testing.allocator);
    defer system.deinit();

    // Create 16 entities to test batch processing (processes 8 at a time)
    var entities: [16]ecs.EntityId = undefined;
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        entities[i] = try world.createEntity();
        const x = @as(f32, @floatFromInt(i));
        const transform = Transform.initFull(
            .{ .x = x, .y = x * 2, .z = x * 3 },
            .{ .x = 0, .y = 0, .z = 0 },
            .{ .x = 2.0, .y = 1.5, .z = 1.0 },
        );
        try world.emplace(Transform, entities[i], transform);
    }

    // Update system (should process in 2 SIMD batches of 8)
    try system.update(&world);

    // Verify all transforms were updated correctly
    i = 0;
    while (i < 16) : (i += 1) {
        if (world.get(Transform, entities[i])) |t| {
            const x = @as(f32, @floatFromInt(i));

            // Check position is in translation part of matrix (column 3)
            try std.testing.expectApproxEqAbs(x, t.world_matrix.data[12], 0.001);
            try std.testing.expectApproxEqAbs(x * 2, t.world_matrix.data[13], 0.001);
            try std.testing.expectApproxEqAbs(x * 3, t.world_matrix.data[14], 0.001);

            // Check scale is in diagonal elements
            try std.testing.expectApproxEqAbs(@as(f32, 2.0), t.world_matrix.data[0], 0.001);
            try std.testing.expectApproxEqAbs(@as(f32, 1.5), t.world_matrix.data[5], 0.001);
            try std.testing.expectApproxEqAbs(@as(f32, 1.0), t.world_matrix.data[10], 0.001);

            // Check w component is 1
            try std.testing.expectApproxEqAbs(@as(f32, 1.0), t.world_matrix.data[15], 0.001);
        } else {
            return error.TransformNotFound;
        }
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
