const std = @import("std");
const zephyr = @import("zephyr");
const ScriptRunner = zephyr.ScriptRunner;
const ActionQueue = zephyr.ActionQueue;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Initialize engine ThreadPool and start a small number of workers
    var tp_ptr = try allocator.create(zephyr.ThreadPool);
    tp_ptr.* = try zephyr.ThreadPool.init(allocator, 2);
    try tp_ptr.start(1);
    defer {
        // Ensure pool is deinitialized after runner and example cleanup
        tp_ptr.deinit();
        allocator.destroy(tp_ptr);
    }

    var runner = try ScriptRunner.init(allocator, tp_ptr);
    defer runner.deinit();

    // Pre-warm a single lua_State
    try runner.setupLuaStatePool(1);

    // Create an ActionQueue to receive main-thread-deliverable script results
    var aq = try ActionQueue.init(allocator);
    defer aq.deinit();

    runner.setResultQueue(&aq);

    const script = "print(\"Hello from Lua\")\nreturn 2+2";

    // We need to pass some ctx pointer; use a small local dummy value for demo.
    var dummy: u8 = 0;
    const ctx_ptr: *anyopaque = @ptrCast(&dummy);

    // Enqueue script (no worker-thread callback — result will be delivered via ActionQueue)
    _ = try runner.enqueueScript(script, ctx_ptr, null);

    // Pop the action on the main thread (blocking)
    const act = aq.pop();
    std.debug.print("Script finished: id={} success={}\n", .{ act.id, act.success });
    if (act.message) |m| {
        std.debug.print("Message: {s}\n", .{m});
        // Free the allocator-owned message
        const tmp: [*]const u8 = @ptrCast(m.ptr);
        const msg_slice: []u8 = @constCast(tmp)[0..m.len];
        allocator.free(msg_slice);
    }
}
