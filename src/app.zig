const std = @import("std");
const Window = @import("window.zig").Window;
const glfw = @import("mach-glfw");
const Pipeline = @import("pipeline.zig").Pipeline;
const simple_vert align(@alignOf(u32)) = @embedFile("simple_vert").*;
const simple_frag align(@alignOf(u32)) = @embedFile("simple_frag").*;
const GraphicsContext = @import("graphics_context.zig").GraphicsContext;
const Swapchain = @import("swapchain.zig").Swapchain;
const vk = @import("vulkan");
const ShaderLibrary = @import("shader.zig").ShaderLibrary;
const Vertex = @import("mesh.zig").Vertex;
const Mesh = @import("mesh.zig").Mesh;
const Model = @import("mesh.zig").Model;
const Scene = @import("scene.zig").Scene;
const SimpleRenderer = @import("renderer.zig").SimpleRenderer;
const Math = @import("mach").math;
const Camera = @import("camera.zig").Camera;

pub const App = struct {
    window: Window = undefined,

    gc: GraphicsContext = undefined,
    allocator: std.mem.Allocator = undefined,
    var current_frame: u32 = 0;
    var swapchain: Swapchain = undefined;
    var cmdbufs: []vk.CommandBuffer = undefined;
    var simple_renderer: SimpleRenderer = undefined;
    var last_frame_time: f64 = undefined;
    var camera: Camera = undefined;

    //var model: Model = undefined;

    pub fn init(self: *@This()) !void {
        self.window = try Window.init(.{ .width = 1280, .height = 720 });

        self.allocator = std.heap.page_allocator;

        self.gc = try GraphicsContext.init(self.allocator, self.window.window_props.title, self.window.window.?);
        std.log.debug("Using device: {s}", .{self.gc.deviceName()});
        swapchain = try Swapchain.init(&self.gc, self.allocator, .{ .width = self.window.window_props.width, .height = self.window.window_props.height });

        try swapchain.createRenderPass();

        var shader_library = ShaderLibrary.init(self.gc, self.allocator);

        try shader_library.add(&.{ &simple_frag, &simple_vert }, &.{ vk.ShaderStageFlags{ .fragment_bit = true }, vk.ShaderStageFlags{ .vertex_bit = true } });

        try swapchain.createFramebuffers();
        try self.gc.createCommandPool();

        var mesh = Mesh.init(self.allocator);
        try mesh.vertices.appendSlice(&.{
            // Back Face
            Vertex{ .pos = .{ -0.5, -0.5, -0.5 }, .color = .{ 0.1, 0.1, 0.8 } },
            Vertex{ .pos = .{ 0.5, 0.5, -0.5 }, .color = .{ 0.1, 0.1, 0.8 } },
            Vertex{ .pos = .{ -0.5, 0.5, -0.5 }, .color = .{ 0.1, 0.1, 0.8 } },
            Vertex{ .pos = .{ -0.5, -0.5, -0.5 }, .color = .{ 0.1, 0.1, 0.8 } },
            Vertex{ .pos = .{ 0.5, -0.5, -0.5 }, .color = .{ 0.1, 0.1, 0.8 } },
            Vertex{ .pos = .{ 0.5, 0.5, -0.5 }, .color = .{ 0.1, 0.1, 0.8 } },
            // Front Face
            Vertex{ .pos = .{ -0.5, -0.5, 0.5 }, .color = .{ 0.1, 0.8, 0.1 } },
            Vertex{ .pos = .{ 0.5, 0.5, 0.5 }, .color = .{ 0.1, 0.8, 0.1 } },
            Vertex{ .pos = .{ -0.5, 0.5, 0.5 }, .color = .{ 0.1, 0.8, 0.1 } },
            Vertex{ .pos = .{ -0.5, -0.5, 0.5 }, .color = .{ 0.1, 0.8, 0.1 } },
            Vertex{ .pos = .{ 0.5, -0.5, 0.5 }, .color = .{ 0.1, 0.8, 0.1 } },
            Vertex{ .pos = .{ 0.5, 0.5, 0.5 }, .color = .{ 0.1, 0.8, 0.1 } },
            // Left Face
            Vertex{ .pos = .{ -0.5, -0.5, -0.5 }, .color = .{ 0.9, 0.9, 0.9 } },
            Vertex{ .pos = .{ -0.5, 0.5, 0.5 }, .color = .{ 0.9, 0.9, 0.9 } },
            Vertex{ .pos = .{ -0.5, -0.5, 0.5 }, .color = .{ 0.9, 0.9, 0.9 } },
            Vertex{ .pos = .{ -0.5, -0.5, -0.5 }, .color = .{ 0.9, 0.9, 0.9 } },
            Vertex{ .pos = .{ -0.5, 0.5, -0.5 }, .color = .{ 0.9, 0.9, 0.9 } },
            Vertex{ .pos = .{ -0.5, 0.5, 0.5 }, .color = .{ 0.9, 0.9, 0.9 } },

            // Right face (yellow)
            Vertex{ .pos = .{ 0.5, -0.5, -0.5 }, .color = .{ 0.8, 0.8, 0.1 } },
            Vertex{ .pos = .{ 0.5, 0.5, 0.5 }, .color = .{ 0.8, 0.8, 0.1 } },
            Vertex{ .pos = .{ 0.5, -0.5, 0.5 }, .color = .{ 0.8, 0.8, 0.1 } },
            Vertex{ .pos = .{ 0.5, -0.5, -0.5 }, .color = .{ 0.8, 0.8, 0.1 } },
            Vertex{ .pos = .{ 0.5, 0.5, -0.5 }, .color = .{ 0.8, 0.8, 0.1 } },
            Vertex{ .pos = .{ 0.5, 0.5, 0.5 }, .color = .{ 0.8, 0.8, 0.1 } },

            // Top face (orange, remember y axis points down)
            Vertex{ .pos = .{ -0.5, -0.5, -0.5 }, .color = .{ 0.9, 0.6, 0.1 } },
            Vertex{ .pos = .{ 0.5, -0.5, 0.5 }, .color = .{ 0.9, 0.6, 0.1 } },
            Vertex{ .pos = .{ -0.5, -0.5, 0.5 }, .color = .{ 0.9, 0.6, 0.1 } },
            Vertex{ .pos = .{ -0.5, -0.5, -0.5 }, .color = .{ 0.9, 0.6, 0.1 } },
            Vertex{ .pos = .{ 0.5, -0.5, -0.5 }, .color = .{ 0.9, 0.6, 0.1 } },
            Vertex{ .pos = .{ 0.5, -0.5, 0.5 }, .color = .{ 0.9, 0.6, 0.1 } },

            // Bottom face (red)
            Vertex{ .pos = .{ -0.5, 0.5, -0.5 }, .color = .{ 0.8, 0.1, 0.1 } },
            Vertex{ .pos = .{ 0.5, 0.5, 0.5 }, .color = .{ 0.8, 0.1, 0.1 } },
            Vertex{ .pos = .{ -0.5, 0.5, 0.5 }, .color = .{ 0.8, 0.1, 0.1 } },
            Vertex{ .pos = .{ -0.5, 0.5, -0.5 }, .color = .{ 0.8, 0.1, 0.1 } },
            Vertex{ .pos = .{ 0.5, 0.5, -0.5 }, .color = .{ 0.8, 0.1, 0.1 } },
            Vertex{ .pos = .{ 0.5, 0.5, 0.5 }, .color = .{ 0.8, 0.1, 0.1 } },
        });

        try mesh.createVertexBuffers(&self.gc);

        const model = Model.init(mesh);

        var scene = Scene.init();

        const object = try scene.addObject(model);
        object.*.transform.scale(Math.Vec3.init(0.5, 0.5, 0.5));
        object.*.transform.translate(Math.Vec3.init(0, 0, 2));
        cmdbufs = try self.gc.createCommandBuffers(
            self.allocator,
        );

        camera = Camera{ .fov = 75.0, .window = self.window };
        std.debug.print("Camera projection transform: {any}\n", .{camera.projectionMatrix.v});

        camera.setOrthographicProjection(-1, 1, -1, 1, -1, 1);

        simple_renderer = try SimpleRenderer.init(@constCast(&self.gc), swapchain.render_pass, scene, shader_library, self.allocator, @constCast(&camera));

        last_frame_time = glfw.getTime();
    }

    pub fn onUpdate(self: *@This()) !bool {
        const current_time = glfw.getTime();
        const dt = current_time - last_frame_time;
        const cmdbuf = cmdbufs[current_frame];
        try swapchain.beginFrame(cmdbufs, .{ .width = self.window.window.?.getSize().width, .height = self.window.window.?.getSize().height }, current_frame);
        swapchain.beginSwapChainRenderPass(cmdbufs, current_frame);
        try simple_renderer.render(cmdbuf, dt);

        swapchain.endSwapChainRenderPass(cmdbuf);
        try swapchain.endFrame(cmdbuf, &current_frame, .{ .width = self.window.window.?.getSize().width, .height = self.window.window.?.getSize().height });
        last_frame_time = current_time;

        return self.window.isRunning();
    }

    pub fn deinit(self: @This()) void {
        try swapchain.waitForAllFences();
        self.gc.destroyCommandBuffers(cmdbufs, self.allocator);
        simple_renderer.deinit();

        swapchain.deinit();
        self.gc.deinit();
        self.window.deinit();
    }
};
