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
    swapchain: Swapchain = undefined,
    gc: GraphicsContext = undefined,
    allocator: std.mem.Allocator = undefined,
    var simple_pipeline: ?Pipeline = undefined;
    var buffer: vk.Buffer = undefined;

    pub fn init(self: *@This(), allocator: std.mem.Allocator) !void {
        self.window = try Window.init(.{});

        self.allocator = allocator;

        self.gc = try GraphicsContext.init(self.allocator, self.window.window_props.title, self.window.window.?);
        std.log.debug("Using device: {s}", .{self.gc.deviceName()});
        self.swapchain = try Swapchain.init(&self.gc, self.allocator, .{ .width = self.window.window_props.width, .height = self.window.window_props.height });

        try self.swapchain.createRenderPass();

        var shader_library = ShaderLibrary.init(self.gc, self.allocator);

        try shader_library.add(&.{ &simple_frag, &simple_vert }, &.{ vk.ShaderStageFlags{ .fragment_bit = true }, vk.ShaderStageFlags{ .vertex_bit = true } });

        simple_pipeline = try Pipeline.init(self.gc, self.swapchain.render_pass, shader_library, try Pipeline.defaultLayout(self.gc), self.allocator);

        try self.swapchain.createFramebuffers();
        try self.gc.createCommandPool();

        var mesh = Mesh.init(allocator);
        try mesh.vertices.appendSlice(&.{
            Vertex{ .pos = .{ 0, -0.5 }, .color = .{ 1, 0, 0 } },
            Vertex{ .pos = .{ 0.5, 0.5 }, .color = .{ 0, 1, 0 } },
            Vertex{ .pos = .{ -0.5, 0.5 }, .color = .{ 0, 0, 1 } },
        });

        buffer = try self.gc.createBuffer(@sizeOf(Vertex) * mesh.vertices.items.len, .{ .transfer_dst_bit = true, .vertex_buffer_bit = true }, .{ .device_local_bit = true });

        try mesh.uploadVertices(&self.gc, buffer);

        const cmdbufs = try self.gc.createCommandBuffers();

        try self.gc.beginSwapChainRenderPass(cmdbufs[i], self.swapchain.framebuffers, self.swapchain.extent);
        try mesh.draw(self.gc, cmdbufs[i], buffer);
        self.gc.endSwapChainRenderPass(cmdbufs[i]);
    }

    pub fn onUpdate(self: @This()) bool {
        return self.window.isRunning();
    }

    pub fn deinit(self: @This()) void {
        simple_pipeline.?.deinit();
        self.gc.vkd.destroyBuffer(self.gc.dev, buffer, null);
        self.swapchain.deinit();
        self.gc.deinit();
        self.window.deinit();
    }
};
