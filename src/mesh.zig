const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("graphics_context.zig").GraphicsContext;
const Math = @import("utils/math.zig");
const Obj = @import("zig-obj");
const Buffer = @import("buffer.zig").Buffer;
const Texture = @import("texture.zig").Texture;
const Geometry = @import("geometry.zig").Geometry;

pub const Vertex = struct {
    pub const binding_description = vk.VertexInputBindingDescription{
        .binding = 0,
        .stride = @sizeOf(Vertex),
        .input_rate = .vertex,
    };

    pub const attribute_description = [_]vk.VertexInputAttributeDescription{
        .{
            .binding = 0,
            .location = 0,
            .format = .r32g32b32_sfloat,
            .offset = @offsetOf(Vertex, "pos"),
        },
        .{
            .binding = 0,
            .location = 1,
            .format = .r32g32b32_sfloat,
            .offset = @offsetOf(Vertex, "color"),
        },
        .{
            .binding = 0,
            .location = 2,
            .format = .r32g32b32_sfloat,
            .offset = @offsetOf(Vertex, "normal"),
        },
        .{
            .binding = 0,
            .location = 3,
            .format = .r32g32_sfloat,
            .offset = @offsetOf(Vertex, "uv"),
        },
    };

    pos: [3]f32 align(16),
    color: [3]f32 align(16),
    normal: [3]f32 align(16) = .{ 0.0, 0.0, 0.0 },
    uv: [2]f32 = .{ 0.0, 0.0 },
};

