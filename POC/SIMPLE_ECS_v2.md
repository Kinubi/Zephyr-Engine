# Simple ECS (EnTT-like) design — FINAL

This document describes a compact EnTT-inspired ECS for Zig where:
- Components are plain POD structs.
- Each component type provides `update()` and `render()` methods.
- There is no central "system" scheduler — component methods are dispatched directly to the engine ThreadPool as work items (chunked for efficiency).

Why this shape?
- EnTT's view API is ergonomic and expressive; it lets callers choose between callback-based iteration, structured tuple iteration, or forward-iteration + `get`.
- Making components own `update`/`render` keeps system code minimal and allows fine-grained parallelism without a global scheduler.

---

## Quick ENTT reference (C++)
```cpp
#include <entt/entt.hpp>

struct position { float x; float y; };
struct velocity { float dx; float dy; };

void update(entt::registry &registry) {
    auto view = registry.view<const position, velocity>();

    view.each([](const auto &pos, auto &vel) { /* ... */ });
    view.each([](auto entity, const auto &pos, auto &vel) { /* ... */ });
    for (auto [entity, pos, vel] : view.each()) { /* ... */ }
    for (auto entity : view) { auto &vel = view.get<velocity>(entity); }
}
```

---

## Target Zig API

### World (minimal API)
- `pub fn init(allocator: std.mem.Allocator) !World`
- `pub fn registerComponent(comptime T: type) !void`
- `pub fn emplace(comptime T: type, self: *World, ent: EntityId, value: T) !void`
- `pub fn view(comptime T: type, self: *World) ?*View(T)`

### View (single-type example)
- `pub fn each(self: *View(T), callback: fn(EntityId, *T) void) void`
  - single-threaded convenience; callback receives entity and mutable pointer to component
- `pub fn each_parallel(self: *View(T), comptime chunk_size: usize, callback: fn([]EntityId, []T, f32) void) !void`
  - splits storage into chunks of at most `chunk_size` elements and schedules chunk jobs on ThreadPool
- forward iteration: `for (entity in view) { let c = view.get(entity); }`

---

## Component contract (required)
Every component type `T` must provide these methods (exact signatures):
- `pub fn update(self: *T, dt: f32) void`
- `pub fn render(self: *const T) void`

Semantics:
- `update()` is allowed to mutate the component and must be safe to call from worker threads (no unsynchronized global state unless externally synchronized).
- `render()` is logically read-only (takes `*const`) but it may enqueue GPU work via thread-safe command buffers provided by the engine.

### Worker signature amendment
Because the engine ThreadPool expects worker functions of the shape
`fn(ctx: *anyopaque, work: WorkItem) void`, the parallel dispatch surface must expose a worker-style entrypoint for each operation. Concretely:

- Components should still provide idiomatic `update(self: *T, dt: f32)` and `render(self: *const T)` for local/serial calls.
- For MT dispatch the component (or its module) must expose top-level worker functions matching the ThreadPool signature, for example:
    - `pub fn update_worker(ctx: *anyopaque, work: @import("../threading/thread_pool.zig").WorkItem) void`
    - `pub fn render_worker(ctx: *anyopaque, work: @import("../threading/thread_pool.zig").WorkItem) void`

These worker functions unpack a small JobCtx from `work.data.custom.user_data` (or other WorkItem union fields) and invoke the per-element `update()`/`render()` methods inside the worker thread.

This keeps the ThreadPool-level API consistent and makes the MT work happen entirely inside the ThreadPool — callers only need to prepare `WorkItem`s and submit them.

---

## Dispatch model — no scheduler
Important constraint: you requested "No system.tick, no scheduler, etc." — dispatch is always explicit and performed by the caller. The engine provides primitives to submit work to the ThreadPool. Two common patterns:

### 1) Chunked component-method dispatch (recommended)
- Caller: obtains a `View(T)` and calls `each_parallel` providing a chunk callback. The chunk callback runs on worker threads and iterates its slice calling `component.update(dt)` or `component.render()`.
- Advantages: low per-component overhead, good cache locality, easy to implement with the existing ThreadPool.

Pseudocode:
```zig
const view = world.view(Health) orelse return;
try view.each_parallel(comptime 64, fn (ents: []EntityId, comps: []Health, dt: f32) void {
    var i: usize = 0;
    while (i < comps.len) : (i += 1) {
        comps[i].update(dt);
    }
});
```

### 2) Per-component job dispatch (higher overhead)
- Caller submits one job per component to the ThreadPool. JobCtx carries a pointer to the instance and an enum (Update/Render) or a direct function pointer to call.
- Use only when per-component work is heavy or when components have very different work lengths.

---

