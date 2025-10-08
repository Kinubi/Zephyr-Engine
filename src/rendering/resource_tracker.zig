const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("../core/graphics_context.zig").GraphicsContext;
const log = @import("../utils/log.zig").log;

/// GPU resource types tracked by the system
pub const ResourceType = enum {
    buffer,
    image,
    image_view,
    descriptor_set,
    pipeline,
    render_pass,
    framebuffer,
};

/// Resource usage flags for barrier generation
pub const ResourceUsageFlags = packed struct {
    vertex_buffer: bool = false,
    index_buffer: bool = false,
    uniform_buffer: bool = false,
    storage_buffer: bool = false,
    color_attachment: bool = false,
    depth_attachment: bool = false,
    shader_read: bool = false,
    shader_write: bool = false,
    transfer_src: bool = false,
    transfer_dst: bool = false,

    pub fn toPipelineStageFlags(self: ResourceUsageFlags) vk.PipelineStageFlags {
        var flags: vk.PipelineStageFlags = .{};

        if (self.vertex_buffer or self.index_buffer) {
            flags.vertex_input_bit = true;
        }
        if (self.uniform_buffer or self.shader_read) {
            flags.vertex_shader_bit = true;
            flags.fragment_shader_bit = true;
            flags.compute_shader_bit = true;
        }
        if (self.storage_buffer or self.shader_write) {
            flags.compute_shader_bit = true;
        }
        if (self.color_attachment) {
            flags.color_attachment_output_bit = true;
        }
        if (self.depth_attachment) {
            flags.early_fragment_tests_bit = true;
            flags.late_fragment_tests_bit = true;
        }
        if (self.transfer_src or self.transfer_dst) {
            flags.transfer_bit = true;
        }

        return flags;
    }

    pub fn toAccessFlags(self: ResourceUsageFlags) vk.AccessFlags {
        var flags: vk.AccessFlags = .{};

        if (self.vertex_buffer) flags.vertex_attribute_read_bit = true;
        if (self.index_buffer) flags.index_read_bit = true;
        if (self.uniform_buffer) flags.uniform_read_bit = true;
        if (self.storage_buffer) {
            flags.shader_read_bit = true;
            flags.shader_write_bit = true;
        }
        if (self.shader_read) flags.shader_read_bit = true;
        if (self.shader_write) flags.shader_write_bit = true;
        if (self.color_attachment) {
            flags.color_attachment_read_bit = true;
            flags.color_attachment_write_bit = true;
        }
        if (self.depth_attachment) {
            flags.depth_stencil_attachment_read_bit = true;
            flags.depth_stencil_attachment_write_bit = true;
        }
        if (self.transfer_src) flags.transfer_read_bit = true;
        if (self.transfer_dst) flags.transfer_write_bit = true;

        return flags;
    }
};

/// Resource state for barrier tracking
pub const ResourceState = struct {
    layout: vk.ImageLayout = .undefined,
    access_flags: vk.AccessFlags = .{},
    stage_flags: vk.PipelineStageFlags = .{ .top_of_pipe_bit = true },
    queue_family: u32 = vk.QUEUE_FAMILY_IGNORED,
};

/// Tracked resource information
pub const TrackedResource = struct {
    handle: u64, // Generic handle (buffer/image/etc.)
    resource_type: ResourceType,
    current_state: ResourceState,
    pending_state: ?ResourceState = null,
    name: []const u8,
};

/// Automatic resource barrier for synchronization
pub const ResourceBarrier = struct {
    resource_handle: u64,
    resource_type: ResourceType,
    src_stage: vk.PipelineStageFlags,
    dst_stage: vk.PipelineStageFlags,
    src_access: vk.AccessFlags,
    dst_access: vk.AccessFlags,
    old_layout: vk.ImageLayout,
    new_layout: vk.ImageLayout,
    src_queue_family: u32 = vk.QUEUE_FAMILY_IGNORED,
    dst_queue_family: u32 = vk.QUEUE_FAMILY_IGNORED,
};

