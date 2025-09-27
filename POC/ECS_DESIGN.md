# Entity Component System (ECS) Design for ZulkanZengine

## Overview

This document outlines the integration of an Entity Component System (ECS) architecture into ZulkanZengine, designed to work alongside the existing Asset Manager and Unified Renderer systems. The ECS will replace the current GameObject-based scene management with a more flexible, performance-oriented approach.

## Current State Analysis

### Existing Architecture Limitations
```zig
// Current rigid structure in scene.zig
pub const Scene = struct {
    objects: std.ArrayList(GameObject),  // Flat list, no hierarchy
    materials: std.ArrayList(Material), // Manual management
    textures: std.ArrayList(Texture),   // No dependency tracking
    // ...
};

// Current component system in components.zig  
pub const PointLightComponent = struct {
    color: Math.Vec3,
    intensity: f32,
};

// Current GameObject in game_object.zig (assumed structure)
pub const GameObject = struct {
    transform: Transform,
    model: ?Model,
    point_light: ?PointLightComponent,
    // Hard-coded component types
};
```

### Problems with Current Approach
1. **Rigid Component Types**: Adding new component types requires modifying GameObject struct
2. **Poor Memory Locality**: Components scattered across GameObject instances
3. **Inefficient Queries**: No way to efficiently find all objects with specific component combinations
4. **No Component Relationships**: Cannot express dependencies between components
5. **Fixed Update Order**: All components updated in same order regardless of dependencies
6. **Poor Cache Performance**: GameObject structure leads to cache misses during iteration

## Proposed ECS Architecture

### Core ECS Components

#### 1. Entity System
```zig
pub const EntityId = enum(u32) {
    invalid = 0,
    _,
    
    pub fn generate(world: *World) EntityId {
        return world.entity_manager.create();
    }
};

pub const EntityManager = struct {
    // Sparse set for fast entity validation
    entities: std.BitSet,
    generations: []u32,
    free_list: std.ArrayList(u32),
    next_id: std.atomic.Atomic(u32),
    
    pub fn create(self: *Self) EntityId {
        if (self.free_list.popOrNull()) |id| {
            const generation = self.generations[id] + 1;
            self.generations[id] = generation;
            self.entities.set(id);
            return @enumFromInt((generation << 16) | id);
        } else {
            const id = self.next_id.fetchAdd(1, .Monotonic);
            try self.resizeIfNeeded(id);
            self.entities.set(id);
            self.generations[id] = 1;
            return @enumFromInt((1 << 16) | id);
        }
    }
    
    pub fn isValid(self: *Self, entity: EntityId) bool {
        const id = @intFromEnum(entity) & 0xFFFF;
        const generation = @intFromEnum(entity) >> 16;
        return id < self.entities.capacity() and 
               self.entities.isSet(id) and 
               self.generations[id] == generation;
    }
    
    pub fn destroy(self: *Self, entity: EntityId) void {
        const id = @intFromEnum(entity) & 0xFFFF;
        if (self.isValid(entity)) {
            self.entities.unset(id);
            try self.free_list.append(id);
        }
    }
};
```

