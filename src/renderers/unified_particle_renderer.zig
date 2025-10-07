const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("../core/graphics_context.zig").GraphicsContext;
const Camera = @import("../rendering/camera.zig").Camera;
const UnifiedPipelineSystem = @import("../rendering/unified_pipeline_system.zig").UnifiedPipelineSystem;
const PipelineConfig = @import("../rendering/unified_pipeline_system.zig").PipelineConfig;
const ResourceBinder = @import("../rendering/resource_binder.zig").ResourceBinder;
const PipelineId = @import("../rendering/unified_pipeline_system.zig").PipelineId;
const Buffer = @import("../core/buffer.zig").Buffer;
const Texture = @import("../core/texture.zig").Texture;
const ShaderManager = @import("../assets/shader_manager.zig").ShaderManager;
const MAX_FRAMES_IN_FLIGHT = @import("../core/swapchain.zig").MAX_FRAMES_IN_FLIGHT;
const log = @import("../utils/log.zig").log;

/// Particle renderer adapted to use the unified pipeline system
///
/// This renderer demonstrates how to adapt compute-based particle systems
/// to work with the new unified pipeline and descriptor management.
pub const UnifiedParticleRenderer = struct {
    allocator: std.mem.Allocator,
    graphics_context: *GraphicsContext,
    shader_manager: *ShaderManager,

    // Unified pipeline system
    pipeline_system: *UnifiedPipelineSystem,
    resource_binder: ResourceBinder,

    // Particle pipelines
    compute_pipeline: PipelineId,
    render_pipeline: PipelineId,

    // Particle data
    particle_buffers: [MAX_FRAMES_IN_FLIGHT]ParticleBuffers,
    particle_count: u32,
    max_particles: u32,

    // Uniform buffers (per frame in flight)
    compute_uniform_buffers: [MAX_FRAMES_IN_FLIGHT]Buffer,
    render_uniform_buffers: [MAX_FRAMES_IN_FLIGHT]Buffer,

    // Hot-reload context
    reload_context: PipelineReloadContext,

    // Flag to track if resources need to be re-setup after hot reload
    needs_resource_setup: bool = false,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        graphics_context: *GraphicsContext,
        shader_manager: *ShaderManager,
        pipeline_system: *UnifiedPipelineSystem,
        render_pass: vk.RenderPass,
        max_particles: u32,
    ) !Self {
        log(.INFO, "unified_particle_renderer", "Initializing unified particle renderer (max_particles: {})", .{max_particles});

        // Use the provided unified pipeline system
        const resource_binder = ResourceBinder.init(allocator, pipeline_system);

        // Create particle buffers for each frame
        var particle_buffers: [MAX_FRAMES_IN_FLIGHT]ParticleBuffers = undefined;
        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            particle_buffers[i] = try ParticleBuffers.create(
                allocator,
                graphics_context,
                max_particles,
            );
        }

        // Create uniform buffers
        var compute_uniform_buffers: [MAX_FRAMES_IN_FLIGHT]Buffer = undefined;
        var render_uniform_buffers: [MAX_FRAMES_IN_FLIGHT]Buffer = undefined;

        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            compute_uniform_buffers[i] = try Buffer.init(
                graphics_context,
                @sizeOf(ComputeUniformBuffer),
                1,
                .{ .uniform_buffer_bit = true },
                .{ .host_visible_bit = true, .host_coherent_bit = true },
            );
            try compute_uniform_buffers[i].map(vk.WHOLE_SIZE, 0);

            render_uniform_buffers[i] = try Buffer.init(
                graphics_context,
                @sizeOf(RenderUniformBuffer),
                1,
                .{ .uniform_buffer_bit = true },
                .{ .host_visible_bit = true, .host_coherent_bit = true },
            );
            try render_uniform_buffers[i].map(vk.WHOLE_SIZE, 0);
        } // Create compute pipeline for particle simulation
        const compute_pipeline_config = PipelineConfig{
            .name = "particle_compute",
            .compute_shader = "shaders/particles.comp",
            .render_pass = vk.RenderPass.null_handle, // Compute pipelines don't use render passes
        };

        const compute_pipeline = try pipeline_system.createPipeline(compute_pipeline_config);

        // Create graphics pipeline for particle rendering
        const render_pipeline_config = PipelineConfig{
            .name = "particle_render",
            .vertex_shader = "shaders/particles.vert",
            .fragment_shader = "shaders/particles.frag",
            .render_pass = render_pass,
            .vertex_input_bindings = &[_]@import("../rendering/pipeline_builder.zig").VertexInputBinding{
                .{ .binding = 0, .stride = @sizeOf(ParticleVertex), .input_rate = .instance },
            },
            .vertex_input_attributes = &[_]@import("../rendering/pipeline_builder.zig").VertexInputAttribute{
                .{ .location = 0, .binding = 0, .format = .r32g32b32_sfloat, .offset = @offsetOf(ParticleVertex, "position") },
                .{ .location = 1, .binding = 0, .format = .r32g32b32_sfloat, .offset = @offsetOf(ParticleVertex, "velocity") },
                .{ .location = 2, .binding = 0, .format = .r32g32b32a32_sfloat, .offset = @offsetOf(ParticleVertex, "color") },
                .{ .location = 3, .binding = 0, .format = .r32_sfloat, .offset = @offsetOf(ParticleVertex, "life") },
            },
            .topology = .point_list,
            .cull_mode = .{}, // No culling for particles
        };

        const render_pipeline = try pipeline_system.createPipeline(render_pipeline_config);

        var renderer = Self{
            .allocator = allocator,
            .graphics_context = graphics_context,
            .shader_manager = shader_manager,
            .pipeline_system = pipeline_system,
            .resource_binder = resource_binder,
            .compute_pipeline = compute_pipeline,
            .render_pipeline = render_pipeline,
            .particle_buffers = particle_buffers,
            .particle_count = 0,
            .max_particles = max_particles,
            .compute_uniform_buffers = compute_uniform_buffers,
            .render_uniform_buffers = render_uniform_buffers,
            .reload_context = undefined,
        };

        // Set up hot-reload context (but don't register callback yet)
        renderer.reload_context = PipelineReloadContext{
            .renderer = undefined, // Will be set after renderer is in final location
        };

        // Bind resources for all frames
        try renderer.setupResources();

        // Mark compute pipeline resources as dirty to ensure they get updated
        // Note: render pipeline doesn't use descriptor sets, only vertex attributes
        renderer.pipeline_system.markPipelineResourcesDirty(renderer.compute_pipeline);

        log(.INFO, "unified_particle_renderer", "✅ Unified particle renderer initialized", .{});

        return renderer;
    }

    /// Register for hot reload callbacks - must be called after renderer is in final memory location
    pub fn registerHotReload(self: *Self) !void {
        // Set up the context pointer now that renderer is in final location
        self.reload_context.renderer = self;

        // Register for pipeline hot-reload
        try self.pipeline_system.registerPipelineReloadCallback(.{
            .context = &self.reload_context,
            .onPipelineReloaded = PipelineReloadContext.onPipelineReloaded,
        });

        log(.DEBUG, "unified_particle_renderer", "Registered for pipeline hot reload callbacks", .{});
    }

    pub fn deinit(self: *Self) void {
        log(.INFO, "unified_particle_renderer", "Cleaning up unified particle renderer", .{});

        // Clean up particle buffers
        for (&self.particle_buffers) |*buffers| {
            buffers.destroy();
        }

        // Clean up uniform buffers
        for (&self.compute_uniform_buffers) |*buffer| {
            buffer.deinit();
        }

        for (&self.render_uniform_buffers) |*buffer| {
            buffer.deinit();
        }

        // Clean up resource binder (pipeline system is owned by app)
        self.resource_binder.deinit();
    }

    /// Update particle simulation
    pub fn updateParticles(
        self: *Self,
        command_buffer: vk.CommandBuffer,
        delta_time: f32,
        emitter_position: [3]f32,
        frame_index: u32,
    ) !void {

        // Check if we need to re-setup resources after hot reload
        if (self.needs_resource_setup) {
            log(.DEBUG, "unified_particle_renderer", "Re-setting up resources after hot reload", .{});

            // Wait for GPU to finish current work before re-binding resources
            // This ensures no descriptor sets are in use when we bind new ones
            try self.graphics_context.vkd.deviceWaitIdle(self.graphics_context.dev);
            log(.DEBUG, "unified_particle_renderer", "GPU idle wait completed for resource re-setup", .{});

            try self.setupResources();
            self.needs_resource_setup = false;
        }

        // Update compute uniform data
        const compute_data = ComputeUniformBuffer{
            .delta_time = delta_time,
            .emitter_position = .{ emitter_position[0], emitter_position[1], emitter_position[2], 1.0 },
            .particle_count = self.particle_count,
            .max_particles = self.max_particles,
            .gravity = .{ 0.0, -9.81, 0.0, 0.0 },
            .spawn_rate = 100.0,
        };

        try self.updateUniformBuffer(&compute_data, &self.compute_uniform_buffers[frame_index]);

        // Update descriptor sets
        try self.resource_binder.updateFrame(frame_index);

        // Dispatch compute shader
        try self.pipeline_system.bindPipeline(command_buffer, self.compute_pipeline);

        // Memory barrier to ensure compute writes are visible to vertex stage
        const memory_barrier = vk.MemoryBarrier{
            .src_access_mask = .{ .shader_write_bit = true },
            .dst_access_mask = .{ .vertex_attribute_read_bit = true },
        };

        self.graphics_context.vkd.cmdPipelineBarrier(
            command_buffer,
            .{ .compute_shader_bit = true },
            .{ .vertex_input_bit = true },
            .{},
            1,
            @ptrCast(&memory_barrier),
            0,
            null,
            0,
            null,
        );

        // Dispatch compute workgroups
        const workgroup_size = 64;
        const workgroups = (self.max_particles + workgroup_size - 1) / workgroup_size;
        self.graphics_context.vkd.cmdDispatch(command_buffer, workgroups, 1, 1);
    }

    /// Render particles
    pub fn renderParticles(
        self: *Self,
        command_buffer: vk.CommandBuffer,
        camera: *const Camera,
        frame_index: u32,
    ) !void {
        if (self.particle_count == 0) return;

        log(.DEBUG, "unified_particle_renderer", "Rendering {} particles (frame {})", .{ self.particle_count, frame_index });

        // Update render uniform data
        const render_data = RenderUniformBuffer{
            .view_projection = camera.projectionMatrix.mul(camera.viewMatrix).data,
            .camera_position = [4]f32{ 0.0, 0.0, 0.0, 1.0 }, // TODO: Get camera position
            .particle_size = 0.1,
        };

        try self.updateUniformBuffer(&render_data, &self.render_uniform_buffers[frame_index]);

        // Update descriptor sets
        try self.resource_binder.updateFrame(frame_index);

        // Bind render pipeline
        try self.pipeline_system.bindPipeline(command_buffer, self.render_pipeline);

        // Bind particle vertex buffer
        const vertex_buffers = [_]vk.Buffer{self.particle_buffers[frame_index].vertex_buffer.buffer};
        const offsets = [_]vk.DeviceSize{0};

        self.graphics_context.vkd.cmdBindVertexBuffers(command_buffer, 0, 1, &vertex_buffers, &offsets);

        // Draw particles as instanced points
        self.graphics_context.vkd.cmdDraw(command_buffer, 1, self.particle_count, 0, 0);
    }

    // Private helper methods

    fn updateUniformBuffer(self: *Self, data: anytype, buffer: *Buffer) !void {
        _ = self;
        buffer.writeToIndex(std.mem.asBytes(&data), 0);
    }

    /// Add particles at emitter position
    pub fn emitParticles(self: *Self, count: u32, position: [3]f32, velocity: [3]f32) void {
        _ = self;
        _ = count;
        _ = position;
        _ = velocity;

        // TODO: Implement particle emission
        // This would typically be done on the CPU side by updating the particle buffer
        // or through compute shader parameters
    }

    /// Reset all particles
    pub fn resetParticles(self: *Self) void {
        self.particle_count = 0;

        // TODO: Clear particle buffers
        // This could be done with a compute shader or by clearing the buffers directly
    }

    // Private implementation

    fn setupResources(self: *Self) !void {
        log(.DEBUG, "unified_particle_renderer", "Setting up particle renderer resources", .{});

        // Defensive check: ensure pipeline IDs are valid
        log(.DEBUG, "unified_particle_renderer", "Compute pipeline: {s} (hash: {})", .{ self.compute_pipeline.name, self.compute_pipeline.hash });
        log(.DEBUG, "unified_particle_renderer", "Render pipeline: {s} (hash: {})", .{ self.render_pipeline.name, self.render_pipeline.hash });

        // Bind resources for all frames
        for (0..MAX_FRAMES_IN_FLIGHT) |frame_index| {
            const frame_idx = @as(u32, @intCast(frame_index));

            // Set 0: Compute uniforms
            try self.resource_binder.bindFullUniformBuffer(
                self.compute_pipeline,
                0,
                0, // set 0, binding 0 - Compute uniform data
                &self.compute_uniform_buffers[frame_index],
                frame_idx,
            );

            // Set 0: Particle data (storage buffers) - Updated to match descriptor layout
            try self.resource_binder.bindFullStorageBuffer(
                self.compute_pipeline,
                0,
                1, // set 0, binding 1 - Particle positions (ParticleSSBOIn)
                &self.particle_buffers[frame_index].vertex_buffer,
                frame_idx,
            );

            try self.resource_binder.bindFullStorageBuffer(
                self.compute_pipeline,
                0,
                2, // set 0, binding 2 - Particle velocities (ParticleSSBOOut)
                &self.particle_buffers[frame_index].velocity_buffer,
                frame_idx,
            );

            // Note: Render pipeline doesn't need descriptor sets - it uses vertex attributes only
            // The particle vertex data is bound as vertex buffers during rendering
        }
    }
};

