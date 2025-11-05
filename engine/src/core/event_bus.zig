const std = @import("std");
const Event = @import("event.zig").Event;
const EventType = @import("event.zig").EventType;
const LayerStack = @import("layer_stack.zig").LayerStack;

/// Event bus for queueing and dispatching events
pub const EventBus = struct {
    allocator: std.mem.Allocator,
    event_queue: std.ArrayList(Event),
    mutex: std.Thread.Mutex, // Protect event_queue from concurrent access

    // Event filtering by category
    enabled_categories: std.EnumSet(EventCategory),

    pub fn init(allocator: std.mem.Allocator) EventBus {
        return .{
            .allocator = allocator,
            .event_queue = std.ArrayList(Event){},
            .mutex = .{},
            .enabled_categories = std.EnumSet(EventCategory).initFull(),
        };
    }

    pub fn deinit(self: *EventBus) void {
        self.event_queue.deinit(self.allocator);
    }

    /// Queue an event for processing
    pub fn queueEvent(self: *EventBus, event: Event) !void {
        const category = getEventCategory(event.event_type);
        if (!self.enabled_categories.contains(category)) {
            return; // Category is disabled, skip this event
        }

        // THREAD-SAFE: Lock while appending to queue (called from GLFW callbacks)
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.event_queue.append(self.allocator, event);
    }

    /// Process all queued events through the layer stack
    pub fn processEvents(self: *EventBus, layer_stack: *LayerStack) void {
        // THREAD-SAFE: Swap to local list under lock to minimize lock contention
        // This prevents holding the lock during potentially slow event dispatch
        var local_events = std.ArrayList(Event){};
        defer local_events.deinit(self.allocator);

        {
            self.mutex.lock();
            defer self.mutex.unlock();

            // Swap the queues so we can process without holding the lock
            std.mem.swap(std.ArrayList(Event), &self.event_queue, &local_events);
        }

        // Process events without holding the lock (allows concurrent queueEvent calls)
        for (local_events.items) |*event| {
            layer_stack.dispatchEvent(event);
        }
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

    /// Enable/disable specific event categories
    pub fn setCategory(self: *EventBus, category: EventCategory, enabled: bool) void {
        if (enabled) {
            self.enabled_categories.insert(category);
        } else {
            self.enabled_categories.remove(category);
        }
    }

    /// Check if a category is enabled
    pub fn isCategoryEnabled(self: *EventBus, category: EventCategory) bool {
        return self.enabled_categories.contains(category);
    }
};

/// Event categories for filtering
pub const EventCategory = enum {
    Window,
    Input,
    Application,
};

/// Get the category for an event type
fn getEventCategory(event_type: EventType) EventCategory {
    return switch (event_type) {
        .WindowResize, .WindowClose => .Window,
        .KeyPressed, .KeyReleased, .KeyTyped, .MouseButtonPressed, .MouseButtonReleased, .MouseMoved, .MouseScrolled => .Input,
        .PathTracingToggled, .WireframeToggled, .CameraUpdated, .SceneLoaded => .Application,
    };
}
