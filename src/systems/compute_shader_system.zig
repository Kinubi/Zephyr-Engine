const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("../graphics_context.zig").GraphicsContext;
const Swapchain = @import("../swapchain.zig").Swapchain;
const FrameInfo = @import("../frameinfo.zig").FrameInfo;
const MAX_FRAMES_IN_FLIGHT = @import("../swapchain.zig").MAX_FRAMES_IN_FLIGHT;

/// Compute shader system for managing compute pipelines and command buffers.
pub const ComputeShaderSystem = struct {
    gc: *GraphicsContext,
    is_dispatched: bool = false,
    swapchain: *Swapchain = undefined,
    compute_bufs: []vk.CommandBuffer = undefined,
    allocator: std.mem.Allocator = undefined,

    pub fn init(
        gc: *GraphicsContext,
        swapchain: *Swapchain,
        allocator: std.mem.Allocator,
    ) !ComputeShaderSystem {
        var self = ComputeShaderSystem{
            .gc = gc,
            .swapchain = swapchain,
            .allocator = allocator,
        };
        try self.createCommandBuffers();
        self.swapchain.compute = true;
        return self;
    }

    fn createCommandBuffers(self: *ComputeShaderSystem) !void {
        self.compute_bufs = self.gc.createCommandBuffers(self.allocator) catch |err| {
            return err;
        };
    }

    fn freeCommandBuffers(self: *ComputeShaderSystem) void {
        if (self.command_buffers.len > 0) {
            self.gc.vkd.freeCommandBuffers(
                self.gc.dev,
                self.command_pool,
                @intCast(self.command_buffers.len),
                self.command_buffers.ptr,
            );
            self.allocator.?.free(self.command_buffers);
            self.command_buffers = &.{};
        }
    }

    pub fn beginCompute(self: *ComputeShaderSystem, frame_info: FrameInfo) void {
        self.swapchain.beginComputePass(frame_info) catch |err| {
            std.debug.print("Failed to begin compute pass: {}\n", .{err});
            return;
        };
    }

    pub fn endCompute(self: *ComputeShaderSystem, frame_info: FrameInfo) void {
        self.swapchain.endComputePass(frame_info) catch |err| {
            std.debug.print("Failed to end compute pass: {}\n", .{err});
            return;
        };
    }

    pub fn deinit(self: *ComputeShaderSystem) void {
        if (self.pipeline != undefined) self.gc.vkd.destroyPipeline(self.gc.dev, self.pipeline, null);
        if (self.pipeline_layout != undefined) self.gc.vkd.destroyPipelineLayout(self.gc.dev, self.pipeline_layout, null);
        self.freeCommandBuffers();
    }
};