#### 2. Component System
```zig
pub const ComponentType = enum(u32) {
    transform,
    mesh_renderer,
    point_light,
    camera,
    animation,
    physics_body,
    audio_source,
    script,
    // Extensible - can add new types without modifying existing code
    _,
    
    pub fn id(comptime T: type) ComponentType {
        return comptime blk: {
            const type_name = @typeName(T);
            break :blk @enumFromInt(std.hash.Wyhash.hash(0, type_name));
        };
    }
};

pub fn ComponentStorage(comptime T: type) type {
    return struct {
        const Self = @This();
        
        // Packed array for memory locality
        components: std.ArrayList(T),
        // Sparse array mapping entity to component index
        entity_to_index: std.HashMap(EntityId, u32),
        // Dense array of entities (same order as components)
        entities: std.ArrayList(EntityId),
        allocator: std.mem.Allocator,
        
        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .components = std.ArrayList(T).init(allocator),
                .entity_to_index = std.HashMap(EntityId, u32).init(allocator),
                .entities = std.ArrayList(EntityId).init(allocator),
                .allocator = allocator,
            };
        }
        
        pub fn add(self: *Self, entity: EntityId, component: T) !void {
            const index = @as(u32, @intCast(self.components.items.len));
            try self.components.append(component);
            try self.entities.append(entity);
            try self.entity_to_index.put(entity, index);
        }
        
        pub fn get(self: *Self, entity: EntityId) ?*T {
            if (self.entity_to_index.get(entity)) |index| {
                return &self.components.items[index];
            }
            return null;
        }
        
        pub fn remove(self: *Self, entity: EntityId) bool {
            if (self.entity_to_index.get(entity)) |index| {
                // Swap-remove to maintain packed array
                const last_index = self.components.items.len - 1;
                if (index != last_index) {
                    self.components.items[index] = self.components.items[last_index];
                    self.entities.items[index] = self.entities.items[last_index];
                    // Update mapping for swapped entity
                    self.entity_to_index.put(self.entities.items[index], index) catch {};
                }
                _ = self.components.pop();
                _ = self.entities.pop();
                _ = self.entity_to_index.remove(entity);
                return true;
            }
            return false;
        }
        
        pub fn iterator(self: *Self) Iterator {
            return .{
                .storage = self,
                .index = 0,
            };
        }
        
        const Iterator = struct {
            storage: *ComponentStorage(T),
            index: u32,
            
            pub fn next(self: *Iterator) ?struct { entity: EntityId, component: *T } {
                if (self.index >= self.storage.components.items.len) return null;
                defer self.index += 1;
                return .{
                    .entity = self.storage.entities.items[self.index],
                    .component = &self.storage.components.items[self.index],
                };
            }
        };
    };
}
```

#### 3. World (ECS Registry)
```zig
pub const World = struct {
    entity_manager: EntityManager,
    // Type-erased component storages
    storages: std.HashMap(ComponentType, *anyopaque),
    // System execution order
    systems: std.ArrayList(*SystemInterface),
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) World {
        return .{
            .entity_manager = EntityManager.init(allocator),
            .storages = std.HashMap(ComponentType, *anyopaque).init(allocator),
            .systems = std.ArrayList(*SystemInterface).init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn createEntity(self: *Self) EntityId {
        return self.entity_manager.create();
    }
    
    pub fn addComponent(self: *Self, entity: EntityId, component: anytype) !void {
        const T = @TypeOf(component);
        const component_type = ComponentType.id(T);
        
        if (self.storages.get(component_type)) |storage_ptr| {
            const storage: *ComponentStorage(T) = @ptrCast(@alignCast(storage_ptr));
            try storage.add(entity, component);
        } else {
            // Create new storage for this component type
            const storage = try self.allocator.create(ComponentStorage(T));
            storage.* = ComponentStorage(T).init(self.allocator);
            try storage.add(entity, component);
            try self.storages.put(component_type, storage);
        }
    }
    
    pub fn getComponent(self: *Self, comptime T: type, entity: EntityId) ?*T {
        const component_type = ComponentType.id(T);
        if (self.storages.get(component_type)) |storage_ptr| {
            const storage: *ComponentStorage(T) = @ptrCast(@alignCast(storage_ptr));
            return storage.get(entity);
        }
        return null;
    }
    
    pub fn removeComponent(self: *Self, comptime T: type, entity: EntityId) bool {
        const component_type = ComponentType.id(T);
        if (self.storages.get(component_type)) |storage_ptr| {
            const storage: *ComponentStorage(T) = @ptrCast(@alignCast(storage_ptr));
            return storage.remove(entity);
        }
        return false;
    }
    
    pub fn hasComponent(self: *Self, comptime T: type, entity: EntityId) bool {
        return self.getComponent(T, entity) != null;
    }
    
    // Query system for efficient component iteration
    pub fn query(self: *Self, comptime ComponentTuple: type) Query(ComponentTuple) {
        return Query(ComponentTuple).init(self);
    }
};
```

