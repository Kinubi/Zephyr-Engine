const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("core/graphics_context.zig").GraphicsContext;
const Math = @import("utils/math.zig");
const Window = @import("window.zig").Window;
const Camera = @import("rendering/camera.zig").Camera;
const glfw = @import("mach-glfw");
const GameObject = @import("scene/game_object.zig").GameObject;

const c = @cImport({
    @cInclude("GLFW/glfw3.h");
});

pub const KeyboardMovementController = struct {
    pub fn init() KeyboardMovementController {
        return KeyboardMovementController{};
    }

    pub fn processInput(self: *KeyboardMovementController, window: *Window, object: *GameObject, dt: f64) void {
        var rotation = Math.Vec3.init(0.0, 0.0, 0.0);
        const lookspeed: f32 = 1;
        _ = self;

        if (c.glfwGetKey(@ptrCast(window.window), c.GLFW_KEY_LEFT) == c.GLFW_PRESS) {
            rotation = rotation.add(Math.Vec3.init(0.0, 1, 0));
        }
        if (c.glfwGetKey(@ptrCast(window.window), c.GLFW_KEY_RIGHT) == c.GLFW_PRESS) {
            rotation = rotation.add(Math.Vec3.init(0.0, -1, 0));
        }
        if (c.glfwGetKey(@ptrCast(window.window), c.GLFW_KEY_UP) == c.GLFW_PRESS) {
            rotation = rotation.add(Math.Vec3.init(1, 0, 0));
        }
        if (c.glfwGetKey(@ptrCast(window.window), c.GLFW_KEY_DOWN) == c.GLFW_PRESS) {
            rotation = rotation.add(Math.Vec3.init(-1, 0, 0));
        }
        rotation = Math.Vec3.normalize(rotation);

        if (Math.Vec3.dot(rotation, rotation) > std.math.floatMin(f32)) {
            object.transform.rotate(Math.Quat.fromEuler(lookspeed * @as(f32, @floatCast(dt)) * rotation.x, lookspeed * @as(f32, @floatCast(dt)) * rotation.y, lookspeed * @as(f32, @floatCast(dt)) * rotation.z));
        }

        var direction = Math.Vec3.init(0.0, 0.0, 0.0);
        const movespeed: f32 = 1;
        if (c.glfwGetKey(@ptrCast(window.window), c.GLFW_KEY_W) == c.GLFW_PRESS) {
            direction = direction.add(Math.Vec3.init(0.0, 0, -1));
        }
        if (c.glfwGetKey(@ptrCast(window.window), c.GLFW_KEY_S) == c.GLFW_PRESS) {
            direction = direction.add(Math.Vec3.init(0.0, 0, 1));
        }
        if (c.glfwGetKey(@ptrCast(window.window), c.GLFW_KEY_A) == c.GLFW_PRESS) {
            direction = direction.add(Math.Vec3.init(1, 0, 0));
        }
        if (c.glfwGetKey(@ptrCast(window.window), c.GLFW_KEY_D) == c.GLFW_PRESS) {
            direction = direction.add(Math.Vec3.init(-1, 0, 0));
        }
        if (c.glfwGetKey(@ptrCast(window.window), c.GLFW_KEY_SPACE) == c.GLFW_PRESS) {
            direction = direction.add(Math.Vec3.init(0, 1, 0));
        }
        if (c.glfwGetKey(@ptrCast(window.window), c.GLFW_KEY_LEFT_CONTROL) == c.GLFW_PRESS) {
            direction = direction.add(Math.Vec3.init(0, -1, 0));
        }
        if (Math.Vec3.dot(direction, direction) > std.math.floatMin(f32)) {
            object.transform.translate(Math.Vec3.normalize(direction).scale(movespeed * @as(f32, @floatCast(dt))));
        }
    }
};
