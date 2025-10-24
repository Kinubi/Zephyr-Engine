# Lighting System for ZulkanZengine

**Last Updated**: October 24, 2025  
**Status**: ✅ Implemented with Instanced Rendering

## Overview

The lighting system provides point light support extracted from the ECS and rendered as visible light volumes (billboards). The system uses **instanced rendering** for efficient visualization of up to 128 lights per frame.

## Architecture

### Rendering Pipeline

```
ECS Entities → LightSystem.extract() → LightVolumePass → GPU Instanced Draw
   (Transform + PointLight)        (LightData)          (SSBO + 1 draw call)
```

**Key Features:**
- ✅ Instanced rendering (single draw call for all lights)
- ✅ SSBO-based light data (128 light capacity)
- ✅ Billboard rendering with camera-facing quads
- ✅ Host-visible mapped buffers (no staging)
- ✅ Integration with path tracing pass (binding 7)
- ✅ Hot-reload compatible

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
    cast_shadows: bool,        // Shadow casting flag (unused currently)
};
```

**Key Methods:**
- `init()` - Create default white light (intensity 1.0, range 10.0)
- `initWithColor(color, intensity)` - Create colored light
- `initWithRange(color, intensity, range)` - Create light with specific range
- `getAttenuation(distance)` - Calculate attenuation factor

**Default Values:**
- Color: (1.0, 1.0, 1.0) white
- Intensity: 1.0
- Range: 10.0
- Attenuation: constant=1.0, linear=0.09, quadratic=0.032

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

pub const LightData = struct {
    lights: std.ArrayList(ExtractedLight),
};
```

**Key Methods:**
- `extract(world: *World) !LightData` - Query all entities with Transform + PointLight
- Returns `LightData` containing array of `ExtractedLight` with world-space positions

**Extraction Logic:**
1. Query ECS for entities with both Transform and PointLight components
2. Read world position from Transform.world_matrix
3. Combine with PointLight color/intensity/range
4. Return array of extracted lights

### Render Passes

#### `LightVolumePass` (`src/rendering/passes/light_volume_pass.zig`)

Forward rendering pass that draws visible light volumes as camera-facing billboards.

**Architecture:**
```
LightSystem.extract() → Update SSBO → Bind Pipeline → Draw(6 verts, N instances)
                              ↓                               ↓
                        LightVolumeData[]              gl_InstanceIndex
```

**Features:**
- **Instanced Rendering**: Single draw call with `gl_InstanceIndex`
- **SSBO Light Data**: Up to 128 lights in GPU buffer
- **Host-Mapped Buffers**: Direct memory access, no staging
- **Billboard Geometry**: 6 vertices (2 triangles) rendered per light
- **Camera-Facing Quads**: Vertex shader computes world-space billboards
- **Hot-Reload Support**: Automatic pipeline rebuild on shader changes

**SSBO Layout:**
```zig
// Matches shader struct layout
const LightVolumeData = extern struct {
    position: [4]f32,   // xyz = world position, w = unused
    color: [4]f32,      // rgb = color * intensity, a = unused
    radius: f32,        // Billboard size (same as light range)
    _padding: [3]f32,   // Align to 16-byte boundary
};
```

**Per-Frame Resources:**
- `light_volume_buffers[MAX_FRAMES_IN_FLIGHT]`: Host-mapped SSBO (32 KB each)
- Max lights: 128 (configurable via `max_lights`)

## Shader Details

### Vertex Shader (`shaders/point_light.vert`)

