# Path Tracing Integration

**Last Updated**: November 22, 2025
**Status**: ✅ Complete

## Overview

This document describes the Path Tracing system integration with the rendering pipeline, including light and particle data access for ray-traced rendering. The system provides hardware-accelerated ray tracing using Vulkan's ray tracing extensions with BVH (TLAS/BLAS) acceleration structures.

## Quick Facts

- **Toggle Key**: 'T' switches between ray tracing and rasterization
- **Performance**: ~5ms GPU time for typical scenes
- **BVH Building**: Async on ThreadPool (bvh_building subsystem)
- **Integration**: Reads light data (binding 7) and particle data (binding 8)
- **Resource Management**: Uses `AccelerationStructureSet` and `MaterialSet` for automatic generation tracking

## Architecture

### System Components

- **PathTracingPass**: Ray traces scene geometry using BVH (TLAS/BLAS)
- **RaytracingSystem**: Manages `AccelerationStructureSet`s (TLAS/BLAS) with generation tracking
- **LightVolumePass**: Manages point lights with instanced rendering
- **ParticleSystem**: GPU-accelerated particle simulation and rendering

### Integration Goals

1. ✅ Path tracer accesses light data from LightVolumePass
2. ✅ Path tracer incorporates particles as emissive geometry
3. ✅ Minimize data duplication through shared buffers
4. ✅ Support dynamic updates (lights moving, particles spawning/dying)
5. ✅ Automatic resource rebinding via generation tracking

---

## Design: Light Integration

### Data Flow
```
Lighting Volume Pass → Light Buffer → Path Tracing Shader
                    ↓
              (shared buffer)
```

### Implementation

#### 1. Light Data Structure (Shared)
```zig
// In shader (GLSL/HLSL):
struct PointLight {
    vec3 position;      // World space position
    float radius;       // Light radius/range
    vec3 color;         // RGB color
    float intensity;    // Light intensity
    uint enabled;       // 0 or 1
    uint padding[3];    // Alignment to 16 bytes
};

layout(set = 0, binding = 7) buffer LightBuffer {
    uint light_count;
    PointLight lights[];
};
```

#### 2. Path Tracing Pass Changes

**Add to PathTracingPass struct:**
```zig
// Reference to lighting volume pass (for light buffer access)
lighting_volume_pass: ?*LightingVolumePass,
// Acceleration Structure Set (TLAS + BLAS)
accel_set: ?*AccelerationStructureSet,
```

**Descriptor Binding:**
- **Binding 7**: Light buffer (SSBO) - shared with lighting volume pass
- **Binding "rs"**: TLAS from `accel_set`
- **Binding "material_buffer"**: Material data from `material_set`
- **Binding "texture_buffer"**: Texture array from `material_set`

**Update Pattern:**
The system now uses `ResourceBinder` with named bindings and generation tracking. Manual descriptor updates are no longer needed for most resources.

```zig
// In setup():
self.accel_set = try self.rt_system.createSet("default");

// Bind TLAS (generation tracked automatically)
try self.resource_binder.bindAccelerationStructureNamed(
    self.path_tracing_pipeline,
    "rs",
    &self.accel_set.?.tlas,
);
```
    }
}
```

#### 3. Shader Integration

**Path Tracing Shader (raygen):**
```glsl
// Direct lighting contribution
vec3 evaluateDirectLighting(vec3 hitPoint, vec3 normal, vec3 albedo) {
    vec3 directLight = vec3(0.0);
    
    // Iterate through all lights
    for (uint i = 0; i < lightBuffer.light_count; i++) {
        PointLight light = lightBuffer.lights[i];
        if (light.enabled == 0) continue;
        
        vec3 toLight = light.position - hitPoint;
        float distance = length(toLight);
        
        // Skip if outside light radius
        if (distance > light.radius) continue;
        
        vec3 L = toLight / distance;
        float NdotL = max(dot(normal, L), 0.0);
        
        if (NdotL > 0.0) {
            // Shadow ray test
            bool inShadow = traceShadowRay(hitPoint, L, distance);
            
            if (!inShadow) {
                // Inverse square attenuation
                float attenuation = 1.0 / (distance * distance);
                attenuation *= smoothstep(light.radius, 0.0, distance);
                
                // Add light contribution
                vec3 radiance = light.color * light.intensity * attenuation;
                directLight += albedo * radiance * NdotL / PI;
            }
        }
    }
    
    return directLight;
}
```

#### 4. Change Detection

**LightingVolumePass:**
```zig
pub const LightingVolumePass = struct {
    // ... existing fields ...
    lights_dirty: bool = true,
    last_light_count: usize = 0,
    
    pub fn checkLightsDirty(self: *LightingVolumePass) bool {
        return self.lights_dirty;
    }
    
    pub fn markLightsSynced(self: *LightingVolumePass) void {
        self.lights_dirty = false;
    }
};
```

**PathTracingPass.updateState():**
```zig
pub fn updateState(self: *PathTracingPass, frame_info: *const FrameInfo) !void {
    // ... existing BVH update ...
    
    // Check if lights changed
    const lights_dirty = if (self.lighting_volume_pass) |lvp|
        lvp.checkLightsDirty()
    else
        false;
    
    const needs_update = bvh_rebuilt or
        materials_dirty or
        textures_dirty or
        lights_dirty or  // Add to existing checks
        // ... other conditions ...
        
    if (needs_update) {
        try self.updateDescriptors();
        
        if (lights_dirty and self.lighting_volume_pass != null) {
            self.lighting_volume_pass.?.markLightsSynced();
        }
    }
}
```

---

## Design: Particle Integration

### Data Flow
```
Particle System → Particle Position Buffer → Path Tracing Shader
              ↓                           ↓
        Compute Shader              Sample as emissive spheres
