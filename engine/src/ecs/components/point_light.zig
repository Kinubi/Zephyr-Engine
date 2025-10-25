const std = @import("std");
const Math = @import("../../utils/math.zig");

/// Point light component for ECS entities
/// Represents a light source that emits light in all directions from a point
pub const PointLight = struct {
    /// Light color (RGB)
    color: Math.Vec3 = Math.Vec3.init(1.0, 1.0, 1.0),

    /// Light intensity/brightness
    intensity: f32 = 1.0,

    /// Maximum range of the light (for culling and attenuation)
    range: f32 = 10.0,

    /// Attenuation constant term (usually 1.0)
    constant: f32 = 1.0,

    /// Attenuation linear term
    linear: f32 = 0.09,

    /// Attenuation quadratic term
    quadratic: f32 = 0.032,

    /// Whether this light casts shadows
    cast_shadows: bool = false,

    /// Calculate attenuation factor based on distance
    pub fn getAttenuation(self: PointLight, distance: f32) f32 {
        if (distance > self.range) return 0.0;
        return 1.0 / (self.constant + self.linear * distance + self.quadratic * distance * distance);
    }

    /// Create a default point light
    pub fn init() PointLight {
        return .{};
    }

    /// Create a point light with custom color and intensity
    pub fn initWithColor(color: Math.Vec3, intensity: f32) PointLight {
        return .{
            .color = color,
            .intensity = intensity,
        };
    }

    /// Create a point light with custom color, intensity, and range
    pub fn initWithRange(color: Math.Vec3, intensity: f32, range: f32) PointLight {
        return .{
            .color = color,
            .intensity = intensity,
            .range = range,
        };
    }
};
