const std = @import("std");
const c = @cImport({
    @cInclude("GLFW/glfw3.h");
});
const vk = @import("vulkan");
const GraphicsContext = @import("../core/graphics_context.zig").GraphicsContext;
const Math = @import("../utils/math.zig");
const Window = @import("../window.zig").Window;

pub const Camera = struct {
    projectionMatrix: Math.Mat4x4 = Math.Mat4x4.identity(),
    viewMatrix: Math.Mat4x4 = Math.Mat4x4.identity(),
    inverseViewMatrix: Math.Mat4x4 = Math.Mat4x4.identity(),

    nearPlane: f32 = 0.1,
    farPlane: f32 = 100.0,
    fov: f32 = 45.0, // degrees, will convert to radians
    aspectRatio: f32 = 16.0 / 9.0,
    window: Window = undefined,

    pub fn setOrthographicProjection(
        self: *Camera,
        left: f32,
        right: f32,
        top: f32,
        bottom: f32,
        near: f32,
        far: f32,
    ) void {
        // glm-style, Vulkan Z [0,1]
        self.projectionMatrix = Math.Mat4x4.identity();
        self.projectionMatrix.get(0, 0).* = 2.0 / (right - left);
        self.projectionMatrix.get(1, 1).* = 2.0 / (bottom - top);
        self.projectionMatrix.get(2, 2).* = 1.0 / (far - near);
        self.projectionMatrix.get(3, 0).* = -(right + left) / (right - left);
        self.projectionMatrix.get(3, 1).* = -(bottom + top) / (bottom - top);
        self.projectionMatrix.get(3, 2).* = -near / (far - near);
    }

    pub fn setPerspectiveProjection(
        self: *Camera,
        fovy: f32, // in radians
        aspect: f32,
        near: f32,
        far: f32,
    ) void {
        // glm-style, Vulkan Z [0,1]
        const tanHalfFovy = @tan(fovy / 2.0);
        self.projectionMatrix = Math.Mat4x4.zero();
        self.projectionMatrix.get(0, 0).* = 1.0 / (aspect * tanHalfFovy);
        self.projectionMatrix.get(1, 1).* = 1.0 / (tanHalfFovy);
        self.projectionMatrix.get(2, 2).* = far / (far - near);
        self.projectionMatrix.get(2, 3).* = 1.0;
        self.projectionMatrix.get(3, 2).* = -(far * near) / (far - near);
    }

    pub fn updateProjectionMatrix(self: *Camera) void {
        var width: c_int = 0;
        var height: c_int = 0;
        c.glfwGetWindowSize(@ptrCast(self.window.window), &width, &height);
        self.aspectRatio = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));
        self.setPerspectiveProjection(
            Math.radians(self.fov),
            self.aspectRatio,
            self.nearPlane,
            self.farPlane,
        );
    }

    pub fn setViewDirection(self: *Camera, position: Math.Vec3, direction: Math.Vec3, up: Math.Vec3) void {
        const w = Math.Vec3.normalize(direction);
        const u = Math.Vec3.normalize(Math.Vec3.cross(w, up));
        const v = Math.Vec3.cross(w, u);

        self.viewMatrix = Math.Mat4x4.identity();
        self.viewMatrix.get(0, 0).* = u.x;
        self.viewMatrix.get(1, 0).* = u.y;
        self.viewMatrix.get(2, 0).* = u.z;
        self.viewMatrix.get(0, 1).* = v.x;
        self.viewMatrix.get(1, 1).* = v.y;
        self.viewMatrix.get(2, 1).* = v.z;
        self.viewMatrix.get(0, 2).* = w.x;
        self.viewMatrix.get(1, 2).* = w.y;
        self.viewMatrix.get(2, 2).* = w.z;
        self.viewMatrix.get(3, 0).* = -Math.Vec3.dot(u, position);
        self.viewMatrix.get(3, 1).* = -Math.Vec3.dot(v, position);
        self.viewMatrix.get(3, 2).* = -Math.Vec3.dot(w, position);

        self.inverseViewMatrix = Math.Mat4x4.identity();
        self.inverseViewMatrix.get(0, 0).* = u.x;
        self.inverseViewMatrix.get(0, 1).* = u.y;
        self.inverseViewMatrix.get(0, 2).* = u.z;
        self.inverseViewMatrix.get(1, 0).* = v.x;
        self.inverseViewMatrix.get(1, 1).* = v.y;
        self.inverseViewMatrix.get(1, 2).* = v.z;
        self.inverseViewMatrix.get(2, 0).* = w.x;
        self.inverseViewMatrix.get(2, 1).* = w.y;
        self.inverseViewMatrix.get(2, 2).* = w.z;
        self.inverseViewMatrix.get(3, 0).* = position.x;
        self.inverseViewMatrix.get(3, 1).* = position.y;
        self.inverseViewMatrix.get(3, 2).* = position.z;
    }

    pub fn setViewTarget(self: *Camera, position: Math.Vec3, target: Math.Vec3, up: Math.Vec3) void {
        self.setViewDirection(position, Math.Vec3.sub(target, position), up);
    }

    pub fn setViewYXZ(self: *Camera, position: Math.Vec3, rotation: Math.Vec3) void {
        const c3 = std.math.cos(rotation.z);
        const s3 = std.math.sin(rotation.z);
        const c2 = std.math.cos(rotation.x);
        const s2 = std.math.sin(rotation.x);
        const c1 = std.math.cos(rotation.y);
        const s1 = std.math.sin(rotation.y);
        const u = Math.Vec3.init(c1 * c3 + s1 * s2 * s3, c2 * s3, c1 * s2 * s3 - c3 * s1);
        const v = Math.Vec3.init(c3 * s1 * s2 - c1 * s3, c2 * c3, c1 * c3 * s2 + s1 * s3);
        const w = Math.Vec3.init(c2 * s1, -s2, c1 * c2);

        self.viewMatrix = Math.Mat4x4.identity();
        self.viewMatrix.get(0, 0).* = u.x;
        self.viewMatrix.get(1, 0).* = u.y;
        self.viewMatrix.get(2, 0).* = u.z;
        self.viewMatrix.get(0, 1).* = v.x;
        self.viewMatrix.get(1, 1).* = v.y;
        self.viewMatrix.get(2, 1).* = v.z;
        self.viewMatrix.get(0, 2).* = w.x;
        self.viewMatrix.get(1, 2).* = w.y;
        self.viewMatrix.get(2, 2).* = w.z;
        self.viewMatrix.get(3, 0).* = -Math.Vec3.dot(u, position);
        self.viewMatrix.get(3, 1).* = -Math.Vec3.dot(v, position);
        self.viewMatrix.get(3, 2).* = -Math.Vec3.dot(w, position);

        self.inverseViewMatrix = Math.Mat4x4.identity();
        self.inverseViewMatrix.get(0, 0).* = u.x;
        self.inverseViewMatrix.get(0, 1).* = u.y;
        self.inverseViewMatrix.get(0, 2).* = u.z;
        self.inverseViewMatrix.get(1, 0).* = v.x;
        self.inverseViewMatrix.get(1, 1).* = v.y;
        self.inverseViewMatrix.get(1, 2).* = v.z;
        self.inverseViewMatrix.get(2, 0).* = w.x;
        self.inverseViewMatrix.get(2, 1).* = w.y;
        self.inverseViewMatrix.get(2, 2).* = w.z;
        self.inverseViewMatrix.get(3, 0).* = position.x;
        self.inverseViewMatrix.get(3, 1).* = position.y;
        self.inverseViewMatrix.get(3, 2).* = position.z;
    }
};
