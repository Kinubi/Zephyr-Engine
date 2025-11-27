const std = @import("std");
const vk = @import("vulkan");
const log = @import("../../utils/log.zig").log;
const RenderGraph = @import("../render_graph.zig").RenderGraph;
const RenderPass = @import("../render_graph.zig").RenderPass;
const RenderPassVTable = @import("../render_graph.zig").RenderPassVTable;
const FrameInfo = @import("../frameinfo.zig").FrameInfo;
const GraphicsContext = @import("../../core/graphics_context.zig").GraphicsContext;
const UnifiedPipelineSystem = @import("../unified_pipeline_system.zig").UnifiedPipelineSystem;
const PipelineConfig = @import("../unified_pipeline_system.zig").PipelineConfig;
const PipelineId = @import("../unified_pipeline_system.zig").PipelineId;
const ResourceBinder = @import("../resource_binder.zig").ResourceBinder;
const ManagedTexture = @import("../texture_manager.zig").ManagedTexture;
const GlobalUboSet = @import("../ubo_set.zig").GlobalUboSet;
const MAX_FRAMES_IN_FLIGHT = @import("../../core/swapchain.zig").MAX_FRAMES_IN_FLIGHT;
const DynamicRenderingHelper = @import("../../utils/dynamic_rendering.zig").DynamicRenderingHelper;
const ecs = @import("../../ecs.zig");
const SkyboxSystem = ecs.SkyboxSystem;
const SkyboxGPUData = ecs.SkyboxGPUData;

