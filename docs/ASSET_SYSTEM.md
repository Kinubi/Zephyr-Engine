# Asset Management System

**Last Updated**: October 24, 2025  
**Status**: ✅ Implemented

## Overview

The Asset Management System provides thread-safe, async asset loading with hot-reload support. It integrates with the ThreadPool for parallel loading and tracks asset lifecycle through reference counting and state management.

## Core Components

- **AssetManager** (`src/assets/asset_manager.zig`) - Main API for loading and accessing assets
- **AssetRegistry** (`src/assets/asset_registry.zig`) - Metadata and state tracking
- **AssetLoader** (`src/assets/asset_loader.zig`) - ThreadPool-integrated async loading
- **HotReloadManager** (`src/assets/hot_reload_manager.zig`) - File watching and auto-reload

## Asset Types

```zig
pub const AssetType = enum(u8) {
    texture,
    mesh,
    material,
    shader,
};

pub const AssetState = enum(u8) {
    unloaded,
    loading,
    staged,   // GPU upload pending
    loaded,
    failed,
};
```

## API Reference

### Initialization

```zig
// Initialize with graphics context and thread pool
var asset_manager = try AssetManager.init(allocator, graphics_context, thread_pool);
defer asset_manager.deinit();

// Optional: Enable hot-reload with file watcher
var file_watcher = try FileWatcher.init(allocator);
try asset_manager.initHotReload(&file_watcher);
```

### Loading Assets

#### Async Loading (Recommended)

```zig
// Load texture asynchronously with priority
const texture_id = try asset_manager.loadAssetAsync(
    "textures/brick.png",
    .texture,
    .normal  // LoadPriority: critical, high, normal, low
);

// Load model asynchronously
const model_id = try asset_manager.loadAssetAsync(
    "models/viking_room.obj",
    .mesh,
    .high
);

// Check if asset is ready
if (asset_manager.isAssetReady(texture_id)) {
    // Asset is loaded and ready to use
}
```

#### Synchronous Loading

```zig
// Load texture synchronously (blocks until complete)
const texture_id = try asset_manager.loadTextureSync("textures/stone.png");

// Immediate use
if (asset_manager.getTexture(texture_id)) |texture| {
    // Use texture immediately
}
```

### Accessing Assets

#### Textures

```zig
// Get loaded texture (returns ?*Texture)
if (asset_manager.getTexture(texture_id)) |texture| {
    // Use texture.image, texture.view, texture.sampler
}

// Get texture for rendering (returns fallback if not ready)
const render_texture_id = asset_manager.getAssetIdForRendering(texture_id);
```

#### Models

```zig
// Get loaded model (returns ?*Model)
if (asset_manager.getModel(model_id)) |model| {
    // Iterate meshes
    for (model.meshes.items) |mesh| {
        mesh.draw(graphics_context, command_buffer);
    }
}

// Get const model reference
if (asset_manager.getLoadedModelConst(model_id)) |model| {
    // Read-only access
}
```

#### Materials

```zig
// Create material with texture reference
const material_id = try asset_manager.createMaterial(albedo_texture_id);

// Get material index for shader binding
if (asset_manager.getMaterialIndex(material_id)) |index| {
    // Use index in material buffer
}
```

### Descriptor Management

#### Texture Descriptors

```zig
// Queue texture descriptor update (async on thread pool)
try asset_manager.queueTextureDescriptorUpdate();

// In render loop - check if update is complete
asset_manager.beginFrame();
if (asset_manager.texture_descriptors_updated) {
    // Texture descriptor array has been updated
    const image_infos = asset_manager.getTextureDescriptorArray();
    // Bind to descriptor set
}
```

#### Material Buffer

```zig
// Queue material buffer update
try asset_manager.queueMaterialBufferUpdate();

// Check if materials updated
if (asset_manager.materials_updated) {
    // Material buffer has been updated
    // Rebind descriptor sets if needed
}

// Clean up stale buffers after frame submission
asset_manager.flushStaleMaterialBuffers();
```

## Load Priorities

```zig
pub const LoadPriority = enum(u8) {
    critical = 0,  // UI textures, fallback assets
    high = 1,      // Player-visible objects
    normal = 2,    // Background objects
    low = 3,       // Preloading, optimization
};

// Helper for distance-based priority
const priority = LoadPriority.fromDistance(distance_to_camera);
```

## Fallback Assets

The system provides automatic fallbacks for missing or loading assets:

```zig
pub const FallbackType = enum {
    missing,  // Pink checkerboard for missing textures
    loading,  // Animated or placeholder for loading
    failed,   // Error indicator
    default,  // Basic white texture
};

// Get fallback asset
const fallback_id = asset_manager.getFallbackAsset(.missing, .texture);
```

## Hot Reload

### Enabling Hot Reload

```zig
// Initialize with file watcher
var file_watcher = try FileWatcher.init(allocator);
try asset_manager.initHotReload(&file_watcher);

// Assets are automatically registered for hot reload on load
// File changes trigger automatic reload via thread pool
```

### How It Works

1. FileWatcher monitors asset directories (textures/, models/, shaders/)
2. File changes detected via inotify (Linux) or polling
3. HotReloadManager queues reload work on thread pool
4. AssetLoader reloads asset in background
5. Asset pointers updated atomically
6. Dependent systems (pipelines, descriptors) notified