#### 4. Query System for Efficient Component Access
```zig
pub fn Query(comptime ComponentTuple: type) type {
    return struct {
        const Self = @This();
        const ComponentTypes = @typeInfo(ComponentTuple).Struct.fields;
        
        world: *World,
        storages: [ComponentTypes.len]*anyopaque,
        min_size: u32,
        
        pub fn init(world: *World) Self {
            var storages: [ComponentTypes.len]*anyopaque = undefined;
            var min_size: u32 = std.math.maxInt(u32);
            
            inline for (ComponentTypes, 0..) |field, i| {
                const T = field.type;
                const component_type = ComponentType.id(T);
                const storage_ptr = world.storages.get(component_type) orelse {
                    // Component type not found, return empty query
                    return Self{
                        .world = world,
                        .storages = storages,
                        .min_size = 0,
                    };
                };
                storages[i] = storage_ptr;
                const storage: *ComponentStorage(T) = @ptrCast(@alignCast(storage_ptr));
                min_size = @min(min_size, @as(u32, @intCast(storage.components.items.len)));
            }
            
            return Self{
                .world = world,
                .storages = storages,
                .min_size = min_size,
            };
        }
        
        pub fn iterator(self: *Self) Iterator {
            return Iterator.init(self);
        }
        
        const Iterator = struct {
            query: *Query(ComponentTuple),
            index: u32,
            
            pub fn init(query: *Query(ComponentTuple)) Iterator {
                return .{
                    .query = query,
                    .index = 0,
                };
            }
            
            pub fn next(self: *Iterator) ?QueryResult {
                while (self.index < self.query.min_size) {
                    defer self.index += 1;
                    
                    // Get entity from first storage
                    const first_storage_ptr = self.query.storages[0];
                    const FirstComponent = ComponentTypes[0].type;
                    const first_storage: *ComponentStorage(FirstComponent) = 
                        @ptrCast(@alignCast(first_storage_ptr));
                    
                    if (self.index >= first_storage.entities.items.len) break;
                    const entity = first_storage.entities.items[self.index];
                    
                    // Check if entity has all required components
                    var all_components_present = true;
                    var components: ComponentTuple = undefined;
                    
                    inline for (ComponentTypes, 0..) |field, i| {
                        const T = field.type;
                        const storage: *ComponentStorage(T) = 
                            @ptrCast(@alignCast(self.query.storages[i]));
                        
                        if (storage.get(entity)) |component| {
                            @field(components, field.name) = component;
                        } else {
                            all_components_present = false;
                            break;
                        }
                    }
                    
                    if (all_components_present) {
                        return QueryResult{
                            .entity = entity,
                            .components = components,
                        };
                    }
                }
                return null;
            }
        };
        
        const QueryResult = struct {
            entity: EntityId,
            components: ComponentTuple,
        };
    };
}
```

### Component Definitions

