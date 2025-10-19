// PointLightRenderer moved from renderer.zig
const vk = @import("vulkan");
const GraphicsContext = @import("../core/graphics_context.zig").GraphicsContext;
const Scene = @import("../scene/scene.zig").Scene;
const UnifiedPipelineSystem = @import("../rendering/unified_pipeline_system.zig").UnifiedPipelineSystem;
const PipelineConfig = @import("../rendering/unified_pipeline_system.zig").PipelineConfig;
const PipelineId = @import("../rendering/unified_pipeline_system.zig").PipelineId;
const Resource = @import("../rendering/unified_pipeline_system.zig").Resource;
const DepthStencilState = @import("../rendering/pipeline_builder.zig").DepthStencilState;
const ColorBlendAttachment = @import("../rendering/pipeline_builder.zig").ColorBlendAttachment;
const Math = @import("../utils/math.zig");
const FrameInfo = @import("../rendering/frameinfo.zig").FrameInfo;
const GlobalUbo = @import("../rendering/frameinfo.zig").GlobalUbo;
const log = @import("../utils/log.zig").log;
const SceneBridge = @import("../rendering/scene_bridge.zig").SceneBridge;
const GlobalUboSet = @import("../rendering/ubo_set.zig").GlobalUboSet;
const MAX_FRAMES_IN_FLIGHT = @import("../core/swapchain.zig").MAX_FRAMES_IN_FLIGHT;

pub const PointLightPushConstant = struct {
    position: Math.Vec4 = Math.Vec4.init(0, 0, 0, 1),
    color: Math.Vec4 = Math.Vec4.init(1, 1, 1, 1),
    radius: f32 = 1.0,
};

