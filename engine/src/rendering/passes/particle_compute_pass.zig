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
const Resource = @import("../unified_pipeline_system.zig").Resource;
const ResourceBinder = @import("../resource_binder.zig").ResourceBinder;
const MAX_FRAMES_IN_FLIGHT = @import("../../core/swapchain.zig").MAX_FRAMES_IN_FLIGHT;
const Buffer = @import("../../core/buffer.zig").Buffer;
const vertex_formats = @import("../vertex_formats.zig");

// ECS imports
const ecs = @import("../../ecs.zig");
const World = ecs.World;
const ParticleComponent = ecs.ParticleComponent;

/// Compute shader uniform buffer
const ComputeUniformBuffer = extern struct {
    delta_time: f32,
    particle_count: u32, // Total allocated particle slots
    emitter_count: u32, // Number of active emitters
    max_particles: u32, // Maximum particle capacity
    gravity: [4]f32, // Global gravity vector
    frame_index: u32, // Current frame for random seed
    _padding: [2]u32 = .{ 0, 0 },
};

/// Particle buffers for ping-pong compute shader
const ParticleBuffers = struct {
    particle_buffer_in: Buffer,
    particle_buffer_out: Buffer,

    fn create(
        graphics_context: *GraphicsContext,
        max_particles: u32,
    ) !ParticleBuffers {
        const buffer_size = @sizeOf(vertex_formats.Particle) * max_particles;

        const particle_buffer_in = try Buffer.init(
            graphics_context,
            buffer_size,
            1,
            .{ .storage_buffer_bit = true, .vertex_buffer_bit = true, .transfer_dst_bit = true, .transfer_src_bit = true },
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

/// Particle compute pass - runs GPU-based particle simulation
pub const ParticleComputePass = struct {
    base: RenderPass,
    allocator: std.mem.Allocator,

    // Rendering context
    graphics_context: *GraphicsContext,
    pipeline_system: *UnifiedPipelineSystem,
    resource_binder: ResourceBinder,
    ecs_world: *World,

    // Compute pipeline
    compute_pipeline: PipelineId = undefined,
    cached_pipeline_handle: vk.Pipeline = .null_handle,

    // Particle storage (per frame in flight with ping-pong buffers)
    particle_buffers: [MAX_FRAMES_IN_FLIGHT]ParticleBuffers,

    // Uniform buffers (per frame in flight)
    compute_uniform_buffers: [MAX_FRAMES_IN_FLIGHT]Buffer,

    // Emitter SSBO (shared across all frames, host-visible for direct updates)
    emitter_buffer: Buffer,
    max_emitters: u32,
    emitter_count: u32 = 0,

    // Particle count
    max_particles: u32,
    last_particle_count: u32 = 0,

    /// Initialize particle buffer with invisible particles (alpha = 0)
    fn initializeParticleBuffer(
        allocator: std.mem.Allocator,
        graphics_context: *GraphicsContext,
        buffers: *ParticleBuffers,
        max_particles: u32,
    ) !void {
        // Create array of invisible particles
        const particles = try allocator.alloc(vertex_formats.Particle, max_particles);
        defer allocator.free(particles);

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

        const buffer_size = max_particles * @sizeOf(vertex_formats.Particle);
        const particle_bytes = std.mem.sliceAsBytes(particles);

        // Create staging buffer
        var staging_buffer = try Buffer.init(
            graphics_context,
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
        try graphics_context.copyBuffer(
            buffers.particle_buffer_in.buffer,
            staging_buffer.buffer,
            buffer_size,
        );
        try graphics_context.copyBuffer(
            buffers.particle_buffer_out.buffer,
            staging_buffer.buffer,
            buffer_size,
        );
    }

    pub fn create(
        allocator: std.mem.Allocator,
        graphics_context: *GraphicsContext,
        pipeline_system: *UnifiedPipelineSystem,
        ecs_world: *World,
        max_particles: u32,
        max_emitters: u32,
    ) !*ParticleComputePass {
        const pass = try allocator.create(ParticleComputePass);

        // Create particle buffers for each frame
        var particle_buffers: [MAX_FRAMES_IN_FLIGHT]ParticleBuffers = undefined;
        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            particle_buffers[i] = try ParticleBuffers.create(
                graphics_context,
                max_particles,
            );
        }

        // Create uniform buffers (per frame in flight)
        var compute_uniform_buffers: [MAX_FRAMES_IN_FLIGHT]Buffer = undefined;
        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            compute_uniform_buffers[i] = try Buffer.init(
                graphics_context,
                @sizeOf(ComputeUniformBuffer),
                1,
                .{ .uniform_buffer_bit = true },
                .{ .host_visible_bit = true, .host_coherent_bit = true },
            );
            try compute_uniform_buffers[i].map(vk.WHOLE_SIZE, 0);
        }

        // Create emitter SSBO (shared across all frames, stays mapped)
        var emitter_buffer = try Buffer.init(
            graphics_context,
            @sizeOf(vertex_formats.GPUEmitter) * max_emitters,
            1,
            .{ .storage_buffer_bit = true, .transfer_dst_bit = true, .transfer_src_bit = true },
            .{ .host_visible_bit = true, .host_coherent_bit = true },
        );
        try emitter_buffer.map(vk.WHOLE_SIZE, 0);

        pass.* = ParticleComputePass{
            .base = RenderPass{
                .name = "particle_compute_pass",
                .enabled = true,
                .vtable = &vtable,
                .dependencies = std.ArrayList([]const u8){},
            },
            .allocator = allocator,
            .graphics_context = graphics_context,
            .pipeline_system = pipeline_system,
            .resource_binder = ResourceBinder.init(allocator, pipeline_system),
            .ecs_world = ecs_world,
            .particle_buffers = particle_buffers,
            .compute_uniform_buffers = compute_uniform_buffers,
            .emitter_buffer = emitter_buffer,
            .max_emitters = max_emitters,
            .max_particles = max_particles,
        };

        log(.INFO, "particle_compute_pass", "Created ParticleComputePass (max={} particles, {} emitters)", .{ max_particles, max_emitters });
        return pass;
    }

    const vtable = RenderPassVTable{
        .setup = setupImpl,
        .update = updateImpl,
        .execute = executeImpl,
        .teardown = teardownImpl,
    };

    fn updateImpl(base: *RenderPass, frame_info: *const FrameInfo) !void {
        _ = base;
        _ = frame_info;
        // No per-frame updates needed for particle compute pass
    }

    fn setupImpl(base: *RenderPass, graph: *RenderGraph) !void {
        const self: *ParticleComputePass = @fieldParentPtr("base", base);
        _ = graph;

        // Create compute pipeline for particle simulation
        const pipeline_config = PipelineConfig{
            .name = "particle_compute",
            .compute_shader = "shaders/particles.comp",
            .render_pass = .null_handle, // Compute pipelines don't use render passes
        };

        self.compute_pipeline = try self.pipeline_system.createPipeline(pipeline_config);
        const entry = self.pipeline_system.pipelines.get(self.compute_pipeline) orelse return error.PipelineNotFound;
        self.cached_pipeline_handle = entry.vulkan_pipeline;

        // Bind all resources and update descriptor sets
        try self.updateDescriptors();

        log(.INFO, "particle_compute_pass", "Setup complete", .{});
    }

    fn executeImpl(base: *RenderPass, frame_info: FrameInfo) !void {
        const self: *ParticleComputePass = @fieldParentPtr("base", base);

        const command_buffer = frame_info.compute_buffer;
        if (command_buffer == .null_handle) {
            return; // No compute command buffer available
        }

        const frame_index = frame_info.current_frame;

        // Check for pipeline reload
        var pipeline_entry = self.pipeline_system.pipelines.get(self.compute_pipeline) orelse return error.PipelineNotFound;
        const pipeline_rebuilt = pipeline_entry.vulkan_pipeline != self.cached_pipeline_handle;

        if (pipeline_rebuilt) {
            log(.INFO, "particle_compute_pass", "Pipeline hot-reloaded, rebinding all descriptors", .{});
            self.pipeline_system.markPipelineResourcesDirty(self.compute_pipeline);
            self.cached_pipeline_handle = pipeline_entry.vulkan_pipeline;

            // Rebind descriptors for ALL frames
            try self.updateDescriptors();
            pipeline_entry = self.pipeline_system.pipelines.get(self.compute_pipeline) orelse return error.PipelineNotFound;
        }

        // Update compute uniform buffer
        // Only process particles for active emitters (200 particles per emitter)
        const particles_per_emitter = self.max_particles / self.max_emitters;
        const active_particle_slots = particles_per_emitter * self.emitter_count;

        const compute_ubo = ComputeUniformBuffer{
            .delta_time = frame_info.dt,
            .particle_count = active_particle_slots, // Only process slots for active emitters
            .emitter_count = self.emitter_count,
            .max_particles = self.max_particles,
            .gravity = .{ 0.0, 9.81, 0.0, 0.0 }, // Standard gravity
            .frame_index = frame_info.current_frame,
        };

        const compute_ubo_bytes = std.mem.asBytes(&compute_ubo);
        self.compute_uniform_buffers[frame_index].writeToBuffer(compute_ubo_bytes, @sizeOf(ComputeUniformBuffer), 0);

        try self.resource_binder.updateFrame(self.compute_pipeline, frame_index);

        try self.pipeline_system.bindPipelineWithDescriptorSets(command_buffer, self.compute_pipeline, frame_index);

        // Dispatch compute shader - only process active particle slots
        const workgroup_size = 256; // Match shader local_size_x
        const workgroups = if (active_particle_slots > 0)
            (active_particle_slots + workgroup_size - 1) / workgroup_size
        else
            0;

        if (workgroups > 0) {
            self.graphics_context.vkd.cmdDispatch(command_buffer, workgroups, 1, 1);
        }

        // OPTIMIZATION: Early exit if no particles to process
        // Avoids memory barriers and buffer copy when no particles are active
        if (active_particle_slots == 0) {
            return;
        }

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

        // Copy output back to input for this frame (ping-pong for next iteration)
        // Only copy active particle slots instead of entire buffer
        const active_buffer_size = active_particle_slots * @sizeOf(vertex_formats.Particle);

        const copy_region = vk.BufferCopy{
            .src_offset = 0,
            .dst_offset = 0,
            .size = active_buffer_size,
        };
        self.graphics_context.vkd.cmdCopyBuffer(
            command_buffer,
            self.particle_buffers[frame_index].particle_buffer_out.buffer,
            self.particle_buffers[(frame_index + 1) % MAX_FRAMES_IN_FLIGHT].particle_buffer_in.buffer,
            1,
            @ptrCast(&copy_region),
        );

        // Barrier to ensure copy completes before next compute dispatch
        const copy_barrier = vk.MemoryBarrier{
            .src_access_mask = .{ .transfer_write_bit = true },
            .dst_access_mask = .{ .shader_read_bit = true },
        };

        self.graphics_context.vkd.cmdPipelineBarrier(
            command_buffer,
            .{ .transfer_bit = true },
            .{ .compute_shader_bit = true },
            .{},
            1,
            @ptrCast(&copy_barrier),
            0,
            null,
            0,
            null,
        );
    }

    fn teardownImpl(base: *RenderPass) void {
        const self: *ParticleComputePass = @fieldParentPtr("base", base);

        // Clean up particle buffers
        for (&self.particle_buffers) |*buffers| {
            buffers.destroy();
        }

        // Clean up uniform buffers
        for (&self.compute_uniform_buffers) |*buffer| {
            buffer.deinit();
        }

        // Clean up emitter buffer
        self.emitter_buffer.deinit();

        log(.INFO, "particle_compute_pass", "Cleaned up ParticleComputePass", .{});
        self.allocator.destroy(self);
    }

    /// Update descriptor sets for all frames (called on pipeline reload)
    fn updateDescriptors(self: *ParticleComputePass) !void {
        // Rebind all resources for ALL frames
        for (0..MAX_FRAMES_IN_FLIGHT) |frame_index| {
            // Bind uniform buffer
            try self.pipeline_system.bindResource(
                self.compute_pipeline,
                0, // set
                0, // binding - uniform buffer
                Resource{ .buffer = .{
                    .buffer = self.compute_uniform_buffers[frame_index].buffer,
                    .offset = 0,
                    .range = @sizeOf(ComputeUniformBuffer),
                } },
                @intCast(frame_index),
            );

            // Bind particle buffer in (storage buffer)
            try self.pipeline_system.bindResource(
                self.compute_pipeline,
                0, // set
                1, // binding - particle buffer in
                Resource{ .buffer = .{
                    .buffer = self.particle_buffers[frame_index].particle_buffer_in.buffer,
                    .offset = 0,
                    .range = vk.WHOLE_SIZE,
                } },
                @intCast(frame_index),
            );

            // Bind particle buffer out (storage buffer)
            try self.pipeline_system.bindResource(
                self.compute_pipeline,
                0, // set
                2, // binding - particle buffer out
                Resource{ .buffer = .{
                    .buffer = self.particle_buffers[frame_index].particle_buffer_out.buffer,
                    .offset = 0,
                    .range = vk.WHOLE_SIZE,
                } },
                @intCast(frame_index),
            );

            // Bind emitter buffer (storage buffer, shared across all frames)
            try self.pipeline_system.bindResource(
                self.compute_pipeline,
                0, // set
                3, // binding - emitter buffer
                Resource{ .buffer = .{
                    .buffer = self.emitter_buffer.buffer,
                    .offset = 0,
                    .range = vk.WHOLE_SIZE,
                } },
                @intCast(frame_index),
            );

            // Update descriptor sets for this frame
            try self.pipeline_system.updateDescriptorSetsForPipeline(
                self.compute_pipeline,
                @intCast(frame_index),
            );
        }
    }

    /// Add a new emitter and spawn initial particles for it
    pub fn addEmitter(self: *ParticleComputePass, emitter: vertex_formats.GPUEmitter, initial_particles: []const vertex_formats.Particle) !u32 {
        if (self.emitter_count >= self.max_emitters) {
            return error.TooManyEmitters;
        }

        const emitter_id = self.emitter_count;

        // Write emitter to mapped buffer
        const emitter_bytes = std.mem.asBytes(&emitter);
        const emitter_size = self.emitter_buffer.instance_size;
        const offset = emitter_id * emitter_size;

        self.emitter_buffer.writeToBuffer(emitter_bytes, emitter_size, offset);
        // No flush needed - using host_coherent memory

        self.emitter_count += 1;

        // NOTE: No need to call updateDescriptors() here!
        // The descriptor set already points to the emitter buffer.
        // We're just updating the data in mapped memory, not changing the binding.
        // Descriptors only need updating on pipeline reload (handled in executeImpl).

        // Spawn initial particles: Read last simulated buffer, add new particles, write to all buffers
        if (initial_particles.len > 0) {
            try self.spawnParticlesForEmitter(emitter_id, initial_particles);
        }

        return emitter_id;
    }

    /// Update an existing emitter (position, colors, spawn rate, etc.)
    /// This just updates the mapped memory - no particle buffer sync needed
    pub fn updateEmitter(self: *ParticleComputePass, emitter_id: u32, emitter: vertex_formats.GPUEmitter) !void {
        if (emitter_id >= self.emitter_count) {
            return error.InvalidEmitterId;
        }

        const emitter_bytes = std.mem.asBytes(&emitter);
        const emitter_size = @sizeOf(vertex_formats.GPUEmitter);
        const offset = emitter_id * emitter_size;

        self.emitter_buffer.writeToBuffer(emitter_bytes, emitter_size, offset);
        // No flush needed - using host_coherent memory
    }

    /// Remove an emitter and kill all its particles
    pub fn removeEmitter(self: *ParticleComputePass, emitter_id: u32) !void {
        if (emitter_id >= self.emitter_count) {
            return error.InvalidEmitterId;
        }

        // Mark emitter as inactive
        var emitter: vertex_formats.GPUEmitter = undefined;
        const emitter_size = @sizeOf(vertex_formats.GPUEmitter);
        const offset = emitter_id * emitter_size;

        // Read current emitter data
        const emitter_ptr = @as([*]u8, @ptrCast(self.emitter_buffer.mapped.?))[offset .. offset + emitter_size];
        @memcpy(std.mem.asBytes(&emitter), emitter_ptr);

        // Mark as inactive
        emitter.is_active = 0;

        self.emitter_buffer.writeToBuffer(std.mem.asBytes(&emitter), emitter_size, offset);
        try self.emitter_buffer.flush(emitter_size, offset);

        // Kill all particles belonging to this emitter by reading last simulated buffer,
        // filtering out particles with this emitter_id, and writing back
        try self.killParticlesForEmitter(emitter_id);

        log(.INFO, "particle_compute_pass", "Removed emitter {d}", .{emitter_id});
    }

    /// Spawn initial particles for a new emitter
    /// OPTIMIZATION: Only reads/writes the emitter's particle range, not the entire buffer
    fn spawnParticlesForEmitter(self: *ParticleComputePass, emitter_id: u32, new_particles: []const vertex_formats.Particle) !void {
        // Calculate particle range for this emitter
        const particles_per_emitter = self.max_particles / self.max_emitters;
        const emitter_start_slot = emitter_id * particles_per_emitter;
        const range_size = particles_per_emitter * @sizeOf(vertex_formats.Particle);
        const range_offset = emitter_start_slot * @sizeOf(vertex_formats.Particle);

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

        // Copy only this emitter's range to all frame buffers (IN and OUT)
        // Use immediate command buffer for the copy
        const cmd_buffer = try self.graphics_context.beginSingleTimeCommands();
        defer self.graphics_context.endSingleTimeCommands(cmd_buffer) catch {};

        const copy_region = vk.BufferCopy{
            .src_offset = 0,
            .dst_offset = range_offset,
            .size = range_size,
        };

        for (0..MAX_FRAMES_IN_FLIGHT) |frame_idx| {
            self.graphics_context.vkd.cmdCopyBuffer(
                cmd_buffer,
                staging_write.buffer,
                self.particle_buffers[frame_idx].particle_buffer_in.buffer,
                1,
                @ptrCast(&copy_region),
            );
            self.graphics_context.vkd.cmdCopyBuffer(
                cmd_buffer,
                staging_write.buffer,
                self.particle_buffers[frame_idx].particle_buffer_out.buffer,
                1,
                @ptrCast(&copy_region),
            );
        }

        self.last_particle_count = @max(self.last_particle_count, @as(u32, @intCast(spawn_index)));
    }

    /// Kill all particles belonging to an emitter
    /// OPTIMIZATION: Only reads/writes the emitter's particle range, not the entire buffer
    fn killParticlesForEmitter(self: *ParticleComputePass, emitter_id: u32) !void {
        const last_frame: usize = if (self.last_particle_count == 0) 0 else (MAX_FRAMES_IN_FLIGHT - 1);

        // Calculate particle range for this emitter
        const particles_per_emitter = self.max_particles / self.max_emitters;
        const emitter_start_slot = emitter_id * particles_per_emitter;
        const range_size = particles_per_emitter * @sizeOf(vertex_formats.Particle);
        const range_offset = emitter_start_slot * @sizeOf(vertex_formats.Particle);

        // Read only this emitter's particle range
        var staging_buffer = try Buffer.init(
            self.graphics_context,
            range_size,
            1,
            .{ .transfer_dst_bit = true, .transfer_src_bit = true },
            .{ .host_visible_bit = true, .host_coherent_bit = true },
        );
        defer staging_buffer.deinit();

        // Use immediate command for reading
        {
            const cmd_buffer = try self.graphics_context.beginSingleTimeCommands();
            defer self.graphics_context.endSingleTimeCommands(cmd_buffer) catch {};

            const read_region = vk.BufferCopy{
                .src_offset = range_offset,
                .dst_offset = 0,
                .size = range_size,
            };

            self.graphics_context.vkd.cmdCopyBuffer(
                cmd_buffer,
                self.particle_buffers[last_frame].particle_buffer_out.buffer,
                staging_buffer.buffer,
                1,
                @ptrCast(&read_region),
            );
        }

        try staging_buffer.map(range_size, 0);
        defer staging_buffer.unmap();

        const particles = @as([*]vertex_formats.Particle, @ptrCast(@alignCast(staging_buffer.mapped.?)))[0..particles_per_emitter];

        // Kill all particles in this emitter's range
        for (particles) |*particle| {
            particle.lifetime = 0.0;
            particle.color[3] = 0.0; // Set alpha to 0
        }

        // Write back only this emitter's range to all frame buffers
        const cmd_buffer = try self.graphics_context.beginSingleTimeCommands();
        defer self.graphics_context.endSingleTimeCommands(cmd_buffer) catch {};

        const write_region = vk.BufferCopy{
            .src_offset = 0,
            .dst_offset = range_offset,
            .size = range_size,
        };

        for (0..MAX_FRAMES_IN_FLIGHT) |frame_idx| {
            self.graphics_context.vkd.cmdCopyBuffer(
                cmd_buffer,
                staging_buffer.buffer,
                self.particle_buffers[frame_idx].particle_buffer_in.buffer,
                1,
                @ptrCast(&write_region),
            );
            self.graphics_context.vkd.cmdCopyBuffer(
                cmd_buffer,
                staging_buffer.buffer,
                self.particle_buffers[frame_idx].particle_buffer_out.buffer,
                1,
                @ptrCast(&write_region),
            );
        }
    }

    /// Get the output particle buffer for rendering
    pub fn getParticleBuffer(self: *ParticleComputePass, frame_index: usize) vk.Buffer {
        return self.particle_buffers[frame_index].particle_buffer_out.buffer;
    }

    /// Get the current active particle count (based on number of active emitters)
    pub fn getParticleCount(self: *ParticleComputePass) u32 {
        const particles_per_emitter = self.max_particles / self.max_emitters;
        return particles_per_emitter * self.emitter_count; // Only active emitter slots
    }
};
