const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("../core/graphics_context.zig").GraphicsContext;
const Buffer = @import("../core/buffer.zig").Buffer;
const ResourceBinder = @import("resource_binder.zig").ResourceBinder;
const log = @import("../utils/log.zig").log;
const CVars = @import("../core/cvar.zig");

pub const MAX_FRAMES_IN_FLIGHT = @import("../core/swapchain.zig").MAX_FRAMES_IN_FLIGHT;

const DEFAULT_FRAME_ARENA_SIZE_MB: i32 = 64; // 64MB default per frame

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

    // Arena allocation support (for per-frame dynamic buffers)
    arena_offset: usize = 0, // Offset within arena buffer (0 = not arena-allocated)
    pending_bind_mask: std.atomic.Value(u8) = std.atomic.Value(u8).init(0), // Frame binding mask (like AS)

    pub const BindingInfo = struct {
        set: u32,
        binding: u32,
        pipeline_name: []const u8,
    };

    /// Get descriptor info for manual binding
    pub fn getDescriptorInfo(self: *const ManagedBuffer) vk.DescriptorBufferInfo {
        return self.buffer.descriptor_info;
    }

    /// Mark buffer as updated - increments generation and sets pending_bind_mask for all frames
    /// Call this whenever buffer content/location changes (resize, arena allocation, compaction)
    pub fn markUpdated(self: *ManagedBuffer) void {
        self.generation +%= 1;
        self.pending_bind_mask.store(0b111, .release); // All frames need rebinding
    }
};

/// Frame arena for dynamic per-frame allocations (materials, instances, dynamic uniforms)
/// One arena per frame - independent allocation management with compaction support
pub const FrameArena = struct {
    buffer: ManagedBuffer,
    capacity: usize,
    current_offset: usize,
    smallest_used_offset: usize,
    frame_index: u32,
    needs_compaction: bool,

    // Track active allocations for compaction
    allocator: std.mem.Allocator,
    active_allocations: std.ArrayList(AllocationInfo),

    pub const AllocationInfo = struct {
        managed_buffer: *ManagedBuffer,
        offset: usize,
        size: usize,
    };

    pub fn init(frame_index: u32, allocator: std.mem.Allocator) FrameArena {
        return .{
            .buffer = undefined, // Will be initialized in BufferManager.init
            .capacity = 0, // Will be set from CVar
            .current_offset = 0,
            .smallest_used_offset = 0,
            .frame_index = frame_index,
            .needs_compaction = false,
            .allocator = allocator,
            .active_allocations = std.ArrayList(AllocationInfo){},
        };
    }

    pub fn deinit(self: *FrameArena) void {
        self.active_allocations.deinit(self.allocator);
    }

    /// Allocate from arena, returns offset within this arena's buffer
    /// Tracks allocation for potential compaction
    pub fn allocate(self: *FrameArena, managed_buffer: *ManagedBuffer, size: usize, alignment: usize) !usize {
        const aligned_offset = std.mem.alignForward(usize, self.current_offset, alignment);

        // Check if allocation would collide with active allocations
        if (aligned_offset + size > self.capacity) {
            // Would wrap - check if we'd collide with smallest_used_offset
            const wrap_offset = std.mem.alignForward(usize, 0, alignment);
            if (wrap_offset + size > self.smallest_used_offset and self.smallest_used_offset > 0) {
                // Collision detected - need compaction
                self.needs_compaction = true;
                return error.ArenaRequiresCompaction;
            }

            if (wrap_offset + size > self.capacity) {
                // Single allocation too large for entire arena
                return error.AllocationTooLarge;
            }

            // Safe to wrap
            const offset = wrap_offset;
            self.current_offset = wrap_offset + size;

            // Track this allocation
            try self.active_allocations.append(self.allocator, .{
                .managed_buffer = managed_buffer,
                .offset = offset,
                .size = size,
            });

            return offset;
        }

        const offset = aligned_offset;
        self.current_offset = aligned_offset + size;

        // Track this allocation
        try self.active_allocations.append(self.allocator, .{
            .managed_buffer = managed_buffer,
            .offset = offset,
            .size = size,
        });

        return offset;
    }

    /// Remove an allocation from tracking and update smallest_used_offset
    pub fn freeAllocation(self: *FrameArena, managed_buffer: *ManagedBuffer) void {
        // Find and remove the allocation
        var i: usize = 0;
        while (i < self.active_allocations.items.len) {
            if (self.active_allocations.items[i].managed_buffer == managed_buffer) {
                _ = self.active_allocations.swapRemove(i);
                break;
            }
            i += 1;
        }

        // Recalculate smallest_used_offset
        self.smallest_used_offset = self.capacity; // Start at end
        for (self.active_allocations.items) |alloc| {
            if (alloc.offset < self.smallest_used_offset) {
                self.smallest_used_offset = alloc.offset;
            }
        }

        // If no allocations left, reset to 0
        if (self.active_allocations.items.len == 0) {
            self.smallest_used_offset = 0;
        }
    }

    /// Explicitly reset arena (clears all tracking)
    pub fn reset(self: *FrameArena) void {
        self.current_offset = 0;
        self.smallest_used_offset = 0;
        self.active_allocations.clearRetainingCapacity();
        self.needs_compaction = false;
    }
};

