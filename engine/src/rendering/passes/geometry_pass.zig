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
const BufferManager = @import("../buffer_manager.zig").BufferManager;
const ManagedBuffer = @import("../buffer_manager.zig").ManagedBuffer;
const TextureDescriptorManager = @import("../texture_descriptor_manager.zig").TextureDescriptorManager;
const AssetManager = @import("../../assets/asset_manager.zig").AssetManager;
const MaterialSystem = @import("../../ecs/systems/material_system.zig").MaterialSystem;
const MaterialSetData = @import("../../ecs/systems/material_system.zig").MaterialSetData;
const vertex_formats = @import("../vertex_formats.zig");
const MAX_FRAMES_IN_FLIGHT = @import("../../core/swapchain.zig").MAX_FRAMES_IN_FLIGHT;
const DynamicRenderingHelper = @import("../../utils/dynamic_rendering.zig").DynamicRenderingHelper;
const ecs = @import("../../ecs.zig");
const GlobalUboSet = @import("../ubo_set.zig").GlobalUboSet;
const render_data_types = @import("../render_data_types.zig");
const Mesh = @import("../mesh.zig").Mesh;

const World = ecs.World;
const RenderSystem = ecs.RenderSystem;
const ShadowMapPass = @import("shadow_map_pass.zig").ShadowMapPass;

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
    buffer_manager: *BufferManager,
    asset_manager: *AssetManager,
    ecs_world: *World,
    global_ubo_set: *GlobalUboSet,

    // Material set data for this pass - direct access to buffers and textures
    material_set: *MaterialSetData,
    descriptor_manager: *TextureDescriptorManager,

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

    // Shadow pass for accessing shadow map texture
    shadow_pass: ?*ShadowMapPass = null,

    // Target material set name (e.g. "opaque", "transparent")
    target_set_name: []const u8,

    pub fn create(
        allocator: std.mem.Allocator,
        graphics_context: *GraphicsContext,
        pipeline_system: *UnifiedPipelineSystem,
        buffer_manager: *BufferManager,
        asset_manager: *AssetManager,
        ecs_world: *World,
        global_ubo_set: *GlobalUboSet,
        material_set: *MaterialSetData,
        descriptor_manager: *TextureDescriptorManager,
        swapchain_color_format: vk.Format,
        swapchain_depth_format: vk.Format,
        render_system: *RenderSystem,
        pass_name: []const u8,
        target_set_name: []const u8,
    ) !*GeometryPass {
        const pass = try allocator.create(GeometryPass);
        pass.* = GeometryPass{
            .base = RenderPass{
                .name = pass_name,
                .enabled = true,
                .vtable = &vtable,
                .dependencies = std.ArrayList([]const u8){},
            },
            .allocator = allocator,
            .graphics_context = graphics_context,
            .pipeline_system = pipeline_system,
            .resource_binder = ResourceBinder.init(allocator, pipeline_system),
            .buffer_manager = buffer_manager,
            .asset_manager = asset_manager,
            .ecs_world = ecs_world,
            .global_ubo_set = global_ubo_set,
            .material_set = material_set,
            .descriptor_manager = descriptor_manager,
            .swapchain_color_format = swapchain_color_format,
            .swapchain_depth_format = swapchain_depth_format,
            .render_system = render_system,
            .target_set_name = target_set_name,
        };

        log(.INFO, "geometry_pass", "Created geometry pass '{s}' for set '{s}'", .{ pass_name, target_set_name });
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

        // Update descriptors - checks for generation changes and rebinds if needed
        try self.resource_binder.updateFrame(self.geometry_pipeline, frame_info.current_frame);
    }

    /// Bind resources once during setup - ResourceBinder tracks changes automatically
    fn bindResources(self: *GeometryPass) !void {
        // Bind material buffers (per-frame array for arena allocation)
        // ResourceBinder will use pending_bind_mask to bind only frames that need updates
        try self.resource_binder.bindStorageBufferArrayNamed(
            self.geometry_pipeline,
            "MaterialBuffer",
            self.material_set.material_buffers,
        );

        // Bind texture array from material set (generation tracked automatically)
        try self.resource_binder.bindTextureArrayNamed(
            self.geometry_pipeline,
            "textures",
            &self.material_set.texture_arrays,
            self.descriptor_manager,
        );

        // Bind global UBO for all frames (generation tracked automatically)
        // Takes array of 3 ManagedBuffers (one per frame-in-flight)
        try self.resource_binder.bindUniformBufferNamed(
            self.geometry_pipeline,
            "GlobalUbo",
            self.global_ubo_set.frame_buffers,
        );

        // Bind shadow data UBO and shadow map if shadow pass is available
        log(.INFO, "geometry_pass", "bindResources: shadow_pass = {}", .{@intFromPtr(self.shadow_pass)});
        if (self.shadow_pass) |shadow_pass| {
            // Bind shadow data buffer (light space matrix, bias, enabled flag)
            var shadow_buffers: [MAX_FRAMES_IN_FLIGHT]*const ManagedBuffer = undefined;
            for (0..MAX_FRAMES_IN_FLIGHT) |i| {
                if (shadow_pass.getShadowDataBuffer(@intCast(i))) |buf| {
                    shadow_buffers[i] = buf;
                }
            }

            self.resource_binder.bindUniformBufferNamed(
                self.geometry_pipeline,
                "ShadowUbo",
                shadow_buffers,
            ) catch |err| {
                log(.WARN, "geometry_pass", "Failed to bind ShadowUbo: {}", .{err});
            };

            // Bind shadow cube texture with comparison sampler
            if (shadow_pass.getShadowCube()) |shadow_cube| {
                try self.resource_binder.bindTextureNamed(
                    self.geometry_pipeline,
                    "shadowCubeMap",
                    shadow_cube,
                );
            }
        } else {
            log(.WARN, "geometry_pass", "No shadow_pass available during bindResources", .{});
        }

        // Bind instance data SSBO from render system (generation tracked automatically)
        // RenderSystem owns and manages this buffer (starts as dummy, gets replaced when instances exist)
        // Buffer is guaranteed to exist after Scene.initRenderGraph()
        // Pass all frame buffers for per-frame binding
        var instance_buf_ptrs: [MAX_FRAMES_IN_FLIGHT]*const ManagedBuffer = undefined;
        for (self.render_system.instance_buffers, 0..) |buf, i| {
            instance_buf_ptrs[i] = buf;
        }
        try self.resource_binder.bindStorageBufferArrayNamed(
            self.geometry_pipeline,
            "InstanceDataBuffer",
            instance_buf_ptrs,
        );
    }

    fn executeImpl(base: *RenderPass, frame_info: FrameInfo) !void {
        const self: *GeometryPass = @fieldParentPtr("base", base);
        const cmd = frame_info.command_buffer;
        const frame_index = frame_info.current_frame;

        // Get rasterization data from render system (cached, no asset manager queries needed)
        const raster_data = try self.render_system.getRasterData();

        // Get batches for this specific material set (e.g. "opaque")
        const batches = raster_data.getBatches(self.target_set_name);

        // Setup dynamic rendering with LOAD (skybox already rendered, don't clear)
        const rendering = DynamicRenderingHelper.initLoad(
            frame_info.hdr_texture.?.image_view,
            frame_info.depth_image_view,
            frame_info.extent,
        );

        // Begin rendering (also sets viewport and scissor) - always do this to clear the framebuffer
        rendering.begin(self.graphics_context, cmd);

        if (batches.len == 0) {
            // No geometry to draw, but we still cleared the framebuffer
            rendering.end(self.graphics_context, cmd);
            return;
        }

        // Bind pipeline with all descriptor sets (Set 0: global UBO, Set 1: materials/textures)
        try self.pipeline_system.bindPipelineWithDescriptorSets(cmd, self.geometry_pipeline, frame_index);

        // Get pipeline layout from pipeline system (ensures we use the correct layout even during hot-reload)
        const pipeline_layout = try self.pipeline_system.getPipelineLayout(self.geometry_pipeline);

        // TRUE INSTANCED RENDERING: Single draw call per unique mesh
        // Instance data read from SSBO using gl_InstanceIndex + push constant offset

        // Calculate total instances for bounds validation
        var total_instance_count: u32 = 0;
        for (batches) |batch| {
            if (batch.visible) {
                total_instance_count += @as(u32, @intCast(batch.instances.len));
            }
        }

        for (batches) |batch| {
            if (!batch.visible) continue;

            const mesh = batch.mesh_handle.getMesh();
            const instance_count: u32 = @intCast(batch.instances.len);

            // Use pre-computed instance buffer offset from batch
            // This correctly handles frustum culling where some objects are skipped
            const push_constants = GeometryPushConstants{
                .instance_offset = batch.instance_buffer_offset,
            };
            self.graphics_context.vkd.cmdPushConstants(
                cmd,
                pipeline_layout,
                vk.ShaderStageFlags{ .vertex_bit = true, .fragment_bit = true },
                0,
                @sizeOf(GeometryPushConstants),
                @ptrCast(&push_constants),
            );

            // Draw all instances of this mesh in a single draw call
            // Shader reads instance_data[gl_InstanceIndex + push_constants.instance_offset]
            mesh.drawInstanced(
                self.graphics_context.*,
                cmd,
                instance_count, // Draw all instances at once
                0, // firstInstance = 0 (offset handled by push constant)
            );
        }

        // End rendering
        rendering.end(self.graphics_context, cmd);
    }

    fn teardownImpl(base: *RenderPass) void {
        const self: *GeometryPass = @fieldParentPtr("base", base);
        log(.INFO, "geometry_pass", "Tearing down", .{});

        // render_system is shared with scene, don't deinit here
        // instance_buffer is owned by render_system, not freed here

        // Clean up resource binder
        self.resource_binder.deinit();

        // Pipeline cleanup handled by UnifiedPipelineSystem
        self.allocator.destroy(self);
        log(.INFO, "geometry_pass", "Teardown complete", .{});
    }

    /// Reset pass state and release resources
    /// Called when the render graph is reset (e.g. scene change)
    /// Clears resource bindings and destroys pipeline to prevent dangling references
    fn reset(ctx: *RenderPass) void {
        const self: *GeometryPass = @fieldParentPtr("base", ctx);
        self.resource_binder.clear();

        // Destroy the old pipeline to avoid dangling resources
        if (self.cached_pipeline_handle != .null_handle) {
            self.pipeline_system.destroyPipeline(self.geometry_pipeline);
            self.cached_pipeline_handle = .null_handle;
        }

        log(.INFO, "geometry_pass", "Reset resources", .{});
    }
};

/// Push constants for geometry pass
pub const GeometryPushConstants = extern struct {
    transform: [16]f32 = Math.Mat4x4.identity().data,
    normal_matrix: [16]f32 = Math.Mat4x4.identity().data,
    material_index: u32 = 0,
    instance_offset: u32 = 0, // For instanced rendering: offset into instance buffer
};
