const std = @import("std");
const Layer = @import("../core/layer.zig").Layer;
const Event = @import("../core/event.zig").Event;
const EventType = @import("../core/event.zig").EventType;
const FrameInfo = @import("../rendering/frameinfo.zig").FrameInfo;
const Window = @import("../window.zig").Window;
const Camera = @import("../rendering/camera.zig").Camera;
const KeyboardMovementController = @import("../keyboard_movement_controller.zig").KeyboardMovementController;
const SceneV2 = @import("../scene/scene_v2.zig").Scene;
const log = @import("../utils/log.zig").log;
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
        _ = self;

        switch (evt.event_type) {
            .KeyPressed => {
                // Handle key press events
                // For now, let specific handlers deal with keys
            },
            .MouseMoved => {
                // Handle mouse movement
            },
            else => {},
        }
    }
};
