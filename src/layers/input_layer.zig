const std = @import("std");
const Layer = @import("../core/layer.zig").Layer;
const Event = @import("../core/event.zig").Event;
const EventType = @import("../core/event.zig").EventType;
const FrameInfo = @import("../rendering/frameinfo.zig").FrameInfo;
const Window = @import("../window.zig").Window;
const Camera = @import("../rendering/camera.zig").Camera;
const KeyboardMovementController = @import("../keyboard_movement_controller.zig").KeyboardMovementController;
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
    last_toggle_time: f64 = 0.0,

    pub fn init(window: *Window, camera: *Camera, camera_controller: *KeyboardMovementController) InputLayer {
        return .{
            .base = .{
                .name = "InputLayer",
                .enabled = true,
                .vtable = &vtable,
            },
            .window = window,
            .camera = camera,
            .camera_controller = camera_controller,
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
    }

    fn render(base: *Layer, frame_info: *const FrameInfo) !void {
        _ = base;
        _ = frame_info;
        // No rendering for input layer
    }

    fn end(base: *Layer, frame_info: *const FrameInfo) !void {
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
