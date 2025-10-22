# Lighting System for ZulkanZengine

## Overview
The lighting system provides deferred lighting capabilities using point lights extracted from the ECS (Entity Component System). It's designed to work with both rasterization and ray tracing pipelines.

## Components

### ECS Components

#### `ecs::PointLight` (`src/ecs/components/point_light.zig`)
```zig
pub const PointLight = struct {
    color: Math.Vec3,          // RGB color
    intensity: f32,            // Brightness multiplier
    range: f32,                // Maximum light range
    constant: f32,             // Attenuation constant (1.0)
    linear: f32,               // Attenuation linear (0.09)
    quadratic: f32,            // Attenuation quadratic (0.032)
    cast_shadows: bool,        // Shadow casting flag
};
```

**Key Methods:**
- `init()` - Create default light
- `initWithColor(color, intensity)` - Create colored light
- `initWithRange(color, intensity, range)` - Create light with range
- `getAttenuation(distance)` - Calculate attenuation factor

### Systems

#### `ecs::LightSystem` (`src/ecs/systems/light_system.zig`)
Extracts point lights from ECS entities for rendering.

```zig
pub const ExtractedLight = struct {
    position: Math.Vec3,
    color: Math.Vec3,
    intensity: f32,
    range: f32,
    attenuation: Math.Vec3,  // (constant, linear, quadratic)
};
```

**Key Methods:**
- `extractLights(world)` - Extract all lights with Transform + PointLight components
- Returns `LightData` containing array of `ExtractedLight`

### Render Passes

#### `LightingPass` (`src/rendering/passes/lighting_pass.zig`)
Deferred lighting pass that applies point light illumination.

**Features:**
- Extracts lights from ECS each frame
- Maintains per-frame light buffers (max 16 lights)
- Supports pipeline hot-reloading
- Converts ECS lights to shader-compatible format

**Shader Light Format:**
```zig
pub const ShaderPointLight = extern struct {
    position: [4]f32,      // xyz = position, w = 1.0
    color: [4]f32,         // rgb = color * intensity, a = 1.0
    attenuation: [4]f32,   // x=constant, y=linear, z=quadratic, w=range
};
```

## Usage

### 1. Register PointLight Component with ECS

```zig
try ecs_world.registerComponent(ecs.PointLight);
```

### 2. Create Light Entities

```zig
// Create point light entity
const light_entity = try ecs_world.createEntity();

// Add transform
const transform = Transform.init();
try ecs_world.emplace(Transform, light_entity, transform);

// Add point light
const point_light = ecs.PointLight.initWithColor(
    Math.Vec3.init(1.0, 0.8, 0.6),  // Warm white
    2.0,                             // Intensity
);
try ecs_world.emplace(ecs.PointLight, light_entity, point_light);

// Position the light
var transform_mut = try ecs_world.getMut(Transform, light_entity);
transform_mut.setPosition(Math.Vec3.init(0, 5, 0));
transform_mut.updateMatrices();
```

### 3. Add LightingPass to RenderGraph

```zig
const lighting_pass = try LightingPass.create(
    allocator,
    graphics_context,
    pipeline_system,
    ecs_world,
    swapchain_color_format,
);

try render_graph.addPass(lighting_pass.toRenderPass());
```

## Integration with Ray Tracing

The lighting system is designed to work with ray tracing:

1. **ExtractedLight** format matches ray tracing shader requirements
2. Light data can be uploaded to GPU for ray tracing shaders
3. Same ECS entities drive both rasterization and ray tracing

### Ray Tracing Shader Integration

In `RayTracingTriangle.rgen.hlsl`:
```hlsl
struct PointLight {
    float4 position;
    float4 color;
};

cbuffer LightBuffer : register(b1) {
    PointLight lights[16];
    int numLights;
};
```

The `ShaderPointLight` format in `LightingPass` matches this shader structure.

## Attenuation Model

Uses distance-based quadratic attenuation:

```
attenuation = 1.0 / (constant + linear * d + quadratic * d²)
```

Default values (suitable for range ~10 units):
- constant: 1.0
- linear: 0.09
- quadratic: 0.032

## Future Enhancements

### Planned Features
1. **Shadow Mapping** - Use `cast_shadows` flag
2. **Light Culling** - Frustum and tile-based culling
3. **Additional Light Types**:
   - Directional lights
   - Spot lights
   - Area lights
4. **G-Buffer Integration** - Proper deferred rendering pipeline
5. **PBR Lighting** - Physically-based rendering materials

### Deferred Rendering Pipeline (TODO)
```
GeometryPass → G-Buffer → LightingPass → Final Image
     ↓
  (positions)
  (normals)
  (albedo)
  (material)
```

## Performance Considerations

- **Max Lights per Frame**: 16 (increase MAX_LIGHTS as needed)
- **Per-Frame Buffers**: Light buffers created for each frame in flight
- **Light Extraction**: O(n) where n = entities with Transform + PointLight
- **GPU Upload**: Lights uploaded every frame (consider caching for static lights)

## Example Scene

```zig
// Main scene light
const sun = try ecs_world.createEntity();
try ecs_world.emplace(Transform, sun, Transform.init());
try ecs_world.emplace(ecs.PointLight, sun, ecs.PointLight.initWithRange(
    Math.Vec3.init(1.0, 1.0, 0.9),  // Warm sunlight
    3.0,                             // Bright
    50.0,                            // Large range
));

// Accent light
const accent = try ecs_world.createEntity();
try ecs_world.emplace(Transform, accent, Transform.init());
try ecs_world.emplace(ecs.PointLight, accent, ecs.PointLight.initWithColor(
    Math.Vec3.init(0.2, 0.5, 1.0),  // Blue accent
    1.5,
));
```

## Implementation Status

- [x] PointLight ECS component
- [x] LightSystem for extraction
- [x] LightingPass render pass
- [x] Shader light buffer format
- [ ] Fullscreen lighting shaders
- [ ] G-Buffer inputs
- [ ] Shadow mapping
- [ ] Light culling
- [ ] PBR integration

## Files Created

1. `src/ecs/components/point_light.zig` - PointLight component
2. `src/ecs/systems/light_system.zig` - Light extraction system
3. `src/rendering/passes/lighting_pass.zig` - Deferred lighting pass

## Modified Files

1. `src/ecs.zig` - Export PointLight and LightSystem
