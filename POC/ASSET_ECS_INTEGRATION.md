# Asset Manager + ECS Integration Approach

## Overview

This document defines the architectural approach for integrating the Asset Manager with the Entity Component System (ECS) in ZulkanZengine. The goal is to create a seamless, performant, and developer-friendly system where assets and entities work together efficiently.

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           ZulkanZengine Application                      │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐     │
│  │   ECS World     │◄──►│  Asset Manager  │◄──►│ Unified Renderer│     │
│  │                 │    │                 │    │                 │     │
│  │ • Entities      │    │ • Resource Pool │    │ • Render Passes │     │
│  │ • Components    │    │ • Dependencies  │    │ • GPU Resources │     │
│  │ • Systems       │    │ • Hot Reloading │    │ • Optimization  │     │
│  │ • Queries       │    │ • Async Loading │    │ • Batching      │     │
│  └─────────────────┘    └─────────────────┘    └─────────────────┘     │
│           │                       │                       │             │
│           └───────────────────────┼───────────────────────┘             │
│                                   │                                     │
│  ┌─────────────────────────────────▼─────────────────────────────────┐   │
│  │                     Integration Layer                              │   │
│  │                                                                    │   │
│  │  • AssetComponent Bridge     • Change Notification System         │   │
│  │  • Resource Lifetime Mgmt    • Scene Serialization               │   │
│  │  • Dependency Resolution     • Performance Monitoring             │   │
│  └────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────┘
```

## Core Integration Principles

### 1. Asset-Component Separation
**Principle**: Assets (data) and Components (entity references) remain separate but connected.

```zig
// WRONG: Component contains asset data directly
pub const MeshComponent = struct {
    vertices: []Vertex,     // ❌ Duplicated data
    indices: []u32,         // ❌ Memory waste
    material: Material,     // ❌ Coupling
};

// CORRECT: Component references asset via ID
pub const MeshRendererComponent = struct {
    mesh_id: AssetId,       // ✅ Reference only
    material_id: AssetId,   // ✅ Lightweight
    render_flags: u32,      // ✅ Entity-specific data
    layer: RenderLayer,     // ✅ Runtime configuration
};
```

**Benefits**:
- Multiple entities can share same asset (memory efficiency)
- Asset hot reloading automatically affects all entities using it
- Clear separation between resource data and entity state

### 2. Reactive Asset Updates
**Principle**: When assets change, affected entities are automatically updated.

```zig
pub const AssetChangeNotifier = struct {
    listeners: std.HashMap(AssetId, std.ArrayList(*SystemInterface)),
    
    pub fn notifyAssetChanged(self: *Self, asset_id: AssetId, change_type: ChangeType) !void {
        if (self.listeners.get(asset_id)) |systems| {
            for (systems.items) |system| {
                try system.onAssetChanged(asset_id, change_type);
            }
        }
        
        // Also notify ECS world for component updates
        try self.notifyECSComponents(asset_id, change_type);
    }
    
    fn notifyECSComponents(self: *Self, asset_id: AssetId, change_type: ChangeType) !void {
        // Find all entities using this asset
        var query = self.world.query(struct { 
            mesh_renderer: *MeshRendererComponent 
        });
        
        var it = query.iterator();
        while (it.next()) |result| {
            const mesh_renderer = result.components.mesh_renderer;
            if (mesh_renderer.mesh_id == asset_id or mesh_renderer.material_id == asset_id) {
                // Mark entity as needing update
                try self.world.addComponent(result.entity, AssetChangedTag{
                    .asset_id = asset_id,
                    .change_type = change_type,
                });
            }
        }
    }
};

pub const AssetChangedTag = struct {
    asset_id: AssetId,
    change_type: ChangeType,
};
```

### 3. Lazy Asset Loading
**Principle**: Assets are loaded on-demand when entities are created or when explicitly requested.

```zig
pub const LazyAssetComponent = struct {
    asset_path: []const u8,
    asset_id: ?AssetId = null,
    load_state: LoadState = .unloaded,
    
    pub const LoadState = enum {
        unloaded,
        loading,
        loaded,
        failed,
    };
};