#### Core Rendering Components
```zig
pub const TransformComponent = struct {
    translation: Math.Vec3 = Math.Vec3.zero(),
    rotation: Math.Quat = Math.Quat.identity(),
    scale: Math.Vec3 = Math.Vec3.one(),
    
    pub fn getMatrix(self: TransformComponent) Math.Mat4 {
        const t_mat = Math.Mat4.translate(self.translation);
        const r_mat = Math.Mat4.fromQuat(self.rotation);
        const s_mat = Math.Mat4.scale(self.scale);
        return Math.Mat4.mul(Math.Mat4.mul(t_mat, r_mat), s_mat);
    }
    
    pub fn getWorldMatrix(self: TransformComponent, parent: ?Math.Mat4) Math.Mat4 {
        const local = self.getMatrix();
        return if (parent) |p| Math.Mat4.mul(p, local) else local;
    }
};

pub const MeshRendererComponent = struct {
    mesh_id: AssetId,
    material_id: AssetId,
    cast_shadows: bool = true,
    receive_shadows: bool = true,
    layer: RenderLayer = .opaque,
    
    pub const RenderLayer = enum {
        opaque,
        transparent,
        overlay,
        shadow_caster_only,
    };
};

pub const CameraComponent = struct {
    projection: ProjectionType = .perspective,
    fov: f32 = 45.0, // degrees, for perspective
    near: f32 = 0.1,
    far: f32 = 1000.0,
    size: f32 = 5.0, // for orthographic
    priority: i32 = 0, // higher priority renders last
    clear_flags: ClearFlags = .{ .color = true, .depth = true },
    clear_color: Math.Vec4 = Math.Vec4.init(0.0, 0.0, 0.0, 1.0),
    
    pub const ProjectionType = enum { perspective, orthographic };
    pub const ClearFlags = packed struct { color: bool, depth: bool, stencil: bool = false };
    
    pub fn getProjectionMatrix(self: CameraComponent, aspect_ratio: f32) Math.Mat4 {
        return switch (self.projection) {
            .perspective => Math.Mat4.perspective(
                Math.toRadians(self.fov), aspect_ratio, self.near, self.far
            ),
            .orthographic => Math.Mat4.orthographic(
                -self.size * aspect_ratio, self.size * aspect_ratio,
                -self.size, self.size, self.near, self.far
            ),
        };
    }
};

pub const PointLightComponent = struct {
    color: Math.Vec3 = Math.Vec3.one(),
    intensity: f32 = 1.0,
    range: f32 = 10.0,
    constant: f32 = 1.0,
    linear: f32 = 0.09,
    quadratic: f32 = 0.032,
    cast_shadows: bool = true,
    
    pub fn getAttenuation(self: PointLightComponent, distance: f32) f32 {
        return 1.0 / (self.constant + self.linear * distance + self.quadratic * distance * distance);
    }
};

pub const DirectionalLightComponent = struct {
    color: Math.Vec3 = Math.Vec3.one(),
    intensity: f32 = 1.0,
    direction: Math.Vec3 = Math.Vec3.init(0.0, -1.0, 0.0),
    cast_shadows: bool = true,
    shadow_cascade_count: u32 = 4,
    shadow_distance: f32 = 100.0,
};
```

#### Hierarchy and Animation Components
```zig
pub const HierarchyComponent = struct {
    parent: ?EntityId = null,
    children: std.ArrayList(EntityId),
    
    pub fn init(allocator: std.mem.Allocator) HierarchyComponent {
        return .{
            .children = std.ArrayList(EntityId).init(allocator),
        };
    }
    
    pub fn addChild(self: *HierarchyComponent, child: EntityId) !void {
        try self.children.append(child);
    }
    
    pub fn removeChild(self: *HierarchyComponent, child: EntityId) bool {
        for (self.children.items, 0..) |c, i| {
            if (c == child) {
                _ = self.children.swapRemove(i);
                return true;
            }
        }
        return false;
    }
};

pub const AnimationComponent = struct {
    current_animation: ?AssetId = null,
    time: f32 = 0.0,
    speed: f32 = 1.0,
    loop: bool = true,
    paused: bool = false,
    blend_tree: ?AnimationBlendTree = null,
    
    pub const AnimationBlendTree = struct {
        // For complex animation blending
        states: std.HashMap([]const u8, AnimationState),
        transitions: std.ArrayList(AnimationTransition),
        current_state: []const u8,
    };
};
```

### System Architecture

#### System Interface
```zig
pub const SystemInterface = struct {
    const Self = @This();
    
    vtable: *const VTable,
    context: *anyopaque,
    
    const VTable = struct {
        update: *const fn (ctx: *anyopaque, world: *World, delta_time: f32) anyerror!void,
        render: *const fn (ctx: *anyopaque, world: *World, renderer: *UnifiedRenderer) anyerror!void,
        deinit: *const fn (ctx: *anyopaque) void,
    };
    
    pub fn init(system: anytype) SystemInterface {
        const T = @TypeOf(system.*);
        const gen = struct {
            fn updateImpl(ctx: *anyopaque, world: *World, delta_time: f32) anyerror!void {
                const self: *T = @ptrCast(@alignCast(ctx));
                return self.update(world, delta_time);
            }
            
            fn renderImpl(ctx: *anyopaque, world: *World, renderer: *UnifiedRenderer) anyerror!void {
                const self: *T = @ptrCast(@alignCast(ctx));
                return self.render(world, renderer);
            }
            
            fn deinitImpl(ctx: *anyopaque) void {
                const self: *T = @ptrCast(@alignCast(ctx));
                self.deinit();
            }
        };
        
        return .{
            .context = system,
            .vtable = &.{
                .update = gen.updateImpl,
                .render = gen.renderImpl,
                .deinit = gen.deinitImpl,
            },
        };
    }
    
    pub fn update(self: SystemInterface, world: *World, delta_time: f32) !void {
        return self.vtable.update(self.context, world, delta_time);
    }
    
    pub fn render(self: SystemInterface, world: *World, renderer: *UnifiedRenderer) !void {
        return self.vtable.render(self.context, world, renderer);
    }
    
    pub fn deinit(self: SystemInterface) void {
        self.vtable.deinit(self.context);
    }
};
```

