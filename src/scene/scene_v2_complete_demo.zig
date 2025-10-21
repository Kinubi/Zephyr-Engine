const std = @import("std");
const log = @import("../utils/log.zig").log;
const Math = @import("../utils/math.zig");
const Vec3 = Math.Vec3;

const ecs = @import("../ecs.zig");
const World = ecs.World;
const Transform = ecs.Transform;
const MeshRenderer = ecs.MeshRenderer;
const Camera = ecs.Camera;

const Scene = @import("scene_v2.zig").Scene;
const GameObject = @import("game_object_v2.zig").GameObject;
const AssetManager = @import("../assets/asset_manager.zig").AssetManager;

/// Demo: Complete Scene v2 API Showcase
/// Demonstrates all spawning methods, hierarchy, and utility functions
pub fn runCompleteDemo(allocator: std.mem.Allocator) !void {
    log(.INFO, "scene_demo", "=== Scene v2 Complete API Demo ===", .{});

    // Setup ECS world
    var world = World.init(allocator, null);
    defer world.deinit();

    try world.registerComponent(Transform);
    try world.registerComponent(MeshRenderer);
    try world.registerComponent(Camera);

    // Mock asset manager (in real app, this would be initialized properly)
    var mock_asset_manager: AssetManager = undefined;

    // Create scene
    var scene = Scene.init(allocator, &world, &mock_asset_manager, "complete_demo");
    defer scene.deinit();

    log(.INFO, "scene_demo", "--- Part 1: Basic Spawning ---", .{});

    // Spawn empty object (container)
    const root = try scene.spawnEmpty("root");
    try root.setPosition(Vec3.init(0, 0, 0));
    log(.INFO, "scene_demo", "Spawned root GameObject", .{});

    // Spawn props (would load actual models in real app)
    // const floor = try scene.spawnProp("models/plane.obj", "textures/floor.png");
    // const tree = try scene.spawnProp("models/tree.obj", "textures/bark.png");

    log(.INFO, "scene_demo", "--- Part 2: Camera Setup ---", .{});

    // Spawn perspective camera
    const main_camera = try scene.spawnCamera(true, 60.0); // 60° FOV
    try main_camera.setPosition(Vec3.init(0, 5, -10));
    log(.INFO, "scene_demo", "Spawned main camera (perspective, 60° FOV)", .{});

    // Spawn orthographic camera for UI
    const ui_camera = try scene.spawnCamera(false, 10.0); // 10 units height
    try ui_camera.setPosition(Vec3.init(0, 0, 0));
    
    // Make UI camera secondary (main_camera is primary)
    if (ui_camera.hasComponent(Camera)) {
        var cam = try ui_camera.getComponentMut(Camera);
        cam.setPrimary(false);
    }
    log(.INFO, "scene_demo", "Spawned UI camera (orthographic, 10 units)", .{});

    log(.INFO, "scene_demo", "--- Part 3: Lights ---", .{});

    // Spawn lights
    const sun = try scene.spawnLight(Vec3.init(1.0, 1.0, 0.9), 1.5);
    try sun.setPosition(Vec3.init(10, 20, 10));
    log(.INFO, "scene_demo", "Spawned sun light", .{});

    const point_light = try scene.spawnLight(Vec3.init(1.0, 0.5, 0.2), 2.0);
    try point_light.setPosition(Vec3.init(5, 3, 5));
    log(.INFO, "scene_demo", "Spawned point light", .{});

    log(.INFO, "scene_demo", "--- Part 4: Particle Systems ---", .{});

    // Spawn particle emitter
    const fire_particles = try scene.spawnParticleEmitter(1000, 50.0);
    try fire_particles.setPosition(Vec3.init(0, 1, 0));
    log(.INFO, "scene_demo", "Spawned fire particle emitter (1000 particles, 50/s)", .{});

    const smoke_particles = try scene.spawnParticleEmitter(500, 20.0);
    try smoke_particles.setPosition(Vec3.init(0, 2, 0));
    log(.INFO, "scene_demo", "Spawned smoke particle emitter (500 particles, 20/s)", .{});

    log(.INFO, "scene_demo", "--- Part 5: Hierarchy ---", .{});

    // Create parent-child hierarchy
    const character = try scene.spawnEmpty("character");
    try character.setPosition(Vec3.init(5, 0, 5));

    const weapon = try scene.spawnEmpty("weapon");
    try weapon.setParent(character);
    try weapon.setPosition(Vec3.init(0.5, 1.5, 0.2)); // Relative to character
    log(.INFO, "scene_demo", "Created character with weapon (parent-child)", .{});

    const hat = try scene.spawnEmpty("hat");
    try hat.setParent(character);
    try hat.setPosition(Vec3.init(0, 2, 0)); // On top of character
    log(.INFO, "scene_demo", "Added hat to character", .{});

    // Verify hierarchy
    const weapon_parent = weapon.getParent();
    try std.testing.expect(weapon_parent != null);
    try std.testing.expectEqual(character.entity_id, weapon_parent.?);
    log(.INFO, "scene_demo", "Verified weapon is child of character", .{});

    log(.INFO, "scene_demo", "--- Part 6: Transform Operations ---", .{});

    // Translate, rotate, scale
    const box = try scene.spawnEmpty("box");
    try box.setPosition(Vec3.init(10, 0, 10));
    try box.translate(Vec3.init(-5, 2, -5));
    try box.setScale(Vec3.init(2, 2, 2));
    try box.setUniformScale(1.5);

    const final_pos = box.getPosition();
    log(.INFO, "scene_demo", "Box final position: ({d:.2}, {d:.2}, {d:.2})", .{ final_pos.?.x, final_pos.?.y, final_pos.?.z });

    log(.INFO, "scene_demo", "--- Part 7: Query and Utility ---", .{});

    // Get entity count
    const entity_count = scene.getEntityCount();
    log(.INFO, "scene_demo", "Total entities in scene: {}", .{entity_count});

    // Iterate over all objects
    const objects = scene.iterateObjects();
    log(.INFO, "scene_demo", "Iterating over {} GameObjects:", .{objects.len});
    for (objects, 0..) |obj, i| {
        const pos = obj.getPosition() orelse Vec3.init(0, 0, 0);
        log(.INFO, "scene_demo", "  [{}] Entity {} at ({d:.2}, {d:.2}, {d:.2})", .{ i, @intFromEnum(obj.entity_id), pos.x, pos.y, pos.z });
    }

    // Find by entity
    const found_camera = scene.findByEntity(main_camera.entity_id);
    try std.testing.expect(found_camera != null);
    log(.INFO, "scene_demo", "Found camera by entity ID", .{});

    log(.INFO, "scene_demo", "--- Part 8: Component Access ---", .{});

    // Check components
    const has_transform = main_camera.hasComponent(Transform);
    const has_camera = main_camera.hasComponent(Camera);
    log(.INFO, "scene_demo", "Main camera has Transform: {}, has Camera: {}", .{ has_transform, has_camera });

    // Get component (immutable)
    const cam_transform = try main_camera.getComponent(Transform);
    log(.INFO, "scene_demo", "Camera transform position: ({d:.2}, {d:.2}, {d:.2})", .{ cam_transform.position.x, cam_transform.position.y, cam_transform.position.z });

    // Get component (mutable)
    const cam_data = try main_camera.getComponentMut(Camera);
    const is_primary = cam_data.is_primary;
    log(.INFO, "scene_demo", "Main camera is primary: {}", .{is_primary});

    log(.INFO, "scene_demo", "--- Part 9: Object Destruction ---", .{});

    // Destroy individual object
    const temp_obj = try scene.spawnEmpty("temporary");
    const temp_entity = temp_obj.entity_id;
    log(.INFO, "scene_demo", "Created temporary object: {}", .{@intFromEnum(temp_entity)});

    scene.destroyObject(temp_obj);
    log(.INFO, "scene_demo", "Destroyed temporary object", .{});

    const final_count = scene.getEntityCount();
    log(.INFO, "scene_demo", "Entity count after destruction: {}", .{final_count});

    log(.INFO, "scene_demo", "--- Part 10: Scene Unload ---", .{});

    // Scene.deinit() will call unload() which destroys all entities
    log(.INFO, "scene_demo", "Scene will be unloaded in defer cleanup...", .{});

    log(.INFO, "scene_demo", "=== Demo Complete ===", .{});
}

