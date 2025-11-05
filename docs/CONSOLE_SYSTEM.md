# Console System — Comprehensive Design & Reference

## Table of Contents

1. [Overview](#overview)
2. [Goals & Design Principles](#goals--design-principles)
3. [Architecture](#architecture)
4. [Component Breakdown](#component-breakdown)
5. [API Reference](#api-reference)
6. [UI Behavior & Controls](#ui-behavior--controls)
7. [Execution Flow](#execution-flow)
8. [Memory & Ownership Model](#memory--ownership-model)
9. [Integration Points](#integration-points)
10. [Advanced Features](#advanced-features)
11. [Error Handling & Diagnostics](#error-handling--diagnostics)
12. [Performance Considerations](#performance-considerations)
13. [Testing Strategy](#testing-strategy)
14. [Common Patterns & Examples](#common-patterns--examples)
15. [Troubleshooting Guide](#troubleshooting-guide)
16. [Future Enhancements](#future-enhancements)

---

## Overview

The **Console System** is a production-ready, ImGui-based developer console integrated into the Zephyr Engine editor. It provides a powerful Lua REPL (Read-Eval-Print Loop) for runtime introspection, debugging, and rapid prototyping. The console serves as the primary interface for developers to interact with the engine's subsystems, query and modify CVARs, execute scripts, and observe real-time logging output.

### Key Capabilities

- **Lua REPL**: Execute arbitrary Lua code with full access to engine bindings
- **Persistent Command History**: 32-entry ring buffer saved to disk between sessions
- **Reverse History Search**: Ctrl+R incremental search through command history
- **Log Integration**: Real-time display of engine logs with filtering by severity level
- **Multi-line Input**: Shift+Enter for complex scripts and formatted code blocks
- **Auto-completion**: Tab-completion for CVAR names, Lua globals, and table members
- **Syntax Highlighting**: Color-coded output for errors, warnings, and results
- **Thread-Safe Execution**: Scripts run on worker threads with safe main-thread dispatch

### Use Cases

1. **Runtime Debugging**: Inspect entity states, component values, and system behavior
2. **Performance Profiling**: Query performance stats and toggle debug visualizations
3. **Content Iteration**: Modify material properties, spawn entities, adjust lighting in real-time
4. **System Testing**: Trigger edge cases, stress-test subsystems, validate state transitions
5. **Configuration Management**: Query and modify CVARs without recompiling

---

## Goals & Design Principles

### Primary Goals

1. **Developer Ergonomics**: Minimize friction for common workflows (set CVAR, spawn entity, query state)
2. **Safety**: Prevent crashes from user errors; isolate script execution from engine state
3. **Performance**: Async execution for expensive scripts; minimal overhead for log forwarding
4. **Persistence**: Remember history, settings, and frequently-used commands across sessions
5. **Extensibility**: Easy to add new commands, bindings, and integrations

### Design Principles

- **Separation of Concerns**: Console UI, execution engine, and log forwarding are independent
- **Clear Ownership**: Console UI owns display buffers; ActionQueue owns cross-thread messages
- **Fail-Safe**: Lua errors are caught and displayed; console remains usable after errors
- **Non-Blocking**: Long-running scripts execute on workers; console remains responsive
- **Zero-Copy Logging**: Log ring buffer minimizes allocations; console reads directly from buffer

---

## Architecture

### High-Level Component Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                      Editor (Main Thread)                    │
├─────────────────────────────────────────────────────────────┤
│                                                               │
│  ┌───────────────────┐         ┌──────────────────────┐     │
│  │   UIRenderer      │────────>│   ConsolePanel       │     │
│  │                   │         │  (ImGui UI)          │     │
│  │ - command_history │         │  - input_buffer      │     │
│  │ - console state   │         │  - output_log        │     │
│  └───────────────────┘         │  - filter_state      │     │
│           │                    └──────────────────────┘     │
│           │                               │                  │
│           v                               v                  │
│  ┌─────────────────────────────────────────────────────┐    │
│  │          ScriptingSystem                             │    │
│  │  - drains ActionQueue                                │    │
│  │  - handles CVarLua actions                           │    │
│  │  - leases lua_State for handlers                     │    │
│  └─────────────────────────────────────────────────────┘    │
│           │                               │                  │
└───────────┼───────────────────────────────┼──────────────────┘
            │                               │
            v                               v
   ┌────────────────────┐         ┌──────────────────┐
   │   ActionQueue      │<────────│   ScriptRunner   │
   │ (thread-safe)      │         │  (ThreadPool)    │
   │ - ScriptResult     │         │  - enqueues jobs │
   │ - CVarLua          │         │  - worker exec   │
   └────────────────────┘         └──────────────────┘
            ^                               │
            │                               v
            │                      ┌────────────────┐
            │                      │   StatePool    │
            │                      │ (lua_State*)   │
            │                      └────────────────┘
            │
   ┌────────────────────┐
   │  LogRingBuffer     │
   │  (thread-safe)     │
   │  - engine logs     │
   │  - forwarded msgs  │
   └────────────────────┘
```

### Data Flow Overview

1. **Input Path**:
   - User types command → ConsolePanel input buffer
   - On Enter → passed to ScriptingSystem
   - ScriptingSystem → enqueues script via ScriptRunner
   - Worker thread → leases lua_State, executes script
   - Worker → pushes ScriptResult Action to ActionQueue

2. **Output Path**:
   - Main thread → drains ActionQueue in scripting_system.update
   - ScriptResult action → formatted and displayed in console output
   - Lua return values → converted to string and shown

3. **Log Forwarding**:
   - Any thread calls `log(level, section, fmt, args)`
   - log.zig → formats message and pushes to LogRingBuffer
   - Console UI → reads from ring buffer each frame
   - Logs displayed with color-coding by severity

---

## Component Breakdown

### ConsolePanel (editor/src/ui/panels/console_panel.zig)

**Responsibilities**:
- Render ImGui window with input field and scrollable output area
- Handle keyboard input (Enter, Up/Down, Ctrl+L, Ctrl+R)
- Display formatted log messages with color-coding
- Manage filter state (show/hide by log level)
- Auto-scroll to bottom on new output

**Key Fields**:
```zig
pub const ConsolePanel = struct {
    allocator: std.mem.Allocator,
    output_buffer: std.ArrayList(ConsoleMessage),
    input_buffer: [1024]u8,
    input_len: usize = 0,
    scroll_to_bottom: bool = false,
    auto_scroll: bool = true,
    show_timestamps: bool = true,
    log_filter_trace: bool = true,
    log_filter_debug: bool = true,
    log_filter_info: bool = true,
    log_filter_warn: bool = true,
    log_filter_error: bool = true,
};
```

**Message Types**:
```zig
pub const MessageType = enum {
    info,     // white
    warning,  // yellow
    error,    // red
    command,  // cyan (echoed user input)
    result,   // green (script output)
};
```

### CommandHistory (editor/src/ui/ui_renderer.zig)

**Responsibilities**:
- Store last 32 commands in a ring buffer
- Navigate history with Up/Down arrows
- Implement reverse-search (Ctrl+R) using incremental substring matching
- Save/load history from `cache/console_history.txt`
- Deduplicate consecutive identical commands

**Implementation Notes**:
- Fixed-size ring buffer (32 entries) to bound memory usage
- Stores command strings allocated from page allocator
- On deinit, writes history to disk (one command per line)
- On init, loads history from disk (up to 32 most recent)
- Reverse-search is ASCII case-insensitive substring match

### Log Forwarding (engine/src/utils/log.zig)

**Ring Buffer Design**:
```zig
pub const LogEntry = struct {
    level: LogLevel,
    section: []const u8,
    message: []const u8,
    timestamp: i64,
};

pub const LogRingBuffer = struct {
    entries: [1024]LogEntry,  // Fixed capacity
    head: usize = 0,
    count: usize = 0,
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
};
```

**Thread-Safety**:
- All log calls acquire mutex before writing to ring buffer
- Ring buffer overwrites oldest entries when full (no blocking)
- Console UI reads entries without blocking (tryLock or separate consumer buffer)

**Integration**:
- Call `initConsoleLogging(allocator)` at editor startup
- Existing `log()` calls automatically forward to ring buffer
- No changes required to existing logging code

---

## API Reference

### Core Functions

#### executeLuaBuffer

```zig
pub fn executeLuaBuffer(
    allocator: std.mem.Allocator,
    state: *anyopaque,
    buf: []const u8,
    owner_entity: u32,
    user_ctx: ?*anyopaque
) !ExecuteResult
```

**Purpose**: Execute a Lua code buffer on a given `lua_State`.

**Parameters**:
- `allocator`: Allocator for error/return message strings
- `state`: Opaque pointer to `lua_State` (cast from `*c.lua_State`)
- `buf`: Lua source code (UTF-8 encoded)
- `owner_entity`: Entity ID to expose as `entity_id` global (0 = none)
- `user_ctx`: Optional context pointer exposed as `zephyr_user_ctx` lightuserdata

**Returns**: `ExecuteResult{ .success: bool, .message: []const u8 }`

**Ownership**:
- **Caller must free** `message` if non-empty using the same `allocator`
- Message is NUL-terminated for C interop but slice excludes NUL

**Behavior**:
- If `buf` fails to compile, checks for `<eof>` error marker
- If present, retries with `return <buf>` to print bare expressions
- On success with return values, converts top stack value to string and returns as message
- Clears Lua stack after execution to prevent state leakage

**Example**:
```zig
const result = try lua.executeLuaBuffer(
    allocator,
    leased_state,
    "print('Hello'); return 42",
    0,
    null
);
defer if (result.message.len > 0) allocator.free(result.message);

if (result.success) {
    std.debug.print("Output: {s}\n", .{result.message}); // "42"
}
```

#### callNamedHandler

```zig
pub fn callNamedHandler(
    allocator: std.mem.Allocator,
    state: *anyopaque,
    handler: []const u8,
    name: []const u8,
    old: []const u8,
    new: []const u8
) !ExecuteResult
```

**Purpose**: Invoke a named Lua function with three string arguments (used for CVAR on_change handlers).

**Parameters**:
- `handler`: Name of Lua function to call (e.g., "OnFovChanged")
- `name`: First argument (typically CVAR name)
- `old`: Second argument (old value as string)
- `new`: Third argument (new value as string)

**Returns**: `ExecuteResult` (success + optional error message)

**Ownership**: Same as `executeLuaBuffer`

**Behavior**:
- Looks up global function by name using `lua_getglobal`
- If not a function, pops stack and returns failure with empty message
- Pushes three string arguments and calls via `lua_pcallk`
- On error, returns formatted error message allocated from `allocator`

**Example**:
```zig
const res = try lua.callNamedHandler(
    allocator,
    leased_state,
    "OnVsyncChanged",
    "r_vsync",
    "true",
    "false"
);
defer if (res.message.len > 0) allocator.free(res.message);
```

---

## UI Behavior & Controls

### Keyboard Shortcuts

| Key Combination | Action |
|-----------------|--------|
| `` ` `` (backtick) | Toggle console visibility |
| `Enter` | Execute current input line |
| `Shift+Enter` | Insert newline (multi-line input) |
| `Up` / `Down` | Navigate command history |
| `Ctrl+R` | Reverse-search history |
| `Tab` | Auto-complete (CVAR names, Lua globals) |
| `Ctrl+L` | Clear output log |
| `Escape` | Clear current input / cancel search |

### Input Field Behavior

- **Single-line mode** (default): Enter executes, Shift+Enter inserts newline
- **Multi-line indicator**: Small icon shown when input contains newlines
- **Syntax highlighting**: Basic color-coding for Lua keywords and strings
- **Auto-indent**: Maintains indentation on newline (Shift+Enter)

### Output Log Features

- **Auto-scroll**: Automatically scrolls to bottom on new messages (toggleable)
- **Manual scroll**: Scrolling up disables auto-scroll until user scrolls to bottom
- **Clickable links**: File paths with line numbers become clickable (e.g., `foo.zig:42`)
- **Copy to clipboard**: Right-click message to copy text
- **Collapsible blocks**: Long Lua table outputs can be collapsed

### Log Filtering

Checkboxes at top of console:
- **Trace** (gray) - Very verbose debug info
- **Debug** (cyan) - Detailed diagnostic messages
- **Info** (white) - Normal informational messages
- **Warn** (yellow) - Warnings and deprecation notices
- **Error** (red) - Errors and failures

### Search & Filter

- **Text search**: Filter logs by substring (case-insensitive)
- **Regex mode**: Toggle regex pattern matching
- **Live update**: Filter applied as you type
- **Match highlighting**: Matched text highlighted in yellow

---

## Execution Flow

### Console Command Execution (Step-by-Step)

```
┌─────────────────────────────────────────────────────────────┐
│ 1. User Input                                                │
│    User types: set r_fov 90                                  │
│    Presses Enter                                              │
└────────────────┬────────────────────────────────────────────┘
                 │
                 v
┌─────────────────────────────────────────────────────────────┐
│ 2. Input Validation                                          │
│    ConsolePanel checks input buffer                          │
│    Trims whitespace, checks for empty input                  │
│    Adds to history (if non-empty, non-duplicate)             │
└────────────────┬────────────────────────────────────────────┘
                 │
                 v
┌─────────────────────────────────────────────────────────────┐
│ 3. Command Parsing                                           │
│    Check for built-in commands (get, set, toggle, etc.)     │
│    If built-in: execute directly via CVAR registry           │
│    If not: treat as Lua code                                 │
└────────────────┬────────────────────────────────────────────┘
                 │
                 v
┌─────────────────────────────────────────────────────────────┐
│ 4. Lua Execution (Async Path)                                │
│    UIRenderer → ScriptingSystem.runScript()                  │
│    ScriptRunner.enqueueScript() copies script bytes          │
│    Creates ScriptJob, submits to ThreadPool                  │
└────────────────┬────────────────────────────────────────────┘
                 │
                 v
┌─────────────────────────────────────────────────────────────┐
│ 5. Worker Thread Execution                                   │
│    Worker picks up job from ThreadPool queue                 │
│    Leases lua_State from StatePool                           │
│    Calls executeLuaBuffer(runner.alloc, state, script, ...)  │
│    On success/error: captures result message                 │
└────────────────┬────────────────────────────────────────────┘
                 │
                 v
┌─────────────────────────────────────────────────────────────┐
│ 6. Result Marshalling                                        │
│    Worker allocates message with ActionQueue.allocator       │
│    Creates Action{ kind=ScriptResult, message=... }          │
│    Pushes to ActionQueue (thread-safe)                       │
│    Frees runner-allocated temp buffers                       │
│    Releases lua_State back to StatePool                      │
└────────────────┬────────────────────────────────────────────┘
                 │
                 v
┌─────────────────────────────────────────────────────────────┐
│ 7. Main Thread Consumption                                   │
│    ScriptingSystem.update() drains ActionQueue               │
│    For ScriptResult actions: formats and logs output         │
│    ConsolePanel reads from log buffer                        │
│    Displays result with appropriate color-coding             │
│    Frees action message using ActionQueue.allocator          │
└─────────────────────────────────────────────────────────────┘
```

### Synchronous Execution Path

For simple/fast scripts (< 2ms), console can execute synchronously:

```zig
// In ConsolePanel or UIRenderer:
if (script_is_simple) {
    const leased = state_pool.acquire();
    const result = lua.executeLuaBuffer(allocator, leased, script, 0, null);
    state_pool.release(leased);
    
    // Display result immediately
    displayOutput(result);
    
    if (result.message.len > 0) allocator.free(result.message);
}
```

---

## Memory & Ownership Model

### Allocator Responsibilities

| Component | Allocator | Lifetime | Freed By |
|-----------|-----------|----------|----------|
| Console output messages | `page_allocator` | Until cleared | Console UI |
| Command history strings | `page_allocator` | Session | UIRenderer.deinit |
| Lua result messages | Worker: `runner.alloc`<br>Main: `action_queue.alloc` | Single frame | Worker copies to AQ alloc, then main thread frees |
| ActionQueue payloads | `action_queue.allocator` (page) | Until consumed | Main thread (ScriptingSystem) |
| Log ring buffer entries | `log_ring_buffer.allocator` | Overwritten | Ring buffer (circular) |

### Cross-Thread Message Pattern

**Problem**: Worker thread allocates message, main thread must free it.

**Solution**: Copy-on-push pattern:

```zig
// Worker thread:
const temp_msg = try runner.allocator.alloc(u8, result.len);
std.mem.copy(u8, temp_msg, result);

const aq_msg = try action_queue.allocator.alloc(u8, result.len);
std.mem.copy(u8, aq_msg, temp_msg);
runner.allocator.free(temp_msg);  // Free temp immediately

const action = Action{
    .id = job.id,
    .kind = .ScriptResult,
    .message = aq_msg,  // ActionQueue allocator buffer
};
try action_queue.push(action);
```

**Main thread**:
```zig
const action = action_queue.tryPop() orelse return;
defer if (action.message) |m| action_queue.allocator.free(m);

// Use action.message...
```

### Common Pitfalls

1. **Double-free**: Freeing message with wrong allocator
   - Solution: Always use ActionQueue.allocator for cross-thread messages

2. **Memory leak**: Forgetting to free ExecuteResult.message
   - Solution: Add `defer` immediately after calling executeLuaBuffer

3. **Use-after-free**: Accessing message after freeing
   - Solution: Copy message if needed beyond current scope

---

## Integration Points

### With CVAR System

Console provides built-in commands for CVAR manipulation:

```lua
-- Get CVAR value
get r_fov              -- prints "50.0"

-- Set CVAR
set r_fov 90           -- validates and updates

-- Toggle boolean
toggle r_vsync         -- flips true/false

-- Reset to default
reset r_fov            -- restores default value

-- List CVARs (glob pattern)
list r_*               -- shows all rendering CVARs

-- Get help
help r_fov             -- shows description and bounds
```

**Implementation**:
- `cvar.get`, `cvar.set`, etc. are Lua bindings that call CVarRegistry methods
- Console parses simple commands and translates to Lua calls
- More complex operations use direct Lua: `cvar.set("r_fov", tonumber(cvar.get("r_fov")) + 10)`

### With Logging System

**Setup** (at editor init):
```zig
try log.initConsoleLogging(allocator);
```

**Automatic forwarding**:
```zig
log(.INFO, "rendering", "Swapchain recreated: {}x{}", .{width, height});
// → Appears in console with [INFO] [rendering] prefix
```

**Custom log entries** from Lua:
```lua
engine_log("Custom message from Lua script")
-- OR
print("This also appears in console")  -- print is aliased to engine_log
```

### With Entity System

Lua bindings expose entity operations:

```lua
-- Get current entity (if script attached to entity)
local ent = entity_id

-- Translate entity
translate_entity(1.0, 0.0, 0.0)  -- dx, dy, dz

-- Query entity components (via Scene pointer)
-- (Requires extending lua_bindings with additional helpers)
```

---

## Advanced Features

### Multi-Line Scripts

Console supports multi-line input for complex scripts:

```lua
-- Press Shift+Enter after each line (except last)
function spawn_cube(x, y, z)
    local ent = scene.createEntity()
    scene.addComponent(ent, Transform, {x, y, z})
    scene.addComponent(ent, MeshRenderer, "cube")
    return ent
end

spawn_cube(0, 5, 0)  -- Press Enter to execute
```

**Tips**:
- Use proper indentation for readability
- Console preserves formatting in history
- Errors show line numbers within your script

### Auto-Completion

Tab-completion works for:

1. **CVAR names**: Type `r_` and press Tab → shows `r_vsync`, `r_fov`, etc.
2. **Lua globals**: Type `cva` + Tab → completes to `cvar`
3. **Table members**: Type `cvar.` + Tab → shows `get`, `set`, etc. (if introspection enabled)

**Implementation Note**: Currently basic prefix-matching; future: fuzzy matching and context-aware suggestions.

### History Management

**Persistence**:
- History saved to `cache/console_history.txt` on editor shutdown
- Format: one command per line (UTF-8)
- Max 32 entries saved (most recent first)

**Reverse-Search** (Ctrl+R):
```
(reverse-i-search)`fov': set r_fov 90
```
- Type to filter matching commands
- Press Ctrl+R again to cycle through matches
- Press Enter to execute selected command
- Press Escape to cancel search

---

## Error Handling & Diagnostics

### Lua Error Display

When a Lua error occurs:

```
[ERROR] [lua] attempt to call a nil value (global 'foo')
stack traceback:
    [string "..."]:1: in main chunk
```

**Console behavior**:
- Error message displayed in red
- Stack trace included (if available)
- Console remains functional (error doesn't crash editor)
- Input buffer retains failed command for editing

### Common Lua Errors

| Error | Cause | Solution |
|-------|-------|----------|
| `attempt to call a nil value` | Function doesn't exist | Check spelling, ensure binding registered |
| `attempt to index a nil value` | Table/object is nil | Check that object exists before accessing |
| `bad argument #N to 'func'` | Wrong type passed | Convert types explicitly (tonumber, tostring) |
| `<eof>` in error message | Incomplete syntax | Complete the expression or check parentheses |

### Debugging Tips

1. **Use print() liberally**: `print("var =", var)` to inspect values
2. **Check types**: `print(type(var))` to verify type
3. **Inspect tables**: `for k,v in pairs(t) do print(k, v) end`
4. **Try simple versions first**: Break complex scripts into steps

---

## Performance Considerations

### Async Execution Benefits

- **Non-blocking**: Long scripts don't freeze editor UI
- **Parallel**: Multiple scripts can run simultaneously on different workers
- **Responsive**: Console remains interactive during execution

**When to use**:
- Scripts that query large data sets
- AI pathfinding or complex calculations
- Any operation > 1-2ms

### Synchronous Fallback

For very simple scripts (e.g., `cvar.get("r_fov")`), synchronous execution is faster:

```zig
// Check if script is simple heuristic:
const is_simple = script.len < 128 and 
                  std.mem.indexOf(u8, script, "for ") == null and
                  std.mem.indexOf(u8, script, "while ") == null;
```

### Log Forwarding Overhead

**Minimal impact**:
- Ring buffer: O(1) insertion
- Mutex contention: ~100ns on uncontended lock
- Memory: Fixed 1024 entries × ~200 bytes = ~200 KB

**Best practices**:
- Avoid logging in tight loops
- Use TRACE level for very verbose output (disabled in release builds)

---

## Testing Strategy

### Manual Testing Checklist

- [ ] Toggle console with `` ` `` key
- [ ] Execute simple Lua: `return 1 + 1` → displays "2"
- [ ] Execute command: `set r_fov 90` → CVAR updated
- [ ] Navigate history with Up/Down
- [ ] Reverse-search with Ctrl+R
- [ ] Multi-line input with Shift+Enter
- [ ] Lua error displays correctly
- [ ] Log messages appear with correct colors
- [ ] Filter logs by level (toggle checkboxes)
- [ ] Auto-scroll to bottom on new message
- [ ] History persists across editor restarts

### Automated Tests

**Unit Tests** (`tests/console_test.zig`):
```zig
test "executeLuaBuffer returns result" {
    const alloc = std.testing.allocator;
    const state = lua.createLuaState(alloc);
    defer lua.destroyLuaState(state);
    
    const result = try lua.executeLuaBuffer(
        alloc,
        state,
        "return 42",
        0,
        null
    );
    defer if (result.message.len > 0) alloc.free(result.message);
    
    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("42", result.message);
}
```

**Integration Tests**:
- Console → ScriptRunner → ActionQueue → Result display
- CVAR change → Lua handler → ActionQueue → Handler invoked
- Log forwarding → Ring buffer → Console display

---

## Common Patterns & Examples

### Pattern: Query Entity State

```lua
-- Get entity ID from script context
local ent = entity_id

-- Query transform (assuming binding exists)
local pos = scene.getPosition(ent)
print("Entity position:", pos.x, pos.y, pos.z)
```

### Pattern: Batch CVAR Updates

```lua
-- Save current FOV, set temp value, restore later
local old_fov = cvar.get("r_fov")
cvar.set("r_fov", "120")  -- Wide FOV for screenshot
-- ... do screenshot ...
cvar.set("r_fov", old_fov)  -- Restore
```

### Pattern: Conditional Execution

```lua
if tonumber(cvar.get("r_msaa")) < 4 then
    print("Warning: MSAA quality is low")
    cvar.set("r_msaa", "4")
end
```

### Pattern: Loop Over Entities

```lua
-- Assuming scene.getAllEntities() binding exists
for _, ent in ipairs(scene.getAllEntities()) do
    print("Entity:", ent)
end
```

---

## Troubleshooting Guide

### Console Won't Open

**Symptoms**: Pressing `` ` `` key does nothing

**Causes**:
1. Key binding conflict (another system capturing backtick)
2. Console disabled in build config
3. ImGui not initialized

**Solutions**:
- Check UILayer event handler for key conflicts
- Verify `show_scripting_console` flag in UIRenderer
- Check ImGui context is valid

### Commands Not Executing

**Symptoms**: Press Enter, nothing happens

**Causes**:
1. Empty input buffer
2. Script execution disabled
3. ScriptingSystem not running

**Solutions**:
- Check input_len > 0
- Verify ScriptingSystem is in Scene's system list
- Check ThreadPool has active workers

### History Not Persisting

**Symptoms**: Command history lost on restart

**Causes**:
1. `cache/` directory doesn't exist
2. File permissions issue
3. Crash before deinit/save

**Solutions**:
- Create `cache/` directory manually
- Check write permissions
- Ensure graceful shutdown calls UIRenderer.deinit

### Lua Errors on Simple Scripts

**Symptoms**: `cvar.get("r_fov")` fails with "nil value"

**Causes**:
1. Bindings not registered
2. Wrong function name
3. CVAR doesn't exist

**Solutions**:
- Verify `registerEngineBindings()` called at Lua state creation
- Use tab-completion to check available functions
- Use `list` command to see available CVARs

---

## Future Enhancements

### Planned Features

1. **Script Debugging**:
   - Breakpoints in Lua scripts
   - Step-through execution
   - Variable watch window

2. **Command Aliases**:
   - Define shortcuts: `alias ss "screenshot"`
   - Persistent aliases in config

3. **Macro Recording**:
   - Record sequence of commands
   - Save as named macro
   - Replay with single command

4. **Scripted Startup**:
   - Execute `autoexec.lua` on editor startup
   - Per-project startup scripts

5. **Enhanced Auto-Completion**:
   - Fuzzy matching
   - Context-aware suggestions
   - Inline documentation tooltips

6. **Console Themes**:
   - Customizable color schemes
   - Font selection
   - Transparency/blur effects

### Known Limitations

1. **Single Console Instance**: Only one console active at a time (no split panes)
2. **No Line Editing**: Can't edit previous lines in multi-line input (must retype)
3. **Limited Table Inspection**: Nested tables not fully explored (manual iteration required)
4. **No Script Files**: Can't directly load/execute `.lua` files (must copy-paste or use Lua `dofile`)

---

For a condensed quick-ref, see `docs/CONSOLE_QUICK_REF.md`.
