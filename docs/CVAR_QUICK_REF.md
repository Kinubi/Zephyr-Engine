# CVar System — Quick Reference

## Console Commands

| Command | Usage | Description |
|---------|-------|-------------|
| `get` | `get <name>` | Print current value of CVar |
| `set` | `set <name> <value>` | Set CVar to value (string parsed by type) |
| `toggle` | `toggle <name>` | Toggle boolean CVar (true ↔ false) |
| `reset` | `reset <name>` | Reset CVar to its default value |
| `list_cvars` | `list_cvars [filter]` | List all CVARs, optionally filter by prefix (e.g., `r_*`) |
| `help` | `help <name>` | Show CVar description and current value |

**Examples**:
```
> set r_fov 90
r_fov set to 90

> get r_fov
r_fov = 90.0 (default: 75.0)

> toggle r_vsync
r_vsync toggled: true -> false

> reset r_fov
r_fov reset to default: 75.0

> list_cvars r_*
r_vsync, r_fov, r_shadow_resolution, r_fullscreen, ...
```

---

## Lua API Reference

### Core Functions

| Function | Signature | Description |
|----------|-----------|-------------|
| `cvar.set` | `cvar.set(name, value)` | Set CVar (value as string) |
| `cvar.get` | `local val = cvar.get(name)` | Get CVar value as string |
| `cvar.reset` | `cvar.reset(name)` | Reset CVar to default |
| `cvar.on_change` | `cvar.on_change(name, handler)` | Register Lua on_change handler |
| `cvar.list` | `local names = cvar.list([filter])` | Get array of CVar names |
| `cvar.get_description` | `local desc = cvar.get_description(name)` | Get CVar description |

### Lua Examples

**Setting Values**:
```lua
cvar.set("r_vsync", "true")
cvar.set("r_fov", "90.0")
cvar.set("g_player_name", "Alice")
```

**Querying Values**:
```lua
local vsync = cvar.get("r_vsync")  -- "true" or "false"
local fov = tonumber(cvar.get("r_fov"))  -- Convert to number: 90.0
```

**Change Handlers**:
```lua
function OnFOVChanged(name, old_val, new_val)
    print(string.format("%s: %s -> %s", name, old_val, new_val))
    -- Update camera projection
    camera.setFOV(tonumber(new_val))
end

-- Register handler at startup
cvar.on_change("r_fov", "OnFOVChanged")
```

**Listing CVARs**:
```lua
local all_cvars = cvar.list()
for _, name in ipairs(all_cvars) do
    print(name .. " = " .. cvar.get(name))
end

local render_cvars = cvar.list("r_*")  -- Filter by prefix
```

---

## Zig API Reference

### CVarRegistry Functions

| Function | Signature | Returns | Description |
|----------|-----------|---------|-------------|
| `init` | `CVarRegistry.init(allocator: Allocator)` | `!CVarRegistry` | Create new registry |
| `deinit` | `registry.deinit()` | `void` | Free all CVARs and internal state |
| `registerCVar` | `registry.registerCVar(name, type, default, desc, flags, ...)` | `!void` | Register or update CVar |
| `setFromString` | `registry.setFromString(name, value)` | `!void` | Set CVar from string (validates type/bounds) |
| `getAsStringAlloc` | `registry.getAsStringAlloc(name, allocator)` | `![]u8` | Get value as allocated string (caller frees) |
| `reset` | `registry.reset(name)` | `!void` | Reset CVar to default value |
| `setLuaOnChange` | `registry.setLuaOnChange(name, handler)` | `!void` | Attach Lua handler name |
| `takePendingChanges` | `registry.takePendingChanges(allocator)` | `![]CVarChange` | Steal pending change events (caller frees) |

### Registration Example

```zig
const CVarFlags = @import("cvar.zig").CVarFlags;

// Bool CVar (archived)
try registry.registerCVar(
    "r_vsync",
    .Bool,
    "true",
    "Enable vertical sync",
    .{ .archived = true },
    null, null, null, null, null
);

// Float CVar with bounds
try registry.registerCVar(
    "r_fov",
    .Float,
    "75.0",
    "Field of view (degrees)",
    .{ .archived = true },
    null, null,     // min_int, max_int (N/A for Float)
    45.0, 120.0,    // min_float, max_float
    null            // no Lua handler yet
);

// String CVar
try registry.registerCVar(
    "g_player_name",
    .String,
    "Player",
    "Player display name",
    .{ .archived = true },
    null, null, null, null, null
);
```

### Setting Values

```zig
// From string
try registry.setFromString("r_fov", "90.0");

// Build string dynamically
var buf: [64]u8 = undefined;
const value_str = try std.fmt.bufPrint(&buf, "{d}", .{new_fov});
try registry.setFromString("r_fov", value_str);
```

### Querying Values