pub const BufferManager = struct {
    allocator: std.mem.Allocator,
    graphics_context: *GraphicsContext,
    resource_binder: *ResourceBinder,

    // Ring buffers for frame-safe cleanup
    deferred_buffers: [MAX_FRAMES_IN_FLIGHT]std.ArrayList(*ManagedBuffer),
    stale_buffers: [MAX_FRAMES_IN_FLIGHT]std.ArrayList(Buffer), // Old Buffer objects from resizing
    current_frame: u32 = 0,
    frame_counter: u64 = 0,

    // Frame arenas for dynamic per-frame allocations (materials, instances, dynamic uniforms)
    frame_arenas: [MAX_FRAMES_IN_FLIGHT]FrameArena,

    // Global registry for debugging
    all_buffers: std.StringHashMap(BufferStats),

    // Registry of all managed buffers for tracking
    managed_buffers: std.ArrayList(*ManagedBuffer),

    /// Initialize BufferManager with ResourceBinder integration
    pub fn init(
        allocator: std.mem.Allocator,
        graphics_context: *GraphicsContext,
        resource_binder: *ResourceBinder,
    ) !*BufferManager {
        // Get frame arena size from CVar (already registered in cvar.zig)
        const arena_size_mb: i32 = blk: {
            if (CVars.getGlobal()) |registry| {
                if (registry.getAsStringAlloc("r_frame_arena_size_mb", allocator)) |value| {
                    defer allocator.free(value);
                    if (std.fmt.parseInt(i32, value, 10)) |parsed| {
                        break :blk parsed;
                    } else |_| {
                        log(.WARN, "buffer_manager", "Failed to parse frame_arena_size_mb CVar, using default {}MB", .{DEFAULT_FRAME_ARENA_SIZE_MB});
                    }
                }
            }
            break :blk DEFAULT_FRAME_ARENA_SIZE_MB;
        };

        const arena_size_bytes = @as(usize, @intCast(arena_size_mb)) * 1024 * 1024;

        const self = try allocator.create(BufferManager);
        self.* = .{
            .allocator = allocator,
            .graphics_context = graphics_context,
            .resource_binder = resource_binder,
            .deferred_buffers = undefined,
            .stale_buffers = undefined,
            .frame_arenas = undefined, // Will initialize below
            .all_buffers = std.StringHashMap(BufferStats).init(allocator),
            .managed_buffers = std.ArrayList(*ManagedBuffer){},
        };

        // Initialize ring buffer arrays
        for (&self.deferred_buffers) |*slot| {
            slot.* = std.ArrayList(*ManagedBuffer){};
        }

        for (&self.stale_buffers) |*slot| {
            slot.* = std.ArrayList(Buffer){};
        }

        // Initialize frame arenas with size from CVar
        for (&self.frame_arenas, 0..) |*arena, i| {
            const frame_idx = @as(u32, @intCast(i));
            arena.* = FrameArena.init(frame_idx, allocator);
            arena.capacity = arena_size_bytes;

            const arena_name = try std.fmt.allocPrint(allocator, "frame_arena_{d}", .{frame_idx});
            defer allocator.free(arena_name);

            // Create the backing buffer (host-visible for direct writes)
            const buffer_config = BufferConfig{
                .name = arena_name,
                .size = arena_size_bytes,
                .strategy = .host_visible,
                .usage = .{
                    .storage_buffer_bit = true,
                    .uniform_buffer_bit = true,
                    .transfer_dst_bit = true,
                },
            };

            const managed_buffer = try self.createBuffer(buffer_config, frame_idx);
            arena.buffer = managed_buffer.*;
        }

        log(.INFO, "buffer_manager", "BufferManager initialized with {} frame arenas ({d}MB each)", .{ MAX_FRAMES_IN_FLIGHT, arena_size_bytes / (1024 * 1024) });
        return self;
    }

    pub fn deinit(self: *BufferManager) void {
        // Clean up frame arenas
        for (&self.frame_arenas) |*arena| {
            arena.deinit();
        }

        // Clean up all deferred buffers
        for (&self.deferred_buffers) |*slot| {
            self.cleanupRingSlot(slot);
            slot.deinit(self.allocator);
        }

        // Clean up all stale buffers
        for (&self.stale_buffers) |*slot| {
            for (slot.items) |*buffer| {
                buffer.deinit();
            }
            slot.deinit(self.allocator);
        }

        self.managed_buffers.deinit(self.allocator);
        self.all_buffers.deinit();
        self.allocator.destroy(self);
        log(.INFO, "buffer_manager", "BufferManager deinitialized", .{});
    }

    /// Create buffer with specified strategy
    /// Returns a pointer to the managed buffer which is automatically registered.
    pub fn createBuffer(
        self: *BufferManager,
        config: BufferConfig,
        _: u32, // frame_index currently unused but reserved for future frame tracking
    ) !*ManagedBuffer {
        // Duplicate the name for ownership
        const owned_name = try self.allocator.dupe(u8, config.name);
        errdefer self.allocator.free(owned_name);

        // Create the buffer based on strategy
        const buffer = switch (config.strategy) {
            .device_local => try self.createDeviceLocalBuffer(config),
            .host_visible => try self.createHostVisibleBuffer(config),
            .host_cached => try self.createHostCachedBuffer(config),
        };

        // Allocate the managed buffer on the heap so we can track it
        const managed = try self.allocator.create(ManagedBuffer);
        errdefer self.allocator.destroy(managed);

        managed.* = ManagedBuffer{
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

        // Automatically register for tracking
        try self.registerBuffer(managed);

        return managed;
    }

    /// Allocate from frame arena for dynamic per-frame data
    /// Returns a view into the arena buffer with the allocated offset
    /// The returned ManagedBuffer should NOT be freed - it's a view into the arena
    ///
    /// On success: Sets arena_offset on managed_buffer
    /// On error.ArenaRequiresCompaction: Caller should fall back to dedicated buffer
    ///   and call managed_buffer.markUpdated() to ensure descriptors get rebound
    pub fn allocateFromFrameArena(
        self: *BufferManager,
        frame_index: u32,
        managed_buffer: *ManagedBuffer,
        size: usize,
        alignment: usize,
    ) !struct { buffer: *ManagedBuffer, offset: usize } {
        if (frame_index >= MAX_FRAMES_IN_FLIGHT) {
            return error.InvalidFrameIndex;
        }

        const arena = &self.frame_arenas[frame_index];
        const offset = try arena.allocate(managed_buffer, size, alignment);

        // Set arena offset on the managed buffer (not returned buffer - that's the arena's buffer)
        managed_buffer.arena_offset = offset;
        managed_buffer.markUpdated(); // Mark for descriptor rebinding

        return .{
            .buffer = &arena.buffer,
            .offset = offset,
        };
    }

    /// Free an allocation from frame arena (updates smallest_used_offset)
    pub fn freeFromFrameArena(self: *BufferManager, frame_index: u32, managed_buffer: *ManagedBuffer) void {
        if (frame_index >= MAX_FRAMES_IN_FLIGHT) return;
        self.frame_arenas[frame_index].freeAllocation(managed_buffer);
    }

    /// Compact a frame arena - creates new arena buffer, copies active allocations, increments generations
    /// Call this at frame start if arena.needs_compaction is true
    pub fn compactFrameArena(self: *BufferManager, frame_index: u32) !void {
        if (frame_index >= MAX_FRAMES_IN_FLIGHT) return error.InvalidFrameIndex;

        const arena = &self.frame_arenas[frame_index];
        if (!arena.needs_compaction) return; // Nothing to do

        log(.INFO, "buffer_manager", "Compacting frame arena {} ({} active allocations)", .{ frame_index, arena.active_allocations.items.len });

        // Create new arena buffer
        const arena_name = try std.fmt.allocPrint(self.allocator, "frame_arena_{d}_compact", .{frame_index});
        defer self.allocator.free(arena_name);

        const buffer_config = BufferConfig{
            .name = arena_name,
            .size = arena.capacity,
            .strategy = .host_visible,
            .usage = .{
                .storage_buffer_bit = true,
                .uniform_buffer_bit = true,
                .transfer_dst_bit = true,
                .transfer_src_bit = true, // For copies
            },
        };

        const new_managed_buffer = try self.createBuffer(buffer_config, frame_index);
        const new_buffer = &new_managed_buffer.buffer;
        const old_buffer = &arena.buffer.buffer;

        // Map both buffers for copying
        const new_data = try new_buffer.map();
        const old_data = try old_buffer.map();

        // Copy all active allocations to new buffer, compacting them
        var new_offset: usize = 0;
        for (arena.active_allocations.items) |*alloc| {
            const aligned_offset = std.mem.alignForward(usize, new_offset, 16); // Assume 16-byte alignment

            // Copy data from old to new
            const src = old_data[alloc.offset .. alloc.offset + alloc.size];
            const dst = new_data[aligned_offset .. aligned_offset + alloc.size];
            @memcpy(dst, src);

            // Update the managed buffer with new offset and mark as updated
            alloc.managed_buffer.arena_offset = aligned_offset;
            alloc.managed_buffer.markUpdated(); // Increments generation and sets pending_bind_mask

            // Update allocation tracking
            alloc.offset = aligned_offset;

            new_offset = aligned_offset + alloc.size;
        }

        old_buffer.unmap();
        new_buffer.unmap();

        // Queue old arena buffer for deferred destruction
        try self.deferBufferDestruction(&arena.buffer);

        // Replace arena buffer with new compacted one
        arena.buffer = new_managed_buffer.*;
        arena.current_offset = new_offset;
        arena.smallest_used_offset = if (arena.active_allocations.items.len > 0) 0 else 0;
        arena.needs_compaction = false;

        log(.INFO, "buffer_manager", "Arena {} compacted: {d}KB -> {d}KB used", .{ frame_index, arena.capacity / 1024, new_offset / 1024 });
    }

    /// Reset frame arena for reuse (typically called when arena fills up or explicit reset needed)
    pub fn resetFrameArena(self: *BufferManager, frame_index: u32) void {
        if (frame_index >= MAX_FRAMES_IN_FLIGHT) return;
        self.frame_arenas[frame_index].reset();
    }

    /// Check if any arenas need compaction and perform it
    /// Call this at the start of each frame before any allocations
    pub fn compactArenasIfNeeded(self: *BufferManager) !void {
        for (&self.frame_arenas, 0..) |*arena, i| {
            if (arena.needs_compaction) {
                try self.compactFrameArena(@intCast(i));
            }
        }
    }

    /// Create and upload data in one call (device-local only)
    pub fn createAndUpload(
        self: *BufferManager,
        name: []const u8,
        data: []const u8,
        frame_index: u32,
    ) !*ManagedBuffer {
        const config = BufferConfig{
            .name = name,
            .size = data.len,
            .strategy = .device_local,
            .usage = .{ .vertex_buffer_bit = true, .transfer_dst_bit = true },
        };

        const managed = try self.createBuffer(config, frame_index);
        try self.updateBuffer(managed, data, frame_index);

        return managed;
    }

    /// Update buffer contents (strategy-aware)
    pub fn updateBuffer(
        self: *BufferManager,
        managed_buffer: *ManagedBuffer,
        data: []const u8,
        _: u32, // frame_index currently unused but reserved for future frame tracking
    ) !void {
        try self.updateBufferRegion(managed_buffer, data, 0);
    }

    /// Update a specific region of the buffer (granular updates)
    pub fn updateBufferRegion(
        self: *BufferManager,
        managed_buffer: *ManagedBuffer,
        data: []const u8,
        offset: vk.DeviceSize,
    ) !void {
        switch (managed_buffer.strategy) {
            .device_local => {
                // Use staging buffer for device-local buffers
                try self.uploadViaStagingWithOffset(&managed_buffer.buffer, data, offset);
            },
            .host_visible => {
                // Direct write for host-visible buffers at offset
                try managed_buffer.buffer.map(data.len, offset);
                managed_buffer.buffer.writeToBuffer(data, data.len, offset);
                managed_buffer.buffer.unmap();
            },
            .host_cached => {
                // Direct write + manual flush for host-cached buffers at offset
                try managed_buffer.buffer.map(data.len, offset);
                managed_buffer.buffer.writeToBuffer(data, data.len, offset);
                // Flush for cached memory (Buffer has flush method)
                try managed_buffer.buffer.flush(data.len, offset);
                managed_buffer.buffer.unmap();
            },
        }

        // Note: Generation is NOT incremented on data updates
        // Generation only increments when the buffer handle changes (recreation)
        // Data updates don't require descriptor set rebinding

        // Update statistics
        if (self.all_buffers.getPtr(managed_buffer.name)) |stats| {
            stats.last_updated = self.frame_counter;
        }
    }

    /// Resize an existing buffer by recreating the underlying Vulkan buffer
    /// Keeps the ManagedBuffer pointer stable but increments generation for rebinding
    pub fn resizeBuffer(
        self: *BufferManager,
        managed_buffer: *ManagedBuffer,
        new_size: vk.DeviceSize,
        usage: vk.BufferUsageFlags,
    ) !void {
        if (new_size == managed_buffer.size) {
            return; // No resize needed
        }

        log(.INFO, "buffer_manager", "Resizing buffer '{s}' from {} to {} bytes", .{
            managed_buffer.name,
            managed_buffer.size,
            new_size,
        });

        // Defer destruction of old buffer - it may still be referenced by descriptor sets
        const old_buffer = managed_buffer.buffer;
        try self.stale_buffers[self.current_frame].append(self.allocator, old_buffer);

        // Create new buffer with same strategy but new size
        const config = BufferConfig{
            .name = managed_buffer.name,
            .size = new_size,
            .strategy = managed_buffer.strategy,
            .usage = usage,
        };

        managed_buffer.buffer = switch (config.strategy) {
            .device_local => try self.createDeviceLocalBuffer(config),
            .host_visible => try self.createHostVisibleBuffer(config),
            .host_cached => try self.createHostCachedBuffer(config),
        };

        // Update managed buffer metadata
        managed_buffer.size = new_size;
        managed_buffer.markUpdated(); // Increment generation and set pending_bind_mask

        // Update statistics
        if (self.all_buffers.getPtr(managed_buffer.name)) |stats| {
            stats.size = new_size;
            stats.last_updated = self.frame_counter;
        }
    }

    /// Register a managed buffer for tracking
    pub fn registerBuffer(self: *BufferManager, managed: *ManagedBuffer) !void {
        try self.managed_buffers.append(self.allocator, managed);
    }

    /// Unregister a managed buffer (call before destroying)
    /// Safe to call even if buffer was never registered
    pub fn unregisterBuffer(self: *BufferManager, managed: *ManagedBuffer) void {
        // Find and remove the buffer from the registry
        var i: usize = 0;
        while (i < self.managed_buffers.items.len) {
            if (self.managed_buffers.items[i] == managed) {
                _ = self.managed_buffers.swapRemove(i);
                return;
            }
            i += 1;
        }
        // Buffer not found in registry - this is OK
    }

    /// Called at frame start to cleanup old buffers
    pub fn beginFrame(self: *BufferManager, frame_index: u32) void {
        self.current_frame = frame_index;
        self.frame_counter += 1;

        // Cleanup stale buffers from resizing
        const stale_slot = &self.stale_buffers[frame_index];
        for (stale_slot.items) |*buffer| {
            buffer.deinit();
        }
        stale_slot.clearRetainingCapacity();

        // Cleanup buffers that are now safe to destroy
        const cleanup_slot = &self.deferred_buffers[frame_index];
        self.cleanupRingSlot(cleanup_slot);
    }

    /// Queue buffer for deferred destruction
    pub fn destroyBuffer(self: *BufferManager, managed_buffer: *ManagedBuffer) !void {
        log(.INFO, "buffer_manager", "Destroying buffer '{s}'", .{managed_buffer.name});

        // Unregister from tracking list
        self.unregisterBuffer(managed_buffer);

        // Add to deferred cleanup slot
        const slot = &self.deferred_buffers[self.current_frame];
        try slot.append(self.allocator, managed_buffer);

        // Remove from statistics
        _ = self.all_buffers.remove(managed_buffer.name);
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
        try self.uploadViaStagingWithOffset(dst, data, 0);
    }

    /// Create staging buffer and upload to device at specific offset
    fn uploadViaStagingWithOffset(
        self: *BufferManager,
        dst: *Buffer,
        data: []const u8,
        offset: vk.DeviceSize,
    ) !void {
        var staging = try Buffer.init(
            self.graphics_context,
            data.len,
            1,
            .{ .transfer_src_bit = true },
            .{ .host_visible_bit = true, .host_coherent_bit = true },
        );
        defer staging.deinit();

        try staging.map(data.len, 0);
        staging.writeToBuffer(data, data.len, 0);
        staging.unmap();

        // Copy from staging to destination buffer using graphics context
        // GraphicsContext needs to support offset for partial copy
        try self.graphics_context.copyFromStagingBufferWithOffset(dst.buffer, &staging, data.len, offset);
    }

    /// Cleanup buffers in ring slot
    fn cleanupRingSlot(self: *BufferManager, slot: *std.ArrayList(*ManagedBuffer)) void {
        for (slot.items) |managed| {
            // Clear tracking name before deinit to prevent use-after-free
            // (the buffer's tracking_name points to managed.name which we'll free)
            managed.buffer.tracking_name = null;

            managed.buffer.deinit();

            // Free the name string
            self.allocator.free(managed.name);

            // Free the managed buffer itself
            self.allocator.destroy(managed);
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
