# Console System — Quick Reference

## Keyboard Shortcuts

| Key | Action | Notes |
|-----|--------|-------|
| `` ` `` | Toggle console | Backtick/tilde key |
| `Enter` | Execute input | Runs current command |
| `Shift+Enter` | New line | Multi-line scripts |
| `Up` / `Down` | History | Navigate previous commands |
| `Ctrl+R` | Reverse search | Incremental history search |
| `Tab` | Auto-complete | CVARs and Lua globals |
| `Ctrl+L` | Clear output | Empties console log |
| `Escape` | Cancel | Clear input or exit search |

## Built-in Commands

### CVAR Operations

```lua
get r_fov                    -- Print current value
set r_fov 90                 -- Set new value
toggle r_vsync               -- Flip boolean
reset r_fov                  -- Restore default
list r_*                     -- List with glob pattern
help r_fov                   -- Show description + bounds
```

### Lua CVAR API

```lua
cvar.get("r_fov")            -- Returns string value
cvar.set("r_fov", "90")      -- Validates and updates
cvar.toggle("r_vsync")       -- Boolean flip
cvar.reset("r_fov")          -- Reset to default
cvar.list()                  -- Array of all CVARs
cvar.help("r_fov")           -- Print help text
cvar.archive("r_fov", true)  -- Mark for persistence
cvar.on_change("r_fov", "HandlerName")  -- Register Lua callback
```

## Common Patterns

### Inspect Values
```lua
return cvar.get("r_fov")                    -- Print single CVAR
print(cvar.get("r_fov"), cvar.get("r_msaa")) -- Multiple values
```

### Conditional Updates
```lua
if tonumber(cvar.get("r_msaa")) < 4 then
    cvar.set("r_msaa", "4")
end
```

### Batch Changes
```lua
cvar.set("r_vsync", "false")
cvar.set("r_msaa", "8")
cvar.set("r_fov", "90")
```

### Register Change Handler
```lua
function OnFovChanged(name, old, new)
    print("FOV changed from " .. old .. " to " .. new)
end

cvar.on_change("r_fov", "OnFovChanged")
```

## Lua API Reference

### executeLuaBuffer
```zig
pub fn executeLuaBuffer(
    allocator: std.mem.Allocator,
    state: *anyopaque,
    buf: []const u8,
    owner_entity: u32,
    user_ctx: ?*anyopaque
) !ExecuteResult

// Returns: ExecuteResult{ .success: bool, .message: []const u8 }
// Ownership: Caller MUST free message if non-empty
```

**Usage**:
```zig
const result = try lua.executeLuaBuffer(allocator, state, script, 0, null);
defer if (result.message.len > 0) allocator.free(result.message);

if (!result.success) {
    log(.ERROR, "lua", "Error: {s}", .{result.message});
}
```

### callNamedHandler
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

**Usage**:
```zig
const res = try lua.callNamedHandler(
    allocator,
    state,
    "OnVsyncChanged",
    "r_vsync",
    "true",
    "false"
);
defer if (res.message.len > 0) allocator.free(res.message);
```

## Log Levels & Colors

| Level | Color | Usage |
|-------|-------|-------|
| TRACE | Gray | Very verbose debug |
| DEBUG | Cyan | Diagnostic messages |
| INFO | White | Normal output |
| WARN | Yellow | Warnings |
| ERROR | Red | Errors and failures |

## History Management

**File**: `cache/console_history.txt`
**Capacity**: 32 commands (ring buffer)
**Format**: One command per line (UTF-8)

**Reverse-Search**:
```
(reverse-i-search)`set r_': set r_fov 90
```
- Type to filter
- Ctrl+R to cycle matches
- Enter to execute
- Escape to cancel

## Common Errors

| Error | Cause | Fix |
|-------|-------|-----|
| `attempt to call a nil value` | Function doesn't exist | Check spelling |
| `attempt to index a nil value` | Object is nil | Verify existence first |
| `bad argument #N` | Wrong type | Use tonumber/tostring |
| `<eof>` | Incomplete expression | Complete syntax |

## Tips & Tricks

1. **Bare expressions print**: `42 + 8` → console shows "50"
2. **Multi-line with Shift+Enter**: Build complex scripts line-by-line
3. **Use print() for debugging**: `print("value =", x)`
4. **Tab-completion**: Start typing and press Tab
5. **History persists**: Commands saved between sessions
6. **Errors don't crash**: Console remains functional after errors

## Memory Rules

- **ExecuteResult.message**: Caller frees with same allocator
- **ActionQueue payloads**: Use `action_queue.allocator`
- **Cross-thread messages**: Copy to ActionQueue allocator before push

## Integration Notes

**With CVARs**: All CVAR operations thread-safe (mutex-protected)
**With Logging**: Auto-forwarded to console (no code changes needed)
**With Entities**: Access via `entity_id` global (if script attached to entity)

---

Full documentation: `docs/CONSOLE_SYSTEM.md`

