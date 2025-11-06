Instanced Rendering — Design & Implementation Plan

Overview

This document captures a compact plan to migrate the engine to an instanced-only raster rendering path. It describes the data contract, how caches are built on the main thread, how GPU uploads are done on the render thread safely (ring cache with MAX_FRAMES_IN_FLIGHT), lifetime rules, edge cases, and a minimal verification checklist.

Goals

- Build instance data on the main thread (no Vulkan calls).
- Upload instance data to device-local SSBOs on the render thread only and cache them across frames.
- Keep GPU buffers alive while in-flight via a per-frame ring (size = MAX_FRAMES_IN_FLIGHT).
- Replace per-object draws with drawInstanced for each unique mesh batch.
- Avoid descriptor-set lifecycle validation warnings by keeping buffers alive until commands finish.

1) Data contract

- CPU layout (engine): `InstanceData`
  - model: mat4 (16 x f32)
  - material_index: u32
  - no padding, the struct will use align()
  - Must match the shader SSBO layout using `std430`.

- RenderData shape (in `render_data_types.zig`):
  - `InstancedBatch`:
    - mesh_ptr: *const Mesh
    - instance_data: []const InstanceData (system memory, owned by RenderSystem cache)
    - instance_count: u32

Contract notes
- The shader expects std430 alignment. The Engine `InstanceData` must use the same field order/padding.
- `InstanceData` must be trivially memcpy'able to staging buffers.

2) High-level flow

- Main thread (RenderSystem):
  - Build caches when scene/renderables change (snapshot-based):
    - Deduplicate by `mesh_ptr` (optionally include material if necessary).
    - For each unique mesh, allocate an `InstanceData[]` in the allocator and populate it with model + material index for each instance.
    - Write these batches into `cached_raster_data[write_idx].batches` (no Vulkan/GC resources created here).
  - `RenderSystem.deinit()` frees the `InstanceData[]` arrays.

- Render thread (GeometryPass.execute):
  - For each `InstancedBatch` in `cached_raster_data`:
    - Look up per-batch GPU cache entry keyed by (`mesh_ptr`, cache_generation).
    - If a valid device-local SSBO already exists for the current cache generation, reuse it.
    - Otherwise:
      - Create a host-visible staging `Buffer` sized for N instances of `InstanceData`.
      - memcpy() the `instance_data` into the staging buffer and unmap.
      - Create a device-local `Buffer` (storage_buffer_bit | transfer_dst_bit, device_local_bit).
      - Call `GraphicsContext.copyFromStagingBuffer(device_buf.buffer, &staging, size)` (render thread only).
      - Put the `device_buf` into `deferred_instance_buffers[frame_index]` (an ArrayList(Buffer)) to ensure it remains alive for MAX_FRAMES_IN_FLIGHT frames.
      - Store a lightweight cache entry mapping the batch key to the `device_buf` handle and cache-generation.
    - Bind the device-local buffer to the pipeline's SSBO binding (via ResourceBinder) for the current frame, then call `mesh.drawInstanced(cmd, instance_count, 0)`.

3) Ring cache & lifetime semantics

- `deferred_instance_buffers` is kept per `GeometryPass` as `[MAX_FRAMES_IN_FLIGHT]ArrayList(Buffer)`.
- Ownership summary:
  - CPU `InstanceData[]` arrays are owned by the `RenderSystem` cache (one per cached slot).
  - Device-local `Buffer` objects (SSBOs) are owned by the per-batch GPU cache entries in `GeometryPass` while they are the "current" buffer for a batch, and ALSO appended to the `deferred_instance_buffers[frame_index]` for lifetime extension.

- Frame behavior (render thread / `GeometryPass`):
  1. At the start of each frame, call `deinit()` / free on all `Buffer` objects stored in `deferred_instance_buffers[frame_index]` (these were created >= MAX_FRAMES_IN_FLIGHT frames ago and are now safe to destroy).
  2. When creating a new device-local buffer for a batch, append the new `Buffer` to `deferred_instance_buffers[frame_index]` immediately after the GPU copy completes.
  3. Store a lightweight cache entry mapping `(mesh_ptr, generation)` -> (device_buffer_handle, last_used_frame_index). The cache entry keeps a reference/pointer to the device buffer but does NOT directly free it when invalidated.

- Invalidation and safety:
  - On cache rebuild the `RenderSystem` increments a small `generation` counter and publishes it with `cached_raster_data` (or embeds it in the batch). GeometryPass uses `(mesh_ptr, generation)` to determine whether an existing device buffer is still valid.
  - When a cache entry becomes stale (generation changed), the entry must be removed from the cache map but its device buffer must NOT be destroyed immediately. Because the buffer was previously appended to some `deferred_instance_buffers[frame_index]` when it was created, it will be freed only when that ring slot is cleared (safe: >= MAX_FRAMES_IN_FLIGHT frames later).

- This guarantees correctness: no device-local buffer is destroyed while it may still be referenced by GPU work recorded using it.

4) Cache key / generation

- Key: `mesh_ptr + generation_id` (generation increments each time `RenderSystem` rebuilds cached_raster_data).
- Generation can be a small `u32` counter stored in the `RenderSystem` and published alongside `cached_raster_data` (or embedded in the batch struct if desired).
- GeometryPass checks both `mesh_ptr` and `generation` when looking for an existing device buffer.

5) Cleanup (explicit deinit rules)

Make the ownership and deinit behavior explicit so there is no accumulation of allocations or device resources.

