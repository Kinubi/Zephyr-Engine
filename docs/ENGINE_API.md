# Zephyr Engine API Reference

**Version:** 1.0  
**Last Updated:** October 25, 2025

---

## Table of Contents

1. [Getting Started](#getting-started)
2. [Engine Core](#engine-core)
3. [Configuration](#configuration)
4. [Frame Loop](#frame-loop)
5. [Layer System](#layer-system)
6. [Event System](#event-system)
7. [Graphics Context](#graphics-context)
8. [Asset Management](#asset-management)
9. [ECS System](#ecs-system)
10. [Examples](#examples)

---

## Getting Started

### Installation

Add Zephyr Engine to your `build.zig.zon`:

```zig
.dependencies = .{
    .zephyr = .{
        .path = "../Zephyr-Engine/engine",
    },
},
```

### Basic Usage

```zig
const std = @import("std");
const zephyr = @import("zephyr");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Initialize engine
    const engine = try zephyr.Engine.init(allocator, .{
        .window = .{
            .width = 1280,
            .height = 720,
            .title = "My Game",
        },
    });
    defer engine.deinit();
    
    // Main loop
    while (engine.isRunning()) {
        const frame_info = try engine.beginFrame();
        try engine.update(frame_info);
        try engine.render(frame_info);
        try engine.endFrame(frame_info);
    }
}
```

---

## Engine Core

### `Engine`

The main engine instance that manages all core systems.

#### Methods

##### `init(allocator, config) !*Engine`

Initialize the engine with the given configuration.

**Parameters:**
- `allocator: std.mem.Allocator` - Memory allocator
- `config: Engine.Config` - Engine configuration

**Returns:** Pointer to initialized Engine instance

**Example:**
```zig
const engine = try zephyr.Engine.init(allocator, .{
    .window = .{
        .width = 1920,
        .height = 1080,
        .title = "My Application",
        .fullscreen = false,
        .vsync = false,
    },
    .renderer = .{
        .enable_ray_tracing = true,
        .max_frames_in_flight = 3,
    },
    .enable_validation = true,
    .enable_performance_monitoring = true,
});
```

##### `deinit()`

Clean up all engine resources. Call this before program exit.

**Example:**
```zig
defer engine.deinit();
```

##### `isRunning() bool`

Check if the engine should continue running (window is open).

**Returns:** `true` if window is still open, `false` if closed

##### `beginFrame() !*FrameInfo`

Begin a new frame. Calculates delta time, processes events, and prepares rendering.

**Returns:** Pointer to FrameInfo struct for this frame

**Errors:**
- `error.WindowClosed` - Window was closed

**Example:**
```zig
const frame_info = try engine.beginFrame();
```

##### `update(frame_info) !void`

Update game logic and all layers.

**Parameters:**
- `frame_info: *FrameInfo` - Current frame information

##### `render(frame_info) !void`

Render the frame through all layers.

**Parameters:**
- `frame_info: *FrameInfo` - Current frame information

##### `endFrame(frame_info) !void`

End the frame and present to screen.

**Parameters:**
- `frame_info: *FrameInfo` - Current frame information

#### Accessor Methods

##### `getLayerStack() *LayerStack`

Get the layer stack for adding custom layers.

**Example:**
```zig
const layer_stack = engine.getLayerStack();
try layer_stack.pushLayer(&my_custom_layer.base);
```

##### `getEventBus() *EventBus`

Get the event bus for queuing events.

**Example:**
```zig
const event_bus = engine.getEventBus();
event_bus.enqueue(.{ .type = .window_resize, .data = .{ .window_resize = .{ .width = 800, .height = 600 } } });
```

##### `getWindow() *Window`

Get the window instance.

##### `getGraphicsContext() *GraphicsContext`

Get the Vulkan graphics context.

##### `getSwapchain() *Swapchain`

Get the swapchain instance.

##### `getAssetManager() ?*AssetManager`

Get the asset manager if enabled (returns null if not initialized).

---

## Configuration

### `Engine.Config`

Main engine configuration struct.

```zig
pub const Config = struct {
    window: WindowConfig,
    renderer: RendererConfig = .{},
    enable_validation: bool = false,
    enable_performance_monitoring: bool = true,
};
```

### `WindowConfig`

Window configuration options.

```zig
pub const WindowConfig = struct {
    width: u32 = 1280,
    height: u32 = 720,
    title: [:0]const u8 = "Zephyr Engine",
    fullscreen: bool = false,
    vsync: bool = false,
};
```

**Fields:**
- `width` - Window width in pixels
- `height` - Window height in pixels
- `title` - Window title (null-terminated string)
- `fullscreen` - Enable fullscreen mode
- `vsync` - Enable vertical sync

### `RendererConfig`

Rendering configuration options.

```zig
pub const RendererConfig = struct {
    enable_ray_tracing: bool = true,
    max_frames_in_flight: u32 = 3,
};
```

**Fields:**
- `enable_ray_tracing` - Enable ray tracing features (requires hardware support)
- `max_frames_in_flight` - Number of frames that can be processed simultaneously

---

## Frame Loop

### `FrameInfo`

Contains information about the current frame.

```zig
pub const FrameInfo = struct {
    current_frame: u32,
    command_buffer: vk.CommandBuffer,
    compute_buffer: vk.CommandBuffer,
    camera: Camera,
    dt: f32,
    extent: vk.Extent2D,
    color_image: vk.Image,
    depth_image: vk.Image,
};
```

**Fields:**
- `current_frame` - Current frame index (0 to max_frames_in_flight-1)
- `command_buffer` - Primary graphics command buffer for this frame
- `compute_buffer` - Compute command buffer for this frame
- `camera` - Active camera for rendering
- `dt` - Delta time since last frame (in seconds)
- `extent` - Current window/swapchain extent
- `color_image` - Current swapchain color image
- `depth_image` - Current depth buffer image

### Frame Loop Pattern

```zig
while (engine.isRunning()) {
    // Begin frame - calculates dt, processes events, acquires swapchain image
    const frame_info = try engine.beginFrame();
    
    // Update - update game logic, ECS systems, animations
    try engine.update(frame_info);
    
    // Render - record draw commands, execute render graph
    try engine.render(frame_info);
    
    // End - submit commands, present image
    try engine.endFrame(frame_info);
}
```

---

## Layer System

Layers provide a way to organize game logic into modular components.

### `Layer`

Base layer struct. Create custom layers by embedding this and implementing the VTable.

```zig
pub const Layer = struct {
    name: [:0]const u8,
    enabled: bool,
    vtable: *const VTable,
    
    pub const VTable = struct {
        attach: *const fn(*Layer) anyerror!void,
        detach: *const fn(*Layer) void,
        begin: *const fn(*Layer, *const FrameInfo) anyerror!void,
        update: *const fn(*Layer, *const FrameInfo) anyerror!void,
        render: *const fn(*Layer, *const FrameInfo) anyerror!void,
        end: *const fn(*Layer, *const FrameInfo) anyerror!void,
        event: *const fn(*Layer, Event) void,
    };
};
```

### Creating a Custom Layer

```zig
const MyLayer = struct {
    base: zephyr.Layer,
    // Your custom fields
    
    pub fn init() MyLayer {
        return .{
            .base = .{
                .name = "MyLayer",
                .enabled = true,
                .vtable = &vtable,
            },
        };
    }
    
    const vtable = zephyr.Layer.VTable{
        .attach = attach,
        .detach = detach,
        .begin = begin,
        .update = update,
        .render = render,
        .end = end,
        .event = event,
    };
    
    fn update(base: *zephyr.Layer, frame_info: *const zephyr.FrameInfo) !void {
        const self: *MyLayer = @fieldParentPtr("base", base);
        // Your update logic here
    }
    
    // Implement other vtable functions...
};
```

### `LayerStack`

Manages a collection of layers.

#### Methods

##### `pushLayer(layer: *Layer) !void`

Add a layer to the stack.

##### `popLayer(layer: *Layer) void`

Remove a layer from the stack.

##### `count() usize`

Get the number of layers in the stack.

---

## Event System

### `Event`

Events represent input and system events.

```zig
pub const Event = struct {
    type: EventType,
    category: EventCategory,
    handled: bool = false,
};
```

### `EventType`

Available event types:
- `window_close`
- `window_resize`
- `key_pressed`
- `key_released`
- `mouse_button_pressed`
- `mouse_button_released`
- `mouse_moved`
- `mouse_scrolled`

### `EventBus`

Manages event queuing and distribution.

#### Methods

##### `enqueue(event: Event) void`

Add an event to the queue.

##### `processEvents(layer_stack: *LayerStack) void`

Process all queued events and dispatch to layers.

---

## Graphics Context

### `GraphicsContext`

Manages Vulkan device and resources.

#### Key Methods

##### `createCommandPool() !void`

Create the command pool for command buffer allocation.

##### `createCommandBuffers(allocator) ![]vk.CommandBuffer`

Allocate command buffers.

##### `deviceName() []const u8`

Get the name of the GPU device.

---

## Asset Management

### `AssetManager`

Handles loading and management of game assets.

**Note:** Asset manager is optional and must be initialized separately if needed.

---

## ECS System

The engine includes a full Entity Component System.

### Importing ECS

```zig
const ecs = @import("zephyr").ecs;
```

### Creating a World

```zig
var world = try ecs.World.init(allocator);
defer world.deinit();
```

### Creating Entities

```zig
const entity = try world.createEntity();
try world.addComponent(entity, Transform{ .position = .{ 0, 0, 0 } });
```

For more details, see [ECS_SYSTEM.md](ECS_SYSTEM.md) and [ECS_QUICK_REFERENCE.md](ECS_QUICK_REFERENCE.md).

---

## Constants

### `MAX_FRAMES_IN_FLIGHT: u32`

Default maximum number of frames in flight (value: 3).

```zig
const max_frames = zephyr.MAX_FRAMES_IN_FLIGHT;
```

---

## Examples

### Minimal Example

```zig
const std = @import("std");
const zephyr = @import("zephyr");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    
    const engine = try zephyr.Engine.init(gpa.allocator(), .{
        .window = .{ .title = "Minimal Example" },
    });
    defer engine.deinit();
    
    while (engine.isRunning()) {
        const frame_info = try engine.beginFrame();
        try engine.update(frame_info);
        try engine.render(frame_info);
        try engine.endFrame(frame_info);
    }
}
```

### Custom Layer Example

```zig
const GameLayer = struct {
    base: zephyr.Layer,
    player_pos: [3]f32 = .{ 0, 0, 0 },
    
    pub fn init() GameLayer {
        return .{
            .base = .{
                .name = "GameLayer",
                .enabled = true,
                .vtable = &vtable,
            },
        };
    }
    
    const vtable = zephyr.Layer.VTable{
        .attach = attach,
        .detach = detach,
        .begin = begin,
        .update = update,
        .render = render,
        .end = end,
        .event = event,
    };
    
    fn attach(base: *zephyr.Layer) !void {
        const self: *GameLayer = @fieldParentPtr("base", base);
        std.debug.print("GameLayer attached!\n", .{});
    }
    
    fn update(base: *zephyr.Layer, frame_info: *const zephyr.FrameInfo) !void {
        const self: *GameLayer = @fieldParentPtr("base", base);
        // Move player based on input
        self.player_pos[0] += frame_info.dt * 2.0;
    }
    
    fn render(base: *zephyr.Layer, frame_info: *const zephyr.FrameInfo) !void {
        const self: *GameLayer = @fieldParentPtr("base", base);
        // Render player...
    }
    
    // Stub implementations for other functions
    fn detach(base: *zephyr.Layer) void { _ = base; }
    fn begin(base: *zephyr.Layer, frame_info: *const zephyr.FrameInfo) !void { _ = base; _ = frame_info; }
    fn end(base: *zephyr.Layer, frame_info: *const zephyr.FrameInfo) !void { _ = base; _ = frame_info; }
    fn event(base: *zephyr.Layer, evt: zephyr.Event) void { _ = base; _ = evt; }
};
```

---

## Best Practices

1. **Always use defer for cleanup:**
   ```zig
   const engine = try zephyr.Engine.init(allocator, config);
   defer engine.deinit();
   ```

2. **Check isRunning() in main loop:**
   ```zig
   while (engine.isRunning()) {
       // Frame loop
   }
   ```

3. **Use delta time for movement:**
   ```zig
   position += velocity * frame_info.dt;
   ```

4. **Add layers in order of dependency:**
   - Performance layer first (timing)
   - Render layer second (rendering)
   - Game layers after

5. **Handle errors appropriately:**
   ```zig
   const frame_info = try engine.beginFrame();
   ```

---

## See Also

- [ECS_SYSTEM.md](ECS_SYSTEM.md) - Entity Component System reference
- [LAYER_SYSTEM_QUICK_REF.md](LAYER_SYSTEM_QUICK_REF.md) - Layer system guide
- [ENGINE_EDITOR_SEPARATION.md](ENGINE_EDITOR_SEPARATION.md) - Architecture overview
- [examples/](../examples/) - Example programs

---

**For issues or contributions, see the main repository.**
