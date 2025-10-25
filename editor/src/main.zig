const App = @import("editor_app.zig").App;

pub fn main() !void {
    var app = App{};

    try app.init();
    defer app.deinit();

    while (try app.update()) {}
}
