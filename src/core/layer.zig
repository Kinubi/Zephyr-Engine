const std = @import("std");
const FrameInfo = @import("../rendering/frameinfo.zig").FrameInfo;
const Event = @import("event.zig").Event;

/// Layer interface for modular application architecture
/// Each layer represents a distinct concern (input, scene, rendering, UI, etc.)
pub const Layer = struct {
    name: []const u8,
    enabled: bool = true,
    vtable: *const VTable,

    /// Virtual function table for polymorphic behavior
    pub const VTable = struct {
        /// Called when layer is attached to the stack
        attach: *const fn (layer: *Layer) anyerror!void,

        /// Called when layer is detached from the stack
        detach: *const fn (layer: *Layer) void,

        /// Called at the start of the frame (before updates)
        begin: *const fn (layer: *Layer, frame_info: *const FrameInfo) anyerror!void,

        /// Called every frame for updates (logic, input, etc.)
        /// Receives full frame context including dt
        update: *const fn (layer: *Layer, frame_info: *const FrameInfo) anyerror!void,

        /// Called every frame for rendering
        render: *const fn (layer: *Layer, frame_info: *const FrameInfo) anyerror!void,

        /// Called at the end of the frame (after rendering)
        end: *const fn (layer: *Layer, frame_info: *const FrameInfo) anyerror!void,

        /// Called when an event is dispatched
        event: *const fn (layer: *Layer, event: *Event) void,
    };

    /// Attach layer to stack
    pub fn attach(self: *Layer) !void {
        return self.vtable.attach(self);
    }

    /// Detach layer from stack
    pub fn detach(self: *Layer) void {
        return self.vtable.detach(self);
    }

    /// Begin frame for this layer
    pub fn begin(self: *Layer, frame_info: *const FrameInfo) !void {
        if (!self.enabled) return;
        return self.vtable.begin(self, frame_info);
    }

    /// Update layer with frame context
    pub fn update(self: *Layer, frame_info: *const FrameInfo) !void {
        if (!self.enabled) return;
        return self.vtable.update(self, frame_info);
    }

    /// Render layer
    pub fn render(self: *Layer, frame_info: *const FrameInfo) !void {
        if (!self.enabled) return;
        return self.vtable.render(self, frame_info);
    }

    /// End frame for this layer
    pub fn end(self: *Layer, frame_info: *const FrameInfo) !void {
        if (!self.enabled) return;
        return self.vtable.end(self, frame_info);
    }

    /// Handle event
    pub fn handleEvent(self: *Layer, event: *Event) void {
        if (!self.enabled) return;
        return self.vtable.event(self, event);
    }
};