```zig
// As string (allocates)
const val_str = try registry.getAsStringAlloc("r_fov", allocator);
defer allocator.free(val_str);
const fov = try std.fmt.parseFloat(f64, val_str);

// Direct access (requires mutex lock)
registry.mutex.lock();
defer registry.mutex.unlock();
const cvar = registry.cvars.get("r_fov") orelse return error.NotFound;
const fov_direct = cvar.float_val;
```

### Processing Pending Changes

```zig
// In ScriptingSystem.update()
const events = try registry.takePendingChanges(allocator);
defer allocator.free(events);  // Free the slice

for (events) |ev| {
    defer {
        allocator.free(ev.name);
        allocator.free(ev.old_value);
        allocator.free(ev.new_value);
        allocator.free(ev.on_change_lua);
    }

    if (ev.on_change_lua.len == 0) continue;  // No Lua handler

    // Build ActionQueue message
    const msg = action_queue.allocator.alloc(u8, total_len) catch continue;
    // ... copy handler\0name\0old\0new ...
    action_queue.push(.{ .kind = .CVarLua, .message = msg }) catch {
        action_queue.allocator.free(msg);
    };
}
```

---

## CVar Types & Validation

| Type | Storage | Valid Strings | Bounds | Example |
|------|---------|---------------|--------|---------|
| `Int` | `i64` | "42", "-100", "0" | Optional min/max | Shadow resolution |
| `Float` | `f64` | "3.14", "-0.5", "100" | Optional min/max | Field of view |
| `Bool` | `bool` | "true", "false", "1", "0" | N/A | VSync enabled |
| `String` | `ArrayList(u8)` | Any UTF-8 | N/A | Player name |

**Validation Rules**:
- **Type safety**: String must parse correctly for CVar type (e.g., "abc" fails for Int)
- **Bounds enforcement**: Numeric values outside min/max are rejected (not clamped)
- **Case insensitive**: Bool accepts "TRUE", "False", "1", "0"

**Error Behavior**:
- Invalid value → `error.InvalidValue`, CVar unchanged
- Out of bounds → `error.ValueOutOfBounds`, CVar unchanged

---

## CVarFlags

| Flag | Description | Example Use Case |
|------|-------------|------------------|
| `archived` | Persist to disk on save | User preferences (FOV, keybinds) |
| `read_only` | Cannot be modified at runtime | GPU device name, engine version |
| `cheat` | Only modifiable in dev/cheat mode | God mode, infinite ammo |
| `developer` | Only visible in developer mode | Internal debug counters |
| `replicated` | (Reserved) Synced in multiplayer | Server tick rate |

**Example**:
```zig
// User setting: archived for persistence
.{ .archived = true }

// Debug CVar: dev-only, not saved
.{ .developer = true }

// Engine constant: read-only, visible
.{ .read_only = true }
```

---

## Common Patterns

### Pattern 1: Startup Registration + Load

```zig
pub fn initCVars(engine: *Engine) !void {
    // 1. Register defaults
    try cvar_defaults.registerAll(engine.cvar_registry);

    // 2. Load user overrides
    cvar_config.loadCVars(
        engine.cvar_registry,
        "config/cvars.json",
        .JSON
    ) catch |err| {
        std.log.warn("Failed to load CVARs: {}", .{err});
    };
}
```

### Pattern 2: Lua on_change with Validation

```lua
function OnShadowResolutionChanged(name, old, new)
    local res = tonumber(new)
    if res < 512 then
        print("Warning: Shadow resolution too low, performance may suffer")
    end
    renderer.setShadowMapSize(res)
end

cvar.on_change("r_shadow_resolution", "OnShadowResolutionChanged")
```

### Pattern 3: Editor ImGui Binding

```zig
// In CVar browser panel
switch (cvar.cvar_type) {
    .Bool => {
        var val = cvar.bool_val;
        if (imgui.Checkbox("##value", &val)) {
            const str = if (val) "true" else "false";
            registry.setFromString(cvar.name, str) catch {};
        }
    },
    .Float => {
        var val: f32 = @floatCast(cvar.float_val);
        if (imgui.SliderFloat("##value", &val, 
            if (cvar.min_float) |min| @floatCast(min) else 0.0,
            if (cvar.max_float) |max| @floatCast(max) else 100.0
        )) {
            var buf: [32]u8 = undefined;
            const str = std.fmt.bufPrint(&buf, "{d}", .{val}) catch continue;
            registry.setFromString(cvar.name, str) catch {};
        }
    },
    // ... Int, String ...
}
```

### Pattern 4: Cached CVar for Hot Path

```zig
// Avoid querying registry every frame
pub const RenderSettings = struct {
    fov: f64,
    vsync: bool,
    shadow_resolution: i64,
};

// Update once per frame or on change
pub fn updateRenderSettings(
    settings: *RenderSettings,
    registry: *CVarRegistry
) void {
    settings.fov = blk: {
        const s = registry.getAsStringAlloc("r_fov", temp_alloc) catch break :blk 75.0;
        defer temp_alloc.free(s);
        break :blk std.fmt.parseFloat(f64, s) catch 75.0;
    };
    // ... repeat for vsync, shadow_resolution ...
}

// Use cached settings in render loop
pub fn render(settings: RenderSettings) void {
    camera.setFOV(settings.fov);  // No registry access
    // ...
}
```