## Zig constraints & runner strategy
- ThreadPool worker functions must be top-level function pointers (no nested function address-of). Two practical approaches:
  - Generic runner: a single top-level `run_chunk_job(ctx: *c_void)` function that inspects a `JobKind` and casts `ctx` to the right chunk type, then invokes the per-chunk callback stored inside `ctx` (function pointer or enum). This central runner is simple and flexible.
  - Comptime-generated runner: generate a small top-level trampoline per `(T, operation)` pair at comptime which directly calls the typed loop. This is faster and safer but more complex.

### JobCtx layout (recommended chunk job)
```zig
pub const JobKind = enum { Update, Render };

pub const ChunkJob(T: type) = struct {
    kind: JobKind,
    ents: []EntityId,
    comps: []T,
    dt: f32,
};
```

The generic top-level runner receives `*c_void` and performs a type-dispatch using a stored `tag` or by using a dynamic Job registry keyed by type name (kept small and internal).

---

## Edge cases and safety
- Mutating other component storages concurrently: NOT SAFE unless the caller establishes ordering or uses locks/command buffers.
- Emplace/remove during concurrent iteration: NOT ALLOWED. Use a deferred command queue.
- Components must be Send/Sync-compatible semantics — they must not rely on thread-locals unless synchronized.

---

## Examples

### 1) Create entities and emplace components (Zig-style pseudocode):
```zig
var w = try World.init(allocator);
try w.registerComponent(Position);
try w.registerComponent(Velocity);

for (i in 0..10) |i| {
    const e = w.registry.create(0);
    try w.emplace(Position, e, Position{ .x = i, .y = i });
    if ((i % 2) == 0) try w.emplace(Velocity, e, Velocity{ .dx = i * .1, .dy = i * .1 });
}

// Run updates in parallel
const view = w.view(Velocity) orelse return;
try view.each_parallel(comptime 32, fn (ents: []EntityId, comps: []Velocity, dt: f32) void {
    var i: usize = 0;
    while (i < comps.len) : (i += 1) {
        comps[i].update(dt);
    }
}, 0.016);
```

### 2) Per-component function pointer dispatch (less common):
```zig
// Prepare a small JobCtx { ptr: &component, kind: Update }
// Submit to ThreadPool with the generic runner which inspects kind and calls update(ptr, dt)
```

---

## Testing and acceptance
Unit tests / POC harness should:
- create many entities and components
- run `each_parallel` with various chunk sizes
- validate components received their `update()` calls (e.g., counters)
- run under ThreadSanitizer if available and under stress to validate safety

Acceptance criteria
- Single-threaded `each` implemented and usable.
- `each_parallel` implemented using chunk-and-spawn with the engine ThreadPool and a generic top-level runner.
- Component types implement `update(self: *T, dt: f32)` and `render(self: *const T)` and are invoked by chunk jobs without a central scheduler.

---

## Next implementation steps (concrete)
1. Implement a compact `DenseSet(T)` and `World` storing storages in an `AutoHashMap` keyed by `@typeName(T)`.
2. Implement `View(T).each` and `View(T).each_parallel` (generic runner + `ChunkJob` allocation).
3. Add a POC harness `POC/ecs_parallel.zig` that creates entities, emplaces components with trivial `update()` counters, runs parallel updates, and verifies results.
4. If needed for perf: add comptime-generated trampolines for tight inner loops.

## Migration roadmap for the rest of the engine
1. **Introduce ECS façade alongside existing systems**
    - Create an `ecs.World` instance inside `app.zig` that is initialised during engine bootstrap but keep legacy systems running.
    - Register components that already exist as ad-hoc structs (e.g. `Transform`, `Velocity`, renderable metadata) so both the classic code and the ECS can read the same data during the overlap period.

2. **Wrap current update/render logic as component methods**
    - For each subsystem, move the per-object logic into component `update`/`render` functions (or thin wrappers around the current code).
    - Where state currently lives in manager structs, split it into (a) component data owned by the registry and (b) global resources (pipelines, caches) passed as context when submitting chunk jobs.

3. **Adopt ECS-driven scheduling subsystem-by-subsystem**
    - Start with self-contained features (particles, simple render passes). Replace the manual loops with ECS `view.each` or `view.each_parallel` calls that enqueue ThreadPool work.
    - Validate behaviour and performance, then delete the old loops for that subsystem. Repeat for the next subsystem until everything runs through ECS views.

4. **Route async/worker jobs through the generic ECS worker**
    - Update existing ThreadPool job producers (particle updates, hot-reload callbacks) so they create ECS chunk jobs instead of subsystem-specific jobs. This keeps the worker model uniform.

5. **Remove legacy data paths**
    - Once all subsystems read/write component storage, remove duplicate containers/managers that previously owned component data.
    - Replace any direct pointer sharing with registry lookups (handles) to keep ownership centralised.

6. **Final cleanup & tooling**
    - Add debug tooling to visualise active entities/components to match the previous ad-hoc inspector functionality.
    - Document the ECS usage patterns for new subsystems, highlighting how to register components, create chunk jobs, and submit work via the ThreadPool.
