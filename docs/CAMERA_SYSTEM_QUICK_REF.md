# Camera System Quick Reference

## Creating a Camera (Legacy)

```zig
var camera = Camera{
    .window = window,
};

// Perspective projection
camera.setPerspectiveProjection(
    Math.radians(45.0),  // FOV
    16.0 / 9.0,          // Aspect ratio
    0.1,                 // Near
    100.0,               // Far
);
```

## Creating a Camera (ECS)

```zig
const camera_entity = world.createEntity();

try world.emplace(ecs.Transform, camera_entity, .{
    .position = .{ 0.0, 0.0, 5.0 },
});

try world.emplace(ecs.Camera, camera_entity, .{
    .fov = 45.0,
    .is_primary = true,
});
```

## Keyboard Controls

```zig
var controller = KeyboardMovementController.init();

// In update loop
controller.processInput(&window, &camera, dt);
```

### Controls

| Key          | Action       |
|--------------|--------------|
| W            | Forward      |
| S            | Backward     |
| A            | Left         |
| D            | Right        |
| Space        | Down         |
| Ctrl         | Up           |
| Arrow Up     | Pitch Up     |
| Arrow Down   | Pitch Down   |
| Arrow Left   | Yaw Left     |
| Arrow Right  | Yaw Right    |

## View Matrix Modes

```zig
// 1. Direction-based
camera.setViewDirection(position, direction, up);

// 2. Target-based
camera.setViewTarget(position, target, up);

// 3. Euler angles (used by controller)
camera.setViewYXZ(position, rotation);
```

## Finding Primary Camera

```zig
pub fn findPrimaryCamera(world: *World) ?EntityId {
    var view = world.view(.{Camera});
    var iter = view.iterator();
    while (iter.next()) |entity| {
        const camera = world.get(Camera, entity).?;
        if (camera.is_primary) return entity;
    }
    return null;
}
```

## Adjusting Movement Speed

```zig
var controller = KeyboardMovementController.init();
controller.move_speed = 10.0;  // Faster
controller.look_speed = 2.5;   // More sensitive rotation
```

## See Also

- [Camera System](CAMERA_SYSTEM.md) - Full documentation
- [ECS System](ECS_SYSTEM.md) - Component management
- [Scene System](SCENE_SYSTEM.md) - Entity management
