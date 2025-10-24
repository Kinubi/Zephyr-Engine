const std = @import("std");
const Event = @import("event.zig").Event;
const LayerStack = @import("layer_stack.zig").LayerStack;

/// Event bus for queueing and dispatching events
pub const EventBus = struct {
    allocator: std.mem.Allocator,
    event_queue: std.ArrayList(Event),

    pub fn init(allocator: std.mem.Allocator) EventBus {
        return .{
            .allocator = allocator,
            .event_queue = .{},
        };
    }

    pub fn deinit(self: *EventBus) void {
        self.event_queue.deinit(self.allocator);
    }

    /// Queue an event for processing
    pub fn queueEvent(self: *EventBus, event: Event) !void {
        try self.event_queue.append(self.allocator, event);
    }

    /// Process all queued events through the layer stack
    pub fn processEvents(self: *EventBus, layer_stack: *LayerStack) void {
        for (self.event_queue.items) |*event| {
            layer_stack.dispatchEvent(event);
        }
        self.event_queue.clearRetainingCapacity();
    }

    /// Get number of queued events
    pub fn queueSize(self: *EventBus) usize {
        return self.event_queue.items.len;
    }

    /// Clear all queued events without processing
    pub fn clear(self: *EventBus) void {
        self.event_queue.clearRetainingCapacity();
    }

    /// Post an event immediately to the layer stack (bypasses queue)
    pub fn postImmediate(self: *EventBus, event: *Event, layer_stack: *LayerStack) void {
        _ = self;
        layer_stack.dispatchEvent(event);
    }
};