#### Core Systems Implementation
```zig
pub const TransformSystem = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) TransformSystem {
        return .{ .allocator = allocator };
    }
    
    pub fn update(self: *TransformSystem, world: *World, delta_time: f32) !void {
        _ = self;
        _ = delta_time;
        
        // Update hierarchical transforms
        var hierarchy_query = world.query(struct {
            hierarchy: *HierarchyComponent,
            transform: *TransformComponent,
        });
        
        var it = hierarchy_query.iterator();
        while (it.next()) |result| {
            if (result.components.hierarchy.parent == null) {
                // Root entity, calculate world transforms for children
                try self.updateChildrenTransforms(world, result.entity, result.components.transform.getMatrix());
            }
        }
    }
    
    fn updateChildrenTransforms(self: *TransformSystem, world: *World, parent: EntityId, parent_matrix: Math.Mat4) !void {
        if (world.getComponent(HierarchyComponent, parent)) |hierarchy| {
            for (hierarchy.children.items) |child| {
                if (world.getComponent(TransformComponent, child)) |child_transform| {
                    const local_matrix = child_transform.getMatrix();
                    const world_matrix = Math.Mat4.mul(parent_matrix, local_matrix);
                    
                    // Store world matrix in a separate component or cache
                    // For now, we could add a WorldTransformComponent
                    
                    // Recurse for grandchildren
                    try self.updateChildrenTransforms(world, child, world_matrix);
                }
            }
        }
    }
    
    pub fn render(self: *TransformSystem, world: *World, renderer: *UnifiedRenderer) !void {
        _ = self;
        _ = world;
        _ = renderer;
        // Transform system doesn't render
    }
    
    pub fn deinit(self: *TransformSystem) void {
        _ = self;
    }
};

pub const RenderSystem = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) RenderSystem {
        return .{ .allocator = allocator };
    }
    
    pub fn update(self: *RenderSystem, world: *World, delta_time: f32) !void {
        _ = self;
        _ = world;
        _ = delta_time;
        // Render system logic happens in render()
    }
    
    pub fn render(self: *RenderSystem, world: *World, renderer: *UnifiedRenderer) !void {
        _ = self;
        
        // Collect all renderable entities
        var render_query = world.query(struct {
            transform: *TransformComponent,
            mesh_renderer: *MeshRendererComponent,
        });
        
        // Group by material and layer for efficient rendering
        var render_groups = std.HashMap(u64, std.ArrayList(RenderItem)).init(self.allocator);
        defer {
            var it = render_groups.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.deinit();
            }
            render_groups.deinit();
        }
        
        var query_it = render_query.iterator();
        while (query_it.next()) |result| {
            const group_key = (@as(u64, @intFromEnum(result.components.mesh_renderer.material_id)) << 32) | 
                             (@as(u64, @intFromEnum(result.components.mesh_renderer.layer)) << 16) |
                             @intFromEnum(result.components.mesh_renderer.mesh_id);
            
            const render_item = RenderItem{
                .entity = result.entity,
                .transform = result.components.transform,
                .mesh_renderer = result.components.mesh_renderer,
            };
            
            if (render_groups.getPtr(group_key)) |list| {
                try list.append(render_item);
            } else {
                var new_list = std.ArrayList(RenderItem).init(self.allocator);
                try new_list.append(render_item);
                try render_groups.put(group_key, new_list);
            }
        }
        
        // Submit grouped render items to unified renderer
        var group_it = render_groups.iterator();
        while (group_it.next()) |entry| {
            try renderer.submitBatch(entry.value_ptr.items);
        }
    }
    
    pub fn deinit(self: *RenderSystem) void {
        _ = self;
    }
    
    const RenderItem = struct {
        entity: EntityId,
        transform: *TransformComponent,
        mesh_renderer: *MeshRendererComponent,
    };
};

pub const CameraSystem = struct {
    allocator: std.mem.Allocator,
    main_camera: ?EntityId = null,
    
    pub fn init(allocator: std.mem.Allocator) CameraSystem {
        return .{ .allocator = allocator };
    }
    
    pub fn update(self: *CameraSystem, world: *World, delta_time: f32) !void {
        _ = delta_time;
        
        // Find main camera (highest priority)
        var camera_query = world.query(struct {
            camera: *CameraComponent,
            transform: *TransformComponent,
        });
        
        var highest_priority: i32 = std.math.minInt(i32);
        var main_camera: ?EntityId = null;
        
        var it = camera_query.iterator();
        while (it.next()) |result| {
            if (result.components.camera.priority > highest_priority) {
                highest_priority = result.components.camera.priority;
                main_camera = result.entity;
            }
        }
        
        self.main_camera = main_camera;
    }
    
    pub fn render(self: *CameraSystem, world: *World, renderer: *UnifiedRenderer) !void {
        if (self.main_camera) |camera_entity| {
            if (world.getComponent(CameraComponent, camera_entity)) |camera| {
                if (world.getComponent(TransformComponent, camera_entity)) |transform| {
                    const view_matrix = Math.Mat4.lookAt(
                        transform.translation,
                        Math.Vec3.add(transform.translation, Math.Vec3.forward()),  // forward direction
                        Math.Vec3.up()
                    );
                    
                    const proj_matrix = camera.getProjectionMatrix(16.0 / 9.0); // TODO: Get actual aspect ratio
                    
                    try renderer.setViewProjection(view_matrix, proj_matrix);
                }
            }
        }
    }
    
    pub fn deinit(self: *CameraSystem) void {
        _ = self;
    }
};
```

