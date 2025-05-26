const std = @import("std");
const c = @cImport({
    @cInclude("GLFW/glfw3.h");
});
const vk = @import("vulkan");
const GraphicsContext = @import("graphics_context.zig").GraphicsContext;

pub const WindowProps = struct {
    width: u32 = 1280,
    height: u32 = 720,
    fullscreen: bool = false,
    title: [:0]const u8 = "Hello Zulkan!",
    vsync: bool = false,
};

pub const Window = struct {
    window: ?*c.GLFWwindow = null,
    window_props: WindowProps = undefined,

    fn errorCallback(error_code: c_int, description: [*c]const u8) callconv(.C) void {
        std.log.err("glfw: {}: {s}\n", .{ error_code, description });
    }

    pub fn init(windowProps: WindowProps) !Window {
        std.debug.print("Initializing GLFW...\n", .{});
        _ = c.glfwSetErrorCallback(errorCallback);
        if (c.glfwInit() != c.GLFW_TRUE) {
            return error.GlfwInitFailed;
        }

        std.debug.print("GLFW initialized successfully.\n", .{});

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
};
