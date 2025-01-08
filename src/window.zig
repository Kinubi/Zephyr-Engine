const std = @import("std");
const glfw = @import("mach-glfw");
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
    window: ?glfw.Window = null,
    window_props: WindowProps = undefined,

    fn errorCallback(error_code: glfw.ErrorCode, description: [:0]const u8) void {
        std.log.err("glfw: {}: {s}\n", .{ error_code, description });
    }

    pub fn init(windowProps: WindowProps) !Window {
        glfw.setErrorCallback(errorCallback);
        if (!glfw.init(.{ .platform = .wayland })) {
            return error.GlfwInitFailed;
        }

        var monitor = glfw.Monitor.getPrimary().?;
        const mode = monitor.getVideoMode().?;

        const width = if (windowProps.fullscreen) mode.getWidth() else windowProps.width;
        const height = if (windowProps.fullscreen) mode.getHeight() else windowProps.height;

        // Create our window
        const window = glfw.Window.create(
            width,
            height,
            windowProps.title,
            if (windowProps.fullscreen) monitor else null,
            null,
            .{ .client_api = .no_api, .context_creation_api = .native_context_api },
        ) orelse {
            return error.GlfwWindowCreationFailed;
        };

        return Window{ .window = window, .window_props = windowProps };
    }

    pub fn deinit(self: Window) void {
        self.window.?.destroy();
        glfw.terminate();
    }
    pub fn isRunning(self: @This()) bool {
        glfw.pollEvents();

        return !self.window.?.shouldClose();
    }
};
