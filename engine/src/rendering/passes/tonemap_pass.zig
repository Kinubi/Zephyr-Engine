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
const MAX_FRAMES_IN_FLIGHT = @import("../../core/swapchain.zig").MAX_FRAMES_IN_FLIGHT;
const DynamicRenderingHelper = @import("../../utils/dynamic_rendering.zig").DynamicRenderingHelper;

/// Final fullscreen tone mapping pass
/// Reads HDR RGBA16F and writes the tone-mapped result into the LDR swapchain image
pub const TonemapPass = struct {
    base: RenderPass,
    allocator: std.mem.Allocator,

    graphics_context: *GraphicsContext,
    pipeline_system: *UnifiedPipelineSystem,
    resource_binder: ResourceBinder,

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

        log(.INFO, "tonemap_pass", "Setup complete", .{});
    }

    fn updateImpl(base: *RenderPass, frame_info: *const FrameInfo) !void {
        const self: *TonemapPass = @fieldParentPtr("base", base);
        _ = frame_info;

        // Handle pipeline hot-reload
        if (self.pipeline_system.pipelines.get(self.pipeline)) |entry| {
            if (entry.vulkan_pipeline != self.cached_pipeline_handle) {
                log(.INFO, "tonemap_pass", "Pipeline hot-reloaded, rebinding descriptors", .{});
                self.cached_pipeline_handle = entry.vulkan_pipeline;
                self.pipeline_system.markPipelineResourcesDirty(self.pipeline);
            }
        }
    }

    fn executeImpl(base: *RenderPass, frame_info: FrameInfo) !void {
        const self: *TonemapPass = @fieldParentPtr("base", base);

        const cmd = frame_info.command_buffer;
        const frame_index = frame_info.current_frame;

        // Bind HDR view+sampler from FrameInfo.hdr_texture for current frame
        const hdr_tex = frame_info.hdr_texture orelse return error.InvalidState;
        const hdr_resource = Resource{ .image = .{
            .image_view = hdr_tex.image_view,
            .sampler = hdr_tex.sampler,
            .layout = .shader_read_only_optimal,
        } };
        try self.pipeline_system.bindResource(self.pipeline, 0, 0, hdr_resource, frame_index);
        try self.resource_binder.updateFrame(self.pipeline, frame_index);

        // Transition HDR image to SHADER_READ_ONLY for sampling
        self.graphics_context.transitionImageLayout(
            cmd,
            frame_info.hdr_texture.?.image,
            .color_attachment_optimal,
            .shader_read_only_optimal,
            .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        );

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

        // Transition swapchain LDR image from color_attachment_optimal to shader_read_only_optimal
        // so the UI layer can sample/blit from it
        self.graphics_context.transitionImageLayout(
            cmd,
            frame_info.color_image,
            .color_attachment_optimal,
            .shader_read_only_optimal,
            .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        );

        // Transition HDR image to SHADER_READ_ONLY for sampling
        self.graphics_context.transitionImageLayout(
            cmd,
            frame_info.hdr_texture.?.image,
            .shader_read_only_optimal,
            .color_attachment_optimal,
            .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        );
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
};

pub const TonemapPushConstants = extern struct {
    exposure: f32 = 1.0,
    manual_gamma: u32 = 1, // 1 = apply gamma 2.2 in shader, 0 = rely on SRGB attachment conversion
};
