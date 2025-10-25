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

// Scene v2 imports (ECS-based scene system)
const SceneV2 = @import("scene/scene_v2.zig").Scene;
const GameObjectV2 = @import("scene/game_object_v2.zig").GameObject;

// Asset system imports
const AssetManager = @import("assets/asset_manager.zig").AssetManager;
const Material = @import("assets/asset_manager.zig").Material;
const ThreadPool = @import("threading/thread_pool.zig").ThreadPool;
const ShaderManager = @import("assets/shader_manager.zig").ShaderManager;
const FileWatcher = @import("utils/file_watcher.zig").FileWatcher;

// Unified pipeline system imports
const UnifiedPipelineSystem = @import("rendering/unified_pipeline_system.zig").UnifiedPipelineSystem;
const ResourceBinder = @import("rendering/resource_binder.zig").ResourceBinder;

const PARTICLE_MAX: u32 = 1024;

// Utility imports
const Math = @import("utils/math.zig");
const log = @import("utils/log.zig").log;

const new_ecs = @import("ecs.zig"); // New coherent ECS system

// Input controller
const KeyboardMovementController = @import("keyboard_movement_controller.zig").KeyboardMovementController;

// UI system
const ImGuiContext = @import("ui/imgui_context.zig").ImGuiContext;
const UIRenderer = @import("ui/ui_renderer.zig").UIRenderer;
const RenderStats = @import("ui/ui_renderer.zig").RenderStats;

// Performance monitoring
const PerformanceMonitor = @import("rendering/performance_monitor.zig").PerformanceMonitor;