pub const Mesh = struct {
    vertices: std.ArrayList(Vertex),
    indices: std.ArrayList(u32),

    vertex_buffer: vk.Buffer = undefined,
    vertex_buffer_memory: vk.DeviceMemory = undefined,
    vertex_buffer_descriptor: vk.DescriptorBufferInfo = undefined,
    index_buffer: vk.Buffer = undefined,
    index_buffer_memory: vk.DeviceMemory = undefined,
    index_buffer_descriptor: vk.DescriptorBufferInfo = undefined,

    pub fn init(allocator: std.mem.Allocator) Mesh {
        return .{
            .vertices = std.ArrayList(Vertex).init(allocator),
            .indices = std.ArrayList(u32).init(allocator),
        };
    }

    pub fn createVertexBuffers(self: *@This(), gc: *GraphicsContext) !void {
        if (self.vertices.items.len < 3) {
            return error.VertexCountTooLow;
        }
        const vertex_count: u32 = @intCast(self.vertices.items.len);
        const buffer_size: usize = @sizeOf(Vertex) * vertex_count;

        // Create staging buffer using Buffer abstraction
        var staging_buffer = try Buffer.init(
            gc,
            @sizeOf(Vertex),
            vertex_count,
            .{ .transfer_src_bit = true },
            .{ .host_visible_bit = true, .host_coherent_bit = true },
        );

        try staging_buffer.map(buffer_size, 0);
        staging_buffer.writeToBuffer(std.mem.sliceAsBytes(self.vertices.items), buffer_size, 0);

        // Create device-local vertex buffer using Buffer abstraction
        const device_buffer = try Buffer.init(
            gc,
            @sizeOf(Vertex),
            vertex_count,
            .{ .storage_buffer_bit = true, .vertex_buffer_bit = true, .transfer_dst_bit = true, .shader_device_address_bit = true, .acceleration_structure_build_input_read_only_bit_khr = true },
            .{
                .device_local_bit = true,
            },
        );
        // Copy from staging to device-local
        try gc.copyBuffer(device_buffer.buffer, staging_buffer.buffer, buffer_size);

        // Store handles
        self.vertex_buffer = device_buffer.buffer;
        self.vertex_buffer_descriptor = device_buffer.descriptor_info;
        self.vertex_buffer_memory = device_buffer.memory;
        staging_buffer.deinit();
        // Don't deinit device_buffer, as we take ownership of its memory
    }

    pub fn createIndexBuffers(self: *@This(), gc: *GraphicsContext) !void {
        if (self.indices.items.len == 0) {
            return;
        }
        const index_count: u32 = @intCast(self.indices.items.len);
        const buffer_size: usize = @sizeOf(u32) * index_count;

        // Create staging buffer using Buffer abstraction
        var staging_buffer = try Buffer.init(
            gc,
            @sizeOf(u32),
            index_count,
            .{ .transfer_src_bit = true },
            .{ .host_visible_bit = true, .host_coherent_bit = true },
        );

        try staging_buffer.map(buffer_size, 0);
        staging_buffer.writeToBuffer(std.mem.sliceAsBytes(self.indices.items), buffer_size, 0);

        // Create device-local index buffer using Buffer abstraction
        const device_buffer = try Buffer.init(
            gc,
            @sizeOf(u32),
            index_count,
            .{ .storage_buffer_bit = true, .index_buffer_bit = true, .transfer_dst_bit = true, .shader_device_address_bit = true, .acceleration_structure_build_input_read_only_bit_khr = true },
            .{ .device_local_bit = true },
        );
        // Copy from staging to device-local
        try gc.copyBuffer(device_buffer.buffer, staging_buffer.buffer, buffer_size);

        // Store handles
        self.index_buffer = device_buffer.buffer;
        self.index_buffer_memory = device_buffer.memory;
        self.index_buffer_descriptor = device_buffer.descriptor_info;
        staging_buffer.deinit();
        // Don't deinit device_buffer, as we take ownership of its memory
    }

    pub fn deinit(self: @This(), gc: GraphicsContext) void {
        self.vertices.deinit();
        self.indices.deinit();
        gc.vkd.freeMemory(gc.dev, self.vertex_buffer_memory, null);
        gc.vkd.destroyBuffer(gc.dev, self.vertex_buffer, null);
        gc.vkd.freeMemory(gc.dev, self.index_buffer_memory, null);
        gc.vkd.destroyBuffer(gc.dev, self.index_buffer, null);
    }

    pub fn draw(self: @This(), gc: GraphicsContext, cmdbuf: vk.CommandBuffer) void {
        const offset = [_]vk.DeviceSize{0};
        gc.vkd.cmdBindVertexBuffers(cmdbuf, 0, 1, @as([*]const vk.Buffer, @ptrCast(&self.vertex_buffer)), &offset);

        if (self.indices.items.len > 0) {
            gc.vkd.cmdBindIndexBuffer(cmdbuf, self.index_buffer, 0, vk.IndexType.uint32);
            gc.vkd.cmdDrawIndexed(cmdbuf, @intCast(self.indices.items.len), 1, 0, 0, 0);
        } else {
            gc.vkd.cmdDraw(cmdbuf, @intCast(self.vertices.items.len), 1, 0, 0);
        }
    }

    pub fn loadFromObj(self: *@This(), allocator: std.mem.Allocator, data: []const u8) !void {
        const model = try Obj.parseObj(allocator, data);
        std.debug.print("Loadin model with {any} meshes and {any} distinct vertices and {any} indices\n", .{ model.meshes.len, model.vertices.len / 3, model.meshes[0].indices.len });
        try self.vertices.ensureTotalCapacity(model.vertices.len);
        try self.indices.ensureTotalCapacity(model.meshes[0].indices.len);

        for (model.meshes) |mesh| {
            var i: u32 = 0;
            for (mesh.num_vertices) |face| {
                for (0..face) |vertex| {
                    const index = mesh.indices[face * i + vertex];
                    const new_vertex = Vertex{
                        .pos = .{ model.vertices[3 * index.vertex.?], model.vertices[3 * index.vertex.? + 1], model.vertices[3 * index.vertex.? + 2] },
                        .color = .{ 1.0, 1.0, 1.0 },
                        .normal = .{ model.normals[3 * index.normal.?], model.normals[3 * index.normal.? + 1], model.normals[3 * index.normal.? + 2] },
                        .uv = .{ model.tex_coords[2 * index.tex_coord.?], model.tex_coords[2 * index.tex_coord.? + 1] },
                    };
                    const vertex_index = vertex_list_contains(self.vertices, new_vertex);
                    if (vertex_index == -1) {
                        try self.vertices.append(new_vertex);
                        try self.indices.append(@as(u32, @intCast(self.vertices.items.len - 1)));
                    } else {
                        try self.indices.append(@as(u32, @intCast(vertex_index)));
                    }
                }
                i += 1;
            }
        }

        std.debug.print("Vertices: {any}, Indices: {any}\n", .{ self.vertices.items.len, self.indices.items.len });
    }
};

fn vertex_list_contains(haystack: std.ArrayList(Vertex), needle: Vertex) i32 {
    for (haystack.items, 0..haystack.items.len) |element, i|
        if (std.mem.eql(f32, &@as([3]f32, element.color), &@as([3]f32, needle.color)) and
            std.mem.eql(f32, &@as([3]f32, element.pos), &@as([3]f32, needle.pos)) and
            std.mem.eql(f32, &@as([3]f32, element.normal), &@as([3]f32, needle.normal)) and
            std.mem.eql(f32, &@as([2]f32, element.uv), &@as([2]f32, needle.uv)))
            return @as(i32, @intCast(i));
    return -1;
}

pub const ModelMesh = struct {
    geometry: Geometry,
    local_transform: Transform = .{}, // relative to model root or parent
};

