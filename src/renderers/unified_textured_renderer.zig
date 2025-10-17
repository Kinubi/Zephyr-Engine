const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("../core/graphics_context.zig").GraphicsContext;
const UnifiedPipelineSystem = @import("../rendering/unified_pipeline_system.zig").UnifiedPipelineSystem;
const PipelineConfig = @import("../rendering/unified_pipeline_system.zig").PipelineConfig;
const ResourceBinder = @import("../rendering/resource_binder.zig").ResourceBinder;
const PipelineId = @import("../rendering/unified_pipeline_system.zig").PipelineId;
const Resource = @import("../rendering/unified_pipeline_system.zig").Resource;
const ShaderManager = @import("../assets/shader_manager.zig").ShaderManager;
const FrameInfo = @import("../rendering/frameinfo.zig").FrameInfo;
const SceneBridge = @import("../rendering/scene_bridge.zig").SceneBridge;
const Vertex = @import("../rendering/mesh.zig").Vertex;
const log = @import("../utils/log.zig").log;
const Math = @import("../utils/math.zig");
const MAX_FRAMES_IN_FLIGHT = @import("../core/swapchain.zig").MAX_FRAMES_IN_FLIGHT;

/// Textured renderer using the unified pipeline system
///
/// This renderer replaces the old textured_renderer but uses UnifiedPipelineSystem
/// like ParticleRenderer does, while maintaining API compatibility.
pub const UnifiedTexturedRenderer = struct {
    allocator: std.mem.Allocator,
    graphics_context: *GraphicsContext,
    shader_manager: *ShaderManager,
    render_pass: vk.RenderPass,

    // Unified pipeline system (shared, not owned)
    pipeline_system: *UnifiedPipelineSystem,
    resource_binder: ResourceBinder,

    // Pipeline for textured objects
    textured_pipeline: PipelineId,
    cached_pipeline_handle: vk.Pipeline,
    descriptor_dirty_flags: [MAX_FRAMES_IN_FLIGHT]bool = [_]bool{true} ** MAX_FRAMES_IN_FLIGHT,

    pub fn init(
        allocator: std.mem.Allocator,
        graphics_context: *GraphicsContext,
        shader_manager: *ShaderManager,
        pipeline_system: *UnifiedPipelineSystem,
        render_pass: vk.RenderPass,
    ) !UnifiedTexturedRenderer {
        log(.INFO, "unified_textured_renderer", "Initializing unified textured renderer", .{});

        // Use the provided pipeline system
        const resource_binder = ResourceBinder.init(allocator, pipeline_system);

        // Create textured pipeline with push constants for per-object transforms
        const pipeline_config = PipelineConfig{
            .name = "textured_renderer",
            .vertex_shader = "shaders/textured.vert",
            .fragment_shader = "shaders/textured.frag",
            .render_pass = render_pass,
            .vertex_input_bindings = &[_]@import("../rendering/pipeline_builder.zig").VertexInputBinding{
                // Match the old Vertex format from scene
                .{ .binding = 0, .stride = @sizeOf(Vertex), .input_rate = .vertex },
            },
            .vertex_input_attributes = &[_]@import("../rendering/pipeline_builder.zig").VertexInputAttribute{
                .{ .location = 0, .binding = 0, .format = .r32g32b32_sfloat, .offset = @offsetOf(Vertex, "pos") },
                .{ .location = 1, .binding = 0, .format = .r32g32b32_sfloat, .offset = @offsetOf(Vertex, "color") },
                .{ .location = 2, .binding = 0, .format = .r32g32b32_sfloat, .offset = @offsetOf(Vertex, "normal") },
                .{ .location = 3, .binding = 0, .format = .r32g32_sfloat, .offset = @offsetOf(Vertex, "uv") },
            },
            .push_constant_ranges = &[_]vk.PushConstantRange{
                .{ .stage_flags = .{ .vertex_bit = true, .fragment_bit = true }, .offset = 0, .size = @sizeOf(TexturedPushConstantData) },
            },
            .cull_mode = .{ .back_bit = true },
            .front_face = .counter_clockwise,
        };

        const textured_pipeline = try pipeline_system.createPipeline(pipeline_config);
        const pipeline_entry = pipeline_system.pipelines.get(textured_pipeline) orelse return error.PipelineNotFound;

        const renderer = UnifiedTexturedRenderer{
            .allocator = allocator,
            .graphics_context = graphics_context,
            .shader_manager = shader_manager,
            .render_pass = render_pass,
            .pipeline_system = pipeline_system,
            .resource_binder = resource_binder,
            .textured_pipeline = textured_pipeline,
            .cached_pipeline_handle = pipeline_entry.vulkan_pipeline,
        };

        log(.INFO, "unified_textured_renderer", "✅ Unified textured renderer initialized", .{});

        return renderer;
    }

    pub fn deinit(self: *UnifiedTexturedRenderer) void {
        log(.INFO, "unified_textured_renderer", "Cleaning up unified textured renderer", .{});

        // Clean up resource binder (but not pipeline system - it's shared)
        self.resource_binder.deinit();
    }

    fn markAllFramesDirty(self: *UnifiedTexturedRenderer) void {
        for (&self.descriptor_dirty_flags) |*flag| {
            flag.* = true;
        }
    }

    pub fn onCreate(self: *UnifiedTexturedRenderer, scene_bridge: *SceneBridge) !void {
        var any_bindings = false;

        if (scene_bridge.getMaterialBufferInfo()) |material_info| {
            const material_resource = Resource{
                .buffer = .{
                    .buffer = material_info.buffer,
                    .offset = material_info.offset,
                    .range = material_info.range,
                },
            };

            for (0..MAX_FRAMES_IN_FLIGHT) |frame_idx| {
                try self.pipeline_system.bindResource(
                    self.textured_pipeline,
                    1,
                    0,
                    material_resource,
                    @intCast(frame_idx),
                );
            }

            any_bindings = true;
        }

        const texture_image_infos = scene_bridge.getTextures();
        var textures_ready = false;
        if (texture_image_infos.len > 0) {
            textures_ready = true;
            for (texture_image_infos) |info| {
                if (info.sampler == vk.Sampler.null_handle or info.image_view == vk.ImageView.null_handle) {
                    textures_ready = false;
                    break;
                }
            }
        }

        if (textures_ready) {
            const texture_resource = Resource{ .image_array = texture_image_infos };
            for (0..MAX_FRAMES_IN_FLIGHT) |frame_idx| {
                try self.pipeline_system.bindResource(
                    self.textured_pipeline,
                    1,
                    1,
                    texture_resource,
                    @intCast(frame_idx),
                );
            }

            any_bindings = true;
        }

        if (any_bindings) {
            for (0..MAX_FRAMES_IN_FLIGHT) |frame_idx| {
                try self.pipeline_system.updateDescriptorSetsForPipeline(self.textured_pipeline, @intCast(frame_idx));
            }
        }
    }

    /// Update material and texture bindings for the current frame
    pub fn update(self: *UnifiedTexturedRenderer, frame_info: *const FrameInfo, scene_bridge: *SceneBridge) !bool {
        const frame_index = frame_info.current_frame;

        const materials_dirty = scene_bridge.materialsUpdated(frame_index);
        const textures_dirty = scene_bridge.texturesUpdated(frame_index);

        const needs_update =
            materials_dirty or
            textures_dirty or
            self.descriptor_dirty_flags[frame_index];

        if (!needs_update) {
            return false;
        }

        const material_info = scene_bridge.getMaterialBufferInfo() orelse {
            log(.WARN, "unified_textured_renderer", "Material buffer not ready, deferring descriptor update", .{});
            self.markAllFramesDirty();
            return false;
        };

        const texture_image_infos = scene_bridge.getTextures();
        const textures_ready = blk: {
            if (texture_image_infos.len == 0) break :blk false;
            for (texture_image_infos) |info| {
                if (info.sampler == vk.Sampler.null_handle or info.image_view == vk.ImageView.null_handle) {
                    break :blk false;
                }
            }
            break :blk true;
        };

        const material_resource = Resource{
            .buffer = .{
                .buffer = material_info.buffer,
                .offset = material_info.offset,
                .range = material_info.range,
            },
        };

        const textures_resource = if (textures_ready)
            Resource{ .image_array = texture_image_infos }
        else
            null;

        for (0..MAX_FRAMES_IN_FLIGHT) |frame_idx| {
            const target_frame: u32 = @intCast(frame_idx);
            try self.pipeline_system.bindResource(self.textured_pipeline, 1, 0, material_resource, target_frame);

            if (textures_resource) |res| {
                try self.pipeline_system.bindResource(self.textured_pipeline, 1, 1, res, target_frame);
            }

            self.descriptor_dirty_flags[frame_idx] = false;
        }

        if (!textures_ready) {
            log(.WARN, "unified_textured_renderer", "Texture descriptors not ready, reusing previous bindings", .{});
        }

        return true;
    }

    /// Render textured objects using scene bridge data
    pub fn render(self: *UnifiedTexturedRenderer, frame_info: FrameInfo, scene_bridge: *SceneBridge) !void {
        const frame_index = frame_info.current_frame;
        const meshes_dirty = scene_bridge.meshesUpdated(frame_index);
        const objects = scene_bridge.getMeshes();
        if (objects.len == 0) {
            if (meshes_dirty) {
                scene_bridge.markMeshesSynced(frame_index);
            }
            return;
        }

        const pipeline_entry = self.pipeline_system.pipelines.get(self.textured_pipeline) orelse return error.PipelineNotFound;
        const pipeline_changed = pipeline_entry.vulkan_pipeline != self.cached_pipeline_handle;
        if (pipeline_changed) {
            self.cached_pipeline_handle = pipeline_entry.vulkan_pipeline;
            self.pipeline_system.markPipelineResourcesDirty(self.textured_pipeline);
            log(.INFO, "unified_textured_renderer", "Pipeline changed, marking resources dirty", .{});
            self.markAllFramesDirty();
        }

        if (self.descriptor_dirty_flags[frame_index]) {
            log(.DEBUG, "unified_textured_renderer", "Descriptors dirty for frame {}, skipping render", .{frame_index});
            return;
        }

        // Update descriptor sets for this frame (materials and textures)
        try self.pipeline_system.updateDescriptorSetsForPipeline(self.textured_pipeline, frame_info.current_frame);

        // Get pipeline layout BEFORE binding (we'll bind manually)
        const pipeline_layout = try self.pipeline_system.getPipelineLayout(self.textured_pipeline);

        // Get the pipeline's Vulkan handle
        const pipeline = self.pipeline_system.pipelines.get(self.textured_pipeline) orelse return error.PipelineNotFound;

        // Bind the Vulkan pipeline directly (skip automatic descriptor binding)
        self.graphics_context.vkd.cmdBindPipeline(frame_info.command_buffer, .graphics, pipeline.vulkan_pipeline);

        // Manually bind descriptor sets like the old renderer
        // Set 0: Global UBO (from frame_info) - contains view/projection matrices
        // Set 1: Material buffer and texture array (from pipeline system)

        // Get set 1 descriptor from the pipeline (materials/textures)
        // descriptor_sets is [set_index][frame_index]
        if (pipeline.descriptor_sets.items.len > 1) {
            const set_1_frames = pipeline.descriptor_sets.items[1]; // Set 1 (materials/textures)
            const material_descriptor_set = set_1_frames[frame_info.current_frame];

            const descriptor_sets = [_]vk.DescriptorSet{
                frame_info.global_descriptor_set, // Set 0: Global
                material_descriptor_set, // Set 1: Materials/Textures
            };

            self.graphics_context.vkd.cmdBindDescriptorSets(
                frame_info.command_buffer,
                .graphics,
                pipeline_layout,
                0, // First set
                descriptor_sets.len,
                &descriptor_sets,
                0,
                null,
            );
        } else {
            // Fallback: only bind global descriptor set if materials aren't ready
            const descriptor_sets = [_]vk.DescriptorSet{
                frame_info.global_descriptor_set, // Set 0: Global
            };

            self.graphics_context.vkd.cmdBindDescriptorSets(
                frame_info.command_buffer,
                .graphics,
                pipeline_layout,
                0, // First set
                descriptor_sets.len,
                &descriptor_sets,
                0,
                null,
            );
        }

        // Render each object
        for (objects) |object| {
            if (!object.visible) continue;

            // Set up push constants with transform and material index (matches old API)
            const push_constants = TexturedPushConstantData{
                .transform = object.transform,
                .normal_matrix = object.transform, // TODO: Calculate proper normal matrix
                .material_index = object.material_index,
            };

            self.graphics_context.vkd.cmdPushConstants(
                frame_info.command_buffer,
                pipeline_layout,
                .{ .vertex_bit = true, .fragment_bit = true },
                0,
                @sizeOf(TexturedPushConstantData),
                &push_constants,
            );

            // Draw the mesh
            object.mesh_handle.getMesh().draw(self.graphics_context.*, frame_info.command_buffer);
        }

        if (meshes_dirty) {
            scene_bridge.markMeshesSynced(frame_index);
        }
    }
};

/// Push constant data for per-object transforms (matches old textured_renderer API)
pub const TexturedPushConstantData = extern struct {
    transform: [16]f32 = Math.Mat4x4.identity().data,
    normal_matrix: [16]f32 = Math.Mat4x4.identity().data,
    material_index: u32 = 0,
};
