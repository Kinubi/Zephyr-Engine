const std = @import("std");
const log = @import("../utils/log.zig").log;
const Math = @import("../utils/math.zig");
const Vec3 = Math.Vec3;

const Scene = @import("scene_v2.zig").Scene;
const GameObject = @import("game_object_v2.zig").GameObject;
const ecs = @import("../ecs.zig");
const World = ecs.World;
const Transform = ecs.Transform;
const MeshRenderer = ecs.MeshRenderer;
const Camera = ecs.Camera;

const AssetManager = @import("../assets/asset_manager.zig").AssetManager;

/// Example: Creating a dungeon level with Scene v2
pub fn exampleDungeonScene(allocator: std.mem.Allocator, world: *World, asset_manager: *AssetManager) !Scene {
    var scene = Scene.init(allocator, world, asset_manager, "dungeon_level");

    // Spawn floor
    const floor = try scene.spawnProp("models/floor.obj", "textures/stone_floor.png");
    try floor.setPosition(Vec3.init(0, 0, 0));
    try floor.setScale(Vec3.init(10, 1, 10));

    // Spawn walls
    const wall1 = try scene.spawnProp("models/wall.obj", "textures/stone_wall.png");
    try wall1.setPosition(Vec3.init(0, 2, -5));

    const wall2 = try scene.spawnProp("models/wall.obj", "textures/stone_wall.png");
    try wall2.setPosition(Vec3.init(0, 2, 5));

    // Spawn treasure chest
    const chest = try scene.spawnProp("models/chest.obj", "textures/chest.png");
    try chest.setPosition(Vec3.init(2, 0, 0));

    // Spawn torch (child of wall for hierarchy demo)
    const torch = try scene.spawnProp("models/torch.obj", "textures/torch.png");
    try torch.setPosition(Vec3.init(-2, 3, -4.9)); // Local position
    try torch.setParent(wall1.*); // Attach to wall

    log(.INFO, "scene_demo", "Created dungeon scene with {} entities", .{scene.entities.items.len});

    return scene;
}

/// Example: Creating a forest level
pub fn exampleForestScene(allocator: std.mem.Allocator, world: *World, asset_manager: *AssetManager) !Scene {
    var scene = Scene.init(allocator, world, asset_manager, "forest_level");

    // Spawn terrain
    const terrain = try scene.spawnProp("models/terrain.obj", "textures/grass.png");
    try terrain.setPosition(Vec3.init(0, -1, 0));
    try terrain.setScale(Vec3.init(20, 1, 20));

    // Spawn trees in a pattern
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        const tree = try scene.spawnProp("models/tree.obj", "textures/bark.png");
        const angle = @as(f32, @floatFromInt(i)) * std.math.pi * 2.0 / 5.0;
        const radius = 8.0;
        const x = @cos(angle) * radius;
        const z = @sin(angle) * radius;
        try tree.setPosition(Vec3.init(x, 0, z));
    }

    // Spawn character spawn point (empty transform)
    const spawn_point = try scene.spawnEmpty("player_spawn");
    try spawn_point.setPosition(Vec3.init(0, 0, 0));

    log(.INFO, "scene_demo", "Created forest scene with {} entities", .{scene.entities.items.len});

    return scene;
}

/// Example: Modifying scene objects at runtime
pub fn exampleRuntimeModification(scene: *Scene) !void {
    log(.INFO, "scene_demo", "Demonstrating runtime modification...", .{});

    // Spawn a new object
    const cube = try scene.spawnProp("models/cube.obj", "textures/metal.png");
    try cube.setPosition(Vec3.init(0, 2, 0));

    // Animate it (in a real game this would be per-frame)
    var frame: u32 = 0;
    while (frame < 10) : (frame += 1) {
        const t = @as(f32, @floatFromInt(frame)) * 0.1;
        const y = 2.0 + @sin(t) * 0.5;
        try cube.setPosition(Vec3.init(0, y, 0));

        const angle = t;
        const axis = Vec3.init(0, 1, 0);
        try cube.rotate(axis, angle * 0.01);
    }

    log(.INFO, "scene_demo", "Animation complete", .{});
}

// ==================== Tests ====================

const testing = std.testing;

test "Scene Demo: dungeon level creation" {
    var world = World.init(testing.allocator, null);
    defer world.deinit();

    try world.registerComponent(Transform);
    try world.registerComponent(MeshRenderer);

    var mock_asset_manager: AssetManager = undefined;
    var scene = try exampleDungeonScene(testing.allocator, &world, &mock_asset_manager);
    defer scene.deinit();

    // Should have floor, 2 walls, chest, torch = 5 entities
    try testing.expectEqual(@as(usize, 5), scene.entities.items.len);
}

test "Scene Demo: forest level creation" {
    var world = World.init(testing.allocator, null);
    defer world.deinit();

    try world.registerComponent(Transform);
    try world.registerComponent(MeshRenderer);

    var mock_asset_manager: AssetManager = undefined;
    var scene = try exampleForestScene(testing.allocator, &world, &mock_asset_manager);
    defer scene.deinit();

    // Should have terrain, 5 trees, spawn point = 7 entities
    try testing.expectEqual(@as(usize, 7), scene.entities.items.len);
}

test "Scene Demo: runtime modification" {
    var world = World.init(testing.allocator, null);
    defer world.deinit();

    try world.registerComponent(Transform);
    try world.registerComponent(MeshRenderer);

    var mock_asset_manager: AssetManager = undefined;
    var scene = Scene.init(testing.allocator, &world, &mock_asset_manager, "test_scene");
    defer scene.deinit();

    // Test runtime modification
    try exampleRuntimeModification(&scene);

    // Should have 1 entity (the animated cube)
    try testing.expectEqual(@as(usize, 1), scene.entities.items.len);
}
