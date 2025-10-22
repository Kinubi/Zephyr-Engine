const std = @import("std");
const vk = @import("vulkan");
const log = @import("../../utils/log.zig").log;
const Math = @import("../../utils/math.zig");

const RenderGraph = @import("../render_graph.zig").RenderGraph;
const RenderPass = @import("../render_graph.zig").RenderPass;
const RenderPassVTable = @import("../render_graph.zig").RenderPassVTable;
const ResourceId = @import("../render_graph.zig").ResourceId;
const FrameInfo = @import("../frameinfo.zig").FrameInfo;
const GraphicsContext = @import("../../core/graphics_context.zig").GraphicsContext;
const UnifiedPipelineSystem = @import("../unified_pipeline_system.zig").UnifiedPipelineSystem;
const PipelineConfig = @import("../unified_pipeline_system.zig").PipelineConfig;
const PipelineId = @import("../unified_pipeline_system.zig").PipelineId;
const Resource = @import("../unified_pipeline_system.zig").Resource;
const ResourceBinder = @import("../resource_binder.zig").ResourceBinder;
const AssetManager = @import("../../assets/asset_manager.zig").AssetManager;
const vertex_formats = @import("../vertex_formats.zig");
const MAX_FRAMES_IN_FLIGHT = @import("../../core/swapchain.zig").MAX_FRAMES_IN_FLIGHT;
const DynamicRenderingHelper = @import("../../utils/dynamic_rendering.zig").DynamicRenderingHelper;

// ECS imports
const ecs = @import("../../ecs.zig");
const World = ecs.World;
const RenderSystem = ecs.RenderSystem;

