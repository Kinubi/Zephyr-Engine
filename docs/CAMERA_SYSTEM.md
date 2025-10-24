# Camera System

**Last Updated**: October 24, 2025  
**Status**: ✅ Complete

## Overview

The Camera System provides both legacy Camera class functionality and ECS-integrated camera components. It supports perspective and orthographic projections, view matrix calculations, and keyboard-based movement controls. The system includes a KeyboardMovementController for WASD + arrow key navigation.

## Architecture

```
┌──────────────────────────────────────────────┐
│          Camera System                       │
└──────────────────────────────────────────────┘
                      │
        ┌─────────────┼─────────────┐
        ▼             ▼             ▼
┌──────────────┐ ┌──────────────┐ ┌──────────────┐
│ Legacy       │ │ ECS          │ │ Movement     │
│ Camera       │ │ Camera       │ │ Controller   │
│              │ │              │ │              │
│ • View       │ │ • Component  │ │ • WASD       │
│ • Projection │ │ • Primary    │ │ • Arrows     │
│ • Matrices   │ │ • FOV        │ │ • Delta-time │
└──────────────┘ └──────────────┘ └──────────────┘
```

## Core Components

### Legacy Camera (Camera.zig)

Standalone camera class with matrix calculations.

```zig
pub const Camera = struct {
    projectionMatrix: Math.Mat4x4,
    viewMatrix: Math.Mat4x4,
    inverseViewMatrix: Math.Mat4x4,
    
    nearPlane: f32 = 0.1,
    farPlane: f32 = 100.0,
    fov: f32 = 45.0,  // degrees
    aspectRatio: f32 = 16.0 / 9.0,
    window: Window,
    
    // Projection setup
    pub fn setPerspectiveProjection(self: *Camera, fovy: f32, aspect: f32, near: f32, far: f32) void;
    pub fn setOrthographicProjection(self: *Camera, left: f32, right: f32, top: f32, bottom: f32, near: f32, far: f32) void;
    pub fn updateProjectionMatrix(self: *Camera) void;
    
    // View matrix setup
    pub fn setViewDirection(self: *Camera, position: Vec3, direction: Vec3, up: Vec3) void;
    pub fn setViewTarget(self: *Camera, position: Vec3, target: Vec3, up: Vec3) void;
    pub fn setViewYXZ(self: *Camera, position: Vec3, rotation: Vec3) void;
};
```

**Features**:
- Perspective and orthographic projections
- Multiple view matrix calculation methods
- Inverse view matrix for world-space calculations
- Vulkan-compatible depth range [0, 1]

### ECS Camera Component

Lightweight camera component for entity-based cameras.

```zig
pub const Camera = struct {
    fov: f32 = 45.0,              // Field of view (degrees)
    aspect_ratio: f32 = 16.0 / 9.0,
    near_plane: f32 = 0.1,
    far_plane: f32 = 100.0,
    is_primary: bool = false,     // Primary camera for rendering
    
    // Projection matrix (calculated by CameraSystem)
    projection_matrix: Math.Mat4x4 = Math.Mat4x4.identity(),
};
```

**Features**:
- Integrated with ECS Transform component
- Primary camera flag for multi-camera scenes
- Automatic matrix calculation via system updates

### KeyboardMovementController

Direct camera manipulation via keyboard input.

```zig
pub const KeyboardMovementController = struct {
    move_speed: f32 = 3.0,
    look_speed: f32 = 1.5,
    
    position: Math.Vec3,
    rotation: Math.Vec3,  // pitch, yaw, roll
    
    pub fn init() KeyboardMovementController;
    pub fn processInput(self: *Self, window: *Window, camera: *Camera, dt: f64) void;
};
```

**Controls**:
- **WASD**: Move forward/backward/left/right
- **Space**: Move down
- **Ctrl**: Move up
- **Arrow Keys**: Rotate camera (pitch/yaw)

**Features**:
- Delta-time based movement (frame-rate independent)
- Normalized input (diagonal movement is same speed)
- Pitch clamping (prevents gimbal lock)
- Smooth rotation and movement

## Usage

### Legacy Camera Setup

```zig
// Create camera
var camera = Camera{
    .window = window,
};

// Set up perspective projection
camera.setPerspectiveProjection(
    Math.radians(45.0),  // FOV in radians
    16.0 / 9.0,          // Aspect ratio
    0.1,                 // Near plane
    100.0,               // Far plane
);

// Position camera
const position = Math.Vec3.init(0, 0, 5);
const target = Math.Vec3.init(0, 0, 0);
const up = Math.Vec3.init(0, 1, 0);
camera.setViewTarget(position, target, up);

// Or use rotation-based positioning
const rotation = Math.Vec3.init(0, 0, 0);  // pitch, yaw, roll
camera.setViewYXZ(position, rotation);
```

### ECS Camera Setup