## Integration with Existing Systems

### Asset Manager Integration
```zig
pub const AssetManagerBridge = struct {
    asset_manager: *AssetManager,
    world: *World,
    
    pub fn createMeshEntity(self: *Self, mesh_path: []const u8, material_path: []const u8) !EntityId {
        // Load assets through asset manager
        const mesh_id = try self.asset_manager.loadMesh(mesh_path);
        const material_id = try self.asset_manager.loadMaterial(material_path);
        
        // Create ECS entity
        const entity = self.world.createEntity();
        try self.world.addComponent(entity, TransformComponent{});
        try self.world.addComponent(entity, MeshRendererComponent{
            .mesh_id = mesh_id,
            .material_id = material_id,
        });
        
        return entity;
    }
    
    pub fn onAssetReloaded(self: *Self, asset_id: AssetId, asset_type: AssetType) !void {
        switch (asset_type) {
            .mesh => {
                // Update all entities using this mesh
                var query = self.world.query(struct { mesh_renderer: *MeshRendererComponent });
                var it = query.iterator();
                while (it.next()) |result| {
                    if (result.components.mesh_renderer.mesh_id == asset_id) {
                        // Notify renderer that this entity needs update
                        // Could add a "dirty" component or flag
                    }
                }
            },
            .material => {
                // Similar for materials
                // ...
            },
            else => {},
        }
    }
};
```

