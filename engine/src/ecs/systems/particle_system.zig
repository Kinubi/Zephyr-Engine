const std = @import("std");
const vk = @import("vulkan");
const World = @import("../world.zig").World;
const Transform = @import("../components/transform.zig").Transform;
const ParticleEmitter = @import("../components/particle_emitter.zig").ParticleEmitter;
const EntityId = @import("../entity_registry.zig").EntityId;
const Scene = @import("../../scene/scene.zig").Scene;
const vertex_formats = @import("../../rendering/vertex_formats.zig");
const GraphicsContext = @import("../../core/graphics_context.zig").GraphicsContext;
const BufferManager = @import("../../rendering/buffer_manager.zig").BufferManager;
const BufferConfig = @import("../../rendering/buffer_manager.zig").BufferConfig;
const ManagedBuffer = @import("../../rendering/buffer_manager.zig").ManagedBuffer;
const Buffer = @import("../../core/buffer.zig").Buffer;
const MAX_FRAMES_IN_FLIGHT = @import("../../core/swapchain.zig").MAX_FRAMES_IN_FLIGHT;
const log = @import("../../utils/log.zig").log;

/// Particle buffers for ping-pong compute shader (holds all frames)
pub const ParticleBuffers = struct {
    particle_buffers_in: [MAX_FRAMES_IN_FLIGHT]*ManagedBuffer,
    particle_buffers_out: [MAX_FRAMES_IN_FLIGHT]*ManagedBuffer,
};

/// Opaque handle to particle GPU resources (buffer references)
/// ParticleComputePass uses this without knowing ParticleSystem internals
pub const ParticleGPUResources = struct {
    particle_buffers: *const ParticleBuffers,
    compute_uniform_buffers: *const [MAX_FRAMES_IN_FLIGHT]*ManagedBuffer,
    emitter_buffer: *const *ManagedBuffer,
    max_particles: u32,
    max_emitters: u32,
};

