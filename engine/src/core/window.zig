const std = @import("std");
const c = @cImport({
    @cDefine("_GLFW_X11", "1");
    @cDefine("GLFW_PLATFORM_WAYLAND", "0");
    @cInclude("GLFW/glfw3.h");
});
const vk = @import("vulkan");
const GraphicsContext = @import("graphics_context.zig").GraphicsContext;
const EventBus = @import("event_bus.zig").EventBus;
const Event = @import("event.zig").Event;
const EventData = @import("event.zig").EventData;

pub const WindowProps = struct {
    width: u32 = 1280,
    height: u32 = 720,
    fullscreen: bool = false,
    title: [:0]const u8 = "Hello Zephyr!",
    vsync: bool = false,
};

pub const Window = struct {
    window: ?*c.GLFWwindow = null,
    window_props: WindowProps = undefined,
    event_bus: ?*EventBus = null, // Optional event bus for event-driven input

    fn errorCallback(error_code: c_int, description: [*c]const u8) callconv(.c) void {
        std.log.err("glfw: {}: {s}\n", .{ error_code, description });
    }

    // GLFW Callbacks for event generation
    fn keyCallback(window: ?*c.GLFWwindow, key: c_int, scancode: c_int, action: c_int, mods: c_int) callconv(.c) void {
        const self = getUserPointer(window);
        if (self.event_bus) |bus| {
            if (action == c.GLFW_PRESS or action == c.GLFW_REPEAT) {
                const event = Event.init(.KeyPressed, .{ .KeyPressed = .{ .key = key, .scancode = scancode, .mods = mods } });
                bus.queueEvent(event) catch {};
            } else if (action == c.GLFW_RELEASE) {
                const event = Event.init(.KeyReleased, .{ .KeyReleased = .{ .key = key, .scancode = scancode, .mods = mods } });
                bus.queueEvent(event) catch {};
            }
        }
    }

    fn mouseButtonCallback(window: ?*c.GLFWwindow, button: c_int, action: c_int, mods: c_int) callconv(.c) void {
        const self = getUserPointer(window);
        if (self.event_bus) |bus| {
            if (action == c.GLFW_PRESS) {
                const event = Event.init(.MouseButtonPressed, .{ .MouseButtonPressed = .{ .button = button, .mods = mods } });
                bus.queueEvent(event) catch {};
            } else if (action == c.GLFW_RELEASE) {
                const event = Event.init(.MouseButtonReleased, .{ .MouseButtonReleased = .{ .button = button, .mods = mods } });
                bus.queueEvent(event) catch {};
            }
        }
    }

    fn cursorPosCallback(window: ?*c.GLFWwindow, xpos: f64, ypos: f64) callconv(.c) void {
        const self = getUserPointer(window);
        if (self.event_bus) |bus| {
            // Store last position to calculate delta (you'd need to add prev_mouse_x/y fields to Window)
            const event = Event.init(.MouseMoved, .{ .MouseMoved = .{ .x = xpos, .y = ypos, .dx = 0.0, .dy = 0.0 } });
            bus.queueEvent(event) catch {};
        }
    }

    // GLFW char callback: forward UTF-8 characters as KeyTyped events on the engine event bus
    fn charCallback(window: ?*c.GLFWwindow, codepoint: c_uint) callconv(.c) void {
        const self = getUserPointer(window);
        if (self.event_bus) |bus| {
            const event = Event.init(.KeyTyped, .{ .KeyTyped = .{ .codepoint = @as(u32, codepoint) } });
            bus.queueEvent(event) catch {};
        }
    }

    fn scrollCallback(window: ?*c.GLFWwindow, xoffset: f64, yoffset: f64) callconv(.c) void {
        const self = getUserPointer(window);
        if (self.event_bus) |bus| {
            const event = Event.init(.MouseScrolled, .{ .MouseScrolled = .{ .x_offset = xoffset, .y_offset = yoffset } });
            bus.queueEvent(event) catch {};
        }
    }

    fn windowSizeCallback(window: ?*c.GLFWwindow, width: c_int, height: c_int) callconv(.c) void {
        const self = getUserPointer(window);
        if (self.event_bus) |bus| {
            const event = Event.init(.WindowResize, .{ .WindowResize = .{ .width = @intCast(width), .height = @intCast(height) } });
            bus.queueEvent(event) catch {};
        }
    }

    fn getUserPointer(window: ?*c.GLFWwindow) *Window {
        return @ptrCast(@alignCast(c.glfwGetWindowUserPointer(window)));
    }

    pub fn init(windowProps: WindowProps) !Window {
        _ = c.glfwSetErrorCallback(errorCallback);
        if (c.glfwInit() != c.GLFW_TRUE) {
            return error.GlfwInitFailed;
        }

        var monitor: ?*c.GLFWmonitor = null;
        var mode: ?*const c.GLFWvidmode = null;
        if (windowProps.fullscreen) {
            monitor = c.glfwGetPrimaryMonitor();
            if (monitor == null) return error.GlfwMonitorNotFound;
            mode = c.glfwGetVideoMode(monitor);
            if (mode == null) return error.GlfwVideoModeNotFound;
        }

        const width: c_int = if (windowProps.fullscreen) mode.?.width else @intCast(windowProps.width);
        const height: c_int = if (windowProps.fullscreen) mode.?.height else @intCast(windowProps.height);

        // Set window hints for Vulkan
        c.glfwWindowHint(c.GLFW_CLIENT_API, c.GLFW_NO_API);

        const window = c.glfwCreateWindow(
            width,
            height,
            windowProps.title.ptr,
            if (windowProps.fullscreen) monitor else null,
            null,
        );
        if (window == null) {
            c.glfwTerminate();
            return error.GlfwWindowCreationFailed;
        }

        return Window{ .window = window, .window_props = windowProps };
    }

    pub fn deinit(self: Window) void {
        if (self.window) |win| {
            c.glfwDestroyWindow(win);
        }
        c.glfwTerminate();
    }
    pub fn isRunning(self: @This()) bool {
        c.glfwPollEvents();
        return self.window != null and c.glfwWindowShouldClose(self.window) == 0;
    }

    pub fn setTitle(self: *Window, title: [*:0]const u8) void {
        if (self.window) |win| {
            c.glfwSetWindowTitle(win, title);
        }
    }

    /// Set event bus and register GLFW callbacks for event-driven input
    pub fn setEventBus(self: *Window, event_bus: *EventBus) void {
        self.event_bus = event_bus;

        if (self.window) |win| {
            // Set window user pointer to this Window instance
            c.glfwSetWindowUserPointer(win, self);

            // Register GLFW callbacks
            _ = c.glfwSetKeyCallback(win, keyCallback);
            _ = c.glfwSetMouseButtonCallback(win, mouseButtonCallback);
            _ = c.glfwSetCursorPosCallback(win, cursorPosCallback);
            _ = c.glfwSetCharCallback(win, charCallback);
            _ = c.glfwSetScrollCallback(win, scrollCallback);
            _ = c.glfwSetWindowSizeCallback(win, windowSizeCallback);
        }
    }
};