// ==================== Tests ====================

test "Scene v2 Complete Demo: runs without errors" {
    try runCompleteDemo(std.testing.allocator);
}

test "Scene v2: spawnCamera creates camera entity" {
    var world = World.init(std.testing.allocator, null);
    defer world.deinit();

    try world.registerComponent(Transform);
    try world.registerComponent(MeshRenderer);
    try world.registerComponent(Camera);

    var mock_asset_manager: AssetManager = undefined;
    var scene = Scene.init(std.testing.allocator, &world, &mock_asset_manager, "test");
    defer scene.deinit();

    const camera = try scene.spawnCamera(true, 60.0);

    std.testing.expect(camera.hasComponent(Transform)) catch unreachable;
    std.testing.expect(camera.hasComponent(Camera)) catch unreachable;
}

test "Scene v2: spawnLight creates light entity" {
    var world = World.init(std.testing.allocator, null);
    defer world.deinit();

    try world.registerComponent(Transform);
    try world.registerComponent(MeshRenderer);

    var mock_asset_manager: AssetManager = undefined;
    var scene = Scene.init(std.testing.allocator, &world, &mock_asset_manager, "test");
    defer scene.deinit();

    const light = try scene.spawnLight(Vec3.init(1, 1, 1), 1.0);

    std.testing.expect(light.hasComponent(Transform)) catch unreachable;
}

