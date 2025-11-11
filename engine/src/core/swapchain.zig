const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("graphics_context.zig").GraphicsContext;
const Texture = @import("texture.zig").Texture;
const TextureManager = @import("../rendering/texture_manager.zig").TextureManager;
const ManagedTexture = @import("../rendering/texture_manager.zig").ManagedTexture;
const glfw = @import("glfw");
const FrameInfo = @import("../rendering/frameinfo.zig").FrameInfo;
const log = @import("../utils/log.zig").log;

const Allocator = std.mem.Allocator;

pub const MAX_FRAMES_IN_FLIGHT = 3;

pub const Swapchain = struct {
    pub const PresentState = enum {
        optimal,
        suboptimal,
    };

    gc: *GraphicsContext,
    allocator: Allocator,
    texture_manager: ?*TextureManager = null,

    surface_format: vk.SurfaceFormatKHR,
    // HDR rendering format used for intermediate backbuffers
    hdr_format: vk.Format = .r32g32b32a32_sfloat,
    present_mode: vk.PresentModeKHR,
    extent: vk.Extent2D,
    handle: vk.SwapchainKHR,
    render_pass: vk.RenderPass = undefined,
    framebuffers: []vk.Framebuffer = undefined,
    image_acquired: []vk.Semaphore = undefined,
    render_finished: []vk.Semaphore = undefined,
    frame_fence: []vk.Fence = undefined,
    compute_finished: []vk.Semaphore = undefined,
    compute_fence: []vk.Fence = undefined,

    swap_images: []SwapImage,
    // HDR textures per frame-in-flight (decoupled from swapchain images)
    hdr_textures: [MAX_FRAMES_IN_FLIGHT]*ManagedTexture = undefined,
    image_index: u32 = 0,
    use_viewport_texture: bool = false,
    compute: bool = false, // Whether to use compute shaders in the swapchain

    pub fn init(gc: *GraphicsContext, allocator: Allocator, texture_manager: *TextureManager, extent: vk.Extent2D) !Swapchain {
        var swapchain = try initRecycle(gc, allocator, extent, .null_handle, .null_handle);
        swapchain.texture_manager = texture_manager;

        // Create HDR textures per frame-in-flight (independent of swapchain image count)
        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            var hdr_name_buf: [64]u8 = undefined;
            const hdr_name = try std.fmt.bufPrint(&hdr_name_buf, "swapchain_hdr_{}", .{i});

            swapchain.hdr_textures[i] = try texture_manager.getOrCreateTexture(.{
                .name = hdr_name,
                .format = swapchain.hdr_format,
                .extent = .{ .width = extent.width, .height = extent.height, .depth = 1 },
                .usage = .{
                    .color_attachment_bit = true,
                    .sampled_bit = true,
                    .transfer_dst_bit = true,
                },
                .samples = .{ .@"1_bit" = true },
            });

            // Track estimated swapchain image memory (not directly allocated by us, but still uses GPU memory)
            // Calculate bytes per pixel outside of runtime control flow
            const bytes_per_pixel: u32 = switch (swapchain.hdr_format) {
                .b8g8r8a8_srgb, .b8g8r8a8_unorm, .r8g8b8a8_srgb, .r8g8b8a8_unorm => 4,
                .a2b10g10r10_unorm_pack32 => 4,
                .r16g16b16a16_sfloat => 8,
                .r32g32b32a32_sfloat => 16,
                else => 4, // Conservative estimate for unknown formats
            };

            if (gc.memory_tracker) |tracker| {
                const estimated_size: u64 = @as(u64, extent.width) * @as(u64, extent.height) * bytes_per_pixel;

                var buf: [32]u8 = undefined;
                const key = std.fmt.bufPrint(&buf, "HDR_image_{x}", .{i}) catch "HDR Image Unknown";
                tracker.trackAllocation(key, estimated_size, .texture) catch |err| {
                    std.log.warn("Failed to track HDR image allocation: {}", .{err});
                };
            }
        }

        var image_acquired = try allocator.alloc(vk.Semaphore, MAX_FRAMES_IN_FLIGHT);
        var render_finished = try allocator.alloc(vk.Semaphore, swapchain.swap_images.len);
        var frame_fence = try allocator.alloc(vk.Fence, MAX_FRAMES_IN_FLIGHT);
        // Allocate compute sync primitives
        var compute_finished = try allocator.alloc(vk.Semaphore, MAX_FRAMES_IN_FLIGHT);
        var compute_fence = try allocator.alloc(vk.Fence, MAX_FRAMES_IN_FLIGHT);
        var i: usize = 0;
        while (i < MAX_FRAMES_IN_FLIGHT) : (i += 1) {
            image_acquired[i] = try gc.vkd.createSemaphore(gc.dev, &.{ .flags = .{} }, null);
            errdefer gc.vkd.destroySemaphore(gc.dev, image_acquired[i], null);
            frame_fence[i] = try gc.vkd.createFence(gc.dev, &.{ .flags = .{ .signaled_bit = true } }, null);
            errdefer gc.vkd.destroyFence(gc.dev, frame_fence[i], null);

            // Compute sync

            compute_finished[i] = try gc.vkd.createSemaphore(gc.dev, &.{ .flags = .{} }, null);
            errdefer gc.vkd.destroySemaphore(gc.dev, compute_finished[i], null);
            compute_fence[i] = try gc.vkd.createFence(gc.dev, &.{ .flags = .{ .signaled_bit = true } }, null);
            errdefer gc.vkd.destroyFence(gc.dev, compute_fence[i], null);
        }
        for (0..swapchain.swap_images.len) |j| {
            render_finished[j] = try gc.vkd.createSemaphore(gc.dev, &.{ .flags = .{} }, null);
            errdefer gc.vkd.destroySemaphore(gc.dev, render_finished[j], null);
        }
        swapchain.image_acquired = image_acquired;
        swapchain.render_finished = render_finished;
        swapchain.frame_fence = frame_fence;
        swapchain.compute_finished = compute_finished;
        swapchain.compute_fence = compute_fence;

        // Create render pass and framebuffers for ImGui compatibility
        try swapchain.createRenderPass();
        try swapchain.createFramebuffers();

        return swapchain;
    }

    pub fn initRecycle(gc: *GraphicsContext, allocator: Allocator, extent: vk.Extent2D, old_handle: vk.SwapchainKHR, old_render_pass: vk.RenderPass) !Swapchain {
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

        const qfi = [_]u32{ gc.graphics_queue.family, gc.present_queue.family, gc.compute_queue.family };
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
            .image_usage = .{ .color_attachment_bit = true, .transfer_dst_bit = true, .sampled_bit = true },
            .image_sharing_mode = sharing_mode,
            .queue_family_index_count = qfi.len,
            .p_queue_family_indices = &qfi,
            .pre_transform = caps.current_transform,
            .composite_alpha = .{ .opaque_bit_khr = true },
            .present_mode = present_mode,
            .clipped = .true,
            .old_swapchain = old_handle,
        }, null);
        errdefer gc.vkd.destroySwapchainKHR(gc.dev, handle, null);

        if (old_handle != .null_handle) {
            // Apparently, the old swapchain handle still needs to be destroyed after recreating.
            gc.vkd.destroySwapchainKHR(gc.dev, old_handle, null);
        }

        const swap_images = try initSwapchainImages(gc, handle, surface_format.format, allocator, actual_extent);
        errdefer for (swap_images) |*si| si.deinit(gc);

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
            .hdr_format = .r16g16b16a16_sfloat,
            .present_mode = present_mode,
            .extent = actual_extent,
            .handle = handle,
            .render_pass = old_render_pass,
            .swap_images = swap_images,
        };
    }

    fn deinitExceptSwapchain(self: *Swapchain) void {
        for (self.swap_images) |*si| si.deinit(self.gc);
        self.gc.vkd.destroyRenderPass(self.gc.dev, self.render_pass, null);
        self.destroyFramebuffers();
    }

    /// Clean up HDR textures (only called during full shutdown, not recreation)
    fn cleanupHdrTextures(self: *Swapchain) void {
        if (self.texture_manager) |tm| {
            for (self.hdr_textures) |hdr_texture| {
                tm.destroyTexture(hdr_texture);
            }
        }
    }

    pub fn waitForAllFences(self: *Swapchain) !void {
        var i: usize = 0;
        while (i < MAX_FRAMES_IN_FLIGHT) : (i += 1) {
            _ = try self.gc.vkd.waitForFences(self.gc.dev, 1, @ptrCast(&self.frame_fence[i]), .true, std.math.maxInt(u64));
            _ = try self.gc.vkd.waitForFences(self.gc.dev, 1, @ptrCast(&self.compute_fence[i]), .true, std.math.maxInt(u64));
        }
    }

    pub fn deinit(self: *Swapchain) void {
        // Clean up HDR textures before other resources
        self.cleanupHdrTextures();

        self.deinitExceptSwapchain();
        self.gc.vkd.destroySwapchainKHR(self.gc.dev, self.handle, null);
        var i: usize = 0;
        while (i < MAX_FRAMES_IN_FLIGHT) : (i += 1) {
            self.gc.vkd.destroySemaphore(self.gc.dev, self.image_acquired[i], null);
            self.gc.vkd.destroyFence(self.gc.dev, self.frame_fence[i], null);
            // Compute sync
            self.gc.vkd.destroySemaphore(self.gc.dev, self.compute_finished[i], null);
            self.gc.vkd.destroyFence(self.gc.dev, self.compute_fence[i], null);
        }
        for (self.render_finished) |semaphore| {
            self.gc.vkd.destroySemaphore(self.gc.dev, semaphore, null);
        }

        // Free allocated memory
        self.allocator.free(self.image_acquired);
        self.allocator.free(self.render_finished);
        self.allocator.free(self.frame_fence);
        self.allocator.free(self.compute_finished);
        self.allocator.free(self.compute_fence);
        self.allocator.free(self.swap_images);
    }

    pub fn recreate(self: *Swapchain, new_extent: vk.Extent2D) !void {
        try self.waitForAllFences();
        const gc = self.gc;
        const allocator = self.allocator;
        const texture_manager = self.texture_manager orelse return error.TextureManagerNotSet;
        const old_handle = self.handle;
        const old_compute = self.compute;
        const old_hdr_textures = self.hdr_textures;
        self.deinitExceptSwapchain();
        const old_acquire = self.image_acquired;
        const old_finished = self.render_finished;
        const old_fence = self.frame_fence;
        const old_compute_finished = self.compute_finished;
        const old_compute_fence = self.compute_fence;
        self.* = try initRecycle(gc, allocator, new_extent, old_handle, .null_handle);
        self.*.texture_manager = texture_manager;
        self.*.hdr_textures = old_hdr_textures;

        // Update HDR textures with new extent
        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            var hdr_name_buf: [64]u8 = undefined;
            const hdr_name = try std.fmt.bufPrint(&hdr_name_buf, "swapchain_hdr_{}", .{i});

            self.*.hdr_textures[i] = try texture_manager.getOrCreateTexture(.{
                .name = hdr_name,
                .format = self.hdr_format,
                .extent = .{ .width = new_extent.width, .height = new_extent.height, .depth = 1 },
                .usage = .{
                    .color_attachment_bit = true,
                    .sampled_bit = true,
                    .transfer_dst_bit = true,
                },
                .samples = .{ .@"1_bit" = true },
            });
        }

        self.*.frame_fence = old_fence;
        self.*.image_acquired = old_acquire;
        self.*.render_finished = old_finished;
        self.*.compute_finished = old_compute_finished;
        self.*.compute_fence = old_compute_fence;
        self.*.compute = old_compute;
    }

    /// Set the texture manager for managing HDR textures
    pub fn setTextureManager(self: *Swapchain, texture_manager: *TextureManager) void {
        self.texture_manager = texture_manager;
    }

    pub fn currentImage(self: Swapchain) vk.Image {
        return self.swap_images[self.image_index].image;
    }

    pub fn currentSwapImage(self: Swapchain) *const SwapImage {
        return &self.swap_images[self.image_index];
    }

    /// Get array of HDR textures for all frames in flight
    /// Used by passes that need to bind all HDR textures at setup time
    pub fn getHdrTextures(self: *Swapchain) [MAX_FRAMES_IN_FLIGHT]*ManagedTexture {
        return self.hdr_textures;
    }

    pub fn depthFormat(self: Swapchain) !vk.Format {
        return try findDepthFormat(self.gc.*);
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

        // Step 2: Submit the command buffer
        if (self.compute) {
            const wait_stage = [_]vk.PipelineStageFlags{ .{ .color_attachment_output_bit = true }, .{ .compute_shader_bit = true } };
            try self.gc.submitToGraphicsQueue(1, &[_]vk.SubmitInfo{.{
                .wait_semaphore_count = 2,
                .p_wait_semaphores = &.{ self.image_acquired[current_frame], self.compute_finished[current_frame] },
                .p_wait_dst_stage_mask = &wait_stage,
                .command_buffer_count = 1,
                .p_command_buffers = @ptrCast(&cmdbuf),
                .signal_semaphore_count = 1,
                .p_signal_semaphores = @ptrCast(&self.render_finished[self.image_index]),
            }}, self.frame_fence[current_frame]);
        } else {
            const wait_stage = [_]vk.PipelineStageFlags{
                .{ .color_attachment_output_bit = true },
            };
            try self.gc.submitToGraphicsQueue(1, &[_]vk.SubmitInfo{.{
                .wait_semaphore_count = 1,
                .p_wait_semaphores = &.{self.image_acquired[current_frame]},
                .p_wait_dst_stage_mask = &wait_stage,
                .command_buffer_count = 1,
                .p_command_buffers = @ptrCast(&cmdbuf),
                .signal_semaphore_count = 1,
                .p_signal_semaphores = @ptrCast(&self.render_finished[self.image_index]),
            }}, self.frame_fence[current_frame]);
        }

        // Step 3: Present the current frame
        const present_result = self.gc.submitToPresentQueue(&vk.PresentInfoKHR{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = @ptrCast(&self.render_finished[self.image_index]),
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
                log(.ERROR, "swapchain", "Failed to recreate swapchain: {any}", .{err});
            };
            try self.createFramebuffers();
        } else if (present_result != .success) {
            return error.ImagePresentFailed;
        }
    }

    pub fn createRenderPass(self: *Swapchain) !void {
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

        const subpass = [_]vk.SubpassDescription{
            .{
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
            },
        };

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

    pub fn createFramebuffers(self: *Swapchain) !void {
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
    pub fn destroyFramebuffers(self: *Swapchain) void {
        for (self.framebuffers) |fb| self.gc.vkd.destroyFramebuffer(self.gc.dev, fb, null);
        self.allocator.free(self.framebuffers);
    }

    pub fn beginSwapChainRenderPass(self: *Swapchain, frame_info: FrameInfo) void {
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

    pub fn endSwapChainRenderPass(self: *Swapchain, frame_info: FrameInfo) void {
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
            self.image_acquired[current_frame],
            .null_handle,
        );

        self.image_index = result.image_index;

        return switch (result.result) {
            .success => .optimal,
            .suboptimal_khr => .suboptimal,
            else => unreachable,
        };
    }

    pub fn beginComputePass(self: *Swapchain, frame_info: FrameInfo) !void {
        _ = try self.gc.vkd.waitForFences(self.gc.dev, 1, @ptrCast(&self.compute_fence[frame_info.current_frame]), .true, std.math.maxInt(u64));

        // Reset compute fence for this frame
        try self.gc.vkd.resetFences(self.gc.dev, 1, @ptrCast(&self.compute_fence[frame_info.current_frame]));

        try self.gc.vkd.resetCommandBuffer(frame_info.compute_buffer, .{});

        const begin_info_compute = vk.CommandBufferBeginInfo{};
        try self.gc.vkd.beginCommandBuffer(frame_info.compute_buffer, &begin_info_compute);
    }

    pub fn beginFrame(self: *Swapchain, frame_info: FrameInfo) !void {
        if (self.image_acquired[frame_info.current_frame] != .null_handle) {
            _ = try self.gc.vkd.waitForFences(self.gc.dev, 1, @ptrCast(&self.frame_fence[frame_info.current_frame]), .true, std.math.maxInt(u64));

            // Now that GPU has finished executing the previous frame, cleanup secondary command buffers
            _ = try self.gc.vkd.waitForFences(self.gc.dev, 1, @ptrCast(&self.compute_fence[frame_info.current_frame]), .true, std.math.maxInt(u64));

            self.gc.cleanupSubmittedSecondaryBuffers();
        }

        // Handle resize - recreate swapchain if extent changed
        if (frame_info.extent.width != self.extent.width or frame_info.extent.height != self.extent.height) {
            log(.INFO, "swapchain", "Window resized: {}x{} -> {}x{}", .{ self.extent.width, self.extent.height, frame_info.extent.width, frame_info.extent.height });
            self.extent = frame_info.extent;
            self.recreate(self.extent) catch |err| {
                log(.ERROR, "swapchain", "Failed to recreate swapchain: {any}", .{err});
                return err;
            };
            log(.INFO, "swapchain", "Swapchain recreated successfully", .{});
        }

        // Acquire next image from swapchain
        var result = self.acquireNextImage(frame_info.current_frame) catch |err| switch (err) {
            error.OutOfDateKHR => Swapchain.PresentState.suboptimal,
            else => |narrow| return narrow,
        };

        // If suboptimal or out of date, recreate and retry acquire
        if (result == .suboptimal) {
            log(.INFO, "swapchain", "Swapchain suboptimal, recreating...", .{});
            self.extent = frame_info.extent;
            self.recreate(self.extent) catch |err| {
                log(.ERROR, "swapchain", "Failed to recreate swapchain: {any}", .{err});
                return err;
            };

            // Retry acquiring image after recreation
            result = self.acquireNextImage(frame_info.current_frame) catch |err| switch (err) {
                error.OutOfDateKHR => {
                    log(.WARN, "swapchain", "Swapchain still out of date after recreation", .{});
                    return error.OutOfDateKHR;
                },
                else => |narrow| return narrow,
            };
            log(.INFO, "swapchain", "Swapchain recreated and image acquired", .{});
        }

        try self.gc.vkd.resetFences(self.gc.dev, 1, @ptrCast(&self.frame_fence[frame_info.current_frame]));

        // Begin graphics command buffer
        try self.gc.vkd.resetCommandBuffer(frame_info.command_buffer, .{});
        const begin_info = vk.CommandBufferBeginInfo{};
        try self.gc.vkd.beginCommandBuffer(frame_info.command_buffer, &begin_info);

        // Transition swapchain image from UNDEFINED to GENERAL (only once after creation)
        // With unified image layouts, GENERAL is optimal for all operations
        const current_image = self.swap_images[self.image_index].image;
        self.gc.transitionImageLayout(
            frame_info.command_buffer,
            current_image,
            .undefined,
            .general, // Unified layout - no more transitions needed!
            .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        );

        // Also begin compute buffer (if compute is enabled)
        if (self.compute) {
            try self.gc.vkd.resetFences(self.gc.dev, 1, @ptrCast(&self.compute_fence[frame_info.current_frame]));
            try self.gc.vkd.resetCommandBuffer(frame_info.compute_buffer, .{});
            const begin_info_compute = vk.CommandBufferBeginInfo{};
            try self.gc.vkd.beginCommandBuffer(frame_info.compute_buffer, &begin_info_compute);
        }
    }

    pub fn endFrame(self: *Swapchain, frame_info: *FrameInfo) !void {
        // End and submit compute buffer first (if compute is enabled)
        if (self.compute) {
            self.gc.vkd.endCommandBuffer(frame_info.compute_buffer) catch |err| {
                log(.ERROR, "swapchain", "Error ending compute command buffer: {any}", .{err});
            };
            self.submitCompute(frame_info.compute_buffer, frame_info.current_frame) catch |err| {
                log(.ERROR, "swapchain", "Error submitting compute command buffer: {any}", .{err});
            };
        }

        // Execute all pending secondary command buffers from worker threads
        try self.gc.executeCollectedSecondaryBuffers(frame_info.command_buffer);

        // Only transition needed: GENERAL -> PRESENT_SRC for presentation
        const current_image = self.swap_images[self.image_index].image;
        self.gc.transitionImageLayout(
            frame_info.command_buffer,
            current_image,
            .general, // Unified layout
            .present_src_khr,
            .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        );

        // HDR texture transition is now handled by UI layer's begin() function
        // which clears and transitions it to color_attachment_optimal

        // End graphics buffer
        self.gc.vkd.endCommandBuffer(frame_info.command_buffer) catch |err| {
            log(.ERROR, "swapchain", "Error ending command buffer: {any}", .{err});
        };

        // Present (submits graphics buffer with semaphore wait on compute)
        self.present(frame_info.command_buffer, frame_info.current_frame, frame_info.extent) catch |err| {
            log(.ERROR, "swapchain", "Error presenting frame: {any}", .{err});
        };

        // Advance to next frame index
        frame_info.current_frame = (frame_info.current_frame + 1) % MAX_FRAMES_IN_FLIGHT;
    }

    pub fn endComputePass(self: *Swapchain, frame_info: FrameInfo) !void {
        self.gc.vkd.endCommandBuffer(frame_info.compute_buffer) catch |err| {
            log(.ERROR, "swapchain", "Error ending command buffer: {any}", .{err});
        };

        self.submitCompute(frame_info.compute_buffer, frame_info.current_frame) catch |err| {
            log(.ERROR, "swapchain", "Error submitting compute command buffer: {any}", .{err});
        };
    }

    pub fn submitCompute(self: *Swapchain, cmdbuf: vk.CommandBuffer, current_frame: u32) !void {
        // Wait for and reset compute fence for this frame
        // Submit compute command buffer
        //const wait_stage = [_]vk.PipelineStageFlags{.{ .compute_shader_bit = true }};
        try self.gc.submitToComputeQueue(1, &[_]vk.SubmitInfo{.{
            .wait_semaphore_count = 0,
            .p_wait_dst_stage_mask = null,
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast(&cmdbuf),
            .signal_semaphore_count = 1,
            .p_signal_semaphores = @ptrCast(&self.compute_finished[current_frame]),
        }}, self.compute_fence[current_frame]);
    }

    pub fn enableViewportTexture(self: *Swapchain, enable: bool) void {
        self.use_viewport_texture = enable;
    }
};

const SwapImage = struct {
    image: vk.Image,
    view: vk.ImageView,
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
        const depth_image_memory = try gc.allocate(mem_reqs, .{ .device_local_bit = true }, vk.MemoryAllocateFlags{ .device_address_bit = false });

        try gc.vkd.bindImageMemory(gc.dev, depth_image, depth_image_memory, 0);

        // Track depth buffer memory allocation
        if (gc.memory_tracker) |tracker| {
            var buf: [32]u8 = undefined;
            const key = std.fmt.bufPrint(&buf, "swapchain_depth_{x}", .{@intFromEnum(depth_image)}) catch "swapchain_depth_unknown";
            tracker.trackAllocation(key, mem_reqs.size, .texture) catch |err| {
                std.log.warn("Failed to track swapchain depth allocation: {}", .{err});
            };
        }

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

        // Track estimated swapchain image memory (not directly allocated by us, but still uses GPU memory)
        // Calculate bytes per pixel outside of runtime control flow
        const bytes_per_pixel: u32 = switch (format) {
            .b8g8r8a8_srgb, .b8g8r8a8_unorm, .r8g8b8a8_srgb, .r8g8b8a8_unorm => 4,
            .a2b10g10r10_unorm_pack32 => 4,
            .r16g16b16a16_sfloat => 8,
            else => 4, // Conservative estimate for unknown formats
        };

        if (gc.memory_tracker) |tracker| {
            const estimated_size: u64 = @as(u64, extent.width) * @as(u64, extent.height) * bytes_per_pixel;

            var buf: [32]u8 = undefined;
            const key = std.fmt.bufPrint(&buf, "swapchain_image_{x}", .{@intFromEnum(image)}) catch "swapchain_image_unknown";
            tracker.trackAllocation(key, estimated_size, .texture) catch |err| {
                std.log.warn("Failed to track swapchain image allocation: {}", .{err});
            };
        }

        return SwapImage{
            .image = image,
            .view = view,
            .depth_image = depth_image,
            .depth_image_view = depth_image_view,
            .depth_image_memory = depth_image_memory,
        };
    }

    fn deinit(self: *SwapImage, gc: *const GraphicsContext) void {
        // Untrack memory before freeing
        if (gc.memory_tracker) |tracker| {
            var buf: [32]u8 = undefined;

            // Untrack depth buffer
            const depth_key = std.fmt.bufPrint(&buf, "swapchain_depth_{x}", .{@intFromEnum(self.depth_image)}) catch "swapchain_depth_unknown";
            tracker.untrackAllocation(depth_key);

            // Untrack swapchain image
            const image_key = std.fmt.bufPrint(&buf, "swapchain_image_{x}", .{@intFromEnum(self.image)}) catch "swapchain_image_unknown";
            tracker.untrackAllocation(image_key);
        }

        gc.vkd.destroyImageView(gc.dev, self.depth_image_view, null);
        gc.vkd.freeMemory(gc.dev, self.depth_image_memory, null);
        gc.vkd.destroyImage(gc.dev, self.depth_image, null);
        gc.vkd.destroyImageView(gc.dev, self.view, null);
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
    errdefer for (swap_images[0..i]) |*si| si.deinit(gc);

    for (images) |image| {
        swap_images[i] = try SwapImage.init(gc, image, format, extent);
        i += 1;
    }

    return swap_images;
}

fn findSurfaceFormat(gc: *const GraphicsContext, allocator: Allocator) !vk.SurfaceFormatKHR {
    // Rank desired formats/colorspaces in preference order.
    // We will pick the first exact match found; otherwise fall back to a reasonable default.
    const prefs = [_]vk.SurfaceFormatKHR{
        // HDR10 (HLG)
        .{ .format = .a2b10g10r10_unorm_pack32, .color_space = .hdr10_hlg_ext },
        // HDR10 (PQ)
        .{ .format = .a2b10g10r10_unorm_pack32, .color_space = .hdr10_st2084_ext },
        // Wide-gamut linear options
        .{ .format = .r16g16b16a16_sfloat, .color_space = .extended_srgb_linear_ext },
        .{ .format = .r16g16b16a16_sfloat, .color_space = .bt709_linear_ext },
        // Standard sRGB
        .{ .format = .b8g8r8a8_srgb, .color_space = .srgb_nonlinear_khr },
    };

    var count: u32 = undefined;
    _ = try gc.vki.getPhysicalDeviceSurfaceFormatsKHR(gc.pdev, gc.surface, &count, null);
    const surface_formats = try allocator.alloc(vk.SurfaceFormatKHR, count);
    defer allocator.free(surface_formats);
    _ = try gc.vki.getPhysicalDeviceSurfaceFormatsKHR(gc.pdev, gc.surface, &count, surface_formats.ptr);

    // Try to find an exact match to our preference list
    for (prefs) |pref| {
        for (surface_formats) |sfmt| {
            if (sfmt.format == pref.format and sfmt.color_space == pref.color_space) {
                return sfmt;
            }
        }
    }

    // If no exact match, try to choose by preferred format regardless of color space
    for (prefs) |pref| {
        for (surface_formats) |sfmt| {
            if (sfmt.format == pref.format) {
                return sfmt;
            }
        }
    }

    // Absolute fallback: first supported format
    return surface_formats[0];
}

fn findPresentMode(gc: *const GraphicsContext, allocator: Allocator) !vk.PresentModeKHR {
    var count: u32 = undefined;
    _ = try gc.vki.getPhysicalDeviceSurfacePresentModesKHR(gc.pdev, gc.surface, &count, null);
    const present_modes = try allocator.alloc(vk.PresentModeKHR, count);
    defer allocator.free(present_modes);
    _ = try gc.vki.getPhysicalDeviceSurfacePresentModesKHR(gc.pdev, gc.surface, &count, present_modes.ptr);
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
