const std = @import("std");
const cvar = @import("../engine/src/core/cvar.zig");

fn my_cb(name: []const u8, old: []const u8, new: []const u8) void {
    const stdout = std.io.getStdOut().writer();
    _ = stdout.print("native callback invoked for '{}' old='{}' new='{}'\n", .{ name, old, new });
}

pub fn main() !void {
    const alloc = std.heap.page_allocator;
    const reg = try cvar.ensureGlobal(alloc);

    // register a test cvar with native callback
    try reg.registerCVar("test.native", cvar.CVarType.String, "initial", "test cvar", cvar.CVarFlags{}, null, null, null, null, &my_cb);

    // set to new value (this appends to pending_changes)
    try reg.setFromString("test.native", "updated");

    // now process pending changes synchronously (this will call native callbacks)
    try reg.processPendingChanges();

    std.debug.print("done\n", .{});
}
