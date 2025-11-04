# Console & CVAR System TODO

## Overview

Implement a developer console with integrated CVAR (Console Variable) system for runtime configuration and debugging. The console provides a Lua-based REPL with command history, auto-completion, and direct access to engine CVARs.

**Priority**: High  
**Status**: In Progress — Phase 0 (UI + log integration) completed
**Target**: Sprint 4

---

## Goals

1. **Console UI** - ImGui-based developer console with input history
2. **Lua Integration** - Full Lua REPL with pretty-printing
3. **CVAR System** - Type-safe console variables with validation
4. **Auto-completion** - Tab completion for CVARs and Lua functions
5. **Persistence** - Save/load CVAR values and command history
6. **Change Callbacks** - Notify systems when CVARs change

---

## Tasks

### Phase 0: Console UI Implementation (Week 1)

#### Task 0.1: Basic Console Window

- [x] Create `ConsolePanel` struct in `editor/src/ui/panels/console_panel.zig`
- [x] Implement ImGui window with dockable support
- [x] Add input text field with enter key handling
- [x] Add scrollable output area with text coloring
- [x] Toggle visibility with ` (backtick/tilde) key
- [x] Support Ctrl+L to clear output
- [x] **Integrate with engine log system** - Display std.log output in console
- [x] Add log level filtering (debug, info, warning, error)
- [x] Add timestamp display for log messages
 - [ ] Color-code log messages by severity
 - [x] Add search/filter functionality for log messages

> Note: Search implemented in the editor as a lightweight ASCII case-insensitive substring search (see `editor/src/ui/ui_renderer.zig`). This can be extended later to full Unicode or regex search.

**File**: `editor/src/ui/panels/console_panel.zig`

```zig
pub const ConsolePanel = struct {
    allocator: std.mem.Allocator,
    output_buffer: std.ArrayList(ConsoleMessage),
    input_buffer: [1024]u8,
    input_len: usize = 0,
    scroll_to_bottom: bool = false,
    auto_scroll: bool = true,
    show_timestamps: bool = true,
    
    pub const MessageType = enum {
        info,
        warning,
        error,
        command,
        result,
    };
    
    pub const ConsoleMessage = struct {
        text: []const u8,
        type: MessageType,
        timestamp: i64,
    };
    
    pub fn init(allocator: std.mem.Allocator) !ConsolePanel;
    pub fn deinit(self: *ConsolePanel) void;
    pub fn render(self: *ConsolePanel) void;
    pub fn addMessage(self: *ConsolePanel, text: []const u8, msg_type: MessageType) !void;
    pub fn clear(self: *ConsolePanel) void;
    pub fn executeCommand(self: *ConsolePanel, command: []const u8) !void;
};
```

#### Task 0.2: Command History
 - [x] Implement circular buffer for command history (fixed-size ring)
 - [x] Up/Down arrow keys to navigate history
 - [x] Persistent history saved to `cache/console_history.txt`
 - [x] Duplicate commands not added consecutively
 - [ ] Ctrl+R for reverse search in history

> Note: Ctrl+R reverse-search implemented. On some platforms GLFW may not report modifier bits reliably; the editor now falls back to ImGui's KeyCtrl state to trigger reverse-search when the scripting console is open.

 - [x] Ctrl+R for reverse search in history (fallback to ImGui.KeyCtrl when GLFW mods unreliable)

> Implementation notes: History is implemented in `editor/src/ui/ui_renderer.zig` using a fixed-size ring buffer (32 entries). History is loaded from `cache/console_history.txt` on init and written back on deinit. Up/Down navigation, duplicate suppression, and a focus fix so the input keeps focus while navigating have been implemented.

```zig
pub const CommandHistory = struct {
    commands: [64][]const u8,
    head: usize = 0,
    count: usize = 0,
    current_index: ?usize = null,
    
    pub fn add(self: *CommandHistory, command: []const u8) !void;
    pub fn previous(self: *CommandHistory) ?[]const u8;
    pub fn next(self: *CommandHistory) ?[]const u8;
    pub fn reset(self: *CommandHistory) void;
    pub fn save(self: *CommandHistory, path: []const u8) !void;
    pub fn load(self: *CommandHistory, path: []const u8) !void;
};
```

#### Task 0.3: Lua REPL Integration
- [x] Pass commands to Lua interpreter
- [x] Capture stdout/stderr from Lua execution
- [ ] Pretty-print Lua results (tables, functions, etc.)
- [x] Handle Lua errors gracefully with stack traces
- [ ] Support multi-line input (shift+enter)

```zig
pub fn executeLuaCommand(self: *ConsolePanel, lua_state: *lua.State, command: []const u8) !void {
    // Compile and execute Lua
    // Capture output
    // Format and display results
}
```

#### Task 0.4: Output Formatting
- [ ] Word wrap for long lines
- [ ] Clickable file:line links (for errors)
- [ ] Collapsible multi-line output
- [ ] Copy output to clipboard



**File**: `editor/src/ui/ui_renderer.zig`

```zig
pub const UIRenderer = struct {
    // ... existing fields ...
    console_panel: ConsolePanel,
    show_console: bool = false,
    
    pub fn renderConsole(self: *UIRenderer) void;
};
```

#### Task 0.6: Log System Integration
- [ ] Modify existing `engine/src/utils/log.zig` to support console forwarding
- [ ] Add thread-safe log message ring buffer (fixed size to prevent unbounded growth)
- [ ] Forward log messages to console panel in addition to stdout
- [ ] Preserve log levels (TRACE, DEBUG, INFO, WARN, ERROR)
- [ ] Include section names and timestamps
- [ ] Add log message filtering by level in console UI
- [ ] Support log message search/regex filtering
- [ ] Add "Clear Logs" button
- [ ] Implement log message count badges per level

**File**: `engine/src/utils/log.zig` (modify existing)

```zig
const std = @import("std");
const time_format = @import("time_format.zig");

