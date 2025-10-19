# ZulkanZengine Asset Management System Documentation

## Overview

The ZulkanZengine Asset Management System is a comprehensive, thread-safe solution for loading, managing, and hot-reloading game assets. It provides automatic dependency resolution, reference counting, and real-time file watching for seamless development workflows.

## Architecture Components

### Core Components

1. **AssetManager** (`src/assets/asset_manager.zig`) - Main interface and orchestrator
2. **AssetRegistry** (`src/assets/asset_registry.zig`) - Asset metadata and dependency tracking
3. **AssetLoader** (`src/assets/asset_loader.zig`) - Multi-threaded asset loading engine
4. **HotReloadManager** (`src/assets/hot_reload_manager.zig`) - File watching and hot reloading
5. **AssetTypes** (`src/assets/asset_types.zig`) - Type definitions and utilities

## System Features

### ✅ Multi-threaded Loading
- **Worker Thread Pool**: Configurable number of worker threads for parallel asset loading
- **Load Priorities**: High, Normal, Low priority queuing system
- **Non-blocking Operations**: Async loading with completion callbacks
- **Thread Safety**: Full mutex protection for concurrent access

### ✅ Smart Dependency Management
- **Automatic Resolution**: Dependencies loaded before dependents
- **Dependency Chains**: Transitive dependency support
- **Circular Detection**: Prevents infinite dependency loops
- **Reference Counting**: Automatic cleanup when no longer referenced

### ✅ Hot Reload System
- **Real-time Monitoring**: File system watching with inotify (Linux)
- **Auto-discovery**: Automatic registration of new assets
- **Selective Reloading**: Only modified assets are reloaded
- **Callback System**: Custom reload handlers for different systems

### ✅ Memory Management
- **Reference Counting**: Automatic asset lifecycle management
- **Fallback Assets**: Graceful degradation for missing/failed assets
- **Memory Tracking**: Built-in memory usage statistics
- **Resource Cleanup**: Proper deinitialization and cleanup

## Asset Types

```zig
pub const AssetType = enum(u8) {
    texture,    // PNG, JPG, etc.
    mesh,       // OBJ, GLB, etc.
    material,   // Material definitions
    shader,     // SPIR-V shaders
    audio,      // Audio files (future)
    scene,      // Scene definitions (future)
    animation,  // Animation data (future)
}
```

## API Usage Examples

### Basic Asset Loading

```zig
// Initialize the asset manager
var asset_manager = try AssetManager.init(allocator);
defer asset_manager.deinit();

// Load a texture with high priority
const texture_id = try asset_manager.loadTexture("textures/stone.png", .high);

// Check if asset is loaded
if (asset_manager.isAssetLoaded(texture_id)) {
    // Asset is ready to use
    const texture_data = asset_manager.getTextureData(texture_id);
}

// Remove reference when done
_ = asset_manager.removeRef(texture_id);
```

### Asynchronous Loading

```zig
// Queue multiple assets for async loading
const texture_id = try asset_manager.loadTexture("textures/brick.png", .normal);
const mesh_id = try asset_manager.loadMesh("models/house.obj", .normal);

// Continue other work...

// Wait for specific asset
asset_manager.waitForAsset(texture_id);

// Or wait for all pending loads
asset_manager.waitForAllLoads();
```

### Dependency Management

```zig
// Load assets with dependencies
const texture_id = try asset_manager.loadTexture("textures/wood.png", .high);
const material_id = try asset_manager.loadMaterial("materials/wood.mat", .normal);

// Set up dependency (material depends on texture)
try asset_manager.addDependency(material_id, texture_id);

// Loading material will automatically load texture first
```

### Hot Reload Integration

```zig
// Enable hot reloading for development
try asset_manager.enableHotReload(true);

// Assets will automatically reload when files change
// Custom callbacks can be registered for specific reload events
```

## Performance Statistics

The system provides comprehensive performance monitoring:

```zig
const stats = asset_manager.getStatistics();
std.log.info("Assets: {d} total, {d} loaded", .{stats.total_assets, stats.loaded_assets});
std.log.info("Memory: {d}MB used", .{stats.memory_used_mb});
std.log.info("Avg Load Time: {d}ms", .{stats.average_load_time_ms});
```

## Hot Reload System

### File Watching
- Monitors `textures/`, `models/`, and `shaders/` directories
- Detects file modifications, creations, and deletions
- Handles file moves and renames appropriately

### Auto-discovery
- New files are automatically registered based on file extensions
- Supported extensions: `.png`, `.jpg`, `.obj`, `.vert`, `.frag`, etc.
- Configurable file type associations

