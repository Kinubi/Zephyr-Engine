const std = @import("std");
const Layer = @import("../core/layer.zig").Layer;
const Event = @import("../core/event.zig").Event;
const FrameInfo = @import("../rendering/frameinfo.zig").FrameInfo;
const PerformanceMonitor = @import("../rendering/performance_monitor.zig").PerformanceMonitor;
const MAX_FRAMES_IN_FLIGHT = @import("../core/swapchain.zig").MAX_FRAMES_IN_FLIGHT;
const Swapchain = @import("../core/swapchain.zig").Swapchain;

/// Performance monitoring layer
/// Manages frame timing and GPU performance tracking
pub const PerformanceLayer = struct {
    base: Layer,
    performance_monitor: *PerformanceMonitor,
    swapchain: *Swapchain,

    pub fn init(performance_monitor: *PerformanceMonitor, swapchain: *Swapchain) PerformanceLayer {
        return .{
            .base = .{
                .name = "PerformanceLayer",
                .enabled = true,
                .vtable = &vtable,
            },
            .performance_monitor = performance_monitor,
            .swapchain = swapchain,
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
