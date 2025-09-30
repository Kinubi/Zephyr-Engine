const std = @import("std");
const EnhancedThreadPool = @import("enhanced_thread_pool.zig").EnhancedThreadPool;
const WorkItem = @import("enhanced_thread_pool.zig").WorkItem;
const WorkItemType = @import("enhanced_thread_pool.zig").WorkItemType;
const WorkPriority = @import("enhanced_thread_pool.zig").WorkPriority;
const SubsystemConfig = @import("enhanced_thread_pool.zig").SubsystemConfig;
const createAssetLoadingWork = @import("enhanced_thread_pool.zig").createAssetLoadingWork;
const createBvhBuildingWork = @import("enhanced_thread_pool.zig").createBvhBuildingWork;
const createComputeWork = @import("enhanced_thread_pool.zig").createComputeWork;

const AssetId = @import("../assets/asset_types.zig").AssetId;
const log = @import("../utils/log.zig").log;

/// Example usage of the EnhancedThreadPool for different subsystems
pub const ThreadPoolExample = struct {
    pool: *EnhancedThreadPool,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !ThreadPoolExample {
        // Create enhanced thread pool with max 16 workers
        const pool = try allocator.create(EnhancedThreadPool);
        pool.* = try EnhancedThreadPool.init(allocator, 16);

        // Register subsystems with their requirements
        try pool.registerSubsystem(SubsystemConfig{
            .name = "Asset Loading",
            .min_workers = 2, // Always keep 2 workers for asset loading
            .max_workers = 6, // Can use up to 6 workers during heavy loading
            .priority = .normal,
            .work_item_type = .asset_loading,
        });

        try pool.registerSubsystem(SubsystemConfig{
            .name = "BVH Building",
            .min_workers = 1, // Minimum 1 worker for BVH updates
            .max_workers = 8, // Can use up to 8 workers for large BVH rebuilds
            .priority = .high, // BVH building has higher priority
            .work_item_type = .bvh_building,
        });

        try pool.registerSubsystem(SubsystemConfig{
            .name = "Compute Tasks",
            .min_workers = 0, // Optional - only when needed
            .max_workers = 4, // Max 4 workers for compute tasks
            .priority = .normal,
            .work_item_type = .compute_task,
        });

        // Start the pool with 4 initial workers
        try pool.start(4);

        return ThreadPoolExample{
            .pool = pool,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ThreadPoolExample) void {
        self.pool.deinit();
        self.allocator.destroy(self.pool);
    }

    /// Example: Asset loading subsystem requests workers
    pub fn demonstrateAssetLoading(self: *ThreadPoolExample) !void {
        log(.INFO, "thread_pool_example", "=== Asset Loading Example ===", .{});

        // Asset loader wants to load 10 assets simultaneously
        const requested_workers = self.pool.requestWorkers(.asset_loading, 10);
        log(.INFO, "thread_pool_example", "Asset loader requested 10 workers, got {}", .{requested_workers});

        // Create some asset loading work items
        for (0..5) |i| {
            const work_item = createAssetLoadingWork(
                i, // work item id
                AssetId.fromU64(@intCast(i + 100)), // asset id
                @as(*anyopaque, @ptrCast(@constCast(&self))), // loader context
                .normal, // priority
                assetLoadingWorker, // worker function
            );

            try self.pool.submitWork(work_item);
        }
    }

    /// Example: Raytracing BVH builder requests workers for large scene rebuild
    pub fn demonstrateBvhBuilding(self: *ThreadPoolExample) !void {
        log(.INFO, "thread_pool_example", "=== BVH Building Example ===", .{});

        // BVH builder needs to rebuild acceleration structures for large scene
        const requested_workers = self.pool.requestWorkers(.bvh_building, 8);
        log(.INFO, "thread_pool_example", "BVH builder requested 8 workers, got {}", .{requested_workers});

        // Create BVH building work - full rebuild of large scene
        const bvh_work = createBvhBuildingWork(
            1000, // work item id
            @as(*anyopaque, @ptrCast(@constCast(&self))), // scene data
            5000, // geometry count
            10000, // instance count
            .full_rebuild, // rebuild type
            .high, // high priority
            bvhBuildingWorker, // worker function
            @as(*anyopaque, @ptrCast(@constCast(&self))), // context
        );

        try self.pool.submitWork(bvh_work);

        // Create some instance-only updates (lower priority)
        for (0..3) |i| {
            const instance_work = createBvhBuildingWork(
                1001 + i, // work item id
                @as(*anyopaque, @ptrCast(@constCast(&self))), // scene data
                0, // no new geometry
                100, // just updating 100 instances
                .instance_only, // instance-only update
                .normal, // normal priority
                bvhBuildingWorker, // worker function
                @as(*anyopaque, @ptrCast(@constCast(&self))), // context
            );

            try self.pool.submitWork(instance_work);
        }
    }

    /// Example: Compute system requests workers for particle simulation
    pub fn demonstrateComputeTasks(self: *ThreadPoolExample) !void {
        log(.INFO, "thread_pool_example", "=== Compute Tasks Example ===", .{});

        // Compute system wants workers for particle simulation
        const requested_workers = self.pool.requestWorkers(.compute_task, 4);
        log(.INFO, "thread_pool_example", "Compute system requested 4 workers, got {}", .{requested_workers});

        // Create particle simulation compute work
        const particle_work = createComputeWork(
            2000, // work item id
            @as(*anyopaque, @ptrCast(@constCast(&self))), // task data
            .{ .x = 64, .y = 64, .z = 1 }, // thread groups
            .normal, // normal priority
            computeTaskWorker, // worker function
            @as(*anyopaque, @ptrCast(@constCast(&self))), // context
        );

        try self.pool.submitWork(particle_work);
    }

    /// Example: Show dynamic scaling based on demand
    pub fn demonstrateDynamicScaling(self: *ThreadPoolExample) !void {
        log(.INFO, "thread_pool_example", "=== Dynamic Scaling Example ===", .{});

        // Start with heavy asset loading demand
        _ = self.pool.requestWorkers(.asset_loading, 6);
        log(.INFO, "thread_pool_example", "High asset loading demand - pool should scale up", .{});

        // Add heavy BVH building demand
        _ = self.pool.requestWorkers(.bvh_building, 8);
        log(.INFO, "thread_pool_example", "Added heavy BVH demand - pool should scale up more", .{});

        // Submit lots of work to trigger scaling
        for (0..20) |i| {
            const work_item = createAssetLoadingWork(
                3000 + i,
                AssetId.fromU64(@intCast(i + 200)),
                @as(*anyopaque, @ptrCast(@constCast(&self))),
                if (i % 3 == 0) .high else .normal,
                assetLoadingWorker,
            );
            try self.pool.submitWork(work_item);
        }

        // Wait a bit to see scaling in action
        std.Thread.sleep(std.time.ns_per_ms * 100);

        // Reduce demand - pool should scale down gradually
        _ = self.pool.requestWorkers(.asset_loading, 1);
        _ = self.pool.requestWorkers(.bvh_building, 1);
        log(.INFO, "thread_pool_example", "Reduced demand - pool should scale down gradually", .{});
    }

    /// Print current pool statistics
    pub fn printStatistics(self: *ThreadPoolExample) void {
        const stats = self.pool.getStatistics();

        log(.INFO, "thread_pool_example", "=== Pool Statistics ===", .{});
        log(.INFO, "thread_pool_example", "Total work items processed: {}", .{stats.total_work_items_processed.load(.acquire)});
        log(.INFO, "thread_pool_example", "Total work items failed: {}", .{stats.total_work_items_failed.load(.acquire)});
        log(.INFO, "thread_pool_example", "Peak worker count: {}", .{stats.peak_worker_count.load(.acquire)});
        log(.INFO, "thread_pool_example", "Current queue size: {}", .{stats.current_queue_size.load(.acquire)});
        log(.INFO, "thread_pool_example", "Average work time: {}μs", .{stats.average_work_time_us.load(.acquire)});
        log(.INFO, "thread_pool_example", "Current workers: {}", .{self.pool.current_worker_count.load(.acquire)});
    }
};

/// Example worker functions for different work types
fn assetLoadingWorker(context: *anyopaque, work_item: WorkItem) void {
    _ = context;

    const asset_data = work_item.data.asset_loading;
    log(.INFO, "thread_pool_example", "Asset worker processing asset {} (priority: {})", .{ asset_data.asset_id.toU64(), @tagName(work_item.priority) });

    // Simulate asset loading work (varying duration)
    const work_duration = 10 + (work_item.id % 50); // 10-60ms
    std.Thread.sleep(std.time.ns_per_ms * work_duration);

    log(.INFO, "thread_pool_example", "Asset worker completed asset {} in {}ms", .{ asset_data.asset_id.toU64(), work_duration });
}

fn bvhBuildingWorker(context: *anyopaque, work_item: WorkItem) void {
    _ = context;

    const bvh_data = work_item.data.bvh_building;
    log(.INFO, "thread_pool_example", "BVH worker processing {} rebuild (geometries: {}, instances: {})", .{ @tagName(bvh_data.rebuild_type), bvh_data.geometry_count, bvh_data.instance_count });

    // Simulate BVH building work (duration based on complexity)
    const base_duration: u64 = switch (bvh_data.rebuild_type) {
        .full_rebuild => 100, // 100ms for full rebuild
        .partial_update => 50, // 50ms for partial update
        .instance_only => 20, // 20ms for instance-only update
    };
    const complexity_factor = @min(bvh_data.geometry_count / 100, 100); // Scale with geometry count
    const work_duration = base_duration + complexity_factor;

    std.Thread.sleep(std.time.ns_per_ms * work_duration);

    log(.INFO, "thread_pool_example", "BVH worker completed {} rebuild in {}ms", .{ @tagName(bvh_data.rebuild_type), work_duration });
}

fn computeTaskWorker(context: *anyopaque, work_item: WorkItem) void {
    _ = context;

    const compute_data = work_item.data.compute_task;
    const total_threads = compute_data.thread_group_size.x * compute_data.thread_group_size.y * compute_data.thread_group_size.z;

    log(.INFO, "thread_pool_example", "Compute worker processing task with {} thread groups ({} total threads)", .{
        total_threads, total_threads * 64, // Assuming 64 threads per group
    });

    // Simulate compute work (duration based on thread count)
    const work_duration = 30 + (total_threads / 100); // 30ms base + complexity
    std.Thread.sleep(std.time.ns_per_ms * work_duration);

    log(.INFO, "thread_pool_example", "Compute worker completed task in {}ms", .{work_duration});
}

/// Example main function showing the enhanced thread pool in action
pub fn runExample(allocator: std.mem.Allocator) !void {
    log(.INFO, "thread_pool_example", "Starting Enhanced ThreadPool Example", .{});

    var example = try ThreadPoolExample.init(allocator);
    defer example.deinit();

    // Set up a callback to monitor worker count changes
    example.pool.setWorkerCountChangedCallback(onWorkerCountChanged);

    // Run different examples
    try example.demonstrateAssetLoading();
    std.Thread.sleep(std.time.ns_per_ms * 50);

    try example.demonstrateBvhBuilding();
    std.Thread.sleep(std.time.ns_per_ms * 50);

    try example.demonstrateComputeTasks();
    std.Thread.sleep(std.time.ns_per_ms * 50);

    try example.demonstrateDynamicScaling();
    std.Thread.sleep(std.time.ns_per_ms * 200); // Wait for work to complete

    example.printStatistics();

    log(.INFO, "thread_pool_example", "Enhanced ThreadPool Example Complete", .{});
}

fn onWorkerCountChanged(old_count: u32, new_count: u32) void {
    log(.INFO, "thread_pool_example", "Worker count changed: {} -> {}", .{ old_count, new_count });
}
