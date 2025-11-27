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
const BufferManager = @import("../buffer_manager.zig").BufferManager;
const ManagedBuffer = @import("../buffer_manager.zig").ManagedBuffer;
const TextureManager = @import("../texture_manager.zig").TextureManager;
const ManagedTexture = @import("../texture_manager.zig").ManagedTexture;
const vertex_formats = @import("../vertex_formats.zig");
const MAX_FRAMES_IN_FLIGHT = @import("../../core/swapchain.zig").MAX_FRAMES_IN_FLIGHT;
const Mesh = @import("../mesh.zig").Mesh;
const ecs = @import("../../ecs.zig");

const World = ecs.World;
const RenderSystem = ecs.RenderSystem;
const PointLight = ecs.PointLight;
const Transform = ecs.Transform;

/// Shadow map resolution (square)
pub const SHADOW_MAP_SIZE: u32 = 2048;

/// Push constants for shadow pass (just model matrix multiplied by lightSpaceMatrix)
pub const ShadowPushConstants = extern struct {
    light_space_model: [16]f32 = Math.Mat4x4.identity().data,
};

/// Shadow data to pass to main rendering (add to GlobalUbo or separate buffer)
pub const ShadowData = extern struct {
    light_space_matrix: [16]f32 = Math.Mat4x4.identity().data,
    shadow_bias: f32 = 0.005,
    shadow_enabled: u32 = 0,
    _padding: [2]f32 = .{ 0, 0 },
};

