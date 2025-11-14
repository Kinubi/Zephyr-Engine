const std = @import("std");
const vk = @import("vulkan");
const zephyr = @import("zephyr");
const log = zephyr.log;

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

    // Font texture using engine's Texture class (heap-allocated for consistency)
    font_texture: ?*Texture = null,
    font_texture_id: c.ImTextureID = 0,

    // Dynamic vertex and index buffers using engine's Buffer class (per-frame for triple buffering)
    vertex_buffers: [MAX_FRAMES_IN_FLIGHT]?Buffer = [_]?Buffer{null} ** MAX_FRAMES_IN_FLIGHT,
    index_buffers: [MAX_FRAMES_IN_FLIGHT]?Buffer = [_]?Buffer{null} ** MAX_FRAMES_IN_FLIGHT,

    // Current buffer sizes (per-frame)
    vertex_buffer_sizes: [MAX_FRAMES_IN_FLIGHT]usize = [_]usize{0} ** MAX_FRAMES_IN_FLIGHT,
    index_buffer_sizes: [MAX_FRAMES_IN_FLIGHT]usize = [_]usize{0} ** MAX_FRAMES_IN_FLIGHT,

    // Track if resources need setup
    resources_need_setup: bool = true,

    // Descriptor pool for per-texture descriptor sets
    descriptor_pool: vk.DescriptorPool = .null_handle,
    descriptor_set_layout: vk.DescriptorSetLayout = .null_handle,

    // Map of texture ID to pre-allocated descriptor sets (one per frame in flight)
    texture_descriptor_sets: std.AutoHashMap(c.ImTextureID, [MAX_FRAMES_IN_FLIGHT]vk.DescriptorSet) = undefined,

    // Map of texture ID to texture objects
    texture_map: std.AutoHashMap(c.ImTextureID, *Texture) = undefined,
    pub fn init(allocator: std.mem.Allocator, gc: *GraphicsContext, swapchain: *Swapchain, pipeline_system: *UnifiedPipelineSystem) !ImGuiVulkanBackend {
        var self = ImGuiVulkanBackend{
            .allocator = allocator,
            .gc = gc,
            .swapchain_format = swapchain.surface_format.format,
            .pipeline_system = pipeline_system,
            .resource_binder = ResourceBinder.init(allocator, pipeline_system),
            .texture_map = std.AutoHashMap(c.ImTextureID, *Texture).init(allocator),
            .texture_descriptor_sets = std.AutoHashMap(c.ImTextureID, [MAX_FRAMES_IN_FLIGHT]vk.DescriptorSet).init(allocator),
        };

        // Create descriptor pool and layout for our own descriptor sets
        try self.createDescriptorResources();

        // Try to create pipeline - may fail if shaders aren't compiled yet
        self.createPipeline() catch {};

        // Upload fonts to GPU
        try self.uploadFonts();

        return self;
    }

    pub fn deinit(self: *ImGuiVulkanBackend) void {
        self.gc.vkd.deviceWaitIdle(self.gc.dev) catch {};

        // Clean up all per-frame vertex buffers
        for (&self.vertex_buffers) |*vb| {
            if (vb.*) |*buffer| {
                buffer.deinit();
            }
        }

        // Clean up all per-frame index buffers
        for (&self.index_buffers) |*ib| {
            if (ib.*) |*buffer| {
                buffer.deinit();
            }
        }

        if (self.font_texture) |ft| {
            ft.deinit();
            self.allocator.destroy(ft);
        }

        // Clean up descriptor resources
        if (self.descriptor_pool != .null_handle) {
            self.gc.vkd.destroyDescriptorPool(self.gc.dev, self.descriptor_pool, null);
        }
        if (self.descriptor_set_layout != .null_handle) {
            self.gc.vkd.destroyDescriptorSetLayout(self.gc.dev, self.descriptor_set_layout, null);
        }

        // Clean up maps
        self.texture_descriptor_sets.deinit();
        self.texture_map.deinit();

        self.resource_binder.deinit();
    }

    /// Generic texture upload function that works for fonts, icons, etc.
    /// Uses synchronous single-time commands to ensure immediate availability
    fn uploadTexture(self: *ImGuiVulkanBackend, pixel_data: []const u8, width: u32, height: u32) !Texture {
        return Texture.loadFromMemorySingle(
            self.gc,
            pixel_data,
            width,
            height,
            .r8g8b8a8_unorm, // Use unorm for UI textures (not srgb)
        );
    }

    fn uploadFonts(self: *ImGuiVulkanBackend) !void {
        const io = c.ImGui_GetIO();

        var pixels: [*c]u8 = undefined;
        var width: c_int = 0;
        var height: c_int = 0;
        c.ImFontAtlas_GetTexDataAsRGBA32(io.*.Fonts, &pixels, &width, &height, null);

        const pixel_count = @as(usize, @intCast(width * height * 4));
        const pixel_data: []const u8 = pixels[0..pixel_count];

        // Allocate font texture on heap (like icon textures)
        const font_texture = try self.allocator.create(Texture);
        errdefer self.allocator.destroy(font_texture);

        font_texture.* = try self.uploadTexture(pixel_data, @intCast(width), @intCast(height));
        font_texture.descriptor.image_layout = .general;

        self.font_texture = font_texture;

        // Register font texture and get its ID
        self.font_texture_id = try self.addTexture(font_texture);

        // Set the font texture ID in ImGui
        const io_ptr = c.ImGui_GetIO();
        c.ImFontAtlas_SetTexID(io_ptr.*.Fonts, self.font_texture_id);
    }

    fn createDescriptorResources(self: *ImGuiVulkanBackend) !void {
        // Create descriptor pool for texture descriptor sets
        const pool_size = vk.DescriptorPoolSize{
            .type = .combined_image_sampler,
            .descriptor_count = 1000 * MAX_FRAMES_IN_FLIGHT, // 1000 textures * frames in flight
        };

        const pool_info = vk.DescriptorPoolCreateInfo{
            .flags = .{ .free_descriptor_set_bit = true },
            .max_sets = 1000 * MAX_FRAMES_IN_FLIGHT,
            .pool_size_count = 1,
            .p_pool_sizes = @ptrCast(&pool_size),
        };

        self.descriptor_pool = try self.gc.vkd.createDescriptorPool(self.gc.dev, &pool_info, null);

        // Create descriptor set layout matching the pipeline's expected layout
        const binding = vk.DescriptorSetLayoutBinding{
            .binding = 0,
            .descriptor_type = .combined_image_sampler,
            .descriptor_count = 1,
            .stage_flags = .{ .fragment_bit = true },
            .p_immutable_samplers = null,
        };

        const layout_info = vk.DescriptorSetLayoutCreateInfo{
            .binding_count = 1,
            .p_bindings = @ptrCast(&binding),
        };

        self.descriptor_set_layout = try self.gc.vkd.createDescriptorSetLayout(self.gc.dev, &layout_info, null);
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
            log(.WARN, "imgui", "ImGui pipeline creation failed. ImGui rendering will be disabled.", .{});
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

    /// Setup initial resources - bind font texture for all frames
    fn setupResources(self: *ImGuiVulkanBackend) !void {
        if (self.pipeline_id == null) return;
        if (self.font_texture == null) return;

        // Bind font texture to all frames initially
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

    fn updateBuffers(self: *ImGuiVulkanBackend, draw_data: [*c]c.ImDrawData, frame_index: u32) !void {
        if (draw_data == null) return;

        const vertex_size = @as(usize, @intCast(draw_data.*.TotalVtxCount)) * @sizeOf(c.ImDrawVert);
        const index_size = @as(usize, @intCast(draw_data.*.TotalIdxCount)) * @sizeOf(c.ImDrawIdx);

        if (vertex_size == 0 or index_size == 0) return;

        // Use per-frame buffers
        const frame_idx = frame_index % MAX_FRAMES_IN_FLIGHT;

        // Create or resize vertex buffer for this frame
        if (self.vertex_buffers[frame_idx] == null or vertex_size > self.vertex_buffer_sizes[frame_idx]) {
            if (self.vertex_buffers[frame_idx]) |*vb| {
                vb.deinit();
            }

            self.vertex_buffers[frame_idx] = try Buffer.init(self.gc, @sizeOf(c.ImDrawVert), @as(u32, @intCast(draw_data.*.TotalVtxCount)), .{ .vertex_buffer_bit = true, .transfer_dst_bit = true }, .{ .host_visible_bit = true, .host_coherent_bit = true });
            self.vertex_buffer_sizes[frame_idx] = vertex_size;

            try self.vertex_buffers[frame_idx].?.map(vk.WHOLE_SIZE, 0);
        }

        // Create or resize index buffer for this frame
        if (self.index_buffers[frame_idx] == null or index_size > self.index_buffer_sizes[frame_idx]) {
            if (self.index_buffers[frame_idx]) |*ib| {
                ib.deinit();
            }

            self.index_buffers[frame_idx] = try Buffer.init(self.gc, @sizeOf(c.ImDrawIdx), @as(u32, @intCast(draw_data.*.TotalIdxCount)), .{ .index_buffer_bit = true, .transfer_dst_bit = true }, .{ .host_visible_bit = true, .host_coherent_bit = true });
            self.index_buffer_sizes[frame_idx] = index_size;

            try self.index_buffers[frame_idx].?.map(vk.WHOLE_SIZE, 0);
        }

        // Copy vertex and index data to this frame's buffers
        var vtx_dst = @as([*]c.ImDrawVert, @ptrCast(@alignCast(self.vertex_buffers[frame_idx].?.mapped.?)));
        var idx_dst = @as([*]c.ImDrawIdx, @ptrCast(@alignCast(self.index_buffers[frame_idx].?.mapped.?)));

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
            // Pipeline was rebuilt; clear cached handle and rebind resources
            self.cached_pipeline_handle = pipeline_entry.vulkan_pipeline;
            self.resource_binder.clearPipeline(self.pipeline_id.?);
            self.resources_need_setup = true;
        }

        // Setup resources if needed
        if (self.resources_need_setup) {
            try self.setupResources();
            self.resources_need_setup = false;
        }

        // Update vertex and index buffers for this frame
        try self.updateBuffers(draw_data, frame_index);

        const frame_idx = frame_index % MAX_FRAMES_IN_FLIGHT;
        if (self.vertex_buffers[frame_idx] == null or self.index_buffers[frame_idx] == null) return;

        // Setup dynamic rendering with load operation (preserve existing framebuffer)
        const rendering = DynamicRenderingHelper.init(
            swapchain.swap_images[swapchain.image_index].view,
            swapchain.swap_images[swapchain.image_index].depth_image_view,
            swapchain.extent,
            .{ 0.0, 0.0, 0.0, 1.0 },
            0.0,
        );

        // Begin rendering (also sets viewport and scissor)
        rendering.begin(self.gc, cmd);
        defer rendering.end(self.gc, cmd);

        // Bind ImGui pipeline with descriptor sets
        try self.pipeline_system.bindPipelineWithDescriptorSets(cmd, self.pipeline_id.?, frame_index);

        // Bind vertex and index buffers for this frame
        const vb_offset: vk.DeviceSize = 0;
        self.gc.vkd.cmdBindVertexBuffers(cmd, 0, 1, @ptrCast(&self.vertex_buffers[frame_idx].?.buffer), @ptrCast(&vb_offset));
        self.gc.vkd.cmdBindIndexBuffer(cmd, self.index_buffers[frame_idx].?.buffer, 0, .uint16);

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

        // Track last bound texture to avoid redundant binds
        var last_texture_id: c.ImTextureID = 0;

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

                // Bind the texture for this draw call dynamically
                var texture_id = pcmd.TexRef._TexID;
                const tex_data = pcmd.TexRef._TexData;

                // If texture_id is 0 but _TexData is set, this is the font texture!
                // ImGui uses _TexData internally for fonts, so we need to translate to our font_texture_id
                if (texture_id == 0 and tex_data != null) {
                    texture_id = self.font_texture_id;
                }

                // Only rebind if texture changed (optimization)
                if (texture_id != last_texture_id and texture_id != 0) {
                    // Get the pre-allocated descriptor sets for this texture
                    if (self.texture_descriptor_sets.get(texture_id)) |desc_sets| {
                        // Bind the descriptor set for the current frame
                        const desc_set = desc_sets[frame_index];

                        self.gc.vkd.cmdBindDescriptorSets(
                            cmd,
                            .graphics,
                            layout,
                            0, // First set
                            1, // Count
                            @ptrCast(&desc_set),
                            0,
                            null,
                        );

                        last_texture_id = texture_id;
                    } else {
                        // No descriptor sets found for this texture ID - nothing to bind
                    }
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

    /// Add a texture to ImGui for rendering
    /// Returns a texture ID (ImTextureID = ImU64) that can be used with ImGui::Image()
    /// Creates pre-allocated descriptor sets (one per frame in flight) for this texture
    /// NOTE: Texture must already be in shader_read_only_optimal layout before calling this
    pub fn addTexture(self: *ImGuiVulkanBackend, texture: *Texture) !c.ImTextureID {
        const descriptor = texture.getDescriptorInfo();

        // Use the image view handle as the texture ID
        const texture_id = @intFromEnum(descriptor.image_view);

        // Allocate descriptor sets for all frames in flight
        var desc_sets: [MAX_FRAMES_IN_FLIGHT]vk.DescriptorSet = undefined;

        const layouts = [_]vk.DescriptorSetLayout{self.descriptor_set_layout} ** MAX_FRAMES_IN_FLIGHT;
        const alloc_info = vk.DescriptorSetAllocateInfo{
            .descriptor_pool = self.descriptor_pool,
            .descriptor_set_count = MAX_FRAMES_IN_FLIGHT,
            .p_set_layouts = &layouts,
        };

        try self.gc.vkd.allocateDescriptorSets(self.gc.dev, &alloc_info, &desc_sets);

        // Update all descriptor sets with the texture info
        var writes: [MAX_FRAMES_IN_FLIGHT]vk.WriteDescriptorSet = undefined;
        var image_infos: [MAX_FRAMES_IN_FLIGHT]vk.DescriptorImageInfo = undefined;

        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            image_infos[i] = vk.DescriptorImageInfo{
                .sampler = descriptor.sampler,
                .image_view = descriptor.image_view,
                .image_layout = descriptor.image_layout,
            };

            writes[i] = vk.WriteDescriptorSet{
                .dst_set = desc_sets[i],
                .dst_binding = 0,
                .dst_array_element = 0,
                .descriptor_count = 1,
                .descriptor_type = .combined_image_sampler,
                .p_image_info = @ptrCast(&image_infos[i]),
                .p_buffer_info = undefined,
                .p_texel_buffer_view = undefined,
            };
        }

        self.gc.vkd.updateDescriptorSets(self.gc.dev, MAX_FRAMES_IN_FLIGHT, &writes, 0, null);

        // Store the descriptor sets and texture
        try self.texture_descriptor_sets.put(texture_id, desc_sets);
        try self.texture_map.put(texture_id, texture);

        return texture_id;
    }

    /// Preferred API: add per-frame textures (uses each Texture's own sampler and layout)
    pub fn addPerFrameTextures(
        self: *ImGuiVulkanBackend,
        textures: [MAX_FRAMES_IN_FLIGHT]*Texture,
    ) !c.ImTextureID {
        // Use the first texture's image view as the stable texture ID
        const first_desc = textures[0].getDescriptorInfo();
        const texture_id: c.ImTextureID = @intFromEnum(first_desc.image_view);

        // Allocate descriptor sets for each frame-in-flight
        var desc_sets: [MAX_FRAMES_IN_FLIGHT]vk.DescriptorSet = undefined;
        const layouts = [_]vk.DescriptorSetLayout{self.descriptor_set_layout} ** MAX_FRAMES_IN_FLIGHT;
        const alloc_info = vk.DescriptorSetAllocateInfo{
            .descriptor_pool = self.descriptor_pool,
            .descriptor_set_count = MAX_FRAMES_IN_FLIGHT,
            .p_set_layouts = &layouts,
        };
        try self.gc.vkd.allocateDescriptorSets(self.gc.dev, &alloc_info, &desc_sets);

        // Write each descriptor set with its corresponding per-frame texture info
        var writes: [MAX_FRAMES_IN_FLIGHT]vk.WriteDescriptorSet = undefined;
        var image_infos: [MAX_FRAMES_IN_FLIGHT]vk.DescriptorImageInfo = undefined;
        inline for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            const di = textures[i].getDescriptorInfo();
            image_infos[i] = vk.DescriptorImageInfo{
                .sampler = di.sampler,
                .image_view = di.image_view,
                // Combined image samplers must use a read-only or general layout in descriptors
                .image_layout = vk.ImageLayout.general,
            };
            writes[i] = vk.WriteDescriptorSet{
                .dst_set = desc_sets[i],
                .dst_binding = 0,
                .dst_array_element = 0,
                .descriptor_count = 1,
                .descriptor_type = .combined_image_sampler,
                .p_image_info = @ptrCast(&image_infos[i]),
                .p_buffer_info = undefined,
                .p_texel_buffer_view = undefined,
            };
        }
        self.gc.vkd.updateDescriptorSets(self.gc.dev, MAX_FRAMES_IN_FLIGHT, &writes, 0, null);

        try self.texture_descriptor_sets.put(texture_id, desc_sets);
        // Optionally track the first texture pointer under the ID for lookup consistency
        try self.texture_map.put(texture_id, textures[0]);
        return texture_id;
    }

    /// Update existing per-frame texture descriptors after a texture resize
    /// This updates the descriptor sets in place without allocating new ones
    pub fn updatePerFrameTextureDescriptors(
        self: *ImGuiVulkanBackend,
        texture_id: c.ImTextureID,
        textures: [MAX_FRAMES_IN_FLIGHT]*Texture,
    ) !void {
        // Get the existing descriptor sets
        const desc_sets = self.texture_descriptor_sets.get(texture_id) orelse return error.TextureNotFound;

        // Update each descriptor set with the new texture info
        var writes: [MAX_FRAMES_IN_FLIGHT]vk.WriteDescriptorSet = undefined;
        var image_infos: [MAX_FRAMES_IN_FLIGHT]vk.DescriptorImageInfo = undefined;
        inline for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            const di = textures[i].getDescriptorInfo();
            image_infos[i] = vk.DescriptorImageInfo{
                .sampler = di.sampler,
                .image_view = di.image_view,
                .image_layout = vk.ImageLayout.general,
            };
            writes[i] = vk.WriteDescriptorSet{
                .dst_set = desc_sets[i],
                .dst_binding = 0,
                .dst_array_element = 0,
                .descriptor_count = 1,
                .descriptor_type = .combined_image_sampler,
                .p_image_info = @ptrCast(&image_infos[i]),
                .p_buffer_info = undefined,
                .p_texel_buffer_view = undefined,
            };
        }
        self.gc.vkd.updateDescriptorSets(self.gc.dev, MAX_FRAMES_IN_FLIGHT, &writes, 0, null);

        // Update the texture map with the new first texture pointer
        try self.texture_map.put(texture_id, textures[0]);
    }

    /// Create a texture from raw RGBA8 pixel data
    /// Uses synchronous command execution to ensure texture is ready immediately
    /// This is the public API for loading textures (icons, images, etc.)
    pub fn createTextureFromPixels(self: *ImGuiVulkanBackend, pixels: []const u8, width: u32, height: u32) !*Texture {
        const texture = try self.allocator.create(Texture);
        errdefer self.allocator.destroy(texture);

        texture.* = try self.uploadTexture(pixels, width, height);
        return texture;
    }

    /// Remove a texture created by createTexture
    pub fn removeTexture(self: *ImGuiVulkanBackend, texture: *Texture) void {
        texture.deinit();
        self.allocator.destroy(texture);
    }

    /// Get the font texture ID for ImGui
    pub fn getFontTextureID(self: *ImGuiVulkanBackend) ?c.ImTextureID {
        if (self.font_texture) |font| {
            const descriptor = font.getDescriptorInfo();
            // Use the image view handle (converted to integer) as ImGui texture ID
            return @intFromEnum(descriptor.image_view);
        }
        return null;
    }
};
