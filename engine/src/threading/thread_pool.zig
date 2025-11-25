const std = @import("std");

// Import AssetId from the asset system
const AssetId = @import("../assets/asset_types.zig").AssetId;
const log = @import("../utils/log.zig").log;
const LogLevel = @import("../utils/log.zig").LogLevel;
const AssetLoader = @import("../assets/asset_loader.zig").AssetLoader;
const AssetManager = @import("../assets/asset_manager.zig").AssetManager;

/// Thread-local pointer to the current worker info (if running on a worker thread)
threadlocal var tls_worker_info: ?*WorkerInfo = null;

/// Work item types for different subsystems
pub const WorkItemType = enum {
    asset_loading,
    hot_reload,
    bvh_building,
    compute_task,
    ecs_update,
    gpu_work,
    custom,
    render_extraction, // Parallel ECS queries and cache building
};

/// Priority levels for work items
pub const WorkPriority = enum(u8) {
    low = 0,
    normal = 1,
    high = 2,
    critical = 3,
};

/// BVH acceleration structure types
pub const BvhAccelerationStructureType = enum {
    blas, // Bottom Level Acceleration Structure - geometry data
    tlas, // Top Level Acceleration Structure - instance data
};

/// BVH rebuild types
pub const BvhRebuildType = enum {
    full_rebuild,
    partial_update,
    instance_only,
};

/// Generic work item that can represent different types of work
pub const WorkItem = struct {
    // Common fields
    id: u64, // Unique work item ID
    item_type: WorkItemType,
    priority: WorkPriority,

    // Type-specific data
    data: WorkData,

    // Worker context and execution function
    worker_fn: *const fn (*anyopaque, WorkItem) void,
    context: *anyopaque,

    const WorkData = union(WorkItemType) {
        asset_loading: AssetLoadingData,
        hot_reload: HotReloadData,
        bvh_building: BvhBuildingData,
        compute_task: ComputeTaskData,
        ecs_update: EcsUpdateData,
        gpu_work: GpuWorkData,
        custom: CustomData,
        render_extraction: RenderExtractionData,
    };

    const AssetLoadingData = struct {
        asset_id: AssetId,
        loader: *anyopaque,
    };

    const HotReloadData = struct {
        file_path: []const u8,
        asset_id: AssetId,
    };

    const BvhBuildingData = struct {
        as_type: BvhAccelerationStructureType,
        work_data: *anyopaque, // For BLAS: points to GeometryData, For TLAS: points to BLASs array
        rebuild_type: BvhRebuildType,
    };

    const ComputeTaskData = struct {
        task_data: *anyopaque,
        thread_group_size: struct { x: u32, y: u32, z: u32 },
    };

    const GpuWorkData = struct {
        staging_type: GPUWork,
        asset_id: AssetId,
        data: *anyopaque, // Points to TextureStaging or MeshStaging
    };

    const EcsUpdateData = struct {
        stage_index: u32,
        job_index: u32,
    };

    const RenderExtractionData = struct {
        chunk_index: u32,
        total_chunks: u32,
        user_data: *anyopaque, // Points to work context
    };

    const CustomData = struct {
        user_data: *anyopaque,
        size: usize,
    };
};

