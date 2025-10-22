// Complete ECS workflow demonstration
// This file demonstrates the full ECS system in action

const std = @import("std");
const ecs = @import("../ecs.zig");
const AssetId = @import("../assets/asset_types.zig").AssetId;
const math = @import("../utils/math.zig");

// Demonstrates complete ECS workflow
test "Complete ECS Workflow: Create Scene, Update, and Render" {
    // Setup allocator
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Initialize ECS World
    var world = ecs.World.init(allocator, null);
    defer world.deinit();

    // Register all components
    try world.registerComponent(ecs.Transform);
    try world.registerComponent(ecs.MeshRenderer);
    try world.registerComponent(ecs.Camera);

    // Initialize systems
    var transform_system = ecs.TransformSystem.init(allocator);
    defer transform_system.deinit();

    var render_system = ecs.RenderSystem.init(allocator);
    defer render_system.deinit();

    // ========================================================================
    // Scene Creation: Build a hierarchical scene
    // ========================================================================

    // Create camera entity
    const camera_entity = try world.createEntity();
    {
        const transform = ecs.Transform.initWithPosition(.{ .x = 0, .y = 5, .z = 10 });
        try world.emplace(ecs.Transform, camera_entity, transform);

        var camera = ecs.Camera.initPerspective(60.0, 16.0 / 9.0, 0.1, 100.0);
        camera.setPrimary(true);
        try world.emplace(ecs.Camera, camera_entity, camera);
    }

    // Create parent entity (e.g., a spaceship)
    const parent_entity = try world.createEntity();
    {
        const transform = ecs.Transform.initWithPosition(.{ .x = 0, .y = 2, .z = 0 });
        try world.emplace(ecs.Transform, parent_entity, transform);

        const renderer = ecs.MeshRenderer.init(@enumFromInt(100), @enumFromInt(200));
        try world.emplace(ecs.MeshRenderer, parent_entity, renderer);
    }

    // Create left wing (child of spaceship)
    const left_wing = try world.createEntity();
    {
        var transform = ecs.Transform.initWithPosition(.{ .x = -3, .y = 0, .z = 0 });
        transform.setParent(parent_entity);
        try world.emplace(ecs.Transform, left_wing, transform);

        var renderer = ecs.MeshRenderer.init(@enumFromInt(101), @enumFromInt(200));
        renderer.setLayer(5); // Different layer for wings
        try world.emplace(ecs.MeshRenderer, left_wing, renderer);
    }

    // Create right wing (child of spaceship)
    const right_wing = try world.createEntity();
    {
        var transform = ecs.Transform.initWithPosition(.{ .x = 3, .y = 0, .z = 0 });
        transform.setParent(parent_entity);
        try world.emplace(ecs.Transform, right_wing, transform);

        var renderer = ecs.MeshRenderer.init(@enumFromInt(102), @enumFromInt(200));
        renderer.setLayer(5);
        try world.emplace(ecs.MeshRenderer, right_wing, renderer);
    }

    // Create ground plane (independent entity)
    const ground = try world.createEntity();
    {
        const transform = ecs.Transform.initWithPosition(.{ .x = 0, .y = 0, .z = 0 });
        try world.emplace(ecs.Transform, ground, transform);

        var renderer = ecs.MeshRenderer.init(@enumFromInt(103), @enumFromInt(201));
        renderer.setLayer(0); // Ground on layer 0
        try world.emplace(ecs.MeshRenderer, ground, renderer);
    }

    // ========================================================================
    // Simulation: Update scene state
    // ========================================================================

    // Rotate the parent spaceship
    if (world.get(ecs.Transform, parent_entity)) |parent_transform| {
        parent_transform.rotate(math.Vec3.init(0, math.radians(45.0), 0));
    }

    // Update transform hierarchies
    try transform_system.update(&world);

    // ========================================================================
    // Validation: Verify hierarchy propagation
    // ========================================================================

    // Parent should be at (0, 2, 0) with rotation
    if (world.get(ecs.Transform, parent_entity)) |t| {
        try std.testing.expect(!t.dirty);
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), t.world_matrix.data[12], 0.001); // x
        try std.testing.expectApproxEqAbs(@as(f32, 2.0), t.world_matrix.data[13], 0.001); // y
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), t.world_matrix.data[14], 0.001); // z
    }

    // Children should have inherited parent's transform
    if (world.get(ecs.Transform, left_wing)) |t| {
        try std.testing.expect(!t.dirty);
        // World matrix should include parent's rotation and translation
    }

    // ========================================================================
    // Rendering: Extract data for GPU submission
    // ========================================================================

    var render_data = try render_system.extractRenderData(&world);
    defer render_data.deinit();

    // Verify camera was found
    try std.testing.expect(render_data.camera != null);
    const camera_data = render_data.camera.?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), camera_data.position.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), camera_data.position.y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), camera_data.position.z, 0.001);

    // Verify all renderable entities were extracted
    try std.testing.expectEqual(@as(usize, 4), render_data.renderables.items.len);

    // Verify layer sorting (layer 0 entities come before layer 5)
    try std.testing.expectEqual(@as(u8, 0), render_data.renderables.items[0].layer);
    try std.testing.expectEqual(@as(u8, 0), render_data.renderables.items[1].layer);
    try std.testing.expectEqual(@as(u8, 5), render_data.renderables.items[2].layer);
    try std.testing.expectEqual(@as(u8, 5), render_data.renderables.items[3].layer);

    // Count entities by layer
    var layer_0_count: usize = 0;
    var layer_5_count: usize = 0;
    for (render_data.renderables.items) |renderable| {
        if (renderable.layer == 0) layer_0_count += 1;
        if (renderable.layer == 5) layer_5_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), layer_0_count); // Ground + Parent
    try std.testing.expectEqual(@as(usize, 2), layer_5_count); // Left + Right wing

    // ========================================================================
    // Runtime Modification: Dynamic scene changes
    // ========================================================================

    // Disable left wing
    if (world.get(ecs.MeshRenderer, left_wing)) |renderer| {
        renderer.setEnabled(false);
    }

    // Re-extract render data
    var render_data2 = try render_system.extractRenderData(&world);
    defer render_data2.deinit();

    // Should now have 3 renderables (left wing disabled)
    try std.testing.expectEqual(@as(usize, 3), render_data2.renderables.items.len);

    // ========================================================================
    // Cleanup: Destroy entities
    // ========================================================================

    world.destroyEntity(left_wing);
    world.destroyEntity(right_wing);
    world.destroyEntity(parent_entity);
    world.destroyEntity(ground);
    world.destroyEntity(camera_entity);

    // Verify all entities are destroyed
    var render_data3 = try render_system.extractRenderData(&world);
    defer render_data3.deinit();

    try std.testing.expectEqual(@as(usize, 0), render_data3.renderables.items.len);
    try std.testing.expect(render_data3.camera == null);
}

