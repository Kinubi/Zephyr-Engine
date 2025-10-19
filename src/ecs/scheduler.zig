const std = @import("std");
const thread_pool = @import("../threading/thread_pool.zig");

pub const Scheduler = struct {
    allocator: std.mem.Allocator,
    thread_pool: *thread_pool.ThreadPool,
    stages: std.ArrayList(Stage),
    config: Config,
    next_work_id: std.atomic.Value(u64),

    pub const Config = struct {
        subsystem_name: []const u8 = "ecs_update",
        min_workers: u32 = 1,
        max_workers: ?u32 = null,
        priority: thread_pool.WorkPriority = .high,
    };

    pub const SystemDescriptor = struct {
        name: []const u8,
        context: *anyopaque,
        prepare: *const fn (*anyopaque, *anyopaque, *JobBuilder) anyerror!void,
    };

    pub const JobDesc = struct {
        name: []const u8,
        context: *anyopaque,
        run: *const fn (*anyopaque, *anyopaque, JobContext) void,
        priority: ?thread_pool.WorkPriority = null,
    };

    pub const JobContext = struct {
        stage_index: usize,
        job_index: u32,
        work_id: u64,
    };

    pub fn init(allocator: std.mem.Allocator, pool: *thread_pool.ThreadPool, config_in: Config) !Scheduler {
        var config = config_in;
        config.max_workers = config.max_workers orelse pool.max_workers;

        try pool.registerSubsystem(.{
            .name = config.subsystem_name,
            .min_workers = config.min_workers,
            .max_workers = config.max_workers.?,
            .priority = config.priority,
            .work_item_type = .ecs_update,
        });

        return .{
            .allocator = allocator,
            .thread_pool = pool,
            .stages = std.ArrayList(Stage).init(allocator),
            .config = config,
            .next_work_id = std.atomic.Value(u64).init(1),
        };
    }

    pub fn deinit(self: *Scheduler) void {
        for (self.stages.items) |*stage| {
            stage.deinit();
        }
        self.stages.deinit();
    }

    pub fn addStage(self: *Scheduler, name: []const u8) !usize {
        const stage = Stage{
            .name = name,
            .systems = std.ArrayList(System).init(self.allocator),
        };
        try self.stages.append(stage);
        return self.stages.items.len - 1;
    }

    pub fn addSystem(self: *Scheduler, stage_index: usize, descriptor: SystemDescriptor) !void {
        if (stage_index >= self.stages.items.len) return error.UnknownStage;
        const system = System{ .descriptor = descriptor };
        try self.stages.items[stage_index].systems.append(system);
    }

    pub fn run(self: *Scheduler, world: *anyopaque) !void {
        var index: usize = 0;
        while (index < self.stages.items.len) : (index += 1) {
            try self.runStage(world, index);
        }
    }

    pub fn runStage(self: *Scheduler, world: *anyopaque, stage_index: usize) !void {
        if (stage_index >= self.stages.items.len) return error.UnknownStage;

        var stage_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer stage_arena.deinit();

        var wait_group = WaitGroup{};
        var job_counter: u32 = 0;
        var builder = JobBuilder{
            .scheduler = self,
            .stage_index = stage_index,
            .wait_group = &wait_group,
            .world = world,
            .job_counter = &job_counter,
            .allocator = stage_arena.allocator(),
        };

        const stage = &self.stages.items[stage_index];
        for (stage.systems.items) |system| {
            try system.descriptor.prepare(system.descriptor.context, world, &builder);
        }

        if (job_counter > 0) {
            _ = self.thread_pool.requestWorkers(.ecs_update, job_counter);
        }

        wait_group.wait();
    }

    fn enqueueJob(self: *Scheduler, desc: JobDesc, world: *anyopaque, wait_group: *WaitGroup, stage_index: usize, job_index: u32, allocator: std.mem.Allocator) !void {
        wait_group.add(1);
        errdefer wait_group.done();

        const payload = try allocator.create(JobPayload);
        payload.* = .{
            .descriptor = desc,
            .world = world,
            .wait_group = wait_group,
            .stage_index = stage_index,
            .job_index = job_index,
        };

        const priority = desc.priority orelse self.config.priority;
        const work_id = self.next_work_id.fetchAdd(1, .monotonic);

        const work_item = thread_pool.WorkItem{
            .id = work_id,
            .item_type = .ecs_update,
            .priority = priority,
            .data = .{ .ecs_update = .{ .stage_index = @intCast(stage_index), .job_index = job_index } },
            .worker_fn = runJob,
            .context = payload,
        };

        if (self.thread_pool.submitWork(work_item)) |_| {} else |err| {
            wait_group.done();
            return err;
        }
    }

    const Stage = struct {
        name: []const u8,
        systems: std.ArrayList(System),

        fn deinit(self: *Stage) void {
            self.systems.deinit();
        }
    };

    const System = struct {
        descriptor: SystemDescriptor,
    };

    pub const JobBuilder = struct {
        scheduler: *Scheduler,
        stage_index: usize,
        wait_group: *WaitGroup,
        world: *anyopaque,
        job_counter: *u32,
        allocator: std.mem.Allocator,

        pub fn spawn(self: *JobBuilder, desc: JobDesc) !void {
            const index = self.job_counter.*;
            self.job_counter.* = index + 1;
            try self.scheduler.enqueueJob(desc, self.world, self.wait_group, self.stage_index, index, self.allocator);
        }
    };

    const JobPayload = struct {
        descriptor: JobDesc,
        world: *anyopaque,
        wait_group: *WaitGroup,
        stage_index: usize,
        job_index: u32,
    };

    fn runJob(context: *anyopaque, work_item: thread_pool.WorkItem) void {
        const payload: *JobPayload = @ptrCast(context);
        const job_ctx = JobContext{
            .stage_index = payload.stage_index,
            .job_index = payload.job_index,
            .work_id = work_item.id,
        };
        payload.descriptor.run(payload.descriptor.context, payload.world, job_ctx);
        payload.wait_group.done();
    }

    const WaitGroup = struct {
        mutex: std.Thread.Mutex = .{},
        cond: std.Thread.Condition = .{},
        counter: usize = 0,

        pub fn add(self: *WaitGroup, delta: usize) void {
            self.mutex.lock();
            self.counter += delta;
            self.mutex.unlock();
        }

        pub fn done(self: *WaitGroup) void {
            self.mutex.lock();
            if (self.counter == 0) {
                self.mutex.unlock();
                return;
            }
            self.counter -= 1;
            if (self.counter == 0) {
                self.cond.broadcast();
            }
            self.mutex.unlock();
        }

        pub fn wait(self: *WaitGroup) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            while (self.counter != 0) {
                self.cond.wait(&self.mutex);
            }
        }
    };
};