pub const LogLevel = enum { TRACE, DEBUG, INFO, WARN, ERROR };

pub const LogEntry = struct {
    level: LogLevel,
    section: []const u8,
    message: []const u8,
    timestamp: i64,
};

// Thread-safe ring buffer for log entries
var log_buffer: ?*LogRingBuffer = null;
var log_buffer_mutex: std.Thread.Mutex = .{};

pub const LogRingBuffer = struct {
    entries: [1024]LogEntry, // Fixed size ring buffer
    head: usize = 0,
    count: usize = 0,
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) !*LogRingBuffer;
    pub fn push(self: *LogRingBuffer, entry: LogEntry) void;
    pub fn copyEntries(self: *LogRingBuffer, dest: []LogEntry) usize;
};

/// Initialize log forwarding to console
pub fn initConsoleLogging(allocator: std.mem.Allocator) !void {
    log_buffer_mutex.lock();
    defer log_buffer_mutex.unlock();
    log_buffer = try LogRingBuffer.init(allocator);
}

/// Modified log function that forwards to console
pub fn log(
    level: LogLevel,
    section: []const u8,
    comptime fmt: []const u8,
    args: anytype,
) void {
    // ... existing stdout printing code ...
    
    // Forward to console if initialized
    if (log_buffer) |buffer| {
        log_buffer_mutex.lock();
        defer log_buffer_mutex.unlock();
        
        // Format message to string
        var msg_buf: [2048]u8 = undefined;
        const message = std.fmt.bufPrint(&msg_buf, fmt, args) catch "(format error)";
        
        // Push to ring buffer (makes copy of strings)
        buffer.push(.{
            .level = level,
            .section = buffer.allocator.dupe(u8, section) catch section,
            .message = buffer.allocator.dupe(u8, message) catch message,
            .timestamp = std.time.milliTimestamp(),
        });
    }
}
```

**Integration Steps**:
1. Modify `engine/src/utils/log.zig` to add optional console forwarding
2. Call `initConsoleLogging()` when editor starts
3. Console panel reads from ring buffer each frame
4. Add UI controls for filtering (checkboxes for each log level)
5. Color-code messages: TRACE=gray, DEBUG=cyan, INFO=white, WARN=yellow, ERROR=red
6. Ring buffer automatically overwrites old entries when full

---

### Phase 1: Core CVAR System (Week 2)

#### Task 1.1: CVAR Data Structure
- [ ] Create `CVAR` struct with type variants (int, float, bool, string)
- [ ] Implement value validation (min/max, enum values)
- [ ] Add flags (read-only, cheat, archived, latched)
- [ ] Support change callbacks
- [ ] Add help text/description

**File**: `engine/src/core/cvar.zig`

```zig
pub const CVarFlags = packed struct {
    read_only: bool = false,    // Cannot be changed at runtime
    archived: bool = false,      // Saved to config file
    cheat: bool = false,         // Only available in dev builds
    latched: bool = false,       // Requires restart to take effect
};

