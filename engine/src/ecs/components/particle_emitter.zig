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

    /// Serialize ParticleEmitter component
    pub fn jsonSerialize(self: ParticleEmitter, serializer: anytype, writer: anytype) !void {
        _ = serializer;
        try writer.beginObject();
        
        try writer.objectField("emission_rate");
        try writer.write(self.emission_rate);
        
        try writer.objectField("particle_lifetime");
        try writer.write(self.particle_lifetime);
        
        try writer.objectField("velocity_min");
        try writer.write(self.velocity_min);
        
        try writer.objectField("velocity_max");
        try writer.write(self.velocity_max);
        
        try writer.objectField("color");
        try writer.write(self.color);
        
        try writer.objectField("spawn_offset");
        try writer.write(self.spawn_offset);
        
        try writer.objectField("active");
        try writer.write(self.active);
        
        try writer.endObject();
    }

    /// Deserialize ParticleEmitter component
    pub fn deserialize(serializer: anytype, value: std.json.Value) !ParticleEmitter {
        var pe = ParticleEmitter.init();
        
        if (value.object.get("emission_rate")) |val| {
            if (val == .float) pe.emission_rate = @floatCast(val.float);
        }
        
        if (value.object.get("particle_lifetime")) |val| {
            if (val == .float) pe.particle_lifetime = @floatCast(val.float);
        }
        
        if (value.object.get("velocity_min")) |val| {
            const parsed = try std.json.parseFromValue(Math.Vec3, serializer.allocator, val, .{});
            pe.velocity_min = parsed.value;
            parsed.deinit();
        }
        
        if (value.object.get("velocity_max")) |val| {
            const parsed = try std.json.parseFromValue(Math.Vec3, serializer.allocator, val, .{});
            pe.velocity_max = parsed.value;
            parsed.deinit();
        }
        
        if (value.object.get("color")) |val| {
            const parsed = try std.json.parseFromValue(Math.Vec3, serializer.allocator, val, .{});
            pe.color = parsed.value;
            parsed.deinit();
        }
        
        if (value.object.get("spawn_offset")) |val| {
            const parsed = try std.json.parseFromValue(Math.Vec3, serializer.allocator, val, .{});
            pe.spawn_offset = parsed.value;
            parsed.deinit();
        }
        
        if (value.object.get("active")) |val| {
            if (val == .bool) pe.active = val.bool;
        }
        
        return pe;
    }
};
