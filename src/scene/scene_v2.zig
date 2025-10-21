const std = @import("std");
const log = @import("../utils/log.zig").log;
const Math = @import("../utils/math.zig");
const Vec3 = Math.Vec3;
const Mat4x4 = Math.Mat4x4;

const AssetManager = @import("../assets/asset_manager.zig").AssetManager;
const AssetId = @import("../assets/asset_types.zig").AssetId;

// ECS imports
const ecs = @import("../ecs.zig");
const World = ecs.World;
const EntityId = ecs.EntityId;
const Transform = ecs.Transform;
const MeshRenderer = ecs.MeshRenderer;
const Camera = ecs.Camera;

const GameObject = @import("game_object_v2.zig").GameObject;

/// Scene represents a game level/map
/// Provides high-level API for creating game objects backed by ECS
pub const Scene = struct {
    ecs_world: *World,
    asset_manager: *AssetManager,
    allocator: std.mem.Allocator,
    name: []const u8,

    // Track entities spawned in this scene for cleanup
    entities: std.ArrayList(EntityId),

    // Store GameObjects for stable pointer returns
    game_objects: std.ArrayList(GameObject),

    /// Initialize a new scene
    pub fn init(
        allocator: std.mem.Allocator,
        ecs_world: *World,
        asset_manager: *AssetManager,
        name: []const u8,
    ) Scene {
        log(.INFO, "scene_v2", "Creating scene: {s}", .{name});
        return Scene{
            .ecs_world = ecs_world,
            .asset_manager = asset_manager,
            .allocator = allocator,
            .name = name,
            .entities = std.ArrayList(EntityId){},
            .game_objects = std.ArrayList(GameObject){},
        };
    }

    /// Spawn a static prop with mesh and texture
    pub fn spawnProp(
        self: *Scene,
        model_path: []const u8,
        texture_path: []const u8,
    ) !*GameObject {
        log(.INFO, "scene_v2", "Spawning prop: {s}", .{model_path});

        // Load assets asynchronously using the correct API
        const AssetType = @import("../assets/asset_types.zig").AssetType;
        const LoadPriority = @import("../assets/asset_manager.zig").LoadPriority;

        // 1. Load model mesh
        const model_id = try self.asset_manager.loadAssetAsync(model_path, AssetType.mesh, LoadPriority.high);

        // 2. Load texture
        const texture_id = try self.asset_manager.loadAssetAsync(texture_path, AssetType.texture, LoadPriority.high);

        // 3. Create material from texture - this registers the material with AssetManager
        //    which will later upload it to the GPU material buffer
        const material_id = try self.asset_manager.createMaterial(texture_id);

        // Create ECS entity
        const entity = try self.ecs_world.createEntity();
        try self.entities.append(self.allocator, entity);

        // Add Transform component (identity transform)
        const transform = Transform.init();
        try self.ecs_world.emplace(Transform, entity, transform);

        // Add MeshRenderer component
        var mesh_renderer = MeshRenderer.init(model_id, material_id);
        mesh_renderer.setTexture(texture_id);
        try self.ecs_world.emplace(MeshRenderer, entity, mesh_renderer);

        // Create GameObject wrapper
        const game_object = GameObject{
            .entity_id = entity,
            .scene = self,
        };

        try self.game_objects.append(self.allocator, game_object);
        const last_index = self.game_objects.items.len - 1;

        log(.INFO, "scene_v2", "Spawned prop entity {} with assets: model={}, material={}, texture={}", .{ @intFromEnum(entity), @intFromEnum(model_id), @intFromEnum(material_id), @intFromEnum(texture_id) });

        return &self.game_objects.items[last_index];
    }

    /// Spawn a character (currently same as prop, will add physics/AI later)
    pub fn spawnCharacter(
        self: *Scene,
        model_path: []const u8,
        texture_path: []const u8,
    ) !*GameObject {
        log(.INFO, "scene_v2", "Spawning character: {s}", .{model_path});

        // For now, same as spawnProp
        // Future: Add RigidBody, CharacterController, etc.
        return try self.spawnProp(model_path, texture_path);
    }

    /// Spawn an empty object with just a Transform
    pub fn spawnEmpty(self: *Scene, name_opt: ?[]const u8) !*GameObject {
        if (name_opt) |name| {
            log(.INFO, "scene_v2", "Spawning empty object: {s}", .{name});
        } else {
            log(.INFO, "scene_v2", "Spawning empty object", .{});
        }
        // TODO: Store name in a Name component

        const entity = try self.ecs_world.createEntity();
        try self.entities.append(self.allocator, entity);

        const transform = Transform.init();
        try self.ecs_world.emplace(Transform, entity, transform);

        const game_object = GameObject{
            .entity_id = entity,
            .scene = self,
        };

        try self.game_objects.append(self.allocator, game_object);
        const last_index = self.game_objects.items.len - 1;

        return &self.game_objects.items[last_index];
    }

    /// Spawn a camera
    pub fn spawnCamera(
        self: *Scene,
        is_perspective: bool,
        fov_or_size: f32,
    ) !*GameObject {
        log(.INFO, "scene_v2", "Spawning camera (perspective={})", .{is_perspective});

        const entity = try self.ecs_world.createEntity();
        try self.entities.append(self.allocator, entity);

        // Add Transform (position will be set by caller)
        const transform = Transform.init();
        try self.ecs_world.emplace(Transform, entity, transform);

        // Add Camera component
        var camera = Camera.init();
        if (is_perspective) {
            camera.setPerspective(fov_or_size, 16.0 / 9.0, 0.1, 1000.0);
        } else {
            camera.setOrthographic(fov_or_size, 16.0 / 9.0, 0.1, 1000.0);
        }
        camera.setPrimary(true); // First camera is primary by default
        try self.ecs_world.emplace(Camera, entity, camera);

        const game_object = GameObject{
            .entity_id = entity,
            .scene = self,
        };

        try self.game_objects.append(self.allocator, game_object);
        const last_index = self.game_objects.items.len - 1;

        log(.INFO, "scene_v2", "Spawned camera entity {}", .{@intFromEnum(entity)});

        return &self.game_objects.items[last_index];
    }

    /// Spawn a point light (as empty object for now, will add Light component later)
    pub fn spawnLight(
        self: *Scene,
        _: Vec3, // color - reserved for future Light component
        _: f32,  // intensity - reserved for future Light component
    ) !*GameObject {
        log(.INFO, "scene_v2", "Spawning light (Light component not yet implemented)", .{});

        // For now, just create an empty object with Transform
        // TODO: Add Light component when implemented
        const light_obj = try self.spawnEmpty("light");
        return light_obj;
    }

    /// Spawn a particle emitter
    pub fn spawnParticleEmitter(
        self: *Scene,
        max_particles: u32,
        emission_rate: f32,
    ) !*GameObject {
        log(.INFO, "scene_v2", "Spawning particle emitter (max={}, rate={d:.2})", .{ max_particles, emission_rate });

        const entity = try self.ecs_world.createEntity();
        try self.entities.append(self.allocator, entity);

        // Add Transform
        const transform = Transform.init();
        try self.ecs_world.emplace(Transform, entity, transform);

        // Add ParticleComponent if registered
        const ParticleComponent = ecs.ParticleComponent;
        if (self.ecs_world.hasComponentType(ParticleComponent)) {
            var particle_comp = ParticleComponent.init();
            particle_comp.max_particles = max_particles;
            particle_comp.emission_rate = emission_rate;
            try self.ecs_world.emplace(ParticleComponent, entity, particle_comp);
        }

        const game_object = GameObject{
            .entity_id = entity,
            .scene = self,
        };

        try self.game_objects.append(self.allocator, game_object);
        const last_index = self.game_objects.items.len - 1;

        log(.INFO, "scene_v2", "Spawned particle emitter entity {}", .{@intFromEnum(entity)});

        return &self.game_objects.items[last_index];
    }

    /// Find a GameObject by entity ID
    pub fn findByEntity(self: *Scene, entity_id: EntityId) ?*GameObject {
        for (self.game_objects.items) |*obj| {
            if (obj.entity_id == entity_id) {
                return obj;
            }
        }
        return null;
    }

    /// Destroy a specific GameObject
    pub fn destroyObject(self: *Scene, game_object: *GameObject) void {
        const entity_id = game_object.entity_id;
        
        // Destroy in ECS world
        self.ecs_world.destroyEntity(entity_id);

        // Remove from tracked entities
        for (self.entities.items, 0..) |eid, i| {
            if (eid == entity_id) {
                _ = self.entities.swapRemove(i);
                break;
            }
        }

        // Remove from game objects (swap remove for performance)
        for (self.game_objects.items, 0..) |*obj, i| {
            if (obj.entity_id == entity_id) {
                _ = self.game_objects.swapRemove(i);
                break;
            }
        }

        log(.INFO, "scene_v2", "Destroyed entity {}", .{@intFromEnum(entity_id)});
    }

    /// Get entity count
    pub fn getEntityCount(self: *Scene) usize {
        return self.entities.items.len;
    }

    /// Iterator over all GameObjects in the scene
    pub fn iterateObjects(self: *Scene) []GameObject {
        return self.game_objects.items;
    }

    /// Unload scene - destroys all entities
    pub fn unload(self: *Scene) void {
        log(.INFO, "scene_v2", "Unloading scene: {s} ({} entities)", .{ self.name, self.entities.items.len });

        // Destroy all entities in reverse order
        var i = self.entities.items.len;
        while (i > 0) {
            i -= 1;
            self.ecs_world.destroyEntity(self.entities.items[i]);
        }

        self.entities.clearRetainingCapacity();
        self.game_objects.clearRetainingCapacity();

        log(.INFO, "scene_v2", "Scene unloaded: {s}", .{self.name});
    }

    /// Cleanup scene resources
    pub fn deinit(self: *Scene) void {
        self.unload();
        self.entities.deinit(self.allocator);
        self.game_objects.deinit(self.allocator);
        log(.INFO, "scene_v2", "Scene destroyed: {s}", .{self.name});
    }
};

