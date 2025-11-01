const std = @import("std");
const World = @import("world.zig").World;
const ThreadPool = @import("../threading/thread_pool.zig").ThreadPool;
const WorkItem = @import("../threading/thread_pool.zig").WorkItem;
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
    // Last-worker completion semaphore: posted exactly once when all jobs finish
    done_sem: std.Thread.Semaphore,
    allocator: std.mem.Allocator,
    // Reusable storage to avoid per-frame allocations for work items
    items_cache: std.ArrayList(WorkItem),

    pub fn init(allocator: std.mem.Allocator, name: []const u8) SystemStage {
        return .{
            .name = name,
            .systems = std.ArrayList(SystemDef){},
            .completion = std.atomic.Value(usize).init(0),
            .done_sem = .{},
            .allocator = allocator,
            .items_cache = std.ArrayList(WorkItem){},
        };
    }

    pub fn deinit(self: *SystemStage) void {
        self.systems.deinit(self.allocator);
        self.items_cache.deinit(self.allocator);
    }

    /// Add a system to this stage
    pub fn addSystem(self: *SystemStage, system: SystemDef) !void {
        try self.systems.append(self.allocator, system);
    }

    /// Execute all systems in this stage in parallel
    pub fn execute(self: *SystemStage, world: *World, dt: f32, thread_pool: ?*ThreadPool, work_id_counter: *std.atomic.Value(u64)) !void {
        // Quick timing instrumentation to compare sequential vs parallel execution
        const start_us = std.time.microTimestamp();
        const mode: []const u8 = "parallel";
        defer {
            const elapsed = std.time.microTimestamp() - start_us;
            log(.INFO, "system_scheduler", "Stage '{s}' executed in {} us (mode={s})", .{ self.name, elapsed, mode });
        }
        const system_count = self.systems.items.len;
        if (system_count == 0) return;

        // Small-stage fast path: sequential is cheaper than dispatch
        if (system_count <= 2 or thread_pool == null) {
            for (self.systems.items) |system| {
                try system.update_fn(world, dt);
            }
            return;
        }

        const pool = thread_pool.?;

        // Initialize completion counter
        self.completion.store(system_count, .release);

        // Build a stage-scoped immutable context and dispatch one job per system
        var stage_ctx = StageContext{
            .world = world,
            .dt = dt,
            .systems = self.systems.items,
            .completion = &self.completion,
            .done_sem = &self.done_sem,
        };

        // Prepare/reuse batch of work items to reduce submit overhead and allocations
        try self.items_cache.ensureTotalCapacity(self.allocator, system_count);
        self.items_cache.clearRetainingCapacity();

        var i: usize = 0;
        while (i < system_count) : (i += 1) {
            self.items_cache.appendAssumeCapacity(.{
                .id = work_id_counter.fetchAdd(1, .monotonic),
                .item_type = .ecs_update,
                .priority = .high, // System updates are frame-critical
                .data = .{ .ecs_update = .{ .stage_index = 0, .job_index = @intCast(i) } },
                .worker_fn = systemWorker,
                .context = &stage_ctx,
            });
        }
        try pool.submitBatch(self.items_cache.items);

        // Wait exactly once for stage completion: last worker posts
        self.done_sem.wait();
    }
};

/// Immutable, stage-scoped context shared by all system jobs in a stage
const StageContext = struct {
    world: *World,
    dt: f32,
    systems: []const SystemDef,
    completion: *std.atomic.Value(usize),
    done_sem: *std.Thread.Semaphore,
};

/// Worker function for parallel system execution
fn systemWorker(context: *anyopaque, work_item: @import("../threading/thread_pool.zig").WorkItem) void {
    const ctx = @as(*StageContext, @ptrCast(@alignCast(context)));
    const job_index: usize = @intCast(work_item.data.ecs_update.job_index);
    defer {
        const prev = ctx.completion.fetchSub(1, .release);
        if (prev == 1) ctx.done_sem.post();
    }

    const sys = ctx.systems[job_index];
    sys.update_fn(ctx.world, ctx.dt) catch |err| {
        log(.ERROR, "system_scheduler", "System '{s}' failed with error: {}", .{ sys.name, err });
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
