# ECS Asset Pipeline Architecture

## Overview
ECS renderers interact directly with AssetManager, bypassing SceneBridge which is legacy infrastructure for the old Scene system.

## Architecture

```
┌─────────────┐
│  Scene v2   │ (ECS-based)
└──────┬──────┘
       │ createMaterial()
       ▼
┌─────────────────┐
│  AssetManager   │
│                 │
│ • loaded_materials: ArrayList<*Material>
│ • material_buffer: Buffer (GPU)
│ • materials_dirty: bool
│ • material_buffer_updating: atomic<bool>
│                 │
│ • texture_image_infos: []DescriptorImageInfo  
│ • texture_descriptors_dirty: bool
│ • texture_descriptors_updating: atomic<bool>
└────────┬────────┘
         │ getMaterialIndex()
         │ getMaterialBuffer()
         │ getTextureDescriptors()
         ▼
┌─────────────────┐
│  EcsRenderer    │
│                 │
│ • Queries AssetManager for material buffer
│ • Checks materials_dirty flag
│ • Rebinds descriptors when dirty
│ • Directly accesses GPU buffers
└─────────────────┘
```

## Asset Dirty Tracking

### Material Buffer Updates

**When materials become dirty:**
1. `createMaterial()` called → sets `materials_dirty = true`
2. Texture finishes loading → sets `materials_dirty = true`
3. Material properties change → sets `materials_dirty = true`

**Update flow:**
```zig
// In AssetManager:
pub fn createMaterial(self: *AssetManager, texture_id: AssetId) !AssetId {
    // ... create material ...
    self.materials_dirty = true;  // Mark for GPU update
}

// AssetManager periodically checks:
pub fn update(self: *AssetManager) !void {
    if (self.materials_dirty) {
        try self.queueMaterialBufferUpdate();  // Async GPU upload
    }
}

// Worker thread uploads to GPU:
fn materialBufferUpdateWorker(work: *WorkItem) void {
    // Upload loaded_materials → material_buffer (GPU)
    // ...
    asset_manager.materials_dirty = false;
    asset_manager.material_buffer_updating.store(false, .release);
}
```

### Texture Descriptor Updates

**When textures become dirty:**
1. New texture loaded → sets `texture_descriptors_dirty = true`
2. Texture hot-reloaded → sets `texture_descriptors_dirty = true`

**Update flow:**
```zig
pub fn update(self: *AssetManager) !void {
    if (self.texture_descriptors_dirty) {
        try self.queueTextureDescriptorUpdate();  // Async descriptor rebuild
    }
}
```

## ECS Renderer Integration

### Initialization
```zig
pub fn init(
    asset_manager: *AssetManager,
    // ... other params
) !EcsRenderer {
    // Store direct reference to AssetManager
    return EcsRenderer{
        .asset_manager = asset_manager,
        // ...
    };
}
```

### Descriptor Binding
```zig
pub fn onCreate(self: *EcsRenderer) !void {
    // Get material buffer directly from AssetManager
    if (self.asset_manager.material_buffer) |buffer| {
        const material_resource = Resource{
            .buffer = .{
                .buffer = buffer.buffer,
                .offset = 0,
                .range = buffer.buffer_size,
            },
        };
        
        // Bind to descriptor set 1, binding 0
        try self.pipeline_system.bindResource(
            self.ecs_pipeline, 
            1, 0, 
            material_resource, 
            frame
        );
    }
    
    // Get texture array directly from AssetManager
    const texture_infos = self.asset_manager.getTextureDescriptorArray();
    if (texture_infos.len > 0) {
        const textures_resource = Resource{
            .image_array = texture_infos
        };
        
        // Bind to descriptor set 1, binding 1
        try self.pipeline_system.bindResource(
            self.ecs_pipeline,
            1, 1,
            textures_resource,
            frame
        );
    }
}
```

### Render Loop with Dirty Checks
```zig
pub fn render(self: *EcsRenderer, frame_info: FrameInfo) !void {
    const frame_index = frame_info.current_frame;
    
    // Check if material buffer was updated
    const materials_dirty = self.asset_manager.materials_dirty;
    
    // Check if texture descriptors were updated
    const textures_dirty = self.asset_manager.texture_descriptors_dirty;
    
    // Rebind descriptors if anything changed
    if (materials_dirty or textures_dirty or self.descriptor_dirty_flags[frame_index]) {
        try self.rebindDescriptors(frame_index);
        self.descriptor_dirty_flags[frame_index] = false;
    }
    
    // ... render entities ...
}

fn rebindDescriptors(self: *EcsRenderer, frame: u32) !void {
    // Get fresh material buffer
    if (self.asset_manager.material_buffer) |buffer| {
        const material_resource = Resource{
            .buffer = .{
                .buffer = buffer.buffer,
                .offset = 0,
                .range = buffer.buffer_size,
            },
        };
        try self.pipeline_system.bindResource(self.ecs_pipeline, 1, 0, material_resource, frame);
    }
    
    // Get fresh texture array
    const texture_infos = self.asset_manager.getTextureDescriptorArray();
    if (texture_infos.len > 0) {
        const textures_resource = Resource{ .image_array = texture_infos };
        try self.pipeline_system.bindResource(self.ecs_pipeline, 1, 1, textures_resource, frame);
    }
    
    // Update descriptor sets
    try self.pipeline_system.updateDescriptorSetsForPipeline(self.ecs_pipeline, frame);
}
```

## Benefits

1. **Simpler Architecture**: Direct AssetManager access, no SceneBridge wrapper
2. **Clearer Ownership**: AssetManager owns all GPU resource state
3. **Unified Asset System**: All asset types managed in one place
4. **Atomic Updates**: Material buffer and texture updates are thread-safe
5. **Lazy Rebuilds**: Dirty flags prevent unnecessary GPU uploads
6. **Hot Reload Ready**: Shader and texture changes automatically propagate

## Migration Path

### Phase 1: ✅ Scene v2 uses AssetManager.createMaterial()
- Scene v2 properly registers materials with AssetManager
- Materials get added to `loaded_materials` array
- Material indices work correctly

### Phase 2: ECS Renderer Direct Access (Next)
- Remove SceneBridge dependency from EcsRenderer.init()
- Get material buffer directly from AssetManager
- Get texture descriptors directly from AssetManager
- Check dirty flags directly on AssetManager

### Phase 3: SceneBridge Becomes Legacy
- Only old Scene uses SceneBridge
- SceneBridge becomes thin wrapper for backward compatibility
- Eventually deprecated when old Scene is removed

## Implementation Notes

### Thread Safety
- AssetManager uses mutexes for material/texture arrays
- Atomic flags for dirty state and update-in-progress
- GPU upload happens on thread pool, render thread reads atomically

### Performance
- Dirty flags prevent redundant descriptor updates
- Material buffer grows but doesn't shrink (reduce allocations)
- Texture descriptor array rebuilt lazily only when needed

### Memory Management
- AssetManager owns all GPU buffers
- Renderers only hold borrowed references
- Cleanup handled in AssetManager.deinit()
