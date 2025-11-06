const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("../core/graphics_context.zig").GraphicsContext;
const Buffer = @import("../core/buffer.zig").Buffer;
const ResourceBinder = @import("resource_binder.zig").ResourceBinder;
const log = @import("../utils/log.zig").log;

pub const MAX_FRAMES_IN_FLIGHT = @import("../core/swapchain.zig").MAX_FRAMES_IN_FLIGHT;

pub const BufferStrategy = enum {
    device_local, // Device memory, staging upload
    host_visible, // Host memory, direct write
    host_cached, // Host memory, manual flush
};

pub const BufferConfig = struct {
    name: []const u8,
    size: vk.DeviceSize,
    strategy: BufferStrategy,
    usage: vk.BufferUsageFlags,
};

pub const BufferStats = struct {
    size: vk.DeviceSize,
    strategy: BufferStrategy,
    created_frame: u64,
    last_updated: u64,
};

pub const ManagedBuffer = struct {
    buffer: Buffer,
    name: []const u8,
    size: vk.DeviceSize,
    strategy: BufferStrategy,
    created_frame: u64,
    generation: u32, // Generation counter for tracking updates
    binding_info: ?BindingInfo = null,

    pub const BindingInfo = struct {
        set: u32,
        binding: u32,
        pipeline_name: []const u8,
    };

    /// Get descriptor info for manual binding
    pub fn getDescriptorInfo(self: *const ManagedBuffer) vk.DescriptorBufferInfo {
        return self.buffer.descriptor_info;
    }
};

