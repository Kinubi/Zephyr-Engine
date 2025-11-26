const std = @import("std");
const vk = @import("vulkan");
const log = @import("../utils/log.zig").log;
const Math = @import("../utils/math.zig");
const Vec3 = Math.Vec3;
const Mat4x4 = Math.Mat4x4;

const AssetManagerMod = @import("../assets/asset_manager.zig");
const AssetManager = AssetManagerMod.AssetManager;
const AssetType = AssetManagerMod.AssetType;
const LoadPriority = AssetManagerMod.LoadPriority;
const AssetId = @import("../assets/asset_types.zig").AssetId;
const GraphicsContext = @import("../core/graphics_context.zig").GraphicsContext;
const TextureManager = @import("../rendering/texture_manager.zig").TextureManager;
const Swapchain = @import("../core/swapchain.zig").Swapchain;
const UnifiedPipelineSystem = @import("../rendering/unified_pipeline_system.zig").UnifiedPipelineSystem;
const MaterialSystemMod = @import("../ecs/systems/material_system.zig");
// NOTE: TextureSystem deprecated - MaterialSystem now handles texture descriptors
const MaterialSystem = MaterialSystemMod.MaterialSystem;
// NOTE: MaterialBufferSet deprecated - MaterialSystem now directly queries components
const BufferManager = @import("../rendering/buffer_manager.zig").BufferManager;
const TextureDescriptorManager = @import("../rendering/texture_descriptor_manager.zig").TextureDescriptorManager;
const RenderGraph = @import("../rendering/render_graph.zig").RenderGraph;
const FrameInfo = @import("../rendering/frameinfo.zig").FrameInfo;
const GlobalUbo = @import("../rendering/frameinfo.zig").GlobalUbo;
const GlobalUboSet = @import("../rendering/ubo_set.zig").GlobalUboSet;
const PerformanceMonitor = @import("../rendering/performance_monitor.zig").PerformanceMonitor;
const ResourceBinder = @import("../rendering/resource_binder.zig").ResourceBinder;
const render_data_types = @import("../rendering/render_data_types.zig");
const GameStateSnapshot = @import("../threading/game_state_snapshot.zig").GameStateSnapshot;

const ParticleComputePass = @import("../rendering/passes/particle_compute_pass.zig").ParticleComputePass;
const GeometryPass = @import("../rendering/passes/geometry_pass.zig").GeometryPass;
const LightVolumePass = @import("../rendering/passes/light_volume_pass.zig").LightVolumePass;
const ParticlePass = @import("../rendering/passes/particle_pass.zig").ParticlePass;
const PathTracingPass = @import("../rendering/passes/path_tracing_pass.zig").PathTracingPass;
const TonemapPass = @import("../rendering/passes/tonemap_pass.zig").TonemapPass;
const BaseRenderPass = @import("../rendering/passes/base_render_pass.zig").BaseRenderPass;
const vertex_formats = @import("../rendering/vertex_formats.zig");

const ThreadPool = @import("../threading/thread_pool.zig").ThreadPool;

// ECS imports
const ecs = @import("../ecs.zig");
const World = ecs.World;
const EntityId = ecs.EntityId;
const Transform = ecs.Transform;
const MeshRenderer = ecs.MeshRenderer;
const Camera = ecs.Camera;
const PointLight = ecs.PointLight;
const Name = ecs.Name;
const UuidComponent = ecs.UuidComponent;

const GameObject = @import("game_object.zig").GameObject;
const SceneSerializer = @import("scene_serializer.zig").SceneSerializer;

