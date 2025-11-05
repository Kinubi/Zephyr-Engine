# Scripting System — Quick Reference

## Component Overview

| Component | Purpose | Thread Affinity |
|-----------|---------|-----------------|
| **ScriptRunner** | Enqueues scripts to ThreadPool | Main → Worker |
| **StatePool** | Pools reusable lua_State instances | Worker (acquire/release) |
| **ActionQueue** | Thread-safe message queue | Worker → Main |
| **ScriptingSystem** | Main-thread dispatcher | Main |
| **Lua Bindings** | C API wrappers for engine systems | Worker + Main |

---

## ScriptRunner API

### Core Functions

| Function | Signature | Description |
|----------|-----------|-------------|
| `init` | `ScriptRunner.init(allocator, thread_pool, state_pool, action_queue)` | Create runner |
| `deinit` | `runner.deinit()` | Free internal state |
| `enqueueScript` | `runner.enqueueScript(script, on_complete)` | Submit script for async execution |

### Usage Example

```zig
// Initialize
var runner = try ScriptRunner.init(
    allocator,
    &thread_pool,
    &state_pool,
    &action_queue
);
defer runner.deinit();

// Enqueue script
try runner.enqueueScript("print('Hello from worker')", null);

// Optional: with worker callback
try runner.enqueueScript("return 2 + 2", myCallback);

fn myCallback(result: []const u8) void {
    std.log.info("Result: {s}", .{result});  // Runs on worker thread!
}
```

---

## StatePool API

### Core Functions

| Function | Signature | Description |
|----------|-----------|-------------|
| `init` | `StatePool.init(allocator, capacity, create_fn, destroy_fn)` | Create pool with N resources |
| `deinit` | `pool.deinit()` | Destroy all resources |
| `acquire` | `pool.acquire()` | Lease resource (blocks if none available) |
| `release` | `pool.release(resource)` | Return resource to pool |

### Lua State Pool Example

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

// Initialize pool
var state_pool = try StatePool.init(
    allocator,
    8,  // 8 lua_States
    createLuaState,
    destroyLuaState
);
defer state_pool.deinit();

// Worker usage
const state = try state_pool.acquire();
defer state_pool.release(state);
// ... use state ...
```

### Sizing Heuristic

```
pool_size = num_worker_threads + 1
```

**Rationale**: One state per worker + one for main thread handlers.

---

## ActionQueue API

### Core Functions

| Function | Signature | Description |
|----------|-----------|-------------|
| `init` | `ActionQueue.init(allocator, capacity)` | Create queue |
| `deinit` | `queue.deinit()` | Free queue (not messages!) |
| `push` | `queue.push(action)` | Enqueue (blocks if full) |
| `tryPop` | `queue.tryPop()` | Dequeue (returns null if empty) |
| `pop` | `queue.pop()` | Dequeue (blocks until available) |

### Action Types

```zig
pub const ActionKind = enum {
    ScriptResult,  // Script execution result
    CVarLua,       // CVar change → Lua handler
    CVarNative,    // Reserved (not used)
};

pub const Action = struct {
    kind: ActionKind,
    message: []u8,  // Payload (allocated with queue.allocator)
};
```

### Producer Pattern (Worker Thread)

```zig
// Allocate message with action_queue.allocator
const msg = action_queue.allocator.dupe(u8, "Script OK") catch return;

// Push to queue
action_queue.push(.{
    .kind = .ScriptResult,
    .message = msg,
}) catch {
    action_queue.allocator.free(msg);  // Free on failure
    std.log.err("ActionQueue full", .{});
};
```

### Consumer Pattern (Main Thread)

```zig
// Drain queue each frame
while (action_queue.tryPop()) |action| {
    defer action_queue.allocator.free(action.message);  // Consumer frees
    
    switch (action.kind) {
        .ScriptResult => {
            std.log.info("Script: {s}", .{action.message});
        },
        .CVarLua => {
            // Parse and invoke Lua handler
            handleCVarLua(action.message);
        },
        .CVarNative => {}, // Not used
    }
}
```

---

## ScriptingSystem API

### Core Functions

| Function | Signature | Description |
|----------|-----------|-------------|
| `init` | `ScriptingSystem.init(allocator, cvar_registry, state_pool, action_queue)` | Create system |
| `deinit` | `system.deinit()` | Free resources |
| `update` | `system.update()` | Process pending actions (call each frame) |

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
        
        // Build and enqueue CVarLua action
        const msg = buildCVarMessage(ev);
        self.action_queue.push(.{ .kind = .CVarLua, .message = msg }) catch {...};
    }
    
    // 2. Drain ActionQueue
    while (self.action_queue.tryPop()) |action| {
        defer self.action_queue.allocator.free(action.message);
        
        switch (action.kind) {
            .CVarLua => invokeLuaHandler(action.message),
            .ScriptResult => logResult(action.message),
            .CVarNative => {},
        }
    }
}
```