/// Thread-safe, blocking priority queue backed by ring buffers and a semaphore
pub const WorkQueue = struct {
    const Ring = struct {
        buf: []WorkItem = &[_]WorkItem{},
        head: usize = 0,
        tail: usize = 0,
        count: usize = 0,

        fn init(allocator: std.mem.Allocator, cap_init: usize) !Ring {
            var r: Ring = .{};
            r.buf = try allocator.alloc(WorkItem, cap_init);
            r.head = 0;
            r.tail = 0;
            r.count = 0;
            return r;
        }

        fn deinit(self: *Ring, allocator: std.mem.Allocator) void {
            allocator.free(self.buf);
            self.* = .{};
        }

        fn capacity(self: *const Ring) usize {
            return self.buf.len;
        }

        fn grow(self: *Ring, allocator: std.mem.Allocator) !void {
            const old_cap = self.buf.len;
            const new_cap = @max(@as(usize, 16), old_cap * 2);
            var new_buf = try allocator.alloc(WorkItem, new_cap);
            // Move existing items in order to new buffer
            var i: usize = 0;
            while (i < self.count) : (i += 1) {
                const idx = (self.head + i) % old_cap;
                new_buf[i] = self.buf[idx];
            }
            allocator.free(self.buf);
            self.buf = new_buf;
            self.head = 0;
            self.tail = self.count;
        }

        fn push(self: *Ring, allocator: std.mem.Allocator, item: WorkItem) !void {
            if (self.count == self.capacity()) try self.grow(allocator);
            self.buf[self.tail] = item;
            self.tail = (self.tail + 1) % self.capacity();
            self.count += 1;
        }

        fn pop(self: *Ring) ?WorkItem {
            if (self.count == 0) return null;
            const item = self.buf[self.head];
            self.head = (self.head + 1) % self.capacity();
            self.count -= 1;
            return item;
        }

        fn pop_tail(self: *Ring) ?WorkItem {
            if (self.count == 0) return null;
            self.tail = (self.tail + self.capacity() - 1) % self.capacity();
            const item = self.buf[self.tail];
            self.count -= 1;
            return item;
        }
    };

    // One ring per priority level
    critical_ring: Ring,
    high_ring: Ring,
    normal_ring: Ring,
    low_ring: Ring,

    mutex: std.Thread.Mutex = .{},
    total_items: std.atomic.Value(u32),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !WorkQueue {
        // Default initial capacity per ring
        const cap: usize = 256; // Reduced default capacity since we have per-worker queues
        return .{
            .critical_ring = try Ring.init(allocator, cap),
            .high_ring = try Ring.init(allocator, cap),
            .normal_ring = try Ring.init(allocator, cap),
            .low_ring = try Ring.init(allocator, cap),
            .total_items = std.atomic.Value(u32).init(0),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *WorkQueue) void {
        self.critical_ring.deinit(self.allocator);
        self.high_ring.deinit(self.allocator);
        self.normal_ring.deinit(self.allocator);
        self.low_ring.deinit(self.allocator);
    }

    inline fn pickRing(self: *WorkQueue, priority: WorkPriority) *Ring {
        return switch (priority) {
            .critical => &self.critical_ring,
            .high => &self.high_ring,
            .normal => &self.normal_ring,
            .low => &self.low_ring,
        };
    }

    pub fn push(self: *WorkQueue, item: WorkItem) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.pickRing(item.priority).push(self.allocator, item);
        _ = self.total_items.fetchAdd(1, .monotonic);
    }

    /// Push a batch of items while holding the lock once; returns number pushed
    pub fn pushBatch(self: *WorkQueue, items: []const WorkItem) !u32 {
        self.mutex.lock();
        defer self.mutex.unlock();

        var pushed: u32 = 0;
        for (items) |it| {
            try self.pickRing(it.priority).push(self.allocator, it);
            pushed += 1;
        }
        _ = self.total_items.fetchAdd(pushed, .monotonic);
        return pushed;
    }

    /// Non-blocking pop in priority order (FIFO - for stealing); returns null if empty
    pub fn pop(self: *WorkQueue) ?WorkItem {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Try critical first, then high, normal, low
        if (self.critical_ring.pop()) |it| {
            _ = self.total_items.fetchSub(1, .monotonic);
            return it;
        }
        if (self.high_ring.pop()) |it| {
            _ = self.total_items.fetchSub(1, .monotonic);
            return it;
        }
        if (self.normal_ring.pop()) |it| {
            _ = self.total_items.fetchSub(1, .monotonic);
            return it;
        }
        if (self.low_ring.pop()) |it| {
            _ = self.total_items.fetchSub(1, .monotonic);
            return it;
        }
        return null;
    }

    /// Non-blocking pop from tail (LIFO - for owner); returns null if empty
    pub fn pop_tail(self: *WorkQueue) ?WorkItem {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Try critical first, then high, normal, low
        // Note: Even for LIFO, we respect priority order
        if (self.critical_ring.pop_tail()) |it| {
            _ = self.total_items.fetchSub(1, .monotonic);
            return it;
        }
        if (self.high_ring.pop_tail()) |it| {
            _ = self.total_items.fetchSub(1, .monotonic);
            return it;
        }
        if (self.normal_ring.pop_tail()) |it| {
            _ = self.total_items.fetchSub(1, .monotonic);
            return it;
        }
        if (self.low_ring.pop_tail()) |it| {
            _ = self.total_items.fetchSub(1, .monotonic);
            return it;
        }
        return null;
    }

    pub fn size(self: *WorkQueue) u32 {
        return self.total_items.load(.acquire);
    }

    pub fn isEmpty(self: *WorkQueue) bool {
        return self.size() == 0;
    }
};

