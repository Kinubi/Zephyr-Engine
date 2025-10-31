## Mutex / Lock Cleanup Plan

This document summarizes where mutexes and locks are used in the codebase, what can safely be replaced with lock-free atomic double-buffering (or other lock-free techniques), and a prioritized, low-risk plan to reduce locking contention.

This write-up is based on a review of these files:
- `engine/src/core/graphics_context.zig`
- `engine/src/core/event_bus.zig`
- `engine/src/utils/file_watcher.zig`
- `engine/src/systems/multithreaded_bvh_builder.zig`
- `engine/src/threading/thread_pool.zig`
- `engine/src/assets/hot_reload_manager.zig`
- `engine/src/threading/render_thread.zig`

Summary: there are several proven lock-free patterns already in the project (render-thread snapshot, TLAS atomic swap, cached render data). The biggest wins are replacing high-frequency short critical sections that protect producer->consumer data with atomic double-buffering or per-worker staging. The thread-pool and complex shared hashmaps should remain locked or require a larger refactor to adopt fully lock-free replacement data structures.

---

## Goals

- Reduce lock contention on hot paths (render submission, command buffer lifetime, BVH completions, event queueing).
- Preserve correctness and resource lifetime semantics (Vulkan queue sync, command pool lifetime, acceleration structure lifetime).
- Implement low-risk changes first and iterate.

## High-level candidates and recommendations

1) GraphicsContext: secondary/submitted command buffer lists — HIGH priority

- Why: these lists are written by worker threads (or main/worker producers) and read/consumed by the render thread. They are a clear producer→consumer pattern.
- Recommendation: Replace the mutex-protected lists with a double-buffered structure and an atomic index flip. If multiple producers can append concurrently, use per-producer staging vectors (thread-local) or a short append mutex only for the write-side append while keeping the flip lock-free.

2) MultithreadedBVHBuilder: TLAS result and BLAS completion lists — MEDIUM priority

- Why: BVH building is done in worker threads and results are transferred to the main thread. TLAS tends to be single-writer (easier); BLAS is multi-writer.
- Recommendation: For TLAS, use an atomic swap of a pointer or index to a completed TLAS (single producer). For BLAS, use per-worker small result lists (worker-local) and merge when the main thread polls; that reduces or eliminates contention on `completed_blas` list.

3) EventBus: queued events — MEDIUM priority

- Why: Events are frequently enqueued (GLFW callbacks) and processed by main loop. Current implementation swaps queue under a lock then processes locally (already good).
- Recommendation: Consider a lock-free MPSC queue implementation or a two-buffer atomic swap if you can ensure producers append safely (e.g., single-producer, thread-local staging, or atomically linked lists). If producers remain many and frequent, prefer a battle-tested MPSC queue over fragile DIY lock-free code.

4) FileWatcher and HotReloadManager: watched paths / maps — LOW to MEDIUM priority

- Why: The map of watched paths and mappings are mutated rarely but read in a hot polling loop (watcher). Converting to copy-on-write snapshots or a read-mostly atomic pointer to an immutable snapshot is possible but requires full snapshot/clone code.
- Recommendation: Leave as-is for now, or implement RCU-like snapshots if you need to remove the mutex. Only do if you measure contention here.

5) ThreadPool core queues and subsystem maps — NOT RECOMMENDED for simple double-buffering

- Why: The threadpool requires prioritized multi-producer / multi-consumer semantics and `popIf` semantics — not a fit for a naive double-buffer swap. Converting to a fully lock-free pool is a large refactor (consider a replace-with-tested lock-free queue library or accept the mutex cost).

6) Vulkan queue synchronization (`queue_mutex`) — DO NOT REMOVE

- Why: Vulkan queue access requires external synchronization; you cannot simply replace this lock without detailed per-call ordering guarantees.

---

## Atomic double-buffer pattern (contract)

This is the canonical pattern to adopt for lists used as producer→consumer handoff where one consumer reads whole batches and producers append to the other buffer.

Contract (simple case):

