const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("graphics_context.zig").GraphicsContext;
const Transform = @import("mesh.zig").Transform;
const Math = @import("utils/math.zig");
const PointLightComponent = @import("components.zig").PointLightComponent;
const Model = @import("mesh.zig").Model;

pub const GameObject = struct {
    transform: Transform = .{},
    model: ?*Model = null, // Now references a Model, not geometries
    point_light: ?PointLightComponent = null,

    pub fn render(self: GameObject, gc: GraphicsContext, cmdbuf: vk.CommandBuffer) !void {
        if (self.model) |model| {
            for (model.meshes.items) |mesh| {
                mesh.geometry.vertex_buffer.bind(gc, cmdbuf);
                mesh.geometry.index_buffer.bind(gc, cmdbuf);
                if (mesh.geometry.index_count > 0) {
                    gc.vkd.cmdDrawIndexed(cmdbuf, mesh.geometry.index_count, 1, 0, 0, 0);
                } else {
                    // Fallback: draw non-indexed
                }
            }
        }
    }

    pub fn deinit(self: GameObject, allocator: std.mem.Allocator) void {
        if (self.model) |model| {
            model.deinit(allocator);
        }
    }
};
