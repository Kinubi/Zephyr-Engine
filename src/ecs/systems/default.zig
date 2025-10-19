const std = @import("std");
const Scheduler = @import("../scheduler.zig").Scheduler;
const ecs_world = @import("../world.zig");
const StageHandles = @import("../stage_handles.zig").StageHandles;
const components = @import("../components.zig");
const DenseSet = @import("../component_dense_set.zig").DenseSet;
const log = @import("../../utils/log.zig").log;

pub fn register(world: *ecs_world.World, stages: StageHandles) !void {
    const scheduler = world.schedulerPtr();

    try scheduler.addSystem(stages.simulation, .{
        .name = "transform_integration",
        .context = @ptrCast(&simulation_context),
        .prepare = simulationPrepare,
    });

    try scheduler.addSystem(stages.render_extraction, .{
        .name = "transform_extraction",
        .context = @ptrCast(&extraction_context),
        .prepare = extractionPrepare,
    });
}

const SimulationContext = struct {
    name: []const u8 = "simulate.transforms",
    chunk_size: usize = 256,
};

const ExtractionContext = struct {
    name: []const u8 = "extract.transforms",
    chunk_size: usize = 256,
};

var simulation_context = SimulationContext{};
var extraction_context = ExtractionContext{};

const SimulationJobContext = struct {
    shared: *SimulationShared,
    start: usize,
    end: usize,
};

const SimulationShared = struct {
    velocity_guard: DenseSet(components.Velocity).ReadGuard,
    transform_guard: DenseSet(components.Transform).WriteGuard,
    remaining: std.atomic.Value(u32),
};

fn simulationPrepare(context_ptr: *anyopaque, world_ptr: *anyopaque, builder: *Scheduler.JobBuilder) !void {
    const ctx = castContextPtr(SimulationContext, context_ptr);
    const world = castContextPtr(ecs_world.World, world_ptr);

    const velocity_storage = world.getStorage(components.Velocity) catch |err| {
        log(.WARN, "ecs.simulation", "velocity storage unavailable: {}", .{err});
        return;
    };

    var velocity_guard = velocity_storage.acquireRead();
    const count = velocity_guard.len();
    if (count == 0) {
        velocity_guard.release();
        return;
    }

    const chunk_size = if (ctx.chunk_size == 0) 1 else ctx.chunk_size;
    const chunk_count = (count + chunk_size - 1) / chunk_size;

    if (chunk_count <= 1) {
        const transform_storage = world.getStorage(components.Transform) catch |err| {
            velocity_guard.release();
            log(.WARN, "ecs.simulation", "transform storage unavailable: {}", .{err});
            return;
        };

        var transform_guard = transform_storage.acquireWrite();
        const dt = world.frameDt();

        var i: usize = 0;
        while (i < count) : (i += 1) {
            const entity = velocity_guard.entityAt(i);
            const velocity_ptr = velocity_guard.valueAt(i);

            if (transform_guard.get(entity)) |transform_ptr| {
                const delta = velocity_ptr.linear.scale(dt);
                transform_ptr.translation = transform_ptr.translation.add(delta);
                components.updateLocalToWorld(transform_ptr);
            }
        }

        transform_guard.release();
        velocity_guard.release();
        return;
    }

    const transform_storage = world.getStorage(components.Transform) catch |err| {
        velocity_guard.release();
        log(.WARN, "ecs.simulation", "transform storage unavailable: {}", .{err});
        return;
    };

    const transform_guard = transform_storage.acquireWrite();
    const shared = try builder.allocator.create(SimulationShared);
    shared.* = .{
        .velocity_guard = velocity_guard,
        .transform_guard = transform_guard,
        .remaining = std.atomic.Value(u32).init(@intCast(chunk_count)),
    };

    var spawn_failed = true;
    defer {
        if (spawn_failed) {
            shared.transform_guard.release();
            shared.velocity_guard.release();
        }
    }

    var index: usize = 0;
    while (index < count) : (index += chunk_size) {
        const end = @min(count, index + chunk_size);
        const job_ctx = try builder.allocator.create(SimulationJobContext);
        job_ctx.* = .{
            .shared = shared,
            .start = index,
            .end = end,
        };

        try builder.spawn(.{
            .name = ctx.name,
            .context = @ptrCast(job_ctx),
            .run = simulationRun,
        });
    }

    spawn_failed = false;
}

