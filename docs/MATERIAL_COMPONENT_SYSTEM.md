# Material Component System

## Overview

Pure ECS-driven material system using component composition. Materials are built from individual components (albedo, roughness, metallic, normal, emissive) that entities can mix and match. Systems query these components to build GPU descriptor arrays and material buffers.

## Architecture

### Component Hierarchy

```
Entity (e.g., Car Body)
├─ Transform
├─ MeshRenderer
├─ MaterialSet (defines shader and type)
├─ AlbedoMaterial (optional)
├─ RoughnessMaterial (optional)
├─ MetallicMaterial (optional)
├─ NormalMaterial (optional)
└─ EmissiveMaterial (optional)
```

### Key Principles

1. **Pure ECS Composition** - Each material property is a separate component
2. **Optional Components** - Entities only have what they need (glass doesn't need metallic)
3. **System-Driven** - Systems query components to build GPU resources
4. **No Intermediate Sets** - Direct ECS → GPU pipeline
5. **Bindless Rendering** - Single shader handles all material variations

## Components

### MaterialSet Component

Defines the material type and shader variant.

```zig
pub const MaterialType = enum {
    opaque,
    transparent,
    translucent,
    masked,
};

pub const MaterialSet = struct {
    type: MaterialType,
    shader_variant: []const u8,  // "pbr_standard", "glass", "unlit", etc.
    
    // Runtime data (filled by system)
    material_buffer_index: u32 = 0,  // Index into GPU material buffer
};
```

### Material Property Components

Each component represents one material property with optional texture + parameters.

```zig
pub const AlbedoMaterial = struct {
    texture_id: AssetId,
    color_tint: [4]f32 = [_]f32{1.0, 1.0, 1.0, 1.0},
};

pub const RoughnessMaterial = struct {
    texture_id: AssetId,
    factor: f32 = 0.5,  // Multiplier applied to texture
};

pub const MetallicMaterial = struct {
    texture_id: AssetId,
    factor: f32 = 0.0,
};

pub const NormalMaterial = struct {
    texture_id: AssetId,
    strength: f32 = 1.0,
};

pub const EmissiveMaterial = struct {
    texture_id: AssetId,
    color: [3]f32 = [_]f32{1.0, 1.0, 1.0},
    intensity: f32 = 1.0,
};
```

## Usage Examples

### Full PBR Material (Car Paint)

```zig
const body = try scene.spawnChild(parent);

try world.emplace(MeshRenderer, body, .{ .model_asset = car_body_mesh });

try world.emplace(MaterialSet, body, .{ 
    .type = .opaque,
    .shader_variant = "pbr_standard"
});

try world.emplace(AlbedoMaterial, body, .{ 
    .texture_id = car_paint_albedo_tex,
    .color_tint = [_]f32{1.0, 0.2, 0.2, 1.0}  // Red tint
});

try world.emplace(RoughnessMaterial, body, .{ 
    .texture_id = car_paint_roughness_tex,
    .factor = 0.3
});

try world.emplace(MetallicMaterial, body, .{ 
    .texture_id = car_paint_metallic_tex,
    .factor = 0.8
});

try world.emplace(NormalMaterial, body, .{ 
    .texture_id = car_paint_normal_tex,
    .strength = 1.0
});
```

### Simple Transparent Material (Glass)

```zig
const windows = try scene.spawnChild(parent);

try world.emplace(MeshRenderer, windows, .{ .model_asset = car_windows_mesh });

try world.emplace(MaterialSet, windows, .{ 
    .type = .transparent,
    .shader_variant = "glass"
});

try world.emplace(AlbedoMaterial, windows, .{ 
    .texture_id = glass_tex,
    .color_tint = [_]f32{0.8, 0.9, 1.0, 0.3}  // Blue tint, 30% opacity
});
```

### Emissive Material (Headlights)

```zig
const headlights = try scene.spawnChild(parent);

try world.emplace(MeshRenderer, headlights, .{ .model_asset = headlights_mesh });

try world.emplace(MaterialSet, headlights, .{ 
    .type = .opaque,
    .shader_variant = "unlit"
});

try world.emplace(EmissiveMaterial, headlights, .{ 
    .texture_id = headlight_glow_tex,
    .color = [_]f32{1.0, 0.95, 0.8},
    .intensity = 5.0
});
```

## System Implementation

### Material System (ECS → GPU)

The material system queries ECS components and builds GPU resources.

```zig
pub fn update(world: *World, dt: f32) !void {
    // Query all entities with materials
    var view = try world.view(MaterialSet, AlbedoMaterial);
    var iter = view.iterator();
    
    var textures = std.ArrayList(vk.DescriptorImageInfo).init(allocator);
    var materials = std.ArrayList(GPUMaterial).init(allocator);
    
    while (iter.next()) |entry| {
        const entity = entry.entity;
        const material_set = world.get(MaterialSet, entity).?;
        const albedo = entry.component;
        
        // Query optional components
        const roughness = world.get(RoughnessMaterial, entity);
        const metallic = world.get(MetallicMaterial, entity);
        const normal = world.get(NormalMaterial, entity);
        const emissive = world.get(EmissiveMaterial, entity);
        
        // Build texture array (bindless)
        const albedo_idx = try addTextureToArray(&textures, albedo.texture_id);
        const roughness_idx = if (roughness) |r| try addTextureToArray(&textures, r.texture_id) else 0;
        const metallic_idx = if (metallic) |m| try addTextureToArray(&textures, m.texture_id) else 0;
        const normal_idx = if (normal) |n| try addTextureToArray(&textures, n.texture_id) else 0;
        const emissive_idx = if (emissive) |e| try addTextureToArray(&textures, e.texture_id) else 0;
        
        // Build GPU material struct
        const material_idx = materials.items.len;
        try materials.append(.{
            .albedo_idx = albedo_idx,
            .roughness_idx = roughness_idx,
            .metallic_idx = metallic_idx,
            .normal_idx = normal_idx,
            .emissive_idx = emissive_idx,
            .albedo_tint = albedo.color_tint,
            .roughness_factor = if (roughness) |r| r.factor else 0.5,
            .metallic_factor = if (metallic) |m| m.factor else 0.0,
            .normal_strength = if (normal) |n| n.strength else 1.0,
            .emissive_color = if (emissive) |e| e.color else [_]f32{0,0,0},
            .emissive_intensity = if (emissive) |e| e.intensity else 0.0,
        });
        
        // Update MaterialSet with GPU index
        material_set.material_buffer_index = @intCast(material_idx);
    }
    
    // Upload to GPU
    try uploadTextureArray(textures.items);
    try uploadMaterialBuffer(materials.items);
}
```

### GPU Material Struct

```zig
pub const GPUMaterial = extern struct {
    albedo_idx: u32,
    roughness_idx: u32,
    metallic_idx: u32,
    normal_idx: u32,
    emissive_idx: u32,
    albedo_tint: [4]f32,
    roughness_factor: f32,
    metallic_factor: f32,
    normal_strength: f32,
    emissive_color: [3]f32,
    emissive_intensity: f32,
    _padding: [3]f32,  // Align to 16 bytes
};
```

## Shader Integration

### Descriptor Layout

```
Set 0: Global UBO (camera, lights)
Set 1: Bindless texture array (textures[])
Set 2: Material buffer SSBO (materials[])
```

### Vertex Shader

```glsl
#version 460

layout(set = 0, binding = 0) uniform GlobalUBO {
    mat4 view;
    mat4 proj;
    vec3 cameraPos;
} global;

layout(push_constant) uniform PushConstants {
    mat4 model;
    uint material_idx;
} push;

layout(location = 0) in vec3 inPosition;
layout(location = 1) in vec3 inNormal;
layout(location = 2) in vec2 inTexCoord;
layout(location = 3) in vec3 inTangent;

layout(location = 0) out vec3 fragWorldPos;
layout(location = 1) out vec3 fragNormal;
layout(location = 2) out vec2 fragTexCoord;
layout(location = 3) out vec3 fragTangent;
layout(location = 4) flat out uint fragMaterialIdx;

void main() {
    vec4 worldPos = push.model * vec4(inPosition, 1.0);
    gl_Position = global.proj * global.view * worldPos;
    
    fragWorldPos = worldPos.xyz;
    fragNormal = mat3(push.model) * inNormal;
    fragTexCoord = inTexCoord;
    fragTangent = mat3(push.model) * inTangent;
    fragMaterialIdx = push.material_idx;
}
```

### Fragment Shader (PBR)

```glsl
#version 460
#extension GL_EXT_nonuniform_qualifier : require

layout(set = 0, binding = 0) uniform GlobalUBO {
    mat4 view;
    mat4 proj;
    vec3 cameraPos;
} global;

layout(set = 1, binding = 0) uniform sampler2D textures[];

struct Material {
    uint albedo_idx;
    uint roughness_idx;
    uint metallic_idx;
    uint normal_idx;
    uint emissive_idx;
    vec4 albedo_tint;
    float roughness_factor;
    float metallic_factor;
    float normal_strength;
    vec3 emissive_color;
    float emissive_intensity;
};

layout(set = 2, binding = 0) readonly buffer MaterialBuffer {
    Material materials[];
};

layout(location = 0) in vec3 fragWorldPos;
layout(location = 1) in vec3 fragNormal;
layout(location = 2) in vec2 fragTexCoord;
layout(location = 3) in vec3 fragTangent;
layout(location = 4) flat in uint fragMaterialIdx;

layout(location = 0) out vec4 outColor;

void main() {
    Material mat = materials[fragMaterialIdx];
    
    // Sample albedo
    vec4 albedo = texture(textures[mat.albedo_idx], fragTexCoord) * mat.albedo_tint;
    
    // Sample roughness (if present)
    float roughness = mat.roughness_factor;
    if (mat.roughness_idx != 0) {
        roughness *= texture(textures[mat.roughness_idx], fragTexCoord).r;
    }
    
    // Sample metallic (if present)
    float metallic = mat.metallic_factor;
    if (mat.metallic_idx != 0) {
        metallic *= texture(textures[mat.metallic_idx], fragTexCoord).r;
    }
    
    // Sample and apply normal map (if present)
    vec3 N = normalize(fragNormal);
    if (mat.normal_idx != 0) {
        vec3 T = normalize(fragTangent);
        vec3 B = cross(N, T);
        mat3 TBN = mat3(T, B, N);
        
        vec3 normalMap = texture(textures[mat.normal_idx], fragTexCoord).xyz * 2.0 - 1.0;
        normalMap.xy *= mat.normal_strength;
        N = normalize(TBN * normalMap);
    }
    
    // Sample emissive (if present)
    vec3 emissive = mat.emissive_color * mat.emissive_intensity;
    if (mat.emissive_idx != 0) {
        emissive *= texture(textures[mat.emissive_idx], fragTexCoord).rgb;
    }
    
    // PBR lighting
    vec3 V = normalize(global.cameraPos - fragWorldPos);
    vec3 F0 = mix(vec3(0.04), albedo.rgb, metallic);
    
    vec3 Lo = vec3(0.0);
    // ... calculate PBR lighting with all lights ...
    
    // Add emissive
    vec3 color = Lo + emissive;
    
    outColor = vec4(color, albedo.a);
}
```

## Multi-Material Entities

Use entity hierarchy for objects with multiple materials:

```zig
// Car with multiple materials
const car_root = try scene.spawnEmpty();

// Body (opaque PBR)
const body = try scene.spawnChild(car_root);
try world.emplace(MeshRenderer, body, .{ .model_asset = body_mesh });
try world.emplace(MaterialSet, body, .{ .type = .opaque, .shader_variant = "pbr_standard" });
try world.emplace(AlbedoMaterial, body, ...);
try world.emplace(RoughnessMaterial, body, ...);
try world.emplace(MetallicMaterial, body, ...);

// Windows (transparent)
const windows = try scene.spawnChild(car_root);
try world.emplace(MeshRenderer, windows, .{ .model_asset = windows_mesh });
try world.emplace(MaterialSet, windows, .{ .type = .transparent, .shader_variant = "glass" });
try world.emplace(AlbedoMaterial, windows, ...);

// Headlights (emissive)
const headlights = try scene.spawnChild(car_root);
try world.emplace(MeshRenderer, headlights, .{ .model_asset = headlights_mesh });
try world.emplace(MaterialSet, headlights, .{ .type = .opaque, .shader_variant = "unlit" });
try world.emplace(EmissiveMaterial, headlights, ...);
```

## Benefits

1. **Pure ECS** - Components only, no domain-specific managers
2. **Flexible** - Mix and match any combination of material properties
3. **Efficient** - Only store what's needed (glass doesn't waste memory on metallic)
4. **Bindless** - Single shader handles all variations
5. **Query-Driven** - Systems automatically discover materials from components
6. **Cache-Friendly** - Components stored contiguously in dense arrays
7. **Parallel-Ready** - Systems can process materials in parallel batches

## Migration from Old System

Old system had:
- MaterialSystem (domain manager with "sets")
- TextureSystem (domain manager with texture arrays)
- Manual `addMaterialToSet()` calls

New system:
- ❌ Remove MaterialSystem domain manager
- ❌ Remove TextureSystem domain manager
- ✅ Add material components (AlbedoMaterial, RoughnessMaterial, etc.)
- ✅ Add MaterialSet component
- ✅ Systems query components and build GPU resources directly
- ✅ No manual bookkeeping - automatic discovery

## TODO

- [ ] Create material component definitions
- [ ] Update Scene.spawnProp() to use components
- [ ] Create material system that queries components
- [ ] Update shaders for bindless material access
- [ ] Update GeometryPass to use new system
- [ ] Update PathTracingPass to use new system
- [ ] Remove old MaterialSystem/TextureSystem
- [ ] Add material editor UI
