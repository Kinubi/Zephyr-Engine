const std = @import("std");
const ecs_world = @import("world.zig");
const StageHandles = @import("stage_handles.zig").StageHandles;
const systems_default = @import("systems/default.zig");
const components = @import("components.zig");
const Math = @import("../utils/math.zig");

pub fn configureWorld(world: *ecs_world.World) !StageHandles {
    const scheduler = world.schedulerPtr();

    const asset_resolve = try scheduler.addStage("asset_resolve");
    const input_script = try scheduler.addStage("input_script");
    const simulation = try scheduler.addStage("physics_animation");
    const visibility = try scheduler.addStage("visibility");
    const render_extraction = try scheduler.addStage("render_extraction");
    const presentation = try scheduler.addStage("presentation");

    const handles = StageHandles{
        .asset_resolve = asset_resolve,
        .input_script = input_script,
        .simulation = simulation,
        .visibility = visibility,
        .render_extraction = render_extraction,
        .presentation = presentation,
    };

    try systems_default.register(world, handles);
    try seedWorld(world);
    return handles;
}

pub fn tick(world: *ecs_world.World, stages: StageHandles) !void {
    _ = stages;
    const scheduler = world.schedulerPtr();
    const world_ptr: *anyopaque = @ptrCast(world);
    try scheduler.run(world_ptr);
}

fn seedWorld(world: *ecs_world.World) !void {
    const entity = world.createEntity(0);
    const transform = components.Transform.init(Math.Vec3.zero(), Math.Vec3.zero(), Math.Vec3.init(1, 1, 1));
    _ = try world.addComponent(entity, transform);

    const velocity = components.Velocity{ .linear = Math.Vec3.init(0.15, 0.0, 0.0) };
    _ = try world.addComponent(entity, velocity);
}
