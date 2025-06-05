const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("../graphics_context.zig").GraphicsContext;
const FrameInfo = @import("../frameinfo.zig").FrameInfo;
const MAX_FRAMES_IN_FLIGHT = @import("../swapchain.zig").MAX_FRAMES_IN_FLIGHT;

/// Compute shader system for managing compute pipelines and command buffers.
pub const ComputeShaderSystem = struct {
    gc: *GraphicsContext, // Use 'gc' for consistency with RaytracingSystem
    pipeline: vk.Pipeline = undefined,
    pipeline_layout: vk.PipelineLayout = undefined,
    descriptor_set_layout: vk.DescriptorSetLayout = undefined,
    command_buffers: []vk.CommandBuffer = &.{},
    is_dispatched: bool = false,
    frame_count: usize = MAX_FRAMES_IN_FLIGHT,
    command_pool: vk.CommandPool = undefined,
    allocator: ?std.mem.Allocator = null,

    pub fn init(
        gc: *GraphicsContext,
        shader_module: vk.ShaderModule,
        descriptor_set_layout: vk.DescriptorSetLayout,
        command_pool: vk.CommandPool,
        allocator: std.mem.Allocator,
    ) !ComputeShaderSystem {
        var self = ComputeShaderSystem{
            .gc = gc,
            .descriptor_set_layout = descriptor_set_layout,
            .command_pool = command_pool,
            .allocator = allocator,
        };
        // Create pipeline layout (idiomatic: use gc.vkd)
        var pipeline_layout_info = vk.PipelineLayoutCreateInfo{
            .sType = vk.STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .setLayoutCount = 1,
            .pSetLayouts = &descriptor_set_layout,
            .pushConstantRangeCount = 0,
            .pPushConstantRanges = null,
        };

        return self;
    }

    pub fn dispatchCompute(self: *ComputeShaderSystem, frame_info: FrameInfo, descriptor_set: vk.DescriptorSet, x: u32, y: u32, z: u32) void {
        const cmd = self.command_buffers[frame_info.current_frame];
        self.gc.vkd.cmdBindPipeline(cmd, vk.PIPELINE_BIND_POINT_COMPUTE, self.pipeline);
        self.gc.vkd.cmdBindDescriptorSets(cmd, vk.PIPELINE_BIND_POINT_COMPUTE, self.pipeline_layout, 0, 1, &descriptor_set, 0, null);
        self.gc.vkd.cmdDispatch(cmd, x, y, z);
    }

    pub fn deinit(self: *ComputeShaderSystem) void {
        if (self.pipeline != undefined) self.gc.vkd.destroyPipeline(self.gc.dev, self.pipeline, null);
        if (self.pipeline_layout != undefined) self.gc.vkd.destroyPipelineLayout(self.gc.dev, self.pipeline_layout, null);
        self.freeCommandBuffers();
    }
};
