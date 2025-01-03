const std = @import("std");
const Window = @import("window.zig").Window;
const glfw = @import("mach-glfw");
const Pipeline = @import("pipeline.zig").Pipeline;
const simple_vert = @embedFile("simple_vert");
const simple_frag = @embedFile("simple_frag");

pub const App = struct {
    window: Window = undefined,
    var simple_pipeline: ?Pipeline = undefined;

    pub fn init(self: *@This()) !void {
        self.window = try Window.init(.{});
        simple_pipeline = try Pipeline.init(self.window.gc, null, simple_vert, simple_frag, Pipeline.defaultLayout(self.window.gc));
    }

    pub fn onUpdate(self: @This()) bool {
        return self.window.isRunning();
    }

    pub fn deinit(self: @This()) void {
        self.window.deinit();
    }
};
