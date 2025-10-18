const std = @import("std");

// Import AssetId from the asset system
const AssetId = @import("../assets/asset_types.zig").AssetId;
const log = @import("../utils/log.zig").log;
const LogLevel = @import("../utils/log.zig").LogLevel;
const AssetLoader = @import("../assets/asset_loader.zig").AssetLoader;
const AssetManager = @import("../assets/asset_manager.zig").AssetManager;

/// Work item types for different subsystems
pub const WorkItemType = enum {
    asset_loading,
    hot_reload,
    bvh_building,
    compute_task,
    gpu_work,
    custom,
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
        gpu_work: GpuWorkData,
        custom: CustomData,
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

    const CustomData = struct {
        user_data: *anyopaque,
        size: usize,
    };
};

/// Thread-safe priority queue for work items
pub const WorkQueue = struct {
    // Priority queues for different priority levels
    critical_queue: std.ArrayList(WorkItem),
    high_queue: std.ArrayList(WorkItem),
    normal_queue: std.ArrayList(WorkItem),
    low_queue: std.ArrayList(WorkItem),

    mutex: std.Thread.Mutex = .{},
    total_items: std.atomic.Value(u32),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) WorkQueue {
        return .{
            .critical_queue = std.ArrayList(WorkItem){},
            .high_queue = std.ArrayList(WorkItem){},
            .normal_queue = std.ArrayList(WorkItem){},
            .low_queue = std.ArrayList(WorkItem){},
            .total_items = std.atomic.Value(u32).init(0),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *WorkQueue) void {
        self.critical_queue.deinit(self.allocator);
        self.high_queue.deinit(self.allocator);
        self.normal_queue.deinit(self.allocator);
        self.low_queue.deinit(self.allocator);
    }

    pub fn push(self: *WorkQueue, item: WorkItem) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const queue = switch (item.priority) {
            .critical => &self.critical_queue,
            .high => &self.high_queue,
            .normal => &self.normal_queue,
            .low => &self.low_queue,
        };

        try queue.append(self.allocator, item);
        _ = self.total_items.fetchAdd(1, .monotonic);
    }

    pub fn pop(self: *WorkQueue) ?WorkItem {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Try critical first, then high, normal, low
        const queues = [_]*std.ArrayList(WorkItem){
            &self.critical_queue,
            &self.high_queue,
            &self.normal_queue,
            &self.low_queue,
        };

        for (queues) |queue| {
            if (queue.items.len > 0) {
                const item = queue.orderedRemove(0);
                _ = self.total_items.fetchSub(1, .monotonic);
                return item;
            }
        }

        return null;
    }

    pub fn popIf(self: *WorkQueue, context: anytype) ?WorkItem {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Try critical first, then high, normal, low
        const queues = [_]*std.ArrayList(WorkItem){
            &self.critical_queue,
            &self.high_queue,
            &self.normal_queue,
            &self.low_queue,
        };

        for (queues) |queue| {
            for (queue.items, 0..) |*item, i| {
                if (context.canProcess(item)) {
                    const work_item = queue.orderedRemove(i);
                    _ = self.total_items.fetchSub(1, .monotonic);
                    return work_item;
                }
            }
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

    pub fn init(worker_id: u32, pool: *ThreadPool) WorkerInfo {
        return .{
            .state = std.atomic.Value(WorkerState).init(.sleeping),
            .last_work_time = std.atomic.Value(i64).init(std.time.milliTimestamp()), // Initialize to current time
            .work_items_completed = std.atomic.Value(u32).init(0),
            .worker_id = worker_id,
            .pool = pool,
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
pub const ThreadPool = struct {
    // Core configuration
    allocator: std.mem.Allocator,
    max_workers: u32,
    current_worker_count: std.atomic.Value(u32),

    // Worker management
    workers: []WorkerInfo,
    work_queue: *WorkQueue,

    // Pool state
    running: bool,
    shutting_down: std.atomic.Value(bool),

    // Subsystem management
    registered_subsystems: std.HashMap(WorkItemType, SubsystemConfig, std.hash_map.AutoContext(WorkItemType), 80),
    subsystem_demands: std.HashMap(WorkItemType, u32, std.hash_map.AutoContext(WorkItemType), 80), // Current demand per subsystem
    active_workers_per_subsystem: std.HashMap(WorkItemType, u32, std.hash_map.AutoContext(WorkItemType), 80), // Currently active workers per subsystem
    subsystems_mutex: std.Thread.Mutex = .{}, // Protects HashMap operations

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
        }

        const work_queue = try allocator.create(WorkQueue);
        work_queue.* = WorkQueue.init(allocator);

        const pool = ThreadPool{
            .allocator = allocator,
            .max_workers = max_workers,
            .current_worker_count = std.atomic.Value(u32).init(0),
            .workers = workers,
            .work_queue = work_queue,
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
        log(.INFO, "enhanced_thread_pool", "DEINIT CALLED - About to shutdown thread pool", .{});
        self.shutdown();

        self.work_queue.deinit();
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

        try self.work_queue.push(work_item);
        self.stats.current_queue_size.store(self.work_queue.size(), .release);

        // Check if we need to scale up
        //self.checkScaling();
    }

    /// Check if a subsystem can accept another worker
    fn canSubsystemAcceptWorker(self: *ThreadPool, work_item_type: WorkItemType) bool {
        self.subsystems_mutex.lock();
        defer self.subsystems_mutex.unlock();

        const config = self.registered_subsystems.get(work_item_type) orelse return false;
        const active_workers = self.active_workers_per_subsystem.get(work_item_type) orelse 0;

        return active_workers < config.max_workers;
    }

    /// Get work from the queue (called by worker threads)
    pub fn getWork(self: *ThreadPool) ?WorkItem {
        // Try to get work that can be processed by available subsystem workers
        return self.work_queue.popIf(struct {
            pool: *ThreadPool,

            pub fn canProcess(ctx: @This(), work_item: *const WorkItem) bool {
                return ctx.pool.canSubsystemAcceptWorker(work_item.item_type);
            }
        }{ .pool = self });
    }

    /// Worker thread main loop
    fn workerThreadMain(worker_info: *WorkerInfo) void {
        const pool = worker_info.pool;
        worker_info.state.store(.idle, .release);

        while (pool.running) {
            // Try to get work
            if (pool.getWork()) |work_item| {
                worker_info.state.store(.working, .release);

                // Increment active worker count for this subsystem
                {
                    pool.subsystems_mutex.lock();
                    defer pool.subsystems_mutex.unlock();

                    const current_workers = pool.active_workers_per_subsystem.get(work_item.item_type) orelse 0;
                    pool.active_workers_per_subsystem.put(work_item.item_type, current_workers + 1) catch {};
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

                // Decrement active worker count for this subsystem
                {
                    pool.subsystems_mutex.lock();
                    defer pool.subsystems_mutex.unlock();

                    const current_workers = pool.active_workers_per_subsystem.get(work_item.item_type) orelse 0;
                    if (current_workers > 0) {
                        pool.active_workers_per_subsystem.put(work_item.item_type, current_workers - 1) catch {};
                    }
                }

                // Update average work time (simple moving average)
                const current_avg = pool.stats.average_work_time_us.load(.acquire);
                const new_avg = if (current_avg == 0) duration else (current_avg + duration) / 2;
                pool.stats.average_work_time_us.store(new_avg, .release);

                worker_info.state.store(.idle, .release);
            } else {
                // No work available, sleep briefly
                worker_info.state.store(.idle, .release);
                std.Thread.sleep(std.time.ns_per_ms * 1); // 1ms

                // Check if we should shut down due to being idle too long (only when no work available)
                if (pool.shouldShutdownWorker(worker_info)) {
                    // Decrement the worker count since this worker is shutting down
                    _ = pool.current_worker_count.fetchSub(1, .acq_rel);
                    break;
                }
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

        const queue_size = self.work_queue.size();
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

        log(.INFO, "enhanced_thread_pool", "SHUTDOWN CALLED - Shutting down thread pool...", .{});

        self.shutting_down.store(true, .release);
        self.running = false;

        // Wait for all active workers to finish
        const current_count = self.current_worker_count.load(.acquire);
        for (0..current_count) |i| {
            if (self.workers[i].thread) |thread| {
                thread.join();
                self.workers[i].thread = null;
            }
        }

        self.current_worker_count.store(0, .release);

        log(.INFO, "enhanced_thread_pool", "Thread pool shutdown complete", .{});
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
