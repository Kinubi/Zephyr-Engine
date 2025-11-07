const std = @import("std");
const zephyr = @import("zephyr");

// Core graphics imports from engine
const Window = zephyr.Window;
const GraphicsContext = zephyr.GraphicsContext;
const Swapchain = zephyr.Swapchain;
const MAX_FRAMES_IN_FLIGHT = 3; // TODO: Get from engine config
const Buffer = zephyr.Buffer;
const Texture = zephyr.Texture;

// Rendering imports from engine
const Vertex = zephyr.Vertex;
const Mesh = zephyr.Mesh;
const Model = zephyr.Model;
const Camera = zephyr.Camera;
const FrameInfo = zephyr.FrameInfo;
const GlobalUbo = zephyr.GlobalUbo;
const GlobalUboSet = zephyr.GlobalUboSet;

// Scene v2 imports from engine (ECS-based scene system)
const Scene = zephyr.Scene;
const GameObjectV2 = zephyr.GameObject;

// Asset system imports from engine
const AssetManager = zephyr.AssetManager;
const Material = zephyr.Material;
const ThreadPool = zephyr.ThreadPool;
const ShaderManager = zephyr.ShaderManager;
const FileWatcher = zephyr.FileWatcher;

// Unified pipeline system imports from engine
const UnifiedPipelineSystem = zephyr.UnifiedPipelineSystem;
const ResourceBinder = zephyr.ResourceBinder;

const PARTICLE_MAX: u32 = 1024;

// Utility imports from engine
const Math = zephyr.math;
const log = zephyr.log;

const new_ecs = zephyr.ecs; // New coherent ECS system

// Input controller (editor-specific)
const KeyboardMovementController = @import("keyboard_movement_controller.zig").KeyboardMovementController;

// UI system (editor-specific)
const ImGuiContext = @import("ui/backend/imgui_context.zig").ImGuiContext;
const UIRenderer = @import("ui/ui_renderer.zig").UIRenderer;
const RenderStats = @import("ui/ui_renderer.zig").RenderStats;

// Performance monitoring from engine
const PerformanceMonitor = zephyr.PerformanceMonitor;

// Layer system from engine
const Layer = zephyr.Layer;
const LayerStack = zephyr.LayerStack;
const EventBus = zephyr.EventBus;
const Event = zephyr.Event;
const EventData = Event.EventData;
const RenderLayer = zephyr.RenderLayer;
const PerformanceLayer = zephyr.PerformanceLayer;
// TODO: These have editor dependencies, temporarily importing locally
const SceneLayer = zephyr.SceneLayer;
const UILayer = @import("layers/ui_layer.zig").UILayer;

// Vulkan bindings and external C libraries
const vk = @import("vulkan");
const builtin = @import("builtin");
const c = @cImport({
    @cInclude("GLFW/glfw3.h");
});

