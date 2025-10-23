const std = @import("std");
const vk = @import("vulkan");
const log = @import("../utils/log.zig").log;
const Math = @import("../utils/math.zig");
const Vec3 = Math.Vec3;
const Mat4x4 = Math.Mat4x4;

const AssetManager = @import("../assets/asset_manager.zig").AssetManager;
const AssetId = @import("../assets/asset_types.zig").AssetId;
const GraphicsContext = @import("../core/graphics_context.zig").GraphicsContext;
const UnifiedPipelineSystem = @import("../rendering/unified_pipeline_system.zig").UnifiedPipelineSystem;
const RenderGraph = @import("../rendering/render_graph.zig").RenderGraph;
const FrameInfo = @import("../rendering/frameinfo.zig").FrameInfo;
const GlobalUbo = @import("../rendering/frameinfo.zig").GlobalUbo;
const PerformanceMonitor = @import("../rendering/performance_monitor.zig").PerformanceMonitor;

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

    // Rendering pipeline for this scene
    render_graph: ?RenderGraph = null,
    particle_compute_pass: ?*@import("../rendering/passes/particle_compute_pass.zig").ParticleComputePass = null,
    geometry_pass: ?*@import("../rendering/passes/geometry_pass.zig").GeometryPass = null,
    path_tracing_pass: ?*@import("../rendering/passes/path_tracing_pass.zig").PathTracingPass = null,

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
    render_system: ecs.RenderSystem,

    // Performance monitoring
    performance_monitor: ?*PerformanceMonitor = null,

    /// Initialize a new scene
    pub fn init(
        allocator: std.mem.Allocator,
        ecs_world: *World,
        asset_manager: *AssetManager,
        name: []const u8,
    ) Scene {
        log(.INFO, "scene_v2", "Creating scene: {s}", .{name});

        // Initialize random number generator with current time as seed
        const seed = @as(u64, @intCast(std.time.timestamp()));
        const prng = std.Random.DefaultPrng.init(seed);

        return Scene{
            .ecs_world = ecs_world,
            .asset_manager = asset_manager,
            .allocator = allocator,
            .name = name,
            .entities = std.ArrayList(EntityId){},
            .game_objects = std.ArrayList(GameObject){},
            .emitter_to_gpu_id = std.AutoHashMap(EntityId, u32).init(allocator),
            .random = prng,
            .light_system = ecs.LightSystem.init(allocator),
            .render_system = ecs.RenderSystem.init(allocator),
        };
    }

    /// Set the performance monitor for profiling
    pub fn setPerformanceMonitor(self: *Scene, monitor: ?*PerformanceMonitor) void {
        self.performance_monitor = monitor;
    }

    /// Spawn a static prop with mesh and texture
    pub fn spawnProp(
        self: *Scene,
        model_path: []const u8,
        texture_path: []const u8,
    ) !*GameObject {

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
        _: f32, // intensity - reserved for future Light component
    ) !*GameObject {
        log(.INFO, "scene_v2", "Spawning light (Light component not yet implemented)", .{});

        // For now, just create an empty object with Transform
        // TODO: Add Light component when implemented
        const light_obj = try self.spawnEmpty("light");
        return light_obj;
    }

    /// Add a particle emitter to an existing entity
    pub fn addParticleEmitter(
        self: *Scene,
        entity: EntityId,
        emission_rate: f32,
        particle_lifetime: f32,
    ) !void {
        log(.INFO, "scene_v2", "Adding particle emitter to entity {} (rate={d:.2}, lifetime={d:.2})", .{ @intFromEnum(entity), emission_rate, particle_lifetime });

        // Get entity transform for emitter position
        const transform = self.ecs_world.get(Transform, entity) orelse return error.EntityHasNoTransform;

        // Create ECS emitter component
        var emitter = ecs.ParticleEmitter.initWithRate(emission_rate);
        emitter.particle_lifetime = particle_lifetime;
        emitter.active = true;
        emitter.velocity_min = .{ .x = -1.5, .y = 5.0, .z = -1.5 };
        emitter.velocity_max = .{ .x = 1.5, .y = 8.0, .z = 1.5 };
        emitter.color = .{ .x = 1.0, .y = 0.8, .z = 0.3 }; // Golden color

        try self.ecs_world.emplace(ecs.ParticleEmitter, entity, emitter);

        // Register emitter with GPU if particle compute pass is initialized
        if (self.particle_compute_pass) |compute_pass| {
            const vertex_formats = @import("../rendering/vertex_formats.zig");

            // Create GPU emitter struct
            const gpu_emitter = vertex_formats.GPUEmitter{
                .position = .{ transform.position.x, transform.position.y, transform.position.z },
                .is_active = 1,
                .velocity_min = .{ emitter.velocity_min.x, -emitter.velocity_min.y, emitter.velocity_min.z },
                .velocity_max = .{ emitter.velocity_max.x, -emitter.velocity_max.y, emitter.velocity_max.z },
                .color_start = .{ emitter.color.x, emitter.color.y, emitter.color.z, 1.0 },
                .color_end = .{ emitter.color.x * 0.5, emitter.color.y * 0.5, emitter.color.z * 0.5, 0.0 }, // Fade to darker
                .lifetime_min = particle_lifetime * 0.8,
                .lifetime_max = particle_lifetime * 1.2,
                .spawn_rate = emission_rate,
                .accumulated_spawn_time = 0.0,
                .particles_per_spawn = 1,
            };

            // Spawn some initial particles (more for better visual effect)
            const initial_particle_count = 200;
            const initial_particles = try self.allocator.alloc(vertex_formats.Particle, initial_particle_count);
            defer self.allocator.free(initial_particles);

            // Generate random initial particles (dead, to be spawned by compute shader)
            for (initial_particles) |*particle| {
                const rand_x = gpu_emitter.velocity_min[0] + (gpu_emitter.velocity_max[0] - gpu_emitter.velocity_min[0]) * self.random.random().float(f32);
                const rand_y = gpu_emitter.velocity_min[1] + (gpu_emitter.velocity_max[1] - gpu_emitter.velocity_min[1]) * self.random.random().float(f32);
                const rand_z = gpu_emitter.velocity_min[2] + (gpu_emitter.velocity_max[2] - gpu_emitter.velocity_min[2]) * self.random.random().float(f32);
                const lifetime = gpu_emitter.lifetime_min + (gpu_emitter.lifetime_max - gpu_emitter.lifetime_min) * self.random.random().float(f32);

                particle.* = vertex_formats.Particle{
                    .position = gpu_emitter.position,
                    .velocity = .{ rand_x, rand_y, rand_z },
                    .color = gpu_emitter.color_start,
                    .lifetime = 0.0, // Dead particles - will be assigned emitter_id by spawnParticlesForEmitter
                    .max_lifetime = lifetime,
                    .emitter_id = 0, // Will be set by spawnParticlesForEmitter

                };
            }

            // Add emitter to GPU and track the GPU ID
            const gpu_emitter_id = try compute_pass.addEmitter(gpu_emitter, initial_particles);
            try self.emitter_to_gpu_id.put(entity, gpu_emitter_id);

            log(.INFO, "scene_v2", "Added particle emitter {} (gpu_id={})", .{ @intFromEnum(entity), gpu_emitter_id });
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
        if (self.render_graph) |*graph| {
            graph.deinit();
        }
        self.entities.deinit(self.allocator);
        self.game_objects.deinit(self.allocator);
        self.emitter_to_gpu_id.deinit();
        self.light_system.deinit();
        self.render_system.deinit();
        log(.INFO, "scene_v2", "Scene destroyed: {s}", .{self.name});
    }

    /// Toggle path tracing on/off (switches between path tracing and raster)
    pub fn setPathTracingEnabled(self: *Scene, enabled: bool) void {
        if (self.path_tracing_pass) |pass| {
            pass.enable_path_tracing = enabled;

            if (enabled) {
                log(.INFO, "scene_v2", "Path tracing ENABLED for scene: {s} (raster will be disabled on next frame)", .{self.name});
            } else {
                log(.INFO, "scene_v2", "Path tracing DISABLED for scene: {s} (raster will be enabled on next frame)", .{self.name});
            }
        } else {
            log(.WARN, "scene_v2", "Cannot toggle path tracing - pass not initialized", .{});
        }
    }

    /// Initialize rendering pipeline for this scene
    /// Must be called after scene creation to enable rendering
    pub fn initRenderGraph(
        self: *Scene,
        graphics_context: *GraphicsContext,
        pipeline_system: *UnifiedPipelineSystem,
        swapchain_format: vk.Format,
        swapchain_depth_format: vk.Format,
        thread_pool: *@import("../threading/thread_pool.zig").ThreadPool,
        global_ubo_set: *@import("../rendering/ubo_set.zig").GlobalUboSet,
        width: u32,
        height: u32,
    ) !void {
        const GeometryPass = @import("../rendering/passes/geometry_pass.zig").GeometryPass;
        const LightVolumePass = @import("../rendering/passes/light_volume_pass.zig").LightVolumePass;
        const ParticleComputePass = @import("../rendering/passes/particle_compute_pass.zig").ParticleComputePass;
        const ParticlePass = @import("../rendering/passes/particle_pass.zig").ParticlePass;
        const PathTracingPass = @import("../rendering/passes/path_tracing_pass.zig").PathTracingPass;

        // Create render graph
        self.render_graph = RenderGraph.init(self.allocator, graphics_context);

        // Create and add ParticleComputePass FIRST (runs on compute queue)
        const max_emitters = 16;
        const particles_per_emitter = 200;
        const particle_compute_pass = try ParticleComputePass.create(
            self.allocator,
            graphics_context,
            pipeline_system,
            self.ecs_world,
            particles_per_emitter * max_emitters, // 200 particles per emitter * 16 emitters = 3200 total
            max_emitters,
        );

        // Save reference for emitter management
        self.particle_compute_pass = particle_compute_pass;

        try self.render_graph.?.addPass(&particle_compute_pass.base);

        // Create and add GeometryPass
        const geometry_pass = try GeometryPass.create(
            self.allocator,
            graphics_context,
            pipeline_system,
            self.asset_manager,
            self.ecs_world,
            global_ubo_set,
            swapchain_format,
            swapchain_depth_format,
            &self.render_system,
        );

        try self.render_graph.?.addPass(&geometry_pass.base);

        // Save reference for toggling between raster and path tracing
        self.geometry_pass = geometry_pass;

        // Create PathTracingPass (alternative to raster rendering)
        const path_tracing_pass = try PathTracingPass.create(
            self.allocator,
            graphics_context,
            pipeline_system,
            thread_pool,
            global_ubo_set,
            self.ecs_world,
            self.asset_manager,
            &self.render_system,
            swapchain_format,
            width,
            height,
        );

        // Save reference for toggling path tracing
        self.path_tracing_pass = path_tracing_pass;

        // NOTE: Path tracing pass starts disabled (enable via setEnabled())
        // For now, we add it to the graph but it won't execute unless enabled
        try self.render_graph.?.addPass(&path_tracing_pass.base);

        // Create and add LightVolumePass (renders after geometry)
        const light_volume_pass = try LightVolumePass.create(
            self.allocator,
            graphics_context,
            pipeline_system,
            self.ecs_world,
            global_ubo_set,
            swapchain_format,
            swapchain_depth_format,
        );

        try self.render_graph.?.addPass(&light_volume_pass.base);

        // Create and add ParticlePass (renders particles with alpha blending)
        const particle_pass = try ParticlePass.create(
            self.allocator,
            graphics_context,
            pipeline_system,
            global_ubo_set,
            swapchain_format,
            swapchain_depth_format,
            10000, // Max 10,000 particles
        );

        // Link render pass to compute pass
        particle_pass.setComputePass(particle_compute_pass);

        try self.render_graph.?.addPass(&particle_pass.base);

        // Compile the graph (setup passes, validate dependencies)
        try self.render_graph.?.compile();

        log(.INFO, "scene_v2", "RenderGraph initialized for scene: {s}", .{self.name});
    }

    /// Render the scene using the RenderGraph
    pub fn render(self: *Scene, frame_info: FrameInfo) !void {
        if (self.render_graph) |*graph| {
            // Toggle geometry pass based on path tracing state
            if (self.path_tracing_pass) |pt_pass| {
                // Search for geometry pass in render graph
                for (graph.passes.items) |pass| {
                    if (std.mem.eql(u8, pass.name, "geometry_pass")) {
                        pass.enabled = !pt_pass.enable_path_tracing;
                    } else if (std.mem.eql(u8, pass.name, "particle_pass")) {
                        pass.enabled = !pt_pass.enable_path_tracing;
                    } else if (std.mem.eql(u8, pass.name, "light_volume_pass")) {
                        pass.enabled = !pt_pass.enable_path_tracing;
                    } else if (std.mem.eql(u8, pass.name, "path_tracing_pass")) {
                        pass.enabled = pt_pass.enable_path_tracing;
                    }
                }
            }
            // Execute only graphics passes (compute passes already executed in update())
            for (graph.passes.items) |pass| {
                if (!pass.enabled) continue;
                if (pass.isComputePass()) continue; // Skip compute passes

                // Begin pass timing
                if (self.performance_monitor) |pm| {
                    try pm.beginPass(pass.name, frame_info.current_frame, frame_info.command_buffer);
                }

                try pass.execute(frame_info);

                // End pass timing
                if (self.performance_monitor) |pm| {
                    try pm.endPass(pass.name, frame_info.current_frame, frame_info.command_buffer);
                }
            }
        } else {
            log(.WARN, "scene_v2", "Attempted to render scene without initialized RenderGraph: {s}", .{self.name});
        }
    }

    /// Update scene state (animations, physics, etc.)
    /// Call this once per frame before rendering
    pub fn update(self: *Scene, frame_info: FrameInfo, global_ubo: *GlobalUbo) !void {
        // Cache view-projection matrix for particle world-to-screen projection
        self.cached_view_proj = global_ubo.projection.mul(global_ubo.view);

        // Update animated lights and extract to GlobalUbo
        try self.updateLights(global_ubo, frame_info.dt);

        // Update particles (CPU-side spawning)
        try self.updateParticles(frame_info.dt);

        // Check for geometry/asset changes every frame (lightweight, sets dirty flags)
        try self.render_system.checkForChanges(self.ecs_world, self.asset_manager);
        if (self.geometry_pass) |geom_pass| {
            // Update path tracing state (BVH and descriptors) if enabled
            if (self.path_tracing_pass) |pt_pass| {
                if (!pt_pass.enable_path_tracing) {
                    try geom_pass.checkAssetUpdates(frame_info.current_frame);
                }
            } else {
                try geom_pass.checkAssetUpdates(frame_info.current_frame);
            }
        }

        // Update path tracing state (BVH and descriptors) if enabled
        if (self.path_tracing_pass) |pt_pass| {
            if (pt_pass.enable_path_tracing) {
                try pt_pass.updateState(&frame_info);
            }
        }

        // Execute compute passes (GPU particle simulation)
        // This must happen between beginCompute/endCompute in app.zig
        if (self.render_graph) |*graph| {
            for (graph.passes.items) |pass| {
                if (pass.enabled and pass.isComputePass()) {
                    // Begin pass timing (with compute buffer for GPU timing)
                    if (self.performance_monitor) |pm| {
                        try pm.beginPass(pass.name, frame_info.current_frame, frame_info.compute_buffer);
                    }

                    try pass.execute(frame_info);

                    // End pass timing
                    if (self.performance_monitor) |pm| {
                        try pm.endPass(pass.name, frame_info.current_frame, frame_info.compute_buffer);
                    }
                }
            }
        }

        // Run ECS systems (transforms, physics, etc.)
        // try self.ecs_world.update(frame_info.dt);
    }

    /// Extract lights from ECS and populate the GlobalUbo
    /// Also animates light positions in a circle
    fn updateLights(self: *Scene, global_ubo: *GlobalUbo, dt: f32) !void {
        self.time_elapsed += dt;

        const PointLight = @import("../ecs.zig").PointLight;

        // Use cached light_system instead of creating a new one each frame
        // (No longer need: var light_system = LightSystem.init(self.allocator); defer light_system.deinit();)

        // Get view of all light entities
        var view = try self.ecs_world.view(PointLight);
        var iter = view.iterator();
        var light_index: usize = 0;

        // Animate and extract lights
        while (iter.next()) |entry| : (light_index += 1) {
            const point_light = entry.component;
            const transform_ptr = self.ecs_world.get(Transform, entry.entity) orelse continue;

            // Animate position in a circle
            const radius: f32 = 1.5;
            const height: f32 = 0.5;
            const speed: f32 = 1.0;
            const angle_offset: f32 = @as(f32, @floatFromInt(light_index)) * (2.0 * std.math.pi / 3.0);

            const angle = self.time_elapsed * speed + angle_offset;
            const x = @cos(angle) * radius;
            const z = @sin(angle) * radius;

            // Update transform position using setter to mark dirty flag
            transform_ptr.setPosition(Math.Vec3.init(x, height, z));

            // Extract to GlobalUbo
            if (light_index < 16) {
                global_ubo.point_lights[light_index] = .{
                    .position = Math.Vec4.init(x, height, z, 1.0),
                    .color = Math.Vec4.init(
                        point_light.color.x * point_light.intensity,
                        point_light.color.y * point_light.intensity,
                        point_light.color.z * point_light.intensity,
                        point_light.intensity,
                    ),
                };
            }
        }

        global_ubo.num_point_lights = @intCast(@min(light_index, 16));

        // Clear remaining light slots
        for (light_index..16) |i| {
            global_ubo.point_lights[i] = .{};
        }
    }

    /// Update particle emitters - spawn particles based on emission rate
    fn updateParticles(self: *Scene, dt: f32) !void {
        _ = dt; // GPU handles all particle updates now

        const ParticleEmitter = @import("../ecs.zig").ParticleEmitter;

        // Update GPU emitter positions when transforms change
        var view = try self.ecs_world.view(ParticleEmitter);
        var iter = view.iterator();

        while (iter.next()) |item| {
            const entity = item.entity;
            const emitter = item.component;

            if (!emitter.active) continue;

            // Get GPU emitter ID
            const gpu_id = self.emitter_to_gpu_id.get(entity) orelse continue;

            // Get current transform
            const transform = self.ecs_world.get(Transform, entity) orelse continue;

            // Check if position has changed (simple comparison)
            // In a real system you might track dirty flags
            if (self.particle_compute_pass) |compute_pass| {
                const vertex_formats = @import("../rendering/vertex_formats.zig");

                // Update GPU emitter with new position
                const gpu_emitter = vertex_formats.GPUEmitter{
                    .position = .{ transform.position.x, transform.position.y, transform.position.z },
                    .is_active = if (emitter.active) 1 else 0,
                    .velocity_min = .{ emitter.velocity_min.x, emitter.velocity_min.y, emitter.velocity_min.z },
                    .velocity_max = .{ emitter.velocity_max.x, emitter.velocity_max.y, emitter.velocity_max.z },
                    .color_start = .{ emitter.color.x, emitter.color.y, emitter.color.z, 1.0 },
                    .color_end = .{ emitter.color.x * 0.5, emitter.color.y * 0.5, emitter.color.z * 0.5, 0.0 },
                    .lifetime_min = emitter.particle_lifetime * 0.8,
                    .lifetime_max = emitter.particle_lifetime * 1.2,
                    .spawn_rate = emitter.emission_rate,
                    .accumulated_spawn_time = 0.0,
                    .particles_per_spawn = 1,
                };

                try compute_pass.updateEmitter(gpu_id, gpu_emitter);
            }
        }

        // No more CPU-side particle spawning or removal!
        // The GPU compute shader handles all particle lifecycle now.
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
