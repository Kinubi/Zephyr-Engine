const std = @import("std");
const vk = @import("vulkan");
const log = @import("../../utils/log.zig").log;

const RenderGraph = @import("../render_graph.zig").RenderGraph;
const RenderPass = @import("../render_graph.zig").RenderPass;
const RenderPassVTable = @import("../render_graph.zig").RenderPassVTable;
const FrameInfo = @import("../frameinfo.zig").FrameInfo;
const GlobalUbo = @import("../frameinfo.zig").GlobalUbo;
const GraphicsContext = @import("../../core/graphics_context.zig").GraphicsContext;
const UnifiedPipelineSystem = @import("../unified_pipeline_system.zig").UnifiedPipelineSystem;
const PipelineConfig = @import("../unified_pipeline_system.zig").PipelineConfig;
const PipelineId = @import("../unified_pipeline_system.zig").PipelineId;
const Resource = @import("../unified_pipeline_system.zig").Resource;
const ResourceBinder = @import("../resource_binder.zig").ResourceBinder;
const Texture = @import("../../core/texture.zig").Texture;
const RaytracingSystem = @import("../../systems/raytracing_system.zig").RaytracingSystem;
const ThreadPool = @import("../../threading/thread_pool.zig").ThreadPool;
const GlobalUboSet = @import("../ubo_set.zig").GlobalUboSet;
const MAX_FRAMES_IN_FLIGHT = @import("../../core/swapchain.zig").MAX_FRAMES_IN_FLIGHT;
const AssetManager = @import("../../assets/asset_manager.zig").AssetManager;
const Mesh = @import("../mesh.zig").Mesh;

// ECS imports
const ecs = @import("../../ecs.zig");
const World = ecs.World;
const RenderSystem = ecs.RenderSystem;

/// Per-frame descriptor data for vertex/index buffers
const PerFrameDescriptorData = struct {
    vertex_infos: std.ArrayList(vk.DescriptorBufferInfo),
    index_infos: std.ArrayList(vk.DescriptorBufferInfo),
    allocator: std.mem.Allocator,
    fn init(allocator: std.mem.Allocator) PerFrameDescriptorData {
        return .{
            .vertex_infos = std.ArrayList(vk.DescriptorBufferInfo){},
            .index_infos = std.ArrayList(vk.DescriptorBufferInfo){},
            .allocator = allocator,
        };
    }

    fn deinit(self: *PerFrameDescriptorData) void {
        self.vertex_infos.deinit(self.allocator);
        self.index_infos.deinit(self.allocator);
    }

    fn updateFromGeometries(self: *PerFrameDescriptorData, rt_data: anytype) !void {
        self.vertex_infos.clearRetainingCapacity();
        self.index_infos.clearRetainingCapacity();

        try self.vertex_infos.ensureTotalCapacity(self.allocator, rt_data.geometries.len);
        try self.index_infos.ensureTotalCapacity(self.allocator, rt_data.geometries.len);

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

            try self.vertex_infos.append(self.allocator, vertex_info);
            try self.index_infos.append(self.allocator, index_info);
        }
    }
};

