const std = @import("std");

pub fn DenseSet(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        items: std.ArrayList(T),

        pub fn init(allocator: std.mem.Allocator) DenseSet(T) {
            return DenseSet(T){ .allocator = allocator, .items = std.ArrayList(T){} };
        }

        pub fn deinit(self: *DenseSet(T)) void {
            self.items.deinit(self.allocator);
        }

        pub fn emplace(self: *DenseSet(T), value: T) !void {
            try self.items.append(self.allocator, value);
        }

        pub fn len(self: *const DenseSet(T)) usize {
            return self.items.items.len;
        }

        pub fn asSlice(self: *DenseSet(T)) []T {
            return self.items.items;
        }
    };
}
