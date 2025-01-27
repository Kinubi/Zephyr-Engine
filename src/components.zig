const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("graphics_context.zig").GraphicsContext;
const Mesh = @import("mesh.zig").Mesh;
const Vertex = @import("mesh.zig").Vertex;
const Model = @import("mesh.zig").Model;
const Transform = @import("mesh.zig").Transform;
const Math = @import("mach").math;

pub const PointLightComponent = struct {
    color: Math.Vec3 = Math.Vec3.init(1.0, 1.0, 1.0),
    intensity: f32 = 1.0,
};