---

## Memory & Ownership Rules

### Critical Rules

1. **takePendingChanges Ownership**  
   Caller **must free**:
   - The returned slice: `allocator.free(events)`
   - Each `CVarChange` field: `allocator.free(ev.name)`, `allocator.free(ev.old_value)`, etc.

2. **ActionQueue Message Ownership**  
   - Allocate with `action_queue.allocator`
   - Consumer (main thread) frees after processing

3. **getAsStringAlloc Ownership**  
   - Returns allocator-owned string
   - Caller must free

4. **Zero-Length Slices**  
   - Always use `defer allocator.free(slice)` even if `len == 0`
   - Zig allocators may track zero-length allocations

### Memory Leak Prevention

```zig
// CORRECT: Unconditional defer
const events = registry.takePendingChanges(allocator);
defer allocator.free(events);  // ← Always free, even if len==0

// WRONG: Conditional free
if (events.len > 0) {
    defer allocator.free(events);  // ← Leaks if len==0
}
```

---

## Error Reference

| Error | Cause | Solution |
|-------|-------|----------|
| `CVarNotFound` | Name doesn't exist in registry | Check spelling, or register CVar first |
| `ReadOnly` | Attempted to modify read-only CVar | Use different CVar or remove flag |
| `InvalidValue` | String doesn't parse to CVar type | Provide valid string (e.g., "true" for Bool, "42" for Int) |
| `ValueOutOfBounds` | Numeric value outside min/max | Provide value within bounds or adjust bounds |
| `OutOfMemory` | Allocator exhausted | Increase limits or reduce CVar count |

**Lua Error Handling**:
```lua
local success, err = pcall(function()
    cvar.set("r_fov", "999")  -- Out of bounds
end)
if not success then
    print("Error: " .. tostring(err))
end
```

---

## Troubleshooting Checklist

### ❌ Lua Handler Not Invoked

- [ ] Handler registered: `cvar.on_change("name", "HandlerFunc")`
- [ ] Function defined before registration: `function HandlerFunc(name, old, new) ... end`
- [ ] ScriptingSystem running: `update()` called every frame
- [ ] No Lua errors: Check console for script errors
- [ ] ActionQueue not full: Increase capacity if needed

**Debug**:
```lua
print("Handler: " .. (cvar.get_lua_handler("r_fov") or "NONE"))
```

### ❌ Memory Leak in takePendingChanges

- [ ] Slice freed: `defer allocator.free(events)`
- [ ] All fields freed: `name`, `old_value`, `new_value`, `on_change_lua`
- [ ] Unconditional defer (not `if (len > 0)`)

**Fix**:
```zig
const events = registry.takePendingChanges(allocator);
defer allocator.free(events);  // ← Add this
for (events) |ev| {
    defer allocator.free(ev.name);          // ← Add these
    defer allocator.free(ev.old_value);
    defer allocator.free(ev.new_value);
    defer allocator.free(ev.on_change_lua);
    // ...
}
```

### ❌ Bounds Validation Failure

**Symptom**: `error.ValueOutOfBounds`

**Check bounds**:
```zig
const cvar = registry.cvars.get("r_fov") orelse return;
std.log.info("Bounds: [{?d}, {?d}]", .{cvar.min_float, cvar.max_float});
```

**Fix**: Adjust value or widen bounds in registration.

### ❌ Persistence Not Working

- [ ] CVar has `archived` flag: `.{ .archived = true }`
- [ ] `saveCVars` called on shutdown
- [ ] File path exists: `config/` directory
- [ ] Write permissions: Check file system permissions

**Manual test**:
```zig
try cvar_config.saveCVars(registry, "test.json", .JSON);
```

---

## Performance Tips

1. **Cache Frequently-Read CVARs**  
   Avoid querying registry in hot loops; cache values in local structs.

2. **Batch Change Notifications**  
   `takePendingChanges` already batches; don't poll multiple times per frame.

3. **Minimize Lua Handler Work**  
   Keep on_change handlers lightweight; defer heavy work to next frame or worker thread.

4. **Use Direct Access for Critical Path**  
   Lock mutex, read `cvar.int_val` directly instead of string conversion.

5. **Limit Archived CVARs**  
   Only mark user-facing settings as `archived`; don't persist debug/developer CVARs.

---

## See Also

- **Full Documentation**: `docs/CVAR_SYSTEM.md`
- **Console System**: `docs/CONSOLE_SYSTEM.md`
- **Scripting System**: `docs/SCRIPTING_SYSTEM.md`
- **Examples**: `examples/cvar_native_test.zig`

---

**Last Updated**: November 5, 2025

