const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("graphics_context.zig").GraphicsContext;
const Mesh = @import("mesh.zig").Mesh;
const Vertex = @import("mesh.zig").Vertex;
const GameObject = @import("game_object.zig").GameObject;
const Model = @import("mesh.zig").Model;
const Math = @import("mach").math;

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

    pub fn addObject(self: *Scene, model: Model) !*GameObject {
        const object = try self.objects.addOne();
        object.* = .{ .model = model };
        return object;
    }

    pub fn render(self: Scene, gc: GraphicsContext, cmdbuf: vk.CommandBuffer) !void {
        for (self.objects.constSlice()) |object| {
            try object.render(gc, cmdbuf);
        }
    }
};
