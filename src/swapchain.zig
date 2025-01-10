const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("graphics_context.zig").GraphicsContext;
const Allocator = std.mem.Allocator;
const glfw = @import("glfw");
const FrameInfo = @import("frameinfo.zig").FrameInfo;

pub const MAX_FRAMES_IN_FLIGHT = 3;

pub const Swapchain = struct {
    pub const PresentState = enum {
        optimal,
        suboptimal,
    };

    gc: *const GraphicsContext,
    allocator: Allocator,

    surface_format: vk.SurfaceFormatKHR,
    present_mode: vk.PresentModeKHR,
    extent: vk.Extent2D,
    handle: vk.SwapchainKHR,
    render_pass: vk.RenderPass = undefined,
    framebuffers: []vk.Framebuffer = undefined,

    swap_images: []SwapImage,
    image_index: u32 = 0,

    pub fn init(gc: *const GraphicsContext, allocator: Allocator, extent: vk.Extent2D) !Swapchain {
        return try initRecycle(gc, allocator, extent, .null_handle, .null_handle);
    }

    pub fn initRecycle(gc: *const GraphicsContext, allocator: Allocator, extent: vk.Extent2D, old_handle: vk.SwapchainKHR, old_render_pass: vk.RenderPass) !Swapchain {
        const caps = try gc.vki.getPhysicalDeviceSurfaceCapabilitiesKHR(gc.pdev, gc.surface);
        const actual_extent = findActualExtent(caps, extent);
        if (actual_extent.width == 0 or actual_extent.height == 0) {
            return error.InvalidSurfaceDimensions;
        }

        const surface_format = try findSurfaceFormat(gc, allocator);
        const present_mode = try findPresentMode(gc, allocator);

        var image_count = caps.min_image_count + 1;
        if (caps.max_image_count > 0) {
            image_count = @min(image_count, caps.max_image_count);
        }

        const qfi = [_]u32{ gc.graphics_queue.family, gc.present_queue.family };
        const sharing_mode: vk.SharingMode = if (gc.graphics_queue.family != gc.present_queue.family)
            .concurrent
        else
            .exclusive;

        const handle = try gc.vkd.createSwapchainKHR(gc.dev, &.{
            .flags = .{},
            .surface = gc.surface,
            .min_image_count = image_count,
            .image_format = surface_format.format,
            .image_color_space = surface_format.color_space,
            .image_extent = actual_extent,
            .image_array_layers = 1,
            .image_usage = .{ .color_attachment_bit = true, .transfer_dst_bit = true },
            .image_sharing_mode = sharing_mode,
            .queue_family_index_count = qfi.len,
            .p_queue_family_indices = &qfi,
            .pre_transform = caps.current_transform,
            .composite_alpha = .{ .opaque_bit_khr = true },
            .present_mode = present_mode,
            .clipped = vk.TRUE,
            .old_swapchain = old_handle,
        }, null);
        errdefer gc.vkd.destroySwapchainKHR(gc.dev, handle, null);

        if (old_handle != .null_handle) {
            // Apparently, the old swapchain handle still needs to be destroyed after recreating.
            gc.vkd.destroySwapchainKHR(gc.dev, old_handle, null);
        }

        const swap_images = try initSwapchainImages(gc, handle, surface_format.format, allocator, extent);
        errdefer for (swap_images) |si| si.deinit(gc);

        // var next_image_acquired = try gc.vkd.createSemaphore(gc.dev, &.{ .flags = .{} }, null);
        // errdefer gc.vkd.destroySemaphore(gc.dev, next_image_acquired, null);

        // const result = try gc.vkd.acquireNextImageKHR(gc.dev, handle, std.math.maxInt(u64), next_image_acquired, .null_handle);
        // if (result.result != .success) {
        //     return error.ImageAcquireFailed;
        // }

        // std.mem.swap(vk.Semaphore, &swap_images[result.image_index].image_acquired, &next_image_acquired);
        return Swapchain{
            .gc = gc,
            .allocator = allocator,
            .surface_format = surface_format,
            .present_mode = present_mode,
            .extent = actual_extent,
            .handle = handle,
            .render_pass = old_render_pass,
            .swap_images = swap_images,
        };
    }

    fn deinitExceptSwapchain(self: *Swapchain) void {
        for (self.swap_images) |si| si.deinit(self.gc);
        self.gc.vkd.destroyRenderPass(self.gc.dev, self.render_pass, null);
        self.destroyFramebuffers();
    }

    pub fn waitForAllFences(self: Swapchain) !void {
        for (self.swap_images) |si| si.waitForFence(self.gc) catch {};
    }

    pub fn deinit(self: *Swapchain) void {
        self.deinitExceptSwapchain();
        self.gc.vkd.destroySwapchainKHR(self.gc.dev, self.handle, null);
    }

    pub fn recreate(self: *Swapchain, new_extent: vk.Extent2D) !void {
        try self.waitForAllFences();
        const gc = self.gc;
        const allocator = self.allocator;
        const old_handle = self.handle;
        self.deinitExceptSwapchain();
        std.debug.print("Extent: {d} {d}\n", .{ new_extent.width, new_extent.height });
        self.* = try initRecycle(gc, allocator, new_extent, old_handle, .null_handle);
        try self.createRenderPass();
    }

    pub fn currentImage(self: Swapchain) vk.Image {
        return self.swap_images[self.image_index].image;
    }

    pub fn currentSwapImage(self: Swapchain) *const SwapImage {
        return &self.swap_images[self.image_index];
    }

    pub fn present(self: *Swapchain, cmdbuf: vk.CommandBuffer, current_frame: u32, extent: vk.Extent2D) !void {
        // Simple method:
        // 1) Acquire next image
        // 2) Wait for and reset fence of the acquired image
        // 3) Submit command buffer with fence of acquired image,
        //    dependendent on the semaphore signalled by the first step.
        // 4) Present current frame, dependent on semaphore signalled by previous step
        // Problem: This way we can't reference the current image while rendering.
        // Better method: Shuffle the steps around such that acquire next image is the last step,
        // leaving the swapchain in a state with the current image.
        // 1) Wait for and reset fence of current image
        // 2) Submit command buffer, signalling fence of current image and dependent on
        //    the semaphore signalled by step 4.
        // 3) Present current frame, dependent on semaphore signalled by the submit
        // 4) Acquire next image, signalling its semaphore
        // One problem that arises is that we can't know beforehand which semaphore to signal,
        // so we keep an extra auxilery semaphore that is swapped around

        // Step 1: Make sure the current frame has finished rendering
        const current = self.swap_images[current_frame];

        // Step 2: Submit the command buffer
        const wait_stage = [_]vk.PipelineStageFlags{.{ .color_attachment_output_bit = true }};
        try self.gc.vkd.queueSubmit(self.gc.graphics_queue.handle, 1, &[_]vk.SubmitInfo{.{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = @ptrCast(&current.image_acquired),
            .p_wait_dst_stage_mask = &wait_stage,
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast(&cmdbuf),
            .signal_semaphore_count = 1,
            .p_signal_semaphores = @ptrCast(&current.render_finished),
        }}, current.frame_fence);

        // Step 3: Present the current frame
        const present_result = self.gc.vkd.queuePresentKHR(self.gc.present_queue.handle, &vk.PresentInfoKHR{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = @ptrCast(&current.render_finished),
            .swapchain_count = 1,
            .p_swapchains = @ptrCast(&self.handle),
            .p_image_indices = @ptrCast(&self.image_index),
            .p_results = null,
        }) catch |err| switch (err) {
            error.OutOfDateKHR => vk.Result.error_out_of_date_khr,
            else => return err,
        };

        if (present_result == .error_out_of_date_khr or present_result == .suboptimal_khr) {
            self.extent = extent;
            self.recreate(extent) catch |err| {
                std.debug.print("Error recreating swapchain: {any}\n", .{err});
            };
            try self.createFramebuffers();
        } else if (present_result != .success) {
            return error.ImagePresentFailed;
        }
    }

    pub fn createRenderPass(self: *@This()) !void {
        const attachments = [_]vk.AttachmentDescription{
            .{
                .flags = .{},
                .format = self.surface_format.format,
                .samples = .{ .@"1_bit" = true },
                .load_op = .clear,
                .store_op = .store,
                .stencil_load_op = .dont_care,
                .stencil_store_op = .dont_care,
                .initial_layout = .undefined,
                .final_layout = .present_src_khr,
            },
            .{
                .flags = .{},
                .format = try findDepthFormat(self.gc.*),
                .samples = .{ .@"1_bit" = true },
                .load_op = .clear,
                .store_op = .dont_care,
                .stencil_load_op = .dont_care,
                .stencil_store_op = .dont_care,
                .initial_layout = .undefined,
                .final_layout = .depth_stencil_attachment_optimal,
            },
        };

        const color_attachment_ref = [_]vk.AttachmentReference{.{
            .attachment = 0,
            .layout = .color_attachment_optimal,
        }};

        const depth_attachment_ref = vk.AttachmentReference{
            .attachment = 1,
            .layout = .depth_stencil_attachment_optimal,
        };

        const subpass = [_]vk.SubpassDescription{.{
            .flags = .{},
            .pipeline_bind_point = .graphics,
            .input_attachment_count = 0,
            .p_input_attachments = undefined,
            .color_attachment_count = color_attachment_ref.len,
            .p_color_attachments = &color_attachment_ref,
            .p_resolve_attachments = null,
            .p_depth_stencil_attachment = &depth_attachment_ref,
            .preserve_attachment_count = 0,
            .p_preserve_attachments = undefined,
        }};

        const dependencies = [_]vk.SubpassDependency{.{
            .src_subpass = vk.SUBPASS_EXTERNAL,
            .dst_subpass = 0,
            .src_stage_mask = .{ .color_attachment_output_bit = true, .early_fragment_tests_bit = true },
            .src_access_mask = .{},
            .dst_stage_mask = .{ .color_attachment_output_bit = true, .early_fragment_tests_bit = true },
            .dst_access_mask = .{ .color_attachment_write_bit = true, .depth_stencil_attachment_write_bit = true },
            .dependency_flags = .{},
        }};

        self.render_pass = try self.gc.vkd.createRenderPass(self.gc.dev, &.{
            .flags = .{},
            .attachment_count = attachments.len,
            .p_attachments = &attachments,
            .subpass_count = subpass.len,
            .p_subpasses = &subpass,
            .dependency_count = dependencies.len,
            .p_dependencies = &dependencies,
        }, null);
    }

    pub fn createFramebuffers(self: *@This()) !void {
        std.debug.print("Creating\n", .{});
        const framebuffers = try self.allocator.alloc(vk.Framebuffer, self.swap_images.len);
        errdefer self.allocator.free(framebuffers);

        var i: usize = 0;
        errdefer for (framebuffers[0..i]) |fb| self.gc.vkd.destroyFramebuffer(self.gc.dev, fb, null);

        for (framebuffers, 0..framebuffers.len) |*fb, j| {
            const attachments = [_]vk.ImageView{ self.swap_images[j].view, self.swap_images[j].depth_image_view };
            fb.* = try self.gc.vkd.createFramebuffer(self.gc.dev, &vk.FramebufferCreateInfo{
                .flags = .{},
                .render_pass = self.render_pass,
                .attachment_count = attachments.len,
                .p_attachments = &attachments,
                .width = self.extent.width,
                .height = self.extent.height,
                .layers = 1,
            }, null);
            i += 1;
        }

        self.framebuffers = framebuffers;
    }
    pub fn destroyFramebuffers(self: *@This()) void {
        for (self.framebuffers) |fb| self.gc.vkd.destroyFramebuffer(self.gc.dev, fb, null);
        self.allocator.free(self.framebuffers);
    }

    pub fn beginSwapChainRenderPass(self: *@This(), frame_info: FrameInfo) void {
        const clear_values = [_]vk.ClearValue{
            .{ .color = .{ .float_32 = .{ 0, 0, 0, 1 } } },
            .{ .depth_stencil = .{ .depth = 1.0, .stencil = 0 } },
        };
        const scissor = vk.Rect2D{
            .offset = .{ .x = 0, .y = 0 },
            .extent = self.extent,
        };

        const render_pass_info = vk.RenderPassBeginInfo{
            .render_pass = self.render_pass,
            .framebuffer = self.framebuffers[self.image_index],
            .render_area = scissor,
            .clear_value_count = clear_values.len,
            .p_clear_values = &clear_values,
        };

        self.gc.vkd.cmdBeginRenderPass(frame_info.command_buffer, &render_pass_info, .@"inline");
        const viewport = vk.Viewport{
            .x = 0,
            .y = 0,
            .width = @as(f32, @floatFromInt(self.extent.width)),
            .height = @as(f32, @floatFromInt(self.extent.height)),
            .min_depth = 0,
            .max_depth = 1,
        };

        self.gc.vkd.cmdSetViewport(frame_info.command_buffer, 0, 1, @as([*]const vk.Viewport, @ptrCast(&viewport)));
        self.gc.vkd.cmdSetScissor(frame_info.command_buffer, 0, 1, @as([*]const vk.Rect2D, @ptrCast(&scissor)));
    }

    pub fn endSwapChainRenderPass(self: *@This(), frame_info: FrameInfo) void {
        self.gc.vkd.cmdEndRenderPass(frame_info.command_buffer);
    }

    pub fn acquireNextImage(
        self: *Swapchain,
        current_frame: u32,
    ) !PresentState {
        // Step 4: Acquire next frame
        const result = try self.gc.vkd.acquireNextImageKHR(
            self.gc.dev,
            self.handle,
            std.math.maxInt(u64),
            self.swap_images[current_frame].image_acquired,
            .null_handle,
        );

        self.image_index = result.image_index;

        return switch (result.result) {
            .success => .optimal,
            .suboptimal_khr => .suboptimal,
            else => unreachable,
        };
    }

    pub fn beginFrame(self: *@This(), frame_info: FrameInfo) !void {
        if (self.swap_images[self.image_index].image_acquired != .null_handle) {
            _ = try self.gc.vkd.waitForFences(self.gc.dev, 1, @ptrCast(&self.swap_images[self.image_index].frame_fence), vk.TRUE, std.math.maxInt(u64));
        }

        if (frame_info.extent.width != self.extent.width or frame_info.extent.height != self.extent.height) {
            self.extent = frame_info.extent;
            self.recreate(self.extent) catch |err| {
                std.debug.print("Error recreating swapchain: {any}\n", .{err});
            };
            try self.createFramebuffers();
        }

        const result = self.acquireNextImage(frame_info.current_frame) catch |err| switch (err) {
            error.OutOfDateKHR => Swapchain.PresentState.suboptimal,
            else => |narrow| return narrow,
        };

        if (result == .suboptimal) {
            self.extent = frame_info.extent;
            self.recreate(self.extent) catch |err| {
                std.debug.print("Error recreating swapchain: {any}\n", .{err});
            };
            try self.createFramebuffers();
        }

        try self.gc.vkd.resetFences(self.gc.dev, 1, @ptrCast(&self.swap_images[frame_info.current_frame].frame_fence));

        try self.gc.vkd.resetCommandBuffer(frame_info.command_buffer, .{});

        const begin_info = vk.CommandBufferBeginInfo{};

        try self.gc.vkd.beginCommandBuffer(frame_info.command_buffer, &begin_info);
    }

    pub fn endFrame(self: *@This(), cmdbuf: vk.CommandBuffer, current_frame: *u32, extent: vk.Extent2D) !void {
        self.gc.vkd.endCommandBuffer(cmdbuf) catch |err| {
            std.debug.print("Error ending command buffer: {any}\n", .{err});
        };

        self.present(cmdbuf, current_frame.*, extent) catch |err| {
            std.debug.print("Error presenting frame: {any}\n", .{err});
        };

        current_frame.* = (current_frame.* + 1) % MAX_FRAMES_IN_FLIGHT;
    }
};

