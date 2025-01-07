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
const Vertex = @import("renderer.zig").Vertex;
const Mesh = @import("renderer.zig").Mesh;

pub const App = struct {
    window: Window = undefined,

    gc: GraphicsContext = undefined,
    allocator: std.mem.Allocator = undefined,
    var current_frame: u32 = 0;
    var swapchain: Swapchain = undefined;
    var simple_pipeline: ?Pipeline = undefined;
    var buffer: vk.Buffer = undefined;
    var cmdbufs: []vk.CommandBuffer = undefined;
    var mesh: Mesh = undefined;
    var memory: vk.DeviceMemory = undefined;

    pub fn init(self: *@This()) !void {
        self.window = try Window.init(.{});

        self.allocator = std.heap.page_allocator;

        self.gc = try GraphicsContext.init(self.allocator, self.window.window_props.title, self.window.window.?);
        std.log.debug("Using device: {s}", .{self.gc.deviceName()});
        swapchain = try Swapchain.init(&self.gc, self.allocator, .{ .width = self.window.window_props.width, .height = self.window.window_props.height });

        try swapchain.createRenderPass();

        var shader_library = ShaderLibrary.init(self.gc, self.allocator);

        try shader_library.add(&.{ &simple_frag, &simple_vert }, &.{ vk.ShaderStageFlags{ .fragment_bit = true }, vk.ShaderStageFlags{ .vertex_bit = true } });

        simple_pipeline = try Pipeline.init(self.gc, swapchain.render_pass, shader_library, try Pipeline.defaultLayout(self.gc), self.allocator);

        try swapchain.createFramebuffers();
        try self.gc.createCommandPool();

        mesh = Mesh.init(self.allocator);
        try mesh.vertices.appendSlice(&.{
            Vertex{ .pos = .{ 0, -0.5 }, .color = .{ 1, 0, 0 } },
            Vertex{ .pos = .{ 0.5, 0.5 }, .color = .{ 0, 1, 0 } },
            Vertex{ .pos = .{ -0.5, 0.5 }, .color = .{ 0, 0, 1 } },
        });

        buffer = try self.gc.createBuffer(@sizeOf(Vertex) * mesh.vertices.items.len, .{ .transfer_dst_bit = true, .vertex_buffer_bit = true });
        const mem_reqs = self.gc.vkd.getBufferMemoryRequirements(self.gc.dev, buffer);
        memory = try self.gc.allocate(mem_reqs, .{ .device_local_bit = true });
        try self.gc.vkd.bindBufferMemory(self.gc.dev, buffer, memory, 0);

        try mesh.uploadVertices(&self.gc, buffer);

        cmdbufs = try self.gc.createCommandBuffers(
            self.allocator,
            swapchain.framebuffers,
        );
    }

    pub fn onUpdate(self: *@This()) !bool {
        const cmdbuf = cmdbufs[current_frame];
        try swapchain.beginFrame(cmdbufs, .{ .width = self.window.window.?.getSize().width, .height = self.window.window.?.getSize().height }, current_frame);
        swapchain.beginSwapChainRenderPass(cmdbufs, .{ .height = swapchain.extent.height, .width = swapchain.extent.width }, current_frame);
        self.gc.vkd.cmdBindPipeline(cmdbuf, .graphics, simple_pipeline.?.pipeline);
        mesh.draw(self.gc, cmdbuf, buffer);

        swapchain.endSwapChainRenderPass(cmdbuf);
        swapchain.endFrame(cmdbuf, &current_frame);

        return self.window.isRunning();
    }

    pub fn deinit(self: @This()) void {
        try swapchain.waitForAllFences();
        self.gc.destroyCommandBuffers(cmdbufs, self.allocator);
        self.gc.vkd.freeMemory(self.gc.dev, memory, null);
        self.gc.vkd.destroyBuffer(self.gc.dev, buffer, null);
        simple_pipeline.?.deinit();
        swapchain.deinit();
        self.gc.deinit();
        self.window.deinit();
    }
};
