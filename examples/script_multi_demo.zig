const std = @import("std");
const zephyr = @import("zephyr");
const ScriptRunner = zephyr.ScriptRunner;
const ActionQueue = zephyr.ActionQueue;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Initialize engine ThreadPool and start a small number of workers
    var tp_ptr = try allocator.create(zephyr.ThreadPool);
    tp_ptr.* = try zephyr.ThreadPool.init(allocator, 4);
    try tp_ptr.start(2);
    defer {
        tp_ptr.deinit();
        allocator.destroy(tp_ptr);
    }

    var runner = try ScriptRunner.init(allocator, tp_ptr);
    defer runner.deinit();

    // Pre-warm a few lua_State instances (StatePool usage)
    try runner.setupLuaStatePool(4);

    var aq = try ActionQueue.init(allocator);
    defer aq.deinit();

    runner.setResultQueue(&aq);

    const NUM_JOBS: usize = 8;

    var ctxs: [NUM_JOBS]u8 = undefined;

    // Enqueue multiple scripts concurrently
    for (0..NUM_JOBS) |i| {
        // Allocate a small script that prints and returns a distinct value
        const script_buf = try std.fmt.allocPrint(allocator, "print(\"Hello from Lua job {d}\")\nreturn {d}", .{ i, i });
        const ctx_ptr: *anyopaque = @ptrCast(&ctxs[i]);

        _ = try runner.enqueueScript(script_buf, ctx_ptr, null);

        // Free the temporary script buffer we allocated for formatting; ScriptRunner copies it
        allocator.free(script_buf);
    }

    // Collect results on main thread
    var received: usize = 0;
    while (received < NUM_JOBS) {
        const act = aq.pop();
        std.debug.print("Script finished: id={} success={}\n", .{ act.id, act.success });
        if (act.message) |m| {
            std.debug.print("Message: {s}\n", .{m});
            // Free allocator-owned message slice
            const tmp: [*]const u8 = @ptrCast(m.ptr);
            const msg_slice: []u8 = @constCast(tmp)[0..m.len];
            allocator.free(msg_slice);
        }
        received += 1;
    }
}