test "Scene v2: spawnParticleEmitter creates particle entity" {
    var world = World.init(std.testing.allocator, null);
    defer world.deinit();

    try world.registerComponent(Transform);
    try world.registerComponent(MeshRenderer);
    try world.registerComponent(ecs.ParticleComponent);

    var mock_asset_manager: AssetManager = undefined;
    var scene = Scene.init(std.testing.allocator, &world, &mock_asset_manager, "test");
    defer scene.deinit();

    const emitter = try scene.spawnParticleEmitter(1000, 50.0);

    std.testing.expect(emitter.hasComponent(Transform)) catch unreachable;
    std.testing.expect(emitter.hasComponent(ecs.ParticleComponent)) catch unreachable;
}

test "Scene v2: findByEntity returns correct GameObject" {
    var world = World.init(std.testing.allocator, null);
    defer world.deinit();

    try world.registerComponent(Transform);
    try world.registerComponent(MeshRenderer);

    var mock_asset_manager: AssetManager = undefined;
    var scene = Scene.init(std.testing.allocator, &world, &mock_asset_manager, "test");
    defer scene.deinit();

    _ = try scene.spawnEmpty("obj1");
    const obj2 = try scene.spawnEmpty("obj2");

    const found = scene.findByEntity(obj2.entity_id);
    try std.testing.expect(found != null);
    try std.testing.expectEqual(obj2.entity_id, found.?.entity_id);
}

test "Scene v2: destroyObject removes entity" {
    var world = World.init(std.testing.allocator, null);
    defer world.deinit();

    try world.registerComponent(Transform);
    try world.registerComponent(MeshRenderer);

    var mock_asset_manager: AssetManager = undefined;
    var scene = Scene.init(std.testing.allocator, &world, &mock_asset_manager, "test");
    defer scene.deinit();

    const obj = try scene.spawnEmpty("temp");
    const initial_count = scene.getEntityCount();

    scene.destroyObject(obj);
    const final_count = scene.getEntityCount();

    try std.testing.expectEqual(initial_count - 1, final_count);
}