---

## Lua Helpers

### executeLuaBuffer

**Signature**:
```zig
pub fn executeLuaBuffer(
    L: *lua.lua_State,
    script: []const u8,
    allocator: Allocator
) ExecuteResult
```

**Returns**:
```zig
pub const ExecuteResult = struct {
    success: bool,
    message: []u8,  // Allocated with provided allocator (caller frees)
};
```

**Usage**:
```zig
const state = try state_pool.acquire();
defer state_pool.release(state);

const result = lua.executeLuaBuffer(state, "return 2 + 2", allocator);
defer allocator.free(result.message);

if (result.success) {
    std.log.info("OK: {s}", .{result.message});
} else {
    std.log.err("Error: {s}", .{result.message});
}
```

### callNamedHandler

**Signature**:
```zig
pub fn callNamedHandler(
    L: *lua.lua_State,
    handler_name: []const u8,
    args: []const []const u8
) void
```

**Usage**:
```zig
const state = try state_pool.acquire();
defer state_pool.release(state);

// Invoke: OnFOVChanged("r_fov", "75.0", "90.0")
lua.callNamedHandler(state, "OnFOVChanged", &.{"r_fov", "75.0", "90.0"});
```

**Error handling**: Lua errors logged internally, function returns normally.

---

## Lua Bindings

### Registered Modules

| Module | Functions | Example Usage |
|--------|-----------|---------------|
| `console` | `log(level, msg)`, `execute(cmd)` | `console.log("info", "Hello")` |
| `cvar` | `set(name, val)`, `get(name)`, `on_change(name, handler)` | `cvar.set("r_fov", "90")` |
| `ecs` | `createEntity()`, `addComponent()`, `getComponent()` | `local id = ecs.createEntity()` |
| `input` | `isKeyPressed(key)`, `getMousePos()` | `if input.isKeyPressed("W") then ... end` |

### Console Module

```lua
-- Log levels: "debug", "info", "warn", "error"
console.log("info", "Initialization complete")

-- Execute console command
console.execute("set r_vsync true")
```

### CVar Module

```lua
-- Set CVar
cvar.set("r_fov", "90")

-- Get CVar
local fov = cvar.get("r_fov")  -- "90"

-- Register on_change handler
function OnFOVChanged(name, old, new)
    print(name .. ": " .. old .. " -> " .. new)
end
cvar.on_change("r_fov", "OnFOVChanged")
```

### ECS Module

```lua
-- Create entity
local entity_id = ecs.createEntity()

-- Add component
ecs.addComponent(entity_id, "Transform", {
    position = {x = 0, y = 0, z = 0},
    rotation = {x = 0, y = 0, z = 0, w = 1}
})

-- Query component
local transform = ecs.getComponent(entity_id, "Transform")
print("Position: " .. transform.position.x)
```

---

## Message Formats

### CVarLua Message

**Format**: NUL-separated strings
```
"handler\0name\0old\0new"
```

**Example**:
```
"OnFOVChanged\0r_fov\075.0\090.0"
```