// ==================== Tests ====================

const testing = std.testing;

test "Scene v2: init creates empty scene" {
    var world = World.init(testing.allocator, null);
    defer world.deinit();

    try world.registerComponent(Transform);
    try world.registerComponent(MeshRenderer);

    var mock_asset_manager: AssetManager = undefined;
    var scene = Scene.init(testing.allocator, &world, &mock_asset_manager, "test_scene");
    defer scene.deinit();

    try testing.expectEqual(@as(usize, 0), scene.entities.items.len);
    try testing.expectEqual(@as(usize, 0), scene.game_objects.items.len);
    try testing.expectEqualStrings("test_scene", scene.name);
}

test "Scene v2: spawnEmpty creates entity with Transform" {
    var world = World.init(testing.allocator, null);
    defer world.deinit();

    try world.registerComponent(Transform);
    try world.registerComponent(MeshRenderer);

    var mock_asset_manager: AssetManager = undefined;
    var scene = Scene.init(testing.allocator, &world, &mock_asset_manager, "test_scene");
    defer scene.deinit();

    const obj = try scene.spawnEmpty("empty_object");

    // Check entity was tracked
    try testing.expectEqual(@as(usize, 1), scene.entities.items.len);
    try testing.expectEqual(@as(usize, 1), scene.game_objects.items.len);

    // Check entity has Transform component
    try testing.expect(world.has(Transform, obj.entity_id));

    // Check default transform values
    const transform = try world.get(Transform, obj.entity_id);
    try testing.expectEqual(Vec3.init(0, 0, 0), transform.translation);
    try testing.expectEqual(Vec3.init(1, 1, 1), transform.scale);
}

test "Scene v2: unload destroys all entities" {
    var world = World.init(testing.allocator, null);
    defer world.deinit();

    try world.registerComponent(Transform);
    try world.registerComponent(MeshRenderer);

    var mock_asset_manager: AssetManager = undefined;
    var scene = Scene.init(testing.allocator, &world, &mock_asset_manager, "test_scene");
    defer scene.deinit();

    // Spawn some objects
    _ = try scene.spawnEmpty("obj1");
    _ = try scene.spawnEmpty("obj2");
    _ = try scene.spawnEmpty("obj3");

    try testing.expectEqual(@as(usize, 3), scene.entities.items.len);

    // Unload scene
    scene.unload();

    try testing.expectEqual(@as(usize, 0), scene.entities.items.len);
    try testing.expectEqual(@as(usize, 0), scene.game_objects.items.len);
}