pub const BufferManager = struct {
    allocator: std.mem.Allocator,
    graphics_context: *GraphicsContext,
    resource_binder: *ResourceBinder,

    // Ring buffers for frame-safe cleanup
    deferred_buffers: [MAX_FRAMES_IN_FLIGHT]std.ArrayList(ManagedBuffer),
    current_frame: u32 = 0,
    frame_counter: u64 = 0,

    // Global registry for debugging
    all_buffers: std.StringHashMap(BufferStats),

    /// Initialize BufferManager with ResourceBinder integration
    pub fn init(
        allocator: std.mem.Allocator,
        graphics_context: *GraphicsContext,
        resource_binder: *ResourceBinder,
    ) !*BufferManager {
        const self = try allocator.create(BufferManager);
        self.* = .{
            .allocator = allocator,
            .graphics_context = graphics_context,
            .resource_binder = resource_binder,
            .deferred_buffers = undefined,
            .all_buffers = std.StringHashMap(BufferStats).init(allocator),
        };

        // Initialize ring buffer arrays
        for (&self.deferred_buffers) |*slot| {
            slot.* = std.ArrayList(ManagedBuffer){};
        }

        log(.INFO, "buffer_manager", "BufferManager initialized", .{});
        return self;
    }

    pub fn deinit(self: *BufferManager) void {
        // Clean up all deferred buffers
        for (&self.deferred_buffers) |*slot| {
            self.cleanupRingSlot(slot);
            slot.deinit(self.allocator);
        }

        self.all_buffers.deinit();
        self.allocator.destroy(self);
        log(.INFO, "buffer_manager", "BufferManager deinitialized", .{});
    }

    /// Create buffer with specified strategy
    pub fn createBuffer(
        self: *BufferManager,
        config: BufferConfig,
        _: u32, // frame_index currently unused but reserved for future frame tracking
    ) !ManagedBuffer {
        // Duplicate the name for ownership
        const owned_name = try self.allocator.dupe(u8, config.name);
        errdefer self.allocator.free(owned_name);

        // Create the buffer based on strategy
        const buffer = switch (config.strategy) {
            .device_local => try self.createDeviceLocalBuffer(config),
            .host_visible => try self.createHostVisibleBuffer(config),
            .host_cached => try self.createHostCachedBuffer(config),
        };

        const managed = ManagedBuffer{
            .buffer = buffer,
            .name = owned_name,
            .size = config.size,
            .strategy = config.strategy,
            .created_frame = self.frame_counter,
            .generation = 1, // Start at generation 1
        };

        // Add to statistics
        try self.all_buffers.put(owned_name, BufferStats{
            .size = config.size,
            .strategy = config.strategy,
            .created_frame = self.frame_counter,
            .last_updated = self.frame_counter,
        });

        log(.DEBUG, "buffer_manager", "Created buffer '{s}': {} bytes, strategy: {}", .{
            config.name, config.size, config.strategy,
        });

        return managed;
    }

    /// Create and upload data in one call (device-local only)
    pub fn createAndUpload(
        self: *BufferManager,
        name: []const u8,
        data: []const u8,
        frame_index: u32,
    ) !ManagedBuffer {
        const config = BufferConfig{
            .name = name,
            .size = data.len,
            .strategy = .device_local,
            .usage = .{ .vertex_buffer_bit = true, .transfer_dst_bit = true },
        };

        var managed = try self.createBuffer(config, frame_index);
        try self.updateBuffer(&managed, data, frame_index);

        return managed;
    }

    /// Update buffer contents (strategy-aware)
    pub fn updateBuffer(
        self: *BufferManager,
        managed_buffer: *ManagedBuffer,
        data: []const u8,
        _: u32, // frame_index currently unused but reserved for future frame tracking
    ) !void {
        switch (managed_buffer.strategy) {
            .device_local => {
                // Use staging buffer for device-local buffers
                try self.uploadViaStaging(&managed_buffer.buffer, data);
            },
            .host_visible => {
                // Direct write for host-visible buffers
                try managed_buffer.buffer.map(data.len, 0);
                managed_buffer.buffer.writeToBuffer(data, data.len, 0);
                managed_buffer.buffer.unmap();
            },
            .host_cached => {
                // Direct write + manual flush for host-cached buffers
                try managed_buffer.buffer.map(data.len, 0);
                managed_buffer.buffer.writeToBuffer(data, data.len, 0);
                // Flush for cached memory (Buffer has flush method)
                try managed_buffer.buffer.flush(data.len, 0);
                managed_buffer.buffer.unmap();
            },
        }

        // Increment generation to signal change
        managed_buffer.generation += 1;

        // Update statistics
        if (self.all_buffers.getPtr(managed_buffer.name)) |stats| {
            stats.last_updated = self.frame_counter;
        }

        log(.DEBUG, "buffer_manager", "Updated buffer '{s}': {} bytes, generation {}", .{
            managed_buffer.name, data.len, managed_buffer.generation,
        });
    }

    /// Called at frame start to cleanup old buffers
    pub fn beginFrame(self: *BufferManager, frame_index: u32) void {
        self.current_frame = frame_index;
        self.frame_counter += 1;

        // Cleanup buffers that are now safe to destroy
        const cleanup_slot = &self.deferred_buffers[frame_index];
        self.cleanupRingSlot(cleanup_slot);
    }

    /// Queue buffer for deferred destruction
    pub fn destroyBuffer(self: *BufferManager, managed_buffer: ManagedBuffer) !void {
        const slot = &self.deferred_buffers[self.current_frame];
        try slot.append(self.allocator, managed_buffer);

        // Remove from statistics
        _ = self.all_buffers.remove(managed_buffer.name);

        log(.DEBUG, "buffer_manager", "Queued buffer '{s}' for destruction", .{managed_buffer.name});
    }

    /// Print memory statistics
    pub fn printStatistics(self: *BufferManager) void {
        log(.INFO, "buffer_manager", "=== Buffer Manager Statistics ===", .{});

        var total_size: u64 = 0;
        var buffer_count: u32 = 0;
        var strategy_counts = [_]u32{0} ** 3; // device_local, host_visible, host_cached

        var iter = self.all_buffers.iterator();
        while (iter.next()) |entry| {
            const stats = entry.value_ptr;
            total_size += stats.size;
            buffer_count += 1;

            const strategy_idx = switch (stats.strategy) {
                .device_local => 0,
                .host_visible => 1,
                .host_cached => 2,
            };
            strategy_counts[strategy_idx] += 1;
        }

        log(.INFO, "buffer_manager", "Total buffers: {}", .{buffer_count});
        log(.INFO, "buffer_manager", "Total size: {d:.2} MB", .{@as(f32, @floatFromInt(total_size)) / (1024.0 * 1024.0)});
        log(.INFO, "buffer_manager", "Device-local: {}, Host-visible: {}, Host-cached: {}", .{
            strategy_counts[0], strategy_counts[1], strategy_counts[2],
        });
        log(.INFO, "buffer_manager", "===============================", .{});
    }

    // Private implementation details

    /// Create staging buffer and upload to device
    fn uploadViaStaging(
        self: *BufferManager,
        dst: *Buffer,
        data: []const u8,
    ) !void {
        var staging = try Buffer.init(
            self.graphics_context,
            data.len,
            1,
            .{ .transfer_src_bit = true },
            .{ .host_visible_bit = true, .host_coherent_bit = true },
        );

        try staging.map(data.len, 0);
        staging.writeToBuffer(data, data.len, 0);
        staging.unmap();

        // Copy from staging to destination buffer using graphics context
        try self.graphics_context.copyFromStagingBuffer(dst.buffer, &staging, data.len);

        log(.DEBUG, "buffer_manager", "Staging upload completed for {} bytes", .{data.len});
    }

    /// Cleanup buffers in ring slot
    fn cleanupRingSlot(self: *BufferManager, slot: *std.ArrayList(ManagedBuffer)) void {
        for (slot.items) |*managed| {
            managed.buffer.deinit();
            // Free the duplicated name string
            self.allocator.free(managed.name);
        }
        slot.clearRetainingCapacity();
    }

    /// Create device-local buffer (optimal for GPU access)
    fn createDeviceLocalBuffer(self: *BufferManager, config: BufferConfig) !Buffer {
        return Buffer.initNamed(
            self.graphics_context,
            config.size,
            1,
            config.usage,
            .{ .device_local_bit = true },
            config.name,
        );
    }

    /// Create host-visible buffer (CPU mappable)
    fn createHostVisibleBuffer(self: *BufferManager, config: BufferConfig) !Buffer {
        return Buffer.initNamed(
            self.graphics_context,
            config.size,
            1,
            config.usage,
            .{ .host_visible_bit = true, .host_coherent_bit = true },
            config.name,
        );
    }

    /// Create host-cached buffer (CPU mappable with manual flushing)
    fn createHostCachedBuffer(self: *BufferManager, config: BufferConfig) !Buffer {
        return Buffer.initNamed(
            self.graphics_context,
            config.size,
            1,
            config.usage,
            .{ .host_visible_bit = true, .host_cached_bit = true },
            config.name,
        );
    }
};
