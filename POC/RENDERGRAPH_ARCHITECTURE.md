# RenderGraph vs GenericRenderer Architecture

**Date**: 21 October 2025  
**Status**: Design Complete → Implementation Starting

---

## Why Replace GenericRenderer?

### Problems with GenericRenderer

```zig
// GenericRenderer is GLOBAL - one instance processes everything
var forward_renderer: GenericRenderer = undefined;

// All scenes rendered the same way
try forward_renderer.addRenderer("textured", .raster, &textured_renderer, ...);
try forward_renderer.addRenderer("ecs_renderer", .raster, &ecs_renderer, ...);
try forward_renderer.addRenderer("point_light", .lighting, &point_light_renderer, ...);

// No per-scene control - dungeon and forest both get RT shadows (or neither)
try forward_renderer.render(frame_info);
```

**Limitations:**
- ❌ One rendering pipeline for all scenes
- ❌ Can't customize per scene (RT shadows in dungeon, shadow maps in forest)
- ❌ Hard-coded execution order
- ❌ No explicit resource dependencies
- ❌ Difficult to add/remove passes dynamically

---

## RenderGraph Solution

### Per-Scene Rendering Pipeline

```zig
// Each scene owns its own render graph
pub const Scene = struct {
    ecs_world: *World,
    render_graph: RenderGraph,  // Scene-specific pipeline!
};

// Dungeon scene - wants RT shadows, SSAO, bloom
var dungeon = Scene.init(...);
try dungeon.render_graph.addPass(DepthPrepass.create(...));
try dungeon.render_graph.addPass(GeometryPass.create(&dungeon));
try dungeon.render_graph.addPass(ShadowPass.create(&dungeon, .Raytraced));  // RT!
try dungeon.render_graph.addPass(LightingPass.create(&dungeon));
try dungeon.render_graph.addPass(SSAOPass.create(...));
try dungeon.render_graph.addPass(PostProcessPass.create(...));

// Forest scene - wants shadow maps, no SSAO, different post-processing
var forest = Scene.init(...);
try forest.render_graph.addPass(GeometryPass.create(&forest));
try forest.render_graph.addPass(ShadowPass.create(&forest, .ShadowMaps));  // Shadow maps!
try forest.render_graph.addPass(LightingPass.create(&forest));
try forest.render_graph.addPass(PostProcessPass.create(...));

// Execute per-scene
try dungeon.render_graph.execute(frame_info);  // RT shadows
try forest.render_graph.execute(frame_info);   // Shadow maps
```

**Benefits:**
- ✅ Each scene defines its own pipeline
- ✅ Easy to add/remove passes per scene
- ✅ Explicit resource dependencies
- ✅ Automatic pass ordering
- ✅ Industry standard approach

---

## Architecture Comparison

### Old: GenericRenderer (Global)

```
┌─────────────────────────────────────┐
│      GenericRenderer (Global)       │
│  ┌─────────────────────────────┐   │
│  │   TexturedRenderer          │   │
│  │   EcsRenderer               │   │
│  │   PointLightRenderer        │   │
│  │   ParticleRenderer          │   │
│  │   RaytracingRenderer        │   │
│  └─────────────────────────────┘   │
│                                     │
│  Hard-coded execution order:        │
│  1. Raster renderers                │
│  2. Lighting renderers              │
│  3. Compute renderers               │
│  4. Raytracing renderers            │
│  5. Post-process renderers          │
└─────────────────────────────────────┘
         ↓
    All Scenes
  (same pipeline)
```

### New: RenderGraph (Per-Scene)

```
┌──────────────────────────┐     ┌──────────────────────────┐
│   Scene: Dungeon         │     │   Scene: Forest          │
│  ┌────────────────────┐  │     │  ┌────────────────────┐  │
│  │   RenderGraph      │  │     │  │   RenderGraph      │  │
│  │                    │  │     │  │                    │  │
│  │ 1. DepthPrepass    │  │     │  │ 1. GeometryPass    │  │
│  │ 2. GeometryPass    │  │     │  │ 2. ShadowPass      │  │
│  │ 3. ShadowPass (RT) │  │     │  │    (Shadow Maps)   │  │
│  │ 4. LightingPass    │  │     │  │ 3. LightingPass    │  │
│  │ 5. SSAOPass        │  │     │  │ 4. TransparencyPass│  │
│  │ 6. TransparencyPass│  │     │  │ 5. PostProcessPass │  │
│  │ 7. PostProcessPass │  │     │  │                    │  │
│  └────────────────────┘  │     │  └────────────────────┘  │
└──────────────────────────┘     └──────────────────────────┘
         ↓                                ↓
    RT Shadows                       Shadow Maps
      SSAO                              No SSAO
      Bloom                         Different Bloom
```

