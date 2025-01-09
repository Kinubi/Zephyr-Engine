const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("graphics_context.zig").GraphicsContext;
const Math = @import("mach").math;
const Window = @import("window.zig").Window;

pub const Camera = struct {
    projectionMatrix: Math.Mat4x4 = Math.Mat4x4.ident,
    viewMatrix: Math.Mat4x4 = Math.Mat4x4.ident,

    nearPlane: f32 = 0.1,
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
        const r22: f32 = far / (near - far);
        const r23: f32 = 1;
        const r32: f32 = -(far * near) / (far - near);

        const proj = Math.Mat4x4.init(
            &Math.Vec4.init(r00, 0, 0, 0),
            &Math.Vec4.init(0, r11, 0, 0),
            &Math.Vec4.init(0, 0, r22, r23),
            &Math.Vec4.init(0, 0, r32, 1),
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

        self.viewMatrix = Math.Mat4x4.init(
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
};