```zig
const world = &scene.ecs_world;

// Create camera entity
const camera_entity = world.createEntity();

try world.emplace(ecs.Transform, camera_entity, .{
    .position = .{ 0.0, 0.0, 5.0 },
});

try world.emplace(ecs.Camera, camera_entity, .{
    .fov = 45.0,
    .aspect_ratio = 16.0 / 9.0,
    .near_plane = 0.1,
    .far_plane = 100.0,
    .is_primary = true,  // Mark as primary rendering camera
});
```

### Keyboard Controller Setup

```zig
// Create controller
var controller = KeyboardMovementController.init();

// In update loop
fn update(dt: f64) void {
    controller.processInput(&window, &camera, dt);
    
    // Camera matrices are automatically updated
    // Use camera.viewMatrix and camera.projectionMatrix for rendering
}
```

### Finding Primary Camera (ECS)

```zig
pub fn findPrimaryCamera(world: *World) ?EntityId {
    var view = world.view(.{Camera});
    var iter = view.iterator();
    
    while (iter.next()) |entity| {
        const camera = world.get(Camera, entity).?;
        if (camera.is_primary) {
            return entity;
        }
    }
    return null;
}

// Get camera matrices
if (findPrimaryCamera(world)) |camera_entity| {
    const transform = world.get(Transform, camera_entity).?;
    const camera = world.get(Camera, camera_entity).?;
    
    // Build view matrix from transform
    const view_matrix = Math.Mat4x4.lookAt(
        transform.position,
        Math.Vec3.add(transform.position, transform.forward()),
        Math.Vec3.init(0, 1, 0),
    );
}
```

## View Matrix Modes

### 1. View Direction

Specify camera position and look direction directly.

```zig
camera.setViewDirection(
    Math.Vec3.init(0, 2, 5),   // Position
    Math.Vec3.init(0, 0, -1),  // Direction (forward)
    Math.Vec3.init(0, 1, 0),   // Up vector
);
```

**Use Case**: Fixed direction cameras (e.g., side-scrollers)

### 2. View Target

Point camera at a specific world position.

```zig
camera.setViewTarget(
    Math.Vec3.init(0, 2, 5),   // Camera position
    Math.Vec3.init(0, 0, 0),   // Look-at target
    Math.Vec3.init(0, 1, 0),   // Up vector
);
```

**Use Case**: Orbit cameras, cinematic cameras

### 3. View YXZ (Euler Angles)

Use Euler angles for FPS-style cameras.

```zig
camera.setViewYXZ(
    Math.Vec3.init(0, 2, 5),   // Position
    Math.Vec3.init(0, Math.pi / 4, 0),  // Rotation (pitch, yaw, roll)
);
```

**Use Case**: First-person cameras, free-look cameras (used by KeyboardMovementController)

## Projection Modes

### Perspective Projection

Standard 3D perspective with field of view.

```zig
camera.setPerspectiveProjection(
    Math.radians(45.0),  // Vertical FOV (radians)
    16.0 / 9.0,          // Aspect ratio
    0.1,                 // Near clipping plane
    100.0,               // Far clipping plane
);
```

**Use Case**: Most 3D rendering (FPS, third-person, etc.)

### Orthographic Projection

Parallel projection without perspective.

```zig
camera.setOrthographicProjection(
    -10.0,  // Left
    10.0,   // Right
    10.0,   // Top
    -10.0,  // Bottom
    0.1,    // Near
    100.0,  // Far
);
```

**Use Case**: 2D games, UI, CAD applications

## Matrix Details

### View Matrix

Transforms world space → camera space.

```
[  Ux  Uy  Uz  -dot(U, P) ]
[  Vx  Vy  Vz  -dot(V, P) ]
[  Wx  Wy  Wz  -dot(W, P) ]
[  0   0   0       1      ]
```

Where:
- **U**: Right vector
- **V**: Up vector
- **W**: Forward vector
- **P**: Camera position

### Inverse View Matrix

Transforms camera space → world space.

```
[  Ux  Vx  Wx  Px ]
[  Uy  Vy  Wy  Py ]
[  Uz  Vz  Wz  Pz ]
[  0   0   0   1  ]
```

**Use Case**: Extracting camera position/rotation, ray casting

### Projection Matrix (Perspective)

Vulkan-compatible perspective projection with Z ∈ [0, 1].

```
[  1/(aspect*tan(fov/2))    0                0                    0              ]
[  0                        1/tan(fov/2)     0                    0              ]
[  0                        0                far/(far-near)       1              ]
[  0                        0                -(far*near)/(far-near)  0          ]
```

## Input Handling Patterns

### Simple Free Camera

```zig
var controller = KeyboardMovementController.init();

while (!window.shouldClose()) {
    const dt = timer.lap();
    
    // Process input
    controller.processInput(&window, &camera, dt);
    
    // Render with updated camera
    render(camera);
}
```

### Multi-Camera Switching

```zig
var cameras = [_]Camera{ camera1, camera2, camera3 };
var active_index: usize = 0;

if (input.keyPressed(.C)) {
    active_index = (active_index + 1) % cameras.len;
}

controller.processInput(&window, &cameras[active_index], dt);
```

