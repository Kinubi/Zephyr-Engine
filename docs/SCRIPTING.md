# Scripting subsystem (notes & non-engine tasks)

This document summarizes the current scripting subsystem state (Lua + ScriptRunner + StatePool) and lists non-engine tasks to finish before full engine integration.

## Current state (feature branch)

- ScriptRunner: enqueues scripts and submits WorkItems to the engine `ThreadPool`.
- StatePool: generic pool for leasing per-job resources (used for `lua_State`).
- Lua bindings: `engine/src/scripting/lua_bindings.zig` wraps create/destroy/execute and returns allocator-owned messages for errors/return values.
- ActionQueue: thread-safe queue for main-thread delivery of results (owners must free message slices on pop).
- Examples:
  - `examples/script_demo.zig` — demonstrates state persistence across two calls using a StatePool size of 1.
  - `examples/script_multi_demo.zig` — enqueues multiple concurrent jobs to stress the pool and ThreadPool integration.
- Tests:
  - `engine/src/scripting/state_pool.zig` contains unit tests for acquire/release, tryAcquire, and acquireTimeout.
  - `engine/src/scripting/script_runner_integration_test.zig` is an integration test that exercises ScriptRunner + StatePool end-to-end.
  - Both tests are wired into `zig build test` via `build.zig`.

## Contracts & ownership notes

- `executeLuaBuffer(allocator, state, buf)` allocates an error or return-message using the provided allocator; callers are responsible for freeing the returned `[]u8` slice exactly once (main thread consumer or callback).
- `Action.message` is `?[]u8` and is owned by the queue consumer; they must free it via the same allocator that created it (usually `page_allocator` in examples).
- `StatePool.acquire()` returns an exclusive `*anyopaque` resource that must be returned via `release()`.

## Non-engine tasks (recommended, prioritized)

1) Wire up lower-latency waiting for `StatePool.acquire()` (high priority)
   - Problem: current blocking acquire is implemented with polling + short sleep. This works but causes unnecessary wakeups and millisecond latency.
   - Options:
     - Use a condition-variable or native OS semaphore with try-wait semantics to block threads efficiently.
     - Implement a small wait-notify using `std.Thread.Condition` (if available in the std of the toolchain) or create platform shims.
   - Deliverable: replace polling loop with a proper wait/notify, preserving tryAcquire/acquireTimeout behavior.

2) Robust timeout/cancellation and error handling (medium priority)
   - Problem: long-running or stuck Lua scripts can block worker threads or hold a `lua_State` indefinitely.
   - Options:
     - Use `acquireTimeout()` to limit how long a job waits for a state and fail-fast with a clear Action error.
     - Implement cooperative script timeouts via Lua debug hooks (lua_sethook) to periodically check a cancellation flag.
     - As a last resort, execute scripts in OS threads that can be terminated—this is heavy and platform-dependent.
   - Deliverable: support configurable script timeouts; have ScriptRunner return timeout errors to ActionQueue.

3) Message lifecycle audits (medium priority)
   - Problem: allocator/free ownership must be unambiguous across threads.
   - Action: grep for `allocator.free(...)` across scripting code and examples; ensure only `[]u8` slices (not raw pointers) are passed to `free` and every allocated message has exactly one free path.
   - Deliverable: short audit commit and small fixes where mismatches are found.

4) Improve tests / add CI step (medium priority)
   - Current: StatePool unit tests + ScriptRunner integration test are added and runnable with `zig build test` locally.
   - Action: Add a lightweight CI workflow (GitHub Actions) to run `zig build test` on Linux (and optionally macOS) — ensure environment provides `lua` system library or install Lua as part of the job.
   - Deliverable: `.github/workflows/ci.yaml` that runs tests.

5) More integration & stress tests (low priority)
   - Add tests that enqueue many concurrent scripts, test `acquireTimeout` races, and simulate high-throughput ActionQueue usage.

6) Optional optimization: per-worker `lua_State` caching (low priority)
   - Problem: Central StatePool can be contended under heavy load.
   - Option: keep a worker-local `lua_State` in each ThreadPool worker (fast path) and use StatePool only as fallback. Requires ThreadPool changes to expose worker-local storage or lifecycle hooks.

7) Documentation & examples (ongoing)
   - Add docs describing ScriptRunner API, StatePool semantics, ActionQueue ownership, and examples usage (this file is the start).

## How to run the tests/examples locally

Build and run tests:

```fish
cd /path/to/ZulkanZengine
zig build test
```

Run the demo examples:

```fish
zig build run-script-demo
zig build run-script-multi
```

## Next step before engine integration

Complete items 1–3 above (StatePool wait improvements, timeouts/cancellation, message lifecycle audit). These make the scripting subsystem robust enough to be owned by the engine and used by other systems safely.

