const std = @import("std");
const vk = @import("vulkan");
const log = @import("../../utils/log.zig").log;
const Math = @import("../../utils/math.zig");
const RenderGraph = @import("../render_graph.zig").RenderGraph;
const RenderPass = @import("../render_graph.zig").RenderPass;
const RenderPassVTable = @import("../render_graph.zig").RenderPassVTable;
const FrameInfo = @import("../frameinfo.zig").FrameInfo;
const GraphicsContext = @import("../../core/graphics_context.zig").GraphicsContext;
const UnifiedPipelineSystem = @import("../unified_pipeline_system.zig").UnifiedPipelineSystem;
const PipelineConfig = @import("../unified_pipeline_system.zig").PipelineConfig;
const PipelineId = @import("../unified_pipeline_system.zig").PipelineId;
const ResourceBinder = @import("../resource_binder.zig").ResourceBinder;
const ManagedBuffer = @import("../buffer_manager.zig").ManagedBuffer;
const TextureManager = @import("../texture_manager.zig").TextureManager;
const ManagedTexture = @import("../texture_manager.zig").ManagedTexture;
const DynamicRenderingHelper = @import("../../utils/dynamic_rendering.zig").DynamicRenderingHelper;
const vertex_formats = @import("../vertex_formats.zig");
const MAX_FRAMES_IN_FLIGHT = @import("../../core/swapchain.zig").MAX_FRAMES_IN_FLIGHT;
const Mesh = @import("../mesh.zig").Mesh;
const ecs = @import("../../ecs.zig");
const ShadowSystem = ecs.ShadowSystem;

const RenderSystem = ecs.RenderSystem;

/// Shadow map resolution (square, per face)
pub const SHADOW_MAP_SIZE: u32 = 1024;

/// Maximum number of shadow-casting point lights
pub const MAX_SHADOW_LIGHTS: u32 = 8;

/// Near and far planes for shadow cube projection
const SHADOW_NEAR: f32 = 0.1;
const SHADOW_FAR: f32 = 50.0;

/// Push constants for shadow pass (single-pass with geometry shader)
/// Model matrix + active light count for geometry shader culling
pub const ShadowPushConstants = extern struct {
    model_matrix: [16]f32 = Math.Mat4x4.identity().data,
    num_active_lights: u32 = MAX_SHADOW_LIGHTS,
    _padding: [3]u32 = .{ 0, 0, 0 },
};

/// Re-export ShadowData from ShadowSystem for external consumers
pub const ShadowData = ecs.ShadowData;

