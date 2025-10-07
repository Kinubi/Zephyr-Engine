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
const GlobalUbo = @import("../rendering/frameinfo.zig").GlobalUbo;
const MAX_FRAMES_IN_FLIGHT = @import("../core/swapchain.zig").MAX_FRAMES_IN_FLIGHT;
const log = @import("../utils/log.zig").log;
const math = @import("../utils/math.zig");

/// Particle renderer using the unified pipeline system
///
/// This renderer demonstrates how to implement compute-based particle systems
/// with the unified pipeline and descriptor management.
pub const ParticleRenderer = struct {
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
                .{ .binding = 0, .stride = @sizeOf(Particle), .input_rate = .vertex },
            },
            .vertex_input_attributes = &[_]@import("../rendering/pipeline_builder.zig").VertexInputAttribute{
                .{ .location = 0, .binding = 0, .format = .r32g32_sfloat, .offset = @offsetOf(Particle, "position") },
                .{ .location = 1, .binding = 0, .format = .r32g32_sfloat, .offset = @offsetOf(Particle, "velocity") },
                .{ .location = 2, .binding = 0, .format = .r32g32b32a32_sfloat, .offset = @offsetOf(Particle, "color") },
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
    }
    pub fn deinit(self: *Self) void {
        log(.INFO, "particle_renderer", "Cleaning up particle renderer", .{});

        // Clean up particle buffers
        for (&self.particle_buffers) |*buffers| {
            buffers.destroy();
        }

        // Clean up uniform buffers
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
        frame_index: u32,
        delta_time: f32,
        emitter_position: math.Vec3,
    ) !void {

        // Check if we need to re-setup resources after hot reload
        if (self.needs_resource_setup) {
            // Wait for GPU to finish current work before re-binding resources
            // This ensures no descriptor sets are in use when we bind new ones
            try self.graphics_context.vkd.deviceWaitIdle(self.graphics_context.dev);

            try self.setupResources();
            self.needs_resource_setup = false;
        }

        // Update ComputeUniformBuffer with current frame data
        const compute_ubo = ComputeUniformBuffer{
            .delta_time = delta_time,
            .emitter_position = .{ emitter_position.x, emitter_position.y, emitter_position.z, 0.0 },
            .particle_count = self.particle_count,
            .max_particles = self.max_particles,
            .gravity = .{ 0.0, -9.81, 0.0, 0.0 }, // Default gravity
            .spawn_rate = 100.0, // Default spawn rate
        };

        // Write compute uniform data to buffer
        const compute_ubo_bytes = std.mem.asBytes(&compute_ubo);
        self.compute_uniform_buffers[frame_index].writeToBuffer(compute_ubo_bytes, @sizeOf(ComputeUniformBuffer), 0);

        // Update descriptor sets for all resources (includes ComputeUniformBuffer and storage buffers)
        try self.resource_binder.updateFrame(frame_index);

        // Dispatch compute shader
        try self.pipeline_system.bindPipeline(command_buffer, self.compute_pipeline);

        // Update descriptor sets first
        try self.pipeline_system.updateDescriptorSets(frame_index);

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
        const workgroup_size = 256; // Match shader local_size_x
        const workgroups = (self.max_particles + workgroup_size - 1) / workgroup_size;
        self.graphics_context.vkd.cmdDispatch(command_buffer, workgroups, 1, 1);

        // Memory barrier to ensure compute writes are complete before copy
        const memory_barrier_after_compute = vk.MemoryBarrier{
            .src_access_mask = .{ .shader_write_bit = true },
            .dst_access_mask = .{ .transfer_read_bit = true, .vertex_attribute_read_bit = true },
        };

        self.graphics_context.vkd.cmdPipelineBarrier(
            command_buffer,
            .{ .compute_shader_bit = true },
            .{ .transfer_bit = true, .vertex_input_bit = true },
            .{},
            1,
            @ptrCast(&memory_barrier_after_compute),
            0,
            null,
            0,
            null,
        );

        // Copy output buffer back to input buffer for next frame (like old system)
        const buffer_size = @sizeOf(Particle) * self.max_particles;
        const copy_region = vk.BufferCopy{
            .src_offset = 0,
            .dst_offset = 0,
            .size = buffer_size,
        };

        self.graphics_context.vkd.cmdCopyBuffer(
            command_buffer,
            self.particle_buffers[frame_index].particle_buffer_out.buffer,
            self.particle_buffers[frame_index].particle_buffer_in.buffer,
            1,
            @ptrCast(&copy_region),
        );

        self.graphics_context.vkd.cmdCopyBuffer(
            command_buffer,
            self.particle_buffers[frame_index].particle_buffer_out.buffer,
            self.particle_buffers[(frame_index + 1) % MAX_FRAMES_IN_FLIGHT].particle_buffer_out.buffer,
            1,
            @ptrCast(&copy_region),
        );
    }

    /// Render particles
    pub fn renderParticles(
        self: *Self,
        command_buffer: vk.CommandBuffer,
        camera: *const Camera,
        frame_index: u32,
    ) !void {
        _ = camera; // Unused since particle shaders don't need camera transforms

        if (self.particle_count == 0) {
            return;
        }

        // Note: The particle shaders don't use uniform buffers, so we skip uniform updates        // Update descriptor sets (though render pipeline doesn't need them)
        try self.resource_binder.updateFrame(frame_index);

        // Bind render pipeline
        try self.pipeline_system.bindPipeline(command_buffer, self.render_pipeline);

        // Bind particle vertex buffer (use input buffer for rendering like old system)
        const vertex_buffers = [_]vk.Buffer{self.particle_buffers[frame_index].particle_buffer_in.buffer};
        const offsets = [_]vk.DeviceSize{0};

        self.graphics_context.vkd.cmdBindVertexBuffers(command_buffer, 0, 1, &vertex_buffers, &offsets);

        // Draw particles as points (vertex rendering, not instanced)
        self.graphics_context.vkd.cmdDraw(command_buffer, self.particle_count, 1, 0, 0);
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

    /// Initialize particles with random positions and velocities (like the old system)
    pub fn initializeParticles(self: *Self) !void {
        log(.INFO, "particle_renderer", "Initializing {} particles with random data", .{self.max_particles});

        // Start with all particles active
        self.particle_count = self.max_particles;

        // Initialize particles with random positions and velocities
        var prng = std.Random.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
        const rand = prng.random();

        // Create initial particle data
        const particle_data = try self.allocator.alloc(Particle, self.max_particles);
        defer self.allocator.free(particle_data);

        const pi = 3.14159265358979323846;
        const scale = 0.25; // Match old system exactly
        const vel_scale = 0.5; // Increased for visible movement (was 0.00025)

        for (particle_data) |*particle| {
            const r = scale * @sqrt(rand.float(f32));
            const theta = rand.float(f32) * 2.0 * pi;

            // Apply aspect ratio correction like old system (assume 16:9 aspect ratio)
            const width: f32 = 1920.0;
            const height: f32 = 1080.0;
            const x = r * @cos(theta) * height / width;
            const y = r * @sin(theta);

            const len = @sqrt(x * x + y * y);
            const vx = if (len > 0.0) (x / len) * vel_scale else 0.0;
            const vy = if (len > 0.0) (y / len) * vel_scale else 0.0;

            particle.* = Particle{
                .position = .{ x, y },
                .velocity = .{ vx, vy },
                .color = .{ rand.float(f32), rand.float(f32), rand.float(f32), 1.0 },
            };
        }

        // Create staging buffer to transfer data to GPU
        const buffer_size = @sizeOf(Particle) * self.max_particles;
        var staging_buffer = try Buffer.init(
            self.graphics_context,
            @sizeOf(Particle),
            self.max_particles,
            .{ .transfer_src_bit = true },
            .{ .host_visible_bit = true, .host_coherent_bit = true },
        );
        defer staging_buffer.deinit();

        // Map and write data to staging buffer
        try staging_buffer.map(buffer_size, 0);
        staging_buffer.writeToBuffer(std.mem.sliceAsBytes(particle_data), buffer_size, 0);

        // Copy from staging buffer to all frame input AND output buffers (like old system)
        for (0..MAX_FRAMES_IN_FLIGHT) |frame_index| {
            try self.graphics_context.copyBuffer(self.particle_buffers[frame_index].particle_buffer_in.buffer, staging_buffer.buffer, buffer_size);
            try self.graphics_context.copyBuffer(self.particle_buffers[frame_index].particle_buffer_out.buffer, staging_buffer.buffer, buffer_size);
        }
    }

    /// Debug method to read back the first particle's position
    fn debugReadFirstParticle(self: *Self, frame_index: u32) !void {
        // Create a staging buffer to read back the first particle
        var staging_buffer = try Buffer.init(
            self.graphics_context,
            @sizeOf(Particle),
            1,
            .{ .transfer_dst_bit = true },
            .{ .host_visible_bit = true, .host_coherent_bit = true },
        );
        defer staging_buffer.deinit();

        // Copy first particle from GPU buffer to staging buffer
        try self.graphics_context.copyBuffer(staging_buffer.buffer, self.particle_buffers[frame_index].particle_buffer_out.buffer, @sizeOf(Particle));

        // Map and read the data
        try staging_buffer.map(@sizeOf(Particle), 0);
        defer staging_buffer.unmap();

        if (staging_buffer.mapped) |mapped_ptr| {
            const particle_ptr: *Particle = @ptrCast(@alignCast(mapped_ptr));
            _ = particle_ptr;
        }
    }

    // Private implementation

    fn setupResources(self: *Self) !void {
        log(.DEBUG, "particle_renderer", "Setting up particle renderer resources", .{});

        // Defensive check: ensure pipeline IDs are valid
        log(.DEBUG, "particle_renderer", "Compute pipeline: {s} (hash: {})", .{ self.compute_pipeline.name, self.compute_pipeline.hash });
        log(.DEBUG, "particle_renderer", "Render pipeline: {s} (hash: {})", .{ self.render_pipeline.name, self.render_pipeline.hash });

        // Bind resources for all frames following old system approach
        for (0..MAX_FRAMES_IN_FLIGHT) |frame_index| {
            const frame_idx = @as(u32, @intCast(frame_index));

            // Set 0: All descriptors following old system approach
            // Binding 0: ComputeUniformBuffer
            try self.resource_binder.bindFullUniformBuffer(
                self.compute_pipeline,
                0,
                0, // set 0, binding 0 - ComputeUniformBuffer
                &self.compute_uniform_buffers[frame_index],
                frame_idx,
            );

            // Binding 1: Particle input buffer (ParticleSSBOIn)
            try self.resource_binder.bindFullStorageBuffer(
                self.compute_pipeline,
                0,
                1, // set 0, binding 1 - Particle input buffer
                &self.particle_buffers[frame_index].particle_buffer_in,
                frame_idx,
            );

            // Binding 2: Particle output buffer (ParticleSSBOOut)
            try self.resource_binder.bindFullStorageBuffer(
                self.compute_pipeline,
                0,
                2, // set 0, binding 2 - Particle output buffer
                &self.particle_buffers[frame_index].particle_buffer_out,
                frame_idx,
            );

            // Note: Render pipeline doesn't need descriptor sets - it uses vertex attributes only
            // The particle vertex data is bound as vertex buffers during rendering
        }
    }
};

