# ECS Integration Guide

This guide shows how to integrate the ECS system into your rendering loop.

## Phase 2 ECS Foundation - Complete ✅

All components and systems are implemented and tested (62 tests passing).

### Components Available

- **Transform**: Position, rotation, scale with parent-child hierarchy
- **MeshRenderer**: References Model/Material/Texture via AssetId
- **Camera**: Perspective/orthographic projection with primary flag
- **ParticleComponent**: GPU compute particle system

### Systems Available

- **TransformSystem**: Updates hierarchical transforms
- **RenderSystem**: Extracts rendering data from entities

## Integration Example

### 1. Setup in App Initialization

```zig
const ecs = @import("ecs.zig");

pub const App = struct {
    // ... existing fields ...
    
    // ECS components
    ecs_world: ecs.World,
    transform_system: ecs.TransformSystem,
    render_system: ecs.RenderSystem,
    
    pub fn init(allocator: std.mem.Allocator) !App {
        // Initialize ECS World with ThreadPool
        var ecs_world = ecs.World.init(allocator, &thread_pool);
        errdefer ecs_world.deinit();
        
        // Register all components
        try ecs_world.registerComponent(ecs.Transform);
        try ecs_world.registerComponent(ecs.MeshRenderer);
        try ecs_world.registerComponent(ecs.Camera);
        
        // Initialize systems
        const transform_system = ecs.TransformSystem.init(allocator);
        const render_system = ecs.RenderSystem.init(allocator);
        
        return App{
            // ... existing initialization ...
            .ecs_world = ecs_world,
            .transform_system = transform_system,
            .render_system = render_system,
        };
    }
    
    pub fn deinit(self: *App) void {
        self.transform_system.deinit();
        self.render_system.deinit();
        self.ecs_world.deinit();
        // ... existing cleanup ...
    }
};
```

### 2. Creating ECS Entities

```zig
// Create a camera entity
pub fn createCamera(self: *App, fov: f32, aspect: f32) !ecs.EntityId {
    const entity = try self.ecs_world.createEntity();
    
    // Add Transform component
    const transform = ecs.Transform.initWithPosition(.{ 
        .x = 0, .y = 5, .z = 10 
    });
    try self.ecs_world.emplace(ecs.Transform, entity, transform);
    
    // Add Camera component
    var camera = ecs.Camera.initPerspective(fov, aspect, 0.1, 1000.0);
    camera.setPrimary(true); // Make this the active camera
    try self.ecs_world.emplace(ecs.Camera, entity, camera);
    
    return entity;
}

// Create a renderable entity (e.g., a viking room model)
pub fn createRenderable(
    self: *App, 
    model_id: AssetId, 
    material_id: AssetId,
    position: math.Vec3
) !ecs.EntityId {
    const entity = try self.ecs_world.createEntity();
    
    // Add Transform component
    const transform = ecs.Transform.initWithPosition(position);
    try self.ecs_world.emplace(ecs.Transform, entity, transform);
    
    // Add MeshRenderer component
    const renderer = ecs.MeshRenderer.init(model_id, material_id);
    try self.ecs_world.emplace(ecs.MeshRenderer, entity, renderer);
    
    return entity;
}

// Create a hierarchical entity (child of parent)
pub fn createChild(
    self: *App,
    parent_entity: ecs.EntityId,
    model_id: AssetId,
    local_offset: math.Vec3
) !ecs.EntityId {
    const entity = try self.ecs_world.createEntity();
    
    // Add Transform with parent relationship
    var transform = ecs.Transform.initWithPosition(local_offset);
    transform.setParent(parent_entity);
    try self.ecs_world.emplace(ecs.Transform, entity, transform);
    
    // Add MeshRenderer
    const renderer = ecs.MeshRenderer.init(model_id, null);
    try self.ecs_world.emplace(ecs.MeshRenderer, entity, renderer);
    
    return entity;
}
```

### 3. Update Loop Integration