- Data: `buffers: [2]ArrayList(Item)` and `current_read: std.atomic.Value(usize)` which is either 0 or 1.
- Producer(s): append items into `buffers[write_idx]` where `write_idx = 1 - current_read.load(.acquire)`.
- Publisher: when a producer (or the last producer) wants to make the written items visible atomically, it does `current_read.store(write_idx, .release)`.
- Consumer: `read_idx = current_read.load(.acquire)`, process `buffers[read_idx]` completely, then clear it. Consumer sees a consistent snapshot because the flip used release-store.

Important details and edge cases:

- Multi-producer appends: if many threads will append concurrently to the same write-side ArrayList, you need thread-safe append. Options:
  - Use per-thread local staging lists and a final short merge (merge can be done by the publisher under a short lock).
  - Use lock-free linked-list append primitives (harder and error-prone).
  - Keep a small append mutex but flip atomically so consumers never block on appends.
- Release/Acquire ordering: store on flip must use `.release`, consumer load must use `.acquire` to guarantee visibility of initialized items.
- Memory/ownership: after consumer processes list, it must free or deinit resources in a safe context; ensure no lingering references across threads.

---

## Concrete low-risk rollout plan (phases)

Phase 0 — Measurement & tests (always first)

- Add microbenchmarks or instrument the hot paths to measure lock hold times and contention (e.g., secondary buffer append rate, BVH completion rate).
- Add unit tests (threaded) for the atomic flip pattern and for per-worker staging merge.

Phase 1 — GraphicsContext secondary/submitted buffers (low-risk, high-reward)

Steps:
1. Add `secondary_buffers: [2]ArrayList(SecondaryCommandBuffer)` and `submitted_buffers: [2]ArrayList(SecondaryCommandBuffer)` as needed and `atomic indices` (e.g., `secondary_index`, `submitted_index`).
2. Implement producers appending to write-side buffer. If multiple producers are present, add per-worker staging or a short append mutex only for append.
3. Replace mutex-protected swap logic with atomic flip `.store(write_idx, .release)` and update consumer to use `.load(.acquire)`.
4. Run integration tests; stress test heavy worker loads.

Phase 2 — TLAS atomic swap + BLAS per-worker staging

Steps:
1. Implement atomic pointer/index swap for TLAS results (single-writer scenario): worker writes into slot and store index atomically.
2. For BLAS results, change worker completion to push into a worker-local vector; main thread periodically collects and merges them with minimal locking.

Phase 3 — EventBus (optional)

- Evaluate using an existing MPSC queue implementation. If you decide to DIY, implement thread-local staging + atomic swap or lock-free MPSC.

Phase 4 — FileWatcher / HotReload (optional)

- If profiling shows contention, implement snapshot-on-write (clone map and atomically swap pointer) for the watched-paths map. Otherwise keep current lock.

Phase 5 — ThreadPool

- Keep the current mutex-based priority queues for now. If the thread pool shows contention and you want to invest, consider replacing `WorkQueue` with a tested concurrent queue or implement segmented queues (per-priority MPSC with lockless consumers).

---

## Verification and test plan

- Unit tests for atomic flip correctness: producers append, flip, consumer reads expected items; test memory ordering with stress harness.
- Integration tests: run `render_thread_test.zig` and other examples that exercise render thread and workers.
- Stress tests: spawn many worker threads that append secondary command buffers and BLAS results; verify no lost items and correct lifetimes.
- CI: add a lightweight thread-safety test job that runs the atomic flip tests on each PR.

---

## Rollback & monitoring

- Rollback: each change should be isolated in a small PR that updates a single subsystem (e.g., GraphicsContext buffers). Keep the old mutex code reachable (via feature flag) until validated.
- Monitoring: add counters for swap frequency, average processing time, and any failed memory operations.

---

## Risks and mitigations

- Risk: subtle memory ordering bugs (lost updates, partially-initialized items). Mitigation: use `.release` on store and `.acquire` on load and add thorough tests.
- Risk: multi-producer appends remain a bottleneck. Mitigation: prefer worker-local staging or keep a tiny append mutex.
- Risk: lifetime/ownership mistakes for Vulkan objects. Mitigation: never free command-buffers/resources on the consumer without ensuring the producing thread has completed its ownership transfer; add explicit ownership comments and tests.

---

## TL;DR / Actionable checklist


If you'd like, I can implement the Phase 1 change as a small PR and include tests and benchmark harness; otherwise this document can be used as the formal plan for the cleanup work.


