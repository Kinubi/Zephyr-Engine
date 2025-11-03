const std = @import("std");
const time_format = @import("time_format.zig");

pub const LogLevel = enum { TRACE, DEBUG, INFO, WARN, ERROR };

/// Internal fixed-size buffers to avoid allocations from arbitrary threads.
const LOG_BUFFER_CAP: usize = 1024; // Ring buffer size
const LOG_SECTION_CAP: usize = 64;
const LOG_MESSAGE_CAP: usize = 512;

pub const LogOut = struct {
    level: LogLevel,
    timestamp: i64,
    section_len: usize,
    section: [LOG_SECTION_CAP]u8,
    message_len: usize,
    message: [LOG_MESSAGE_CAP]u8,
};

pub const LogRingBuffer = struct {
    entries: [LOG_BUFFER_CAP]LogOut,
    head: usize,
    count: usize,
    mutex: std.Thread.Mutex,

    pub fn init(self: *LogRingBuffer) void {
        self.head = 0;
        self.count = 0;
        // Initialize mutex
        self.mutex = std.Thread.Mutex{};
    }

    pub fn push(self: *LogRingBuffer, entry: LogOut) void {
        _ = self.mutex.lock();
        defer self.mutex.unlock();

        const idx = (self.head + self.count) % LOG_BUFFER_CAP;
        self.entries[idx] = entry;
        if (self.count < LOG_BUFFER_CAP) {
            self.count += 1;
        } else {
            // Buffer full: advance head so we overwrite oldest
            self.head = (self.head + 1) % LOG_BUFFER_CAP;
        }
    }

    /// Copy up to dest.len entries into dest in chronological order (oldest->newest).
    pub fn fetch(self: *LogRingBuffer, dest: []LogOut) usize {
        _ = self.mutex.lock();
        defer self.mutex.unlock();

        const to_copy = if (dest.len < self.count) dest.len else self.count;
        var out_i: usize = 0;
        while (out_i < to_copy) : (out_i += 1) {
            const src_idx = (self.head + out_i) % LOG_BUFFER_CAP;
            dest[out_i] = self.entries[src_idx];
        }
        return to_copy;
    }
};

var log_ring: ?*LogRingBuffer = null;

/// Initialize the optional in-memory log buffer (call from editor startup)
pub fn initLogRingBuffer() void {
    if (log_ring != null) return;
    // Use a static buffer so we don't need allocator lifetime management here
    // Allocate once on the global allocator (statically owned for lifetime of process)
    const g_alloc = std.heap.page_allocator;
    const mem = g_alloc.alloc(LogRingBuffer, 1) catch return;
    mem[0].init();
    log_ring = &mem[0];
}

/// Fetch recent logs into the provided destination array. Returns number copied.
pub fn fetchLogs(dest: []LogOut) usize {
    if (log_ring == null) return 0;
    return log_ring.?.fetch(dest);
}

/// Clear the in-memory log ring buffer (drops all stored entries).
pub fn clearLogs() void {
    if (log_ring == null) return;
    const rb = log_ring.?;
    _ = rb.mutex.lock();
    defer rb.mutex.unlock();
    rb.head = 0;
    rb.count = 0;
}

/// Logs a message with a timestamp, log level, and section.
/// Also forwards the message to the optional in-memory ring buffer.
pub fn log(
    level: LogLevel,
    section: []const u8,
    comptime fmt: []const u8,
    args: anytype,
) void {
    const now = std.time.milliTimestamp();
    var buf: [64]u8 = undefined; // For timestamp formatting
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
    // Print to stdout as before
    std.debug.print("[{s}] [{s}] [{s}] ", .{ timestamp, level_str, section });
    std.debug.print(fmt, args);
    std.debug.print("\n", .{});

    // If ring buffer initialized, push a copy into it (truncate to capacities)
    if (log_ring) |rb| {
        var e: LogOut = undefined;
        e.level = level;
        e.timestamp = now;

        // copy section
        const slen: usize = @min(section.len, LOG_SECTION_CAP - 1);
        std.mem.copyForwards(u8, e.section[0..slen], section[0..slen]);
        e.section_len = slen;
        if (slen < LOG_SECTION_CAP) e.section[slen] = 0;

        // format message into temporary buffer then copy/truncate
        var tmp: [LOG_MESSAGE_CAP]u8 = undefined;
        const msg_slice = std.fmt.bufPrint(&tmp, fmt, args) catch "(format error)";
        const mlen: usize = @min(msg_slice.len, LOG_MESSAGE_CAP - 1);
        std.mem.copyForwards(u8, e.message[0..mlen], msg_slice[0..mlen]);
        e.message_len = mlen;
        if (mlen < LOG_MESSAGE_CAP) e.message[mlen] = 0;

        rb.push(e);
    }
}
