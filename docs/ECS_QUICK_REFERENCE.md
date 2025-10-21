# ECS Quick Reference Card

## Initialization

```zig
const ecs = @import("ecs.zig");

// Create World
var world = ecs.World.init(allocator, &thread_pool);
defer world.deinit();

// Register components (required before use)
try world.registerComponent(ecs.Transform);
try world.registerComponent(ecs.MeshRenderer);
try world.registerComponent(ecs.Camera);

// Initialize systems
var transform_system = ecs.TransformSystem.init(allocator);
defer transform_system.deinit();

var render_system = ecs.RenderSystem.init(allocator);
defer render_system.deinit();
```

## Entity Management

```zig
// Create
const entity = try world.createEntity();

// Destroy
world.destroyEntity(entity);
```

## Component Operations

```zig
// Add component
const transform = ecs.Transform.initWithPosition(.{ .x = 0, .y = 1, .z = 0 });
try world.emplace(ecs.Transform, entity, transform);

// Get component (returns ?*T)
if (world.get(ecs.Transform, entity)) |transform| {
    transform.translate(.{ .x = 1, .y = 0, .z = 0 });
}

// Remove component
world.remove(ecs.Transform, entity);
```

## Component Initialization

```zig
// Transform
Transform.init()                              // Identity transform
Transform.initWithPosition(pos)               // At position
Transform.initFull(pos, rot, scale)          // Full specification

// MeshRenderer
MeshRenderer.init(model_id, material_id)      // Basic
MeshRenderer.initWithTexture(m, mat, tex)    // With texture override
MeshRenderer.initModelOnly(model_id)          // Model only

// Camera
Camera.init()                                 // Default perspective
Camera.initPerspective(fov, aspect, n, f)    // Custom perspective
Camera.initOrthographic(l, r, b, t, n, f)    // Orthographic
```

## Component Methods

### Transform

```zig
// Modification
transform.translate(offset: Vec3)
transform.rotate(euler: Vec3)
transform.scale(factor: Vec3)
transform.setParent(parent_entity: ?EntityId)

// Queries
transform.hasParent() -> bool
transform.getLocalMatrix() -> Mat4
transform.updateWorldMatrix()

// Properties
.position: Vec3
.rotation: Vec3  // radians
.scale: Vec3
.parent: ?EntityId
.world_matrix: Mat4
.dirty: bool
```

### MeshRenderer

```zig
// Modification
renderer.setModel(asset_id: AssetId)
renderer.setMaterial(asset_id: AssetId)
renderer.setTexture(asset_id: ?AssetId)
renderer.setEnabled(enabled: bool)
renderer.setLayer(layer: u8)

// Queries
renderer.hasValidAssets() -> bool
renderer.getTextureAsset() -> ?AssetId

// Properties
.model_asset: ?AssetId
.material_asset: ?AssetId
.texture_asset: ?AssetId
.enabled: bool
.layer: u8  // 0-255
.casts_shadows: bool
.receives_shadows: bool
```

### Camera

```zig
// Modification
camera.setPerspective(fov, aspect, near, far)
camera.setOrthographic(l, r, b, t, near, far)
camera.setFov(fov: f32)
camera.setAspectRatio(ratio: f32)
camera.setClipPlanes(near, far: f32)
camera.setPrimary(is_primary: bool)

// Queries
camera.getProjectionMatrix() -> Mat4x4

// Properties
.projection_type: ProjectionType  // .perspective or .orthographic
.fov: f32  // degrees
.aspect_ratio: f32
.near_plane: f32
.far_plane: f32
.is_primary: bool
.projection_matrix: Mat4x4
.projection_dirty: bool
```

## System Updates

```zig
// Update transforms (handles hierarchies)
try transform_system.update(&world);

// Extract render data
var render_data = try render_system.extractRenderData(&world);
defer render_data.deinit();

// Use render data
if (render_data.camera) |cam| {
    // cam.projection_matrix: Mat4x4
    // cam.view_matrix: Mat4x4
    // cam.position: Vec3
}

for (render_data.renderables.items) |renderable| {
    // renderable.model_asset: AssetId
    // renderable.material_asset: ?AssetId
    // renderable.texture_asset: ?AssetId
    // renderable.world_matrix: Mat4x4
    // renderable.layer: u8
    // renderable.casts_shadows: bool
    // renderable.receives_shadows: bool
}
```

## Queries

```zig
// Create view
var view = try world.view(ecs.Transform);

// Iterate
var iter = view.iterator();
while (iter.next()) |entry| {
    const entity = entry.entity;      // EntityId
    const component = entry.component; // *Transform
    
    component.translate(.{ .x = 0.1, .y = 0, .z = 0 });
}

// Each callback
view.each(struct {
    pub fn call(entity: EntityId, component: *Transform) void {
        component.translate(.{ .x = 0.1, .y = 0, .z = 0 });
    }
}.call);

// Parallel each (with ThreadPool)
try view.each_parallel(struct {
    pub fn call(entity: EntityId, component: *Transform) void {
        component.translate(.{ .x = 0.1, .y = 0, .z = 0 });
    }
}.call, thread_pool);
```