/// Skybox render pass - renders environment background behind geometry
///
/// Simple pass like TonemapPass - receives ManagedTexture from SkyboxSystem,
/// ResourceBinder handles version tracking automatically.
///
/// Uses depth testing (less-or-equal) to fill pixels where no geometry was drawn.
/// Supports: equirectangular HDR maps and procedural sky.
pub const SkyboxPass = struct {
    base: RenderPass,
    allocator: std.mem.Allocator,

    // Rendering context
    graphics_context: *GraphicsContext,
    pipeline_system: *UnifiedPipelineSystem,
    resource_binder: ResourceBinder,
    global_ubo_set: *GlobalUboSet,

    // Skybox system (provides ManagedTexture and GPU data)
    skybox_system: *SkyboxSystem,

    // Formats
    color_format: vk.Format,
    depth_format: vk.Format,

    // Pipeline
    pipeline: PipelineId = undefined,
    cached_pipeline_handle: vk.Pipeline = .null_handle,

    pub fn create(
        allocator: std.mem.Allocator,
        graphics_context: *GraphicsContext,
        pipeline_system: *UnifiedPipelineSystem,
        global_ubo_set: *GlobalUboSet,
        skybox_system: *SkyboxSystem,
        color_format: vk.Format,
        depth_format: vk.Format,
    ) !*SkyboxPass {
        const pass = try allocator.create(SkyboxPass);
        pass.* = SkyboxPass{
            .base = RenderPass{
                .name = "skybox_pass",
                .enabled = true,
                .vtable = &vtable,
                .dependencies = std.ArrayList([]const u8){},
            },
            .allocator = allocator,
            .graphics_context = graphics_context,
            .pipeline_system = pipeline_system,
            .resource_binder = ResourceBinder.init(allocator, pipeline_system),
            .global_ubo_set = global_ubo_set,
            .skybox_system = skybox_system,
            .color_format = color_format,
            .depth_format = depth_format,
        };

        log(.INFO, "skybox_pass", "Created SkyboxPass", .{});
        return pass;
    }

    const vtable = RenderPassVTable{
        .setup = setupImpl,
        .update = updateImpl,
        .execute = executeImpl,
        .teardown = teardownImpl,
        .checkValidity = checkValidityImpl,
        .reset = reset,
    };

    fn setupImpl(base: *RenderPass, graph: *RenderGraph) !void {
        const self: *SkyboxPass = @fieldParentPtr("base", base);
        _ = graph;

        const DepthStencilState = @import("../pipeline_builder.zig").DepthStencilState;

        // Create pipeline - skybox writes at far depth, geometry overwrites with nearer depth
        const color_formats = [_]vk.Format{self.color_format};
        const pipeline_config = PipelineConfig{
            .name = "skybox_pass",
            .vertex_shader = "assets/shaders/skybox.vert",
            .fragment_shader = "assets/shaders/skybox.frag",
            .render_pass = .null_handle, // Dynamic rendering
            .cull_mode = .{},
            .front_face = .counter_clockwise,
            .depth_stencil_state = DepthStencilState.default(), // Write depth (skybox at far plane)
            .dynamic_rendering_color_formats = &color_formats,
            .dynamic_rendering_depth_format = self.depth_format,
            .push_constant_ranges = &[_]vk.PushConstantRange{.{
                .stage_flags = .{ .fragment_bit = true },
                .offset = 0,
                .size = @sizeOf(SkyboxGPUData),
            }},
        };

        const result = try self.pipeline_system.createPipeline(pipeline_config);
        self.pipeline = result.id;
        if (!result.success) {
            log(.WARN, "skybox_pass", "Pipeline creation failed. Pass will be disabled.", .{});
            return error.PipelineCreationFailed;
        }

        const pipeline_entry = self.pipeline_system.pipelines.get(self.pipeline) orelse return error.PipelineNotFound;
        self.cached_pipeline_handle = pipeline_entry.vulkan_pipeline;

        // Populate ResourceBinder with shader reflection data
        if (try self.pipeline_system.getPipelineReflection(self.pipeline)) |reflection| {
            var mut_reflection = reflection;
            try self.resource_binder.populateFromReflection(mut_reflection);
            mut_reflection.deinit(self.allocator);
        }

        // Bind resources (ResourceBinder tracks versions automatically)
        try self.bindResources();

        self.pipeline_system.markPipelineResourcesDirty(self.pipeline);

        log(.INFO, "skybox_pass", "Setup complete", .{});
    }

    fn updateImpl(base: *RenderPass, frame_info: *const FrameInfo) !void {
        const self: *SkyboxPass = @fieldParentPtr("base", base);

        // Check if pipeline was hot-reloaded
        const pipeline_entry = self.pipeline_system.pipelines.get(self.pipeline) orelse return;
        const pipeline_rebuilt = pipeline_entry.vulkan_pipeline != self.cached_pipeline_handle;

        if (pipeline_rebuilt) {
            log(.INFO, "skybox_pass", "Pipeline hot-reloaded, rebinding resources", .{});
            self.cached_pipeline_handle = pipeline_entry.vulkan_pipeline;
            self.resource_binder.clearPipeline(self.pipeline);

            // Rebind after hot reload
            try self.bindResources();
        }

        // Update descriptors for this frame (ResourceBinder handles rebinding if texture changed)
        try self.resource_binder.updateFrame(self.pipeline, frame_info.current_frame);
    }

    /// Bind resources - called during setup
    /// ResourceBinder automatically tracks ManagedTexture generation for rebinding
    fn bindResources(self: *SkyboxPass) !void {
        // Bind global UBO for all frames (set 0, binding 0)
        try self.resource_binder.bindUniformBufferNamed(
            self.pipeline,
            "GlobalUBO",
            self.global_ubo_set.frame_buffers,
        );

        // Bind environment texture (set 0, binding 1)
        // ResourceBinder tracks generation - will skip binding if gen=0 (not yet loaded)
        try self.resource_binder.bindTextureNamed(
            self.pipeline,
            "envMap",
            self.skybox_system.getEnvironmentTexture(),
        );
    }

    fn executeImpl(base: *RenderPass, frame_info: FrameInfo) !void {
        const self: *SkyboxPass = @fieldParentPtr("base", base);

        const cmd = frame_info.command_buffer;
        const frame_index = frame_info.current_frame;

        // Setup dynamic rendering with clear operation (skybox runs first, clears framebuffer)
        const rendering = DynamicRenderingHelper.init(
            frame_info.hdr_texture.?.image_view,
            frame_info.depth_image_view,
            frame_info.extent,
            .{ 0.01, 0.01, 0.01, 1.0 }, // clear color (dark gray - visible if skybox fails)
            1.0, // clear depth to far plane
        );

        rendering.begin(self.graphics_context, cmd);

        // Only draw skybox if we have valid resources
        if (self.skybox_system.canRender()) {
            // Bind pipeline with descriptors
            try self.pipeline_system.bindPipelineWithDescriptorSets(cmd, self.pipeline, frame_index);

            // Push skybox data as push constants
            const gpu_data = self.skybox_system.getGPUData();
            const pipeline_layout = try self.pipeline_system.getPipelineLayout(self.pipeline);
            self.graphics_context.vkd.cmdPushConstants(
                cmd,
                pipeline_layout,
                .{ .fragment_bit = true },
                0,
                @sizeOf(SkyboxGPUData),
                &gpu_data,
            );

            // Fullscreen triangle (no vertex buffers)
            self.graphics_context.vkd.cmdDraw(cmd, 3, 1, 0, 0);
        }

        rendering.end(self.graphics_context, cmd);
    }

    fn teardownImpl(base: *RenderPass) void {
        const self: *SkyboxPass = @fieldParentPtr("base", base);
        self.resource_binder.deinit();
        self.allocator.destroy(self);
        log(.INFO, "skybox_pass", "Teardown complete", .{});
    }

    fn checkValidityImpl(base: *RenderPass) bool {
        const self: *SkyboxPass = @fieldParentPtr("base", base);
        return self.pipeline_system.pipelines.contains(self.pipeline);
    }

    fn reset(ctx: *RenderPass) void {
        const self: *SkyboxPass = @fieldParentPtr("base", ctx);
        self.resource_binder.clear();

        if (self.cached_pipeline_handle != .null_handle) {
            self.pipeline_system.destroyPipeline(self.pipeline);
            self.cached_pipeline_handle = .null_handle;
        }

        log(.INFO, "skybox_pass", "Reset resources", .{});
    }
};
