const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vulkan");
const c = @import("c.zig");
const Allocator = std.mem.Allocator;
const MAX_FRAMES_IN_FLIGHT = @import("swapchain.zig").MAX_FRAMES_IN_FLIGHT;
const Buffer = @import("buffer.zig").Buffer;
const log = @import("../utils/log.zig").log;

const required_device_extensions = [_][*:0]const u8{
    vk.extensions.khr_swapchain.name,
    vk.extensions.khr_dynamic_rendering.name,
    vk.extensions.khr_acceleration_structure.name,
    vk.extensions.khr_ray_tracing_pipeline.name,
    vk.extensions.khr_ray_query.name,
    vk.extensions.khr_deferred_host_operations.name,
    vk.extensions.ext_swapchain_maintenance_1.name,
};

const optional_device_extensions = [_][*:0]const u8{};

const required_instance_extensions = [_][*:0]const u8{
    vk.extensions.khr_get_surface_capabilities_2.name,
    vk.extensions.ext_surface_maintenance_1.name,
};

const optional_instance_extensions = [_][*:0]const u8{
    vk.extensions.khr_get_physical_device_properties_2.name,
        //vk.extensions.khr_portability_enumeration.name,
};
const apis: []const vk.ApiInfo = &.{
    // You can either add invidiual functions by manually creating an 'api'
    .{
        .base_commands = .{
            .createInstance = true,
        },
        .instance_commands = .{
            .createDevice = true,
        },
        .device_commands = .{
            .createShaderModule = true,
        },
    },
    // Or you can add entire feature sets or extensions
    vk.features.version_1_4,
    vk.extensions.khr_swapchain,
    vk.extensions.khr_ray_query,
    vk.extensions.khr_acceleration_structure,
    vk.extensions.ext_swapchain_maintenance_1,
    vk.extensions.ext_surface_maintenance_1,
};

/// Next, pass the `apis` to the wrappers to create dispatch tables.
const BaseWrapper = vk.BaseWrapper;
const InstanceWrapper = vk.InstanceWrapper;
const DeviceWrapper = vk.DeviceWrapper;