/// Scene represents a game level/map
/// Provides high-level API for creating game objects backed by ECS
pub const Scene = struct {
    ecs_world: *World,
    asset_manager: *AssetManager,
    allocator: std.mem.Allocator,
    name: []const u8,

    // Scene state
    state: SceneState = .Edit,

    // Snapshot of the scene state before entering Play mode
    play_mode_snapshot: ?std.ArrayList(u8) = null,

    // Track entities spawned in this scene for cleanup
    entities: std.ArrayList(EntityId),

    // Store GameObjects for stable pointer returns
    game_objects: std.ArrayList(GameObject),

    // Rendering pipeline for this scene
    render_graph: ?*RenderGraph = null,

    // Emitter tracking: map ECS entity ID to GPU emitter ID
    emitter_to_gpu_id: std.AutoHashMap(EntityId, u32),

    // Animation time tracking
    time_elapsed: f32 = 0.0,

    // Random number generator for particle systems
    random: std.Random.DefaultPrng,

    // Cache view-projection matrix for particle world-to-screen projection
    cached_view_proj: Math.Mat4x4 = Math.Mat4x4.identity(),

    // Light system (reused across frames instead of recreating)
    light_system: ecs.LightSystem,

    // Shared render system for both raster and ray tracing passes
    render_system: *ecs.RenderSystem,

    // Scripting system (owned by the Scene)
    scripting_system: *ecs.ScriptingSystem,
    physics_system: ?*ecs.PhysicsSystem = null,

    // Rendering domain systems (owned by the Scene)
    material_system: ?*MaterialSystem = null,
    particle_system: ?*ecs.ParticleSystem = null,
    // NOTE: TextureSystem moved to Engine - it manages infrastructure textures (HDR/LDR)

    // Performance monitoring
    performance_monitor: ?*PerformanceMonitor = null,

    // Thread-safe path tracing state (set by main thread, applied by render thread)
    // -1 = no change pending, 0 = disable requested, 1 = enable requested
    pending_pt_state: std.atomic.Value(i32) = std.atomic.Value(i32).init(-1),

    // Read-write lock to synchronize updates with scene modifications (clearing/loading)
    // Main thread holds exclusive lock during load/clear
    // Render thread holds shared lock during update/render
    state_lock: std.Thread.RwLock = .{},

    // Input state tracking for scripts (updated by SceneLayer from events)
    // Tracks up to 512 keys (covers all GLFW key codes)
    key_states: [512]bool = [_]bool{false} ** 512,
    // Mouse button states (up to 8 buttons)
    mouse_button_states: [8]bool = [_]bool{false} ** 8,
    // Mouse position
    mouse_x: f64 = 0,
    mouse_y: f64 = 0,

    // Engine context references
    graphics_context: *GraphicsContext,
    pipeline_system: *UnifiedPipelineSystem,
    buffer_manager: *BufferManager,
    descriptor_manager: *TextureDescriptorManager,
    texture_manager: *TextureManager,
    swapchain: *Swapchain,
    global_ubo_set: *GlobalUboSet,
    thread_pool: *ThreadPool,

    /// Initialize a new scene
    pub fn init(
        allocator: std.mem.Allocator,
        ecs_world: *World,
        asset_manager: *AssetManager,
        graphics_context: *GraphicsContext,
        pipeline_system: *UnifiedPipelineSystem,
        buffer_manager: *BufferManager,
        descriptor_manager: *TextureDescriptorManager,
        texture_manager: *TextureManager,
        swapchain: *Swapchain,
        thread_pool: *ThreadPool,
        global_ubo_set: *GlobalUboSet,
        name: []const u8,
    ) !Scene {
        log(.INFO, "scene", "Creating scene: {s}", .{name});

        // Initialize random number generator with current time as seed
        const seed = @as(u64, @intCast(std.time.timestamp()));
        const prng = std.Random.DefaultPrng.init(seed);

        const render_system = try allocator.create(ecs.RenderSystem);
        render_system.* = try ecs.RenderSystem.init(allocator, thread_pool, buffer_manager);
        try ecs_world.setUserData("render_system", @ptrCast(render_system));

        const scripting_system = try allocator.create(ecs.ScriptingSystem);
        scripting_system.* = try ecs.ScriptingSystem.init(allocator, thread_pool, 4);

        var scene = Scene{
            .ecs_world = ecs_world,
            .asset_manager = asset_manager,
            .allocator = allocator,
            .name = name,
            .entities = std.ArrayList(EntityId){},
            .game_objects = std.ArrayList(GameObject){},
            .emitter_to_gpu_id = std.AutoHashMap(EntityId, u32).init(allocator),
            .random = prng,
            .light_system = ecs.LightSystem.init(allocator),
            .render_system = render_system,
            .scripting_system = scripting_system,
            .physics_system = try ecs.PhysicsSystem.init(allocator),
            .graphics_context = graphics_context,
            .pipeline_system = pipeline_system,
            .buffer_manager = buffer_manager,
            .descriptor_manager = descriptor_manager,
            .texture_manager = texture_manager,
            .swapchain = swapchain,
            .global_ubo_set = global_ubo_set,
            .thread_pool = thread_pool,
        };

        // Initialize render graph with empty scene
        // Directly initialize resources instead of calling load(null) to avoid unnecessary clear()
        try scene.initRenderGraphResources();

        return scene;
    }

    /// Save the scene to a JSON file
    pub fn save(self: *Scene, file_path: []const u8) !void {
        var file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();

        var buffer: [4096]u8 = undefined;
        var buffered_writer = file.writer(&buffer);
        var writer_interface = &buffered_writer.interface;

        var serializer = SceneSerializer.init(self);

        var stringify = std.json.Stringify{
            .writer = writer_interface,
            .options = .{ .whitespace = .indent_4 },
            .indent_level = 0,
            .next_punctuation = .the_beginning,
            .nesting_stack = undefined,
            .raw_streaming_mode = .none,
        };

        try serializer.jsonStringify(&stringify);
        try writer_interface.flush();
    }

    /// Load the scene from a JSON file
    pub fn load(self: *Scene, file_path: ?[]const u8) !void {
        self.state_lock.lock();
        defer self.state_lock.unlock();

        // Clear existing scene first
        self.clearInternal();

        // Clean up old render graph resources before creating new ones
        if (self.render_graph) |graph| {
            graph.deinit();
            self.allocator.destroy(graph);
            self.render_graph = null;
        }
        if (self.particle_system) |ps| {
            ps.deinit();
            self.allocator.destroy(ps);
            self.particle_system = null;
        }
        if (self.material_system) |ms| {
            ms.deinit();
            self.allocator.destroy(ms);
            self.material_system = null;
        }
        if (self.physics_system) |ps| {
            ps.deinit();
            self.allocator.destroy(ps);
            self.physics_system = null;
        }

        // Recreate ScriptingSystem to ensure clean state (no pending actions, fresh Lua states)
        self.scripting_system.deinit();
        self.allocator.destroy(self.scripting_system);
        self.scripting_system = try self.allocator.create(ecs.ScriptingSystem);
        self.scripting_system.* = try ecs.ScriptingSystem.init(self.allocator, self.thread_pool, 4);

        // Recreate RenderSystem to ensure clean state (fresh instance buffers)
        self.render_system.deinit();
        self.allocator.destroy(self.render_system);
        self.render_system = try self.allocator.create(ecs.RenderSystem);
        self.render_system.* = try ecs.RenderSystem.init(self.allocator, self.thread_pool, self.buffer_manager);

        // Restore render_system since clear() removed it (and we just recreated it)
        try self.ecs_world.setUserData("render_system", @ptrCast(self.render_system));

        // Initialize Render Graph and Systems
        try self.initRenderGraphResources();

        if (file_path) |path| {
            const file = try std.fs.cwd().openFile(path, .{});
            defer file.close();

            const file_size = (try file.stat()).size;
            const buffer = try self.allocator.alloc(u8, file_size);
            defer self.allocator.free(buffer);

            _ = try file.readAll(buffer);

            var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, buffer, .{});
            defer parsed.deinit();

            var serializer = SceneSerializer.init(self);
            defer serializer.deinit();

            try serializer.deserialize(parsed.value);

            // Register deserialized particle emitters
            for (self.game_objects.items) |game_obj| {
                const entity = game_obj.entity_id;
                if (self.ecs_world.get(ecs.ParticleEmitter, entity)) |emitter| {
                    if (self.ecs_world.get(Transform, entity)) |transform| {
                        try self.registerEmitterWithSystem(entity, emitter.*, transform.*);
                    }
                }
            }
        }
    }

    /// Set the performance monitor for profiling
    pub fn setPerformanceMonitor(self: *Scene, monitor: ?*PerformanceMonitor) void {
        self.performance_monitor = monitor;
    }

    /// Spawn a static prop with mesh and texture
    /// Material parameters for spawnProp
    pub const MaterialParams = struct {
        albedo_texture_path: ?[]const u8 = null,
        roughness_texture_path: ?[]const u8 = null,
        metallic_texture_path: ?[]const u8 = null,
        normal_texture_path: ?[]const u8 = null,
        emissive_texture_path: ?[]const u8 = null,

        albedo_color: [4]f32 = [4]f32{ 1.0, 1.0, 1.0, 1.0 },
        roughness: f32 = 0.5,
        metallic: f32 = 0.0,
        emissive: f32 = 0.0,
        normal_strength: f32 = 1.0,
        emissive_color: [3]f32 = [3]f32{ 1.0, 1.0, 1.0 },

        set_name: []const u8 = "opaque", // Material set name (e.g., "opaque", "transparent", "character")
        shader_variant: []const u8 = "pbr_standard",
    };

    pub fn spawnProp(
        self: *Scene,
        model_path: []const u8,
        material_params: MaterialParams,
    ) !*GameObject {

        // 1. Load model mesh
        const model_id = try self.asset_manager.loadAssetAsync(model_path, AssetType.mesh, LoadPriority.high);

        // 2. Load textures (if provided)
        const albedo_texture_id = if (material_params.albedo_texture_path) |path|
            try self.asset_manager.loadAssetAsync(path, AssetType.texture, LoadPriority.high)
        else
            AssetId.invalid;

        const roughness_texture_id = if (material_params.roughness_texture_path) |path|
            try self.asset_manager.loadAssetAsync(path, AssetType.texture, LoadPriority.high)
        else
            AssetId.invalid;

        const metallic_texture_id = if (material_params.metallic_texture_path) |path|
            try self.asset_manager.loadAssetAsync(path, AssetType.texture, LoadPriority.high)
        else
            AssetId.invalid;

        const normal_texture_id = if (material_params.normal_texture_path) |path|
            try self.asset_manager.loadAssetAsync(path, AssetType.texture, LoadPriority.high)
        else
            AssetId.invalid;

        const emissive_texture_id = if (material_params.emissive_texture_path) |path|
            try self.asset_manager.loadAssetAsync(path, AssetType.texture, LoadPriority.high)
        else
            AssetId.invalid;

        // Create ECS entity
        const entity = try self.ecs_world.createEntity();
        try self.entities.append(self.allocator, entity);

        // Add Transform component (identity transform)
        const transform = Transform.init();
        try self.ecs_world.emplace(Transform, entity, transform);

        // Add MeshRenderer component (just references the model)
        const mesh_renderer = MeshRenderer.init(model_id);
        try self.ecs_world.emplace(MeshRenderer, entity, mesh_renderer);

        // Add MaterialSet component
        const material_set = ecs.MaterialSet{
            .set_name = material_params.set_name,
            .shader_variant = material_params.shader_variant,
        };
        try self.ecs_world.emplace(ecs.MaterialSet, entity, material_set);

        // Add UuidComponent
        try self.ecs_world.emplace(UuidComponent, entity, UuidComponent.init());

        // Add material property components (only if textures are provided)
        if (albedo_texture_id.toU64() != 0) {
            const albedo_mat = ecs.AlbedoMaterial.initWithTint(albedo_texture_id, material_params.albedo_color);
            try self.ecs_world.emplace(ecs.AlbedoMaterial, entity, albedo_mat);
        }

        if (roughness_texture_id.toU64() != 0) {
            const roughness_mat = ecs.RoughnessMaterial.initWithFactor(roughness_texture_id, material_params.roughness);
            try self.ecs_world.emplace(ecs.RoughnessMaterial, entity, roughness_mat);
        }

        if (metallic_texture_id.toU64() != 0) {
            const metallic_mat = ecs.MetallicMaterial.initWithFactor(metallic_texture_id, material_params.metallic);
            try self.ecs_world.emplace(ecs.MetallicMaterial, entity, metallic_mat);
        }

        if (normal_texture_id.toU64() != 0) {
            const normal_mat = ecs.NormalMaterial.initWithStrength(normal_texture_id, material_params.normal_strength);
            try self.ecs_world.emplace(ecs.NormalMaterial, entity, normal_mat);
        }

        if (emissive_texture_id.toU64() != 0) {
            const emissive_mat = ecs.EmissiveMaterial.initFull(emissive_texture_id, material_params.emissive_color, material_params.emissive);
            try self.ecs_world.emplace(ecs.EmissiveMaterial, entity, emissive_mat);
        }

        // Create GameObject wrapper
        const game_object = GameObject{
            .entity_id = entity,
            .scene = self,
        };

        try self.game_objects.append(self.allocator, game_object);
        const last_index = self.game_objects.items.len - 1;

        return &self.game_objects.items[last_index];
    }

    /// Update an existing entity's model and texture assets (or add MeshRenderer if missing)
    /// Loads the model & texture via the AssetManager and creates a material for the texture.
    /// Marks the entity's Transform as dirty so render systems pick up the change.
    pub fn updatePropAssets(
        self: *Scene,
        entity: EntityId,
        model_path: []const u8,
        texture_path: []const u8,
    ) !void {
        // Validate entity
        if (!self.ecs_world.isValid(entity)) return error.InvalidArgument;

        // 1. Request model and texture asynchronously (high priority for immediate updates)
        const model_id = try self.asset_manager.loadAssetAsync(model_path, AssetType.mesh, LoadPriority.high);
        const texture_id = try self.asset_manager.loadAssetAsync(texture_path, AssetType.texture, LoadPriority.high);

        // Ensure Transform exists and mark dirty so render/compute systems will update GPU state
        if (!self.ecs_world.has(Transform, entity)) {
            const transform = Transform.init();
            try self.ecs_world.emplace(Transform, entity, transform);
            try self.entities.append(self.allocator, entity);
        } else {
            const transform = self.ecs_world.get(Transform, entity) orelse return error.EntityHasNoTransform;
            transform.dirty = true;
        }

        // Update or add MeshRenderer component
        if (self.ecs_world.has(MeshRenderer, entity)) {
            const mr = self.ecs_world.get(MeshRenderer, entity) orelse return error.ComponentNotRegistered;
            mr.setModel(model_id);
        } else {
            const mesh_renderer = MeshRenderer.init(model_id);
            try self.ecs_world.emplace(MeshRenderer, entity, mesh_renderer);
        }

        // Update AlbedoMaterial with the texture
        const albedo_mat = ecs.AlbedoMaterial.init(texture_id);
        try self.ecs_world.emplace(ecs.AlbedoMaterial, entity, albedo_mat);

        log(.INFO, "scene", "Updated assets for entity {} -> model:{s} texture:{s}", .{ @intFromEnum(entity), model_path, texture_path });
    }

    /// Convenience: update only the model asset for an entity
    pub fn updateModelForEntity(
        self: *Scene,
        entity: EntityId,
        model_path: []const u8,
    ) !void {
        if (!self.ecs_world.isValid(entity)) return error.InvalidArgument;
        const model_id = try self.asset_manager.loadAssetAsync(model_path, AssetType.mesh, LoadPriority.high);

        if (self.ecs_world.has(MeshRenderer, entity)) {
            const mr = self.ecs_world.get(MeshRenderer, entity) orelse return error.ComponentNotRegistered;
            mr.setModel(model_id);
        } else {
            // Create a model-only renderer (material will be provided by material system)
            const mesh_renderer = MeshRenderer.init(model_id);
            try self.ecs_world.emplace(MeshRenderer, entity, mesh_renderer);
        }

        if (self.ecs_world.get(Transform, entity)) |transform| {
            transform.dirty = true;
        }
    }

    /// Convenience: update only the texture (and material) for an entity
    /// DEPRECATED: This uses old asset-based materials. Use material components instead.
    pub fn updateTextureForEntity(
        self: *Scene,
        entity: EntityId,
        texture_path: []const u8,
    ) !void {
        _ = self;
        _ = entity;
        _ = texture_path;
        log(.WARN, "scene", "updateTextureForEntity is DEPRECATED - use material components instead", .{});
        return error.DeprecatedFunction;
    }

    /// Spawn a character (currently same as prop, will add physics/AI later)
    pub fn spawnCharacter(
        self: *Scene,
        model_path: []const u8,
        texture_path: []const u8,
    ) !*GameObject {
        log(.INFO, "scene", "Spawning character: {s}", .{model_path});

        // For now, same as spawnProp
        // Future: Add RigidBody, CharacterController, etc.
        return try self.spawnProp(model_path, texture_path);
    }

    /// Spawn an empty object with just a Transform
    pub fn spawnEmpty(self: *Scene, name_opt: ?[]const u8) !*GameObject {
        if (name_opt) |name| {
            log(.INFO, "scene", "Spawning empty object: {s}", .{name});
        } else {
            log(.INFO, "scene", "Spawning empty object", .{});
        }

        const entity = try self.ecs_world.createEntity();
        try self.entities.append(self.allocator, entity);

        const transform = Transform.init();
        try self.ecs_world.emplace(Transform, entity, transform);

        // Add Name component if name provided
        if (name_opt) |name| {
            const name_component = try Name.init(self.allocator, name);
            try self.ecs_world.emplace(Name, entity, name_component);
        }

        // Add UuidComponent
        try self.ecs_world.emplace(UuidComponent, entity, UuidComponent.init());

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
        log(.INFO, "scene", "Spawning camera (perspective={})", .{is_perspective});

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
            const aspect = 16.0 / 9.0;
            const height = fov_or_size;
            const width = height * aspect;
            camera.setOrthographic(-width * 0.5, width * 0.5, -height * 0.5, height * 0.5, 0.1, 1000.0);
        }
        camera.setPrimary(true); // First camera is primary by default
        try self.ecs_world.emplace(Camera, entity, camera);

        // Add UuidComponent
        try self.ecs_world.emplace(UuidComponent, entity, UuidComponent.init());

        const game_object = GameObject{
            .entity_id = entity,
            .scene = self,
        };

        try self.game_objects.append(self.allocator, game_object);
        const last_index = self.game_objects.items.len - 1;

        log(.INFO, "scene", "Spawned camera entity {}", .{@intFromEnum(entity)});

        return &self.game_objects.items[last_index];
    }

    /// Spawn a point light
    pub fn spawnLight(
        self: *Scene,
        color: Vec3,
        intensity: f32,
    ) !*GameObject {
        log(.INFO, "scene", "Spawning point light (color={d:.2}/{d:.2}/{d:.2}, intensity={d:.2})", .{ color.x, color.y, color.z, intensity });

        // Create entity with Transform and Name
        const light_obj = try self.spawnEmpty("light");

        // Add PointLight component
        const point_light = PointLight.initWithColor(color, intensity);
        try self.ecs_world.emplace(PointLight, light_obj.entity_id, point_light);

        return light_obj;
    }

    /// Add a particle emitter to an existing entity
    pub fn addParticleEmitter(
        self: *Scene,
        entity: EntityId,
        emission_rate: f32,
        particle_lifetime: f32,
    ) !void {
        log(.INFO, "scene", "Adding particle emitter to entity {} (rate={d:.2}, lifetime={d:.2})", .{ @intFromEnum(entity), emission_rate, particle_lifetime });

        // Get entity transform for emitter position
        const transform = self.ecs_world.get(Transform, entity) orelse return error.EntityHasNoTransform;
        transform.dirty = true;

        // Create ECS emitter component
        var emitter = ecs.ParticleEmitter.initWithRate(emission_rate);
        emitter.particle_lifetime = particle_lifetime;
        emitter.active = true;
        emitter.velocity_min = .{ .x = -1.5, .y = 5.0, .z = -1.5 };
        emitter.velocity_max = .{ .x = 1.5, .y = 8.0, .z = 1.5 };
        emitter.color = .{ .x = 1.0, .y = 0.8, .z = 0.3 }; // Golden color

        try self.ecs_world.emplace(ecs.ParticleEmitter, entity, emitter);

        try self.registerEmitterWithSystem(entity, emitter, transform.*);
    }

    fn registerEmitterWithSystem(self: *Scene, entity: EntityId, emitter: ecs.ParticleEmitter, transform: Transform) !void {
        // Register emitter with GPU via ParticleSystem
        if (self.particle_system) |ps| {
            // Create GPU emitter struct
            const gpu_emitter = vertex_formats.GPUEmitter{
                .position = .{ transform.position.x, transform.position.y, transform.position.z },
                .is_active = if (emitter.active) 1 else 0,
                .velocity_min = .{ emitter.velocity_min.x, emitter.velocity_min.y, emitter.velocity_min.z },
                .velocity_max = .{ emitter.velocity_max.x, emitter.velocity_max.y, emitter.velocity_max.z },
                .color_start = .{ emitter.color.x, emitter.color.y, emitter.color.z, 1.0 },
                .color_end = .{ emitter.color.x * 0.5, emitter.color.y * 0.5, emitter.color.z * 0.5, 0.0 }, // Fade to darker
                .lifetime_min = emitter.particle_lifetime * 0.8,
                .lifetime_max = emitter.particle_lifetime * 1.2,
                .spawn_rate = emitter.emission_rate,
                .accumulated_spawn_time = 0.0,
                .particles_per_spawn = 1,
            };

            // Spawn some initial particles (more for better visual effect)
            const initial_particle_count = 200;
            const initial_particles = try self.allocator.alloc(vertex_formats.Particle, initial_particle_count);
            defer self.allocator.free(initial_particles);

            // Generate random initial particles (alive for immediate visibility)
            for (initial_particles) |*particle| {
                const rand_x = gpu_emitter.velocity_min[0] + (gpu_emitter.velocity_max[0] - gpu_emitter.velocity_min[0]) * self.random.random().float(f32);
                const rand_y = gpu_emitter.velocity_min[1] + (gpu_emitter.velocity_max[1] - gpu_emitter.velocity_min[1]) * self.random.random().float(f32);
                const rand_z = gpu_emitter.velocity_min[2] + (gpu_emitter.velocity_max[2] - gpu_emitter.velocity_min[2]) * self.random.random().float(f32);
                const lifetime = gpu_emitter.lifetime_min + (gpu_emitter.lifetime_max - gpu_emitter.lifetime_min) * self.random.random().float(f32);

                particle.* = vertex_formats.Particle{
                    .position = gpu_emitter.position,
                    .velocity = .{ rand_x, rand_y, rand_z },
                    .color = gpu_emitter.color_start,
                    .lifetime = lifetime * 0.5, // Start particles mid-life for immediate visibility
                    .max_lifetime = lifetime,
                    .emitter_id = 0, // Will be set by spawnParticlesForEmitter

                };
            }

            // Add emitter to ParticleSystem and track the GPU ID
            const gpu_emitter_id = try ps.addEmitter(gpu_emitter, initial_particles);
            try self.emitter_to_gpu_id.put(entity, gpu_emitter_id);

            log(.INFO, "scene", "Added particle emitter {} (gpu_id={})", .{ @intFromEnum(entity), gpu_emitter_id });
        }
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

        // Release any Lua state owned by a ScriptComponent before destroying the entity
        if (self.ecs_world.get(ecs.ScriptComponent, entity_id)) |sc| {
            self.scripting_system.releaseScriptState(sc);
        }

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

        log(.INFO, "scene", "Destroyed entity {}", .{@intFromEnum(entity_id)});
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
        log(.INFO, "scene", "Unloading scene: {s} ({} entities)", .{ self.name, self.entities.items.len });

        // Release all Lua states before destroying entities
        for (self.entities.items) |entity_id| {
            if (self.ecs_world.get(ecs.ScriptComponent, entity_id)) |sc| {
                self.scripting_system.releaseScriptState(sc);
            }
        }

        // Destroy all entities in reverse order
        var i = self.entities.items.len;
        while (i > 0) {
            i -= 1;
            self.ecs_world.destroyEntity(self.entities.items[i]);
        }

        self.entities.clearRetainingCapacity();
        self.game_objects.clearRetainingCapacity();

        // Remove render_system from ECS user data
        _ = self.ecs_world.removeUserData("render_system");

        log(.INFO, "scene", "Scene unloaded: {s}", .{self.name});
    }

    /// Cleanup scene resources
    pub fn deinit(self: *Scene) void {
        self.unload();
        if (self.render_graph) |graph| {
            graph.deinit();
            self.allocator.destroy(graph);
        }
        log(.INFO, "scene", "Deinitializing scene: {s}", .{self.name});
        self.entities.deinit(self.allocator);
        self.game_objects.deinit(self.allocator);
        self.emitter_to_gpu_id.deinit();
        // Deinit scripting system
        self.scripting_system.deinit();
        self.allocator.destroy(self.scripting_system);

        // Deinit rendering domain systems
        // NOTE: TextureSystem now owned by Engine
        if (self.material_system) |ms| {
            ms.deinit();
        }
        if (self.particle_system) |ps| {
            ps.deinit();
        }

        if (self.physics_system) |ps| {
            log(.INFO, "scene", "Deinitializing physics system...", .{});
            ps.deinit();
            log(.INFO, "scene", "Physics system deinitialized", .{});
        } else {
            log(.WARN, "scene", "Physics system is null in deinit!", .{});
        }

        self.light_system.deinit();
        self.render_system.deinit();
        log(.INFO, "scene", "Scene destroyed: {s}", .{self.name});
    }

    /// Set path tracing enabled/disabled state
    /// @param enabled: true to enable path tracing, false to disable
    /// This sets an explicit state rather than toggling, so calling with the same
    /// value multiple times is idempotent (safe and will do nothing if already in that state)
    pub fn setPathTracingEnabled(self: *Scene, enabled: bool) !void {
        // THREAD-SAFE: Set desired state atomically
        // Main thread sets state, render thread applies it
        const state_value: i32 = if (enabled) 1 else 0;
        self.pending_pt_state.store(state_value, .release);
    }

    /// Apply pending path tracing state change (called on RENDER THREAD)
    /// Returns true if state was changed
    pub fn applyPendingPathTracingToggle(self: *Scene) !bool {
        // Get pending state and reset to "no change pending"
        const pending_state = self.pending_pt_state.swap(-1, .acq_rel);
        if (pending_state == -1) return false; // No pending state change

        const new_enabled = pending_state == 1;

        // Update render graph pass states (SAFE: on render thread)
        if (self.render_graph) |graph| {
            // Get current state to check if it actually needs to change
            const currently_enabled = if (graph.getPass("path_tracing_pass")) |pass| pass.enabled else false;

            // If state is already what we want, no need to change
            if (currently_enabled == new_enabled) {
                log(.DEBUG, "scene", "Path tracing already in desired state ({}), no change needed", .{new_enabled});
                return false;
            }

            // Set the path tracing pass's internal flag via its setEnabled method
            if (graph.getPass("path_tracing_pass")) |pass| {
                const pt_pass: *PathTracingPass = @fieldParentPtr("base", pass);
                pt_pass.setEnabled(new_enabled);
            }

            if (new_enabled) {
                // Path tracing mode: disable raster passes, enable PT
                graph.disablePass("geometry_pass");
                graph.disablePass("particle_pass");
                graph.disablePass("light_volume_pass");
                graph.enablePass("path_tracing_pass");
                try graph.recompile();
                // CRITICAL: Wait for GPU to finish all in-flight work before continuing
                // The render graph recompile changes pipeline state, and we need to ensure
                // any previous frames using the old pipelines have completed before we
                // submit new work. This prevents fence reuse issues where we try to use
                // a fence that's still in-flight from the previous submit.

                log(.INFO, "scene", "Path tracing ENABLED for scene: {s}", .{self.name});
            } else {
                // Raster mode: enable raster passes, disable PT
                graph.enablePass("geometry_pass");
                graph.enablePass("particle_pass");
                graph.enablePass("light_volume_pass");
                graph.disablePass("path_tracing_pass");
                try graph.recompile();
                log(.INFO, "scene", "Path tracing DISABLED for scene: {s}", .{self.name});
            }
            return true;
        } else {
            log(.WARN, "scene", "Cannot toggle path tracing - render graph not initialized", .{});
            return false;
        }
    }

    /// Initialize rendering pipeline for this scene
    /// Internal helper called by load()
    fn initRenderGraphResources(self: *Scene) !void {
        const graphics_context = self.graphics_context;
        const pipeline_system = self.pipeline_system;
        const buffer_manager = self.buffer_manager;
        const descriptor_manager = self.descriptor_manager;
        const texture_manager = self.texture_manager;
        const swapchain = self.swapchain;
        const thread_pool = self.thread_pool;
        const global_ubo_set = self.global_ubo_set;
        const width = swapchain.extent.width;
        const height = swapchain.extent.height;

        // Initialize Material system for this scene
        // MaterialSystem now directly queries ECS components and builds GPU resources
        self.material_system = try MaterialSystem.init(
            self.allocator,
            buffer_manager,
            descriptor_manager,
            self.asset_manager,
        );

        log(.INFO, "scene", "Initialized material system (ECS-driven)", .{});

        // Create particle system (owns particle GPU buffers)
        const max_emitters = 16;
        const particles_per_emitter = 200;
        self.particle_system = try ecs.ParticleSystem.init(
            self.allocator,
            graphics_context,
            buffer_manager,
            particles_per_emitter * max_emitters, // 200 particles per emitter * 16 emitters = 3200 total
            max_emitters,
        );

        log(.INFO, "scene", "Initialized particle system (ECS-driven)", .{});

        // Initialize Physics System if not already (e.g. after load/clear)
        if (self.physics_system == null) {
            self.physics_system = try ecs.PhysicsSystem.init(self.allocator);
            log(.INFO, "scene", "Initialized physics system (Jolt)", .{});
        }

        // Create render graph
        self.render_graph = try self.allocator.create(RenderGraph);
        self.render_graph.?.* = RenderGraph.init(self.allocator, graphics_context);

        // Create and add ParticleComputePass FIRST (runs on compute queue)
        const particle_compute_pass = ParticleComputePass.create(
            self.allocator,
            graphics_context,
            pipeline_system,
            self.particle_system.?,
            self.ecs_world,
        ) catch |err| blk: {
            log(.WARN, "scene", "Failed to create ParticleComputePass: {}. Particles disabled.", .{err});
            break :blk null;
        };

        if (particle_compute_pass) |pass| {
            try self.render_graph.?.addPass(&pass.base);
        }

        // Create and add GeometryPass
        // Get direct access to material set data for the opaque set
        const opaque_material_set = try self.material_system.?.getOrCreateSet("opaque");

        const geometry_pass = GeometryPass.create(
            self.allocator,
            graphics_context,
            pipeline_system,
            buffer_manager,
            self.asset_manager,
            self.ecs_world,
            global_ubo_set,
            opaque_material_set,
            descriptor_manager,
            swapchain.hdr_format,
            try swapchain.depthFormat(),
            self.render_system,
            "geometry_pass",
            "opaque",
        ) catch |err| blk: {
            log(.WARN, "scene", "Failed to create GeometryPass: {}. Geometry rendering disabled.", .{err});
            break :blk null;
        };

        if (geometry_pass) |pass| {
            try self.render_graph.?.addPass(&pass.base);
        }

        // Create PathTracingPass (alternative to raster rendering)
        // Get direct access to material set data for the opaque set
        const path_tracing_material_set = try self.material_system.?.getOrCreateSet("opaque");
        const path_tracing_pass = PathTracingPass.create(
            self.allocator,
            graphics_context,
            pipeline_system,
            thread_pool,
            global_ubo_set,
            self.ecs_world,
            self.asset_manager,
            self.render_system,
            texture_manager,
            path_tracing_material_set,
            descriptor_manager,
            swapchain,
            width,
            height,
        ) catch |err| blk: {
            log(.WARN, "scene", "Failed to create PathTracingPass: {}. Path tracing disabled.", .{err});
            break :blk null;
        };

        // NOTE: Path tracing pass starts disabled (enable via setPathTracingEnabled())
        if (path_tracing_pass) |pass| {
            try self.render_graph.?.addPass(&pass.base);
        }

        // Create and add LightVolumePass (renders after geometry)
        const light_volume_pass = LightVolumePass.create(
            self.allocator,
            graphics_context,
            pipeline_system,
            buffer_manager,
            self.ecs_world,
            global_ubo_set,
            swapchain.hdr_format,
            try swapchain.depthFormat(),
        ) catch |err| blk: {
            log(.WARN, "scene", "Failed to create LightVolumePass: {}. Point light rendering disabled.", .{err});
            break :blk null;
        };

        if (light_volume_pass) |pass| {
            try self.render_graph.?.addPass(&pass.base);
        }

        // Create and add ParticlePass (renders particles with alpha blending)
        const particle_pass = ParticlePass.create(
            self.allocator,
            graphics_context,
            pipeline_system,
            global_ubo_set,
            swapchain.hdr_format,
            try swapchain.depthFormat(),
            10000, // Max 10,000 particles
        ) catch |err| blk: {
            log(.WARN, "scene", "Failed to create ParticlePass: {}. Particle rendering disabled.", .{err});
            break :blk null;
        };

        if (particle_pass) |pass| {
            try self.render_graph.?.addPass(&pass.base);
            // Link render pass to compute pass if both exist
            if (particle_compute_pass) |compute_pass| {
                pass.setComputePass(compute_pass);
            }
        }

        // Final tonemap pass to convert HDR backbuffer to LDR swapchain image
        const tonemap_pass = TonemapPass.create(
            self.allocator,
            graphics_context,
            pipeline_system,
            swapchain.getHdrTextures(),
            swapchain.surface_format.format,
        ) catch |err| blk: {
            log(.WARN, "scene", "Failed to create TonemapPass: {}. Final tonemapping disabled.", .{err});
            break :blk null;
        };

        if (tonemap_pass) |pass| {
            try self.render_graph.?.addPass(&pass.base);
        }

        // Compile the graph (setup passes, validate dependencies)
        try self.render_graph.?.compile();

        // Initialize pass states: start with raster mode (path tracing disabled)
        try self.setPathTracingEnabled(false);

        log(.INFO, "scene", "RenderGraph initialized for scene: {s}", .{self.name});
    }

    /// Render the scene using the RenderGraph
    pub fn render(self: *Scene, frame_info: FrameInfo) !void {
        // Try to acquire shared lock - if exclusive lock is held (scene loading), skip this frame
        if (!self.state_lock.tryLockShared()) {
            return;
        }
        defer self.state_lock.unlockShared();

        if (self.render_graph) |graph| {
            // Execute all passes (compute and graphics)
            // Performance monitoring is handled by the RenderGraph
            try graph.execute(frame_info);
        } else {
            log(.WARN, "scene", "Attempted to render scene without initialized RenderGraph: {s}", .{self.name});
        }
    }

    /// Phase 2.1: Main thread preparation (game logic, ECS queries)
    /// Call this on the MAIN THREAD before capturing snapshot
    pub fn prepareFrame(self: *Scene, global_ubo: *GlobalUbo) !void {
        // Try to acquire shared lock - if exclusive lock is held (scene loading), skip this frame
        if (!self.state_lock.tryLockShared()) {
            // Scene is being loaded/modified, skip preparation this frame
            return;
        }
        defer self.state_lock.unlockShared();

        // Apply any pending path tracing toggles FIRST (CPU-side state change)
        // This prepares the render graph state for frame N+1 while render thread renders frame N

        // Cache view-projection matrix for particle world-to-screen projection
        self.cached_view_proj = global_ubo.projection.mul(global_ubo.view);

        if (self.render_graph) |graph| {
            // Create minimal frame_info for prepareExecute (no Vulkan resources needed yet)
            const prep_frame_info = FrameInfo{
                .command_buffer = vk.CommandBuffer.null_handle,
                .current_frame = 0,
                .extent = undefined,
                .color_image = undefined,
                .color_image_view = undefined,
                .depth_image_view = undefined,
                .performance_monitor = null,
            };
            try graph.prepareExecute(&prep_frame_info);
        }
    }

    /// Update scene state (Vulkan descriptor updates)
    /// Call this once per frame on RENDER THREAD before rendering
    pub fn update(self: *Scene, frame_info: FrameInfo, global_ubo: *GlobalUbo) !void {
        // Try to acquire shared lock - if exclusive lock is held (scene loading), skip this frame
        if (!self.state_lock.tryLockShared()) {
            return;
        }
        defer self.state_lock.unlockShared();

        _ = global_ubo;

        // Update all render passes through the render graph (descriptor sets)
        if (self.render_graph) |graph| {
            try graph.update(&frame_info);
        }
    }

    /// Clear the scene (destroy all entities and reset state)
    pub fn clear(self: *Scene) void {
        self.state_lock.lock();
        defer self.state_lock.unlock();
        self.clearInternal();
    }

    fn clearInternal(self: *Scene) void {
        log(.INFO, "scene", "Clearing scene...", .{});

        // Release all Lua states before destroying entities
        for (self.entities.items) |entity| {
            if (self.ecs_world.get(ecs.ScriptComponent, entity)) |sc| {
                self.scripting_system.releaseScriptState(sc);
            }
        }

        // Destroy all entities in the ECS world
        for (self.entities.items) |entity| {
            self.ecs_world.destroyEntity(entity);
        }
        self.entities.clearRetainingCapacity();
        self.game_objects.clearRetainingCapacity();
        self.emitter_to_gpu_id.clearRetainingCapacity();

        if (self.material_system) |ms| {
            ms.reset();
        }

        if (self.particle_system) |ps| {
            ps.reset();
        }

        if (self.physics_system) |ps| {
            ps.reset();
        }

        if (self.render_graph) |graph| {
            graph.reset();
        }

        // Remove render_system from ECS user data
        _ = self.ecs_world.removeUserData("render_system");
    }

    /// Get camera matrices from the primary ECS camera (for play mode rendering)
    /// Returns null if no primary camera exists in the scene
    pub const PlayCameraData = struct {
        view_matrix: Math.Mat4x4,
        projection_matrix: Math.Mat4x4,
        inverse_view_matrix: Math.Mat4x4,
        position: Vec3,
    };

    pub fn getPlayModeCamera(self: *Scene) ?PlayCameraData {
        // Find the primary camera in the ECS world
        var camera_view = self.ecs_world.view(Camera) catch return null;
        var iter = camera_view.iterator();

        while (iter.next()) |entry| {
            const camera = entry.component;
            if (camera.is_primary) {
                // Get the transform for this camera entity
                const transform = self.ecs_world.get(Transform, entry.entity) orelse continue;

                // Build view matrix from quaternion rotation and position
                // View matrix = inverse of model matrix
                // For an orthogonal rotation matrix, inverse = transpose
                // We need to build the rotation matrix, transpose it, then apply -position

                const q = transform.rotation;
                const pos = transform.position;

                // Convert quaternion to rotation matrix (for the camera's forward/right/up)
                const rot_mat = q.toMat4();

                // Extract basis vectors from rotation matrix
                const right = Vec3.init(rot_mat.data[0], rot_mat.data[1], rot_mat.data[2]);
                const up = Vec3.init(rot_mat.data[4], rot_mat.data[5], rot_mat.data[6]);
                const forward = Vec3.init(rot_mat.data[8], rot_mat.data[9], rot_mat.data[10]);

                // Build view matrix: rotation transposed + translation
                var view_matrix = Math.Mat4x4.identity();
                // Transpose the rotation part
                view_matrix.data[0] = right.x;
                view_matrix.data[1] = up.x;
                view_matrix.data[2] = forward.x;
                view_matrix.data[4] = right.y;
                view_matrix.data[5] = up.y;
                view_matrix.data[6] = forward.y;
                view_matrix.data[8] = right.z;
                view_matrix.data[9] = up.z;
                view_matrix.data[10] = forward.z;
                // Translation: -dot(axis, position) for each axis
                view_matrix.data[12] = -Vec3.dot(right, pos);
                view_matrix.data[13] = -Vec3.dot(up, pos);
                view_matrix.data[14] = -Vec3.dot(forward, pos);

                // Build inverse view matrix (the world matrix)
                var inverse_view = Math.Mat4x4.identity();
                inverse_view.data[0] = right.x;
                inverse_view.data[1] = right.y;
                inverse_view.data[2] = right.z;
                inverse_view.data[4] = up.x;
                inverse_view.data[5] = up.y;
                inverse_view.data[6] = up.z;
                inverse_view.data[8] = forward.x;
                inverse_view.data[9] = forward.y;
                inverse_view.data[10] = forward.z;
                inverse_view.data[12] = pos.x;
                inverse_view.data[13] = pos.y;
                inverse_view.data[14] = pos.z;

                // Ensure projection matrix is up to date
                var cam_mut = self.ecs_world.getMut(Camera, entry.entity) orelse continue;
                cam_mut.updateProjectionMatrix();

                return PlayCameraData{
                    .view_matrix = view_matrix,
                    .projection_matrix = cam_mut.projection_matrix,
                    .inverse_view_matrix = inverse_view,
                    .position = pos,
                };
            }
        }

        return null;
    }

    // =========================================================================
    // Input State Management (for scripts)
    // Updated by SceneLayer from events, read by lua_bindings
    // =========================================================================

    /// Handle an input event and update key/mouse state
    pub fn handleInputEvent(self: *Scene, event: *const @import("../core/event.zig").Event) void {
        switch (event.event_type) {
            .KeyPressed => {
                const key = event.data.KeyPressed.key;
                if (key >= 0 and key < 512) {
                    self.key_states[@intCast(key)] = true;
                }
            },
            .KeyReleased => {
                const key = event.data.KeyReleased.key;
                if (key >= 0 and key < 512) {
                    self.key_states[@intCast(key)] = false;
                }
            },
            .MouseButtonPressed => {
                const button = event.data.MouseButtonPressed.button;
                if (button >= 0 and button < 8) {
                    self.mouse_button_states[@intCast(button)] = true;
                }
            },
            .MouseButtonReleased => {
                const button = event.data.MouseButtonReleased.button;
                if (button >= 0 and button < 8) {
                    self.mouse_button_states[@intCast(button)] = false;
                }
            },
            .MouseMoved => {
                self.mouse_x = event.data.MouseMoved.x;
                self.mouse_y = event.data.MouseMoved.y;
            },
            else => {},
        }
    }

    /// Check if a key is currently pressed
    pub fn isKeyDown(self: *const Scene, key: i32) bool {
        if (key >= 0 and key < 512) {
            return self.key_states[@intCast(key)];
        }
        return false;
    }

    /// Check if a mouse button is currently pressed
    pub fn isMouseButtonDown(self: *const Scene, button: i32) bool {
        if (button >= 0 and button < 8) {
            return self.mouse_button_states[@intCast(button)];
        }
        return false;
    }

    /// Get current mouse position
    pub fn getMousePosition(self: *const Scene) struct { x: f64, y: f64 } {
        return .{ .x = self.mouse_x, .y = self.mouse_y };
    }
};

