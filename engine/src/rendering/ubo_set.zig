const std = @import("std");
const vk = @import("vulkan");
const Buffer = @import("../core/buffer.zig").Buffer;
const GlobalUbo = @import("frameinfo.zig").GlobalUbo;
const MAX_FRAMES_IN_FLIGHT = @import("../core/swapchain.zig").MAX_FRAMES_IN_FLIGHT;
const GraphicsContext = @import("../core/graphics_context.zig").GraphicsContext;

/// Manages the global UBO buffers (one per frame in flight)
/// Descriptor sets are now managed by UnifiedPipelineSystem via bindResource()
pub const GlobalUboSet = struct {
    buffers: []Buffer,
    allocator: std.mem.Allocator,

    pub fn init(gc: *GraphicsContext, allocator: std.mem.Allocator) !GlobalUboSet {
        var buffers = try allocator.alloc(Buffer, MAX_FRAMES_IN_FLIGHT);
        errdefer allocator.free(buffers);

        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            buffers[i] = try Buffer.init(
                gc,
                @sizeOf(GlobalUbo),
                1,
                .{ .uniform_buffer_bit = true },
                .{ .host_visible_bit = true, .host_coherent_bit = true },
            );
            errdefer {
                // Clean up any buffers we've already created on error
                for (0..i) |j| {
                    buffers[j].deinit();
                }
            }
            try buffers[i].map(vk.WHOLE_SIZE, 0);
        }

        return GlobalUboSet{
            .buffers = buffers,
            .allocator = allocator,
        };
    }

    pub fn update(self: *GlobalUboSet, frame: usize, ubo: *GlobalUbo) void {
        self.buffers[frame].writeToBuffer(std.mem.asBytes(ubo), vk.WHOLE_SIZE, 0);
        self.buffers[frame].flush(vk.WHOLE_SIZE, 0) catch {};
    }

    pub fn deinit(self: *GlobalUboSet) void {
        for (self.buffers) |*buf| buf.deinit();
        self.allocator.free(self.buffers);
    }
};