Document authored by: automated code review (based on file inspection) — use as guidance, validate with profiling and integration tests before merging.

## Addendum: Atomic BLAS result lists and event-driven TLAS worker

This project uses callbacks/flags today to coordinate BLAS completion and subsequent TLAS builds. A more scalable and simpler approach is to have BLAS workers push completed BLAS results into a per-TLAS-job atomic list and have an event-driven TLAS worker (spawned from rt_system.update) check those job heads and build TLAS when all expected BLAS entries are present.

Why this helps
- Removes many callback/flag interactions and centralizes TLAS decision logic into an event-driven worker.
- Lock-free BLAS result publish (atomic push) scales well with many builder threads.
- Fits cleanly with the existing double-buffered snapshot approach: BLAS results are stable resources the TLAS worker consumes and then publishes the built TLAS into the engine's double-buffered TLAS slot (atomic flip) so render-facing code sees a stable TLAS per frame.
- No hot polling — worker only runs when spawned from rt_system.update, integrating with the frame update cycle.

Recommended pattern (per-job lists)

1) Per-TLAS-job record (registered at TLAS submission time)
  - expected_count: u32
  - completed_count: std.atomic.Value(u32)
  - head: std.atomic.Value(*BlasNode) // lock-free singly-linked list head
  - job_id: u64

2) BLAS worker on completion
  - allocate a BlasNode, populate `BlasResult` (handle + buffer + device address + geometry id)
  - push node into the job's head with a CAS loop (typical lock-free push)
  - increment job.completed_count (optional; can also be derived by counting nodes later)

3) Event-driven TLAS worker (called from rt_system.update)
   - rt_system.update() detects geometry or transform changes and submits a TLAS job
   - TLAS worker immediately checks if BLAS are ready (lookup in registry):
     - Transform-only: all BLAS exist → build TLAS immediately
     - Geometry change: spawn BLAS workers for missing BLAS, set expected_count
   - Worker polls active jobs (only during update, not continuously):
     - Read `completed_count` (atomic load) and compare to `expected_count`
     - If >= expected_count: `head.exchange(null, .acquire)`, gather BLAS results, build TLAS
   - After TLAS is built, publish into the engine's double-buffered TLAS slot (atomic flip)
   - This avoids keeping a CPU core hot with polling and integrates naturally with the frame update cycle.Handling TLAS rebuilds that reuse existing BLAS

- Transform-only TLAS rebuilds (objects moved, no geometry changes) use the same worker code path:
  - TLAS worker checks BLAS registry for required geometry IDs
  - All BLAS are already present → `expected_count` remains 0 or is immediately satisfied
  - Worker builds TLAS immediately with updated instance transforms and existing BLAS handles
- No special `transform_only` flag needed — the worker naturally handles this case by checking BLAS availability

Edge cases & notes
- BLAS failures must be recorded in the BlasNode (status) so TLAS worker can decide whether to fail the job or retry.
- If producers don't know job_id, fall back to a global list + mapping, but per-job heads are strongly preferred to avoid filtering and reinsertion.
- Keep job registration and deregistration operations under a short mutex; only the hot path (push into head and atomically read counts) is lock-free.

API compatibility
- Keep existing BLAS completion callbacks as an optional compatibility mode (the new TLAS worker can call the old callback if configured). Transition TLAS-building callers to submit jobs that specify expected_count and job_id.

Operational note — start implementing
- The TLAS worker is event-driven: spawned from rt_system.update() when geometry or transforms change, not a continuous polling loop.
- Exact flow:
  1. rt_system.update() detects geometry or transform changes
  2. Spawns TLAS worker job via ThreadPool (single job, runs once)
  3. Worker checks BLAS registry for all required geometry IDs
  4. If any BLAS missing: spawn BLAS worker jobs, set expected_count
  5. Worker polls job.completed_count briefly until all BLAS ready
  6. Build TLAS with current transforms and BLAS handles
  7. Publish via atomic flip to stable slot
- This avoids hot polling (no wasted CPU) and integrates cleanly with the existing update cycle.
- Worker polls only during its execution (typically milliseconds), not continuously.
- This design is fully compatible with the engine's double-buffered TLAS publication model and with transform-only TLAS rebuilds that reuse existing BLAS handles.

