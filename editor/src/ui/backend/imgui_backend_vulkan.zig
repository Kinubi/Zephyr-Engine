const std = @import("std");
const vk = @import("vulkan");
const zephyr = @import("zephyr");

const c = @import("imgui_c.zig").c;

const GraphicsContext = zephyr.GraphicsContext;
const Swapchain = zephyr.Swapchain;
const Buffer = zephyr.Buffer;
const Texture = zephyr.Texture;
const UnifiedPipelineSystem = zephyr.UnifiedPipelineSystem;
const PipelineId = zephyr.PipelineId;
const Resource = zephyr.Resource;
const ResourceBinder = zephyr.ResourceBinder;
const DynamicRenderingHelper = zephyr.DynamicRenderingHelper;
const MAX_FRAMES_IN_FLIGHT = 3; // TODO: Get from engine config

pub const ImGuiVulkanBackend = struct {
    allocator: std.mem.Allocator,
    gc: *GraphicsContext,
    swapchain_format: vk.Format,
    pipeline_system: *UnifiedPipelineSystem,
    pipeline_id: ?PipelineId = null,
    cached_pipeline_handle: vk.Pipeline = .null_handle,
    resource_binder: ResourceBinder,

    // Font texture using engine's Texture class
    font_texture: ?Texture = null,

    // Dynamic vertex and index buffers using engine's Buffer class
    vertex_buffer: ?Buffer = null,
    index_buffer: ?Buffer = null,

    // Current buffer sizes
    vertex_buffer_size: usize = 0,
    index_buffer_size: usize = 0,

    // Track if resources need setup
    resources_need_setup: bool = true,

    pub fn init(allocator: std.mem.Allocator, gc: *GraphicsContext, swapchain: *Swapchain, pipeline_system: *UnifiedPipelineSystem) !ImGuiVulkanBackend {
        var self = ImGuiVulkanBackend{
            .allocator = allocator,
            .gc = gc,
            .swapchain_format = swapchain.surface_format.format,
            .pipeline_system = pipeline_system,
            .resource_binder = ResourceBinder.init(allocator, pipeline_system),
        };

        // Try to create pipeline - may fail if shaders aren't compiled yet
        self.createPipeline() catch |err| {
            std.debug.print("ImGui: Pipeline creation deferred (shaders not ready): {}\n", .{err});
        };

        // Upload fonts to GPU
        try self.uploadFonts();

        return self;
    }

    pub fn deinit(self: *ImGuiVulkanBackend) void {
        self.gc.vkd.deviceWaitIdle(self.gc.dev) catch {};

        if (self.vertex_buffer) |*vb| {
            vb.deinit();
        }

        if (self.index_buffer) |*ib| {
            ib.deinit();
        }

        if (self.font_texture) |*ft| {
            ft.deinit();
        }

        self.resource_binder.deinit();
    }

    fn uploadFonts(self: *ImGuiVulkanBackend) !void {
        const io = c.ImGui_GetIO();

        var pixels: [*c]u8 = undefined;
        var width: c_int = 0;
        var height: c_int = 0;
        c.ImFontAtlas_GetTexDataAsRGBA32(io.*.Fonts, &pixels, &width, &height, null);

        const pixel_count = @as(usize, @intCast(width * height * 4));
        const pixel_data: []const u8 = pixels[0..pixel_count];

        // Create texture - Texture.init() will transition to shader_read_only_optimal for sampled-only textures
        self.font_texture = try Texture.init(
            self.gc,
            .r8g8b8a8_unorm, // Use unorm, not srgb for fonts
            .{ .width = @intCast(width), .height = @intCast(height), .depth = 1 },
            .{ .sampled_bit = true, .transfer_dst_bit = true },
            .{ .@"1_bit" = true },
        );

        // Transition to transfer_dst_optimal for upload
        try self.gc.transitionImageLayoutSingleTime(
            self.font_texture.?.image,
            .shader_read_only_optimal,
            .transfer_dst_optimal,
            .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        );

        // Upload pixel data to texture via staging buffer
        const buffer_size = pixel_count;
        var staging_buffer = try Buffer.init(
            self.gc,
            buffer_size,
            1,
            .{ .transfer_src_bit = true },
            .{ .host_visible_bit = true, .host_coherent_bit = true },
        );
        defer staging_buffer.deinit();

        try staging_buffer.map(buffer_size, 0);
        staging_buffer.writeToBuffer(pixel_data, buffer_size, 0);
        staging_buffer.unmap();

        // Copy buffer to image
        try self.gc.copyBufferToImageSingleTime(
            staging_buffer,
            self.font_texture.?.image,
            @intCast(width),
            @intCast(height),
        );

        // Transition to shader read only layout for sampling
        try self.gc.transitionImageLayoutSingleTime(
            self.font_texture.?.image,
            .transfer_dst_optimal,
            .shader_read_only_optimal,
            .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        );

        // Update descriptor info with correct layout
        self.font_texture.?.descriptor.image_layout = .shader_read_only_optimal;
    }

    fn createPipeline(self: *ImGuiVulkanBackend) !void {
        const color_formats = [_]vk.Format{self.swapchain_format};

        // Define ImGui vertex input layout
        const PipelineBuilder = zephyr.PipelineBuilder;

        const bindings = [_]PipelineBuilder.VertexInputBinding{
            .{ .binding = 0, .stride = @sizeOf(c.ImDrawVert), .input_rate = .vertex },
        };

        const attributes = [_]PipelineBuilder.VertexInputAttribute{
            .{ .location = 0, .binding = 0, .format = .r32g32_sfloat, .offset = @offsetOf(c.ImDrawVert, "pos") },
            .{ .location = 1, .binding = 0, .format = .r32g32_sfloat, .offset = @offsetOf(c.ImDrawVert, "uv") },
            .{ .location = 2, .binding = 0, .format = .r8g8b8a8_unorm, .offset = @offsetOf(c.ImDrawVert, "col") },
        };

        // Push constant range for scale/translate
        const push_constants = [_]vk.PushConstantRange{
            .{
                .stage_flags = .{ .vertex_bit = true },
                .offset = 0,
                .size = @sizeOf(f32) * 4, // scale.xy + translate.xy
            },
        };

        // Register ImGui pipeline with UnifiedPipelineSystem
        const result = try self.pipeline_system.createPipeline(.{
            .name = "imgui",
            .vertex_shader = "assets/shaders/imgui.vert",
            .fragment_shader = "assets/shaders/imgui.frag",
            .vertex_input_bindings = &bindings,
            .vertex_input_attributes = &attributes,
            .push_constant_ranges = &push_constants,
            .render_pass = .null_handle, // Using dynamic rendering
            .dynamic_rendering_color_formats = &color_formats,
            .dynamic_rendering_depth_format = null,
            .cull_mode = .{}, // No culling
            .depth_stencil_state = .{
                .depth_test_enable = false,
                .depth_write_enable = false,
                .depth_compare_op = .always,
                .depth_bounds_test_enable = false,
                .stencil_test_enable = false,
                .front = undefined,
                .back = undefined,
                .min_depth_bounds = 0,
                .max_depth_bounds = 1,
            },
            .color_blend_attachment = .{
                .blend_enable = true,
                .src_color_blend_factor = .src_alpha,
                .dst_color_blend_factor = .one_minus_src_alpha,
                .color_blend_op = .add,
                .src_alpha_blend_factor = .one,
                .dst_alpha_blend_factor = .zero,
                .alpha_blend_op = .add,
                .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
            },
        });

        self.pipeline_id = result.id;

        if (!result.success) {
            std.log.warn("ImGui pipeline creation failed. ImGui rendering will be disabled.", .{});
            return error.PipelineCreationFailed;
        }

        // Cache the pipeline handle
        if (self.pipeline_id) |pid| {
            const entry = self.pipeline_system.pipelines.get(pid) orelse return error.PipelineNotFound;
            self.cached_pipeline_handle = entry.vulkan_pipeline;
        }

        // Mark that resources need setup
        self.resources_need_setup = true;
    }

    /// Bind resources (font texture) for all frames
    fn setupResources(self: *ImGuiVulkanBackend) !void {
        if (self.pipeline_id == null) return;
        if (self.font_texture == null) return;

        // Bind font texture to descriptor set 0, binding 0 for all frames
        const font_descriptor = self.font_texture.?.getDescriptorInfo();
        const texture_resource = Resource{
            .image = .{
                .image_view = font_descriptor.image_view,
                .sampler = font_descriptor.sampler,
                .layout = font_descriptor.image_layout,
            },
        };

        for (0..MAX_FRAMES_IN_FLIGHT) |frame_idx| {
            try self.pipeline_system.bindResource(
                self.pipeline_id.?,
                0, // Set
                0, // Binding
                texture_resource,
                @intCast(frame_idx),
            );
        }

        // Update resource binder for all frames
        for (0..MAX_FRAMES_IN_FLIGHT) |frame_idx| {
            try self.resource_binder.updateFrame(self.pipeline_id.?, @intCast(frame_idx));
        }
    }

    fn updateBuffers(self: *ImGuiVulkanBackend, draw_data: [*c]c.ImDrawData) !void {
        if (draw_data == null) return;

        const vertex_size = @as(usize, @intCast(draw_data.*.TotalVtxCount)) * @sizeOf(c.ImDrawVert);
        const index_size = @as(usize, @intCast(draw_data.*.TotalIdxCount)) * @sizeOf(c.ImDrawIdx);

        if (vertex_size == 0 or index_size == 0) return;

        // Create or resize vertex buffer
        if (self.vertex_buffer == null or vertex_size > self.vertex_buffer_size) {
            if (self.vertex_buffer) |*vb| {
                vb.deinit();
            }

            self.vertex_buffer = try Buffer.init(self.gc, @sizeOf(c.ImDrawVert), @as(u32, @intCast(draw_data.*.TotalVtxCount)), .{ .vertex_buffer_bit = true, .transfer_dst_bit = true }, .{ .host_visible_bit = true, .host_coherent_bit = true });
            self.vertex_buffer_size = vertex_size;

            try self.vertex_buffer.?.map(vk.WHOLE_SIZE, 0);
        }

        // Create or resize index buffer
        if (self.index_buffer == null or index_size > self.index_buffer_size) {
            if (self.index_buffer) |*ib| {
                ib.deinit();
            }

            self.index_buffer = try Buffer.init(self.gc, @sizeOf(c.ImDrawIdx), @as(u32, @intCast(draw_data.*.TotalIdxCount)), .{ .index_buffer_bit = true, .transfer_dst_bit = true }, .{ .host_visible_bit = true, .host_coherent_bit = true });
            self.index_buffer_size = index_size;

            try self.index_buffer.?.map(vk.WHOLE_SIZE, 0);
        }

        // Copy vertex and index data
        var vtx_dst = @as([*]c.ImDrawVert, @ptrCast(@alignCast(self.vertex_buffer.?.mapped.?)));
        var idx_dst = @as([*]c.ImDrawIdx, @ptrCast(@alignCast(self.index_buffer.?.mapped.?)));

        var n: usize = 0;
        while (n < draw_data.*.CmdListsCount) : (n += 1) {
            const cmd_list = draw_data.*.CmdLists.Data[n];

            const vtx_src = cmd_list.*.VtxBuffer.Data;
            const vtx_count = @as(usize, @intCast(cmd_list.*.VtxBuffer.Size));
            @memcpy(vtx_dst[0..vtx_count], vtx_src[0..vtx_count]);
            vtx_dst += vtx_count;

            const idx_src = cmd_list.*.IdxBuffer.Data;
            const idx_count = @as(usize, @intCast(cmd_list.*.IdxBuffer.Size));
            @memcpy(idx_dst[0..idx_count], idx_src[0..idx_count]);
            idx_dst += idx_count;
        }

        // No need to flush - we're using host_coherent_bit memory
    }

    pub fn renderDrawData(self: *ImGuiVulkanBackend, cmd: vk.CommandBuffer, draw_data: [*c]c.ImDrawData, swapchain: *Swapchain, frame_index: u32) !void {
        // Early exit if nothing to render
        if (draw_data == null or draw_data.*.CmdListsCount == 0) return;

        // Now we have a pipeline, proceed with rendering
        if (self.pipeline_id == null) return;

        // Check if pipeline was hot-reloaded
        const pipeline_entry = self.pipeline_system.pipelines.get(self.pipeline_id.?) orelse return error.PipelineNotFound;
        const pipeline_rebuilt = pipeline_entry.vulkan_pipeline != self.cached_pipeline_handle;

        if (pipeline_rebuilt) {
            std.debug.print("ImGui: Pipeline hot-reloaded, rebinding descriptors\n", .{});
            self.cached_pipeline_handle = pipeline_entry.vulkan_pipeline;
            self.resource_binder.clearPipeline(self.pipeline_id.?);
            self.resources_need_setup = true;
        }

        // Setup resources if needed
        if (self.resources_need_setup) {
            try self.setupResources();
            self.resources_need_setup = false;
        }

        // Update vertex and index buffers
        try self.updateBuffers(draw_data);

        if (self.vertex_buffer == null or self.index_buffer == null) return;

        // Setup dynamic rendering with load operation (preserve existing framebuffer)
        const rendering = DynamicRenderingHelper.initLoad(
            swapchain.swap_images[swapchain.image_index].view,
            null, // No depth for ImGui
            swapchain.extent,
        );

        // Begin rendering (also sets viewport and scissor)
        rendering.begin(self.gc, cmd);
        defer rendering.end(self.gc, cmd);

        // Bind ImGui pipeline with descriptor sets
        try self.pipeline_system.bindPipelineWithDescriptorSets(cmd, self.pipeline_id.?, frame_index);

        // Bind vertex and index buffers
        const vb_offset: vk.DeviceSize = 0;
        self.gc.vkd.cmdBindVertexBuffers(cmd, 0, 1, @ptrCast(&self.vertex_buffer.?.buffer), @ptrCast(&vb_offset));
        self.gc.vkd.cmdBindIndexBuffer(cmd, self.index_buffer.?.buffer, 0, .uint16);

        // Setup orthographic projection matrix in push constants
        const L: f32 = draw_data.*.DisplayPos.x;
        const R: f32 = draw_data.*.DisplayPos.x + draw_data.*.DisplaySize.x;
        const T: f32 = draw_data.*.DisplayPos.y;
        const B: f32 = draw_data.*.DisplayPos.y + draw_data.*.DisplaySize.y;

        const push_constants = [4]f32{
            2.0 / (R - L),
            2.0 / (B - T),
            -1.0 - L * (2.0 / (R - L)),
            -1.0 - T * (2.0 / (B - T)),
        };

        const layout = try self.pipeline_system.getPipelineLayout(self.pipeline_id.?);
        self.gc.vkd.cmdPushConstants(
            cmd,
            layout,
            .{ .vertex_bit = true },
            0,
            @sizeOf(@TypeOf(push_constants)),
            &push_constants,
        );

        // Render command lists
        var vtx_offset: u32 = 0;
        var idx_offset: u32 = 0;

        const clip_off = draw_data.*.DisplayPos;
        const clip_scale = draw_data.*.FramebufferScale;

        var n: usize = 0;
        while (n < draw_data.*.CmdListsCount) : (n += 1) {
            const cmd_list = draw_data.*.CmdLists.Data[n];

            var cmd_i: usize = 0;
            while (cmd_i < cmd_list.*.CmdBuffer.Size) : (cmd_i += 1) {
                const pcmd = &cmd_list.*.CmdBuffer.Data[cmd_i];

                // User callback - skip for now
                if (pcmd.UserCallback != null) {
                    continue;
                }

                // Project scissor/clipping rectangles
                var clip_min = c.ImVec2{
                    .x = (pcmd.ClipRect.x - clip_off.x) * clip_scale.x,
                    .y = (pcmd.ClipRect.y - clip_off.y) * clip_scale.y,
                };
                var clip_max = c.ImVec2{
                    .x = (pcmd.ClipRect.z - clip_off.x) * clip_scale.x,
                    .y = (pcmd.ClipRect.w - clip_off.y) * clip_scale.y,
                };

                // Clamp to viewport
                if (clip_min.x < 0.0) clip_min.x = 0.0;
                if (clip_min.y < 0.0) clip_min.y = 0.0;
                if (clip_max.x > @as(f32, @floatFromInt(swapchain.extent.width))) clip_max.x = @floatFromInt(swapchain.extent.width);
                if (clip_max.y > @as(f32, @floatFromInt(swapchain.extent.height))) clip_max.y = @floatFromInt(swapchain.extent.height);
                if (clip_max.x <= clip_min.x or clip_max.y <= clip_min.y) continue;

                // Apply scissor
                const scissor = vk.Rect2D{
                    .offset = .{
                        .x = @as(i32, @intFromFloat(clip_min.x)),
                        .y = @as(i32, @intFromFloat(clip_min.y)),
                    },
                    .extent = .{
                        .width = @as(u32, @intFromFloat(clip_max.x - clip_min.x)),
                        .height = @as(u32, @intFromFloat(clip_max.y - clip_min.y)),
                    },
                };
                self.gc.vkd.cmdSetScissor(cmd, 0, 1, @ptrCast(&scissor));

                // Draw
                self.gc.vkd.cmdDrawIndexed(
                    cmd,
                    pcmd.ElemCount,
                    1,
                    pcmd.IdxOffset + idx_offset,
                    @as(i32, @intCast(pcmd.VtxOffset + vtx_offset)),
                    0,
                );
            }

            vtx_offset += @intCast(cmd_list.*.VtxBuffer.Size);
            idx_offset += @intCast(cmd_list.*.IdxBuffer.Size);
        }
    }
};
