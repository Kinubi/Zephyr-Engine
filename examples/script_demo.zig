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

    // Pre-warm a single lua_State so the same state is reused between calls.
    try runner.setupLuaStatePool(1);

    // Create an ActionQueue to receive main-thread-deliverable script results
    var aq = try ActionQueue.init(allocator);
    defer aq.deinit();

    runner.setResultQueue(&aq);

    // Scripts that mutate and then read a global `x` to verify state preservation.
    const script_inc = "if x == nil then x = 0 end\nx = x + 1";
    const script_read = "print(\"reading x\")\nreturn x + 1";

    // We need to pass some ctx pointer; use a small local dummy value for demo.
    var dummy: u8 = 0;
    const ctx_ptr: *anyopaque = @ptrCast(&dummy);

    // Enqueue first script to increment x
    _ = try runner.enqueueScript(script_inc, ctx_ptr, null, zephyr.Entity.invalid, null);
    const act1 = aq.pop();
    std.debug.print("Script 1 finished: id={} success={}\n", .{ act1.id, act1.success });
    if (act1.message) |m| {
        std.debug.print("Message1: {s}\n", .{m});
        const tmp: [*]const u8 = @ptrCast(m.ptr);
        const msg_slice: []u8 = @constCast(tmp)[0..m.len];
        allocator.free(msg_slice);
    }

    // Enqueue second script that returns x
    _ = try runner.enqueueScript(script_read, ctx_ptr, null, zephyr.Entity.invalid, null);
    const act2 = aq.pop();
    std.debug.print("Script 2 finished: id={} success={}\n", .{ act2.id, act2.success });
    if (act2.message) |m| {
        std.debug.print("Message2 (returned x): {s}\n", .{m});
        const tmp2: [*]const u8 = @ptrCast(m.ptr);
        const msg_slice2: []u8 = @constCast(tmp2)[0..m.len];
        allocator.free(msg_slice2);
    }
}
