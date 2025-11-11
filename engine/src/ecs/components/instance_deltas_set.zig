const std = @import("std");
const render_data_types = @import("../../rendering/render_data_types.zig");

/// Instance delta update for render system
/// Tracks which instances changed and their new data
pub const InstanceDeltasSet = struct {
    changed_indices: []u32 = &.{},
    changed_data: []render_data_types.RasterizationData.InstanceData = &.{},
    allocator: ?std.mem.Allocator = null,

    pub fn init() InstanceDeltasSet {
        return .{};
    }

    pub fn deinit(self: *InstanceDeltasSet) void {
        if (self.allocator) |allocator| {
            if (self.changed_indices.len > 0) {
                allocator.free(self.changed_indices);
            }
            if (self.changed_data.len > 0) {
                allocator.free(self.changed_data);
            }
        }
        self.changed_indices = &.{};
        self.changed_data = &.{};
        self.allocator = null;
    }

    pub fn setDeltas(
        self: *InstanceDeltasSet,
        allocator: std.mem.Allocator,
        indices: []u32,
        data: []render_data_types.RasterizationData.InstanceData,
    ) void {
        // Free old data
        if (self.allocator) |old_allocator| {
            if (self.changed_indices.len > 0) {
                old_allocator.free(self.changed_indices);
            }
            if (self.changed_data.len > 0) {
                old_allocator.free(self.changed_data);
            }
        }

        self.changed_indices = indices;
        self.changed_data = data;
        self.allocator = allocator;
    }

    pub fn clear(self: *InstanceDeltasSet) void {
        if (self.allocator) |allocator| {
            if (self.changed_indices.len > 0) {
                allocator.free(self.changed_indices);
            }
            if (self.changed_data.len > 0) {
                allocator.free(self.changed_data);
            }
        }
        self.changed_indices = &.{};
        self.changed_data = &.{};
    }
};