- Where to free CPU `InstanceData[]` arrays:
  - RenderSystem owns the cached CPU arrays. Any code that replaces a cached slot (the WRITE buffer at `cached_raster_data[write_idx]`) MUST free the previous `InstanceData[]` arrays stored in that slot before overwriting it. Concretely:
    1. At the top of `rebuildCaches` / `rebuildCachesFromSnapshot`, before building into `write_idx`, check `if (self.cached_raster_data[write_idx]) |old| { free(old.batches[].instance_data); free(old.batches); }` (or equivalent) to release CPU memory owned by that slot.
    2. After building new `InstancedBatch` objects and their `InstanceData[]` buffers, write the new value into `self.cached_raster_data[write_idx]` and atomically flip the active index.
  - `RenderSystem.deinit()` must iterate both cached slots (active and inactive) and free any `InstanceData[]` arrays still present there.

- Where to free device-local `Buffer`s (SSBOs):
  - GeometryPass is responsible for actual `Buffer.deinit()` calls because only the render thread creates and destroys GPU resources.
  - Each frame, at frame index `i`, GeometryPass must free all `Buffer`s contained in `deferred_instance_buffers[i]` at the start of the frame (these buffers were appended >= MAX_FRAMES_IN_FLIGHT frames earlier).
  - When a per-batch cache entry is invalidated (e.g., generation changed), do NOT call `Buffer.deinit()` immediately from the cache-invalidation path. Instead, remove the entry from the lookup map so it won't be reused; the physical `Buffer` was already appended to some `deferred_instance_buffers[...]` when created and will be freed later by the ring slot when its turn comes.
  - On `GeometryPass.teardown()` (engine shutdown), iterate all ring slots and `deinit()` every remaining `Buffer`, then deinit the `ArrayList`s themselves. This is the final cleanup if the application exits before all ring slots rotated.

- Additional invariant checks (recommended):
  - Assert that every `InstancedBatch.instance_data` is allocated from the same `RenderSystem.allocator`, and that `RenderSystem` only frees these arrays (single owner).
  - Log or assert when a per-batch cache overwrite occurs to ensure the old `device_buffer` was previously appended into the ring (so it will be freed later).

- Pseudo-step summary for a safe rebuild (main thread + render thread interplay):
  1. Main thread (RenderSystem.rebuildCaches):
     - Determine `write_idx` and free previously allocated CPU arrays in that slot (if any).
     - Allocate and populate new `InstanceData[]` arrays and assign to `cached_raster_data[write_idx].batches`.
     - Increment `cache_generation` and write it alongside the cached data (or embed per-batch).
     - Atomically flip `active_cache_index` to make the new cache visible to render thread.

  2. Render thread (GeometryPass, next frame):
     - Read `cached_raster_data[active_idx]` and observe the `generation` for each batch.
     - For each batch, consult GPU cache map keyed by `(mesh_ptr, generation)`.
       - If buffer exists: reuse it.
       - If not: create staging -> device buffer, append device buffer to `deferred_instance_buffers[current_frame]`, insert (mesh_ptr,generation)->device_buffer into GPU cache map.

  3. Later frames: when ring slot `i` is processed, GeometryPass frees all `Buffer`s that were appended to `deferred_instance_buffers[i]`.

Following these explicit rules prevents the buildup you observed: CPU arrays are freed when the write buffer is reused, and device buffers are freed deterministically by the render-thread ring.

6) Edge cases and considerations

- Zero-instance batches: skip upload and draw.
- Extremely large instance counts: consider chunked uploads or staging buffer sizing limits. Document maximum instance buffer size if any.
- Partial asset loads: skip instances where `mesh_ptr` is null.
- Pipeline hot-reload: resource binder already rebinds pipeline + descriptors per draw; ensure cached SSBOs remain valid across pipeline updates or rebind steps.
- Descriptor set validation: keeping device buffers alive for the ring lifetime prevents "destroyed while still in use" warnings.

7) Tests and verification steps

- Unit test: small snapshot with 2 models using the same mesh. Call `buildCachesFromSnapshotSingleThreaded` and assert `cached_raster_data.batches.len == 1` and `instance_count == 2`.
- Integration run: enable Vulkan validation layers and run an example scene; verify no descriptor lifetime warnings.
- Performance check: measure draw calls for repeated meshes before/after.

8) Implementation checklist (next commits)

- [ ] Add `generation` to `RenderSystem` cache and publish it with cached data.
- [ ] Implement deduplication and creation of `InstanceData[]` arrays in `buildCachesFromSnapshotSingleThreaded`.
- [ ] GeometryPass: implement per-batch device buffer cache and upload flow using `deferred_instance_buffers` ring.
- [ ] Replace per-object draw path with instanced draw-only path.
- [ ] Add tests for cache building and run with Vulkan validation layers.
- [ ] Remove legacy `RenderableObject` references and update docs/examples.

9) Quick commands

Build & run (from repository root):

```fish
zig build
zig build run
```

When iterating, watch build output and Vulkan validation logs (enable validation layers in engine config).


Appendix — Small example `InstanceData` (Zig)

```zig
pub const InstanceData = extern struct {
    model: [16]f32,
    material_index: u32,
    _padding: [3]u32 = [_]u32{0} ** 3,
};
```

That's the concise design doc. If you want, I will now implement the per-batch cache in `geometry_pass.zig` and wire generation/versioning through `RenderSystem` (option A from the previous message).