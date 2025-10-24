# Threaded Rendering Design Document

**Version:** 1.0  
**Date:** October 24, 2025  
**Author:** ZulkanZengine Team  
**Status:** Design Proposal

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Current Architecture](#current-architecture)
3. [Threading Opportunities](#threading-opportunities)
4. [Proposed Architecture](#proposed-architecture)
5. [Implementation Phases](#implementation-phases)
6. [Vulkan Thread Safety Considerations](#vulkan-thread-safety-considerations)
7. [Performance Analysis](#performance-analysis)
8. [Risk Assessment](#risk-assessment)
9. [Future Extensions](#future-extensions)

---

## Executive Summary

This document outlines a design for leveraging the existing ThreadPool infrastructure to parallelize rendering operations in ZulkanZengine. The current rendering pipeline is entirely single-threaded on the CPU side, leaving significant performance on the table for multi-core systems.

### Goals
- **Reduce frame time** by parallelizing CPU-bound rendering tasks
- **Improve scalability** across systems with varying core counts
- **Maintain determinism** and avoid race conditions
- **Leverage existing ThreadPool** with minimal architectural changes

### Key Metrics
- **Current CPU bottleneck:** ~60-70% of frame time spent in single-threaded ECS queries and command buffer recording
- **Target improvement:** 30-50% reduction in CPU frame time on 8+ core systems
- **Risk level:** Medium (Vulkan thread safety requires careful design)

---

## Current Architecture

### Single-Threaded Rendering Flow

```
Frame N:
  1. Main Thread: ECS Update (transform hierarchies, animations)
  2. Main Thread: Scene Update (particles, lights, culling)
  3. Main Thread: RenderSystem.checkForChanges() - ECS queries
  4. Main Thread: Build render caches (raster + raytracing)
  5. Main Thread: Command buffer recording
     - GeometryPass.execute()
     - PathTracingPass.execute() 
     - LightVolumePass.execute()
     - ParticlePass.execute()
  6. Main Thread: Submit command buffers
  7. GPU: Execute commands
```

### Existing ThreadPool Subsystems

```zig
// Already registered in app.zig:
- hot_reload (1-2 workers, low priority)
- bvh_building (1-4 workers, critical priority)  
- custom_work (1-2 workers, low priority)
- ecs_update (2-8 workers, normal priority)      // Currently unused for rendering
- Enhanced Asset Loading (1-6 workers)
- GPU Asset Processing (1-4 workers)
```

**Observation:** The `ecs_update` subsystem exists but is not utilized for rendering workloads.

---

## Threading Opportunities

### High-Value Parallelization Points

#### 1. **ECS Component Queries** (High Impact)
```zig
// Current: Single-threaded iteration
pub fn extractRenderData(self: *RenderSystem, world: *World) !RenderData {
    for (world.entities) |entity| {
        // Query Transform + MeshRenderer for each entity
        // ~15-20μs per entity on complex scenes
    }
}

// Proposed: Parallel batches
// Split entities into chunks, process in parallel
// Gather results, merge into single cache
```

**Expected Speedup:** 3-4x on 8-core systems (Amdahl's law limited by merge phase)

#### 2. **Command Buffer Recording** (Medium-High Impact)
```zig
// Current: Single primary command buffer
executeImpl(frame_info) {
    for (objects) |object| {
        cmdPushConstants(...)
        object.mesh.draw(...)  // ~2-3μs per draw call
    }
}

// Proposed: Secondary command buffers per thread
// Each worker records subset of draw calls
// Primary command buffer executes secondaries
```

**Expected Speedup:** 2-3x on 8-core systems (limited by driver overhead)

#### 3. **Parallel Cache Building** (Medium Impact)
```zig
// Current: Sequential cache builds
buildRasterCache() -> buildRaytracingCache()

// Proposed: Concurrent cache builders
// Raster and raytracing caches built in parallel
// Both depend on same ECS query results (read-only access safe)
```

**Expected Speedup:** 1.5-2x (caches have data dependencies)

#### 4. **Frustum Culling** (Future - High Impact)
```zig
// When visibility culling is implemented:
// Parallel frustum tests for 1000s of objects
// Each thread processes chunk of transforms
// ~0.5μs per object, highly parallel
```

**Expected Speedup:** 5-8x on 8-core systems (embarrassingly parallel)

---

## Proposed Architecture

### Phase 1: Parallel ECS Queries

#### Design

```zig
// New subsystem registration in app.zig
try thread_pool.registerSubsystem(.{
    .name = "render_extraction",
    .min_workers = 2,
    .max_workers = 8,
    .priority = .high,  // Frame-critical work
    .work_item_type = .render_extraction,
});

// RenderSystem.extractRenderData() implementation
pub fn extractRenderData(self: *RenderSystem, world: *World) !RenderData {
    const entity_count = world.entities.len;
    const worker_count = self.thread_pool.getActiveWorkerCount(.render_extraction);
    const chunk_size = (entity_count + worker_count - 1) / worker_count;
    
    // Allocate per-thread results
    var thread_results = try self.allocator.alloc(ThreadLocalResults, worker_count);
    defer self.allocator.free(thread_results);
    
    // Submit parallel work
    for (0..worker_count) |i| {
        const start = i * chunk_size;
        const end = @min(start + chunk_size, entity_count);
        
        try self.thread_pool.submitWork(.{
            .type = .render_extraction,
            .priority = .high,
            .function = extractEntitiesChunk,
            .context = .{
                .world = world,
                .start = start,
                .end = end,
                .results = &thread_results[i],
            },
        });
    }
    
    // Wait for completion
    try self.thread_pool.waitForCompletion(.render_extraction);
    
    // Merge results (single-threaded, fast)
    return mergeThreadResults(thread_results);
}
```

#### Thread Safety Analysis

| Resource | Access Pattern | Safety Mechanism |
|----------|----------------|------------------|
| `World.entities` | Read-only | No locking needed |
| `Transform` components | Read-only | No locking needed |
| `MeshRenderer` components | Read-only | No locking needed |
| `thread_results[i]` | Write (unique index per thread) | No locking needed |
| AssetManager queries | Read-only (asset pointers) | Already thread-safe |

**Conclusion:** This phase requires NO synchronization primitives if we guarantee no ECS modifications during extraction.

### Phase 2: Secondary Command Buffers

#### Current Implementation Status

GraphicsContext already provides secondary command buffer support via:
- `beginWorkerCommandBuffer()` - Allocates from thread-local command pools
- `endWorkerCommandBuffer()` - Collects buffers for later execution
- `executeCollectedSecondaryBuffers()` - Executes on primary command buffer
- `cleanupSubmittedSecondaryBuffers()` - Cleanup after frame submission

**Current Limitations:**
1. ⚠️ Designed for async copy operations, not rendering
2. ⚠️ Empty inheritance info (won't inherit pipeline bindings)
3. ⚠️ Uses `simultaneous_use_bit` (for overlapping async work, not parallel recording)
4. ⚠️ No support for dynamic rendering inheritance

**Required Enhancements:**

```zig
// Add new method to GraphicsContext for rendering secondary buffers
pub fn beginRenderingSecondaryBuffer(
    self: *GraphicsContext,
    pipeline: vk.Pipeline,
    pipeline_layout: vk.PipelineLayout,
    color_format: vk.Format,
    depth_format: vk.Format,
) !SecondaryCommandBuffer {
    const pool = try self.getThreadCommandPool();
    
    var alloc_info = vk.CommandBufferAllocateInfo{
        .command_pool = pool,
        .level = .secondary,
        .command_buffer_count = 1,
    };
    
    var command_buffer: vk.CommandBuffer = undefined;
    {
        self.command_pool_mutex.lock();
        defer self.command_pool_mutex.unlock();
        try self.vkd.allocateCommandBuffers(self.dev, &alloc_info, @ptrCast(&command_buffer));
    }
    
    // Dynamic rendering inheritance (VK 1.3 / KHR_dynamic_rendering)
    var dynamic_rendering_info = vk.CommandBufferInheritanceRenderingInfoKHR{
        .color_attachment_count = 1,
        .p_color_attachment_formats = &[_]vk.Format{color_format},
        .depth_attachment_format = depth_format,
        .stencil_attachment_format = .undefined,
        .rasterization_samples = .{ .@"1_bit" = true },
    };
    
    const inheritance_info = vk.CommandBufferInheritanceInfo{
        .p_next = &dynamic_rendering_info,  // Chain dynamic rendering info
        .render_pass = .null_handle,  // Not used with dynamic rendering
        .subpass = 0,
        .framebuffer = .null_handle,
        .occlusion_query_enable = vk.FALSE,
        .query_flags = .{},
        .pipeline_statistics = .{},
    };
    
    const begin_info = vk.CommandBufferBeginInfo{
        .flags = .{
            .one_time_submit_bit = true,
            .render_pass_continue_bit = true,  // Inherit render state
        },
        .p_inheritance_info = &inheritance_info,
    };
    
    {
        self.command_pool_mutex.lock();
        defer self.command_pool_mutex.unlock();
        try self.vkd.beginCommandBuffer(command_buffer, &begin_info);
    }
    
    return SecondaryCommandBuffer.init(self.allocator, pool, command_buffer);
}
```

#### Design

```zig
// GeometryPass structure additions
pub const GeometryPass = struct {
    // ... existing fields ...
    
    // No need to store command buffers - GraphicsContext manages them!
    // Secondary buffers are automatically collected and executed
};

// Modified execute implementation
fn executeImpl(base: *RenderPass, frame_info: FrameInfo) !void {
    const self: *GeometryPass = @fieldParentPtr("base", base);
    
    const raster_data = try self.render_system.getRasterData();
    const object_count = raster_data.objects.len;
    const worker_count = self.thread_pool.getActiveWorkerCount(.render_recording);
    
    // Begin primary command buffer
    const primary_cmd = frame_info.command_buffer;
    
    // Setup dynamic rendering
    const rendering = DynamicRenderingHelper.init(...);
    rendering.begin(self.graphics_context, primary_cmd);
    
    // Bind pipeline once on primary (inherited by secondaries)
    try self.pipeline_system.bindPipelineWithDescriptorSets(
        primary_cmd, 
        self.geometry_pipeline, 
        frame_info.current_frame
    );
    
    // Submit parallel recording work to thread pool
    const chunk_size = (object_count + worker_count - 1) / worker_count;
    for (0..worker_count) |i| {
        const start = i * chunk_size;
        const end = @min(start + chunk_size, object_count);
        
        try self.thread_pool.submitWork(.{
            .type = .render_recording,
            .priority = .critical,
            .function = recordDrawCommands,
            .context = .{
                .gc = self.graphics_context,
                .objects = raster_data.objects[start..end],
                .pipeline = self.cached_pipeline_handle,
                .pipeline_layout = self.cached_pipeline_layout,
                .color_format = self.swapchain_color_format,
                .depth_format = self.swapchain_depth_format,
            },
        });
    }
    
    // Wait for all workers to finish recording
    try self.thread_pool.waitForCompletion(.render_recording);
    
    // Execute all collected secondary buffers (managed by GraphicsContext)
    try self.graphics_context.executeCollectedSecondaryBuffers(primary_cmd);
    
    rendering.end(self.graphics_context, primary_cmd);
}

// Worker thread function
fn recordDrawCommands(context: *RecordingContext) !void {
    // GraphicsContext provides the secondary buffer with proper inheritance
    var secondary_cmd = try context.gc.beginRenderingSecondaryBuffer(
        context.pipeline,
        context.pipeline_layout,
        context.color_format,
        context.depth_format,
    );
    
    const cmd = secondary_cmd.command_buffer;
    
    // Pipeline and descriptor sets already inherited from primary!
    // Just record draw calls
    for (context.objects) |object| {
        context.gc.vkd.cmdPushConstants(
            cmd, 
            context.pipeline_layout,
            .{ .vertex_bit = true, .fragment_bit = true },
            0,
            @sizeOf(GeometryPushConstants),
            &GeometryPushConstants{
                .transform = object.transform,
                .normal_matrix = object.transform,
                .material_index = object.material_index,
            },
        );
        object.mesh_handle.getMesh().draw(context.gc.*, cmd);
    }
    
    // GraphicsContext collects this automatically
    try context.gc.endWorkerCommandBuffer(&secondary_cmd);
}
```

#### Vulkan Requirements

1. **Command Pools:** ✅ Already implemented - Thread-local pools via `getThreadCommandPool()`
2. **Secondary Command Buffers:** ✅ Infrastructure exists - needs rendering enhancements
3. **Dynamic Rendering Inheritance:** ⚠️ Requires `VkCommandBufferInheritanceRenderingInfoKHR`
4. **Execution:** ✅ Already implemented - `executeCollectedSecondaryBuffers()`
5. **Cleanup:** ✅ Already implemented - `cleanupSubmittedSecondaryBuffers()`

**Implementation Checklist:**
- [ ] Add `beginRenderingSecondaryBuffer()` to GraphicsContext
- [ ] Add dynamic rendering inheritance info support
- [ ] Test with VK_KHR_dynamic_rendering extension
- [ ] Verify descriptor set inheritance works correctly
- [ ] Profile driver overhead on target GPUs (AMD/NVIDIA/Intel)

#### Performance Considerations

**Pros:**
- True parallel command buffer recording
- Scales with draw call count
- No synchronization needed (GraphicsContext handles thread safety)
- ✅ Infrastructure mostly complete (thread pools, command pools, collection system)

**Cons:**
- Driver overhead for secondary command buffers (~10-15% on some drivers)
- ⚠️ Requires enhancement for dynamic rendering support
- Worth it only if draw call count > 500

**Decision Point:** Implement `beginRenderingSecondaryBuffer()` then profile. Only enable if >500 draw calls AND net speedup observed.

### Phase 3: Parallel Cache Building

#### Design

```zig
pub fn checkForChanges(self: *RenderSystem, world: *World, asset_manager: *AssetManager) !void {
    // ... change detection logic ...
    
    if (changes_detected) {
        // Submit parallel cache building
        var raster_future = try self.thread_pool.submitWork(.{
            .type = .cache_building,
            .priority = .high,
            .function = buildRasterCacheWorker,
            .context = .{ .system = self, .world = world, .asset_manager = asset_manager },
        });
        
        var rt_future = try self.thread_pool.submitWork(.{
            .type = .cache_building,
            .priority = .high,
            .function = buildRaytracingCacheWorker,
            .context = .{ .system = self, .world = world, .asset_manager = asset_manager },
        });
        
        // Wait for both to complete
        try raster_future.wait();
        try rt_future.wait();
    }
}
```

**Data Dependencies:**
- Both caches read same ECS query results (safe - read-only)
- Each cache writes to separate memory (safe - no overlap)
- AssetManager queries are read-only (safe - already thread-safe)

**Expected Speedup:** 1.5-2x (caches overlap but not perfectly parallel due to different workloads)

---

## Implementation Phases

### Phase 1: Parallel ECS Extraction (Week 1-2)
**Priority:** HIGH  
**Risk:** LOW  
**Complexity:** Medium

**Tasks:**
1. Add `render_extraction` subsystem to ThreadPool
2. Implement chunked entity iteration in `RenderSystem.extractRenderData()`
3. Add per-thread result buffers
4. Implement merge phase
5. Add frame budget enforcement (max 2ms for extraction)
6. Profile and tune chunk sizes

**Success Criteria:**
- 3x speedup in `extractRenderData()` on 8-core systems
- No race conditions (validate with ThreadSanitizer)
- Frame time reduction of 10-15%

### Phase 2: Parallel Cache Building (Week 3)
**Priority:** MEDIUM  
**Risk:** LOW  
**Complexity:** Low

**Tasks:**
1. Add `cache_building` subsystem
2. Refactor cache builders to accept external contexts
3. Implement parallel dispatch in `checkForChanges()`
4. Add synchronization with `waitForCompletion()`

**Success Criteria:**
- 1.5x speedup in cache building
- Frame time reduction of 5-7%

### Phase 3: Secondary Command Buffers (Week 4-5) [OPTIONAL]
**Priority:** LOW  
**Risk:** MEDIUM  
**Complexity:** Medium-Low (infrastructure exists, needs rendering extensions)

**Decision Gate:** Only implement if draw call count > 500 in production scenes

**Tasks:**
1. ✅ Thread-local command pools (already implemented)
2. ✅ Secondary buffer collection system (already implemented)
3. ⚠️ Add `beginRenderingSecondaryBuffer()` with dynamic rendering inheritance
4. Update GeometryPass to use parallel recording
5. Update LightVolumePass (if beneficial - only 1 draw call currently)
6. Profile driver overhead vs. speedup on target GPUs

**Success Criteria:**
- 2-3x speedup in command recording for >500 draw calls
- No increase in GPU time (validate with RenderDoc)
- Frame time reduction of 10-15%
- No regressions on any driver (AMD/NVIDIA/Intel)

### Phase 4: Frustum Culling [FUTURE]
**Priority:** FUTURE  
**Risk:** LOW  
**Complexity:** Medium

**Blocked By:** Visibility culling system implementation

---

## Vulkan Thread Safety Considerations

### Safe Operations (No Synchronization Needed)

| Operation | Thread Safety | Notes |
|-----------|---------------|-------|
| Query descriptor sets | ✅ Thread-safe | Read-only after creation |
| Read pipeline layouts | ✅ Thread-safe | Immutable after creation |
| Read uniform buffers | ✅ Thread-safe | Per-frame buffers indexed by frame |
| Query textures | ✅ Thread-safe | AssetManager uses internal locking |
| Secondary cmdbuf recording | ✅ Thread-safe | Each thread uses own pool |

### Unsafe Operations (Require Synchronization)

| Operation | Solution | Notes |
|-----------|----------|-------|
| Primary cmdbuf recording | ❌ Main thread only | Vulkan spec: single writer |
| Descriptor set writes | ❌ Per-frame isolation | Already handled by ring buffers |
| Pipeline creation | 🔒 ShaderManager mutex | Already implemented |
| Asset loading | 🔒 AssetManager mutex | Already implemented |

### Memory Ordering

```zig
// Required memory barriers for parallel cache building:

// After parallel ECS extraction:
std.atomic.fence(.SeqCst);  // Ensure all writes visible before merge

// After cache building:
self.renderables_dirty = false;  // Single atomic write, no fence needed

// Command buffer submission already has implicit barriers
```

---

## Performance Analysis

### Expected Frame Time Breakdown

**Current (Single-Threaded):**
```
Total Frame Time: 16.67ms (60 FPS target)
├─ CPU Work: 12ms
│  ├─ ECS Extraction: 4ms       <- TARGET
│  ├─ Cache Building: 2ms       <- TARGET  
│  ├─ Command Recording: 3ms    <- TARGET (optional)
│  └─ Other: 3ms
└─ GPU Work: 8ms
```

**After Phase 1 + 2 (Parallel Extraction + Caches):**
```
Total Frame Time: 13.5ms (74 FPS achieved)
├─ CPU Work: 8.5ms (-29% from baseline)
│  ├─ ECS Extraction: 1.5ms     ✅ 3x speedup
│  ├─ Cache Building: 1ms       ✅ 2x speedup
│  ├─ Command Recording: 3ms    
│  └─ Other: 3ms
└─ GPU Work: 8ms
```

**After Phase 3 (+ Secondary Cmdbufs):**
```
Total Frame Time: 11.5ms (87 FPS achieved)
├─ CPU Work: 7ms (-42% from baseline)
│  ├─ ECS Extraction: 1.5ms
│  ├─ Cache Building: 1ms
│  ├─ Command Recording: 1.5ms  ✅ 2x speedup
│  └─ Other: 3ms
└─ GPU Work: 8ms
```

**Note:** Phase 3 speedup assumes >500 draw calls. With current optimizations (instanced light rendering, visibility filtering), typical scenes have 50-200 draw calls, making Phase 3 low priority.

### Scalability Analysis

| CPU Cores | Phase 1 Speedup | Phase 2 Speedup | Phase 3 Speedup | Total FPS Gain |
|-----------|-----------------|-----------------|-----------------|----------------|
| 4 cores   | 2.5x            | 1.3x            | 1.5x            | +12 FPS        |
| 8 cores   | 3.5x            | 1.8x            | 2x              | +20 FPS        |
| 16 cores  | 4.0x            | 2.0x            | 2.5x            | +22 FPS        |

**Note:** Diminishing returns beyond 8 cores due to Amdahl's law (GPU becomes bottleneck). Phase 3 benefits assume >500 draw calls.

---

## Risk Assessment

### Technical Risks

| Risk | Probability | Impact | Mitigation |
|------|-------------|--------|------------|
| Race conditions in ECS | LOW | HIGH | Use ThreadSanitizer, read-only queries |
| Driver bugs with secondary cmdbufs | LOW | MEDIUM | GraphicsContext infrastructure battle-tested |
| Thread pool starvation | LOW | MEDIUM | Reserve workers for rendering subsystem |
| Cache coherency issues | LOW | MEDIUM | Explicit memory barriers |
| Regression in single-threaded perf | LOW | HIGH | Keep single-threaded fallback |
| Dynamic rendering inheritance unsupported | LOW | MEDIUM | Check VK_KHR_dynamic_rendering support |

### Performance Risks

| Risk | Probability | Impact | Mitigation |
|------|-------------|--------|------------|
| Thread spawning overhead | LOW | LOW | Pre-warmed worker threads |
| Context switching overhead | MEDIUM | MEDIUM | Tune chunk sizes for cache locality |
| Memory contention | MEDIUM | MEDIUM | Per-thread allocators for temp data |
| False sharing | LOW | LOW | Cache-line align per-thread structures |

---

## Future Extensions

### Post-MVP Enhancements

1. **Compute-Based Culling** (GPU-driven)
   - Move frustum culling to compute shader
   - Indirect draw calls eliminate CPU loop
   - Requires: VK_EXT_mesh_shader or compute + indirect

2. **Async Compute for Particles**
   - Overlap particle simulation with rendering
   - Requires: Separate async compute queue
   - Expected gain: 2-3ms per frame

3. **Multi-GPU Support** (AFR/SFR)
   - Alternate frame rendering across GPUs
   - Leverage thread pool for multi-device management
   - Expected gain: 2x throughput (not latency)

4. **CPU Occlusion Culling**
   - Hierarchical Z-buffer on CPU
   - Parallel occlusion tests per thread
   - Expected gain: 50-70% draw call reduction

---

## Appendix: Code Patterns

### Pattern 1: Parallel For-Each

```zig
pub fn parallelForEach(
    comptime T: type,
    items: []const T,
    thread_pool: *ThreadPool,
    work_type: WorkItemType,
    function: fn(*T) void,
) !void {
    const worker_count = thread_pool.getActiveWorkerCount(work_type);
    const chunk_size = (items.len + worker_count - 1) / worker_count;
    
    for (0..worker_count) |i| {
        const start = i * chunk_size;
        const end = @min(start + chunk_size, items.len);
        
        try thread_pool.submitWork(.{
            .type = work_type,
            .priority = .normal,
            .function = function,
            .context = items[start..end],
        });
    }
    
    try thread_pool.waitForCompletion(work_type);
}
```

### Pattern 2: Parallel Reduce

```zig
pub fn parallelReduce(
    comptime T: type,
    comptime R: type,
    items: []const T,
    thread_pool: *ThreadPool,
    map_fn: fn(T) R,
    reduce_fn: fn(R, R) R,
    identity: R,
) !R {
    var thread_results = try allocator.alloc(R, worker_count);
    defer allocator.free(thread_results);
    
    // Initialize to identity
    for (thread_results) |*result| result.* = identity;
    
    // Parallel map phase
    for (0..worker_count) |i| {
        try thread_pool.submitWork(.{
            .function = mapWorker,
            .context = .{ .items = chunk, .result = &thread_results[i] },
        });
    }
    
    try thread_pool.waitForCompletion(.render_extraction);
    
    // Sequential reduce phase (fast for small worker_count)
    var final_result = identity;
    for (thread_results) |result| {
        final_result = reduce_fn(final_result, result);
    }
    
    return final_result;
}
```

### Pattern 3: Future-Based Async

```zig
pub const Future = struct {
    completed: std.atomic.Atomic(bool),
    result: ?anyerror!void,
    
    pub fn wait(self: *Future) !void {
        while (!self.completed.load(.Acquire)) {
            std.Thread.yield() catch {};
        }
        return self.result.?;
    }
};

pub fn asyncBuildCache(self: *RenderSystem) !*Future {
    var future = try self.allocator.create(Future);
    future.* = .{
        .completed = std.atomic.Atomic(bool).init(false),
        .result = null,
    };
    
    try self.thread_pool.submitWork(.{
        .function = buildCacheWorker,
        .context = .{ .system = self, .future = future },
    });
    
    return future;
}
```

---

## References

- [Vulkan Spec: Threading](https://registry.khronos.org/vulkan/specs/1.3-extensions/html/chap3.html#fundamentals-threadingbehavior)
- [GDC 2016: Multithreading in Doom](https://www.gdcvault.com/play/1023408/Multithreading-the-Entire-Destiny)
- [SIGGRAPH 2015: Multithreaded Rendering](https://advances.realtimerendering.com/s2015/aaltonenhaar_siggraph2015_combined_final_footer_220dpi.pdf)
- [ThreadPool Implementation: ZulkanZengine/src/threading/thread_pool.zig](../src/threading/thread_pool.zig)

---

**Document Revision History:**
- v1.0 (2025-10-24): Initial design proposal
