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
const log = @import("../utils/log.zig").log;

const TexturedPushConstantData = extern struct {
    transform: [16]f32 = Math.Mat4x4.identity().data,
    normal_matrix: [16]f32 = Math.Mat4x4.identity().data,
    material_index: u32 = 0,
};

/// Textured renderer that supports materials and textures
pub const TexturedRenderer = struct {
    gc: *GraphicsContext,
    pipeline: Pipeline,
    pipeline_layout: vk.PipelineLayout,
    descriptors: ForwardRenderPassDescriptors,
    allocator: std.mem.Allocator,

    pub fn init(
        gc: *GraphicsContext,
        render_pass: vk.RenderPass,
        shader_library: ShaderLibrary,
        allocator: std.mem.Allocator,
        global_set_layout: vk.DescriptorSetLayout,
    ) !TexturedRenderer {
        // Initialize descriptor management
        var descriptors = try ForwardRenderPassDescriptors.init(gc, allocator);

        // Create pipeline layout with both global and material descriptor sets
        const material_layout = descriptors.getMaterialDescriptorSetLayout() orelse return error.NoMaterialLayout;

        const descriptor_set_layouts = [_]vk.DescriptorSetLayout{
            global_set_layout, // Set 0: Global data
            material_layout, // Set 1: Material data
        };

        const push_constant_ranges = [_]vk.PushConstantRange{
            .{
                .stage_flags = .{ .vertex_bit = true, .fragment_bit = true },
                .offset = 0,
                .size = @sizeOf(TexturedPushConstantData),
            },
        };

        const pipeline_layout = try gc.vkd.createPipelineLayout(
            gc.dev,
            &vk.PipelineLayoutCreateInfo{
                .flags = .{},
                .set_layout_count = descriptor_set_layouts.len,
                .p_set_layouts = &descriptor_set_layouts,
                .push_constant_range_count = push_constant_ranges.len,
                .p_push_constant_ranges = &push_constant_ranges,
            },
            null,
        );

        // Create graphics pipeline
        const pipeline = try Pipeline.init(
            gc.*,
            render_pass,
            shader_library,
            pipeline_layout,
            try Pipeline.defaultLayout(pipeline_layout),
            allocator,
        );

        return TexturedRenderer{
            .gc = gc,
            .pipeline = pipeline,
            .pipeline_layout = pipeline_layout,
            .descriptors = descriptors,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TexturedRenderer) void {
        self.pipeline.deinit();
        self.gc.vkd.destroyPipelineLayout(self.gc.dev, self.pipeline_layout, null);
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

    /// Render objects using materials and textures
    pub fn render(self: *TexturedRenderer, frame_info: FrameInfo, raster_data: RasterizationData) !void {
        // Bind pipeline
        self.gc.vkd.cmdBindPipeline(frame_info.command_buffer, .graphics, self.pipeline.pipeline);

        // Bind descriptor sets
        const descriptor_sets = [_]vk.DescriptorSet{
            frame_info.global_descriptor_set, // Set 0: Global
            self.descriptors.getMaterialDescriptorSet(frame_info.current_frame) orelse return, // Set 1: Material
        };

        self.gc.vkd.cmdBindDescriptorSets(
            frame_info.command_buffer,
            .graphics,
            self.pipeline_layout,
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
                self.pipeline_layout,
                .{ .vertex_bit = true, .fragment_bit = true },
                0,
                @sizeOf(TexturedPushConstantData),
                &push_constants,
            );

            object.mesh_handle.getMesh().draw(self.gc.*, frame_info.command_buffer);
        }
    }
};
