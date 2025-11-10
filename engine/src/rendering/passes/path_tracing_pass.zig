const std = @import("std");
const vk = @import("vulkan");
const log = @import("../../utils/log.zig").log;
const RenderGraph = @import("../render_graph.zig").RenderGraph;
const RenderPass = @import("../render_graph.zig").RenderPass;
const RenderPassVTable = @import("../render_graph.zig").RenderPassVTable;
const FrameInfo = @import("../frameinfo.zig").FrameInfo;
const GraphicsContext = @import("../../core/graphics_context.zig").GraphicsContext;
const Swapchain = @import("../../core/swapchain.zig").Swapchain;
const UnifiedPipelineSystem = @import("../unified_pipeline_system.zig").UnifiedPipelineSystem;
const PipelineConfig = @import("../unified_pipeline_system.zig").PipelineConfig;
const PipelineId = @import("../unified_pipeline_system.zig").PipelineId;
const Resource = @import("../unified_pipeline_system.zig").Resource;
const ResourceBinder = @import("../resource_binder.zig").ResourceBinder;
const Texture = @import("../../core/texture.zig").Texture;
const ManagedTexture = @import("../texture_manager.zig").ManagedTexture;
const TextureManager = @import("../texture_manager.zig").TextureManager;
const RaytracingSystem = @import("../../rendering/raytracing/raytracing_system.zig").RaytracingSystem;
const ManagedTLAS = @import("../../rendering/raytracing/raytracing_system.zig").ManagedTLAS;
const AccelerationStructureSet = @import("../../rendering/raytracing/raytracing_system.zig").AccelerationStructureSet;
const ThreadPool = @import("../../threading/thread_pool.zig").ThreadPool;
const GlobalUboSet = @import("../ubo_set.zig").GlobalUboSet;
const MaterialSystem = @import("../../ecs/systems/material_system.zig").MaterialSystem;
const MaterialBindings = @import("../../ecs/systems/material_system.zig").MaterialBindings;
const MAX_FRAMES_IN_FLIGHT = @import("../../core/swapchain.zig").MAX_FRAMES_IN_FLIGHT;
const AssetManager = @import("../../assets/asset_manager.zig").AssetManager;
const Mesh = @import("../mesh.zig").Mesh;
const ecs = @import("../../ecs.zig");

const World = ecs.World;
const RenderSystem = ecs.RenderSystem;

