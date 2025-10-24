const std = @import("std");
const Layer = @import("../core/layer.zig").Layer;
const Event = @import("../core/event.zig").Event;
const FrameInfo = @import("../rendering/frameinfo.zig").FrameInfo;
const PerformanceMonitor = @import("../rendering/performance_monitor.zig").PerformanceMonitor;

/// Performance monitoring layer
/// Manages frame timing and GPU performance tracking
pub const PerformanceLayer = struct {
    base: Layer,
    performance_monitor: *PerformanceMonitor,

    pub fn init(performance_monitor: *PerformanceMonitor) PerformanceLayer {
        return .{
            .base = .{
                .name = "PerformanceLayer",
                .enabled = true,
                .vtable = &vtable,
            },
            .performance_monitor = performance_monitor,
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

        // Begin frame monitoring
        try self.performance_monitor.beginFrame(frame_info.current_frame);

        // Reset queries for this frame (after command buffers started)
        try self.performance_monitor.resetQueriesForFrame(frame_info.compute_buffer);
        try self.performance_monitor.writeFrameStartTimestamp(frame_info.compute_buffer);
    }

    fn update(base: *Layer, frame_info: *const FrameInfo) !void {
        _ = base;
        _ = frame_info;
        // Performance monitoring happens in begin/end
    }

    fn render(base: *Layer, frame_info: *const FrameInfo) !void {
        _ = base;
        _ = frame_info;
        // Performance data collected via pass timing
    }

    fn end(base: *Layer, frame_info: *const FrameInfo) !void {
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