```

### Implementation

#### 1. Particle Data Access

**Particle Buffer Structure:**
```glsl
struct Particle {
    vec3 position;
    float size;
    vec3 velocity;
    float life;
    vec4 color;     // RGBA (A = opacity)
};

layout(set = 0, binding = 8) readonly buffer ParticleBuffer {
    uint particle_count;
    Particle particles[];
};
```

#### 2. Path Tracing Pass Changes

**Add to PathTracingPass struct:**
```zig
// Reference to particle system
particle_system: ?*ParticleSystem,

// Track particle state
last_particle_count: usize = 0,
```

**Descriptor Binding:**
- **Binding 8**: Particle buffer (SSBO) - shared with particle system
  - Type: Storage Buffer
  - Access: Read-only in path tracer
  - Update: Every frame (particles constantly changing)

**Update Pattern:**
```zig
pub fn updateDescriptors(self: *PathTracingPass) !void {
    // ... existing bindings 0-7 ...
    
    // Binding 8: Particle buffer (if particle system exists)
    if (self.particle_system) |ps| {
        const particle_buffer = ps.getActiveParticleBuffer(frame_index);
        if (particle_buffer) |pbuf| {
            const particle_resource = Resource{
                .buffer = .{
                    .buffer = pbuf.buffer,
                    .offset = 0,
                    .range = pbuf.size,
                },
            };
            for (0..MAX_FRAMES_IN_FLIGHT) |frame_idx| {
                try self.pipeline_system.bindResource(
                    self.path_tracing_pipeline,
                    0, 8,
                    particle_resource,
                    @intCast(frame_idx)
                );
            }
        }
    }
}
```

#### 3. Shader Integration

**Path Tracing Shader - Particle Intersection:**
```glsl
// Custom intersection for particles (called during ray traversal)
float intersectParticles(vec3 origin, vec3 direction, out uint hitParticleIdx) {
    float closest_t = 1e10;
    hitParticleIdx = 0xFFFFFFFF;
    
    for (uint i = 0; i < particleBuffer.particle_count; i++) {
        Particle p = particleBuffer.particles[i];
        
        // Skip dead particles
        if (p.life <= 0.0) continue;
        
        // Sphere intersection test
        vec3 oc = origin - p.position;
        float radius = p.size * 0.5;
        
        float a = dot(direction, direction);
        float b = 2.0 * dot(oc, direction);
        float c = dot(oc, oc) - radius * radius;
        float discriminant = b * b - 4.0 * a * c;
        
        if (discriminant > 0.0) {
            float t = (-b - sqrt(discriminant)) / (2.0 * a);
            if (t > 0.001 && t < closest_t) {
                closest_t = t;
                hitParticleIdx = i;
            }
        }
    }
    
    return closest_t;
}