pub const AssetLoadingSystem = struct {
    pub fn update(self: *Self, world: *World, delta_time: f32) !void {
        // Process entities with pending asset loads
        var query = world.query(struct {
            lazy_asset: *LazyAssetComponent,
            mesh_renderer: *MeshRendererComponent,
        });
        
        var it = query.iterator();
        while (it.next()) |result| {
            const lazy = result.components.lazy_asset;
            const mesh_renderer = result.components.mesh_renderer;
            
            switch (lazy.load_state) {
                .unloaded => {
                    // Start async loading
                    const asset_id = try self.asset_manager.loadAsync(lazy.asset_path);
                    lazy.asset_id = asset_id;
                    lazy.load_state = .loading;
                },
                .loading => {
                    // Check if loading completed
                    if (lazy.asset_id) |asset_id| {
                        if (self.asset_manager.isLoaded(asset_id)) {
                            mesh_renderer.mesh_id = asset_id;
                            lazy.load_state = .loaded;
                            
                            // Remove lazy component - no longer needed
                            _ = world.removeComponent(LazyAssetComponent, result.entity);
                        }
                    }
                },
                else => {}, // Already loaded or failed
            }
        }
    }
};
```

## Asset-ECS Bridge Components

### 1. Resource Reference Components
These components link entities to assets managed by the Asset Manager.

```zig
pub const MeshRendererComponent = struct {
    mesh_id: AssetId,
    material_id: AssetId,
    
    // Entity-specific rendering properties (not in assets)
    visible: bool = true,
    cast_shadows: bool = true,
    receive_shadows: bool = true,
    render_layer: RenderLayer = .opaque,
    lod_bias: f32 = 0.0,
    
    // Runtime state (modified by systems)
    last_rendered_frame: u64 = 0,
    bounds_dirty: bool = true,
    
    pub const RenderLayer = enum(u8) {
        background = 0,
        opaque = 1,
        transparent = 2,
        overlay = 3,
    };
};

pub const TextureComponent = struct {
    texture_id: AssetId,
    
    // Texture-specific properties
    uv_offset: Math.Vec2 = Math.Vec2.zero(),
    uv_scale: Math.Vec2 = Math.Vec2.one(),
    tiling: TextureTiling = .repeat,
    filter_mode: FilterMode = .linear,
    
    pub const TextureTiling = enum { repeat, clamp, mirror };
    pub const FilterMode = enum { nearest, linear, trilinear };
};

pub const AudioSourceComponent = struct {
    audio_clip_id: AssetId,
    
    // Audio-specific properties  
    volume: f32 = 1.0,
    pitch: f32 = 1.0,
    loop: bool = false,
    spatial: bool = true,
    min_distance: f32 = 1.0,
    max_distance: f32 = 100.0,
    
    // Runtime state
    playing: bool = false,
    current_time: f32 = 0.0,
};

pub const AnimatorComponent = struct {
    animation_controller_id: AssetId,
    
    // Animation state
    current_state: []const u8 = "idle",
    state_time: f32 = 0.0,
    transitions: std.HashMap([]const u8, AnimationTransition),
    parameters: std.HashMap([]const u8, AnimationParameter),
    
    pub const AnimationTransition = struct {
        from_state: []const u8,
        to_state: []const u8,
        duration: f32,
        condition: TransitionCondition,
    };
    
    pub const AnimationParameter = union(enum) {
        float: f32,
        int: i32,
        bool: bool,
        trigger: void,
    };
};
```

### 2. Asset Metadata Components
These components provide additional information about how assets should be used.

```zig
pub const AssetMetadataComponent = struct {
    asset_id: AssetId,
    load_priority: LoadPriority = .normal,
    memory_category: MemoryCategory = .standard,
    quality_level: QualityLevel = .high,
    
    pub const LoadPriority = enum(u8) {
        low = 0,
        normal = 1, 
        high = 2,
        critical = 3,
    };
    
    pub const MemoryCategory = enum {
        standard,    // Normal GPU memory
        streaming,   // Can be streamed in/out
        persistent,  // Keep in memory always
        temporary,   // Can be freed aggressively
    };
    
    pub const QualityLevel = enum {
        low,      // Use low-res versions
        medium,   // Use medium-res versions  
        high,     // Use full-res versions
        ultra,    // Use enhanced versions if available
    };
};