/// Particle buffers for each frame - matches old renderer exactly
const ParticleBuffers = struct {
    particle_buffer_in: Buffer,
    particle_buffer_out: Buffer,

    fn create(
        allocator: std.mem.Allocator,
        graphics_context: *GraphicsContext,
        max_particles: u32,
    ) !ParticleBuffers {
        _ = allocator; // Not needed for Buffer.init

        const buffer_size = @sizeOf(Particle) * max_particles;

        const particle_buffer_in = try Buffer.init(
            graphics_context,
            buffer_size,
            1,
            .{ .storage_buffer_bit = true, .vertex_buffer_bit = true, .transfer_dst_bit = true },
            .{ .device_local_bit = true },
        );

        const particle_buffer_out = try Buffer.init(
            graphics_context,
            buffer_size,
            1,
            .{ .storage_buffer_bit = true, .vertex_buffer_bit = true, .transfer_src_bit = true, .transfer_dst_bit = true },
            .{ .device_local_bit = true },
        );

        return ParticleBuffers{
            .particle_buffer_in = particle_buffer_in,
            .particle_buffer_out = particle_buffer_out,
        };
    }

    fn destroy(self: *ParticleBuffers) void {
        self.particle_buffer_in.deinit();
        self.particle_buffer_out.deinit();
    }
};