/// ResourceTracker manages GPU resource states and generates barriers automatically
pub const ResourceTracker = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    graphics_context: *GraphicsContext,
    resources: std.HashMap(u64, TrackedResource, std.hash_map.DefaultContext(u64), std.hash_map.default_max_load_percentage),
    pending_barriers: std.ArrayList(ResourceBarrier),

    pub fn init(allocator: std.mem.Allocator, graphics_context: *GraphicsContext) Self {
        return Self{
            .allocator = allocator,
            .graphics_context = graphics_context,
            .resources = std.HashMap(u64, TrackedResource, std.hash_map.DefaultContext(u64), std.hash_map.default_max_load_percentage).init(allocator),
            .pending_barriers = std.ArrayList(ResourceBarrier).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.resources.deinit();
        self.pending_barriers.deinit();
    }

    /// Register a buffer for tracking
    pub fn trackBuffer(self: *Self, buffer: vk.Buffer, name: []const u8) !void {
        const handle = @intFromPtr(buffer.handle);
        const resource = TrackedResource{
            .handle = handle,
            .resource_type = .buffer,
            .current_state = ResourceState{
                .access_flags = .{},
                .stage_flags = .{ .top_of_pipe_bit = true },
            },
            .name = try self.allocator.dupe(u8, name),
        };

        try self.resources.put(handle, resource);
    }

    /// Register an image for tracking
    pub fn trackImage(self: *Self, image: vk.Image, initial_layout: vk.ImageLayout, name: []const u8) !void {
        const handle = @intFromPtr(image.handle);
        const resource = TrackedResource{
            .handle = handle,
            .resource_type = .image,
            .current_state = ResourceState{
                .layout = initial_layout,
                .access_flags = .{},
                .stage_flags = .{ .top_of_pipe_bit = true },
            },
            .name = try self.allocator.dupe(u8, name),
        };

        try self.resources.put(handle, resource);
    }

    /// Request a resource transition
    pub fn requestTransition(self: *Self, handle: u64, usage: ResourceUsageFlags, layout: ?vk.ImageLayout) !void {
        if (self.resources.getPtr(handle)) |resource| {
            const new_access = usage.toAccessFlags();
            const new_stage = usage.toPipelineStageFlags();
            const new_layout = layout orelse resource.current_state.layout;

            // Check if transition is needed
            if (!std.meta.eql(resource.current_state.access_flags, new_access) or
                !std.meta.eql(resource.current_state.stage_flags, new_stage) or
                resource.current_state.layout != new_layout)
            {
                const barrier = ResourceBarrier{
                    .resource_handle = handle,
                    .resource_type = resource.resource_type,
                    .src_stage = resource.current_state.stage_flags,
                    .dst_stage = new_stage,
                    .src_access = resource.current_state.access_flags,
                    .dst_access = new_access,
                    .old_layout = resource.current_state.layout,
                    .new_layout = new_layout,
                };

                try self.pending_barriers.append(barrier);

                // Update pending state
                resource.pending_state = ResourceState{
                    .layout = new_layout,
                    .access_flags = new_access,
                    .stage_flags = new_stage,
                    .queue_family = resource.current_state.queue_family,
                };
            }
        }
    }

    /// Emit all pending barriers to command buffer
    pub fn emitBarriers(self: *Self, command_buffer: vk.CommandBuffer) !void {
        if (self.pending_barriers.items.len == 0) return;

        var memory_barriers = std.ArrayList(vk.MemoryBarrier).init(self.allocator);
        defer memory_barriers.deinit();
        var buffer_barriers = std.ArrayList(vk.BufferMemoryBarrier).init(self.allocator);
        defer buffer_barriers.deinit();
        var image_barriers = std.ArrayList(vk.ImageMemoryBarrier).init(self.allocator);
        defer image_barriers.deinit();

        var src_stage_mask: vk.PipelineStageFlags = .{};
        var dst_stage_mask: vk.PipelineStageFlags = .{};

        for (self.pending_barriers.items) |barrier| {
            src_stage_mask = unionFlags(src_stage_mask, barrier.src_stage);
            dst_stage_mask = unionFlags(dst_stage_mask, barrier.dst_stage);

            switch (barrier.resource_type) {
                .buffer => {
                    const buffer_barrier = vk.BufferMemoryBarrier{
                        .src_access_mask = barrier.src_access,
                        .dst_access_mask = barrier.dst_access,
                        .src_queue_family_index = barrier.src_queue_family,
                        .dst_queue_family_index = barrier.dst_queue_family,
                        .buffer = @ptrFromInt(barrier.resource_handle),
                        .offset = 0,
                        .size = vk.WHOLE_SIZE,
                    };
                    try buffer_barriers.append(buffer_barrier);
                },
                .image => {
                    const image_barrier = vk.ImageMemoryBarrier{
                        .src_access_mask = barrier.src_access,
                        .dst_access_mask = barrier.dst_access,
                        .old_layout = barrier.old_layout,
                        .new_layout = barrier.new_layout,
                        .src_queue_family_index = barrier.src_queue_family,
                        .dst_queue_family_index = barrier.dst_queue_family,
                        .image = @ptrFromInt(barrier.resource_handle),
                        .subresource_range = vk.ImageSubresourceRange{
                            .aspect_mask = .{ .color_bit = true },
                            .base_mip_level = 0,
                            .level_count = vk.REMAINING_MIP_LEVELS,
                            .base_array_layer = 0,
                            .layer_count = vk.REMAINING_ARRAY_LAYERS,
                        },
                    };
                    try image_barriers.append(image_barrier);
                },
                else => {
                    // Generic memory barrier for other resource types
                    const memory_barrier = vk.MemoryBarrier{
                        .src_access_mask = barrier.src_access,
                        .dst_access_mask = barrier.dst_access,
                    };
                    try memory_barriers.append(memory_barrier);
                },
            }
        }

        // Emit pipeline barrier
        self.graphics_context.device.cmdPipelineBarrier(
            command_buffer,
            src_stage_mask,
            dst_stage_mask,
            .{},
            @intCast(memory_barriers.items.len),
            if (memory_barriers.items.len > 0) memory_barriers.items.ptr else null,
            @intCast(buffer_barriers.items.len),
            if (buffer_barriers.items.len > 0) buffer_barriers.items.ptr else null,
            @intCast(image_barriers.items.len),
            if (image_barriers.items.len > 0) image_barriers.items.ptr else null,
        );

        // Apply pending states
        for (self.pending_barriers.items) |barrier| {
            if (self.resources.getPtr(barrier.resource_handle)) |resource| {
                if (resource.pending_state) |pending| {
                    resource.current_state = pending;
                    resource.pending_state = null;
                }
            }
        }

        // Clear barriers
        self.pending_barriers.clearAndFree();
    }

    /// Helper to union pipeline stage flags
    fn unionFlags(a: vk.PipelineStageFlags, b: vk.PipelineStageFlags) vk.PipelineStageFlags {
        return @bitCast(@as(u32, @bitCast(a)) | @as(u32, @bitCast(b)));
    }

    /// Get current resource state
    pub fn getResourceState(self: *const Self, handle: u64) ?ResourceState {
        if (self.resources.get(handle)) |resource| {
            return resource.current_state;
        }
        return null;
    }

    /// Untrack a resource
    pub fn untrack(self: *Self, handle: u64) void {
        if (self.resources.fetchRemove(handle)) |entry| {
            self.allocator.free(entry.value.name);
        }
    }

    /// Get resource tracking statistics
    pub fn getStats(self: *const Self) struct {
        tracked_resources: usize,
        pending_barriers: usize,
    } {
        return .{
            .tracked_resources = self.resources.count(),
            .pending_barriers = self.pending_barriers.items.len,
        };
    }

    /// Print debug information
    pub fn printDebugInfo(self: *const Self) void {
        log(.INFO, "resource_tracker", "=== Resource Tracker Debug Info ===", .{});
        log(.INFO, "resource_tracker", "Tracked Resources: {d}", .{self.resources.count()});
        log(.INFO, "resource_tracker", "Pending Barriers: {d}", .{self.pending_barriers.items.len});

        var iterator = self.resources.iterator();
        while (iterator.next()) |entry| {
            const resource = entry.value_ptr.*;
            log(.INFO, "resource_tracker", "  Resource: {s} (type: {s}, handle: 0x{X})", .{
                resource.name,
                @tagName(resource.resource_type),
                resource.handle,
            });
        }
    }
};
