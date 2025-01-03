const std = @import("std");
const Window = @import("window.zig").Window;

pub fn main() !void {
    const window = try Window.init(.{});
    while (window.isRunning()) {}
}
