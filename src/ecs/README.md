# ECS Module - Entity Component System

**Status**: ✅ Production Ready - All 65 tests passing

A high-performance, type-safe entity-component-system implementation for ZulkanZengine.

## Quick Start

```zig
const ecs = @import("ecs.zig");

// Initialize world
var world = ecs.World.init(allocator, &thread_pool);
defer world.deinit();

// Register components
try world.registerComponent(ecs.Transform);
try world.registerComponent(ecs.MeshRenderer);
try world.registerComponent(ecs.Camera);

// Create entity
const entity = try world.createEntity();

// Add components
const transform = ecs.Transform.initWithPosition(.{ .x = 0, .y = 1, .z = 0 });
try world.emplace(ecs.Transform, entity, transform);

const renderer = ecs.MeshRenderer.init(model_id, material_id);
try world.emplace(ecs.MeshRenderer, entity, renderer);

// Initialize systems
var transform_system = ecs.TransformSystem.init(allocator);
var render_system = ecs.RenderSystem.init(allocator);

// Update loop
try transform_system.update(&world);

// Render loop
var render_data = try render_system.extractRenderData(&world);
defer render_data.deinit();
```

## Architecture

### Core Components

```
World (Central ECS Manager)
  ├── EntityRegistry (Entity lifecycle)
  ├── DenseSet<T> (Component storage)
  └── View<T> (Component queries)
```

### Available Components

- **Transform**: Position, rotation, scale with parent-child hierarchies
- **MeshRenderer**: References models/materials via AssetId
- **Camera**: Perspective/orthographic projection with primary flag
- **ParticleComponent**: GPU compute particle system

### Available Systems

- **TransformSystem**: Hierarchical transform updates
- **RenderSystem**: Extracts rendering data from entities

## Features

### Type Safety
- `EntityId` is `enum(u32)` with generational indices
- `AssetId` is `enum(u64)` for asset references
- Compile-time component type checking

### Performance
- **Dirty Flags**: Components only recalculate when changed
- **Packed Storage**: Cache-friendly iteration with DenseSet
- **Parallel Dispatch**: ThreadPool integration for multi-threaded updates
- **Layer Sorting**: Efficient render order management

### Memory Efficiency
- Zero-copy asset references (4-8 bytes per ID)
- Generational entity IDs (4 bytes)
- Optional relationships (no overhead when unused)

## Component Details

### Transform Component

Manages spatial transformations with hierarchical relationships.

```zig
// Create transform
var transform = ecs.Transform.initWithPosition(.{ .x = 1, .y = 2, .z = 3 });

// Modify transform
transform.translate(.{ .x = 0.1, .y = 0, .z = 0 });
transform.rotate(.{ .x = 0, .y = math.radians(45), .z = 0 });
transform.scale(.{ .x = 2, .y = 2, .z = 2 });

// Parent-child hierarchy
child_transform.setParent(parent_entity);

// Check if transform changed
if (transform.dirty) {
    transform.updateWorldMatrix();
}
```

**Fields:**
- `position: Vec3` - Local position
- `rotation: Vec3` - Euler angles (radians)
- `scale: Vec3` - Local scale
- `parent: ?EntityId` - Optional parent entity
- `world_matrix: Mat4` - Cached world transform
- `dirty: bool` - Needs recalculation flag

### MeshRenderer Component

References renderable assets and controls visibility.

```zig
// Create renderer
var renderer = ecs.MeshRenderer.init(model_id, material_id);

// With texture override
var renderer = ecs.MeshRenderer.initWithTexture(model_id, material_id, texture_id);

// Runtime changes
renderer.setEnabled(false); // Hide
renderer.setLayer(5); // Change render order
renderer.setMaterial(new_material_id); // Swap material
renderer.casts_shadows = false; // Disable shadow casting
```

**Fields:**
- `model_asset: ?AssetId` - Model reference
- `material_asset: ?AssetId` - Material reference
- `texture_asset: ?AssetId` - Optional texture override
- `enabled: bool` - Visibility flag
- `layer: u8` - Render sorting (0-255)
- `casts_shadows: bool` - Shadow casting
- `receives_shadows: bool` - Shadow receiving

### Camera Component

Manages projection and view matrices.

```zig
// Perspective camera
var camera = ecs.Camera.initPerspective(60.0, 16.0/9.0, 0.1, 1000.0);

// Orthographic camera
var camera = ecs.Camera.initOrthographic(-10, 10, -10, 10, 0.1, 100);

// Set as active camera
camera.setPrimary(true);

// Modify settings
camera.setFov(75.0);
camera.setAspectRatio(21.0 / 9.0);
camera.setClipPlanes(0.01, 500.0);

// Get projection matrix (auto-updates if dirty)
const proj = camera.getProjectionMatrix();
```