/// Particle system - Owns particle GPU buffers and manages emitter lifecycle
/// Provides buffer references to ParticleComputePass for rendering
pub const ParticleSystem = struct {
    allocator: std.mem.Allocator,
    graphics_context: *GraphicsContext,
    buffer_manager: *BufferManager,

    // GPU resources
    particle_buffers: ParticleBuffers = undefined,
    compute_uniform_buffers: [MAX_FRAMES_IN_FLIGHT]*ManagedBuffer = undefined,
    emitter_buffer: *ManagedBuffer = undefined,

    // Configuration
    max_particles: u32,
    max_emitters: u32,
    emitter_count: u32 = 0,
    last_particle_count: u32 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        graphics_context: *GraphicsContext,
        buffer_manager: *BufferManager,
        max_particles: u32,
        max_emitters: u32,
    ) !*ParticleSystem {
        const self = try allocator.create(ParticleSystem);
        self.* = .{
            .allocator = allocator,
            .graphics_context = graphics_context,
            .buffer_manager = buffer_manager,
            .max_particles = max_particles,
            .max_emitters = max_emitters,
        };

        // Create particle buffers for each frame (ping-pong)
        const buffer_size = @sizeOf(vertex_formats.Particle) * max_particles;
        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            self.particle_buffers.particle_buffers_in[i] = try buffer_manager.createBuffer(
                BufferConfig{
                    .name = "particle_buffer_in",
                    .size = buffer_size,
                    .usage = .{ .storage_buffer_bit = true, .vertex_buffer_bit = true, .transfer_dst_bit = true, .transfer_src_bit = true },
                    .strategy = .device_local,
                },
                @intCast(i),
            );

            self.particle_buffers.particle_buffers_out[i] = try buffer_manager.createBuffer(
                BufferConfig{
                    .name = "particle_buffer_out",
                    .size = buffer_size,
                    .usage = .{ .storage_buffer_bit = true, .vertex_buffer_bit = true, .transfer_src_bit = true, .transfer_dst_bit = true },
                    .strategy = .device_local,
                },
                @intCast(i),
            );
        }

        // Initialize particle buffers with invisible particles
        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            try self.initializeParticleBuffer(i);
        }

        // Create uniform buffers (per frame)
        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            self.compute_uniform_buffers[i] = try buffer_manager.createBuffer(
                BufferConfig{
                    .name = "particle_compute_ubo",
                    .size = @sizeOf(ComputeUniformBuffer),
                    .usage = .{ .uniform_buffer_bit = true },
                    .strategy = .host_visible,
                },
                @intCast(i),
            );

            // Map the uniform buffer for direct CPU writes
            try self.compute_uniform_buffers[i].buffer.map(@sizeOf(ComputeUniformBuffer), 0);
        }

        // Create emitter buffer (shared across frames)
        self.emitter_buffer = try buffer_manager.createBuffer(
            BufferConfig{
                .name = "particle_emitter_buffer",
                .size = @sizeOf(vertex_formats.GPUEmitter) * max_emitters,
                .usage = .{ .storage_buffer_bit = true, .transfer_dst_bit = true, .transfer_src_bit = true },
                .strategy = .host_visible,
            },
            0,
        );

        // Map the emitter buffer for direct CPU writes
        try self.emitter_buffer.buffer.map(@sizeOf(vertex_formats.GPUEmitter) * max_emitters, 0);

        log(.INFO, "particle_system", "ParticleSystem initialized ({} particles, {} emitters)", .{ max_particles, max_emitters });
        return self;
    }

    pub fn deinit(self: *ParticleSystem) void {
        // Unmap buffers before destroying
        for (&self.compute_uniform_buffers) |buffer| {
            buffer.buffer.unmap();
        }
        self.emitter_buffer.buffer.unmap();

        // Clean up particle buffers
        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            self.buffer_manager.destroyBuffer(self.particle_buffers.particle_buffers_in[i]) catch {};
            self.buffer_manager.destroyBuffer(self.particle_buffers.particle_buffers_out[i]) catch {};
        }

        // Clean up uniform buffers
        for (&self.compute_uniform_buffers) |buffer| {
            self.buffer_manager.destroyBuffer(buffer) catch {};
        }

        // Clean up emitter buffer
        self.buffer_manager.destroyBuffer(self.emitter_buffer) catch {};

        log(.INFO, "particle_system", "ParticleSystem cleaned up", .{});
        self.allocator.destroy(self);
    }

    /// Get GPU resources for rendering (opaque handle)
    pub fn getGPUResources(self: *ParticleSystem) ParticleGPUResources {
        return .{
            .particle_buffers = &self.particle_buffers,
            .compute_uniform_buffers = &self.compute_uniform_buffers,
            .emitter_buffer = &self.emitter_buffer,
            .max_particles = self.max_particles,
            .max_emitters = self.max_emitters,
        };
    }

    /// Initialize particle buffer with invisible particles (alpha = 0)
    fn initializeParticleBuffer(self: *ParticleSystem, frame_index: usize) !void {
        const particles = try self.allocator.alloc(vertex_formats.Particle, self.max_particles);
        defer self.allocator.free(particles);

        // Initialize all particles as dead (lifetime = 0)
        for (particles) |*particle| {
            particle.* = vertex_formats.Particle{
                .position = .{ 0.0, 0.0, 0.0 },
                .velocity = .{ 0.0, 0.0, 0.0 },
                .color = .{ 0.0, 0.0, 0.0, 0.0 }, // Alpha = 0 makes it invisible
                .lifetime = 0.0,
                .max_lifetime = 1.0,
                .emitter_id = 0,
            };
        }

        const buffer_size = self.max_particles * @sizeOf(vertex_formats.Particle);
        const particle_bytes = std.mem.sliceAsBytes(particles);

        // Create staging buffer
        var staging_buffer = try Buffer.init(
            self.graphics_context,
            buffer_size,
            1,
            .{ .transfer_src_bit = true },
            .{ .host_visible_bit = true, .host_coherent_bit = true },
        );
        defer staging_buffer.deinit();

        try staging_buffer.map(buffer_size, 0);
        defer staging_buffer.unmap();

        staging_buffer.writeToBuffer(particle_bytes, buffer_size, 0);

        // Upload to both input and output buffers
        try self.graphics_context.copyBuffer(
            self.particle_buffers.particle_buffers_in[frame_index].buffer.buffer,
            staging_buffer.buffer,
            buffer_size,
        );
        try self.graphics_context.copyBuffer(
            self.particle_buffers.particle_buffers_out[frame_index].buffer.buffer,
            staging_buffer.buffer,
            buffer_size,
        );
    }

    /// Add a new emitter and spawn initial particles for it
    pub fn addEmitter(self: *ParticleSystem, emitter: vertex_formats.GPUEmitter, initial_particles: []const vertex_formats.Particle) !u32 {
        if (self.emitter_count >= self.max_emitters) {
            return error.TooManyEmitters;
        }

        const emitter_id = self.emitter_count;

        // Write emitter to buffer
        const emitter_bytes = std.mem.asBytes(&emitter);
        const emitter_size = @sizeOf(vertex_formats.GPUEmitter);
        const offset = emitter_id * emitter_size;

        // Write to mapped buffer
        const dst_ptr = @as([*]u8, @ptrCast(self.emitter_buffer.buffer.mapped.?))[offset..];
        @memcpy(dst_ptr[0..emitter_bytes.len], emitter_bytes);

        self.emitter_count += 1;

        // Spawn initial particles
        if (initial_particles.len > 0) {
            try self.spawnParticlesForEmitter(emitter_id, initial_particles);
        }

        return emitter_id;
    }

    /// Update an existing emitter (position, colors, spawn rate, etc.)
    pub fn updateEmitter(self: *ParticleSystem, emitter_id: u32, emitter: vertex_formats.GPUEmitter) !void {
        if (emitter_id >= self.emitter_count) {
            return error.InvalidEmitterId;
        }

        const emitter_bytes = std.mem.asBytes(&emitter);
        const emitter_size = @sizeOf(vertex_formats.GPUEmitter);
        const offset = emitter_id * emitter_size;

        // Write to mapped buffer
        const dst_ptr = @as([*]u8, @ptrCast(self.emitter_buffer.buffer.mapped.?))[offset..];
        @memcpy(dst_ptr[0..emitter_bytes.len], emitter_bytes);
    }

    /// Remove an emitter and kill all its particles
    pub fn removeEmitter(self: *ParticleSystem, emitter_id: u32) !void {
        if (emitter_id >= self.emitter_count) {
            return error.InvalidEmitterId;
        }

        // Mark emitter as inactive
        var emitter: vertex_formats.GPUEmitter = undefined;
        const emitter_size = @sizeOf(vertex_formats.GPUEmitter);
        const offset = emitter_id * emitter_size;

        // Read current emitter data
        const src_ptr = @as([*]u8, @ptrCast(self.emitter_buffer.buffer.mapped.?))[offset..];
        @memcpy(std.mem.asBytes(&emitter), src_ptr[0..emitter_size]);

        // Mark as inactive
        emitter.is_active = 0;

        // Write back
        const dst_ptr = @as([*]u8, @ptrCast(self.emitter_buffer.buffer.mapped.?))[offset..];
        @memcpy(dst_ptr[0..emitter_size], std.mem.asBytes(&emitter));

        // Kill all particles belonging to this emitter
        try self.killParticlesForEmitter(emitter_id);

        log(.INFO, "particle_system", "Removed emitter {d}", .{emitter_id});
    }

    /// Spawn initial particles for a new emitter
    fn spawnParticlesForEmitter(self: *ParticleSystem, emitter_id: u32, new_particles: []const vertex_formats.Particle) !void {
        // Calculate particle range for this emitter
        const particles_per_emitter = self.max_particles / self.max_emitters;
        const range_size = particles_per_emitter * @sizeOf(vertex_formats.Particle);
        const range_offset = @as(vk.DeviceSize, emitter_id) * @as(vk.DeviceSize, particles_per_emitter) * @as(vk.DeviceSize, @sizeOf(vertex_formats.Particle));

        // Prepare particles for this emitter's range only
        const particles_to_write = try self.allocator.alloc(vertex_formats.Particle, particles_per_emitter);
        defer self.allocator.free(particles_to_write);

        // Initialize all particles in this emitter's range
        var spawn_index: usize = 0;
        for (0..particles_per_emitter) |slot_idx| {
            if (spawn_index < new_particles.len) {
                // Use initial particle data
                particles_to_write[slot_idx] = new_particles[spawn_index];
                particles_to_write[slot_idx].emitter_id = emitter_id;
                spawn_index += 1;
            } else {
                // Fill remaining slots with dead particles owned by this emitter
                particles_to_write[slot_idx] = vertex_formats.Particle{
                    .position = .{ 0.0, 0.0, 0.0 },
                    .velocity = .{ 0.0, 0.0, 0.0 },
                    .color = .{ 0.0, 0.0, 0.0, 0.0 },
                    .lifetime = 0.0,
                    .max_lifetime = 1.0,
                    .emitter_id = emitter_id,
                };
            }
        }

        // Create staging buffer for just this emitter's range
        var staging_write = try Buffer.init(
            self.graphics_context,
            range_size,
            1,
            .{ .transfer_src_bit = true },
            .{ .host_visible_bit = true, .host_coherent_bit = true },
        );
        defer staging_write.deinit();

        try staging_write.map(range_size, 0);
        defer staging_write.unmap();

        const particle_bytes = std.mem.sliceAsBytes(particles_to_write);
        staging_write.writeToBuffer(particle_bytes, range_size, 0);

        // Copy to all frame buffers (IN and OUT)
        for (0..MAX_FRAMES_IN_FLIGHT) |frame_idx| {
            try self.graphics_context.copyBufferWithOffset(
                self.particle_buffers.particle_buffers_in[frame_idx].buffer.buffer,
                staging_write.buffer,
                @as(vk.DeviceSize, range_size),
                range_offset,
                0,
            );

            try self.graphics_context.copyBufferWithOffset(
                self.particle_buffers.particle_buffers_out[frame_idx].buffer.buffer,
                staging_write.buffer,
                @as(vk.DeviceSize, range_size),
                range_offset,
                0,
            );
        }

        self.last_particle_count = @max(self.last_particle_count, @as(u32, @intCast(spawn_index)));
    }

    /// Kill all particles belonging to an emitter
    fn killParticlesForEmitter(self: *ParticleSystem, emitter_id: u32) !void {
        const last_frame: usize = if (self.last_particle_count == 0) 0 else (MAX_FRAMES_IN_FLIGHT - 1);

        // Calculate particle range for this emitter
        const particles_per_emitter = self.max_particles / self.max_emitters;
        const range_size = particles_per_emitter * @sizeOf(vertex_formats.Particle);
        const range_offset = @as(vk.DeviceSize, emitter_id) * @as(vk.DeviceSize, particles_per_emitter) * @as(vk.DeviceSize, @sizeOf(vertex_formats.Particle));

        // Read only this emitter's particle range
        var staging_buffer = try Buffer.init(
            self.graphics_context,
            range_size,
            1,
            .{ .transfer_dst_bit = true, .transfer_src_bit = true },
            .{ .host_visible_bit = true, .host_coherent_bit = true },
        );
        defer staging_buffer.deinit();

        // Read the emitter range into the staging buffer
        try self.graphics_context.copyBufferWithOffset(
            staging_buffer.buffer,
            self.particle_buffers.particle_buffers_out[last_frame].buffer.buffer,
            @as(vk.DeviceSize, range_size),
            0,
            range_offset,
        );

        try staging_buffer.map(range_size, 0);
        defer staging_buffer.unmap();

        const particles = @as([*]vertex_formats.Particle, @ptrCast(@alignCast(staging_buffer.mapped.?)))[0..particles_per_emitter];

        // Kill all particles in this emitter's range
        for (particles) |*particle| {
            particle.lifetime = 0.0;
            particle.color[3] = 0.0; // Set alpha to 0
        }

        // Write back to all frame buffers
        for (0..MAX_FRAMES_IN_FLIGHT) |frame_idx| {
            try self.graphics_context.copyBufferWithOffset(
                self.particle_buffers.particle_buffers_in[frame_idx].buffer.buffer,
                staging_buffer.buffer,
                @as(vk.DeviceSize, range_size),
                range_offset,
                0,
            );
            try self.graphics_context.copyBufferWithOffset(
                self.particle_buffers.particle_buffers_out[frame_idx].buffer.buffer,
                staging_buffer.buffer,
                @as(vk.DeviceSize, range_size),
                range_offset,
                0,
            );
        }
    }

    /// Get the output particle buffer for rendering
    pub fn getParticleBuffer(self: *ParticleSystem, frame_index: usize) vk.Buffer {
        return self.particle_buffers.particle_buffers_out[frame_index].buffer.buffer;
    }

    /// Get the current active particle count
    pub fn getParticleCount(self: *ParticleSystem) u32 {
        const particles_per_emitter = self.max_particles / self.max_emitters;
        return particles_per_emitter * self.emitter_count;
    }

    /// Update particle emitters - mainly tracks transform changes
    /// GPU handles actual particle updates
    pub fn update(self: *ParticleSystem, world: *World, dt: f32) !void {
        _ = self;
        _ = dt; // GPU handles timing

        // Just verify emitters are active and have transforms
        // The actual GPU update happens in scene via render graph
        var view = try world.view(ParticleEmitter);
        var iter = view.iterator();

        while (iter.next()) |item| {
            const emitter = item.component;
            if (!emitter.active) continue;

            // Verify transform exists
            _ = world.get(Transform, item.entity) orelse continue;

            // Transform dirty flag will trigger GPU emitter update in scene
        }
    }

    /// Reset the particle system
    pub fn reset(self: *ParticleSystem) void {
        self.emitter_count = 0;
        self.last_particle_count = 0;
        log(.INFO, "particle_system", "ParticleSystem reset", .{});
    }
};

