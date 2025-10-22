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
const Texture = @import("../../core/texture.zig").Texture;
const RaytracingSystem = @import("../../systems/raytracing_system.zig").RaytracingSystem;
const ThreadPool = @import("../../threading/thread_pool.zig").ThreadPool;
const GlobalUboSet = @import("../ubo_set.zig").GlobalUboSet;
const MAX_FRAMES_IN_FLIGHT = @import("../../core/swapchain.zig").MAX_FRAMES_IN_FLIGHT;

// ECS imports
const ecs = @import("../../ecs.zig");
const World = ecs.World;

/// Path tracing pass - renders the scene using ray tracing for realistic global illumination
pub const PathTracingPass = struct {
    base: RenderPass,
    allocator: std.mem.Allocator,

    // Core rendering infrastructure
    graphics_context: *GraphicsContext,
    pipeline_system: *UnifiedPipelineSystem,
    thread_pool: *ThreadPool,
    global_ubo_set: *GlobalUboSet,
    ecs_world: *World,

    // Path tracing pipeline
    path_tracing_pipeline: PipelineId = undefined,
    cached_pipeline_handle: vk.Pipeline = .null_handle,

    // Ray tracing system (manages BVH/acceleration structures)
    rt_system: *RaytracingSystem,

    // Output texture for path-traced results
    output_texture: Texture,
    width: u32,
    height: u32,

    // Acceleration structure tracking
    tlas: vk.AccelerationStructureKHR = vk.AccelerationStructureKHR.null_handle,
    tlas_valid: bool = false,

    // Per-frame descriptor tracking
    descriptor_dirty_flags: [MAX_FRAMES_IN_FLIGHT]bool = [_]bool{true} ** MAX_FRAMES_IN_FLIGHT,

    // Toggle between raster and path tracing
    enable_path_tracing: bool = false,

    pub fn create(
        allocator: std.mem.Allocator,
        graphics_context: *GraphicsContext,
        pipeline_system: *UnifiedPipelineSystem,
        thread_pool: *ThreadPool,
        global_ubo_set: *GlobalUboSet,
        ecs_world: *World,
        width: u32,
        height: u32,
    ) !*PathTracingPass {
        const pass = try allocator.create(PathTracingPass);

        // Create raytracing system for BVH management
        const rt_system = try allocator.create(RaytracingSystem);
        rt_system.* = try RaytracingSystem.init(graphics_context, allocator, thread_pool);

        // Create output texture for path-traced results
        const output_texture = try Texture.init(
            graphics_context,
            .r8g8b8a8_unorm,
            .{ .width = width, .height = height, .depth = 1 },
            vk.ImageUsageFlags{
                .storage_bit = true,
                .transfer_src_bit = true,
                .transfer_dst_bit = true,
                .sampled_bit = true,
            },
            vk.SampleCountFlags{ .@"1_bit" = true },
        );

        pass.* = PathTracingPass{
            .base = RenderPass{
                .name = "path_tracing_pass",
                .vtable = &vtable,
            },
            .allocator = allocator,
            .graphics_context = graphics_context,
            .pipeline_system = pipeline_system,
            .thread_pool = thread_pool,
            .global_ubo_set = global_ubo_set,
            .ecs_world = ecs_world,
            .rt_system = rt_system,
            .output_texture = output_texture,
            .width = width,
            .height = height,
        };

        log(.INFO, "path_tracing_pass", "Created PathTracingPass ({}x{})", .{ width, height });
        return pass;
    }

    const vtable = RenderPassVTable{
        .setup = setupImpl,
        .execute = executeImpl,
        .teardown = teardownImpl,
    };

    fn setupImpl(base: *RenderPass, graph: *RenderGraph) !void {
        const self: *PathTracingPass = @fieldParentPtr("base", base);
        _ = graph;

        // Create path tracing pipeline
        const pipeline_config = PipelineConfig{
            .name = "path_tracing",
            .raygen_shader = "shaders/RayTracingTriangle.rgen.hlsl",
            .miss_shader = "shaders/RayTracingTriangle.rmiss.hlsl",
            .closest_hit_shader = "shaders/RayTracingTriangle.rchit.hlsl",
            .render_pass = vk.RenderPass.null_handle,
        };

        self.path_tracing_pipeline = try self.pipeline_system.createPipeline(pipeline_config);
        const entry = self.pipeline_system.pipelines.get(self.path_tracing_pipeline) orelse return error.PipelineNotFound;
        self.cached_pipeline_handle = entry.vulkan_pipeline;

        // Update shader binding table
        try self.rt_system.updateShaderBindingTable(entry.vulkan_pipeline);

        // Mark all descriptors as dirty so they get updated
        for (&self.descriptor_dirty_flags) |*dirty| {
            dirty.* = true;
        }

        log(.INFO, "path_tracing_pass", "Setup complete", .{});
    }

    /// Update descriptors for all frames (called when resources change)
    /// Update descriptors for all frames (like rt_renderer.update does)
    fn updateDescriptors(self: *PathTracingPass) !void {
        if (!self.tlas_valid) {
            log(.WARN, "path_tracing_pass", "TLAS not valid, skipping descriptor update", .{});
            return;
        }

        // Prepare resources (exactly like rt_renderer does)
        const accel_resource = Resource{ .acceleration_structure = self.tlas };

        const output_descriptor = self.output_texture.getDescriptorInfo();
        const output_resource = Resource{
            .image = .{
                .image_view = output_descriptor.image_view,
                .sampler = output_descriptor.sampler,
                .layout = output_descriptor.image_layout,
            },
        };

        // Bind resources for ALL frames (like rt_renderer does)
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

            // Bind all resources to Set 0 (like rt_renderer does)
            // Binding 0: Acceleration Structure (TLAS)
            try self.pipeline_system.bindResource(self.path_tracing_pipeline, 0, 0, accel_resource, target_frame);
            // Binding 1: Output Image (storage image)
            try self.pipeline_system.bindResource(self.path_tracing_pipeline, 0, 1, output_resource, target_frame);
            // Binding 2: Camera UBO (global uniform buffer)
            try self.pipeline_system.bindResource(self.path_tracing_pipeline, 0, 2, global_resource, target_frame);

            self.descriptor_dirty_flags[frame_idx] = false;
        }

        log(.INFO, "path_tracing_pass", "Updated descriptors for all frames", .{});
    }

    fn executeImpl(base: *RenderPass, frame_info: FrameInfo) !void {
        const self: *PathTracingPass = @fieldParentPtr("base", base);
        const frame_index = frame_info.current_frame;

        // Check if pipeline was hot-reloaded
        const pipeline_entry = self.pipeline_system.pipelines.get(self.path_tracing_pipeline) orelse return error.PipelineNotFound;
        const pipeline_rebuilt = pipeline_entry.vulkan_pipeline != self.cached_pipeline_handle;

        if (pipeline_rebuilt) {
            log(.INFO, "path_tracing_pass", "Pipeline hot-reloaded, updating SBT", .{});
            try self.rt_system.updateShaderBindingTable(pipeline_entry.vulkan_pipeline);
            self.cached_pipeline_handle = pipeline_entry.vulkan_pipeline;
        }

        // Check if TLAS changed
        const tlas_changed = self.rt_system.tlas != vk.AccelerationStructureKHR.null_handle and
            (!self.tlas_valid or self.rt_system.tlas_dirty);

        if (tlas_changed) {
            self.updateTLAS(self.rt_system.tlas);
            self.rt_system.tlas_dirty = false;
        }

        // Check if we need to update descriptors (like rt_renderer does)
        const needs_update = tlas_changed or
            pipeline_rebuilt or
            self.descriptor_dirty_flags[frame_index];

        if (needs_update) {
            try self.updateDescriptors();
        }

        // Skip if TLAS is not valid
        if (!self.tlas_valid) {
            log(.WARN, "path_tracing_pass", "TLAS not valid, skipping path tracing", .{});
            return;
        }

        const cmd = frame_info.command_buffer;

        // Update descriptor sets for this frame
        try self.pipeline_system.updateDescriptorSetsForPipeline(
            self.path_tracing_pipeline,
            frame_index,
        );

        // Bind ray tracing pipeline (this also binds descriptor sets internally)
        try self.pipeline_system.bindPipeline(cmd, self.path_tracing_pipeline);

        // Dispatch rays
        try self.dispatchRays(cmd, self.rt_system.shader_binding_table);

        log(.INFO, "path_tracing_pass", "Path tracing dispatched", .{});
    }
    fn teardownImpl(base: *RenderPass) void {
        const self: *PathTracingPass = @fieldParentPtr("base", base);

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

    /// Toggle path tracing on/off (allows switching to raster)
    pub fn setEnabled(self: *PathTracingPass, enabled: bool) void {
        self.enable_path_tracing = enabled;
        if (enabled) {
            log(.INFO, "path_tracing_pass", "Path tracing ENABLED", .{});
        } else {
            log(.INFO, "path_tracing_pass", "Path tracing DISABLED (using raster)", .{});
        }
    }

    /// Get the path-traced output texture
    pub fn getOutputTexture(self: *PathTracingPass) *Texture {
        return &self.output_texture;
    }
};

fn alignForward(val: usize, alignment: usize) usize {
    return ((val + alignment - 1) / alignment) * alignment;
}