fn simulationRun(context_ptr: *anyopaque, world_ptr: *anyopaque, job_ctx: Scheduler.JobContext) void {
    _ = job_ctx;
    const chunk = castContextPtr(SimulationJobContext, context_ptr);
    const shared = chunk.shared;
    const world = castContextPtr(ecs_world.World, world_ptr);

    const velocity_guard = &shared.velocity_guard;
    const transform_guard = &shared.transform_guard;
    const dt = world.frameDt();

    var i = chunk.start;
    while (i < chunk.end) : (i += 1) {
        const entity = velocity_guard.entityAt(i);
        const velocity_ptr = velocity_guard.valueAt(i);

        if (transform_guard.get(entity)) |transform_ptr| {
            const delta = velocity_ptr.linear.scale(dt);
            transform_ptr.translation = transform_ptr.translation.add(delta);
            components.updateLocalToWorld(transform_ptr);
        }
    }

    if (shared.remaining.fetchSub(1, .acq_rel) == 1) {
        shared.transform_guard.release();
        shared.velocity_guard.release();
    }
}

const ExtractionJobContext = struct {
    shared: *ExtractionShared,
    start: usize,
    end: usize,
};

const ExtractionShared = struct {
    transform_guard: DenseSet(components.Transform).ReadGuard,
    remaining: std.atomic.Value(u32),
};

fn extractionPrepare(context_ptr: *anyopaque, world_ptr: *anyopaque, builder: *Scheduler.JobBuilder) !void {
    const ctx = castContextPtr(ExtractionContext, context_ptr);
    const world = castContextPtr(ecs_world.World, world_ptr);

    const transform_storage = world.getStorage(components.Transform) catch |err| {
        log(.WARN, "ecs.extraction", "transform storage unavailable: {}", .{err});
        return;
    };

    var transform_guard = transform_storage.acquireRead();
    const count = transform_guard.len();
    if (count == 0) {
        transform_guard.release();
        try world.ensureExtractionCapacity(0);
        return;
    }

    try world.ensureExtractionCapacity(count);

    const chunk_size = if (ctx.chunk_size == 0) 1 else ctx.chunk_size;
    const chunk_count = (count + chunk_size - 1) / chunk_size;

    if (chunk_count <= 1) {
        const positions = world.extractionPositionsMut();
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const transform_ptr = transform_guard.valueAt(i);
            positions[i] = transform_ptr.translation;
        }
        transform_guard.release();
        return;
    }

    const shared = try builder.allocator.create(ExtractionShared);
    shared.* = .{
        .transform_guard = transform_guard,
        .remaining = std.atomic.Value(u32).init(@intCast(chunk_count)),
    };

    var spawn_failed = true;
    defer if (spawn_failed) shared.transform_guard.release();

    var index: usize = 0;
    while (index < count) : (index += chunk_size) {
        const end = @min(count, index + chunk_size);
        const job_ctx = try builder.allocator.create(ExtractionJobContext);
        job_ctx.* = .{
            .shared = shared,
            .start = index,
            .end = end,
        };

        try builder.spawn(.{
            .name = ctx.name,
            .context = @ptrCast(job_ctx),
            .run = extractionRun,
        });
    }

    spawn_failed = false;
}

fn extractionRun(context_ptr: *anyopaque, world_ptr: *anyopaque, job_ctx: Scheduler.JobContext) void {
    _ = job_ctx;
    const chunk = castContextPtr(ExtractionJobContext, context_ptr);
    const shared = chunk.shared;
    const world = castContextPtr(ecs_world.World, world_ptr);

    const transform_guard = &shared.transform_guard;
    const positions = world.extractionPositionsMut();

    var i = chunk.start;
    while (i < chunk.end) : (i += 1) {
        const transform_ptr = transform_guard.valueAt(i);
        positions[i] = transform_ptr.translation;
    }

    if (shared.remaining.fetchSub(1, .acq_rel) == 1) {
        shared.transform_guard.release();
    }
}

fn castContextPtr(comptime T: type, ptr: *anyopaque) *T {
    return @ptrFromInt(@intFromPtr(ptr));
}