// In main ray tracing loop:
void main() {
    // Trace geometry
    traceRayEXT(...);
    
    // Check particle intersection
    uint particleIdx;
    float particle_t = intersectParticles(ray.origin, ray.direction, particleIdx);
    
    // If particle is closer than geometry hit
    if (particle_t < geometryHit_t) {
        Particle p = particleBuffer.particles[particleIdx];
        
        // Particles are emissive
        vec3 emission = p.color.rgb * p.color.a;
        
        // Add to accumulated radiance
        throughput *= emission;
        
        // Particles don't continue bouncing (pure emissive)
        break;
    }
}
```

**Alternative: Volumetric Approach**
```glsl
// For each path segment, accumulate particle contributions
vec3 evaluateParticleVolume(vec3 rayStart, vec3 rayEnd) {
    vec3 emission = vec3(0.0);
    vec3 direction = rayEnd - rayStart;
    float segmentLength = length(direction);
    direction /= segmentLength;
    
    // Sample particles along ray
    const int samples = 16;
    for (int s = 0; s < samples; s++) {
        float t = (s + 0.5) / float(samples) * segmentLength;
        vec3 samplePos = rayStart + direction * t;
        
        // Check all particles
        for (uint i = 0; i < particleBuffer.particle_count; i++) {
            Particle p = particleBuffer.particles[i];
            if (p.life <= 0.0) continue;
            
            float dist = length(samplePos - p.position);
            float radius = p.size * 0.5;
            
            // Soft falloff
            if (dist < radius) {
                float influence = 1.0 - smoothstep(0.0, radius, dist);
                emission += p.color.rgb * p.color.a * influence;
            }
        }
    }
    
    return emission / float(samples);
}
```

#### 4. Update Strategy

**PathTracingPass.updateState():**
```zig
pub fn updateState(self: *PathTracingPass, frame_info: *const FrameInfo) !void {
    // ... existing updates ...
    
    // Always update particles (they change every frame)
    const particles_active = if (self.particle_system) |ps|
        ps.getActiveParticleCount() > 0
    else
        false;
    
    const needs_update = bvh_rebuilt or
        materials_dirty or
        textures_dirty or
        lights_dirty or
        particles_active or  // Update if particles exist
        // ... other conditions ...
        
    if (needs_update) {
        try self.updateDescriptors();
    }
}
```

---

## Integration Architecture

### Descriptor Set Layout (Set 0)

| Binding | Type | Description | Source |
|---------|------|-------------|--------|
| 0 | Acceleration Structure | TLAS | rt_system |
| 1 | Storage Image | Output texture | path_tracing_pass |
| 2 | Uniform Buffer | Camera data | global_ubo_set |
| 3 | Storage Buffer Array | Vertex buffers | render_system |
| 4 | Storage Buffer Array | Index buffers | render_system |
| 5 | Storage Buffer | Material buffer | asset_manager |
| 6 | Combined Image Sampler Array | Texture array | asset_manager |
| **7** | **Storage Buffer** | **Light buffer** | **lighting_volume_pass** |
| **8** | **Storage Buffer** | **Particle buffer** | **particle_system** |

### Initialization Order

```zig
// In scene.zig or app.zig:

// 1. Create passes
const lighting_volume_pass = try LightingVolumePass.create(...);
const particle_system = try ParticleSystem.init(...);

// 2. Create path tracing pass with references
var path_tracing_pass = try PathTracingPass.create(
    allocator,
    graphics_context,
    // ... existing params ...
);

// 3. Set references AFTER creation
path_tracing_pass.lighting_volume_pass = &lighting_volume_pass;
path_tracing_pass.particle_system = &particle_system;

// 4. Initial descriptor update
try path_tracing_pass.updateDescriptors();
```

### Update Flow (per frame)

```
1. scene.update()
   ├─> lighting_volume_pass.update() → Updates light positions/colors
   ├─> particle_system.update() → Compute shader updates particles
   └─> path_tracing_pass.updateState()
       ├─> Check lights_dirty
       ├─> Check particles_active
       └─> updateDescriptors() if needed

2. scene.render()
   ├─> lighting_volume_pass.execute() → Renders light volumes (optional)
   ├─> particle_system.render() → Renders particles (optional)
   └─> path_tracing_pass.execute()
       └─> Ray tracing shader accesses light & particle buffers
