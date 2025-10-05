const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("../core/graphics_context.zig").GraphicsContext;
const Pipeline = @import("../core/pipeline.zig").Pipeline;
const ShaderLibrary = @import("../core/shader.zig").ShaderLibrary;
const Math = @import("../utils/math.zig");
const Camera = @import("../rendering/camera.zig").Camera;
const FrameInfo = @import("../rendering/frameinfo.zig").FrameInfo;
const ForwardRenderPassDescriptors = @import("../rendering/render_pass_descriptors.zig").ForwardRenderPassDescriptors;
const RasterizationData = @import("../rendering/scene_view.zig").RasterizationData;
const DynamicPipelineManager = @import("../rendering/dynamic_pipeline_manager.zig").DynamicPipelineManager;
const log = @import("../utils/log.zig").log;

pub const TexturedPushConstantData = extern struct {
    transform: [16]f32 = Math.Mat4x4.identity().data,
    normal_matrix: [16]f32 = Math.Mat4x4.identity().data,
    material_index: u32 = 0,
};

/// Textured renderer that supports materials and textures with dynamic pipelines
pub const TexturedRenderer = struct {
    gc: *GraphicsContext,
    pipeline_manager: *DynamicPipelineManager,
    descriptors: ForwardRenderPassDescriptors,
    allocator: std.mem.Allocator,
    pipeline_name: []const u8 = "textured_renderer",
    render_pass: vk.RenderPass,

    pub fn init(
        gc: *GraphicsContext,
        render_pass: vk.RenderPass,
        shader_library: ShaderLibrary,
        allocator: std.mem.Allocator,
        global_set_layout: vk.DescriptorSetLayout,
        pipeline_manager: *DynamicPipelineManager,
    ) !TexturedRenderer {
        _ = shader_library; // No longer needed, using dynamic pipelines
        _ = global_set_layout; // Used for descriptor setup but not pipeline creation
        
        // Initialize descriptor management
        const descriptors = try ForwardRenderPassDescriptors.init(gc, allocator);

        return TexturedRenderer{
            .gc = gc,
            .pipeline_manager = pipeline_manager,
            .descriptors = descriptors,
            .allocator = allocator,
            .render_pass = render_pass,
        };
    }

    pub fn deinit(self: *TexturedRenderer) void {
        // Only clean up descriptors, pipeline is managed by DynamicPipelineManager
        self.descriptors.deinit();
    }

    /// Update material data for current frame
    pub fn updateMaterialData(
        self: *TexturedRenderer,
        frame_index: u32,
        material_buffer_info: vk.DescriptorBufferInfo,
        texture_image_infos: []const vk.DescriptorImageInfo,
    ) !void {
        try self.descriptors.updateMaterialData(frame_index, material_buffer_info, texture_image_infos);
    }

    /// Render objects using materials and textures with dynamic pipelines
    pub fn render(self: *TexturedRenderer, frame_info: FrameInfo, raster_data: RasterizationData) !void {
        // Get dynamic pipeline
        const pipeline = self.pipeline_manager.getPipeline(self.pipeline_name, self.render_pass) catch |err| {
            log(.ERROR, "textured_renderer", "Failed to get pipeline: {}", .{err});
            return;
        };
        
        const pipeline_layout = self.pipeline_manager.getPipelineLayout(self.pipeline_name);
        
        if (pipeline == null or pipeline_layout == null) {
            log(.WARN, "textured_renderer", "Pipeline or layout not available", .{});
            return;
        }

        // Bind dynamic pipeline
        self.gc.vkd.cmdBindPipeline(frame_info.command_buffer, .graphics, pipeline.?);

        // Bind descriptor sets
        const descriptor_sets = [_]vk.DescriptorSet{
            frame_info.global_descriptor_set, // Set 0: Global
            self.descriptors.getMaterialDescriptorSet(frame_info.current_frame) orelse return, // Set 1: Material
        };

        self.gc.vkd.cmdBindDescriptorSets(
            frame_info.command_buffer,
            .graphics,
            pipeline_layout.?,
            0, // First set
            descriptor_sets.len,
            &descriptor_sets,
            0,
            null,
        );

        // Render each object
        for (raster_data.objects) |object| {
            if (!object.visible) continue;
            // std.log.info("  Object {d}: mesh ptr={x}", .{ i, @intFromPtr(object.mesh) });

            // Set up push constants with transform and material index
            const push_constants = TexturedPushConstantData{
                .transform = object.transform,
                .normal_matrix = object.transform, // TODO: Calculate proper normal matrix
                .material_index = object.material_index,
            };

            self.gc.vkd.cmdPushConstants(
                frame_info.command_buffer,
                pipeline_layout.?,
                .{ .vertex_bit = true, .fragment_bit = true },
                0,
                @sizeOf(TexturedPushConstantData),
                &push_constants,
            );

            object.mesh_handle.getMesh().draw(self.gc.*, frame_info.command_buffer);
        }
    }
};
