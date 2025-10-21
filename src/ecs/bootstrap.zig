const std = @import("std");
const World = @import("world.zig").World;

pub const StageHandles = struct {
    // Minimal placeholder for stage handles used by app.zig
    pub fn init() StageHandles {
        return StageHandles{};
    }
};

pub fn configureWorld(world: *World) !StageHandles {
    _ = world;
    return StageHandles.init();
}

pub fn tick(world: *World, handles: StageHandles) !void {
    _ = world;
    _ = handles;
    // No-op minimal tick
}