---

## RenderGraph Design

### Core Concept: Graph of Passes

```zig
pub const RenderGraph = struct {
    allocator: Allocator,
    scene: *Scene,
    
    // Passes in execution order (after compilation)
    passes: std.ArrayList(*RenderPass),
    
    // Resource registry (render targets, depth buffers, etc)
    resources: ResourceRegistry,
    
    /// Add a pass to the graph
    pub fn addPass(self: *RenderGraph, pass: *RenderPass) !void {
        try self.passes.append(self.allocator, pass);
    }
    
    /// Compile: Build execution order, validate dependencies
    pub fn compile(self: *RenderGraph) !void {
        // TODO: Topological sort based on resource dependencies
        // For now: execute in order added
        log(.INFO, "render_graph", "Compiled graph with {} passes", .{self.passes.items.len});
    }
    
    /// Execute all passes
    pub fn execute(self: *RenderGraph, frame_info: FrameInfo) !void {
        for (self.passes.items) |pass| {
            if (!pass.enabled) continue;
            
            log(.TRACE, "render_graph", "Executing pass: {s}", .{pass.name});
            try pass.execute(frame_info);
        }
    }
    
    pub fn deinit(self: *RenderGraph) void {
        for (self.passes.items) |pass| {
            pass.vtable.teardown(pass);
        }
        self.passes.deinit(self.allocator);
        self.resources.deinit();
    }
};
```

### RenderPass Interface

```zig
pub const RenderPass = struct {
    name: []const u8,
    enabled: bool = true,
    
    // Virtual method table
    vtable: *const VTable,
    
    pub const VTable = struct {
        /// Setup resources, declare dependencies
        setup: *const fn(*RenderPass, *RenderGraph) anyerror!void,
        
        /// Execute the pass
        execute: *const fn(*RenderPass, FrameInfo) anyerror!void,
        
        /// Cleanup
        teardown: *const fn(*RenderPass) void,
    };
};
```

### Example: GeometryPass

```zig
pub const GeometryPass = struct {
    base: RenderPass,
    scene: *Scene,
    pipeline_system: *UnifiedPipelineSystem,
    
    // Resources this pass uses
    color_target: ResourceId,
    depth_buffer: ResourceId,
    
    pub fn create(allocator: Allocator, scene: *Scene, pipeline: *UnifiedPipelineSystem) !*GeometryPass {
        const pass = try allocator.create(GeometryPass);
        pass.* = GeometryPass{
            .base = RenderPass{
                .name = "GeometryPass",
                .enabled = true,
                .vtable = &vtable,
            },
            .scene = scene,
            .pipeline_system = pipeline,
            .color_target = undefined,  // Set during setup
            .depth_buffer = undefined,
        };
        return pass;
    }
    
    const vtable = RenderPass.VTable{
        .setup = setupImpl,
        .execute = executeImpl,
        .teardown = teardownImpl,
    };
    
    fn setupImpl(base: *RenderPass, graph: *RenderGraph) !void {
        const self = @fieldParentPtr(GeometryPass, "base", base);
        
        // Register resources we need
        self.color_target = try graph.resources.createRenderTarget("color", .RGBA16F);
        self.depth_buffer = try graph.resources.getOrCreateDepthBuffer("depth");
        
        log(.INFO, "geometry_pass", "Setup complete", .{});
    }
    
    fn executeImpl(base: *RenderPass, frame_info: FrameInfo) !void {
        const self = @fieldParentPtr(GeometryPass, "base", base);
        
        // Extract renderables from ECS
        var render_system = RenderSystem{ .allocator = self.scene.allocator };
        var render_data = try render_system.extractRenderData(self.scene.ecs_world);
        defer render_data.deinit();
        
        if (render_data.renderables.items.len == 0) return;
        
        // Render each entity (similar to EcsRenderer)
        for (render_data.renderables.items) |renderable| {
            // ... draw logic using pipeline_system ...
        }
        
        log(.TRACE, "geometry_pass", "Rendered {} entities", .{render_data.renderables.items.len});
    }
    
    fn teardownImpl(base: *RenderPass) void {
        const self = @fieldParentPtr(GeometryPass, "base", base);
        self.scene.allocator.destroy(self);
    }
};
```

