# Phase 2: Engine API Implementation

**Status:** 🔄 In Progress  
**Started:** October 25, 2025  
**Goal:** Implement the Engine struct to provide a clean, high-level API for the editor

---

## Overview

Phase 2 focuses on implementing the `Engine` struct in `engine/src/core/engine.zig` to provide a unified interface for initializing and managing all engine systems. Currently, the editor directly constructs and manages individual systems (Window, GraphicsContext, LayerStack, etc.). The goal is to encapsulate this complexity behind a clean API.

## Current State

**✅ Completed:**
- Engine struct exists with method signatures
- Module export (zulkan.zig) created with all necessary types
- Build system configured for engine-as-module
- Application compiles and runs successfully

**🔄 In Progress:**
- Engine.init() implementation (currently panics)
- Frame loop methods (beginFrame/update/render/endFrame)
- System lifecycle management

**❌ Pending:**
- Refactor editor_app.zig to use Engine API
- Remove direct system construction from editor
- Documentation for Engine API usage

---

## Implementation Tasks

### 1. Engine.init() Implementation

**Goal:** Initialize all core engine systems from a single call

```zig
pub fn init(allocator: std.mem.Allocator, config: Config) !Engine {
    var engine: Engine = undefined;
    engine.allocator = allocator;
    
    // 1. Create window
    engine.window = try Window.init(.{
        .width = config.window.width,
        .height = config.window.height,
        .title = config.window.title,
        .fullscreen = config.window.fullscreen,
    });
    errdefer engine.window.deinit();
    
    // 2. Initialize graphics context
    engine.graphics_context = try GraphicsContext.init(
        allocator,
        engine.window.getGLFWwindow(),
        config.enable_validation,
    );
    errdefer engine.graphics_context.deinit();
    
    // 3. Create swapchain
    engine.swapchain = try Swapchain.init(
        allocator,
        &engine.graphics_context,
        &engine.window,
        config.renderer.vsync,
    );
    errdefer engine.swapchain.deinit();
    
    // 4. Initialize event system
    engine.event_bus = EventBus.init(allocator);
    errdefer engine.event_bus.deinit();
    
    engine.window.setEventBus(&engine.event_bus);
    
    // 5. Initialize layer stack
    engine.layer_stack = try LayerStack.init(allocator);
    errdefer engine.layer_stack.deinit();
    
    // 6. Optional systems
    if (config.enable_performance_monitoring) {
        engine.performance_monitor = try allocator.create(PerformanceMonitor);
        engine.performance_monitor.* = try PerformanceMonitor.init(allocator);
    }
    
    // 7. Asset manager (optional)
    // engine.asset_manager = ...
    
    return engine;
}
```

**Challenges:**
- Proper error handling with defer cleanup
- Configuration flexibility
- Optional system initialization
- Dependencies between systems

### 2. Engine.deinit() Implementation

**Goal:** Clean up all engine systems in reverse order

```zig
pub fn deinit(self: *Engine) void {
    // Clean up in reverse order of initialization
    
    if (self.asset_manager) |am| {
        am.deinit();
        self.allocator.destroy(am);
    }
    
    if (self.performance_monitor) |pm| {
        pm.deinit();
        self.allocator.destroy(pm);
    }
    
    self.layer_stack.deinit();
    self.event_bus.deinit();
    self.swapchain.deinit();
    self.graphics_context.deinit();
    self.window.deinit();
}
```

### 3. Frame Loop Implementation

**Goal:** Encapsulate the main frame loop logic

#### beginFrame()

```zig
pub fn beginFrame(self: *Engine) !FrameInfo {
    // 1. Process window events
    self.window.pollEvents();
    
    if (!self.window.isRunning()) {
        return error.WindowClosed;
    }
    
    // 2. Process queued events through layers
    try self.event_bus.processEvents(&self.layer_stack);
    
    // 3. Begin frame for swapchain
    const image_index = try self.swapchain.acquireNextImage();
    
    // 4. Create frame info
    var frame_info = FrameInfo{
        .frame_index = self.swapchain.getCurrentFrame(),
        .image_index = image_index,
        .command_buffer = self.swapchain.getCurrentCommandBuffer(),
        // ... other fields
    };
    
    // 5. Begin all layers
    try self.layer_stack.beginAll(&frame_info);
    
    return frame_info;
}
```

#### update()

```zig
pub fn update(self: *Engine, frame_info: *const FrameInfo) !void {
    // Update all layers
    try self.layer_stack.updateAll(frame_info);
}
```

#### render()

```zig
pub fn render(self: *Engine, frame_info: *const FrameInfo) !void {
    // Render all layers
    try self.layer_stack.renderAll(frame_info);
}
```

