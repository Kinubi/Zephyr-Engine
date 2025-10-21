const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("../core/graphics_context.zig").GraphicsContext;
const UnifiedPipelineSystem = @import("../rendering/unified_pipeline_system.zig").UnifiedPipelineSystem;
const PipelineConfig = @import("../rendering/unified_pipeline_system.zig").PipelineConfig;
const ResourceBinder = @import("../rendering/resource_binder.zig").ResourceBinder;
const PipelineId = @import("../rendering/unified_pipeline_system.zig").PipelineId;
const Resource = @import("../rendering/unified_pipeline_system.zig").Resource;
const ShaderManager = @import("../assets/shader_manager.zig").ShaderManager;
const AssetManager = @import("../assets/asset_manager.zig").AssetManager;
const FrameInfo = @import("../rendering/frameinfo.zig").FrameInfo;
const SceneBridge = @import("../rendering/scene_bridge.zig").SceneBridge;
const vertex_formats = @import("../rendering/vertex_formats.zig");
const log = @import("../utils/log.zig").log;
const Math = @import("../utils/math.zig");
const MAX_FRAMES_IN_FLIGHT = @import("../core/swapchain.zig").MAX_FRAMES_IN_FLIGHT;

// ECS imports
const new_ecs = @import("../ecs.zig");
const World = new_ecs.World;
const RenderSystem = new_ecs.RenderSystem;
const TransformSystem = new_ecs.TransformSystem;

