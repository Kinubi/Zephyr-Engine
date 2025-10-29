# Layer and Event System Design

**Version:** 1.0  
**Date:** October 24, 2025  
**Status:** Design Proposal  
**Author:** Zephyr-Engine Team

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Problem Statement](#problem-statement)
3. [Current Architecture Issues](#current-architecture-issues)
4. [Proposed Architecture](#proposed-architecture)
5. [Layer System](#layer-system)
6. [Event System](#event-system)
7. [Integration with Existing Systems](#integration-with-existing-systems)
8. [Implementation Plan](#implementation-plan)
9. [Examples](#examples)
10. [Performance Considerations](#performance-considerations)

---

## Executive Summary

The current `app.zig` update loop is monolithic and disorganized, making it difficult to:
- Add new features without modifying core app logic
- Control execution order of subsystems
- Share data between subsystems cleanly
- Enable/disable features at runtime

**Solution:** Implement a **Layer System** for organizing update/render logic and an **Event System** for decoupled communication between layers.

### Key Benefits
- 🎯 **Organized execution** - Clear order of operations
- 🔌 **Decoupled systems** - Layers don't depend on each other
- 🎛️ **Runtime control** - Enable/disable layers dynamically
- 📡 **Event-driven** - Systems communicate via events, not direct calls
- 🧪 **Testable** - Each layer can be tested independently

---

## Problem Statement

### Current `app.zig` Update Loop Issues

```zig
pub fn update(self: *App) !bool {
    // 300+ lines of tangled logic:
    // - Input handling mixed with rendering
    // - Scene updates interleaved with UI
    // - Performance monitoring scattered throughout
    // - No clear boundaries between systems
    // - Difficult to add features without breaking existing code
    // - Hard to test individual subsystems
}
```

**Problems:**
1. ❌ **Monolithic** - Everything in one giant function
2. ❌ **Tight coupling** - Systems directly call each other
3. ❌ **Hard to extend** - Adding features requires modifying core app
4. ❌ **Unclear ordering** - When does each system run?
5. ❌ **No runtime control** - Can't disable systems without code changes
6. ❌ **Poor separation** - UI, input, rendering, and logic mixed together

---

## Current Architecture Issues

### Example of Current Spaghetti Code

```zig
// Input handling
const t_key_state = c.glfwGetKey(window, GLFW_KEY_T);
if (t_key_state == c.GLFW_PRESS) {
    // Toggle path tracing...
}

// Performance monitoring
if (performance_monitor) |pm| {
    try pm.beginFrame(current_frame);
}

// Scene update
try scene_v2.update(frame_info, &ubo);

// More performance monitoring
if (performance_monitor) |pm| {
    try pm.endPass("scene_update", current_frame, null);
}

// Asset management
asset_manager.beginFrame();

// Rendering
try swapchain.beginFrame(frame_info);

// More scene stuff
try scene_v2.render(frame_info);

// UI rendering
if (show_ui) {
    try ui_renderer.render(&stats);
}

// More performance monitoring...
```

**Issues:**
- Input, rendering, and logic are interleaved
- Performance monitoring code duplicated everywhere
- No clear execution order
- Hard to see what runs when
- Difficult to add new systems

---

## Proposed Architecture

### High-Level Overview

```
Application
    ├── LayerStack (ordered list of layers)
    │   ├── PerformanceLayer (first - monitors all)
    │   ├── InputLayer (early - captures input)
    │   ├── SceneLayer (mid - updates scene)
    │   ├── RenderLayer (mid - renders scene)
    │   ├── UILayer (late - renders UI on top)
    │   └── DebugLayer (last - debug overlays)
    │
    └── EventBus (global event dispatcher)
        ├── Event Queue
        └── Event Handlers (registered by layers)
```

### Execution Flow

```
Frame N:
  1. App.update() called
  2. Build FrameInfo (includes dt, camera, frame index, etc.)
  3. Poll OS events → dispatch to EventBus
  4. LayerStack.update(frame_info) - iterate layers:
     → PerformanceLayer.update(frame_info)
     → InputLayer.update(frame_info)  
     → SceneLayer.update(frame_info)
     → RenderLayer.update(frame_info)
     → UILayer.update(frame_info)
     → DebugLayer.update(frame_info)
  5. Process EventBus queue
  6. LayerStack.render(frame_info)
  7. Present frame
```

---

## Layer System

### Layer Interface

```zig
pub const Layer = struct {
    name: []const u8,
    enabled: bool = true,
    
    // Virtual function table
    vtable: *const LayerVTable,
    
    pub const LayerVTable = struct {
        /// Called when layer is attached to the stack
        attach: *const fn (layer: *Layer) anyerror!void,
        
        /// Called when layer is detached from the stack
        detach: *const fn (layer: *Layer) void,
        
        /// Called every frame for updates (logic, input, etc.)
        /// Receives full frame context including dt
        update: *const fn (layer: *Layer, frame_info: *const FrameInfo) anyerror!void,
        
        /// Called every frame for rendering
        render: *const fn (layer: *Layer, frame_info: *const FrameInfo) anyerror!void,
        
        /// Called when an event is dispatched
        event: *const fn (layer: *Layer, event: *Event) void,
    };
    
    pub fn attach(self: *Layer) !void {
        return self.vtable.attach(self);
    }
    
    pub fn detach(self: *Layer) void {
        return self.vtable.detach(self);
    }
    
    pub fn update(self: *Layer, frame_info: *const FrameInfo) !void {
        if (!self.enabled) return;
        return self.vtable.update(self, frame_info);
    }
    
    pub fn render(self: *Layer, frame_info: *const FrameInfo) !void {
        if (!self.enabled) return;
        return self.vtable.render(self, frame_info);
    }
    
    pub fn event(self: *Layer, event: *Event) void {
        if (!self.enabled) return;
        return self.vtable.event(self, event);
    }
};
```

### LayerStack

```zig
pub const LayerStack = struct {
    layers: std.ArrayList(*Layer),
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) LayerStack {
        return .{
            .layers = std.ArrayList(*Layer){},
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *LayerStack) void {
        // Detach all layers in reverse order
        var i = self.layers.items.len;
        while (i > 0) {
            i -= 1;
            self.layers.items[i].detach();
        }
        self.layers.deinit(self.allocator);
    }
    
    /// Push a layer onto the stack
    pub fn pushLayer(self: *LayerStack, layer: *Layer) !void {
        try self.layers.append(self.allocator, layer);
        try layer.attach();
    }
    
    /// Push an overlay (always on top)
    pub fn pushOverlay(self: *LayerStack, overlay: *Layer) !void {
        try self.layers.append(self.allocator, overlay);
        try overlay.attach();
    }
    
    /// Remove a layer
    pub fn popLayer(self: *LayerStack, layer: *Layer) void {
        if (std.mem.indexOfScalar(*Layer, self.layers.items, layer)) |index| {
            layer.detach();
            _ = self.layers.orderedRemove(index);
        }
    }
    
    /// Update all layers with current frame info
    pub fn update(self: *LayerStack, frame_info: *const FrameInfo) !void {
        for (self.layers.items) |layer| {
            try layer.update(frame_info);
        }
    }
    
    /// Render all layers
    pub fn render(self: *LayerStack, frame_info: *const FrameInfo) !void {
        for (self.layers.items) |layer| {
            try layer.render(frame_info);
        }
    }
    
    /// Dispatch event to all layers (reverse order for input handling)
    pub fn event(self: *LayerStack, event: *Event) void {
        // Process in reverse order (top layers first)
        // Top layers can "consume" events to prevent propagation
        var i = self.layers.items.len;
        while (i > 0) {
            i -= 1;
            self.layers.items[i].event(event);
            if (event.handled) break;
        }
    }
};
```

---

## Event System

### Event Types

```zig
pub const EventType = enum {
    // Window events
    WindowResize,
    WindowClose,
    WindowFocus,
    WindowLostFocus,
    WindowMoved,
    
    // Input events
    KeyPressed,
    KeyReleased,
    KeyTyped,
    MouseButtonPressed,
    MouseButtonReleased,
    MouseMoved,
    MouseScrolled,
    
    // Application events
    AppUpdate,
    AppRender,
    AppTick,
    
    // Custom events
    SceneChanged,
    AssetLoaded,
    PathTracingToggled,
    CameraChanged,
};

pub const EventCategory = enum(u8) {
    None = 0,
    Application = 1 << 0,
    Input = 1 << 1,
    Keyboard = 1 << 2,
    Mouse = 1 << 3,
    MouseButton = 1 << 4,
};

pub const Event = struct {
    event_type: EventType,
    handled: bool = false,
    
    // Type-erased data
    data: EventData,
    
    pub const EventData = union(EventType) {
        WindowResize: struct { width: u32, height: u32 },
        WindowClose: void,
        WindowFocus: void,
        WindowLostFocus: void,
        WindowMoved: struct { x: i32, y: i32 },
        
        KeyPressed: struct { key: i32, repeat_count: u32 },
        KeyReleased: struct { key: i32 },
        KeyTyped: struct { key: i32 },
        
        MouseButtonPressed: struct { button: i32 },
        MouseButtonReleased: struct { button: i32 },
        MouseMoved: struct { x: f32, y: f32 },
        MouseScrolled: struct { x_offset: f32, y_offset: f32 },
        
        AppUpdate: void,
        AppRender: void,
        AppTick: void,
        
        SceneChanged: struct { scene_name: []const u8 },
        AssetLoaded: struct { asset_id: usize },
        PathTracingToggled: struct { enabled: bool },
        CameraChanged: void,
    };
    
    pub fn init(event_type: EventType, data: EventData) Event {
        return .{
            .event_type = event_type,
            .data = data,
        };
    }
    
    pub fn isCategory(self: Event, category: EventCategory) bool {
        return switch (self.event_type) {
            .AppUpdate, .AppRender, .AppTick => category == .Application,
            .KeyPressed, .KeyReleased, .KeyTyped => category == .Keyboard,
            .MouseButtonPressed, .MouseButtonReleased => category == .MouseButton,
            .MouseMoved, .MouseScrolled => category == .Mouse,
            else => false,
        };
    }
};
```

### EventBus

```zig
pub const EventBus = struct {
    allocator: std.mem.Allocator,
    event_queue: std.ArrayList(Event),
    
    pub fn init(allocator: std.mem.Allocator) EventBus {
        return .{
            .allocator = allocator,
            .event_queue = std.ArrayList(Event){},
        };
    }
    
    pub fn deinit(self: *EventBus) void {
        self.event_queue.deinit(self.allocator);
    }
    
    /// Queue an event for processing
    pub fn queueEvent(self: *EventBus, event: Event) !void {
        try self.event_queue.append(self.allocator, event);
    }
    
    /// Dispatch an event immediately to the layer stack
    pub fn dispatchEvent(event: *Event, layer_stack: *LayerStack) void {
        layer_stack.onEvent(event);
    }
    
    /// Process all queued events
    pub fn processEvents(self: *EventBus, layer_stack: *LayerStack) void {
        for (self.event_queue.items) |*event| {
            layer_stack.onEvent(event);
        }
        self.event_queue.clearRetainingCapacity();
    }
};
```

---

## Integration with Existing Systems

### Example Layers

#### 1. PerformanceLayer

```zig
pub const PerformanceLayer = struct {
    base: Layer,
    performance_monitor: *PerformanceMonitor,
    
    pub fn create(allocator: std.mem.Allocator, pm: *PerformanceMonitor) !*PerformanceLayer {
        const layer = try allocator.create(PerformanceLayer);
        layer.* = .{
            .base = .{
                .name = "PerformanceLayer",
                .vtable = &vtable,
            },
            .performance_monitor = pm,
        };
        return layer;
    }
    
    const vtable = Layer.LayerVTable{
        .attach = attach,
        .detach = detach,
        .update = update,
        .render = render,
        .event = event,
    };
    
    fn attach(base: *Layer) !void {
        const self: *PerformanceLayer = @fieldParentPtr("base", base);
        try self.performance_monitor.init();
    }
    
    fn detach(base: *Layer) void {
        const self: *PerformanceLayer = @fieldParentPtr("base", base);
        _ = self;
    }
    
    fn update(base: *Layer, frame_info: *const FrameInfo) !void {
        const self: *PerformanceLayer = @fieldParentPtr("base", base);
        // Performance monitoring happens automatically via begin/endPass
        // Could track frame times here if needed
        _ = self;
        _ = frame_info;
    }
    
    fn render(base: *Layer, frame_info: *const FrameInfo) !void {
        const self: *PerformanceLayer = @fieldParentPtr("base", base);
        _ = frame_info;
        _ = self;
    }
    
    fn event(base: *Layer, event: *Event) void {
        const self: *PerformanceLayer = @fieldParentPtr("base", base);
        _ = event;
        _ = self;
    }
};
```

#### 2. InputLayer

```zig
pub const InputLayer = struct {
    base: Layer,
    window: *Window,
    camera_controller: *KeyboardMovementController,
    last_toggle_time: f64 = 0,
    
    pub fn create(allocator: std.mem.Allocator, window: *Window, controller: *KeyboardMovementController) !*InputLayer {
        const layer = try allocator.create(InputLayer);
        layer.* = .{
            .base = .{
                .name = "InputLayer",
                .vtable = &vtable,
            },
            .window = window,
            .camera_controller = controller,
        };
        return layer;
    }
    
    fn update(base: *Layer, frame_info: *const FrameInfo) !void {
        const self: *InputLayer = @fieldParentPtr("base", base);
        
        // Handle camera movement using dt from frame_info
        try self.camera_controller.update(self.window, frame_info.dt);
        
        // Handle key toggles
        const TOGGLE_COOLDOWN = 0.2;
        const t_key_state = c.glfwGetKey(self.window.window.?, GLFW_KEY_T);
        const toggle_time = c.glfwGetTime();
        
        if (t_key_state == c.GLFW_PRESS and (toggle_time - self.last_toggle_time) > TOGGLE_COOLDOWN) {
            // Dispatch PathTracingToggled event
            const event_data = Event.init(.PathTracingToggled, .{ .PathTracingToggled = .{ .enabled = true } });
            // Event will be queued and processed by SceneLayer
            self.last_toggle_time = toggle_time;
            _ = event_data;
        }
    }
    
    fn event(base: *Layer, event: *Event) void {
        const self: *InputLayer = @fieldParentPtr("base", base);
        _ = self;
        
        switch (event.event_type) {
            .KeyPressed => {
                // Handle key press
                event.handled = true;
            },
            .MouseMoved => {
                // Handle mouse movement
            },
            else => {},
        }
    }
};
```

#### 3. SceneLayer

```zig
pub const SceneLayer = struct {
    base: Layer,
    scene: *Scene,
    asset_manager: *AssetManager,
    ubo_set: *GlobalUboSet,
    camera: *Camera,
    
    pub fn create(allocator: std.mem.Allocator, scene: *Scene, assets: *AssetManager, ubo: *GlobalUboSet, camera: *Camera) !*SceneLayer {
        const layer = try allocator.create(SceneLayer);
        layer.* = .{
            .base = .{
                .name = "SceneLayer",
                .vtable = &vtable,
            },
            .scene = scene,
            .asset_manager = assets,
            .ubo_set = ubo,
            .camera = camera,
        };
        return layer;
    }
    
    fn update(base: *Layer, frame_info: *const FrameInfo) !void {
        const self: *SceneLayer = @fieldParentPtr("base", base);
        
        // Update camera projection
        self.camera.updateProjectionMatrix();
        
        // Build UBO using frame_info
        var ubo = GlobalUbo{
            .view = self.camera.viewMatrix,
            .projection = self.camera.projectionMatrix,
            .dt = frame_info.dt,
        };
        
        // Update UBO set for this frame
        self.ubo_set.update(frame_info.current_frame, &ubo);
        
        // Update scene logic (if needed)
        try self.scene.update(frame_info, &ubo);
    }
    
    fn render(base: *Layer, frame_info: *const FrameInfo) !void {
        const self: *SceneLayer = @fieldParentPtr("base", base);
        
        // Render scene
        try self.scene.render(frame_info);
    }
    
    fn event(base: *Layer, event: *Event) void {
        const self: *SceneLayer = @fieldParentPtr("base", base);
        
        switch (event.event_type) {
            .PathTracingToggled => {
                const enabled = event.data.PathTracingToggled.enabled;
                self.scene.setPathTracingEnabled(enabled) catch {};
                event.handled = true;
            },
            else => {},
        }
    }
};
```

#### 4. RenderLayer

```zig
pub const RenderLayer = struct {
    base: Layer,
    swapchain: *Swapchain,
    graphics_context: *GraphicsContext,
    
    fn update(base: *Layer, frame_info: *const FrameInfo) !void {
        _ = base;
        _ = frame_info;
        // Nothing to do - rendering happens in render()
    }
    
    fn render(base: *Layer, frame_info: *const FrameInfo) !void {
        const self: *RenderLayer = @fieldParentPtr("base", base);
        
        // Begin frame
        try self.swapchain.beginFrame(frame_info.*);
        
        // Scene rendering happens in SceneLayer
        // This layer just manages frame begin/end
    }
};
```

#### 5. UILayer

```zig
pub const UILayer = struct {
    base: Layer,
    ui_renderer: *UIRenderer,
    show_ui: bool = true,
    
    fn render(base: *Layer, frame_info: *const FrameInfo) !void {
        const self: *UILayer = @fieldParentPtr("base", base);
        
        if (!self.show_ui) return;
        
        const stats = RenderStats{
            .fps = 60.0, // Get from app or performance monitor
            .frame_time_ms = frame_info.dt * 1000.0,
            .entity_count = 100,
            .draw_calls = 50,
            .path_tracing_enabled = false,
        };
        
        try self.ui_renderer.render(&stats);
    }
    
    fn event(base: *Layer, event: *Event) void {
        const self: *UILayer = @fieldParentPtr("base", base);
        
        switch (event.event_type) {
            .KeyPressed => {
                if (event.data.KeyPressed.key == GLFW_KEY_F1) {
                    self.show_ui = !self.show_ui;
                    event.handled = true;
                }
            },
            else => {},
        }
    }
};
```

---

## Implementation Plan

### Phase 1: Core Infrastructure (Week 1)

**Files to Create:**
- `src/layers/layer.zig` - Base Layer interface
- `src/layers/layer_stack.zig` - LayerStack implementation
- `src/events/event.zig` - Event types and data
- `src/events/event_bus.zig` - Event bus and dispatcher

**Tasks:**
1. ✅ Implement Layer interface with VTable
2. ✅ Implement LayerStack push/pop/update/render
3. ✅ Define core Event types
4. ✅ Implement EventBus queue and dispatch

**Success Criteria:**
- Can create layers and add to stack
- Can update/render layers in order
- Can queue and dispatch events

---

### Phase 2: Migrate Existing Systems (Week 2)

**Layers to Create:**
- `src/layers/performance_layer.zig`
- `src/layers/input_layer.zig`
- `src/layers/scene_layer.zig`
- `src/layers/render_layer.zig`
- `src/layers/ui_layer.zig`

**Tasks:**
1. Extract performance monitoring into PerformanceLayer
2. Extract input handling into InputLayer
3. Extract scene updates into SceneLayer
4. Extract rendering into RenderLayer
5. Extract UI into UILayer
6. Update `app.zig` to use LayerStack

**Success Criteria:**
- `app.zig` update loop reduced to <50 lines
- Each system isolated in its own layer
- No functionality lost

---

### Phase 3: Event Integration (Week 3)

**Tasks:**
1. Replace direct calls with events where appropriate
2. Implement input event dispatching from GLFW callbacks
3. Add event handlers to layers
4. Add custom events (SceneChanged, AssetLoaded, etc.)

**Success Criteria:**
- Systems communicate via events
- Input properly propagates to layers
- Custom events working

---

### Phase 4: Advanced Features (Week 4)

**Tasks:**
1. Add layer enable/disable at runtime
2. Add layer priority/ordering
3. Add event filtering/categories
4. Add performance profiling per layer
5. Add layer serialization for save/load

**Success Criteria:**
- Can toggle layers at runtime
- Can reorder layers
- Can profile each layer individually

---

## Examples

### Simplified App.zig After Migration

```zig
pub const App = struct {
    // Core
    allocator: std.mem.Allocator,
    window: Window,
    gc: GraphicsContext,
    swapchain: Swapchain,
    
    // Layer system
    layer_stack: LayerStack,
    event_bus: EventBus,
    
    // Layers
    performance_layer: *PerformanceLayer,
    input_layer: *InputLayer,
    scene_layer: *SceneLayer,
    render_layer: *RenderLayer,
    ui_layer: *UILayer,
    
    pub fn init() !App {
        var app: App = undefined;
        
        // Initialize core systems
        app.window = try Window.init(.{});
        app.gc = try GraphicsContext.init(allocator, "Zephyr-Engine", app.window.window.?);
        app.swapchain = try Swapchain.init(&app.gc, allocator, extent);
        
        // Initialize layer stack
        app.layer_stack = LayerStack.init(allocator);
        app.event_bus = EventBus.init(allocator);
        
        // Create and attach layers (in order)
        app.performance_layer = try PerformanceLayer.create(allocator, &app.performance_monitor);
        try app.layer_stack.pushLayer(&app.performance_layer.base);
        
        app.input_layer = try InputLayer.create(allocator, &app.window, &app.camera_controller);
        try app.layer_stack.pushLayer(&app.input_layer.base);
        
        app.scene_layer = try SceneLayer.create(allocator, &app.scene, &app.asset_manager, &app.ubo_set, &app.camera);
        try app.layer_stack.pushLayer(&app.scene_layer.base);
        
        app.render_layer = try RenderLayer.create(allocator, &app.swapchain, &app.gc);
        try app.layer_stack.pushLayer(&app.render_layer.base);
        
        app.ui_layer = try UILayer.create(allocator, &app.ui_renderer);
        try app.layer_stack.pushLayer(&app.ui_layer.base);
        
        return app;
    }
    
    pub fn update(self: *App) !bool {
        if (!self.window.isRunning()) return false;
        
        // Build frame info with all context (includes dt, camera, extent, etc.)
        const frame_info = self.buildFrameInfo();
        
        // Update all layers with full frame context
        try self.layer_stack.update(&frame_info);
        
        // Process event queue
        self.event_bus.processEvents(&self.layer_stack);
        
        // Render all layers
        try self.layer_stack.render(&frame_info);
        
        // Present
        try self.swapchain.present(frame_info.command_buffer, self.current_frame, self.window_extent);
        
        self.current_frame = (self.current_frame + 1) % MAX_FRAMES_IN_FLIGHT;
        
        return true;
    }
};
```

### Clean and Organized
- **~40 lines** instead of 300+
- **Clear separation** of concerns
- **Easy to extend** - just add a new layer
- **Runtime control** - enable/disable layers
- **Testable** - each layer independent

---

## Performance Considerations

### Memory

**Layer Storage:**
- Layers stored as pointers in ArrayList: `8 bytes * num_layers`
- Typical app: ~5-10 layers = 40-80 bytes
- **Negligible overhead**

**Event Queue:**
- Events stored in ArrayList with `Event` union
- Typical frame: ~10-50 events
- Event size: ~32 bytes (union + metadata)
- Typical frame: 320-1600 bytes
- **Acceptable overhead**

### Performance

**Layer Iteration:**
- Simple for-loop over ArrayList
- No virtual dispatch overhead (uses VTable directly)
- **~5-10ns per layer** on modern CPU

**Event Dispatch:**
- O(n) where n = number of layers
- Early termination if event handled
- **~20-50ns per event**

**Frame Budget:**
- Layer updates: <0.1ms total
- Event processing: <0.1ms total
- **Total overhead: <0.2ms per frame** (negligible)

---

## Future Enhancements

### 1. Layer Groups
Group related layers for bulk enable/disable:
```zig
layer_stack.disableGroup("Debug"); // Disables all debug layers
```

### 2. Async Layers
Layers that run on separate threads:
```zig
pub const AsyncSceneLayer = struct {
    // Runs scene updates on background thread
    // Synchronizes with main thread for rendering
};
```

### 3. Layer Serialization
Save/load layer state:
```zig
layer_stack.serialize("layer_config.json");
layer_stack.deserialize("layer_config.json");
```

### 4. Event Recording/Replay
Record events for debugging:
```zig
event_bus.startRecording();
// ... play game ...
event_bus.saveRecording("session.events");
event_bus.replay("session.events"); // Deterministic replay
```

### 5. Hot-Reloadable Layers
Reload layer code without restarting:
```zig
layer_stack.reloadLayer("SceneLayer"); // Recompiles and swaps
```

---

## Conclusion

The Layer and Event system provides:

✅ **Organization** - Clear structure for app update loop  
✅ **Decoupling** - Systems don't depend on each other  
✅ **Extensibility** - Easy to add new features  
✅ **Runtime Control** - Enable/disable systems dynamically  
✅ **Testability** - Each layer can be tested independently  
✅ **Performance** - Negligible overhead (<0.2ms per frame)  

This design transforms the monolithic `app.zig` into a clean, organized system that's easy to maintain and extend.

---

**Next Steps:**
1. Review and approve this design
2. Begin Phase 1 implementation
3. Create example layers
4. Migrate existing app.zig code

**Estimated Total Time:** 3-4 weeks for full migration