pub const CVarType = enum {
    int,
    float,
    bool,
    string,
};

pub const CVarValue = union(CVarType) {
    int: i32,
    float: f32,
    bool: bool,
    string: []const u8,
};

pub const CVar = struct {
    name: []const u8,
    description: []const u8,
    value: CVarValue,
    default_value: CVarValue,
    flags: CVarFlags,
    
    // Validation
    min_value: ?CVarValue = null,
    max_value: ?CVarValue = null,
    
    // Callback when value changes
    on_change: ?*const fn (old: CVarValue, new: CVarValue) void = null,
};
```

#### Task 1.2: CVAR Registry
- [ ] Create global CVAR registry (hash map)
- [ ] Implement `registerCVar(name, default, description, flags)`
- [ ] Implement `getCVar(name)` - returns ?*CVar
- [ ] Implement `setCVar(name, value)` - validates and updates
- [ ] Implement `resetCVar(name)` - reset to default
- [ ] Add thread-safe access (mutex if needed)

**File**: `engine/src/core/cvar_registry.zig`

```zig
pub const CVarRegistry = struct {
    cvars: std.StringHashMap(*CVar),
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,
    
    pub fn init(allocator: std.mem.Allocator) CVarRegistry;
    pub fn deinit(self: *CVarRegistry) void;
    
    pub fn register(self: *CVarRegistry, cvar: *CVar) !void;
    pub fn get(self: *CVarRegistry, name: []const u8) ?*CVar;
    pub fn set(self: *CVarRegistry, name: []const u8, value: CVarValue) !void;
    pub fn reset(self: *CVarRegistry, name: []const u8) !void;
    pub fn list(self: *CVarRegistry) []const *CVar;
};
```

#### Task 1.3: Common CVARs
- [ ] Register engine CVARs (r_vsync, r_msaa, r_hdr, etc.)
- [ ] Register editor CVARs (e_show_stats, e_show_gizmos, etc.)
- [ ] Register debug CVARs (d_show_fps, d_wireframe, etc.)

**File**: `engine/src/core/cvar_defaults.zig`

```zig
// Rendering
r_vsync: CVar = .{ .name = "r_vsync", .value = .{ .bool = true }, ... };
r_msaa: CVar = .{ .name = "r_msaa", .value = .{ .int = 1 }, .min = .{ .int = 1 }, .max = .{ .int = 8 } };
r_hdr: CVar = .{ .name = "r_hdr", .value = .{ .bool = true }, ... };
r_fov: CVar = .{ .name = "r_fov", .value = .{ .float = 50.0 }, .min = .{ .float = 30.0 }, .max = .{ .float = 120.0 } };

// Editor
e_show_stats: CVar = .{ .name = "e_show_stats", .value = .{ .bool = true }, ... };
e_show_gizmos: CVar = .{ .name = "e_show_gizmos", .value = .{ .bool = true }, ... };
e_autosave: CVar = .{ .name = "e_autosave", .value = .{ .bool = true }, ... };
e_autosave_interval: CVar = .{ .name = "e_autosave_interval", .value = .{ .int = 300 }, ... };

