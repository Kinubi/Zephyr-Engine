const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("graphics_context.zig").GraphicsContext;

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

    vao: c_uint = undefined,
    vbo: c_uint = undefined,
    ibo: c_uint = undefined,

    pub fn init(allocator: std.mem.Allocator) Mesh {
        return .{
            .vertices = std.ArrayList(Vertex).init(allocator),
            .indices = std.ArrayList(u32).init(allocator),
        };
    }

    pub fn uploadVertices(self: @This(), gc: *const GraphicsContext, buffer: vk.Buffer) !void {
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

        try gc.copyBuffer(buffer, staging_buffer, @sizeOf(Vertex) * self.vertices.items.len);
    }

    pub fn draw(self: @This(), gc: GraphicsContext, cmdbuf: vk.CommandBuffer, buffer: vk.Buffer) void {
        gc.vkd.cmdBindVertexBuffers(cmdbuf, 0, 1, &buffer, &0);
        gc.vkd.cmdDraw(cmdbuf, self.vertices.items.len, 1, 0, 0);
    }
};