// Demonstrates ECS performance with many entities
test "ECS Performance: 1000 entities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = ecs.World.init(allocator, null);
    defer world.deinit();

    try world.registerComponent(ecs.Transform);
    try world.registerComponent(ecs.MeshRenderer);
    try world.registerComponent(ecs.Camera);

    var transform_system = ecs.TransformSystem.init(allocator);
    defer transform_system.deinit();

    var render_system = ecs.RenderSystem.init(allocator);
    defer render_system.deinit();

    // Create 1000 entities
    const entity_count = 1000;
    var entities: [entity_count]ecs.EntityId = undefined;

    for (0..entity_count) |i| {
        const entity = try world.createEntity();
        entities[i] = entity;

        const x = @as(f32, @floatFromInt(i % 32));
        const z = @as(f32, @floatFromInt(i / 32));

        const transform = ecs.Transform.initWithPosition(.{ .x = x, .y = 0, .z = z });
        try world.emplace(ecs.Transform, entity, transform);

        const renderer = ecs.MeshRenderer.init(@enumFromInt(1), @enumFromInt(1));
        try world.emplace(ecs.MeshRenderer, entity, renderer);
    }

    // Update transforms
    const start = std.time.nanoTimestamp();
    try transform_system.update(&world);
    const transform_time = std.time.nanoTimestamp() - start;

    // Extract render data
    const extract_start = std.time.nanoTimestamp();
    var render_data = try render_system.extractRenderData(&world);
    defer render_data.deinit();
    const extract_time = std.time.nanoTimestamp() - extract_start;

    // Verify all entities were extracted
    try std.testing.expectEqual(@as(usize, entity_count), render_data.renderables.items.len);

    // Print performance metrics (only in debug mode)
    if (false) { // Set to true to see timing
        std.debug.print("\n1000 entities:\n", .{});
        std.debug.print("  Transform update: {}μs\n", .{@divTrunc(transform_time, 1000)});
        std.debug.print("  Render extraction: {}μs\n", .{@divTrunc(extract_time, 1000)});
    }

    // Performance expectations (should be fast)
    try std.testing.expect(transform_time < 10_000_000); // < 10ms
    try std.testing.expect(extract_time < 10_000_000); // < 10ms
}
