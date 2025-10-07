const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("../core/graphics_context.zig").GraphicsContext;
const Camera = @import("../core/camera.zig").Camera;
const UnifiedPipelineSystem = @import("../rendering/unified_pipeline_system.zig").UnifiedPipelineSystem;
const ResourceBinder = @import("../rendering/resource_binder.zig").ResourceBinder;
const PipelineId = @import("../rendering/unified_pipeline_system.zig").PipelineId;
const Buffer = @import("../core/buffer.zig").Buffer;
const Image = @import("../core/image.zig").Image;
const ShaderManager = @import("../assets/shader_manager.zig").ShaderManager;
const MAX_FRAMES_IN_FLIGHT = @import("../core/swapchain.zig").MAX_FRAMES_IN_FLIGHT;
const log = @import("../utils/log.zig").log;

/// Example textured renderer using the unified pipeline system
///
/// This shows how to migrate from the old fragmented approach to the new
/// unified pipeline and descriptor management system.
pub const UnifiedTexturedRenderer = struct {
    allocator: std.mem.Allocator,
    graphics_context: *GraphicsContext,
    shader_manager: *ShaderManager,

    // Unified pipeline system
    pipeline_system: UnifiedPipelineSystem,
    resource_binder: ResourceBinder,

    // Pipeline for textured objects
    textured_pipeline: PipelineId,

    // Uniform buffers (per frame in flight)
    mvp_buffers: [MAX_FRAMES_IN_FLIGHT]*Buffer,
    light_buffers: [MAX_FRAMES_IN_FLIGHT]*Buffer,

    // Default resources
    default_texture: struct {
        image: *Image,
        view: vk.ImageView,
        sampler: vk.Sampler,
    },

    // Hot-reload context
    reload_context: PipelineReloadContext,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        graphics_context: *GraphicsContext,
        shader_manager: *ShaderManager,
        render_pass: vk.RenderPass,
    ) !Self {
        log(.INFO, "unified_textured_renderer", "Initializing unified textured renderer");

        // Initialize unified pipeline system
        var pipeline_system = try UnifiedPipelineSystem.init(allocator, graphics_context, shader_manager);
        const resource_binder = ResourceBinder.init(allocator, &pipeline_system);

        // Create per-frame uniform buffers
        var mvp_buffers: [MAX_FRAMES_IN_FLIGHT]*Buffer = undefined;
        var light_buffers: [MAX_FRAMES_IN_FLIGHT]*Buffer = undefined;

        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            mvp_buffers[i] = try Buffer.create(
                allocator,
                graphics_context,
                @sizeOf(MVPUniformBuffer),
                .{ .uniform_buffer_bit = true },
                .{ .host_visible_bit = true, .host_coherent_bit = true },
            );

            light_buffers[i] = try Buffer.create(
                allocator,
                graphics_context,
                @sizeOf(LightUniformBuffer),
                .{ .uniform_buffer_bit = true },
                .{ .host_visible_bit = true, .host_coherent_bit = true },
            );
        }

        // Create default texture
        const default_texture = try createDefaultTexture(allocator, graphics_context);

        // Create textured pipeline with automatic descriptor layout extraction
        const pipeline_config = UnifiedPipelineSystem.PipelineConfig{
            .name = "textured_objects",
            .vertex_shader = "shaders/textured.vert",
            .fragment_shader = "shaders/textured.frag",
            .render_pass = render_pass,
            .vertex_input_bindings = &[_]@import("../rendering/pipeline_builder.zig").VertexInputBinding{
                .{ .binding = 0, .stride = @sizeOf(TexturedVertex), .input_rate = .vertex },
            },
            .vertex_input_attributes = &[_]@import("../rendering/pipeline_builder.zig").VertexInputAttribute{
                .{ .location = 0, .binding = 0, .format = .r32g32b32_sfloat, .offset = @offsetOf(TexturedVertex, "position") },
                .{ .location = 1, .binding = 0, .format = .r32g32b32_sfloat, .offset = @offsetOf(TexturedVertex, "normal") },
                .{ .location = 2, .binding = 0, .format = .r32g32_sfloat, .offset = @offsetOf(TexturedVertex, "tex_coord") },
            },
            .cull_mode = .{ .back_bit = true },
            .front_face = .counter_clockwise,
        };

        const textured_pipeline = try pipeline_system.createPipeline(pipeline_config);

        var renderer = Self{
            .allocator = allocator,
            .graphics_context = graphics_context,
            .shader_manager = shader_manager,
            .pipeline_system = pipeline_system,
            .resource_binder = resource_binder,
            .textured_pipeline = textured_pipeline,
            .mvp_buffers = mvp_buffers,
            .light_buffers = light_buffers,
            .default_texture = default_texture,
            .reload_context = undefined,
        };

        // Set up hot-reload context
        renderer.reload_context = PipelineReloadContext{
            .renderer = &renderer,
        };

        // Register for pipeline hot-reload
        try pipeline_system.registerPipelineReloadCallback(.{
            .context = &renderer.reload_context,
            .onPipelineReloaded = PipelineReloadContext.onPipelineReloaded,
        });

        // Bind default resources for all frames
        try renderer.setupDefaultResources();

        log(.INFO, "unified_textured_renderer", "✅ Unified textured renderer initialized");

        return renderer;
    }

    pub fn deinit(self: *Self) void {
        log(.INFO, "unified_textured_renderer", "Cleaning up unified textured renderer");

        // Clean up uniform buffers
        for (self.mvp_buffers) |buffer| {
            buffer.destroy();
            self.allocator.destroy(buffer);
        }

        for (self.light_buffers) |buffer| {
            buffer.destroy();
            self.allocator.destroy(buffer);
        }

        // Clean up default texture
        self.graphics_context.vkd.destroyImageView(self.graphics_context.dev, self.default_texture.view, null);
        self.graphics_context.vkd.destroySampler(self.graphics_context.dev, self.default_texture.sampler, null);
        self.default_texture.image.destroy();
        self.allocator.destroy(self.default_texture.image);

        // Clean up pipeline system
        self.resource_binder.deinit();
        self.pipeline_system.deinit();
    }

    /// Render textured objects
    pub fn render(
        self: *Self,
        command_buffer: vk.CommandBuffer,
        camera: *const Camera,
        objects: []const TexturedObject,
        frame_index: u32,
    ) !void {
        if (objects.len == 0) return;

        log(.DEBUG, "unified_textured_renderer", "Rendering {} textured objects (frame {})", .{ objects.len, frame_index });

        // Update frame-specific uniform data
        try self.updateFrameUniforms(camera, frame_index);

        // Update descriptor sets for this frame
        try self.resource_binder.updateFrame(frame_index);

        // Bind the unified pipeline
        try self.pipeline_system.bindPipeline(command_buffer, self.textured_pipeline);

        // Render all objects
        for (objects) |object| {
            try self.renderObject(command_buffer, object, frame_index);
        }
    }

    /// Add a textured object with custom texture
    pub fn bindObjectTexture(
        self: *Self,
        image_view: vk.ImageView,
        sampler: vk.Sampler,
        frame_index: u32,
    ) !void {
        // Bind custom texture to set 1, binding 0 (per-object texture)
        try self.resource_binder.bindTextureDefault(
            self.textured_pipeline,
            1,
            0, // set 1, binding 0
            image_view,
            sampler,
            frame_index,
        );
    }

    /// Update per-object transform data
    pub fn updateObjectTransform(
        self: *Self,
        transform: @import("../math/transform.zig").Transform,
        frame_index: u32,
    ) !void {
        _ = self; // TODO: Implement per-object uniform buffer management

        // Create object uniform data
        const object_ubo = ObjectUniformBuffer{
            .model = transform.getMatrix(),
            .normal_matrix = transform.getNormalMatrix(),
        };

        // Update object uniform buffer
        // This would require per-object uniform buffers in a real implementation
        _ = object_ubo;
        _ = frame_index;

        // TODO: Implement per-object uniform buffer management
        // For now, we'll use push constants or vertex attributes for per-object data
    }

    // Private implementation

    fn setupDefaultResources(self: *Self) !void {
        log(.DEBUG, "unified_textured_renderer", "Setting up default resources");

        // Bind default resources for all frames
        for (0..MAX_FRAMES_IN_FLIGHT) |frame_index| {
            const frame_idx = @as(u32, @intCast(frame_index));

            // Set 0: Frame-global data
            try self.resource_binder.bindFullUniformBuffer(
                self.textured_pipeline,
                0,
                0, // set 0, binding 0 - MVP data
                self.mvp_buffers[frame_index],
                frame_idx,
            );

            try self.resource_binder.bindFullUniformBuffer(
                self.textured_pipeline,
                0,
                1, // set 0, binding 1 - Light data
                self.light_buffers[frame_index],
                frame_idx,
            );

            // Set 1: Default texture (will be overridden per object)
            try self.resource_binder.bindTextureDefault(
                self.textured_pipeline,
                1,
                0, // set 1, binding 0 - Diffuse texture
                self.default_texture.view,
                self.default_texture.sampler,
                frame_idx,
            );
        }
    }

    fn updateFrameUniforms(self: *Self, camera: *const Camera, frame_index: u32) !void {
        // Update MVP uniform buffer
        const mvp_data = MVPUniformBuffer{
            .view = camera.getViewMatrix(),
            .projection = camera.getProjectionMatrix(),
            .view_projection = camera.getViewProjectionMatrix(),
        };

        try self.mvp_buffers[frame_index].writeData(&mvp_data, 0);

        // Update light uniform buffer
        const light_data = LightUniformBuffer{
            .light_position = .{ 5.0, 5.0, 5.0, 1.0 },
            .light_color = .{ 1.0, 1.0, 1.0, 1.0 },
            .ambient_strength = 0.1,
            .light_intensity = 1.0,
        };

        try self.light_buffers[frame_index].writeData(&light_data, 0);
    }

    fn renderObject(self: *Self, command_buffer: vk.CommandBuffer, object: TexturedObject, frame_index: u32) !void {
        _ = frame_index;

        // Bind vertex and index buffers
        const vertex_buffers = [_]vk.Buffer{object.vertex_buffer};
        const offsets = [_]vk.DeviceSize{0};

        self.graphics_context.vkd.cmdBindVertexBuffers(command_buffer, 0, 1, &vertex_buffers, &offsets);

        if (object.index_buffer) |index_buffer| {
            self.graphics_context.vkd.cmdBindIndexBuffer(command_buffer, index_buffer, 0, .uint32);
            self.graphics_context.vkd.cmdDrawIndexed(command_buffer, object.index_count, 1, 0, 0, 0);
        } else {
            self.graphics_context.vkd.cmdDraw(command_buffer, object.vertex_count, 1, 0, 0);
        }
    }

    fn createDefaultTexture(allocator: std.mem.Allocator, graphics_context: *GraphicsContext) !@TypeOf(@as(UnifiedTexturedRenderer, undefined).default_texture) {
        // Create a simple white 1x1 texture as default
        const image = try Image.create2D(
            allocator,
            graphics_context,
            1,
            1, // 1x1 pixel
            .r8g8b8a8_srgb,
            .{ .sampled_bit = true },
            .optimal,
        );

        // Upload white pixel data
        const white_pixel = [_]u8{ 255, 255, 255, 255 };
        try image.transitionLayout(.undefined, .transfer_dst_optimal);
        try image.uploadData(&white_pixel);
        try image.transitionLayout(.transfer_dst_optimal, .shader_read_only_optimal);

        // Create image view
        const view = try graphics_context.vkd.createImageView(graphics_context.dev, &vk.ImageViewCreateInfo{
            .image = image.handle,
            .view_type = .@"2d",
            .format = .r8g8b8a8_srgb,
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        }, null);

        // Create sampler
        const sampler = try graphics_context.vkd.createSampler(graphics_context.dev, &vk.SamplerCreateInfo{
            .mag_filter = .linear,
            .min_filter = .linear,
            .address_mode_u = .repeat,
            .address_mode_v = .repeat,
            .address_mode_w = .repeat,
            .anisotropy_enable = vk.TRUE,
            .max_anisotropy = 16.0,
            .border_color = .int_opaque_black,
            .unnormalized_coordinates = vk.FALSE,
            .compare_enable = vk.FALSE,
            .compare_op = .always,
            .mipmap_mode = .linear,
            .mip_lod_bias = 0.0,
            .min_lod = 0.0,
            .max_lod = 0.0,
        }, null);

        return .{
            .image = image,
            .view = view,
            .sampler = sampler,
        };
    }
};