pub const PointLightRenderer = struct {
    scene: *Scene = undefined,
    pipeline_system: *UnifiedPipelineSystem,
    gc: *GraphicsContext = undefined,
    pipeline_id: PipelineId,
    cached_pipeline_handle: vk.Pipeline,
    render_pass: vk.RenderPass,
    global_ubo_set: *GlobalUboSet,

    pub fn init(
        gc: *GraphicsContext,
        pipeline_system: *UnifiedPipelineSystem,
        render_pass: vk.RenderPass,
        scene: *Scene,
        global_ubo_set: *GlobalUboSet,
    ) !PointLightRenderer {
        const pipeline_config = PipelineConfig{
            .name = "point_light_renderer",
            .vertex_shader = "shaders/point_light.vert",
            .fragment_shader = "shaders/point_light.frag",
            .render_pass = render_pass,
            .topology = .triangle_list,
            .cull_mode = .{ .back_bit = true },
            .front_face = .counter_clockwise,
            .push_constant_ranges = &[_]vk.PushConstantRange{
                .{
                    .stage_flags = .{ .vertex_bit = true, .fragment_bit = true },
                    .offset = 0,
                    .size = @sizeOf(PointLightPushConstant),
                },
            },
            .multisample_state = null,
            .depth_stencil_state = DepthStencilState{
                .depth_test_enable = false,
                .depth_write_enable = false,
                .depth_compare_op = .less,
            },
            .color_blend_attachment = ColorBlendAttachment.additiveBlend(),
        };

        const pipeline_id = try pipeline_system.createPipeline(pipeline_config);
        const pipeline_ptr = pipeline_system.pipelines.getPtr(pipeline_id) orelse return error.PipelineNotFound;

        // Bind the shared global UBO buffer to the pipeline's descriptor set for each frame.
        for (0..MAX_FRAMES_IN_FLIGHT) |frame_idx| {
            const buffer_info = global_ubo_set.buffers[frame_idx].descriptor_info;
            const resource = Resource{
                .buffer = .{
                    .buffer = buffer_info.buffer,
                    .offset = buffer_info.offset,
                    .range = buffer_info.range,
                },
            };

            try pipeline_system.bindResource(
                pipeline_id,
                0,
                0,
                resource,
                @intCast(frame_idx),
            );

            try pipeline_system.updateDescriptorSetsForPipeline(pipeline_id, @intCast(frame_idx));
        }

        return PointLightRenderer{
            .scene = scene,
            .pipeline_system = pipeline_system,
            .gc = gc,
            .pipeline_id = pipeline_id,
            .cached_pipeline_handle = pipeline_ptr.vulkan_pipeline,
            .render_pass = render_pass,
            .global_ubo_set = global_ubo_set,
        };
    }

    pub fn update_point_lights(self: *PointLightRenderer, frame_info: *FrameInfo, global_ubo: *GlobalUbo) !void {
        _ = frame_info;
        var num_lights: u32 = 0;
        for (self.scene.objects.items) |*object| {
            if (object.point_light == null) {
                continue;
            }
            global_ubo.point_lights[num_lights].color = Math.Vec4.init(object.point_light.?.color.x, object.point_light.?.color.y, object.point_light.?.color.z, object.point_light.?.intensity);
            global_ubo.point_lights[num_lights].position = Math.Vec4.init(
                object.transform.local2world.data[12],
                object.transform.local2world.data[13],
                object.transform.local2world.data[14],
                object.transform.local2world.data[15],
            );
            num_lights += 1;
        }
        global_ubo.num_point_lights = num_lights;
    }

    pub fn update(self: *PointLightRenderer, _frame_info: *const FrameInfo, _scene_bridge: *SceneBridge) !bool {
        _ = self;
        _ = _frame_info;
        _ = _scene_bridge;
        return false;
    }

    pub fn deinit(self: *PointLightRenderer) void {
        _ = self;
    }

    pub fn render(self: *PointLightRenderer, frame_info: FrameInfo, scene_bridge: *SceneBridge) !void {
        _ = scene_bridge;
        const pipeline_ptr = self.pipeline_system.pipelines.getPtr(self.pipeline_id) orelse {
            log(.ERROR, "point_light_renderer", "Pipeline not found", .{});
            return;
        };

        const pipeline_changed = pipeline_ptr.vulkan_pipeline != self.cached_pipeline_handle;
        if (pipeline_changed) {
            self.cached_pipeline_handle = pipeline_ptr.vulkan_pipeline;
            self.pipeline_system.markPipelineResourcesDirty(self.pipeline_id);
        }

        try self.pipeline_system.updateDescriptorSetsForPipeline(self.pipeline_id, frame_info.current_frame);

        const pipeline_layout = try self.pipeline_system.getPipelineLayout(self.pipeline_id);
        self.gc.*.vkd.cmdBindPipeline(frame_info.command_buffer, .graphics, pipeline_ptr.vulkan_pipeline);

        if (pipeline_ptr.descriptor_sets.items.len == 0) {
            log(.WARN, "point_light_renderer", "No descriptor sets available for point light pipeline", .{});
            return;
        }

        const descriptor_set = pipeline_ptr.descriptor_sets.items[0][frame_info.current_frame];
        self.gc.*.vkd.cmdBindDescriptorSets(
            frame_info.command_buffer,
            .graphics,
            pipeline_layout,
            0,
            1,
            @ptrCast(&descriptor_set),
            0,
            null,
        );

        for (self.scene.objects.items) |*object| {
            if (object.point_light == null) {
                continue;
            }
            const push = PointLightPushConstant{ .position = Math.Vec4.init(
                object.transform.local2world.data[12],
                object.transform.local2world.data[13],
                object.transform.local2world.data[14],
                object.transform.local2world.data[15],
            ), .color = Math.Vec4.init(object.point_light.?.color.x, object.point_light.?.color.y, object.point_light.?.color.z, object.point_light.?.intensity), .radius = object.transform.object_scale.x };

            self.gc.*.vkd.cmdPushConstants(frame_info.command_buffer, pipeline_layout, .{ .vertex_bit = true, .fragment_bit = true }, 0, @sizeOf(PointLightPushConstant), @ptrCast(&push));
            self.gc.*.vkd.cmdDraw(frame_info.command_buffer, 6, 1, 0, 0);
        }
    }
};
