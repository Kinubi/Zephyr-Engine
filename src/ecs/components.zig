const Math = @import("../utils/math.zig");

pub const Transform = struct {
    translation: Math.Vec3 = Math.Vec3.zero(),
    rotation: Math.Vec3 = Math.Vec3.zero(),
    scale: Math.Vec3 = Math.Vec3.init(1.0, 1.0, 1.0),
    local_to_world: Math.Mat4 = Math.Mat4.identity(),

    pub fn init(translation: Math.Vec3, rotation: Math.Vec3, scale: Math.Vec3) Transform {
        var transform = Transform{
            .translation = translation,
            .rotation = rotation,
            .scale = scale,
            .local_to_world = Math.Mat4.identity(),
        };
        updateLocalToWorld(&transform);
        return transform;
    }
};

pub const Velocity = struct {
    linear: Math.Vec3 = Math.Vec3.zero(),
    angular: Math.Vec3 = Math.Vec3.zero(),
};

pub fn updateLocalToWorld(transform: *Transform) void {
    // Compose scale and translation only for now; rotation hooks come later.
    const scale_matrix = Math.Mat4.scale(transform.scale);
    const translation_matrix = Math.Mat4.translation(transform.translation);
    transform.local_to_world = translation_matrix.mul(scale_matrix);
}
