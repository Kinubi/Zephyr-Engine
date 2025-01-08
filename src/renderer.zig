const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("graphics_context.zig").GraphicsContext;
const Scene = @import("scene.zig").Scene;
const Pipeline = @import("pipeline.zig").Pipeline;
const ShaderLibrary = @import("shader.zig").ShaderLibrary;
const Math = @import("mach").math;

const SimplePushConstantData = struct {
    transform: Math.Mat2x2 = Math.Mat2x2.ident,
    offset: Math.Vec2 = Math.Vec2.init(0.0, 0.0),
    color: Math.Vec3 align(@alignOf(f16)) = Math.Vec3.init(0.0, 0.0, 0.0),
};

pub const SimpleRenderer = struct {
    scene: Scene = undefined,
    pipeline: Pipeline = undefined,
    gc: *GraphicsContext = undefined,
    pipeline_layout: vk.PipelineLayout = undefined,

    pub fn init(gc: *GraphicsContext, render_pass: vk.RenderPass, scene: Scene, shader_library: ShaderLibrary, alloc: std.mem.Allocator) !SimpleRenderer {
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
        return SimpleRenderer{ .scene = scene, .pipeline = pipeline, .gc = gc, .pipeline_layout = layout };
    }

    pub fn render(self: *@This(), cmdbuf: vk.CommandBuffer, dt: f64) !void {
        self.gc.*.vkd.cmdBindPipeline(cmdbuf, .graphics, self.pipeline.pipeline);
        for (self.scene.objects.slice()) |*object| {
            const offset_mult = Math.Vec2.init(0.1, 0.1).mulScalar(@floatCast(dt));
            object.transform.offset = object.transform.offset.add(&offset_mult);

            const push = SimplePushConstantData{ .offset = object.transform.offset, .color = Math.Vec3.init(0.3, 0.2, 0.5) };

            self.gc.*.vkd.cmdPushConstants(cmdbuf, self.pipeline_layout, .{ .vertex_bit = true, .fragment_bit = true }, 0, @sizeOf(SimplePushConstantData), @ptrCast(&push));
        }
        try self.scene.render(self.gc.*, cmdbuf);
    }
};
