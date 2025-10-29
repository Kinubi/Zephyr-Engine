const std = @import("std");
const FrameInfo = @import("../rendering/frameinfo.zig").FrameInfo;
const Event = @import("event.zig").Event;

/// Layer interface for modular application architecture
/// Each layer represents a distinct concern (input, scene, rendering, UI, etc.)
pub const Layer = struct {
    name: []const u8,
    enabled: bool = true,
    vtable: *const VTable,

    // Performance tracking (in nanoseconds)
    timing: LayerTiming = .{},

    pub const LayerTiming = struct {
        prepare_time_ns: u64 = 0,
        begin_time_ns: u64 = 0,
        update_time_ns: u64 = 0,
        render_time_ns: u64 = 0,
        end_time_ns: u64 = 0,
        event_time_ns: u64 = 0,

        pub fn getTotalMs(self: LayerTiming) f32 {
            const total_ns = self.prepare_time_ns + self.begin_time_ns + self.update_time_ns + self.render_time_ns + self.end_time_ns + self.event_time_ns;
            return @as(f32, @floatFromInt(total_ns)) / 1_000_000.0;
        }

        pub fn reset(self: *LayerTiming) void {
            self.prepare_time_ns = 0;
            self.begin_time_ns = 0;
            self.update_time_ns = 0;
            self.render_time_ns = 0;
            self.end_time_ns = 0;
            self.event_time_ns = 0;
        }
    };

    /// Virtual function table for polymorphic behavior
    pub const VTable = struct {
        /// Called when layer is attached to the stack
        attach: *const fn (layer: *Layer) anyerror!void,

        /// Called when layer is detached from the stack
        detach: *const fn (layer: *Layer) void,

        /// PHASE 2.1: Called on MAIN THREAD for CPU-side preparation
        /// Game logic, ECS queries, physics - NO Vulkan work
        /// Optional - can be null for layers without main thread work
        prepare: ?*const fn (layer: *Layer, dt: f32) anyerror!void,

        /// Called at the start of the frame (before updates)
        begin: *const fn (layer: *Layer, frame_info: *const FrameInfo) anyerror!void,

        /// PHASE 2.1: Called on RENDER THREAD for Vulkan descriptor updates
        /// Receives full frame context including dt
        update: *const fn (layer: *Layer, frame_info: *const FrameInfo) anyerror!void,

        /// PHASE 2.1: Called on RENDER THREAD for Vulkan draw commands
        render: *const fn (layer: *Layer, frame_info: *const FrameInfo) anyerror!void,

        /// Called at the end of the frame (after rendering)
        end: *const fn (layer: *Layer, frame_info: *FrameInfo) anyerror!void,

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

    /// PHASE 2.1: Prepare layer (MAIN THREAD - no Vulkan work)
    pub fn prepare(self: *Layer, dt: f32) !void {
        if (!self.enabled) return;
        if (self.vtable.prepare) |prep| {
            const start_time = std.time.nanoTimestamp();
            try prep(self, dt);
            const end_time = std.time.nanoTimestamp();
            self.timing.prepare_time_ns = @intCast(end_time - start_time);
        }
    }

    /// Begin frame for this layer
    pub fn begin(self: *Layer, frame_info: *const FrameInfo) !void {
        if (!self.enabled) return;
        const start_time = std.time.nanoTimestamp();
        try self.vtable.begin(self, frame_info);
        const end_time = std.time.nanoTimestamp();
        self.timing.begin_time_ns = @intCast(end_time - start_time);
    }

    /// Update layer with frame context
    pub fn update(self: *Layer, frame_info: *const FrameInfo) !void {
        if (!self.enabled) return;
        const start_time = std.time.nanoTimestamp();
        try self.vtable.update(self, frame_info);
        const end_time = std.time.nanoTimestamp();
        self.timing.update_time_ns = @intCast(end_time - start_time);
    }

    /// Render layer
    pub fn render(self: *Layer, frame_info: *const FrameInfo) !void {
        if (!self.enabled) return;
        const start_time = std.time.nanoTimestamp();
        try self.vtable.render(self, frame_info);
        const end_time = std.time.nanoTimestamp();
        self.timing.render_time_ns = @intCast(end_time - start_time);
    }

    /// End frame for this layer
    pub fn end(self: *Layer, frame_info: *FrameInfo) !void {
        if (!self.enabled) return;
        const start_time = std.time.nanoTimestamp();
        try self.vtable.end(self, frame_info);
        const end_time = std.time.nanoTimestamp();
        self.timing.end_time_ns = @intCast(end_time - start_time);
    }

    /// Handle event
    pub fn handleEvent(self: *Layer, event: *Event) void {
        if (!self.enabled) return;
        const start_time = std.time.nanoTimestamp();
        self.vtable.event(self, event);
        const end_time = std.time.nanoTimestamp();
        self.timing.event_time_ns += @intCast(end_time - start_time);
    }
};
