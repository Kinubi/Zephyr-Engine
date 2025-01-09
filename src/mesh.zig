const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("graphics_context.zig").GraphicsContext;
const Math = @import("mach").math;
const Obj = @import("zig-obj");

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
    };

    pos: [3]f32,
    color: [3]f32,
};

pub const Mesh = struct {
    vertices: std.ArrayList(Vertex),
    indices: std.ArrayList(u32),
    var vertex_buffer: vk.Buffer = undefined;
    var index_buffer: vk.Buffer = undefined;
    var index_buffer_memory: vk.DeviceMemory = undefined;
    var vertex_buffer_memory: vk.DeviceMemory = undefined;

    pub fn init(allocator: std.mem.Allocator) Mesh {
        return .{
            .vertices = std.ArrayList(Vertex).init(allocator),
            .indices = std.ArrayList(u32).init(allocator),
        };
    }

    pub fn createVertexBuffers(self: @This(), gc: *GraphicsContext) !void {
        vertex_buffer = try gc.createBuffer(@sizeOf(Vertex) * self.vertices.items.len, .{ .transfer_dst_bit = true, .vertex_buffer_bit = true });
        const mem_reqs = gc.vkd.getBufferMemoryRequirements(gc.dev, vertex_buffer);
        vertex_buffer_memory = try gc.allocate(mem_reqs, .{ .device_local_bit = true });
        try gc.vkd.bindBufferMemory(gc.dev, vertex_buffer, vertex_buffer_memory, 0);
        try self.uploadVertices(gc);
    }

    fn uploadVertices(self: @This(), gc: *const GraphicsContext) !void {
        const staging_buffer = try gc.vkd.createBuffer(gc.dev, &.{
            .flags = .{},
            .size = @sizeOf(Vertex) * self.vertices.items.len,
            .usage = .{ .transfer_src_bit = true },
            .sharing_mode = .exclusive,
            .queue_family_index_count = 0,
            .p_queue_family_indices = undefined,
        }, null);
        defer gc.vkd.destroyBuffer(gc.dev, staging_buffer, null);
        const mem_reqs = gc.vkd.getBufferMemoryRequirements(gc.dev, staging_buffer);
        const staging_memory = try gc.allocate(mem_reqs, .{ .host_visible_bit = true, .host_coherent_bit = true });
        defer gc.vkd.freeMemory(gc.dev, staging_memory, null);
        try gc.vkd.bindBufferMemory(gc.dev, staging_buffer, staging_memory, 0);

        {
            const data = try gc.vkd.mapMemory(gc.dev, staging_memory, 0, vk.WHOLE_SIZE, .{});
            defer gc.vkd.unmapMemory(gc.dev, staging_memory);

            const gpu_vertices: [*]Vertex = @ptrCast(@alignCast(data));
            for (self.vertices.items, 0..) |vertex, i| {
                gpu_vertices[i] = vertex;
            }
        }

        try gc.copyBuffer(vertex_buffer, staging_buffer, @sizeOf(Vertex) * self.vertices.items.len);
    }

    pub fn createIndexBuffers(self: @This(), gc: *GraphicsContext) !void {
        if (self.indices.items.len == 0) {
            return;
        }
        index_buffer = try gc.createBuffer(@sizeOf(u32) * self.indices.items.len, .{ .transfer_dst_bit = true, .index_buffer_bit = true });
        const mem_reqs = gc.vkd.getBufferMemoryRequirements(gc.dev, index_buffer);
        index_buffer_memory = try gc.allocate(mem_reqs, .{ .device_local_bit = true });
        try gc.vkd.bindBufferMemory(gc.dev, index_buffer, index_buffer_memory, 0);
        try self.uploadIndices(gc);
    }

    fn uploadIndices(self: @This(), gc: *const GraphicsContext) !void {
        const staging_buffer = try gc.vkd.createBuffer(gc.dev, &.{
            .flags = .{},
            .size = @sizeOf(u32) * self.indices.items.len,
            .usage = .{ .transfer_src_bit = true },
            .sharing_mode = .exclusive,
            .queue_family_index_count = 0,
            .p_queue_family_indices = undefined,
        }, null);
        defer gc.vkd.destroyBuffer(gc.dev, staging_buffer, null);
        const mem_reqs = gc.vkd.getBufferMemoryRequirements(gc.dev, staging_buffer);
        const staging_memory = try gc.allocate(mem_reqs, .{ .host_visible_bit = true, .host_coherent_bit = true });
        defer gc.vkd.freeMemory(gc.dev, staging_memory, null);
        try gc.vkd.bindBufferMemory(gc.dev, staging_buffer, staging_memory, 0);

        {
            const data = try gc.vkd.mapMemory(gc.dev, staging_memory, 0, vk.WHOLE_SIZE, .{});
            defer gc.vkd.unmapMemory(gc.dev, staging_memory);

            const gpu_indices: [*]u32 = @ptrCast(@alignCast(data));
            for (self.indices.items, 0..) |index, i| {
                gpu_indices[i] = index;
            }
        }

        try gc.copyBuffer(index_buffer, staging_buffer, @sizeOf(u32) * self.indices.items.len);
    }

    pub fn deinit(self: @This(), gc: GraphicsContext) void {
        self.vertices.deinit();
        self.indices.deinit();
        gc.vkd.freeMemory(gc.dev, vertex_buffer_memory, null);
        gc.vkd.destroyBuffer(gc.dev, vertex_buffer, null);
        gc.vkd.freeMemory(gc.dev, index_buffer_memory, null);
        gc.vkd.destroyBuffer(gc.dev, index_buffer, null);
    }

    pub fn draw(self: @This(), gc: GraphicsContext, cmdbuf: vk.CommandBuffer) void {
        const offset = [_]vk.DeviceSize{0};
        gc.vkd.cmdBindVertexBuffers(cmdbuf, 0, 1, @as([*]const vk.Buffer, @ptrCast(&vertex_buffer)), &offset);

        if (self.indices.items.len > 0) {
            gc.vkd.cmdBindIndexBuffer(cmdbuf, index_buffer, 0, vk.IndexType.uint32);
            gc.vkd.cmdDrawIndexed(cmdbuf, @intCast(self.indices.items.len), 1, 0, 0, 0);
        } else {
            gc.vkd.cmdDraw(cmdbuf, @intCast(self.vertices.items.len), 1, 0, 0);
        }
    }

    pub fn loadFromObj(self: *@This(), allocator: std.mem.Allocator, data: []const u8) !void {
        const model = try Obj.parseObj(allocator, data);
        std.debug.print("Loaded model {any} with {any} indices and {any} vertices\n", .{ model.vertices.len, model.meshes[0].indices.len, model.meshes[0].num_vertices.len });
        try self.vertices.ensureTotalCapacity(model.vertices.len);
        try self.indices.ensureTotalCapacity(model.meshes[0].indices.len);

        for (model.meshes) |mesh| {
            var i: u32 = 0;
            while (i < mesh.indices.len) : (i += 1) {
                std.debug.print("start: {any}, middle: {},  end: {any}\n", .{ model.vertices[@as(usize, @intCast(mesh.indices[i].vertex.?))], model.vertices[@as(usize, @intCast(mesh.indices[i].vertex.? + 1))], model.vertices[@as(usize, @intCast(mesh.indices[i].vertex.? + 2))] });
                // std.debug.print("Index: {any}, {any}, {any}\n", .{ mesh.indices[i], mesh.indices[i + 1], mesh.indices[i + 2] });
                const vertices = .{ model.vertices[@intCast(mesh.indices[i].vertex.?)], model.vertices[@intCast(mesh.indices[i].vertex.? + 1)], model.vertices[@intCast(mesh.indices[i].vertex.? + 2)] };
                try self.vertices.appendSlice(&.{Vertex{ .pos = .{ vertices[0], vertices[1], vertices[2] }, .color = .{ 1.0, 1.0, 1.0 } }});

                try self.indices.append(@intCast(mesh.indices[i].vertex.?));
            }
        }

        std.debug.print("Vertices: {any}, Indices: {any}\n", .{ self.vertices.items, self.indices.items });
    }
};