```zig
pub fn update(self: *App, dt: f32) !void {
    // Update keyboard/mouse input (existing code)
    self.keyboard_controller.moveInPlaneXZ(
        self.window.window, 
        dt, 
        &self.viewer_object
    );
    
    // Update ECS transforms (handles parent-child hierarchies)
    try self.transform_system.update(&self.ecs_world);
    
    // Update individual components if needed
    // try self.ecs_world.update(ecs.Transform, dt);
    
    // Update camera entity transform if controlled by player
    if (self.player_camera_entity) |camera_entity| {
        if (self.ecs_world.get(ecs.Transform, camera_entity)) |transform| {
            // Apply viewer_object transform to camera
            transform.position = self.viewer_object.transform.translation;
            transform.rotation = self.viewer_object.transform.rotation;
            transform.dirty = true;
        }
    }
}
```

### 4. Render Loop Integration

```zig
pub fn render(self: *App, frame_idx: usize) !void {
    // ... existing frame setup ...
    
    // Extract rendering data from ECS
    var render_data = try self.render_system.extractRenderData(&self.ecs_world);
    defer render_data.deinit();
    
    // Set up camera from ECS (if available)
    const camera_data = if (render_data.camera) |cam| cam else blk: {
        // Fallback to existing camera if no ECS camera found
        break :blk ecs.RenderSystem.CameraData{
            .projection_matrix = self.camera.projectionMatrix,
            .view_matrix = self.camera.viewMatrix,
            .position = self.viewer_object.transform.translation,
        };
    };
    
    var frame_info = FrameInfo{
        .frameIndex = frame_idx,
        .frameTime = self.frame_time,
        .commandBuffer = command_buffer,
        .camera = .{
            .viewMatrix = camera_data.view_matrix,
            .projectionMatrix = camera_data.projection_matrix,
        },
        .globalDescriptorSet = global_descriptor_sets[frame_idx],
    };
    
    // Begin frame (existing code)
    try self.renderer.beginFrame();
    
    // Begin render pass
    self.renderer.beginSwapchainRenderPass(command_buffer);
    
    // Render ECS entities
    for (render_data.renderables.items) |renderable| {
        // Get Model from Asset Manager
        const model = self.asset_manager.getModel(renderable.model_asset);
        if (model == null) continue;
        
        // Get Material (if specified)
        const material = if (renderable.material_asset) |mat_id|
            self.asset_manager.getMaterial(mat_id)
        else
            null;
        
        // Use GenericRenderer to draw
        const push_data = SimplePushConstantData{
            .modelMatrix = renderable.world_matrix,
            .normalMatrix = renderable.world_matrix.normal3x3(),
        };
        
        try self.generic_renderer.render(
            frame_info,
            model.?,
            material,
            push_data,
        );
    }
    
    // Render existing GameObjects (for backward compatibility)
    try self.simple_render_system.renderGameObjects(frame_info, &self.game_objects);
    
    // ... rest of render pass ...
}
```

### 5. Practical Scene Setup Example

```zig
pub fn setupScene(self: *App) !void {
    // Load assets
    const viking_model = try self.asset_manager.loadModel("models/viking_room.obj");
    const viking_material = try self.asset_manager.loadMaterial("materials/viking_room.mat");
    const cube_model = try self.asset_manager.loadModel("models/colored_cube.obj");
    
    // Create main camera
    const camera = try self.createCamera(50.0, self.renderer.getAspectRatio());
    self.player_camera_entity = camera;
    
    // Create ground plane
    _ = try self.createRenderable(
        viking_model,
        viking_material,
        math.Vec3.init(0, 0, 0)
    );
    
    // Create parent entity (e.g., a spaceship)
    const spaceship = try self.createRenderable(
        cube_model,
        null,
        math.Vec3.init(0, 2, 0)
    );
    
    // Create children (e.g., wings attached to spaceship)
    _ = try self.createChild(
        spaceship,
        cube_model,
        math.Vec3.init(-2, 0, 0) // Left wing
    );
    
    _ = try self.createChild(
        spaceship,
        cube_model,
        math.Vec3.init(2, 0, 0) // Right wing
    );
    
    // Rotate parent - children will follow automatically
    if (self.ecs_world.get(ecs.Transform, spaceship)) |transform| {
        transform.rotate(math.Vec3.init(0, math.radians(45.0), 0));
    }
}
```

