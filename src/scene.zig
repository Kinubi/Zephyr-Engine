const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("graphics_context.zig").GraphicsContext;
const Mesh = @import("mesh.zig").Mesh;
const Vertex = @import("mesh.zig").Vertex;
const GameObject = @import("game_object.zig").GameObject;
const Model = @import("mesh.zig").Model;
const Math = @import("mach").math;
const PointLightComponent = @import("components.zig").PointLightComponent;

pub const Scene = struct {
    objects: std.BoundedArray(GameObject, 1024),

    pub fn init() Scene {
        return Scene{
            .objects = .{},
        };
    }

    pub fn deinit(self: *Scene, gc: GraphicsContext) void {
        for (self.objects.constSlice()) |object| {
            object.deinit(gc);
        }
    }

    pub fn addEmpty(self: *Scene) !*GameObject {
        const object = try self.objects.addOne();
        object.* = .{ .model = null };
        return object;
    }

    pub fn addObject(self: *Scene, model: ?Model, point_light: ?PointLightComponent) !*GameObject {
        const object = try self.objects.addOne();
        object.* = .{ .model = model, .point_light = point_light };
        return object;
    }

    pub fn render(self: Scene, gc: GraphicsContext, cmdbuf: vk.CommandBuffer) !void {
        for (self.objects.constSlice()) |object| {
            try object.render(gc, cmdbuf);
        }
    }
};
