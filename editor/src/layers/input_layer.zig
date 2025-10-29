const std = @import("std");
const zulkan = @import("zulkan");

const Layer = zulkan.Layer;
const Event = zulkan.Event;
const EventType = zulkan.EventType;
const FrameInfo = zulkan.FrameInfo;
const Window = zulkan.Window;
const Camera = zulkan.Camera;
const KeyboardMovementController = @import("../keyboard_movement_controller.zig").KeyboardMovementController;
const SceneV2 = zulkan.Scene;
const log = zulkan.log;
const c = @cImport({
    @cInclude("GLFW/glfw3.h");
});

/// Input handling layer
/// Processes keyboard and mouse input, updates camera controller
pub const InputLayer = struct {
    base: Layer,
    window: *Window,
    camera: *Camera,
    camera_controller: *KeyboardMovementController,
    scene: *SceneV2,
    last_toggle_time: f64 = 0.0,

    const TOGGLE_COOLDOWN: f64 = 0.3; // 300ms cooldown

    pub fn init(
        window: *Window,
        camera: *Camera,
        camera_controller: *KeyboardMovementController,
        scene: *SceneV2,
    ) InputLayer {
        return .{
            .base = .{
                .name = "InputLayer",
                .enabled = true,
                .vtable = &vtable,
            },
            .window = window,
            .camera = camera,
            .camera_controller = camera_controller,
            .scene = scene,
        };
    }

    const vtable = Layer.VTable{
        .attach = attach,
        .detach = detach,
        .prepare = null, // InputLayer has no main thread preparation work
        .begin = begin,
        .update = update,
        .render = render,
        .end = end,
        .event = event,
    };

    fn attach(base: *Layer) !void {
        const self: *InputLayer = @fieldParentPtr("base", base);
        _ = self;
    }

    fn detach(base: *Layer) void {
        const self: *InputLayer = @fieldParentPtr("base", base);
        _ = self;
    }

    fn begin(base: *Layer, frame_info: *const FrameInfo) !void {
        _ = base;
        _ = frame_info;
    }

    fn update(base: *Layer, frame_info: *const FrameInfo) !void {
        const self: *InputLayer = @fieldParentPtr("base", base);

        // Process camera movement using dt from frame_info
        self.camera_controller.processInput(self.window, self.camera, frame_info.dt);

        // Toggle path tracing with 'T' key (with debouncing)
        const GLFW_KEY_T = 84;
        const t_key_state = c.glfwGetKey(@ptrCast(self.window.window.?), GLFW_KEY_T);
        const toggle_time = c.glfwGetTime();

        if (t_key_state == c.GLFW_PRESS and (toggle_time - self.last_toggle_time) > TOGGLE_COOLDOWN) {
            if (self.scene.render_graph != null) {
                // Check current path tracing state via the render graph
                const pt_enabled = if (self.scene.render_graph.?.getPass("path_tracing_pass")) |pass| pass.enabled else false;
                try self.scene.setPathTracingEnabled(!pt_enabled);
                self.last_toggle_time = toggle_time;
                log(.INFO, "InputLayer", "Path tracing toggled: {}", .{!pt_enabled});
            }
        }
    }

    fn render(base: *Layer, frame_info: *const FrameInfo) !void {
        _ = base;
        _ = frame_info;
        // No rendering for input layer
    }

    fn end(base: *Layer, frame_info: *FrameInfo) !void {
        _ = base;
        _ = frame_info;
    }

    fn event(base: *Layer, evt: *Event) void {
        const self: *InputLayer = @fieldParentPtr("base", base);

        switch (evt.event_type) {
            .KeyPressed => {
                const key_data = evt.data.KeyPressed;
                const GLFW_KEY_T = 84;

                // Toggle path tracing with 'T' key (with debouncing)
                if (key_data.key == GLFW_KEY_T) {
                    const toggle_time = c.glfwGetTime();
                    if ((toggle_time - self.last_toggle_time) > TOGGLE_COOLDOWN) {
                        if (self.scene.render_graph != null) {
                            const pt_enabled = if (self.scene.render_graph.?.getPass("path_tracing_pass")) |pass| pass.enabled else false;
                            self.scene.setPathTracingEnabled(!pt_enabled) catch {};
                            self.last_toggle_time = toggle_time;
                            evt.markHandled();
                        }
                    }
                }

                // F1 to toggle UI (will be handled by UILayer)
                // F2 to toggle performance graphs (will be handled by UILayer)
                // These are just examples - layers can handle their own toggle keys
            },
            .MouseMoved => {
                // Mouse movement is handled by camera controller in update()
            },
            .WindowResize => {
                // Window resize handling
                log(.INFO, "InputLayer", "Window resized to {}x{}", .{ evt.data.WindowResize.width, evt.data.WindowResize.height });
            },
            else => {},
        }
    }
};