/// ShadowMapPass - Renders scene depth from light's perspective
///
/// Creates a depth-only render target that geometry pass can sample
/// Currently supports the first shadow-casting point light (omnidirectional approximated as directional)
pub const ShadowMapPass = struct {
    base: RenderPass,
    allocator: std.mem.Allocator,

    // Rendering context
    graphics_context: *GraphicsContext,
    pipeline_system: *UnifiedPipelineSystem,
    resource_binder: ResourceBinder,
    buffer_manager: *BufferManager,
    texture_manager: *TextureManager,
    ecs_world: *World,

    // Shadow map resources (custom sampler is stored in ManagedTexture)
    shadow_map: ?*ManagedTexture = null,

    // Shadow data buffer (light-space matrix, bias, etc.)
    shadow_data_buffers: [MAX_FRAMES_IN_FLIGHT]?*ManagedBuffer = .{null} ** MAX_FRAMES_IN_FLIGHT,

    // Pipeline
    shadow_pipeline: PipelineId = undefined,
    cached_pipeline_handle: vk.Pipeline = .null_handle,
    cached_pipeline_layout: vk.PipelineLayout = .null_handle,

    // Render system for getting renderable entities
    render_system: *RenderSystem,

    // Current shadow data (updated each frame)
    current_shadow_data: ShadowData = .{},
    // Cached light space matrix as Mat4x4 for efficient access during rendering
    light_space_matrix: Math.Mat4x4 = Math.Mat4x4.identity(),

    pub fn create(
        allocator: std.mem.Allocator,
        graphics_context: *GraphicsContext,
        pipeline_system: *UnifiedPipelineSystem,
        buffer_manager: *BufferManager,
        texture_manager: *TextureManager,
        ecs_world: *World,
        render_system: *RenderSystem,
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
            .buffer_manager = buffer_manager,
            .texture_manager = texture_manager,
            .ecs_world = ecs_world,
            .render_system = render_system,
        };

        // Create shadow map texture and data buffers during init
        // This ensures they're available when geometry pass binds them
        try pass.createShadowMapTexture();
        try pass.createShadowDataBuffers();

        log(.INFO, "shadow_map_pass", "Created ShadowMapPass", .{});
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

        // Create depth-only pipeline
        const DepthStencilState = @import("../pipeline_builder.zig").DepthStencilState;

        const pipeline_config = PipelineConfig{
            .name = "shadow_map_pass",
            .vertex_shader = "assets/shaders/shadow.vert",
            .fragment_shader = null, // Depth-only, no fragment shader needed
            .render_pass = .null_handle, // Dynamic rendering
            .vertex_input_bindings = vertex_formats.mesh_bindings[0..],
            .vertex_input_attributes = vertex_formats.mesh_attributes[0..],
            .cull_mode = .{ .front_bit = true }, // Cull front faces to reduce shadow acne
            .front_face = .counter_clockwise,
            .depth_stencil_state = DepthStencilState{
                .depth_test_enable = true,
                .depth_write_enable = true,
                .depth_compare_op = .less,
                .stencil_test_enable = false,
            },
            .dynamic_rendering_color_formats = &[_]vk.Format{}, // No color output
            .dynamic_rendering_depth_format = .d32_sfloat,
            .push_constant_ranges = &[_]vk.PushConstantRange{.{
                .stage_flags = .{ .vertex_bit = true },
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

        // Shadow pass uses only push constants (no descriptor bindings needed)
        // The shadow map texture and ShadowUbo are consumed by geometry_pass, not here

        log(.INFO, "shadow_map_pass", "Setup complete - shadow map {}x{}", .{ SHADOW_MAP_SIZE, SHADOW_MAP_SIZE });
    }

    fn createShadowMapTexture(self: *ShadowMapPass) !void {
        const TextureConfig = @import("../texture_manager.zig").TextureConfig;
        const SamplerConfig = @import("../texture_manager.zig").TextureManager.SamplerConfig;

        // Create depth texture with comparison sampler for shadow mapping (PCF)
        self.shadow_map = try self.texture_manager.createTextureWithSampler(
            TextureConfig{
                .name = "shadow_map",
                .format = .d32_sfloat,
                .extent = .{ .width = SHADOW_MAP_SIZE, .height = SHADOW_MAP_SIZE, .depth = 1 },
                .usage = .{ .depth_stencil_attachment_bit = true, .sampled_bit = true },
                .samples = .{ .@"1_bit" = true },
            },
            SamplerConfig{
                .mag_filter = .linear,
                .min_filter = .linear,
                .mipmap_mode = .nearest,
                .address_mode_u = .clamp_to_border,
                .address_mode_v = .clamp_to_border,
                .address_mode_w = .clamp_to_border,
                .border_color = .float_opaque_white, // Outside shadow = lit
                .compare_enable = true, // Enable depth comparison for PCF
                .compare_op = .less_or_equal,
            },
        );

        log(.INFO, "shadow_map_pass", "Created shadow map texture with comparison sampler", .{});
    }

    fn createShadowDataBuffers(self: *ShadowMapPass) !void {
        const BufferConfig = @import("../buffer_manager.zig").BufferConfig;

        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            const config = BufferConfig{
                .name = "ShadowData",
                .size = @sizeOf(ShadowData),
                .strategy = .host_visible,
                .usage = .{ .uniform_buffer_bit = true },
            };
            self.shadow_data_buffers[i] = try self.buffer_manager.createBuffer(config, @intCast(i));
        }
    }

    fn updateImpl(base: *RenderPass, frame_info: *const FrameInfo) !void {
        const self: *ShadowMapPass = @fieldParentPtr("base", base);

        // Find first shadow-casting light
        var light_pos: Math.Vec3 = Math.Vec3.init(0, 10, 0); // Default light position
        var found_shadow_light = false;

        // Query for entities with Transform and PointLight
        var query = self.ecs_world.query(struct {
            transform: *Transform,
            light: *PointLight,
        }) catch |err| {
            log(.WARN, "shadow_map_pass", "Failed to query lights: {}", .{err});
            return;
        };
        defer query.deinit();

        while (query.next()) |data| {
            if (data.light.cast_shadows) {
                light_pos = Math.Vec3.init(data.transform.position.x, data.transform.position.y, data.transform.position.z);
                found_shadow_light = true;
                break;
            }
        }

        // Calculate light-space matrix
        // For point lights, we approximate with a directional projection looking at scene center
        const light_target = Math.Vec3.init(0, 0, 0); // Look at origin
        const light_up = Math.Vec3.init(0, 1, 0);

        // Orthographic projection for directional-style shadows
        const shadow_extent: f32 = 50.0; // Scene bounds for shadow map
        const near_plane: f32 = 0.1;
        const far_plane: f32 = 100.0;

        const light_view = Math.Mat4x4.lookAt(light_pos, light_target, light_up);

        // Build orthographic projection matrix manually
        // Using Vulkan clip space conventions (Y-down, Z 0-1)
        const left = -shadow_extent;
        const right = shadow_extent;
        const bottom = -shadow_extent;
        const top = shadow_extent;
        var light_projection = Math.Mat4x4.identity();
        light_projection.data[0] = 2.0 / (right - left);
        light_projection.data[5] = 2.0 / (bottom - top); // Vulkan Y flip
        light_projection.data[10] = 1.0 / (far_plane - near_plane);
        light_projection.data[12] = -(right + left) / (right - left);
        light_projection.data[13] = -(bottom + top) / (bottom - top);
        light_projection.data[14] = -near_plane / (far_plane - near_plane);

        // Store the combined light-space matrix
        const light_space_mat = light_projection.mul(light_view);
        self.light_space_matrix = light_space_mat; // Cache for rendering
        self.current_shadow_data = ShadowData{
            .light_space_matrix = light_space_mat.data,
            .shadow_bias = 0.005,
            .shadow_enabled = if (found_shadow_light) 1 else 0,
        };

        // Update shadow data buffer for this frame
        const frame_index = frame_info.current_frame;
        if (self.shadow_data_buffers[frame_index]) |buffer| {
            const data = std.mem.asBytes(&self.current_shadow_data);
            try self.buffer_manager.updateBuffer(buffer, data, frame_index);
        }

        // Check for pipeline hot-reload
        const pipeline_entry = self.pipeline_system.pipelines.get(self.shadow_pipeline) orelse return;
        if (pipeline_entry.vulkan_pipeline != self.cached_pipeline_handle) {
            log(.INFO, "shadow_map_pass", "Pipeline hot-reloaded", .{});
            self.cached_pipeline_handle = pipeline_entry.vulkan_pipeline;
            self.cached_pipeline_layout = try self.pipeline_system.getPipelineLayout(self.shadow_pipeline);
        }
    }

    fn executeImpl(base: *RenderPass, frame_info: FrameInfo) !void {
        const self: *ShadowMapPass = @fieldParentPtr("base", base);

        // Skip if no shadow-casting lights
        if (self.current_shadow_data.shadow_enabled == 0) return;

        // Skip if shadow map not ready
        const shadow_map = self.shadow_map orelse return;
        if (shadow_map.generation == 0) return;

        const cmd = frame_info.command_buffer;
        const gc = self.graphics_context;

        // Begin dynamic rendering for depth-only pass
        const depth_attachment = vk.RenderingAttachmentInfo{
            .s_type = .rendering_attachment_info,
            .image_view = shadow_map.texture.image_view,
            .image_layout = .general,
            .resolve_mode = .{},
            .resolve_image_layout = .undefined,
            .resolve_image_view = .null_handle,
            .load_op = .clear,
            .store_op = .store,
            .clear_value = .{ .depth_stencil = .{ .depth = 1.0, .stencil = 0 } },
            .p_next = null,
        };

        const rendering_info = vk.RenderingInfo{
            .s_type = .rendering_info,
            .render_area = .{
                .offset = .{ .x = 0, .y = 0 },
                .extent = .{ .width = SHADOW_MAP_SIZE, .height = SHADOW_MAP_SIZE },
            },
            .layer_count = 1,
            .view_mask = 0,
            .color_attachment_count = 0,
            .p_color_attachments = null,
            .p_depth_attachment = &depth_attachment,
            .p_stencil_attachment = null,
            .flags = .{},
            .p_next = null,
        };

        gc.vkd.cmdBeginRendering(cmd, &rendering_info);

        // Set viewport and scissor for shadow map
        const viewport = vk.Viewport{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(SHADOW_MAP_SIZE),
            .height = @floatFromInt(SHADOW_MAP_SIZE),
            .min_depth = 0.0,
            .max_depth = 1.0,
        };
        gc.vkd.cmdSetViewport(cmd, 0, 1, @ptrCast(&viewport));

        const scissor = vk.Rect2D{
            .offset = .{ .x = 0, .y = 0 },
            .extent = .{ .width = SHADOW_MAP_SIZE, .height = SHADOW_MAP_SIZE },
        };
        gc.vkd.cmdSetScissor(cmd, 0, 1, @ptrCast(&scissor));

        // Bind shadow pipeline
        if (self.cached_pipeline_handle != .null_handle) {
            gc.vkd.cmdBindPipeline(cmd, .graphics, self.cached_pipeline_handle);

            // Render shadow casters
            try self.renderShadowCasters(cmd, frame_info);
        }

        gc.vkd.cmdEndRendering(cmd);
    }

    fn renderShadowCasters(self: *ShadowMapPass, cmd: vk.CommandBuffer, frame_info: FrameInfo) !void {
        const gc = self.graphics_context;
        _ = frame_info;

        // Get rasterization data from render system
        const raster_data = try self.render_system.getRasterData();

        // Render all material sets (opaque, transparent, etc.)
        for (raster_data.batch_lists) |batch_list| {
            const batches = batch_list.batches;

            for (batches) |batch| {
                if (!batch.visible) continue;

                const mesh = batch.mesh_handle.getMesh();

                // Bind vertex buffer
                // Bind vertex buffer (required)
                const vb = mesh.vertex_buffer orelse continue;
                const vertex_buffers = [_]vk.Buffer{vb.buffer};
                const offsets = [_]vk.DeviceSize{0};
                gc.vkd.cmdBindVertexBuffers(cmd, 0, 1, &vertex_buffers, &offsets);

                // Bind index buffer if present
                if (mesh.index_buffer) |ib| {
                    gc.vkd.cmdBindIndexBuffer(cmd, ib.buffer, 0, .uint32);
                }

                // Draw each instance with its transform
                for (batch.instances) |instance| {
                    // Build model matrix from instance data (already in [16]f32 format)
                    const model_matrix = Math.Mat4x4{
                        .data = instance.transform,
                    };

                    // Push lightSpaceMatrix * modelMatrix
                    const push_constants = ShadowPushConstants{
                        .light_space_model = self.light_space_matrix.mul(model_matrix).data,
                    };

                    gc.vkd.cmdPushConstants(
                        cmd,
                        self.cached_pipeline_layout,
                        .{ .vertex_bit = true },
                        0,
                        @sizeOf(ShadowPushConstants),
                        std.mem.asBytes(&push_constants),
                    );

                    // Draw
                    if (mesh.index_buffer != null) {
                        gc.vkd.cmdDrawIndexed(cmd, @intCast(mesh.indices.items.len), 1, 0, 0, 0);
                    } else {
                        gc.vkd.cmdDraw(cmd, @intCast(mesh.vertices.items.len), 1, 0, 0);
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

        // Shadow map texture and its custom sampler are managed by TextureManager

        // Destroy shadow data buffers
        for (self.shadow_data_buffers) |buffer_opt| {
            if (buffer_opt) |buffer| {
                self.buffer_manager.destroyBuffer(buffer) catch {};
            }
        }

        self.texture_manager.*.destroyTexture(self.shadow_map.?);

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

    /// Get the shadow map texture for binding in geometry pass
    /// The ManagedTexture includes the custom comparison sampler for PCF
    pub fn getShadowMap(self: *ShadowMapPass) ?*ManagedTexture {
        return self.shadow_map;
    }

    /// Get shadow data for the current frame
    pub fn getShadowData(self: *ShadowMapPass) *const ShadowData {
        return &self.current_shadow_data;
    }

    /// Get shadow data buffer for a specific frame
    pub fn getShadowDataBuffer(self: *ShadowMapPass, frame: u32) ?*ManagedBuffer {
        return self.shadow_data_buffers[frame];
    }
};