pub const AssetDependencyComponent = struct {
    dependencies: std.ArrayList(AssetId),
    dependents: std.ArrayList(EntityId),
    
    pub fn init(allocator: std.mem.Allocator) AssetDependencyComponent {
        return .{
            .dependencies = std.ArrayList(AssetId).init(allocator),
            .dependents = std.ArrayList(EntityId).init(allocator),
        };
    }
    
    pub fn addDependency(self: *Self, asset_id: AssetId) !void {
        try self.dependencies.append(asset_id);
    }
    
    pub fn removeDependency(self: *Self, asset_id: AssetId) bool {
        for (self.dependencies.items, 0..) |dep, i| {
            if (dep == asset_id) {
                _ = self.dependencies.swapRemove(i);
                return true;
            }
        }
        return false;
    }
};
```

## Asset Manager Integration Systems

### 1. Asset Synchronization System
Keeps ECS components in sync with Asset Manager state.

```zig
pub const AssetSyncSystem = struct {
    asset_manager: *AssetManager,
    allocator: std.mem.Allocator,
    
    pub fn update(self: *Self, world: *World, delta_time: f32) !void {
        _ = delta_time;
        
        // Process asset change notifications
        try self.processAssetChanges(world);
        
        // Update asset metadata
        try self.updateAssetMetadata(world);
        
        // Handle failed asset loads
        try self.handleFailedLoads(world);
    }
    
    fn processAssetChanges(self: *Self, world: *World) !void {
        // Find entities with asset changed tags
        var query = world.query(struct {
            changed: *AssetChangedTag,
        });
        
        var it = query.iterator();
        while (it.next()) |result| {
            const change = result.components.changed;
            
            switch (change.change_type) {
                .reloaded => {
                    // Asset was hot-reloaded, update dependent components
                    try self.updateDependentComponents(world, result.entity, change.asset_id);
                },
                .unloaded => {
                    // Asset was unloaded, mark components as invalid
                    try self.markAssetInvalid(world, result.entity, change.asset_id);
                },
                .failed => {
                    // Asset failed to load, use fallback
                    try self.useFallbackAsset(world, result.entity, change.asset_id);
                },
            }
            
            // Remove the change tag
            _ = world.removeComponent(AssetChangedTag, result.entity);
        }
    }
    
    fn updateDependentComponents(self: *Self, world: *World, entity: EntityId, asset_id: AssetId) !void {
        // Update mesh renderer if mesh changed
        if (world.getComponent(MeshRendererComponent, entity)) |mesh_renderer| {
            if (mesh_renderer.mesh_id == asset_id) {
                // Mark bounds as dirty since mesh data changed
                mesh_renderer.bounds_dirty = true;
                
                // Add update tag for render system
                try world.addComponent(entity, RenderDataChangedTag{});
            }
        }
        
        // Update texture component if texture changed
        if (world.getComponent(TextureComponent, entity)) |texture| {
            if (texture.texture_id == asset_id) {
                // Texture changed, mark for descriptor set update
                try world.addComponent(entity, DescriptorSetDirtyTag{});
            }
        }
        
        // Handle other component types...
    }
    
    fn useFallbackAsset(self: *Self, world: *World, entity: EntityId, failed_asset_id: AssetId) !void {
        // Get fallback asset ID from asset manager
        const fallback_id = self.asset_manager.getFallbackAsset(failed_asset_id);
        
        // Update components to use fallback
        if (world.getComponent(MeshRendererComponent, entity)) |mesh_renderer| {
            if (mesh_renderer.mesh_id == failed_asset_id) {
                mesh_renderer.mesh_id = fallback_id;
            }
            if (mesh_renderer.material_id == failed_asset_id) {
                mesh_renderer.material_id = fallback_id;
            }
        }
        
        // Add warning tag for debugging
        try world.addComponent(entity, AssetWarningTag{
            .message = "Using fallback asset due to load failure",
            .original_asset = failed_asset_id,
            .fallback_asset = fallback_id,
        });
    }
};

