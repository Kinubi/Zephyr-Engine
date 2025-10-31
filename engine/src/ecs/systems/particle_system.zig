const std = @import("std");
const World = @import("../world.zig").World;
const Transform = @import("../components/transform.zig").Transform;
const ParticleEmitter = @import("../components/particle_emitter.zig").ParticleEmitter;
const EntityId = @import("../entity_registry.zig").EntityId;
const Scene = @import("../../scene/scene.zig").Scene;
/// Particle system for managing CPU-side emitter state
/// GPU compute shader handles actual particle simulation
pub const ParticleSystem = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ParticleSystem {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ParticleSystem) void {
        _ = self;
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
};

/// Standalone system function for particle emitter updates (for SystemScheduler)
/// Updates GPU emitter positions when transforms change
pub fn updateParticleEmittersSystem(world: *World, dt: f32) !void {
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
        const gpu_id = scene.emitter_to_gpu_id.get(entity) orelse continue;

        if (scene.render_graph) |*graph| {
            if (graph.getPass("particle_compute_pass")) |pass| {
                const ParticleComputePass = @import("../../rendering/passes/particle_compute_pass.zig").ParticleComputePass;
                const compute_pass: *ParticleComputePass = @fieldParentPtr("base", pass);

                const vertex_formats = @import("../../rendering/vertex_formats.zig");

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

                try compute_pass.updateEmitter(gpu_id, gpu_emitter);
                // NOTE: Don't clear dirty flag here - RenderSystem needs to detect transform changes!
                // The dirty flag will be cleared by RenderSystem after rebuilding the cache.
            }
        }
    }
}
