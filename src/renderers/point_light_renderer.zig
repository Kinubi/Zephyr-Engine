// PointLightRenderer moved from renderer.zig
const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("../core/graphics_context.zig").GraphicsContext;
const Scene = @import("../scene/scene.zig").Scene;
const Pipeline = @import("../core/pipeline.zig").Pipeline;
const ShaderLibrary = @import("../core/shader.zig").ShaderLibrary;
const Math = @import("../utils/math.zig");
const Camera = @import("../rendering/camera.zig").Camera;
const FrameInfo = @import("../rendering/frameinfo.zig").FrameInfo;
const GlobalUbo = @import("../rendering/frameinfo.zig").GlobalUbo;
const RenderSystem = @import("../systems/render_system.zig").RenderSystem;
const DynamicPipelineManager = @import("../rendering/dynamic_pipeline_manager.zig").DynamicPipelineManager;
const log = @import("../utils/log.zig").log;

pub const PointLightPushConstant = struct {
    position: Math.Vec4 = Math.Vec4.init(0, 0, 0, 1),
    color: Math.Vec4 = Math.Vec4.init(1, 1, 1, 1),
    radius: f32 = 1.0,
};

pub const PointLightRenderer = struct {
    scene: *Scene = undefined,
    pipeline_manager: *DynamicPipelineManager,
    gc: *GraphicsContext = undefined,
    camera: *Camera = undefined,
    pipeline_name: []const u8 = "point_light_renderer",
    render_pass: vk.RenderPass,

    pub fn init(gc: *GraphicsContext, render_pass: vk.RenderPass, scene: *Scene, shader_library: ShaderLibrary, alloc: std.mem.Allocator, camera: *Camera, global_set_layout: vk.DescriptorSetLayout, pipeline_manager: *DynamicPipelineManager) !PointLightRenderer {
        _ = shader_library; // No longer needed, using dynamic pipelines
        _ = alloc; // No longer needed for pipeline creation
        _ = global_set_layout; // No longer needed for pipeline creation
        
        return PointLightRenderer{ 
            .scene = scene, 
            .pipeline_manager = pipeline_manager,
            .gc = gc, 
            .camera = camera,
            .render_pass = render_pass,
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

    pub fn deinit(self: *PointLightRenderer) void {
        // Pipeline is managed by DynamicPipelineManager, no cleanup needed
        _ = self;
    }

    pub fn render(self: *PointLightRenderer, frame_info: FrameInfo) !void {
        // Get dynamic pipeline
        const pipeline = self.pipeline_manager.getPipeline(self.pipeline_name, self.render_pass) catch |err| {
            log(.ERROR, "point_light_renderer", "Failed to get pipeline: {}", .{err});
            return;
        };
        
        const pipeline_layout = self.pipeline_manager.getPipelineLayout(self.pipeline_name);
        
        if (pipeline == null or pipeline_layout == null) {
            log(.WARN, "point_light_renderer", "Pipeline or layout not available", .{});
            return;
        }

        // Bind dynamic pipeline
        self.gc.*.vkd.cmdBindPipeline(frame_info.command_buffer, .graphics, pipeline.?);
        
        // Bind descriptor sets
        self.gc.vkd.cmdBindDescriptorSets(frame_info.command_buffer, .graphics, pipeline_layout.?, 0, 1, @ptrCast(&frame_info.global_descriptor_set), 0, null);
        
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
            
            self.gc.*.vkd.cmdPushConstants(frame_info.command_buffer, pipeline_layout.?, .{ .vertex_bit = true, .fragment_bit = true }, 0, @sizeOf(PointLightPushConstant), @ptrCast(&push));
            self.gc.vkd.cmdDraw(frame_info.command_buffer, 6, 1, 0, 0);
        }
    }
};
