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
const Resource = @import("../unified_pipeline_system.zig").Resource;
const ResourceBinder = @import("../resource_binder.zig").ResourceBinder;
const ManagedTexture = @import("../texture_manager.zig").ManagedTexture;
const MAX_FRAMES_IN_FLIGHT = @import("../../core/swapchain.zig").MAX_FRAMES_IN_FLIGHT;
const DynamicRenderingHelper = @import("../../utils/dynamic_rendering.zig").DynamicRenderingHelper;

// TODO: SIMPLIFY RENDER PASS - Remove resource update/check logic
// TODO: Use named resource binding: bindTexture("HDRInput", hdr_texture)

/// Final fullscreen tone mapping pass
/// Reads HDR RGBA16F and writes the tone-mapped result into the LDR swapchain image
pub const TonemapPass = struct {
    base: RenderPass,
    allocator: std.mem.Allocator,

    graphics_context: *GraphicsContext,
    pipeline_system: *UnifiedPipelineSystem,
    resource_binder: ResourceBinder,

    // HDR input textures (per-frame swapchain textures)
    hdr_textures: [MAX_FRAMES_IN_FLIGHT]*ManagedTexture,

    // Formats
    swapchain_color_format: vk.Format,

    // Pipeline
    pipeline: PipelineId = undefined,
    cached_pipeline_handle: vk.Pipeline = .null_handle,

    // Parameters
    exposure: f32 = 1.0,

    pub fn create(
        allocator: std.mem.Allocator,
        graphics_context: *GraphicsContext,
        pipeline_system: *UnifiedPipelineSystem,
        hdr_textures: [MAX_FRAMES_IN_FLIGHT]*ManagedTexture,
        swapchain_color_format: vk.Format,
    ) !*TonemapPass {
        const pass = try allocator.create(TonemapPass);
        pass.* = TonemapPass{
            .base = RenderPass{
                .name = "tonemap_pass",
                .enabled = true,
                .vtable = &vtable,
                // Initialize an empty dependency list; we'll append required deps below
                .dependencies = std.ArrayList([]const u8){},
            },
            .allocator = allocator,
            .graphics_context = graphics_context,
            .pipeline_system = pipeline_system,
            .resource_binder = ResourceBinder.init(allocator, pipeline_system),
            .hdr_textures = hdr_textures,
            .swapchain_color_format = swapchain_color_format,
        };

        // Explicitly declare execution dependencies so tonemap runs after all prior passes
        try pass.base.dependencies.append(allocator, "geometry_pass");
        try pass.base.dependencies.append(allocator, "path_tracing_pass");
        try pass.base.dependencies.append(allocator, "particle_pass");
        try pass.base.dependencies.append(allocator, "light_volume_pass");

        log(.INFO, "tonemap_pass", "Created TonemapPass", .{});
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
        const self: *TonemapPass = @fieldParentPtr("base", base);
        _ = graph;

        const color_formats = [_]vk.Format{self.swapchain_color_format};
        const pipeline_config = PipelineConfig{
            .name = "tonemap_pass",
            .vertex_shader = "assets/shaders/tonemap.vert",
            .fragment_shader = "assets/shaders/tonemap.frag",
            .render_pass = .null_handle, // Dynamic rendering
            .cull_mode = .{},
            .front_face = .counter_clockwise,
            .dynamic_rendering_color_formats = &color_formats,
            .dynamic_rendering_depth_format = .undefined, // no depth
            .push_constant_ranges = &[_]vk.PushConstantRange{.{
                .stage_flags = .{ .fragment_bit = true },
                .offset = 0,
                .size = @sizeOf(TonemapPushConstants),
            }},
        };

        const result = try self.pipeline_system.createPipeline(pipeline_config);
        self.pipeline = result.id;
        if (!result.success) {
            log(.WARN, "tonemap_pass", "Pipeline creation failed. Pass will be disabled.", .{});
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

        // Bind resources once during setup - ResourceBinder will track updates automatically
        try self.bindResources();

        self.pipeline_system.markPipelineResourcesDirty(self.pipeline);

        log(.INFO, "tonemap_pass", "Setup complete", .{});
    }

    fn updateImpl(base: *RenderPass, frame_info: *const FrameInfo) !void {
        const self: *TonemapPass = @fieldParentPtr("base", base);

        // Update descriptors for this frame
        try self.resource_binder.updateFrame(self.pipeline, frame_info.current_frame);
    }

    /// Bind resources - called during setup and after hot-reload
    fn bindResources(self: *TonemapPass) !void {
        // Bind HDR texture array (one per frame-in-flight)
        try self.resource_binder.bindManagedTexturePerFrameNamed(
            self.pipeline,
            "uHdr",
            self.hdr_textures,
        );
    }

    fn executeImpl(base: *RenderPass, frame_info: FrameInfo) !void {
        const self: *TonemapPass = @fieldParentPtr("base", base);

        const cmd = frame_info.command_buffer;
        const frame_index = frame_info.current_frame;

        // Setup dynamic rendering targeting the LDR swapchain image (no depth)
        const rendering = DynamicRenderingHelper.init(
            frame_info.color_image_view,
            null,
            frame_info.extent,
            .{ 0.0, 0.0, 0.0, 1.0 },
            1.0,
        );

        rendering.begin(self.graphics_context, cmd);

        // Bind pipeline with descriptors
        try self.pipeline_system.bindPipelineWithDescriptorSets(cmd, self.pipeline, frame_index);

        // Push constants (exposure and gamma control)
        const pc = TonemapPushConstants{
            .exposure = self.exposure,
            .manual_gamma = if (isSrgbFormat(self.swapchain_color_format)) 0 else 1,
        };

        const pipeline_layout = try self.pipeline_system.getPipelineLayout(self.pipeline);
        self.graphics_context.vkd.cmdPushConstants(
            cmd,
            pipeline_layout,
            .{ .fragment_bit = true },
            0,
            @sizeOf(TonemapPushConstants),
            &pc,
        );

        // Fullscreen triangle (no vertex buffers)
        self.graphics_context.vkd.cmdDraw(cmd, 3, 1, 0, 0);

        rendering.end(self.graphics_context, cmd);

        // No transitions needed! Images stay in GENERAL layout
    }

    fn teardownImpl(base: *RenderPass) void {
        const self: *TonemapPass = @fieldParentPtr("base", base);
        self.resource_binder.deinit();
        self.allocator.destroy(self);
        log(.INFO, "tonemap_pass", "Teardown complete", .{});
    }

    fn checkValidityImpl(base: *RenderPass) bool {
        const self: *TonemapPass = @fieldParentPtr("base", base);
        // Consider pass valid if pipeline exists
        return self.pipeline_system.pipelines.contains(self.pipeline);
    }

    fn isSrgbFormat(format: vk.Format) bool {
        return switch (format) {
            .b8g8r8a8_srgb, .r8g8b8a8_srgb, .a8b8g8r8_srgb_pack32 => true,
            else => false,
        };
    }

    /// Reset pass state and release resources
    /// Called when the render graph is reset (e.g. scene change)
    /// Clears resource bindings and destroys pipeline to prevent dangling references
    fn reset(ctx: *RenderPass) void {
        const self: *TonemapPass = @fieldParentPtr("base", ctx);
        self.resource_binder.clear();

        if (self.cached_pipeline_handle != .null_handle) {
            self.pipeline_system.destroyPipeline(self.pipeline);
            self.cached_pipeline_handle = .null_handle;
        }

        log(.INFO, "tonemap_pass", "Reset resources", .{});
    }
};

pub const TonemapPushConstants = extern struct {
    exposure: f32 = 1.0,
    manual_gamma: u32 = 1, // 1 = apply gamma 2.2 in shader, 0 = rely on SRGB attachment conversion
};
