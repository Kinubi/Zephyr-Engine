# Scene-ECS Integration Design

**Goal**: Refactor Scene to be a high-level "level builder" API on top of the ECS, providing Unity-like convenience while leveraging ECS performance.

**Status**: Design Phase → Implementation  
**Date**: 21 October 2025

---

## Vision: Scene as Game Level

### Mental Model
```
Scene = Level/Map in a game
├── Spawns game objects (props, characters, lights)
├── Manages object lifecycle (creation, destruction)
├── Provides convenient API (Unity-like)
├── Owns RenderGraph (defines how scene renders)
└── All data stored in ECS (performance, flexibility)
```

### Current vs New Architecture

**Current (Dual System):**
```
Scene (GameObject array) ────→ TexturedRenderer
    ↓
SceneBridge ────→ Material/Texture management
    
ECS World (separate) ────→ RenderSystem ────→ EcsRenderer

GenericRenderer (global)
├── TexturedRenderer
├── EcsRenderer
├── PointLightRenderer
└── ParticleRenderer
```

**New (Unified via ECS + RenderGraph):**
```
Scene (high-level API)
    ↓
Creates ECS Entities with Components
    ↓
GameObject (handle to entity)
    ↓
ECS World (single source of truth)
    ↓
Scene.RenderGraph (scene-specific pipeline)
    ├── DepthPrepass (optional)
    ├── GeometryPass (ECS entities)
    ├── ShadowPass (RT or shadow maps)
    ├── LightingPass
    ├── TransparencyPass
    └── PostProcessing
    ↓
Vulkan
```

**GenericRenderer is REPLACED by per-scene RenderGraph**

---

## Core Design Principles

1. **Scene is a Builder** - Convenience API for creating game objects
2. **GameObject is a Handle** - Lightweight wrapper around EntityId
3. **ECS is Storage** - All actual data lives in components
4. **RenderGraph per Scene** - Each scene defines its own rendering pipeline
5. **Composable Render Passes** - Build complex pipelines from simple passes
6. **Unity-like API** - Familiar patterns for game developers

---

## RenderGraph Design

### What is a RenderGraph?

A **RenderGraph** is a directed acyclic graph (DAG) of rendering operations:
- **Nodes** = Render passes (geometry, shadows, lighting, post-process)
- **Edges** = Data dependencies (render targets, depth buffers)
- **Execution** = Automatic ordering based on dependencies

### Why RenderGraph over GenericRenderer?

**GenericRenderer Problems:**
- Global renderer processes all scenes the same way
- Hard-coded execution order
- Can't have per-scene rendering techniques
- No explicit resource dependencies

**RenderGraph Benefits:**
- ✅ Each scene defines its own pipeline
- ✅ Automatic pass ordering based on dependencies
- ✅ Resource management (render targets, depth buffers)
- ✅ Easy to add/remove passes
- ✅ Scene can choose: RT shadows OR shadow maps OR no shadows
- ✅ Industry standard (Unreal, Unity HDRP, Frostbite)

### RenderGraph Architecture

```zig
pub const RenderGraph = struct {
    allocator: Allocator,
    scene: *Scene,
    
    // Render passes in execution order
    passes: std.ArrayList(*RenderPass),
    
    // Resource management
    resources: ResourceRegistry,
    
    pub fn init(allocator: Allocator, scene: *Scene) RenderGraph;
    
    /// Add a render pass to the graph
    pub fn addPass(self: *RenderGraph, pass: *RenderPass) !void;
    
    /// Build execution order (topological sort of dependencies)
    pub fn compile(self: *RenderGraph) !void;
    
    /// Execute all passes in order
    pub fn execute(self: *RenderGraph, frame_info: FrameInfo) !void;
    
    pub fn deinit(self: *RenderGraph) void;
};

/// Base render pass interface
pub const RenderPass = struct {
    name: []const u8,
    enabled: bool = true,
    
    // Virtual methods (implemented by specific passes)
    vtable: *const VTable,
    
    pub const VTable = struct {
        setup: *const fn(*RenderPass, *RenderGraph) anyerror!void,
        execute: *const fn(*RenderPass, FrameInfo) anyerror!void,
        teardown: *const fn(*RenderPass) void,
    };
    
    pub fn setup(self: *RenderPass, graph: *RenderGraph) !void {
        return self.vtable.setup(self, graph);
    }
    
    pub fn execute(self: *RenderPass, frame_info: FrameInfo) !void {
        return self.vtable.execute(self, frame_info);
    }
};
```