/// Particle buffers for each frame
const ParticleBuffers = struct {
    vertex_buffer: Buffer,
    velocity_buffer: Buffer,

    fn create(
        allocator: std.mem.Allocator,
        graphics_context: *GraphicsContext,
        max_particles: u32,
    ) !ParticleBuffers {
        _ = allocator; // Not needed for Buffer.init

        const vertex_buffer = try Buffer.init(
            graphics_context,
            @sizeOf(ParticleVertex),
            max_particles,
            .{ .vertex_buffer_bit = true, .storage_buffer_bit = true },
            .{ .device_local_bit = true },
        );

        const velocity_buffer = try Buffer.init(
            graphics_context,
            @sizeOf(ParticleVelocity),
            max_particles,
            .{ .storage_buffer_bit = true },
            .{ .device_local_bit = true },
        );

        return ParticleBuffers{
            .vertex_buffer = vertex_buffer,
            .velocity_buffer = velocity_buffer,
        };
    }

    fn destroy(self: *ParticleBuffers) void {
        self.vertex_buffer.deinit();
        self.velocity_buffer.deinit();
    }
};

/// Particle vertex data (for rendering)
pub const ParticleVertex = extern struct {
    position: [3]f32,
    velocity: [3]f32,
    color: [4]f32,
    life: f32,
    _padding: [3]f32 = .{ 0.0, 0.0, 0.0 },
};

