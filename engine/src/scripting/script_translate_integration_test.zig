const std = @import("std");
const testing = std.testing;
const zephyr = @import("zephyr");
const World = zephyr.World;
const Transform = zephyr.Transform;
const ScriptComponent = zephyr.ScriptComponent;
const Scene = zephyr.Scene;
const ThreadPool = zephyr.ThreadPool;

test "Script translate integration: script moves entity via translate_entity" {
    const allocator = testing.allocator;

    var world = World.init(allocator, null);
    defer world.deinit();

    try world.registerComponent(Transform);
    try world.registerComponent(ScriptComponent);

    var mock_asset_manager: @import("../assets/asset_manager.zig").AssetManager = undefined;

    // Create a small ThreadPool for the test (required by Scene.init and scripting)
    var tp_ptr = try allocator.create(ThreadPool);
    tp_ptr.* = try ThreadPool.init(allocator, 1);
    try tp_ptr.start(1);
    defer {
        tp_ptr.deinit();
        allocator.destroy(tp_ptr);
    }

    var scene = try Scene.init(allocator, &world, &mock_asset_manager, tp_ptr, "test_scene_translate");
    defer scene.deinit();

    // Spawn an empty object with Transform
    const obj = try scene.spawnEmpty("movable");

    // Enqueue a script that calls translate_entity to move by +1 in X
    const script = "translate_entity(1.0, 0.0, 0.0)";

    var dummy_ctx: u8 = 0;
    const ctx_ptr: *anyopaque = @ptrCast(&dummy_ctx);

    _ = try scene.scripting_system.runScript(script, ctx_ptr, obj.entity_id, @ptrCast(&scene));

    // Wait for action (blocking pop)
    const act = scene.scripting_system.action_queue.pop();
    try testing.expect(act.success == true);

    // After script finished, transform should have moved by +1 in X
    const t = try world.get(Transform, obj.entity_id);
    try testing.expectEqual(1.0, t.translation.x);
}
