const std = @import("std");

// Core graphics imports
const Window = @import("window.zig").Window;
const graphics_context = @import("core/graphics_context.zig");
const GraphicsContext = graphics_context.GraphicsContext;
const Swapchain = @import("core/swapchain.zig").Swapchain;
const MAX_FRAMES_IN_FLIGHT = @import("core/swapchain.zig").MAX_FRAMES_IN_FLIGHT;
const core_texture = @import("core/texture.zig");

const Buffer = @import("core/buffer.zig").Buffer;

// Rendering imports
const Vertex = @import("rendering/mesh.zig").Vertex;
const Mesh = @import("rendering/mesh.zig").Mesh;
const Model = @import("rendering/mesh.zig").Model;
const Camera = @import("rendering/camera.zig").Camera;
const FrameInfo = @import("rendering/frameinfo.zig").FrameInfo;
const GlobalUbo = @import("rendering/frameinfo.zig").GlobalUbo;
const GlobalUboSet = @import("rendering/ubo_set.zig").GlobalUboSet;

// Scene imports
const Scene = @import("scene/scene.zig").Scene;
const GameObject = @import("scene/game_object.zig").GameObject;
const Material = @import("assets/asset_manager.zig").Material;

// Scene v2 imports (new ECS-based scene system)
const SceneV2 = @import("scene/scene_v2.zig").Scene;
const GameObjectV2 = @import("scene/game_object_v2.zig").GameObject;

// Asset system imports
const AssetManager = @import("assets/asset_manager.zig").AssetManager;
const ThreadPool = @import("threading/thread_pool.zig").ThreadPool;
const ShaderManager = @import("assets/shader_manager.zig").ShaderManager;
const FileWatcher = @import("utils/file_watcher.zig").FileWatcher;

// Shader-pipeline integration removed in favor of the unified pipeline system

// Unified pipeline system imports
const UnifiedPipelineSystem = @import("rendering/unified_pipeline_system.zig").UnifiedPipelineSystem;
const ResourceBinder = @import("rendering/resource_binder.zig").ResourceBinder;

// Renderer imports
const TexturedRenderer = @import("renderers/textured_renderer.zig").TexturedRenderer;
const EcsRenderer = @import("renderers/ecs_renderer.zig").EcsRenderer;
const PointLightRenderer = @import("renderers/point_light_renderer.zig").PointLightRenderer;
const ParticleRenderer = @import("renderers/particle_renderer.zig").ParticleRenderer;
const RaytracingRenderer = @import("renderers/raytracing_renderer.zig").RaytracingRenderer;

// System imports
// RaytracingSystem is now integrated into RaytracingRenderer
const ComputeShaderSystem = @import("systems/compute_shader_system.zig").ComputeShaderSystem;

const PARTICLE_MAX: u32 = 1024;

// Render Pass System imports
const GenericRenderer = @import("rendering/generic_renderer.zig").GenericRenderer;
const RendererType = @import("rendering/generic_renderer.zig").RendererType;
const RendererEntry = @import("rendering/generic_renderer.zig").RendererEntry;
const SceneBridge = @import("rendering/scene_bridge.zig").SceneBridge;

// Utility imports
const Math = @import("utils/math.zig");
const log = @import("utils/log.zig").log;

const new_ecs = @import("ecs.zig"); // New coherent ECS system

// Input controller
const KeyboardMovementController = @import("keyboard_movement_controller.zig").KeyboardMovementController;

// Vulkan bindings and external C libraries
const vk = @import("vulkan");
const c = @cImport({
    @cInclude("GLFW/glfw3.h");
});