```glsl
#version 450
#extension GL_ARB_shader_draw_parameters : enable

// Billboard corners (2 triangles = 6 vertices)
const vec2 OFFSETS[6] = vec2[](
    vec2(-1.0, -1.0), vec2(-1.0, 1.0), vec2(1.0, -1.0),
    vec2(1.0, -1.0), vec2(-1.0, 1.0), vec2(1.0, 1.0)
);

// SSBO for instanced light data
struct LightVolumeData {
    vec4 position;
    vec4 color;
    float radius;
    float _padding[3];
};

layout(set = 0, binding = 1) readonly buffer LightVolumeBuffer {
    LightVolumeData lights[];
} lightVolumes;

void main() {
    // Fetch light data for this instance
    LightVolumeData light = lightVolumes.lights[gl_InstanceIndex];
    
    // Extract camera right/up vectors from view matrix
    vec3 cameraRightWorld = vec3(ubo.view[0][0], ubo.view[1][0], ubo.view[2][0]);
    vec3 cameraUpWorld = vec3(ubo.view[0][1], ubo.view[1][1], ubo.view[2][1]);
    
    // Compute world-space billboard position
    vec3 positionWorld = light.position.xyz
        + light.radius * OFFSETS[gl_VertexIndex].x * cameraRightWorld
        + light.radius * OFFSETS[gl_VertexIndex].y * cameraUpWorld;
    
    gl_Position = ubo.projection * ubo.view * vec4(positionWorld, 1.0);
}
```

**Key Techniques:**
- `gl_InstanceIndex` fetches per-light data from SSBO
- `gl_VertexIndex` selects billboard corner (0-5)
- Camera vectors extracted from view matrix for billboarding
- Radius determines billboard size (matches light range)

### Fragment Shader (`shaders/point_light.frag`)

```glsl
#version 450

layout(location = 4) in vec2 v_pos;       // Billboard UV (-1 to 1)
layout(location = 5) in vec4 v_color;     // Light color * intensity
layout(location = 6) in float v_radius;   // Light range

layout(location = 0) out vec4 outColor;

void main() {
    float dist = length(v_pos);
    float alpha = 1.0 - smoothstep(0.0, 1.0, dist);  // Radial fade
    
    outColor = vec4(v_color.rgb, alpha * v_color.a);
}
```

**Rendering:**
- Circular radial fade from center to edge
- Alpha blending for soft appearance
- Color directly from light intensity

## Usage

### 1. Register PointLight Component

```zig
try ecs_world.registerComponent(ecs.PointLight);
```

### 2. Create Light Entities

```zig
// Create point light entity
const light_entity = try ecs_world.createEntity();

// Add transform
var transform = Transform.init();
transform.setPosition(Math.Vec3.init(0, 5, 0));
transform.updateMatrices();
try ecs_world.emplace(Transform, light_entity, transform);

// Add point light
const point_light = ecs.PointLight.initWithColor(
    Math.Vec3.init(1.0, 0.8, 0.6),  // Warm white
    2.0,                             // Intensity
);
try ecs_world.emplace(ecs.PointLight, light_entity, point_light);
```

**Common Light Configurations:**

```zig
// Bright white light
const bright = ecs.PointLight.initWithColor(
    Math.Vec3.init(1, 1, 1),
    5.0
);

// Colored accent light
const colored = ecs.PointLight.initWithRange(
    Math.Vec3.init(0.2, 0.5, 1.0),  // Blue
    3.0,                             // Intensity
    15.0                             // Range
);

// Dim ambient light
const ambient = ecs.PointLight.init();  // Default 1.0 intensity, 10.0 range
```

### 3. Add LightVolumePass to RenderGraph

```zig
const light_volume_pass = try LightVolumePass.create(
    allocator,
    graphics_context,
    pipeline_system,
    ecs_world,
    global_ubo_set,
);

try render_graph.addPass(light_volume_pass);
```

**Pass Configuration:**
- Runs after GeometryPass (renders on top of geometry)
- Uses alpha blending for soft light visualization
- Automatically extracts lights each frame
- Supports hot-reloading of shaders

## Path Tracing Integration

Light data is also available to the path tracing pass via descriptor binding 7:

```glsl
// PathTracing shader (binding 7)
struct PointLight {
    vec4 position;
    vec4 color;
};

layout(set = 0, binding = 7) readonly buffer PointLightsBuffer {
    uint count;
    PointLight lights[];
} pointLightsData;
```

**Integration Points:**
1. `LightSystem.extract()` generates unified light list
2. `RenderSystem.getLightData()` provides read-only access
3. Both LightVolumePass and PathTracingPass consume same data
4. Automatic synchronization via ECS query

## Performance Characteristics

### CPU Cost
- **ECS Extraction**: O(N) where N = number of light entities
- **Buffer Update**: Single `memcpy` to host-mapped SSBO
- **Command Recording**: Single `cmdDraw(6, light_count, 0, 0)` call