```

---

## Performance Considerations

### Light Integration
- **Buffer Size**: Reasonable for typical scenes (< 100 lights)
- **Shadow Rays**: Each light requires shadow ray test = potential performance hit
- **Optimization**: Use importance sampling (test brightest lights first)
- **Culling**: Skip lights outside camera frustum or too far from geometry

### Particle Integration
- **Buffer Size**: Can be large (1000s of particles)
- **Intersection Cost**: O(N) per ray for N particles
- **Optimization Strategies**:
  1. **Spatial Hashing**: Partition particles into grid cells
  2. **LOD**: Reduce particle count for distant emitters
  3. **Importance Sampling**: Only test particles near ray path
  4. **BVH for Particles**: Build acceleration structure for particle positions

### Recommended Optimizations

```glsl
// Use bounding sphere for early rejection
bool rayIntersectsSphere(vec3 origin, vec3 direction, vec3 center, float radius) {
    vec3 oc = origin - center;
    float b = dot(oc, direction);
    float c = dot(oc, oc) - radius * radius;
    float discriminant = b * b - c;
    return discriminant > 0.0 && (-b - sqrt(discriminant)) > 0.0;
}

// Only test particles in view frustum
bool particleInFrustum(vec3 pos, float radius) {
    // Frustum planes from camera UBO
    for (int i = 0; i < 6; i++) {
        if (dot(frustumPlanes[i].xyz, pos) + frustumPlanes[i].w < -radius) {
            return false;
        }
    }
    return true;
}
```

---

## Future Enhancements

### 1. Light Clustering
Group lights into clusters for efficient evaluation:
```
Camera Space → Grid → Light List per Cell → Shader samples cluster
```

### 2. Particle Acceleration Structure
Build mini-BVH or grid for particles:
```zig
pub const ParticleAcceleration = struct {
    grid_size: [3]u32,
    cell_particle_lists: []std.ArrayList(u32),
};
```

### 3. Hybrid Rendering
Combine ray-traced primary visibility with rasterized lights/particles for performance:
```
Ray Tracing (geometry) + Rasterization (lights/particles) = Hybrid Path Tracing
```

### 4. Importance Sampling
Sample lights proportionally to their contribution:
```glsl
float lightPower = light.intensity * luminance(light.color) / (distance * distance);
float probability = lightPower / totalPower;
```

---

## Implementation Checklist

- [ ] Add `lighting_volume_pass` reference to PathTracingPass
- [ ] Add `particle_system` reference to PathTracingPass
- [ ] Implement binding 7 (light buffer) in updateDescriptors
- [ ] Implement binding 8 (particle buffer) in updateDescriptors
- [ ] Add lights_dirty tracking to LightingVolumePass
- [ ] Update PathTracingPass.updateState() to check light/particle changes
- [ ] Implement shader light evaluation function
- [ ] Implement shader particle intersection
- [ ] Test with dynamic lights (moving, changing color/intensity)
- [ ] Test with spawning/dying particles
- [ ] Profile performance with many lights/particles
- [ ] Implement optimizations if needed (clustering, spatial hashing)

---

## Testing Strategy

### Unit Tests
1. Light buffer binding with null lighting_volume_pass
2. Light buffer binding with valid lighting_volume_pass
3. Particle buffer binding with null particle_system
4. Particle buffer binding with valid particle_system
5. Descriptor update when lights change
6. Descriptor update when particles spawn/die

### Integration Tests
1. Render scene with 1 light, verify contribution
2. Render scene with multiple lights, verify shadows
3. Render scene with particles, verify emission
4. Render scene with lights + particles together
5. Dynamic test: move lights during render
6. Dynamic test: spawn particles during render

### Performance Tests
1. Baseline: Path tracing without lights/particles
2. With 10 lights
3. With 100 lights
4. With 1000 particles
5. With 10000 particles
6. Combined: 100 lights + 1000 particles

---

## References

- **Implementation**: 
  - `src/rendering/passes/path_tracing_pass.zig`
  - `src/systems/raytracing_system.zig`
  - `src/systems/multithreaded_bvh_builder.zig`
- **Shaders**: 
  - `shaders/RayTracingTriangle.rgen.hlsl`
  - `shaders/RayTracingTriangle.rchit.hlsl`
  - `shaders/RayTracingTriangle.rmiss.hlsl`
- **Related Docs**: 
  - [RenderGraph System](RENDER_GRAPH_SYSTEM.md) - Pass coordination
  - [Lighting System](LIGHTING_SYSTEM.md) - Light data (binding 7)
  - [Particle System](PARTICLE_SYSTEM.md) - Particle data (binding 8)
  - [Enhanced Thread Pool](ENHANCED_THREAD_POOL.md) - Async BVH building

---

*Last Updated: October 24, 2025*