// TODO: SIMPLIFY RENDER PASS - Remove resource update/check logic
// TODO: Use named resource binding for clarity:
//       - bindStorageBuffer("VertexBuffers", vertex_buffer_array)
//       - bindStorageBuffer("IndexBuffers", index_buffer_array)
//       - bindAccelerationStructure("TLAS", tlas)

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
    texture_manager: *TextureManager,

    // Material bindings for path tracing (opaque handle)
    material_bindings: MaterialBindings,

    // Path tracing pipeline
    path_tracing_pipeline: PipelineId = undefined,
    cached_pipeline_handle: vk.Pipeline = .null_handle,

    // Ray tracing system (manages BVH/acceleration structures)
    rt_system: *RaytracingSystem,

    // Output texture for path-traced results (pointer to managed texture)
    output_texture: *ManagedTexture,
    width: u32,
    height: u32,

    // Swapchain format for output texture
    swapchain_format: vk.Format,

    // Acceleration structure set (contains ManagedTLAS and ManagedGeometryBuffers)
    accel_set: ?*AccelerationStructureSet = null,

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
        texture_manager: *TextureManager,
        material_bindings: MaterialBindings,
        swapchain: *const Swapchain,
        width: u32,
        height: u32,
    ) !*PathTracingPass {
        const pass = try allocator.create(PathTracingPass);

        // Create raytracing system for BVH management
        const rt_system = try allocator.create(RaytracingSystem);
        rt_system.* = try RaytracingSystem.init(graphics_context, allocator, thread_pool);

        var output_texture = try allocator.create(ManagedTexture);
        // Get any HDR texture (all frames have same format/size) for resize linking
        const hdr_texture = @constCast(swapchain).getHdrTextures()[0];

        output_texture = try texture_manager.createTexture(.{
            .name = "pt_output",
            .format = hdr_texture.format,
            .extent = .{ .width = width, .height = height, .depth = 1 },
            .usage = .{
                .storage_bit = true,
                .transfer_src_bit = true,
                .transfer_dst_bit = true,
                .sampled_bit = true,
            },
            .samples = .{ .@"1_bit" = true },
            .resize_source = hdr_texture, // Link to HDR texture for automatic resizing
        });

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
            .texture_manager = texture_manager,
            .material_bindings = material_bindings,
            .rt_system = rt_system,
            .output_texture = output_texture,
            .width = width,
            .height = height,
            .swapchain_format = swapchain.hdr_format,
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

        // Don't update descriptors during recovery either - wait for valid TLAS
        // Mark all descriptors dirty so they'll be updated on next frame
        for (&self.descriptor_dirty_flags) |*flag| {
            flag.* = true;
        }

        log(.INFO, "path_tracing_pass", "Recovery setup complete, descriptors will update on next frame", .{});
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

        // Populate ResourceBinder with shader reflection data
        if (try self.pipeline_system.getPipelineReflection(self.path_tracing_pipeline)) |reflection| {
            var mut_reflection = reflection;
            try self.resource_binder.populateFromReflection(mut_reflection);
            mut_reflection.deinit(self.allocator);
        }

        // Get ManagedTLAS from rt_system (creates "default" set if it doesn't exist)
        // Even if TLAS hasn't been built yet (generation = 0), we need to register it
        // with ResourceBinder so it can track generation changes for automatic rebinding
        self.accel_set = try self.rt_system.createSet("default");

        try self.bindResources();
    }

    /// Bind resources once during setup - ResourceBinder tracks changes automatically
    fn bindResources(self: *PathTracingPass) !void {
        // Bind output texture (generation tracked automatically)
        try self.resource_binder.bindTextureNamed(
            self.path_tracing_pipeline,
            "image", // Output texture binding name from shader
            self.output_texture,
        );

        // Bind material buffer (generation tracked automatically)
        try self.resource_binder.bindStorageBufferNamed(
            self.path_tracing_pipeline,
            "material_buffer", // The actual binding name from shader
            self.material_bindings.material_buffer,
        );

        // Bind texture array from material bindings (generation tracked automatically)
        try self.resource_binder.bindTextureArrayNamed(
            self.path_tracing_pipeline,
            "texture_buffer",
            self.material_bindings.texture_array,
        );

        // Bind global UBO for all frames (generation tracked automatically)
        try self.resource_binder.bindUniformBufferNamed(
            self.path_tracing_pipeline,
            "type.cam", // The actual binding name from shader reflection (type.cam)
            self.global_ubo_set.frame_buffers,
        );

        // Bind TLAS (generation tracked automatically)
        try self.resource_binder.bindAccelerationStructureNamed(
            self.path_tracing_pipeline,
            "rs",
            &self.accel_set.?.tlas,
        );

        // Bind vertex and index buffer arrays from managed geometry buffers
        // Always bind (even if empty) so they get tracked for generation changes
        const geometry_buffers = &self.accel_set.?.geometry_buffers;

        // Bind vertex buffers (registers for tracking even if empty)
        try self.resource_binder.bindBufferArrayNamed(
            self.path_tracing_pipeline,
            "vertex_buffer",
            geometry_buffers.vertex_infos.items,
            &geometry_buffers.vertex_infos,
            &geometry_buffers.generation,
        );

        // Bind index buffers (registers for tracking even if empty)
        try self.resource_binder.bindBufferArrayNamed(
            self.path_tracing_pipeline,
            "index_buffer",
            geometry_buffers.index_infos.items,
            &geometry_buffers.index_infos,
            &geometry_buffers.generation,
        );
    }
    fn executeImpl(base: *RenderPass, frame_info: FrameInfo) !void {
        const self: *PathTracingPass = @fieldParentPtr("base", base);
        const frame_index = frame_info.current_frame;

        const pipeline_entry = self.pipeline_system.pipelines.get(self.path_tracing_pipeline) orelse return error.PipelineNotFound;
        if (pipeline_entry.vulkan_pipeline != self.cached_pipeline_handle) {
            log(.INFO, "path_tracing_pass", "Pipeline hot-reloaded, rebinding all descriptors", .{});
            try self.rt_system.updateShaderBindingTable(pipeline_entry.vulkan_pipeline);
            self.cached_pipeline_handle = pipeline_entry.vulkan_pipeline;
            self.pipeline_system.markPipelineResourcesDirty(self.path_tracing_pipeline);

            return;
        }

        const cmd = frame_info.command_buffer;

        // Dispatch rays and render
        try self.pipeline_system.bindPipelineWithDescriptorSets(cmd, self.path_tracing_pipeline, frame_index);
        try self.dispatchRays(cmd, self.rt_system.shader_binding_table);

        // Always copy to swapchain so we present the last valid output
        try self.copyOutputToFrameImage(cmd, frame_info.hdr_texture.?.image);
    }
    fn teardownImpl(base: *RenderPass) void {
        const self: *PathTracingPass = @fieldParentPtr("base", base);
        log(.INFO, "path_tracing_pass", "Tearing down", .{});

        // Clean up per-frame descriptor data
        for (&self.per_frame) |*frame_data| {
            frame_data.deinit();
        }

        self.texture_manager.destroyTexture(self.output_texture);

        self.rt_system.deinit();

        self.allocator.destroy(self.rt_system);

        self.allocator.destroy(self);
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

        self.graphics_context.vkd.cmdTraceRaysKHR(
            command_buffer,
            &raygen_region,
            &miss_region,
            &hit_region,
            &callable_region,
            self.output_texture.extent.width,
            self.output_texture.extent.height,
            1, // depth
        );
    }

    fn copyOutputToFrameImage(self: *PathTracingPass, command_buffer: vk.CommandBuffer, frame_image: vk.Image) !void {
        const gc = self.graphics_context;

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
                .width = self.output_texture.extent.width,
                .height = self.output_texture.extent.height,
                .depth = 1,
            },
            .dst_offset = vk.Offset3D{ .x = 0, .y = 0, .z = 0 },
        };

        gc.vkd.cmdCopyImage(
            command_buffer,
            self.output_texture.texture.image,
            vk.ImageLayout.general, // Source in GENERAL
            frame_image,
            vk.ImageLayout.general, // Destination also in GENERAL - no transition needed!
            1,
            @ptrCast(&copy_info),
        );

        // No transition needed - both images stay in GENERAL!
    }

    fn updateImpl(base: *RenderPass, frame_info: *const FrameInfo) !void {
        const self: *PathTracingPass = @fieldParentPtr("base", base);
        const frame_index = frame_info.current_frame;

        const geometry_changed = self.render_system.raytracing_descriptors_dirty;

        _ = try self.rt_system.update(self.render_system, frame_info, geometry_changed);
        // CRITICAL: Also clear raytracing_descriptors_dirty if we updated for it
        // Otherwise it leaks into next frame and causes confusion
        if (geometry_changed) {
            self.render_system.raytracing_descriptors_dirty = false;
        }
        // Update resource binder - checks for generation changes and rebinds if needed
        try self.resource_binder.updateFrame(self.path_tracing_pipeline, frame_index);
    }

    /// Toggle path tracing on/off (allows switching to raster)
    pub fn setEnabled(self: *PathTracingPass, enabled: bool) void {
        const was_disabled = !self.enable_path_tracing;
        self.enable_path_tracing = enabled;

        // If we're enabling PT after it was disabled, force a BVH rebuild
        if (enabled and was_disabled) {
            self.rt_system.forceRebuild();
        }
    }

    /// Get the path-traced output texture
    pub fn getOutputTexture(self: *PathTracingPass) *Texture {
        return &self.output_texture.texture;
    }
};

fn alignForward(val: usize, alignment: usize) usize {
    return ((val + alignment - 1) / alignment) * alignment;
}
