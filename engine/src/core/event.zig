const std = @import("std");

/// Event types for inter-layer communication
pub const EventType = enum {
    // Window events
    WindowResize,
    WindowClose,

    // Input events
    KeyPressed,
    KeyReleased,
    KeyTyped,
    MouseButtonPressed,
    MouseButtonReleased,
    MouseMoved,
    MouseScrolled,

    // Application events
    PathTracingToggled,
    WireframeToggled,
    CameraUpdated,
    SceneLoaded,

    // Custom events can be added here
};

/// Event data union for different event types
pub const EventData = union(EventType) {
    WindowResize: struct {
        width: u32,
        height: u32,
    },
    WindowClose: void,

    KeyPressed: struct {
        key: i32,
        scancode: i32,
        mods: i32,
    },
    KeyReleased: struct {
        key: i32,
        scancode: i32,
        mods: i32,
    },
    KeyTyped: struct {
        codepoint: u32,
    },

    MouseButtonPressed: struct {
        button: i32,
        mods: i32,
    },
    MouseButtonReleased: struct {
        button: i32,
        mods: i32,
    },

    MouseMoved: struct {
        x: f64,
        y: f64,
        dx: f64,
        dy: f64,
    },

    MouseScrolled: struct {
        x_offset: f64,
        y_offset: f64,
    },

    PathTracingToggled: struct {
        enabled: bool,
    },

    WireframeToggled: struct {
        enabled: bool,
    },

    CameraUpdated: void,
    SceneLoaded: void,
};

/// Event for inter-layer communication
pub const Event = struct {
    event_type: EventType,
    data: EventData,
    handled: bool = false,

    /// Create a new event
    pub fn init(event_type: EventType, data: EventData) Event {
        return .{
            .event_type = event_type,
            .data = data,
        };
    }

    /// Mark event as handled (prevents further propagation)
    pub fn markHandled(self: *Event) void {
        self.handled = true;
    }
};