### Specific Render Passes

```zig
// Depth prepass - early Z testing
pub const DepthPrepass = struct {
    base: RenderPass,
    depth_buffer: ResourceId,
    
    pub fn create(allocator: Allocator) !*DepthPrepass;
};

// Main geometry pass - render opaque objects
pub const GeometryPass = struct {
    base: RenderPass,
    color_target: ResourceId,
    depth_buffer: ResourceId,  // Reads from depth prepass if available
    scene: *Scene,
    
    pub fn create(allocator: Allocator, scene: *Scene) !*GeometryPass;
};

// Shadow pass - raytraced or shadow maps
pub const ShadowPass = struct {
    base: RenderPass,
    technique: ShadowTechnique,
    shadow_map: ?ResourceId,  // For shadow maps
    scene: *Scene,
    
    pub const ShadowTechnique = enum {
        ShadowMaps,
        Raytraced,
        None,
    };
    
    pub fn create(allocator: Allocator, scene: *Scene, technique: ShadowTechnique) !*ShadowPass;
};

// Lighting pass - apply lights with shadows
pub const LightingPass = struct {
    base: RenderPass,
    color_target: ResourceId,
    shadow_info: ?ResourceId,  // From shadow pass
    scene: *Scene,
    
    pub fn create(allocator: Allocator, scene: *Scene) !*LightingPass;
};

// SSAO pass
pub const SSAOPass = struct {
    base: RenderPass,
    depth_buffer: ResourceId,
    normal_buffer: ResourceId,
    ao_buffer: ResourceId,
    
    pub fn create(allocator: Allocator) !*SSAOPass;
};

// Transparency pass - sorted back-to-front
pub const TransparencyPass = struct {
    base: RenderPass,
    color_target: ResourceId,
    depth_buffer: ResourceId,
    scene: *Scene,
    
    pub fn create(allocator: Allocator, scene: *Scene) !*TransparencyPass;
};

// Post-processing (bloom, tone mapping, etc)
pub const PostProcessPass = struct {
    base: RenderPass,
    input_color: ResourceId,
    output_color: ResourceId,
    enable_bloom: bool = true,
    enable_tone_mapping: bool = true,
    
    pub fn create(allocator: Allocator) !*PostProcessPass;
};
```

---

## API Design

### Scene Class

```zig
pub const Scene = struct {
    ecs_world: *World,              // Reference to ECS world
    asset_manager: *AssetManager,   // For loading assets
    allocator: Allocator,
    name: []const u8,                // "Level 1", "Boss Arena", etc.
    
    // Track entities spawned in this scene (for cleanup)
    entities: std.ArrayList(EntityId),
    
    /// Initialize a scene with a name
    pub fn init(allocator: Allocator, ecs_world: *World, asset_manager: *AssetManager, name: []const u8) Scene;
    
    /// Spawn a static prop (mesh only)
    pub fn spawnProp(
        self: *Scene,
        model_path: []const u8,
        texture_path: []const u8,
    ) !*GameObject;
    
    /// Spawn a character (mesh + future: physics, AI)
    pub fn spawnCharacter(
        self: *Scene,
        model_path: []const u8,
        texture_path: []const u8,
    ) !*GameObject;
    
    /// Spawn a point light
    pub fn spawnLight(self: *Scene, light_type: LightType) !*GameObject;
    
    /// Spawn an empty object (just Transform)
    pub fn spawnEmpty(self: *Scene, name: []const u8) !*GameObject;
    
    /// Load scene from file (future)
    pub fn load(allocator: Allocator, ecs_world: *World, asset_manager: *AssetManager, path: []const u8) !Scene;
    
    /// Save scene to file (future)
    pub fn save(self: *Scene, path: []const u8) !void;
    
    /// Unload scene - destroys all entities
    pub fn unload(self: *Scene) void;
    
    /// Deinit - cleanup
    pub fn deinit(self: *Scene) void;
};
```

### GameObject Class

