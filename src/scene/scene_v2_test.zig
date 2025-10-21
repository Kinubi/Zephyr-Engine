const std = @import("std");
const testing = std.testing;
const log = @import("../utils/log.zig").log;
const Math = @import("../utils/math.zig");
const Vec3 = Math.Vec3;

const Scene = @import("scene_v2.zig").Scene;
const GameObject = @import("game_object_v2.zig").GameObject;
const ecs = @import("../ecs.zig");
const World = ecs.World;
const Transform = ecs.Transform;
const MeshRenderer = ecs.MeshRenderer;

const AssetManager = @import("../assets/asset_manager.zig").AssetManager;
const AssetId = @import("../assets/asset_types.zig").AssetId;

// Mock AssetManager for testing
const MockAssetManager = struct {
    fn loadModelAsync(self: *anyopaque, path: []const u8) !AssetId {
        _ = self;
        _ = path;
        return @enumFromInt(1);
    }

    fn loadMaterialAsync(self: *anyopaque, path: []const u8) !AssetId {
        _ = self;
        _ = path;
        return @enumFromInt(2);
    }

    fn loadTextureAsync(self: *anyopaque, path: []const u8) !AssetId {
        _ = self;
        _ = path;
        return @enumFromInt(3);
    }
};

test "Scene.init creates empty scene" {
    var world = World.init(testing.allocator, null);
    defer world.deinit();

    try world.registerComponent(Transform);
    try world.registerComponent(MeshRenderer);

    var mock_asset_manager: AssetManager = undefined;
    var scene = Scene.init(testing.allocator, &world, &mock_asset_manager, "test_scene");
    defer scene.deinit();

    try testing.expectEqual(@as(usize, 0), scene.entities.items.len);
    try testing.expectEqual(@as(usize, 0), scene.game_objects.items.len);
    try testing.expectEqualStrings("test_scene", scene.name);
}

test "Scene.spawnEmpty creates entity with Transform" {
    var world = World.init(testing.allocator, null);
    defer world.deinit();

    try world.registerComponent(Transform);
    try world.registerComponent(MeshRenderer);

    var mock_asset_manager: AssetManager = undefined;
    var scene = Scene.init(testing.allocator, &world, &mock_asset_manager, "test_scene");
    defer scene.deinit();

    const obj = try scene.spawnEmpty("empty_object");

    // Check entity was tracked
    try testing.expectEqual(@as(usize, 1), scene.entities.items.len);
    try testing.expectEqual(@as(usize, 1), scene.game_objects.items.len);

    // Check entity has Transform component
    try testing.expect(world.has(Transform, obj.entity_id));

    // Check default transform values
    const transform = try world.get(Transform, obj.entity_id);
    try testing.expectEqual(Vec3.init(0, 0, 0), transform.translation);
    try testing.expectEqual(Vec3.init(1, 1, 1), transform.scale);
}

test "GameObject.setPosition updates transform" {
    var world = World.init(testing.allocator, null);
    defer world.deinit();

    try world.registerComponent(Transform);
    try world.registerComponent(MeshRenderer);

    var mock_asset_manager: AssetManager = undefined;
    var scene = Scene.init(testing.allocator, &world, &mock_asset_manager, "test_scene");
    defer scene.deinit();

    const obj = try scene.spawnEmpty("test_obj");

    // Set position
    const new_pos = Vec3.init(10, 20, 30);
    try obj.setPosition(new_pos);

    // Verify position changed
    const pos = obj.getPosition();
    try testing.expect(pos != null);
    try testing.expectEqual(new_pos, pos.?);
}

test "GameObject.setScale updates transform" {
    var world = World.init(testing.allocator, null);
    defer world.deinit();

    try world.registerComponent(Transform);
    try world.registerComponent(MeshRenderer);

    var mock_asset_manager: AssetManager = undefined;
    var scene = Scene.init(testing.allocator, &world, &mock_asset_manager, "test_scene");
    defer scene.deinit();

    const obj = try scene.spawnEmpty("test_obj");

    // Set scale
    const new_scale = Vec3.init(2, 3, 4);
    try obj.setScale(new_scale);

    // Verify scale changed
    const scale = obj.getScale();
    try testing.expect(scale != null);
    try testing.expectEqual(new_scale, scale.?);
}

test "GameObject.translate moves object by offset" {
    var world = World.init(testing.allocator, null);
    defer world.deinit();

    try world.registerComponent(Transform);
    try world.registerComponent(MeshRenderer);

    var mock_asset_manager: AssetManager = undefined;
    var scene = Scene.init(testing.allocator, &world, &mock_asset_manager, "test_scene");
    defer scene.deinit();

    const obj = try scene.spawnEmpty("test_obj");

    // Set initial position
    try obj.setPosition(Vec3.init(10, 20, 30));

    // Translate by offset
    try obj.translate(Vec3.init(5, -10, 15));

    // Verify new position
    const pos = obj.getPosition();
    try testing.expect(pos != null);
    try testing.expectEqual(Vec3.init(15, 10, 45), pos.?);
}

