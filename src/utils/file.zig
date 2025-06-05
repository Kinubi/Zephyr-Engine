const std = @import("std");

/// Loads a file from disk into a newly allocated buffer.
pub fn loadFileAlloc(allocator: std.mem.Allocator, path: []const u8, max_size: usize) ![]u8 {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    return try file.readToEndAlloc(allocator, max_size);
}
