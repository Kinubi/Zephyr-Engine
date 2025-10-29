# Entity Component System (ECS)

## Overview

The Zephyr-Engine ECS provides a data-oriented foundation for game and simulation logic. It keeps component storage contiguous, schedules work across a shared thread pool, and extracts frame data for the renderer. The current implementation focuses on deterministic per-frame updates and low-latency data extraction while remaining extendable for future systems such as AI, input scripting, or animation.

Key traits:

- **Explicit lifecycle** – `World.beginFrame` and the scheduler `run` call gate all per-frame work.
- **Chunked job dispatch** – Systems create chunked tasks through the scheduler for multicore execution.
- **Guard-based storage access** – Component sets use read/write guards to manage synchronization without copying data.
- **Renderer extraction** – Extraction systems push component state to frame buffers for the render pipeline.

## Core Types

| Type | File | Purpose |
|------|------|---------|
| `ecs.world.World` | `src/ecs/world.zig` | Owns entity registry, component stores, per-frame buffers, and the scheduler |
| `ecs.scheduler.Scheduler` | `src/ecs/scheduler.zig` | Queues system jobs on the shared thread pool, tracks stage metrics |
| `ecs.component_dense_set.DenseSet(T)` | `src/ecs/component_dense_set.zig` | Sparse set optimized for contiguous component storage and fast lookups |
| `ecs.entity_registry.EntityRegistry` | `src/ecs/entity_registry.zig` | Generates and recycles entity IDs |
| `ecs.stage_handles.StageHandles` | `src/ecs/stage_handles.zig` | Describes scheduler stage indices used by systems |
| `ecs.bootstrap` | `src/ecs/bootstrap.zig` | Sets up default stages/systems and seeds initial entities |
| `ecs.systems.defaults` | `src/ecs/systems/default.zig` | Built-in transform integration and extraction jobs |

### Stage Handle Layout

The default bootstrap registers the following stages in-order:

| Handle Field | Stage Name | Purpose |
|--------------|------------|---------|
| `asset_resolve` | `asset_resolve` | Background asset processing before simulation |
| `input_script` | `input_script` | Player input, scripting hooks |
| `simulation` | `physics_animation` | Physics, animation, and gameplay logic |
| `visibility` | `visibility` | Culling or visibility classification |
| `render_extraction` | `render_extraction` | Extract ECS data into renderer-friendly buffers |
| `presentation` | `presentation` | Last-minute presentation tasks |

You can append additional stages by calling `scheduler.addStage` before or after `configureWorld`. Store the returned index in a custom struct parallel to `StageHandles` so that systems know which stage to target.

## Initialization Flow

1. **Create the world**
   ```zig
   const world = try ecs.world.World.init(allocator, .{ .thread_pool = thread_pool });
   ```
2. **Configure stages and systems**
   ```zig
   const handles = try ecs.bootstrap.configureWorld(&world);
   ```
   `configureWorld` registers the default stage layout:
   - `asset_resolve`
   - `input_script`
   - `physics_animation`
   - `visibility`
   - `render_extraction`
   - `presentation`

   It also registers the default simulation/extraction systems and seeds a demo entity with `Transform` + `Velocity`.

3. **Per-frame loop**
   ```zig
   try world.beginFrame(frame_index, frame_dt);
   try ecs.bootstrap.tick(&world, handles);
   ```
   - `beginFrame` updates frame counters and clears extraction buffers.
   - `tick` delegates to the scheduler to run all systems for the configured stages.

## Scheduler Stages & Metrics

The scheduler drives each stage sequentially. Inside a stage, systems can enqueue jobs that run in parallel on the shared thread pool. After each stage completes the scheduler records:

- `Stage.last_job_count` – number of jobs spawned during the most recent run.
- `Stage.last_duration_ns` – total nanoseconds spent preparing, dispatching, and waiting for jobs.

Use the helper APIs to inspect timing and load:

```zig
const stage_count = scheduler.stageCount();
var i: usize = 0;
while (i < stage_count) : (i += 1) {
    if (scheduler.stageMetrics(i)) |metrics| {
        log(.DEBUG, "ecs.stages", "{s}: jobs={} duration={}ns",
            .{ metrics.name, metrics.last_job_count, metrics.last_duration_ns });
    }
}
```

### Metric Interpretation

- **Zero jobs** usually means the stage had no work (guards returned length `0`) or every system ran a single-chunk fast path.
- **Duration spikes** with low job counts typically indicate setup time (arena allocation, logging) rather than work; inspect the corresponding systems.
- **High job counts** with near-constant duration show good parallel scaling; if duration grows proportionally, revisit chunk size or worker availability.

For more granular insight, add per-system timers inside `prepare` or use the thread pool's statistics to correlate job execution with worker utilization.

### Scheduler Configuration

`World.init` forwards a `Scheduler.Config` to control worker usage and prioritization:

```zig
const scheduler_cfg = ecs.scheduler.Scheduler.Config{
    .subsystem_name = "ecs_update",
    .min_workers = 2,
    .max_workers = 8,
    .priority = .high,
};

const world = try ecs.world.World.init(allocator, .{
    .thread_pool = thread_pool,
    .scheduler = scheduler_cfg,
});
```

- Increase `min_workers` to keep more workers online for consistently heavy frames.
- Clamp `max_workers` if you want ECS to leave headroom for other subsystems.
- Adjust `priority` when competing with asset streaming or GPU tasks.

## Component Storage

Components live inside `DenseSet(T)` storages owned by the world.

- **Adding**: `try world.addComponent(entity, component_value)` returns `true` if a new component slot was created.
- **Removing**: `world.removeComponent(T, entity)` removes and compacts storage.
- **Borrowing (read-only)**: `world.borrowComponent(T, entity)` returns a `ComponentReadHandle` that unlocks on `release()`.
- **Borrowing (mutable)**: `world.borrowComponentMut(T, entity)` returns a `ComponentWriteHandle`.
- **Iteration**: `world.forEach(.{ComponentA, ComponentB}, context, callback)` acquires read guards for each component and iterates over matching entities.

Storages use a sparse index to map entity IDs to dense array slots. SIMD helpers populate and scan the sparse array in fast blocks. Synchronization relies on `std.Thread.RwLock` with guard wrappers so systems can safely share access.

### Entity Lifecycle

1. `world.createEntity(tag)` allocates a fresh `EntityId` (tag can differentiate gameplay categories).
2. Components attach via `world.addComponent` which creates backing storage on demand.
3. Systems operate exclusively on live entities; destroying an entity automatically removes its components from every storage through `ComponentEntry.remove_fn`.
4. Destroyed IDs return to the registry’s free list; systems must be robust to sparse indices.

### Guard Patterns

- **Read guard**: `var guard = storage.acquireRead(); defer guard.release();` Grants immutable access to `items`, `entityAt`, `valueAt`, and `get`.
- **Write guard**: `var guard = storage.acquireWrite(); defer guard.release();` Adds `put` and mutable `get` for in-place edits.
- **Shared guards**: For multithreaded jobs, acquire once in `prepare`, store in a shared context, and release only after the final job completes (see Simulation/Extraction examples below).

## Default Components

Defined in `src/ecs/components.zig`:

- `Transform` – position/rotation/scale with a cached `local_to_world` matrix. Includes `init` and `updateLocalToWorld` helper.
- `Velocity` – linear and angular velocity vectors.

These form the minimal dataset needed to animate simple objects and extract render positions.

## System Execution Model

Systems register with a scheduler stage via `scheduler.addSystem(stage, descriptor)`. Each descriptor provides:

- `name` – diagnostic label.
- `context` – static configuration pointer (often a struct with tunables).
- `prepare(context_ptr, world_ptr, builder)` – builds jobs for the stage.

### Job Building

`prepare` is responsible for:

1. Acquiring component guards.
2. Determining the number of entities (`len`).
3. Calculating chunk sizes (default 256) and allocating job contexts.
4. Calling `builder.spawn(JobDesc)` for each chunk.

Example from the default transform integration system:

```zig
const chunk_size = if (ctx.chunk_size == 0) 1 else ctx.chunk_size;
const chunk_count = (count + chunk_size - 1) / chunk_size;

// Single chunk => run inline for low overhead
if (chunk_count <= 1) { /* ... */ return; }

const shared = try builder.allocator.create(SimulationShared);
shared.* = .{
    .velocity_guard = velocity_guard,
    .transform_guard = transform_guard,
    .remaining = std.atomic.Value(u32).init(@intCast(chunk_count)),
};

while (index < count) : (index += chunk_size) {
    const end = @min(count, index + chunk_size);
    const job_ctx = try builder.allocator.create(SimulationJobContext);
    job_ctx.* = .{ .shared = shared, .start = index, .end = end };
    try builder.spawn(.{ .name = ctx.name, .context = @ptrCast(job_ctx), .run = simulationRun });
}
```

### Job Execution & Guard Sharing

`simulationRun` accesses the shared guard to avoid reacquiring storage on every chunk:

```zig
const shared = chunk.shared;
const velocity_guard = &shared.velocity_guard;
const transform_guard = &shared.transform_guard;
const dt = world.frameDt();

var i = chunk.start;
while (i < chunk.end) : (i += 1) {
    const entity = velocity_guard.entityAt(i);
    const velocity_ptr = velocity_guard.valueAt(i);
    if (transform_guard.get(entity)) |transform_ptr| {
        const delta = velocity_ptr.linear.scale(dt);
        transform_ptr.translation = transform_ptr.translation.add(delta);
        components.updateLocalToWorld(transform_ptr);
    }
}

if (shared.remaining.fetchSub(1, .acq_rel) == 1) {
    shared.transform_guard.release();
    shared.velocity_guard.release();
}
```

The last job to finish releases the guards, keeping synchronization costs constant regardless of chunk count.

The same pattern applies to extraction:

```zig
const shared = chunk.shared;
const transform_guard = &shared.transform_guard;
const positions = world.extractionPositionsMut();

var i = chunk.start;
while (i < chunk.end) : (i += 1) {
    positions[i] = transform_guard.valueAt(i).translation;
}

if (shared.remaining.fetchSub(1, .acq_rel) == 1) {
    shared.transform_guard.release();
}
```

This structure keeps write operations thread-safe without redundant locking per job.

### Extraction System

The default extraction system copies transform translations into the world’s `extraction_positions` buffer, which the renderer consumes each frame. It mirrors the simulation model: single chunk fast-path, shared guard for parallel jobs, and per-stage capacity management via `world.ensureExtractionCapacity`.

## Thread Pool Integration

- Scheduler jobs use the global `thread_pool.ThreadPool`. The pool already registers the `ecs_update` subsystem with configurable min/max worker counts from `Scheduler.Config`.
- At dispatch time the scheduler calls `thread_pool.requestWorkers(.ecs_update, job_counter)` to hint at the desired worker count.
- Jobs are submitted via `thread_pool.submitWork`, the same infrastructure used by the asset system and hot reloaders, ensuring consistent prioritization.
- The thread pool tracks active workers per subsystem. Heavy ECS frames may temporarily scale up worker threads; metrics from `ENHANCED_THREAD_POOL.md` can confirm allocation behavior.

## Extending the ECS

1. **Add new components**
   - Define component structs under `src/ecs/components/` (or a new module) and register them where needed.
   - Use `world.ensureStorage` implicit behavior by adding the component during initialization.

2. **Create new systems**
   - Implement `prepare` + `run` pair following the job pattern above.
   - Register the system in `ecs.bootstrap.configureWorld` or a custom bootstrap module.
   - Consider guard sharing to minimize synchronization cost under load.

3. **Custom stages**
   - Call `scheduler.addStage("my_stage")` to create additional scheduling boundaries.
   - Store the returned index in a custom handles struct for later use.

