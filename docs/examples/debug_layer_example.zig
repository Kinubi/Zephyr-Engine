// Example: Simple Debug Layer
// This file demonstrates how to create a minimal custom layer for Zephyr-Engine
// Location: Place this in src/layers/debug_layer.zig

const std = @import("std");
const Layer = @import("../core/layer.zig").Layer;
const Event = @import("../core/event.zig").Event;
const EventType = @import("../core/event.zig").EventType;
const FrameInfo = @import("../rendering/frameinfo.zig").FrameInfo;

/// Simple debug layer that logs frame information
/// Demonstrates the minimal layer implementation
pub const DebugLayer = struct {
    base: Layer, // REQUIRED: Must be first field

    // Custom fields
    frame_count: u64 = 0,
    log_interval: u64 = 60, // Log every 60 frames
    show_debug: bool = true,

    /// Initialize the debug layer
    pub fn init() DebugLayer {
        return .{
            .base = .{
                .name = "DebugLayer",
                .enabled = true,
                .vtable = &vtable,
            },
        };
    }

    // VTable defines which functions implement the Layer interface
    const vtable = Layer.VTable{
        .attach = attach,
        .detach = detach,
        .begin = begin,
        .update = update,
        .render = render,
        .end = end,
        .event = event,
    };

    /// Called once when layer is added to the stack
    fn attach(base: *Layer) !void {
        const self: *DebugLayer = @fieldParentPtr("base", base);
        _ = self;
        std.log.info("DebugLayer attached", .{});
    }

    /// Called once when layer is removed from the stack
    fn detach(base: *Layer) void {
        const self: *DebugLayer = @fieldParentPtr("base", base);
        std.log.info("DebugLayer detached after {} frames", .{self.frame_count});
    }

    /// Called at the start of each frame
    fn begin(base: *Layer, frame_info: *const FrameInfo) !void {
        _ = base;
        _ = frame_info;
        // Setup frame state here
    }

    /// Called every frame for logic updates
    fn update(base: *Layer, frame_info: *const FrameInfo) !void {
        const self: *DebugLayer = @fieldParentPtr("base", base);

        self.frame_count += 1;

        // Log debug info every N frames
        if (self.show_debug and self.frame_count % self.log_interval == 0) {
            const fps = 1.0 / frame_info.dt;
            std.log.info("Frame {}: FPS={d:.1}, dt={d:.4}ms", .{
                self.frame_count,
                fps,
                frame_info.dt * 1000.0,
            });

            // Access layer timing
            const total_ms = self.base.timing.getTotalMs();
            std.log.info("  DebugLayer CPU time: {d:.3}ms", .{total_ms});
        }
    }

    /// Called every frame for rendering
    fn render(base: *Layer, frame_info: *const FrameInfo) !void {
        _ = base;
        _ = frame_info;
        // Add custom rendering here (e.g., debug overlays)
    }

    /// Called at the end of each frame for cleanup
    fn end(base: *Layer, frame_info: *FrameInfo) !void {
        _ = base;
        _ = frame_info;
        // Cleanup frame state here
    }

    /// Handle events from the event system
    fn event(base: *Layer, evt: *Event) void {
        const self: *DebugLayer = @fieldParentPtr("base", base);

        switch (evt.event_type) {
            .KeyPressed => {
                const key_data = evt.data.KeyPressed;

                // F4 key toggles debug layer
                const GLFW_KEY_F4 = 293;
                if (key_data.key == GLFW_KEY_F4) {
                    self.show_debug = !self.show_debug;
                    std.log.info("Debug logging: {}", .{self.show_debug});
                    evt.markHandled(); // Prevent other layers from seeing this event
                }
            },

            .WindowResize => {
                const width = evt.data.WindowResize.width;
                const height = evt.data.WindowResize.height;
                std.log.info("Window resized to {}x{}", .{ width, height });
            },

            else => {},
        }
    }
};

// ============================================================================
// Usage Example (in app.zig):
// ============================================================================
//
// 1. Import the layer:
//    const DebugLayer = @import("layers/debug_layer.zig").DebugLayer;
//
// 2. Add field to App:
//    var debug_layer: DebugLayer = undefined;
//
// 3. Initialize in App.init():
//    debug_layer = DebugLayer.init();
//    try layer_stack.pushLayer(&debug_layer.base);
//
// 4. Runtime controls:
//    - F4: Toggle debug logging
//    - Layer is automatically profiled
//
// That's it! The layer will now run every frame.
