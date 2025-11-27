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

/// Shadow map resolution (square, per face)
pub const SHADOW_MAP_SIZE: u32 = 1024;

/// Near and far planes for shadow cube projection
const SHADOW_NEAR: f32 = 0.1; // Close enough for most scenes
const SHADOW_FAR: f32 = 50.0;

/// Push constants for shadow pass (model matrix + light info + view/proj for current face)
pub const ShadowPushConstants = extern struct {
    model_matrix: [16]f32 = Math.Mat4x4.identity().data,
    light_pos: [4]f32 = .{ 0, 0, 0, 0 }, // xyz = position, w = far plane
    view_proj: [16]f32 = Math.Mat4x4.identity().data, // view * projection for current face
};

/// Shadow data to pass to main rendering
pub const ShadowData = extern struct {
    light_pos: [4]f32 = .{ 0, 0, 0, 0 }, // xyz = position, w = far plane
    shadow_bias: f32 = 0.02,
    shadow_enabled: u32 = 0,
    _padding: [2]f32 = .{ 0, 0 },
};

/// ShadowMapPass - Renders scene depth from light's perspective using cube shadow maps
///
/// Creates a 6-face cube depth texture for omnidirectional point light shadows
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

    // Cube shadow map (ManagedTexture with is_cube = true)
    shadow_cube: ?*ManagedTexture = null,

    // Shadow data buffer (light position, bias, etc.)
    shadow_data_buffers: [MAX_FRAMES_IN_FLIGHT]?*ManagedBuffer = .{null} ** MAX_FRAMES_IN_FLIGHT,

    // Pipeline
    shadow_pipeline: PipelineId = undefined,
    cached_pipeline_handle: vk.Pipeline = .null_handle,
    cached_pipeline_layout: vk.PipelineLayout = .null_handle,

    // Render system for getting renderable entities
    render_system: *RenderSystem,

    // Current shadow data (updated each frame)
    current_shadow_data: ShadowData = .{},
    // Light position cached for rendering
    light_position: Math.Vec3 = Math.Vec3.init(0, 10, 0),

    // 6 face view matrices (computed once per frame)
    face_view_matrices: [6]Math.Mat4x4 = .{Math.Mat4x4.identity()} ** 6,
    // Perspective projection for cube shadow map
    shadow_projection: Math.Mat4x4 = Math.Mat4x4.identity(),

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

        // Create shadow pipeline with fragment shader for linear depth
        const DepthStencilState = @import("../pipeline_builder.zig").DepthStencilState;

        const pipeline_config = PipelineConfig{
            .name = "shadow_map_pass",
            .vertex_shader = "assets/shaders/shadow.vert",
            .fragment_shader = "assets/shaders/shadow.frag", // Fragment shader writes linear depth
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
            .push_constant_ranges = &[_]vk.PushConstantRange{.{
                .stage_flags = .{ .vertex_bit = true, .fragment_bit = true },
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

        log(.INFO, "shadow_map_pass", "Setup complete - shadow cube map {}x{} per face", .{ SHADOW_MAP_SIZE, SHADOW_MAP_SIZE });
    }

    fn createShadowMapTexture(self: *ShadowMapPass) !void {
        // Create cube depth texture with comparison sampler for shadow mapping (PCF)
        self.shadow_cube = try self.texture_manager.createCubeDepthTexture(
            "shadow_cube",
            SHADOW_MAP_SIZE,
            .d32_sfloat,
            true, // compare_enable for PCF
            .less_or_equal, // Lit if fragment depth <= stored depth (closer to light)
        );

        log(.INFO, "shadow_map_pass", "Created cube shadow map texture with comparison sampler", .{});
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

        // Store light position for cube shadow map sampling
        self.light_position = light_pos;
        self.current_shadow_data = ShadowData{
            .light_pos = .{ light_pos.x, light_pos.y, light_pos.z, SHADOW_FAR },
            .shadow_bias = 0.001, // Small bias - normal check handles back faces
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

    /// Build perspective projection matrix for cube shadow map (90 degree FOV)
    /// Uses Vulkan conventions: Z range [0,1], Y flipped
    fn buildShadowProjection() Math.Mat4x4 {
        const aspect: f32 = 1.0; // Square faces
        const fov: f32 = std.math.pi / 2.0; // 90 degrees - required for cube maps
        const near = SHADOW_NEAR;
        const far = SHADOW_FAR;

        const tan_half_fov = @tan(fov / 2.0);
        var proj = Math.Mat4x4.identity();
        proj.data[0] = 1.0 / (aspect * tan_half_fov);
        proj.data[5] = -1.0 / tan_half_fov; // Negative for Vulkan Y-flip
        proj.data[10] = far / (far - near); // Vulkan depth range [0,1]
        proj.data[11] = 1.0;
        proj.data[14] = -(far * near) / (far - near);
        proj.data[15] = 0.0;
        return proj;
    }

    /// Build view matrix for a cube face.
    ///
    /// Cube map face indices: 0=+X, 1=-X, 2=+Y, 3=-Y, 4=+Z, 5=-Z
    ///
    /// Standard cube map convention - look toward face direction.
    fn buildFaceViewMatrix(light_pos: Math.Vec3, face: u32) Math.Mat4x4 {
        // Look toward face direction - but X faces are swapped to match cube map convention
        const directions = [6]Math.Vec3{
            Math.Vec3.init(-1, 0, 0), // Face 0 (+X): look toward -X (swapped)
            Math.Vec3.init(1, 0, 0), // Face 1 (-X): look toward +X (swapped)
            Math.Vec3.init(0, 1, 0), // Face 2 (+Y): look toward +Y
            Math.Vec3.init(0, -1, 0), // Face 3 (-Y): look toward -Y
            Math.Vec3.init(0, 0, 1), // Face 4 (+Z): look toward +Z
            Math.Vec3.init(0, 0, -1), // Face 5 (-Z): look toward -Z
        };

        // Up vectors - standard for cube maps
        const ups = [6]Math.Vec3{
            Math.Vec3.init(0, -1, 0), // +X: up is -Y
            Math.Vec3.init(0, -1, 0), // -X: up is -Y
            Math.Vec3.init(0, 0, 1), // +Y: up is +Z
            Math.Vec3.init(0, 0, -1), // -Y: up is -Z
            Math.Vec3.init(0, -1, 0), // +Z: up is -Y
            Math.Vec3.init(0, -1, 0), // -Z: up is -Y
        };

        const target = Math.Vec3.add(light_pos, directions[face]);
        return Math.Mat4x4.lookAt(light_pos, target, ups[face]);
    }

    fn executeImpl(base: *RenderPass, frame_info: FrameInfo) !void {
        const self: *ShadowMapPass = @fieldParentPtr("base", base);

        // Skip if no shadow-casting lights
        if (self.current_shadow_data.shadow_enabled == 0) return;

        // Skip if shadow cube not ready
        const shadow_cube = self.shadow_cube orelse return;
        if (shadow_cube.generation == 0) return;

        const cmd = frame_info.command_buffer;
        const gc = self.graphics_context;

        // Build projection matrix (same for all faces)
        const projection = buildShadowProjection();

        // Set viewport and scissor (same for all faces)
        const viewport = vk.Viewport{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(SHADOW_MAP_SIZE),
            .height = @floatFromInt(SHADOW_MAP_SIZE),
            .min_depth = 0.0,
            .max_depth = 1.0,
        };

        const scissor = vk.Rect2D{
            .offset = .{ .x = 0, .y = 0 },
            .extent = .{ .width = SHADOW_MAP_SIZE, .height = SHADOW_MAP_SIZE },
        };

        // Render all 6 cube faces
        for (0..6) |face| {
            // Get face view from cube texture
            const face_view = shadow_cube.getFaceView(@intCast(face)) orelse continue;

            // Build view matrix for this face
            const view = buildFaceViewMatrix(self.light_position, @intCast(face));
            const view_proj = projection.mul(view);

            // Begin dynamic rendering for this face
            const depth_attachment = vk.RenderingAttachmentInfo{
                .s_type = .rendering_attachment_info,
                .image_view = face_view,
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
            gc.vkd.cmdSetViewport(cmd, 0, 1, @ptrCast(&viewport));
            gc.vkd.cmdSetScissor(cmd, 0, 1, @ptrCast(&scissor));

            // Bind shadow pipeline
            if (self.cached_pipeline_handle != .null_handle) {
                gc.vkd.cmdBindPipeline(cmd, .graphics, self.cached_pipeline_handle);

                // Render shadow casters for this face
                try self.renderShadowCastersForFace(cmd, view_proj);
            }

            gc.vkd.cmdEndRendering(cmd);
        }
    }

    fn renderShadowCastersForFace(self: *ShadowMapPass, cmd: vk.CommandBuffer, view_proj: Math.Mat4x4) !void {
        const gc = self.graphics_context;

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

                // Draw each instance with its transform
                for (batch.instances) |instance| {
                    // Build model matrix from instance data (already in [16]f32 format)
                    const model_matrix = Math.Mat4x4{
                        .data = instance.transform,
                    };

                    // Push model matrix, light position, and view/proj for this face
                    const push_constants = ShadowPushConstants{
                        .model_matrix = model_matrix.data,
                        .light_pos = .{ self.light_position.x, self.light_position.y, self.light_position.z, SHADOW_FAR },
                        .view_proj = view_proj.data,
                    };

                    gc.vkd.cmdPushConstants(
                        cmd,
                        self.cached_pipeline_layout,
                        .{ .vertex_bit = true, .fragment_bit = true },
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

        // Shadow cube texture is managed by TextureManager

        // Destroy shadow data buffers
        for (self.shadow_data_buffers) |buffer_opt| {
            if (buffer_opt) |buffer| {
                self.buffer_manager.destroyBuffer(buffer) catch {};
            }
        }

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

    /// Get shadow data for the current frame
    pub fn getShadowData(self: *ShadowMapPass) *const ShadowData {
        return &self.current_shadow_data;
    }

    /// Get shadow data buffer for a specific frame
    pub fn getShadowDataBuffer(self: *ShadowMapPass, frame: u32) ?*ManagedBuffer {
        return self.shadow_data_buffers[frame];
    }
};
