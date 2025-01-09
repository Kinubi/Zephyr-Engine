const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("graphics_context.zig").GraphicsContext;
const Scene = @import("scene.zig").Scene;
const Pipeline = @import("pipeline.zig").Pipeline;
const ShaderLibrary = @import("shader.zig").ShaderLibrary;
const Math = @import("mach").math;
const glfw = @import("mach-glfw");
const Camera = @import("camera.zig").Camera;

const SimplePushConstantData = extern struct {
    projectionView: Math.Mat4x4 = Math.Mat4x4.ident,
    transform: Math.Mat4x4 = Math.Mat4x4.ident,
    color: Math.Vec3 = Math.Vec3.init(0.0, 0.0, 0.0),
};

pub const SimpleRenderer = struct {
    scene: Scene = undefined,
    pipeline: Pipeline = undefined,
    gc: *GraphicsContext = undefined,
    pipeline_layout: vk.PipelineLayout = undefined,
    camera: *Camera = undefined,

    pub fn init(gc: *GraphicsContext, render_pass: vk.RenderPass, scene: Scene, shader_library: ShaderLibrary, alloc: std.mem.Allocator, camera: *Camera) !SimpleRenderer {
        const pcr = [1]vk.PushConstantRange{.{ .stage_flags = .{ .vertex_bit = true, .fragment_bit = true }, .offset = 0, .size = @sizeOf(SimplePushConstantData) }};
        const layout = try gc.*.vkd.createPipelineLayout(
            gc.*.dev,
            &vk.PipelineLayoutCreateInfo{
                .flags = .{},
                .set_layout_count = 0,
                .p_set_layouts = null,
                .push_constant_range_count = 1,
                .p_push_constant_ranges = &pcr,
            },
            null,
        );
        const pipeline = try Pipeline.init(gc.*, render_pass, shader_library, try Pipeline.defaultLayout(layout), alloc);
        return SimpleRenderer{ .scene = scene, .pipeline = pipeline, .gc = gc, .pipeline_layout = layout, .camera = camera };
    }

    pub fn deinit(self: *SimpleRenderer) void {
        self.gc.*.vkd.destroyPipelineLayout(self.gc.*.dev, self.pipeline_layout, null);
        self.scene.deinit(self.gc.*);
        self.pipeline.deinit();
    }

    pub fn render(self: *@This(), cmdbuf: vk.CommandBuffer, dt: f64) !void {
        self.gc.*.vkd.cmdBindPipeline(cmdbuf, .graphics, self.pipeline.pipeline);

        const projectionView = Math.Mat4x4.mul(&self.camera.projectionMatrix, &self.camera.viewMatrix);
        for (self.scene.objects.slice()) |*object| {
            if (object.model == null) {
                continue;
            }
            // object.transform.rotate(Math.Quat.fromEuler(Math.degreesToRadians(0), @as(f32, @floatCast(dt)), 0.5 * @as(f32, @floatCast(dt))));
            //const color = Math.Vec3.init(Math.sin(@as(f32, @floatCast(glfw.getTime()))), Math.cos(@as(f32, @floatCast(glfw.getTime()))), Math.sin(@as(f32, @floatCast(glfw.getTime())) + @as(f32, 1.0)));
            _ = dt;
            const push = SimplePushConstantData{ .projectionView = projectionView, .transform = object.transform.local2world };

            self.gc.*.vkd.cmdPushConstants(cmdbuf, self.pipeline_layout, .{ .vertex_bit = true, .fragment_bit = true }, 0, @sizeOf(SimplePushConstantData), @ptrCast(&push));
        }
        try self.scene.render(self.gc.*, cmdbuf);
    }
};
