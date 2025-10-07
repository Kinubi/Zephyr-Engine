const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("../core/graphics_context.zig").GraphicsContext;
const Pipeline = @import("../core/pipeline.zig").Pipeline;
const ShaderLibrary = @import("../core/shader.zig").ShaderLibrary;
const FrameInfo = @import("../rendering/frameinfo.zig").FrameInfo;
const GlobalUbo = @import("../rendering/frameinfo.zig").GlobalUbo;
const Swapchain = @import("../core/swapchain.zig").Swapchain;
const Buffer = @import("../core/buffer.zig").Buffer;
const Texture = @import("../core/texture.zig").Texture;
const RayTracingRenderPassDescriptors = @import("../rendering/render_pass_descriptors.zig").RayTracingRenderPassDescriptors;
const RaytracingSystem = @import("../systems/raytracing_system.zig").RaytracingSystem;
const ThreadPool = @import("../threading/thread_pool.zig").ThreadPool;
const MAX_FRAMES_IN_FLIGHT = @import("../core/swapchain.zig").MAX_FRAMES_IN_FLIGHT;
const log = @import("../utils/log.zig").log;
const DescriptorSetConfig = @import("../rendering/render_pass_descriptors.zig").DescriptorSetConfig;

fn alignForward(val: usize, alignment: usize) usize {
    return ((val + alignment - 1) / alignment) * alignment;
}

