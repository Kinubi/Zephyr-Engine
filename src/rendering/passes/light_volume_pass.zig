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

const Buffer = @import("../../core/buffer.zig").Buffer;

// ECS imports for lights
const ecs = @import("../../ecs.zig");
const World = ecs.World;
const LightSystem = ecs.LightSystem;

// Global UBO
const GlobalUboSet = @import("../ubo_set.zig").GlobalUboSet;
const Resource = @import("../unified_pipeline_system.zig").Resource;

/// Light volume data for SSBO (matches shader struct)
const LightVolumeData = extern struct {
    position: [4]f32,
    color: [4]f32,
    radius: f32,
    _padding: [3]f32 = .{0} ** 3,
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

    // SSBO for instanced light data (per frame to avoid synchronization issues)
    light_volume_buffers: [MAX_FRAMES_IN_FLIGHT]Buffer,
    max_lights: u32,

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

        // Create SSBO for light data (per frame in flight)
        const max_lights: u32 = 128; // Support up to 128 lights
        var light_volume_buffers: [MAX_FRAMES_IN_FLIGHT]Buffer = undefined;

        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            light_volume_buffers[i] = try Buffer.init(
                graphics_context,
                @sizeOf(LightVolumeData) * max_lights,
                1,
                .{ .storage_buffer_bit = true },
                .{ .host_visible_bit = true, .host_coherent_bit = true },
            );
            // Keep buffer mapped for writes (host_coherent means no need to flush)
            try light_volume_buffers[i].map(@sizeOf(LightVolumeData) * max_lights, 0);
        }

        pass.* = LightVolumePass{
            .base = RenderPass{
                .name = "light_volume_pass",
                .enabled = true,
                .vtable = &vtable,
                .dependencies = std.ArrayList([]const u8){},
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
            .light_volume_buffers = light_volume_buffers,
            .max_lights = max_lights,
        };

        log(.INFO, "light_volume_pass", "Created LightVolumePass", .{});
        return pass;
    }

    const vtable = RenderPassVTable{
        .setup = setupImpl,
        .update = updateImpl,
        .execute = executeImpl,
        .teardown = teardownImpl,
    };

    fn updateImpl(base: *RenderPass, frame_info: *const FrameInfo) !void {
        _ = base;
        _ = frame_info;
        // No per-frame updates needed for light volume pass
    }

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
            .push_constant_ranges = null, // No push constants - using SSBO now
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
        try self.updateDescriptors();

        log(.INFO, "light_volume_pass", "Setup complete", .{});
    }

    fn updateDescriptors(self: *LightVolumePass) !void {
        // Bind global UBO and light SSBO for all frames
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
                0, // Binding 0 - Global UBO
                ubo_resource,
                @intCast(frame_idx),
            );

            // Bind light volume SSBO
            const ssbo_resource = Resource{
                .buffer = .{
                    .buffer = self.light_volume_buffers[frame_idx].buffer,
                    .offset = 0,
                    .range = @sizeOf(LightVolumeData) * self.max_lights,
                },
            };

            try self.pipeline_system.bindResource(
                self.light_volume_pipeline,
                0, // Set 0
                1, // Binding 1 - Light SSBO
                ssbo_resource,
                @intCast(frame_idx),
            );

            try self.resource_binder.updateFrame(self.light_volume_pipeline, @as(u32, @intCast(frame_idx)));
        }
    }

    fn executeImpl(base: *RenderPass, frame_info: FrameInfo) !void {
        const self: *LightVolumePass = @fieldParentPtr("base", base);
        const cmd = frame_info.command_buffer;
        const frame_index = frame_info.current_frame;

        // Get cached lights (light system handles caching internally)
        const light_data = try self.light_system.getLights(self.ecs_world);

        if (light_data.lights.items.len == 0) {
            return; // No lights to render
        }

        // Update SSBO with light data for this frame
        const light_count = @min(light_data.lights.items.len, self.max_lights);
        var light_volumes = try self.allocator.alloc(LightVolumeData, light_count);
        defer self.allocator.free(light_volumes);

        for (light_data.lights.items[0..light_count], 0..) |light, i| {
            light_volumes[i] = LightVolumeData{
                .position = [4]f32{ light.position.x, light.position.y, light.position.z, 1.0 },
                .color = [4]f32{
                    light.color.x * light.intensity,
                    light.color.y * light.intensity,
                    light.color.z * light.intensity,
                    1.0,
                },
                .radius = @max(0.1, light.intensity * 0.2),
            };
        }

        // Write to SSBO
        const buffer_size = @sizeOf(LightVolumeData) * light_count;
        const light_bytes = std.mem.sliceAsBytes(light_volumes);
        self.light_volume_buffers[frame_index].writeToBuffer(light_bytes, buffer_size, 0);

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
            try self.updateDescriptors();
        }

        try self.pipeline_system.bindPipelineWithDescriptorSets(cmd, self.light_volume_pipeline, frame_info.current_frame);

        // Instanced draw - single draw call for all lights
        // 6 vertices per billboard, light_count instances
        self.graphics_context.vkd.cmdDraw(cmd, 6, @intCast(light_count), 0, 0);
    }

    fn teardownImpl(base: *RenderPass) void {
        const self: *LightVolumePass = @fieldParentPtr("base", base);
        log(.INFO, "light_volume_pass", "Tearing down", .{});

        // Clean up SSBO buffers
        for (&self.light_volume_buffers) |*buffer| {
            buffer.deinit();
        }

        self.light_system.deinit();
        self.allocator.destroy(self);
    }
};
