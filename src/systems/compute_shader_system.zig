const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("../graphics_context.zig").GraphicsContext;

/// Compute shader system for managing compute pipelines and command buffers.
pub const ComputeShaderSystem = struct {
    device: *GraphicsContext,
    pipeline: vk.Pipeline = undefined,
    pipeline_layout: vk.PipelineLayout = undefined,
    descriptor_set_layout: vk.DescriptorSetLayout = undefined,
    command_buffers: []vk.CommandBuffer = &.{},
    current_frame_index: usize = 0,
    is_dispatched: bool = false,

    pub fn init(
        device: *GraphicsContext,
        shader_module: vk.ShaderModule,
        descriptor_set_layout: vk.DescriptorSetLayout,
        command_pool: vk.CommandPool,
        frame_count: usize,
    ) !ComputeShaderSystem {
        var self = ComputeShaderSystem{
            .device = device,
            .descriptor_set_layout = descriptor_set_layout,
        };
        // Create pipeline layout
        var pipeline_layout_info = vk.PipelineLayoutCreateInfo{
            .sType = vk.STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .setLayoutCount = 1,
            .pSetLayouts = &descriptor_set_layout,
            .pushConstantRangeCount = 0,
            .pPushConstantRanges = null,
        };
        if (vk.createPipelineLayout(device.dev, &pipeline_layout_info, null, &self.pipeline_layout) != vk.SUCCESS) {
            return error.PipelineLayoutCreationFailed;
        }
        // Create compute pipeline
        var stage_info = vk.PipelineShaderStageCreateInfo{
            .sType = vk.STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .stage = vk.SHADER_STAGE_COMPUTE_BIT,
            .module = shader_module,
            .pName = "main",
        };
        var pipeline_info = vk.ComputePipelineCreateInfo{
            .sType = vk.STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
            .stage = stage_info,
            .layout = self.pipeline_layout,
        };
        if (vk.createComputePipelines(device.dev, null, 1, &pipeline_info, null, &self.pipeline) != vk.SUCCESS) {
            return error.PipelineCreationFailed;
        }
        // Allocate command buffers
        var alloc_info = vk.CommandBufferAllocateInfo{
            .sType = vk.STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .commandPool = command_pool,
            .level = vk.COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = @intCast(u32, frame_count),
        };
        self.command_buffers = try device.allocator.alloc(vk.CommandBuffer, frame_count);
        if (vk.allocateCommandBuffers(device.dev, &alloc_info, self.command_buffers.ptr) != vk.SUCCESS) {
            return error.CommandBufferAllocationFailed;
        }
        return self;
    }

    pub fn begin(self: *ComputeShaderSystem) vk.CommandBuffer {
        std.debug.assert(!self.is_dispatched);
        self.is_dispatched = true;
        const cmd = self.command_buffers[self.current_frame_index];
        var begin_info = vk.CommandBufferBeginInfo{
            .sType = vk.STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        };
        _ = vk.beginCommandBuffer(cmd, &begin_info);
        return cmd;
    }

    pub fn end(self: *ComputeShaderSystem) vk.CommandBuffer {
        std.debug.assert(self.is_dispatched);
        const cmd = self.command_buffers[self.current_frame_index];
        _ = vk.endCommandBuffer(cmd);
        self.is_dispatched = false;
        self.current_frame_index = (self.current_frame_index + 1) % self.command_buffers.len;
        return cmd;
    }

    pub fn dispatch(self: *ComputeShaderSystem, cmd: vk.CommandBuffer, descriptor_set: vk.DescriptorSet, x: u32, y: u32, z: u32) void {
        vk.cmdBindPipeline(cmd, vk.PIPELINE_BIND_POINT_COMPUTE, self.pipeline);
        vk.cmdBindDescriptorSets(cmd, vk.PIPELINE_BIND_POINT_COMPUTE, self.pipeline_layout, 0, 1, &descriptor_set, 0, null);
        vk.cmdDispatch(cmd, x, y, z);
    }

    pub fn deinit(self: *ComputeShaderSystem) void {
        if (self.pipeline != undefined) vk.destroyPipeline(self.device.dev, self.pipeline, null);
        if (self.pipeline_layout != undefined) vk.destroyPipelineLayout(self.device.dev, self.pipeline_layout, null);
        if (self.command_buffers.len > 0) self.device.allocator.free(self.command_buffers);
    }
};
