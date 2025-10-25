const std = @import("std");
const Math = @import("../../utils/math.zig");

/// ParticleEmitter spawns particles at a specific location
pub const ParticleEmitter = struct {
    /// Emission rate (particles per second)
    emission_rate: f32 = 10.0,

    /// Particle lifetime in seconds
    particle_lifetime: f32 = 2.0,

    /// Initial velocity range
    velocity_min: Math.Vec3 = Math.Vec3.init(-0.5, 0.5, -0.5),
    velocity_max: Math.Vec3 = Math.Vec3.init(0.5, 1.5, 0.5),

    /// Particle color
    color: Math.Vec3 = Math.Vec3.init(1.0, 0.8, 0.2),

    /// Emission offset from transform position
    spawn_offset: Math.Vec3 = Math.Vec3.init(0, 0, 0),

    /// Internal state
    time_since_last_emit: f32 = 0.0,
    active: bool = true,

    pub fn init() ParticleEmitter {
        return .{};
    }

    pub fn initWithRate(rate: f32) ParticleEmitter {
        return .{
            .emission_rate = rate,
        };
    }

    pub fn setColor(self: *ParticleEmitter, color: Math.Vec3) void {
        self.color = color;
    }

    pub fn setVelocityRange(self: *ParticleEmitter, min: Math.Vec3, max: Math.Vec3) void {
        self.velocity_min = min;
        self.velocity_max = max;
    }
};
