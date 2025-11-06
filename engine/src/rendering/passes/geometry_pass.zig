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
const MaterialSystem = @import("../material_system.zig").MaterialSystem;
const vertex_formats = @import("../vertex_formats.zig");
const MAX_FRAMES_IN_FLIGHT = @import("../../core/swapchain.zig").MAX_FRAMES_IN_FLIGHT;
const DynamicRenderingHelper = @import("../../utils/dynamic_rendering.zig").DynamicRenderingHelper;

// ECS imports
const ecs = @import("../../ecs.zig");
const World = ecs.World;
const RenderSystem = ecs.RenderSystem;

// Global UBO
const GlobalUboSet = @import("../ubo_set.zig").GlobalUboSet;

/// GeometryPass renders opaque ECS entities using dynamic rendering
/// Uses automatic resource management: binds resources once in setup,
/// ResourceBinder + BufferManager handle updates behind the scenes
/// Outputs: color target (RGBA16F) + depth buffer (D32)
pub const GeometryPass = struct {
    base: RenderPass,
    allocator: std.mem.Allocator,

    // Rendering context
    graphics_context: *GraphicsContext,
    pipeline_system: *UnifiedPipelineSystem,
    resource_binder: ResourceBinder,
    asset_manager: *AssetManager,
    material_system: *MaterialSystem,
    ecs_world: *World,
    global_ubo_set: *GlobalUboSet,

    // Swapchain formats
    swapchain_color_format: vk.Format,
    swapchain_depth_format: vk.Format,

    // Resources this pass uses (registered during setup)
    color_target: ResourceId = .invalid,
    depth_buffer: ResourceId = .invalid,

    // Pipeline
    geometry_pipeline: PipelineId = undefined,
    cached_pipeline_handle: vk.Pipeline = .null_handle,
    cached_pipeline_layout: vk.PipelineLayout = .null_handle,

    // Shared render system (pointer to scene's render system)
    render_system: *RenderSystem,

    pub fn create(
        allocator: std.mem.Allocator,
        graphics_context: *GraphicsContext,
        pipeline_system: *UnifiedPipelineSystem,
        asset_manager: *AssetManager,
        material_system: *MaterialSystem,
        ecs_world: *World,
        global_ubo_set: *GlobalUboSet,
        swapchain_color_format: vk.Format,
        swapchain_depth_format: vk.Format,
        render_system: *RenderSystem,
    ) !*GeometryPass {
        const pass = try allocator.create(GeometryPass);
        pass.* = GeometryPass{
            .base = RenderPass{
                .name = "geometry_pass",
                .enabled = true,
                .vtable = &vtable,
                .dependencies = std.ArrayList([]const u8){},
            },
            .allocator = allocator,
            .graphics_context = graphics_context,
            .pipeline_system = pipeline_system,
            .resource_binder = ResourceBinder.init(allocator, pipeline_system),
            .asset_manager = asset_manager,
            .material_system = material_system,
            .ecs_world = ecs_world,
            .global_ubo_set = global_ubo_set,
            .swapchain_color_format = swapchain_color_format,
            .swapchain_depth_format = swapchain_depth_format,
            .render_system = render_system,
        };

        log(.INFO, "geometry_pass", "Created geometry_pass", .{});
        return pass;
    }

    const vtable = RenderPassVTable{
        .setup = setupImpl,
        .update = updateImpl,
        .execute = executeImpl,
        .teardown = teardownImpl,
        .checkValidity = checkValidityImpl,
    };

    fn checkValidityImpl(base: *RenderPass) bool {
        const self: *GeometryPass = @fieldParentPtr("base", base);

        // Check if pipeline now exists (hot-reload succeeded)
        if (!self.pipeline_system.pipelines.contains(self.geometry_pipeline)) {
            return false;
        }

        // Pipeline exists! Complete the setup that was skipped during initial failure
        const pipeline_entry = self.pipeline_system.pipelines.get(self.geometry_pipeline) orelse return false;
        self.cached_pipeline_handle = pipeline_entry.vulkan_pipeline;
        self.cached_pipeline_layout = self.pipeline_system.getPipelineLayout(self.geometry_pipeline) catch return false;

        // Bind resources after recovery
        self.bindResources() catch return false;
        self.pipeline_system.markPipelineResourcesDirty(self.geometry_pipeline);

        log(.INFO, "geometry_pass", "Recovery setup complete", .{});
        return true;
    }

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
            .vertex_shader = "assets/shaders/textured.vert",
            .fragment_shader = "assets/shaders/textured.frag",
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

        const result = try self.pipeline_system.createPipeline(pipeline_config);
        self.geometry_pipeline = result.id;

        if (!result.success) {
            log(.WARN, "geometry_pass", "Pipeline creation failed. Pass will be disabled.", .{});
            return error.PipelineCreationFailed;
        }

        const pipeline_entry = self.pipeline_system.pipelines.get(self.geometry_pipeline) orelse return error.PipelineNotFound;
        self.cached_pipeline_handle = pipeline_entry.vulkan_pipeline;
        self.cached_pipeline_layout = try self.pipeline_system.getPipelineLayout(self.geometry_pipeline);

        // Populate ResourceBinder with shader reflection data
        if (try self.pipeline_system.getPipelineReflection(self.geometry_pipeline)) |reflection| {
            var mut_reflection = reflection;
            try self.resource_binder.populateFromReflection(mut_reflection);
            mut_reflection.deinit(self.allocator);
        }

        // Bind resources once during setup - ResourceBinder will track updates automatically
        try self.bindResources();

        self.pipeline_system.markPipelineResourcesDirty(self.geometry_pipeline);

        log(.INFO, "geometry_pass", "Setup complete (color: {}, depth: {})", .{ self.color_target.toInt(), self.depth_buffer.toInt() });
    }

    pub fn updateImpl(base: *RenderPass, frame_info: *const FrameInfo) !void {
        const self: *GeometryPass = @fieldParentPtr("base", base);

        const pipeline_entry = self.pipeline_system.pipelines.get(self.geometry_pipeline) orelse return;
        const pipeline_rebuilt = pipeline_entry.vulkan_pipeline != self.cached_pipeline_handle;

        if (pipeline_rebuilt) {
            log(.INFO, "geometry_pass", "Pipeline hot-reloaded, rebinding resources", .{});
            self.cached_pipeline_handle = pipeline_entry.vulkan_pipeline;
            self.cached_pipeline_layout = try self.pipeline_system.getPipelineLayout(self.geometry_pipeline);
            self.resource_binder.clearPipeline(self.geometry_pipeline);

            // Rebind after hot reload
            try self.bindResources();
        }

        // Bind resources every frame to detect MaterialBuffer changes
        try self.bindResources();

        // Update descriptors for all frames
        // for (0..MAX_FRAMES_IN_FLIGHT) |frame_idx| {
        //     const frame_index = @as(u32, @intCast(frame_idx));
        //     try self.resource_binder.updateFrame(self.geometry_pipeline, frame_index);
        // }
        try self.resource_binder.updateFrame(self.geometry_pipeline, frame_info.current_frame);
    }

    /// Bind resources once during setup - ResourceBinder tracks changes automatically
    fn bindResources(self: *GeometryPass) !void {
        const GlobalUbo = @import("../frameinfo.zig").GlobalUbo;

        // Bind resources for all frames using named binding
        for (0..MAX_FRAMES_IN_FLIGHT) |frame_idx| {
            const frame_index = @as(u32, @intCast(frame_idx));

            // Bind global UBO using named binding "GlobalUbo"
            const ubo_buffer = &self.global_ubo_set.buffers[frame_idx];
            try self.resource_binder.bindUniformBufferNamed(
                self.geometry_pipeline,
                "GlobalUbo",
                ubo_buffer,
                0, // offset
                @sizeOf(GlobalUbo),
                frame_index,
            );

            // Bind material buffer using named binding "MaterialBuffer" (if exists)
            if (self.material_system.getCurrentBuffer()) |material_buffer| {
                try self.resource_binder.bindStorageBufferNamed(
                    self.geometry_pipeline,
                    "MaterialBuffer",
                    @constCast(&material_buffer.buffer),
                    0, // offset
                    vk.WHOLE_SIZE,
                    frame_index,
                );
            }

            // Bind texture array using named binding "textures"
            const texture_image_infos = self.asset_manager.getTextureDescriptorArray();
            if (texture_image_infos.len > 0) {
                var textures_ready = true;
                for (texture_image_infos) |info| {
                    if (info.sampler == vk.Sampler.null_handle or info.image_view == vk.ImageView.null_handle) {
                        textures_ready = false;
                        break;
                    }
                }

                if (textures_ready) {
                    try self.resource_binder.bindTextureArrayNamed(
                        self.geometry_pipeline,
                        "textures",
                        texture_image_infos,
                        frame_index,
                    );
                }
            }
        }
    }

    fn executeImpl(base: *RenderPass, frame_info: FrameInfo) !void {
        const self: *GeometryPass = @fieldParentPtr("base", base);
        const cmd = frame_info.command_buffer;
        const frame_index = frame_info.current_frame;

        // Get rasterization data from render system (cached, no asset manager queries needed)
        const raster_data = try self.render_system.getRasterData();

        if (raster_data.objects.len == 0) {
            log(.TRACE, "geometry_pass", "No entities to render", .{});
            return;
        }

        // Setup dynamic rendering with helper
        const rendering = DynamicRenderingHelper.init(
            frame_info.hdr_texture.?.image_view,
            frame_info.depth_image_view,
            frame_info.extent,
            .{ 0.01, 0.01, 0.01, 1.0 }, // clear color (dark gray)
            1.0, // clear depth
        );

        // Begin rendering (also sets viewport and scissor)
        rendering.begin(self.graphics_context, cmd);
        // Update descriptor sets for this frame using ResourceBinder (handles Set 1: materials/textures)

        // Bind pipeline with all descriptor sets (Set 0: global UBO, Set 1: materials/textures)
        try self.pipeline_system.bindPipelineWithDescriptorSets(cmd, self.geometry_pipeline, frame_index);

        // Get pipeline layout from pipeline system (ensures we use the correct layout even during hot-reload)
        // Don't use cached_pipeline_layout here - it might be stale during hot-reload
        const pipeline_layout = try self.pipeline_system.getPipelineLayout(self.geometry_pipeline);

        // Render each object (mesh pointers and material indices already resolved in cache)
        // NOTE: All objects in cache are currently visible (visibility culling not yet implemented)
        // When adding visibility culling, filter at cache build time in RenderSystem, not here

        // TODO(MAINTENANCE): IMPLEMENT INSTANCED RENDERING - HIGH PRIORITY
        // Currently drawing each mesh individually with instance_count=1 (very inefficient!)
        //
        // Problem: For a scene with 1000 identical trees, we make 1000 draw calls.
        // Solution: Group objects by (mesh, material), draw once with instance_count=N.
        //
        // Required changes:
        // 1. RenderSystem: Sort cached objects by mesh_id during extraction
        // 2. RenderSystem: Build instance data buffer (transforms + material indices)
        // 3. GeometryPass: Loop over unique meshes, not individual objects
        // 4. GeometryPass: Use instanced drawing API
        // 5. Mesh: Add drawInstanced(instance_count, instance_buffer_offset) method
        // 6. Shaders: Use gl_InstanceIndex to fetch per-instance data
        //
        // Expected benefit: 10-100x reduction in draw calls for scenes with repeated assets
        // (e.g., 1000 trees → 1 draw call, 500 rocks → 1 draw call)
        //
        // Complexity: MEDIUM - requires render system refactor + shader changes
        // Branch recommended: features/instanced-rendering (not a simple maintenance fix)
        for (raster_data.objects) |object| {
            // Push constants (data already resolved in cache)
            const push_constants = GeometryPushConstants{
                .transform = object.transform,
                .normal_matrix = object.transform, // TODO: Compute proper normal matrix
                .material_index = object.material_index,
            };

            self.graphics_context.vkd.cmdPushConstants(
                cmd,
                pipeline_layout,
                .{ .vertex_bit = true, .fragment_bit = true },
                0,
                @sizeOf(GeometryPushConstants),
                &push_constants,
            );

            // Draw mesh (pointer already resolved in cache)
            // NOTE: instance_count=1 here - no instancing yet!
            object.mesh_handle.getMesh().draw(self.graphics_context.*, cmd);
        }

        // End rendering
        rendering.end(self.graphics_context, cmd);

        // Leave color image in COLOR_ATTACHMENT_OPTIMAL; swapchain.endFrame will transition
        // the swapchain image to PRESENT, and offscreen viewport images should remain in
        // a layout suitable for their next consumer.
    }

    fn teardownImpl(base: *RenderPass) void {
        const self: *GeometryPass = @fieldParentPtr("base", base);
        log(.INFO, "geometry_pass", "Tearing down", .{});

        // render_system is shared with scene, don't deinit here

        // Clean up resource binder
        self.resource_binder.deinit();

        // Pipeline cleanup handled by UnifiedPipelineSystem
        self.allocator.destroy(self);
        log(.INFO, "geometry_pass", "Teardown complete", .{});
    }
};

/// Push constants for geometry pass
pub const GeometryPushConstants = extern struct {
    transform: [16]f32 = Math.Mat4x4.identity().data,
    normal_matrix: [16]f32 = Math.Mat4x4.identity().data,
    material_index: u32 = 0,
};