pub const SceneState = enum {
    Edit,
    Play,
    Pause,
};

// ==================== Tests ====================

const testing = std.testing;

test "Scene v2: init creates empty scene" {
    var world = World.init(testing.allocator, null);
    defer world.deinit();

    try world.registerComponent(Transform);
    try world.registerComponent(MeshRenderer);

    var mock_asset_manager: AssetManager = undefined;
    // Create a small ThreadPool for the test (required by Scene.init)
    var tp_ptr = try testing.allocator.create(ThreadPool);
    tp_ptr.* = try ThreadPool.init(testing.allocator, 1);
    defer {
        tp_ptr.deinit();
        testing.allocator.destroy(tp_ptr);
    }

    var mock_buffer_manager: BufferManager = undefined;
    var scene = Scene.init(testing.allocator, &world, &mock_asset_manager, tp_ptr, &mock_buffer_manager, "test_scene");
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
    var tp_ptr = try testing.allocator.create(ThreadPool);
    tp_ptr.* = try ThreadPool.init(testing.allocator, 1);
    defer {
        tp_ptr.deinit();
        testing.allocator.destroy(tp_ptr);
    }

    var mock_buffer_manager: BufferManager = undefined;
    var scene = Scene.init(testing.allocator, &world, &mock_asset_manager, tp_ptr, &mock_buffer_manager, "test_scene");
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
    var scene = Scene.init(testing.allocator, &world, &mock_asset_manager, null, "test_scene");
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