```zig
pub const GameObject = struct {
    entity_id: EntityId,
    scene: *Scene,
    
    // ===== Transform Operations =====
    pub fn setPosition(self: *GameObject, pos: Vec3) !void;
    pub fn setRotation(self: *GameObject, rot: Vec3) !void;
    pub fn setScale(self: *GameObject, scale: Vec3) !void;
    
    pub fn getPosition(self: *GameObject) !Vec3;
    pub fn getRotation(self: *GameObject) !Vec3;
    pub fn getWorldMatrix(self: *GameObject) !Mat4x4;
    
    pub fn translate(self: *GameObject, delta: Vec3) !void;
    pub fn rotate(self: *GameObject, delta: Vec3) !void;
    
    // ===== Component Access =====
    pub fn getComponent(self: *GameObject, comptime T: type) !*T;
    pub fn addComponent(self: *GameObject, comptime T: type, component: T) !void;
    pub fn hasComponent(self: *GameObject, comptime T: type) bool;
    pub fn removeComponent(self: *GameObject, comptime T: type) !void;
    
    // Convenience accessors
    pub fn getTransform(self: *GameObject) !*Transform;
    pub fn getMeshRenderer(self: *GameObject) !*MeshRenderer;
    pub fn getCamera(self: *GameObject) !*Camera;
    
    // ===== Hierarchy =====
    pub fn setParent(self: *GameObject, parent: ?*GameObject) !void;
    pub fn getParent(self: *GameObject) !?EntityId;
    pub fn getChildren(self: *GameObject) ![]EntityId; // Future
    
    // ===== Lifecycle =====
    pub fn destroy(self: *GameObject) !void;
    pub fn isValid(self: *GameObject) bool;
};
```

---

## Implementation Phases

### Phase 1: Scene Refactor + Basic RenderGraph (This Session)
**Goal**: Scene creates ECS entities, basic RenderGraph replaces GenericRenderer

**Tasks**:
- [x] Create design document
- [x] Create scene_v2.zig (Scene with ECS)
- [ ] Create game_object.zig (GameObject wrapper)
- [ ] Create render_graph.zig (RenderGraph infrastructure)
- [ ] Create basic render passes:
  - [ ] GeometryPass (renders ECS entities)
  - [ ] LightingPass (point lights)
- [ ] Update app.zig to use Scene v2 + RenderGraph
- [ ] Remove GenericRenderer usage
- [ ] Test that scene objects render

**Files to Create**:
- `src/scene/scene_v2.zig` ✅ (created)
- `src/scene/game_object.zig` (pending)
- `src/rendering/render_graph.zig` (pending)
- `src/rendering/passes/geometry_pass.zig` (pending)
- `src/rendering/passes/lighting_pass.zig` (pending)

**Files to Change**:
- `src/app.zig` (use RenderGraph instead of GenericRenderer)

**Expected Outcome**: 
- Scene creates ECS entities
- RenderGraph executes passes
- Objects render correctly
- GenericRenderer removed

---

### Phase 2: Advanced Render Passes (Next Session)
**Goal**: Add more rendering techniques

**Tasks**:
- [ ] Implement DepthPrepass
- [ ] Implement ShadowPass (shadow maps + RT)
- [ ] Implement SSAOPass
- [ ] Implement TransparencyPass
- [ ] Implement PostProcessPass (bloom, tone mapping)
- [ ] Resource management in RenderGraph
- [ ] Automatic dependency resolution

**Files to Create**:
- `src/rendering/passes/depth_prepass.zig`
- `src/rendering/passes/shadow_pass.zig`
- `src/rendering/passes/ssao_pass.zig`
- `src/rendering/passes/transparency_pass.zig`
- `src/rendering/passes/post_process_pass.zig`

**Expected Outcome**: 
- Full featured render pipeline
- Per-scene technique selection
- Advanced rendering effects

---

### Phase 3: Scene Serialization & Editor (Future)
**Goal**: Save/load scenes, visual editor

**Tasks**:
- [ ] Scene save/load to JSON
- [ ] Prefab system
- [ ] ImGui scene inspector
- [ ] Hierarchy view
- [ ] Component editor
- [ ] RenderGraph visualizer

