const std = @import("std");
const Layer = @import("layer.zig").Layer;
const Event = @import("event.zig").Event;
const FrameInfo = @import("../rendering/frameinfo.zig").FrameInfo;

/// Manages a stack of layers with ordered execution
pub const LayerStack = struct {
    allocator: std.mem.Allocator,
    layers: std.ArrayList(*Layer),
    overlay_insert_index: usize = 0,

    pub fn init(allocator: std.mem.Allocator) LayerStack {
        return .{
            .allocator = allocator,
            .layers = .{},
        };
    }

    pub fn deinit(self: *LayerStack) void {
        // Detach all layers in reverse order
        var i = self.layers.items.len;
        while (i > 0) {
            i -= 1;
            self.layers.items[i].detach();
        }
        self.layers.deinit(self.allocator);
    }

    /// Push a layer onto the stack (before overlays)
    pub fn pushLayer(self: *LayerStack, layer: *Layer) !void {
        try self.layers.insert(self.allocator, self.overlay_insert_index, layer);
        self.overlay_insert_index += 1;
        try layer.attach();
    }

    /// Push an overlay (always on top)
    pub fn pushOverlay(self: *LayerStack, overlay: *Layer) !void {
        try self.layers.append(self.allocator, overlay);
        try overlay.attach();
    }

    /// Remove a layer
    pub fn popLayer(self: *LayerStack, layer: *Layer) void {
        if (std.mem.indexOfScalar(*Layer, self.layers.items, layer)) |index| {
            layer.detach();
            _ = self.layers.orderedRemove(index);
            if (index < self.overlay_insert_index) {
                self.overlay_insert_index -= 1;
            }
        }
    }

    /// PHASE 2.1: Prepare all layers (MAIN THREAD - no Vulkan work)
    pub fn prepare(self: *LayerStack, dt: f32) !void {
        for (self.layers.items) |layer| {
            try layer.prepare(dt);
        }
    }

    /// Update all layers with current frame info (RENDER THREAD - Vulkan descriptors)
    pub fn update(self: *LayerStack, frame_info: *const FrameInfo) !void {
        for (self.layers.items) |layer| {
            try layer.update(frame_info);
        }
    }

    /// Begin frame for all layers
    pub fn begin(self: *LayerStack, frame_info: *const FrameInfo) !void {
        for (self.layers.items) |layer| {
            try layer.begin(frame_info);
        }
    }

    /// Render all layers
    pub fn render(self: *LayerStack, frame_info: *const FrameInfo) !void {
        for (self.layers.items) |layer| {
            try layer.render(frame_info);
        }
    }

    /// End frame for all layers
    pub fn end(self: *LayerStack, frame_info: *FrameInfo) !void {
        for (self.layers.items) |layer| {
            try layer.end(frame_info);
        }
    }

    /// Dispatch event to all layers.
    ///
    /// Events are dispatched top-down (overlays first). A
    /// layer may mark the event handled to stop further propagation.
    pub fn dispatchEvent(self: *LayerStack, event: *Event) void {
        // Process in forward order (bottom layers first)
        var i: usize = 0;
        while (i < self.layers.items.len) : (i += 1) {
            self.layers.items[i].handleEvent(event);
            if (event.handled) break;
        }
    }

    /// Get number of layers
    pub fn count(self: *LayerStack) usize {
        return self.layers.items.len;
    }

    /// Get layer by index
    pub fn get(self: *LayerStack, index: usize) ?*Layer {
        if (index >= self.layers.items.len) return null;
        return self.layers.items[index];
    }
};