/// Worker thread state
pub const WorkerState = enum(u8) {
    sleeping = 0, // No work assigned, thread sleeping
    working = 1, // Currently executing a work item
    idle = 2, // Ready for work but no work available
    shutting_down = 3,
};

/// Individual worker thread info
pub const WorkerInfo = struct {
    thread: ?std.Thread = null,
    state: std.atomic.Value(WorkerState),
    last_work_time: std.atomic.Value(i64), // timestamp of last work completion
    work_items_completed: std.atomic.Value(u32),
    worker_id: u32,
    pool: *ThreadPool,
    local_queue: *WorkQueue, // Per-worker queue for work stealing

    pub fn init(worker_id: u32, pool: *ThreadPool) WorkerInfo {
        return .{
            .state = std.atomic.Value(WorkerState).init(.sleeping),
            .last_work_time = std.atomic.Value(i64).init(std.time.milliTimestamp()), // Initialize to current time
            .work_items_completed = std.atomic.Value(u32).init(0),
            .worker_id = worker_id,
            .pool = pool,
            .local_queue = undefined, // Initialized in ThreadPool.init
        };
    }

    pub fn isActive(self: *const WorkerInfo) bool {
        const state = self.state.load(.acquire);
        return state == .working or state == .idle;
    }

    pub fn getIdleTime(self: *const WorkerInfo) i64 {
        const last_work = self.last_work_time.load(.acquire);
        if (last_work == 0) return 0;
        return std.time.milliTimestamp() - last_work;
    }
};

/// Subsystem registration for requesting workers
pub const SubsystemConfig = struct {
    name: []const u8,
    min_workers: u32, // Minimum guaranteed workers
    max_workers: u32, // Maximum workers this subsystem can use
    priority: WorkPriority, // Default priority for this subsystem's work
    work_item_type: WorkItemType,
};