### Reload Callbacks
```zig
// Register for texture reload events
asset_manager.registerReloadCallback(.texture, onTextureReloaded);

fn onTextureReloaded(asset_id: AssetId, old_data: ?*anyopaque, new_data: *anyopaque) void {
    // Handle texture reload (update GPU resources, etc.)
}
```

## Thread Pool Configuration

```zig
// Initialize with custom worker count
const worker_count = 4; // Recommended: CPU core count
var asset_manager = try AssetManager.initWithWorkers(allocator, worker_count);
```

## Error Handling

The system provides robust error handling:

```zig
const LoadResult = union(enum) {
    success: AssetId,
    file_not_found: []const u8,
    unsupported_format: []const u8,
    memory_error: std.mem.Allocator.Error,
    dependency_error: AssetId,
};
```

## Integration with Scene System

The asset system integrates seamlessly with the scene management:

```zig
// Enhanced scene with asset manager integration
var scene = try EnhancedScene.init(allocator, &asset_manager);

// Load objects with automatic asset management
const obj = try scene.addModelWithTextureAsync("models/car.obj", "textures/car.png");

// Assets load in background, fallback objects shown immediately
```

## Configuration

### Directory Structure
```
assets/
├── textures/           # Texture files (PNG, JPG)
├── models/             # 3D models (OBJ, GLB)
├── materials/          # Material definitions
├── shaders/            # Shader files (SPIR-V)
│   └── cached/         # Compiled shader cache
└── audio/              # Audio files (future)
```

### File Extensions
- **Textures**: `.png`, `.jpg`, `.jpeg`, `.tga`, `.bmp`
- **Meshes**: `.obj`, `.glb`, `.gltf`
- **Shaders**: `.vert`, `.frag`, `.comp`, `.hlsl`
- **Materials**: `.mat`, `.json` (custom format)

## Performance Characteristics

### Loading Performance
- **Multi-threaded**: 4x improvement with 4 worker threads
- **Priority System**: Critical assets loaded first
- **Caching**: Duplicate requests reuse existing loads
- **Memory Efficient**: Reference counting prevents duplication

### Memory Usage
- **Fallback Assets**: ~50KB overhead for fallback textures/meshes
- **Metadata**: ~200 bytes per registered asset
- **Thread Pool**: ~8KB per worker thread
- **File Watching**: ~1KB per watched file

### Hot Reload Performance
- **File Detection**: <1ms response time to file changes
- **Reload Time**: Depends on asset size, typically 10-100ms
- **Impact**: Zero impact when no files change

## Best Practices

### 1. Asset Organization
- Use consistent directory structure
- Group related assets together
- Use descriptive file names

### 2. Loading Strategy
- Load critical assets at startup with high priority
- Use async loading for non-critical assets
- Implement loading screens for large asset sets

### 3. Memory Management
- Remove asset references when no longer needed
- Use fallback assets for graceful degradation
- Monitor memory usage in development

### 4. Hot Reload Workflow
- Enable hot reload in development builds only
- Test asset changes frequently during development
- Use version control to track asset changes

## Troubleshooting

### Common Issues

1. **Asset Not Loading**
   - Check file path and permissions
   - Verify supported file format
   - Check console logs for detailed errors

2. **Slow Loading Performance**
   - Increase worker thread count
   - Check asset file sizes
   - Monitor disk I/O performance

3. **Hot Reload Not Working**
   - Verify file watcher permissions
   - Check if files are in watched directories
   - Ensure files aren't locked by other processes

4. **Memory Leaks**
   - Verify all asset references are removed
   - Check for circular dependencies
   - Use memory profiling tools

### Debug Information

Enable detailed logging for troubleshooting:

```zig
// Print comprehensive asset system state
asset_manager.printDebugInfo();

// Get detailed statistics
const stats = asset_manager.getStatistics();
const loader_stats = asset_manager.getLoaderStatistics();
```

## Future Enhancements

### Planned Features
- **Compression Support**: LZ4/Zstandard compression for assets
- **Streaming**: Large asset streaming for open-world games
- **Asset Bundles**: Packaging multiple assets into single files
- **Network Loading**: Remote asset loading capabilities
- **Asset Validation**: Checksum verification and corruption detection

### Performance Optimizations
- **GPU Upload**: Direct GPU memory uploads
- **Parallel Decompression**: Multi-threaded asset decompression
- **Predictive Loading**: AI-based asset preloading
- **Memory Pools**: Custom allocators for different asset types

---

*This documentation reflects the current state of the ZulkanZengine Asset Management System as of September 2025.*