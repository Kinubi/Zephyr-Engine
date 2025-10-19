# Asset System Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                    ZulkanZengine Asset System                       │
└─────────────────────────────────────────────────────────────────────┘

                              Application Layer
┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐
│   Game Scene    │  │   Renderer      │  │  User Code      │
│                 │  │                 │  │                 │
│ - Objects       │  │ - Textures      │  │ - Custom Logic  │
│ - Components    │  │ - Meshes        │  │ - Event Handler │
│ - Transforms    │  │ - Materials     │  │ - UI Systems    │
└─────────┬───────┘  └─────────┬───────┘  └─────────┬───────┘
          │                    │                    │
          └────────────────────┼────────────────────┘
                               │
                    ┌──────────▼──────────┐
                    │   AssetManager      │◄── Main API Interface
                    │                     │
                    │ ┌─ Public Methods ─┐│
                    │ │ • loadTexture()  ││
                    │ │ • loadMesh()     ││
                    │ │ • addRef()       ││
                    │ │ • removeRef()    ││
                    │ │ • waitForAsset() ││
                    │ │ • getStatistics()││
                    │ └──────────────────┘│
                    └──┬──────────┬───────┘
                       │          │
              ┌────────▼─┐    ┌───▼──────────┐
              │Registry  │    │ HotReload    │
              │          │    │ Manager      │
              │┌────────┐│    │              │
              ││Assets  ││    │┌────────────┐│
              ││        ││    ││FileWatcher ││
              ││• Meta  ││    ││            ││
              ││• State ││    ││• inotify   ││
              ││• Deps  ││    ││• Callbacks ││
              │└────────┘│    ││• Discovery ││
              │          │    │└────────────┘│
              └────┬─────┘    └───────┬──────┘
                   │                  │
                   │    ┌─────────────▼─────────────┐
                   │    │        File System        │
                   │    │                           │
                   │    │  textures/  models/  etc/ │
                   │    └───────────────────────────┘
                   │
        ┌──────────▼──────────┐
        │    AssetLoader      │◄── Multi-threaded Loading Engine
        │                     │
        │  ┌─ Thread Pool ───┐│
        │  │                 ││
        │  │ Worker 1 ────┐  ││    ┌─ Load Priorities ─┐
        │  │              │  ││    │ • High Priority   │
        │  │ Worker 2 ────┼──┼┼────┤ • Normal Priority │
        │  │              │  ││    │ • Low Priority    │
        │  │ Worker N ────┘  ││    └───────────────────┘
        │  │                 ││
        │  │ ┌─ Load Queue ─┐ ││
        │  │ │ │ │ │ │ │ │ │ ││
        │  │ └─ Priority ───┘ ││
        │  └─────────────────┘│
        └──┬──────────────────┘
           │
           │                            
           ▼                            
 ┌─ Asset Type Loading ─┐               
 │                      │               
 │ ┌─ Texture Loader ─┐ │  ┌─ Asset States ─┐
 │ │ • PNG/JPG        │ │  │                │
 │ │ • Format Conv.   │ │  │ • Unloaded     │
 │ │ • GPU Upload     │ │  │ • Loading      │
 │ └──────────────────┘ │  │ • Loaded       │
 │                      │  │ • Failed       │
 │ ┌─ Mesh Loader ────┐ │  └────────────────┘
 │ │ • OBJ Parser     │ │
 │ │ • Vertex Data    │ │  ┌─ Memory Mgmt ──┐
 │ │ • Index Data     │ │  │                │
 │ └──────────────────┘ │  │ • Ref Counting │
 │                      │  │ • Garbage GC   │
 │ ┌─ Material Loader ┐ │  │ • Fallbacks    │
 │ │ • Dependencies   │ │  │ • Statistics   │
 │ │ • Textures       │ │  └────────────────┘
 │ └──────────────────┘ │
 └──────────────────────┘

 Data Flow:
 
 1. Application requests asset via AssetManager
 2. AssetManager checks Registry for existing asset
 3. If not loaded, AssetManager queues work in AssetLoader
 4. AssetLoader assigns work to available thread worker
 5. Worker loads asset from file system
 6. Worker updates Registry with loaded data
 7. AssetManager notifies application of completion
 8. HotReloadManager monitors files and triggers reloads

 Dependencies:
 
 AssetManager ──► AssetRegistry (asset metadata)
             ├─► AssetLoader   (loading engine)  
             └─► HotReloadManager (file watching)
             
 AssetLoader ──► ThreadPool    (worker threads)
            └─► FileSystem    (asset files)
            
 HotReloadManager ──► FileWatcher (inotify)
                 └─► FileSystem  (monitoring)

 Thread Safety:
 - AssetManager: Mutex-protected public API
 - AssetRegistry: Internal mutex for metadata
 - AssetLoader: Lock-free work queue + worker synchronization
 - HotReloadManager: Callback serialization to main thread
```

## Component Responsibilities

### AssetManager (Orchestrator)
- **Public API**: Single point of entry for all asset operations
- **Coordination**: Manages interactions between Registry, Loader, and HotReload
- **Reference Counting**: Tracks asset usage and lifetime
- **Statistics**: Provides performance and memory usage metrics

### AssetRegistry (Metadata Store)
- **Asset Metadata**: Stores file paths, types, states, load times
- **Dependency Graph**: Manages asset dependencies and load order
- **State Tracking**: Monitors loading progress and completion
- **Path Mapping**: Maps file paths to Asset IDs

### AssetLoader (Loading Engine)  
- **Thread Pool**: Manages configurable number of worker threads
- **Priority Queue**: Schedules high-priority assets first
- **Format Support**: Handles different asset file formats
- **Progress Tracking**: Reports loading progress and completion

### HotReloadManager (Development Support)
- **File System Monitoring**: Uses inotify for real-time file watching
- **Auto-discovery**: Detects new assets and registers them automatically
- **Selective Reloading**: Only reloads changed assets
- **Callback System**: Notifies systems when assets are reloaded

### Integration Points

The asset system integrates with other engine systems:

- **Scene System**: Automatic asset loading for game objects
- **Renderer**: Texture and mesh data for GPU resources
- **Material System**: Shader and texture dependencies
- **Audio System**: Future audio asset support
- **Scripting**: Asset references in game logic