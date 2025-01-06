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
    var swapchain: Swapchain = undefined;
    var simple_pipeline: ?Pipeline = undefined;
    var buffer: vk.Buffer = undefined;
    var cmdbufs: []vk.CommandBuffer = undefined;
    var mesh: Mesh = undefined;

    pub fn init(self: *@This(), allocator: std.mem.Allocator) !void {
        self.window = try Window.init(.{});

        self.allocator = allocator;

        self.gc = try GraphicsContext.init(self.allocator, self.window.window_props.title, self.window.window.?);
        std.log.debug("Using device: {s}", .{self.gc.deviceName()});
        swapchain = try Swapchain.init(&self.gc, self.allocator, .{ .width = self.window.window_props.width, .height = self.window.window_props.height });

        try swapchain.createRenderPass();

        var shader_library = ShaderLibrary.init(self.gc, self.allocator);

        try shader_library.add(&.{ &simple_frag, &simple_vert }, &.{ vk.ShaderStageFlags{ .fragment_bit = true }, vk.ShaderStageFlags{ .vertex_bit = true } });

        simple_pipeline = try Pipeline.init(self.gc, swapchain.render_pass, shader_library, try Pipeline.defaultLayout(self.gc), self.allocator);

        try swapchain.createFramebuffers();
        try self.gc.createCommandPool();

        mesh = Mesh.init(allocator);
        try mesh.vertices.appendSlice(&.{
            Vertex{ .pos = .{ 0, -0.5 }, .color = .{ 1, 0, 0 } },
            Vertex{ .pos = .{ 0.5, 0.5 }, .color = .{ 0, 1, 0 } },
            Vertex{ .pos = .{ -0.5, 0.5 }, .color = .{ 0, 0, 1 } },
        });

        buffer = try self.gc.createBuffer(@sizeOf(Vertex) * mesh.vertices.items.len, .{ .transfer_dst_bit = true, .vertex_buffer_bit = true }, .{ .device_local_bit = true });

        try mesh.uploadVertices(&self.gc, buffer);

        cmdbufs = try self.gc.createCommandBuffers(swapchain.framebuffers, self.allocator);
    }

    pub fn onUpdate(self: @This()) !bool {
        std.debug.print("Presenting\n", .{});
        const image_index = swapchain.image_index;
        try self.gc.vkd.beginCommandBuffer(cmdbufs[image_index], &.{
            .flags = .{},
            .p_inheritance_info = null,
        });
        std.debug.print("Presenting harder\n", .{});
        try self.gc.beginSwapChainRenderPass(cmdbufs[image_index], swapchain.framebuffers[image_index], swapchain.render_pass, swapchain.extent);
        self.gc.vkd.cmdBindPipeline(cmdbufs[image_index], .graphics, simple_pipeline.?.pipeline);
        mesh.draw(self.gc, cmdbufs[image_index], buffer);
        try self.gc.endSwapChainRenderPass(cmdbufs[image_index]);
        std.debug.print("Presenting harder still\n", .{});
        const state = swapchain.present(cmdbufs[image_index]) catch |err| switch (err) {
            error.OutOfDateKHR => Swapchain.PresentState.suboptimal,
            else => |narrow| return narrow,
        };
        std.debug.print("Presenting harder even more {any}\n", .{state});

        if (state == .suboptimal) {
            std.debug.print("I am not worthy\n", .{});
            const size = self.window.window.?.getSize();
            try swapchain.recreate(.{ .width = size.width, .height = size.height });

            swapchain.destroyFramebuffers();
            try swapchain.createFramebuffers();

            self.gc.destroyCommandBuffers(cmdbufs, self.allocator);
            cmdbufs = try self.gc.createCommandBuffers(swapchain.framebuffers, self.allocator);
        }
        std.debug.print("Presenting the hardest", .{});
        return self.window.isRunning();
    }

    pub fn deinit(self: @This()) void {
        try swapchain.waitForAllFences();

        self.gc.destroyCommandBuffers(cmdbufs, self.allocator);
        simple_pipeline.?.deinit();
        self.gc.vkd.destroyBuffer(self.gc.dev, buffer, null);
        swapchain.deinit();
        self.gc.deinit();
        self.window.deinit();
    }
};