---

## Migration Path

### Step 1: Keep Both (Parallel Development)

```zig
// app.zig - During transition
var forward_renderer: GenericRenderer = undefined;  // Old
var render_graph: ?RenderGraph = null;              // New

// Use flag to switch
const use_render_graph = true;

if (use_render_graph) {
    try render_graph.?.execute(frame_info);
} else {
    try forward_renderer.render(frame_info);
}
```

### Step 2: Implement Basic RenderGraph

- Create `render_graph.zig`
- Create `GeometryPass` (replaces EcsRenderer)
- Create `LightingPass` (replaces PointLightRenderer)
- Test that objects render correctly

### Step 3: Remove GenericRenderer

- Delete `generic_renderer.zig`
- Delete individual renderers (TexturedRenderer, EcsRenderer, etc.)
- Keep particle renderer (moves to compute pass)
- Keep raytracing renderer (moves to RT pass)

### Step 4: Add Advanced Passes

- DepthPrepass
- ShadowPass (multiple techniques)
- SSAOPass
- TransparencyPass
- PostProcessPass

---

## Benefits Summary

### For Scene System
- ✅ Each scene defines its own rendering pipeline
- ✅ Easy to switch techniques (RT vs shadow maps)
- ✅ Can test different pipelines without code changes

### For Performance
- ✅ Only execute needed passes
- ✅ Explicit resource dependencies (better GPU sync)
- ✅ Easier to optimize (profiling per-pass)

### For Development
- ✅ Industry standard (familiar to game devs)
- ✅ Modular (easy to add new passes)
- ✅ Testable (test individual passes)
- ✅ Debuggable (visualize graph execution)

### For Features
- ✅ Per-scene quality settings
- ✅ Dynamic pipeline reconfiguration
- ✅ Editor integration (visual graph editor)
- ✅ Hot-reload of individual passes

---

## Implementation Timeline

**This Session:**
1. Create basic RenderGraph infrastructure
2. Create GeometryPass (replaces EcsRenderer logic)
3. Create LightingPass (replaces PointLightRenderer logic)
4. Update app.zig to use RenderGraph
5. Remove GenericRenderer usage
6. Verify rendering works

**Next Session:**
1. Add DepthPrepass
2. Add ShadowPass with RT + shadow maps
3. Add TransparencyPass
4. Add PostProcessPass
5. Resource management system

**Future:**
1. Automatic pass ordering (topological sort)
2. RenderGraph serialization (save/load pipelines)
3. Visual graph editor in ImGui
4. Performance profiling per-pass

---

## Technical Notes

### Resource Management

Resources (render targets, depth buffers) are tracked by the graph:

```zig
pub const ResourceRegistry = struct {
    render_targets: std.StringHashMap(RenderTarget),
    depth_buffers: std.StringHashMap(DepthBuffer),
    
    pub fn createRenderTarget(self: *ResourceRegistry, name: []const u8, format: vk.Format) !ResourceId;
    pub fn getOrCreateDepthBuffer(self: *ResourceRegistry, name: []const u8) !ResourceId;
    pub fn getResource(self: *ResourceRegistry, id: ResourceId) Resource;
};
```

### Pass Dependencies

Future enhancement - passes declare dependencies:

```zig
// LightingPass depends on GeometryPass color output
const lighting_pass = try LightingPass.create(...);
lighting_pass.addInputDependency(geometry_pass.color_target);

// Graph automatically orders passes based on dependencies
try render_graph.compile();  // Topological sort
```

### Multi-Scene Rendering

Can execute multiple scene graphs per frame:

```zig
// Main world
try main_world_scene.render_graph.execute(frame_info);

// Picture-in-picture minimap
try minimap_scene.render_graph.execute(minimap_frame_info);

// UI overlay
try ui_scene.render_graph.execute(ui_frame_info);
```

---

**This design gives us the flexibility to have completely different rendering pipelines per scene while maintaining clean, modular code!** 🚀