/// Enhanced ThreadPool with dynamic worker allocation
///
/// TODO(FEATURE): WORK-STEALING JOB QUEUE - MEDIUM PRIORITY
/// Current ThreadPool uses mutex-based priority queues. Add work-stealing for better load balancing.
///
/// Current issues:
/// - Mutex contention on queue push/pop (bottleneck at high concurrency)
/// - Uneven work distribution (some workers idle while others busy)
/// - Priority inversion (high-priority work stuck behind mutex)
///
/// Work-stealing design:
/// - Per-worker deque (double-ended queue)
/// - Owner pushes/pops from tail (lock-free)
/// - Stealers pop from head (lock-free CAS)
/// - Idle workers steal from random busy workers
///
/// Required changes:
/// - Add engine/src/threading/work_stealing_queue.zig
/// - Replace WorkQueue with per-worker deques in ThreadPool
/// - Update worker loop to check local queue first, then steal
///
/// Benefits: Lower contention, better load balancing, higher throughput
/// Complexity: MEDIUM - lock-free data structures + steal logic
/// Branch: features/work-stealing
///
/// TODO(FEATURE): FIBER-BASED JOB SYSTEM - LOW PRIORITY
/// Add fiber support for lightweight tasks and cooperative scheduling.
///
/// Current issues:
/// - Thread pool workers block on sync primitives (wasted CPU)
/// - Cannot suspend job mid-execution (e.g., wait for asset)
/// - Limited parallelism (8 workers max)
///
/// Fiber features:
/// - Lightweight context switching (no kernel involvement)
/// - Suspend on resource wait, resume when ready
/// - Thousands of fibers per worker thread
///
/// Required changes:
/// - Add engine/src/threading/fiber.zig
/// - Add fiber scheduler to ThreadPool
/// - Update async operations to use fibers
///
/// Benefits: Higher CPU utilization, more parallelism, simpler async code
/// Complexity: HIGH - assembly for context switching + scheduler
/// Branch: features/fiber-system
pub const ThreadPool = struct {
    // Core configuration
    allocator: std.mem.Allocator,
    max_workers: u32,
    current_worker_count: std.atomic.Value(u32),

    // Worker management
    workers: []WorkerInfo,
    work_queue: *WorkQueue, // Global queue for overflow/external work
    work_available: std.Thread.Semaphore = .{}, // Global semaphore for all work

    // Pool state
    running: bool,
    shutting_down: std.atomic.Value(bool),

    // Subsystem management
    registered_subsystems: std.HashMap(WorkItemType, SubsystemConfig, std.hash_map.AutoContext(WorkItemType), 80),
    subsystem_demands: std.HashMap(WorkItemType, u32, std.hash_map.AutoContext(WorkItemType), 80), // Current demand per subsystem
    active_workers_per_subsystem: std.HashMap(WorkItemType, u32, std.hash_map.AutoContext(WorkItemType), 80), // Currently active workers per subsystem
    subsystems_mutex: std.Thread.Mutex = .{}, // Protects HashMap operations
    track_active_per_subsystem: bool = false, // Optional: disable to remove per-job lock overhead

    // Statistics and monitoring
    stats: PoolStatistics,
    stats_mutex: std.Thread.Mutex = .{},

    // Dynamic scaling parameters
    scale_up_threshold: f32 = 0.8, // Scale up when queue utilization > 80%
    scale_down_threshold: f32 = 0.3, // Scale down when utilization < 30%
    idle_timeout_ms: i64 = 5000, // Shutdown workers idle for 5+ seconds
    last_scale_check: std.atomic.Value(i64),

    // Callbacks
    on_worker_count_changed: ?*const fn (u32, u32) void = null, // (old_count, new_count)
    thread_exit_hook: ?ThreadExitHook = null,

    pub const PoolStatistics = struct {
        total_work_items_processed: std.atomic.Value(u64),
        total_work_items_failed: std.atomic.Value(u64),
        peak_worker_count: std.atomic.Value(u32),
        current_queue_size: std.atomic.Value(u32),
        average_work_time_us: std.atomic.Value(u64),

        pub fn init() PoolStatistics {
            return .{
                .total_work_items_processed = std.atomic.Value(u64).init(0),
                .total_work_items_failed = std.atomic.Value(u64).init(0),
                .peak_worker_count = std.atomic.Value(u32).init(0),
                .current_queue_size = std.atomic.Value(u32).init(0),
                .average_work_time_us = std.atomic.Value(u64).init(0),
            };
        }
    };

    const ThreadExitHook = struct {
        callback: *const fn (*anyopaque) void,
        context: *anyopaque,
    };

    pub fn init(allocator: std.mem.Allocator, max_workers: u32) !ThreadPool {
        log(.INFO, "enhanced_thread_pool", "Initializing ThreadPool with max {} workers", .{max_workers});

        const workers = try allocator.alloc(WorkerInfo, max_workers);

        // Initialize all worker slots (but don't start threads yet)
        for (workers, 0..) |*worker, i| {
            worker.* = WorkerInfo.init(@intCast(i), undefined); // Will set pool pointer after struct creation
            // Create local queue
            const local_q = try allocator.create(WorkQueue);
            local_q.* = try WorkQueue.init(allocator);
            worker.local_queue = local_q;
        }

        const work_queue = try allocator.create(WorkQueue);
        work_queue.* = try WorkQueue.init(allocator);

        const pool = ThreadPool{
            .allocator = allocator,
            .max_workers = max_workers,
            .current_worker_count = std.atomic.Value(u32).init(0),
            .workers = workers,
            .work_queue = work_queue,
            .work_available = .{},
            .running = false,
            .shutting_down = std.atomic.Value(bool).init(false),
            .registered_subsystems = std.HashMap(WorkItemType, SubsystemConfig, std.hash_map.AutoContext(WorkItemType), 80).init(allocator),
            .subsystem_demands = std.HashMap(WorkItemType, u32, std.hash_map.AutoContext(WorkItemType), 80).init(allocator),
            .active_workers_per_subsystem = std.HashMap(WorkItemType, u32, std.hash_map.AutoContext(WorkItemType), 80).init(allocator),
            .stats = PoolStatistics.init(),
            .last_scale_check = std.atomic.Value(i64).init(0),
        };

        return pool;
    }

    pub fn deinit(self: *ThreadPool) void {
        self.shutdown();

        // Free local queues
        for (self.workers) |*worker| {
            worker.local_queue.deinit();
            self.allocator.destroy(worker.local_queue);
        }

        self.work_queue.deinit();
        self.allocator.destroy(self.work_queue); // Free the work_queue pointer
        self.registered_subsystems.deinit();
        self.subsystem_demands.deinit();
        self.active_workers_per_subsystem.deinit();
        self.allocator.free(self.workers);

        log(.INFO, "enhanced_thread_pool", "ThreadPool deinitialized", .{});
    }

    /// Register a subsystem that can request workers
    pub fn registerSubsystem(self: *ThreadPool, config: SubsystemConfig) !void {
        try self.registered_subsystems.put(config.work_item_type, config);
        try self.subsystem_demands.put(config.work_item_type, 0);
        try self.active_workers_per_subsystem.put(config.work_item_type, 0);

        log(.INFO, "enhanced_thread_pool", "Registered subsystem '{s}' (min: {}, max: {})", .{ config.name, config.min_workers, config.max_workers });
    }

    /// Start the thread pool with initial worker count
    pub fn start(self: *ThreadPool, initial_workers: u32) !void {
        if (self.running) {
            log(.WARN, "enhanced_thread_pool", "ThreadPool already running", .{});
            return;
        }

        self.running = true;
        self.last_scale_check.store(std.time.milliTimestamp(), .release);

        // Start initial workers
        const workers_to_start = @min(initial_workers, self.max_workers);
        try self.scaleWorkers(workers_to_start);

        log(.INFO, "enhanced_thread_pool", "ThreadPool started with {} workers", .{workers_to_start});
    }

    /// Request workers for a specific subsystem
    pub fn requestWorkers(self: *ThreadPool, subsystem_type: WorkItemType, requested_count: u32) u32 {
        if (!self.running) return 0;

        self.subsystems_mutex.lock();
        defer self.subsystems_mutex.unlock();

        // Get subsystem configuration
        const subsystem_config = self.registered_subsystems.get(subsystem_type) orelse return 0;

        // Update demand tracking for this subsystem
        self.subsystem_demands.put(subsystem_type, requested_count) catch {};

        // Calculate actual allocation based on subsystem limits and current usage
        const current_active = self.active_workers_per_subsystem.get(subsystem_type) orelse 0;
        const max_allowed = subsystem_config.max_workers;
        const can_allocate = if (max_allowed > current_active) max_allowed - current_active else 0;
        const allocated = @min(@min(requested_count, can_allocate), max_allowed);

        // Check if we need to scale up the total worker pool
        const current_total_workers = self.current_worker_count.load(.acquire);
        const total_demand = self.calculateTotalDemandLocked();
        const minimum_needed = self.calculateMinimumWorkersLocked();

        // Determine target worker count (ensure we meet minimum requirements)
        const target_workers = @max(@min(total_demand, self.max_workers), minimum_needed);

        // Scale up if needed
        if (target_workers > current_total_workers) {
            // Release lock temporarily for scaling operation to avoid deadlock
            self.subsystems_mutex.unlock();
            self.scaleWorkers(target_workers) catch |err| {
                log(.ERROR, "enhanced_thread_pool", "Failed to scale workers from {} to {}: {}", .{ current_total_workers, target_workers, err });
            };
            self.subsystems_mutex.lock();
        }

        return allocated;
    }

    /// Submit work to the pool
    pub fn submitWork(self: *ThreadPool, work_item: WorkItem) !void {
        if (!self.running) {
            return error.ThreadPoolNotRunning;
        }

        // Use TLS to find if we are on a worker thread for this pool
        var pushed_locally = false;
        if (tls_worker_info) |worker| {
            if (worker.pool == self) {
                try worker.local_queue.push(work_item);
                pushed_locally = true;
            }
        }

        if (!pushed_locally) {
            try self.work_queue.push(work_item);
        }

        _ = self.stats.current_queue_size.fetchAdd(1, .monotonic);
        self.work_available.post();
    }

    /// Submit a batch of work items to the pool
    pub fn submitBatch(self: *ThreadPool, items: []const WorkItem) !void {
        if (!self.running) {
            return error.ThreadPoolNotRunning;
        }

        var pushed_locally = false;
        if (tls_worker_info) |worker| {
            if (worker.pool == self) {
                _ = try worker.local_queue.pushBatch(items);
                pushed_locally = true;
            }
        }

        if (!pushed_locally) {
            _ = try self.work_queue.pushBatch(items);
        }

        _ = self.stats.current_queue_size.fetchAdd(@intCast(items.len), .monotonic);
        
        var i: usize = 0;
        while (i < items.len) : (i += 1) {
            self.work_available.post();
        }
    }

    /// Check if a subsystem can accept another worker
    fn canSubsystemAcceptWorker(self: *ThreadPool, work_item_type: WorkItemType) bool {
        self.subsystems_mutex.lock();
        defer self.subsystems_mutex.unlock();

        const config = self.registered_subsystems.get(work_item_type) orelse return false;
        const active_workers = self.active_workers_per_subsystem.get(work_item_type) orelse 0;

        return active_workers < config.max_workers;
    }

    /// Get work from queues (Local -> Global -> Steal)
    pub fn getWork(self: *ThreadPool, worker_info: *WorkerInfo) ?WorkItem {
        // 1. Try local queue (LIFO for cache locality)
        if (worker_info.local_queue.pop_tail()) |item| {
            _ = self.stats.current_queue_size.fetchSub(1, .monotonic);
            return item;
        }

        // 2. Try global queue (FIFO)
        if (self.work_queue.pop()) |item| {
            _ = self.stats.current_queue_size.fetchSub(1, .monotonic);
            return item;
        }

        // 3. Try to steal from other workers (FIFO)
        // Start from a random index to reduce contention
        // We use a simple linear congruential generator for speed
        const seed = @as(u32, @truncate(@as(u64, @intCast(std.time.nanoTimestamp()))));
        const worker_count = self.current_worker_count.load(.acquire);
        if (worker_count <= 1) return null;

        const start_idx = seed % worker_count;
        var i: u32 = 0;
        while (i < worker_count) : (i += 1) {
            const idx = (start_idx + i) % worker_count;
            if (idx == worker_info.worker_id) continue;

            const victim = &self.workers[idx];
            // Only steal if victim is active
            if (victim.isActive()) {
                if (victim.local_queue.pop()) |item| {
                    _ = self.stats.current_queue_size.fetchSub(1, .monotonic);
                    return item;
                }
            }
        }

        return null;
    }

    /// Worker thread main loop
    fn workerThreadMain(worker_info: *WorkerInfo) void {
        const pool = worker_info.pool;
        tls_worker_info = worker_info; // Set TLS
        worker_info.state.store(.idle, .release);

        while (pool.running) {
            // Block until work is available
            pool.work_available.wait();

            // Try to get work
            if (pool.getWork(worker_info)) |work_item| {
                worker_info.state.store(.working, .release);

                if (pool.track_active_per_subsystem) {
                    pool.subsystems_mutex.lock();
                    const current_workers = pool.active_workers_per_subsystem.get(work_item.item_type) orelse 0;
                    pool.active_workers_per_subsystem.put(work_item.item_type, current_workers + 1) catch {};
                    pool.subsystems_mutex.unlock();
                }

                const start_time = std.time.microTimestamp();

                // Execute the work item
                work_item.worker_fn(work_item.context, work_item);

                const end_time = std.time.microTimestamp();
                const duration = @as(u64, @intCast(end_time - start_time));

                // Update statistics
                _ = worker_info.work_items_completed.fetchAdd(1, .monotonic);
                _ = pool.stats.total_work_items_processed.fetchAdd(1, .monotonic);
                worker_info.last_work_time.store(std.time.milliTimestamp(), .release);

                if (pool.track_active_per_subsystem) {
                    pool.subsystems_mutex.lock();
                    const current_workers = pool.active_workers_per_subsystem.get(work_item.item_type) orelse 0;
                    if (current_workers > 0) {
                        pool.active_workers_per_subsystem.put(work_item.item_type, current_workers - 1) catch {};
                    }
                    pool.subsystems_mutex.unlock();
                }

                // Update average work time (simple moving average)
                const current_avg = pool.stats.average_work_time_us.load(.acquire);
                const new_avg = if (current_avg == 0) duration else (current_avg + duration) / 2;
                pool.stats.average_work_time_us.store(new_avg, .release);

                worker_info.state.store(.idle, .release);
            } else {
                // Spurious wake or race: no item popped, continue waiting
                worker_info.state.store(.idle, .release);
            }
        }

        // log(.DEBUG, "enhanced_thread_pool", "Worker {} exited main loop (running={})", .{ worker_info.worker_id, pool.running.load(.acquire) });
        worker_info.state.store(.shutting_down, .release);
        if (pool.thread_exit_hook) |hook| {
            hook.callback(hook.context);
        }
        // log(.DEBUG, "enhanced_thread_pool", "Worker {} shutting down", .{worker_info.worker_id});
    }

    /// Scale the number of active workers
    fn scaleWorkers(self: *ThreadPool, target_count: u32) !void {
        const current_count = self.current_worker_count.load(.acquire);
        const actual_target = @min(target_count, self.max_workers);
        if (actual_target == current_count) return;

        if (actual_target > current_count) {
            // Update count before spawning to prevent race condition
            self.current_worker_count.store(actual_target, .release);

            // Scale up - start more workers
            for (current_count..actual_target) |i| {
                const worker = &self.workers[i];
                worker.pool = self;
                worker.thread = try std.Thread.spawn(.{}, workerThreadMain, .{worker});
            }
        } else {
            // Scale down - workers will shut themselves down when idle
            self.current_worker_count.store(actual_target, .release);
        }

        // Update peak worker count
        const current_peak = self.stats.peak_worker_count.load(.acquire);
        if (actual_target > current_peak) {
            self.stats.peak_worker_count.store(actual_target, .release);
        }

        // Call callback if set
        if (self.on_worker_count_changed) |callback| {
            callback(current_count, actual_target);
        }
    }

    /// Check if scaling is needed based on current load
    fn checkScaling(self: *ThreadPool) void {
        const now = std.time.milliTimestamp();
        const last_check = self.last_scale_check.load(.acquire);

        // Only check scaling every 100ms to avoid thrashing
        if (now - last_check < 100) return;

        self.last_scale_check.store(now, .release);

        const queue_size = self.stats.current_queue_size.load(.acquire);
        const current_workers = self.current_worker_count.load(.acquire);

        // If we have work but no workers, we need to spawn at least one worker
        if (queue_size > 0) {
            const min_workers = self.calculateMinimumWorkers();
            const target_workers = @max(1, min_workers); // At least 1 worker if there's work
            self.scaleWorkers(target_workers) catch |err| {
                log(.WARN, "enhanced_thread_pool", "Failed to scale up from 0 workers: {}", .{err});
            };
            return;
        }

        if (current_workers == 0) return;

        const utilization = @as(f32, @floatFromInt(queue_size)) / @as(f32, @floatFromInt(current_workers));

        if (utilization > self.scale_up_threshold and current_workers < self.max_workers) {
            // Scale up
            const new_count = @min(current_workers + 1, self.max_workers);
            self.scaleWorkers(new_count) catch |err| {
                log(.WARN, "enhanced_thread_pool", "Failed to scale up: {}", .{err});
            };
        } else if (utilization < self.scale_down_threshold and current_workers > 1) {
            // Scale down (gradual - workers will shut down when idle)
            // Don't actively kill workers, let them timeout naturally
        }
    }

    /// Check if a worker should shut down due to being idle too long
    fn shouldShutdownWorker(self: *ThreadPool, worker_info: *WorkerInfo) bool {
        self.subsystems_mutex.lock();
        defer self.subsystems_mutex.unlock();

        const current_workers = self.current_worker_count.load(.acquire);
        const minimum_workers = self.calculateMinimumWorkersLocked(); // Use locked version
        // Never shut down if we're at or below minimum
        if (current_workers <= minimum_workers) return false;

        // Check if idle too long
        const idle_time = worker_info.getIdleTime();
        return idle_time > self.idle_timeout_ms;
    }

    /// Calculate minimum workers needed based on registered subsystems (assumes mutex is held)
    fn calculateMinimumWorkers(self: *ThreadPool) u32 {
        self.subsystems_mutex.lock();
        defer self.subsystems_mutex.unlock();
        return self.calculateMinimumWorkersLocked();
    }

    /// Calculate minimum workers - internal version that assumes mutex is already held
    fn calculateMinimumWorkersLocked(self: *ThreadPool) u32 {
        var min_total: u32 = 0;
        var iter = self.registered_subsystems.valueIterator();
        while (iter.next()) |config| {
            min_total += config.min_workers;
        }
        return @min(min_total, self.max_workers);
    }

    /// Calculate total demand from all subsystems
    fn calculateTotalDemand(self: *ThreadPool) u32 {
        self.subsystems_mutex.lock();
        defer self.subsystems_mutex.unlock();
        return self.calculateTotalDemandLocked();
    }

    /// Calculate total demand - internal version that assumes mutex is already held
    fn calculateTotalDemandLocked(self: *ThreadPool) u32 {
        var total: u32 = 0;
        var iter = self.subsystem_demands.valueIterator();
        while (iter.next()) |demand| {
            total += demand.*;
        }
        return total;
    }

    /// Gracefully shutdown the thread pool
    pub fn shutdown(self: *ThreadPool) void {
        if (!self.running) return;

        self.shutting_down.store(true, .release);
        self.running = false;

        // Wake all workers so they can exit their wait
        const current_count = self.current_worker_count.load(.acquire);
        var i_post: u32 = 0;
        while (i_post < current_count) : (i_post += 1) {
            self.work_available.post();
        }
        // Wait for all active workers to finish
        for (0..current_count) |i| {
            if (self.workers[i].thread) |thread| {
                thread.join();
                self.workers[i].thread = null;
            }
        }

        self.current_worker_count.store(0, .release);
    }

    /// Get current pool statistics
    pub fn getStatistics(self: *ThreadPool) PoolStatistics {
        self.stats.current_queue_size.store(self.work_queue.size(), .release);
        return self.stats;
    }

    /// Set callback for worker count changes
    pub fn setWorkerCountChangedCallback(self: *ThreadPool, callback: *const fn (u32, u32) void) void {
        self.on_worker_count_changed = callback;
    }

    /// Set hook to run when a worker thread exits
    pub fn setThreadExitHook(self: *ThreadPool, callback: *const fn (*anyopaque) void, context: *anyopaque) void {
        self.thread_exit_hook = ThreadExitHook{
            .callback = callback,
            .context = context,
        };
    }
};

