const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("graphics_context.zig").GraphicsContext;
const Mesh = @import("mesh.zig").Mesh;
const Vertex = @import("mesh.zig").Vertex;
const Model = @import("mesh.zig").Model;
const Transform = @import("mesh.zig").Transform;
const Math = @import("mach").math;

pub const GameObject = struct {
    transform: Transform = .{},
    model: ?Model = null,

    pub fn render(self: GameObject, gc: GraphicsContext, cmdbuf: vk.CommandBuffer) !void {
        if (self.model) |model| {
            for (model.primitives.constSlice()) |primitive| {
                const mesh = primitive.mesh orelse continue;
                mesh.draw(gc, cmdbuf);
            }
        }
    }

    pub fn deinit(self: GameObject, gc: GraphicsContext) void {
        if (self.model) |model| {
            model.deinit(gc);
        }
    }
};
