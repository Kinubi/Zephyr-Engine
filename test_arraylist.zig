const std = @import("std");
const CollisionEvent = struct { a: u32 };
pub fn main() void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var list = std.ArrayList(CollisionEvent).init(allocator);
    list.deinit();
}