#### endFrame()

```zig
pub fn endFrame(self: *Engine, frame_info: *const FrameInfo) !void {
    // 1. End all layers
    try self.layer_stack.endAll(frame_info);
    
    // 2. Submit and present
    try self.swapchain.submitCommandBuffer(frame_info.command_buffer);
    try self.swapchain.present(frame_info.image_index);
    
    // 3. Update performance stats
    if (self.performance_monitor) |pm| {
        pm.endFrame();
    }
}
```

### 4. Editor Integration

**Goal:** Refactor editor_app.zig to use Engine API

**Current (editor_app.zig):**
```zig
pub fn init(self: *App) !void {
    // Manually initialize ~20+ systems
    self.window = try Window.init(...);
    self.gc = try GraphicsContext.init(...);
    self.swapchain = try Swapchain.init(...);
    // ... many more lines
}

pub fn update(self: *App) !bool {
    // Manual frame loop
    self.window.pollEvents();
    const image_index = try self.swapchain.acquireNextImage();
    // ... manual layer management
}
```

**Target (using Engine API):**
```zig
pub fn init(self: *App) !void {
    // Initialize engine with config
    self.engine = try zulkan.Engine.init(self.allocator, .{
        .window = .{
            .width = 1280,
            .height = 720,
            .title = "ZulkanEditor",
        },
        .enable_validation = true,
        .enable_performance_monitoring = true,
    });
    
    // Add custom editor layers
    try self.engine.getLayerStack().pushLayer(&self.input_layer.base);
    try self.engine.getLayerStack().pushLayer(&self.ui_layer.base);
    
    // Initialize editor-specific systems
    self.imgui_context = try ImGuiContext.init(...);
    // ...
}

pub fn update(self: *App) !bool {
    // Use engine frame loop
    const frame_info = try self.engine.beginFrame();
    try self.engine.update(&frame_info);
    try self.engine.render(&frame_info);
    try self.engine.endFrame(&frame_info);
    
    return self.engine.isRunning();
}
```

---

## TODOs from Phase 1

### High Priority

1. **Restore missing methods:**
   - [ ] `GraphicsContext.workerThreadExitHook` - Thread exit callback
   - [ ] `Texture.deinitZstbi()` - Texture library cleanup
   - [ ] `Event.EventData` - Verify access pattern is correct

2. **Fix layer dependencies:**
   - [ ] Decide: Should InputLayer/UILayer be in engine or editor?
   - [ ] Option A: Make them generic/pluggable in engine
   - [ ] Option B: Keep in editor as examples
   - [ ] Option C: Create base classes in engine, implementations in editor

3. **Add missing constants:**
   - [ ] `MAX_FRAMES_IN_FLIGHT` - Currently hardcoded as 3
   - [ ] Should be in EngineConfig or as constant export

### Medium Priority

4. **Improve Config System:**
   - [ ] Add validation for config values
   - [ ] Document all config options
   - [ ] Add defaults for optional fields

5. **Error Handling:**
   - [ ] Ensure all init functions have proper cleanup
   - [ ] Test error paths (OOM, device lost, etc.)
   - [ ] Add logging for initialization steps

6. **Testing:**
   - [ ] Create simple example using Engine API
   - [ ] Verify engine can run headless (no window)
   - [ ] Test multiple engine instances

### Low Priority

7. **Documentation:**
   - [ ] Write ENGINE_API.md with usage examples
   - [ ] Document all public Engine methods
   - [ ] Create migration guide for existing code

8. **Optimization:**
   - [ ] Lazy initialization for optional systems
   - [ ] Profile initialization time
   - [ ] Reduce memory allocations

---

## Success Criteria

Phase 2 will be considered complete when:

1. ✅ `Engine.init()` successfully initializes all systems
2. ✅ Frame loop methods (begin/update/render/end) work correctly
3. ✅ Editor uses Engine API instead of direct system construction
4. ✅ All Phase 1 TODOs are resolved or have clear path forward
5. ✅ At least one example program uses the Engine API
6. ✅ Engine can be used without editor components
7. ✅ Documentation covers basic Engine usage

---

## Timeline

**Estimated Effort:** 2-3 days

- **Day 1:** Implement Engine.init() and deinit()
- **Day 2:** Implement frame loop methods, test with simple example
- **Day 3:** Refactor editor to use Engine API, clean up TODOs

---

## Notes

- Keep the API simple - don't expose too much internals
- Config should be flexible but have good defaults
- Error messages should be helpful for debugging
- Consider future extensibility (plugins, custom systems)