pub const Model = struct {
    meshes: std.ArrayList(ModelMesh),

    pub fn loadFromObj(allocator: std.mem.Allocator, gc: *GraphicsContext, data: []const u8, name: []const u8) !Model {
        const obj = try Obj.parseObj(allocator, data);
        var meshes = std.ArrayList(ModelMesh).init(allocator);
        for (obj.meshes) |obj_mesh| {
            var mesh = Mesh.init(allocator);
            try mesh.vertices.ensureTotalCapacity(obj.vertices.len);
            try mesh.indices.ensureTotalCapacity(obj_mesh.indices.len);
            var index_offset: usize = 0;
            for (obj_mesh.num_vertices) |face_vertex_count| {
                // Compute face normal if any vertex is missing a normal
                var face_normal: [3]f32 = .{ 0.0, 0.0, 0.0 };
                var need_compute_normal = false;
                var face_positions: [3][3]f32 = undefined;
                var vtx_count: usize = 0;
                for (0..face_vertex_count) |vtx_in_face| {
                    const idx = obj_mesh.indices[index_offset + vtx_in_face];
                    if (idx.normal == null) need_compute_normal = true;
                    if (vtx_count < 3) {
                        const pos_idx = idx.vertex.?;
                        face_positions[vtx_count] = .{
                            obj.vertices[pos_idx * 3],
                            obj.vertices[pos_idx * 3 + 1],
                            obj.vertices[pos_idx * 3 + 2],
                        };
                        vtx_count += 1;
                    }
                }
                if (need_compute_normal and vtx_count == 3) {
                    // Compute face normal using cross product
                    const v0 = face_positions[0];
                    const v1 = face_positions[1];
                    const v2 = face_positions[2];
                    const u = .{ v1[0] - v0[0], v1[1] - v0[1], v1[2] - v0[2] };
                    const v = .{ v2[0] - v0[0], v2[1] - v0[1], v2[2] - v0[2] };
                    face_normal = .{
                        u[1] * v[2] - u[2] * v[1],
                        u[2] * v[0] - u[0] * v[2],
                        u[0] * v[1] - u[1] * v[0],
                    };
                    // Normalize
                    const len = @sqrt(face_normal[0] * face_normal[0] + face_normal[1] * face_normal[1] + face_normal[2] * face_normal[2]);
                    if (len > 0.0) {
                        face_normal[0] /= len;
                        face_normal[1] /= len;
                        face_normal[2] /= len;
                    }
                }
                for (0..face_vertex_count) |vtx_in_face| {
                    const idx = obj_mesh.indices[index_offset + vtx_in_face];
                    const pos_idx = idx.vertex.?;
                    const pos = .{
                        obj.vertices[pos_idx * 3],
                        obj.vertices[pos_idx * 3 + 1],
                        obj.vertices[pos_idx * 3 + 2],
                    };
                    const normal = if (idx.normal) |nidx| .{
                        obj.normals[nidx * 3],
                        obj.normals[nidx * 3 + 1],
                        obj.normals[nidx * 3 + 2],
                    } else face_normal;
                    const uv = if (idx.tex_coord) |tidx| .{
                        obj.tex_coords[tidx * 2],
                        obj.tex_coords[tidx * 2 + 1],
                    } else .{ 0.0, 0.0 };
                    const vertex = Vertex{
                        .pos = pos,
                        .color = .{ 1.0, 1.0, 1.0 },
                        .normal = normal,
                        .uv = uv,
                    };
                    const vertex_index = vertex_list_contains(mesh.vertices, vertex);
                    if (vertex_index == -1) {
                        try mesh.vertices.append(vertex);
                        try mesh.indices.append(@as(u32, @intCast(mesh.vertices.items.len - 1)));
                    } else {
                        try mesh.indices.append(@as(u32, @intCast(vertex_index)));
                    }
                }
                index_offset += face_vertex_count;
            }
            try mesh.createIndexBuffers(gc);
            try mesh.createVertexBuffers(gc);
            const geometry = Geometry{ .mesh = mesh, .name = name };
            try meshes.append(ModelMesh{
                .geometry = geometry,
                .local_transform = Transform{},
            });
        }
        return Model{
            .meshes = meshes,
        };
    }

    // pub fn init(mesh: Mesh) Model {
    //     @compileError("Model.init(mesh) is deprecated. Use Model with meshes array and ModelMesh instead.");
    // }

    pub fn deinit(self: *Model, gc: GraphicsContext) void {
        for (self.meshes.items) |mesh| {
            mesh.geometry.mesh.deinit(gc);
        }
        self.meshes.deinit();
    }

    pub fn addTexture(self: *Model, texture: *Texture) void {
        for (self.meshes.items) |model_mesh| {
            if (model_mesh.geometry.material) |mat| {
                mat.base_color_texture = texture;
            }
        }
    }

    pub fn addTextures(self: *Model, textures: []const *Texture) void {
        if (self.meshes.items.len != textures.len) {
            std.debug.print("Error: Model has {any} meshes, but {any} textures were provided.\n", .{ self.meshes.items.len, textures.len });
            return;
        }
        for (self.meshes.items, 0..) |model_mesh, i| {
            if (model_mesh.geometry.material) |mat| {
                mat.base_color_texture = textures[i];
            }
        }
    }

    // Debug print to dump vertex colors for all meshes in the model
    pub fn dumpVertexColors(self: Model) void {
        std.debug.print("[Model] Dumping vertex colors for all meshes in model:\n", .{});
        for (self.meshes.items, 0..) |model_mesh, mesh_idx| {
            const mesh = &model_mesh.geometry.mesh;
            std.debug.print("  Mesh {d}:\n", .{mesh_idx});
            for (mesh.vertices.items, 0..) |v, i| {
                std.debug.print("    Vertex {d}: color = ({any}, {any}, {any})\n", .{ i, v.color[0], v.color[1], v.color[2] });
            }
        }
    }
};

