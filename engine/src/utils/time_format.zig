const std = @import("std");

/// Utility functions for formatting timestamps as human-readable strings (UTC).
///
/// All functions are pure and do not mutate global state.
/// Converts a millisecond timestamp (since epoch) to a formatted string: dd/mm/yyyy hh:mm:ss (UTC).
///
/// Allocates a new string using the provided allocator.
///
/// - allocator: The allocator to use for the output string.
/// - ms_since_epoch: Milliseconds since the Unix epoch (UTC).
///
/// Returns: Allocated string with formatted timestamp, or an error if allocation fails.
pub fn formatTimestamp(
    allocator: std.mem.Allocator,
    ms_since_epoch: i64,
) ![]u8 {
    const seconds: i64 = @divTrunc(ms_since_epoch, 1000);
    const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = @as(u64, @intCast(seconds)) };
    const epoch_day: std.time.epoch.EpochDay = epoch_seconds.getEpochDay();
    const day_seconds: std.time.epoch.DaySeconds = epoch_seconds.getDaySeconds();
    const year_and_day: std.time.epoch.YearAndDay = epoch_day.calculateYearDay();
    const month_and_day: std.time.epoch.MonthAndDay = year_and_day.calculateMonthDay();
    return std.fmt.allocPrint(
        allocator,
        "{d:0>2}/{d:0>2}/{d:0>4} {d:0>2}:{d:0>2}:{d:0>2}",
        .{
            @as(u32, month_and_day.day_index + 1), // day is 0-based
            @as(u32, @intFromEnum(month_and_day.month)), // month is 1-based
            @as(u16, year_and_day.year),
            @as(u32, day_seconds.getHoursIntoDay()),
            @as(u32, day_seconds.getMinutesIntoHour()),
            @as(u32, day_seconds.getSecondsIntoMinute()),
        },
    );
}

/// Formats a millisecond timestamp (since epoch) to dd/mm/yyyy hh:mm:ss (UTC) into a provided buffer.
///
/// - buf: The buffer to write the formatted string into.
/// - ms_since_epoch: Milliseconds since the Unix epoch (UTC).
///
/// Returns: Slice of the buffer containing the formatted timestamp, or an error if the buffer is too small.
pub fn formatTimestampBuf(
    buf: []u8,
    ms_since_epoch: i64,
) ![]u8 {
    const seconds: i64 = @divTrunc(ms_since_epoch, 1000);
    const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = @as(u64, @intCast(seconds)) };
    const epoch_day: std.time.epoch.EpochDay = epoch_seconds.getEpochDay();
    const day_seconds: std.time.epoch.DaySeconds = epoch_seconds.getDaySeconds();
    const year_and_day: std.time.epoch.YearAndDay = epoch_day.calculateYearDay();
    const month_and_day: std.time.epoch.MonthAndDay = year_and_day.calculateMonthDay();
    return std.fmt.bufPrint(
        buf,
        "{d:0>2}/{d:0>2}/{d:0>4} {d:0>2}:{d:0>2}:{d:0>2}",
        .{
            @as(u32, month_and_day.day_index + 1),
            @as(u32, @intFromEnum(month_and_day.month)),
            @as(u16, year_and_day.year),
            @as(u32, day_seconds.getHoursIntoDay()),
            @as(u32, day_seconds.getMinutesIntoHour()),
            @as(u32, day_seconds.getSecondsIntoMinute()),
        },
    );
}
