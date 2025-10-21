Simple ECS (EN-TT-like) design

Goal
- Provide a small, ergonomic Entity-Component-System surface (in the spirit of EnTT) in Zig.
- Keep components simple POD structs.
- Allow easy iteration: view(T).each(|entity, comp| ...).
- Add parallel iteration using the existing ThreadPool (chunk-and-spawn) as a second step.

Component contract
- Components are plain structs (no inheritance/virtuals).
- Components are stored in a DenseSet(T) per component type: contiguous array of components and parallel array of EntityId.

World API (minimal)
- world.init(allocator) -> World
- world.registerComponent(comptime T)
- world.emplace(comptime T, entity, value)
- world.getStorage(comptime T) -> *DenseSet(T)
- world.view(comptime T) -> View(T)

View API
- view.each(callback(entity, *const T)) -- simple, single-threaded iteration
- view.each_parallel(chunk_size, callback(entity, *const T)) -- chunk & spawn version using ThreadPool (planned)

Threading model (chunk & spawn)
- For parallel iteration, split the contiguous component array into chunks of N elements.
- For each chunk allocate a small JobCtx on the heap (or an arena) and submit a WorkItem to ThreadPool with a top-level run function pointer and the JobCtx pointer.
- Wait for completion using a wait-group (or by tracking work ids). ThreadPool exposes requestWorkers and submitWork; we'll use a per-stage wait mechanism in the scheduler layer.

Zig-specific notes
- Avoid taking the address of nested functions. We must provide top-level function pointers (or comptime-generated top-level trampolines) for ThreadPool's worker_fn.
- Implement chunked trampolines using a small set of generic top-level runner functions that interpret JobCtx (hold a pointer to a function pointer + data pointer), or generate dedicated top-level functions at comptime when feasible.

Example usage
- const w = try World.init(allocator);
- try w.registerComponent(Transform);
- const e = w.createEntity(0);
- try w.emplace(Transform, e, Transform.init(...));
- var view = w.view(Transform);
- view.each(fn (ent, tptr) void { ... });

Next steps
- Implement view.each_parallel using ThreadPool job submission and a small wait-group.
- Add more sophisticated queries (multi-component views) and an ergonomic foreach that yields typed tuples.