### 6. Runtime Entity Manipulation

```zig
// Toggle renderer visibility
pub fn toggleEntityVisibility(self: *App, entity: ecs.EntityId) void {
    if (self.ecs_world.get(ecs.MeshRenderer, entity)) |renderer| {
        renderer.setEnabled(!renderer.enabled);
    }
}

// Move entity
pub fn moveEntity(self: *App, entity: ecs.EntityId, offset: math.Vec3) void {
    if (self.ecs_world.get(ecs.Transform, entity)) |transform| {
        transform.translate(offset);
    }
}

// Change entity's material at runtime
pub fn setEntityMaterial(self: *App, entity: ecs.EntityId, material_id: AssetId) void {
    if (self.ecs_world.get(ecs.MeshRenderer, entity)) |renderer| {
        renderer.setMaterial(material_id);
    }
}

// Switch to different camera
pub fn setActiveCamera(self: *App, camera_entity: ecs.EntityId) !void {
    // Disable all cameras
    var view = try self.ecs_world.view(ecs.Camera);
    var iter = view.iterator();
    while (iter.next()) |entry| {
        entry.component.setPrimary(false);
    }
    
    // Enable specified camera
    if (self.ecs_world.get(ecs.Camera, camera_entity)) |camera| {
        camera.setPrimary(true);
    }
}
```

## Performance Characteristics

### ECS System Performance (62 tests passing)

- **Transform Component**: Dirty flag optimization prevents unnecessary matrix recalculation
- **MeshRenderer**: Zero-copy asset references via AssetId
- **Camera**: Lazy projection matrix calculation
- **TransformSystem**: Two-pass hierarchy update (O(n) where n = entity count)
- **RenderSystem**: Single-pass extraction with layer sorting
- **ThreadPool Integration**: Parallel component updates via `world.update()`

### Memory Usage

- **EntityId**: 4 bytes (enum(u32) with generational index)
- **Transform**: ~136 bytes (Vec3 × 3 + Mat4 + parent + flags)
- **MeshRenderer**: ~24 bytes (3 AssetIds + flags)
- **Camera**: ~76 bytes (settings + Mat4x4 + flags)

### Recommended Entity Counts

- **Transform only**: 10,000+ entities
- **Transform + MeshRenderer**: 1,000-5,000 entities
- **Complex hierarchies**: 100-500 entity chains

## Migration Strategy

### Phase 1: Parallel Systems ✅ (Current)
Keep both GameObject and ECS systems running side-by-side.

### Phase 2: Gradual Migration
- New features use ECS exclusively
- Slowly migrate existing GameObjects to ECS entities
- Keep both render paths active

### Phase 3: Full ECS (Future)
- Remove GameObject system entirely
- Pure ECS architecture
- Optimize for cache coherency

## Known Limitations & TODOs

1. **Matrix Inverse**: Camera view matrix needs proper inverse calculation
2. **Multi-camera**: Only one primary camera supported currently
3. **Frustum Culling**: Not yet implemented in RenderSystem
4. **LOD System**: Not yet integrated with MeshRenderer
5. **Animation**: No animation component yet

## Next Steps

1. Add matrix inverse to math.zig for proper camera view matrices
2. Implement frustum culling in RenderSystem
3. Add CameraSystem for automatic aspect ratio updates
4. Create AnimationComponent for skeletal/keyframe animation
5. Implement spatial partitioning (octree/BVH) for large scenes

## Testing

All 62 tests pass:
- 22 Core ECS tests
- 5 ParticleComponent tests
- 7 Transform tests
- 8 MeshRenderer tests
- 12 Camera tests
- 3 TransformSystem tests
- 5 RenderSystem tests

Run tests:
```bash
zig test src/ecs.zig
```

Build application:
```bash
zig build
```
