const RenderChangeFlags = @import("../../threading/game_state_snapshot.zig").RenderChangeFlags;
const Math = @import("../../utils/math.zig");
const AssetId = @import("../../assets/asset_types.zig").AssetId;
const EntityId = @import("../entity_registry.zig").EntityId;
const std = @import("std");

/// Extracted renderable entity data (written by prepare, read by snapshot)
pub const ExtractedRenderable = struct {
    entity_id: EntityId,
    transform: Math.Mat4x4,
    model_asset: AssetId,
    material_buffer_index: ?u32,
    texture_asset: ?AssetId,
    layer: u8,
    casts_shadows: bool,
    receives_shadows: bool,
};

/// RenderablesSet component - tracks render change state and extracted data for snapshot system
/// Similar to MaterialSet, this is written by RenderSystem.prepare() and read by captureSnapshot()
pub const RenderablesSet = struct {
    /// Change detection flags from prepare phase
    changes: RenderChangeFlags = .{},

    /// Generation counter - incremented each time caches are rebuilt
    /// Used by update phase to detect if GPU buffers need updating
    generation: u32 = 0,

    /// Extracted renderable entities (from prepare phase)
    /// Allocated and owned by this component
    renderables: []ExtractedRenderable = &.{},
    allocator: ?std.mem.Allocator = null,

    pub fn init() RenderablesSet {
        return .{};
    }

    pub fn deinit(self: *RenderablesSet) void {
        if (self.allocator) |allocator| {
            if (self.renderables.len > 0) {
                allocator.free(self.renderables);
            }
        }
        self.renderables = &.{};
    }

    pub fn setRenderables(self: *RenderablesSet, allocator: std.mem.Allocator, renderables: []ExtractedRenderable) void {
        // Free old data
        self.deinit();
        // Store new data
        self.renderables = renderables;
        self.allocator = allocator;
    }

    pub fn markDirty(self: *RenderablesSet, transform_only: bool) void {
        self.changes.renderables_dirty = true;
        self.changes.transform_only_change = transform_only;
        self.changes.raster_descriptors_dirty = !transform_only;
        self.changes.raytracing_descriptors_dirty = !transform_only;
    }

    pub fn clearDirty(self: *RenderablesSet) void {
        self.changes = .{};
    }

    pub fn incrementGeneration(self: *RenderablesSet) void {
        self.generation +%= 1;
    }
};
