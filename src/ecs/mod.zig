pub const entity = @import("entity_registry.zig");
pub const storage = @import("component_dense_set.zig");
pub const scheduler = @import("scheduler.zig");
pub const world = @import("world.zig");
pub const bootstrap = @import("bootstrap.zig");
pub const components = @import("components.zig");
pub const stage_handles = @import("stage_handles.zig");
pub const systems = struct {
    pub const defaults = @import("systems/default.zig");
};
