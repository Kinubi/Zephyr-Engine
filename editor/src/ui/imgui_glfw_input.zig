const std = @import("std");

const c = @cImport({
    @cDefine("GLFW_INCLUDE_VULKAN", "1");
    @cDefine("GLFW_INCLUDE_NONE", "1");
    @cInclude("GLFW/glfw3.h");
    @cInclude("dcimgui.h");
});

/// Minimal GLFW input handler for ImGui - optimized for performance
/// Only updates what ImGui actually needs
pub const ImGuiGlfwInput = struct {
    window: *c.GLFWwindow,
    time: f64 = 0.0,
    mouse_pressed: [5]bool = [_]bool{false} ** 5,

    pub fn init(window: *c.GLFWwindow) ImGuiGlfwInput {
        return .{
            .window = window,
            .time = c.glfwGetTime(),
        };
    }

    pub fn newFrame(self: *ImGuiGlfwInput) void {
        const io = c.ImGui_GetIO();

        // Update display size
        var w: c_int = 0;
        var h: c_int = 0;
        c.glfwGetWindowSize(self.window, &w, &h);
        io.*.DisplaySize = .{ .x = @floatFromInt(w), .y = @floatFromInt(h) };

        // Update framebuffer scale (for high DPI)
        var display_w: c_int = 0;
        var display_h: c_int = 0;
        c.glfwGetFramebufferSize(self.window, &display_w, &display_h);
        if (w > 0 and h > 0) {
            io.*.DisplayFramebufferScale = .{
                .x = @as(f32, @floatFromInt(display_w)) / @as(f32, @floatFromInt(w)),
                .y = @as(f32, @floatFromInt(display_h)) / @as(f32, @floatFromInt(h)),
            };
        }

        // Update delta time
        const current_time = c.glfwGetTime();
        io.*.DeltaTime = if (self.time > 0.0) @floatCast(current_time - self.time) else @as(f32, 1.0 / 60.0);
        self.time = current_time;

        // Update mouse position
        var mouse_x: f64 = 0.0;
        var mouse_y: f64 = 0.0;
        c.glfwGetCursorPos(self.window, &mouse_x, &mouse_y);
        io.*.MousePos = .{ .x = @floatCast(mouse_x), .y = @floatCast(mouse_y) };

        // Update mouse buttons (only check if window is focused)
        if (c.glfwGetWindowAttrib(self.window, c.GLFW_FOCUSED) != 0) {
            io.*.MouseDown[0] = self.mouse_pressed[0] or c.glfwGetMouseButton(self.window, c.GLFW_MOUSE_BUTTON_LEFT) != 0;
            io.*.MouseDown[1] = self.mouse_pressed[1] or c.glfwGetMouseButton(self.window, c.GLFW_MOUSE_BUTTON_RIGHT) != 0;
            io.*.MouseDown[2] = self.mouse_pressed[2] or c.glfwGetMouseButton(self.window, c.GLFW_MOUSE_BUTTON_MIDDLE) != 0;
        }
    }
};