/// Helper functions for creating work items
/// Create an asset loading work item
pub fn createAssetLoadingWork(
    id: u64,
    asset_id: AssetId,
    loader: *anyopaque,
    priority: WorkPriority,
    worker_fn: *const fn (*anyopaque, WorkItem) void,
) WorkItem {
    return WorkItem{
        .id = id,
        .item_type = .asset_loading,
        .priority = priority,
        .data = .{ .asset_loading = .{ .asset_id = asset_id, .loader = loader } },
        .worker_fn = worker_fn,
        .context = loader,
    };
}

/// Create a BVH building work item
pub fn createBvhBuildingWork(
    id: u64,
    as_type: BvhAccelerationStructureType,
    work_data: *anyopaque,
    rebuild_type: BvhRebuildType,
    priority: WorkPriority,
    worker_fn: *const fn (*anyopaque, WorkItem) void,
    context: *anyopaque,
) WorkItem {
    return WorkItem{
        .id = id,
        .item_type = .bvh_building,
        .priority = priority,
        .data = .{ .bvh_building = .{
            .as_type = as_type,
            .work_data = work_data,
            .rebuild_type = rebuild_type,
        } },
        .worker_fn = worker_fn,
        .context = context,
    };
}

/// Create a compute task work item
pub fn createComputeWork(
    id: u64,
    task_data: *anyopaque,
    thread_groups: struct { x: u32, y: u32, z: u32 },
    priority: WorkPriority,
    worker_fn: *const fn (*anyopaque, WorkItem) void,
    context: *anyopaque,
) WorkItem {
    return WorkItem{
        .id = id,
        .item_type = .compute_task,
        .priority = priority,
        .data = .{ .compute_task = .{
            .task_data = task_data,
            .thread_group_size = thread_groups,
        } },
        .worker_fn = worker_fn,
        .context = context,
    };
}

pub const GPUWork = enum { texture, mesh, shader_rebuild };

/// Create a GPU work item for processing staged assets
pub fn createGPUWork(
    id: u64,
    staging_type: GPUWork,
    asset_id: AssetId,
    staging_data: *anyopaque,
    priority: WorkPriority,
    worker_fn: *const fn (*anyopaque, WorkItem) void,
    context: *anyopaque,
) WorkItem {
    return WorkItem{
        .id = id,
        .item_type = .gpu_work,
        .priority = priority,
        .data = .{ .gpu_work = .{
            .staging_type = staging_type,
            .asset_id = asset_id,
            .data = staging_data,
        } },
        .worker_fn = worker_fn,
        .context = context,
    };
}

/// Create a custom work item (for specialized tasks like file watching)
pub fn createCustomWork(
    id: u64,
    user_data: *anyopaque,
    data_size: usize,
    priority: WorkPriority,
    worker_fn: *const fn (*anyopaque, WorkItem) void,
    context: *anyopaque,
) WorkItem {
    return WorkItem{
        .id = id,
        .item_type = .custom,
        .priority = priority,
        .data = .{ .custom = .{
            .user_data = user_data,
            .size = data_size,
        } },
        .worker_fn = worker_fn,
        .context = context,
    };
}
