const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("../core/graphics_context.zig").GraphicsContext;
const UnifiedPipelineSystem = @import("../rendering/unified_pipeline_system.zig").UnifiedPipelineSystem;
const PipelineConfig = @import("../rendering/unified_pipeline_system.zig").PipelineConfig;
const PipelineId = @import("../rendering/unified_pipeline_system.zig").PipelineId;
const Resource = @import("../rendering/unified_pipeline_system.zig").Resource;
const FrameInfo = @import("../rendering/frameinfo.zig").FrameInfo;
const Swapchain = @import("../core/swapchain.zig").Swapchain;
const Texture = @import("../core/texture.zig").Texture;
const RaytracingSystem = @import("../systems/raytracing_system.zig").RaytracingSystem;
const ThreadPool = @import("../threading/thread_pool.zig").ThreadPool;
const MAX_FRAMES_IN_FLIGHT = @import("../core/swapchain.zig").MAX_FRAMES_IN_FLIGHT;
const Mesh = @import("../rendering/mesh.zig").Mesh;
const SceneBridge = @import("../rendering/scene_bridge.zig").SceneBridge;
const GlobalUboSet = @import("../rendering/ubo_set.zig").GlobalUboSet;
const log = @import("../utils/log.zig").log;

fn alignForward(val: usize, alignment: usize) usize {
    return ((val + alignment - 1) / alignment) * alignment;
}

const PerFrameDescriptorData = struct {
    vertex_infos: std.ArrayList(vk.DescriptorBufferInfo),
    index_infos: std.ArrayList(vk.DescriptorBufferInfo),

    fn init() PerFrameDescriptorData {
        return .{
            .vertex_infos = std.ArrayList(vk.DescriptorBufferInfo){},
            .index_infos = std.ArrayList(vk.DescriptorBufferInfo){},
        };
    }

    fn deinit(self: *PerFrameDescriptorData, allocator: std.mem.Allocator) void {
        self.vertex_infos.deinit(allocator);
        self.index_infos.deinit(allocator);
    }

    fn updateFromGeometries(self: *PerFrameDescriptorData, allocator: std.mem.Allocator, rt_data: anytype) !void {
        self.vertex_infos.clearRetainingCapacity();
        self.index_infos.clearRetainingCapacity();

        try self.vertex_infos.ensureTotalCapacity(allocator, rt_data.geometries.len);
        try self.index_infos.ensureTotalCapacity(allocator, rt_data.geometries.len);

        for (rt_data.geometries) |geometry| {
            const mesh: *Mesh = geometry.mesh_ptr;

            const vertex_info = if (mesh.vertex_buffer) |vertex_buf|
                vk.DescriptorBufferInfo{
                    .buffer = vertex_buf.buffer,
                    .offset = 0,
                    .range = vertex_buf.instance_size * vertex_buf.instance_count,
                }
            else
                vk.DescriptorBufferInfo{ .buffer = vk.Buffer.null_handle, .offset = 0, .range = 0 };

            const index_info = if (mesh.index_buffer) |index_buf|
                vk.DescriptorBufferInfo{
                    .buffer = index_buf.buffer,
                    .offset = 0,
                    .range = index_buf.instance_size * index_buf.instance_count,
                }
            else
                vk.DescriptorBufferInfo{ .buffer = vk.Buffer.null_handle, .offset = 0, .range = 0 };

            self.vertex_infos.appendAssumeCapacity(vertex_info);
            self.index_infos.appendAssumeCapacity(index_info);
        }
    }
};