pub const GraphicsContext = struct {
    const WorkerCommandPool = struct {
        id: std.Thread.Id,
        pool: vk.CommandPool,
    };

    vkb: BaseWrapper,
    vki: InstanceWrapper,
    vkd: DeviceWrapper,

    instance: vk.Instance,
    surface: vk.SurfaceKHR,
    pdev: vk.PhysicalDevice,
    props: vk.PhysicalDeviceProperties,
    mem_props: vk.PhysicalDeviceMemoryProperties,

    dev: vk.Device,
    graphics_queue: Queue,
    present_queue: Queue,
    compute_queue: Queue, // Added for async compute
    command_pool: vk.CommandPool,
    main_thread_id: std.Thread.Id,
    allocator: Allocator,
    worker_command_pools: std.ArrayList(WorkerCommandPool),
    command_pool_mutex: std.Thread.Mutex,

    // Queue submission synchronization
    // Vulkan spec requires external synchronization for queue access from multiple threads
    queue_mutex: std.Thread.Mutex,

    pub fn init(allocator: Allocator, app_name: [*:0]const u8, window: *c.GLFWwindow) !GraphicsContext {
        var self: GraphicsContext = undefined;
        self.vkb = BaseWrapper.load(@as(vk.PfnGetInstanceProcAddr, @ptrCast(&c.glfwGetInstanceProcAddress)));
        self.main_thread_id = std.Thread.getCurrentId();
        self.allocator = allocator;
        self.worker_command_pools = .{};
        self.command_pool_mutex = std.Thread.Mutex{};

        // Initialize double-buffered secondary command buffer collection
        if (!secondary_buffers_initialized) {
            pending_buffers[0] = std.ArrayList(SecondaryCommandBuffer){};
            pending_buffers[1] = std.ArrayList(SecondaryCommandBuffer){};
            secondary_buffers_initialized = true;
        }
        var glfw_ext_count: u32 = 0;
        const glfw_exts_ptr = c.glfwGetRequiredInstanceExtensions(&glfw_ext_count);
        if (glfw_exts_ptr == null) {
            log(.ERROR, "graphics_context", "failed to get required vulkan instance extensions, {}", .{glfw_ext_count});
            return error.code;
        }
        // Convert [*c][*c]const u8 to []const [*:0]const u8 safely
        var glfw_exts = try allocator.alloc([*:0]const u8, glfw_ext_count);
        defer allocator.free(glfw_exts);
        for (0..glfw_ext_count) |i| {
            glfw_exts[i] = glfw_exts_ptr[i];
        }

        var instance_extensions = try std.ArrayList([*:0]const u8).initCapacity(allocator, glfw_exts.len + required_instance_extensions.len + optional_instance_extensions.len);
        defer instance_extensions.deinit(allocator);
        try instance_extensions.appendSlice(allocator, glfw_exts);

        // Add required instance extensions
        try instance_extensions.appendSlice(allocator, &required_instance_extensions);

        var count: u32 = undefined;
        _ = try self.vkb.enumerateInstanceExtensionProperties(null, &count, null);

        const propsv = try allocator.alloc(vk.ExtensionProperties, count);
        defer allocator.free(propsv);

        _ = try self.vkb.enumerateInstanceExtensionProperties(null, &count, propsv.ptr);

        for (optional_instance_extensions) |extension_name| {
            for (propsv) |prop| {
                const len = std.mem.indexOfScalar(u8, &prop.extension_name, 0).?;
                const prop_ext_name = prop.extension_name[0..len];
                if (std.mem.eql(u8, prop_ext_name, std.mem.span(extension_name))) {
                    try instance_extensions.append(allocator, @ptrCast(extension_name));
                    break;
                }
            }
        }
        const instance_layers = &[_][*:0]const u8{"VK_LAYER_KHRONOS_validation"};

        var layer_count: u32 = 0;
        _ = try self.vkb.enumerateInstanceLayerProperties(&layer_count, null);

        const available_layers = try allocator.alloc(vk.LayerProperties, layer_count);
        defer allocator.free(available_layers);
        _ = try self.vkb.enumerateInstanceLayerProperties(&count, available_layers.ptr);

        var layers = try std.ArrayList([*:0]const u8).initCapacity(allocator, instance_layers.len);
        defer layers.deinit(allocator);
        for (instance_layers) |optional| {
            for (available_layers) |available| {
                if (std.mem.eql(
                    u8,
                    std.mem.sliceTo(optional, 0),
                    std.mem.sliceTo(&available.layer_name, 0),
                )) {
                    try layers.append(allocator, optional);
                    break;
                }
            }
        }

        const app_info = vk.ApplicationInfo{
            .p_application_name = app_name,
            .application_version = @bitCast(vk.makeApiVersion(0, 0, 0, 0)),
            .p_engine_name = app_name,
            .engine_version = @bitCast(vk.makeApiVersion(0, 0, 0, 0)),
            .api_version = @bitCast(vk.API_VERSION_1_3),
        };

        self.instance = try self.vkb.createInstance(&vk.InstanceCreateInfo{
            .flags = if (builtin.os.tag == .macos) .{
                .enumerate_portability_bit_khr = true,
            } else .{},
            .p_application_info = &app_info,
            .enabled_layer_count = @intCast(layers.items.len),
            .pp_enabled_layer_names = layers.items.ptr,
            .enabled_extension_count = @intCast(instance_extensions.items.len),
            .pp_enabled_extension_names = @ptrCast(instance_extensions.items),
        }, null);

        self.vki = InstanceWrapper.load(self.instance, self.vkb.dispatch.vkGetInstanceProcAddr.?);
        errdefer self.vki.destroyInstance(self.instance, null);

        self.surface = try createSurface(self.instance, window);
        errdefer self.vki.destroySurfaceKHR(self.instance, self.surface, null);

        const candidate = try pickPhysicalDevice(self.vki, self.instance, allocator, self.surface);
        self.pdev = candidate.pdev;
        self.props = candidate.props;
        self.dev = try initializeCandidate(allocator, self.vki, candidate);
        self.vkd = DeviceWrapper.load(self.dev, self.vki.dispatch.vkGetDeviceProcAddr.?);
        errdefer self.vkd.destroyDevice(self.dev, null);

        self.graphics_queue = Queue.init(self.vkd, self.dev, candidate.queues.graphics_family, false);
        self.present_queue = Queue.init(self.vkd, self.dev, candidate.queues.present_family, false);
        self.compute_queue = Queue.init(self.vkd, self.dev, candidate.queues.compute_family, false);

        self.mem_props = self.vki.getPhysicalDeviceMemoryProperties(self.pdev);

        // Initialize queue synchronization
        self.queue_mutex = std.Thread.Mutex{};

        return self;
    }

    pub fn deinit(self: *GraphicsContext) void {
        self.command_pool_mutex.lock();
        for (self.worker_command_pools.items) |worker_pool| {
            self.vkd.destroyCommandPool(self.dev, worker_pool.pool, null);
        }
        self.worker_command_pools.deinit(self.allocator);
        self.command_pool_mutex.unlock();

        log(.INFO, "graphics_context", "Cleaning up pending secondary command buffers", .{});
        if (secondary_buffers_initialized) {
            const total = pending_buffers[0].items.len + pending_buffers[1].items.len;
            log(.INFO, "graphics_context", "Cleaning {} pending buffers", .{total});
            for (&pending_buffers) |*buffer| {
                for (buffer.items) |*secondary_buf| {
                    secondary_buf.deinit(self);
                }
                buffer.deinit(self.allocator);
            }
        }

        if (submitted_buffers_initialized) {
            log(.INFO, "graphics_context", "Cleaning {} submitted buffers", .{submitted_secondary_buffers.items.len});
            for (submitted_secondary_buffers.items) |*secondary_buf| {
                secondary_buf.deinit(self);
            }
            submitted_secondary_buffers.deinit(self.allocator);
        }

        self.vkd.destroyCommandPool(self.dev, self.command_pool, null);
        self.vkd.destroyDevice(self.dev, null);
        self.vki.destroySurfaceKHR(self.instance, self.surface, null);
        self.vki.destroyInstance(self.instance, null);
    }

    pub fn deviceName(self: GraphicsContext) []const u8 {
        const len = std.mem.indexOfScalar(u8, &self.props.device_name, 0).?;
        return self.props.device_name[0..len];
    }

    pub fn findMemoryTypeIndex(self: GraphicsContext, memory_type_bits: u32, flags: vk.MemoryPropertyFlags) !u32 {
        for (self.mem_props.memory_types[0..self.mem_props.memory_type_count], 0..) |mem_type, i| {
            if (memory_type_bits & (@as(u32, 1) << @as(u5, @truncate(i))) != 0 and mem_type.property_flags.contains(flags)) {
                return @as(u32, @truncate(i));
            }
        }

        return error.NoSuitableMemoryType;
    }

    pub fn allocate(self: GraphicsContext, requirements: vk.MemoryRequirements, flags: vk.MemoryPropertyFlags, allocate_flags: vk.MemoryAllocateFlags) !vk.DeviceMemory {
        return try self.vkd.allocateMemory(self.dev, &.{
            .allocation_size = requirements.size,
            .memory_type_index = try self.findMemoryTypeIndex(requirements.memory_type_bits, flags),
            .p_next = &vk.MemoryAllocateFlagsInfo{
                .flags = allocate_flags,
                .device_mask = 0,
            },
        }, null);
    }

    pub fn createCommandPool(self: *GraphicsContext) !void {
        self.command_pool = try self.vkd.createCommandPool(self.dev, &.{
            .flags = .{ .reset_command_buffer_bit = true },
            .queue_family_index = self.graphics_queue.family,
        }, null);
    }

    /// Returns a command pool appropriate for the current thread.
    /// Main thread uses self.command_pool, worker threads use per-thread pools stored in a hash map.
    pub fn getThreadCommandPool(self: *GraphicsContext) !vk.CommandPool {
        if (std.Thread.getCurrentId() == self.main_thread_id) {
            return self.command_pool;
        } else {
            const thread_id = std.Thread.getCurrentId();

            self.command_pool_mutex.lock();
            defer self.command_pool_mutex.unlock();

            for (self.worker_command_pools.items) |worker_pool| {
                if (worker_pool.id == thread_id) {
                    return worker_pool.pool;
                }
            }

            const new_pool = try self.vkd.createCommandPool(self.dev, &.{
                .flags = .{ .reset_command_buffer_bit = true },
                .queue_family_index = self.graphics_queue.family,
            }, null);
            try self.worker_command_pools.append(self.allocator, .{ .id = thread_id, .pool = new_pool });

            return new_pool;
        }
    }

    /// Clean up thread-local command pool (should be called when worker thread exits)
    pub fn cleanupThreadCommandPool(self: *GraphicsContext) void {
        if (std.Thread.getCurrentId() == self.main_thread_id) {
            return;
        }

        const thread_id = std.Thread.getCurrentId();
        self.command_pool_mutex.lock();
        defer self.command_pool_mutex.unlock();

        var index: usize = 0;
        while (index < self.worker_command_pools.items.len) : (index += 1) {
            if (self.worker_command_pools.items[index].id == thread_id) {
                const removed = self.worker_command_pools.swapRemove(index);
                self.vkd.destroyCommandPool(self.dev, removed.pool, null);
                break;
            }
        }
    }

    /// Reset all worker thread command pools
    /// This frees all command buffers allocated from worker pools, including orphaned secondary buffers
    /// THREAD-SAFE: Must be called from render thread when no workers are active
    pub fn resetAllWorkerCommandPools(self: *GraphicsContext) void {
        self.command_pool_mutex.lock();
        defer self.command_pool_mutex.unlock();

        for (self.worker_command_pools.items) |worker_pool| {
            // Reset the entire pool, freeing all command buffers
            self.vkd.resetCommandPool(self.dev, worker_pool.pool, .{}) catch |err| {
                log(.ERROR, "graphics_context", "Failed to reset worker command pool: {}", .{err});
            };
        }

        log(.DEBUG, "graphics_context", "Reset {} worker command pools", .{self.worker_command_pools.items.len});
    }

    pub fn getThreadQueue(self: *GraphicsContext) !Queue {
        // Use Zig's threadlocal storage for worker command pools
        return self.graphics_queue;
    }

    /// Copy buffer using worker-friendly secondary command buffer approach
    pub fn copyBuffer(self: *GraphicsContext, dst: vk.Buffer, src: vk.Buffer, size: vk.DeviceSize) !void {
        // Check if we're on a worker thread
        if (std.Thread.getCurrentId() != self.main_thread_id) {
            // Use secondary command buffer (no queue submission)
            var secondary_cmd = try self.beginWorkerCommandBuffer();
            const region = vk.BufferCopy{
                .src_offset = 0,
                .dst_offset = 0,
                .size = size,
            };
            self.vkd.cmdCopyBuffer(secondary_cmd.command_buffer, src, dst, 1, @ptrCast(&region));
            try self.endWorkerCommandBuffer(&secondary_cmd);
        } else {
            // Main thread can use legacy approach for now
            const command_buffer = try self.beginSingleTimeCommands();
            defer self.endSingleTimeCommands(command_buffer) catch |err| {
                log(.ERROR, "graphics_context", "endSingleTimeCommands failed: {any}", .{err});
            };
            const region = vk.BufferCopy{
                .src_offset = 0,
                .dst_offset = 0,
                .size = size,
            };
            self.vkd.cmdCopyBuffer(command_buffer, src, dst, 1, @ptrCast(&region));
        }
    }

    pub fn copyBufferWithOffset(self: *GraphicsContext, dst: vk.Buffer, src: vk.Buffer, size: vk.DeviceSize, dst_offset: vk.DeviceSize, src_offset: vk.DeviceSize) !void {
        // Check if we're on a worker thread
        if (std.Thread.getCurrentId() != self.main_thread_id) {
            // Use secondary command buffer (no queue submission)
            var secondary_cmd = try self.beginWorkerCommandBuffer();
            const region = vk.BufferCopy{
                .src_offset = src_offset,
                .dst_offset = dst_offset,
                .size = size,
            };
            self.vkd.cmdCopyBuffer(secondary_cmd.command_buffer, src, dst, 1, @ptrCast(&region));
            try self.endWorkerCommandBuffer(&secondary_cmd);
        } else {
            // Main thread can use legacy approach for now
            const command_buffer = try self.beginSingleTimeCommands();
            defer self.endSingleTimeCommands(command_buffer) catch |err| {
                log(.ERROR, "graphics_context", "endSingleTimeCommands failed: {any}", .{err});
            };
            const region = vk.BufferCopy{
                .src_offset = src_offset,
                .dst_offset = dst_offset,
                .size = size,
            };
            self.vkd.cmdCopyBuffer(command_buffer, src, dst, 1, @ptrCast(&region));
        }
    }

    /// Copy from staging buffer with proper lifetime management for worker threads
    pub fn copyFromStagingBuffer(self: *GraphicsContext, dst: vk.Buffer, staging_buffer: *Buffer, size: vk.DeviceSize) !void {
        // Check if we're on a worker thread
        if (std.Thread.getCurrentId() != self.main_thread_id) {
            // Use secondary command buffer with staging buffer lifetime management
            staging_buffer.unmap();
            var secondary_cmd = try self.beginWorkerCommandBuffer();
            const region = vk.BufferCopy{
                .src_offset = 0,
                .dst_offset = 0,
                .size = size,
            };
            self.vkd.cmdCopyBuffer(secondary_cmd.command_buffer, staging_buffer.buffer, dst, 1, @ptrCast(&region));
            // Add staging buffer to pending resources (will be cleaned up after command execution)
            try secondary_cmd.addPendingResource(staging_buffer.buffer, staging_buffer.memory);
            try self.endWorkerCommandBuffer(&secondary_cmd);
            staging_buffer.buffer = vk.Buffer.null_handle;
            staging_buffer.memory = vk.DeviceMemory.null_handle;
            staging_buffer.descriptor_info.buffer = vk.Buffer.null_handle;
            // Don't call staging_buffer.deinit() - it will be cleaned up after command execution
        } else {
            // Main thread executes command synchronously
            const region = vk.BufferCopy{
                .src_offset = 0,
                .dst_offset = 0,
                .size = size,
            };
            const command_buffer = try self.beginSingleTimeCommands();
            self.vkd.cmdCopyBuffer(command_buffer, staging_buffer.buffer, dst, 1, @ptrCast(&region));
            // End and execute synchronously, then cleanup
            try self.endSingleTimeCommands(command_buffer);
            // Now safe to deinit staging buffer since command has executed
            staging_buffer.deinit();
        }
    }

    pub fn createCommandBuffers(
        self: *GraphicsContext,
        allocator: Allocator,
    ) ![]vk.CommandBuffer {
        const cmdbufs = try allocator.alloc(vk.CommandBuffer, MAX_FRAMES_IN_FLIGHT);
        errdefer allocator.free(cmdbufs);

        try self.vkd.allocateCommandBuffers(self.dev, &vk.CommandBufferAllocateInfo{
            .command_pool = self.command_pool,
            .level = .primary,
            .command_buffer_count = @truncate(cmdbufs.len),
        }, cmdbufs.ptr);
        errdefer self.vkd.freeCommandBuffers(self.dev, self.command_pool, @truncate(cmdbufs.len), cmdbufs.ptr);

        return cmdbufs;
    }

    pub fn destroyCommandBuffers(self: @This(), cmdbufs: []vk.CommandBuffer, allocator: std.mem.Allocator) void {
        self.vkd.freeCommandBuffers(self.dev, self.command_pool, @truncate(cmdbufs.len), cmdbufs.ptr);
        allocator.free(cmdbufs);
    }

    pub fn createBuffer(
        self: *GraphicsContext,
        size: u64,
        usage: vk.BufferUsageFlags,
        memory_properties: vk.MemoryPropertyFlags,
        buffer: *vk.Buffer,
        memory: *vk.DeviceMemory,
    ) !void {
        // Create the buffer
        buffer.* = try self.vkd.createBuffer(self.dev, &.{
            .flags = .{},
            .size = size,
            .usage = usage,
            .sharing_mode = vk.SharingMode.exclusive,
            .queue_family_index_count = 0,
            .p_queue_family_indices = null,
        }, null);

        // Get memory requirements

        const mem_reqs = self.vkd.getBufferMemoryRequirements(self.dev, buffer.*);

        // Allocate memory
        memory.* = try self.allocate(mem_reqs, memory_properties, .{ .device_address_bit = true });

        // Bind buffer memory
        try self.vkd.bindBufferMemory(self.dev, buffer.*, memory.*, 0);
    }

    pub fn assertRaytracingResourcesValid(self: *GraphicsContext, tlas: vk.AccelerationStructureKHR, output_image_view: vk.ImageView) void {
        _ = self;
        std.debug.assert(tlas != vk.NULL_HANDLE);
        std.debug.assert(output_image_view != vk.NULL_HANDLE);
    }

    pub fn getAccessFlags(layout: vk.ImageLayout) vk.AccessFlags {
        // Maps VkImageLayout to VkAccessFlags for pipeline barriers
        return switch (layout) {
            .undefined => vk.AccessFlags{},
            .general => vk.AccessFlags{ .shader_write_bit = true, .shader_read_bit = true },
            .color_attachment_optimal => vk.AccessFlags{ .color_attachment_write_bit = true, .color_attachment_read_bit = true },
            .depth_stencil_attachment_optimal => vk.AccessFlags{ .depth_stencil_attachment_write_bit = true, .depth_stencil_attachment_read_bit = true },
            .transfer_src_optimal => vk.AccessFlags{ .transfer_read_bit = true },
            .transfer_dst_optimal => vk.AccessFlags{ .transfer_write_bit = true },
            .shader_read_only_optimal => vk.AccessFlags{ .shader_read_bit = true },
            .present_src_khr => vk.AccessFlags{},
            else => vk.AccessFlags{},
        };
    }

    pub fn getPipelineStageFlags(layout: vk.ImageLayout) vk.PipelineStageFlags {
        // Maps VkImageLayout to VkPipelineStageFlags for pipeline barriers
        return switch (layout) {
            .undefined => vk.PipelineStageFlags{ .top_of_pipe_bit = true },
            .general => vk.PipelineStageFlags{ .all_commands_bit = true },
            .color_attachment_optimal => vk.PipelineStageFlags{ .color_attachment_output_bit = true },
            .depth_stencil_attachment_optimal => vk.PipelineStageFlags{ .early_fragment_tests_bit = true },
            .transfer_src_optimal, .transfer_dst_optimal => vk.PipelineStageFlags{ .transfer_bit = true },
            .shader_read_only_optimal => vk.PipelineStageFlags{ .fragment_shader_bit = true },
            .present_src_khr => vk.PipelineStageFlags{ .bottom_of_pipe_bit = true },
            else => vk.PipelineStageFlags{ .all_commands_bit = true },
        };
    }

    pub fn transitionImageLayout(
        self: *GraphicsContext,
        command_buffer: vk.CommandBuffer,
        image: vk.Image,
        old_layout: vk.ImageLayout,
        new_layout: vk.ImageLayout,
        subresource_range: vk.ImageSubresourceRange,
    ) void {
        const src_access_mask = GraphicsContext.getAccessFlags(old_layout);
        const dst_access_mask = GraphicsContext.getAccessFlags(new_layout);
        const src_stage = GraphicsContext.getPipelineStageFlags(old_layout);
        const dst_stage = GraphicsContext.getPipelineStageFlags(new_layout);
        var barrier = vk.ImageMemoryBarrier{
            .s_type = vk.StructureType.image_memory_barrier,
            .src_access_mask = src_access_mask,
            .dst_access_mask = dst_access_mask,
            .old_layout = old_layout,
            .new_layout = new_layout,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = image,
            .subresource_range = subresource_range,
        };
        self.vkd.cmdPipelineBarrier(
            command_buffer,
            src_stage,
            dst_stage,
            .{},
            0,
            null,
            0,
            null,
            1,
            @ptrCast(&barrier),
        );
    }

    pub fn createImageWithInfo(
        self: *GraphicsContext,
        image_info: vk.ImageCreateInfo,
        memory_properties: vk.MemoryPropertyFlags,
        image: *vk.Image,
        memory: *vk.DeviceMemory,
    ) !void {
        image.* = try self.vkd.createImage(self.dev, &image_info, null);
        const mem_reqs = self.vkd.getImageMemoryRequirements(self.dev, image.*);
        memory.* = try self.allocate(mem_reqs, memory_properties, .{});
        try self.vkd.bindImageMemory(self.dev, image.*, memory.*, 0);
    }

    // Secondary command buffer for worker threads - no queue submission
    const PendingResource = struct {
        buffer: vk.Buffer,
        memory: vk.DeviceMemory,

        pub fn cleanup(self: PendingResource, gc: *GraphicsContext) void {
            gc.vkd.destroyBuffer(gc.dev, self.buffer, null);
            gc.vkd.freeMemory(gc.dev, self.memory, null);
        }
    };

    const SecondaryCommandBuffer = struct {
        pool: vk.CommandPool,
        command_buffer: vk.CommandBuffer,
        is_recording: bool = false,
        pending_resources: ?std.ArrayList(PendingResource),
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, pool: vk.CommandPool, command_buffer: vk.CommandBuffer) SecondaryCommandBuffer {
            return SecondaryCommandBuffer{
                .pool = pool,
                .command_buffer = command_buffer,
                .is_recording = true,
                .pending_resources = null,
                .allocator = allocator,
            };
        }

        pub fn addPendingResource(self: *SecondaryCommandBuffer, buffer: vk.Buffer, memory: vk.DeviceMemory) !void {
            if (self.pending_resources == null) {
                self.pending_resources = std.ArrayList(PendingResource){};
            }
            try self.pending_resources.?.append(self.allocator, PendingResource{ .buffer = buffer, .memory = memory });
        }

        pub fn deinit(self: *SecondaryCommandBuffer, gc: *GraphicsContext) void {
            // Clean up all pending resources if any exist
            if (self.pending_resources) |*resources| {
                for (resources.items) |resource| {
                    resource.cleanup(gc);
                }
                resources.deinit(self.allocator);
            }

            // IMPORTANT: Do NOT call vkFreeCommandBuffers on worker thread command buffers!
            // Command pools can only be accessed from the thread that created them.
            // Worker thread command buffers will be freed when their pools are reset via resetAllWorkerCommandPools()
            // Only free if this is from the main thread's pool
            if (self.pool == gc.command_pool) {
                gc.command_pool_mutex.lock();
                defer gc.command_pool_mutex.unlock();
                gc.vkd.freeCommandBuffers(gc.dev, self.pool, 1, @ptrCast(&self.command_buffer));
            }
            // For worker pools: command buffer will be freed when pool is reset (no explicit free needed)
        }
    };

    // Atomic double-buffer for lock-free secondary command buffer collection
    var pending_buffers: [2]std.ArrayList(SecondaryCommandBuffer) = undefined;
    var current_write_index: std.atomic.Value(u8) = std.atomic.Value(u8).init(0);
    var append_mutex: std.Thread.Mutex = std.Thread.Mutex{}; // Only held during append, not read
    var secondary_buffers_initialized: bool = false;

    /// Begin a secondary command buffer for worker thread work (no queue submission)
    pub fn beginWorkerCommandBuffer(self: *GraphicsContext) !SecondaryCommandBuffer {
        // Allocate secondary command buffer
        const pool = self.getThreadCommandPool() catch |err| {
            log(.ERROR, "graphics_context", "Failed to get thread command pool: {any}", .{err});
            return err;
        };

        var alloc_info = vk.CommandBufferAllocateInfo{
            .s_type = vk.StructureType.command_buffer_allocate_info,
            .command_pool = pool,
            .level = .secondary, // This is the key difference!
            .command_buffer_count = 1,
        };

        var command_buffer: vk.CommandBuffer = undefined;
        {
            self.command_pool_mutex.lock();
            defer self.command_pool_mutex.unlock();
            try self.vkd.allocateCommandBuffers(self.dev, &alloc_info, @ptrCast(&command_buffer));
        }

        // Secondary command buffers need inheritance info
        const inheritance_info = vk.CommandBufferInheritanceInfo{
            .s_type = vk.StructureType.command_buffer_inheritance_info,
            .p_next = null,
            .render_pass = vk.RenderPass.null_handle,
            .subpass = 0,
            .framebuffer = vk.Framebuffer.null_handle,
            .occlusion_query_enable = vk.Bool32.false,
            .query_flags = vk.QueryControlFlags{},
            .pipeline_statistics = vk.QueryPipelineStatisticFlags{},
        };

        const begin_info = vk.CommandBufferBeginInfo{
            .s_type = vk.StructureType.command_buffer_begin_info,
            .p_next = null,
            .flags = vk.CommandBufferUsageFlags{
                .one_time_submit_bit = true,
                .simultaneous_use_bit = true,
            },
            .p_inheritance_info = &inheritance_info,
        };

        {
            self.command_pool_mutex.lock();
            defer self.command_pool_mutex.unlock();
            try self.vkd.beginCommandBuffer(command_buffer, &begin_info);
        }

        return SecondaryCommandBuffer.init(self.allocator, pool, command_buffer);
    }

    /// End a worker command buffer and add it to pending collection (no queue submission)
    pub fn endWorkerCommandBuffer(self: *GraphicsContext, secondary_cmd: *SecondaryCommandBuffer) !void {
        if (!secondary_cmd.is_recording) return;

        {
            self.command_pool_mutex.lock();
            defer self.command_pool_mutex.unlock();
            try self.vkd.endCommandBuffer(secondary_cmd.command_buffer);
        }
        secondary_cmd.is_recording = false;

        // Append to current write buffer (short lock only for ArrayList append)
        const write_idx = current_write_index.load(.acquire);

        append_mutex.lock();
        defer append_mutex.unlock();
        try pending_buffers[write_idx].append(self.allocator, secondary_cmd.*);
    }

    // Storage for secondary command buffers that are submitted but not yet executed
    var submitted_secondary_buffers: std.ArrayList(SecondaryCommandBuffer) = undefined;
    var submitted_buffers_mutex: std.Thread.Mutex = std.Thread.Mutex{};
    var submitted_buffers_initialized: bool = false;

    /// Execute all pending secondary command buffers on main thread
    pub fn executeCollectedSecondaryBuffers(self: *GraphicsContext, primary_cmd: vk.CommandBuffer) !void {
        // Atomic flip: swap write index and take ownership of the PREVIOUS write buffer as our read buffer.
        // The swap returns the old write index, which is exactly the buffer we should now read and execute.
        const prev_write_idx = current_write_index.swap(1 - current_write_index.load(.monotonic), .acq_rel);
        const read_idx = prev_write_idx;

        // No lock needed - we own the read buffer
        if (pending_buffers[read_idx].items.len == 0) return;

        // Initialize submitted buffers collection if needed
        if (!submitted_buffers_initialized) {
            submitted_secondary_buffers = std.ArrayList(SecondaryCommandBuffer){};
            submitted_buffers_initialized = true;
        }

        // Create array of secondary command buffer handles
        var secondary_handles = try self.allocator.alloc(vk.CommandBuffer, pending_buffers[read_idx].items.len);
        defer self.allocator.free(secondary_handles);

        for (pending_buffers[read_idx].items, 0..) |secondary, i| {
            secondary_handles[i] = secondary.command_buffer;
        }

        // Execute secondary buffers in primary command buffer
        self.vkd.cmdExecuteCommands(primary_cmd, @intCast(secondary_handles.len), secondary_handles.ptr);

        // Move secondary command buffers to submitted collection (don't deinit yet!)
        submitted_buffers_mutex.lock();
        defer submitted_buffers_mutex.unlock();

        for (pending_buffers[read_idx].items) |secondary| {
            try submitted_secondary_buffers.append(self.allocator, secondary);
        }

        // Clear the read buffer for next cycle
        pending_buffers[read_idx].clearRetainingCapacity();
    }

    /// Clear any pending secondary command buffers without executing them
    /// Use this when switching rendering modes to discard async work from previous mode
    ///
    /// FIXED: Now properly frees command buffers by resetting all worker command pools
    /// This is safe because:
    /// 1. Called during RT toggle when no BVH building is active
    /// 2. Worker threads are idle (waiting for work)
    /// 3. vkResetCommandPool frees all buffers allocated from that pool
    ///
    /// WARNING: Only call this when you're certain no workers are using their command pools!
    pub fn clearPendingSecondaryBuffers(self: *GraphicsContext) void {
        append_mutex.lock();
        defer append_mutex.unlock();

        const count0 = pending_buffers[0].items.len;
        const count1 = pending_buffers[1].items.len;
        const total = count0 + count1;

        // Clear both buffers
        pending_buffers[0].clearRetainingCapacity();
        pending_buffers[1].clearRetainingCapacity();

        // Reset all worker command pools to free their command buffers
        self.resetAllWorkerCommandPools();

        log(.DEBUG, "graphics_context", "Discarded {} pending secondary command buffers and reset worker pools", .{total});
    }

    /// Clean up submitted secondary command buffers after frame submission completes
    pub fn cleanupSubmittedSecondaryBuffers(self: *GraphicsContext) void {
        submitted_buffers_mutex.lock();
        defer submitted_buffers_mutex.unlock();

        if (!submitted_buffers_initialized) return;

        // Clean up all submitted secondary command buffers
        for (submitted_secondary_buffers.items) |*secondary| {
            secondary.deinit(self);
        }

        // Clear the submitted collection
        submitted_secondary_buffers.clearRetainingCapacity();
    }

    /// Legacy single-time commands (kept for compatibility, but should be avoided on worker threads)
    pub fn beginSingleTimeCommands(self: *GraphicsContext) !vk.CommandBuffer {
        var alloc_info = vk.CommandBufferAllocateInfo{
            .s_type = vk.StructureType.command_buffer_allocate_info,
            .command_pool = self.command_pool,
            .level = .primary,
            .command_buffer_count = 1,
        };
        var command_buffer: vk.CommandBuffer = undefined;
        try self.vkd.allocateCommandBuffers(self.dev, &alloc_info, @ptrCast(&command_buffer));
        var begin_info = vk.CommandBufferBeginInfo{
            .s_type = vk.StructureType.command_buffer_begin_info,
            .flags = .{ .one_time_submit_bit = true },
            .p_inheritance_info = null,
        };
        try self.vkd.beginCommandBuffer(command_buffer, &begin_info);
        return command_buffer;
    }

    pub fn endSingleTimeCommands(self: *GraphicsContext, command_buffer: vk.CommandBuffer) !void {
        try self.vkd.endCommandBuffer(command_buffer);
        var submit_info = vk.SubmitInfo{
            .s_type = vk.StructureType.submit_info,
            .wait_semaphore_count = 0,
            .p_wait_semaphores = null,
            .p_wait_dst_stage_mask = null,
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast(&command_buffer),
            .signal_semaphore_count = 0,
            .p_signal_semaphores = null,
        };

        // Synchronize queue access as required by Vulkan spec
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();

        try self.vkd.queueSubmit(self.graphics_queue.handle, 1, @ptrCast(&submit_info), .null_handle);
        try self.vkd.queueWaitIdle(self.graphics_queue.handle);
        self.vkd.freeCommandBuffers(self.dev, self.command_pool, 1, @ptrCast(&command_buffer));
    }

    /// Synchronized queue submission for graphics operations
    /// Use this method for all queue submissions to ensure proper synchronization
    pub fn submitToGraphicsQueue(
        self: *GraphicsContext,
        submit_count: u32,
        submits: [*]const vk.SubmitInfo,
        fence: vk.Fence,
    ) !void {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();
        try self.vkd.queueSubmit(self.graphics_queue.handle, submit_count, submits, fence);
    }

    /// Synchronized queue wait for graphics operations
    pub fn waitGraphicsQueueIdle(self: *GraphicsContext) !void {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();
        try self.vkd.queueWaitIdle(self.graphics_queue.handle);
    }

    /// Wait for all device operations to complete
    pub fn waitDeviceIdle(self: *GraphicsContext) !void {
        try self.vkd.deviceWaitIdle(self.dev);
    }

    /// Synchronized present queue submission (if different from graphics)
    pub fn submitToPresentQueue(
        self: *GraphicsContext,
        present_info: *const vk.PresentInfoKHR,
    ) !vk.Result {
        // If present queue is the same as graphics queue, use the same mutex
        if (self.present_queue.family == self.graphics_queue.family) {
            self.queue_mutex.lock();
            defer self.queue_mutex.unlock();
        }
        return self.vkd.queuePresentKHR(self.present_queue.handle, present_info);
    }

    /// Synchronized compute queue submission
    /// Note: Compute queue may be separate from graphics queue, but we still need synchronization
    pub fn submitToComputeQueue(
        self: *GraphicsContext,
        submit_count: u32,
        submits: [*]const vk.SubmitInfo,
        fence: vk.Fence,
    ) !void {
        // If compute queue is the same as graphics queue, use the same mutex
        if (self.compute_queue.family == self.graphics_queue.family) {
            self.queue_mutex.lock();
            defer self.queue_mutex.unlock();
        }
        try self.vkd.queueSubmit(self.compute_queue.handle, submit_count, submits, fence);
    }

    pub fn transitionImageLayoutSingleTime(
        self: *GraphicsContext,
        image: vk.Image,
        old_layout: vk.ImageLayout,
        new_layout: vk.ImageLayout,
        subresource_range: vk.ImageSubresourceRange,
    ) !void {
        if (std.Thread.getCurrentId() == self.main_thread_id) {
            // Main thread: use synchronous single-time command
            const command_buffer = try self.beginSingleTimeCommands();
            self.transitionImageLayout(command_buffer, image, old_layout, new_layout, subresource_range);
            try self.endSingleTimeCommands(command_buffer);
        } else {
            // Worker thread: use secondary command buffer
            var secondary_cmd = try self.beginWorkerCommandBuffer();
            self.transitionImageLayout(secondary_cmd.command_buffer, image, old_layout, new_layout, subresource_range);
            try self.endWorkerCommandBuffer(&secondary_cmd);
        }
    }

    pub fn copyBufferToImageSingleTime(
        self: *GraphicsContext,
        buffer: Buffer,
        image: vk.Image,
        width: u32,
        height: u32,
    ) !void {
        const region = vk.BufferImageCopy{
            .buffer_offset = 0,
            .buffer_row_length = 0,
            .buffer_image_height = 0,
            .image_subresource = .{
                .aspect_mask = vk.ImageAspectFlags{ .color_bit = true },
                .mip_level = 0,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .image_offset = .{ .x = 0, .y = 0, .z = 0 },
            .image_extent = .{ .width = width, .height = height, .depth = 1 },
        };

        if (std.Thread.getCurrentId() == self.main_thread_id) {
            // Main thread: use synchronous single-time command
            const command_buffer = try self.beginSingleTimeCommands();
            self.vkd.cmdCopyBufferToImage(
                command_buffer,
                buffer.buffer,
                image,
                vk.ImageLayout.transfer_dst_optimal,
                1,
                @ptrCast(&region),
            );
            try self.endSingleTimeCommands(command_buffer);
        } else {
            // Worker thread: use secondary command buffer
            var secondary_cmd = try self.beginWorkerCommandBuffer();
            try secondary_cmd.addPendingResource(buffer.buffer, buffer.memory);
            self.vkd.cmdCopyBufferToImage(
                secondary_cmd.command_buffer,
                buffer.buffer,
                image,
                vk.ImageLayout.transfer_dst_optimal,
                1,
                @ptrCast(&region),
            );
            try self.endWorkerCommandBuffer(&secondary_cmd);
        }
    }

    pub fn generateMipmapsSingleTime(
        self: *GraphicsContext,
        image: vk.Image,
        width: u32,
        height: u32,
        mip_levels: u32,
    ) !void {
        if (std.Thread.getCurrentId() == self.main_thread_id) {
            // Main thread: use synchronous single-time command
            const command_buffer = try self.beginSingleTimeCommands();
            try self.generateMipmapsImpl(command_buffer, image, width, height, mip_levels);
            try self.endSingleTimeCommands(command_buffer);
        } else {
            // Worker thread: use secondary command buffer
            var secondary_cmd = try self.beginWorkerCommandBuffer();
            try self.generateMipmapsImpl(secondary_cmd.command_buffer, image, width, height, mip_levels);
            try self.endWorkerCommandBuffer(&secondary_cmd);
        }
    }

    fn generateMipmapsImpl(
        self: *GraphicsContext,
        command_buffer: vk.CommandBuffer,
        image: vk.Image,
        width: u32,
        height: u32,
        mip_levels: u32,
    ) !void {
        var mip_width: i32 = @intCast(width);
        var mip_height: i32 = @intCast(height);
        for (1..mip_levels) |i| {
            const src_mip: u32 = @intCast(i - 1);
            const dst_mip: u32 = @intCast(i);
            const barrier = vk.ImageMemoryBarrier{
                .s_type = vk.StructureType.image_memory_barrier,
                .src_access_mask = vk.AccessFlags{ .transfer_write_bit = true },
                .dst_access_mask = vk.AccessFlags{ .transfer_read_bit = true },
                .old_layout = vk.ImageLayout.transfer_dst_optimal,
                .new_layout = vk.ImageLayout.transfer_src_optimal,
                .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .image = image,
                .subresource_range = .{
                    .aspect_mask = vk.ImageAspectFlags{ .color_bit = true },
                    .base_mip_level = src_mip,
                    .level_count = 1,
                    .base_array_layer = 0,
                    .layer_count = 1,
                },
            };
            self.vkd.cmdPipelineBarrier(
                command_buffer,
                vk.PipelineStageFlags{ .transfer_bit = true },
                vk.PipelineStageFlags{ .transfer_bit = true },
                .{},
                0,
                null,
                0,
                null,
                1,
                @ptrCast(&barrier),
            );
            const blit = vk.ImageBlit{
                .src_subresource = .{
                    .aspect_mask = vk.ImageAspectFlags{ .color_bit = true },
                    .mip_level = src_mip,
                    .base_array_layer = 0,
                    .layer_count = 1,
                },
                .src_offsets = .{
                    .{ .x = 0, .y = 0, .z = 0 },
                    .{ .x = mip_width, .y = mip_height, .z = 1 },
                },
                .dst_subresource = .{
                    .aspect_mask = vk.ImageAspectFlags{ .color_bit = true },
                    .mip_level = dst_mip,
                    .base_array_layer = 0,
                    .layer_count = 1,
                },
                .dst_offsets = .{
                    .{ .x = 0, .y = 0, .z = 0 },
                    .{ .x = @max(1, @divTrunc(mip_width, 2)), .y = @max(1, @divTrunc(mip_height, 2)), .z = 1 },
                },
            };
            self.vkd.cmdBlitImage(
                command_buffer,
                image,
                vk.ImageLayout.transfer_src_optimal,
                image,
                vk.ImageLayout.transfer_dst_optimal,
                1,
                @ptrCast(&blit),
                vk.Filter.linear,
            );
            // Transition previous mip to SHADER_READ_ONLY_OPTIMAL
            const barrier2 = vk.ImageMemoryBarrier{
                .s_type = vk.StructureType.image_memory_barrier,
                .src_access_mask = vk.AccessFlags{ .transfer_read_bit = true },
                .dst_access_mask = vk.AccessFlags{ .shader_read_bit = true },
                .old_layout = vk.ImageLayout.transfer_src_optimal,
                .new_layout = vk.ImageLayout.shader_read_only_optimal,
                .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .image = image,
                .subresource_range = .{
                    .aspect_mask = vk.ImageAspectFlags{ .color_bit = true },
                    .base_mip_level = src_mip,
                    .level_count = 1,
                    .base_array_layer = 0,
                    .layer_count = 1,
                },
            };
            self.vkd.cmdPipelineBarrier(
                command_buffer,
                vk.PipelineStageFlags{ .transfer_bit = true },
                vk.PipelineStageFlags{ .fragment_shader_bit = true },
                .{},
                0,
                null,
                0,
                null,
                1,
                @ptrCast(&barrier2),
            );
            mip_width = @max(1, @divTrunc(mip_width, 2));
            mip_height = @max(1, @divTrunc(mip_height, 2));
        }
        // Final mip level to SHADER_READ_ONLY_OPTIMAL
        const final_barrier = vk.ImageMemoryBarrier{
            .s_type = vk.StructureType.image_memory_barrier,
            .src_access_mask = vk.AccessFlags{ .transfer_write_bit = true },
            .dst_access_mask = vk.AccessFlags{ .shader_read_bit = true },
            .old_layout = vk.ImageLayout.transfer_dst_optimal,
            .new_layout = vk.ImageLayout.shader_read_only_optimal,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = image,
            .subresource_range = .{
                .aspect_mask = vk.ImageAspectFlags{ .color_bit = true },
                .base_mip_level = mip_levels - 1,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        };
        self.vkd.cmdPipelineBarrier(
            command_buffer,
            vk.PipelineStageFlags{ .transfer_bit = true },
            vk.PipelineStageFlags{ .fragment_shader_bit = true },
            .{},
            0,
            null,
            0,
            null,
            1,
            @ptrCast(&final_barrier),
        );
    }
};

pub const Queue = struct {
    handle: vk.Queue,
    family: u32,

    fn init(vkd: DeviceWrapper, dev: vk.Device, family: u32, new: bool) Queue {
        if (new) {
            return .{
                .handle = vkd.getDeviceQueue(dev, family, 1),
                .family = family,
            };
        }
        return .{
            .handle = vkd.getDeviceQueue(dev, family, 0),
            .family = family,
        };
    }
};

fn createSurface(instance: vk.Instance, window: *c.GLFWwindow) !vk.SurfaceKHR {
    var surface: vk.SurfaceKHR = undefined;
    if (c.glfwCreateWindowSurface(instance, window, null, &surface) != vk.Result.success) {
        return error.SurfaceInitFailed;
    }

    return surface;
}

fn initializeCandidate(allocator: Allocator, vki: InstanceWrapper, candidate: DeviceCandidate) !vk.Device {
    const priority = [_]f32{1};
    const qci = [_]vk.DeviceQueueCreateInfo{
        .{
            .flags = .{},
            .queue_family_index = candidate.queues.graphics_family,
            .queue_count = 2,
            .p_queue_priorities = &priority,
        },
        .{
            .flags = .{},
            .queue_family_index = candidate.queues.present_family,
            .queue_count = 1,
            .p_queue_priorities = &priority,
        },
    };

    const queue_count: u32 = if (candidate.queues.graphics_family == candidate.queues.present_family)
        1 // nvidia
    else
        2; // amd

    var device_extensions = try std.ArrayList([*:0]const u8).initCapacity(allocator, required_device_extensions.len);
    defer device_extensions.deinit(allocator);

    try device_extensions.appendSlice(allocator, required_device_extensions[0..required_device_extensions.len]);

    var count: u32 = undefined;
    _ = try vki.enumerateDeviceExtensionProperties(candidate.pdev, null, &count, null);

    const propsv = try allocator.alloc(vk.ExtensionProperties, count);
    defer allocator.free(propsv);

    _ = try vki.enumerateDeviceExtensionProperties(candidate.pdev, null, &count, propsv.ptr);

    for (optional_device_extensions) |extension_name| {
        for (propsv) |prop| {
            if (std.mem.eql(u8, prop.extension_name[0..prop.extension_name.len], std.mem.span(extension_name))) {
                try device_extensions.append(extension_name);

                break;
            }
        }
    }
    var create_info = vk.DeviceCreateInfo{
        .flags = .{},
        .queue_create_info_count = queue_count,
        .p_queue_create_infos = &qci,
        .enabled_layer_count = 0,
        .pp_enabled_layer_names = undefined,
        .enabled_extension_count = @as(u32, @intCast(device_extensions.items.len)),
        .pp_enabled_extension_names = @as([*]const [*:0]const u8, @ptrCast(device_extensions.items)),
        .p_enabled_features = null,
    };
    var ray_query_create = vk.PhysicalDeviceRayQueryFeaturesKHR{
        .ray_query = .true,
    };

    var ray_tracing_create = vk.PhysicalDeviceRayTracingPipelineFeaturesKHR{
        .ray_tracing_pipeline = .true,
    };
    ray_query_create.p_next = &ray_tracing_create;

    var accel_create = vk.PhysicalDeviceAccelerationStructureFeaturesKHR{
        .acceleration_structure = .true,
    };
    ray_tracing_create.p_next = &accel_create;

    var vulkan12_features = vk.PhysicalDeviceVulkan12Features{
        .runtime_descriptor_array = .true,
        .descriptor_indexing = .true,
        .shader_input_attachment_array_dynamic_indexing = .true,
        .shader_uniform_texel_buffer_array_dynamic_indexing = .true,
        .shader_storage_texel_buffer_array_dynamic_indexing = .true,
        .shader_uniform_buffer_array_non_uniform_indexing = .true,
        .shader_sampled_image_array_non_uniform_indexing = .true,
        .shader_storage_buffer_array_non_uniform_indexing = .true,
        .shader_storage_image_array_non_uniform_indexing = .true,
        .shader_uniform_texel_buffer_array_non_uniform_indexing = .true,
        .shader_storage_texel_buffer_array_non_uniform_indexing = .true,
        .descriptor_binding_uniform_buffer_update_after_bind = .true,
        .descriptor_binding_sampled_image_update_after_bind = .true,
        .descriptor_binding_storage_image_update_after_bind = .true,
        .descriptor_binding_storage_buffer_update_after_bind = .true,
        .descriptor_binding_uniform_texel_buffer_update_after_bind = .true,
        .descriptor_binding_storage_texel_buffer_update_after_bind = .true,
        .descriptor_binding_update_unused_while_pending = .true,
        .descriptor_binding_partially_bound = .true,
        .descriptor_binding_variable_descriptor_count = .true,
        // Buffer device address features (promoted to Vulkan 1.2)
        .buffer_device_address = .true,
        .buffer_device_address_capture_replay = .true,
        .buffer_device_address_multi_device = .true,
        // Host query reset (promoted to Vulkan 1.2) - for performance monitoring
        .host_query_reset = .true,
    };
    accel_create.p_next = &vulkan12_features;

    // Enable dynamic rendering (Vulkan 1.3 core / VK_KHR_dynamic_rendering)
    var dynamic_rendering_features = vk.PhysicalDeviceDynamicRenderingFeatures{
        .dynamic_rendering = .true,
    };
    vulkan12_features.p_next = &dynamic_rendering_features;

    create_info.p_next = &ray_query_create;
    return try vki.createDevice(candidate.pdev, &create_info, null);
}

const DeviceCandidate = struct {
    pdev: vk.PhysicalDevice,
    props: vk.PhysicalDeviceProperties,
    queues: QueueAllocation,
};

const QueueAllocation = struct {
    graphics_family: u32,
    present_family: u32,
    compute_family: u32, // Added for async compute
};

fn pickPhysicalDevice(
    vki: InstanceWrapper,
    instance: vk.Instance,
    allocator: Allocator,
    surface: vk.SurfaceKHR,
) !DeviceCandidate {
    var device_count: u32 = undefined;
    _ = try vki.enumeratePhysicalDevices(instance, &device_count, null);

    const pdevs = try allocator.alloc(vk.PhysicalDevice, device_count);
    defer allocator.free(pdevs);

    _ = try vki.enumeratePhysicalDevices(instance, &device_count, pdevs.ptr);

    for (pdevs) |pdev| {
        if (try checkSuitable(vki, pdev, allocator, surface)) |candidate| {
            return candidate;
        }
    }

    return error.NoSuitableDevice;
}

fn checkSuitable(
    vki: InstanceWrapper,
    pdev: vk.PhysicalDevice,
    allocator: Allocator,
    surface: vk.SurfaceKHR,
) !?DeviceCandidate {
    const props = vki.getPhysicalDeviceProperties(pdev);

    if (!try checkExtensionSupport(vki, pdev, allocator)) {
        return null;
    }

    if (!try checkSurfaceSupport(vki, pdev, surface)) {
        return null;
    }

    if (try allocateQueues(vki, pdev, allocator, surface)) |allocation| {
        return DeviceCandidate{
            .pdev = pdev,
            .props = props,
            .queues = allocation,
        };
    }

    return null;
}

fn allocateQueues(vki: InstanceWrapper, pdev: vk.PhysicalDevice, allocator: Allocator, surface: vk.SurfaceKHR) !?QueueAllocation {
    var family_count: u32 = undefined;
    vki.getPhysicalDeviceQueueFamilyProperties(pdev, &family_count, null);

    const families = try allocator.alloc(vk.QueueFamilyProperties, family_count);
    defer allocator.free(families);
    vki.getPhysicalDeviceQueueFamilyProperties(pdev, &family_count, families.ptr);

    var graphics_family: ?u32 = null;
    var present_family: ?u32 = null;
    var compute_family: ?u32 = null;

    for (families, 0..) |properties, i| {
        const family = @as(u32, @intCast(i));

        if (graphics_family == null and properties.queue_flags.graphics_bit) {
            graphics_family = family;
        }

        if (present_family == null and (try vki.getPhysicalDeviceSurfaceSupportKHR(pdev, family, surface)) == .true) {
            present_family = family;
        }

        if (compute_family == null and properties.queue_flags.compute_bit) {
            compute_family = family;
        }
    }

    if (graphics_family != null and present_family != null and compute_family != null) {
        return QueueAllocation{
            .graphics_family = graphics_family.?,
            .present_family = present_family.?,
            .compute_family = compute_family.?,
        };
    }

    return null;
}

fn checkSurfaceSupport(vki: InstanceWrapper, pdev: vk.PhysicalDevice, surface: vk.SurfaceKHR) !bool {
    var format_count: u32 = undefined;
    _ = try vki.getPhysicalDeviceSurfaceFormatsKHR(pdev, surface, &format_count, null);

    var present_mode_count: u32 = undefined;
    _ = try vki.getPhysicalDeviceSurfacePresentModesKHR(pdev, surface, &present_mode_count, null);

    return format_count > 0 and present_mode_count > 0;
}

fn checkExtensionSupport(
    vki: InstanceWrapper,
    pdev: vk.PhysicalDevice,
    allocator: Allocator,
) !bool {
    var count: u32 = undefined;
    _ = try vki.enumerateDeviceExtensionProperties(pdev, null, &count, null);

    const propsv = try allocator.alloc(vk.ExtensionProperties, count);
    defer allocator.free(propsv);

    _ = try vki.enumerateDeviceExtensionProperties(pdev, null, &count, propsv.ptr);

    for (required_device_extensions) |ext| {
        for (propsv) |props| {
            const len = std.mem.indexOfScalar(u8, &props.extension_name, 0).?;
            const prop_ext_name = props.extension_name[0..len];
            if (std.mem.eql(u8, std.mem.span(ext), prop_ext_name)) {
                break;
            }
        } else {
            return false;
        }
    }

    return true;
}

pub fn workerThreadExitHook(context_ptr: *anyopaque) void {
    const aligned_ctx: *align(@alignOf(GraphicsContext)) anyopaque = @alignCast(context_ptr);
    const gc_ptr: *GraphicsContext = @ptrCast(aligned_ctx);
    gc_ptr.cleanupThreadCommandPool();
}