4. **Instrumentation**
   - Use `stageMetrics` to monitor stage load.
   - Add extra logging inside systems to track chunk distribution or per-job timing if necessary.
   - Consider exposing metrics to the renderer HUD or debug UI for live tuning.

### Example: Adding a Health System

```zig
const Health = struct { current: f32, max: f32 };
const HealthStorage = ecs.storage.DenseSet(Health);

const HealthShared = struct {
    guard: HealthStorage.WriteGuard,
};

fn castContextPtr(comptime T: type, ptr: *anyopaque) *T {
    return @ptrCast(@alignCast(ptr));
}

fn healthPrepare(context_ptr: *anyopaque, world_ptr: *anyopaque, builder: *ecs.scheduler.Scheduler.JobBuilder) !void {
    _ = context_ptr;
    const world = castContextPtr(ecs.world.World, world_ptr);
    const storage = world.getStorage(Health) catch return;
    var guard = storage.acquireWrite();
    const count = guard.len();
    if (count == 0) {
        guard.release();
        return;
    }

    const shared = try builder.allocator.create(HealthShared);
    shared.* = .{ .guard = guard };

    const job_ctx = try builder.allocator.create(struct { shared: *HealthShared });
    job_ctx.* = .{ .shared = shared };

    try builder.spawn(.{
        .name = "health_regen",
        .context = @ptrCast(job_ctx),
        .run = healthRun,
    });
}

fn healthRun(context_ptr: *anyopaque, world_ptr: *anyopaque, job_ctx: ecs.scheduler.Scheduler.JobContext) void {
    _ = world_ptr;
    _ = job_ctx;
    const ctx = castContextPtr(struct { shared: *HealthShared }, context_ptr);
    const guard = &ctx.shared.guard;
    for (guard.items()) |*value| {
        value.current = @min(value.max, value.current + 1.0);
    }
    guard.release();
}
```

This example bypasses chunking for simplicity. For large datasets reintroduce the chunk pattern and shared guards shown earlier, splitting the dataset across multiple jobs while retaining a single shared guard instance.

## Usage Example

```zig
const handles = try ecs.bootstrap.configureWorld(&world);
const entity = world.createEntity(1);

try world.addComponent(entity, MyComponent.init());
try world.addComponent(entity, components.Transform.init(Math.Vec3.zero(), Math.Vec3.zero(), Math.Vec3.splat(1.0)));

// Within the frame loop
try world.beginFrame(frame_index, delta_time);
try ecs.bootstrap.tick(&world, handles);

const positions = world.extractionPositions();
if (positions.len > 0) {
    log(.DEBUG, "ecs.extract", "first position: {any}", .{positions[0]});
}
```

## Troubleshooting

- **No entities update** – Ensure `world.beginFrame` is called every frame before `tick`; otherwise `frameDt` remains stale and extraction buffers are cleared incorrectly.
- **Missing components** – If a system logs `ComponentNotRegistered`, double-check that you seeded the component via `world.addComponent` or ran the relevant bootstrap that creates its storage.
- **Thread pool starvation** – Monitor `stageMetrics.last_job_count`. If the count spikes without corresponding time reduction, consider adjusting `chunk_size` or increasing `Scheduler.Config.max_workers`.
- **Contention** – Systems that write to the same component storage will serialize; break them into read/write phases or use separate storages where possible.
- **Entity recycling surprises** – Debug logs from `EntityRegistry` can confirm whether IDs are being recycled; ensure systems don't cache stale pointers across frames.
- **Chunk imbalance** – If one job consistently costs more (e.g., uneven work per entity), experiment with smaller chunk sizes or dynamic partitioning logic in `prepare`.

## Future Improvements

- Component archetype grouping for cache-friendly iteration.
- Job dependency graphs between stages.
- Editor introspection utilities using the scheduler metrics API.
- Hot-reloadable system registration.

The current implementation is stable for gameplay prototyping and render extraction, while leaving clear extension points for more advanced ECS features.
