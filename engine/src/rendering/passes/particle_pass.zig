const std = @import("std");
const vk = @import("vulkan");
const log = @import("../../utils/log.zig").log;
const Math = @import("../../utils/math.zig");

const RenderGraph = @import("../render_graph.zig").RenderGraph;
const RenderPass = @import("../render_graph.zig").RenderPass;
const RenderPassVTable = @import("../render_graph.zig").RenderPassVTable;
const ResourceId = @import("../render_graph.zig").ResourceId;
const FrameInfo = @import("../frameinfo.zig").FrameInfo;
const GlobalUbo = @import("../frameinfo.zig").GlobalUbo;
const GraphicsContext = @import("../../core/graphics_context.zig").GraphicsContext;
const UnifiedPipelineSystem = @import("../unified_pipeline_system.zig").UnifiedPipelineSystem;
const PipelineConfig = @import("../unified_pipeline_system.zig").PipelineConfig;
const PipelineId = @import("../unified_pipeline_system.zig").PipelineId;
const Resource = @import("../unified_pipeline_system.zig").Resource;
const ResourceBinder = @import("../resource_binder.zig").ResourceBinder;
const MAX_FRAMES_IN_FLIGHT = @import("../../core/swapchain.zig").MAX_FRAMES_IN_FLIGHT;
const DynamicRenderingHelper = @import("../../utils/dynamic_rendering.zig").DynamicRenderingHelper;
const Buffer = @import("../../core/buffer.zig").Buffer;
const vertex_formats = @import("../vertex_formats.zig");

// ECS imports for particles
const ecs = @import("../../ecs.zig");
const World = ecs.World;
const ParticleComponent = ecs.ParticleComponent;

// Global UBO
const GlobalUboSet = @import("../ubo_set.zig").GlobalUboSet;

