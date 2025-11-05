# Scripting System — Design & Reference

## Table of Contents

1. [Overview](#overview)
2. [Design Principles](#design-principles)
3. [Architecture](#architecture)
4. [Key Components](#key-components)
5. [ScriptRunner](#scriptrunner)
6. [StatePool](#statepool)
7. [ActionQueue](#actionqueue)
8. [ScriptingSystem](#scriptingsystem)
9. [Lua Bindings](#lua-bindings)
10. [Execution Flow](#execution-flow)
11. [Memory & Ownership Model](#memory--ownership-model)
12. [Thread Safety](#thread-safety)
13. [Integration Points](#integration-points)
14. [Advanced Features](#advanced-features)
15. [Error Handling](#error-handling)
16. [Performance Considerations](#performance-considerations)
17. [Testing Strategy](#testing-strategy)
18. [Common Patterns](#common-patterns)
19. [Troubleshooting Guide](#troubleshooting-guide)

---

## Overview

The **Scripting System** enables safe, **multi-threaded execution of Lua scripts** in the Zephyr Engine. It provides a bridge between worker-thread script execution and main-thread engine state mutation, balancing throughput with safety.

**Core capabilities:**
- **Asynchronous script execution**: Scripts run on ThreadPool workers without blocking the main thread
- **Resource pooling**: Reusable `lua_State` instances minimize allocation overhead
- **Thread-safe communication**: ActionQueue transfers results and events from workers to main thread
- **CVar integration**: Lua on_change handlers invoked when CVARs change
- **Memory safety**: Explicit ownership rules prevent leaks and use-after-free bugs
- **Lua C API abstraction**: Clean bindings for engine systems (console, CVARs, ECS, etc.)

**Design philosophy:**  
Scripts execute on worker threads but **cannot directly mutate engine state**. Instead, they enqueue **Actions** (messages) that the main thread processes safely. This eliminates data races and provides deterministic engine state updates.

---

## Design Principles

1. **Worker Threads for Throughput, Main Thread for Safety**  
   - Scripts run on ThreadPool workers to avoid blocking the main thread
   - Only the main thread mutates engine state (ECS, renderer, CVARs)
   - Workers communicate via ActionQueue messages

2. **Ownership is Explicit**  
   - Each allocation has a clear owner and lifetime
   - ActionQueue messages allocated with `action_queue.allocator`, freed by consumer
   - Script copies allocated with `script_runner.allocator`, freed after execution
   - Lua strings managed by Lua's GC

3. **No Native Callbacks Across Threads**  
   - Native C function pointers are **intentionally not supported** for cross-thread communication
   - Rationale: Avoids dangling pointers, lifetime management complexity, and data races
   - Use ActionQueue + Lua handlers instead

4. **Resource Pooling for Performance**  
   - `lua_State` creation is expensive (~1ms); pool reuses instances
   - Semaphore-based availability provides lock-free fast path for acquire/release

5. **Fail-Safe Degradation**  
   - If ActionQueue is full, worker logs warning and drops message
   - If StatePool is exhausted, acquire blocks until resource available
   - Lua runtime errors captured and returned as `ExecuteResult.message`

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│                       SCRIPTING SYSTEM                               │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │                   Main Thread                                 │  │
│  │                                                               │  │
│  │  ┌──────────────────┐      ┌──────────────────┐             │  │
│  │  │ ScriptingSystem  │      │   Console UI     │             │  │
│  │  │   .update()      │      │   (executeCmd)   │             │  │
│  │  └────────┬─────────┘      └────────┬─────────┘             │  │
│  │           │                         │                        │  │
│  │           ├─ takePendingChanges ────┤                        │  │
│  │           │   (CVarRegistry)        │                        │  │
│  │           ↓                         ↓                        │  │
│  │  ┌──────────────────────────────────────────┐               │  │
│  │  │       ActionQueue.push(CVarLua)          │               │  │
│  │  └──────────────────┬───────────────────────┘               │  │
│  │                     │                                        │  │
│  │                     ↓                                        │  │
│  │           ┌─────────────────────┐                           │  │
│  │           │  ActionQueue.pop()  │◄─┐                        │  │
│  │           └──────────┬──────────┘  │                        │  │
│  │                      ↓              │                        │  │
│  │         ┌────────────────────────┐  │                       │  │
│  │         │ Dispatch to Lua        │  │                       │  │
│  │         │ - CVarLua → handler    │  │                       │  │
│  │         │ - ScriptResult → log   │  │                       │  │
│  │         └────────────────────────┘  │                       │  │
│  └─────────────────────────────────────┼───────────────────────┘  │
│                                        │                          │
│         ════════════════════════════════════════                 │
│                                        │                          │
│  ┌─────────────────────────────────────┼───────────────────────┐ │
│  │                Worker Threads       │                       │ │
│  │                                     │                       │ │
│  │  ┌──────────────────┐               │                       │ │
│  │  │  ScriptRunner    │               │                       │ │
│  │  │  .enqueueScript()│               │                       │ │
│  │  └────────┬─────────┘               │                       │ │
│  │           │                         │                       │ │
│  │           ↓                         │                       │ │
│  │  ┌──────────────────┐               │                       │ │
│  │  │   ThreadPool     │               │                       │ │
│  │  │  (WorkItem)      │               │                       │ │
│  │  └────────┬─────────┘               │                       │ │
│  │           │                         │                       │ │
│  │           ↓                         │                       │ │
│  │  ┌──────────────────────┐           │                       │ │
│  │  │  StatePool.acquire() │           │                       │ │
│  │  │  → lua_State*        │           │                       │ │
│  │  └──────────┬───────────┘           │                       │ │
│  │             ↓                       │                       │ │
│  │  ┌──────────────────────┐           │                       │ │
│  │  │ executeLuaBuffer()   │           │                       │ │
│  │  │ (run Lua script)     │           │                       │ │
│  │  └──────────┬───────────┘           │                       │ │
│  │             ↓                       │                       │ │
│  │  ┌──────────────────────┐           │                       │ │
│  │  │  StatePool.release() │           │                       │ │
│  │  └──────────┬───────────┘           │                       │ │
│  │             │                       │                       │ │
│  │             ↓                       │                       │ │
│  │  ┌──────────────────────────────┐   │                       │ │
│  │  │ ActionQueue.push(Result)     │───┘                       │ │
│  │  │ (allocate with queue.alloc)  │                           │ │
│  │  └──────────────────────────────┘                           │ │
│  └──────────────────────────────────────────────────────────────┘ │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────────┐ │
│  │                       StatePool                              │ │
│  │  [lua_State*, lua_State*, lua_State*, ...]                  │ │
│  │  Semaphore: available_count                                 │ │
│  └──────────────────────────────────────────────────────────────┘ │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────────┐ │
│  │                     ActionQueue                              │ │
│  │  [Action{CVarLua}, Action{ScriptResult}, ...]               │ │
│  │  Mutex + Semaphore for thread-safe push/pop                 │ │
│  └──────────────────────────────────────────────────────────────┘ │
│                                                                  │
└──────────────────────────────────────────────────────────────────────┘
```

**Execution phases:**
1. **Enqueue**: Main thread calls `ScriptRunner.enqueueScript(script_bytes)` → copies to runner allocator → submits WorkItem to ThreadPool
2. **Execute**: Worker acquires `lua_State` → runs `executeLuaBuffer` → releases state
3. **Report**: Worker allocates result message with `action_queue.allocator` → pushes to ActionQueue
4. **Dispatch**: Main thread pops ActionQueue → processes `CVarLua`/`ScriptResult` actions → frees message

---

## Key Components

### Component Overview

| Component | File | Purpose | Thread Affinity |
|-----------|------|---------|-----------------|
| **ScriptRunner** | `script_runner.zig` | Enqueues scripts to ThreadPool | Main → Worker |
| **StatePool** | `state_pool.zig` | Pools reusable `lua_State` instances | Worker (acquire/release) |
| **ActionQueue** | `action_queue.zig` | Thread-safe message queue | Worker → Main |
| **ScriptingSystem** | `scripting_system.zig` | Main-thread dispatcher, CVar integration | Main |
| **Lua Bindings** | `lua_bindings.zig` | C API wrappers for engine systems | Worker (read), Main (write) |

---

## ScriptRunner

### Purpose
Provides high-level interface for enqueuing Lua scripts to execute on worker threads.

### Key Functions

| Function | Signature | Description |
|----------|-----------|-------------|
| `init` | `ScriptRunner.init(allocator, thread_pool, state_pool, action_queue)` | Create runner |
| `deinit` | `runner.deinit()` | Free internal state |
| `enqueueScript` | `runner.enqueueScript(script_bytes, on_complete)` | Submit script for async execution |

### Execution Flow

```zig
pub fn enqueueScript(
    self: *ScriptRunner,
    script: []const u8,
    on_complete: ?*const fn([]const u8) void
) !void {
    // 1. Copy script to runner allocator (survives enqueue)
    const script_copy = try self.allocator.dupe(u8, script);
    errdefer self.allocator.free(script_copy);

    // 2. Create work item
    const work_item = ThreadPool.WorkItem{
        .func = scriptWorkerFunc,
        .data = @ptrCast(&WorkContext{
            .script = script_copy,
            .state_pool = self.state_pool,
            .action_queue = self.action_queue,
            .runner_allocator = self.allocator,
            .on_complete = on_complete,
        }),
    };

    // 3. Submit to thread pool
    try self.thread_pool.submit(work_item);
}
```

**Worker function** (runs on ThreadPool):
```zig
fn scriptWorkerFunc(data: *anyopaque) void {
    const ctx = @ptrCast(*WorkContext, @alignCast(@alignOf(WorkContext), data));
    defer ctx.runner_allocator.free(ctx.script); // Free script copy

    // Acquire lua_State from pool
    const state = ctx.state_pool.acquire() catch |err| {
        std.log.err("Failed to acquire lua_State: {}", .{err});
        return;
    };
    defer ctx.state_pool.release(state);

    // Execute script
    const result = lua.executeLuaBuffer(state, ctx.script, ctx.runner_allocator);
    defer ctx.runner_allocator.free(result.message);

    // Build ActionQueue message (copy to action_queue.allocator)
    const msg = ctx.action_queue.allocator.dupe(u8, result.message) catch {
        std.log.err("Failed to allocate action message", .{});
        return;
    };

    // Push to ActionQueue
    ctx.action_queue.push(.{
        .kind = .ScriptResult,
        .message = msg,
    }) catch {
        ctx.action_queue.allocator.free(msg);
    };

    // Optional worker-side callback (must be thread-safe!)
    if (ctx.on_complete) |callback| {
        callback(result.message);
    }
}
```

### Memory Ownership

| Allocation | Allocator | Lifetime | Freed By |
|------------|-----------|----------|----------|
| `script_copy` | `runner.allocator` | Until worker completes | Worker (defer in `scriptWorkerFunc`) |
| `result.message` | `runner.allocator` (passed to `executeLuaBuffer`) | Until copied to ActionQueue | Worker (defer after copy) |
| ActionQueue `msg` | `action_queue.allocator` | Until popped | Main thread (ActionQueue consumer) |

---

## StatePool

### Purpose
Maintains a pool of reusable `lua_State*` instances to avoid expensive creation overhead (~1ms per state).

### Key Functions

| Function | Signature | Description |
|----------|-----------|-------------|
| `init` | `StatePool.init(allocator, capacity, create_fn, destroy_fn)` | Create pool with N resources |
| `deinit` | `pool.deinit()` | Destroy all resources and free pool |
| `acquire` | `pool.acquire()` | Lease a resource (blocks if none available) |
| `release` | `pool.release(resource)` | Return resource to pool |

### Data Structure

```zig
pub const StatePool = struct {
    allocator: Allocator,
    resources: ArrayList(*anyopaque),  // Array of lua_State*
    available: Semaphore,               // Counts available resources
    mutex: Mutex,                       // Protects resources array
    create_fn: *const fn(Allocator) anyerror!*anyopaque,
    destroy_fn: *const fn(*anyopaque) void,
};
```

### Acquire/Release Flow

```
acquire():
  1. semaphore.wait()  // Block until available_count > 0
  2. mutex.lock()
  3. resource = resources.pop()  // Take last resource
  4. mutex.unlock()
  5. return resource

release(resource):
  1. mutex.lock()
  2. resources.append(resource)  // Return to pool
  3. mutex.unlock()
  4. semaphore.post()  // Signal availability
```

### Creation Functions

**For Lua states**:
```zig
fn createLuaState(allocator: Allocator) !*anyopaque {
    const L = lua.luaL_newstate() orelse return error.OutOfMemory;
    lua.luaL_openlibs(L);
    
    // Register engine bindings
    lua_bindings.registerConsoleFunctions(L);
    lua_bindings.registerCVarFunctions(L);
    
    return @ptrCast(*anyopaque, L);
}

fn destroyLuaState(resource: *anyopaque) void {
    const L = @ptrCast(*lua.lua_State, resource);
    lua.lua_close(L);
}
```

**Initialization**:
```zig
var state_pool = try StatePool.init(
    allocator,
    8,  // 8 lua_States in pool
    createLuaState,
    destroyLuaState
);
defer state_pool.deinit();
```

### Performance Characteristics

- **Acquire (fast path)**: Semaphore wait + mutex lock/unlock (~100ns if resource available)
- **Acquire (slow path)**: Blocks until another worker releases a state
- **Creation cost**: ~1ms per `lua_State` (only at pool init, not runtime)

---

## ActionQueue

### Purpose
Thread-safe queue for transferring messages from worker threads to the main thread.

### Key Functions

| Function | Signature | Description |
|----------|-----------|-------------|
| `init` | `ActionQueue.init(allocator, capacity)` | Create queue with max capacity |
| `deinit` | `queue.deinit()` | Free queue (does not free messages!) |
| `push` | `queue.push(action)` | Enqueue action (blocks if full) |
| `tryPop` | `queue.tryPop()` | Dequeue action (returns null if empty) |
| `pop` | `queue.pop()` | Dequeue action (blocks until available) |

### Data Structure

```zig
pub const ActionKind = enum {
    ScriptResult,  // Script execution result
    CVarLua,       // CVar change → Lua handler
    CVarNative,    // (Reserved, not used)
};

pub const Action = struct {
    kind: ActionKind,
    message: []u8,  // Payload buffer (caller-owned)
};

pub const ActionQueue = struct {
    allocator: Allocator,       // For internal ArrayList
    actions: ArrayList(Action), // Circular buffer
    mutex: Mutex,
    semaphore: Semaphore,       // Counts available items
    capacity: usize,
};
```

### Push/Pop Flow

```
push(action):
  1. mutex.lock()
  2. if (actions.len >= capacity) return error.QueueFull
  3. actions.append(action)
  4. mutex.unlock()
  5. semaphore.post()  // Signal new item available

pop():
  1. semaphore.wait()  // Block until item available
  2. mutex.lock()
  3. action = actions.orderedRemove(0)  // FIFO
  4. mutex.unlock()
  5. return action

tryPop():
  1. if (!semaphore.tryWait()) return null  // Non-blocking
  2. mutex.lock()
  3. action = actions.orderedRemove(0)
  4. mutex.unlock()
  5. return action
```

### Message Payload Ownership

**Critical rule**: `action.message` **must** be allocated with `action_queue.allocator` (or a compatible allocator known to the consumer).

**Worker (producer)**:
```zig
const msg = action_queue.allocator.dupe(u8, result_str) catch return;
action_queue.push(.{ .kind = .ScriptResult, .message = msg }) catch {
    action_queue.allocator.free(msg);  // Free on push failure
};
```

**Main thread (consumer)**:
```zig
while (action_queue.tryPop()) |action| {
    defer action_queue.allocator.free(action.message);  // Consumer frees
    
    switch (action.kind) {
        .ScriptResult => handleScriptResult(action.message),
        .CVarLua => handleCVarLua(action.message),
        .CVarNative => {}, // Intentionally not used
    }
}
```

---

## ScriptingSystem

### Purpose
Main-thread ECS system that:
1. Polls `CVarRegistry` for pending changes and dispatches Lua handlers
2. Drains `ActionQueue` and processes worker results

### Key Functions

| Function | Signature | Description |
|----------|-----------|-------------|
| `init` | `ScriptingSystem.init(allocator, cvar_registry, state_pool)` | Create system |
| `deinit` | `system.deinit()` | Free resources |
| `update` | `system.update()` | Called each frame to process pending actions |

### Update Flow

```zig
pub fn update(self: *ScriptingSystem) void {
    // 1. Process CVar changes
    const events = self.cvar_registry.takePendingChanges(self.allocator);
    defer self.allocator.free(events);

    for (events) |ev| {
        defer {
            self.allocator.free(ev.name);
            self.allocator.free(ev.old_value);
            self.allocator.free(ev.new_value);
            self.allocator.free(ev.on_change_lua);
        }

        if (ev.on_change_lua.len == 0) continue;

        // Build message: "handler\0name\0old\0new"
        const total_len = ev.on_change_lua.len + 1 + ev.name.len + 1 + 
                          ev.old_value.len + 1 + ev.new_value.len;
        const msg = self.action_queue.allocator.alloc(u8, total_len) catch continue;
        // ... memcpy with NUL separators ...

        self.action_queue.push(.{ .kind = .CVarLua, .message = msg }) catch {
            self.action_queue.allocator.free(msg);
        };
    }

    // 2. Drain ActionQueue
    while (self.action_queue.tryPop()) |action| {
        defer self.action_queue.allocator.free(action.message);

        switch (action.kind) {
            .ScriptResult => {
                // Log script result
                std.log.info("Script result: {s}", .{action.message});
            },
            .CVarLua => {
                // Parse "handler\0name\0old\0new"
                const parts = parseNulSeparated(action.message);
                if (parts.len != 4) {
                    std.log.err("Invalid CVarLua message format", .{});
                    continue;
                }

                // Acquire lua_State and invoke handler
                const state = self.state_pool.acquire() catch continue;
                defer self.state_pool.release(state);

                lua.callNamedHandler(state, parts[0], &.{parts[1], parts[2], parts[3]});
            },
            .CVarNative => {}, // Not used
        }
    }
}
```

### Message Format (CVarLua)

**Encoding**:
```
"OnFOVChanged\0r_fov\075.0\090.0"
 └────┬─────┘ └─┬─┘ └┬─┘ └┬─┘
  handler    name  old  new
```

**Parsing**:
```zig
fn parseNulSeparated(buffer: []const u8) [][]const u8 {
    var parts = std.ArrayList([]const u8).init(temp_allocator);
    var start: usize = 0;
    for (buffer, 0..) |byte, i| {
        if (byte == 0) {
            parts.append(buffer[start..i]) catch break;
            start = i + 1;
        }
    }
    return parts.toOwnedSlice();
}
```

---

## Lua Bindings

### Purpose
Expose engine functionality to Lua scripts via C API wrappers.

### Registered Modules

| Module | Functions | Description |
|--------|-----------|-------------|
| `console` | `log(level, msg)`, `execute(cmd)` | Console output and command execution |
| `cvar` | `set(name, val)`, `get(name)`, `on_change(name, handler)` | CVar access |
| `ecs` | `createEntity()`, `addComponent()`, `getComponent()` | Entity management |
| `input` | `isKeyPressed(key)`, `getMousePos()` | Input queries |

### Example Binding (cvar.set)

**C binding in `lua_bindings.zig`**:
```zig
fn lua_cvar_set(L: *lua.lua_State) callconv(.C) c_int {
    const name = lua.luaL_checkstring(L, 1);
    const value = lua.luaL_checkstring(L, 2);

    // Access global CVarRegistry (thread-safe)
    const registry = getGlobalCVarRegistry();
    registry.setFromString(std.mem.span(name), std.mem.span(value)) catch |err| {
        lua.lua_pushstring(L, @errorName(err));
        lua.lua_error(L);
        return 0;
    };

    return 0; // No return values
}

pub fn registerCVarFunctions(L: *lua.lua_State) void {
    lua.lua_newtable(L);
    
    lua.lua_pushcfunction(L, lua_cvar_set);
    lua.lua_setfield(L, -2, "set");
    
    lua.lua_pushcfunction(L, lua_cvar_get);
    lua.lua_setfield(L, -2, "get");
    
    // ... more functions ...
    
    lua.lua_setglobal(L, "cvar");
}
```

**Lua usage**:
```lua
cvar.set("r_fov", "90")
local fov = cvar.get("r_fov")
print("FOV: " .. fov)
```

### Thread Safety Notes

- **Read operations** (e.g., `cvar.get`, `ecs.getComponent`): Safe from worker threads if underlying data is mutex-protected
- **Write operations** (e.g., `cvar.set`, `ecs.addComponent`): Must only occur on main thread OR use ActionQueue to defer to main thread

---

## Execution Flow

### End-to-End Example: Console Execute Script

**Scenario**: User types `exec("print('Hello')")` in console.

```
Frame N:
  1. Console: user types `exec("print('Hello')")`
     └─> Console.executeCommand("exec", ["print('Hello')"])
         └─> ScriptRunner.enqueueScript("print('Hello')")
             ├─ Allocate script_copy with runner.allocator
             ├─ Create WorkItem with script_copy pointer
             └─> ThreadPool.submit(WorkItem)

Worker Thread:
  2. ThreadPool dequeues WorkItem, calls scriptWorkerFunc(data)
     ├─> StatePool.acquire() → lua_State*
     ├─> executeLuaBuffer(L, "print('Hello')", runner.allocator)
     │   ├─ luaL_loadbuffer(L, script, len, "console")
     │   ├─ lua_pcall(L, 0, 0, 0)
     │   └─ Return ExecuteResult{ .success = true, .message = "" }
     ├─> StatePool.release(L)
     ├─> Allocate result_msg with action_queue.allocator
     ├─> ActionQueue.push(Action{ .kind = ScriptResult, .message = result_msg })
     └─> Free script_copy with runner.allocator

Frame N+1 (Main Thread):
  3. ScriptingSystem.update()
     └─> ActionQueue.tryPop() → Action{ .kind = ScriptResult, .message = "" }
         ├─ Log: "Script result: (empty)"
         └─> action_queue.allocator.free(message)

Output:
  Console prints: "Hello" (from Lua print())
```

### End-to-End Example: CVar on_change Handler

**Scenario**: CVar `r_fov` changes from 75 to 90, Lua handler `OnFOVChanged` registered.

```
Frame N:
  1. User: `set r_fov 90`
     └─> CVarRegistry.setFromString("r_fov", "90")
         ├─ Validate: 45 ≤ 90 ≤ 120 ✓
         ├─ Update cvar.float_val = 90.0
         └─ pending_changes.append({ name="r_fov", old="75.0", new="90.0", on_change_lua="OnFOVChanged" })

Frame N+1:
  2. ScriptingSystem.update()
     ├─> CVarRegistry.takePendingChanges(allocator) → [{ name="r_fov", ... }]
     ├─ For each event with non-empty on_change_lua:
     │  ├─ Allocate msg = "OnFOVChanged\0r_fov\075.0\090.0" with action_queue.allocator
     │  └─> ActionQueue.push(Action{ .kind = CVarLua, .message = msg })
     └─> ActionQueue.tryPop() → Action{ .kind = CVarLua, .message = "OnFOVChanged\0..." }
         ├─ Parse: handler="OnFOVChanged", name="r_fov", old="75.0", new="90.0"
         ├─> StatePool.acquire() → lua_State*
         ├─> lua.callNamedHandler(L, "OnFOVChanged", &.{"r_fov", "75.0", "90.0"})
         │   ├─ lua_getglobal(L, "OnFOVChanged")
         │   ├─ lua_pushstring(L, "r_fov")
         │   ├─ lua_pushstring(L, "75.0")
         │   ├─ lua_pushstring(L, "90.0")
         │   ├─ lua_pcall(L, 3, 0, 0)
         │   └─ Lua executes: function OnFOVChanged(name, old, new) print(...) end
         ├─> StatePool.release(L)
         └─> action_queue.allocator.free(msg)

Output:
  Lua prints: "r_fov changed: 75.0 -> 90.0"
  Camera FOV updated via Lua callback
```

---

## Memory & Ownership Model

### Allocator Responsibilities

| Component | Allocator | Usage | Lifetime |
|-----------|-----------|-------|----------|
| ScriptRunner | `runner.allocator` | Script copies, temp buffers | Until worker completes |
| StatePool | `pool.allocator` | Resource array (ArrayList) | Until pool deinit |
| ActionQueue | `queue.allocator` | Internal ArrayList | Until queue deinit |
| ActionQueue messages | `action_queue.allocator` | Action payloads | Until consumer frees |
| Lua states | Lua internal | Lua stack, GC heap | Until lua_close |

### Ownership Rules

1. **Script Copies** (`ScriptRunner.enqueueScript`)  
   - Allocated: `runner.allocator.dupe(u8, script)`
   - Owned by: Worker thread
   - Freed by: Worker (defer in `scriptWorkerFunc`)

2. **ExecuteResult.message** (`executeLuaBuffer`)  
   - Allocated: Caller-provided allocator (typically `runner.allocator`)
   - Owned by: Worker thread
   - Freed by: Worker (after copying to ActionQueue message)

3. **ActionQueue Message Payloads**  
   - Allocated: `action_queue.allocator.dupe(u8, ...)`
   - Owned by: ActionQueue → transferred to consumer on pop
   - Freed by: Main thread (consumer of `tryPop`/`pop`)

4. **CVar Change Event Buffers** (`takePendingChanges`)  
   - Allocated: `registry.allocator` → transferred to caller allocator
   - Owned by: Caller of `takePendingChanges`
   - Freed by: Caller (must free slice + each field)

### Zero-Length Buffer Handling

**Problem**: Zig allocators may return zero-length slices that still require `free()`.

**Solution**: Always use unconditional `defer allocator.free(slice)`.

```zig
// CORRECT:
const msg = action_queue.allocator.alloc(u8, len) catch return;
defer action_queue.allocator.free(msg);  // ← Always defer, even if len==0

// WRONG:
if (msg.len > 0) {
    defer action_queue.allocator.free(msg);  // ← Leaks if len==0
}
```

---

## Thread Safety

### Mutex-Protected Structures

| Structure | Mutex | Protects |
|-----------|-------|----------|
| `CVarRegistry` | `registry.mutex` | `cvars` HashMap, `pending_changes` |
| `StatePool` | `pool.mutex` | `resources` ArrayList |
| `ActionQueue` | `queue.mutex` | `actions` ArrayList |

### Lock-Free Operations

- **Semaphore wait/post**: Atomic operations (no mutex needed)
- **Lua stack operations**: Thread-local (each worker has separate `lua_State`)

### Data Race Prevention

**Rule**: Workers can **read** engine state (if mutex-protected) but **cannot write** except via ActionQueue.

**Example** (safe):
```zig
// Worker reads CVar (safe: registry.mutex protects)
const val = cvar_registry.getAsStringAlloc("r_fov", allocator);
defer allocator.free(val);
// Use val...
```

**Example** (unsafe):
```zig
// Worker writes CVar (UNSAFE: bypasses main thread!)
cvar_registry.setFromString("r_fov", "90");  // ← DATA RACE!
```

**Correct approach**:
```zig
// Worker enqueues action for main thread to process
const msg = action_queue.allocator.dupe(u8, "set_fov\09090") catch return;
action_queue.push(.{ .kind = .ScriptResult, .message = msg }) catch {
    action_queue.allocator.free(msg);
};
```

### Deadlock Prevention

**Potential deadlock**: Worker acquires StatePool → main thread acquires StatePool → both block if pool exhausted.

**Solution**: Main thread uses `tryAcquire` (non-blocking) or workers use separate pool.

---

## Integration Points

### Console System

**Console executes Lua scripts**:
```lua
-- In console:
> exec("print('Hello')")
```

**Implementation**:
```zig
pub fn console_exec(L: *lua.lua_State) callconv(.C) c_int {
    const script = lua.luaL_checkstring(L, 1);
    
    const runner = getGlobalScriptRunner();
    runner.enqueueScript(std.mem.span(script), null) catch |err| {
        lua.lua_pushstring(L, @errorName(err));
        lua.lua_error(L);
    };
    
    return 0;
}
```

### CVar System

**CVar on_change handlers**:
```lua
function OnVsyncChanged(name, old, new)
    print(name .. ": " .. old .. " -> " .. new)
end
cvar.on_change("r_vsync", "OnVsyncChanged")
```

**Implementation**: See [ScriptingSystem.update()](#scriptingsystem).

### ECS System

**Lua can query entities**:
```lua
local entity_id = ecs.createEntity()
ecs.addComponent(entity_id, "Transform", { x = 0, y = 0, z = 0 })
local transform = ecs.getComponent(entity_id, "Transform")
print("Position: " .. transform.x .. ", " .. transform.y)
```

**Thread safety**: Read-only from workers, mutations must be enqueued as actions.

---

## Advanced Features

### Custom Action Types

**Extend `ActionKind` enum**:
```zig
pub const ActionKind = enum {
    ScriptResult,
    CVarLua,
    CVarNative,  // Reserved
    CustomEvent, // ← New action type
};
```

**Handle in ScriptingSystem**:
```zig
.CustomEvent => {
    // Parse action.message and handle custom event
    handleCustomEvent(action.message);
},
```

### Worker-Side Callbacks

**Use case**: Immediate feedback without round-tripping through ActionQueue.

**Pattern**:
```zig
pub fn enqueueScript(
    self: *ScriptRunner,
    script: []const u8,
    on_complete: ?*const fn([]const u8) void  // ← Worker callback
) !void {
    // ... (see ScriptRunner section)
}
```

**Callback invoked**:
```zig
if (ctx.on_complete) |callback| {
    callback(result.message);  // ← Runs on worker thread!
}
```

**Safety**: Callback must be thread-safe (no engine state mutation).

### Script Batching

**Pattern**: Execute multiple scripts in one worker task.

```zig
pub fn enqueueBatch(
    self: *ScriptRunner,
    scripts: []const []const u8
) !void {
    const batch_copy = try self.allocator.dupe([]const u8, scripts);
    // ... submit WorkItem with batch ...
}
```

**Worker loop**:
```zig
for (batch_copy) |script| {
    const result = lua.executeLuaBuffer(state, script, allocator);
    // ... enqueue result ...
}
```

---

## Error Handling

### Error Types

| Error | Source | Recovery |
|-------|--------|----------|
| `OutOfMemory` | Allocator exhausted | Reduce load or increase limits |
| `QueueFull` | ActionQueue capacity exceeded | Increase queue capacity or drain faster |
| `LuaRuntimeError` | Script execution failed | Log error, continue processing |
| `StatePoolExhausted` | All lua_States in use | Increase pool size or wait for release |

### Lua Runtime Errors

**Capture in `executeLuaBuffer`**:
```zig
pub fn executeLuaBuffer(
    L: *lua.lua_State,
    script: []const u8,
    allocator: Allocator
) ExecuteResult {
    if (lua.luaL_loadbuffer(L, script.ptr, script.len, "script") != 0) {
        const err_msg = lua.lua_tostring(L, -1);
        const msg_copy = allocator.dupe(u8, std.mem.span(err_msg)) catch "OOM";
        lua.lua_pop(L, 1);
        return .{ .success = false, .message = msg_copy };
    }

    if (lua.lua_pcall(L, 0, 0, 0) != 0) {
        const err_msg = lua.lua_tostring(L, -1);
        const msg_copy = allocator.dupe(u8, std.mem.span(err_msg)) catch "OOM";
        lua.lua_pop(L, 1);
        return .{ .success = false, .message = msg_copy };
    }

    return .{ .success = true, .message = allocator.dupe(u8, "OK") catch "OK" };
}
```

**Handle in main thread**:
```zig
if (action.kind == .ScriptResult) {
    if (std.mem.startsWith(u8, action.message, "ERROR:")) {
        std.log.err("Script failed: {s}", .{action.message});
    } else {
        std.log.info("Script OK: {s}", .{action.message});
    }
}
```

---

## Performance Considerations

### StatePool Sizing

**Undersized**: Workers block on `acquire()`, idle threads waste CPU.  
**Oversized**: Excess memory usage (~1MB per `lua_State`).

**Heuristic**: `pool_size = num_worker_threads + 1` (for main thread handlers).

### ActionQueue Capacity

**Undersized**: Workers get `error.QueueFull`, drop messages.  
**Oversized**: Excess memory usage.

**Heuristic**: `capacity = 256` (sufficient for 60 FPS with ~4 actions/frame).

### Lua Handler Overhead

**Cost per invocation**:
- StatePool acquire/release: ~100ns
- Lua function lookup: ~50ns
- Lua call: ~200ns
- **Total**: ~350ns per handler

**Recommendation**: Attach handlers to infrequently-changed CVARs (<10 changes/frame).

### Script Copy Overhead

**Cost**: `O(script_len)` per `enqueueScript`.

**Optimization**: For repeated scripts, store script once and reuse pointer (requires careful lifetime management).

---

## Testing Strategy

### Unit Tests

**StatePool Test** (`state_pool_test.zig`):
```zig
test "StatePool concurrent acquire/release" {
    var pool = try StatePool.init(allocator, 4, createMockResource, destroyMockResource);
    defer pool.deinit();

    const num_threads = 16;
    var threads: [num_threads]std.Thread = undefined;

    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, workerFunc, .{&pool});
    }

    for (threads) |thread| thread.join();

    try std.testing.expect(pool.resources.items.len == 4); // All returned
}

fn workerFunc(pool: *StatePool) void {
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const res = pool.acquire() catch unreachable;
        std.time.sleep(10_000); // 10µs
        pool.release(res);
    }
}
```

**ActionQueue Test** (`action_queue_test.zig`):
```zig
test "ActionQueue thread-safe push/pop" {
    var queue = try ActionQueue.init(page_allocator, 128);
    defer queue.deinit();

    // Spawn producer threads
    const producers = try allocator.alloc(std.Thread, 4);
    defer allocator.free(producers);
    for (producers) |*thread| {
        thread.* = try std.Thread.spawn(.{}, producerFunc, .{&queue});
    }

    // Consumer thread
    var received: usize = 0;
    while (received < 400) : (received += 1) {  // 4 producers × 100 msgs
        const action = queue.pop();
        defer queue.allocator.free(action.message);
        try std.testing.expect(action.kind == .ScriptResult);
    }

    for (producers) |thread| thread.join();
}

fn producerFunc(queue: *ActionQueue) void {
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const msg = queue.allocator.dupe(u8, "test") catch unreachable;
        queue.push(.{ .kind = .ScriptResult, .message = msg }) catch unreachable;
    }
}
```

### Integration Tests

**Script Execution Test** (`script_demo.zig`):
```zig
pub fn main() !void {
    var runner = try ScriptRunner.init(allocator, &thread_pool, &state_pool, &action_queue);
    defer runner.deinit();

    // Enqueue script
    try runner.enqueueScript("return 2 + 2", null);

    // Wait for result
    std.time.sleep(10_000_000); // 10ms

    // Check ActionQueue
    const action = action_queue.tryPop() orelse return error.NoResult;
    defer action_queue.allocator.free(action.message);

    try std.testing.expectEqualStrings("OK", action.message);
}
```

---

## Common Patterns

### Pattern 1: Console Script Execution

```zig
// In console command handler:
pub fn console_exec(args: [][]const u8) void {
    if (args.len < 1) return;
    const script = args[0];
    
    script_runner.enqueueScript(script, null) catch |err| {
        std.log.err("Failed to enqueue script: {}", .{err});
    };
}
```

### Pattern 2: CVar Lua Handler Registration

```lua
-- Lua script loaded at startup:
function OnGammaChanged(name, old, new)
    local gamma = tonumber(new)
    renderer.setGamma(gamma)
end

cvar.on_change("r_gamma", "OnGammaChanged")
```

### Pattern 3: Async Script with Result

```zig
// Enqueue with worker callback:
try runner.enqueueScript("return expensive_calculation()", logResult);

fn logResult(result: []const u8) void {
    std.log.info("Result: {s}", .{result});
}
```

### Pattern 4: Batch Script Execution

```zig
const scripts = [_][]const u8{
    "print('Script 1')",
    "print('Script 2')",
    "print('Script 3')",
};

for (scripts) |script| {
    try runner.enqueueScript(script, null);
}
```

---

## Troubleshooting Guide

### Problem: Script Never Executes

**Symptoms**: `enqueueScript` succeeds but no result appears.

**Checklist**:
- [ ] ThreadPool initialized and running
- [ ] StatePool has available resources
- [ ] ActionQueue not full
- [ ] ScriptingSystem.update() called each frame

**Debug**:
```zig
std.log.info("ActionQueue size: {}", .{action_queue.actions.items.len});
std.log.info("StatePool available: {}", .{state_pool.available.value});
```

### Problem: Memory Leak in ActionQueue

**Symptoms**: Memory usage grows over time.

**Cause**: Forgot to free `action.message` after popping.

**Fix**:
```zig
while (action_queue.tryPop()) |action| {
    defer action_queue.allocator.free(action.message);  // ← Must free
    // Process action...
}
```

### Problem: Lua Runtime Error Not Captured

**Symptoms**: Script fails but no error message.

**Cause**: `executeLuaBuffer` not checking `lua_pcall` return value.

**Fix**: See [Error Handling](#error-handling) section.

### Problem: Data Race / Crash

**Symptoms**: Intermittent crashes when workers access engine state.

**Cause**: Worker writing to non-thread-safe structure.

**Solution**: Use ActionQueue to defer write to main thread:
```zig
// WRONG (worker writes directly):
ecs.addComponent(entity_id, component);

// CORRECT (enqueue action):
const msg = action_queue.allocator.dupe(u8, "add_component\0...") catch return;
action_queue.push(.{ .kind = .CustomEvent, .message = msg }) catch {...};
```

---

## See Also

- **Quick Reference**: `docs/SCRIPTING_QUICK_REF.md`
- **Console System**: `docs/CONSOLE_SYSTEM.md`
- **CVar System**: `docs/CVAR_SYSTEM.md`
- **Examples**: `examples/script_demo.zig`, `examples/script_multi_demo.zig`

---

**Document Version**: 2.0  
**Last Updated**: November 5, 2025  
**Maintainer**: Zephyr Engine Team