**Parsing**:
```zig
fn parseNulSeparated(buffer: []const u8) [][]const u8 {
    var parts = ArrayList([]const u8).init(temp_allocator);
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

### ScriptResult Message

**Format**: Plain text
```
"OK" | "ERROR: <error message>"
```

**Example**:
```
"OK"
"ERROR: attempt to call a nil value"
```

---

## Memory & Ownership Rules

### Critical Rules

| Allocation | Allocator | Freed By |
|------------|-----------|----------|
| Script copy (in `enqueueScript`) | `runner.allocator` | Worker (defer) |
| `ExecuteResult.message` | Caller-provided allocator | Caller (defer) |
| ActionQueue message | `action_queue.allocator` | Consumer (main thread) |
| CVar change events | `registry.allocator` → caller | Caller of `takePendingChanges` |

### Ownership Patterns

#### Pattern 1: Worker Allocates for ActionQueue

```zig
// Worker thread:
const msg = action_queue.allocator.dupe(u8, "result") catch return;
action_queue.push(.{ .kind = .ScriptResult, .message = msg }) catch {
    action_queue.allocator.free(msg);  // Free on push failure
};
```

#### Pattern 2: Main Thread Consumes ActionQueue

```zig
// Main thread:
while (action_queue.tryPop()) |action| {
    defer action_queue.allocator.free(action.message);  // Always free
    // Process action...
}
```

#### Pattern 3: Zero-Length Buffer Safety

```zig
// CORRECT: Unconditional defer
const msg = action_queue.allocator.alloc(u8, len) catch return;
defer action_queue.allocator.free(msg);  // ← Always defer

// WRONG: Conditional free
if (msg.len > 0) {
    defer action_queue.allocator.free(msg);  // ← Leaks if len==0
}
```

---

## Common Patterns

### Pattern 1: Console Script Execution

```zig
// Console command: exec("print('Hello')")
pub fn console_exec(L: *lua.lua_State) callconv(.C) c_int {
    const script = lua.luaL_checkstring(L, 1);
    
    script_runner.enqueueScript(std.mem.span(script), null) catch |err| {
        lua.lua_pushstring(L, @errorName(err));
        lua.lua_error(L);
    };
    
    return 0;
}
```

### Pattern 2: CVar on_change Lua Handler

```lua
function OnVsyncChanged(name, old, new)
    print("VSync: " .. old .. " -> " .. new)
    if new == "true" then
        renderer.enableVSync()
    else
        renderer.disableVSync()
    end
end

cvar.on_change("r_vsync", "OnVsyncChanged")
```

### Pattern 3: Async Script with Worker Callback

```zig
try runner.enqueueScript(
    "local result = expensive_calculation(); return result",
    workerCallback
);

fn workerCallback(result: []const u8) void {
    std.log.info("Worker result: {s}", .{result});
    // NOTE: Runs on worker thread, no engine mutations!
}
```

### Pattern 4: Synchronous Main-Thread Script

```zig
// For immediate execution (no worker overhead):
const state = try state_pool.acquire();
defer state_pool.release(state);

const result = lua.executeLuaBuffer(state, "return 2 + 2", allocator);
defer allocator.free(result.message);

if (result.success) {
    std.log.info("Result: {s}", .{result.message});
}
```

---

## Error Handling

### Error Types

| Error | Cause | Recovery |
|-------|-------|----------|
| `OutOfMemory` | Allocator exhausted | Reduce load or increase limits |
| `QueueFull` | ActionQueue capacity exceeded | Increase capacity or drain faster |
| `LuaRuntimeError` | Script execution failed | Logged automatically, continue |
| `StatePoolExhausted` | All lua_States in use | Blocks until release |

### Lua Error Capture

**Automatic in `executeLuaBuffer`**:
```zig
if (lua.lua_pcall(L, 0, 0, 0) != 0) {
    const err_msg = lua.lua_tostring(L, -1);
    return .{ .success = false, .message = allocator.dupe(u8, err_msg) };
}
```

**Check in consumer**:
```zig
if (std.mem.startsWith(u8, action.message, "ERROR:")) {
    std.log.err("Script failed: {s}", .{action.message});
} else {
    std.log.info("Script OK: {s}", .{action.message});
}
```

---

## Performance Tips

### 1. StatePool Sizing

```zig
// Good: One state per worker + main thread
pool_size = thread_pool.num_workers + 1

// Bad: Undersized (workers block)
pool_size = 2  // ← Workers compete for states

// Bad: Oversized (excess memory)
pool_size = 100  // ← Wastes ~100MB
```

### 2. ActionQueue Capacity

```zig
// Good: Sufficient for 60 FPS × 4 actions/frame
capacity = 256

