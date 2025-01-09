const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("graphics_context.zig").GraphicsContext;
const Math = @import("mach").math;
const Window = @import("window.zig").Window;
const Camera = @import("camera.zig").Camera;
const glfw = @import("mach-glfw");
const GameObject = @import("game_object.zig").GameObject;

pub const KeyboardMovementController = struct {
    pub fn init() KeyboardMovementController {
        return KeyboardMovementController{};
    }

    pub fn processInput(self: *KeyboardMovementController, window: *Window, object: *GameObject, dt: f64) void {
        var rotation = Math.Vec3.init(0.0, 0.0, 0.0);
        const lookspeed: f32 = 1;
        _ = self;

        if (window.window.?.getKey(glfw.Key.left) == glfw.Action.press) {
            rotation = rotation.add(&Math.Vec3.init(0.0, 1, 0));
        }
        if (window.window.?.getKey(glfw.Key.right) == glfw.Action.press) {
            rotation = rotation.add(&Math.Vec3.init(0.0, -1, 0));
        }
        if (window.window.?.getKey(glfw.Key.up) == glfw.Action.press) {
            rotation = rotation.add(&Math.Vec3.init(1, 0, 0));
        }
        if (window.window.?.getKey(glfw.Key.down) == glfw.Action.press) {
            rotation = rotation.add(&Math.Vec3.init(-1, 0, 0));
        }
        rotation = Math.Vec3.normalize(&rotation, 0);

        if (Math.Vec3.dot(&rotation, &rotation) > std.math.floatMin(f32)) {
            object.transform.rotate(Math.Quat.fromEuler(lookspeed * @as(f32, @floatCast(dt)) * rotation.x(), lookspeed * @as(f32, @floatCast(dt)) * rotation.y(), lookspeed * @as(f32, @floatCast(dt)) * rotation.z()));
        }

        var direction = Math.Vec3.init(0.0, 0.0, 0.0);
        const movespeed: f32 = 1;
        if (window.window.?.getKey(glfw.Key.w) == glfw.Action.press) {
            direction = direction.add(&Math.Vec3.init(0.0, 0, -1));
        }
        if (window.window.?.getKey(glfw.Key.s) == glfw.Action.press) {
            direction = direction.add(&Math.Vec3.init(0.0, 0, 1));
        }
        if (window.window.?.getKey(glfw.Key.a) == glfw.Action.press) {
            direction = direction.add(&Math.Vec3.init(1, 0, 0));
        }
        if (window.window.?.getKey(glfw.Key.d) == glfw.Action.press) {
            direction = direction.add(&Math.Vec3.init(-1, 0, 0));
        }
        if (window.window.?.getKey(glfw.Key.space) == glfw.Action.press) {
            direction = direction.add(&Math.Vec3.init(0, 1, 0));
        }
        if (window.window.?.getKey(glfw.Key.left_control) == glfw.Action.press) {
            direction = direction.add(&Math.Vec3.init(0, -1, 0));
        }

        if (Math.Vec3.dot(&direction, &direction) > std.math.floatMin(f32)) {
            object.transform.translate(Math.Vec3.normalize(&direction, 0).mulScalar(movespeed * @as(f32, @floatCast(dt))));
        }
    }
};
