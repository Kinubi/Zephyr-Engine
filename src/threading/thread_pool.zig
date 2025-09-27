const std = @import("std");

// Import AssetId from the asset system
const AssetId = @import("../assets/asset_types.zig").AssetId;
const log = @import("../utils/log.zig").log;
const LogLevel = @import("../utils/log.zig").LogLevel;

pub const WorkItem = struct {
    asset_id: AssetId,
    loader: *anyopaque, // Will be cast to specific loader type
};

pub const WorkQueue = struct {
    items: std.ArrayList(WorkItem),
    mutex: std.Thread.Mutex = .{},
    len: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) WorkQueue {
        _ = allocator;
        return .{
            .items = std.ArrayList(WorkItem){},
        };
    }

    pub fn deinit(self: *WorkQueue, allocator: std.mem.Allocator) void {
        self.items.deinit(allocator);
    }

    pub fn push(self: *WorkQueue, item: WorkItem, allocator: std.mem.Allocator) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.items.append(allocator, item);
        self.len += 1;
    }

    pub fn pop(self: *WorkQueue) ?WorkItem {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.len == 0) return null;

        const item = self.items.items[0];
        // Move remaining items forward
        for (1..self.len) |i| {
            self.items.items[i - 1] = self.items.items[i];
        }
        self.len -= 1;
        return item;
    }
};

pub const ThreadPool = struct {
    threads: []std.Thread,
    work_queue: WorkQueue,
    running: bool = true,
    shutting_down: std.atomic.Value(bool),
    allocator: std.mem.Allocator,
    threads_ready: std.ArrayList(bool),
    threads_ready_mutex: std.Thread.Mutex = .{},
    ready_count: std.atomic.Value(u32),
    worker_fn: *const fn (*ThreadPool, usize) void,

    const WorkerContext = struct {
        pool: *ThreadPool,
        worker_id: usize,
    };

    fn genericWorkerThread(context: WorkerContext) void {
        context.pool.worker_fn(context.pool, context.worker_id);
    }

    pub fn init(allocator: std.mem.Allocator, worker_count: u32, comptime worker_fn: anytype) !ThreadPool {
        log(.INFO, "thread_pool", "Starting with {} worker threads...", .{worker_count});

        var pool = ThreadPool{
            .threads = try allocator.alloc(std.Thread, worker_count),
            .work_queue = WorkQueue.init(allocator),
            .running = true,
            .shutting_down = std.atomic.Value(bool).init(false),
            .allocator = allocator,
            .threads_ready = std.ArrayList(bool){},
            .ready_count = std.atomic.Value(u32).init(0),
            .threads_ready_mutex = std.Thread.Mutex{},
            .worker_fn = worker_fn,
        };

        // Initialize threads_ready array
        for (0..worker_count) |_| {
            try pool.threads_ready.append(allocator, false);
        }

        // Start worker threads
        for (pool.threads, 0..) |*thread, i| {
            thread.* = try std.Thread.spawn(.{}, genericWorkerThread, .{WorkerContext{ .pool = &pool, .worker_id = i }});
        }

        // Wait for all threads to become ready
        log(.DEBUG, "thread_pool", "Waiting for {d} worker threads to become ready...", .{worker_count});
        while (pool.ready_count.load(.acquire) < worker_count) {
            std.Thread.sleep(std.time.ns_per_ms * 1); // 1ms sleep
        }
        log(.INFO, "thread_pool", "All {d} worker threads are ready!", .{worker_count});

        return pool;
    }

    pub fn deinit(self: *ThreadPool) void {
        // Signal shutdown to prevent threads from accessing deallocated memory
        self.shutting_down.store(true, .release);

        // Signal all threads to stop under mutex protection
        self.work_queue.mutex.lock();
        self.running = false;
        // Clear any existing jobs to avoid processing them during shutdown
        self.work_queue.len = 0;
        self.work_queue.mutex.unlock();

        log(.INFO, "thread_pool", "Shutting down {} worker threads...", .{self.threads.len});

        // Join all threads to ensure clean shutdown
        for (self.threads) |thread| {
            thread.join();
        }

        self.work_queue.deinit(self.allocator);
        self.threads_ready.deinit(self.allocator);
        self.allocator.free(self.threads);

        log(.INFO, "thread_pool", "All worker threads shut down cleanly", .{});
    }

    pub fn submitWork(self: *ThreadPool, work_item: WorkItem) !void {
        if (!self.running) return error.ThreadPoolNotRunning;

        // Check if we have any ready threads
        const ready_count = self.ready_count.load(.acquire);
        if (ready_count == 0) {
            log(.WARN, "thread_pool", "WARNING: No ready worker threads available for work item", .{});
            return error.NoWorkerThreadsAvailable;
        }

        try self.work_queue.push(work_item, self.allocator);
    }

    /// Check if the thread pool has available worker threads
    pub fn hasAvailableWorkers(self: *const ThreadPool) bool {
        return self.running and self.ready_count.load(.acquire) > 0;
    }

    /// Mark thread as ready (called by worker threads)
    pub fn markThreadReady(self: *ThreadPool) void {
        const ready = self.ready_count.fetchAdd(1, .monotonic) + 1;
        log(.DEBUG, "thread_pool", "Thread ready! ({}/{})", .{ ready, self.threads.len });

        if (ready == self.threads.len) {
            log(.INFO, "thread_pool", "All {} worker threads are ready!", .{self.threads.len});
        }
    }

    /// Mark thread as shutting down (called by worker threads)
    pub fn markThreadShuttingDown(self: *ThreadPool, worker_id: usize) void {
        // Don't access threads_ready if we're already shutting down
        if (self.shutting_down.load(.acquire)) {
            log(.DEBUG, "thread_pool", "Worker {d} shutting down (pool already deallocating)", .{worker_id});
            return;
        }

        self.threads_ready_mutex.lock();
        defer self.threads_ready_mutex.unlock();

        // Double-check after acquiring the mutex
        if (self.shutting_down.load(.acquire)) {
            log(.DEBUG, "thread_pool", "Worker {d} shutting down (pool already deallocating)", .{worker_id});
            return;
        }

        if (worker_id < self.threads_ready.items.len and self.threads_ready.items[worker_id]) {
            self.threads_ready.items[worker_id] = false;
            const old_count = self.ready_count.fetchSub(1, .acq_rel);
            if (old_count > 0) {
                log(.DEBUG, "thread_pool", "Worker {d} shutting down (ready count: {d})", .{ worker_id, old_count - 1 });
            }
        }
    }

    /// Get work from the queue (called by worker threads)
    pub fn getWork(self: *ThreadPool) ?WorkItem {
        return self.work_queue.pop();
    }
};
