const std = @import("std");
const Layer = @import("../core/layer.zig").Layer;
const Event = @import("../core/event.zig").Event;
const FrameInfo = @import("../rendering/frameinfo.zig").FrameInfo;
const PerformanceMonitor = @import("../rendering/performance_monitor.zig").PerformanceMonitor;
const MAX_FRAMES_IN_FLIGHT = @import("../core/swapchain.zig").MAX_FRAMES_IN_FLIGHT;
const Swapchain = @import("../core/swapchain.zig").Swapchain;
const Window = @import("../core/window.zig").Window;
const c = @cImport({
    @cInclude("GLFW/glfw3.h");
});

/// Performance monitoring layer
/// Manages frame timing and GPU performance tracking
pub const PerformanceLayer = struct {
    base: Layer,
    performance_monitor: *PerformanceMonitor,
    swapchain: *Swapchain,
    window: *Window,

    // FPS tracking
    fps_frame_count: u32 = 0,
    fps_last_time: f64 = 0.0,
    current_fps: f32 = 0.0,

    pub fn init(performance_monitor: *PerformanceMonitor, swapchain: *Swapchain, window: *Window) PerformanceLayer {
        return .{
            .base = .{
                .name = "PerformanceLayer",
                .enabled = true,
                .vtable = &vtable,
            },
            .performance_monitor = performance_monitor,
            .swapchain = swapchain,
            .window = window,
            .fps_last_time = c.glfwGetTime(),
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
        const self: *PerformanceLayer = @fieldParentPtr("base", base);
        _ = self;
        // Performance monitor should already be initialized
    }

    fn detach(base: *Layer) void {
        const self: *PerformanceLayer = @fieldParentPtr("base", base);
        _ = self;
    }

    fn begin(base: *Layer, frame_info: *const FrameInfo) !void {
        const self: *PerformanceLayer = @fieldParentPtr("base", base);
        const prev_frame = if (frame_info.current_frame == 0) MAX_FRAMES_IN_FLIGHT - 1 else frame_info.current_frame - 1;
        try self.performance_monitor.updateGpuTimings(prev_frame, self.swapchain.frame_fence, self.swapchain.compute_fence);

        // Begin frame monitoring (must happen before swapchain.beginFrame)
        try self.performance_monitor.beginFrame(frame_info.current_frame);
    }

    fn update(base: *Layer, frame_info: *const FrameInfo) !void {
        const self: *PerformanceLayer = @fieldParentPtr("base", base);

        // Reset queries and write frame start timestamp after command buffers are started
        try self.performance_monitor.resetQueriesForFrame(frame_info.compute_buffer);
        try self.performance_monitor.writeFrameStartTimestamp(frame_info.compute_buffer);

        // Update FPS and window title
        self.fps_frame_count += 1;
        const current_time = c.glfwGetTime();

        if (current_time - self.fps_last_time >= 1.0) {
            self.current_fps = @as(f32, @floatFromInt(self.fps_frame_count)) / @as(f32, @floatCast(current_time - self.fps_last_time));

            // Update window title with FPS
            var title_buffer: [256:0]u8 = undefined;
            const title_slice = std.fmt.bufPrintZ(title_buffer[0..], "ZulkanZengine - FPS: {d:.1}", .{self.current_fps}) catch blk: {
                break :blk std.fmt.bufPrintZ(title_buffer[0..], "ZulkanZengine", .{}) catch "ZulkanZengine";
            };

            self.window.setTitle(title_slice.ptr);

            self.fps_frame_count = 0;
            self.fps_last_time = current_time;
        }
    }

    fn render(base: *Layer, frame_info: *const FrameInfo) !void {
        _ = base;
        _ = frame_info;
        // Performance data collected via pass timing
    }

    fn end(base: *Layer, frame_info: *FrameInfo) !void {
        const self: *PerformanceLayer = @fieldParentPtr("base", base);

        // Write frame end timestamp and complete monitoring
        try self.performance_monitor.writeFrameEndTimestamp(frame_info.command_buffer);
        try self.performance_monitor.endFrame(frame_info.current_frame);
    }

    fn event(base: *Layer, evt: *Event) void {
        const self: *PerformanceLayer = @fieldParentPtr("base", base);
        _ = self;
        _ = evt;
    }
};
