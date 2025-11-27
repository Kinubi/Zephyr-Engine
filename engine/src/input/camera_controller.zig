const std = @import("std");
const Math = @import("../utils/math.zig");
const Camera = @import("../rendering/camera.zig").Camera;
const Event = @import("../core/event.zig").Event;
const EventType = @import("../core/event.zig").EventType;
const c = @cImport({
    @cInclude("GLFW/glfw3.h");
});

/// CameraController - event-driven editor-style fly camera
/// - Consumes input events it uses (RMB look, scroll, movement keys)
/// - Applies smooth, dt-scaled motion in update()
pub const CameraController = struct {
    // Pose (instance fields)
    position: Math.Vec3 = Math.Vec3.init(0, 0, 3),
    rotation: Math.Vec3 = Math.Vec3.init(0, 0, 0), // pitch (x), yaw (y), roll (z)

    // Tuning (instance fields)
    move_speed: f32 = 3.0,
    mouse_sensitivity: f32 = 0.003, // Radians per pixel of mouse movement
    fov: f32 = 75.0,

    // State
    look_active: bool = false,
    last_mouse_valid: bool = false,
    last_mouse_x: f64 = 0.0,
    last_mouse_y: f64 = 0.0,
    
    // Smoothing for mouse look (accumulated delta applied in update)
    pending_yaw: f32 = 0.0,
    pending_pitch: f32 = 0.0,

    keys: struct {
        w: bool = false,
        a: bool = false,
        s: bool = false,
        d: bool = false,
        up: bool = false, // Space
        down: bool = false, // Ctrl
        fast: bool = false, // Shift
    } = .{},

    pub fn init() CameraController {
        return .{};
    }

    /// Handle a single input event. Returns true if consumed.
    pub fn event(self: *CameraController, evt: *Event) bool {
        switch (evt.event_type) {
            .KeyPressed => {
                const k = evt.data.KeyPressed.key;
                switch (k) {
                    c.GLFW_KEY_W => self.keys.w = true,
                    c.GLFW_KEY_A => self.keys.a = true,
                    c.GLFW_KEY_S => self.keys.s = true,
                    c.GLFW_KEY_D => self.keys.d = true,
                    c.GLFW_KEY_LEFT_CONTROL, c.GLFW_KEY_RIGHT_CONTROL => self.keys.up = true,
                    c.GLFW_KEY_SPACE => self.keys.down = true,
                    c.GLFW_KEY_LEFT_SHIFT, c.GLFW_KEY_RIGHT_SHIFT => self.keys.fast = true,
                    else => return false,
                }
                return true;
            },
            .KeyReleased => {
                const k = evt.data.KeyReleased.key;
                switch (k) {
                    c.GLFW_KEY_W => self.keys.w = false,
                    c.GLFW_KEY_A => self.keys.a = false,
                    c.GLFW_KEY_S => self.keys.s = false,
                    c.GLFW_KEY_D => self.keys.d = false,
                    c.GLFW_KEY_LEFT_CONTROL, c.GLFW_KEY_RIGHT_CONTROL => self.keys.up = false,
                    c.GLFW_KEY_SPACE => self.keys.down = false,
                    c.GLFW_KEY_LEFT_SHIFT, c.GLFW_KEY_RIGHT_SHIFT => self.keys.fast = false,
                    else => return false,
                }
                return true;
            },
            .MouseButtonPressed => {
                if (evt.data.MouseButtonPressed.button == c.GLFW_MOUSE_BUTTON_RIGHT) {
                    self.look_active = true;
                    self.last_mouse_valid = false; // reset delta on next move
                    return true;
                }
                return false;
            },
            .MouseButtonReleased => {
                if (evt.data.MouseButtonReleased.button == c.GLFW_MOUSE_BUTTON_RIGHT) {
                    self.look_active = false;
                    self.last_mouse_valid = false;
                    return true;
                }
                return false;
            },
            .MouseMoved => {
                if (!self.look_active) return false;
                const x = evt.data.MouseMoved.x;
                const y = evt.data.MouseMoved.y;
                if (self.last_mouse_valid) {
                    const dx = x - self.last_mouse_x;
                    const dy = y - self.last_mouse_y;
                    // Accumulate rotation delta - applied smoothly in update()
                    self.pending_yaw += @as(f32, @floatCast(dx)) * self.mouse_sensitivity;
                    self.pending_pitch -= @as(f32, @floatCast(dy)) * self.mouse_sensitivity;
                }
                self.last_mouse_x = x;
                self.last_mouse_y = y;
                self.last_mouse_valid = true;
                return true;
            },
            .MouseScrolled => {
                const scroll = evt.data.MouseScrolled.y_offset;
                self.fov = std.math.clamp(self.fov - @as(f32, @floatCast(scroll)) * 2.0, 20.0, 90.0);
                return true;
            },
            else => return false,
        }
    }

    /// Apply continuous motion and update the camera view/projection
    pub fn update(self: *CameraController, camera: *Camera, dt: f32) void {
        // Apply pending mouse rotation with smoothing
        // Use exponential smoothing for responsive but smooth camera movement
        const smooth_factor: f32 = 15.0; // Higher = snappier, lower = smoother
        const blend = 1.0 - @exp(-smooth_factor * dt);
        
        if (@abs(self.pending_yaw) > 0.0001 or @abs(self.pending_pitch) > 0.0001) {
            self.rotation.y += self.pending_yaw * blend;
            self.rotation.x += self.pending_pitch * blend;
            
            // Decay pending rotation
            self.pending_yaw *= (1.0 - blend);
            self.pending_pitch *= (1.0 - blend);
            
            // Clamp pitch to prevent gimbal lock
            self.rotation.x = std.math.clamp(self.rotation.x, -1.5, 1.5);
        }
        
        // Movement
        var dir = Math.Vec3.init(0, 0, 0);
        if (self.keys.w) dir.z -= 1;
        if (self.keys.s) dir.z += 1;
        if (self.keys.a) dir.x -= 1;
        if (self.keys.d) dir.x += 1;
        if (self.keys.up) dir.y += 1;
        if (self.keys.down) dir.y -= 1;

        if (Math.Vec3.dot(dir, dir) > 0.0) {
            dir = Math.Vec3.normalize(dir);

            const yaw = self.rotation.y;
            const forward = Math.Vec3.init(-std.math.sin(yaw), 0, -std.math.cos(yaw));
            const right = Math.Vec3.init(std.math.cos(yaw), 0, -std.math.sin(yaw));
            const up = Math.Vec3.init(0, 1, 0);

            var v = Math.Vec3.init(0, 0, 0);
            v = Math.Vec3.add(v, Math.Vec3.scale(forward, dir.z));
            v = Math.Vec3.add(v, Math.Vec3.scale(right, dir.x));
            v = Math.Vec3.add(v, Math.Vec3.scale(up, dir.y));

            var speed = self.move_speed;
            if (self.keys.fast) speed *= 4.0;

            self.position = Math.Vec3.add(self.position, Math.Vec3.scale(v, speed * dt));
        }

        // Apply FOV with existing aspect ratio set by UI/resize logic
        camera.fov = self.fov;
        camera.setPerspectiveProjection(Math.radians(camera.fov), camera.aspectRatio, camera.nearPlane, camera.farPlane);

        // Update view matrix
        camera.setViewYXZ(self.position, self.rotation);
    }

    /// Get the current view matrix from controller state without modifying any camera
    /// Use this when you need the editor camera's view separately
    /// Compute camera basis vectors (u, v, w) from rotation using YXZ Euler angles.
    /// This matches the calculation in Camera.setViewYXZ exactly.
    /// u = right vector, v = up vector, w = forward vector
    fn computeBasisVectors(self: *const CameraController) struct { u: Math.Vec3, v: Math.Vec3, w: Math.Vec3 } {
        const c3 = std.math.cos(self.rotation.z); // roll
        const s3 = std.math.sin(self.rotation.z);
        const c2 = std.math.cos(self.rotation.x); // pitch
        const s2 = std.math.sin(self.rotation.x);
        const c1 = std.math.cos(self.rotation.y); // yaw
        const s1 = std.math.sin(self.rotation.y);

        return .{
            .u = Math.Vec3.init(c1 * c3 + s1 * s2 * s3, c2 * s3, c1 * s2 * s3 - c3 * s1),
            .v = Math.Vec3.init(c3 * s1 * s2 - c1 * s3, c2 * c3, c1 * c3 * s2 + s1 * s3),
            .w = Math.Vec3.init(c2 * s1, -s2, c1 * c2),
        };
    }

    /// Get the current view matrix from controller state.
    /// Uses the same YXZ Euler angle calculation as Camera.setViewYXZ.
    pub fn getViewMatrix(self: *const CameraController) Math.Mat4x4 {
        const basis = self.computeBasisVectors();

        var view = Math.Mat4x4.identity();
        view.data[0] = basis.u.x;
        view.data[1] = basis.v.x;
        view.data[2] = basis.w.x;
        view.data[4] = basis.u.y;
        view.data[5] = basis.v.y;
        view.data[6] = basis.w.y;
        view.data[8] = basis.u.z;
        view.data[9] = basis.v.z;
        view.data[10] = basis.w.z;
        view.data[12] = -Math.Vec3.dot(basis.u, self.position);
        view.data[13] = -Math.Vec3.dot(basis.v, self.position);
        view.data[14] = -Math.Vec3.dot(basis.w, self.position);

        return view;
    }

    /// Get the current inverse view matrix (world transform) from controller state.
    /// Uses the same YXZ Euler angle calculation as Camera.setViewYXZ.
    pub fn getInverseViewMatrix(self: *const CameraController) Math.Mat4x4 {
        const basis = self.computeBasisVectors();

        var inv_view = Math.Mat4x4.identity();
        inv_view.data[0] = basis.u.x;
        inv_view.data[1] = basis.u.y;
        inv_view.data[2] = basis.u.z;
        inv_view.data[4] = basis.v.x;
        inv_view.data[5] = basis.v.y;
        inv_view.data[6] = basis.v.z;
        inv_view.data[8] = basis.w.x;
        inv_view.data[9] = basis.w.y;
        inv_view.data[10] = basis.w.z;
        inv_view.data[12] = self.position.x;
        inv_view.data[13] = self.position.y;
        inv_view.data[14] = self.position.z;

        return inv_view;
    }

    /// Get the current position
    pub fn getPosition(self: *const CameraController) Math.Vec3 {
        return self.position;
    }
};
