const std = @import("std");
const Window = @import("window.zig").Window;
const App = @import("app.zig").App;

pub fn main() !void {
    var app = App{};
    const allocator = std.heap.page_allocator;

    try app.init(allocator);
    defer app.deinit();
    while (app.onUpdate()) {}
}
