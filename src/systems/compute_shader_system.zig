const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("../core/graphics_context.zig").GraphicsContext;
const Swapchain = @import("../core/swapchain.zig").Swapchain;
const FrameInfo = @import("../rendering/frameinfo.zig").FrameInfo;
const MAX_FRAMES_IN_FLIGHT = @import("../core/swapchain.zig").MAX_FRAMES_IN_FLIGHT;

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

    /// Dispatch a compute shader with the given pipeline and descriptor set abstraction.
    /// - pipeline: expects .pipeline and .pipeline_layout fields
    /// - descriptor_set: expects .descriptor_set field
    /// - frame_info: FrameInfo for the current frame
    /// - group_counts: [3]u32 for x, y, z group counts
    pub fn dispatch(
        self: *ComputeShaderSystem,
        pipeline: anytype, // expects .pipeline and .pipeline_layout fields
        descriptor_set: anytype, // expects .descriptor_set field
        frame_info: FrameInfo,
        group_counts: [3]u32,
    ) void {
        self.gc.vkd.cmdBindPipeline(frame_info.compute_buffer, vk.PipelineBindPoint.compute, pipeline.pipeline);
        self.gc.vkd.cmdBindDescriptorSets(
            frame_info.compute_buffer,
            vk.PipelineBindPoint.compute,
            pipeline.pipeline_layout,
            0,
            1,
            @ptrCast(&descriptor_set.descriptor_set),
            0,
            null,
        );
        self.gc.vkd.cmdDispatch(
            frame_info.compute_buffer,
            group_counts[0],
            group_counts[1],
            group_counts[2],
        );
    }

    pub fn deinit(self: *ComputeShaderSystem) void {
        self.gc.destroyCommandBuffers(self.compute_bufs, self.allocator);
    }
};