**Expected Outcome**: 
- Complete scene management
- Editor tooling

---

## Migration Strategy

### Backward Compatibility
Keep old scene.zig temporarily:
```zig
// Old code still works
const old_scene = @import("scene/scene.zig");

// New code uses v2
const Scene = @import("scene/scene_v2.zig");
```

### Gradual Migration
1. Create Scene v2 alongside Scene v1
2. Test that both work simultaneously
3. Migrate app.zig to use Scene v2
4. Remove Scene v1 when confident

---

## Example Usage (After Implementation)

### Creating a Dungeon Level with RenderGraph

```zig
// ===== Scene Setup =====
var dungeon = Scene.init(allocator, ecs_world, asset_manager, "Dungeon Level 1");
defer dungeon.deinit();

// Spawn level geometry
const floor = try dungeon.spawnProp("models/floor.obj", "textures/stone.png");
try floor.setPosition(Vec3.init(0, 0, 0));
try floor.setScale(Vec3.init(10, 1, 10));

const wall = try dungeon.spawnProp("models/wall.obj", "textures/brick.png");
try wall.setPosition(Vec3.init(0, 0, 5));

const orc = try dungeon.spawnCharacter("models/orc.obj", "textures/orc_skin.png");
try orc.setPosition(Vec3.init(3, 0, 3));

const torch = try dungeon.spawnProp("models/torch.obj", "textures/torch.png");
try torch.setPosition(Vec3.init(-3, 2, 3));

// ===== Build RenderGraph (Dungeon-specific pipeline) =====
var render_graph = RenderGraph.init(allocator, &dungeon);
defer render_graph.deinit();

// Depth prepass for better performance
const depth_prepass = try DepthPrepass.create(allocator);
try render_graph.addPass(&depth_prepass.base);

// Main geometry
const geometry_pass = try GeometryPass.create(allocator, &dungeon);
try render_graph.addPass(&geometry_pass.base);

// Raytraced shadows (dungeon is indoors, RT looks great)
const shadow_pass = try ShadowPass.create(allocator, &dungeon, .Raytraced);
try render_graph.addPass(&shadow_pass.base);

// Lighting with RT shadows
const lighting_pass = try LightingPass.create(allocator, &dungeon);
try render_graph.addPass(&lighting_pass.base);

// SSAO for depth
const ssao_pass = try SSAOPass.create(allocator);
try render_graph.addPass(&ssao_pass.base);

// Transparency (torches, particles)
const transparency_pass = try TransparencyPass.create(allocator, &dungeon);
try render_graph.addPass(&transparency_pass.base);

// Post-processing (bloom for torches)
const post_process = try PostProcessPass.create(allocator);
post_process.enable_bloom = true;
try render_graph.addPass(&post_process.base);

// Compile the graph (orders passes, validates dependencies)
try render_graph.compile();

// ===== Game Loop =====
while (running) {
    // Update ECS systems
    try transform_system.update(ecs_world);
    
    // Execute render graph for this scene
    try render_graph.execute(frame_info);
}
```

### Creating an Outdoor Level (Different Pipeline)

```zig
// ===== Outdoor Scene =====
var forest = Scene.init(allocator, ecs_world, asset_manager, "Forest");
defer forest.deinit();

// Spawn outdoor objects
const tree = try forest.spawnProp("models/tree.obj", "textures/bark.png");
const grass = try forest.spawnProp("models/grass.obj", "textures/grass.png");

// ===== Build DIFFERENT RenderGraph =====
var render_graph = RenderGraph.init(allocator, &forest);
defer render_graph.deinit();

// NO depth prepass (not worth it for outdoor with many transparent objects)

// Main geometry
const geometry_pass = try GeometryPass.create(allocator, &forest);
try render_graph.addPass(&geometry_pass.base);

// Shadow MAPS instead of RT (outdoor is huge, shadow maps better)
const shadow_pass = try ShadowPass.create(allocator, &forest, .ShadowMaps);
try render_graph.addPass(&shadow_pass.base);

// Lighting
const lighting_pass = try LightingPass.create(allocator, &forest);
try render_graph.addPass(&lighting_pass.base);

// NO SSAO (outdoor doesn't benefit much)

// Transparency (grass, leaves)
const transparency_pass = try TransparencyPass.create(allocator, &forest);
try render_graph.addPass(&transparency_pass.base);

// Post-processing (different settings)
const post_process = try PostProcessPass.create(allocator);
post_process.enable_bloom = false;  // Natural lighting
try render_graph.addPass(&post_process.base);

try render_graph.compile();

// Execute
try render_graph.execute(frame_info);
```

