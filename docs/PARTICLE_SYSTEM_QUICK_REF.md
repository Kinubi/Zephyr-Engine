# Particle System Quick Reference

## Creating a Particle Emitter

```zig
const world = &scene.ecs_world;
const entity = world.createEntity();

// Add transform
try world.emplace(ecs.Transform, entity, .{
    .position = .{ 0.0, 2.0, 0.0 },
});

// Add particle emitter
try world.emplace(ecs.ParticleEmitter, entity, .{
    .emit_rate = 50.0,              // 50 particles/sec
    .max_particles = 500,           // Capacity
    .particle_lifetime = 2.0,       // Seconds
    .initial_velocity = .{ 0.0, 5.0, 0.0 },
    .velocity_variation = .{ 2.0, 1.0, 2.0 },
    .color = .{ 1.0, 0.5, 0.2, 1.0 },  // RGBA
    .size = 0.1,
    .active = true,
});
```

## Runtime Control

```zig
// Get emitter
var emitter = world.get(ParticleEmitter, entity).?;

// Toggle emission
emitter.active = !emitter.active;

// Change emission rate
emitter.emit_rate = 100.0;

// Change color
emitter.color = .{ 0.2, 0.5, 1.0, 1.0 };  // Blue

// Change velocity
emitter.initial_velocity = .{ 0.0, 10.0, 0.0 };  // Faster upward
```

## Setting Up Passes

```zig
// 1. Create compute pass
var particle_compute = try ParticleComputePass.create(
    allocator,
    graphics_context,
    pipeline_system,
    &scene.ecs_world,
    max_particles,    // e.g., 10000
    max_emitters,     // e.g., 32
);

// 2. Create render pass
var particle_pass = try ParticlePass.create(
    allocator,
    graphics_context,
    pipeline_system,
    global_ubo_set,
    swapchain_color_format,
    swapchain_depth_format,
    max_particles,
);

// 3. Link passes
particle_pass.compute_pass = particle_compute;

// 4. Add to render graph (ORDER MATTERS!)
try render_graph.addPass(&particle_compute.base);  // Compute first
try render_graph.addPass(&particle_pass.base);     // Render second
```

## Common Patterns

### Fire Effect
```zig
.emit_rate = 100.0,
.particle_lifetime = 1.0,
.initial_velocity = .{ 0.0, 3.0, 0.0 },
.velocity_variation = .{ 0.5, 0.5, 0.5 },
.color = .{ 1.0, 0.4, 0.0, 1.0 },  // Orange
.size = 0.15,
```

### Smoke Effect
```zig
.emit_rate = 30.0,
.particle_lifetime = 3.0,
.initial_velocity = .{ 0.0, 1.0, 0.0 },
.velocity_variation = .{ 1.0, 0.5, 1.0 },
.color = .{ 0.3, 0.3, 0.3, 0.5 },  // Gray, semi-transparent
.size = 0.3,
```

### Fountain Effect
```zig
.emit_rate = 200.0,
.particle_lifetime = 2.0,
.initial_velocity = .{ 0.0, 10.0, 0.0 },
.velocity_variation = .{ 2.0, 2.0, 2.0 },
.color = .{ 0.2, 0.6, 1.0, 1.0 },  // Blue water
.size = 0.05,
```

### Explosion Effect
```zig
.emit_rate = 1000.0,  // Burst of particles
.particle_lifetime = 0.5,
.initial_velocity = .{ 0.0, 5.0, 0.0 },
.velocity_variation = .{ 10.0, 5.0, 10.0 },  // High variation
.color = .{ 1.0, 0.5, 0.0, 1.0 },
.size = 0.1,
```

## Performance Guidelines

| Particle Count | Recommended Use Case    | Performance Impact |
|----------------|-------------------------|-------------------|
| < 1,000        | Small effects           | Negligible        |
| 1,000-10,000   | Medium effects          | Low (~0.2ms)      |
| 10,000-100,000 | Large effects           | Medium (~0.8ms)   |
| > 100,000      | Extreme effects         | High (~8ms)       |

## Troubleshooting

### No Particles Visible
- Check `emitter.active = true`
- Verify `emit_rate > 0`
- Ensure `particle_lifetime > 0`
- Check `color.a > 0` (alpha channel)

### Low Performance
- Reduce `max_particles` capacity
- Lower `emit_rate`
- Shorten `particle_lifetime`
- Limit number of active emitters

### Particles Spawn at Origin
- Ensure entity has `Transform` component
- Check `transform.position` is correct
- Verify emitter is reading transform data

## See Also

- [Particle System](PARTICLE_SYSTEM.md) - Full documentation
- [RenderGraph System](RENDER_GRAPH_SYSTEM.md) - Pass coordination
- [ECS System](ECS_SYSTEM.md) - Component management
