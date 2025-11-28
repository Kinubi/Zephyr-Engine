const std = @import("std");
const Math = @import("../../utils/math.zig");
const ShadowSystem = @import("../systems/shadow_system.zig");

/// ShadowDataSet component - snapshot of shadow system state for triple-buffered rendering
/// Written by ShadowSystem.prepare() on main thread, read by captureSnapshot() for render thread
///
/// This follows the same pattern as RenderablesSet - prepare phase computes everything,
/// stores it here, and the snapshot system copies it for each render frame.
pub const ShadowDataSet = struct {
    /// Pre-computed GPU SSBO data (ready to upload)
    gpu_ssbo: ShadowSystem.ShadowDataSSBO = .{},

    /// Legacy single-light data for geometry pass UBO
    legacy_shadow_data: ShadowSystem.ShadowData = .{},

    /// Number of active shadow-casting lights
    active_light_count: u32 = 0,

    /// Generation counter - incremented when shadow data changes
    /// Used by render thread to detect if GPU buffers need updating
    generation: u32 = 0,

    /// Whether shadow data changed this frame
    changed: bool = false,

    pub fn init() ShadowDataSet {
        return .{};
    }

    pub fn deinit(self: *ShadowDataSet) void {
        _ = self;
        // No allocations to free
    }

    /// Mark that shadow data has been updated
    pub fn markChanged(self: *ShadowDataSet) void {
        self.changed = true;
        self.generation +%= 1;
    }

    /// Clear the changed flag (after snapshot captures it)
    pub fn clearChanged(self: *ShadowDataSet) void {
        self.changed = false;
    }
};
