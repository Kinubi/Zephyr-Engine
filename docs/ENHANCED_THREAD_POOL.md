# Enhanced ThreadPool Documentation

## Overview

The Enhanced ThreadPool is a sophisticated, demand-driven thread management system designed to efficiently allocate computational resources across multiple subsystems in ZulkanZengine. Unlike the original fixed-size ThreadPool, this system dynamically scales worker threads based on actual demand from different subsystems.

## Key Features

### 1. **Dynamic Worker Allocation**
- **Max Workers**: Configurable maximum number of worker threads (typically set to CPU core count)
- **Demand-Based Scaling**: Automatically scales up/down based on work queue size and subsystem demands
- **Intelligent Distribution**: Allocates workers to subsystems based on their registered requirements

### 2. **Subsystem Registration**
- **Min/Max Workers**: Each subsystem can specify minimum guaranteed and maximum possible workers
- **Priority Levels**: Work items have priority levels (low, normal, high, critical)
- **Work Types**: Different work types (asset_loading, bvh_building, compute_task, custom)

### 3. **Advanced Scheduling**
- **Priority Queue**: High-priority work is processed before low-priority work
- **Intelligent Scaling**: Scales up when queue utilization > 80%, scales down when < 30%
- **Idle Timeout**: Workers automatically shut down after 5 seconds of inactivity

### 4. **Comprehensive Statistics**
- **Performance Monitoring**: Tracks work completion times, peak worker usage, failure rates
- **Real-time Metrics**: Queue size, active workers, processed items
- **Callback System**: Notifications when worker count changes

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    Enhanced ThreadPool                         │
├─────────────────────────────────────────────────────────────────┤
│  Subsystem Registration:                                        │
│  ┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐   │
│  │ Asset Loading   │ │ BVH Building    │ │ Compute Tasks   │   │
│  │ min: 2, max: 6  │ │ min: 1, max: 8  │ │ min: 0, max: 4  │   │
│  │ priority: normal│ │ priority: high  │ │ priority: normal│   │
│  └─────────────────┘ └─────────────────┘ └─────────────────┘   │
├─────────────────────────────────────────────────────────────────┤
│  Priority Work Queue:                                           │
│  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐ ┌───────────┐ │
│  │ Critical    │ │ High        │ │ Normal      │ │ Low       │ │
│  │ Queue       │ │ Queue       │ │ Queue       │ │ Queue     │ │
│  └─────────────┘ └─────────────┘ └─────────────┘ └───────────┘ │
├─────────────────────────────────────────────────────────────────┤
│  Dynamic Worker Pool (0 to max_workers):                       │
│  ┌─────────┐ ┌─────────┐ ┌─────────┐     ┌─────────┐           │
│  │Worker 0 │ │Worker 1 │ │Worker 2 │ ... │Worker N │           │
│  │ idle    │ │ working │ │ sleeping│     │shutting │           │
│  └─────────┘ └─────────┘ └─────────┘     └─────────┘           │
└─────────────────────────────────────────────────────────────────┘
```

## Usage Examples

### 1. Asset Loading Integration

```zig
// Register asset loading subsystem
try pool.registerSubsystem(SubsystemConfig{
    .name = "Asset Loading",
    .min_workers = 2,      // Always keep 2 workers ready
    .max_workers = 6,      // Can scale up to 6 during heavy loading
    .priority = .normal,
    .work_item_type = .asset_loading,
});

// Request workers when loading many assets
const allocated_workers = pool.requestWorkers(.asset_loading, 10); // Request 10, might get 6

// Submit asset loading work
const work_item = createAssetLoadingWork(
    asset_id_counter,           // unique work ID
    asset_id,                   // AssetId to load
    asset_loader_ptr,           // AssetLoader context
    .normal,                    // priority
    assetLoadingWorkerFunction, // worker function
);
try pool.submitWork(work_item);
```

### 2. Raytracing BVH Building

```zig
// Register BVH building subsystem with high priority
try pool.registerSubsystem(SubsystemConfig{
    .name = "BVH Building",
    .min_workers = 1,      // Always keep 1 worker for updates
    .max_workers = 8,      // Can use up to 8 for large rebuilds
    .priority = .high,     // High priority for frame rate
    .work_item_type = .bvh_building,
});

// Request workers for large scene rebuild
const allocated_workers = pool.requestWorkers(.bvh_building, 8);

// Submit full BVH rebuild (high priority, resource intensive)
const bvh_work = createBvhBuildingWork(
    work_id,
    scene_data_ptr,
    geometry_count,
    instance_count,
    .full_rebuild,          // Full reconstruction
    .high,                  // High priority
    bvhBuildingWorkerFn,
    raytracing_system_ptr,
);
try pool.submitWork(bvh_work);

// Submit instance-only updates (normal priority, quick)
const instance_work = createBvhBuildingWork(
    work_id + 1,
    scene_data_ptr,
    0,                      // No new geometry
    updated_instance_count,
    .instance_only,         // Just update instances
    .normal,                // Normal priority
    bvhBuildingWorkerFn,
    raytracing_system_ptr,
);
try pool.submitWork(instance_work);
```

### 3. Compute Tasks

```zig
// Register compute tasks (optional, on-demand)
try pool.registerSubsystem(SubsystemConfig{
    .name = "Compute Tasks",
    .min_workers = 0,      // No minimum - only when needed
    .max_workers = 4,      // Max 4 for particle simulation, etc.
    .priority = .normal,
    .work_item_type = .compute_task,
});

// Request workers for particle simulation
const allocated_workers = pool.requestWorkers(.compute_task, 4);

