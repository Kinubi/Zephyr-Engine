const std = @import("std");
const Window = @import("window.zig").Window;
const App = @import("app.zig").App;

pub fn main() !void {
    var app = App{};
    const allocator = std.heap.page_allocator;

    try app.init(allocator);
    defer app.deinit();
    var i: u32 = 0;
    while (try app.onUpdate()) {
        std.debug.print("i: {}", .{i});
        if (i == 1)
            break;
        i += 1;
    }
}
