const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vulkan");
const c = @import("c.zig");
const Allocator = std.mem.Allocator;
const MAX_FRAMES_IN_FLIGHT = @import("swapchain.zig").MAX_FRAMES_IN_FLIGHT;

const required_device_extensions = [_][*:0]const u8{
    vk.extensions.khr_swapchain.name,
    vk.extensions.khr_acceleration_structure.name,
    vk.extensions.khr_ray_tracing_pipeline.name,
    vk.extensions.khr_ray_query.name,
    vk.extensions.khr_deferred_host_operations.name,
        //vk.extensions.khr_maintenance_8.name,
        //vk.extensions.khr_portability_subset.name,
};

const optional_device_extensions = [_][*:0]const u8{};

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
};

/// Next, pass the `apis` to the wrappers to create dispatch tables.
const BaseWrapper = vk.BaseWrapper;
const InstanceWrapper = vk.InstanceWrapper;
const DeviceWrapper = vk.DeviceWrapper;

pub const GraphicsContext = struct {
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
    command_pool: vk.CommandPool,

    pub fn init(allocator: Allocator, app_name: [*:0]const u8, window: *c.GLFWwindow) !GraphicsContext {
        var self: GraphicsContext = undefined;
        self.vkb = BaseWrapper.load(@as(vk.PfnGetInstanceProcAddr, @ptrCast(&c.glfwGetInstanceProcAddress)));

        var glfw_ext_count: u32 = 0;
        const glfw_exts_ptr = c.glfwGetRequiredInstanceExtensions(&glfw_ext_count);
        if (glfw_exts_ptr == null) {
            std.log.err("failed to get required vulkan instance extensions, {}", .{glfw_ext_count});
            return error.code;
        }
        // Convert [*c][*c]const u8 to []const [*:0]const u8 safely
        var glfw_exts = try allocator.alloc([*:0]const u8, glfw_ext_count);
        for (0..glfw_ext_count) |i| {
            glfw_exts[i] = glfw_exts_ptr[i];
        }

        var instance_extensions = try std.ArrayList([*:0]const u8).initCapacity(allocator, glfw_exts.len + 1);
        defer instance_extensions.deinit();
        try instance_extensions.appendSlice(glfw_exts);

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
                    try instance_extensions.append(@ptrCast(extension_name));
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

        var layers = std.BoundedArray([*:0]const u8, instance_layers.len){};
        for (instance_layers) |optional| {
            for (available_layers) |available| {
                if (std.mem.eql(
                    u8,
                    std.mem.sliceTo(optional, 0),
                    std.mem.sliceTo(&available.layer_name, 0),
                )) {
                    layers.appendAssumeCapacity(optional);
                    break;
                }
            }
        }

        const app_info = vk.ApplicationInfo{
            .p_application_name = app_name,
            .application_version = @bitCast(vk.makeApiVersion(0, 0, 0, 0)),
            .p_engine_name = app_name,
            .engine_version = @bitCast(vk.makeApiVersion(0, 0, 0, 0)),
            .api_version = @bitCast(vk.API_VERSION_1_2),
        };

        self.instance = try self.vkb.createInstance(&vk.InstanceCreateInfo{
            .flags = if (builtin.os.tag == .macos) .{
                .enumerate_portability_bit_khr = true,
            } else .{},
            .p_application_info = &app_info,
            .enabled_layer_count = @intCast(layers.len),
            .pp_enabled_layer_names = layers.slice().ptr,
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

        self.graphics_queue = Queue.init(self.vkd, self.dev, candidate.queues.graphics_family);
        self.present_queue = Queue.init(self.vkd, self.dev, candidate.queues.present_family);

        self.mem_props = self.vki.getPhysicalDeviceMemoryProperties(self.pdev);

        return self;
    }

    pub fn deinit(self: GraphicsContext) void {
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

    pub fn createCommandPool(self: *@This()) !void {
        self.command_pool = try self.vkd.createCommandPool(self.dev, &.{
            .flags = .{ .reset_command_buffer_bit = true },
            .queue_family_index = self.graphics_queue.family,
        }, null);
    }

    pub fn copyBuffer(self: @This(), dst: vk.Buffer, src: vk.Buffer, size: vk.DeviceSize) !void {
        var cmdbuf: vk.CommandBuffer = undefined;
        try self.vkd.allocateCommandBuffers(self.dev, &.{
            .command_pool = self.command_pool,
            .level = .primary,
            .command_buffer_count = 1,
        }, @ptrCast(&cmdbuf));

        try self.vkd.beginCommandBuffer(cmdbuf, &.{
            .flags = .{ .one_time_submit_bit = true },
            .p_inheritance_info = null,
        });

        const region = vk.BufferCopy{
            .src_offset = 0,
            .dst_offset = 0,
            .size = size,
        };
        self.vkd.cmdCopyBuffer(cmdbuf, src, dst, 1, @ptrCast(&region));

        try self.vkd.endCommandBuffer(cmdbuf);

        const si = vk.SubmitInfo{
            .wait_semaphore_count = 0,
            .p_wait_semaphores = undefined,
            .p_wait_dst_stage_mask = undefined,
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast(&cmdbuf),
            .signal_semaphore_count = 0,
            .p_signal_semaphores = undefined,
        };
        try self.vkd.queueSubmit(self.graphics_queue.handle, 1, @ptrCast(&si), .null_handle);
        try self.vkd.queueWaitIdle(self.graphics_queue.handle);
    }

    pub fn createCommandBuffers(
        self: *@This(),
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
        self: *@This(),
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
        try self.vkd.queueSubmit(self.graphics_queue.handle, 1, @ptrCast(&submit_info), .null_handle);
        try self.vkd.queueWaitIdle(self.graphics_queue.handle);
        self.vkd.freeCommandBuffers(self.dev, self.command_pool, 1, @ptrCast(&command_buffer));
    }

    pub fn transitionImageLayoutSingleTime(
        self: *GraphicsContext,
        image: vk.Image,
        old_layout: vk.ImageLayout,
        new_layout: vk.ImageLayout,
        subresource_range: vk.ImageSubresourceRange,
    ) !void {
        const command_buffer = try self.beginSingleTimeCommands();
        defer self.endSingleTimeCommands(command_buffer) catch unreachable;
        self.transitionImageLayout(command_buffer, image, old_layout, new_layout, subresource_range);
        // endSingleTimeCommands will submit and free the command buffer
    }

    pub fn copyBufferToImageSingleTime(
        self: *GraphicsContext,
        buffer: vk.Buffer,
        image: vk.Image,
        width: u32,
        height: u32,
    ) !void {
        const command_buffer = try self.beginSingleTimeCommands();
        defer self.endSingleTimeCommands(command_buffer) catch unreachable;
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
        self.vkd.cmdCopyBufferToImage(
            command_buffer,
            buffer,
            image,
            vk.ImageLayout.transfer_dst_optimal,
            1,
            @ptrCast(&region),
        );
    }

    pub fn generateMipmapsSingleTime(
        self: *GraphicsContext,
        image: vk.Image,
        width: u32,
        height: u32,
        mip_levels: u32,
    ) !void {
        const command_buffer = try self.beginSingleTimeCommands();
        defer self.endSingleTimeCommands(command_buffer) catch unreachable;

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

    fn init(vkd: DeviceWrapper, dev: vk.Device, family: u32) Queue {
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
            .queue_count = 1,
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
    defer device_extensions.deinit();

    try device_extensions.appendSlice(required_device_extensions[0..required_device_extensions.len]);

    var count: u32 = undefined;
    _ = try vki.enumerateDeviceExtensionProperties(candidate.pdev, null, &count, null);

    const propsv = try allocator.alloc(vk.ExtensionProperties, count);
    defer allocator.free(propsv);

    _ = try vki.enumerateDeviceExtensionProperties(candidate.pdev, null, &count, propsv.ptr);
    for (propsv) |prop| {
        std.debug.print("Added extension: {s}\n", .{prop.extension_name});
    }

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
        .ray_query = 1,
    };

    var ray_tracing_create = vk.PhysicalDeviceRayTracingPipelineFeaturesKHR{
        .ray_tracing_pipeline = 1,
    };
    ray_query_create.p_next = &ray_tracing_create;

    var bda_create = vk.PhysicalDeviceBufferDeviceAddressFeatures{
        .buffer_device_address = 1,
        .buffer_device_address_capture_replay = 1,
        .buffer_device_address_multi_device = 1,
    };
    ray_tracing_create.p_next = &bda_create;

    var accel_create = vk.PhysicalDeviceAccelerationStructureFeaturesKHR{
        .acceleration_structure = 1,
    };
    bda_create.p_next = &accel_create;

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

    for (families, 0..) |properties, i| {
        const family = @as(u32, @intCast(i));

        if (graphics_family == null and properties.queue_flags.graphics_bit) {
            graphics_family = family;
        }

        if (present_family == null and (try vki.getPhysicalDeviceSurfaceSupportKHR(pdev, family, surface)) == vk.TRUE) {
            present_family = family;
        }
    }

    if (graphics_family != null and present_family != null) {
        return QueueAllocation{
            .graphics_family = graphics_family.?,
            .present_family = present_family.?,
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
            std.debug.print("Device has extentions {s}\n", .{props.extension_name});
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