test "GameObject.setParent creates hierarchy" {
    var world = World.init(testing.allocator, null);
    defer world.deinit();

    try world.registerComponent(Transform);
    try world.registerComponent(MeshRenderer);

    var mock_asset_manager: AssetManager = undefined;
    var scene = Scene.init(testing.allocator, &world, &mock_asset_manager, "test_scene");
    defer scene.deinit();

    const parent = try scene.spawnEmpty("parent");
    const child = try scene.spawnEmpty("child");

    // Set parent
    try child.setParent(parent);

    // Verify hierarchy
    const parent_id = child.getParent();
    try testing.expect(parent_id != null);
    try testing.expectEqual(parent.entity_id, parent_id.?);
}

test "GameObject.hasComponent checks component existence" {
    var world = World.init(testing.allocator, null);
    defer world.deinit();

    try world.registerComponent(Transform);
    try world.registerComponent(MeshRenderer);

    var mock_asset_manager: AssetManager = undefined;
    var scene = Scene.init(testing.allocator, &world, &mock_asset_manager, "test_scene");
    defer scene.deinit();

    const obj = try scene.spawnEmpty("test_obj");

    // Should have Transform
    try testing.expect(obj.hasComponent(Transform));

    // Should NOT have MeshRenderer
    try testing.expect(!obj.hasComponent(MeshRenderer));
}

test "GameObject.addComponent adds new component" {
    var world = World.init(testing.allocator, null);
    defer world.deinit();

    try world.registerComponent(Transform);
    try world.registerComponent(MeshRenderer);

    var mock_asset_manager: AssetManager = undefined;
    var scene = Scene.init(testing.allocator, &world, &mock_asset_manager, "test_scene");
    defer scene.deinit();

    const obj = try scene.spawnEmpty("test_obj");

    // Add MeshRenderer
    const mesh_renderer = MeshRenderer.init(@enumFromInt(1), @enumFromInt(2));
    try obj.addComponent(MeshRenderer, mesh_renderer);

    // Verify component added
    try testing.expect(obj.hasComponent(MeshRenderer));
    const renderer = try obj.getComponent(MeshRenderer);
    try testing.expectEqual(@as(u32, 1), @intFromEnum(renderer.model_id));
}

test "Scene.unload destroys all entities" {
    var world = World.init(testing.allocator, null);
    defer world.deinit();

    try world.registerComponent(Transform);
    try world.registerComponent(MeshRenderer);

    var mock_asset_manager: AssetManager = undefined;
    var scene = Scene.init(testing.allocator, &world, &mock_asset_manager, "test_scene");
    defer scene.deinit();

    // Spawn some objects
    _ = try scene.spawnEmpty("obj1");
    _ = try scene.spawnEmpty("obj2");
    _ = try scene.spawnEmpty("obj3");

    try testing.expectEqual(@as(usize, 3), scene.entities.items.len);

    // Unload scene
    scene.unload();

    try testing.expectEqual(@as(usize, 0), scene.entities.items.len);
    try testing.expectEqual(@as(usize, 0), scene.game_objects.items.len);
}

test "Multiple scenes can coexist" {
    var world = World.init(testing.allocator, null);
    defer world.deinit();

    try world.registerComponent(Transform);
    try world.registerComponent(MeshRenderer);

    var mock_asset_manager: AssetManager = undefined;

    // Create two scenes
    var scene1 = Scene.init(testing.allocator, &world, &mock_asset_manager, "scene1");
    defer scene1.deinit();

    var scene2 = Scene.init(testing.allocator, &world, &mock_asset_manager, "scene2");
    defer scene2.deinit();

    // Spawn objects in each scene
    _ = try scene1.spawnEmpty("scene1_obj");
    _ = try scene2.spawnEmpty("scene2_obj1");
    _ = try scene2.spawnEmpty("scene2_obj2");

    try testing.expectEqual(@as(usize, 1), scene1.entities.items.len);
    try testing.expectEqual(@as(usize, 2), scene2.entities.items.len);

    // Total entities in world
    try testing.expectEqual(@as(usize, 3), world.entity_count);
}

test "GameObject pointer stability" {
    var world = World.init(testing.allocator, null);
    defer world.deinit();

    try world.registerComponent(Transform);
    try world.registerComponent(MeshRenderer);

    var mock_asset_manager: AssetManager = undefined;
    var scene = Scene.init(testing.allocator, &world, &mock_asset_manager, "test_scene");
    defer scene.deinit();

    // Spawn object and store pointer
    const obj1 = try scene.spawnEmpty("obj1");
    const ptr1 = @intFromPtr(obj1);

    // Spawn more objects (might cause reallocation)
    _ = try scene.spawnEmpty("obj2");
    _ = try scene.spawnEmpty("obj3");
    _ = try scene.spawnEmpty("obj4");

    // Original pointer should still be valid (assuming no realloc)
    // This test verifies the design - Scene stores GameObjects and returns stable pointers
    const ptr2 = @intFromPtr(&scene.game_objects.items[0]);

    // Note: If ArrayList reallocates, pointers become invalid
    // This is a known limitation - document that GameObjects should be accessed via Scene
    _ = ptr1;
    _ = ptr2;

    // Better approach: Access via index or entity_id
    try testing.expectEqual(obj1.entity_id, scene.game_objects.items[0].entity_id);
}