// Layer system
const Layer = @import("core/layer.zig").Layer;
const LayerStack = @import("core/layer_stack.zig").LayerStack;
const EventBus = @import("core/event_bus.zig").EventBus;
const Event = @import("core/event.zig").Event;
const EventData = @import("core/event.zig").EventData;
const RenderLayer = @import("layers/render_layer.zig").RenderLayer;
const PerformanceLayer = @import("layers/performance_layer.zig").PerformanceLayer;
const InputLayer = @import("layers/input_layer.zig").InputLayer;
const SceneLayer = @import("layers/scene_layer.zig").SceneLayer;
const UILayer = @import("layers/ui_layer.zig").UILayer;

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

    // Module-level variables (static state shared across App instances)

    var swapchain: Swapchain = undefined;
    var cmdbufs: []vk.CommandBuffer = undefined;
    var compute_bufs: []vk.CommandBuffer = undefined;

    var shader_manager: ShaderManager = undefined;

    // Unified pipeline system
    var unified_pipeline_system: UnifiedPipelineSystem = undefined;
    var resource_binder: ResourceBinder = undefined;

    var last_frame_time: f64 = undefined;
    var camera: Camera = undefined;
    var camera_controller: KeyboardMovementController = undefined;
    var global_UBO_buffers: ?[]Buffer = undefined;
    var frame_info: FrameInfo = FrameInfo{};

    var frame_index: u32 = 0;
    var frame_counter: u64 = 0; // Global frame counter for scheduling
    var thread_pool: *ThreadPool = undefined;
    var asset_manager: *AssetManager = undefined;
    var file_watcher: *FileWatcher = undefined;

    var performance_monitor: ?*PerformanceMonitor = null;
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
    var scene_v2: SceneV2 = undefined;
    var scene_v2_enabled: bool = true; // Always enabled now

    // UI system
    var imgui_context: ImGuiContext = undefined;
    var ui_renderer: UIRenderer = undefined;

    // Layer system
    var layer_stack: LayerStack = undefined;
    var event_bus: EventBus = undefined;
    var render_layer: RenderLayer = undefined;
    var performance_layer: PerformanceLayer = undefined;
    var input_layer: InputLayer = undefined;
    var scene_layer: SceneLayer = undefined;
    var ui_layer: UILayer = undefined;

    pub fn init(self: *App) !void {
        log(.INFO, "app", "Initializing ZulkanZengine...", .{});
        self.window = try Window.init(.{ .width = 1280, .height = 720 });

        self.allocator = std.heap.page_allocator;

        // Initialize scheduled assets system
        scheduled_assets = std.ArrayList(ScheduledAsset){};

        self.gc = try GraphicsContext.init(self.allocator, self.window.window_props.title, @ptrCast(self.window.window.?));
        log(.INFO, "app", "Using device: {s}", .{self.gc.deviceName()});
        swapchain = try Swapchain.init(&self.gc, self.allocator, .{ .width = self.window.window_props.width, .height = self.window.window_props.height });

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

        try thread_pool.registerSubsystem(.{
            .name = "render_extraction",
            .min_workers = 2,
            .max_workers = 8,
            .priority = .high, // Frame-critical work
            .work_item_type = .render_extraction,
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

        // ==================== Scene v2: Cornell Box with Two Vases ====================
        log(.INFO, "app", "Creating Scene v2: Cornell Box with two vases...", .{});

        scene_v2 = SceneV2.init(self.allocator, &new_ecs_world, asset_manager, thread_pool, "cornell_box");

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
        // Get window dimensions for path tracing pass
        var window_width: c_int = 0;
        var window_height: c_int = 0;
        c.glfwGetWindowSize(@ptrCast(self.window.window.?), &window_width, &window_height);

        // --- Use new GlobalUboSet abstraction ---
        global_ubo_set = self.allocator.create(GlobalUboSet) catch unreachable;
        global_ubo_set.* = try GlobalUboSet.init(&self.gc, self.allocator);

        try scene_v2.initRenderGraph(
            &self.gc,
            &unified_pipeline_system,
            swapchain.surface_format.format,
            try swapchain.depthFormat(),
            thread_pool,
            global_ubo_set,
            @intCast(window_width),
            @intCast(window_height),
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

        cmdbufs = try self.gc.createCommandBuffers(
            self.allocator,
        );

        compute_bufs = try self.gc.createCommandBuffers(
            self.allocator,
        );
        swapchain.compute = true;

        camera_controller = KeyboardMovementController.init();

        camera = Camera{ .fov = 75.0, .window = self.window };
        camera.updateProjectionMatrix();
        camera.setViewDirection(Math.Vec3.init(0, 0, 0), Math.Vec3.init(0, 0, 1), Math.Vec3.init(0, 1, 0));

        log(.INFO, "app", "ECS renderer initialized", .{});

        log(.INFO, "app", "Initialization complete", .{});

        log(.INFO, "app", "Unified particle renderer initialized", .{});

        log(.INFO, "app", "Render pass manager system initialized (GenericRenderer disabled)", .{});

        var init_frame_info = frame_info;
        init_frame_info.command_buffer = cmdbufs[frame_info.current_frame];
        init_frame_info.compute_buffer = vk.CommandBuffer.null_handle;
        init_frame_info.camera = &camera;
        // try forward_renderer.update(&init_frame_info);  // OLD: Disabled for RenderGraph
        // try rt_render_pass.update(&init_frame_info);    // OLD: Disabled for RenderGraph

        last_frame_time = c.glfwGetTime();
        frame_info.camera = &camera;
        frame_info.performance_monitor = null; // Will be set after initialization

        // Initialize ImGui
        log(.INFO, "app", "Initializing ImGui...", .{});
        imgui_context = try ImGuiContext.init(self.allocator, &self.gc, @ptrCast(self.window.window.?), &swapchain, &unified_pipeline_system);
        ui_renderer = UIRenderer.init();
        log(.INFO, "app", "ImGui initialized", .{});

        // Initialize Performance Monitor
        log(.INFO, "app", "Initializing Performance Monitor...", .{});
        performance_monitor = try self.allocator.create(PerformanceMonitor);
        performance_monitor.?.* = try PerformanceMonitor.init(self.allocator, &self.gc);
        frame_info.performance_monitor = performance_monitor;
        last_performance_report = c.glfwGetTime();
        log(.INFO, "app", "Performance Monitor initialized", .{});

        // Connect performance monitor to scene
        if (scene_v2_enabled) {
            scene_v2.setPerformanceMonitor(performance_monitor);
        }

        // Initialize Layer System
        log(.INFO, "app", "Initializing Layer System...", .{});
        layer_stack = LayerStack.init(self.allocator);
        event_bus = EventBus.init(self.allocator);
        
        // Wire up window callbacks to event bus
        self.window.setEventBus(&event_bus);

        // Create performance layer (should be first to track all frame timing)
        performance_layer = PerformanceLayer.init(performance_monitor.?, &swapchain, &self.window);
        try layer_stack.pushLayer(&performance_layer.base);

        // Create render layer
        render_layer = RenderLayer.init(&swapchain);
        try layer_stack.pushLayer(&render_layer.base);

        // Create input layer (handles camera movement and input)
        input_layer = InputLayer.init(&self.window, &camera, &camera_controller, &scene_v2);
        try layer_stack.pushLayer(&input_layer.base);

        // Create scene layer (updates scene, ECS systems, UBO)
        scene_layer = SceneLayer.init(&camera, &scene_v2, global_ubo_set, &transform_system, &new_ecs_world, performance_monitor);
        try layer_stack.pushLayer(&scene_layer.base);

        // Create UI layer (renders ImGui overlay)
        ui_layer = UILayer.init(&imgui_context, &ui_renderer, performance_monitor, &swapchain, &scene_v2, &camera_controller);
        try layer_stack.pushOverlay(&ui_layer.base); // UI is an overlay (always on top)

        log(.INFO, "app", "Layer System initialized with {} layers", .{layer_stack.count()});

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

        const current_time = c.glfwGetTime();

        const dt = current_time - last_frame_time;

        // ==================== PREPARE FRAME ====================
        // Set up frame_info with command buffers, timing, and window state
        frame_info.command_buffer = cmdbufs[frame_info.current_frame];
        frame_info.compute_buffer = compute_bufs[frame_info.current_frame];
        frame_info.dt = @floatCast(dt);

        var width: c_int = 0;
        var height: c_int = 0;
        c.glfwGetWindowSize(@ptrCast(self.window.window.?), &width, &height);
        frame_info.extent = .{ .width = @as(u32, @intCast(width)), .height = @as(u32, @intCast(height)) };

        // ==================== BEGIN FRAME (via Layer System) ====================
        // PerformanceLayer.begin() -> calls performance_monitor.beginFrame()
        // RenderLayer.begin() -> calls swapchain.beginFrame() and populates frame_info images
        try layer_stack.begin(&frame_info);

        // ==================== PROCESS EVENTS ====================
        // Dispatch all queued events to layers
        event_bus.processEvents(&layer_stack);

        // ==================== UPDATE LAYERS ====================
        // PerformanceLayer.update() -> resets queries and writes frame start timestamp
        // InputLayer.update() -> processes input, camera movement
        // SceneLayer.update() -> updates transforms, scene, UBO
        try layer_stack.update(&frame_info);

        // ==================== RENDER LAYERS ====================
        // SceneLayer.render() -> renders the scene
        // UILayer.render() -> renders ImGui overlay
        try layer_stack.render(&frame_info);

        // ==================== END FRAME ====================
        // End all layers (cleanup, etc.)
        try layer_stack.end(&frame_info);

        last_frame_time = current_time;

        return self.window.isRunning();
    }

    pub fn deinit(self: *App) void {
        _ = self.gc.vkd.deviceWaitIdle(self.gc.dev) catch {}; // Ensure all GPU work is finished before destroying resources

        swapchain.waitForAllFences() catch unreachable;

        // Clean up Layer System
        layer_stack.deinit();
        event_bus.deinit();
        log(.INFO, "app", "Layer System cleaned up", .{});

        // Clean up Performance Monitor
        if (performance_monitor) |pm| {
            pm.deinit();
            self.allocator.destroy(pm);
        }

        // Clean up UI
        ui_renderer.deinit();
        imgui_context.deinit();

        // Clean up scheduled assets list
        scheduled_assets.deinit(self.allocator);

        global_ubo_set.deinit();

        // Clean up generic renderer
        // forward_renderer.deinit();  // OLD: Disabled for RenderGraph
        // rt_render_pass.deinit();    // OLD: Disabled for RenderGraph

        self.gc.destroyCommandBuffers(cmdbufs, self.allocator);
        self.gc.destroyCommandBuffers(compute_bufs, self.allocator);

        // Clean up unified systems (forward_renderer already deinit'd particle renderer)
        resource_binder.deinit();
        unified_pipeline_system.deinit();

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