**Fields:**
- `projection_type: ProjectionType` - Perspective or Orthographic
- `fov: f32` - Field of view (degrees)
- `aspect_ratio: f32` - Width/height ratio
- `near_plane: f32` - Near clip distance
- `far_plane: f32` - Far clip distance
- `is_primary: bool` - Active camera flag
- `projection_matrix: Mat4x4` - Cached matrix
- `projection_dirty: bool` - Needs recalculation

## System Details

### TransformSystem

Updates hierarchical transforms in two passes:

1. **Dirty Pass**: Recalculate local→world matrices for changed transforms
2. **Hierarchy Pass**: Propagate parent transforms to children

```zig
var system = ecs.TransformSystem.init(allocator);
defer system.deinit();

// Update all transforms
try system.update(&world);
```

**Performance**: O(n) where n = number of entities with Transform component

### RenderSystem

Extracts rendering data for GPU submission:

```zig
var system = ecs.RenderSystem.init(allocator);
defer system.deinit();

// Extract all renderables and camera
var render_data = try system.extractRenderData(&world);
defer render_data.deinit();

// Use camera
if (render_data.camera) |cam| {
    // cam.projection_matrix
    // cam.view_matrix
    // cam.position
}

// Render entities (sorted by layer)
for (render_data.renderables.items) |renderable| {
    const model = asset_manager.getModel(renderable.model_asset);
    renderer.draw(model, renderable.world_matrix);
}
```

**Features:**
- Queries entities with MeshRenderer (+ optional Transform)
- Finds primary Camera (+ optional Transform)
- Sorts renderables by layer (0-255)
- Filters disabled entities
- Returns ready-to-render data structures

## Workflow Examples

### Creating a Hierarchical Scene

```zig
// Create parent (spaceship)
const spaceship = try world.createEntity();
const parent_transform = ecs.Transform.initWithPosition(.{ .x = 0, .y = 2, .z = 0 });
try world.emplace(ecs.Transform, spaceship, parent_transform);

const renderer = ecs.MeshRenderer.init(spaceship_model, spaceship_material);
try world.emplace(ecs.MeshRenderer, spaceship, renderer);

// Create left wing (child)
const left_wing = try world.createEntity();
var wing_transform = ecs.Transform.initWithPosition(.{ .x = -3, .y = 0, .z = 0 });
wing_transform.setParent(spaceship); // Attach to parent
try world.emplace(ecs.Transform, left_wing, wing_transform);

const wing_renderer = ecs.MeshRenderer.init(wing_model, wing_material);
try world.emplace(ecs.MeshRenderer, left_wing, wing_renderer);

// Rotate parent - children follow automatically
if (world.get(ecs.Transform, spaceship)) |t| {
    t.rotate(.{ .x = 0, .y = math.radians(45), .z = 0 });
}

try transform_system.update(&world);
```

### Runtime Entity Manipulation

```zig
// Toggle visibility
if (world.get(ecs.MeshRenderer, entity)) |renderer| {
    renderer.setEnabled(!renderer.enabled);
}

// Move entity
if (world.get(ecs.Transform, entity)) |transform| {
    transform.translate(.{ .x = 1, .y = 0, .z = 0 });
}

// Change material
if (world.get(ecs.MeshRenderer, entity)) |renderer| {
    renderer.setMaterial(new_material_id);
}

// Switch active camera
var camera_view = try world.view(ecs.Camera);
var iter = camera_view.iterator();
while (iter.next()) |entry| {
    entry.component.setPrimary(entry.entity == target_camera);
}
```

### Multi-Camera Setup

```zig
// Main camera
const main_cam = try world.createEntity();
var camera1 = ecs.Camera.initPerspective(60.0, 16.0/9.0, 0.1, 1000.0);
camera1.setPrimary(true);
try world.emplace(ecs.Camera, main_cam, camera1);

// Minimap camera (orthographic)
const minimap_cam = try world.createEntity();
var camera2 = ecs.Camera.initOrthographic(-50, 50, -50, 50, 0.1, 500);
camera2.setPrimary(false);
try world.emplace(ecs.Camera, minimap_cam, camera2);

// Later: switch cameras
if (world.get(ecs.Camera, minimap_cam)) |cam| {
    cam.setPrimary(true);
}
if (world.get(ecs.Camera, main_cam)) |cam| {
    cam.setPrimary(false);
}
```