### Custom Movement Speed

```zig
var controller = KeyboardMovementController.init();
controller.move_speed = 10.0;  // Faster movement
controller.look_speed = 2.5;   // Faster rotation

// Sprint mode
if (c.glfwGetKey(window.window, c.GLFW_KEY_LEFT_SHIFT) == c.GLFW_PRESS) {
    const old_speed = controller.move_speed;
    controller.move_speed *= 2.0;  // Double speed
    controller.processInput(&window, &camera, dt);
    controller.move_speed = old_speed;
}
```

## Integration Points

### With RenderSystem

```zig
// Extract camera from ECS
pub fn extractCameraData(world: *World) ?CameraData {
    if (findPrimaryCamera(world)) |camera_entity| {
        const transform = world.get(Transform, camera_entity).?;
        const camera = world.get(Camera, camera_entity).?;
        
        return CameraData{
            .view_matrix = calculateViewMatrix(transform),
            .projection_matrix = camera.projection_matrix,
            .position = transform.position,
        };
    }
    return null;
}
```

### With FrameInfo

```zig
pub const FrameInfo = struct {
    frame_index: u32,
    delta_time: f32,
    command_buffer: vk.CommandBuffer,
    camera: *Camera,  // Legacy camera
    // ... other fields
};

// Build frame info
const frame_info = FrameInfo{
    .camera = &camera,
    // ...
};
```

### With GlobalUBO

```zig
pub const GlobalUbo = extern struct {
    projection: Math.Mat4x4,
    view: Math.Mat4x4,
    inverse_view: Math.Mat4x4,
    camera_position: [4]f32,
    // ...
};

// Update UBO from camera
ubo.projection = camera.projectionMatrix;
ubo.view = camera.viewMatrix;
ubo.inverse_view = camera.inverseViewMatrix;
ubo.camera_position = .{ camera_pos.x, camera_pos.y, camera_pos.z, 1.0 };
```

## Performance Considerations

### Matrix Recalculation

- **View matrix**: Recalculate only when position/rotation changes
- **Projection matrix**: Recalculate only when FOV/aspect changes
- **Cache results**: Avoid recalculating every frame if static

### Input Polling

- Keyboard polling is lightweight (~0.01ms)
- Process input once per frame, not per system
- Use delta-time for frame-rate independence

### Multiple Cameras

| Camera Count | CPU Overhead | Memory Usage | Notes                          |
|--------------|--------------|--------------|--------------------------------|
| 1            | Negligible   | ~256 bytes   | Single main camera             |
| 2-5          | Low          | ~1 KB        | Multi-viewport, minimap        |
| 10+          | Medium       | ~5 KB        | Security cameras, replays      |

## Troubleshooting

### Camera Not Moving

**Symptoms**: Keyboard input doesn't affect camera

**Solutions**:
1. Check `controller.processInput()` is called each frame
2. Verify `dt` (delta time) is > 0
3. Ensure window has focus
4. Check `move_speed` and `look_speed` are non-zero

### Upside-Down Rendering

**Symptoms**: Scene is flipped vertically

**Solutions**:
1. Check Y-axis direction in view matrix calculation
2. Verify up vector is `(0, 1, 0)` not `(0, -1, 0)`
3. Ensure viewport is configured correctly

### Jittery Movement

**Symptoms**: Camera movement stutters or jerks

**Solutions**:
1. Use delta-time (`dt`) for frame-rate independence
2. Normalize movement direction before scaling
3. Check for floating-point precision issues
4. Profile frame time variance

### Gimbal Lock

**Symptoms**: Camera rotation behaves strangely near vertical

**Solutions**:
1. Clamp pitch angle (already done in KeyboardMovementController):
   ```zig
   self.rotation.x = std.math.clamp(self.rotation.x, -1.5, 1.5);
   ```
2. Use quaternions for complex rotations (future enhancement)

## Future Enhancements

### Planned

- **Smooth Camera**: Interpolated movement and rotation
- **Orbit Camera**: Rotate around a target point
- **Path Camera**: Follow predefined spline paths
- **Shake/Wobble**: Camera shake effects

### Under Consideration

- **Quaternion Rotation**: Avoid gimbal lock entirely
- **Mouse Look**: Direct mouse input for rotation
- **Camera Constraints**: Limit movement to specific areas
- **Multiple Primary Cameras**: Split-screen support

## References

- **Implementation**: 
  - `src/rendering/camera.zig` (Legacy camera)
  - `src/ecs/components/camera.zig` (ECS component)
  - `src/keyboard_movement_controller.zig` (Input controller)
- **Related Docs**: 
  - [ECS System](ECS_SYSTEM.md)
  - [Scene System](SCENE_SYSTEM.md)
  - [RenderGraph System](RENDER_GRAPH_SYSTEM.md)

---

*Last Updated: October 24, 2025*