// Submit particle simulation work
const compute_work = createComputeWork(
    work_id,
    particle_system_ptr,
    .{ .x = 64, .y = 64, .z = 1 }, // Thread group dimensions
    .normal,
    particleComputeWorkerFn,
    compute_system_ptr,
);
try pool.submitWork(compute_work);
```

## Dynamic Scaling Behavior

### Scale-Up Conditions
- **Queue Utilization > 80%**: When work items per worker exceeds threshold
- **Subsystem Demand**: When registered subsystems request more workers
- **Priority Work**: High/critical priority work can trigger immediate scaling

### Scale-Down Conditions
- **Queue Utilization < 30%**: When work load decreases significantly
- **Idle Timeout**: Workers idle for >5 seconds shut down automatically
- **Minimum Preservation**: Never scales below registered minimum workers

### Example Scaling Scenario
```
Initial State: 4 workers
├─ Asset Loading: 2 workers (min: 2, max: 6)
├─ BVH Building: 1 worker  (min: 1, max: 8)
└─ Compute: 1 worker       (min: 0, max: 4)

Large Scene Load Event:
├─ Asset Loading requests 6 workers → scales to 8 total workers
├─ BVH Building requests 8 workers  → scales to 12 total workers
└─ High work queue (40+ items)      → scales to 16 total workers (max)

Work Completion:
├─ Queue drains to 5 items          → no immediate change
├─ Workers become idle              → gradual scale-down over 5+ seconds
└─ Steady State: 4 workers          → maintains minimum requirements
```

## Integration with Existing Systems

### AssetLoader Migration
```zig
// Old system:
const thread_pool = try ThreadPool.init(allocator, 8, assetWorkerThread);

// New system:
const enhanced_pool = try allocator.create(EnhancedThreadPool);
enhanced_pool.* = try EnhancedThreadPool.init(allocator, 16);

try enhanced_pool.registerSubsystem(SubsystemConfig{
    .name = "Asset Loading",
    .min_workers = 2,
    .max_workers = 8,
    .priority = .normal,
    .work_item_type = .asset_loading,
});

try enhanced_pool.start(4); // Start with 4 workers
```

### Raytracing System Integration
```zig
// In raytracing_system.zig
pub fn requestBvhRebuild(self: *RaytracingSystem, scene: *Scene) !void {
    // Request workers based on scene complexity
    const geometry_count = self.countSceneGeometry(scene);
    const requested_workers = if (geometry_count > 1000) 8 else 4;
    
    const allocated = self.thread_pool.requestWorkers(.bvh_building, requested_workers);
    
    // Submit BLAS building work (can be parallelized)
    for (scene.geometries) |geometry, i| {
        const blas_work = createBvhBuildingWork(
            self.work_id_counter + i,
            geometry,
            1, // One geometry per work item
            0, // No instances for BLAS
            .full_rebuild,
            .high,
            self.blasBuildingWorker,
            self,
        );
        try self.thread_pool.submitWork(blas_work);
    }
    
    // Submit TLAS building work (depends on BLAS completion)
    const tlas_work = createBvhBuildingWork(
        self.work_id_counter + 1000,
        scene,
        0, // No new geometry
        scene.instances.len,
        .instance_only,
        .high,
        self.tlasBuildingWorker,
        self,
    );
    try self.thread_pool.submitWork(tlas_work);
}
```

## Performance Benefits

### 1. **Resource Efficiency**
- **No Wasted Threads**: Only creates workers when actually needed
- **Intelligent Distribution**: Allocates resources where they provide most benefit
- **Automatic Cleanup**: Idle workers shut down to free resources

### 2. **Responsiveness**
- **Priority Scheduling**: Critical work (frame-rate affecting) gets processed first
- **Demand-Based Scaling**: Scales up quickly when work spikes occur
- **Subsystem Isolation**: One busy subsystem doesn't starve others

### 3. **Scalability**
- **CPU Utilization**: Efficiently uses all available CPU cores
- **Memory Efficiency**: Only allocates worker stacks when needed
- **Future-Proof**: Easily add new subsystems without architectural changes

## Migration Strategy

### Phase 1: Parallel Implementation
1. Keep existing ThreadPool operational
2. Implement EnhancedThreadPool alongside
3. Create adapter layer for gradual migration
4. Test performance and stability

### Phase 2: Gradual Migration
1. Migrate AssetLoader to use EnhancedThreadPool
2. Implement BVH building on separate threads
3. Add compute task support for particle systems
4. Performance comparison and optimization

### Phase 3: Full Replacement
1. Remove old ThreadPool implementation
2. Optimize enhanced system based on real-world usage
3. Add additional features (work stealing, NUMA awareness)
4. Documentation and developer tools

## Monitoring and Debugging

### Statistics Available
```zig
const stats = pool.getStatistics();
log(.INFO, "pool", "Processed: {}, Failed: {}, Peak workers: {}, Avg time: {}μs", .{
    stats.total_work_items_processed.load(.acquire),
    stats.total_work_items_failed.load(.acquire),
    stats.peak_worker_count.load(.acquire),
    stats.average_work_time_us.load(.acquire),
});
```

### Callback System
```zig
// Monitor worker scaling
pool.setWorkerCountChangedCallback(onWorkerCountChanged);

fn onWorkerCountChanged(old_count: u32, new_count: u32) void {
    log(.INFO, "scaling", "Workers: {} -> {} ({})", .{
        old_count, new_count, if (new_count > old_count) "scale up" else "scale down"
    });
}
```

This enhanced system provides a robust foundation for multi-threaded operations in ZulkanZengine, particularly important for the upcoming BVH building requirements in the raytracing system.