Once you're ready I can start the engine integration (create `ScriptingSystem`, export `ScriptRunner` in `zephyr.zig`, and wire ActionQueue into the main loop). I'll hold off until you commit the doc changes.

---
Document last updated: 2025-10-31
Scripting subsystem design — Lua integration

Goal

Add a safe, high-performance scripting subsystem to the engine using Lua. The subsystem should:

- Support running user scripts to control game logic, editor tools, and ui.
- Be safe with respect to Lua's threading model.
- Be efficient: use background worker threads for script execution and minimize allocation overhead.
- Provide a small, well-defined bridge for scripts to call into engine functionality.

Design summary

We choose "Option B" — a dedicated scripting subsystem that runs script jobs on a configurable pool of scripting worker threads. Each scripting worker owns and keeps a dedicated `lua_State` instance. Script jobs are enqueued into a thread-safe job queue and workers are awakened via a semaphore. This gives us these properties:

- No concurrent access to the same `lua_State` (each worker has exclusive access to its state).
- Workers can run scripts in parallel (N script threads) without requiring a global Lua mutex.
- Scripts can execute as background jobs (good for AI, procedural generation, asset scripting) and post results back to the main thread.
- Job scheduling can reuse existing engine patterns (semaphores, queues, thread lifecycle management).

Key components

- ScriptJob
  - Fields: id, script bytes/string, arguments (opaque), completion callback / promise handle, allocator.
  - Jobs are allocated on the heap and owned by the queue until a worker consumes them.

- ScriptRunner (public API)
  - init(allocator, num_workers)
  - deinit()
  - enqueueScript(script: []const u8, ctx: *anyopaque, callback: ?fn(*anyopaque, result) ) -> job_id
  - Worker threads: each worker maintains a `lua_State *L`, initializes it on start (open libs or restricted set), and runs a loop:
    - wait on semaphore
    - pull one or many jobs from the queue
    - execute script in its `L`, capturing any errors
    - call the job's completion callback (on worker thread) or enqueue result for main-thread consumption
    - destroy job memory

- Job queue
  - Protected by a mutex and signalled by a semaphore. The queue holds ScriptJob pointers.
  - We intentionally keep the queue implementation simple to start (ArrayList + remove(0)). We can later replace with a lock-free queue if needed.

- Result dispatch
  - Two modes for delivery:
    1) Worker-callback: the job includes a callback executed on the worker thread when the script finishes. The callback must be thread-safe.
    2) Main-thread delivery: the job can ask for its result to be posted back to the main thread via World.userdata or an engine-provided response queue (preferred for engine state mutation).

- Lua binding strategy
  - Expose a minimal C API to scripts:
    - `engine.log(level, text)`
    - `engine.spawn_entity(template)` (returns an id or request handle)
    - `engine.post_to_main_thread(fn_id, data)` (enqueues a main-thread action)
  - Bindings are small C functions that push/pop Lua stack and call into engine functions (thread-safe variants or enqueued actions).

Concurrency & safety

- Each worker owns `lua_State *L` and calls `lua_gc` periodically (e.g., after `n` jobs or `k` bytes allocated).
- Worker callbacks that mutate engine state should not modify engine state directly unless documented as thread-safe. Prefer using an enqueued main-thread callback pattern:
  - Worker produces a Result object (small, POD) and enqueues an Action into an engine main-thread queue protected by a semaphore (we already use a render_thread-like pattern). Main thread processes these actions at a frame barrier.
- For scripts that require immediate main-thread access, the engine can provide a synchronous RPC-style helper that enqueues a request and blocks the script worker until main thread processes it. Use this only sparingly.

Implementation plan (initial)

Phase 1 (MVP) — create the core:
- docs/SCRIPTING.md (this file)
- engine/src/scripting/script_runner.zig: ScriptRunner with
  - job struct, queue, semaphore, worker threads
  - enqueueScript API
  - placeholder Lua integration (stubs) so compilation succeeds
- Tests: small unit test that enqueues N synthetic jobs and ensures workers process them and callbacks are invoked.

Phase 2 — Lua binding and main-thread integration:
- Add `@cImport` wrapper for Lua and link instructions in build.zig
- Implement real script execution inside worker threads (loadstring, pcall)
- Provide safe bindings and a main-thread action queue

Phase 3 — polish:
- Add per-worker GC tuning, pooling for script memory, profiling hooks, and sandboxing options
- Add editor integration: allow live hot-reload of scripts, console, and REPL support

Open design questions

- Do you want scripts to be able to synchronously call main-thread engine APIs (RPC) or only asynchronous posting?
- How many script workers should be default (1 for deterministic, CPU_count-1 for throughput)? We can expose this as a runtime config.


Contact

If you want I can start implementing Phase 1 now and wire a tiny demo that uses the new ScriptRunner to run a trivial script job. Let me know any preferences about default worker count and result delivery model.
