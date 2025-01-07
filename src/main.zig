const std = @import("std");
const Window = @import("window.zig").Window;
const App = @import("app.zig").App;

pub fn main() !void {
    var app = App{};

    try app.init();
    defer app.deinit();

    while (try app.onUpdate()) {}
}