/// Compute shader uniform buffer
const ComputeUniformBuffer = extern struct {
    delta_time: f32,
    particle_count: u32,
    emitter_count: u32,
    max_particles: u32,
    gravity: [4]f32,
    frame_index: u32,
    _padding: [2]u32 = .{ 0, 0 },
};

/// Standalone system function for particle emitter updates (for SystemScheduler)
/// Updates GPU emitter positions when transforms change
/// Free update function for particle emitters (SystemScheduler-compatible)
pub fn update(world: *World, dt: f32) !void {
    _ = dt; // GPU handles all particle updates now

    // Get the scene from world userdata
    const scene_ptr = world.getUserData("scene") orelse return;
    const scene: *Scene = @ptrCast(@alignCast(scene_ptr));

    // Update GPU emitter positions when transforms change
    var view = try world.view(ParticleEmitter);
    var iter = view.iterator();

    while (iter.next()) |item| {
        const entity = item.entity;
        const emitter = item.component;

        if (!emitter.active) continue;

        // Get current transform
        const transform = world.get(Transform, entity) orelse continue;

        // Only update GPU emitter if transform changed (dirty flag)
        if (!transform.dirty) continue;

        // Get GPU emitter ID
        // Optimization: Use cached ID in component if available
        var gpu_id: u32 = 0;
        if (emitter.gpu_id) |id| {
            gpu_id = id;
        } else {
            // Fallback to hash map lookup and cache it
            if (scene.emitter_to_gpu_id.get(entity)) |id| {
                gpu_id = id;
                emitter.gpu_id = id;
            } else {
                continue;
            }
        }

        // Update GPU emitter via ParticleSystem
        if (scene.particle_system) |ps| {
            // Update GPU emitter with new position
            const gpu_emitter = vertex_formats.GPUEmitter{
                .position = .{ transform.position.x, transform.position.y, transform.position.z },
                .is_active = if (emitter.active) 1 else 0,
                .velocity_min = .{ emitter.velocity_min.x, emitter.velocity_min.y, emitter.velocity_min.z },
                .velocity_max = .{ emitter.velocity_max.x, emitter.velocity_max.y, emitter.velocity_max.z },
                .color_start = .{ emitter.color.x, emitter.color.y, emitter.color.z, 1.0 },
                .color_end = .{ emitter.color.x * 0.5, emitter.color.y * 0.5, emitter.color.z * 0.5, 0.0 },
                .lifetime_min = emitter.particle_lifetime * 0.8,
                .lifetime_max = emitter.particle_lifetime * 1.2,
                .spawn_rate = emitter.emission_rate,
                .accumulated_spawn_time = 0.0,
                .particles_per_spawn = 1,
            };

            try ps.updateEmitter(gpu_id, gpu_emitter);
            // NOTE: Don't clear dirty flag here - RenderSystem needs to detect transform changes!
            // The dirty flag will be cleared by RenderSystem after rebuilding the cache.
        }
    }
}