pub const Transform = struct {
    local2world: Math.Mat4x4 = Math.Mat4x4.identity(),
    normal2world: Math.Mat4x4 = Math.Mat4x4.identity(),
    object_scale: Math.Vec3 = Math.Vec3.init(1.0, 1.0, 1.0),

    pub fn translate(self: *Transform, vec: Math.Vec3) void {
        self.local2world = self.local2world.mul(Math.Mat4x4.translation(vec));
    }

    pub fn rotate(self: *Transform, quat: Math.Quat) void {
        const qx = quat.x;
        const qy = quat.y;
        const qz = quat.z;
        const qw = quat.w;

        const rotMat = Math.Mat4x4.init(
            &Math.Vec4.init(
                1 - 2 * (qy * qy + qz * qz),
                2 * (qx * qy + qz * qw),
                2 * (qx * qz - qy * qw),
                0,
            ),
            &Math.Vec4.init(
                2 * (qx * qy - qz * qw),
                1 - 2 * (qx * qx + qz * qz),
                2 * (qy * qz + qx * qw),
                0,
            ),
            &Math.Vec4.init(
                2 * (qx * qz + qy * qw),
                2 * (qy * qz - qx * qw),
                1 - 2 * (qx * qx + qy * qy),
                0,
            ),
            &Math.Vec4.init(0.0, 0.0, 0.0, 1.0),
        );

        self.local2world = self.local2world.mul(rotMat);
    }

    pub fn scale(self: *Transform, vec: Math.Vec3) void {
        self.local2world = self.local2world.mul(Math.Mat4x4.scale(vec));
        self.normal2world = self.normal2world.mul(Math.Mat4x4.scale(Math.Vec3.init(1.0 / vec.x, 1.0 / vec.y, 1.0 / vec.z)));
        self.object_scale = vec;
    }
};

// Example loader function for a model with multiple meshes
pub fn loadModelAsGeometries(allocator: std.mem.Allocator, gc: *GraphicsContext, mesh_datas: []Mesh, name: []const u8) !std.ArrayList(*Geometry) {
    var geometries = std.ArrayList(*Geometry).init(allocator);
    for (mesh_datas, 0..) |mesh, i| {
        const geom_name = try std.fmt.allocPrint(allocator, "{s}_mesh_{d}", .{ name, i });
        const geometry = try mesh.toGeometry(allocator, gc, geom_name);
        try geometries.append(geometry);
    }
    return geometries;
}

// Example loader function for a model with multiple meshes and per-mesh transforms
pub fn loadModelWithTransforms(
    allocator: std.mem.Allocator,
    gc: *GraphicsContext,
    mesh_datas: []Mesh,
    name: []const u8,
    transforms: []const Transform,
) !Model {
    var meshes = std.ArrayList(ModelMesh).init(allocator);
    for (mesh_datas, 0..) |mesh, i| {
        const geom_name = try std.fmt.allocPrint(allocator, "{s}_mesh_{d}", .{ name, i });
        const geometry = try mesh.toGeometry(allocator, gc, geom_name);
        const local_transform = if (i < transforms.len) transforms[i] else Transform{};
        try meshes.append(ModelMesh{
            .geometry = geometry,
            .local_transform = local_transform,
        });
    }
    return Model{
        .meshes = meshes,
    };
}

pub fn fromMesh(allocator: std.mem.Allocator, mesh: Mesh, name: []const u8) !*Model {
    const geom = Geometry{
        .mesh = mesh,
        .name = name,
    };
    const model = try allocator.create(Model);
    model.* = Model{
        .meshes = blk: {
            var arr = std.ArrayList(ModelMesh).init(allocator);
            try arr.append(ModelMesh{ .geometry = geom, .local_transform = .{} });
            break :blk arr;
        },
    };
    return model;
}
