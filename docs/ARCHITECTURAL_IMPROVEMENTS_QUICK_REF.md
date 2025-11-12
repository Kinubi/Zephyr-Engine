# Architectural Improvements Quick Reference

Quick reference for the new architectural improvements in Zephyr Engine.

## Error Handling

### Import
```zig
const zephyr = @import("zephyr");
```

### Set Error Handler
```zig
zephyr.setErrorHandler(myHandler);

fn myHandler(ctx: zephyr.ErrorContext) void {
    std.log.err("{s} at {s}:{d}", .{ctx.message, ctx.file, ctx.line});
}
```

### Error Types
```zig
// All engine errors
zephyr.EngineError.InitializationFailed
zephyr.EngineError.ResourceNotFound
zephyr.EngineError.OutOfMemory
// ... and more
```

### Recovery Strategies
```zig
var recovery = zephyr.errors.Recovery.init(.retry);
while (recovery.shouldRetry()) {
    doOperation() catch continue;
    break;
}
```

---

## Resource Management

### Create Manager
```zig
var manager = zephyr.ResourceManager(MyType).init(allocator);
defer manager.deinit();
```

### Create Resource
```zig
const resource = MyType{ /* ... */ };
const handle = try manager.create("resource_name", resource);
```

### Get Resource
```zig
if (manager.get(handle)) |resource| {
    // Use resource
}
```

### Reference Counting
```zig
try manager.addRef(handle);  // Increment
manager.removeRef(handle);    // Decrement (auto-cleanup at 0)
```

### Destroy Resource
```zig
manager.destroy(handle);  // Manual cleanup
```

### Get Statistics
```zig
const stats = manager.getStats();
std.log.info("Active: {d}, Total Refs: {d}", .{
    stats.active,
    stats.total_refs,
});
```

---

## Configuration Management

### Create Manager
```zig
var config = zephyr.ConfigManager.init(allocator);
defer config.deinit();
```

### Register Config
```zig
try config.register(
    "graphics.vsync",
    .{ .bool = true },
    "Enable vertical sync",
    "graphics",
    .{},
);
```

### Register with Validation
```zig
try config.register(
    "graphics.scale",
    .{ .float = 1.0 },
    "Resolution scale",
    "graphics",
    .{ .validator = myValidator },
);

fn myValidator(value: zephyr.ConfigValue) !void {
    if (value.float < 0.5 or value.float > 2.0) {
        return error.OutOfRange;
    }
}
```

### Get Values
```zig
const vsync = config.getBool("graphics.vsync", true);
const scale = config.getFloat("graphics.scale", 1.0);
const max_fps = config.getInt("graphics.max_fps", 60);
const version = config.getString("engine.version", "1.0.0");
```

### Set Values
```zig
try config.set("graphics.vsync", .{ .bool = false });
```

### Read-Only Config
```zig
try config.register(
    "engine.version",
    .{ .string = "1.0.0" },
    "Engine version",
    "system",
    .{ .read_only = true },
);

// This will fail:
config.set("engine.version", .{ .string = "2.0.0" }) catch |err| {
    // err == ValidationError.ReadOnly
};
```

### Requires Restart
```zig
try config.register(
    "graphics.backend",
    .{ .string = "vulkan" },
    "Graphics backend",
    "graphics",
    .{ .requires_restart = true },
);

// Setting this will log a warning
try config.set("graphics.backend", .{ .string = "opengl" });
// WARNING: Config 'graphics.backend' requires restart to take effect
```

### File Operations
```zig
// Save to file
try config.saveToFile("config.ini");

// Load from file
try config.loadFromFile("config.ini");

// Check if dirty
if (config.isDirty()) {
    try config.saveToFile("config.ini");
}
```

### Reset Config
```zig
// Reset single config
try config.reset("graphics.vsync");

// Reset all configs
config.resetAll();
```

### Get by Category
```zig
const graphics_configs = try config.getCategory("graphics", allocator);
defer allocator.free(graphics_configs);

for (graphics_configs) |name| {
    std.log.info("Config: {s}", .{name});
}
```

---

## Common Patterns

### Integrated Example
```zig
const System = struct {
    config: *zephyr.ConfigManager,
    resources: *zephyr.ResourceManager(Texture),
    
    pub fn init(allocator: std.mem.Allocator) !System {
        var config = try allocator.create(zephyr.ConfigManager);
        config.* = zephyr.ConfigManager.init(allocator);
        
        var resources = try allocator.create(zephyr.ResourceManager(Texture));
        resources.* = zephyr.ResourceManager(Texture).init(allocator);
        
        try config.register("texture.max_size", .{ .int = 4096 }, ...);
        
        return .{
            .config = config,
            .resources = resources,
        };
    }
    
    pub fn loadTexture(self: *System, name: []const u8) !Handle {
        const max_size = self.config.getInt("texture.max_size", 4096);
        const texture = try createTexture(max_size);
        return self.resources.create(name, texture);
    }
};
```

### Error Handling with Recovery
```zig
var recovery = zephyr.errors.Recovery.init(.retry);
recovery.max_retries = 5;

while (true) {
    loadAsset() catch |err| {
        if (recovery.shouldRetry()) {
            std.time.sleep(100 * std.time.ns_per_ms);
            continue;
        }
        return err;
    };
    break;
}
```

### Resource with Auto-Cleanup
```zig
const handle = try manager.create("temp", resource);
defer manager.destroy(handle);  // Cleanup on scope exit

// Use resource
if (manager.get(handle)) |res| {
    // Work with res
}
```

---

## Configuration File Format

```ini
# Zephyr Engine Configuration
# Auto-generated - edit with caution

# Enable vertical synchronization
# Category: graphics
graphics.vsync=true

# Resolution scale factor (0.5 - 2.0)
# Category: graphics
graphics.resolution_scale=1.00

# Maximum frames per second
# Category: graphics
graphics.max_fps=144

# Engine version
# Category: system
# [READ ONLY]
engine.version="1.0.0"
```

---

## Type Reference

### ConfigValue Types
```zig
.bool => true/false
.int => -9223372036854775808 to 9223372036854775807
.float => 64-bit floating point
.string => UTF-8 string
```

### Handle Structure
```zig
pub fn Handle(comptime T: type) type {
    return struct {
        index: u32,      // Slot index
        generation: u32, // Version (prevents use-after-free)
    };
}
```

### Resource States
```zig
pub const ResourceState = enum {
    uninitialized,
    loading,
    ready,
    error_state,
    disposed,
};
```

---

## See Also

- [Full Documentation](ARCHITECTURAL_IMPROVEMENTS.md)
- [Example Program](../examples/architectural_improvements_demo.zig)
- [Engine API](zephyr.zig)
