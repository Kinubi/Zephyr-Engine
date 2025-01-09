const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("graphics_context.zig").GraphicsContext;
const Math = @import("mach").math;
const Window = @import("window.zig").Window;

pub const Camera = struct {
    projectionMatrix: Math.Mat4x4 = Math.Mat4x4.ident,
    viewMatrix: Math.Mat4x4 = Math.Mat4x4.ident,

    nearPlane: f32 = -1 + 0.1,
    farPlane: f32 = 1,
    fov: f32 = 5,
    aspectRatio: f32 = 16.0 / 9.0,
    window: Window = undefined,

    fn perspectiveLH_ZO(
        // More doc string
        /// The field of view angle in the y direction, in radians.
        fovy: f32,
        /// The aspect ratio of the viewport's width to its height.
        aspect: f32,
        /// The depth (z coordinate) of the near clipping plane.
        near: f32,
        /// The depth (z coordinate) of the far clipping plane.
        far: f32,
    ) Math.Mat4x4 {
        const tanHalfFovy: f32 = @tan(fovy / 2.0);

        const r00: f32 = 1.0 / (aspect * tanHalfFovy);
        const r11: f32 = 1.0 / (tanHalfFovy);
        const r22: f32 = far / (far - near);
        const r23: f32 = 1;
        const r32: f32 = -(far * near) / (far - near);

        const proj = Math.Mat4x4.init(
            &Math.Vec4.init(r00, 0, 0, 0),
            &Math.Vec4.init(0, r11, 0, 0),
            &Math.Vec4.init(0, 0, r22, r32),
            &Math.Vec4.init(0, 0, r23, 1),
        );

        return proj;
    }

    pub inline fn setOrthographicProjection(
        self: *@This(),
        left: f32,
        right: f32,
        bottom: f32,
        top: f32,
        near: f32,
        far: f32,
    ) void {
        const r00: f32 = 2.0 / (right - left);
        const r11: f32 = 2.0 / (top - bottom);
        const r22: f32 = -2.0 / (far - near);
        const r30: f32 = -(right + left) / (right - left);
        const r31: f32 = -(top + bottom) / (bottom - top);
        const r32: f32 = -(near) / (far - near);

        self.projectionMatrix = Math.Mat4x4.init(
            &Math.Vec4.init(r00, 0, 0, r30),
            &Math.Vec4.init(0, r11, 0, r31),
            &Math.Vec4.init(0, 0, r22, r32),
            &Math.Vec4.init(0, 0, 0, 1),
        );
    }

    pub fn updateProjectionMatrix(self: *Camera) void {
        const size = self.window.window.?.getSize();
        self.aspectRatio = @as(f32, @floatFromInt(size.width)) / @as(f32, @floatFromInt(size.height));

        self.projectionMatrix = perspectiveLH_ZO(
            Math.degreesToRadians(self.fov),
            self.aspectRatio,
            self.nearPlane,
            self.farPlane,
        );
    }

    pub fn setViewDirection(self: *Camera, position: Math.Vec3, direction: *Math.Vec3, up: Math.Vec3) void {
        direction.v[0] = -direction.x();
        const w = Math.Vec3.normalize(&direction.*, 0);
        const u = Math.Vec3.normalize(&Math.Vec3.cross(&up, &w), 0);
        const v = Math.Vec3.cross(&w, &u);

        const r00: f32 = u.x();
        const r10: f32 = u.y();
        const r20: f32 = u.z();
        const r30: f32 = -Math.Vec3.dot(&u, &position);
        const r01: f32 = v.x();
        const r11: f32 = v.y();
        const r21: f32 = v.z();
        const r31: f32 = -Math.Vec3.dot(&v, &position);

        const r02: f32 = w.x();
        const r12: f32 = w.y();
        const r22: f32 = w.z();
        const r32: f32 = -Math.Vec3.dot(&w, &position);

        self.viewMatrix = Math.Mat4x4.init(
            &Math.Vec4.init(r00, r01, r02, 0),
            &Math.Vec4.init(r10, r11, r12, 0),
            &Math.Vec4.init(r20, r21, r22, 0),
            &Math.Vec4.init(r30, r31, r32, 1),
        );
    }

    pub fn setViewTarget(self: *Camera, position: Math.Vec3, target: Math.Vec3, up: Math.Vec3.init(0, -1, 0)) void {
        const direction = Math.Vec3.sub(target, position);
        self.setViewDirection(position, direction, up);
    }

    pub fn setViewYXZ(self: *Camera, position: Math.Vec3, rotation: Math.Vec3) void {
        const cosX = Math.cos(rotation.x());
        const sinX = Math.sin(rotation.x());
        const cosY = Math.cos(rotation.y());
        const sinY = Math.sin(rotation.y());
        const cosZ = Math.cos(rotation.z());
        const sinZ = Math.sin(rotation.z());

        const rotX = Math.Mat4x4.init(
            &Math.Vec4.init(1, 0, 0, 0),
            &Math.Vec4.init(0, cosX, -sinX, 0),
            &Math.Vec4.init(0, sinX, cosX, 0),
            &Math.Vec4.init(0, 0, 0, 1),
        );

        const rotY = Math.Mat4x4.init(
            &Math.Vec4.init(cosY, 0, sinY, 0),
            &Math.Vec4.init(0, 1, 0, 0),
            &Math.Vec4.init(-sinY, 0, cosY, 0),
            &Math.Vec4.init(0, 0, 0, 1),
        );

        const rotZ = Math.Mat4x4.init(
            &Math.Vec4.init(cosZ, -sinZ, 0, 0),
            &Math.Vec4.init(sinZ, cosZ, 0, 0),
            &Math.Vec4.init(0, 0, 1, 0),
            &Math.Vec4.init(0, 0, 0, 1),
        );

        const rotationMatrix = Math.Mat4x4.mul(&rotZ, &Math.Mat4x4.mul(&rotY, &rotX));

        const translationMatrix = Math.Mat4x4.init(
            &Math.Vec4.init(1, 0, 0, -position.x()),
            &Math.Vec4.init(0, 1, 0, -position.y()),
            &Math.Vec4.init(0, 0, 1, -position.z()),
            &Math.Vec4.init(0, 0, 0, 1),
        );

        self.viewMatrix = Math.Mat4x4.mul(&rotationMatrix, &translationMatrix);
    }
};
