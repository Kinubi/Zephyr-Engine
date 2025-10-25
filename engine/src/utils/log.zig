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
    var buf: [64]u8 = undefined; // Increased buffer size
    var timestamp: []const u8 = "<bad time>";

    // Use the buffer-based formatting function to avoid allocation issues
    if (time_format.formatTimestampBuf(&buf, now)) |ts| {
        timestamp = ts;
    } else |_| {
        // Fallback to simple millisecond timestamp if formatting fails
        timestamp = std.fmt.bufPrint(&buf, "{d}ms", .{now}) catch "<bad time>";
    }

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
