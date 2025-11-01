const std = @import("std");
const zephyr = @import("zephyr");
const ScriptRunner = zephyr.ScriptRunner;
const ActionQueue = zephyr.ActionQueue;
const EntityId = @import("../ecs/entity_registry.zig").EntityId;

test "ScriptRunner + StatePool integration" {
    const allocator = std.heap.page_allocator;

    var tp_ptr = try allocator.create(zephyr.ThreadPool);
    tp_ptr.* = try zephyr.ThreadPool.init(allocator, 2);
    try tp_ptr.start(1);
    defer {
        tp_ptr.deinit();
        allocator.destroy(tp_ptr);
    }

    var runner = try ScriptRunner.init(allocator, tp_ptr);
    defer runner.deinit();

    try runner.setupLuaStatePool(1);

    var aq = try ActionQueue.init(allocator);
    defer aq.deinit();

    runner.setResultQueue(&aq);

    const script_inc = "if x == nil then x = 0 end\nx = x + 1";
    const script_read = "return x";

    // Enqueue increment
    var dummy_ctx: u8 = 0;
    const ctx_ptr: *anyopaque = @ptrCast(&dummy_ctx);
    _ = try runner.enqueueScript(script_inc, ctx_ptr, null, EntityId.invalid, null);
    _ = aq.pop(); // discard first result

    // Enqueue read
    _ = try runner.enqueueScript(script_read, ctx_ptr, null, EntityId.invalid, null);
    const act = aq.pop();

    try std.testing.expect(act.success == true);
    if (act.message) |m| {
        // Convert returned string to integer and check equals 1
        const parsed = std.fmt.parseInt(i64, m, 10) catch 0;
        try std.testing.expect(parsed == 1);
        // free message
        const tmp: [*]const u8 = @ptrCast(m.ptr);
        const msg_slice: []u8 = @constCast(tmp)[0..m.len];
        allocator.free(msg_slice);
    } else {
        try std.testing.expect(false);
    }
}
