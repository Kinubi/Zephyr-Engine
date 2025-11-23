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
const BufferManager = @import("../buffer_manager.zig").BufferManager;
const ManagedBuffer = @import("../buffer_manager.zig").ManagedBuffer;
const vertex_formats = @import("../vertex_formats.zig");

// ECS imports
const ecs = @import("../../ecs.zig");
const World = ecs.World;
const ParticleComponent = ecs.ParticleComponent;
const ParticleSystem = ecs.ParticleSystem;
const ParticleBuffers = ecs.ParticleBuffers;
const ParticleGPUResources = ecs.ParticleGPUResources;

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

/// Particle compute pass - runs GPU-based particle simulation
pub const ParticleComputePass = struct {
    base: RenderPass,
    allocator: std.mem.Allocator,

    // Rendering context
    graphics_context: *GraphicsContext,
    pipeline_system: *UnifiedPipelineSystem,
    resource_binder: ResourceBinder,
    ecs_world: *World,
    particle_system: *ParticleSystem,

    // Compute pipeline
    compute_pipeline: PipelineId = undefined,
    cached_pipeline_handle: vk.Pipeline = .null_handle,

    // GPU resource references (owned by ParticleSystem)
    particle_buffers: *const ParticleBuffers,
    compute_uniform_buffers: *const [MAX_FRAMES_IN_FLIGHT]*ManagedBuffer,
    emitter_buffer: *const *ManagedBuffer,

    // Configuration (from ParticleSystem)
    max_emitters: u32,
    max_particles: u32,

    // Debug counter
    debug_frame_counter: u32 = 0,

    pub fn create(
        allocator: std.mem.Allocator,
        graphics_context: *GraphicsContext,
        pipeline_system: *UnifiedPipelineSystem,
        particle_system: *ParticleSystem,
        ecs_world: *World,
    ) !*ParticleComputePass {
        const pass = try allocator.create(ParticleComputePass);

        // Get GPU resources from ParticleSystem
        const gpu_resources = particle_system.getGPUResources();

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
            .particle_system = particle_system,
            .particle_buffers = gpu_resources.particle_buffers,
            .compute_uniform_buffers = gpu_resources.compute_uniform_buffers,
            .emitter_buffer = gpu_resources.emitter_buffer,
            .max_emitters = gpu_resources.max_emitters,
            .max_particles = gpu_resources.max_particles,
        };

        log(.INFO, "particle_compute_pass", "Created ParticleComputePass (max={} particles, {} emitters)", .{ gpu_resources.max_particles, gpu_resources.max_emitters });
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
        const self: *ParticleComputePass = @fieldParentPtr("base", base);

        // Check if pipeline now exists (hot-reload succeeded)
        if (!self.pipeline_system.pipelines.contains(self.compute_pipeline)) {
            return false;
        }

        // Pipeline exists! Complete the setup that was skipped during initial failure
        const entry = self.pipeline_system.pipelines.get(self.compute_pipeline) orelse return false;
        self.cached_pipeline_handle = entry.vulkan_pipeline;

        // Bind all resources and update descriptor sets
        self.bindResources() catch |err| {
            log(.WARN, "particle_compute_pass", "Failed to update descriptors during recovery: {}", .{err});
            return false;
        };

        log(.INFO, "particle_compute_pass", "Recovery setup complete", .{});
        return true;
    }

    fn updateImpl(base: *RenderPass, frame_info: *const FrameInfo) !void {
        const self: *ParticleComputePass = @fieldParentPtr("base", base);
        // Check for pipeline reload
        var pipeline_entry = self.pipeline_system.pipelines.get(self.compute_pipeline) orelse return error.PipelineNotFound;
        const pipeline_rebuilt = pipeline_entry.vulkan_pipeline != self.cached_pipeline_handle;

        if (pipeline_rebuilt) {
            log(.INFO, "particle_compute_pass", "Pipeline hot-reloaded, rebinding all descriptors", .{});
            self.pipeline_system.markPipelineResourcesDirty(self.compute_pipeline);
            self.cached_pipeline_handle = pipeline_entry.vulkan_pipeline;

            // Rebind descriptors for ALL frames
            try self.bindResources();
            pipeline_entry = self.pipeline_system.pipelines.get(self.compute_pipeline) orelse return error.PipelineNotFound;
        }

        try self.resource_binder.updateFrame(self.compute_pipeline, frame_info.current_frame);
    }

    fn setupImpl(base: *RenderPass, graph: *RenderGraph) !void {
        const self: *ParticleComputePass = @fieldParentPtr("base", base);
        _ = graph;

        // Create compute pipeline for particle simulation
        const pipeline_config = PipelineConfig{
            .name = "particle_compute",
            .compute_shader = "assets/shaders/particles.comp",
            .render_pass = .null_handle, // Compute pipelines don't use render passes
        };

        const result = try self.pipeline_system.createPipeline(pipeline_config);
        self.compute_pipeline = result.id;

        if (!result.success) {
            log(.WARN, "particle_compute_pass", "Pipeline creation failed. Pass will be disabled.", .{});
            return error.PipelineCreationFailed;
        }

        const entry = self.pipeline_system.pipelines.get(self.compute_pipeline) orelse return error.PipelineNotFound;
        self.cached_pipeline_handle = entry.vulkan_pipeline;
        // Populate ResourceBinder with shader reflection data
        if (try self.pipeline_system.getPipelineReflection(self.compute_pipeline)) |reflection| {
            var mut_reflection = reflection;

            try self.resource_binder.populateFromReflection(mut_reflection);
            mut_reflection.deinit(self.allocator);
        } // Bind all resources and update descriptor sets
        try self.bindResources();
        self.pipeline_system.markPipelineResourcesDirty(self.compute_pipeline);

        log(.INFO, "particle_compute_pass", "Setup complete", .{});
    }

    fn executeImpl(base: *RenderPass, frame_info: FrameInfo) !void {
        const self: *ParticleComputePass = @fieldParentPtr("base", base);

        const command_buffer = frame_info.compute_buffer;
        if (command_buffer == .null_handle) {
            log(.WARN, "particle_compute_pass", "No compute command buffer available - skipping compute dispatch", .{});
            return; // No compute command buffer available
        }

        const frame_index = frame_info.current_frame;

        // Update compute uniform buffer
        // Only process particles for active emitters (200 particles per emitter)
        const particles_per_emitter = self.max_particles / self.max_emitters;
        const active_particle_slots = particles_per_emitter * self.particle_system.emitter_count;

        const delta_time = if (frame_info.snapshot) |s| s.delta_time else 0.0;

        const compute_ubo = ComputeUniformBuffer{
            .delta_time = delta_time,
            .particle_count = active_particle_slots, // Only process slots for active emitters
            .emitter_count = self.particle_system.emitter_count,
            .max_particles = self.max_particles,
            .gravity = .{ 0.0, 9.81, 0.0, 0.0 }, // Standard gravity
            .frame_index = frame_info.current_frame,
        };

        const compute_ubo_bytes = std.mem.asBytes(&compute_ubo);
        self.compute_uniform_buffers[frame_index].*.buffer.writeToBuffer(compute_ubo_bytes, @sizeOf(ComputeUniformBuffer), 0);

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
            self.particle_buffers.particle_buffers_out[frame_index].buffer.buffer,
            self.particle_buffers.particle_buffers_in[(frame_index + 1) % MAX_FRAMES_IN_FLIGHT].buffer.buffer,
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

        // ParticleSystem owns buffers - no cleanup needed here
        log(.INFO, "particle_compute_pass", "Cleaned up ParticleComputePass", .{});
        self.allocator.destroy(self);
    }

    /// Update descriptor sets for all frames (called on pipeline reload)
    fn bindResources(self: *ParticleComputePass) !void {

        // Bind uniform buffers (per frame) - matches shader "ComputeUniformBuffer ubo"
        try self.resource_binder.bindUniformBufferNamed(
            self.compute_pipeline,
            "ComputeUniformBuffer",
            self.compute_uniform_buffers.*,
        );

        // Bind particle buffers (storage buffers, per frame with ping-pong)
        // Match shader "ParticleBufferIn { particlesIn[] }"

        log(.INFO, "particle_compute_pass", "Binding ParticleBufferIn[0]={} to binding 1", .{self.particle_buffers.particle_buffers_in[0].buffer.buffer});
        try self.resource_binder.bindStorageBufferArrayNamed(
            self.compute_pipeline,
            "ParticleBufferIn",
            self.particle_buffers.particle_buffers_in,
        );

        // Match shader "ParticleBufferOut { particlesOut[] }"

        log(.INFO, "particle_compute_pass", "Binding ParticleBufferOut[0]={} to binding 2", .{self.particle_buffers.particle_buffers_out[0].buffer.buffer});
        try self.resource_binder.bindStorageBufferArrayNamed(
            self.compute_pipeline,
            "ParticleBufferOut",
            self.particle_buffers.particle_buffers_out,
        );

        // Bind emitter buffer (shared across all frames)
        // Match shader "EmitterBuffer { emitters[] }"
        try self.resource_binder.bindStorageBufferNamed(
            self.compute_pipeline,
            "EmitterBuffer",
            self.emitter_buffer.*,
        );
    }

    /// Delegate: Add a new emitter (managed by ParticleSystem)
    pub fn addEmitter(self: *ParticleComputePass, emitter: vertex_formats.GPUEmitter, initial_particles: []const vertex_formats.Particle) !u32 {
        return self.particle_system.addEmitter(emitter, initial_particles);
    }

    /// Delegate: Update an existing emitter (managed by ParticleSystem)
    pub fn updateEmitter(self: *ParticleComputePass, emitter_id: u32, emitter: vertex_formats.GPUEmitter) !void {
        return self.particle_system.updateEmitter(emitter_id, emitter);
    }

    /// Delegate: Remove an emitter (managed by ParticleSystem)
    pub fn removeEmitter(self: *ParticleComputePass, emitter_id: u32) !void {
        return self.particle_system.removeEmitter(emitter_id);
    }

    /// Delegate: Get the output particle buffer for rendering
    pub fn getParticleBuffer(self: *ParticleComputePass, frame_index: usize) vk.Buffer {
        return self.particle_system.getParticleBuffer(frame_index);
    }

    /// Delegate: Get the current active particle count
    pub fn getParticleCount(self: *ParticleComputePass) u32 {
        return self.particle_system.getParticleCount();
    }

    fn reset(ctx: *RenderPass) void {
        const self: *ParticleComputePass = @fieldParentPtr("base", ctx);
        self.resource_binder.clear();
        
        if (self.cached_pipeline_handle != .null_handle) {
            self.pipeline_system.destroyPipeline(self.compute_pipeline);
            self.cached_pipeline_handle = .null_handle;
        }
        
        log(.INFO, "particle_compute_pass", "Reset resources", .{});
    }
};