pub const App = struct {
    window: Window = undefined,

    gc: GraphicsContext = undefined,
    allocator: std.mem.Allocator = undefined,

    // Initialize to true so descriptors are updated on first frames
    descriptor_dirty_flags: [MAX_FRAMES_IN_FLIGHT]bool = [_]bool{true} ** MAX_FRAMES_IN_FLIGHT,
    as_dirty_flags: [MAX_FRAMES_IN_FLIGHT]bool = [_]bool{false} ** MAX_FRAMES_IN_FLIGHT,

    // FPS tracking variables (instance variables)
    fps_frame_count: u32 = 0,
    fps_last_time: f64 = 0.0,
    current_fps: f32 = 0.0,

    var current_frame: u32 = 0;
    var swapchain: Swapchain = undefined;
    var cmdbufs: []vk.CommandBuffer = undefined;

    // Individual renderers (still needed for initialization)
    var textured_renderer: TexturedRenderer = undefined;
    var ecs_renderer: EcsRenderer = undefined;
    var point_light_renderer: PointLightRenderer = undefined;
    var raytracing_renderer: RaytracingRenderer = undefined;
    //var particle_renderer: ParticleRenderer = undefined;
    var particle_renderer: ParticleRenderer = undefined;

    // OLD: Generic forward renderer (DISABLED FOR RENDER GRAPH)
    // var forward_renderer: GenericRenderer = undefined;

    // OLD: Raytracing render pass (DISABLED FOR RENDER GRAPH)
    // var rt_render_pass: GenericRenderer = undefined;

    var compute_shader_system: ComputeShaderSystem = undefined;
    var shader_manager: ShaderManager = undefined;
    // NOTE: Shader-pipeline integration removed - unified pipeline system handles hot reload now

    // Unified pipeline system
    var unified_pipeline_system: UnifiedPipelineSystem = undefined;
    var resource_binder: ResourceBinder = undefined;

    var last_frame_time: f64 = undefined;
    var camera: Camera = undefined;
    var viewer_object: *GameObject = undefined;
    var camera_controller: KeyboardMovementController = undefined;
    var global_UBO_buffers: ?[]Buffer = undefined;
    var frame_info: FrameInfo = FrameInfo{};

    var frame_index: u32 = 0;
    var frame_counter: u64 = 0; // Global frame counter for scheduling
    var scene: Scene = undefined;
    var thread_pool: *ThreadPool = undefined;
    var asset_manager: *AssetManager = undefined;
    var file_watcher: *FileWatcher = undefined;
    // Application-owned FileWatcher for hot-reload; created early so it can be
    // deinitialized after other systems that depend on it have been deinitialized.

    var last_performance_report: f64 = 0.0; // Track when we last printed performance stats

    // Scheduled asset loading system
    const ScheduledAsset = struct {
        frame: u64,
        model_path: []const u8,
        texture_path: []const u8,
        position: Math.Vec3,
        rotation: Math.Vec3,
        scale: Math.Vec3,
        loaded: bool = false,
    };
    var scheduled_assets: std.ArrayList(ScheduledAsset) = undefined;

    // Raytracing system field
    var global_ubo_set: *GlobalUboSet = undefined;

    // Scene bridge and view for rendering
    var scene_bridge: SceneBridge = undefined;
    // Generic renderer system is now the default rendering path

    // New coherent ECS system
    var new_ecs_world: new_ecs.World = undefined;
    var new_ecs_enabled: bool = false;

    // ECS systems
    var transform_system: new_ecs.TransformSystem = undefined;

    // Scene v2 (ECS-based scene)
    var scene_v2: SceneV2 = undefined;
    var scene_v2_enabled: bool = false;

    pub fn init(self: *App) !void {
        log(.INFO, "app", "Initializing ZulkanZengine...", .{});
        self.window = try Window.init(.{ .width = 1280, .height = 720 });

        self.allocator = std.heap.page_allocator;

        // Initialize scheduled assets system
        scheduled_assets = std.ArrayList(ScheduledAsset){};

        self.gc = try GraphicsContext.init(self.allocator, self.window.window_props.title, @ptrCast(self.window.window.?));
        log(.INFO, "app", "Using device: {s}", .{self.gc.deviceName()});
        swapchain = try Swapchain.init(&self.gc, self.allocator, .{ .width = self.window.window_props.width, .height = self.window.window_props.height });
        // try swapchain.createRenderPass();

        // try swapchain.createFramebuffers();
        try self.gc.createCommandPool();

        // Initialize Thread Pool with dynamic scaling
        thread_pool = try self.allocator.create(ThreadPool);
        thread_pool.* = try ThreadPool.init(self.allocator, 16); // Max 16 workers
        thread_pool.setThreadExitHook(graphics_context.workerThreadExitHook, @ptrCast(&self.gc));

        // Register subsystems with thread pool

        try thread_pool.registerSubsystem(.{
            .name = "hot_reload",
            .min_workers = 1,
            .max_workers = 2,
            .priority = .low,
            .work_item_type = .hot_reload,
        });

        try thread_pool.registerSubsystem(.{
            .name = "bvh_building",
            .min_workers = 1,
            .max_workers = 4,
            .priority = .critical,
            .work_item_type = .bvh_building,
        });

        try thread_pool.registerSubsystem(.{
            .name = "custom_work",
            .min_workers = 1,
            .max_workers = 2,
            .priority = .low,
            .work_item_type = .custom,
        });

        try thread_pool.registerSubsystem(.{
            .name = "ecs_update",
            .min_workers = 2,
            .max_workers = 8,
            .priority = .normal,
            .work_item_type = .ecs_update,
        });

        // Start the thread pool with initial workers
        try thread_pool.start(8); // Start with 4 workers

        // Initialize new coherent ECS system
        log(.INFO, "app", "Initializing new ECS system with ThreadPool support...", .{});
        new_ecs_world = new_ecs.World.init(self.allocator, thread_pool);
        errdefer new_ecs_world.deinit();

        // Register all ECS components
        try new_ecs_world.registerComponent(new_ecs.ParticleComponent);
        try new_ecs_world.registerComponent(new_ecs.ParticleEmitter);
        try new_ecs_world.registerComponent(new_ecs.Transform);
        try new_ecs_world.registerComponent(new_ecs.MeshRenderer);
        try new_ecs_world.registerComponent(new_ecs.Camera);
        log(.INFO, "app", "Registered ECS components: ParticleComponent, ParticleEmitter, Transform, MeshRenderer, Camera", .{});

        // Initialize ECS systems
        transform_system = new_ecs.TransformSystem.init(self.allocator);
        log(.INFO, "app", "Initialized ECS systems: TransformSystem", .{});

        new_ecs_enabled = true;
        log(.INFO, "app", "New ECS system initialized with {} particles", .{PARTICLE_MAX});

        // Initialize Asset Manager on heap for stable pointer address
        asset_manager = try AssetManager.init(self.allocator, &self.gc, thread_pool);

        // Create application-owned FileWatcher and hand it to hot-reload systems
        file_watcher = try self.allocator.create(FileWatcher);
        file_watcher.* = FileWatcher.init(self.allocator, thread_pool);
        try file_watcher.start();

        // Initialize Shader Manager for hot reload and compilation
        shader_manager = try ShaderManager.init(self.allocator, thread_pool, file_watcher);
        try shader_manager.addShaderDirectory("shaders");
        // Don't watch shaders/cached - we don't want to recompile cache files
        try shader_manager.start();
        log(.INFO, "app", "Shader hot reload system initialized", .{});

        // Initialize Unified Pipeline System
        unified_pipeline_system = try UnifiedPipelineSystem.init(self.allocator, &self.gc, &shader_manager);
        resource_binder = ResourceBinder.init(self.allocator, &unified_pipeline_system);

        // Connect pipeline system to shader manager for hot reload
        shader_manager.setPipelineSystem(&unified_pipeline_system);

        log(.INFO, "app", "Unified pipeline system initialized", .{});

        // Shader-pipeline integration intentionally removed. Unified pipeline system is active.

        // Initialize Scene with Asset Manager integration
        scene = Scene.init(&self.gc, self.allocator, asset_manager);

        // Enhanced Scene registers for asset completion callbacks during its init

        scene.enableHotReload(file_watcher) catch |err| {
            log(.WARN, "app", "Failed to enable hot reloading: {}", .{err});
        };

        // --- Load cube mesh using asset-based enhanced scene system ---
        const cube_object = try scene.addModelAssetAsync("models/cube.obj", "textures/missing.png", Math.Vec3.init(0, 0.5, 0.5), // position
            Math.Vec3.init(0, 0, 0), // rotation
            Math.Vec3.init(0.5, 0.5, 0.5)); // scale
        log(.INFO, "app", "Added cube object (asset-based) with asset IDs: model={}, material={}, texture={}", .{ cube_object.model_asset orelse @as(@TypeOf(cube_object.model_asset.?), @enumFromInt(0)), cube_object.material_asset orelse @as(@TypeOf(cube_object.material_asset.?), @enumFromInt(0)), cube_object.texture_asset orelse @as(@TypeOf(cube_object.texture_asset.?), @enumFromInt(0)) });

        // Create another textured cube with a different texture (asset-based)
        const cube2_object = try scene.addModelAssetAsync("models/cube.obj", "textures/default.png", Math.Vec3.init(0.7, -0.5, 0.5), // position
            Math.Vec3.init(0, 0, 0), // rotation
            Math.Vec3.init(0.5, 0.5, 0.5)); // scale
        log(.INFO, "app", "Added second cube object (asset-based) with asset IDs: model={}, material={}, texture={}", .{ cube2_object.model_asset orelse @as(@TypeOf(cube2_object.model_asset.?), @enumFromInt(0)), cube2_object.material_asset orelse @as(@TypeOf(cube2_object.material_asset.?), @enumFromInt(0)), cube2_object.texture_asset orelse @as(@TypeOf(cube2_object.texture_asset.?), @enumFromInt(0)) });

        // // Add another vase with a different texture (asset-based)
        // const vase1_object = try scene.addModelAssetAsync("models/smooth_vase.obj", "textures/error.png", Math.Vec3.init(-0.7, -0.5, 0.5), // position
        //     Math.Vec3.init(0, 0, 0), // rotation
        //     Math.Vec3.init(0.5, 0.5, 0.5)); // scale
        // log(.INFO, "app", "Added first vase object (asset-based) with asset IDs: model={}, material={}, texture={}", .{ vase1_object.model_asset orelse @as(@TypeOf(vase1_object.model_asset.?), @enumFromInt(0)), vase1_object.material_asset orelse @as(@TypeOf(vase1_object.material_asset.?), @enumFromInt(0)), vase1_object.texture_asset orelse @as(@TypeOf(vase1_object.texture_asset.?), @enumFromInt(0)) });

        // Schedule the flat vase to be loaded at frame 1000
        try scheduled_assets.append(self.allocator, ScheduledAsset{
            .frame = 50000,
            .model_path = "models/flat_vase.obj",
            .texture_path = "textures/granitesmooth1-albedo.png",
            .position = Math.Vec3.init(-1.4, -0.5, 0.5),
            .rotation = Math.Vec3.init(0, 0, 0),
            .scale = Math.Vec3.init(0.5, 0.5, 0.5),
        });
        log(.INFO, "app", "Scheduled flat vase to be loaded at frame 1000", .{});

        // Give async texture loading a moment to complete
        std.Thread.sleep(100_000_000); // 100ms

        // ==================== Scene v2: Cornell Box with Two Vases ====================
        log(.INFO, "app", "Creating Scene v2: Cornell Box with two vases...", .{});

        scene_v2 = SceneV2.init(self.allocator, &new_ecs_world, asset_manager, "cornell_box");
        scene_v2_enabled = true;

        // Cornell Box dimensions - smaller and pushed back so camera can see it
        const box_size: f32 = 2.0; // Smaller box
        const half_size = box_size / 2.0;
        const box_offset_z: f32 = 3.0; // Push box away from camera

        // Floor (white)
        const floor = try scene_v2.spawnProp("models/cube.obj", "textures/missing.png");
        try floor.setPosition(Math.Vec3.init(0, -half_size + 3, box_offset_z - 3));
        try floor.setScale(Math.Vec3.init(box_size, 0.1, box_size));
        log(.INFO, "app", "Scene v2: Added floor", .{});

        // Ceiling (white)
        const ceiling = try scene_v2.spawnProp("models/cube.obj", "textures/missing.png");
        try ceiling.setPosition(Math.Vec3.init(0, half_size - 3, 0));
        try ceiling.setScale(Math.Vec3.init(box_size, 0.1, box_size));
        log(.INFO, "app", "Scene v2: Added ceiling", .{});

        // Back wall (white)
        const back_wall = try scene_v2.spawnProp("models/cube.obj", "textures/missing.png");
        try back_wall.setPosition(Math.Vec3.init(0, 0, half_size + 1));
        try back_wall.setScale(Math.Vec3.init(box_size, box_size, 0.1));
        log(.INFO, "app", "Scene v2: Added back wall", .{});

        // Left wall (red) - using error.png for red color
        const left_wall = try scene_v2.spawnProp("models/cube.obj", "textures/error.png");
        try left_wall.setPosition(Math.Vec3.init(-half_size - 1, 0, 0));
        try left_wall.setScale(Math.Vec3.init(0.1, box_size, box_size));
        log(.INFO, "app", "Scene v2: Added left wall (red)", .{});

        // Right wall (green) - using default.png for green-ish color
        const right_wall = try scene_v2.spawnProp("models/cube.obj", "textures/default.png");
        try right_wall.setPosition(Math.Vec3.init(half_size + 1, 0, 0));
        try right_wall.setScale(Math.Vec3.init(0.1, box_size, box_size));
        log(.INFO, "app", "Scene v2: Added right wall (green)", .{});

        // // First vase (left side) - smooth vase
        // const vase1 = try scene_v2.spawnProp("models/smooth_vase.obj", "textures/granitesmooth1-albedo.png");
        // try vase1.setPosition(Math.Vec3.init(-1.2, -half_size + 0.05, 0.5));
        // try vase1.setScale(Math.Vec3.init(0.8, 0.8, 0.8));
        // log(.INFO, "app", "Scene v2: Added vase 1 (smooth)", .{});

        // Second vase (right side) - flat vase
        const vase2 = try scene_v2.spawnProp("models/flat_vase.obj", "textures/granitesmooth1-albedo.png");
        try vase2.setPosition(Math.Vec3.init(1.2, -half_size + 0.05, 0.5));
        try vase2.setScale(Math.Vec3.init(0.8, 0.8, 0.8));
        log(.INFO, "app", "Scene v2: Added vase 2 (flat)", .{});

        log(.INFO, "app", "Scene v2 Cornell Box complete with {} entities!", .{scene_v2.entities.items.len});

        // ==================== Add Lights to Scene v2 ====================
        log(.INFO, "app", "Adding lights to scene v2...", .{});

        // Register PointLight component in scene_v2's ECS world
        try scene_v2.ecs_world.registerComponent(new_ecs.PointLight);

        // Main light (white, center-top)
        const main_light = try scene_v2.ecs_world.createEntity();
        const main_light_transform = new_ecs.Transform.initWithPosition(Math.Vec3.init(0, 1.5, 1.0));
        try scene_v2.ecs_world.emplace(new_ecs.Transform, main_light, main_light_transform);
        try scene_v2.ecs_world.emplace(new_ecs.PointLight, main_light, new_ecs.PointLight.initWithRange(
            Math.Vec3.init(1.0, 1.0, 1.0), // White
            3.0, // Intensity
            10.0, // Range
        ));
        log(.INFO, "app", "Scene v2: Added main light", .{});

        // Warm accent light (left side, orange)
        const warm_light = try scene_v2.ecs_world.createEntity();
        const warm_light_transform = new_ecs.Transform.initWithPosition(Math.Vec3.init(-1.5, 0.5, 1.0));
        try scene_v2.ecs_world.emplace(new_ecs.Transform, warm_light, warm_light_transform);
        try scene_v2.ecs_world.emplace(new_ecs.PointLight, warm_light, new_ecs.PointLight.initWithRange(
            Math.Vec3.init(1.0, 0.6, 0.2), // Orange
            2.0, // Intensity
            8.0, // Range
        ));
        log(.INFO, "app", "Scene v2: Added warm accent light", .{});

        // Cool accent light (right side, blue)
        const cool_light = try scene_v2.ecs_world.createEntity();
        const cool_light_transform = new_ecs.Transform.initWithPosition(Math.Vec3.init(1.5, 0.5, 1.0));
        try scene_v2.ecs_world.emplace(new_ecs.Transform, cool_light, cool_light_transform);
        try scene_v2.ecs_world.emplace(new_ecs.PointLight, cool_light, new_ecs.PointLight.initWithRange(
            Math.Vec3.init(0.2, 0.5, 1.0), // Blue
            2.0, // Intensity
            8.0, // Range
        ));
        log(.INFO, "app", "Scene v2: Added cool accent light", .{});

        log(.INFO, "app", "Scene v2: Lights added successfully", .{});

        asset_manager.beginFrame();
        // Initialize RenderGraph for scene_v2
        try scene_v2.initRenderGraph(
            &self.gc,
            &unified_pipeline_system,
            swapchain.surface_format.format,
            try swapchain.depthFormat(),
        );
        log(.INFO, "app", "Scene v2 RenderGraph initialized", .{});

        // Add particle emitter to vase2 (AFTER render graph is initialized so particle compute pass exists)
        try scene_v2.addParticleEmitter(
            vase2.entity_id,
            50.0, // emission_rate: 20 particles per second (increased for better visibility)
            2.5, // particle_lifetime: 2.5 seconds (slightly longer)
        );
        log(.INFO, "app", "Scene v2: Added particle emitter to vase 2", .{});

        // ==================== End Scene v2 Setup ====================

        // log(.DEBUG, "scene", "Adding point light objects", .{});
        // const object3 = try scene.addObject(null, .{ .color = Math.Vec3.init(0.2, 0.5, 1.0), .intensity = 1.0 });
        // object3.transform.translate(Math.Vec3.init(0.5, 0.5, 0.5));
        // object3.transform.scale(Math.Vec3.init(0.5, 0.5, 0.5));

        // const object4 = try scene.addObject(null, .{ .color = Math.Vec3.init(0.5, 0.2, 0.2), .intensity = 1.0 });
        // object4.transform.translate(Math.Vec3.init(0, -1, 0.5));
        // object4.transform.scale(Math.Vec3.init(0.05, 0, 0));

        // const object6 = try scene.addObject(null, .{ .color = Math.Vec3.init(0.5, 0.2, 0.2), .intensity = 1.0 });
        // object6.transform.translate(Math.Vec3.init(0, -1, 0.5));
        // object6.transform.scale(Math.Vec3.init(0.05, 0, 0));

        cmdbufs = try self.gc.createCommandBuffers(
            self.allocator,
        );

        viewer_object = try scene.addEmpty();
        camera_controller = KeyboardMovementController.init();

        camera = Camera{ .fov = 75.0, .window = self.window };
        camera.updateProjectionMatrix();
        camera.setViewDirection(Math.Vec3.init(0, 0, 0), Math.Vec3.init(0, 0, 1), Math.Vec3.init(0, 1, 0));

        // --- Use new GlobalUboSet abstraction ---
        global_ubo_set = self.allocator.create(GlobalUboSet) catch unreachable;
        global_ubo_set.* = try GlobalUboSet.init(&self.gc, self.allocator);
        frame_info.global_descriptor_set = global_ubo_set.sets[0];

        // Register global descriptor sets with the pipeline system for automatic binding
        unified_pipeline_system.setGlobalDescriptorSets(global_ubo_set.sets);

        //_ = try scene.updateSyncResources(self.allocator);

        // Initialize unified textured renderer with shared pipeline system
        // textured_renderer = try TexturedRenderer.init(
        //     self.allocator,
        //     @constCast(&self.gc),
        //     &shader_manager,
        //     &unified_pipeline_system,
        //     swapchain.render_pass,
        // );

        // Initialize ECS renderer with shared pipeline system
        // ecs_renderer = try EcsRenderer.init(
        //     self.allocator,
        //     @constCast(&self.gc),
        //     &shader_manager,
        //     asset_manager, // asset_manager is already a pointer
        //     &unified_pipeline_system,
        //     swapchain.render_pass,
        //     &new_ecs_world,
        // );
        log(.INFO, "app", "ECS renderer initialized", .{});

        // Material data is now managed by the asset_manager and bound via UnifiedPipelineSystem
        // No need for separate updateMaterialData calls

        // point_light_renderer = try PointLightRenderer.init(
        //     @constCast(&self.gc),
        //     &unified_pipeline_system,
        //     swapchain.render_pass,
        //     scene.asScene(),
        //     global_ubo_set,
        // );

        // // Initialize unified raytracing renderer through the shared pipeline system
        // raytracing_renderer = try RaytracingRenderer.init(
        //     self.allocator,
        //     @constCast(&self.gc),
        //     &unified_pipeline_system,
        //     &swapchain,
        //     thread_pool,
        //     global_ubo_set,
        // );

        // --- Raytracing pipeline setup ---
        // Use the same global descriptor set and layout as the renderer

        // Create scene bridge for render pass system and raytracing
        scene_bridge = SceneBridge.init(&scene, self.allocator);

        // // Connect new ECS World to SceneBridge for particle extraction
        // if (new_ecs_enabled) {
        //     scene_bridge.setEcsWorld(&new_ecs_world);
        //     log(.INFO, "app", "Connected ECS World to SceneBridge", .{});
        // }

        // Note: TLAS creation will be handled in the update loop once BLAS is complete
        // SBT will be created by raytracing renderer when pipeline is ready

        log(.INFO, "app", "Creating unified particle renderer...", .{});
        // particle_renderer = try ParticleRenderer.init(
        //     self.allocator,
        //     &self.gc,
        //     &shader_manager,
        //     &unified_pipeline_system,
        //     swapchain.render_pass,
        //     PARTICLE_MAX,
        // );

        log(.INFO, "app", "Unified particle renderer initialized", .{});

        // --- Compute shader system initialization ---
        compute_shader_system = try ComputeShaderSystem.init(&self.gc, &swapchain, self.allocator);

        log(.INFO, "ComputeSystem", "Compute system fully initialized", .{});

        // ==================== OLD GENERIC RENDERER (DISABLED FOR RENDER GRAPH) ====================
        // Initialize Generic Forward Renderer (rasterization only)
        // forward_renderer = GenericRenderer.init(self.allocator);

        // Set the scene bridge for renderers that need scene data
        // forward_renderer.setSceneBridge(&scene_bridge);

        // Set the swapchain for renderers that need it
        // forward_renderer.setSwapchain(&swapchain);

        // Add rasterization renderers to the forward renderer
        // try forward_renderer.addRenderer("textured", RendererType.raster, &textured_renderer, TexturedRenderer);
        // try forward_renderer.addRenderer("ecs_renderer", RendererType.raster, &ecs_renderer, EcsRenderer);
        // try forward_renderer.addRenderer("point_light", RendererType.lighting, &point_light_renderer, PointLightRenderer);
        // try forward_renderer.addRenderer("particle_renderer", RendererType.compute, &particle_renderer, ParticleRenderer);

        // Prime renderer descriptor bindings once all raster renderers are registered
        // try forward_renderer.onCreate();

        // Initialize Raytracing Render Pass (separate from forward renderer)
        // rt_render_pass = GenericRenderer.init(self.allocator);

        // Set the scene bridge and swapchain for raytracing
        // rt_render_pass.setSceneBridge(&scene_bridge);
        // rt_render_pass.setSwapchain(&swapchain);

        // Add raytracing renderer to its own render pass
        // try rt_render_pass.addRenderer("raytracing", RendererType.raytracing, &raytracing_renderer, RaytracingRenderer);

        // Ensure raytracing renderer receives initial descriptor bindings before the first frame
        // try rt_render_pass.onCreate();

        // Future renderers can be added here:
        // try forward_renderer.addRenderer("particle", RendererType.compute, &particle_renderer, ParticleRenderer);
        // try forward_renderer.addRenderer("shadow", RendererType.raster, &shadow_renderer, ShadowRenderer);
        // ==================== END OLD GENERIC RENDERER ====================

        log(.INFO, "app", "Render pass manager system initialized (GenericRenderer disabled)", .{});

        var init_frame_info = frame_info;
        init_frame_info.current_frame = current_frame;
        init_frame_info.command_buffer = cmdbufs[current_frame];
        init_frame_info.compute_buffer = vk.CommandBuffer.null_handle;
        init_frame_info.camera = &camera;
        // try forward_renderer.update(&init_frame_info);  // OLD: Disabled for RenderGraph
        // try rt_render_pass.update(&init_frame_info);    // OLD: Disabled for RenderGraph

        last_frame_time = c.glfwGetTime();
        self.fps_last_time = last_frame_time; // Initialize FPS tracking
        frame_info.camera = &camera;
        // // Legacy initialization removed - descriptors updated via SceneBridge during rendering
    }

    pub fn update(self: *App) !bool {
        // Reset AssetManager dirty flags at frame start
        // Async completion will set them back to true during the frame
        asset_manager.beginFrame();

        // Process deferred pipeline destroys for hot reload safety
        unified_pipeline_system.processDeferredDestroys();

        // Increment frame counter for scheduling
        frame_counter += 1;

        // Check for scheduled asset loads
        for (scheduled_assets.items) |*scheduled_asset| {
            if (!scheduled_asset.loaded and frame_counter >= scheduled_asset.frame) {
                log(.INFO, "app", "Loading scheduled asset at frame {}: {s}", .{ frame_counter, scheduled_asset.model_path });

                var loaded_object = try scene_v2.spawnProp(scheduled_asset.model_path, scheduled_asset.texture_path);
                try loaded_object.setPosition(scheduled_asset.position);

                try loaded_object.setScale(scheduled_asset.scale);

                log(.INFO, "app", "Note: Asset loading is asynchronous - the actual model and texture will appear once background loading completes", .{});

                scheduled_asset.loaded = true;
                try scene_v2.addParticleEmitter(
                    loaded_object.entity_id,
                    50.0, // emission_rate: 20 particles per second (increased for better visibility)
                    2.5, // particle_lifetime: 2.5 seconds (slightly longer)
                );
            }
        }

        // _ = try scene_bridge.updateAsyncResources();

        //std.debug.print("Updating frame {d}\n", .{current_frame});
        const current_time = c.glfwGetTime();

        // Print performance report every 10 seconds in debug builds
        if (comptime std.debug.runtime_safety) {
            if (current_time - last_performance_report >= 10.0) {
                asset_manager.printPerformanceReport();
                last_performance_report = current_time;
            }
        }

        // Update FPS in title bar every second
        self.fps_frame_count += 1;
        if (current_time - self.fps_last_time >= 1.0) {
            self.current_fps = @as(f32, @floatFromInt(self.fps_frame_count)) / @as(f32, @floatCast(current_time - self.fps_last_time));

            // Create title with FPS - use a stack buffer for the string
            var title_buffer: [256:0]u8 = undefined;
            const title_slice = std.fmt.bufPrintZ(title_buffer[0..], "ZulkanZengine - FPS: {d:.1}", .{self.current_fps}) catch |err| blk: {
                log(.WARN, "app", "Failed to format title: {}", .{err});
                break :blk std.fmt.bufPrintZ(title_buffer[0..], "ZulkanZengine", .{}) catch "ZulkanZengine";
            };

            self.window.setTitle(title_slice.ptr);

            self.fps_frame_count = 0;
            self.fps_last_time = current_time;
        }
        const dt = current_time - last_frame_time;

        const cmdbuf = cmdbufs[current_frame];
        const computebuf = compute_shader_system.compute_bufs[current_frame];
        frame_info.command_buffer = cmdbuf;
        frame_info.compute_buffer = computebuf;
        frame_info.dt = @floatCast(dt);
        frame_info.current_frame = current_frame;

        var width: c_int = 0;
        var height: c_int = 0;
        c.glfwGetWindowSize(@ptrCast(self.window.window.?), &width, &height);
        frame_info.extent = .{ .width = @as(u32, @intCast(width)), .height = @as(u32, @intCast(height)) };

        camera_controller.processInput(&self.window, viewer_object, dt);
        frame_info.camera.viewMatrix = viewer_object.transform.local2world;
        frame_info.camera.updateProjectionMatrix();
        var ubo = GlobalUbo{
            .view = frame_info.camera.viewMatrix,
            .projection = frame_info.camera.projectionMatrix,
            .dt = @floatCast(dt),
        };

        // Update ECS transform hierarchies
        if (new_ecs_enabled) {
            try transform_system.update(&new_ecs_world);
        }

        compute_shader_system.beginCompute(frame_info);
        // Update scene (animations, physics, lights, etc.)
        if (scene_v2_enabled) {
            try scene_v2.update(frame_info, &ubo);
        }

        // try forward_renderer.update(&frame_info);  // OLD: Disabled for RenderGraph

        // try rt_render_pass.update(&frame_info);    // OLD: Disabled for RenderGraph

        compute_shader_system.endCompute(frame_info);
        global_ubo_set.*.update(frame_info.current_frame, &ubo);

        //log(.TRACE, "app", "Frame start", .{});
        try swapchain.beginFrame(frame_info);

        // Populate image views for dynamic rendering
        const swap_image = swapchain.currentSwapImage();
        frame_info.color_image = swapchain.currentImage();
        frame_info.color_image_view = swap_image.view;
        frame_info.depth_image_view = swap_image.depth_image_view;

        // OLD: Legacy render pass (disabled for dynamic rendering)
        // swapchain.beginSwapChainRenderPass(frame_info);

        // Execute rasterization renderers through the forward renderer
        // try forward_renderer.render(frame_info);  // OLD: Disabled for RenderGraph

        // NEW: Execute Scene v2 RenderGraph (uses dynamic rendering)
        if (scene_v2_enabled) {
            try scene_v2.render(frame_info);
        }

        // OLD: Legacy render pass (disabled for dynamic rendering)
        // swapchain.endSwapChainRenderPass(frame_info);

        // Execute raytracing render pass BEFORE any render pass begins (raytracing must be outside render passes)
        // try rt_render_pass.render(frame_info);  // OLD: Disabled for RenderGraph

        try swapchain.endFrame(frame_info, &current_frame);
        last_frame_time = current_time;

        //log(.TRACE, "app", "Frame end", .{});

        // if (frame_counter >= 60_000) {
        //     // Stop the app once the frame counter reaches the test threshold.
        //     return false;
        // }

        return self.window.isRunning();
    }

    pub fn deinit(self: *App) void {
        _ = self.gc.vkd.deviceWaitIdle(self.gc.dev) catch {}; // Ensure all GPU work is finished before destroying resources

        swapchain.waitForAllFences() catch unreachable;

        // Clean up scheduled assets list
        scheduled_assets.deinit(self.allocator);

        global_ubo_set.deinit();

        // Cleanup generic renderer
        // forward_renderer.deinit();  // OLD: Disabled for RenderGraph
        // rt_render_pass.deinit();    // OLD: Disabled for RenderGraph

        self.gc.destroyCommandBuffers(cmdbufs, self.allocator);

        // Clean up unified systems (forward_renderer already deinit'd particle renderer)
        resource_binder.deinit();
        unified_pipeline_system.deinit();

        // Cleanup heap-allocated shader library

        //particle_renderer.deinit();
        scene.deinit();

        // Clean up Scene v2
        if (scene_v2_enabled) {
            scene_v2.deinit();
            log(.INFO, "app", "Scene v2 cleaned up", .{});
        }

        shader_manager.deinit();
        asset_manager.deinit();
        file_watcher.deinit();

        // Clean up new ECS system
        if (new_ecs_enabled) {
            new_ecs_world.deinit();
            log(.INFO, "app", "New ECS system cleaned up", .{});
        }

        // Shutdown thread pool last to prevent threading conflicts
        thread_pool.deinit();
        self.allocator.destroy(thread_pool);
        log(.INFO, "app", "Thread pool shut down", .{});
        swapchain.deinit();
        self.gc.deinit();

        // Clean up zstbi global state
        core_texture.deinitZstbi();

        self.window.deinit();
    }
};
