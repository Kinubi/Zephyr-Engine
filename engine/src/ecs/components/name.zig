const std = @import("std");

/// Name component for identifying entities
/// Used for debugging, editor UI, and entity queries by name
pub const Name = struct {
    /// Entity name (owned string)
    name: []const u8,
    
    /// Create name component with owned copy of string
    pub fn init(allocator: std.mem.Allocator, name: []const u8) !Name {
        const owned_name = try allocator.dupe(u8, name);
        return Name{ .name = owned_name };
    }
    
    /// Create name component from string literal (no allocation)
    pub fn initStatic(name: []const u8) Name {
        return Name{ .name = name };
    }
    
    /// Free owned string
    pub fn deinit(self: *Name, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};