### GPU Cost
- **Vertex Shader**: 6 * N invocations (N = light count)
- **Fragment Shader**: ~50-200 pixels per light (billboard coverage)
- **Bandwidth**: Minimal (SSBO read, no textures)

### Scalability
- **Current Limit**: 128 lights (32 KB SSBO)
- **Typical Usage**: 10-50 lights per scene
- **Bottleneck**: Fragment overdraw if lights overlap heavily

**Optimization Notes:**
- Instanced rendering eliminates per-light draw call overhead
- Host-mapped buffers avoid staging copies
- Single-pass rendering (no depth pre-pass needed)
- Early exit when `light_count == 0` (zero GPU work)

## Limitations & Future Work

### Current Limitations
- ❌ No shadow mapping (lights don't cast shadows in rasterization)
- ❌ No light culling (all lights drawn every frame)
- ❌ Fixed 128 light capacity
- ❌ Billboard-only visualization (no volumetric rendering)

### Planned Features
- [ ] Frustum culling (skip off-screen lights)
- [ ] Distance-based LOD (smaller billboards for distant lights)
- [ ] Light clustering for efficient shader sampling
- [ ] Shadow mapping integration
- [ ] Volumetric light scattering

### Path Tracing Benefits
The path tracing pass automatically uses all lights for:
- ✅ Global illumination
- ✅ Soft shadows
- ✅ Accurate light transport
- ✅ Area light approximation (from point lights)

## Debugging

### Common Issues

**Lights not visible:**
```zig
// Check ECS components
if (ecs_world.has(ecs.PointLight, entity)) {
    const light = try ecs_world.get(ecs.PointLight, entity);
    std.debug.print("Light: color={}, intensity={}\n", .{light.color, light.intensity});
}

// Check transform
if (ecs_world.has(Transform, entity)) {
    const transform = try ecs_world.get(Transform, entity);
    std.debug.print("Position: {}\n", .{transform.getWorldPosition()});
}
```

**Lights too small/large:**
```zig
// Adjust range (controls billboard size)
var light = try ecs_world.getMut(ecs.PointLight, entity);
light.range = 5.0;  // Smaller billboards
```

**Performance issues:**
```zig
// Count active lights
const light_data = try LightSystem.extract(ecs_world);
defer light_data.deinit();
std.debug.print("Active lights: {}\n", .{light_data.lights.items.len});
```

### Logging

The LightVolumePass logs key events:
```
[INFO] light_volume_pass: Created LightVolumePass (max 128 lights)
[INFO] light_volume_pass: Setup complete
[DEBUG] light_volume_pass: Rendering 12 lights
[INFO] light_volume_pass: Pipeline hot-reloaded
```

Enable debug logging in `light_volume_pass.zig` for per-frame updates.

## Migration Notes

### From Old Deferred Lighting System

The old `LightingPass` used deferred shading with per-light push constants. The new system:

**Old Approach (Removed):**
```zig
// Per-light push constants + draw calls
for (lights) |light| {
    cmdPushConstants(cmd, layout, &light);  // N push constant updates
    cmdDraw(cmd, 6, 1, 0, 0);              // N draw calls
}
```

**New Approach (Current):**
```zig
// Single SSBO + instanced draw
updateLightBuffer(lights);                  // 1 memcpy
cmdDraw(cmd, 6, light_count, 0, 0);       // 1 draw call
```

**Benefits:**
- 95% reduction in draw calls (N → 1)
- No push constant overhead
- Better GPU occupancy from instancing
- Scales to 128 lights with minimal CPU cost

**Breaking Changes:**
- Shaders now use `gl_InstanceIndex` instead of push constants
- SSBO binding 1 required (was push constant range 0)
- Maximum 128 lights (was unlimited but slow)

---

**See Also:**
- [ECS System Documentation](ECS_SYSTEM.md)
- [Path Tracing Integration](PATH_TRACING_INTEGRATION.md)
- [Render Pass Vulkan Integration](RENDER_PASS_VULKAN_INTEGRATION.md)
- [Threaded Rendering Design](THREADED_RENDERING_DESIGN.md)
