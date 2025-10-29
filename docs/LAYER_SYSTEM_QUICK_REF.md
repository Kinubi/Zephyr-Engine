# Layer System Quick Reference

**Version:** 1.0  
**Date:** October 25, 2025  
**Status:** Production Ready  

---

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Quick Start](#quick-start)
4. [Creating Custom Layers](#creating-custom-layers)
5. [Event System](#event-system)
6. [Performance Profiling](#performance-profiling)
7. [Runtime Controls](#runtime-controls)
8. [Best Practices](#best-practices)
9. [Troubleshooting](#troubleshooting)

---

## Overview

The Layer System provides a modular architecture for organizing application logic in Zephyr-Engine. Each layer represents a distinct concern (input, scene, rendering, UI) and executes in a well-defined order.

### Key Benefits

- ✅ **Organized Execution** - Clear phases: begin → update → render → end
- ✅ **Event-Driven** - Decoupled communication via EventBus
- ✅ **Runtime Control** - Enable/disable layers with F-keys
- ✅ **Performance Tracking** - Per-layer CPU time profiling
- ✅ **Easy to Extend** - Add new layers without modifying core code

### Current Layers (Execution Order)

1. **PerformanceLayer** - Frame timing and GPU query management
2. **RenderLayer** - Swapchain lifecycle (begin/end frame)
3. **InputLayer** - Keyboard/mouse input and camera control
4. **SceneLayer** - ECS updates, scene logic, UBO management
5. **UILayer** - ImGui rendering (overlay, always on top)

---

## Architecture

### Layer Interface

```zig
pub const Layer = struct {
    name: []const u8,
    enabled: bool = true,
    vtable: *const VTable,
    timing: LayerTiming = .{},  // Performance tracking

    pub const VTable = struct {
        attach: *const fn (layer: *Layer) anyerror!void,
        detach: *const fn (layer: *Layer) void,
        begin: *const fn (layer: *Layer, frame_info: *const FrameInfo) anyerror!void,
        update: *const fn (layer: *Layer, frame_info: *const FrameInfo) anyerror!void,
        render: *const fn (layer: *Layer, frame_info: *const FrameInfo) anyerror!void,
        end: *const fn (layer: *Layer, frame_info: *FrameInfo) anyerror!void,
        event: *const fn (layer: *Layer, event: *Event) void,
    };
};
```

### Execution Flow

Each frame follows this pattern:

```
1. Begin Phase    → PerformanceLayer, RenderLayer, InputLayer, SceneLayer, UILayer
2. Process Events → EventBus dispatches to layers (reverse order)
3. Update Phase   → All layers update logic
4. Render Phase   → All layers render
5. End Phase      → All layers cleanup
```

### Performance Tracking

Every layer automatically tracks CPU time spent in each phase:

```zig
pub const LayerTiming = struct {
    begin_time_ns: u64,   // Time spent in begin()
    update_time_ns: u64,  // Time spent in update()
    render_time_ns: u64,  // Time spent in render()
    end_time_ns: u64,     // Time spent in end()
    event_time_ns: u64,   // Time spent in event()
    
    pub fn getTotalMs(self: LayerTiming) f32 {
        // Returns total time in milliseconds
    }
};
```

---

## Quick Start

### Using Existing Layers

Layers are automatically initialized in `app.zig`:

```zig
// Layers are already set up and running
// Just use the runtime controls:

// F1 - Toggle UI visibility
// F2 - Toggle performance graphs
// T  - Toggle path tracing
```

### Adding a Layer to the Stack

```zig
// In app.zig init():
var my_layer = MyCustomLayer.init(/* dependencies */);
try layer_stack.pushLayer(&my_layer.base);  // Regular layer
// or
try layer_stack.pushOverlay(&my_layer.base);  // Overlay (rendered on top)
```

---

## Creating Custom Layers

### Step 1: Define Your Layer Struct

```zig
const std = @import("std");
const Layer = @import("../core/layer.zig").Layer;
const Event = @import("../core/event.zig").Event;
const FrameInfo = @import("../rendering/frameinfo.zig").FrameInfo;

pub const MyCustomLayer = struct {
    base: Layer,  // REQUIRED: Must be first field
    
    // Your custom fields
    my_data: i32 = 0,
    enabled_feature: bool = true,

    pub fn init() MyCustomLayer {
        return .{
            .base = .{
                .name = "MyCustomLayer",
                .enabled = true,
                .vtable = &vtable,
            },
        };
    }

    const vtable = Layer.VTable{
        .attach = attach,
        .detach = detach,
        .begin = begin,
        .update = update,
        .render = render,
        .end = end,
        .event = event,
    };
};
```

### Step 2: Implement Required Methods

```zig
fn attach(base: *Layer) !void {
    const self: *MyCustomLayer = @fieldParentPtr("base", base);
    // Called once when layer is added to stack
    // Initialize resources here
}

fn detach(base: *Layer) void {
    const self: *MyCustomLayer = @fieldParentPtr("base", base);
    // Called once when layer is removed from stack
    // Cleanup resources here
}

fn begin(base: *Layer, frame_info: *const FrameInfo) !void {
    const self: *MyCustomLayer = @fieldParentPtr("base", base);
    // Called at the start of each frame
    // Setup frame state
}

fn update(base: *Layer, frame_info: *const FrameInfo) !void {
    const self: *MyCustomLayer = @fieldParentPtr("base", base);
    // Called every frame for logic updates
    // Use frame_info.dt for delta time
    
    self.my_data += 1;
}

fn render(base: *Layer, frame_info: *const FrameInfo) !void {
    const self: *MyCustomLayer = @fieldParentPtr("base", base);
    // Called every frame for rendering
    // Use frame_info.command_buffer for Vulkan commands
}

fn end(base: *Layer, frame_info: *FrameInfo) !void {
    const self: *MyCustomLayer = @fieldParentPtr("base", base);
    // Called at the end of each frame
    // Cleanup frame-specific state
}

fn event(base: *Layer, evt: *Event) void {
    const self: *MyCustomLayer = @fieldParentPtr("base", base);
    // Called when events are dispatched
    
    switch (evt.event_type) {
        .KeyPressed => {
            const key = evt.data.KeyPressed.key;
            if (key == 70) { // 'F' key
                self.enabled_feature = !self.enabled_feature;
                evt.markHandled();  // Prevent other layers from seeing this event
            }
        },
        else => {},
    }
}
```

### Step 3: Use FrameInfo

The `FrameInfo` struct provides everything you need for rendering:

```zig
pub const FrameInfo = struct {
    dt: f32,                        // Delta time (seconds)
    current_frame: u32,             // Current frame index (0-2)
    command_buffer: vk.CommandBuffer,
    compute_buffer: vk.CommandBuffer,
    color_image: vk.Image,
    color_image_view: vk.ImageView,
    depth_image_view: vk.ImageView,
    extent: vk.Extent2D,
};
```

---

## Event System

### Available Event Types

```zig
pub const EventType = enum {
    // Window events
    WindowResize,
    WindowClose,
    
    // Input events
    KeyPressed,
    KeyReleased,
    MouseButtonPressed,
    MouseButtonReleased,
    MouseMoved,
    MouseScrolled,
    
    // Application events
    PathTracingToggled,
    WireframeToggled,
    CameraUpdated,
    SceneLoaded,
};
```

### Handling Events

Events propagate in **reverse order** (top layers first). Mark events as handled to stop propagation:

```zig
fn event(base: *Layer, evt: *Event) void {
    const self: *MyLayer = @fieldParentPtr("base", base);
    
    switch (evt.event_type) {
        .KeyPressed => {
            const key_data = evt.data.KeyPressed;
            
            if (key_data.key == GLFW_KEY_SPACE) {
                // Handle spacebar
                std.log.info("Space pressed!", .{});
                evt.markHandled();  // Other layers won't see this event
            }
        },
        .MouseMoved => {
            const mouse_data = evt.data.MouseMoved;
            // Handle mouse movement at (x, y)
        },
        .WindowResize => {
            const width = evt.data.WindowResize.width;
            const height = evt.data.WindowResize.height;
            // Handle window resize
        },
        else => {},
    }
}
```

### Generating Custom Events

```zig
// In your layer or system:
const event = Event.init(.SceneLoaded, .{ .SceneLoaded = {} });
try event_bus.queueEvent(event);

// Events will be processed next frame
```

### Event Categories

Events are organized into categories that can be toggled:

```zig
pub const EventCategory = enum {
    Window,      // WindowResize, WindowClose
    Input,       // Key/Mouse events
    Application, // Custom app events
};

// Disable a category (in app.zig or layer):
event_bus.setCategory(.Input, false);  // Disable all input events
```

---

## Performance Profiling

### Per-Layer Timing

Every layer tracks its performance automatically:

```zig
// In any layer's update/render:
const total_ms = self.base.timing.getTotalMs();
std.log.info("{s} took {d:.2}ms this frame", .{self.base.name, total_ms});

// Access individual phases:
const update_ms = @as(f32, @floatFromInt(self.base.timing.update_time_ns)) / 1_000_000.0;
const render_ms = @as(f32, @floatFromInt(self.base.timing.render_time_ns)) / 1_000_000.0;
```

### Displaying in UI

Layer timing can be displayed in ImGui (future enhancement):

```zig
// In UIRenderer.renderStatsWindow():
c.ImGui_Text("Layer Performance:");
for (layer_stack.layers.items) |layer| {
    const time_ms = layer.timing.getTotalMs();
    c.ImGui_Text("  %s: %.2f ms", layer.name.ptr, time_ms);
}
```

---

## Runtime Controls

### Built-in Keyboard Shortcuts

| Key | Action | Handled By |
|-----|--------|------------|
| **F1** | Toggle entire UI | UILayer |
| **F2** | Toggle performance graphs | UILayer |
| **T** | Toggle path tracing | InputLayer |
| **ESC** | (Reserved) | - |

### Adding Custom Shortcuts

In your layer's event handler:

```zig
fn event(base: *Layer, evt: *Event) void {
    const self: *MyLayer = @fieldParentPtr("base", base);
    
    if (evt.event_type == .KeyPressed) {
        const GLFW_KEY_F3 = 292;
        if (evt.data.KeyPressed.key == GLFW_KEY_F3) {
            self.feature_enabled = !self.feature_enabled;
            std.log.info("Feature toggled: {}", .{self.feature_enabled});
            evt.markHandled();
        }
    }
}
```

### Toggling Layers Programmatically

```zig
// In app.zig or another layer:
my_layer.base.enabled = false;  // Disable layer
my_layer.base.enabled = true;   // Enable layer

// Disabled layers skip all phases (begin/update/render/end/event)
```

---

## Best Practices

### 1. Layer Ordering Matters

Place layers in order of dependency:
- **PerformanceLayer** first (tracks everything)
- **RenderLayer** second (manages swapchain)
- **Logic layers** in the middle (Input, Scene)
- **UILayer** last (overlays on top)

### 2. Use Events for Decoupling

❌ **Bad** - Direct dependencies:
```zig
// InputLayer directly calling SceneLayer
scene_layer.togglePathTracing();
```

✅ **Good** - Event-driven:
```zig
// InputLayer queues event
const event = Event.init(.PathTracingToggled, .{ .PathTracingToggled = .{ .enabled = true } });
try event_bus.queueEvent(event);

// SceneLayer handles event
fn event(base: *Layer, evt: *Event) void {
    if (evt.event_type == .PathTracingToggled) {
        // Toggle path tracing
    }
}
```

### 3. Keep Layers Focused

Each layer should have a single responsibility:
- **InputLayer** - Input only, no rendering
- **SceneLayer** - Scene logic only, no input handling
- **UILayer** - UI only, no game logic

### 4. Use FrameInfo for Frame Context

Always use `frame_info.dt` for time-based calculations:

```zig
fn update(base: *Layer, frame_info: *const FrameInfo) !void {
    const self: *MyLayer = @fieldParentPtr("base", base);
    
    // ✅ Framerate-independent
    self.position += self.velocity * frame_info.dt;
}
```

### 5. Mark Events as Handled

Prevent event propagation when appropriate:

```zig
if (evt.event_type == .KeyPressed and evt.data.KeyPressed.key == MY_KEY) {
    // Handle the key
    evt.markHandled();  // Other layers won't see this
}
```

---

## Troubleshooting

### Layer Not Updating

**Problem:** Layer's update() isn't being called.

**Solutions:**
1. Check `layer.enabled` is true
2. Verify layer was added to stack: `layer_stack.pushLayer(&my_layer.base)`
3. Check for errors in begin() that might prevent update()

### Events Not Received

**Problem:** Layer's event() isn't seeing events.

**Solutions:**
1. Check event category is enabled: `event_bus.isCategoryEnabled(.Input)`
2. Verify layer is in stack and enabled
3. Check if another layer marked event as handled
4. Ensure GLFW callbacks are registered: `window.setEventBus(&event_bus)`

### Performance Issues

**Problem:** Frame rate drops after adding layer.

**Solutions:**
1. Check layer timing: `layer.timing.getTotalMs()`
2. Optimize expensive operations in update/render
3. Move heavy work to begin() or end() if frame-sync not needed
4. Consider making layer toggleable with F-key

### Incorrect Execution Order

**Problem:** Layer runs before dependencies are ready.

**Solutions:**
1. Reorder layers in `app.zig` initialization
2. Use events to notify when dependencies are ready
3. Check for null pointers in layer's update/render

---

## Example: Debug Overlay Layer

Complete example of a custom debug overlay layer:

```zig
pub const DebugOverlayLayer = struct {
    base: Layer,
    show_fps: bool = true,
    show_entity_count: bool = true,
    
    pub fn init() DebugOverlayLayer {
        return .{
            .base = .{
                .name = "DebugOverlay",
                .enabled = true,
                .vtable = &vtable,
            },
        };
    }
    
    const vtable = Layer.VTable{
        .attach = attach,
        .detach = detach,
        .begin = begin,
        .update = update,
        .render = render,
        .end = end,
        .event = event,
    };
    
    fn attach(base: *Layer) !void {
        std.log.info("Debug overlay attached", .{});
    }
    
    fn detach(base: *Layer) void {
        std.log.info("Debug overlay detached", .{});
    }
    
    fn begin(base: *Layer, frame_info: *const FrameInfo) !void {
        _ = base;
        _ = frame_info;
    }
    
    fn update(base: *Layer, frame_info: *const FrameInfo) !void {
        _ = base;
        _ = frame_info;
    }
    
    fn render(base: *Layer, frame_info: *const FrameInfo) !void {
        const self: *DebugOverlayLayer = @fieldParentPtr("base", base);
        
        if (self.show_fps) {
            const fps = 1.0 / frame_info.dt;
            // Render FPS counter (using ImGui or custom rendering)
            _ = fps;
        }
    }
    
    fn end(base: *Layer, frame_info: *FrameInfo) !void {
        _ = base;
        _ = frame_info;
    }
    
    fn event(base: *Layer, evt: *Event) void {
        const self: *DebugOverlayLayer = @fieldParentPtr("base", base);
        
        if (evt.event_type == .KeyPressed) {
            const GLFW_KEY_F3 = 292;
            if (evt.data.KeyPressed.key == GLFW_KEY_F3) {
                self.base.enabled = !self.base.enabled;
                evt.markHandled();
            }
        }
    }
};
```

---

## Next Steps

- See `LAYER_EVENT_SYSTEM.md` for detailed architecture design
- Check existing layers in `src/layers/` for more examples
- Experiment with F-key toggles to understand layer behavior
- Create custom layers for your specific features

**Happy layering! 🎯**