/// Raytracing renderer built on the unified pipeline system.
pub const RaytracingRenderer = struct {
    allocator: std.mem.Allocator,
    graphics_context: *GraphicsContext,
    pipeline_system: *UnifiedPipelineSystem,
    swapchain: *Swapchain,

    rt_system: *RaytracingSystem,
    global_ubo_set: *GlobalUboSet,

    raytracing_pipeline: PipelineId,
    pipeline_handle: vk.Pipeline,

    output_texture: Texture,
    width: u32,
    height: u32,

    descriptor_dirty_flags: [MAX_FRAMES_IN_FLIGHT]bool = [_]bool{true} ** MAX_FRAMES_IN_FLIGHT,
    per_frame: [MAX_FRAMES_IN_FLIGHT]PerFrameDescriptorData,

    tlas: vk.AccelerationStructureKHR = vk.AccelerationStructureKHR.null_handle,
    tlas_valid: bool = false,


    pub fn init(
        allocator: std.mem.Allocator,
        graphics_context: *GraphicsContext,
        pipeline_system: *UnifiedPipelineSystem,
        swapchain: *Swapchain,
        thread_pool: *ThreadPool,
        global_ubo_set: *GlobalUboSet,
    ) !RaytracingRenderer {
        log(.INFO, "unified_raytracing_renderer", "Initializing unified raytracing renderer", .{});

        const pipeline_config = PipelineConfig{
            .name = "unified_raytracing_renderer",
            .raygen_shader = "shaders/RayTracingTriangle.rgen.hlsl",
            .miss_shader = "shaders/RayTracingTriangle.rmiss.hlsl",
            .closest_hit_shader = "shaders/RayTracingTriangle.rchit.hlsl",
            .render_pass = vk.RenderPass.null_handle,
        };

        const pipeline_id = try pipeline_system.createPipeline(pipeline_config);
        const pipeline_entry = pipeline_system.pipelines.get(pipeline_id) orelse return error.PipelineNotFound;

        var output_format = swapchain.surface_format.format;
        if (output_format == vk.Format.a2r10g10b10_unorm_pack32) {
            output_format = vk.Format.a2b10g10r10_unorm_pack32;
        }

        const output_texture = try Texture.init(
            graphics_context,
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

        const rt_system = try allocator.create(RaytracingSystem);
        rt_system.* = try RaytracingSystem.init(graphics_context, allocator, swapchain.extent.width, swapchain.extent.height, thread_pool);
        try rt_system.updateShaderBindingTable(pipeline_entry.vulkan_pipeline);

        var per_frame: [MAX_FRAMES_IN_FLIGHT]PerFrameDescriptorData = undefined;
        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            per_frame[i] = PerFrameDescriptorData.init();
        }

        log(.INFO, "unified_raytracing_renderer", "✅ Unified raytracing renderer initialized", .{});

        return RaytracingRenderer{
            .allocator = allocator,
            .graphics_context = graphics_context,
            .pipeline_system = pipeline_system,
            .swapchain = swapchain,
            .rt_system = rt_system,
            .global_ubo_set = global_ubo_set,
            .raytracing_pipeline = pipeline_id,
            .pipeline_handle = pipeline_entry.vulkan_pipeline,
            .output_texture = output_texture,
            .width = swapchain.extent.width,
            .height = swapchain.extent.height,
            .per_frame = per_frame,
        };
    }

    pub fn deinit(self: *RaytracingRenderer) void {
        log(.INFO, "unified_raytracing_renderer", "Cleaning up unified raytracing renderer", .{});

        self.graphics_context.vkd.deviceWaitIdle(self.graphics_context.dev) catch |err| {
            log(.WARN, "unified_raytracing_renderer", "Failed to wait for device idle during deinit: {}", .{err});
        };

        self.output_texture.deinit();

        for (&self.per_frame) |*frame| {
            frame.deinit(self.allocator);
        }

        self.rt_system.deinit();
        self.allocator.destroy(self.rt_system);
    }

    fn markAllFramesDirty(self: *RaytracingRenderer) void {
        for (&self.descriptor_dirty_flags) |*flag| {
            flag.* = true;
        }
    }

    pub fn updateTLAS(self: *RaytracingRenderer, tlas: vk.AccelerationStructureKHR) void {
        self.tlas = tlas;
        self.tlas_valid = (tlas != vk.AccelerationStructureKHR.null_handle);
        self.markAllFramesDirty();
    }

    pub fn update(self: *RaytracingRenderer, frame_info: *const FrameInfo, scene_bridge: *SceneBridge) !bool {
        const frame_index = frame_info.current_frame;
        if (frame_index >= MAX_FRAMES_IN_FLIGHT) return error.InvalidFrameIndex;

        _ = try self.rt_system.update(scene_bridge, frame_info);

        if (self.rt_system.tlas != vk.AccelerationStructureKHR.null_handle and
            (!self.tlas_valid or self.rt_system.tlas_dirty))
        {
            self.updateTLAS(self.rt_system.tlas);
            self.rt_system.tlas_dirty = false;
        }

        const raytracing_dirty = scene_bridge.raytracingUpdated(frame_index);
        const materials_dirty = scene_bridge.materialsUpdated(frame_index);
        const textures_dirty = scene_bridge.texturesUpdated(frame_index);

        const rt_geometries = scene_bridge.getRaytracingGeometries();
        const per_frame = &self.per_frame[frame_index];
        const geometry_count = rt_geometries.len;

        const needs_update = raytracing_dirty or
            materials_dirty or
            textures_dirty or
            self.descriptor_dirty_flags[frame_index] or
            self.rt_system.descriptors_need_update or
            per_frame.vertex_infos.items.len != geometry_count or
            per_frame.index_infos.items.len != geometry_count;

        if (!needs_update) {
            return false;
        }

        const material_info = scene_bridge.getMaterialBufferInfo() orelse {
            return false;
        };

        const texture_image_infos = scene_bridge.getTextures();
        const textures_ready = blk: {
            if (texture_image_infos.len == 0) break :blk false;
            for (texture_image_infos) |info| {
                if (info.sampler == vk.Sampler.null_handle or info.image_view == vk.ImageView.null_handle) {
                    break :blk false;
                }
            }
            break :blk true;
        };
        const material_resource = Resource{
            .buffer = .{
                .buffer = material_info.buffer,
                .offset = material_info.offset,
                .range = material_info.range,
            },
        };

        const textures_resource = if (textures_ready)
            Resource{ .image_array = texture_image_infos }
        else
            null;
        for (0..MAX_FRAMES_IN_FLIGHT) |frame_idx| {
            const target_frame: u32 = @intCast(frame_idx);
            const frame_data = &self.per_frame[frame_idx];
            try frame_data.updateFromGeometries(self.allocator, .{ .geometries = rt_geometries });

            if (frame_data.vertex_infos.items.len > 0) {
                const vertices_resource = Resource{ .buffer_array = frame_data.vertex_infos.items };
                try self.pipeline_system.bindResource(self.raytracing_pipeline, 0, 3, vertices_resource, target_frame);
            }
            if (frame_data.index_infos.items.len > 0) {
                const indices_resource = Resource{ .buffer_array = frame_data.index_infos.items };
                try self.pipeline_system.bindResource(self.raytracing_pipeline, 0, 4, indices_resource, target_frame);
            }

            try self.pipeline_system.bindResource(self.raytracing_pipeline, 0, 5, material_resource, target_frame);

            if (textures_resource) |res| {
                try self.pipeline_system.bindResource(self.raytracing_pipeline, 0, 6, res, target_frame);
            }
        }

        if (!self.tlas_valid) {
            return false;
        }

        const accel_resource = Resource{ .acceleration_structure = self.tlas };
        const output_descriptor = self.output_texture.getDescriptorInfo();
        const output_resource = Resource{
            .image = .{
                .image_view = output_descriptor.image_view,
                .sampler = output_descriptor.sampler,
                .layout = output_descriptor.image_layout,
            },
        };

        for (0..MAX_FRAMES_IN_FLIGHT) |frame_idx| {
            const target_frame: u32 = @intCast(frame_idx);
            const global_ubo_buffer_info = self.global_ubo_set.buffers[frame_idx].descriptor_info;
            const global_resource = Resource{
                .buffer = .{
                    .buffer = global_ubo_buffer_info.buffer,
                    .offset = global_ubo_buffer_info.offset,
                    .range = global_ubo_buffer_info.range,
                },
            };

            try self.pipeline_system.bindResource(self.raytracing_pipeline, 0, 0, accel_resource, target_frame);
            try self.pipeline_system.bindResource(self.raytracing_pipeline, 0, 1, output_resource, target_frame);
            try self.pipeline_system.bindResource(self.raytracing_pipeline, 0, 2, global_resource, target_frame);

            self.descriptor_dirty_flags[frame_idx] = false;
        }

        self.rt_system.descriptors_need_update = false;

        if (raytracing_dirty) {
            scene_bridge.markRaytracingSynced(frame_index);
        }

        return true;
    }

    pub fn render(self: *RaytracingRenderer, frame_info: FrameInfo, scene_bridge: *SceneBridge) !void {
        _ = scene_bridge;

        if (self.rt_system.tlas != vk.AccelerationStructureKHR.null_handle and
            (!self.tlas_valid or self.rt_system.tlas_dirty))
        {
            self.updateTLAS(self.rt_system.tlas);
            self.rt_system.tlas_dirty = false;
        }

        if (!self.tlas_valid) {
            return;
        }

        if (self.descriptor_dirty_flags[frame_info.current_frame]) {
            return;
        }

        const gc = self.graphics_context;

        try self.resizeOutput(self.swapchain);

        const pipeline_entry = self.pipeline_system.pipelines.get(self.raytracing_pipeline) orelse return error.PipelineNotFound;
        if (pipeline_entry.vulkan_pipeline != self.pipeline_handle) {
            try self.rt_system.updateShaderBindingTable(pipeline_entry.vulkan_pipeline);
            self.pipeline_handle = pipeline_entry.vulkan_pipeline;
            self.pipeline_system.markPipelineResourcesDirty(self.raytracing_pipeline);
            self.markAllFramesDirty();
        }

        try self.pipeline_system.updateDescriptorSetsForPipeline(self.raytracing_pipeline, frame_info.current_frame);

        gc.vkd.cmdBindPipeline(frame_info.command_buffer, vk.PipelineBindPoint.ray_tracing_khr, pipeline_entry.vulkan_pipeline);

        if (pipeline_entry.descriptor_sets.items.len == 0) {
            log(.WARN, "unified_raytracing_renderer", "No descriptor sets available for raytracing pipeline", .{});
            return;
        }

        const frame_sets = pipeline_entry.descriptor_sets.items[0];
        const descriptor_set = frame_sets[frame_info.current_frame];
        const descriptor_sets = [_]vk.DescriptorSet{descriptor_set};
        const descriptor_sets_slice = descriptor_sets[0..];
        const descriptor_count: u32 = @intCast(descriptor_sets.len);

        gc.vkd.cmdBindDescriptorSets(
            frame_info.command_buffer,
            vk.PipelineBindPoint.ray_tracing_khr,
            pipeline_entry.pipeline_layout,
            0,
            descriptor_count,
            descriptor_sets_slice.ptr,
            0,
            null,
        );

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

        try self.copyOutputToSwapchain(frame_info.command_buffer, self.swapchain);
    }

    fn resizeOutput(self: *RaytracingRenderer, swapchain: *Swapchain) !void {
        if (swapchain.extent.width == self.width and swapchain.extent.height == self.height) {
            return;
        }

        try self.graphics_context.vkd.deviceWaitIdle(self.graphics_context.dev);

        self.output_texture.deinit();

        var output_format = swapchain.surface_format.format;
        if (output_format == vk.Format.a2r10g10b10_unorm_pack32) {
            output_format = vk.Format.a2b10g10r10_unorm_pack32;
        }

        self.output_texture = try Texture.init(
            self.graphics_context,
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

        self.markAllFramesDirty();
    }

    fn copyOutputToSwapchain(self: *RaytracingRenderer, command_buffer: vk.CommandBuffer, swapchain: *Swapchain) !void {
        const gc = self.graphics_context;

        try self.output_texture.transitionImageLayout(
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
        );

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

        try self.output_texture.transitionImageLayout(
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
        );

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