/// GeometryPass renders opaque ECS entities using dynamic rendering
/// Outputs: color target (RGBA16F) + depth buffer (D32)
pub const GeometryPass = struct {
    base: RenderPass,
    allocator: std.mem.Allocator,

    // Rendering context
    graphics_context: *GraphicsContext,
    pipeline_system: *UnifiedPipelineSystem,
    resource_binder: ResourceBinder,
    asset_manager: *AssetManager,
    ecs_world: *World,

    // Swapchain formats
    swapchain_color_format: vk.Format,
    swapchain_depth_format: vk.Format,

    // Resources this pass uses (registered during setup)
    color_target: ResourceId = .invalid,
    depth_buffer: ResourceId = .invalid,

    // Pipeline
    geometry_pipeline: PipelineId = undefined,
    cached_pipeline_handle: vk.Pipeline = .null_handle,

    // Hot reload state
    resources_need_setup: bool = false,
    descriptor_dirty_flags: [MAX_FRAMES_IN_FLIGHT]bool = [_]bool{true} ** MAX_FRAMES_IN_FLIGHT,

    // Render system for extracting entities
    render_system: RenderSystem,

    pub fn create(
        allocator: std.mem.Allocator,
        graphics_context: *GraphicsContext,
        pipeline_system: *UnifiedPipelineSystem,
        asset_manager: *AssetManager,
        ecs_world: *World,
        swapchain_color_format: vk.Format,
        swapchain_depth_format: vk.Format,
    ) !*GeometryPass {
        const pass = try allocator.create(GeometryPass);
        pass.* = GeometryPass{
            .base = RenderPass{
                .name = "GeometryPass",
                .enabled = true,
                .vtable = &vtable,
            },
            .allocator = allocator,
            .graphics_context = graphics_context,
            .pipeline_system = pipeline_system,
            .resource_binder = ResourceBinder.init(allocator, pipeline_system),
            .asset_manager = asset_manager,
            .ecs_world = ecs_world,
            .swapchain_color_format = swapchain_color_format,
            .swapchain_depth_format = swapchain_depth_format,
            .render_system = RenderSystem{ .allocator = allocator },
        };

        log(.INFO, "geometry_pass", "Created GeometryPass", .{});
        return pass;
    }

    const vtable = RenderPassVTable{
        .setup = setupImpl,
        .execute = executeImpl,
        .teardown = teardownImpl,
    };

    fn setupImpl(base: *RenderPass, graph: *RenderGraph) !void {
        const self: *GeometryPass = @fieldParentPtr("base", base);

        // Register resources we need
        // Note: actual image creation happens externally (swapchain for color, separate depth buffer)
        // We just register logical resources here
        self.color_target = try graph.resources.registerResource(
            "geometry_color",
            .render_target,
            .r16g16b16a16_sfloat, // RGBA16F
        );

        self.depth_buffer = try graph.resources.registerResource(
            "geometry_depth",
            .depth_buffer,
            .d32_sfloat, // D32
        );

        // Create pipeline using dynamic rendering (no render pass)
        const color_formats = [_]vk.Format{self.swapchain_color_format};
        const pipeline_config = PipelineConfig{
            .name = "geometry_pass",
            .vertex_shader = "shaders/textured.vert",
            .fragment_shader = "shaders/textured.frag",
            .render_pass = .null_handle, // ❌ No render pass for dynamic rendering!
            .vertex_input_bindings = vertex_formats.mesh_bindings[0..],
            .vertex_input_attributes = vertex_formats.mesh_attributes[0..],
            .push_constant_ranges = &[_]vk.PushConstantRange{
                .{
                    .stage_flags = .{ .vertex_bit = true, .fragment_bit = true },
                    .offset = 0,
                    .size = @sizeOf(GeometryPushConstants),
                },
            },
            .cull_mode = .{ .back_bit = true },
            .front_face = .counter_clockwise,
            .dynamic_rendering_color_formats = &color_formats,
            .dynamic_rendering_depth_format = self.swapchain_depth_format,
        };

        self.geometry_pipeline = try self.pipeline_system.createPipeline(pipeline_config);
        const pipeline_entry = self.pipeline_system.pipelines.get(self.geometry_pipeline) orelse return error.PipelineNotFound;
        self.cached_pipeline_handle = pipeline_entry.vulkan_pipeline;

        // Mark resources as needing setup
        self.resources_need_setup = true;
        self.pipeline_system.markPipelineResourcesDirty(self.geometry_pipeline);

        log(.INFO, "geometry_pass", "Setup complete (color: {}, depth: {})", .{ self.color_target.toInt(), self.depth_buffer.toInt() });
    }

    /// Bind material buffer and texture array from AssetManager to all frames
    fn setupResources(self: *GeometryPass) !void {
        // Bind material buffer for all frames
        if (self.asset_manager.material_buffer) |buffer| {
            const material_resource = Resource{
                .buffer = .{
                    .buffer = buffer.buffer,
                    .offset = 0,
                    .range = buffer.buffer_size,
                },
            };

            for (0..MAX_FRAMES_IN_FLIGHT) |frame_idx| {
                try self.pipeline_system.bindResource(
                    self.geometry_pipeline,
                    1,
                    0,
                    material_resource,
                    @intCast(frame_idx),
                );
            }
        }

        // Bind texture array for all frames
        const texture_image_infos = self.asset_manager.getTextureDescriptorArray();
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
            const textures_resource = Resource{ .image_array = texture_image_infos };

            for (0..MAX_FRAMES_IN_FLIGHT) |frame_idx| {
                try self.pipeline_system.bindResource(
                    self.geometry_pipeline,
                    1,
                    1,
                    textures_resource,
                    @intCast(frame_idx),
                );
            }
        }
    }

    fn executeImpl(base: *RenderPass, frame_info: FrameInfo) !void {
        const self: *GeometryPass = @fieldParentPtr("base", base);
        const cmd = frame_info.command_buffer;
        const frame_index = frame_info.current_frame;

        // Check if pipeline was hot-reloaded
        const pipeline_entry = self.pipeline_system.pipelines.get(self.geometry_pipeline) orelse return error.PipelineNotFound;
        const pipeline_rebuilt = pipeline_entry.vulkan_pipeline != self.cached_pipeline_handle;

        if (pipeline_rebuilt) {
            log(.INFO, "geometry_pass", "Pipeline hot-reloaded, clearing resource binder cache", .{});
            self.cached_pipeline_handle = pipeline_entry.vulkan_pipeline;
            self.resource_binder.clearPipeline(self.geometry_pipeline);
        }

        // Check if assets were updated (materials or textures)
        const assets_updated = self.asset_manager.materials_updated or self.asset_manager.texture_descriptors_updated;

        if (assets_updated or pipeline_rebuilt) {
            log(.INFO, "geometry_pass", "Assets updated, marking resources for rebind", .{});
            try self.setupResources();
        }

        // Extract renderables from ECS
        var render_data = try self.render_system.extractRenderData(self.ecs_world);
        defer render_data.deinit();

        if (render_data.renderables.items.len == 0) {
            log(.TRACE, "geometry_pass", "No entities to render", .{});
            return;
        }

        // Transition swapchain image from UNDEFINED to COLOR_ATTACHMENT_OPTIMAL
        self.graphics_context.transitionImageLayout(
            cmd,
            frame_info.color_image,
            .undefined,
            .color_attachment_optimal,
            .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        );

        // Setup dynamic rendering with helper
        const rendering = DynamicRenderingHelper.init(
            frame_info.color_image_view,
            frame_info.depth_image_view,
            frame_info.extent,
            .{ 0.01, 0.01, 0.01, 1.0 }, // clear color (dark gray)
            1.0, // clear depth
        );

        // Begin rendering (also sets viewport and scissor)
        rendering.begin(self.graphics_context, cmd);

        // Bind pipeline with automatic Set 0 (global UBO) binding
        try self.pipeline_system.bindPipelineWithGlobalSet(cmd, self.geometry_pipeline, frame_index);

        // Update descriptor sets for this frame using ResourceBinder (handles Set 1: materials/textures)
        try self.resource_binder.updateFrame(self.geometry_pipeline, frame_index);

        // Bind Set 1 (materials/textures) - ResourceBinder has updated it, now we need to bind it
        if (self.pipeline_system.getDescriptorSet(self.geometry_pipeline, 1, frame_index)) |set_1| {
            const pipeline_layout = try self.pipeline_system.getPipelineLayout(self.geometry_pipeline);
            self.graphics_context.vkd.cmdBindDescriptorSets(
                cmd,
                .graphics,
                pipeline_layout,
                1, // Set 1
                1,
                @ptrCast(&set_1),
                0,
                null,
            );
        }

        // Get pipeline layout for push constants
        const pipeline_layout = try self.pipeline_system.getPipelineLayout(self.geometry_pipeline);

        // Render each entity
        var rendered_count: usize = 0;
        for (render_data.renderables.items) |renderable| {
            // Get model
            const model = self.asset_manager.getModel(renderable.model_asset) orelse {
                continue;
            };

            // Get material index
            const material_asset = renderable.material_asset orelse continue;
            const material_index = self.asset_manager.getMaterialIndex(material_asset) orelse continue;

            // Push constants
            const push_constants = GeometryPushConstants{
                .transform = renderable.world_matrix.data,
                .normal_matrix = renderable.world_matrix.data, // TODO: Compute proper normal matrix
                .material_index = @intCast(material_index),
            };

            self.graphics_context.vkd.cmdPushConstants(
                cmd,
                pipeline_layout,
                .{ .vertex_bit = true, .fragment_bit = true },
                0,
                @sizeOf(GeometryPushConstants),
                &push_constants,
            );

            // Draw all meshes
            for (model.meshes.items) |model_mesh| {
                model_mesh.geometry.mesh.draw(self.graphics_context.*, cmd);
            }

            rendered_count += 1;
        }

        // End rendering
        rendering.end(self.graphics_context, cmd);

        // Transition swapchain image from COLOR_ATTACHMENT_OPTIMAL to PRESENT_SRC_KHR
        self.graphics_context.transitionImageLayout(
            cmd,
            frame_info.color_image,
            .color_attachment_optimal,
            .present_src_khr,
            .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        );
    }

    fn teardownImpl(base: *RenderPass) void {
        const self: *GeometryPass = @fieldParentPtr("base", base);
        log(.INFO, "geometry_pass", "Tearing down", .{});

        // Clean up resource binder
        self.resource_binder.deinit();

        // Pipeline cleanup handled by UnifiedPipelineSystem
        self.allocator.destroy(self);
    }
};

/// Push constants for geometry pass
pub const GeometryPushConstants = extern struct {
    transform: [16]f32 = Math.Mat4x4.identity().data,
    normal_matrix: [16]f32 = Math.Mat4x4.identity().data,
    material_index: u32 = 0,
};
