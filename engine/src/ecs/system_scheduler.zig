const std = @import("std");
const World = @import("world.zig").World;
const ThreadPool = @import("../threading/thread_pool.zig").ThreadPool;
const log = @import("../utils/log.zig").log;

/// Component types that systems can read/write
/// Used for dependency analysis
pub const ComponentAccess = struct {
    /// Components this system reads (shared access allowed)
    reads: []const []const u8,
    /// Components this system writes (exclusive access required)
    writes: []const []const u8,
};

/// System function signature
pub const SystemFn = *const fn (*World, f32) anyerror!void;

/// System definition with metadata
pub const SystemDef = struct {
    name: []const u8,
    update_fn: SystemFn,
    access: ComponentAccess,
};

/// Parallel system execution stage
/// Systems in the same stage can run concurrently
pub const SystemStage = struct {
    name: []const u8,
    systems: std.ArrayList(SystemDef),
    completion: std.atomic.Value(usize),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8) SystemStage {
        return .{
            .name = name,
            .systems = std.ArrayList(SystemDef){},
            .completion = std.atomic.Value(usize).init(0),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SystemStage) void {
        self.systems.deinit(self.allocator);
    }

    /// Add a system to this stage
    pub fn addSystem(self: *SystemStage, system: SystemDef) !void {
        try self.systems.append(self.allocator, system);
    }

    /// Execute all systems in this stage in parallel
    pub fn execute(self: *SystemStage, world: *World, dt: f32, thread_pool: ?*ThreadPool, work_id_counter: *std.atomic.Value(u64)) !void {
        const system_count = self.systems.items.len;
        if (system_count == 0) return;

        // Single system - no parallelization needed
        if (system_count == 1) {
            try self.systems.items[0].update_fn(world, dt);
            return;
        }

        // No thread pool - fallback to sequential execution
        if (thread_pool == null) {
            for (self.systems.items) |system| {
                try system.update_fn(world, dt);
            }
            return;
        }

        const pool = thread_pool.?;

        // Reset completion counter
        self.completion.store(system_count, .release);

        // Submit all systems as work items
        for (self.systems.items) |system| {
            const work_context = try pool.allocator.create(SystemWorkContext);
            work_context.* = .{
                .world = world,
                .dt = dt,
                .update_fn = system.update_fn,
                .completion = &self.completion,
                .system_name = system.name,
                .allocator = pool.allocator,
            };

            try pool.submitWork(.{
                .id = work_id_counter.fetchAdd(1, .monotonic),
                .item_type = .ecs_update,
                .priority = .high, // System updates are frame-critical
                .data = .{
                    .ecs_update = .{
                        .stage_index = 0,
                        .job_index = 0,
                    },
                },
                .worker_fn = systemWorker,
                .context = work_context,
            });
        }

        // Wait for all systems to complete
        while (self.completion.load(.acquire) > 0) {
            std.Thread.yield() catch {};
        }
    }
};

/// Context for system worker thread
const SystemWorkContext = struct {
    world: *World,
    dt: f32,
    update_fn: SystemFn,
    completion: *std.atomic.Value(usize),
    system_name: []const u8,
    allocator: std.mem.Allocator,
};

/// Worker function for parallel system execution
fn systemWorker(context: *anyopaque, work_item: @import("../threading/thread_pool.zig").WorkItem) void {
    _ = work_item;
    const ctx = @as(*SystemWorkContext, @ptrCast(@alignCast(context)));
    defer {
        _ = ctx.completion.fetchSub(1, .release);
        // Free the work context allocated for this job
        ctx.allocator.destroy(ctx);
    }

    ctx.update_fn(ctx.world, ctx.dt) catch |err| {
        // Use correct string placeholder for system_name and keep error formatting
        log(.ERROR, "system_scheduler", "System '{s}' failed with error: {}", .{ ctx.system_name, err });
        // System failure doesn't crash the frame - log and continue
    };
}

/// System scheduler manages parallel execution of ECS systems
pub const SystemScheduler = struct {
    allocator: std.mem.Allocator,
    stages: std.ArrayList(SystemStage),
    thread_pool: ?*ThreadPool,
    work_id_counter: std.atomic.Value(u64),

    pub fn init(allocator: std.mem.Allocator, thread_pool: ?*ThreadPool) SystemScheduler {
        return .{
            .allocator = allocator,
            .stages = std.ArrayList(SystemStage){},
            .thread_pool = thread_pool,
            .work_id_counter = std.atomic.Value(u64).init(0),
        };
    }

    pub fn deinit(self: *SystemScheduler) void {
        for (self.stages.items) |*stage| {
            stage.deinit();
        }
        self.stages.deinit(self.allocator);
    }

    /// Add a new stage to the scheduler
    pub fn addStage(self: *SystemScheduler, name: []const u8) !*SystemStage {
        const stage = SystemStage.init(self.allocator, name);
        try self.stages.append(self.allocator, stage);
        return &self.stages.items[self.stages.items.len - 1];
    }

    /// Execute all stages sequentially (systems within each stage run in parallel)
    pub fn execute(self: *SystemScheduler, world: *World, dt: f32) !void {
        for (self.stages.items) |*stage| {
            try stage.execute(world, dt, self.thread_pool, &self.work_id_counter);
        }
    }

    /// Build a default scheduler with common system stages
    pub fn buildDefault(allocator: std.mem.Allocator, thread_pool: ?*ThreadPool) !SystemScheduler {
        var scheduler = SystemScheduler.init(allocator, thread_pool);
        errdefer scheduler.deinit();

        // Stage 1: Independent systems that can run in parallel
        // (Transform, Animation, Particle updates)
        _ = try scheduler.addStage("ParallelUpdates");

        // Stage 2: Systems that depend on Stage 1
        // (Physics, Collision detection)
        _ = try scheduler.addStage("PhysicsAndCollision");

        // Stage 3: Render preparation
        // (Frustum culling, LOD selection, render data extraction)
        _ = try scheduler.addStage("RenderPreparation");

        return scheduler;
    }
};

/// Helper to check if two systems can run in parallel
pub fn canRunInParallel(system_a: SystemDef, system_b: SystemDef) bool {
    // Check for write-write conflicts
    for (system_a.access.writes) |write_a| {
        for (system_b.access.writes) |write_b| {
            if (std.mem.eql(u8, write_a, write_b)) {
                return false; // Both write same component
            }
        }
    }

    // Check for write-read conflicts
    for (system_a.access.writes) |write_a| {
        for (system_b.access.reads) |read_b| {
            if (std.mem.eql(u8, write_a, read_b)) {
                return false; // A writes, B reads
            }
        }
    }

    for (system_b.access.writes) |write_b| {
        for (system_a.access.reads) |read_a| {
            if (std.mem.eql(u8, write_b, read_a)) {
                return false; // B writes, A reads
            }
        }
    }

    // No conflicts - can run in parallel
    return true;
}
