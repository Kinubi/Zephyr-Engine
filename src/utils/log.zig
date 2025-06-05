const std = @import("std");
const time_format = @import("time_format.zig");

pub const LogLevel = enum { TRACE, DEBUG, INFO, WARN, ERROR };

/// Logs a message with a timestamp, log level, and section.
pub fn log(
    level: LogLevel,
    section: []const u8,
    comptime fmt: []const u8,
    args: anytype,
) void {
    const now = std.time.milliTimestamp();
    var buf: [32]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const allocator = fba.allocator();
    var timestamp: []const u8 = "<bad time>";
    if (time_format.formatTimestamp(allocator, now)) |ts| {
        timestamp = ts;
    } else |_| {}
    const level_str = switch (level) {
        .TRACE => "TRACE",
        .DEBUG => "DEBUG",
        .INFO => "INFO",
        .WARN => "WARN",
        .ERROR => "ERROR",
    };
    std.debug.print("[{s}] [{s}] [{s}] ", .{ timestamp, level_str, section });
    std.debug.print(fmt, args);
    std.debug.print("\n", .{});
}