const SwapImage = struct {
    image: vk.Image,
    view: vk.ImageView,
    image_acquired: vk.Semaphore,
    render_finished: vk.Semaphore,
    frame_fence: vk.Fence,
    depth_image: vk.Image,
    depth_image_view: vk.ImageView,
    depth_image_memory: vk.DeviceMemory,

    fn init(gc: *const GraphicsContext, image: vk.Image, format: vk.Format, extent: vk.Extent2D) !SwapImage {
        const view = try gc.vkd.createImageView(gc.dev, &.{
            .flags = .{},
            .image = image,
            .view_type = .@"2d",
            .format = format,
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        }, null);
        errdefer gc.vkd.destroyImageView(gc.dev, view, null);

        const image_acquired = try gc.vkd.createSemaphore(gc.dev, &.{ .flags = .{} }, null);
        errdefer gc.vkd.destroySemaphore(gc.dev, image_acquired, null);

        const render_finished = try gc.vkd.createSemaphore(gc.dev, &.{ .flags = .{} }, null);
        errdefer gc.vkd.destroySemaphore(gc.dev, render_finished, null);

        const frame_fence = try gc.vkd.createFence(gc.dev, &.{ .flags = .{ .signaled_bit = true } }, null);
        errdefer gc.vkd.destroyFence(gc.dev, frame_fence, null);

        const depth_image = try gc.vkd.createImage(gc.dev, &.{
            .image_type = .@"2d",
            .extent = .{ .width = extent.width, .height = extent.height, .depth = 1 },
            .mip_levels = 1,
            .array_layers = 1,
            .format = try findDepthFormat(gc.*),
            .tiling = .optimal,
            .initial_layout = .undefined,
            .usage = .{ .depth_stencil_attachment_bit = true },
            .samples = .{ .@"1_bit" = true },
            .sharing_mode = .exclusive,
            .flags = .{},
            .queue_family_index_count = 0,
        }, null);

        const mem_reqs = gc.vkd.getImageMemoryRequirements(gc.dev, depth_image);
        const depth_image_memory = try gc.allocate(mem_reqs, .{ .device_local_bit = true });

        try gc.vkd.bindImageMemory(gc.dev, depth_image, depth_image_memory, 0);

        const depth_image_view = try gc.vkd.createImageView(gc.dev, &.{
            .flags = .{},
            .image = depth_image,
            .view_type = .@"2d",
            .format = try findDepthFormat(gc.*),
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
            .subresource_range = .{
                .aspect_mask = .{ .depth_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        }, null);

        return SwapImage{
            .image = image,
            .view = view,
            .image_acquired = image_acquired,
            .render_finished = render_finished,
            .frame_fence = frame_fence,
            .depth_image = depth_image,
            .depth_image_view = depth_image_view,
            .depth_image_memory = depth_image_memory,
        };
    }

    fn deinit(self: SwapImage, gc: *const GraphicsContext) void {
        self.waitForFence(gc) catch return;
        gc.vkd.destroyImageView(gc.dev, self.depth_image_view, null);
        gc.vkd.freeMemory(gc.dev, self.depth_image_memory, null);
        gc.vkd.destroyImage(gc.dev, self.depth_image, null);
        gc.vkd.destroyImageView(gc.dev, self.view, null);
        gc.vkd.destroySemaphore(gc.dev, self.image_acquired, null);
        gc.vkd.destroySemaphore(gc.dev, self.render_finished, null);
        gc.vkd.destroyFence(gc.dev, self.frame_fence, null);
    }

    fn waitForFence(self: SwapImage, gc: *const GraphicsContext) !void {
        _ = try gc.vkd.waitForFences(gc.dev, 1, @ptrCast(&self.frame_fence), vk.TRUE, std.math.maxInt(u64));
    }
};

fn initSwapchainImages(gc: *const GraphicsContext, swapchain: vk.SwapchainKHR, format: vk.Format, allocator: Allocator, extent: vk.Extent2D) ![]SwapImage {
    var count: u32 = undefined;
    _ = try gc.vkd.getSwapchainImagesKHR(gc.dev, swapchain, &count, null);
    const images = try allocator.alloc(vk.Image, count);
    defer allocator.free(images);
    _ = try gc.vkd.getSwapchainImagesKHR(gc.dev, swapchain, &count, images.ptr);

    const swap_images = try allocator.alloc(SwapImage, count);
    errdefer allocator.free(swap_images);

    var i: usize = 0;
    errdefer for (swap_images[0..i]) |si| si.deinit(gc);

    for (images) |image| {
        swap_images[i] = try SwapImage.init(gc, image, format, extent);
        i += 1;
    }

    return swap_images;
}

fn findSurfaceFormat(gc: *const GraphicsContext, allocator: Allocator) !vk.SurfaceFormatKHR {
    const preferred = vk.SurfaceFormatKHR{
        // .format = .b8g8r8a8_srgb,
        // .color_space = .srgb_nonlinear_khr,
        .format = .a2b10g10r10_unorm_pack32,
        .color_space = .hdr10_hlg_ext,
    };

    var count: u32 = undefined;
    _ = try gc.vki.getPhysicalDeviceSurfaceFormatsKHR(gc.pdev, gc.surface, &count, null);
    const surface_formats = try allocator.alloc(vk.SurfaceFormatKHR, count);
    defer allocator.free(surface_formats);
    _ = try gc.vki.getPhysicalDeviceSurfaceFormatsKHR(gc.pdev, gc.surface, &count, surface_formats.ptr);

    for (surface_formats) |sfmt| {
        if (std.meta.eql(sfmt, preferred)) {
            return preferred;
        }
    }

    return surface_formats[0]; // There must always be at least one supported surface format
}

fn findPresentMode(gc: *const GraphicsContext, allocator: Allocator) !vk.PresentModeKHR {
    var count: u32 = undefined;
    _ = try gc.vki.getPhysicalDeviceSurfacePresentModesKHR(gc.pdev, gc.surface, &count, null);
    const present_modes = try allocator.alloc(vk.PresentModeKHR, count);
    defer allocator.free(present_modes);
    _ = try gc.vki.getPhysicalDeviceSurfacePresentModesKHR(gc.pdev, gc.surface, &count, present_modes.ptr);
    std.debug.print("The following modes are here: {any}\n", .{present_modes});
    const preferred = [_]vk.PresentModeKHR{ .immediate_khr, .mailbox_khr };

    for (preferred) |mode| {
        if (std.mem.indexOfScalar(vk.PresentModeKHR, present_modes, mode) != null) {
            return mode;
        }
    }

    return .fifo_khr;
}

fn findActualExtent(caps: vk.SurfaceCapabilitiesKHR, extent: vk.Extent2D) vk.Extent2D {
    if (caps.current_extent.width != 0xFFFF_FFFF) {
        return caps.current_extent;
    } else {
        return .{
            .width = std.math.clamp(extent.width, caps.min_image_extent.width, caps.max_image_extent.width),
            .height = std.math.clamp(extent.height, caps.min_image_extent.height, caps.max_image_extent.height),
        };
    }
}

fn findSupportedFormat(gc: GraphicsContext, candidates: []const vk.Format, tiling: vk.ImageTiling, features: vk.FormatFeatureFlags) !vk.Format {
    for (candidates) |format| {
        var props = gc.vki.getPhysicalDeviceFormatProperties(gc.pdev, format);

        if (tiling == .linear and props.linear_tiling_features.contains(features) and hasStencilComponent(format)) {
            return format;
        } else if (tiling == .optimal and props.optimal_tiling_features.contains(features) and hasStencilComponent(format)) {
            return format;
        }
    }

    return error.NoSupportedFormat;
}

fn findDepthFormat(gc: GraphicsContext) !vk.Format {
    const preferred = [_]vk.Format{ .d32_sfloat, .d32_sfloat_s8_uint, .d24_unorm_s8_uint };
    return try findSupportedFormat(gc, preferred[0..], .optimal, .{ .depth_stencil_attachment_bit = true });
}

fn hasStencilComponent(format: vk.Format) bool {
    return format == .d32_sfloat_s8_uint or format == .d24_unorm_s8_uint;
}
