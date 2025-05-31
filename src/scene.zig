const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("graphics_context.zig").GraphicsContext;
const Mesh = @import("mesh.zig").Mesh;
const Model = @import("mesh.zig").Model;
const Math = @import("utils/math.zig");
const GameObject = @import("game_object.zig").GameObject;
const PointLightComponent = @import("components.zig").PointLightComponent;
const fromMesh = @import("mesh.zig").fromMesh;

pub const Scene = struct {
    objects: std.BoundedArray(GameObject, 1024),

    pub fn init() Scene {
        return Scene{
            .objects = .{},
        };
    }

    pub fn deinit(self: *Scene, allocator: std.mem.Allocator) void {
        std.debug.print("Deinitializing Scene with {any} objects\n", .{self.objects.constSlice().len});
        for (self.objects.constSlice()) |object| {
            object.deinit(allocator);
        }
    }

    pub fn addEmpty(self: *Scene) !*GameObject {
        const object = try self.objects.addOne();
        object.* = .{ .model = null };
        return object;
    }

    pub fn addObject(self: *Scene, model: ?*Model, point_light: ?PointLightComponent) !*GameObject {
        const object = try self.objects.addOne();
        object.* = .{
            .model = if (model) |m| m else null,
            .point_light = point_light,
        };
        return object;
    }

    pub fn addModelFromMesh(self: *Scene, allocator: std.mem.Allocator, mesh: *Mesh, gc: *GraphicsContext, name: []const u8, transform: ?Math.Vec3) !*GameObject {
        const model = try fromMesh(allocator, mesh, gc, name);
        const object = try self.addObject(model, null);
        if (transform) |t| {
            object.transform.translate(t);
        }
        return object;
    }

    pub fn addModel(self: *Scene, allocator: std.mem.Allocator, model: Model, point_light: ?PointLightComponent) !*GameObject {
        // Heap-allocate the model internally
        const model_ptr = try allocator.create(Model);
        model_ptr.* = model;
        const object = try self.addObject(model_ptr, point_light);
        return object;
    }

    pub fn render(self: Scene, gc: GraphicsContext, cmdbuf: vk.CommandBuffer) !void {
        for (self.objects.constSlice()) |object| {
            try object.render(gc, cmdbuf);
        }
    }
};
