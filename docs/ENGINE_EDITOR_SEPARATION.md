# Engine/Editor Separation Design

**Version:** 1.0  
**Date:** October 25, 2025  
**Status:** Design Phase  

---

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Project Structure](#project-structure)
4. [Public API Design](#public-api-design)
5. [Build System](#build-system)
6. [Migration Plan](#migration-plan)
7. [Implementation Phases](#implementation-phases)

---

## Overview

### Goal

Separate ZulkanZengine into two distinct components:
- **ZulkanEngine** - Core engine as a static library
- **ZulkanEditor** - Editor application using the engine

### Benefits

- ✅ **Clean API boundary** - Forces good architectural decisions
- ✅ **Reusable engine** - Can be used in games, tools, runtime
- ✅ **Faster iteration** - Editor changes don't require engine rebuild
- ✅ **Smaller runtime** - Games don't include editor overhead
- ✅ **Library distribution** - Engine can be packaged as Zig module

### Principles

1. **Engine is headless-capable** - Can run without UI for dedicated servers
2. **Zig-style API** - Idiomatic Zig, not C-style exports
3. **Minimal dependencies** - Engine has fewer deps than editor
4. **Hot-reloadable** - Editor can reload engine lib (future)

---

## Architecture

### Component Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                     ZulkanEditor (exe)                      │
├─────────────────────────────────────────────────────────────┤
│  Editor Layers        │  Editor Panels   │  Editor Tools    │
│  - ViewportLayer      │  - Hierarchy     │  - Asset Import  │
│  - InspectorLayer     │  - Inspector     │  - Scene Edit    │
│  - AssetBrowserLayer  │  - Console       │  - Preferences   │
│  - ConsoleLayer       │  - Profiler      │                  │
└────────────────────────┬────────────────────────────────────┘
                         │ uses
                         ▼
┌─────────────────────────────────────────────────────────────┐
│                    ZulkanEngine (lib)                       │
├─────────────────────────────────────────────────────────────┤
│  Core                 │  Systems          │  Subsystems      │
│  - Engine             │  - Rendering      │  - Assets        │
│  - Window             │  - ECS            │  - Threading     │
│  - LayerStack         │  - Scene          │  - FileWatcher   │
│  - EventBus           │  - Camera         │  - Hot Reload    │
│                       │  - Performance    │                  │
└─────────────────────────────────────────────────────────────┘
```

### What Goes Where?

#### **Engine Library (Core Engine)**

**Systems:**
- ✅ Core (Window, Graphics Context, Layer System, Event Bus)
- ✅ Rendering (Swapchain, Pipelines, RenderGraph, Shaders)
- ✅ ECS (World, Components, Systems)
- ✅ Scene (Scene v2, GameObject v2, Hierarchies)
- ✅ Assets (AssetManager, Loaders, Hot Reload)
- ✅ Performance (PerformanceMonitor, Profiling)
- ✅ Threading (ThreadPool, WorkItems)
- ✅ Math (Vectors, Matrices, Transforms)

**Layers (Engine-Provided):**
- ✅ PerformanceLayer - Frame timing
- ✅ RenderLayer - Swapchain management
- ❓ InputLayer - Basic input (could be engine or editor)
- ✅ SceneLayer - Scene updates

**Optional Debug UI:**
- ✅ Basic stats overlay (FPS, frame time)
- ✅ Performance graphs (optional, can be disabled)
- ❌ Scene editing UI
- ❌ Inspector panels

#### **Editor Application**

**Editor-Specific:**
- ✅ Editor window and UI framework
- ✅ Scene hierarchy panel
- ✅ Component inspector
- ✅ Asset browser
- ✅ Console/logging panel
- ✅ Viewport rendering
- ✅ Gizmos (translate, rotate, scale)
- ✅ Scene editing tools
- ✅ Preferences/settings

**Editor Layers:**
- ViewportLayer - 3D scene viewport with camera controls
- InspectorLayer - Entity/component editing
- AssetBrowserLayer - File system browser
- ConsoleLayer - Log output
- EditorInputLayer - Editor-specific input (overrides engine input)

---

## Project Structure

### New Directory Layout

```
ZulkanZengine/
├─ build.zig                    # Root build - builds both lib and exe
├─ build.zig.zon               # Dependencies
│
├─ engine/                      # ENGINE LIBRARY
│  ├─ src/
│  │  ├─ zulkan.zig            # Main module export (public API)
│  │  ├─ core/
│  │  │  ├─ engine.zig         # Engine struct (main API)
│  │  │  ├─ window.zig
│  │  │  ├─ graphics_context.zig
│  │  │  ├─ swapchain.zig
│  │  │  ├─ layer.zig
│  │  │  ├─ layer_stack.zig
│  │  │  ├─ event.zig
│  │  │  ├─ event_bus.zig
│  │  │  └─ ...
│  │  ├─ rendering/
│  │  │  ├─ camera.zig
│  │  │  ├─ render_graph.zig
│  │  │  ├─ performance_monitor.zig
│  │  │  └─ ...
│  │  ├─ ecs/
│  │  │  ├─ world.zig
│  │  │  ├─ entity_registry.zig
│  │  │  └─ ...
│  │  ├─ scene/
│  │  │  ├─ scene.zig
│  │  │  └─ game_object.zig
│  │  ├─ assets/
│  │  ├─ layers/
│  │  │  ├─ performance_layer.zig
│  │  │  ├─ render_layer.zig
│  │  │  └─ scene_layer.zig
│  │  ├─ systems/
│  │  ├─ threading/
│  │  ├─ math/
│  │  └─ utils/
│  └─ README.md                # Engine-specific docs
│
├─ editor/                      # EDITOR APPLICATION
│  ├─ src/
│  │  ├─ main.zig              # Editor entry point
│  │  ├─ editor_app.zig        # Editor application class
│  │  ├─ layers/
│  │  │  ├─ viewport_layer.zig
│  │  │  ├─ inspector_layer.zig
│  │  │  ├─ asset_browser_layer.zig
│  │  │  └─ console_layer.zig
│  │  ├─ panels/
│  │  │  ├─ hierarchy_panel.zig
│  │  │  ├─ inspector_panel.zig
│  │  │  ├─ asset_panel.zig
│  │  │  └─ console_panel.zig
│  │  ├─ tools/
│  │  │  ├─ gizmo.zig
│  │  │  ├─ asset_importer.zig
│  │  │  └─ scene_serializer.zig
│  │  └─ ui/
│  │     └─ editor_ui.zig
│  └─ resources/               # Editor-only resources
│     ├─ icons/
│     └─ fonts/
│
├─ runtime/                     # FUTURE: Game runtime
│  └─ src/
│     └─ main.zig              # Minimal runtime for shipping games
│
├─ docs/                        # Documentation
│  ├─ ENGINE_API.md            # Engine API reference
│  ├─ EDITOR_GUIDE.md          # Editor user guide
│  └─ ...
│
├─ examples/                    # Example projects using the engine
│  └─ simple_game/
│     └─ main.zig
│
└─ assets/                      # Shared assets (test data)
   ├─ models/
   ├─ textures/
   └─ shaders/
```

---

## Public API Design

### Core Engine API (`engine/src/core/engine.zig`)

```zig
const std = @import("std");
const vk = @import("vulkan");

/// Main engine instance
/// Manages core systems and provides the public API
pub const Engine = struct {
    allocator: std.mem.Allocator,
    
    // Core systems (private)
    window: Window,
    graphics_context: GraphicsContext,
    layer_stack: LayerStack,
    event_bus: EventBus,
    
    // Optional systems
    asset_manager: ?*AssetManager,
    performance_monitor: ?*PerformanceMonitor,
    
    /// Engine configuration
    pub const Config = struct {
        window: WindowConfig,
        renderer: RendererConfig,
        enable_validation: bool = false,
        enable_performance_monitoring: bool = true,
        
        pub const WindowConfig = struct {
            width: u32 = 1280,
            height: u32 = 720,
            title: [:0]const u8 = "ZulkanEngine",
            fullscreen: bool = false,
            vsync: bool = false,
        };
        
        pub const RendererConfig = struct {
            enable_ray_tracing: bool = true,
            max_frames_in_flight: u32 = 3,
        };
    };
    
    /// Initialize the engine with configuration
    pub fn init(allocator: std.mem.Allocator, config: Config) !Engine {
        // Initialize core systems
        // Return engine instance
    }
    
    /// Shutdown the engine and cleanup all resources
    pub fn deinit(self: *Engine) void {
        // Cleanup all systems
    }
    
    /// Check if engine should continue running
    pub fn isRunning(self: *Engine) bool {
        return self.window.isRunning();
    }
    
    /// Begin a new frame
    /// Returns frame info for rendering
    pub fn beginFrame(self: *Engine) !FrameInfo {
        // Process events
        // Begin all layers
        // Return frame info
    }
    
    /// Update engine logic
    pub fn update(self: *Engine, frame_info: *const FrameInfo) !void {
        // Update all layers
    }
    
    /// Render the frame
    pub fn render(self: *Engine, frame_info: *const FrameInfo) !void {
        // Render all layers
    }
    
    /// End the frame and present
    pub fn endFrame(self: *Engine, frame_info: *FrameInfo) !void {
        // End all layers
        // Present to screen
    }
    
    /// Get the layer stack for adding custom layers
    pub fn getLayerStack(self: *Engine) *LayerStack {
        return &self.layer_stack;
    }
    
    /// Get the event bus for queuing events
    pub fn getEventBus(self: *Engine) *EventBus {
        return &self.event_bus;
    }
    
    /// Get the asset manager (if enabled)
    pub fn getAssetManager(self: *Engine) ?*AssetManager {
        return self.asset_manager;
    }
    
    /// Get performance statistics
    pub fn getPerformanceStats(self: *Engine) ?PerformanceStats {
        if (self.performance_monitor) |pm| {
            return pm.getStats();
        }
        return null;
    }
};
```

### Module Export (`engine/src/zulkan.zig`)

```zig
// Main engine module export
// This is what users import: @import("zulkan")

pub const Engine = @import("core/engine.zig").Engine;
pub const EngineConfig = Engine.Config;

// Core types
pub const Layer = @import("core/layer.zig").Layer;
pub const LayerStack = @import("core/layer_stack.zig").LayerStack;
pub const Event = @import("core/event.zig").Event;
pub const EventType = @import("core/event.zig").EventType;
pub const EventBus = @import("core/event_bus.zig").EventBus;
pub const Window = @import("core/window.zig").Window;

// Rendering
pub const Camera = @import("rendering/camera.zig").Camera;
pub const FrameInfo = @import("rendering/frameinfo.zig").FrameInfo;
pub const PerformanceStats = @import("rendering/performance_monitor.zig").PerformanceStats;

// ECS
pub const World = @import("ecs/world.zig").World;
pub const Entity = @import("ecs/entity_registry.zig").Entity;

// Scene
pub const Scene = @import("scene/scene_v2.zig").Scene;
pub const GameObject = @import("scene/game_object_v2.zig").GameObject;

// Assets
pub const AssetManager = @import("assets/asset_manager.zig").AssetManager;

// Math
pub const Math = @import("math/math.zig");

// Layers (engine-provided)
pub const PerformanceLayer = @import("layers/performance_layer.zig").PerformanceLayer;
pub const RenderLayer = @import("layers/render_layer.zig").RenderLayer;
pub const SceneLayer = @import("layers/scene_layer.zig").SceneLayer;

// Utils
pub const log = @import("utils/log.zig").log;
```

### Example Usage (Editor)

```zig
const std = @import("std");
const zulkan = @import("zulkan");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Configure engine
    const config = zulkan.EngineConfig{
        .window = .{
            .title = "ZulkanEditor",
            .width = 1920,
            .height = 1080,
        },
        .enable_performance_monitoring = true,
    };
    
    // Initialize engine
    var engine = try zulkan.Engine.init(allocator, config);
    defer engine.deinit();
    
    // Add custom editor layers
    var viewport_layer = ViewportLayer.init(/* ... */);
    try engine.getLayerStack().pushLayer(&viewport_layer.base);
    
    // Main loop
    while (engine.isRunning()) {
        const frame_info = try engine.beginFrame();
        try engine.update(&frame_info);
        try engine.render(&frame_info);
        try engine.endFrame(&frame_info);
    }
}
```

---

## Build System

### Root `build.zig`

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    
    // ========== ENGINE LIBRARY ==========
    const engine = b.addStaticLibrary(.{
        .name = "zulkan",
        .root_source_file = b.path("engine/src/zulkan.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    // Add engine dependencies
    addEngineDependencies(b, engine, target, optimize);
    
    // Install engine library
    b.installArtifact(engine);
    
    // ========== EDITOR EXECUTABLE ==========
    const editor = b.addExecutable(.{
        .name = "ZulkanEditor",
        .root_source_file = b.path("editor/src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    // Link engine library
    editor.linkLibrary(engine);
    
    // Add editor dependencies
    addEditorDependencies(b, editor, target, optimize);
    
    // Install editor
    b.installArtifact(editor);
    
    // Run command
    const run_cmd = b.addRunArtifact(editor);
    run_cmd.step.dependOn(b.getInstallStep());
    
    const run_step = b.step("run", "Run the editor");
    run_step.dependOn(&run_cmd.step);
    
    // Tests
    addTests(b, engine, editor, target, optimize);
}

fn addEngineDependencies(b: *std.Build, lib: *std.Build.Step.Compile, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    // Vulkan
    const vulkan_headers = b.dependency("vulkan_headers", .{});
    const vk_gen = b.dependency("vulkan_zig", .{}).artifact("vulkan-zig-generator");
    const vk_generate_cmd = b.addRunArtifact(vk_gen);
    vk_generate_cmd.addFileArg(vulkan_headers.path("registry/vk.xml"));
    lib.root_module.addImport("vulkan", b.addModule("vulkan", .{
        .root_source_file = vk_generate_cmd.addOutputFileArg("vk.zig"),
    }));
    
    // System libraries
    lib.linkSystemLibrary("glfw");
    lib.linkLibC();
    
    // Optional: ImGui for engine debug UI
    // addImGuiDependency(b, lib, target, optimize);
}

fn addEditorDependencies(b: *std.Build, exe: *std.Build.Step.Compile, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    // ImGui (required for editor)
    addImGuiDependency(b, exe, target, optimize);
    
    // Additional editor-only deps
}
```

---

## Migration Plan

### Phase 1: Restructure Files (Week 1)

**Step 1: Create new directory structure**
```bash
mkdir -p engine/src
mkdir -p editor/src/layers
mkdir -p editor/src/panels
mkdir -p editor/src/tools
mkdir -p runtime/src
```

**Step 2: Move engine files**
```bash
# Core systems stay in engine
mv src/core engine/src/
mv src/rendering engine/src/
mv src/ecs engine/src/
mv src/scene engine/src/
mv src/assets engine/src/
mv src/layers engine/src/
mv src/systems engine/src/
mv src/threading engine/src/
mv src/math engine/src/
mv src/utils engine/src/
```

**Step 3: Move editor files**
```bash
# UI components go to editor
mv src/ui editor/src/
mv src/main.zig editor/src/
mv src/app.zig editor/src/editor_app.zig
```

**Step 4: Create API files**
```bash
# Create engine module export
touch engine/src/zulkan.zig

# Create Engine class
touch engine/src/core/engine.zig
```

### Phase 2: Update Build System (Week 1)

1. Update `build.zig` to build engine as library
2. Create editor executable that links engine
3. Fix import paths
4. Test that everything compiles

### Phase 3: Define Engine API (Week 1-2)

1. Implement `Engine` struct in `engine/src/core/engine.zig`
2. Create `zulkan.zig` module export
3. Update `app.zig` → `editor_app.zig` to use Engine API
4. Remove direct system access from editor

### Phase 4: Create Editor Layers (Week 2)

1. ViewportLayer - 3D scene viewport
2. InspectorLayer - Entity/component inspector
3. AssetBrowserLayer - File browser
4. ConsoleLayer - Log output

### Phase 5: Polish & Test (Week 2-3)

1. Test engine library standalone
2. Verify editor functionality
3. Create simple example using engine
4. Document API

---

## Implementation Phases

### Phase 1: Foundation ✅
**Goal:** File structure and build system

- [ ] Create directory structure
- [ ] Move files to engine/editor
- [ ] Update build.zig
- [ ] Fix all import paths
- [ ] Verify compilation

**Success Criteria:** Project compiles with new structure

### Phase 2: Engine API 🔄
**Goal:** Define clean engine interface

- [ ] Create Engine struct
- [ ] Create zulkan.zig module
- [ ] Implement init/deinit
- [ ] Implement frame loop methods
- [ ] Add system accessors

**Success Criteria:** Editor can use Engine API

### Phase 3: Editor Separation 🔄
**Goal:** Make editor use engine library

- [ ] Convert app.zig to use Engine API
- [ ] Remove direct system access
- [ ] Move UI code to editor
- [ ] Create editor layers
- [ ] Test editor functionality

**Success Criteria:** Editor works via Engine API only

### Phase 4: Documentation 📝
**Goal:** Document the architecture

- [ ] Write ENGINE_API.md
- [ ] Update README.md
- [ ] Create migration guide
- [ ] Add examples

**Success Criteria:** Others can use the engine

---

## Next Steps

1. **Review this design** - Any changes needed?
2. **Start Phase 1** - Restructure files and build system
3. **Iterate on API** - Refine as we implement

**Let's build a proper engine architecture! 🚀**