/// Vertex format for textured objects
const TexturedVertex = extern struct {
    position: [3]f32,
    normal: [3]f32,
    tex_coord: [2]f32,
};

/// Object to be rendered
pub const TexturedObject = struct {
    vertex_buffer: vk.Buffer,
    index_buffer: ?vk.Buffer = null,
    vertex_count: u32,
    index_count: u32 = 0,
    texture_view: ?vk.ImageView = null,
    texture_sampler: ?vk.Sampler = null,
};

/// MVP uniform buffer layout
const MVPUniformBuffer = extern struct {
    view: [16]f32,
    projection: [16]f32,
    view_projection: [16]f32,
};

/// Light uniform buffer layout
const LightUniformBuffer = extern struct {
    light_position: [4]f32,
    light_color: [4]f32,
    ambient_strength: f32,
    light_intensity: f32,
    _padding: [2]f32 = .{ 0.0, 0.0 },
};

/// Object uniform buffer layout (for per-object data)
const ObjectUniformBuffer = extern struct {
    model: [16]f32,
    normal_matrix: [16]f32,
};

/// Pipeline reload context for hot-reload integration
const PipelineReloadContext = struct {
    renderer: *UnifiedTexturedRenderer,

    fn onPipelineReloaded(context: *anyopaque, pipeline_id: PipelineId) void {
        const self: *PipelineReloadContext = @ptrCast(@alignCast(context));

        log(.INFO, "unified_textured_renderer", "Pipeline reloaded: {s}", .{pipeline_id.name});

        // Re-setup default resources after pipeline reload
        self.renderer.setupDefaultResources() catch |err| {
            log(.ERROR, "unified_textured_renderer", "Failed to re-setup resources after reload: {}", .{err});
        };
    }
};