/// Particle rendering pass
/// Renders particles computed by ParticleComputePass
pub const ParticlePass = struct {
    base: RenderPass,
    allocator: std.mem.Allocator,

    // Rendering context
    graphics_context: *GraphicsContext,
    pipeline_system: *UnifiedPipelineSystem,
    resource_binder: ResourceBinder,
    compute_pass: ?*@import("particle_compute_pass.zig").ParticleComputePass,
    global_ubo_set: *GlobalUboSet,

    // Swapchain formats
    swapchain_color_format: vk.Format,
    swapchain_depth_format: vk.Format,

    // Pipeline
    particle_pipeline: PipelineId = undefined,
    cached_pipeline_handle: vk.Pipeline = .null_handle,

    // Particle count
    max_particles: u32,

    pub fn create(
        allocator: std.mem.Allocator,
        graphics_context: *GraphicsContext,
        pipeline_system: *UnifiedPipelineSystem,
        global_ubo_set: *GlobalUboSet,
        swapchain_color_format: vk.Format,
        swapchain_depth_format: vk.Format,
        max_particles: u32,
    ) !*ParticlePass {
        const pass = try allocator.create(ParticlePass);

        pass.* = ParticlePass{
            .base = RenderPass{
                .name = "particle_pass",
                .enabled = true,
                .vtable = &vtable,
                .dependencies = std.ArrayList([]const u8){},
            },
            .allocator = allocator,
            .graphics_context = graphics_context,
            .pipeline_system = pipeline_system,
            .resource_binder = ResourceBinder.init(allocator, pipeline_system),
            .compute_pass = null, // Will be set by scene
            .global_ubo_set = global_ubo_set,
            .swapchain_color_format = swapchain_color_format,
            .swapchain_depth_format = swapchain_depth_format,
            .max_particles = max_particles,
        };

        log(.INFO, "particle_pass", "Created ParticlePass (max={} particles)", .{max_particles});
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
        const self: *ParticlePass = @fieldParentPtr("base", base);

        // Check if pipeline now exists (hot-reload succeeded)
        if (!self.pipeline_system.pipelines.contains(self.particle_pipeline)) {
            return false;
        }

        // Pipeline exists! Complete the setup that was skipped during initial failure
        const pipeline_entry = self.pipeline_system.pipelines.get(self.particle_pipeline) orelse return false;
        self.cached_pipeline_handle = pipeline_entry.vulkan_pipeline;

        // Bind global UBO to all frames
        self.updateDescriptors() catch |err| {
            log(.WARN, "particle_pass", "Failed to update descriptors during recovery: {}", .{err});
            return false;
        };

        log(.INFO, "particle_pass", "Recovery setup complete", .{});
        return true;
    }

    fn updateImpl(base: *RenderPass, frame_info: *const FrameInfo) !void {
        _ = base;
        _ = frame_info;
        // No per-frame updates needed for particle rendering pass
    }

    fn setupImpl(base: *RenderPass, graph: *RenderGraph) !void {
        const self: *ParticlePass = @fieldParentPtr("base", base);
        _ = graph;

        // Create particle rendering pipeline
        const color_formats = [_]vk.Format{self.swapchain_color_format};
        const pipeline_config = PipelineConfig{
            .name = "particle_pass",
            .vertex_shader = "assets/shaders/particles.vert",
            .fragment_shader = "assets/shaders/particles.frag",
            .render_pass = .null_handle, // Dynamic rendering
            .vertex_input_bindings = vertex_formats.particle_bindings[0..],
            .vertex_input_attributes = vertex_formats.particle_attributes[0..],
            .topology = .point_list,
            .cull_mode = .{}, // No culling for particles
            .dynamic_rendering_color_formats = &color_formats,
            .dynamic_rendering_depth_format = self.swapchain_depth_format,
            // Enable standard alpha blending for particles
            .color_blend_attachment = .{
                .blend_enable = true,
                .src_color_blend_factor = .src_alpha,
                .dst_color_blend_factor = .one_minus_src_alpha,
                .color_blend_op = .add,
                .src_alpha_blend_factor = .one,
                .dst_alpha_blend_factor = .one_minus_src_alpha,
                .alpha_blend_op = .add,
                .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
            },
        };

        const result = try self.pipeline_system.createPipeline(pipeline_config);
        self.particle_pipeline = result.id;

        if (!result.success) {
            // Pipeline creation failed - return error so RenderGraph disables the pass
            log(.WARN, "particle_pass", "Pipeline creation failed. Pass will be disabled.", .{});
            return error.PipelineCreationFailed;
        }

        const pipeline_entry = self.pipeline_system.pipelines.get(self.particle_pipeline) orelse return error.PipelineNotFound;
        self.cached_pipeline_handle = pipeline_entry.vulkan_pipeline;

        // Bind global UBO to all frames
        try self.updateDescriptors();

        log(.INFO, "particle_pass", "Setup complete", .{});
    }
    fn updateDescriptors(self: *ParticlePass) !void {
        // Bind global UBO for all frames
        for (0..@import("../../core/swapchain.zig").MAX_FRAMES_IN_FLIGHT) |frame_idx| {
            const ubo_resource = Resource{
                .buffer = .{
                    .buffer = self.global_ubo_set.buffers[frame_idx].buffer,
                    .offset = 0,
                    .range = @sizeOf(@import("../frameinfo.zig").GlobalUbo),
                },
            };

            try self.pipeline_system.bindResource(
                self.particle_pipeline,
                0, // Set 0
                0, // Binding 0
                ubo_resource,
                @intCast(frame_idx),
            );
            try self.resource_binder.updateFrame(self.particle_pipeline, @as(u32, @intCast(frame_idx)));
        }
    }

    fn executeImpl(base: *RenderPass, frame_info: FrameInfo) !void {
        const self: *ParticlePass = @fieldParentPtr("base", base);

        const command_buffer = frame_info.command_buffer;
        const frame_index = frame_info.current_frame;

        // Check if pipeline exists (might have been created by hot-reload after initial failure)
        var pipeline_entry = self.pipeline_system.pipelines.get(self.particle_pipeline) orelse {
            // Pipeline doesn't exist - skip rendering
            return;
        };

        // Check for pipeline reload (includes first-time creation after initial failure)
        const pipeline_rebuilt = pipeline_entry.vulkan_pipeline != self.cached_pipeline_handle;

        if (pipeline_rebuilt) {
            log(.INFO, "particle_pass", "Pipeline hot-reloaded, rebinding all descriptors", .{});
            self.pipeline_system.markPipelineResourcesDirty(self.particle_pipeline);
            self.cached_pipeline_handle = pipeline_entry.vulkan_pipeline;

            // Rebind resources after hot reload
            try self.updateDescriptors();

            pipeline_entry = self.pipeline_system.pipelines.get(self.particle_pipeline) orelse return error.PipelineNotFound;
        }

        // Check if we have a compute pass
        if (self.compute_pass == null) {
            return; // No compute pass, nothing to render
        }

        // Setup dynamic rendering with helper (render on top of existing scene)
        // Use initLoad to preserve existing color and depth
        const rendering = DynamicRenderingHelper.initLoad(
            frame_info.color_image_view,
            frame_info.depth_image_view,
            frame_info.extent,
        );

        // Begin rendering (also sets viewport and scissor)
        rendering.begin(self.graphics_context, command_buffer);

        // Bind vertex buffer from compute pass output
        const particle_buffer = self.compute_pass.?.getParticleBuffer(frame_index);
        const vertex_buffers = [_]vk.Buffer{particle_buffer};
        const offsets = [_]vk.DeviceSize{0};
        self.graphics_context.vkd.cmdBindVertexBuffers(
            command_buffer,
            0,
            1,
            &vertex_buffers,
            &offsets,
        );

        try self.pipeline_system.bindPipelineWithDescriptorSets(command_buffer, self.particle_pipeline, frame_index);

        // Draw only active particles (not the entire max_particles buffer)
        const active_particle_count = self.compute_pass.?.getParticleCount();
        if (active_particle_count == 0) {
            rendering.end(self.graphics_context, command_buffer);
            return; // No particles to render
        }

        self.graphics_context.vkd.cmdDraw(
            command_buffer,
            active_particle_count,
            1,
            0,
            0,
        );

        // End rendering
        rendering.end(self.graphics_context, command_buffer);
    }

    fn teardownImpl(base: *RenderPass) void {
        const self: *ParticlePass = @fieldParentPtr("base", base);

        log(.INFO, "particle_pass", "Cleaned up ParticlePass", .{});
        self.allocator.destroy(self);
    }

    /// Set the compute pass that produces particles
    pub fn setComputePass(self: *ParticlePass, compute_pass: *@import("particle_compute_pass.zig").ParticleComputePass) void {
        self.compute_pass = compute_pass;
    }
};