## Performance Characteristics

### Tested Entity Counts

| Scenario | Entity Count | Performance |
|----------|--------------|-------------|
| Transform only | 10,000+ | < 1ms update |
| Transform + MeshRenderer | 1,000-5,000 | Typical games |
| Deep hierarchies | 100-500 | Complex scenes |
| Test suite | 1,000 | < 10ms (full cycle) |

### Memory Footprint

| Type | Size | Notes |
|------|------|-------|
| EntityId | 4 bytes | enum(u32) |
| Transform | ~136 bytes | 3×Vec3 + Mat4 + parent + flags |
| MeshRenderer | ~24 bytes | 3×AssetId + flags |
| Camera | ~76 bytes | Settings + Mat4 + flags |

### ThreadPool Integration

- **Workers**: 8 threads (configurable)
- **Subsystem**: `ecs_update` (min: 2, max: 8)
- **Parallel Updates**: `world.update(Component, dt)` with `each_parallel()`

## Testing

**65 comprehensive tests** covering all functionality:

```bash
# Run all ECS tests
zig test src/ecs.zig

# Run with specific subsystems
zig test src/ecs.zig --test-filter "Transform"
zig test src/ecs.zig --test-filter "RenderSystem"
```

### Test Coverage

- Core ECS (22 tests): EntityRegistry, DenseSet, View, World
- ParticleComponent (5 tests): Lifecycle, rendering, GPU compute
- Transform (7 tests): Init, setters, hierarchy, matrices
- MeshRenderer (8 tests): Init, setters, validation, extraction
- Camera (12 tests): Projections, settings, primary flag
- TransformSystem (3 tests): Update, hierarchy, multiple children
- RenderSystem (5 tests): Extraction, sorting, filtering
- Workflow (3 tests): Complete scene, performance, runtime changes

## Integration

See **docs/ECS_INTEGRATION_GUIDE.md** for complete integration examples.

### Quick Integration Checklist

1. ✅ Initialize World with ThreadPool
2. ✅ Register all components
3. ✅ Create entities and add components
4. ✅ Initialize systems (Transform, Render)
5. ✅ Update loop: `transform_system.update(&world)`
6. ✅ Render loop: `render_system.extractRenderData(&world)`
7. ✅ Feed extracted data to GenericRenderer

## API Reference

### World API

```zig
// Entity management
pub fn createEntity(self: *World) !EntityId
pub fn destroyEntity(self: *World, entity: EntityId) void

// Component management
pub fn registerComponent(self: *World, comptime T: type) !void
pub fn emplace(self: *World, comptime T: type, entity: EntityId, component: T) !void
pub fn get(self: *World, comptime T: type, entity: EntityId) ?*T
pub fn remove(self: *World, comptime T: type, entity: EntityId) void

// Queries
pub fn view(self: *World, comptime T: type) !View(T)

// Bulk operations
pub fn update(self: *World, comptime T: type, dt: f32) !void
pub fn render(self: *World, comptime T: type, context: anytype) !void
```

### View API

```zig
// Iteration
pub fn iterator(self: *View(T)) Iterator
pub fn each(self: *View(T), func: anytype) void
pub fn each_parallel(self: *View(T), func: anytype, thread_pool: *ThreadPool) !void
```

## Best Practices

### Component Design
- Keep components data-focused (no logic)
- Use dirty flags for expensive calculations
- Prefer composition over inheritance

### System Design
- Systems contain logic, not data
- One system per responsibility
- Update order matters (Transform before Render)

### Performance Tips
- Use parallel dispatch for independent updates
- Batch entity creation/destruction
- Minimize component adds/removes per frame
- Use layers for render sorting, not manual ordering

### Memory Management
- World owns all entities and components
- Systems are lightweight coordinators
- Use ArenaAllocator for temporary render data

## Future Enhancements

### Planned Features
- [ ] Matrix inverse for proper camera view transforms
- [ ] Frustum culling in RenderSystem
- [ ] CameraSystem for automatic aspect ratio updates
- [ ] AnimationComponent for skeletal/keyframe animation
- [ ] LODComponent for level-of-detail management
- [ ] Spatial partitioning (Octree/BVH)
- [ ] PhysicsComponent integration
- [ ] ScriptComponent for runtime behavior

### Optimization Opportunities
- [ ] Archetype-based storage for better cache locality
- [ ] Sparse sets for rare components
- [ ] Entity relationships (beyond parent-child)
- [ ] Component groups for batch operations
- [ ] Multi-threaded system execution

## License

Part of ZulkanZengine - October 2025
