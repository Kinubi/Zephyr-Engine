# Material and Texture Sets System

## Overview

The MaterialSystem and TextureSystem now support **named sets** for organizing materials and textures into separate collections. This allows different render passes to use different material/texture groups.

## Architecture

```
TextureSystem
  ├─ "opaque" TextureSet
  │   ├─ texture_1.png
  │   ├─ texture_2.png
  │   └─ descriptor_array[] (GPU descriptors)
  │
  └─ "transparent" TextureSet
      ├─ texture_3.png
      └─ descriptor_array[] (GPU descriptors)

MaterialSystem
  ├─ "opaque" MaterialBufferSet
  │   ├─ Linked to "opaque" TextureSet
  │   ├─ material_1, material_2
  │   └─ GPU buffer (SSBO)
  │
  └─ "transparent" MaterialBufferSet
      ├─ Linked to "transparent" TextureSet
      ├─ material_3
      └─ GPU buffer (SSBO)
```

## Usage

### 1. Create Texture Set

```zig
// Create a named texture set
const opaque_texture_set = try texture_system.createSet("opaque");

// Add textures to the set
try texture_system.addTextureToSet("opaque", albedo_texture_id);
try texture_system.addTextureToSet("opaque", roughness_texture_id);

// Rebuild the texture set's descriptor array
try texture_system.rebuildTextureSet("opaque");
```

### 2. Create Material Set (Linked to Texture Set)

```zig
// Create material set linked to texture set
const opaque_materials = try material_system.createSet("opaque", "opaque");

// Add materials to the set
try material_system.addMaterialToSet("opaque", material_1_id);
try material_system.addMaterialToSet("opaque", material_2_id);

// Rebuild the material buffer
try material_system.rebuildMaterialSet("opaque", frame_index);
```

### 3. Bind Resources for Rendering

```zig
// Get the buffers/descriptors
const material_buffer = material_system.getBuffer("opaque").?;
const texture_descriptors = texture_system.getDescriptorArrayForSet("opaque").?;

// Bind to pipeline via ResourceBinder
try resource_binder.bindStorageBufferNamed(
    pipeline, 
    "MaterialBuffer", 
    material_buffer, 
    0, 
    vk.WHOLE_SIZE
);

try resource_binder.bindTextureArray(
    pipeline,
    "textures",
    texture_descriptors
);
```

## Complete Example

```zig
// === Setup Phase ===

// 1. Create texture sets for different material types
_ = try texture_system.createSet("opaque");
_ = try texture_system.createSet("transparent");

// 2. Load textures and assign to sets
const albedo_id = try asset_manager.loadTexture("wall_albedo.png");
try texture_system.addTextureToSet("opaque", albedo_id);

const glass_albedo_id = try asset_manager.loadTexture("glass.png");
try texture_system.addTextureToSet("transparent", glass_albedo_id);

// 3. Rebuild texture descriptor arrays
try texture_system.rebuildTextureSet("opaque");
try texture_system.rebuildTextureSet("transparent");

// 4. Create material sets linked to texture sets
_ = try material_system.createSet("opaque", "opaque");
_ = try material_system.createSet("transparent", "transparent");

// 5. Load materials and assign to sets
const wall_material_id = try asset_manager.loadMaterial("wall.mat");
try material_system.addMaterialToSet("opaque", wall_material_id);

const glass_material_id = try asset_manager.loadMaterial("glass.mat");
try material_system.addMaterialToSet("transparent", glass_material_id);

// 6. Rebuild material buffers
try material_system.rebuildMaterialSet("opaque", frame_index);
try material_system.rebuildMaterialSet("transparent", frame_index);


// === Render Phase ===

// Render opaque pass
{
    const material_buffer = material_system.getBuffer("opaque").?;
    const textures = texture_system.getDescriptorArrayForSet("opaque").?;
    
    try resource_binder.bindStorageBufferNamed(
        opaque_pipeline, 
        "MaterialBuffer", 
        material_buffer, 
        0, 
        vk.WHOLE_SIZE
    );
    
    // ... draw opaque objects ...
}

// Render transparent pass
{
    const material_buffer = material_system.getBuffer("transparent").?;
    const textures = texture_system.getDescriptorArrayForSet("transparent").?;
    
    try resource_binder.bindStorageBufferNamed(
        transparent_pipeline, 
        "MaterialBuffer", 
        material_buffer, 
        0, 
        vk.WHOLE_SIZE
    );
    
    // ... draw transparent objects ...
}
```

## Automatic Generation Tracking

Both systems use **generation numbers** that increment when data changes:

- **TextureSet.generation** - Increments when `rebuildTextureSet()` is called
- **MaterialBufferSet.buffer.generation** - Increments when `rebuildMaterialSet()` is called

The ResourceBinder automatically tracks these generations and rebinds descriptors when changes are detected.

## Benefits

1. **Separation**: Different passes can use completely different material/texture sets
2. **Memory Efficiency**: Only load textures/materials needed for each pass
3. **Flexibility**: Easy to add new sets for UI, particles, post-processing, etc.
4. **Cache Coherency**: Materials using similar textures stay together in memory
5. **Automatic Rebinding**: Generation tracking handles GPU updates transparently

## Migration from Old API

### Old (Single Global Buffer):
```zig
const buffer = material_system.getCurrentBuffer();
```

### New (Named Sets):
```zig
const buffer = material_system.getBuffer("opaque").?;
```

### Old (Global Texture Array):
```zig
const textures = texture_system.getDescriptorArray();
```

### New (Named Texture Sets):
```zig
const textures = texture_system.getDescriptorArrayForSet("opaque").?;
```