## Statistics

```zig
const stats = asset_manager.getStatistics();

// Available metrics:
// - stats.total_loaded_textures: usize
// - stats.total_loaded_models: usize
// - stats.total_loaded_materials: usize
// - stats.texture_memory_mb: f32
// - stats.model_memory_mb: f32

// Print performance report
asset_manager.printPerformanceReport();
```

## Thread Safety

- **AssetManager**: Mutex-protected public API
- **AssetRegistry**: Internal mutex for metadata updates
- **AssetLoader**: Lock-free work queue, thread-safe completion callbacks
- **Texture/Model Maps**: Separate mutexes (textures_mutex, models_mutex)

## Usage Patterns

### Scene Setup

```zig
// Load assets for scene
const floor_texture = try asset_manager.loadAssetAsync("textures/floor.png", .texture, .normal);
const floor_model = try asset_manager.loadAssetAsync("models/floor.obj", .mesh, .normal);
const floor_material = try asset_manager.createMaterial(floor_texture);

// Create ECS entity
const entity = try ecs_world.createEntity();
try ecs_world.emplace(Transform, entity, Transform.init());
try ecs_world.emplace(MeshRenderer, entity, MeshRenderer.init(floor_model, floor_material));

// Rendering happens automatically when assets are loaded
// Fallbacks displayed until real assets ready
```

### Per-Frame Update

```zig
pub fn update(self: *App) !void {
    // Mark frame start
    self.asset_manager.beginFrame();
    
    // Check for descriptor updates
    if (self.asset_manager.texture_descriptors_updated) {
        // Rebuild descriptor sets with new texture array
        try self.updateTextureDescriptors();
        self.asset_manager.texture_descriptors_updated = false;
    }
    
    if (self.asset_manager.materials_updated) {
        // Material buffer updated, no action needed (auto-bound)
        self.asset_manager.materials_updated = false;
    }
    
    // Other update logic...
}

pub fn endFrame(self: *App) void {
    // Clean up stale buffers after GPU submission
    self.asset_manager.flushStaleMaterialBuffers();
}
```

### Error Handling

```zig
// Load with error handling
const texture_id = asset_manager.loadAssetAsync(
    "textures/missing.png",
    .texture,
    .normal
) catch |err| {
    log(.ERROR, "app", "Failed to load texture: {}", .{err});
    // Use fallback
    break :blk asset_manager.getFallbackAsset(.missing, .texture);
};

// Check asset state
if (asset_manager.registry.getAsset(texture_id)) |metadata| {
    switch (metadata.state) {
        .loaded => {
            // Asset ready
        },
        .loading => {
            // Still loading, use fallback
        },
        .failed => {
            // Load failed, use error fallback
        },
        else => {},
    }
}
```

## Integration with Other Systems

### ECS Integration

```zig
// MeshRenderer component stores AssetIds
pub const MeshRenderer = struct {
    model_asset: AssetId,
    material_asset: ?AssetId = null,
    texture_override: ?AssetId = null,
    enabled: bool = true,
};

// RenderSystem extracts assets for rendering
const raster_data = try render_system.getRasterData();
for (raster_data.objects) |object| {
    if (asset_manager.getModel(object.mesh_handle)) |model| {
        model.draw(graphics_context, command_buffer);
    }
}
```

### Pipeline System Integration

```zig
// Shaders hot-reload via shader_manager + asset_manager
// Material buffer bound to descriptor set 0, binding 2
// Texture descriptor array bound to descriptor set 0, binding 3

// Queue updates when new assets loaded
if (asset_manager.texture_descriptors_dirty) {
    try asset_manager.queueTextureDescriptorUpdate();
}

if (asset_manager.materials_dirty) {
    try asset_manager.queueMaterialBufferUpdate();
}
```

## Performance Considerations

- **Async Loading**: Use `loadAssetAsync` for non-blocking loads
- **Priority System**: Use appropriate priorities to load critical assets first
- **Descriptor Batching**: Descriptor updates are batched and async
- **Material Buffer**: Single GPU buffer for all materials (cache-friendly)
- **Fallback Strategy**: Immediate display of fallbacks prevents stalls
- **Thread Pool Integration**: Leverages all CPU cores for loading

## Limitations

- **Texture Limit**: Currently supports up to 1024 textures in descriptor array
- **Material Limit**: No hard limit, but larger buffers increase update cost
- **File Watching**: Linux-only (inotify), other platforms use polling
- **Texture Formats**: Limited to formats supported by stb_image (PNG, JPG, TGA, BMP)
- **Model Formats**: Currently OBJ only (via tinyobj loader)

## Future Work

- [ ] GLTF/GLB model support
- [ ] Compressed texture formats (BC7, ASTC)
- [ ] Streaming for large assets (mip levels, LODs)
- [ ] Asset bundles/packaging
- [ ] Reference counting and automatic unloading
- [ ] Memory budget management
- [ ] Cross-platform file watching

---

**See Also:**
- [ECS System](ECS_SYSTEM.md) for entity-component integration
- [Unified Pipeline Migration](UNIFIED_PIPELINE_MIGRATION.md) for shader/pipeline management
- [Enhanced Thread Pool](ENHANCED_THREAD_POOL.md) for threading model