/// Path tracing pass - renders the scene using ray tracing for realistic global illumination
pub const PathTracingPass = struct {
    base: RenderPass,
    allocator: std.mem.Allocator,

    // Core rendering infrastructure
    graphics_context: *GraphicsContext,
    pipeline_system: *UnifiedPipelineSystem,
    resource_binder: ResourceBinder,
    thread_pool: *ThreadPool,
    global_ubo_set: *GlobalUboSet,
    ecs_world: *World,
    asset_manager: *AssetManager,
    render_system: *RenderSystem,

    // Path tracing pipeline
    path_tracing_pipeline: PipelineId = undefined,
    cached_pipeline_handle: vk.Pipeline = .null_handle,

    // Ray tracing system (manages BVH/acceleration structures)
    rt_system: *RaytracingSystem,

    // Output texture for path-traced results
    output_texture: Texture,
    width: u32,
    height: u32,

    // Swapchain format for output texture
    swapchain_format: vk.Format,

    // Acceleration structure tracking
    tlas: vk.AccelerationStructureKHR = vk.AccelerationStructureKHR.null_handle,
    tlas_valid: bool = false,

    // Per-frame descriptor tracking
    descriptor_dirty_flags: [MAX_FRAMES_IN_FLIGHT]bool = [_]bool{true} ** MAX_FRAMES_IN_FLIGHT,
    per_frame: [MAX_FRAMES_IN_FLIGHT]PerFrameDescriptorData = undefined,

    // Toggle between raster and path tracing
    enable_path_tracing: bool = false,

    pub fn create(
        allocator: std.mem.Allocator,
        graphics_context: *GraphicsContext,
        pipeline_system: *UnifiedPipelineSystem,
        thread_pool: *ThreadPool,
        global_ubo_set: *GlobalUboSet,
        ecs_world: *World,
        asset_manager: *AssetManager,
        render_system: *RenderSystem,
        swapchain_format: vk.Format,
        width: u32,
        height: u32,
    ) !*PathTracingPass {
        const pass = try allocator.create(PathTracingPass);

        // Create raytracing system for BVH management
        const rt_system = try allocator.create(RaytracingSystem);
        rt_system.* = try RaytracingSystem.init(graphics_context, allocator, thread_pool);

        // Use swapchain format for output texture (with special case for packed formats)
        var output_format = swapchain_format;
        if (output_format == vk.Format.a2r10g10b10_unorm_pack32) {
            output_format = vk.Format.a2b10g10r10_unorm_pack32;
        }

        // Create output texture for path-traced results
        const output_texture = try Texture.init(
            graphics_context,
            output_format,
            .{ .width = width, .height = height, .depth = 1 },
            vk.ImageUsageFlags{
                .storage_bit = true,
                .transfer_src_bit = true,
                .transfer_dst_bit = true,
                .sampled_bit = true,
            },
            vk.SampleCountFlags{ .@"1_bit" = true },
        );

        // Initialize per-frame descriptor data
        var per_frame: [MAX_FRAMES_IN_FLIGHT]PerFrameDescriptorData = undefined;
        for (&per_frame) |*frame_data| {
            frame_data.* = PerFrameDescriptorData.init(allocator);
        }

        pass.* = PathTracingPass{
            .base = RenderPass{
                .name = "path_tracing_pass",
                .enabled = true,
                .vtable = &vtable,
                .dependencies = std.ArrayList([]const u8){},
            },
            .allocator = allocator,
            .graphics_context = graphics_context,
            .pipeline_system = pipeline_system,
            .resource_binder = ResourceBinder.init(allocator, pipeline_system),
            .thread_pool = thread_pool,
            .global_ubo_set = global_ubo_set,
            .ecs_world = ecs_world,
            .asset_manager = asset_manager,
            .render_system = render_system,
            .rt_system = rt_system,
            .output_texture = output_texture,
            .width = width,
            .height = height,
            .swapchain_format = swapchain_format,
            .per_frame = per_frame,
        };

        return pass;
    }

    const vtable = RenderPassVTable{
        .setup = setupImpl,
        .update = updateImpl,
        .execute = executeImpl,
        .teardown = teardownImpl,
        .checkValidity = checkValidityImpl,
    };

    fn checkValidityImpl(base: *RenderPass) bool {
        const self: *PathTracingPass = @fieldParentPtr("base", base);

        // Check if pipeline now exists (hot-reload succeeded)
        if (!self.pipeline_system.pipelines.contains(self.path_tracing_pipeline)) {
            return false;
        }

        // Pipeline exists! Complete the setup that was skipped during initial failure
        const entry = self.pipeline_system.pipelines.get(self.path_tracing_pipeline) orelse return false;
        self.cached_pipeline_handle = entry.vulkan_pipeline;

        // Update shader binding table
        self.rt_system.updateShaderBindingTable(entry.vulkan_pipeline) catch |err| {
            log(.WARN, "path_tracing_pass", "Failed to update SBT during recovery: {}", .{err});
            return false;
        };

        self.updateDescriptors() catch |err| {
            log(.WARN, "path_tracing_pass", "Failed to update descriptors during recovery: {}", .{err});
            return false;
        };

        log(.INFO, "path_tracing_pass", "Recovery setup complete", .{});
        return true;
    }

    fn setupImpl(base: *RenderPass, graph: *RenderGraph) !void {
        const self: *PathTracingPass = @fieldParentPtr("base", base);
        _ = graph;

        // Create path tracing pipeline
        const pipeline_config = PipelineConfig{
            .name = "path_tracing",
            .raygen_shader = "assets/shaders/RayTracingTriangle.rgen.hlsl",
            .miss_shader = "assets/shaders/RayTracingTriangle.rmiss.hlsl",
            .closest_hit_shader = "assets/shaders/RayTracingTriangle.rchit.hlsl",
            .render_pass = vk.RenderPass.null_handle,
        };

        const result = try self.pipeline_system.createPipeline(pipeline_config);
        self.path_tracing_pipeline = result.id;

        if (!result.success) {
            log(.WARN, "path_tracing_pass", "Pipeline creation failed. Pass will be disabled.", .{});
            return error.PipelineCreationFailed;
        }

        const entry = self.pipeline_system.pipelines.get(self.path_tracing_pipeline) orelse return error.PipelineNotFound;
        self.cached_pipeline_handle = entry.vulkan_pipeline;

        // Update shader binding table
        try self.rt_system.updateShaderBindingTable(entry.vulkan_pipeline);
        try self.updateDescriptors();
    }

    /// Update descriptors for all frames (exactly like rt_renderer.update does)
    fn updateDescriptors(self: *PathTracingPass) !void {
        if (!self.tlas_valid) {
            // TLAS not ready yet - this is normal during async BVH building
            return;
        }

        // Get raytracing data from render system (already cached)
        const rt_data = try self.render_system.getRaytracingData();
        defer {
            self.allocator.free(rt_data.geometries);
            self.allocator.free(rt_data.instances);
            self.allocator.free(rt_data.materials);
        }

        // Get material buffer info from asset manager
        const material_info = if (self.asset_manager.material_buffer) |buffer|
            buffer.descriptor_info
        else
            vk.DescriptorBufferInfo{
                .buffer = vk.Buffer.null_handle,
                .offset = 0,
                .range = 0,
            };

        // Get texture array from asset manager
        const texture_image_infos = self.asset_manager.getTextureDescriptorArray();
        const textures_ready = blk: {
            if (texture_image_infos.len == 0) break :blk false;
            for (texture_image_infos) |info| {
                if (info.sampler == vk.Sampler.null_handle or info.image_view == vk.ImageView.null_handle) {
                    break :blk false;
                }
            }
            break :blk true;
        };

        // Prepare material resource
        const material_resource = Resource{
            .buffer = .{
                .buffer = material_info.buffer,
                .offset = material_info.offset,
                .range = material_info.range,
            },
        };

        // Prepare textures resource
        const textures_resource = if (textures_ready)
            Resource{ .image_array = texture_image_infos }
        else
            null;

        // Update vertex/index buffers and bind them for ALL frames (like rt_renderer does)
        for (0..MAX_FRAMES_IN_FLIGHT) |frame_idx| {
            const target_frame: u32 = @intCast(frame_idx);
            const frame_data = &self.per_frame[frame_idx];

            // Update vertex/index buffer info from geometries
            try frame_data.updateFromGeometries(.{ .geometries = rt_data.geometries });

            // Binding 3: Vertex buffers
            if (frame_data.vertex_infos.items.len > 0) {
                const vertices_resource = Resource{ .buffer_array = frame_data.vertex_infos.items };
                try self.pipeline_system.bindResource(self.path_tracing_pipeline, 0, 3, vertices_resource, target_frame);
            }

            // Binding 4: Index buffers
            if (frame_data.index_infos.items.len > 0) {
                const indices_resource = Resource{ .buffer_array = frame_data.index_infos.items };
                try self.pipeline_system.bindResource(self.path_tracing_pipeline, 0, 4, indices_resource, target_frame);
            }

            // Binding 5: Material buffer
            try self.pipeline_system.bindResource(self.path_tracing_pipeline, 0, 5, material_resource, target_frame);

            // Binding 6: Texture samplers
            if (textures_resource) |res| {
                try self.pipeline_system.bindResource(self.path_tracing_pipeline, 0, 6, res, target_frame);
            }
        }

        // Now bind TLAS, output image, and camera UBO for all frames
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

            // Get global UBO buffer for this frame
            const global_ubo_buffer_info = self.global_ubo_set.buffers[frame_idx].descriptor_info;
            const global_resource = Resource{
                .buffer = .{
                    .buffer = global_ubo_buffer_info.buffer,
                    .offset = global_ubo_buffer_info.offset,
                    .range = global_ubo_buffer_info.range,
                },
            };

            // Binding 0: Acceleration Structure (TLAS)
            try self.pipeline_system.bindResource(self.path_tracing_pipeline, 0, 0, accel_resource, target_frame);
            // Binding 1: Output Image (storage image)
            try self.pipeline_system.bindResource(self.path_tracing_pipeline, 0, 1, output_resource, target_frame);
            // Binding 2: Camera UBO (global uniform buffer)
            try self.pipeline_system.bindResource(self.path_tracing_pipeline, 0, 2, global_resource, target_frame);
            self.descriptor_dirty_flags[frame_idx] = false;
        }

        for (0..MAX_FRAMES_IN_FLIGHT) |frame_idx| {
            try self.resource_binder.updateFrame(self.path_tracing_pipeline, @as(u32, @intCast(frame_idx)));
        }

        // Don't flush here - resources may still be in use by descriptors/command buffers
        // They'll be flushed during deinit when GPU is idle
    }

    fn executeImpl(base: *RenderPass, frame_info: FrameInfo) !void {
        const self: *PathTracingPass = @fieldParentPtr("base", base);
        const frame_index = frame_info.current_frame;

        // Skip if TLAS is not valid (like rt_renderer.render does)
        if (!self.tlas_valid) {
            return;
        }

        // Skip if descriptors are dirty (like rt_renderer.render does)
        if (self.descriptor_dirty_flags[frame_index]) {
            return;
        }

        const pipeline_entry = self.pipeline_system.pipelines.get(self.path_tracing_pipeline) orelse return error.PipelineNotFound;
        if (pipeline_entry.vulkan_pipeline != self.cached_pipeline_handle) {
            log(.INFO, "path_tracing_pass", "Pipeline hot-reloaded, rebinding all descriptors", .{});
            try self.rt_system.updateShaderBindingTable(pipeline_entry.vulkan_pipeline);
            self.cached_pipeline_handle = pipeline_entry.vulkan_pipeline;
            self.pipeline_system.markPipelineResourcesDirty(self.path_tracing_pipeline);

            // Rebind resources after hot reload
            try self.updateDescriptors();
        }

        const cmd = frame_info.command_buffer;

        try self.pipeline_system.bindPipelineWithDescriptorSets(cmd, self.path_tracing_pipeline, frame_index);
        // Dispatch rays
        try self.dispatchRays(cmd, self.rt_system.shader_binding_table);

        // Copy output to swapchain image
        try self.copyOutputToSwapchain(cmd, frame_info.color_image);
    }
    fn teardownImpl(base: *RenderPass) void {
        const self: *PathTracingPass = @fieldParentPtr("base", base);

        // Clean up per-frame descriptor data
        for (&self.per_frame) |*frame_data| {
            frame_data.deinit();
        }

        self.output_texture.deinit();
        self.rt_system.deinit();
        self.allocator.destroy(self.rt_system);

        log(.INFO, "path_tracing_pass", "Cleaned up PathTracingPass", .{});
        self.allocator.destroy(self);
    }

    fn updateTLAS(self: *PathTracingPass, new_tlas: vk.AccelerationStructureKHR) void {
        self.tlas = new_tlas;
        self.tlas_valid = true;

        // Mark all descriptors as dirty since TLAS changed
        for (&self.descriptor_dirty_flags) |*dirty| {
            dirty.* = true;
        }
    }

    fn dispatchRays(
        self: *PathTracingPass,
        command_buffer: vk.CommandBuffer,
        sbt_buffer: vk.Buffer,
    ) !void {
        // Get ray tracing pipeline properties
        const pdev = self.graphics_context.pdev;
        var rt_props = vk.PhysicalDeviceRayTracingPipelinePropertiesKHR{
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
            .properties = undefined,
            .p_next = &rt_props,
        };

        self.graphics_context.vki.getPhysicalDeviceProperties2(pdev, &props2);

        const handle_size_aligned = alignForward(
            rt_props.shader_group_handle_size,
            rt_props.shader_group_handle_alignment,
        );

        // Get base address and align regions to shader_group_base_alignment
        const base_address = self.graphics_context.vkd.getBufferDeviceAddress(
            self.graphics_context.dev,
            &vk.BufferDeviceAddressInfo{
                .buffer = sbt_buffer,
            },
        );

        // Define shader binding table regions with proper alignment
        const raygen_region = vk.StridedDeviceAddressRegionKHR{
            .device_address = base_address,
            .stride = handle_size_aligned,
            .size = handle_size_aligned,
        };

        // Align miss region to base_alignment
        const miss_offset = alignForward(handle_size_aligned, rt_props.shader_group_base_alignment);
        const miss_region = vk.StridedDeviceAddressRegionKHR{
            .device_address = base_address + miss_offset,
            .stride = handle_size_aligned,
            .size = handle_size_aligned,
        };

        // Align hit region to base_alignment
        const hit_offset = alignForward(miss_offset + handle_size_aligned, rt_props.shader_group_base_alignment);
        const hit_region = vk.StridedDeviceAddressRegionKHR{
            .device_address = base_address + hit_offset,
            .stride = handle_size_aligned,
            .size = handle_size_aligned,
        };

        const callable_region = vk.StridedDeviceAddressRegionKHR{
            .device_address = 0,
            .stride = 0,
            .size = 0,
        };

        // Dispatch rays
        self.graphics_context.vkd.cmdTraceRaysKHR(
            command_buffer,
            &raygen_region,
            &miss_region,
            &hit_region,
            &callable_region,
            self.width,
            self.height,
            1, // depth
        );
    }

    fn copyOutputToSwapchain(self: *PathTracingPass, command_buffer: vk.CommandBuffer, swapchain_image: vk.Image) !void {
        const gc = self.graphics_context;

        // OPTIMIZATION: Keep output texture in GENERAL layout (supports all operations including transfer)
        // This eliminates 2 image transitions per frame (GENERAL→TRANSFER_SRC→GENERAL)
        // Only transition the swapchain image (required for presentation)

        // Transition swapchain image from PRESENT_SRC to TRANSFER_DST_OPTIMAL
        gc.transitionImageLayout(
            command_buffer,
            swapchain_image,
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

        // Copy from output texture to swapchain
        // Output texture stays in GENERAL layout (valid for both storage writes and transfer src)
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
                .width = self.width,
                .height = self.height,
                .depth = 1,
            },
            .dst_offset = vk.Offset3D{ .x = 0, .y = 0, .z = 0 },
        };

        gc.vkd.cmdCopyImage(
            command_buffer,
            self.output_texture.image,
            vk.ImageLayout.general, // Source stays in GENERAL
            swapchain_image,
            vk.ImageLayout.transfer_dst_optimal,
            1,
            @ptrCast(&copy_info),
        );

        // Transition swapchain image back to PRESENT_SRC
        gc.transitionImageLayout(
            command_buffer,
            swapchain_image,
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

    /// Resize the output texture when swapchain is recreated
    pub fn resize(self: *PathTracingPass, new_width: u32, new_height: u32) !void {
        if (self.width == new_width and self.height == new_height) {
            return; // No change needed
        }

        log(.INFO, "path_tracing_pass", "Resizing output texture: {}x{} -> {}x{}", .{ self.width, self.height, new_width, new_height });

        // Destroy old texture
        self.output_texture.deinit();

        // Use swapchain format for output texture (with special case for packed formats)
        var output_format = self.swapchain_format;
        if (output_format == vk.Format.a2r10g10b10_unorm_pack32) {
            output_format = vk.Format.a2b10g10r10_unorm_pack32;
        }

        // Create new output texture with new dimensions
        self.output_texture = try Texture.init(
            self.graphics_context,
            output_format,
            .{ .width = new_width, .height = new_height, .depth = 1 },
            vk.ImageUsageFlags{
                .storage_bit = true,
                .transfer_src_bit = true,
                .transfer_dst_bit = true,
                .sampled_bit = true,
            },
            vk.SampleCountFlags{ .@"1_bit" = true },
        );

        // Update dimensions
        self.width = new_width;
        self.height = new_height;

        // Mark all descriptors as dirty so they get updated with new image
        for (&self.descriptor_dirty_flags) |*flag| {
            flag.* = true;
        }

        log(.INFO, "path_tracing_pass", "Output texture resized successfully", .{});
    }

    fn updateImpl(base: *RenderPass, frame_info: *const FrameInfo) !void {
        const self: *PathTracingPass = @fieldParentPtr("base", base);
        const frame_index = frame_info.current_frame;

        // Check if window was resized and recreate output texture if needed
        if (self.width != frame_info.extent.width or self.height != frame_info.extent.height) {
            try self.resize(frame_info.extent.width, frame_info.extent.height);
        }

        // Flush deferred resources from MAX_FRAMES_IN_FLIGHT ago
        // At this point, the fence has been waited on (in swapchain.beginFrame),
        // so resources queued during that frame are safe to destroy
        self.rt_system.flushDeferredFrame(frame_index);

        // // Check various dirty flags BEFORE updating (like rt_renderer.update does)
        // _ = self.render_system.checkBvhRebuildNeeded();
        const materials_dirty = self.asset_manager.materials_updated;
        const textures_dirty = self.asset_manager.texture_descriptors_updated;

        // Check if render system detected geometry changes
        const geometry_changed = self.render_system.raytracing_descriptors_dirty;

        // Update BVH using rt_system (handles BLAS/TLAS building)
        const bvh_rebuilt = try self.rt_system.update(self.render_system, frame_info, geometry_changed);

        // Check if TLAS changed (handle changed OR dirty flag set)
        const tlas_changed = self.rt_system.tlas != vk.AccelerationStructureKHR.null_handle and
            (!self.tlas_valid or self.rt_system.tlas_dirty or self.tlas != self.rt_system.tlas);

        if (tlas_changed) {
            self.updateTLAS(self.rt_system.tlas);
            self.rt_system.tlas_dirty = false;

            // Clear renderables dirty flag now that TLAS is built and ready
            self.render_system.renderables_dirty = false;
        }

        const needs_update = bvh_rebuilt or
            materials_dirty or
            textures_dirty or
            geometry_changed or
            self.descriptor_dirty_flags[frame_index] or tlas_changed;

        // Only update descriptors if TLAS is valid
        if (needs_update and self.tlas_valid) {
            try self.updateDescriptors();

            // Clear the raytracing flag after updating descriptors
            self.render_system.raytracing_descriptors_dirty = false;
        }
    }

    /// Toggle path tracing on/off (allows switching to raster)
    pub fn setEnabled(self: *PathTracingPass, enabled: bool) void {
        self.enable_path_tracing = enabled;
    }

    /// Get the path-traced output texture
    pub fn getOutputTexture(self: *PathTracingPass) *Texture {
        return &self.output_texture;
    }
};

fn alignForward(val: usize, alignment: usize) usize {
    return ((val + alignment - 1) / alignment) * alignment;
}