// Debug
d_show_fps: CVar = .{ .name = "d_show_fps", .value = .{ .bool = true }, ... };
d_wireframe: CVar = .{ .name = "d_wireframe", .value = .{ .bool = false }, ... };
d_show_bounds: CVar = .{ .name = "d_show_bounds", .value = .{ .bool = false }, ... };
```

---

### Phase 2: CVAR Lua Integration (Week 3)

#### Task 2.1: Lua Bindings
- [ ] Expose `getCVar(name)` to Lua
- [ ] Expose `setCVar(name, value)` to Lua
- [ ] Expose `resetCVar(name)` to Lua
- [ ] Expose `listCVars()` to Lua (returns array of CVAR info)
- [ ] Expose `help(cvar_name)` to Lua (shows description)

**File**: `engine/src/scripting/lua_cvar_bindings.zig`

```zig
pub fn registerCVarBindings(L: *lua.State) !void {
    // cvar.get("name") -> value
    lua.register(L, "cvar_get", luaGetCVar);
    
    // cvar.set("name", value) -> success
    lua.register(L, "cvar_set", luaSetCVar);
    
    // cvar.reset("name") -> success
    lua.register(L, "cvar_reset", luaResetCVar);
    
    // cvar.list() -> array of {name, value, description}
    lua.register(L, "cvar_list", luaListCVars);
    
    // cvar.help("name") -> prints description
    lua.register(L, "cvar_help", luaHelpCVar);
}
```

#### Task 2.2: Console Commands
- [ ] Implement `get <cvar>` command (prints value)
- [ ] Implement `set <cvar> <value>` command
- [ ] Implement `toggle <cvar>` command (for booleans)
- [ ] Implement `reset <cvar>` command
- [ ] Implement `list [filter]` command (lists all CVARs matching filter)
- [ ] Implement `help <cvar>` command

**Usage Examples:**
```lua
-- Get value
get r_fov
--> r_fov = 50.0

-- Set value
set r_fov 90
--> r_fov = 90.0

-- Toggle boolean
toggle r_vsync
--> r_vsync = false

-- Reset to default
reset r_fov
--> r_fov = 50.0 (default)

-- List all rendering CVARs
list r_*
--> r_vsync, r_msaa, r_hdr, r_fov

-- Get help
help r_fov
--> r_fov: Field of view in degrees (30.0 - 120.0)
```

#### Task 2.3: Auto-completion
- [ ] Implement tab completion for CVAR names
- [ ] Show matching CVARs when typing partial name
- [ ] Show CVAR description in tooltip

**File**: `editor/src/ui/scripting_console.zig`

---

### Phase 3: Persistence (Week 4)

#### Task 3.1: Config File Format
- [ ] Choose format (JSON, TOML, or custom)
- [ ] Implement save to `config.json` or `cvars.cfg`
- [ ] Implement load from config file
- [ ] Only save CVARs with `archived` flag

**File**: `engine/src/core/cvar_config.zig`

```zig
pub fn saveCVars(registry: *CVarRegistry, path: []const u8) !void;
pub fn loadCVars(registry: *CVarRegistry, path: []const u8) !void;
```

**Example `cvars.cfg`:**
```json
{
  "r_vsync": true,
  "r_msaa": 4,
  "r_fov": 90.0,
  "e_show_stats": true,
  "e_autosave_interval": 300
}
```

#### Task 3.2: Auto-save on Exit
- [ ] Save CVARs when engine shuts down
- [ ] Load CVARs on engine startup
- [ ] Handle errors gracefully (missing file, parse errors)

---

### Phase 4: Advanced Features (Week 5)

#### Task 4.1: Change Callbacks
- [ ] Implement callback registration
- [ ] Trigger callbacks when CVAR changes
- [ ] Support multiple callbacks per CVAR
- [ ] Add callback priorities

**Example:**
```zig
// Register callback for FOV changes
cvar_registry.get("r_fov").?.on_change = onFovChanged;

fn onFovChanged(old: CVarValue, new: CVarValue) void {
    camera.fov = new.float;
    camera.updateProjection();
}
```

#### Task 4.2: Latched CVARs
- [ ] Implement latched flag (requires restart)
- [ ] Show "restart required" message when latched CVAR changes
- [ ] Store pending latched values
- [ ] Apply latched values on next startup

#### Task 4.3: Cheat CVARs
- [ ] Only allow cheats in debug/dev builds
- [ ] Add `sv_cheats` master CVAR
- [ ] Require `sv_cheats 1` to enable cheat CVARs
- [ ] Show warning when enabling cheats

#### Task 4.4: CVAR History
- [ ] Track CVAR value history (last N changes)
- [ ] Implement `undo` command to revert changes
- [ ] Show history in console with timestamps

---

## Integration Points

### 1. Rendering System
```zig
// Use CVARs for render settings
if (cvar_registry.get("r_vsync")) |cvar| {
    enable_vsync = cvar.value.bool;
}

