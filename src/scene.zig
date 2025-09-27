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
const loadFileAlloc = @import("utils/file.zig").loadFileAlloc;
const log = @import("utils/log.zig").log;
const LogLevel = @import("utils/log.zig").LogLevel;

pub const Material = extern struct {
    albedo_texture_id: u32 = 0, // 4 bytes
    roughness: f32 = 0.5, // 4 bytes
    metallic: f32 = 1.0, // 4 bytes
    emissive: f32 = 0.0, // 4 bytes
    emissive_color: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 }, // 16 bytes (vec4, even if you only use 3)
    // 32 bytes total, aligned to 16 bytes
};

pub const Scene = struct {
    objects: std.ArrayList(GameObject),
    materials: std.ArrayList(Material),
    textures: std.ArrayList(Texture),
    material_buffer: ?*Buffer = null, // GPU buffer for materials
    texture_image_infos: []const vk.DescriptorImageInfo = &[_]vk.DescriptorImageInfo{},
    gc: *GraphicsContext, // Store reference to GraphicsContext
    allocator: std.mem.Allocator, // Store allocator

    pub fn init(gc: *GraphicsContext, allocator: std.mem.Allocator) Scene {
        return Scene{
            .objects = std.ArrayList(GameObject){},
            .materials = std.ArrayList(Material){},
            .textures = std.ArrayList(Texture){},
            .gc = gc,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Scene) void {
        log(.INFO, "scene", "Deinitializing Scene with {d} objects", .{self.objects.items.len});
        // Deinit all objects (models/meshes)
        for (self.objects.items) |object| {
            object.deinit();
        }
        self.objects.deinit(self.allocator);
        // Deinit all textures
        log(.DEBUG, "scene", "Deinitializing {d} textures", .{self.textures.items.len});
        for (self.textures.items) |*tex| {
            tex.deinit();
        }
        self.textures.deinit(self.allocator);
        // Deinit material buffer if present
        if (self.material_buffer) |buf| {
            log(.DEBUG, "scene", "Deinitializing material buffer", .{});
            buf.deinit();
            self.allocator.destroy(buf);
            self.material_buffer = null;
        }
        // Free texture_image_infos if heap-allocated
        const static_empty_infos = &[_]vk.DescriptorImageInfo{};
        if (self.texture_image_infos.len > 0 and self.texture_image_infos.ptr != static_empty_infos.ptr) {
            log(.DEBUG, "scene", "Freeing texture_image_infos array", .{});
            self.allocator.free(self.texture_image_infos);
            self.texture_image_infos = static_empty_infos;
        }
        // Clear and deinit materials
        log(.DEBUG, "scene", "Clearing materials array", .{});
        self.materials.clearRetainingCapacity();
        self.materials.deinit(self.allocator);
        log(.INFO, "scene", "Scene deinit complete", .{});
    }

    pub fn addEmpty(self: *Scene) !*GameObject {
        try self.objects.append(self.allocator, .{ .model = null });
        return &self.objects.items[self.objects.items.len - 1];
    }

    pub fn addObject(self: *Scene, model: ?*Model, point_light: ?PointLightComponent) !*GameObject {
        try self.objects.append(self.allocator, .{
            .model = if (model) |m| m else null,
            .point_light = point_light,
        });
        return &self.objects.items[self.objects.items.len - 1];
    }

    pub fn addModelFromMesh(self: *Scene, mesh: Mesh, name: []const u8, transform: ?Math.Vec3) !*GameObject {
        const model = try fromMesh(self.allocator, mesh, name);
        const object = try self.addObject(model, null);
        if (transform) |t| {
            object.transform.translate(t);
        }
        return object;
    }

    pub fn addModel(self: *Scene, model: Model, point_light: ?PointLightComponent) !*GameObject {
        // Heap-allocate the model internally
        const model_ptr = try self.allocator.create(Model);
        model_ptr.* = model;
        const object = try self.addObject(model_ptr, point_light);
        return object;
    }

    pub fn addTexture(self: *Scene, texture: Texture) !usize {
        try self.textures.append(self.allocator, texture);
        const index = self.textures.items.len - 1;
        try self.updateTextureImageInfos(self.allocator);
        log(.INFO, "scene", "Added texture at index {d}", .{index});
        return index;
    }

    pub fn addMaterial(self: *Scene, material: Material) !usize {
        try self.materials.append(self.allocator, material);
        const index = self.materials.items.len - 1;
        try self.updateMaterialBuffer(self.gc, self.allocator);
        log(.INFO, "scene", "Added material at index {d}", .{index});
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
        log(.DEBUG, "scene", "Updating material buffer with {d} materials", .{self.materials.items.len});
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
        for (self.objects.items) |object| {
            try object.render(gc, cmdbuf);
        }
    }

    pub fn addModelWithMaterial(
        self: *Scene,
        model_path: []const u8,
        texture_path: []const u8,
    ) !*GameObject {
        log(.DEBUG, "scene", "Loading model from {s}", .{model_path});
        const model_data = try loadFileAlloc(self.allocator, model_path, 10 * 1024 * 1024); // 10MB max
        defer self.allocator.free(model_data);
        const model = try Model.loadFromObj(self.allocator, self.gc, model_data, model_path);
        log(.DEBUG, "scene", "Loading texture from {s}", .{texture_path});
        const texture = try Texture.initFromFile(self.gc, texture_path, .rgba8);
        const texture_id = try self.addTexture(texture);
        const material = Material{ .albedo_texture_id = @intCast(texture_id) };
        const material_id = try self.addMaterial(material);
        for (model.meshes.items) |*mesh| {
            mesh.geometry.mesh.material_id = @intCast(material_id);
        }
        log(.INFO, "scene", "Assigned material {d} to all meshes in model {s}", .{ material_id, model_path });
        return try self.addModel(model, null);
    }

    pub fn addModelWithMaterialAndTransform(
        self: *Scene,
        model_path: []const u8,
        texture_path: []const u8,
        transform: Math.Vec3,
        scale: Math.Vec3,
    ) !*GameObject {
        const obj = try self.addModelWithMaterial(model_path, texture_path);
        obj.transform.translate(transform);
        obj.transform.scale(scale);
        return obj;
    }
};

// No direct usage of mesh.vertex_buffer_descriptor or mesh.index_buffer_descriptor in this file, but if you add such usage, use mesh.vertex_buffer.?.descriptor_info and mesh.index_buffer.?.descriptor_info.