## Common Patterns

### Create Renderable Entity

```zig
const entity = try world.createEntity();

const transform = ecs.Transform.initWithPosition(.{ .x = 0, .y = 1, .z = 0 });
try world.emplace(ecs.Transform, entity, transform);

const renderer = ecs.MeshRenderer.init(model_id, material_id);
try world.emplace(ecs.MeshRenderer, entity, renderer);
```

### Parent-Child Hierarchy

```zig
// Create parent
const parent = try world.createEntity();
const parent_transform = ecs.Transform.init();
try world.emplace(ecs.Transform, parent, parent_transform);

// Create child
const child = try world.createEntity();
var child_transform = ecs.Transform.init();
child_transform.setParent(parent);
try world.emplace(ecs.Transform, child, child_transform);

// Update hierarchy
try transform_system.update(&world);
```

### Camera Setup

```zig
const camera_entity = try world.createEntity();

const transform = ecs.Transform.initWithPosition(.{ .x = 0, .y = 5, .z = 10 });
try world.emplace(ecs.Transform, camera_entity, transform);

var camera = ecs.Camera.initPerspective(60.0, 16.0/9.0, 0.1, 1000.0);
camera.setPrimary(true);
try world.emplace(ecs.Camera, camera_entity, camera);
```

### Toggle Visibility

```zig
if (world.get(ecs.MeshRenderer, entity)) |renderer| {
    renderer.setEnabled(!renderer.enabled);
}
```

### Change Material

```zig
if (world.get(ecs.MeshRenderer, entity)) |renderer| {
    renderer.setMaterial(new_material_id);
}
```

### Move Entity

```zig
if (world.get(ecs.Transform, entity)) |transform| {
    transform.translate(.{ .x = dt * speed, .y = 0, .z = 0 });
}
```

### Rotate Entity

```zig
if (world.get(ecs.Transform, entity)) |transform| {
    transform.rotate(.{ .x = 0, .y = dt * angular_speed, .z = 0 });
}
```

## Type Reference

```zig
// Core types
EntityId = enum(u32) { invalid = 0, _ }
AssetId = enum(u64) { invalid = 0, _ }

// Math types
Vec3 = struct { x: f32, y: f32, z: f32 }
Mat4 = struct { data: [16]f32 }
Mat4x4 = Mat4

// Component protocols
pub fn update(self: *Component, dt: f32) void
pub fn render(self: *const Component, context: RenderContext) void
```

## Performance Tips

- ✅ Use dirty flags (Transform, Camera)
- ✅ Batch entity operations
- ✅ Use parallel dispatch for independent updates
- ✅ Layer-based sorting (not manual)
- ✅ Minimize component add/remove per frame
- ✅ ArenaAllocator for temporary data

## Common Errors

### Component Not Registered
```zig
// ❌ Wrong
var view = try world.view(ecs.Transform);

// ✅ Correct - register first
try world.registerComponent(ecs.Transform);
var view = try world.view(ecs.Transform);
```

### Wrong AssetId Creation
```zig
// ❌ Wrong
const asset_id = AssetId.init(1);

// ✅ Correct
const asset_id: AssetId = @enumFromInt(1);
```

### ArrayList Initialization (Zig 0.15)
```zig
// ❌ Wrong
var list = std.ArrayList(T).init(allocator);

// ✅ Correct
var list: std.ArrayList(T) = .{};
defer list.deinit(allocator);
try list.append(allocator, item);
```

### View Cleanup
```zig
// ✅ Views don't need deinit
var view = try world.view(ecs.Transform);
// No defer needed
```

## Update Loop Template

```zig
pub fn update(self: *App, dt: f32) !void {
    // 1. Update input/game logic
    self.processInput(dt);
    
    // 2. Update ECS transforms
    try self.transform_system.update(&self.ecs_world);
    
    // 3. Optional: Update individual components
    // try self.ecs_world.update(ecs.ParticleComponent, dt);
}
```

## Render Loop Template

```zig
pub fn render(self: *App) !void {
    // 1. Extract render data
    var render_data = try self.render_system.extractRenderData(&self.ecs_world);
    defer render_data.deinit();
    
    // 2. Setup camera
    const cam = render_data.camera orelse self.default_camera;
    
    // 3. Begin frame
    try self.renderer.beginFrame();
    self.renderer.beginSwapchainRenderPass(command_buffer);
    
    // 4. Render entities (sorted by layer)
    for (render_data.renderables.items) |renderable| {
        const model = self.asset_manager.getModel(renderable.model_asset);
        try self.generic_renderer.render(frame_info, model, null, .{
            .modelMatrix = renderable.world_matrix,
        });
    }
    
    // 5. End frame
    self.renderer.endSwapchainRenderPass(command_buffer);
    try self.renderer.endFrame();
}
```

## Status: ✅ All 65 Tests Passing

```bash
zig test src/ecs.zig
```
