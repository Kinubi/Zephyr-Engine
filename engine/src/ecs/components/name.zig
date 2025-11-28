const std = @import("std");

/// Name component for identifying entities
/// Used for debugging, editor UI, and entity queries by name
pub const Name = struct {
    pub const json_name = "Name";
    /// Entity name (owned or static string)
    name: []const u8,
    /// Whether this name owns its string (needs freeing)
    owned: bool = true,

    /// Create name component with owned copy of string
    pub fn init(allocator: std.mem.Allocator, name: []const u8) !Name {
        const owned_name = try allocator.dupe(u8, name);
        return Name{ .name = owned_name, .owned = true };
    }

    /// Create name component from string literal (no allocation)
    pub fn initStatic(name: []const u8) Name {
        return Name{ .name = name, .owned = false };
    }

    /// Free owned string (only if we own it)
    pub fn deinit(self: *Name, allocator: std.mem.Allocator) void {
        if (self.owned) {
            allocator.free(self.name);
        }
    }

    /// Serialize Name component
    pub fn jsonSerialize(self: Name, serializer: anytype, writer: anytype) !void {
        _ = serializer;
        try writer.beginObject();
        try writer.objectField("name");
        try writer.write(self.name);
        try writer.endObject();
    }

    /// Deserialize Name component
    pub fn deserialize(serializer: anytype, value: std.json.Value) !Name {
        if (value.object.get("name")) |name_val| {
            if (name_val == .string) {
                return Name.init(serializer.allocator, name_val.string);
            }
        }
        return Name.init(serializer.allocator, "Entity");
    }
};
