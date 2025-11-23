const std = @import("std");

/// UUID Component for stable entity identification across sessions
/// Uses UUID v4 (random)
pub const UuidComponent = struct {
    bytes: [16]u8,

    /// Generate a new random UUID v4
    pub fn init() UuidComponent {
        var uuid = UuidComponent{ .bytes = undefined };
        std.crypto.random.bytes(&uuid.bytes);

        // Set version to 4 (0100)
        uuid.bytes[6] = (uuid.bytes[6] & 0x0f) | 0x40;
        // Set variant to RFC 4122 (10xx)
        uuid.bytes[8] = (uuid.bytes[8] & 0x3f) | 0x80;

        return uuid;
    }

    /// Create from existing bytes
    pub fn fromBytes(bytes: [16]u8) UuidComponent {
        return .{ .bytes = bytes };
    }

    /// Parse from standard UUID string (36 chars with hyphens)
    /// e.g. "550e8400-e29b-41d4-a716-446655440000"
    pub fn fromString(str: []const u8) !UuidComponent {
        if (str.len != 36) return error.InvalidUuidFormat;

        var bytes: [16]u8 = undefined;
        var hex_buf: [32]u8 = undefined;
        var hex_idx: usize = 0;

        for (str) |c| {
            if (c != '-') {
                if (hex_idx >= 32) return error.InvalidUuidFormat;
                hex_buf[hex_idx] = c;
                hex_idx += 1;
            }
        }

        if (hex_idx != 32) return error.InvalidUuidFormat;

        _ = try std.fmt.hexToBytes(&bytes, &hex_buf);
        return .{ .bytes = bytes };
    }

    /// Format as string
    pub fn format(
        self: UuidComponent,
        writer: anytype,
    ) !void {
        // 8-4-4-4-12 format
        try writer.print("{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
            self.bytes[0],  self.bytes[1],  self.bytes[2],  self.bytes[3],
            self.bytes[4],  self.bytes[5],  self.bytes[6],  self.bytes[7],
            self.bytes[8],  self.bytes[9],  self.bytes[10], self.bytes[11],
            self.bytes[12], self.bytes[13], self.bytes[14], self.bytes[15],
        });
    }

    /// Check equality
    pub fn eql(self: UuidComponent, other: UuidComponent) bool {
        return std.mem.eql(u8, &self.bytes, &other.bytes);
    }
};
