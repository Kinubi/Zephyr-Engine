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
        scene_data: *anyopaque,
        geometry_count: u32,
        instance_count: u32,
        rebuild_type: BvhRebuildType,
    };

    const BvhRebuildType = enum {
        full_rebuild,
        partial_update,
        instance_only,
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

        log(.DEBUG, "enhanced_thread_pool", "Pushed {s} priority work item (id: {}, total: {})", .{ @tagName(item.priority), item.id, self.total_items.load(.acquire) });
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
                log(.DEBUG, "enhanced_thread_pool", "Popped {s} priority work item (id: {}, remaining: {})", .{ @tagName(item.priority), item.id, self.total_items.load(.acquire) });
                return item;
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
    pool: *EnhancedThreadPool,

    pub fn init(worker_id: u32, pool: *EnhancedThreadPool) WorkerInfo {
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
pub const EnhancedThreadPool = struct {
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

    pub fn init(allocator: std.mem.Allocator, max_workers: u32) !EnhancedThreadPool {
        log(.INFO, "enhanced_thread_pool", "Initializing EnhancedThreadPool with max {} workers", .{max_workers});

        const workers = try allocator.alloc(WorkerInfo, max_workers);

        // Initialize all worker slots (but don't start threads yet)
        for (workers, 0..) |*worker, i| {
            worker.* = WorkerInfo.init(@intCast(i), undefined); // Will set pool pointer after struct creation
        }

        const work_queue = try allocator.create(WorkQueue);
        work_queue.* = WorkQueue.init(allocator);

        const pool = EnhancedThreadPool{
            .allocator = allocator,
            .max_workers = max_workers,
            .current_worker_count = std.atomic.Value(u32).init(0),
            .workers = workers,
            .work_queue = work_queue,
            .running = false,
            .shutting_down = std.atomic.Value(bool).init(false),
            .registered_subsystems = std.HashMap(WorkItemType, SubsystemConfig, std.hash_map.AutoContext(WorkItemType), 80).init(allocator),
            .subsystem_demands = std.HashMap(WorkItemType, u32, std.hash_map.AutoContext(WorkItemType), 80).init(allocator),
            .stats = PoolStatistics.init(),
            .last_scale_check = std.atomic.Value(i64).init(0),
        };

        return pool;
    }

    pub fn deinit(self: *EnhancedThreadPool) void {
        log(.INFO, "enhanced_thread_pool", "DEINIT CALLED - About to shutdown thread pool", .{});
        self.shutdown();

        self.work_queue.deinit();
        self.registered_subsystems.deinit();
        self.subsystem_demands.deinit();
        self.allocator.free(self.workers);

        log(.INFO, "enhanced_thread_pool", "EnhancedThreadPool deinitialized", .{});
    }

    /// Register a subsystem that can request workers
    pub fn registerSubsystem(self: *EnhancedThreadPool, config: SubsystemConfig) !void {
        try self.registered_subsystems.put(config.work_item_type, config);
        try self.subsystem_demands.put(config.work_item_type, 0);

        log(.INFO, "enhanced_thread_pool", "Registered subsystem '{s}' (min: {}, max: {})", .{ config.name, config.min_workers, config.max_workers });
    }

    /// Start the thread pool with initial worker count
    pub fn start(self: *EnhancedThreadPool, initial_workers: u32) !void {
        if (self.running) {
            log(.WARN, "enhanced_thread_pool", "ThreadPool already running", .{});
            return;
        }

        self.running = true;
        self.last_scale_check.store(std.time.milliTimestamp(), .release);

        // Start initial workers
        const workers_to_start = @min(initial_workers, self.max_workers);
        try self.scaleWorkers(workers_to_start);

        log(.INFO, "enhanced_thread_pool", "EnhancedThreadPool started with {} workers", .{workers_to_start});
    }

    /// Request workers for a specific subsystem
    pub fn requestWorkers(self: *EnhancedThreadPool, subsystem_type: WorkItemType, requested_count: u32) u32 {
        if (!self.running) return 0;

        self.subsystems_mutex.lock();
        defer self.subsystems_mutex.unlock();

        const total_demand = self.calculateTotalDemand();
        const current_count = self.current_worker_count.load(.acquire);

        // Determine how many workers to allocate to this subsystem
        const subsystem_config = self.registered_subsystems.get(subsystem_type) orelse return 0;
        const max_for_subsystem = @min(requested_count, subsystem_config.max_workers);

        // Scale up if needed and possible
        if (total_demand > current_count and current_count < self.max_workers) {
            const new_worker_count = @min(total_demand, self.max_workers);
            self.scaleWorkers(new_worker_count) catch |err| {
                log(.ERROR, "enhanced_thread_pool", "Failed to scale workers: {}", .{err});
            };
            log(.INFO, "enhanced_thread_pool", "Scaled up from {} to {} workers", .{ current_count, new_worker_count });
        }

        log(.DEBUG, "enhanced_thread_pool", "Subsystem {} requested {} workers, allocated {}", .{ subsystem_type, requested_count, max_for_subsystem });
        return max_for_subsystem;
    }

    /// Submit work to the pool
    pub fn submitWork(self: *EnhancedThreadPool, work_item: WorkItem) !void {
        if (!self.running) {
            return error.ThreadPoolNotRunning;
        }

        try self.work_queue.push(work_item);
        self.stats.current_queue_size.store(self.work_queue.size(), .release);

        // Check if we need to scale up
        self.checkScaling();
    }

    /// Get work from the queue (called by worker threads)
    pub fn getWork(self: *EnhancedThreadPool) ?WorkItem {
        return self.work_queue.pop();
    }

    /// Worker thread main loop
    fn workerThreadMain(worker_info: *WorkerInfo) void {
        const pool = worker_info.pool;
        worker_info.state.store(.idle, .release);

        // Single debug log to confirm worker enters loop
        std.debug.print("Worker {} entering main loop\n", .{worker_info.worker_id});

        while (pool.running) {
            // Try to get work
            if (pool.getWork()) |work_item| {
                worker_info.state.store(.working, .release);

                const start_time = std.time.microTimestamp();

                // Execute the work item
                work_item.worker_fn(work_item.context, work_item);

                const end_time = std.time.microTimestamp();
                const duration = @as(u64, @intCast(end_time - start_time));

                // Update statistics
                _ = worker_info.work_items_completed.fetchAdd(1, .monotonic);
                _ = pool.stats.total_work_items_processed.fetchAdd(1, .monotonic);
                worker_info.last_work_time.store(std.time.milliTimestamp(), .release);

                // Update average work time (simple moving average)
                const current_avg = pool.stats.average_work_time_us.load(.acquire);
                const new_avg = if (current_avg == 0) duration else (current_avg + duration) / 2;
                pool.stats.average_work_time_us.store(new_avg, .release);

                worker_info.state.store(.idle, .release);

                log(.DEBUG, "enhanced_thread_pool", "Worker {} completed work item {} in {}μs", .{ worker_info.worker_id, work_item.id, duration });
            } else {
                // No work available, sleep briefly
                worker_info.state.store(.idle, .release);
                std.Thread.sleep(std.time.ns_per_ms * 1); // 1ms

                // Check if we should shut down due to being idle too long (only when no work available)
                if (pool.shouldShutdownWorker(worker_info)) {
                    break;
                }
            }
        }

        // log(.DEBUG, "enhanced_thread_pool", "Worker {} exited main loop (running={})", .{ worker_info.worker_id, pool.running.load(.acquire) });
        worker_info.state.store(.shutting_down, .release);
        // log(.DEBUG, "enhanced_thread_pool", "Worker {} shutting down", .{worker_info.worker_id});
    }

    /// Scale the number of active workers
    fn scaleWorkers(self: *EnhancedThreadPool, target_count: u32) !void {
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
                log(.DEBUG, "enhanced_thread_pool", "Running is: {}", .{worker.pool.running});
                worker.thread = try std.Thread.spawn(.{}, workerThreadMain, .{worker});
            }
            log(.INFO, "enhanced_thread_pool", "Scaled up from {} to {} workers", .{ current_count, actual_target });
        } else {
            // Scale down - workers will shut themselves down when idle
            log(.INFO, "enhanced_thread_pool", "Scaling down from {} to {} workers (gradual)", .{ current_count, actual_target });
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
    fn checkScaling(self: *EnhancedThreadPool) void {
        const now = std.time.milliTimestamp();
        const last_check = self.last_scale_check.load(.acquire);

        // Only check scaling every 100ms to avoid thrashing
        if (now - last_check < 100) return;

        self.last_scale_check.store(now, .release);

        const queue_size = self.work_queue.size();
        const current_workers = self.current_worker_count.load(.acquire);

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
    fn shouldShutdownWorker(self: *EnhancedThreadPool, worker_info: *WorkerInfo) bool {
        self.subsystems_mutex.lock();
        defer self.subsystems_mutex.unlock();

        const current_workers = self.current_worker_count.load(.acquire);
        const minimum_workers = self.calculateMinimumWorkersLocked(); // Use locked version

        // Never shut down if we're at or below minimum
        if (current_workers <= minimum_workers) return false;

        // Check if idle too long
        const idle_time = worker_info.getIdleTime();
        log(.TRACE, "enhanced_thread_pool", "Worker {} idle for {}ms", .{ worker_info.worker_id, idle_time });
        return idle_time > self.idle_timeout_ms;
    }

    /// Calculate minimum workers needed based on registered subsystems (assumes mutex is held)
    fn calculateMinimumWorkers(self: *EnhancedThreadPool) u32 {
        self.subsystems_mutex.lock();
        defer self.subsystems_mutex.unlock();
        return self.calculateMinimumWorkersLocked();
    }

    /// Calculate minimum workers - internal version that assumes mutex is already held
    fn calculateMinimumWorkersLocked(self: *EnhancedThreadPool) u32 {
        var min_total: u32 = 0;
        var iter = self.registered_subsystems.valueIterator();
        while (iter.next()) |config| {
            min_total += config.min_workers;
        }
        return @min(min_total, self.max_workers);
    }

    /// Calculate total demand from all subsystems
    fn calculateTotalDemand(self: *EnhancedThreadPool) u32 {
        var total: u32 = 0;
        var iter = self.subsystem_demands.valueIterator();
        while (iter.next()) |demand| {
            total += demand.*;
        }
        return total;
    }

    /// Gracefully shutdown the thread pool
    pub fn shutdown(self: *EnhancedThreadPool) void {
        if (!self.running.load(.acquire)) return;

        log(.INFO, "enhanced_thread_pool", "SHUTDOWN CALLED - Shutting down thread pool...", .{});

        self.shutting_down.store(true, .release);
        self.running.store(false, .release);

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
    pub fn getStatistics(self: *EnhancedThreadPool) PoolStatistics {
        self.stats.current_queue_size.store(self.work_queue.size(), .release);
        return self.stats;
    }

    /// Set callback for worker count changes
    pub fn setWorkerCountChangedCallback(self: *EnhancedThreadPool, callback: *const fn (u32, u32) void) void {
        self.on_worker_count_changed = callback;
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
    scene_data: *anyopaque,
    geometry_count: u32,
    instance_count: u32,
    rebuild_type: WorkItem.WorkData.BvhBuildingData.BvhRebuildType,
    priority: WorkPriority,
    worker_fn: *const fn (*anyopaque, WorkItem) void,
    context: *anyopaque,
) WorkItem {
    return WorkItem{
        .id = id,
        .item_type = .bvh_building,
        .priority = priority,
        .data = .{ .bvh_building = .{
            .scene_data = scene_data,
            .geometry_count = geometry_count,
            .instance_count = instance_count,
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

pub const GPUWork = enum { texture, mesh };

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