/// ShadowMapPass - Renders scene depth from light's perspective using cube shadow maps
///
/// Consumes ShadowSystem for light positions and GPU buffers.
/// ShadowSystem owns and manages the buffers; this pass binds them via resource_binder.
pub const ShadowMapPass = struct {
    base: RenderPass,
    allocator: std.mem.Allocator,

    // Rendering context
    graphics_context: *GraphicsContext,
    pipeline_system: *UnifiedPipelineSystem,
    resource_binder: ResourceBinder,
    texture_manager: *TextureManager,

    // Shadow system (owns light data and GPU buffers)
    shadow_system: *ShadowSystem,

    // Shadow cube texture (owned by this pass via TextureManager)
    shadow_cube: ?*ManagedTexture = null,

    // Pipeline
    shadow_pipeline: PipelineId = undefined,
    cached_pipeline_handle: vk.Pipeline = .null_handle,
    cached_pipeline_layout: vk.PipelineLayout = .null_handle,

    // Render system for getting renderable entities
    render_system: *RenderSystem,

    pub fn create(
        allocator: std.mem.Allocator,
        graphics_context: *GraphicsContext,
        pipeline_system: *UnifiedPipelineSystem,
        texture_manager: *TextureManager,
        render_system: *RenderSystem,
        shadow_system: *ShadowSystem,
    ) !*ShadowMapPass {
        const pass = try allocator.create(ShadowMapPass);
        pass.* = ShadowMapPass{
            .base = RenderPass{
                .name = "shadow_map_pass",
                .enabled = true,
                .vtable = &vtable,
                .dependencies = std.ArrayList([]const u8){},
            },
            .allocator = allocator,
            .graphics_context = graphics_context,
            .pipeline_system = pipeline_system,
            .resource_binder = ResourceBinder.init(allocator, pipeline_system),
            .texture_manager = texture_manager,
            .shadow_system = shadow_system,
            .render_system = render_system,
        };

        // Create shadow map texture during init
        // This ensures it's available when geometry pass binds it
        try pass.createShadowMapTexture();

        log(.INFO, "shadow_map_pass", "Created ShadowMapPass (using ShadowSystem)", .{});
        return pass;
    }

    const vtable = RenderPassVTable{
        .setup = setupImpl,
        .update = updateImpl,
        .execute = executeImpl,
        .teardown = teardownImpl,
        .checkValidity = checkValidityImpl,
        .reset = reset,
    };

    fn setupImpl(base: *RenderPass, graph: *RenderGraph) !void {
        const self: *ShadowMapPass = @fieldParentPtr("base", base);
        _ = graph;

        // Create shadow pipeline with geometry shader for single-pass layered rendering
        const DepthStencilState = @import("../pipeline_builder.zig").DepthStencilState;

        const pipeline_config = PipelineConfig{
            .name = "shadow_map_pass",
            .vertex_shader = "assets/shaders/shadow.vert",
            .geometry_shader = "assets/shaders/shadow.geom", // Broadcasts to all layers
            .fragment_shader = "assets/shaders/shadow.frag",
            .render_pass = .null_handle, // Dynamic rendering
            .vertex_input_bindings = vertex_formats.mesh_bindings[0..],
            .vertex_input_attributes = vertex_formats.mesh_attributes[0..],
            .cull_mode = .{ .back_bit = true }, // Cull back faces - render front faces
            .front_face = .counter_clockwise,
            .depth_stencil_state = DepthStencilState{
                .depth_test_enable = true,
                .depth_write_enable = true,
                .depth_compare_op = .less,
                .stencil_test_enable = false,
            },
            .dynamic_rendering_color_formats = &[_]vk.Format{}, // No color output
            .dynamic_rendering_depth_format = .d32_sfloat,
            .dynamic_rendering_view_mask = 0, // No multiview - geometry shader handles layers
            .push_constant_ranges = &[_]vk.PushConstantRange{.{
                .stage_flags = .{ .vertex_bit = true, .geometry_bit = true, .fragment_bit = true },
                .offset = 0,
                .size = @sizeOf(ShadowPushConstants),
            }},
        };

        const result = try self.pipeline_system.createPipeline(pipeline_config);
        self.shadow_pipeline = result.id;

        if (!result.success) {
            log(.WARN, "shadow_map_pass", "Pipeline creation failed, will retry on hot-reload", .{});
            return;
        }

        const pipeline_entry = self.pipeline_system.pipelines.get(self.shadow_pipeline) orelse return error.PipelineNotFound;
        self.cached_pipeline_handle = pipeline_entry.vulkan_pipeline;
        self.cached_pipeline_layout = try self.pipeline_system.getPipelineLayout(self.shadow_pipeline);

        // Populate ResourceBinder with shader reflection data for SSBO binding
        if (try self.pipeline_system.getPipelineReflection(self.shadow_pipeline)) |reflection| {
            var mut_reflection = reflection;
            try self.resource_binder.populateFromReflection(mut_reflection);
            mut_reflection.deinit(self.allocator);
        }

        // Bind resources (SSBO from ShadowSystem)
        try self.bindResources();
        self.pipeline_system.markPipelineResourcesDirty(self.shadow_pipeline);

        log(.INFO, "shadow_map_pass", "Setup complete - shadow cube array {}x{} per face, {} lights max", .{
            SHADOW_MAP_SIZE,
            SHADOW_MAP_SIZE,
            MAX_SHADOW_LIGHTS,
        });
    }

    fn createShadowMapTexture(self: *ShadowMapPass) !void {
        // Create cube depth ARRAY texture for multi-light shadow mapping with multiview
        // Memory layout: [face0_light0..N, face1_light0..N, ...] optimized for multiview
        self.shadow_cube = try self.texture_manager.createCubeDepthArrayTexture(
            "shadowArrayMap",
            SHADOW_MAP_SIZE,
            MAX_SHADOW_LIGHTS, // One cube per light
            .d32_sfloat,
            true, // compare_enable for PCF
            .less_or_equal, // Lit if fragment depth <= stored depth (closer to light)
        );

        log(.INFO, "shadow_map_pass", "Created cube array shadow map for {} lights", .{MAX_SHADOW_LIGHTS});
    }

    fn updateImpl(base: *RenderPass, frame_info: *const FrameInfo) !void {
        const self: *ShadowMapPass = @fieldParentPtr("base", base);

        // Check for pipeline hot-reload
        const pipeline_entry = self.pipeline_system.pipelines.get(self.shadow_pipeline) orelse return;
        const pipeline_rebuilt = pipeline_entry.vulkan_pipeline != self.cached_pipeline_handle;

        if (pipeline_rebuilt) {
            log(.INFO, "shadow_map_pass", "Pipeline hot-reloaded, rebinding resources", .{});
            self.cached_pipeline_handle = pipeline_entry.vulkan_pipeline;
            self.cached_pipeline_layout = try self.pipeline_system.getPipelineLayout(self.shadow_pipeline);
            self.resource_binder.clearPipeline(self.shadow_pipeline);

            // Rebind after hot reload
            try self.bindResources();
        }

        // Update descriptors - checks for generation changes and rebinds if needed
        try self.resource_binder.updateFrame(self.shadow_pipeline, frame_info.current_frame);
    }

    /// Bind resources once during setup - ResourceBinder tracks changes automatically
    fn bindResources(self: *ShadowMapPass) !void {
        // Bind shadow data SSBO from ShadowSystem (per-frame buffers)
        try self.resource_binder.bindStorageBufferArrayNamed(
            self.shadow_pipeline,
            "ShadowDataSSBO",
            self.shadow_system.shadow_data_buffers,
        );

        log(.INFO, "shadow_map_pass", "Bound ShadowDataSSBO from ShadowSystem", .{});
    }

    fn executeImpl(base: *RenderPass, frame_info: FrameInfo) !void {
        const self: *ShadowMapPass = @fieldParentPtr("base", base);

        // Skip if no shadow-casting lights (check from ShadowSystem)
        const active_light_count = self.shadow_system.getActiveLightCount();
        if (active_light_count == 0) return;

        // Skip if shadow cube not ready
        const shadow_cube = self.shadow_cube orelse return;
        if (shadow_cube.generation == 0) return;

        const cmd = frame_info.command_buffer;

        // Bind pipeline with all descriptor sets (SSBO binding handled by resource_binder.updateFrame)
        try self.pipeline_system.bindPipelineWithDescriptorSets(cmd, self.shadow_pipeline, frame_info.current_frame);

        // Single-pass rendering using geometry shader with invocations
        try self.renderAllFacesAndLights(cmd, shadow_cube, active_light_count);
    }

    /// Render all cube faces for ALL lights in a single render pass
    /// Uses geometry shader with invocations to broadcast to all 48 layers
    fn renderAllFacesAndLights(
        self: *ShadowMapPass,
        cmd: vk.CommandBuffer,
        shadow_cube: *ManagedTexture,
        active_light_count: u32,
    ) !void {
        const gc = self.graphics_context;

        // Get the full array view covering all layers (6 faces × MAX_LIGHTS = 48)
        const full_view = shadow_cube.getFullArrayView();
        const extent = vk.Extent2D{ .width = SHADOW_MAP_SIZE, .height = SHADOW_MAP_SIZE };
        const total_layers: u32 = 6 * MAX_SHADOW_LIGHTS;

        // Use layered rendering with all 48 layers
        // Geometry shader's gl_Layer output selects the target layer
        const helper = DynamicRenderingHelper.initDepthOnly(
            full_view,
            extent,
            1.0, // clear depth to 1.0 (far)
            0, // No multiview
            total_layers, // All 48 layers accessible
        );

        helper.begin(gc, cmd);
        try self.renderShadowCasters(cmd, active_light_count);
        helper.end(gc, cmd);
    }

    /// Render all shadow casters - geometry shader broadcasts to all 6 faces
    /// Each mesh is drawn with instanceCount = numActiveLights
    fn renderShadowCasters(self: *ShadowMapPass, cmd: vk.CommandBuffer, active_light_count: u32) !void {
        const gc = self.graphics_context;

        // Early exit if no lights
        if (active_light_count == 0) return;

        // Get pipeline layout from pipeline system
        const pipeline_layout = try self.pipeline_system.getPipelineLayout(self.shadow_pipeline);

        // Get rasterization data from render system
        const raster_data = try self.render_system.getRasterData();

        // Render all material sets (opaque, transparent, etc.)
        for (raster_data.batch_lists) |batch_list| {
            const batches = batch_list.batches;

            for (batches) |batch| {
                if (!batch.visible) continue;

                const mesh = batch.mesh_handle.getMesh();

                // Bind vertex buffer (required)
                const vb = mesh.vertex_buffer orelse continue;
                const vertex_buffers = [_]vk.Buffer{vb.buffer};
                const offsets = [_]vk.DeviceSize{0};
                gc.vkd.cmdBindVertexBuffers(cmd, 0, 1, &vertex_buffers, &offsets);

                // Bind index buffer if present
                if (mesh.index_buffer) |ib| {
                    gc.vkd.cmdBindIndexBuffer(cmd, ib.buffer, 0, .uint32);
                }

                // Draw each mesh with instanceCount = active_light_count
                // Each instance renders to one light, geometry shader broadcasts to 6 faces
                for (batch.instances) |instance| {
                    const push_constants = ShadowPushConstants{
                        .model_matrix = instance.transform,
                        .num_active_lights = active_light_count,
                    };

                    gc.vkd.cmdPushConstants(
                        cmd,
                        pipeline_layout,
                        .{ .vertex_bit = true, .geometry_bit = true, .fragment_bit = true },
                        0,
                        @sizeOf(ShadowPushConstants),
                        std.mem.asBytes(&push_constants),
                    );

                    // Draw with instanceCount = active lights
                    // Vertex shader: gl_InstanceIndex = light index
                    // Geometry shader: 6 invocations per primitive = 6 faces
                    if (mesh.index_buffer != null) {
                        gc.vkd.cmdDrawIndexed(cmd, @intCast(mesh.indices.items.len), active_light_count, 0, 0, 0);
                    } else {
                        gc.vkd.cmdDraw(cmd, @intCast(mesh.vertices.items.len), active_light_count, 0, 0);
                    }
                }
            }
        }
    }

    fn checkValidityImpl(base: *RenderPass) bool {
        const self: *ShadowMapPass = @fieldParentPtr("base", base);
        return self.pipeline_system.pipelines.contains(self.shadow_pipeline);
    }

    fn teardownImpl(base: *RenderPass) void {
        const self: *ShadowMapPass = @fieldParentPtr("base", base);

        // Shadow cube texture is managed by TextureManager
        // Buffers are owned by ShadowSystem, not this pass

        if (self.shadow_cube) |cube| {
            self.texture_manager.destroyTexture(cube);
        }

        self.resource_binder.deinit();
        self.allocator.destroy(self);

        log(.INFO, "shadow_map_pass", "Teardown complete", .{});
    }

    fn reset(ctx: *RenderPass) void {
        const self: *ShadowMapPass = @fieldParentPtr("base", ctx);
        self.resource_binder.clear();

        if (self.cached_pipeline_handle != .null_handle) {
            self.pipeline_system.destroyPipeline(self.shadow_pipeline);
            self.cached_pipeline_handle = .null_handle;
        }

        log(.INFO, "shadow_map_pass", "Reset resources", .{});
    }

    // Public API for other passes to access shadow data

    /// Get the shadow cube texture for binding in geometry pass
    /// The ManagedTexture (with is_cube=true) includes the comparison sampler for PCF
    pub fn getShadowCube(self: *ShadowMapPass) ?*ManagedTexture {
        return self.shadow_cube;
    }

    /// Get shadow data for the current frame (from ShadowSystem)
    pub fn getShadowData(self: *ShadowMapPass) *const ShadowData {
        return self.shadow_system.getLegacyShadowData();
    }

    /// Get shadow data buffer for a specific frame (from ShadowSystem)
    pub fn getShadowDataBuffer(self: *ShadowMapPass, frame: u32) ?*ManagedBuffer {
        return self.shadow_system.getShadowDataBuffer(frame);
    }
};