if (cvar_registry.get("r_msaa")) |cvar| {
    msaa_samples = @intCast(cvar.value.int);
}
```

### 2. Camera System
```zig
// FOV callback
fn onFovChanged(old: CVarValue, new: CVarValue) void {
    camera.fov = new.float;
    camera.updateProjection();
}

cvar_registry.get("r_fov").?.on_change = onFovChanged;
```

### 3. Editor UI
```zig
// Sync UI checkboxes with CVARs
if (c.ImGui_Checkbox("Show Stats", &show_stats)) {
    try cvar_registry.set("e_show_stats", .{ .bool = show_stats });
}
```

### 4. Scripting Console
```lua
-- Lua script can query and modify CVARs
local fov = cvar.get("r_fov")
print("Current FOV: " .. fov)

cvar.set("r_fov", 90)
print("FOV changed to 90")
```

---

## Testing

### Unit Tests
- [ ] Test CVAR registration
- [ ] Test get/set operations
- [ ] Test validation (min/max)
- [ ] Test callbacks
- [ ] Test persistence (save/load)
- [ ] Test Lua bindings

### Integration Tests
- [ ] Test CVAR changes affect rendering
- [ ] Test console commands work correctly
- [ ] Test auto-completion
- [ ] Test config file save/load
- [ ] Test latched CVARs

---

## Documentation

- [ ] API documentation (function signatures, usage)
- [ ] User guide (console commands, CVAR list)
- [ ] Developer guide (adding new CVARs, callbacks)
- [ ] Example scripts using CVARs

---

## Success Criteria

- ✅ CVARs can be registered and accessed from C++ code
- ✅ CVARs can be queried and modified from Lua console
- ✅ CVAR values are validated (type, range)
- ✅ CVARs are saved to config file on exit
- ✅ CVARs are loaded from config file on startup
- ✅ Tab completion works for CVAR names
- ✅ Callbacks are triggered when CVARs change
- ✅ Latched CVARs require restart
- ✅ Cheat CVARs only work with sv_cheats enabled

---

## Future Enhancements

- Network-synced CVARs (for multiplayer)
- CVAR profiles (save/load different configurations)
- CVAR groups (toggle entire categories)
- CVAR search/filter in UI
- CVAR inspector panel (show all CVARs in tree view)
- CVAR diff tool (compare current vs default values)
- CVAR export/import (share configurations)

---

## Related Files

**Core System:**
- `engine/src/core/cvar.zig` - CVAR structure
- `engine/src/core/cvar_registry.zig` - Registry and management
- `engine/src/core/cvar_defaults.zig` - Default CVARs
- `engine/src/core/cvar_config.zig` - Persistence

**Scripting:**
- `engine/src/scripting/lua_cvar_bindings.zig` - Lua bindings

**Editor:**
- `editor/src/ui/scripting_console.zig` - Console UI
- `editor/src/ui/cvar_inspector.zig` - CVAR inspector panel (optional)

---

## Dependencies

- Lua (for console integration)
- JSON parser (for config file) OR TOML parser
- Hash map (for CVAR registry)

---

## Estimated Effort

- Phase 0 (Console UI): 3-4 days
- Phase 1 (CVAR Core): 3-4 days
- Phase 2 (CVAR Lua): 2-3 days
- Phase 3 (Persistence): 2 days
- Phase 4 (Advanced): 3-4 days

**Total**: ~3-4 weeks for complete implementation

---

## Implementation Order

1. **Console UI First** - Build the UI shell before CVAR system
2. **Basic Lua REPL** - Get command execution working
3. **CVAR System** - Add type-safe variables
4. **CVAR Commands** - Integrate CVARs into console
5. **Polish** - Auto-completion, persistence, advanced features
