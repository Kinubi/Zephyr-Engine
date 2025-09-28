const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("../core/graphics_context.zig").GraphicsContext;
const Transform = @import("../rendering/mesh.zig").Transform;
const Math = @import("../utils/math.zig");
const PointLightComponent = @import("components.zig").PointLightComponent;
const Model = @import("../rendering/mesh.zig").Model;

pub const GameObject = struct {
    transform: Transform = .{},
    model: ?*Model = null, // Now references a Model, not geometries
    point_light: ?PointLightComponent = null,

    pub fn render(self: GameObject, gc: GraphicsContext, cmdbuf: vk.CommandBuffer) !void {
        if (self.model) |model| {
            for (model.meshes.items) |mesh| {
                // Use the mesh's draw method which handles binding
                mesh.geometry.mesh.draw(gc, cmdbuf);
            }
        }
    }

    pub fn deinit(self: GameObject) void {
        if (self.model) |model| {
            model.deinit();
        }
    }
};