### Scene Serialization
```zig
pub const SceneSerializer = struct {
    world: *World,
    asset_manager: *AssetManager,
    allocator: std.mem.Allocator,
    
    pub const SerializedEntity = struct {
        id: u64, // Stable ID for serialization
        components: std.json.Value,
    };
    
    pub const SerializedScene = struct {
        entities: []SerializedEntity,
        asset_dependencies: []AssetId,
    };
    
    pub fn serialize(self: *Self, entities: []EntityId) !std.json.Value {
        var serialized = std.ArrayList(SerializedEntity).init(self.allocator);
        defer serialized.deinit();
        
        for (entities) |entity| {
            var components = std.json.ObjectMap.init(self.allocator);
            
            // Serialize each component type
            if (self.world.getComponent(TransformComponent, entity)) |transform| {
                const transform_json = try self.serializeTransform(transform);
                try components.put("transform", transform_json);
            }
            
            if (self.world.getComponent(MeshRendererComponent, entity)) |mesh_renderer| {
                const mesh_renderer_json = try self.serializeMeshRenderer(mesh_renderer);
                try components.put("mesh_renderer", mesh_renderer_json);
            }
            
            // Add more component types...
            
            try serialized.append(.{
                .id = @intFromEnum(entity),
                .components = std.json.Value{ .object = components },
            });
        }
        
        return std.json.Value{ .array = std.json.Array.fromOwnedSlice(
            self.allocator, 
            try serialized.toOwnedSlice()
        )};
    }
    
    pub fn deserialize(self: *Self, scene_data: std.json.Value) ![]EntityId {
        // Implementation for loading scenes from JSON
        // ...
    }
};
```

## Migration Plan from Current System

### Phase 1: ECS Foundation (1-2 weeks)
1. **Implement Core ECS Components**
   - `EntityManager`, `World`, `ComponentStorage`
   - Basic component types: `TransformComponent`, `MeshRendererComponent`
   - Query system for efficient iteration

2. **Create System Architecture**
   - `SystemInterface` and system registration
   - Basic systems: `TransformSystem`, `RenderSystem`

3. **Integration Points**
   - Bridge between ECS and existing `Scene` class
   - Maintain compatibility with current `GameObject` approach

### Phase 2: Component Migration (2-3 weeks)
1. **Replace GameObject Components**
   - Migrate `PointLightComponent` to ECS
   - Add new components: `CameraComponent`, `HierarchyComponent`
   - Update rendering systems to use ECS queries

2. **Asset System Integration**
   - Connect ECS entities with Asset Manager
   - Implement asset change notifications to ECS

3. **Performance Optimization**
   - Implement component batching for rendering
   - Add spatial partitioning for culling

### Phase 3: Advanced Features (3-4 weeks)
1. **Scene Management**
   - Hierarchical transforms
   - Scene serialization/deserialization
   - Prefab system

2. **Animation and Physics**
   - Animation component and system
   - Basic physics integration
   - Component dependencies and ordering

3. **Developer Tools**
   - ECS inspector/debugger
   - Performance profiling
   - Component hot-reloading

## Performance Characteristics

### Memory Layout Benefits
- **Cache Friendly**: Components stored in contiguous arrays, not scattered in GameObjects
- **Memory Efficiency**: Only allocate memory for components that exist
- **Batch Processing**: Systems can process components in tight loops

### Query Performance
- **Fast Iteration**: Query system provides O(n) iteration over relevant entities only
- **Component Filtering**: Skip entities that don't have required components
- **Memory Prefetching**: Sequential access patterns improve cache utilization

### Scalability
- **Entity Limit**: 4 billion entities with generational indices
- **Component Types**: Unlimited component types via compile-time hashing
- **System Parallelization**: Systems can run in parallel when dependencies allow

## Conclusion

This ECS design provides a solid foundation for scalable game entity management in ZulkanZengine. It addresses the current limitations of rigid GameObject structure while maintaining integration with the existing Asset Manager and Renderer systems. The migration plan allows for gradual transition without breaking existing functionality.

The ECS will enable:
- **Better Performance**: Cache-friendly memory layout and efficient queries
- **Greater Flexibility**: Easy addition of new component types and systems
- **Cleaner Architecture**: Separation of concerns between data (components) and logic (systems)
- **Enhanced Tooling**: Better introspection and debugging capabilities

This design sets the stage for advanced features like complex animation systems, physics integration, and sophisticated rendering techniques while maintaining the performance characteristics necessary for real-time graphics applications.