/// Particle velocity data (for compute shader)
const ParticleVelocity = extern struct {
    velocity: [3]f32,
    life: f32,
    start_life: f32,
    _padding: [3]f32 = .{ 0.0, 0.0, 0.0 },
};

/// Compute shader uniform buffer
const ComputeUniformBuffer = extern struct {
    delta_time: f32,
    emitter_position: [4]f32,
    particle_count: u32,
    max_particles: u32,
    gravity: [4]f32,
    spawn_rate: f32,
    _padding: [3]f32 = .{ 0.0, 0.0, 0.0 },
};

/// Render shader uniform buffer
const RenderUniformBuffer = extern struct {
    view_projection: [16]f32,
    camera_position: [4]f32,
    particle_size: f32,
    _padding: [3]f32 = .{ 0.0, 0.0, 0.0 },
};

/// Pipeline reload context for hot-reload integration
const PipelineReloadContext = struct {
    renderer: *UnifiedParticleRenderer,

    fn onPipelineReloaded(context: *anyopaque, pipeline_id: PipelineId) void {
        const self: *PipelineReloadContext = @ptrCast(@alignCast(context));

        log(.INFO, "unified_particle_renderer", "Pipeline reloaded: {s}", .{pipeline_id.name});

        // Update the renderer's pipeline ID references to avoid stale pointers
        if (std.mem.eql(u8, pipeline_id.name, "particle_compute")) {
            self.renderer.compute_pipeline = pipeline_id;
            log(.DEBUG, "unified_particle_renderer", "Updated compute pipeline reference", .{});
        } else if (std.mem.eql(u8, pipeline_id.name, "particle_render")) {
            self.renderer.render_pipeline = pipeline_id;
            log(.DEBUG, "unified_particle_renderer", "Updated render pipeline reference", .{});
        }

        // NOTE: We don't call setupResources() here during hot reload because:
        // 1. It would bind resources immediately, marking them as dirty
        // 2. updateFrame() might be called while old descriptor sets are still in use
        // 3. This causes Vulkan validation errors about updating in-use descriptor sets
        //
        // Instead, mark that resources need setup and handle it on the next render call.
        self.renderer.needs_resource_setup = true;
        log(.DEBUG, "unified_particle_renderer", "Pipeline hot reload complete - resources will be set up on next render", .{});
    }
};
