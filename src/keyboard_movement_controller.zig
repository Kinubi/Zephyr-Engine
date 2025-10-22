const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("core/graphics_context.zig").GraphicsContext;
const Math = @import("utils/math.zig");
const Window = @import("window.zig").Window;
const Camera = @import("rendering/camera.zig").Camera;
const glfw = @import("mach-glfw");

const c = @cImport({
    @cInclude("GLFW/glfw3.h");
});

/// Keyboard movement controller for direct camera manipulation
/// Updates camera position and orientation based on keyboard input
pub const KeyboardMovementController = struct {
    move_speed: f32 = 3.0,
    look_speed: f32 = 1.5,
    
    // Track camera state
    position: Math.Vec3 = Math.Vec3.init(0, 0, 0),
    rotation: Math.Vec3 = Math.Vec3.init(0, 0, 0), // pitch, yaw, roll

    pub fn init() KeyboardMovementController {
        return KeyboardMovementController{
            .position = Math.Vec3.init(0, 0, 3), // Start slightly back from origin
            .rotation = Math.Vec3.init(0, 0, 0),
        };
    }

    /// Process keyboard input and update camera
    pub fn processInput(self: *KeyboardMovementController, window: *Window, camera: *Camera, dt: f64) void {
        const dt_f32 = @as(f32, @floatCast(dt));
        
        // Handle rotation (arrow keys)
        var rotation_delta = Math.Vec3.init(0.0, 0.0, 0.0);
        
        if (c.glfwGetKey(@ptrCast(window.window), c.GLFW_KEY_LEFT) == c.GLFW_PRESS) {
            rotation_delta.y += 1.0; // Yaw left
        }
        if (c.glfwGetKey(@ptrCast(window.window), c.GLFW_KEY_RIGHT) == c.GLFW_PRESS) {
            rotation_delta.y -= 1.0; // Yaw right
        }
        if (c.glfwGetKey(@ptrCast(window.window), c.GLFW_KEY_UP) == c.GLFW_PRESS) {
            rotation_delta.x -= 1.0; // Pitch up
        }
        if (c.glfwGetKey(@ptrCast(window.window), c.GLFW_KEY_DOWN) == c.GLFW_PRESS) {
            rotation_delta.x += 1.0; // Pitch down
        }

        // Apply rotation if any input detected
        if (Math.Vec3.dot(rotation_delta, rotation_delta) > std.math.floatMin(f32)) {
            rotation_delta = Math.Vec3.normalize(rotation_delta);
            self.rotation = Math.Vec3.add(self.rotation, Math.Vec3.scale(rotation_delta, self.look_speed * dt_f32));
            
            // Clamp pitch to prevent gimbal lock
            self.rotation.x = std.math.clamp(self.rotation.x, -1.5, 1.5);
        }

        // Handle movement (WASD + Space/Ctrl)
        var direction = Math.Vec3.init(0.0, 0.0, 0.0);
        
        if (c.glfwGetKey(@ptrCast(window.window), c.GLFW_KEY_W) == c.GLFW_PRESS) {
            direction.z -= 1.0; // Forward
        }
        if (c.glfwGetKey(@ptrCast(window.window), c.GLFW_KEY_S) == c.GLFW_PRESS) {
            direction.z += 1.0; // Backward
        }
        if (c.glfwGetKey(@ptrCast(window.window), c.GLFW_KEY_A) == c.GLFW_PRESS) {
            direction.x -= 1.0; // Left
        }
        if (c.glfwGetKey(@ptrCast(window.window), c.GLFW_KEY_D) == c.GLFW_PRESS) {
            direction.x += 1.0; // Right
        }
        if (c.glfwGetKey(@ptrCast(window.window), c.GLFW_KEY_SPACE) == c.GLFW_PRESS) {
            direction.y -= 1.0; // Down
        }
        if (c.glfwGetKey(@ptrCast(window.window), c.GLFW_KEY_LEFT_CONTROL) == c.GLFW_PRESS) {
            direction.y += 1.0; // Up
        }

        // Apply movement if any input detected
        if (Math.Vec3.dot(direction, direction) > std.math.floatMin(f32)) {
            direction = Math.Vec3.normalize(direction);
            
            // Calculate forward/right vectors from rotation
            const yaw = self.rotation.y;
            const forward = Math.Vec3.init(-std.math.sin(yaw), 0, -std.math.cos(yaw));
            const right = Math.Vec3.init(std.math.cos(yaw), 0, -std.math.sin(yaw));
            const up = Math.Vec3.init(0, 1, 0);
            
            var movement = Math.Vec3.init(0, 0, 0);
            movement = Math.Vec3.add(movement, Math.Vec3.scale(forward, direction.z));
            movement = Math.Vec3.add(movement, Math.Vec3.scale(right, direction.x));
            movement = Math.Vec3.add(movement, Math.Vec3.scale(up, direction.y));
            
            movement = Math.Vec3.scale(movement, self.move_speed * dt_f32);
            self.position = Math.Vec3.add(self.position, movement);
        }
        
        // Update camera view matrix using YXZ rotation (yaw, pitch, roll)
        camera.setViewYXZ(self.position, self.rotation);
    }
};