pub const App = struct {
    // Core engine instance - manages window, graphics, swapchain, base layers
    engine: *zephyr.Engine = undefined,
    allocator: std.mem.Allocator = undefined,

    // Initialize to true so descriptors are updated on first frames
    descriptor_dirty_flags: [MAX_FRAMES_IN_FLIGHT]bool = [_]bool{true} ** MAX_FRAMES_IN_FLIGHT,
    as_dirty_flags: [MAX_FRAMES_IN_FLIGHT]bool = [_]bool{false} ** MAX_FRAMES_IN_FLIGHT,

    // Module-level variables (static state shared across App instances)

    var shader_manager: ShaderManager = undefined;

    // Unified pipeline system
    var unified_pipeline_system: UnifiedPipelineSystem = undefined;
    var resource_binder: ResourceBinder = undefined;

    var camera: Camera = undefined;
    var camera_controller: zephyr.CameraController = undefined;
    var global_UBO_buffers: ?[]Buffer = undefined;

    var frame_counter: u64 = 0; // Global frame counter for scheduling (should track rendered frames, not game loop iterations)
    var thread_pool: *ThreadPool = undefined;
    var asset_manager: *AssetManager = undefined;

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

    // New coherent ECS system
    var new_ecs_world: new_ecs.World = undefined;
    var new_ecs_enabled: bool = false;

    // ECS systems
    var transform_system: new_ecs.TransformSystem = undefined;

    // Scene v2 (ECS-based scene)
    var scene: Scene = undefined;
    var scene_enabled: bool = true; // Always enabled now

    // UI system
    var imgui_context: ImGuiContext = undefined;
    var ui_renderer: UIRenderer = undefined;

    // Editor-specific layers
    var scene_layer: SceneLayer = undefined;
    var ui_layer: UILayer = undefined;

    pub fn init(self: *App) !void {
        log(.INFO, "app", "Initializing Zephyr-Engine Editor...", .{});

        self.allocator = std.heap.page_allocator;

        // Initialize scheduled assets system
        scheduled_assets = std.ArrayList(ScheduledAsset){};

        // ==================== Initialize Engine ====================
        // Engine handles: window, graphics context, swapchain, command buffers, base layers
        log(.INFO, "app", "Initializing engine core systems...", .{});

        // Initialize CVar registry before engine initialization
        _ = try zephyr.cvar.ensureGlobal(self.allocator);
        const cvar_reg = zephyr.cvar.getGlobal();

        self.engine = try zephyr.Engine.init(self.allocator, .{
            .window = .{
                .width = 2560,
                .height = 1440,
                .title = "Zephyr Editor",
            },
            .enable_validation = false,
            .enable_performance_monitoring = true,
            .enable_render_thread = true, // Phase 2.1 complete: prepare/update/render separation
            .max_worker_threads = 8, // ThreadPool configuration
            .cvar_registry = if (cvar_reg) |reg| @ptrCast(reg) else null,
        });
        errdefer self.engine.deinit();

        log(.INFO, "app", "Engine initialized - Using device: {s}", .{self.engine.getGraphicsContext().deviceName()});

        // Get convenient references to engine systems
        const gc = self.engine.getGraphicsContext();
        const swapchain = self.engine.getSwapchain();
        const window = self.engine.getWindow();
        const performance_monitor = self.engine.performance_monitor;

        // Get ThreadPool from engine for custom application work
        thread_pool = self.engine.getThreadPool();

        // Register custom application work subsystem (for ad-hoc tasks)
        try thread_pool.registerSubsystem(.{
            .name = "custom_work",
            .min_workers = 1,
            .max_workers = 2,
            .priority = .low,
            .work_item_type = .custom,
        });

        // ==================== Initialize Core Rendering Systems via Engine ====================
        // Initialize all core rendering systems through the engine (includes FileWatcher)
        try self.engine.initRenderingSystems();

        // ==================== Get ECS System from Engine ====================
        new_ecs_world = self.engine.getECSWorld().?.*;
        new_ecs_enabled = true;
        // Initialize editor-specific ECS systems
        transform_system = new_ecs.TransformSystem.init(self.allocator);
        log(.INFO, "app", "ECS system available from engine, initialized editor systems", .{});

        // Get convenient references to engine-managed systems
        asset_manager = self.engine.getAssetManager().?;
        shader_manager = self.engine.getShaderManager().?.*;
        unified_pipeline_system = self.engine.getUnifiedPipelineSystem().?.*;
        resource_binder = self.engine.getResourceBinder().?.*;

        // FileWatcher is now owned by engine - no need to store reference
        log(.INFO, "app", "Core rendering systems initialized via engine", .{});

        // ==================== Scene v2: Cornell Box with Two Vases ====================
        log(.INFO, "app", "Creating Scene v2: Cornell Box with two vases...", .{});

        scene = try Scene.init(self.allocator, &new_ecs_world, asset_manager, thread_pool, "cornell_box");

        // Register scene pointer in World so systems can access it
        try new_ecs_world.setUserData("scene", @ptrCast(&scene));

        // Scene owns its local systems (scripting is scene-local). The scheduler looks up
        // the Scene via userdata and dispatches to the scene-owned scripting system; no
        // separate scripting_system userdata registration is required.

        // Schedule the flat vase to be loaded at frame 1000
        try scheduled_assets.append(self.allocator, ScheduledAsset{
            .frame = 50000,
            .model_path = "assets/models/flat_vase.obj",
            .texture_path = "assets/textures/granitesmooth1-albedo.png",
            .position = Math.Vec3.init(-1.4, -0.5, 0.5),
            .rotation = Math.Vec3.init(0, 0, 0),
            .scale = Math.Vec3.init(0.5, 0.5, 0.5),
        });
        log(.INFO, "app", "Scheduled flat vase to be loaded at frame 1000", .{});

        // Give async texture loading a moment to complete
        std.Thread.sleep(100_000_000); // 100ms

        // Initialize RenderGraph BEFORE spawning props (so MaterialSystem exists)
        var window_width: c_int = 0;
        var window_height: c_int = 0;
        c.glfwGetWindowSize(@ptrCast(window.window.?), &window_width, &window_height);

        global_ubo_set = self.allocator.create(GlobalUboSet) catch unreachable;
        global_ubo_set.* = try GlobalUboSet.init(gc, self.allocator);

        try scene.initRenderGraph(
            gc,
            self.engine.getUnifiedPipelineSystem().?,
            self.engine.getBufferManager().?,
            swapchain.hdr_format,
            swapchain.surface_format.format,
            try swapchain.depthFormat(),
            thread_pool,
            global_ubo_set,
            @intCast(window_width),
            @intCast(window_height),
        );

        log(.INFO, "app", "Scene render graph initialized", .{});

        // Cornell Box dimensions - smaller and pushed back so camera can see it
        const box_size: f32 = 2.0; // Smaller box
        const half_size = box_size / 2.0;
        const box_offset_z: f32 = 3.0; // Push box away from camera

        // Floor (white)
        const floor = try scene.spawnProp("assets/models/cube.obj", .{
            .albedo_texture_path = "assets/textures/missing.png",
        });
        try floor.setPosition(Math.Vec3.init(0, -half_size + 3, box_offset_z - 3));
        try floor.setScale(Math.Vec3.init(box_size, 0.1, box_size));
        log(.INFO, "app", "Scene v2: Added floor", .{});

        // Ceiling (white)
        const ceiling = try scene.spawnProp("assets/models/cube.obj", .{
            .albedo_texture_path = "assets/textures/missing.png",
        });
        try ceiling.setPosition(Math.Vec3.init(0, half_size - 3, 0));
        try ceiling.setScale(Math.Vec3.init(box_size, 0.1, box_size));
        log(.INFO, "app", "Scene v2: Added ceiling", .{});

        // Back wall (white)
        const back_wall = try scene.spawnProp("assets/models/cube.obj", .{
            .albedo_texture_path = "assets/textures/error.png",
        });
        try back_wall.setPosition(Math.Vec3.init(0, 0, half_size + 1));
        try back_wall.setScale(Math.Vec3.init(box_size, box_size, 0.1));
        log(.INFO, "app", "Scene v2: Added back wall", .{});

        // Left wall (red) - using error.png for red color
        const left_wall = try scene.spawnProp("assets/models/cube.obj", .{
            .albedo_texture_path = "assets/textures/granitesmooth1-bl/granitesmooth1-albedo.png",
        });
        try left_wall.setPosition(Math.Vec3.init(-half_size - 1, 0, 0));
        try left_wall.setScale(Math.Vec3.init(0.1, box_size, box_size));
        log(.INFO, "app", "Scene v2: Added left wall (red)", .{});

        // Right wall (green) - using default.png for green-ish color
        const right_wall = try scene.spawnProp("assets/models/cube.obj", .{});
        try right_wall.setPosition(Math.Vec3.init(half_size + 1, 0, 0));
        try right_wall.setScale(Math.Vec3.init(0.1, box_size, box_size));
        log(.INFO, "app", "Scene v2: Added right wall (green)", .{});

        // Second vase (right side) - flat vase with PBR material
        const vase2 = try scene.spawnProp("assets/models/flat_vase.obj", .{
            .albedo_texture_path = "assets/textures/granitesmooth1-bl/granitesmooth1-albedo.png",
            .roughness_texture_path = "assets/textures/granitesmooth1-bl/granitesmooth1-roughness3.png",
            .roughness = 1.0, // Use full roughness from texture
        });
        try vase2.setPosition(Math.Vec3.init(1.2, -half_size + 0.05, 0.5));
        try vase2.setScale(Math.Vec3.init(0.8, 0.8, 0.8));
        // Attach a small script that moves the vase gradually each frame

        log(.INFO, "app", "Scene v2: Added vase 2 (flat)", .{});

        log(.INFO, "app", "Scene v2 Cornell Box complete with {} entities!", .{scene.entities.items.len});

        // ==================== Add Lights to Scene v2 ====================
        log(.INFO, "app", "Adding lights to scene v2...", .{});

        // Register PointLight component in scene's ECS world
        try scene.ecs_world.registerComponent(new_ecs.PointLight);

        // Main light (white, center-top)
        const main_light = try scene.ecs_world.createEntity();
        const main_light_transform = new_ecs.Transform.initWithPosition(Math.Vec3.init(0, 1.5, 1.0));
        try scene.ecs_world.emplace(new_ecs.Transform, main_light, main_light_transform);
        try scene.ecs_world.emplace(new_ecs.PointLight, main_light, new_ecs.PointLight.initWithRange(
            Math.Vec3.init(1.0, 1.0, 1.0), // White
            3.0, // Intensity
            10.0, // Range
        ));
        log(.INFO, "app", "Scene v2: Added main light", .{});

        // Warm accent light (left side, orange)
        const warm_light = try scene.ecs_world.createEntity();
        const warm_light_transform = new_ecs.Transform.initWithPosition(Math.Vec3.init(-1.5, 0.5, 1.0));
        try scene.ecs_world.emplace(new_ecs.Transform, warm_light, warm_light_transform);
        try scene.ecs_world.emplace(new_ecs.PointLight, warm_light, new_ecs.PointLight.initWithRange(
            Math.Vec3.init(1.0, 0.6, 0.2), // Orange
            2.0, // Intensity
            8.0, // Range
        ));
        log(.INFO, "app", "Scene v2: Added warm accent light", .{});

        // Cool accent light (right side, blue)
        const cool_light = try scene.ecs_world.createEntity();
        const cool_light_transform = new_ecs.Transform.initWithPosition(Math.Vec3.init(1.5, 0.5, 1.0));
        try scene.ecs_world.emplace(new_ecs.Transform, cool_light, cool_light_transform);
        try scene.ecs_world.emplace(new_ecs.PointLight, cool_light, new_ecs.PointLight.initWithRange(
            Math.Vec3.init(0.2, 0.5, 1.0), // Blue
            2.0, // Intensity
            8.0, // Range
        ));
        log(.INFO, "app", "Scene v2: Added cool accent light", .{});

        log(.INFO, "app", "Scene v2: Lights added successfully", .{});

        // NOTE: TextureSystem and MaterialSystem now handle their own updates
        // (RenderGraph already initialized above before spawning props)

        // Add particle emitter to vase2 (AFTER render graph is initialized so particle compute pass exists)
        try scene.addParticleEmitter(
            vase2.entity_id,
            50.0, // emission_rate: 50 particles per second
            2.5, // particle_lifetime: 2.5 seconds
        );
        log(.INFO, "app", "Scene v2: Added particle emitter to vase 2", .{});

        // ==================== End Scene v2 Setup ====================

        // ==================== Initialize Camera ====================
        camera_controller = zephyr.CameraController.init();

        camera = Camera{ .fov = 75.0, .window = window.* };
        camera.updateProjectionMatrix();
        camera.setViewDirection(Math.Vec3.init(0, 0, 0), Math.Vec3.init(0, 0, 1), Math.Vec3.init(0, 1, 0));

        log(.INFO, "app", "Camera initialized", .{});

        // ==================== Initialize ImGui ====================
        log(.INFO, "app", "Initializing ImGui...", .{});
        imgui_context = try ImGuiContext.init(self.allocator, gc, @ptrCast(window.window.?), swapchain, self.engine.getUnifiedPipelineSystem().?);

        ui_renderer = UIRenderer.init(self.allocator);
        log(.INFO, "app", "ImGui initialized", .{});

        // Connect performance monitor to scene
        if (scene_enabled and performance_monitor != null) {
            scene.setPerformanceMonitor(performance_monitor);
        }

        // ==================== Add Editor-Specific Layers ====================
        log(.INFO, "app", "Adding editor-specific layers...", .{});

        // InputLayer removed: events are generated by Window -> EventBus and
        // are consumed by SceneLayer/UILayer directly.

        // Create scene layer (updates scene, ECS systems, UBO)
        scene_layer = SceneLayer.init(&camera, &scene, global_ubo_set, &transform_system, &new_ecs_world, performance_monitor, &camera_controller);
        try self.engine.getLayerStack().pushLayer(&scene_layer.base);

        // Create UI layer (renders ImGui overlay)
        ui_layer = UILayer.init(&imgui_context, &ui_renderer, performance_monitor, swapchain, &scene, &camera, &camera_controller);
        try self.engine.getLayerStack().pushOverlay(&ui_layer.base); // UI is an overlay (always on top)

        log(.INFO, "app", "Editor layers added - Total layers: {}", .{self.engine.getLayerStack().count()});

        log(.INFO, "app", "Editor initialization complete!", .{});
    }

    pub fn update(self: *App) !bool {
        // NOTE: TextureSystem and MaterialSystem now handle their own updates
        // No need for AssetManager.beginFrame() anymore

        // Process deferred pipeline destroys for hot reload safety
        self.engine.getUnifiedPipelineSystem().?.processDeferredDestroys();

        // Increment frame counter for scheduling
        // In render thread mode, use the slowest thread's frame count (the bottleneck)
        // This ensures scheduled assets appear based on actual rendered frames
        if (self.engine.isRenderThreadEnabled()) {
            // Use min(main_thread_frames, rendered_frames) - the effective progress
            frame_counter = self.engine.getEffectiveFrameCount();
        } else {
            // Single-threaded: just increment
            frame_counter += 1;
        }

        // Check for scheduled asset loads
        for (scheduled_assets.items) |*scheduled_asset| {
            if (!scheduled_asset.loaded and frame_counter >= scheduled_asset.frame) {
                log(.INFO, "app", "Loading scheduled asset at frame {}: {s}", .{ frame_counter, scheduled_asset.model_path });

                var loaded_object = try scene.spawnProp(scheduled_asset.model_path, .{
                    .albedo_texture_path = scheduled_asset.texture_path,
                });
                try loaded_object.setPosition(scheduled_asset.position);
                try loaded_object.setScale(scheduled_asset.scale);

                // If this is the first vase (or any scheduled prop), attach the moving script
                const move_script_sched = "translate_entity(0.01, 0.0, 0.0)";
                try scene.ecs_world.emplace(new_ecs.ScriptComponent, loaded_object.entity_id, new_ecs.ScriptComponent.init(move_script_sched, true, false));

                log(.INFO, "app", "Note: Asset loading is asynchronous - the actual model and texture will appear once background loading completes", .{});

                scheduled_asset.loaded = true;
                try scene.addParticleEmitter(
                    loaded_object.entity_id,
                    50.0, // emission_rate: 50 particles per second
                    2.5, // particle_lifetime: 2.5 seconds
                );
            }
        }

        // ==================== USE ENGINE FRAME LOOP ====================
        if (self.engine.isRenderThreadEnabled()) {
            // RENDER THREAD MODE (Phase 2.1): Main thread handles game logic, render thread handles GPU

            const dt = self.engine.frame_info.dt;

            // MAIN THREAD: Prepare all layers (game logic, ECS queries, NO Vulkan)
            // This calls layer.prepare() which calls scene.prepareFrame()
            try self.engine.prepare(dt);

            // MAIN THREAD: Capture game state snapshot and signal render thread (non-blocking)
            // This copies data from World into snapshot for render thread to use
            try self.engine.captureAndSignalRenderThread(&new_ecs_world, &camera);

            // Main thread continues immediately without blocking on GPU
            // The render thread will:
            //   1. Wait for snapshot
            //   2. Call engine.update() → layer.update() → scene.prepareRender() (Vulkan descriptors)
            //   3. Call engine.render() → layer.render() → scene.render() (Vulkan draws)
            //   4. Present
        } else {
            // SINGLE-THREADED MODE: Main thread does everything
            // Begin frame through engine
            const frame_info = try self.engine.beginFrame();

            // Update engine systems
            try self.engine.update(frame_info);

            // Render frame
            try self.engine.render(frame_info);

            // End frame
            try self.engine.endFrame(frame_info);
        }

        return self.engine.isRunning();
    }

    pub fn deinit(self: *App) void {
        _ = self.engine.getGraphicsContext().vkd.deviceWaitIdle(self.engine.getGraphicsContext().dev) catch {}; // Ensure all GPU work is finished
        self.engine.getSwapchain().waitForAllFences() catch unreachable;

        // Clean up UI
        ui_renderer.deinit();
        imgui_context.deinit();

        // Clean up scheduled assets list
        scheduled_assets.deinit(self.allocator);

        global_ubo_set.deinit();

        // Clean up Scene v2
        if (scene_enabled) {
            scene.deinit();
            log(.INFO, "app", "Scene v2 cleaned up", .{});
        }

        // FileWatcher and ThreadPool are now managed by engine
        log(.INFO, "app", "FileWatcher and ThreadPool managed by engine", .{});

        // Clean up engine (handles all core systems including ThreadPool and FileWatcher)
        // Engine handles: window, graphics context, swapchain, layers, render thread, threading
        self.engine.deinit();
        log(.INFO, "app", "Engine shut down (including ThreadPool and FileWatcher)", .{});

        // Save and cleanup global CVar registry (persists archived CVars to disk)
        zephyr.cvar.deinitGlobal();
        log(.INFO, "app", "CVar system shut down (archived CVars saved)", .{});
    }
};
