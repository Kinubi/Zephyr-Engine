const std = @import("std");
const demo = @import("src/rendering/render_pass_demo.zig");

pub fn main() !void {
    std.log.info("Testing Week 1 Render Pass Architecture...", .{});
    try demo.testRenderPassArchitecture();
}
