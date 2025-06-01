const std = @import("std");
const vk = @import("vulkan");
const Buffer = @import("buffer.zig").Buffer;
const DescriptorPool = @import("descriptors.zig").DescriptorPool;
const DescriptorSetLayout = @import("descriptors.zig").DescriptorSetLayout;
const DescriptorWriter = @import("descriptors.zig").DescriptorWriter;
const GlobalUbo = @import("frameinfo.zig").GlobalUbo;
const MAX_FRAMES_IN_FLIGHT = @import("swapchain.zig").MAX_FRAMES_IN_FLIGHT;
const GraphicsContext = @import("graphics_context.zig").GraphicsContext;

pub const GlobalUboSet = struct {
    pool: *DescriptorPool,
    layout: *DescriptorSetLayout,
    sets: []vk.DescriptorSet,
    buffers: []Buffer,

    pub fn init(gc: *GraphicsContext, allocator: std.mem.Allocator) !GlobalUboSet {
        var buffers = try allocator.alloc(Buffer, MAX_FRAMES_IN_FLIGHT);
        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            buffers[i] = try Buffer.init(
                gc,
                @sizeOf(GlobalUbo),
                1,
                .{ .uniform_buffer_bit = true },
                .{ .host_visible_bit = true, .host_coherent_bit = true },
            );
            try buffers[i].map(vk.WHOLE_SIZE, 0);
        }

        var pool_builder = DescriptorPool.Builder{ .gc = gc, .poolSizes = std.ArrayList(vk.DescriptorPoolSize).init(allocator), .poolFlags = .{}, .maxSets = 0 };
        const pool = @constCast(&try pool_builder.setMaxSets(MAX_FRAMES_IN_FLIGHT).addPoolSize(.uniform_buffer, MAX_FRAMES_IN_FLIGHT + 1).build());

        var layout_builder = DescriptorSetLayout.Builder{ .gc = gc, .bindings = std.AutoHashMap(u32, vk.DescriptorSetLayoutBinding).init(allocator) };
        const layout = @constCast(&try layout_builder.addBinding(0, .uniform_buffer, .{ .vertex_bit = true, .fragment_bit = true }, 1).build());

        var sets = try allocator.alloc(vk.DescriptorSet, MAX_FRAMES_IN_FLIGHT);
        var writer = DescriptorWriter.init(gc, layout, pool);
        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            const bufferInfo = buffers[i].descriptor_info;
            try writer.writeBuffer(0, @constCast(&bufferInfo)).build(&sets[i]);
        }

        return GlobalUboSet{
            .pool = pool,
            .layout = layout,
            .sets = sets,
            .buffers = buffers,
        };
    }

    pub fn update(self: *GlobalUboSet, frame: usize, ubo: *GlobalUbo) void {
        self.buffers[frame].writeToBuffer(std.mem.asBytes(ubo), vk.WHOLE_SIZE, 0);
        self.buffers[frame].flush(vk.WHOLE_SIZE, 0) catch {};
    }

    pub fn deinit(self: *GlobalUboSet) void {
        for (self.buffers) |*buf| buf.deinit();
        // Optionally deinit pool/layout/sets if you own them
    }
};
