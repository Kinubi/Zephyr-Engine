const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("graphics_context.zig").GraphicsContext;
const Math = @import("mach").math;

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
            .format = .r32g32_sfloat,
            .offset = @offsetOf(Vertex, "pos"),
        },
        .{
            .binding = 0,
            .location = 1,
            .format = .r32g32b32_sfloat,
            .offset = @offsetOf(Vertex, "color"),
        },
    };

    pos: [2]f32,
    color: [3]f32,
};

pub const Mesh = struct {
    vertices: std.ArrayList(Vertex),
    indices: std.ArrayList(u32),
    var vertex_buffer: vk.Buffer = undefined;
    var index_buffer: vk.Buffer = undefined;
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

    pub fn deinit(self: @This(), gc: GraphicsContext) void {
        self.vertices.deinit();
        self.indices.deinit();
        gc.vkd.freeMemory(gc.dev, vertex_buffer_memory, null);
        gc.vkd.destroyBuffer(gc.dev, vertex_buffer, null);
    }

    pub fn draw(self: @This(), gc: GraphicsContext, cmdbuf: vk.CommandBuffer) void {
        const offset = [_]vk.DeviceSize{0};
        gc.vkd.cmdBindVertexBuffers(cmdbuf, 0, 1, @as([*]const vk.Buffer, @ptrCast(&vertex_buffer)), &offset);
        gc.vkd.cmdDraw(cmdbuf, @intCast(self.vertices.items.len), 1, 0, 0);
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
};

pub const Primitive = struct {
    mesh: ?Mesh = null,
};

pub const Transform = struct {
    local2world: Math.Mat4x4 = Math.Mat4x4.ident,
    offset: Math.Vec2 = Math.Vec2.init(0, 0),

    pub fn translate(self: *Transform, vec: Math.Vec3) void {
        self.local2world = self.local2world.transpose().mul(&Math.Mat4x4.translate(vec)).transpose();
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
