const std = @import("std");
const vk = @import("vulkan");
const Buffer = @import("../core/buffer.zig").Buffer;
const GlobalUbo = @import("frameinfo.zig").GlobalUbo;
const MAX_FRAMES_IN_FLIGHT = @import("../core/swapchain.zig").MAX_FRAMES_IN_FLIGHT;
const GraphicsContext = @import("../core/graphics_context.zig").GraphicsContext;
const buffer_manager_module = @import("buffer_manager.zig");
const BufferManager = buffer_manager_module.BufferManager;
const ManagedBuffer = buffer_manager_module.ManagedBuffer;
const BufferConfig = buffer_manager_module.BufferConfig;

/// Manages the global UBO buffers (one per frame in flight)
/// Now uses BufferManager with generation tracking for automatic rebinding
/// Descriptor sets are managed by UnifiedPipelineSystem via bindResource()
pub const GlobalUboSet = struct {
    buffer_manager: *BufferManager,
    allocator: std.mem.Allocator,

    // One ManagedBuffer per frame-in-flight
    frame_buffers: [MAX_FRAMES_IN_FLIGHT]*ManagedBuffer,

    pub fn init(gc: *GraphicsContext, allocator: std.mem.Allocator, buffer_manager: *BufferManager) !GlobalUboSet {
        _ = gc; // No longer needed - BufferManager handles GraphicsContext

        var frame_buffers: [MAX_FRAMES_IN_FLIGHT]*ManagedBuffer = undefined;

        // Create all frame buffers upfront (one per frame-in-flight)
        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            const frame_index = @as(u32, @intCast(i));
            const buffer_config = BufferConfig{
                .name = "GlobalUBO",
                .size = @sizeOf(GlobalUbo),
                .strategy = .host_visible,
                .usage = .{ .uniform_buffer_bit = true },
            };

            frame_buffers[i] = try buffer_manager.createBuffer(buffer_config, frame_index);
        }

        return GlobalUboSet{
            .buffer_manager = buffer_manager,
            .allocator = allocator,
            .frame_buffers = frame_buffers,
        };
    }

    /// Update UBO data for a specific frame
    /// Just updates the existing buffer, doesn't recreate it
    pub fn update(self: *GlobalUboSet, frame: usize, ubo: *GlobalUbo) void {
        const frame_index = @as(u32, @intCast(frame));
        const frame_buffer = self.frame_buffers[frame];
        const data = std.mem.asBytes(ubo);

        // Update buffer contents (increments generation automatically)
        self.buffer_manager.updateBuffer(frame_buffer, data, frame_index) catch |err| {
            std.debug.print("Failed to update UBO buffer: {}\n", .{err});
        };
    }

    /// Get the ManagedBuffer for a specific frame (for ResourceBinder)
    pub fn getBuffer(self: *GlobalUboSet, frame: usize) *ManagedBuffer {
        return self.frame_buffers[frame];
    }

    pub fn deinit(self: *GlobalUboSet) void {
        // Destroy all frame buffers via BufferManager
        for (self.frame_buffers) |buffer| {
            if (buffer.generation > 0) {
                self.buffer_manager.destroyBuffer(buffer) catch |err| {
                    std.debug.print("Failed to destroy UBO buffer: {}\n", .{err});
                };
            }
        }
    }
};
