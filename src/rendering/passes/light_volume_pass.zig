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
const ResourceBinder = @import("../resource_binder.zig").ResourceBinder;
const PipelineConfig = @import("../unified_pipeline_system.zig").PipelineConfig;
const PipelineId = @import("../unified_pipeline_system.zig").PipelineId;
const MAX_FRAMES_IN_FLIGHT = @import("../../core/swapchain.zig").MAX_FRAMES_IN_FLIGHT;
const DynamicRenderingHelper = @import("../../utils/dynamic_rendering.zig").DynamicRenderingHelper;

// ECS imports for lights
const ecs = @import("../../ecs.zig");
const World = ecs.World;
const LightSystem = ecs.LightSystem;

// Global UBO
const GlobalUboSet = @import("../ubo_set.zig").GlobalUboSet;
const Resource = @import("../unified_pipeline_system.zig").Resource;

/// Push constants for light volume rendering
pub const LightVolumePushConstants = extern struct {
    position: [4]f32 = [4]f32{ 0, 0, 0, 1 },
    color: [4]f32 = [4]f32{ 1, 1, 1, 1 },
    radius: f32 = 1.0,
};

/// LightVolumePass renders emissive spheres/billboards at light positions
/// This makes lights visible and provides visual feedback for debugging
pub const LightVolumePass = struct {
    base: RenderPass,
    allocator: std.mem.Allocator,

    // Rendering context
    graphics_context: *GraphicsContext,
    pipeline_system: *UnifiedPipelineSystem,
    resource_binder: ResourceBinder,
    ecs_world: *World,
    global_ubo_set: *GlobalUboSet,

    // Swapchain formats
    swapchain_color_format: vk.Format,
    swapchain_depth_format: vk.Format,

    // Pipeline
    light_volume_pipeline: PipelineId = undefined,
    cached_pipeline_handle: vk.Pipeline = .null_handle,

    // Light extraction system
    light_system: LightSystem,

    pub fn create(
        allocator: std.mem.Allocator,
        graphics_context: *GraphicsContext,
        pipeline_system: *UnifiedPipelineSystem,
        ecs_world: *World,
        global_ubo_set: *GlobalUboSet,
        swapchain_color_format: vk.Format,
        swapchain_depth_format: vk.Format,
    ) !*LightVolumePass {
        const pass = try allocator.create(LightVolumePass);
        pass.* = LightVolumePass{
            .base = RenderPass{
                .name = "light_volume_pass",
                .vtable = &vtable,
            },
            .allocator = allocator,
            .graphics_context = graphics_context,
            .pipeline_system = pipeline_system,
            .resource_binder = ResourceBinder.init(allocator, pipeline_system),
            .ecs_world = ecs_world,
            .global_ubo_set = global_ubo_set,
            .swapchain_color_format = swapchain_color_format,
            .swapchain_depth_format = swapchain_depth_format,
            .light_system = LightSystem.init(allocator),
        };

        log(.INFO, "light_volume_pass", "Created LightVolumePass", .{});
        return pass;
    }

    const vtable = RenderPassVTable{
        .setup = setupImpl,
        .execute = executeImpl,
        .teardown = teardownImpl,
    };

    fn setupImpl(base: *RenderPass, graph: *RenderGraph) !void {
        const self: *LightVolumePass = @fieldParentPtr("base", base);
        _ = graph;

        // Create billboard light rendering pipeline
        const color_formats = [_]vk.Format{self.swapchain_color_format};
        const pipeline_config = PipelineConfig{
            .name = "light_volume_pass",
            .vertex_shader = "shaders/point_light.vert",
            .fragment_shader = "shaders/point_light.frag",
            .render_pass = .null_handle, // Dynamic rendering
            .vertex_input_bindings = null, // No vertex input for billboards
            .vertex_input_attributes = null,
            .push_constant_ranges = &[_]vk.PushConstantRange{
                .{
                    .stage_flags = .{ .vertex_bit = true, .fragment_bit = true },
                    .offset = 0,
                    .size = @sizeOf(LightVolumePushConstants),
                },
            },
            .topology = .triangle_list,
            .polygon_mode = .fill,
            .cull_mode = .{ .back_bit = true },
            .front_face = .counter_clockwise,
            .dynamic_rendering_color_formats = &color_formats,
            .dynamic_rendering_depth_format = self.swapchain_depth_format,
            .depth_stencil_state = .{
                .depth_test_enable = true, // Test against depth buffer
                .depth_write_enable = false, // Don't write to depth (transparent)
                .depth_compare_op = .less,
            },
            .color_blend_attachment = .{
                .blend_enable = true,
                .src_color_blend_factor = .src_alpha,
                .dst_color_blend_factor = .one, // Additive for glow effect
                .color_blend_op = .add,
                .src_alpha_blend_factor = .one,
                .dst_alpha_blend_factor = .zero,
                .alpha_blend_op = .add,
                .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
            },
        };

        self.light_volume_pipeline = try self.pipeline_system.createPipeline(pipeline_config);
        const pipeline_entry = self.pipeline_system.pipelines.get(self.light_volume_pipeline) orelse return error.PipelineNotFound;
        self.cached_pipeline_handle = pipeline_entry.vulkan_pipeline;

        // Bind global UBO to all frames
        try self.setupResources();

        log(.INFO, "light_volume_pass", "Setup complete", .{});
    }

    fn setupResources(self: *LightVolumePass) !void {
        // Bind global UBO for all frames
        for (0..MAX_FRAMES_IN_FLIGHT) |frame_idx| {
            const ubo_resource = Resource{
                .buffer = .{
                    .buffer = self.global_ubo_set.buffers[frame_idx].buffer,
                    .offset = 0,
                    .range = @sizeOf(@import("../frameinfo.zig").GlobalUbo),
                },
            };

            try self.pipeline_system.bindResource(
                self.light_volume_pipeline,
                0, // Set 0
                0, // Binding 0
                ubo_resource,
                @intCast(frame_idx),
            );
            try self.resource_binder.updateFrame(self.light_volume_pipeline, @as(u32, @intCast(frame_idx)));
        }
    }

    fn executeImpl(base: *RenderPass, frame_info: FrameInfo) !void {
        const self: *LightVolumePass = @fieldParentPtr("base", base);
        const cmd = frame_info.command_buffer;

        // Extract lights from ECS
        var light_data = try self.light_system.extractLights(self.ecs_world);
        defer light_data.deinit();

        if (light_data.lights.items.len == 0) {
            return; // No lights to render
        }

        // Setup dynamic rendering with load operations (don't clear, render on top of geometry)
        const helper = DynamicRenderingHelper.initLoad(
            frame_info.color_image_view,
            frame_info.depth_image_view,
            frame_info.extent,
        );

        helper.begin(self.graphics_context, cmd);
        defer helper.end(self.graphics_context, cmd);

        // Check for pipeline hot-reload
        const pipeline_entry = self.pipeline_system.pipelines.get(self.light_volume_pipeline) orelse return error.PipelineNotFound;
        const pipeline_rebuilt = pipeline_entry.vulkan_pipeline != self.cached_pipeline_handle;

        if (pipeline_rebuilt) {
            log(.INFO, "light_volume_pass", "Pipeline hot-reloaded", .{});
            self.cached_pipeline_handle = pipeline_entry.vulkan_pipeline;
            self.pipeline_system.markPipelineResourcesDirty(self.light_volume_pipeline);
            try self.setupResources();
        }

        try self.pipeline_system.bindPipelineWithDescriptorSets(cmd, self.light_volume_pipeline, frame_info.current_frame);
        const pipeline_layout = try self.pipeline_system.getPipelineLayout(self.light_volume_pipeline);
        // Render each light as a billboard
        for (light_data.lights.items) |light| {
            const push_constants = LightVolumePushConstants{
                .position = [4]f32{ light.position.x, light.position.y, light.position.z, 1.0 },
                .color = [4]f32{
                    light.color.x * light.intensity,
                    light.color.y * light.intensity,
                    light.color.z * light.intensity,
                    1.0,
                },
                .radius = @max(0.1, light.intensity * 0.2), // Visual size based on intensity
            };

            self.graphics_context.vkd.cmdPushConstants(
                cmd,
                pipeline_layout,
                .{ .vertex_bit = true, .fragment_bit = true },
                0,
                @sizeOf(LightVolumePushConstants),
                @ptrCast(&push_constants),
            );

            // Draw billboard (6 vertices = 2 triangles)
            self.graphics_context.vkd.cmdDraw(cmd, 6, 1, 0, 0);
        }
    }

    fn teardownImpl(base: *RenderPass) void {
        const self: *LightVolumePass = @fieldParentPtr("base", base);
        log(.INFO, "light_volume_pass", "Tearing down", .{});
        self.light_system.deinit();
        self.allocator.destroy(self);
    }
};