/// ECS-integrated renderer that uses RenderSystem to extract entities
/// and renders them through the UnifiedPipeline system.
///
/// This renderer bridges the ECS world with Vulkan rendering by:
/// 1. Using RenderSystem to extract entities with Transform + MeshRenderer components
/// 2. Looking up models/materials/textures from AssetManager using AssetIds
/// 3. Rendering via UnifiedPipeline with proper descriptor binding
pub const EcsRenderer = struct {
    allocator: std.mem.Allocator,
    graphics_context: *GraphicsContext,
    shader_manager: *ShaderManager,
    asset_manager: *AssetManager,
    render_pass: vk.RenderPass,

    // ECS integration
    ecs_world: *World,
    render_system: RenderSystem,

    // Pipeline infrastructure
    pipeline_system: *UnifiedPipelineSystem,
    resource_binder: ResourceBinder,

    ecs_pipeline: PipelineId,
    cached_pipeline_handle: vk.Pipeline,
    descriptor_dirty_flags: [MAX_FRAMES_IN_FLIGHT]bool = [_]bool{true} ** MAX_FRAMES_IN_FLIGHT,

    pub fn init(
        allocator: std.mem.Allocator,
        graphics_context: *GraphicsContext,
        shader_manager: *ShaderManager,
        asset_manager: *AssetManager,
        pipeline_system: *UnifiedPipelineSystem,
        render_pass: vk.RenderPass,
        ecs_world: *World,
    ) !EcsRenderer {
        log(.INFO, "ecs_renderer", "Initializing ECS renderer", .{});

        const resource_binder = ResourceBinder.init(allocator, pipeline_system);

        // Create pipeline using the same textured shaders
        const pipeline_config = PipelineConfig{
            .name = "ecs_renderer",
            .vertex_shader = "shaders/textured.vert",
            .fragment_shader = "shaders/textured.frag",
            .render_pass = render_pass,
            .vertex_input_bindings = vertex_formats.mesh_bindings[0..],
            .vertex_input_attributes = vertex_formats.mesh_attributes[0..],
            .push_constant_ranges = &[_]vk.PushConstantRange{
                .{
                    .stage_flags = .{ .vertex_bit = true, .fragment_bit = true },
                    .offset = 0,
                    .size = @sizeOf(EcsPushConstantData),
                },
            },
            .cull_mode = .{ .back_bit = true },
            .front_face = .counter_clockwise,
        };

        const ecs_pipeline = try pipeline_system.createPipeline(pipeline_config);
        const pipeline_entry = pipeline_system.pipelines.get(ecs_pipeline) orelse return error.PipelineNotFound;

        const renderer = EcsRenderer{
            .allocator = allocator,
            .graphics_context = graphics_context,
            .shader_manager = shader_manager,
            .asset_manager = asset_manager,
            .render_pass = render_pass,
            .ecs_world = ecs_world,
            .render_system = RenderSystem{ .allocator = allocator },
            .pipeline_system = pipeline_system,
            .resource_binder = resource_binder,
            .ecs_pipeline = ecs_pipeline,
            .cached_pipeline_handle = pipeline_entry.vulkan_pipeline,
        };

        log(.INFO, "ecs_renderer", "ECS renderer initialized", .{});
        return renderer;
    }

    pub fn deinit(self: *EcsRenderer) void {
        log(.INFO, "ecs_renderer", "Cleaning up ECS renderer", .{});
        self.resource_binder.deinit();
    }

    fn markAllFramesDirty(self: *EcsRenderer) void {
        for (&self.descriptor_dirty_flags) |*flag| {
            flag.* = true;
        }
    }

    pub fn onCreate(self: *EcsRenderer, _: *SceneBridge) !void {
        var any_bindings = false;

        // Bind material buffer directly from AssetManager (not SceneBridge)
        // This is the modern ECS path - get GPU resources directly from AssetManager
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
                    self.ecs_pipeline,
                    1,
                    0,
                    material_resource,
                    @intCast(frame_idx),
                );
            }

            any_bindings = true;
        }

        // Bind texture array directly from AssetManager
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
                    self.ecs_pipeline,
                    1,
                    1,
                    textures_resource,
                    @intCast(frame_idx),
                );
            }

            any_bindings = true;
        }

        // Update all descriptor sets if we have bindings
        if (any_bindings) {
            for (0..MAX_FRAMES_IN_FLIGHT) |frame_idx| {
                try self.pipeline_system.updateDescriptorSetsForPipeline(self.ecs_pipeline, @intCast(frame_idx));
            }
        }

        log(.INFO, "ecs_renderer", "ECS renderer onCreate complete (materials: {}, textures: {})", .{ self.asset_manager.material_buffer != null, textures_ready });
    }

    /// Update checks if pipeline needs refresh or descriptors need rebinding
    pub fn update(self: *EcsRenderer, frame_info: *const FrameInfo, _: *SceneBridge) !bool {
        const frame_index = frame_info.current_frame;

        // Check for material/texture updates directly from AssetManager
        const materials_dirty = self.asset_manager.materials_dirty;
        const textures_dirty = self.asset_manager.texture_descriptors_dirty;

        const needs_update =
            materials_dirty or
            textures_dirty or
            self.descriptor_dirty_flags[frame_index];

        if (!needs_update) {
            return false;
        }

        // Check if pipeline was hot-reloaded
        const pipeline_entry = self.pipeline_system.pipelines.get(self.ecs_pipeline) orelse return error.PipelineNotFound;
        const pipeline_changed = pipeline_entry.vulkan_pipeline != self.cached_pipeline_handle;

        if (pipeline_changed) {
            log(.INFO, "ecs_renderer", "Pipeline hot-reloaded, updating cache", .{});
            self.cached_pipeline_handle = pipeline_entry.vulkan_pipeline;
            self.pipeline_system.markPipelineResourcesDirty(self.ecs_pipeline);
            self.markAllFramesDirty();
        }

        // Get material buffer directly from AssetManager
        const material_buffer = self.asset_manager.material_buffer orelse {
            log(.WARN, "ecs_renderer", "Material buffer not ready, deferring descriptor update", .{});
            self.markAllFramesDirty();
            return false;
        };

        // Get texture array directly from AssetManager
        const texture_image_infos = self.asset_manager.getTextureDescriptorArray();
        const textures_ready = blk: {
            if (texture_image_infos.len == 0) break :blk false;
            for (texture_image_infos) |info| {
                if (info.sampler == vk.Sampler.null_handle or info.image_view == vk.ImageView.null_handle) {
                    break :blk false;
                }
            }
            break :blk true;
        };

        // Bind resources
        const material_resource = Resource{
            .buffer = .{
                .buffer = material_buffer.buffer,
                .offset = 0,
                .range = material_buffer.buffer_size,
            },
        };

        const textures_resource = if (textures_ready)
            Resource{ .image_array = texture_image_infos }
        else
            null;

        for (0..MAX_FRAMES_IN_FLIGHT) |frame_idx| {
            const target_frame: u32 = @intCast(frame_idx);
            try self.pipeline_system.bindResource(self.ecs_pipeline, 1, 0, material_resource, target_frame);

            if (textures_resource) |res| {
                try self.pipeline_system.bindResource(self.ecs_pipeline, 1, 1, res, target_frame);
            }

            self.descriptor_dirty_flags[frame_idx] = false;
        }

        if (!textures_ready) {
            log(.WARN, "ecs_renderer", "Texture descriptors not ready, reusing previous bindings", .{});
        }

        return true;
    }

    /// Render ECS entities using RenderSystem to extract renderables
    pub fn render(self: *EcsRenderer, frame_info: FrameInfo, scene_bridge: *SceneBridge) !void {
        const frame_index = frame_info.current_frame;

        // Check if scene data was updated this frame
        const meshes_dirty = scene_bridge.meshesUpdated(frame_index);

        // Extract rendering data from ECS
        var render_data = try self.render_system.extractRenderData(self.ecs_world);
        defer render_data.deinit();

        // Log entity count for debugging
        if (render_data.renderables.items.len > 0) {
            log(.INFO, "ecs_renderer", "Found {} ECS entities to render", .{render_data.renderables.items.len});
        }

        // Skip if no entities to render
        if (render_data.renderables.items.len == 0) {
            if (meshes_dirty) {
                scene_bridge.markMeshesSynced(frame_index);
            }
            return;
        }

        // Update descriptors if needed
        if (self.descriptor_dirty_flags[frame_index]) {
            try self.pipeline_system.updateDescriptorSetsForPipeline(self.ecs_pipeline, frame_info.current_frame);
            self.descriptor_dirty_flags[frame_index] = false;
        }

        const pipeline_layout = try self.pipeline_system.getPipelineLayout(self.ecs_pipeline);
        const pipeline = self.pipeline_system.pipelines.get(self.ecs_pipeline) orelse return error.PipelineNotFound;

        // Bind pipeline
        self.graphics_context.vkd.cmdBindPipeline(frame_info.command_buffer, .graphics, pipeline.vulkan_pipeline);

        // Bind descriptor sets (global + material/texture)
        if (pipeline.descriptor_sets.items.len > 1) {
            const set_1_frames = pipeline.descriptor_sets.items[1];
            const material_descriptor_set = set_1_frames[frame_info.current_frame];

            const descriptor_sets = [_]vk.DescriptorSet{
                frame_info.global_descriptor_set,
                material_descriptor_set,
            };

            self.graphics_context.vkd.cmdBindDescriptorSets(
                frame_info.command_buffer,
                .graphics,
                pipeline_layout,
                0,
                descriptor_sets.len,
                &descriptor_sets,
                0,
                null,
            );
        } else {
            const descriptor_sets = [_]vk.DescriptorSet{
                frame_info.global_descriptor_set,
            };

            self.graphics_context.vkd.cmdBindDescriptorSets(
                frame_info.command_buffer,
                .graphics,
                pipeline_layout,
                0,
                descriptor_sets.len,
                &descriptor_sets,
                0,
                null,
            );
        }

        // Render each entity
        var rendered_count: usize = 0;
        var skipped_no_model: usize = 0;
        var skipped_no_material_asset: usize = 0;
        var skipped_no_material_index: usize = 0;

        for (render_data.renderables.items) |renderable| {
            // Get model from asset manager
            const model = self.asset_manager.getModel(renderable.model_asset) orelse {
                // Suppress warning - assets may still be loading
                skipped_no_model += 1;
                log(.DEBUG, "ecs_renderer", "Entity skipped: no model for asset {}", .{@intFromEnum(renderable.model_asset)});
                continue;
            };

            // Look up material index from AssetManager
            const material_asset = renderable.material_asset orelse {
                // No material assigned
                skipped_no_material_asset += 1;
                log(.DEBUG, "ecs_renderer", "Entity skipped: no material asset assigned", .{});
                continue;
            };
            const material_idx_opt = self.asset_manager.getMaterialIndex(material_asset);
            if (material_idx_opt == null) {
                // Suppress warning - assets may still be loading
                skipped_no_material_index += 1;
                log(.DEBUG, "ecs_renderer", "Entity skipped: no material index for asset {}", .{@intFromEnum(material_asset)});
                continue;
            }
            const material_index = material_idx_opt.?; // Prepare push constants
            const push_constants = EcsPushConstantData{
                .transform = renderable.world_matrix.data,
                .normal_matrix = renderable.world_matrix.data, // TODO: Compute proper normal matrix
                .material_index = @intCast(material_index),
            };

            // Push constants
            self.graphics_context.vkd.cmdPushConstants(
                frame_info.command_buffer,
                pipeline_layout,
                .{ .vertex_bit = true, .fragment_bit = true },
                0,
                @sizeOf(EcsPushConstantData),
                &push_constants,
            );

            // Draw all meshes in the model
            for (model.meshes.items) |model_mesh| {
                model_mesh.geometry.mesh.draw(self.graphics_context.*, frame_info.command_buffer);
            }
            rendered_count += 1;
        }

        // Mark scene resources as synced after rendering
        if (meshes_dirty) {
            scene_bridge.markMeshesSynced(frame_index);
        }

        // Log skip statistics
        if (skipped_no_model > 0 or skipped_no_material_asset > 0 or skipped_no_material_index > 0) {
            log(.INFO, "ecs_renderer", "Skipped entities: {} no model, {} no material asset, {} no material index", .{ skipped_no_model, skipped_no_material_asset, skipped_no_material_index });
        }

        if (rendered_count > 0) {
            log(.TRACE, "ecs_renderer", "Rendered {} ECS entities", .{rendered_count});
        }
    }
};

/// Push constant data for ECS entities
pub const EcsPushConstantData = extern struct {
    transform: [16]f32 = Math.Mat4x4.identity().data,
    normal_matrix: [16]f32 = Math.Mat4x4.identity().data,
    material_index: u32 = 0,
};