### Level Switching

```zig
// Unload current scene (destroys entities + render graph)
current_scene.deinit();

// Load new scene with different render pipeline
var boss_arena = try createBossArena(allocator, ecs_world, asset_manager);
// Boss arena might have: RT reflections, volumetric lighting, etc.
```

---

## Technical Details

### GameObject Lifetime
- **Created**: `Scene.spawnX()` allocates GameObject, stores in scene
- **Tracked**: EntityId stored in scene.entities array
- **Destroyed**: Either `gameobject.destroy()` or `scene.unload()`

### Component Access Pattern
```zig
// Option 1: Get component directly
const transform = try gameobject.getComponent(Transform);
transform.position = new_pos;

// Option 2: Convenience accessor
try gameobject.setPosition(new_pos);  // Internally gets Transform component
```

### Memory Management
```zig
Scene owns:
- entities: ArrayList(EntityId)  // For cleanup
- Maybe: gameobjects: ArrayList(*GameObject)  // For returning stable pointers

GameObject:
- Allocated by Scene
- Freed by Scene.unload() or gameobject.destroy()
- Just stores entity_id + scene pointer (small)
```

### Entity Cleanup
```zig
pub fn unload(self: *Scene) void {
    // Destroy all entities in reverse order (handle dependencies)
    var i = self.entities.items.len;
    while (i > 0) {
        i -= 1;
        self.ecs_world.destroyEntity(self.entities.items[i]) catch |err| {
            log(.WARN, "scene", "Failed to destroy entity: {}", .{err});
        };
    }
    self.entities.clearRetainingCapacity();
}
```

---

## Testing Plan

### Unit Tests
- [ ] Scene.spawnProp() creates entity with correct components
- [ ] GameObject.setPosition() updates Transform component
- [ ] Scene.unload() destroys all entities
- [ ] GameObject component access methods work correctly

### Integration Tests
- [ ] Scene objects render via EcsRenderer
- [ ] Transform hierarchy propagates correctly
- [ ] Material and texture bindings work
- [ ] Multiple scenes can be loaded/unloaded

### Validation
- [ ] All 65 ECS tests still pass
- [ ] Build succeeds without warnings
- [ ] Application runs and renders scene objects
- [ ] No memory leaks (valgrind check)

---

## Benefits Summary

### For Game Development
- ✅ Unity-like API (`spawnProp`, `setPosition`, etc.)
- ✅ Scene management (load/unload levels)
- ✅ Hierarchy support (parent-child relationships)
- ✅ Component flexibility (add any component to objects)

### For Engine Architecture
- ✅ Single source of truth (ECS)
- ✅ Single rendering path (EcsRenderer only)
- ✅ Data-oriented (cache-friendly)
- ✅ Queryable (find all objects with component X)
- ✅ Extensible (add new systems easily)

### For Performance
- ✅ ECS iteration (fast)
- ✅ No GameObject array duplication
- ✅ Better cache locality
- ✅ Parallel system processing (ThreadPool)

---

## Risks & Mitigation

### Risk: Breaking Existing Code
**Mitigation**: Keep scene.zig, create scene_v2.zig, migrate gradually

### Risk: GameObject Pointer Stability
**Mitigation**: Store GameObjects in ArrayList, return pointers from there

### Risk: Complex Hierarchy Management
**Mitigation**: Start simple (basic parent-child), enhance later

### Risk: Performance Regression
**Mitigation**: Benchmark before/after, profile rendering path

---

## Next Steps

1. **Create scene_v2.zig** with basic Scene struct
2. **Create game_object.zig** with GameObject wrapper
3. **Implement spawnProp()** - minimal viable implementation
4. **Update app.zig** to create test scene using Scene v2
5. **Verify rendering** - objects should appear via EcsRenderer
6. **Iterate** - add more spawn methods, improve API

**Let's start implementation! 🚀**
