# Asset System Quick Reference

## Initialization
```zig
var asset_manager = try AssetManager.init(allocator);
defer asset_manager.deinit();

// Enable hot reload for development
try asset_manager.enableHotReload(true);
```

## Loading Assets

### Textures
```zig
// Synchronous loading
const texture_id = try asset_manager.loadTexture("textures/stone.png", .high);

// Asynchronous loading
const texture_id = try asset_manager.loadTextureAsync("textures/brick.png", .normal);
asset_manager.waitForAsset(texture_id);
```

### Meshes
```zig
// Load 3D model
const mesh_id = try asset_manager.loadMesh("models/house.obj", .normal);
```

### Materials
```zig
// Load material with automatic texture dependencies
const material_id = try asset_manager.loadMaterial("materials/wood.mat", .normal);
```

## Asset Management

### Reference Counting
```zig
// Add reference (prevents asset from being unloaded)
asset_manager.addRef(texture_id);

// Remove reference (returns true if asset can be unloaded)
const can_unload = asset_manager.removeRef(texture_id);
```

### Status Checking
```zig
// Check if asset is loaded and ready
if (asset_manager.isAssetLoaded(texture_id)) {
    // Safe to use asset
}

// Get asset state
const state = asset_manager.getAssetState(texture_id);
// States: .unloaded, .loading, .loaded, .failed
```

## Dependencies
```zig
// Set up dependency chain
try asset_manager.addDependency(material_id, texture_id);
// Loading material will automatically load texture first

// Get dependencies
const deps = asset_manager.getDependencies(material_id);
```

## Performance Monitoring
```zig
// Get current statistics
const stats = asset_manager.getStatistics();
std.log.info("Assets: {d} loaded, Memory: {d}MB", .{
    stats.loaded_assets, 
    stats.memory_used_mb
});

// Print detailed debug info
asset_manager.printDebugInfo();
```

## Scene Integration
```zig
// Initialize enhanced scene with asset manager
var scene = try EnhancedScene.init(allocator, &asset_manager);

// Load object with automatic fallback
const obj = try scene.addModelWithTextureAsync(
    "models/car.obj", 
    "textures/car_diffuse.png"
);

// Object appears immediately with fallback, real assets load in background
```

## Hot Reload Callbacks
```zig
// Register for asset reload events
asset_manager.registerReloadCallback(.texture, onTextureReloaded);

fn onTextureReloaded(asset_id: AssetId, context: ?*anyopaque) void {
    // Update GPU resources, refresh renderers, etc.
}
```

## Common Patterns

### Batch Loading
```zig
// Queue multiple assets
const ids = [_]AssetId{
    try asset_manager.loadTexture("tex1.png", .normal),
    try asset_manager.loadTexture("tex2.png", .normal),
    try asset_manager.loadMesh("model.obj", .normal),
};

// Wait for all to complete
asset_manager.waitForAllLoads();
```

### Fallback Handling
```zig
// Get asset data with fallback
const texture_data = asset_manager.getTextureDataSafe(texture_id);
// Returns fallback texture if original failed/not ready
```

### Memory Management
```zig
// Cleanup unused assets
asset_manager.garbageCollect();

// Force unload specific asset
asset_manager.forceUnload(asset_id);
```

## File Extensions Supported
- **Textures**: `.png`, `.jpg`, `.jpeg`, `.tga`, `.bmp`
- **Meshes**: `.obj`, `.glb`, `.gltf` 
- **Shaders**: `.vert`, `.frag`, `.comp`, `.hlsl`
- **Materials**: `.mat`, `.json`

## Load Priorities
- `.high` - Critical assets (UI, player character)
- `.normal` - Regular game assets
- `.low` - Background/optional assets

## Error Handling
```zig
const texture_id = asset_manager.loadTexture("missing.png", .normal) catch |err| switch (err) {
    error.FileNotFound => {
        // Use fallback asset
        asset_manager.getFallbackTexture()
    },
    else => return err,
};
```

## Performance Tips
1. **Use async loading** for non-critical assets
2. **Remove references** when objects are destroyed
3. **Group similar assets** in same directory
4. **Enable hot reload** only in debug builds
5. **Monitor memory usage** with statistics
6. **Use fallback assets** for graceful degradation

## Thread Safety
- All AssetManager functions are thread-safe
- Asset data pointers remain valid until reference count reaches zero
- Hot reload callbacks are called from the main thread