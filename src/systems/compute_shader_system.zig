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
    frame_count: usize = 0,
    command_pool: vk.CommandPool = undefined,

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
            .frame_count = frame_count,
            .command_pool = command_pool,
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
        const stage_info = vk.PipelineShaderStageCreateInfo{
            .sType = vk.STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .stage = vk.SHADER_STAGE_COMPUTE_BIT,
            .module = shader_module,
            .pName = "main",
        };
        const pipeline_info = vk.ComputePipelineCreateInfo{
            .sType = vk.STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
            .stage = stage_info,
            .layout = self.pipeline_layout,
        };
        if (vk.createComputePipelines(device.dev, null, 1, &pipeline_info, null, &self.pipeline) != vk.SUCCESS) {
            return error.PipelineCreationFailed;
        }
        try self.createCommandBuffers();
        return self;
    }

    fn createCommandBuffers(self: *ComputeShaderSystem) !void {
        var alloc_info = vk.CommandBufferAllocateInfo{
            .sType = vk.STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .commandPool = self.command_pool,
            .level = vk.COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = @intCast(self.frame_count),
        };
        self.command_buffers = try self.device.allocator.alloc(vk.CommandBuffer, self.frame_count);
        if (vk.allocateCommandBuffers(self.device.dev, &alloc_info, self.command_buffers.ptr) != vk.SUCCESS) {
            return error.CommandBufferAllocationFailed;
        }
    }

    fn freeCommandBuffers(self: *ComputeShaderSystem) void {
        if (self.command_buffers.len > 0) {
            vk.freeCommandBuffers(
                self.device.dev,
                self.command_pool,
                @intCast(self.command_buffers.len),
                self.command_buffers.ptr,
            );
            self.device.allocator.free(self.command_buffers);
            self.command_buffers = &.{};
        }
    }

    pub fn beginCompute(self: *ComputeShaderSystem) vk.CommandBuffer {
        std.debug.assert(!self.is_dispatched);
        self.is_dispatched = true;
        const cmd = self.command_buffers[self.current_frame_index];
        var begin_info = vk.CommandBufferBeginInfo{
            .sType = vk.STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        };
        if (vk.beginCommandBuffer(cmd, &begin_info) != vk.SUCCESS) {
            @panic("failed to begin recording command buffer!");
        }
        return cmd;
    }

    pub fn endCompute(self: *ComputeShaderSystem) vk.CommandBuffer {
        std.debug.assert(self.is_dispatched);
        const cmd = self.command_buffers[self.current_frame_index];
        if (vk.endCommandBuffer(cmd) != vk.SUCCESS) {
            @panic("failed to record command buffer!");
        }
        self.is_dispatched = false;
        self.current_frame_index = (self.current_frame_index + 1) % self.frame_count;
        return cmd;
    }

    pub fn dispatchCompute(self: *ComputeShaderSystem, cmd: vk.CommandBuffer, descriptor_set: vk.DescriptorSet, x: u32, y: u32, z: u32) void {
        vk.cmdBindPipeline(cmd, vk.PIPELINE_BIND_POINT_COMPUTE, self.pipeline);
        vk.cmdBindDescriptorSets(cmd, vk.PIPELINE_BIND_POINT_COMPUTE, self.pipeline_layout, 0, 1, &descriptor_set, 0, null);
        vk.cmdDispatch(cmd, x, y, z);
    }

    pub fn deinit(self: *ComputeShaderSystem) void {
        if (self.pipeline != undefined) vk.destroyPipeline(self.device.dev, self.pipeline, null);
        if (self.pipeline_layout != undefined) vk.destroyPipelineLayout(self.device.dev, self.pipeline_layout, null);
        self.freeCommandBuffers();
    }
};
