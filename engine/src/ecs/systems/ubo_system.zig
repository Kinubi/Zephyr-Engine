const std = @import("std");
const vk = @import("vulkan");
const buffer_manager_module = @import("../../rendering/buffer_manager.zig");
const BufferManager = buffer_manager_module.BufferManager;
const ManagedBuffer = buffer_manager_module.ManagedBuffer;
const log = @import("../../utils/log.zig").log;

const MAX_FRAMES_IN_FLIGHT = @import("../../core/swapchain.zig").MAX_FRAMES_IN_FLIGHT;

/// UBOSystem - Manages per-frame uniform buffers
///
/// Unlike MaterialSystem which manages a single shared SSBO, UBOSystem manages
/// per-frame UBOs (one buffer per frame-in-flight). This is necessary because
/// UBO data changes every frame (camera, time, etc.) and we don't want to
/// overwrite data that's still being used by the GPU.
///
/// Each frame gets its own ManagedBuffer with independent generation tracking.
pub const UBOSystem = struct {
    allocator: std.mem.Allocator,
    buffer_manager: *BufferManager,

    // One buffer per frame-in-flight
    frame_buffers: [MAX_FRAMES_IN_FLIGHT]?*ManagedBuffer,

    pub fn init(
        allocator: std.mem.Allocator,
        buffer_manager: *BufferManager,
        ubo_size: vk.DeviceSize,
    ) !*UBOSystem {
        const self = try allocator.create(UBOSystem);

        // Initialize all frame buffers as null - they will be created on first use
        self.* = .{
            .allocator = allocator,
            .buffer_manager = buffer_manager,
            .frame_buffers = [_]?*ManagedBuffer{null} ** MAX_FRAMES_IN_FLIGHT,
        };

        _ = ubo_size; // Size will be determined on first update

        log(.INFO, "ubo_system", "UBOSystem initialized", .{});
        return self;
    }

    /// Get the buffer for a specific frame index
    pub fn getBuffer(self: *UBOSystem, frame_index: u32) ?*ManagedBuffer {
        return self.frame_buffers[frame_index];
    }

    /// Update a frame's UBO data
    /// Creates the buffer on first call, otherwise updates existing buffer
    pub fn updateFrameData(
        self: *UBOSystem,
        frame_index: u32,
        data: []const u8,
    ) !void {
        const frame_buffer_opt = &self.frame_buffers[frame_index];

        // Check if buffer exists
        if (frame_buffer_opt.*) |frame_buffer| {
            // Buffer exists - validate size and update
            if (data.len != frame_buffer.size) {
                log(.ERROR, "ubo_system", "Data size mismatch: expected {} bytes, got {}", .{ frame_buffer.size, data.len });
                return error.SizeMismatch;
            }
            try self.buffer_manager.updateBuffer(frame_buffer, data, frame_index);
        } else {
            // First time - create the buffer
            const buffer_config = buffer_manager_module.BufferConfig{
                .name = "GlobalUBO",
                .size = data.len,
                .strategy = .host_visible,
                .usage = .{ .uniform_buffer_bit = true, .transfer_dst_bit = true },
            };

            frame_buffer_opt.* = try self.buffer_manager.createBuffer(buffer_config, frame_index);
            try self.buffer_manager.updateBuffer(frame_buffer_opt.*.?, data, frame_index);
        }
    }

    pub fn deinit(self: *UBOSystem) void {
        // Destroy all frame buffers
        for (self.frame_buffers) |buffer_opt| {
            if (buffer_opt) |buffer| {
                self.buffer_manager.destroyBuffer(buffer) catch |err| {
                    log(.WARN, "ubo_system", "Failed to destroy UBO buffer on deinit: {}", .{err});
                };
            }
        }

        self.allocator.destroy(self);
        log(.INFO, "ubo_system", "UBOSystem deinitialized", .{});
    }
};