// Bad: Too small (workers get QueueFull)
capacity = 16  // ← High drop rate

// Bad: Too large (excess memory)
capacity = 10000  // ← Wastes memory
```

### 3. Avoid Frequent on_change Handlers

```lua
-- BAD: Handler on every-frame CVar
cvar.on_change("d_frame_count", "OnFrameCount")  -- ← Called 60× per second

-- GOOD: Handler on user settings
cvar.on_change("r_fov", "OnFOVChanged")  -- ← Called rarely
```

### 4. Batch Script Execution

```zig
// BAD: Enqueue 100 scripts individually
for (scripts) |script| {
    try runner.enqueueScript(script, null);  // ← 100 WorkItems
}

// GOOD: Combine into single script
const combined = try std.mem.join(allocator, "\n", scripts);
defer allocator.free(combined);
try runner.enqueueScript(combined, null);  // ← 1 WorkItem
```

---

## Troubleshooting Checklist

### ❌ Script Never Executes

- [ ] ThreadPool initialized and running
- [ ] StatePool has available resources (`pool.available.value > 0`)
- [ ] ActionQueue not full (`queue.actions.items.len < capacity`)
- [ ] ScriptingSystem.update() called each frame

**Debug**:
```zig
std.log.info("Queue size: {}", .{action_queue.actions.items.len});
std.log.info("StatePool available: {}", .{state_pool.available.value});
```

### ❌ Memory Leak

- [ ] ActionQueue messages freed after pop: `defer allocator.free(action.message)`
- [ ] CVar event buffers freed: `defer allocator.free(ev.name)`, etc.
- [ ] ExecuteResult.message freed: `defer allocator.free(result.message)`
- [ ] Unconditional defer (not `if (len > 0)`)

**Fix**:
```zig
while (action_queue.tryPop()) |action| {
    defer action_queue.allocator.free(action.message);  // ← Add this
    // ...
}
```

### ❌ Lua Handler Not Invoked

- [ ] Handler registered: `cvar.on_change("name", "HandlerFunc")`
- [ ] Function defined: `function HandlerFunc(name, old, new) ... end`
- [ ] ScriptingSystem running: `update()` called
- [ ] No Lua errors: Check console

**Debug**:
```lua
print("Handler: " .. (cvar.get_lua_handler("r_fov") or "NONE"))
```

### ❌ Data Race / Crash

- [ ] Workers only read engine state (no writes)
- [ ] Mutations enqueued as actions (not direct)
- [ ] Mutex held when accessing shared structures

**Fix**: Use ActionQueue instead of direct write:
```zig
// WRONG (worker writes):
ecs.addComponent(entity_id, component);  // ← DATA RACE!

// CORRECT (enqueue action):
const msg = action_queue.allocator.dupe(u8, "add_component\0...") catch return;
action_queue.push(.{ .kind = .CustomEvent, .message = msg }) catch {...};
```

---

## Thread Safety Summary

### Safe Operations (Any Thread)

- `StatePool.acquire()` / `release()`
- `ActionQueue.push()` / `pop()`
- `CVarRegistry.getAsStringAlloc()` (read-only)
- Lua stack operations (thread-local state)

### Unsafe Operations (Main Thread Only)

- `CVarRegistry.setFromString()` (write)
- `ECS.addComponent()` / `removeComponent()` (write)
- `Renderer.queueCommand()` (write)

### Cross-Thread Communication

**Rule**: Workers enqueue actions, main thread applies.

```
Worker Thread          ActionQueue          Main Thread
─────────────          ───────────          ───────────
  Lua script    →    push(Action)    →    pop(Action)
  Computation   →    (message)       →    Apply change
  Read CVARs    →                    →    Mutate engine
```

---

## See Also

- **Full Documentation**: `docs/SCRIPTING_SYSTEM.md`
- **Console Quick Ref**: `docs/CONSOLE_QUICK_REF.md`
- **CVar Quick Ref**: `docs/CVAR_QUICK_REF.md`
- **Examples**: `examples/script_demo.zig`, `examples/script_multi_demo.zig`

---

**Last Updated**: November 5, 2025