// Helper component tags
pub const RenderDataChangedTag = struct {};
pub const DescriptorSetDirtyTag = struct {};
pub const AssetWarningTag = struct {
    message: []const u8,
    original_asset: AssetId,
    fallback_asset: AssetId,
};
```

### 2. Asset Loading System
Manages asynchronous asset loading for ECS entities.

```zig
pub const AssetLoadingSystem = struct {
    asset_manager: *AssetManager,
    loading_queue: std.ArrayList(LoadRequest),
    allocator: std.mem.Allocator,
    
    const LoadRequest = struct {
        entity: EntityId,
        asset_path: []const u8,
        asset_type: AssetType,
        priority: LoadPriority,
        callback: ?LoadCallback = null,
    };
    
    const LoadCallback = struct {
        context: *anyopaque,
        onComplete: *const fn (context: *anyopaque, entity: EntityId, asset_id: AssetId) void,
        onFailed: *const fn (context: *anyopaque, entity: EntityId, error_msg: []const u8) void,
    };
    
    pub fn init(asset_manager: *AssetManager, allocator: std.mem.Allocator) AssetLoadingSystem {
        return .{
            .asset_manager = asset_manager,
            .loading_queue = std.ArrayList(LoadRequest).init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn update(self: *Self, world: *World, delta_time: f32) !void {
        _ = delta_time;
        
        // Process completed loads
        try self.processCompletedLoads(world);
        
        // Submit new load requests
        try self.submitPendingLoads(world);
        
        // Update loading progress
        try self.updateLoadingProgress(world);
    }
    
    pub fn loadAssetForEntity(self: *Self, entity: EntityId, asset_path: []const u8, 
                             asset_type: AssetType, priority: LoadPriority) !void {
        try self.loading_queue.append(.{
            .entity = entity,
            .asset_path = asset_path,
            .asset_type = asset_type,
            .priority = priority,
        });
    }
    
    fn processCompletedLoads(self: *Self, world: *World) !void {
        // Check asset manager for completed loads
        var completed = try self.asset_manager.getCompletedLoads(self.allocator);
        defer completed.deinit();
        
        for (completed.items) |result| {
            // Find the entity that requested this load
            const entity = self.findRequestingEntity(result.request_id);
            if (entity == EntityId.invalid) continue;
            
            if (result.success) {
                // Asset loaded successfully
                try self.attachAssetToEntity(world, entity, result.asset_id, result.asset_type);
            } else {
                // Asset failed to load
                try self.handleLoadFailure(world, entity, result.error_message);
            }
        }
    }
    
    fn attachAssetToEntity(self: *Self, world: *World, entity: EntityId, 
                          asset_id: AssetId, asset_type: AssetType) !void {
        switch (asset_type) {
            .mesh => {
                // Add or update mesh renderer component
                if (world.getComponent(MeshRendererComponent, entity)) |mesh_renderer| {
                    mesh_renderer.mesh_id = asset_id;
                    mesh_renderer.bounds_dirty = true;
                } else {
                    try world.addComponent(entity, MeshRendererComponent{
                        .mesh_id = asset_id,
                        .material_id = self.asset_manager.getDefaultMaterial(),
                    });
                }
            },
            .texture => {
                // Add or update texture component
                if (world.getComponent(TextureComponent, entity)) |texture| {
                    texture.texture_id = asset_id;
                } else {
                    try world.addComponent(entity, TextureComponent{
                        .texture_id = asset_id,
                    });
                }
            },
            .material => {
                // Update material reference
                if (world.getComponent(MeshRendererComponent, entity)) |mesh_renderer| {
                    mesh_renderer.material_id = asset_id;
                }
            },
            // Handle other asset types...
            else => {},
        }
        
        // Remove any loading components
        _ = world.removeComponent(AssetLoadingTag, entity);
        
        // Add loaded tag for one frame (systems can react to newly loaded assets)
        try world.addComponent(entity, AssetLoadedTag{ .asset_id = asset_id });
    }
};

// Loading state components
pub const AssetLoadingTag = struct {
    asset_path: []const u8,
    progress: f32 = 0.0,
};

pub const AssetLoadedTag = struct {
    asset_id: AssetId,
};
```

### 3. Asset Dependency System
Manages dependencies between assets and entities.

```zig
pub const AssetDependencySystem = struct {
    asset_manager: *AssetManager,
    // Dependency graph: asset_id -> [entity_ids that depend on it]
    asset_dependencies: std.HashMap(AssetId, std.ArrayList(EntityId)),
    allocator: std.mem.Allocator,
    
    pub fn init(asset_manager: *AssetManager, allocator: std.mem.Allocator) AssetDependencySystem {
        return .{
            .asset_manager = asset_manager,
            .asset_dependencies = std.HashMap(AssetId, std.ArrayList(EntityId)).init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn update(self: *Self, world: *World, delta_time: f32) !void {
        _ = delta_time;
        
        // Rebuild dependency graph
        try self.rebuildDependencies(world);
        
        // Check for orphaned assets
        try self.cleanupOrphanedAssets();
        
        // Preload dependencies for high-priority entities
        try self.preloadDependencies(world);
    }
    
    fn rebuildDependencies(self: *Self, world: *World) !void {
        // Clear existing dependencies
        var it = self.asset_dependencies.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.asset_dependencies.clearRetainingCapacity();
        
        // Scan all entities for asset dependencies
        var mesh_query = world.query(struct {
            mesh_renderer: *MeshRendererComponent,
        });
        
        var mesh_it = mesh_query.iterator();
        while (mesh_it.next()) |result| {
            const mesh_renderer = result.components.mesh_renderer;
            
            // Track mesh dependency
            try self.addDependency(mesh_renderer.mesh_id, result.entity);
            
            // Track material dependency
            try self.addDependency(mesh_renderer.material_id, result.entity);
            
            // Get material's texture dependencies
            if (self.asset_manager.getMaterialTextures(mesh_renderer.material_id)) |textures| {
                for (textures) |texture_id| {
                    try self.addDependency(texture_id, result.entity);
                }
            }
        }
        
        // Scan other component types for dependencies...
        var texture_query = world.query(struct {
            texture: *TextureComponent,
        });
        
        var texture_it = texture_query.iterator();
        while (texture_it.next()) |result| {
            try self.addDependency(result.components.texture.texture_id, result.entity);
        }
    }
    
    fn addDependency(self: *Self, asset_id: AssetId, entity: EntityId) !void {
        if (self.asset_dependencies.getPtr(asset_id)) |entities| {
            // Check if already exists
            for (entities.items) |existing| {
                if (existing == entity) return;
            }
            try entities.append(entity);
        } else {
            var entities = std.ArrayList(EntityId).init(self.allocator);
            try entities.append(entity);
            try self.asset_dependencies.put(asset_id, entities);
        }
    }
    
    fn cleanupOrphanedAssets(self: *Self) !void {
        // Get all loaded assets from asset manager
        const loaded_assets = try self.asset_manager.getLoadedAssets(self.allocator);
        defer loaded_assets.deinit();
        
        for (loaded_assets.items) |asset_id| {
            // Check if any entities depend on this asset
            if (!self.asset_dependencies.contains(asset_id)) {
                // No entities depend on this asset, consider unloading
                if (self.asset_manager.canUnload(asset_id)) {
                    try self.asset_manager.unloadAsset(asset_id);
                }
            }
        }
    }
    
    pub fn getEntitiesUsingAsset(self: *Self, asset_id: AssetId) []EntityId {
        if (self.asset_dependencies.get(asset_id)) |entities| {
            return entities.items;
        }
        return &[_]EntityId{};
    }
};
```

## Scene Management Integration

### Scene File Format
Scenes are stored as JSON with asset references and ECS entity data.

```json
{
  "scene_info": {
    "name": "Main Scene",
    "version": "1.0",
    "created": "2024-01-01T00:00:00Z"
  },
  "assets": {
    "meshes": [
      {
        "id": "mesh_001",
        "path": "models/cube.obj",
        "import_settings": {
          "scale": 1.0,
          "generate_normals": true,
          "generate_tangents": true
        }
      }
    ],
    "materials": [
      {
        "id": "mat_001", 
        "path": "materials/default.mat",
        "dependencies": ["tex_001", "tex_002"]
      }
    ],
    "textures": [
      {
        "id": "tex_001",
        "path": "textures/albedo.png",
        "import_settings": {
          "format": "BC7",
          "generate_mipmaps": true,
          "filter": "trilinear"
        }
      }
    ]
  },
  "entities": [
    {
      "id": "entity_001",
      "name": "Cube",
      "components": {
        "transform": {
          "translation": [0.0, 0.0, 0.0],
          "rotation": [0.0, 0.0, 0.0, 1.0],
          "scale": [1.0, 1.0, 1.0]
        },
        "mesh_renderer": {
          "mesh_id": "mesh_001",
          "material_id": "mat_001",
          "visible": true,
          "cast_shadows": true,
          "receive_shadows": true,
          "render_layer": "opaque"
        }
      }
    }
  ],
  "hierarchy": [
    {
      "parent": null,
      "entity": "entity_001",
      "children": []
    }
  ]
}
```

### Scene Serialization System
```zig
pub const SceneSystem = struct {
    asset_manager: *AssetManager,
    world: *World,
    allocator: std.mem.Allocator,
    
    pub fn saveScene(self: *Self, scene_path: []const u8, entities: []EntityId) !void {
        var scene_data = SceneData.init(self.allocator);
        defer scene_data.deinit();
        
        // Collect asset dependencies
        var asset_deps = std.HashSet(AssetId).init(self.allocator);
        defer asset_deps.deinit();
        
        for (entities) |entity| {
            // Serialize entity components
            var entity_data = EntityData.init(self.allocator, entity);
            
            // Transform component
            if (self.world.getComponent(TransformComponent, entity)) |transform| {
                entity_data.components.transform = SerializedTransform.fromComponent(transform.*);
                
                // Collect asset dependencies from this entity
                try self.collectAssetDependencies(entity, &asset_deps);
            }
            
            // Mesh renderer component
            if (self.world.getComponent(MeshRendererComponent, entity)) |mesh_renderer| {
                entity_data.components.mesh_renderer = SerializedMeshRenderer.fromComponent(mesh_renderer.*);
            }
            
            // Add more components...
            
            try scene_data.entities.append(entity_data);
        }
        
        // Serialize asset information
        var asset_it = asset_deps.iterator();
        while (asset_it.next()) |asset_id| {
            const asset_info = try self.asset_manager.getAssetInfo(asset_id.*);
            try scene_data.assets.append(asset_info);
        }
        
        // Write to file
        const json_string = try std.json.stringifyAlloc(self.allocator, scene_data, .{});
        defer self.allocator.free(json_string);
        
        try std.fs.cwd().writeFile(scene_path, json_string);
    }
    
    pub fn loadScene(self: *Self, scene_path: []const u8) ![]EntityId {
        const scene_content = try std.fs.cwd().readFileAlloc(self.allocator, scene_path, 1024 * 1024);
        defer self.allocator.free(scene_content);
        
        const parsed = try std.json.parseFromSlice(SceneData, self.allocator, scene_content, .{});
        defer parsed.deinit();
        
        const scene_data = parsed.value;
        
        // Load all assets first
        for (scene_data.assets) |asset_info| {
            _ = try self.asset_manager.loadAsset(asset_info.path, asset_info.type);
        }
        
        // Create entities
        var created_entities = std.ArrayList(EntityId).init(self.allocator);
        defer created_entities.deinit();
        
        for (scene_data.entities) |entity_data| {
            const entity = self.world.createEntity();
            
            // Deserialize components
            if (entity_data.components.transform) |transform| {
                try self.world.addComponent(entity, transform.toComponent());
            }
            
            if (entity_data.components.mesh_renderer) |mesh_renderer| {
                // Resolve asset IDs from paths
                const mesh_id = try self.asset_manager.getAssetIdFromPath(mesh_renderer.mesh_path);
                const material_id = try self.asset_manager.getAssetIdFromPath(mesh_renderer.material_path);
                
                try self.world.addComponent(entity, MeshRendererComponent{
                    .mesh_id = mesh_id,
                    .material_id = material_id,
                    .visible = mesh_renderer.visible,
                    .cast_shadows = mesh_renderer.cast_shadows,
                    .receive_shadows = mesh_renderer.receive_shadows,
                    .render_layer = mesh_renderer.render_layer,
                });
            }
            
            try created_entities.append(entity);
        }
        
        return try created_entities.toOwnedSlice();
    }
};
```

## Performance Considerations

### Memory Management
1. **Component Memory**: Use packed arrays for cache-friendly access
2. **Asset References**: Store only AssetIds in components (4-8 bytes each)
3. **Dependency Tracking**: Use efficient hash maps with pre-allocated capacity
4. **Query Caching**: Cache frequently used queries to avoid re-computation

### Hot Reloading Performance
```zig
pub const HotReloadingOptimizer = struct {
    // Batch change notifications to avoid per-entity updates
    pending_changes: std.HashMap(AssetId, ChangeInfo),
    change_timer: f32 = 0.0,
    batch_interval: f32 = 0.1, // Process changes every 100ms
    
    pub fn update(self: *Self, world: *World, delta_time: f32) !void {
        self.change_timer += delta_time;
        
        if (self.change_timer >= self.batch_interval and self.pending_changes.count() > 0) {
            // Process all pending changes in batch
            var it = self.pending_changes.iterator();
            while (it.next()) |entry| {
                try self.processAssetChange(world, entry.key_ptr.*, entry.value_ptr.*);
            }
            
            self.pending_changes.clearRetainingCapacity();
            self.change_timer = 0.0;
        }
    }
    
    pub fn queueAssetChange(self: *Self, asset_id: AssetId, change_type: ChangeType) !void {
        // Coalesce multiple changes to same asset
        try self.pending_changes.put(asset_id, ChangeInfo{
            .change_type = change_type,
            .timestamp = std.time.milliTimestamp(),
        });
    }
};
```

### Asset Streaming
```zig
pub const StreamingSystem = struct {
    // Predict which assets will be needed based on entity movement
    prediction_distance: f32 = 100.0,
    
    pub fn update(self: *Self, world: *World, delta_time: f32) !void {
        // Find camera position
        const camera_pos = self.getCameraPosition(world);
        
        // Predict future camera position
        const camera_velocity = self.getCameraVelocity(world);
        const predicted_pos = Math.Vec3.add(camera_pos, Math.Vec3.scale(camera_velocity, 2.0)); // 2 seconds ahead
        
        // Find entities near predicted position
        var transform_query = world.query(struct {
            transform: *TransformComponent,
            mesh_renderer: *MeshRendererComponent,
        });
        
        var it = transform_query.iterator();
        while (it.next()) |result| {
            const distance = Math.Vec3.distance(result.components.transform.translation, predicted_pos);
            
            if (distance <= self.prediction_distance) {
                // Ensure assets are loaded with high priority
                try self.asset_manager.ensureLoaded(result.components.mesh_renderer.mesh_id, .high);
                try self.asset_manager.ensureLoaded(result.components.mesh_renderer.material_id, .high);
            } else if (distance > self.prediction_distance * 2.0) {
                // Consider unloading distant assets
                try self.asset_manager.considerUnloading(result.components.mesh_renderer.mesh_id);
            }
        }
    }
};
```

## Development Tools Integration

### ECS Inspector with Asset Information
```zig
pub const ECSInspector = struct {
    pub fn inspectEntity(self: *Self, world: *World, entity: EntityId) EntityInspectorData {
        var data = EntityInspectorData.init(entity);
        
        // Add component information with asset details
        if (world.getComponent(MeshRendererComponent, entity)) |mesh_renderer| {
            const mesh_info = self.asset_manager.getAssetInfo(mesh_renderer.mesh_id);
            const material_info = self.asset_manager.getAssetInfo(mesh_renderer.material_id);
            
            data.components.mesh_renderer = .{
                .component = mesh_renderer.*,
                .mesh_path = mesh_info.path,
                .mesh_status = mesh_info.status,
                .material_path = material_info.path,
                .material_status = material_info.status,
            };
        }
        
        return data;
    }
    
    pub fn showAssetDependencies(self: *Self, asset_id: AssetId) []EntityId {
        return self.dependency_system.getEntitiesUsingAsset(asset_id);
    }
};
```

## Conclusion

This integrated approach provides:
- **Clean Separation**: Assets and entities remain separate but connected
- **Reactive Updates**: Changes to assets automatically propagate to entities  
- **Performance**: Efficient memory layout and batched operations
- **Developer Experience**: Rich tooling and debugging capabilities
- **Scalability**: Handles large numbers of entities and assets efficiently

The system is designed to grow with the engine while maintaining performance and ease of use.