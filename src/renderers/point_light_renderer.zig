// PointLightRenderer moved from renderer.zig
const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("../graphics_context.zig").GraphicsContext;
const Scene = @import("../scene.zig").Scene;
const Pipeline = @import("../pipeline.zig").Pipeline;
const ShaderLibrary = @import("../shader.zig").ShaderLibrary;
const Math = @import("../utils/math.zig");
const Camera = @import("../camera.zig").Camera;
const FrameInfo = @import("../frameinfo.zig").FrameInfo;
const GlobalUbo = @import("../frameinfo.zig").GlobalUbo;
const RenderSystem = @import("../systems/render_system.zig").RenderSystem;

const PointLightPushConstant = struct {
    position: Math.Vec4 = Math.Vec4.init(0, 0, 0, 1),
    color: Math.Vec4 = Math.Vec4.init(1, 1, 1, 1),
    radius: f32 = 1.0,
};

pub const PointLightRenderer = struct {
    scene: *Scene = undefined,
    pipeline: Pipeline = undefined,
    gc: *GraphicsContext = undefined,
    pipeline_layout: vk.PipelineLayout = undefined,
    camera: *Camera = undefined,

    pub fn init(gc: *GraphicsContext, render_pass: vk.RenderPass, scene: *Scene, shader_library: ShaderLibrary, alloc: std.mem.Allocator, camera: *Camera, global_set_layout: vk.DescriptorSetLayout) !PointLightRenderer {
        const pcr = [_]vk.PushConstantRange{.{ .stage_flags = .{ .vertex_bit = true, .fragment_bit = true }, .offset = 0, .size = @sizeOf(PointLightPushConstant) }};
        const dsl = [_]vk.DescriptorSetLayout{global_set_layout};
        const layout = try gc.*.vkd.createPipelineLayout(
            gc.*.dev,
            &vk.PipelineLayoutCreateInfo{
                .flags = .{},
                .set_layout_count = dsl.len,
                .p_set_layouts = &dsl,
                .push_constant_range_count = pcr.len,
                .p_push_constant_ranges = &pcr,
            },
            null,
        );
        const pipeline = try Pipeline.init(gc.*, render_pass, shader_library, layout, try Pipeline.defaultLayout(layout), alloc);
        return PointLightRenderer{ .scene = scene, .pipeline = pipeline, .gc = gc, .pipeline_layout = layout, .camera = camera };
    }

    pub fn update_point_lights(self: *PointLightRenderer, frame_info: *FrameInfo, global_ubo: *GlobalUbo) !void {
        _ = frame_info;
        var num_lights: u32 = 0;
        for (self.scene.objects.slice()) |*object| {
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

    pub fn deinit(self: *PointLightRenderer) void {
        self.pipeline.deinit();
    }

    pub fn render(self: *PointLightRenderer, frame_info: FrameInfo) !void {
        self.gc.*.vkd.cmdBindPipeline(frame_info.command_buffer, .graphics, self.pipeline.pipeline);
        self.gc.vkd.cmdBindDescriptorSets(frame_info.command_buffer, .graphics, self.pipeline_layout, 0, 1, @ptrCast(&frame_info.global_descriptor_set), 0, null);
        for (self.scene.objects.slice()) |*object| {
            if (object.point_light == null) {
                continue;
            }
            const push = PointLightPushConstant{ .position = Math.Vec4.init(
                object.transform.local2world.data[12],
                object.transform.local2world.data[13],
                object.transform.local2world.data[14],
                object.transform.local2world.data[15],
            ), .color = Math.Vec4.init(object.point_light.?.color.x, object.point_light.?.color.y, object.point_light.?.color.z, object.point_light.?.intensity), .radius = object.transform.object_scale.x };
            self.gc.*.vkd.cmdPushConstants(frame_info.command_buffer, self.pipeline_layout, .{ .vertex_bit = true, .fragment_bit = true }, 0, @sizeOf(PointLightPushConstant), @ptrCast(&push));
            self.gc.vkd.cmdDraw(frame_info.command_buffer, 6, 1, 0, 0);
        }
    }
};
