const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("graphics_context.zig").GraphicsContext;
const Mesh = @import("mesh.zig").Mesh;
const Model = @import("mesh.zig").Model;
const Math = @import("utils/math.zig");
const GameObject = @import("game_object.zig").GameObject;
const PointLightComponent = @import("components.zig").PointLightComponent;
const fromMesh = @import("mesh.zig").fromMesh;
const Texture = @import("texture.zig").Texture;
const Buffer = @import("buffer.zig").Buffer;

pub const Material = extern struct {
    albedo_texture_id: u32 = 0, // 4 bytes
    roughness: f32 = 0.5, // 4 bytes
    metallic: f32 = 1.0, // 4 bytes
    emissive: f32 = 0.0, // 4 bytes
    emissive_color: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 }, // 16 bytes (vec4, even if you only use 3)
    // 32 bytes total, aligned to 16 bytes
};

pub const Scene = struct {
    objects: std.BoundedArray(GameObject, 1024),
    materials: std.ArrayList(Material),
    textures: std.ArrayList(Texture),
    material_buffer: ?*Buffer = null, // GPU buffer for materials
    texture_image_infos: []const vk.DescriptorImageInfo = &[_]vk.DescriptorImageInfo{},

    pub fn init(allocator: std.mem.Allocator) Scene {
        return Scene{
            .objects = .{},
            .materials = std.ArrayList(Material).init(allocator),
            .textures = std.ArrayList(Texture).init(allocator),
        };
    }

    pub fn deinit(self: *Scene, gc: GraphicsContext) void {
        std.debug.print("Deinitializing Scene with {any} objects\n", .{self.objects.constSlice().len});
        for (self.objects.constSlice()) |object| {
            object.deinit(gc);
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

    pub fn addModelFromMesh(self: *Scene, allocator: std.mem.Allocator, mesh: Mesh, name: []const u8, transform: ?Math.Vec3) !*GameObject {
        const model = try fromMesh(allocator, mesh, name);
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

    pub fn addTexture(self: *Scene, texture: Texture) !usize {
        try self.textures.append(texture);
        const index = self.textures.items.len - 1;
        return index;
    }

    pub fn addMaterial(self: *Scene, material: Material) !usize {
        try self.materials.append(material);
        const index = self.materials.items.len - 1;
        return index;
    }

    pub fn updateMaterialBuffer(self: *Scene, gc: *GraphicsContext, allocator: std.mem.Allocator) !void {
        if (self.materials.items.len == 0) return;
        if (self.material_buffer) |buf| {
            buf.deinit();
        }
        const buf = try allocator.create(Buffer);
        buf.* = try Buffer.init(
            gc,
            @sizeOf(Material),
            @as(u32, @intCast(self.materials.items.len)),
            .{
                .storage_buffer_bit = true,
            },
            .{ .host_visible_bit = true, .host_coherent_bit = true },
        );
        try buf.map(@sizeOf(Material) * self.materials.items.len, 0);
        std.debug.print("Updating material buffer with {any} materials\n", .{self.materials.items});
        buf.writeToBuffer(
            std.mem.sliceAsBytes(self.materials.items),
            @sizeOf(Material) * self.materials.items.len,
            0,
        );

        self.material_buffer = buf;
    }

    pub fn updateTextureImageInfos(self: *Scene, allocator: std.mem.Allocator) !void {
        if (self.textures.items.len == 0) {
            self.texture_image_infos = &[_]vk.DescriptorImageInfo{};
            return;
        }
        const infos = try allocator.alloc(vk.DescriptorImageInfo, self.textures.items.len);
        for (self.textures.items, 0..) |tex, i| {
            infos[i] = tex.descriptor;
        }
        self.texture_image_infos = infos;
    }

    pub fn render(self: Scene, gc: GraphicsContext, cmdbuf: vk.CommandBuffer) !void {
        for (self.objects.constSlice()) |object| {
            try object.render(gc, cmdbuf);
        }
    }
};