/// Raytracing renderer that follows the render pass pattern
pub const RaytracingRenderer = struct {
    gc: *GraphicsContext,
    allocator: std.mem.Allocator,

    // Pipeline and layout
    pipeline: Pipeline = undefined,
    pipeline_layout: vk.PipelineLayout = vk.PipelineLayout.null_handle,

    // Pipeline recreation dependencies
    render_pass: vk.RenderPass = undefined,
    shader_library: ShaderLibrary = undefined,

    // Output texture
    output_texture: Texture = undefined,
    width: u32 = 1280,
    height: u32 = 720,

    // Descriptor management
    descriptors: *RayTracingRenderPassDescriptors = undefined,

    // Raytracing system instance
    rt_system: *RaytracingSystem = undefined,

    // Swapchain reference for copying output
    swapchain: *Swapchain = undefined,

    // Raytracing state
    tlas: vk.AccelerationStructureKHR = undefined,
    tlas_valid: bool = false,
    descriptors_initialized: bool = false,
    descriptor_dirty_flags: [MAX_FRAMES_IN_FLIGHT]bool = [_]bool{false} ** MAX_FRAMES_IN_FLIGHT,

    pub fn init(
        gc: *GraphicsContext,
        allocator: std.mem.Allocator,
        render_pass: vk.RenderPass,
        shader_library: ShaderLibrary,
        swapchain: *Swapchain,
        thread_pool: *ThreadPool,
    ) !RaytracingRenderer {
        // Initialize descriptor manager with minimal counts (will resize dynamically)
        const initial_vertex_buffer_count: u32 = 1;
        const initial_index_buffer_count: u32 = 1;
        var descriptors = try allocator.create(RayTracingRenderPassDescriptors);
        descriptors.* = try RayTracingRenderPassDescriptors.init(
            gc,
            allocator,
            initial_vertex_buffer_count,
            initial_index_buffer_count,
        );

        // Create pipeline layout using the descriptor set layout
        const rt_layout = descriptors.getDescSetLayout() orelse return error.FailedToGetDescriptorSetLayout;
        const dsl = [_]vk.DescriptorSetLayout{rt_layout};
        const pipeline_layout = try gc.vkd.createPipelineLayout(
            gc.dev,
            &vk.PipelineLayoutCreateInfo{
                .flags = .{},
                .set_layout_count = dsl.len,
                .p_set_layouts = &dsl,
                .push_constant_range_count = 0,
                .p_push_constant_ranges = null,
            },
            null,
        );

        // Create raytracing pipeline
        const pipeline = try Pipeline.initRaytracing(
            gc.*,
            render_pass,
            shader_library,
            pipeline_layout,
            Pipeline.defaultRaytracingLayout(pipeline_layout),
            allocator,
        );

        // Create output texture
        var output_format = swapchain.surface_format.format;
        if (output_format == vk.Format.a2r10g10b10_unorm_pack32) {
            output_format = vk.Format.a2b10g10r10_unorm_pack32;
        }
        const output_texture = try Texture.init(
            gc,
            output_format,
            .{ .width = swapchain.extent.width, .height = swapchain.extent.height, .depth = 1 },
            vk.ImageUsageFlags{
                .storage_bit = true,
                .transfer_src_bit = true,
                .transfer_dst_bit = true,
                .sampled_bit = true,
            },
            vk.SampleCountFlags{ .@"1_bit" = true },
        );

        // Initialize raytracing system (heap allocated for proper lifetime management)
        const rt_system = try allocator.create(RaytracingSystem);
        rt_system.* = try RaytracingSystem.init(
            gc,
            allocator,
            swapchain.extent.width,
            swapchain.extent.height,
            thread_pool,
        );

        // Initialize shader binding table after pipeline creation
        try rt_system.updateShaderBindingTable(pipeline.pipeline);

        return RaytracingRenderer{
            .gc = gc,
            .allocator = allocator,
            .pipeline = pipeline,
            .pipeline_layout = pipeline_layout,
            .render_pass = render_pass,
            .shader_library = shader_library,
            .rt_system = rt_system,
            .swapchain = swapchain,
            .output_texture = output_texture,
            .width = swapchain.extent.width,
            .height = swapchain.extent.height,
            .descriptors = descriptors,
            .tlas = vk.AccelerationStructureKHR.null_handle,
            .tlas_valid = false,
        };
    }

    pub fn deinit(self: *RaytracingRenderer) void {
        // Wait for device idle
        self.gc.vkd.deviceWaitIdle(self.gc.dev) catch |err| {
            log(.WARN, "raytracing_renderer", "Failed to wait for device idle during deinit: {}", .{err});
        };

        // Clean up output texture
        self.output_texture.deinit();

        // Clean up descriptors
        self.descriptors.deinit();

        // Clean up raytracing system (heap allocated)
        self.rt_system.deinit();
        self.allocator.destroy(self.rt_system);

        // Clean up pipeline
        self.pipeline.deinit();

        // Clean up pipeline layout (check if valid first)
        if (self.pipeline_layout != vk.PipelineLayout.null_handle) {
            self.gc.vkd.destroyPipelineLayout(self.gc.dev, self.pipeline_layout, null);
            self.pipeline_layout = vk.PipelineLayout.null_handle;
        }
    }

    /// Update TLAS reference for raytracing
    pub fn updateTLAS(self: *RaytracingRenderer, tlas: vk.AccelerationStructureKHR) void {
        self.tlas = tlas;
        self.tlas_valid = (tlas != vk.AccelerationStructureKHR.null_handle);
        // Reset descriptor initialization flag since TLAS changed
        self.descriptors_initialized = false;
        // Mark all frames as needing descriptor updates
        self.markAllFramesDirty();
    }

    /// Mark all frames in flight as needing descriptor updates
    pub fn markAllFramesDirty(self: *RaytracingRenderer) void {
        for (&self.descriptor_dirty_flags) |*flag| {
            flag.* = true;
        }
    }

    /// Mark descriptors as needing updates due to material changes
    pub fn markMaterialsDirty(self: *RaytracingRenderer) void {
        self.markAllFramesDirty();
    }

    /// Update descriptors with current frame data
    pub fn updateDescriptors(
        self: *RaytracingRenderer,
        frame_index: u32,
        global_ubo_buffer_info: vk.DescriptorBufferInfo,
        vertex_buffer_infos: []const vk.DescriptorBufferInfo,
        index_buffer_infos: []const vk.DescriptorBufferInfo,
        material_buffer_info: vk.DescriptorBufferInfo,
        texture_image_infos: []const vk.DescriptorImageInfo,
    ) !void {
        if (!self.tlas_valid) {
            log(.WARN, "raytracing_renderer", "Cannot update descriptors: TLAS not valid", .{});
            return;
        }

        // Get acceleration structure descriptor info
        const as_info = vk.WriteDescriptorSetAccelerationStructureKHR{
            .s_type = vk.StructureType.write_descriptor_set_acceleration_structure_khr,
            .p_next = null,
            .acceleration_structure_count = 1,
            .p_acceleration_structures = @ptrCast(&self.tlas),
        };

        // Get output image info
        const output_image_info = self.output_texture.getDescriptorInfo();

        // Update all raytracing descriptors
        try self.descriptors.updateRaytracingData(
            frame_index,
            @constCast(&as_info),
            output_image_info,
            global_ubo_buffer_info,
            vertex_buffer_infos,
            index_buffer_infos,
            material_buffer_info,
            texture_image_infos,
        );
    }

    /// Update material data only
    pub fn updateMaterialData(
        self: *RaytracingRenderer,
        frame_index: u32,
        material_buffer_info: vk.DescriptorBufferInfo,
        texture_image_infos: []const vk.DescriptorImageInfo,
    ) !void {
        try self.descriptors.updateMatData(frame_index, material_buffer_info, texture_image_infos);
    }

    /// Update acceleration structure data only
    pub fn updateASData(
        self: *RaytracingRenderer,
        frame_index: u32,
        vertex_buffer_infos: []const vk.DescriptorBufferInfo,
        index_buffer_infos: []const vk.DescriptorBufferInfo,
    ) !void {
        if (!self.tlas_valid) return;

        const as_info = vk.WriteDescriptorSetAccelerationStructureKHR{
            .s_type = vk.StructureType.write_descriptor_set_acceleration_structure_khr,
            .p_next = null,
            .acceleration_structure_count = 1,
            .p_acceleration_structures = @ptrCast(&self.tlas),
        };

        try self.descriptors.updateASData(frame_index, @constCast(&as_info), vertex_buffer_infos, index_buffer_infos);
    }

    /// Update from scene view raytracing data (handles dynamic buffer counts)
    pub fn updateFromSceneView(
        self: *RaytracingRenderer,
        frame_index: u32,
        global_ubo_buffer_info: vk.DescriptorBufferInfo,
        material_buffer_info: vk.DescriptorBufferInfo,
        texture_image_infos: []const vk.DescriptorImageInfo,
        rt_data: anytype, // SceneView.RaytracingData
        rt_system: *RaytracingSystem, // Reference to reset descriptor update flag
    ) !void {
        if (!self.tlas_valid) {
            log(.WARN, "raytracing_renderer", "Cannot update from scene view: TLAS not valid", .{});
            return;
        }

        // Check if we need to resize descriptors based on new buffer counts
        const new_vertex_count = @as(u32, @intCast(rt_data.geometries.len));
        const new_index_count = @as(u32, @intCast(rt_data.geometries.len));
        const new_texture_count = @as(u32, @intCast(texture_image_infos.len));

        // Check if we need to resize descriptors based on new buffer counts
        const needs_resize = self.descriptors.needsResize(new_vertex_count, new_index_count, new_texture_count);

        // Update descriptors if: 1) Never initialized, 2) Per-frame dirty flag set, 3) Resize needed
        const frame_needs_update = self.descriptor_dirty_flags[frame_index];
        const needs_update = !self.descriptors_initialized or frame_needs_update or needs_resize;

        if (needs_update) {
            if (needs_resize) {
                try self.resizeDescriptors(new_vertex_count, new_index_count, new_texture_count);
            }

            // Update all descriptors
            const as_info = vk.WriteDescriptorSetAccelerationStructureKHR{
                .s_type = vk.StructureType.write_descriptor_set_acceleration_structure_khr,
                .p_next = null,
                .acceleration_structure_count = 1,
                .p_acceleration_structures = @ptrCast(&self.tlas),
            };

            const output_image_info = self.output_texture.getDescriptorInfo();

            try self.descriptors.updateFromSceneViewData(
                frame_index,
                @constCast(&as_info),
                output_image_info,
                global_ubo_buffer_info,
                material_buffer_info,
                texture_image_infos,
                rt_data,
            );

            // Mark descriptors as initialized
            self.descriptors_initialized = true;

            // Clear the per-frame dirty flag
            self.descriptor_dirty_flags[frame_index] = false;

            // Reset the descriptor update flag in the raytracing system
            rt_system.descriptors_need_update = false;
        }
    }

    /// Resize descriptor sets when buffer counts change
    fn resizeDescriptors(
        self: *RaytracingRenderer,
        new_vertex_buffer_count: u32,
        new_index_buffer_count: u32,
        new_texture_count: u32,
    ) !void {
        // Create new bindings array on heap (updated counts)
        const new_bindings = try self.allocator.dupe(DescriptorSetConfig.BindingConfig, &[_]DescriptorSetConfig.BindingConfig{
            // Binding 0: Top-level acceleration structure
            .{
                .binding = 0,
                .descriptor_type = .acceleration_structure_khr,
                .stage_flags = .{ .raygen_bit_khr = true },
                .descriptor_count = 1,
            },
            // Binding 1: Storage image (output)
            .{
                .binding = 1,
                .descriptor_type = .storage_image,
                .stage_flags = .{ .raygen_bit_khr = true },
                .descriptor_count = 1,
            },
            // Binding 2: Uniform buffer (camera data)
            .{
                .binding = 2,
                .descriptor_type = .uniform_buffer,
                .stage_flags = .{ .raygen_bit_khr = true },
                .descriptor_count = 1,
            },
            // Binding 3: Vertex buffers array (updated count)
            .{
                .binding = 3,
                .descriptor_type = .storage_buffer,
                .stage_flags = .{ .raygen_bit_khr = true, .closest_hit_bit_khr = true },
                .descriptor_count = @max(new_vertex_buffer_count, 1),
            },
            // Binding 4: Index buffers array (updated count)
            .{
                .binding = 4,
                .descriptor_type = .storage_buffer,
                .stage_flags = .{ .raygen_bit_khr = true, .closest_hit_bit_khr = true },
                .descriptor_count = @max(new_index_buffer_count, 1),
            },
            // Binding 5: Material buffer
            .{
                .binding = 5,
                .descriptor_type = .storage_buffer,
                .stage_flags = .{ .closest_hit_bit_khr = true },
                .descriptor_count = 1,
            },
            // Binding 6: Texture array (dynamically sized)
            .{
                .binding = 6,
                .descriptor_type = .combined_image_sampler,
                .stage_flags = .{ .closest_hit_bit_khr = true },
                .descriptor_count = @max(new_texture_count, 1),
            },
        });

        // Create new configuration with updated buffer counts
        const new_set_config = DescriptorSetConfig{
            .set_index = 0,
            .bindings = new_bindings,
        };

        // Recreate the descriptor set with new configuration
        try self.descriptors.manager.recreateDescriptorSet(0, new_set_config);

        // CRITICAL: Update stored config in self.descriptors.configs to prevent infinite loop
        self.descriptors.configs[0] = new_set_config;

        // CRITICAL: When descriptor set layout changes, we must recreate pipeline layout and pipeline
        try self.recreatePipelineLayoutAndPipeline();

        // Reset descriptor initialization flag since we've recreated them
        self.descriptors_initialized = false;
    }

    /// Recreate pipeline layout and pipeline after descriptor layout changes
    fn recreatePipelineLayoutAndPipeline(self: *RaytracingRenderer) !void {
        // Wait for device idle before destroying pipeline resources
        try self.gc.vkd.deviceWaitIdle(self.gc.dev);

        // Destroy old pipeline and layout (check if valid first)
        self.pipeline.deinit();

        // Get updated descriptor set layout
        const rt_layout = self.descriptors.manager.getDescriptorSetLayout(0) orelse return error.FailedToGetDescriptorSetLayout;
        const dsl = [_]vk.DescriptorSetLayout{rt_layout};

        // Recreate pipeline layout with new descriptor set layout
        self.pipeline_layout = try self.gc.vkd.createPipelineLayout(
            self.gc.dev,
            &vk.PipelineLayoutCreateInfo{
                .flags = .{},
                .set_layout_count = dsl.len,
                .p_set_layouts = &dsl,
                .push_constant_range_count = 0,
                .p_push_constant_ranges = null,
            },
            null,
        );

        // Validate shader library state before using it
        if (self.shader_library.shaders.items.len == 0) {
            log(.ERROR, "raytracing_renderer", "Shader library has no shaders loaded", .{});
            return error.EmptyShaderLibrary;
        }

        // Add safety check for shader library validity
        if (self.shader_library.shaders.items.len == 0) {
            log(.ERROR, "raytracing_renderer", "Shader library corrupted: len={}", .{self.shader_library.shaders.items.len});
            return error.ShaderLibraryCorrupted;
        }

        // Recreate pipeline with new layout
        self.pipeline = try Pipeline.initRaytracing(
            self.gc.*,
            self.render_pass,
            self.shader_library,
            self.pipeline_layout,
            Pipeline.defaultRaytracingLayout(self.pipeline_layout),
            self.allocator,
        );

        // Update SBT after pipeline recreation with error handling
        self.rt_system.updateShaderBindingTable(self.pipeline.pipeline) catch |err| {
            log(.ERROR, "raytracing_renderer", "Failed to update SBT after pipeline recreation: {}", .{err});
            return err;
        };
    }

    /// Resize output texture for new swapchain dimensions
    pub fn resizeOutput(self: *RaytracingRenderer, swapchain: *Swapchain) !void {
        if (swapchain.extent.width == self.width and swapchain.extent.height == self.height) {
            return; // No resize needed
        }

        // Wait for device idle before destroying texture
        try self.gc.vkd.deviceWaitIdle(self.gc.dev);

        // Destroy old texture
        self.output_texture.deinit();

        // Create new texture with new dimensions
        var output_format = swapchain.surface_format.format;
        if (output_format == vk.Format.a2r10g10b10_unorm_pack32) {
            output_format = vk.Format.a2b10g10r10_unorm_pack32;
        }

        self.output_texture = try Texture.init(
            self.gc,
            output_format,
            .{ .width = swapchain.extent.width, .height = swapchain.extent.height, .depth = 1 },
            vk.ImageUsageFlags{
                .storage_bit = true,
                .transfer_src_bit = true,
                .transfer_dst_bit = true,
                .sampled_bit = true,
            },
            vk.SampleCountFlags{ .@"1_bit" = true },
        );

        self.width = swapchain.extent.width;
        self.height = swapchain.extent.height;
    }

    /// Record raytracing commands for a frame
    pub fn render(
        self: *RaytracingRenderer,
        frame_info: FrameInfo,
    ) !void {
        if (!self.tlas_valid) {
            log(.WARN, "raytracing_renderer", "Cannot render: TLAS not valid", .{});
            return;
        }

        const gc = self.gc;

        // Check if we need to resize
        try self.resizeOutput(self.swapchain);

        // Bind pipeline
        gc.vkd.cmdBindPipeline(frame_info.command_buffer, vk.PipelineBindPoint.ray_tracing_khr, self.pipeline.pipeline);

        // Bind descriptor set
        if (self.descriptors.getDescSet(frame_info.current_frame)) |descriptor_set| {
            gc.vkd.cmdBindDescriptorSets(
                frame_info.command_buffer,
                vk.PipelineBindPoint.ray_tracing_khr,
                self.pipeline_layout,
                0,
                1,
                @ptrCast(&descriptor_set),
                0,
                null,
            );
        } else {
            log(.WARN, "raytracing_renderer", "No descriptor set available for frame {}", .{frame_info.current_frame});
            return;
        }

        // Setup SBT regions
        var rt_props = vk.PhysicalDeviceRayTracingPipelinePropertiesKHR{
            .s_type = vk.StructureType.physical_device_ray_tracing_pipeline_properties_khr,
            .p_next = null,
            .shader_group_handle_size = 0,
            .max_ray_recursion_depth = 0,
            .max_shader_group_stride = 0,
            .shader_group_base_alignment = 0,
            .shader_group_handle_capture_replay_size = 0,
            .max_ray_dispatch_invocation_count = 0,
            .shader_group_handle_alignment = 0,
            .max_ray_hit_attribute_size = 0,
        };
        var props2 = vk.PhysicalDeviceProperties2{
            .s_type = vk.StructureType.physical_device_properties_2,
            .p_next = &rt_props,
            .properties = gc.props,
        };
        gc.vki.getPhysicalDeviceProperties2(gc.pdev, &props2);

        const handle_size = rt_props.shader_group_handle_size;
        const base_alignment = rt_props.shader_group_base_alignment;
        const sbt_stride = alignForward(handle_size, base_alignment);

        const sbt_addr_info = vk.BufferDeviceAddressInfo{
            .s_type = vk.StructureType.buffer_device_address_info,
            .buffer = self.rt_system.shader_binding_table,
        };
        const sbt_addr = gc.vkd.getBufferDeviceAddress(gc.dev, &sbt_addr_info);

        var raygen_region = vk.StridedDeviceAddressRegionKHR{
            .device_address = sbt_addr,
            .stride = sbt_stride,
            .size = sbt_stride,
        };
        var miss_region = vk.StridedDeviceAddressRegionKHR{
            .device_address = sbt_addr + sbt_stride,
            .stride = sbt_stride,
            .size = sbt_stride,
        };
        var hit_region = vk.StridedDeviceAddressRegionKHR{
            .device_address = sbt_addr + sbt_stride * 2,
            .stride = sbt_stride,
            .size = sbt_stride,
        };
        var callable_region = vk.StridedDeviceAddressRegionKHR{
            .device_address = 0,
            .stride = 0,
            .size = 0,
        };

        // Dispatch rays
        gc.vkd.cmdTraceRaysKHR(
            frame_info.command_buffer,
            &raygen_region,
            &miss_region,
            &hit_region,
            &callable_region,
            self.width,
            self.height,
            1,
        );

        // Image layout transitions and copy to swapchain
        try self.copyOutputToSwapchain(frame_info.command_buffer, self.swapchain);
    }

    /// Copy raytracing output to swapchain image
    fn copyOutputToSwapchain(self: *RaytracingRenderer, command_buffer: vk.CommandBuffer, swapchain: *Swapchain) !void {
        const gc = self.gc;

        // Transition output image to TRANSFER_SRC
        self.output_texture.transitionImageLayout(
            command_buffer,
            vk.ImageLayout.general,
            vk.ImageLayout.transfer_src_optimal,
            .{
                .aspect_mask = vk.ImageAspectFlags{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        ) catch |err| return err;

        // Transition swapchain image to TRANSFER_DST
        gc.transitionImageLayout(
            command_buffer,
            swapchain.swap_images[swapchain.image_index].image,
            vk.ImageLayout.present_src_khr,
            vk.ImageLayout.transfer_dst_optimal,
            .{
                .aspect_mask = vk.ImageAspectFlags{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        );

        // Copy image
        const copy_info = vk.ImageCopy{
            .src_subresource = .{
                .aspect_mask = vk.ImageAspectFlags{ .color_bit = true },
                .mip_level = 0,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .src_offset = vk.Offset3D{ .x = 0, .y = 0, .z = 0 },
            .dst_subresource = .{
                .aspect_mask = vk.ImageAspectFlags{ .color_bit = true },
                .mip_level = 0,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .extent = vk.Extent3D{
                .width = swapchain.extent.width,
                .height = swapchain.extent.height,
                .depth = 1,
            },
            .dst_offset = vk.Offset3D{ .x = 0, .y = 0, .z = 0 },
        };

        gc.vkd.cmdCopyImage(
            command_buffer,
            self.output_texture.image,
            vk.ImageLayout.transfer_src_optimal,
            swapchain.swap_images[swapchain.image_index].image,
            vk.ImageLayout.transfer_dst_optimal,
            1,
            @ptrCast(&copy_info),
        );

        // Transition output image back to GENERAL
        self.output_texture.transitionImageLayout(
            command_buffer,
            vk.ImageLayout.transfer_src_optimal,
            vk.ImageLayout.general,
            .{
                .aspect_mask = vk.ImageAspectFlags{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        ) catch |err| return err;

        // Transition swapchain image to PRESENT_SRC
        gc.transitionImageLayout(
            command_buffer,
            swapchain.swap_images[swapchain.image_index].image,
            vk.ImageLayout.transfer_dst_optimal,
            vk.ImageLayout.present_src_khr,
            .{
                .aspect_mask = vk.ImageAspectFlags{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        );
    }
};
