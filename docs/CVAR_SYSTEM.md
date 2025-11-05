# CVAR System — Design & Reference

## Table of Contents

1. [Overview](#overview)
2. [Design Principles](#design-principles)
3. [Architecture](#architecture)
4. [Key Components](#key-components)
5. [CVar Data Model](#cvar-data-model)
6. [Registry Operations](#registry-operations)
7. [Change Notification Flow](#change-notification-flow)
8. [Memory & Ownership Model](#memory--ownership-model)
9. [Type System & Validation](#type-system--validation)
10. [Persistence System](#persistence-system)
11. [Integration Points](#integration-points)
12. [Advanced Features](#advanced-features)
13. [Error Handling](#error-handling)
14. [Performance Considerations](#performance-considerations)
15. [Testing Strategy](#testing-strategy)
16. [Common Patterns](#common-patterns)
17. [Troubleshooting Guide](#troubleshooting-guide)

---

## Overview

The **CVAR (Console Variable) system** provides type-safe, validated, persistent runtime configuration management for the Zephyr Engine. CVARs bridge native code, editor UI, and Lua scripting, enabling dynamic tuning of rendering parameters, gameplay settings, debug flags, and more without recompilation.

**Key capabilities:**
- **Type-safe storage**: Int, Float, Bool, String with compile-time and runtime validation
- **Bounds validation**: Optional min/max constraints for numeric types
- **Persistence**: Automatic save/load of archived CVARs to disk
- **Change notifications**: Lua `on_change` handlers invoked when values change
- **Thread-safe access**: Mutex-protected registry with lock-free reads where possible
- **Editor integration**: ImGui panels for browsing, editing, and debugging CVARs
- **Console integration**: Full access via console commands (`cvar.set`, `cvar.get`, etc.)

**Design philosophy:**  
CVARs are *not* a replacement for strongly-typed configuration structs in performance-critical code. They excel at *tuneable parameters* that need runtime modification, persistence, and scriptability. For hot-path rendering or physics, prefer direct struct fields and use CVARs only during initialization or infrequent updates.

---

## Design Principles

1. **Type Safety First**  
   - Each CVar has a fixed type (Int/Float/Bool/String) established at registration
   - String-to-value parsing validates type compatibility and bounds
   - Type mismatches return errors rather than silently coercing

2. **Explicit Validation**  
   - Numeric CVARs support optional `min`/`max` bounds
   - Validation occurs at `setFromString` time, before value is committed
   - Invalid values are rejected; CVar retains previous value

3. **Change Notifications (Lua Only)**  
   - Lua `on_change` handlers receive `(name, old_value, new_value)` when CVar changes
   - Native C function-pointer callbacks are *intentionally not supported* to simplify cross-thread ownership and avoid dangling pointers
   - Change events are batched and dispatched to Lua via ActionQueue

4. **Thread Safety**  
   - Registry operations (`set`, `get`, `register`) are protected by a single mutex
   - Pending change events are accumulated inside the mutex and transferred out atomically
   - Long-running Lua handlers execute outside the registry lock

5. **Persistence**  
   - CVARs marked `archived = true` are saved to disk on shutdown and loaded on startup
   - Persistence format is JSON or TOML (configurable)
   - Only user-modified values are saved (defaults are implied)

6. **Separation of Concerns**  
   - **Registry (`cvar.zig`)**: Core storage, locking, validation
   - **Defaults (`cvar_defaults.zig`)**: Engine/editor default CVar registrations
   - **Persistence (`cvar_config.zig`)**: Save/load helpers
   - **Integration (`scripting_system.zig`)**: Change dispatch to Lua

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                         CVAR SYSTEM                              │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌──────────────┐      ┌──────────────┐      ┌──────────────┐  │
│  │  Console UI  │      │  Editor UI   │      │  Lua Script  │  │
│  │  (ImGui)     │      │  (ImGui)     │      │  (cvar.xxx)  │  │
│  └──────┬───────┘      └──────┬───────┘      └──────┬───────┘  │
│         │                     │                     │          │
│         └─────────────────────┼─────────────────────┘          │
│                               ↓                                │
│                    ┌──────────────────────┐                    │
│                    │   CVarRegistry       │                    │
│                    │  (Mutex-protected)   │                    │
│                    ├──────────────────────┤                    │
│                    │ • cvars: HashMap     │                    │
│                    │ • pending_changes    │                    │
│                    │ • mutex: Mutex       │                    │
│                    └──────────┬───────────┘                    │
│                               │                                │
│              ┌────────────────┼────────────────┐               │
│              ↓                ↓                ↓               │
│   ┌──────────────────┐ ┌─────────────┐ ┌─────────────────┐   │
│   │ cvar_defaults.zig│ │ cvar.zig    │ │ cvar_config.zig │   │
│   │ (Registration)   │ │ (Core)      │ │ (Persistence)   │   │
│   └──────────────────┘ └─────────────┘ └─────────────────┘   │
│                                                                │
│                    Change Events Flow:                         │
│   Registry.setFromString → pending_changes → takePendingChanges│
│        ↓                                                       │
│   ScriptingSystem → ActionQueue → Lua on_change handlers      │
│                                                                │
└──────────────────────────────────────────────────────────────────┘
```

**Data flow:**
1. **Registration**: Engine registers default CVARs at startup (`cvar_defaults.zig`)
2. **Persistence Load**: Archived CVARs loaded from disk override defaults
3. **Runtime Modification**: Console/Editor/Lua calls `CVarRegistry.setFromString`
4. **Validation**: Registry validates type and bounds, updates value if valid
5. **Change Recording**: Valid changes appended to `pending_changes` (inside mutex)
6. **Dispatch**: `ScriptingSystem.update()` calls `takePendingChanges`, builds ActionQueue messages for Lua handlers
7. **Notification**: Main thread drains ActionQueue, invokes Lua `on_change(name, old, new)`
8. **Persistence Save**: On shutdown, archived CVARs written to disk

---

## Key Components

### File: `engine/src/core/cvar.zig`
**Purpose**: Core registry, CVar struct, thread-safe operations, change recording.

**Key types:**
- `CVarType`: enum { Int, Float, Bool, String }
- `CVarFlags`: struct { archived, read_only, cheat, developer, etc. }
- `CVar`: struct holding name, type, value storage, defaults, bounds, description, Lua handler
- `CVarRegistry`: HashMap of CVars + pending_changes ArrayList + Mutex

**Key functions:**
- `CVarRegistry.init(allocator)`: Create registry
- `registerCVar(...)`: Register or update a CVar (idempotent)
- `setFromString(name, val)`: Validate and set value, record change event
- `getAsStringAlloc(name, allocator)`: Query value as string (allocates)
- `takePendingChanges(allocator)`: Atomically steal pending change events
- `reset(name)`: Revert to default value
- `setLuaOnChange(name, handler)`: Attach Lua handler name

### File: `engine/src/core/cvar_defaults.zig`
**Purpose**: Default CVar registrations for engine, editor, and debug subsystems.

**Examples:**
```zig
// Rendering
_ = reg.registerCVar("r_vsync", .Bool, "true", "Enable VSync", .{ .archived = true }, ...) catch {};
_ = reg.registerCVar("r_fov", .Float, "75.0", "Field of view", .{ .archived = true }, null, null, 45.0, 120.0, null) catch {};

// Debug
_ = reg.registerCVar("d_show_fps", .Bool, "false", "Show FPS overlay", .{}, ...) catch {};

// Gameplay
_ = reg.registerCVar("g_mouse_sensitivity", .Float, "1.0", "Mouse sensitivity", .{ .archived = true }, null, null, 0.1, 5.0, null) catch {};
```

### File: `engine/src/core/cvar_config.zig`
**Purpose**: Save/load archived CVARs to/from disk (JSON/TOML).

**Key functions:**
- `saveCVars(registry, filepath, format)`: Write archived CVARs to file
- `loadCVars(registry, filepath, format)`: Read file, call `setFromString` for each entry

**Persistence rules:**
- Only CVARs with `flags.archived == true` are persisted
- File location: `config/cvars.json` (user settings) or `cache/cvars_debug.json` (dev overrides)
- On load, registry is queried; missing CVARs are skipped (allows config to outlive code changes)

### File: `engine/src/ecs/systems/scripting_system.zig`
**Purpose**: Dispatch CVar change events to Lua handlers.

**Execution flow in `update()`:**
```zig
pub fn update(self: *ScriptingSystem) void {
    // 1. Steal pending CVar changes
    const events = self.cvar_registry.takePendingChanges(self.allocator);
    defer self.allocator.free(events);

    // 2. For each event with a Lua handler, build ActionQueue message
    for (events) |ev| {
        if (ev.on_change_lua.len == 0) continue; // No Lua handler

        // Allocate message: "handler\0name\0old\0new"
        const msg = self.action_queue.allocator.alloc(u8, total_len) catch continue;
        // ... copy strings with NUL separators ...

        // 3. Enqueue action
        self.action_queue.push(.{ .kind = .CVarLua, .message = msg }) catch {
            self.action_queue.allocator.free(msg);
        };
    }

    // 4. Drain ActionQueue and dispatch
    while (self.action_queue.pop()) |action| {
        defer self.action_queue.allocator.free(action.message);
        switch (action.kind) {
            .CVarLua => {
                // Parse "handler\0name\0old\0new"
                const parts = parseNulSeparated(action.message);
                const state = self.state_pool.acquire() catch continue;
                defer self.state_pool.release(state);
                lua.callNamedHandler(state, parts[0], &.{parts[1], parts[2], parts[3]});
            },
            // ... other action kinds ...
        }
    }
}
```

---

## CVar Data Model

### CVar Struct Fields

| Field | Type | Description |
|-------|------|-------------|
| `name` | `[]const u8` | Unique CVar identifier (e.g., "r_vsync") |
| `cvar_type` | `CVarType` | Int, Float, Bool, or String |
| `int_val` | `i64` | Current value (if type == Int) |
| `float_val` | `f64` | Current value (if type == Float) |
| `bool_val` | `bool` | Current value (if type == Bool) |
| `str_val` | `ArrayList(u8)` | Current value (if type == String) |
| `default_int` | `i64` | Default value for Int type |
| `default_float` | `f64` | Default value for Float type |
| `default_bool` | `bool` | Default value for Bool type |
| `default_str` | `ArrayList(u8)` | Default value for String type |
| `min_int` | `?i64` | Optional minimum bound (Int) |
| `max_int` | `?i64` | Optional maximum bound (Int) |
| `min_float` | `?f64` | Optional minimum bound (Float) |
| `max_float` | `?f64` | Optional maximum bound (Float) |
| `description` | `ArrayList(u8)` | Human-readable description |
| `flags` | `CVarFlags` | Bitflags (archived, read_only, cheat, developer, etc.) |
| `on_change_lua` | `ArrayList(u8)` | Lua handler function name (empty if none) |

### CVarType Enum

```zig
pub const CVarType = enum {
    Int,    // i64 storage
    Float,  // f64 storage
    Bool,   // bool storage
    String, // ArrayList(u8) storage
};
```

### CVarFlags Struct

```zig
pub const CVarFlags = struct {
    archived: bool = false,      // Persist to disk
    read_only: bool = false,     // Prevent runtime modification
    cheat: bool = false,         // Only modifiable in dev builds
    developer: bool = false,     // Only visible in dev mode
    replicated: bool = false,    // (Reserved for multiplayer)
};
```

### CVarChange Struct
Used for pending change events:

```zig
pub const CVarChange = struct {
    name: []const u8,             // CVar name (registry-allocated)
    old_value: []const u8,        // Old value as string (registry-allocated)
    new_value: []const u8,        // New value as string (registry-allocated)
    on_change_lua: []const u8,    // Lua handler name (registry-allocated)
};
```

---

## Registry Operations

### Registration

**Function**: `CVarRegistry.registerCVar`

**Signature**:
```zig
pub fn registerCVar(
    self: *CVarRegistry,
    name: []const u8,
    cvar_type: CVarType,
    default_value: []const u8,
    description: []const u8,
    flags: CVarFlags,
    min_int: ?i64,
    max_int: ?i64,
    min_float: ?f64,
    max_float: ?f64,
    on_change: ?[]const u8,
) !void
```

**Behavior**:
- Acquires registry mutex
- Checks if CVar exists; if so, updates description/flags/bounds but retains current value
- If new, parses `default_value` string to typed value, validates bounds, stores in HashMap
- Copies all string parameters using registry allocator
- Returns error if parsing fails or type/bounds are invalid

**Example**:
```zig
try registry.registerCVar(
    "r_shadow_resolution",
    .Int,
    "2048",
    "Shadow map resolution (pixels)",
    .{ .archived = true },
    256,    // min_int
    8192,   // max_int
    null,   // min_float (N/A)
    null,   // max_float (N/A)
    null    // no Lua handler yet
);
```

### Setting Values

**Function**: `CVarRegistry.setFromString`

**Signature**:
```zig
pub fn setFromString(self: *CVarRegistry, name: []const u8, value: []const u8) !void
```

**Behavior**:
1. Acquire mutex
2. Lookup CVar by name; error if not found
3. Check `flags.read_only`; error if true
4. Parse `value` string according to `cvar_type`
   - Int: `std.fmt.parseInt`
   - Float: `std.fmt.parseFloat`
   - Bool: "true"/"false"/"1"/"0" (case-insensitive)
   - String: direct copy
5. Validate bounds (if numeric type has min/max set)
6. If value unchanged, return early (no change event)
7. Format old value as string, update CVar, append `CVarChange` to `pending_changes`
8. Release mutex

**Example**:
```zig
try registry.setFromString("r_vsync", "false");
try registry.setFromString("r_fov", "90.0");
```

### Querying Values

**Function**: `CVarRegistry.getAsStringAlloc`

**Signature**:
```zig
pub fn getAsStringAlloc(self: *CVarRegistry, name: []const u8, allocator: Allocator) ![]u8
```

**Behavior**:
- Acquires mutex, looks up CVar, formats value as string, allocates copy using provided allocator
- **Caller must free** the returned slice

**Example**:
```zig
const val = try registry.getAsStringAlloc("r_fov", allocator);
defer allocator.free(val);
std.debug.print("FOV = {s}\n", .{val});
```

**Alternative (typed access)**:
For performance-critical code, prefer direct struct fields:
```zig
const cvar = registry.cvars.get("r_fov") orelse return error.NotFound;
registry.mutex.lock();
defer registry.mutex.unlock();
const fov = cvar.float_val;
```

### Resetting to Default

**Function**: `CVarRegistry.reset`

**Signature**:
```zig
pub fn reset(self: *CVarRegistry, name: []const u8) !void
```

**Behavior**:
- Looks up CVar, restores default value, records change event if value changed

**Example**:
```zig
try registry.reset("r_fov"); // Reverts to 75.0
```

### Setting Lua Handler

**Function**: `CVarRegistry.setLuaOnChange`

**Signature**:
```zig
pub fn setLuaOnChange(self: *CVarRegistry, name: []const u8, handler: []const u8) !void
```

**Behavior**:
- Acquires mutex, looks up CVar, copies `handler` string to `on_change_lua` field
- If `handler` is empty, clears Lua handler (no notifications for this CVar)

**Example (from Lua)**:
```lua
function OnFOVChanged(name, old, new)
    print("FOV changed: " .. old .. " -> " .. new)
end
cvar.on_change("r_fov", "OnFOVChanged")
```

### Stealing Pending Changes

**Function**: `CVarRegistry.takePendingChanges`

**Signature**:
```zig
pub fn takePendingChanges(self: *CVarRegistry, allocator: Allocator) ![]CVarChange
```

**Behavior**:
- Acquires mutex
- Moves `pending_changes` ArrayList to caller (replaces with empty ArrayList)
- Converts to owned slice using provided allocator
- **Caller must free** the slice and each `CVarChange` string field

**Usage in ScriptingSystem**:
```zig
const events = cvar_registry.takePendingChanges(allocator);
defer allocator.free(events);
for (events) |ev| {
    defer allocator.free(ev.name);
    defer allocator.free(ev.old_value);
    defer allocator.free(ev.new_value);
    defer allocator.free(ev.on_change_lua);
    // ... build ActionQueue message ...
}
```

---

## Change Notification Flow

### Step-by-Step Execution

1. **User Action**  
   Console command: `cvar.set("r_fov", "90")`  
   → Lua calls C binding `cvarSet`  
   → `CVarRegistry.setFromString("r_fov", "90")`

2. **Registry Validation**  
   ```
   Mutex: LOCK
   ├─ Lookup CVar "r_fov" → found (type=Float, min=45, max=120)
   ├─ Parse "90" → 90.0 (valid)
   ├─ Validate: 45.0 ≤ 90.0 ≤ 120.0 → OK
   ├─ Old value: 75.0 → Format as "75.0"
   ├─ New value: 90.0 → Store in cvar.float_val
   ├─ Append CVarChange { name="r_fov", old="75.0", new="90.0", on_change_lua="OnFOVChanged" }
   Mutex: UNLOCK
   ```

3. **ScriptingSystem Poll**  
   Next frame, `ScriptingSystem.update()`:
   ```zig
   const events = cvar_registry.takePendingChanges(allocator);
   // events = [{ name="r_fov", old="75.0", new="90.0", on_change_lua="OnFOVChanged" }]
   ```

4. **ActionQueue Message Build**  
   ```zig
   for (events) |ev| {
       if (ev.on_change_lua.len == 0) continue; // Skip if no handler

       // Allocate: "OnFOVChanged\0r_fov\075.0\090.0"
       const msg = action_queue.allocator.alloc(u8, total_len) catch continue;
       // ... memcpy with NUL separators ...

       action_queue.push(.{ .kind = .CVarLua, .message = msg }) catch {
           action_queue.allocator.free(msg);
       };
   }
   ```

5. **Main Thread Dispatch**  
   Later in `ScriptingSystem.update()`:
   ```zig
   while (action_queue.pop()) |action| {
       defer action_queue.allocator.free(action.message);
       if (action.kind == .CVarLua) {
           const parts = parseNulSeparated(action.message);
           // parts = ["OnFOVChanged", "r_fov", "75.0", "90.0"]

           const state = state_pool.acquire() catch continue;
           defer state_pool.release(state);

           lua.callNamedHandler(state, parts[0], &.{parts[1], parts[2], parts[3]});
           // → Invokes Lua: OnFOVChanged("r_fov", "75.0", "90.0")
       }
   }
   ```

6. **Lua Handler Execution**  
   ```lua
   function OnFOVChanged(name, old, new)
       print("FOV changed from " .. old .. " to " .. new)
       -- Update camera projection, etc.
   end
   ```

### Timing Diagram

```
Frame N:
  User → Console → cvar.set("r_fov", "90")
         └─> CVarRegistry.setFromString (mutex held briefly)
             └─> pending_changes.append(...)

Frame N+1:
  ScriptingSystem.update()
  ├─ takePendingChanges() → steals pending_changes
  ├─ Build ActionQueue messages (allocates with action_queue.allocator)
  ├─ action_queue.push(CVarLua)
  ├─ ...
  ├─ action_queue.pop()
  └─ lua.callNamedHandler("OnFOVChanged", ...)
      └─ Lua function executes on main thread
```

---

## Memory & Ownership Model

### Allocator Usage

| Component | Allocator | Lifetime | Freed By |
|-----------|-----------|----------|----------|
| CVarRegistry internals | `registry.allocator` | Until registry deinit | Registry |
| CVar name/description | `registry.allocator` | Until CVar removed | Registry |
| Pending change events | `registry.allocator` | Until `takePendingChanges` | Caller of `takePendingChanges` |
| ActionQueue messages | `action_queue.allocator` | Until popped | ActionQueue consumer (main thread) |
| Lua string copies | Lua's internal allocator | Until GC'd | Lua garbage collector |

### takePendingChanges Ownership

**Pattern**:
```zig
const events = registry.takePendingChanges(allocator);
defer allocator.free(events); // Free the slice itself
for (events) |ev| {
    defer allocator.free(ev.name);
    defer allocator.free(ev.old_value);
    defer allocator.free(ev.new_value);
    defer allocator.free(ev.on_change_lua);
    // Use ev...
}
```

**Critical rule**: Caller takes ownership of the array **and** each string field. All must be freed using the provided allocator.

### ActionQueue Message Ownership

**Pattern**:
```zig
// Build message using action_queue.allocator
const msg = action_queue.allocator.alloc(u8, len) catch return;
// ... fill msg ...
action_queue.push(.{ .kind = .CVarLua, .message = msg }) catch {
    action_queue.allocator.free(msg); // Free on push failure
    return;
};

// Later, consumer:
while (action_queue.pop()) |action| {
    defer action_queue.allocator.free(action.message); // Consumer frees
    // Process action...
}
```

**Critical rule**: Messages are allocated with `action_queue.allocator` and freed by the consumer (main thread).

### Zero-Length Slice Handling

**Problem**: Zig allocators may return zero-length slices that still require `free()` to avoid leaks in internal bookkeeping.

**Solution**: Always use unconditional `defer allocator.free(slice)`, even if `slice.len == 0`.

**Example (correct)**:
```zig
const events = registry.takePendingChanges(allocator);
defer allocator.free(events); // ALWAYS free, even if len==0
```

---

## Type System & Validation

### Type Parsing Rules

| Type | Valid String Examples | Invalid Examples | Notes |
|------|----------------------|------------------|-------|
| Int | "42", "-100", "0" | "3.14", "true", "abc" | Parsed via `std.fmt.parseInt(i64)` |
| Float | "3.14", "-0.5", "100" | "true", "abc" | Parsed via `std.fmt.parseFloat(f64)` |
| Bool | "true", "false", "1", "0" | "yes", "no", "2" | Case-insensitive |
| String | Any UTF-8 | (N/A) | Direct copy, no parsing |

### Bounds Validation

**Numeric types (Int/Float)** support optional `min`/`max` bounds:

```zig
// FOV: 45.0 to 120.0
try registry.registerCVar("r_fov", .Float, "75.0", "...", .{}, null, null, 45.0, 120.0, null);

// Attempt to set invalid value:
registry.setFromString("r_fov", "150.0") catch |err| {
    // err == error.ValueOutOfBounds
};
```

**Validation occurs**:
- At registration (default value must be in bounds)
- At runtime (`setFromString` enforces bounds before committing)

**No validation for**:
- Bool (only true/false)
- String (any valid UTF-8)

### Type Safety Guarantees

1. **No silent coercion**: Setting "true" to an Int CVar returns error, not 1
2. **Bounds are hard limits**: Values outside bounds are rejected, not clamped
3. **Type is immutable**: Cannot change CVar type after registration

---

## Persistence System

### Saved File Format (JSON Example)

**File**: `config/cvars.json`
```json
{
  "r_vsync": "false",
  "r_fov": "90.0",
  "r_shadow_resolution": "4096",
  "g_mouse_sensitivity": "1.5"
}
```

### Save Operation

**Function**: `cvar_config.saveCVars(registry, filepath, .JSON)`

**Behavior**:
1. Iterate all CVARs in registry
2. Filter: only include CVARs with `flags.archived == true`
3. Format each value as string
4. Write to file as JSON object

**When to call**:
- On clean shutdown (`engine.deinit()`)
- On user request (console command: `cvar.save`)

### Load Operation

**Function**: `cvar_config.loadCVars(registry, filepath, .JSON)`

**Behavior**:
1. Parse JSON file
2. For each key-value pair, call `registry.setFromString(key, value)`
3. If CVar doesn't exist, skip (allows config to outlive code changes)
4. If value is invalid, log warning and skip

**When to call**:
- At engine startup, after default CVARs are registered

### Persistence Lifecycle

```
Startup:
  ├─ registerDefaultCVars() (from cvar_defaults.zig)
  ├─ loadCVars("config/cvars.json")
  └─ User-saved values override defaults

Runtime:
  └─ User modifies CVARs via console/UI

Shutdown:
  ├─ saveCVars("config/cvars.json")
  └─ Only archived CVARs are written
```

---

## Integration Points

### Lua API

**Module**: `cvar` (registered in `lua_bindings.zig`)

| Function | Signature | Description |
|----------|-----------|-------------|
| `cvar.set` | `cvar.set(name, value)` | Set CVar (value as string) |
| `cvar.get` | `local val = cvar.get(name)` | Get CVar as string |
| `cvar.reset` | `cvar.reset(name)` | Reset to default |
| `cvar.on_change` | `cvar.on_change(name, handler)` | Attach Lua handler |

**Example**:
```lua
cvar.set("r_vsync", "true")
local vsync = cvar.get("r_vsync") -- "true"

function OnVsyncChanged(name, old, new)
    print(name .. ": " .. old .. " -> " .. new)
end
cvar.on_change("r_vsync", "OnVsyncChanged")
```

### Console Integration

**Built-in commands** (from `console_system.zig`):

| Command | Example | Description |
|---------|---------|-------------|
| `set` | `set r_fov 90` | Set CVar |
| `get` | `get r_fov` | Print CVar value |
| `reset` | `reset r_fov` | Reset to default |
| `list_cvars` | `list_cvars` | List all CVARs |

**Implementation**: Console Lua environment has `cvar` module pre-loaded.

### Editor UI

**CVar Browser Panel** (`editor/src/panels/cvar_browser.zig`):
- Lists all CVARs in a table
- Filters by name/flags (archived, developer, etc.)
- Inline editing with validation
- Reset button per CVar
- Save/Load buttons

**Implementation**:
```zig
pub fn draw(self: *CVarBrowser, registry: *CVarRegistry) void {
    if (imgui.Begin("CVAR Browser", ...)) {
        defer imgui.End();

        const cvars = registry.getAllCVars(); // Returns iterator
        for (cvars) |cvar| {
            imgui.Text(cvar.name);
            imgui.SameLine();
            // Draw input widget based on cvar.cvar_type
            switch (cvar.cvar_type) {
                .Int => {
                    var val = cvar.int_val;
                    if (imgui.InputInt(cvar.name, &val)) {
                        const str = std.fmt.allocPrint(temp_allocator, "{d}", .{val});
                        registry.setFromString(cvar.name, str) catch {};
                    }
                },
                // ... Float, Bool, String ...
            }
        }
    }
}
```

---

## Advanced Features

### Conditional Registration

**Pattern**: Register CVARs only in debug builds or editor mode:
```zig
if (build_options.debug_mode) {
    try registry.registerCVar("d_show_collision", .Bool, "false", "...", .{}, ...);
}
```

### Dynamic CVar Creation

**Use case**: Mods or plugins register their own CVARs at runtime.

**Example**:
```lua
-- Lua script loaded by mod system
cvar.set("mod_example_enabled", "true") -- Auto-creates if not exists?
```

**Note**: Current design requires explicit registration. For dynamic creation, extend `setFromString` to optionally create CVARs with default type/flags.

### CVar Groups

**Pattern**: Use naming convention for logical grouping:
```
r_*  — Rendering
g_*  — Gameplay
d_*  — Debug
ui_* — UI/Editor
```

**UI support**: CVar Browser can filter by prefix.

### Read-Only CVARs

**Use case**: Expose engine state as read-only CVARs (e.g., `r_device_name`).

**Example**:
```zig
try registry.registerCVar("r_device_name", .String, "NVIDIA RTX 3080", "GPU name", .{ .read_only = true }, ...);
```

**Enforcement**: `setFromString` returns `error.ReadOnly`.

---

## Error Handling

### Error Types

| Error | Cause | Recovery |
|-------|-------|----------|
| `error.CVarNotFound` | Name doesn't exist in registry | Check spelling, or register CVar first |
| `error.ReadOnly` | Attempted to modify read-only CVar | Remove `.read_only` flag or use different CVar |
| `error.InvalidValue` | String parse failed (type mismatch) | Provide valid string for CVar type |
| `error.ValueOutOfBounds` | Numeric value outside min/max | Provide value within bounds |
| `error.OutOfMemory` | Allocator exhausted | Increase allocator limits or reduce CVar count |

### Error Handling Pattern

**In Zig**:
```zig
registry.setFromString("r_fov", "200") catch |err| {
    std.log.err("Failed to set r_fov: {}", .{err});
    return; // Keep old value
};
```

**In Lua** (via pcall):
```lua
local success, err = pcall(function()
    cvar.set("r_fov", "200")
end)
if not success then
    print("Error: " .. tostring(err))
end
```

### Validation Failure Logging

**Registry behavior**: On validation failure, registry logs error and returns without modifying CVar.

**Example log**:
```
[ERROR] (cvar) Failed to set 'r_fov': value 200.0 exceeds max 120.0
```

---

## Performance Considerations

### Lock Contention

**Bottleneck**: Single mutex protects entire registry.

**Mitigations**:
- Read-heavy workloads: Consider lock-free snapshots (future optimization)
- Batch operations: Use `takePendingChanges` to minimize lock acquisitions
- Hot path: Cache CVar values in local structs; poll changes infrequently

### String Allocation Overhead

**Problem**: `getAsStringAlloc` allocates on every call.

**Solution**: For frequently-read CVARs, cache the value:
```zig
// At init:
const fov = try std.fmt.parseFloat(f64, try registry.getAsStringAlloc("r_fov", allocator));

// In render loop:
// Use cached `fov` directly, don't query registry
```

### Change Notification Batching

**Optimization**: `pending_changes` accumulates multiple changes per frame; `takePendingChanges` transfers them in one mutex acquisition.

**Benefit**: Reduces per-change lock overhead.

### Lua Handler Overhead

**Cost**: Each Lua `on_change` invocation requires:
- StatePool acquire/release
- Lua stack setup
- Function lookup and call

**Recommendation**: Avoid attaching handlers to CVARs that change every frame (e.g., frame counters). Use polling instead.

---

## Testing Strategy

### Unit Tests

**File**: `engine/src/core/cvar_test.zig`

**Coverage**:
1. **Registration**
   - Register Int/Float/Bool/String CVARs
   - Assert defaults are set correctly
   - Test duplicate registration (should update, not error)

2. **Type Parsing**
   - Valid strings → correct typed values
   - Invalid strings → error (no silent coercion)

3. **Bounds Validation**
   - Values within bounds → accepted
   - Values outside bounds → `error.ValueOutOfBounds`

4. **Change Recording**
   - Modify CVar → `pending_changes` has one entry
   - `takePendingChanges` → pending_changes is empty

5. **Ownership Semantics**
   - `takePendingChanges` transfers ownership
   - Free returned slice and all fields → no leaks

6. **Persistence Round-Trip**
   - Save CVARs → JSON file
   - Load CVARs → values match

**Example**:
```zig
test "CVar bounds validation" {
    var reg = try CVarRegistry.init(std.testing.allocator);
    defer reg.deinit();

    try reg.registerCVar("test_int", .Int, "50", "...", .{}, 0, 100, null, null, null);

    // Valid
    try reg.setFromString("test_int", "75");
    const val1 = try reg.getAsStringAlloc("test_int", std.testing.allocator);
    defer std.testing.allocator.free(val1);
    try std.testing.expectEqualStrings("75", val1);

    // Invalid (too high)
    try std.testing.expectError(error.ValueOutOfBounds, reg.setFromString("test_int", "150"));

    // Value unchanged after error
    const val2 = try reg.getAsStringAlloc("test_int", std.testing.allocator);
    defer std.testing.allocator.free(val2);
    try std.testing.expectEqualStrings("75", val2);
}
```

### Integration Tests

**File**: `examples/cvar_native_test.zig`

**Coverage**:
1. **Lua on_change Dispatch**
   - Register CVar with Lua handler
   - Modify from Zig → Lua handler invoked
   - Assert handler received correct (name, old, new)

2. **Console Integration**
   - Execute `cvar.set("r_fov", "90")` from console
   - Assert CVar updated
   - Assert Lua handler triggered

3. **Persistence**
   - Set CVARs, save to file
   - Restart engine, load file
   - Assert values restored

**Example**:
```zig
// In cvar_native_test.zig:
pub fn main() !void {
    var registry = try CVarRegistry.init(allocator);
    defer registry.deinit();

    try registry.registerCVar("test_var", .Int, "10", "...", .{ .archived = true }, 0, 100, null, null, null);

    // Simulate Lua handler registration
    try registry.setLuaOnChange("test_var", "OnTestChanged");

    // Modify
    try registry.setFromString("test_var", "25");

    // Check pending changes
    const events = try registry.takePendingChanges(allocator);
    defer allocator.free(events);
    try std.testing.expect(events.len == 1);
    try std.testing.expectEqualStrings("test_var", events[0].name);
    try std.testing.expectEqualStrings("10", events[0].old_value);
    try std.testing.expectEqualStrings("25", events[0].new_value);
}
```

---

## Common Patterns

### Pattern 1: Engine Init with Persistence

```zig
pub fn initEngine(allocator: Allocator) !*Engine {
    var engine = try Engine.create(allocator);

    // 1. Register default CVARs
    try cvar_defaults.registerAll(engine.cvar_registry);

    // 2. Load user overrides from disk
    cvar_config.loadCVars(engine.cvar_registry, "config/cvars.json", .JSON) catch |err| {
        std.log.warn("Failed to load CVARs: {}", .{err});
    };

    return engine;
}
```

### Pattern 2: Lua on_change Handler

**Lua script**:
```lua
function OnFOVChanged(name, old_val, new_val)
    print("Field of view changed: " .. old_val .. " -> " .. new_val)
    -- Update camera projection matrix
    camera.setFOV(tonumber(new_val))
end

-- Attach handler at startup
cvar.on_change("r_fov", "OnFOVChanged")
```

### Pattern 3: Editor CVar Browser

```zig
pub fn drawCVarBrowser(registry: *CVarRegistry) void {
    if (!imgui.Begin("CVar Browser", null, 0)) {
        imgui.End();
        return;
    }
    defer imgui.End();

    var iter = registry.cvars.iterator();
    while (iter.next()) |entry| {
        const cvar = entry.value_ptr;

        imgui.PushID(cvar.name.ptr);
        defer imgui.PopID();

        imgui.Text(cvar.name);
        imgui.SameLine();

        switch (cvar.cvar_type) {
            .Bool => {
                var val = cvar.bool_val;
                if (imgui.Checkbox("##value", &val)) {
                    const str = if (val) "true" else "false";
                    registry.setFromString(cvar.name, str) catch {};
                }
            },
            .Int => {
                var val: i32 = @intCast(cvar.int_val);
                if (imgui.InputInt("##value", &val, 1, 10, 0)) {
                    var buf: [32]u8 = undefined;
                    const str = std.fmt.bufPrint(&buf, "{d}", .{val}) catch continue;
                    registry.setFromString(cvar.name, str) catch {};
                }
            },
            // ... Float, String ...
        }
    }
}
```

### Pattern 4: Conditional Debug CVar

```zig
pub fn registerDebugCVars(registry: *CVarRegistry) !void {
    if (build_options.enable_debug_cvars) {
        try registry.registerCVar("d_show_fps", .Bool, "false", "Show FPS overlay", .{}, ...);
        try registry.registerCVar("d_wireframe", .Bool, "false", "Wireframe rendering", .{}, ...);
    }
}
```

---

## Troubleshooting Guide

### Problem: Lua on_change Handler Not Invoked

**Symptoms**: CVar value changes, but Lua function never called.

**Checklist**:
1. ✓ Handler registered: `cvar.on_change("r_fov", "OnFOVChanged")`
2. ✓ Function defined: `function OnFOVChanged(name, old, new) ... end`
3. ✓ ScriptingSystem running: `update()` called each frame
4. ✓ ActionQueue not full: Check `action_queue.capacity`
5. ✓ Lua errors: Check console for script errors during handler execution

**Debug**:
```lua
-- Verify registration
print(cvar.get_lua_handler("r_fov")) -- Should print "OnFOVChanged"

-- Add debug logging in handler
function OnFOVChanged(name, old, new)
    print("HANDLER CALLED: " .. name)
end
```

### Problem: CVar Value Rejected (Bounds Error)

**Symptoms**: `setFromString` returns `error.ValueOutOfBounds`.

**Cause**: Numeric value outside min/max range.

**Solution**:
```zig
// Check bounds in registration:
const cvar = registry.cvars.get("r_fov") orelse return error.NotFound;
std.log.info("r_fov bounds: min={?}, max={?}", .{cvar.min_float, cvar.max_float});

// Adjust value or bounds as needed
```

### Problem: Memory Leak in takePendingChanges

**Symptoms**: Memory usage grows over time when CVARs change frequently.

**Cause**: Forgot to free `CVarChange` string fields.

**Solution**:
```zig
const events = registry.takePendingChanges(allocator);
defer allocator.free(events); // Free slice
for (events) |ev| {
    defer allocator.free(ev.name);          // ← Must free
    defer allocator.free(ev.old_value);     // ← Must free
    defer allocator.free(ev.new_value);     // ← Must free
    defer allocator.free(ev.on_change_lua); // ← Must free
    // Use ev...
}
```

### Problem: Persistence Not Working

**Symptoms**: CVar changes not saved to disk.

**Checklist**:
1. ✓ CVar has `archived` flag: `flags.archived == true`
2. ✓ `saveCVars` called on shutdown
3. ✓ File path exists: `config/` directory must exist
4. ✓ File permissions: Write access to `config/cvars.json`

**Debug**:
```zig
// Manual save test
try cvar_config.saveCVars(registry, "test_cvars.json", .JSON);
// Check file contents
```

### Problem: Type Mismatch Error

**Symptoms**: `setFromString` returns `error.InvalidValue`.

**Cause**: String doesn't match CVar type (e.g., "true" for Int CVar).

**Solution**:
```zig
// Check CVar type:
const cvar = registry.cvars.get("r_vsync") orelse return error.NotFound;
std.log.info("r_vsync type: {}", .{cvar.cvar_type}); // .Bool

// Provide correct string:
try registry.setFromString("r_vsync", "true"); // OK
try registry.setFromString("r_vsync", "1");    // OK
try registry.setFromString("r_vsync", "yes");  // ERROR
```

### Problem: Race Condition / Crash in Multithreaded Access

**Symptoms**: Intermittent crashes when accessing CVARs from worker threads.

**Cause**: Mutex not held, or accessing CVar pointer after releasing mutex.

**Solution**:
```zig
// WRONG:
registry.mutex.lock();
const cvar = registry.cvars.get("r_fov") orelse return error.NotFound;
registry.mutex.unlock();
const fov = cvar.float_val; // ← cvar pointer may be invalidated!

// CORRECT:
registry.mutex.lock();
const cvar = registry.cvars.get("r_fov") orelse {
    registry.mutex.unlock();
    return error.NotFound;
};
const fov = cvar.float_val; // ← read value while holding lock
registry.mutex.unlock();
```

**Best practice**: Use `getAsStringAlloc` from any thread; it handles locking internally.

---

## See Also

- **Quick Reference**: `docs/CVAR_QUICK_REF.md`
- **Console System**: `docs/CONSOLE_SYSTEM.md`
- **Scripting System**: `docs/SCRIPTING_SYSTEM.md`
- **Example Code**: `examples/cvar_native_test.zig`

---

**Document Version**: 2.0  
**Last Updated**: November 5, 2025  
**Maintainer**: Zephyr Engine Team