/// Particle vertex data (for rendering) - matches old renderer exactly
pub const Particle = extern struct {
    position: [2]f32,
    velocity: [2]f32,
    color: [4]f32,

    pub const binding_description = vk.VertexInputBindingDescription{
        .binding = 0,
        .stride = @sizeOf(Particle),
        .input_rate = .vertex,
    };

    pub const attribute_description = [_]vk.VertexInputAttributeDescription{
        .{ .binding = 0, .location = 0, .format = .r32g32_sfloat, .offset = @offsetOf(Particle, "position") },
        .{ .binding = 0, .location = 1, .format = .r32g32_sfloat, .offset = @offsetOf(Particle, "velocity") },
        .{ .binding = 0, .location = 2, .format = .r32g32b32a32_sfloat, .offset = @offsetOf(Particle, "color") },
    };
};

/// Render shader uniform buffer
const RenderUniformBuffer = extern struct {
    view_projection: [16]f32,
    camera_position: [4]f32,
    particle_size: f32,
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

/// Pipeline reload context for hot-reload integration
const PipelineReloadContext = struct {
    renderer: *ParticleRenderer,

    fn onPipelineReloaded(context: *anyopaque, pipeline_id: PipelineId) void {
        const self: *PipelineReloadContext = @ptrCast(@alignCast(context));

        log(.INFO, "particle_renderer", "Pipeline reloaded: {s}", .{pipeline_id.name});

        // Update the renderer's pipeline ID references to avoid stale pointers
        if (std.mem.eql(u8, pipeline_id.name, "particle_compute")) {
            self.renderer.compute_pipeline = pipeline_id;
        } else if (std.mem.eql(u8, pipeline_id.name, "particle_render")) {
            self.renderer.render_pipeline = pipeline_id;
        }

        // NOTE: We don't call setupResources() here during hot reload because:
        // 1. It would bind resources immediately, marking them as dirty
        // 2. updateFrame() might be called while old descriptor sets are still in use
        // 3. This causes Vulkan validation errors about updating in-use descriptor sets
        //
        // Instead, mark that resources need setup and handle it on the next render call.
        self.renderer.needs_resource_setup = true;
    }
};