pub const Model = struct {
    primitives: PrimitivesArray = .{},

    const PrimitivesArray = std.BoundedArray(Primitive, 8);

    pub fn init(mesh: Mesh) Model {
        return Model{
            .primitives = PrimitivesArray.fromSlice(&.{
                .{
                    .mesh = mesh,
                },
            }) catch unreachable,
        };
    }

    pub fn deinit(self: Model, gc: GraphicsContext) void {
        for (self.primitives.constSlice()) |primitive| {
            if (primitive.mesh) |mesh| {
                mesh.deinit(gc);
            }
        }
    }
};

pub const Primitive = struct {
    mesh: ?Mesh = null,
};

pub const Transform = struct {
    local2world: Math.Mat4x4 = Math.Mat4x4.ident,
    rotation: Math.Vec3 = Math.Vec3.init(0.0, 0.0, 0.0),
    position: Math.Vec3 = Math.Vec3.init(0.0, 0.0, 0.0),

    pub fn translate(self: *Transform, vec: Math.Vec3) void {
        self.local2world = self.local2world.mul(&Math.Mat4x4.translate(vec));
    }

    pub fn rotate(self: *Transform, quat: Math.Quat) void {
        const qx = quat.v.v[0]; // -
        const qy = quat.v.v[1];
        const qz = quat.v.v[2];
        const qw = quat.v.v[3];

        // From glm: https://github.com/g-truc/glm/blob/33b4a621a697a305bc3a7610d290677b96beb181/glm/gtc/quaternion.inl#L47
        const rotMat = Math.Mat4x4{
            .v = [4]Math.Vec4{
                Math.vec4(
                    1 - 2 * (qy * qy + qz * qz),
                    2 * (qx * qy + qz * qw),
                    2 * (qx * qz - qy * qw),
                    0,
                ),
                Math.vec4(
                    2 * (qx * qy - qz * qw),
                    1 - 2 * (qx * qx + qz * qz),
                    2 * (qy * qz + qx * qw),
                    0,
                ),
                Math.vec4(
                    2 * (qx * qz + qy * qw),
                    2 * (qy * qz - qx * qw),
                    1 - 2 * (qx * qx + qy * qy),
                    0,
                ),
                Math.vec4(0.0, 0.0, 0.0, 1.0),
            },
        };

        self.local2world = self.local2world.mul(&rotMat);
    }

    pub fn scale(self: *Transform, vec: Math.Vec3) void {
        self.local2world = self.local2world.mul(&Math.Mat4x4.scale(vec));
    }
};
