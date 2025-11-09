const std = @import("std");
const vk = @import("vulkan");
const Window = @import("window.zig").Window;
const GraphicsContext = @import("graphics_context.zig").GraphicsContext;
const Swapchain = @import("swapchain.zig").Swapchain;
const LayerStack = @import("layer_stack.zig").LayerStack;
const EventBus = @import("event_bus.zig").EventBus;
const FrameInfo = @import("../rendering/frameinfo.zig").FrameInfo;
const AssetManager = @import("../assets/asset_manager.zig").AssetManager;
const PerformanceMonitor = @import("../rendering/performance_monitor.zig").PerformanceMonitor;
const RenderLayer = @import("../layers/render_layer.zig").RenderLayer;
const PerformanceLayer = @import("../layers/performance_layer.zig").PerformanceLayer;
const RenderThreadContext = @import("../threading/render_thread.zig").RenderThreadContext;
const ThreadPool = @import("../threading/thread_pool.zig").ThreadPool;
const memory_tracker_module = @import("../rendering/memory_tracker.zig");
const MemoryTracker = memory_tracker_module.MemoryTracker;
const MemoryBudget = memory_tracker_module.MemoryBudget;
const CVarRegistry = @import("cvar.zig").CVarRegistry;
const BufferManager = @import("../rendering/buffer_manager.zig").BufferManager;
const ResourceBinder = @import("../rendering/resource_binder.zig").ResourceBinder;
const UnifiedPipelineSystem = @import("../rendering/unified_pipeline_system.zig").UnifiedPipelineSystem;
const MaterialSystem = @import("../ecs/systems/material_system.zig").MaterialSystem;
const TextureManager = @import("../rendering/texture_manager.zig").TextureManager;
const ShaderManager = @import("../assets/shader_manager.zig").ShaderManager;
const FileWatcher = @import("../utils/file_watcher.zig").FileWatcher;
const ecs = @import("../ecs.zig");
const World = ecs.World;
const log = @import("../utils/log.zig").log;
const startRenderThread = @import("../threading/render_thread.zig").startRenderThread;
const stopRenderThread = @import("../threading/render_thread.zig").stopRenderThread;
const mainThreadUpdate = @import("../threading/render_thread.zig").mainThreadUpdate;
const rtGetEffectiveFrameCount = @import("../threading/render_thread.zig").getEffectiveFrameCount;
const c = @cImport({
    @cInclude("GLFW/glfw3.h");
});

/// Main engine instance
/// Manages core systems and provides the public API
pub const Engine = struct {
    allocator: std.mem.Allocator,

    // Core systems
    window: Window,
    graphics_context: GraphicsContext,
    swapchain: Swapchain,
    layer_stack: LayerStack,
    event_bus: EventBus,
    frame_info: FrameInfo,
    last_frame_time: f64,
    command_buffers: []vk.CommandBuffer,
    compute_buffers: []vk.CommandBuffer,

    // Built-in layers (required for proper operation)
    render_layer: RenderLayer,
    performance_layer: ?PerformanceLayer = null,

    // Optional systems
    asset_manager: ?*AssetManager = null,
    performance_monitor: ?*PerformanceMonitor = null,
    memory_tracker: ?*MemoryTracker = null,

    // Rendering systems
    shader_manager: ?*ShaderManager = null,
    unified_pipeline_system: ?*UnifiedPipelineSystem = null,
    resource_binder: ?*ResourceBinder = null,
    buffer_manager: ?*BufferManager = null,
    material_system: ?*MaterialSystem = null,
    texture_manager: ?*TextureManager = null,

    // Asset and file systems
    file_watcher: ?*FileWatcher = null,

    // ECS system
    ecs_world: ?*World = null,

    // Threading (required)
    thread_pool: *ThreadPool,
    render_thread_context: ?RenderThreadContext = null,
    use_render_thread: bool = false,

    /// Engine configuration
    pub const Config = struct {
        window: WindowConfig,
        renderer: RendererConfig = .{},
        enable_validation: bool = false,
        enable_performance_monitoring: bool = true,
        enable_render_thread: bool = false, // Phase 2.0: Separate render thread
        max_worker_threads: u32 = 8, // ThreadPool configuration
        cvar_registry: ?*CVarRegistry = null, // Optional CVar registry for runtime config

        pub const WindowConfig = struct {
            width: u32 = 1280,
            height: u32 = 720,
            title: [:0]const u8 = "ZephyrEngine",
            fullscreen: bool = false,
            vsync: bool = false,
        };

        pub const RendererConfig = struct {
            enable_ray_tracing: bool = true,
            max_frames_in_flight: u32 = 3,
        };
    };

    /// Initialize the engine with configuration
    pub fn init(allocator: std.mem.Allocator, config: Config) !*Engine {
        const engine = try allocator.create(Engine);
        errdefer allocator.destroy(engine);
        engine.allocator = allocator;

        // 1. Create window
        engine.window = try Window.init(.{
            .width = config.window.width,
            .height = config.window.height,
            .title = config.window.title,
            .fullscreen = config.window.fullscreen,
        });
        errdefer engine.window.deinit();

        // 2. Initialize graphics context
        engine.graphics_context = try GraphicsContext.init(
            allocator,
            config.window.title,
            @ptrCast(engine.window.window.?),
        );
        errdefer engine.graphics_context.deinit();

        // 2.5. Initialize memory tracker if enabled via CVar (defaults to OFF)
        // User can enable with: cvar set r_trackMemory true
        // And enable logging with: cvar set r_logMemoryAllocs true
        engine.memory_tracker = null;
        if (config.cvar_registry) |cvar_reg| {
            if (cvar_reg.getAsStringAlloc("r_trackMemory", allocator)) |value| {
                defer allocator.free(value);
                log(.INFO, "engine", "r_trackMemory at startup: {s}", .{value});
                if (std.mem.eql(u8, value, "true")) {
                    const budget = MemoryBudget{
                        .max_buffer_mb = 4096,
                        .max_texture_mb = 8192,
                        .max_blas_mb = 512,
                        .max_tlas_mb = 256,
                        .max_total_mb = 16384,
                    };
                    engine.memory_tracker = try MemoryTracker.init(allocator, budget);
                    engine.graphics_context.memory_tracker = engine.memory_tracker;
                    log(.INFO, "engine", "Memory tracker ENABLED (Buffer: 4GB, Texture: 8GB, BLAS: 512MB, TLAS: 256MB, Total: 16GB)", .{});
                }
            }
        }

        // 3. Initialize BufferManager (rendering systems will be registered by application)
        // Note: Applications should call registerRenderingSystems() after creating their own systems
        engine.buffer_manager = null; // Will be initialized when rendering systems are registered

        // 3.5. Initialize TextureManager BEFORE Swapchain (swapchain needs it for HDR textures)
        engine.texture_manager = try allocator.create(TextureManager);
        errdefer allocator.destroy(engine.texture_manager.?);
        engine.texture_manager.?.* = try TextureManager.init(
            allocator,
            &engine.graphics_context,
        );
        log(.INFO, "engine", "TextureManager initialized early for swapchain HDR textures", .{});

        // 4. Create swapchain (now with TextureManager available)
        engine.swapchain = try Swapchain.init(
            &engine.graphics_context,
            allocator,
            engine.texture_manager.?,
            .{
                .width = config.window.width,
                .height = config.window.height,
            },
        );
        errdefer engine.swapchain.deinit();

        // 5. Create command pool (required before creating command buffers)
        try engine.graphics_context.createCommandPool();

        // 6. Create command buffers
        engine.command_buffers = try engine.graphics_context.createCommandBuffers(allocator);
        errdefer engine.graphics_context.destroyCommandBuffers(engine.command_buffers, allocator);

        engine.compute_buffers = try engine.graphics_context.createCommandBuffers(allocator);
        errdefer engine.graphics_context.destroyCommandBuffers(engine.compute_buffers, allocator);

        engine.swapchain.compute = true;

        // 7. Optional: Performance monitoring (must be before layers)
        if (config.enable_performance_monitoring) {
            engine.performance_monitor = try allocator.create(PerformanceMonitor);
            errdefer allocator.destroy(engine.performance_monitor.?);
            engine.performance_monitor.?.* = try PerformanceMonitor.init(allocator, &engine.graphics_context);
        }

        // 8. Initialize event system and layer stack
        engine.event_bus = EventBus.init(allocator);
        errdefer engine.event_bus.deinit();

        engine.window.setEventBus(&engine.event_bus);

        engine.layer_stack = LayerStack.init(allocator);
        errdefer engine.layer_stack.deinit();

        // 9. Create and add layers in order
        // PerformanceLayer first (if enabled) - needs to track full frame timing
        if (config.enable_performance_monitoring) {
            engine.performance_layer = PerformanceLayer.init(engine.performance_monitor.?, &engine.swapchain, &engine.window);
            try engine.layer_stack.pushLayer(&engine.performance_layer.?.base);
        }

        // RenderLayer (REQUIRED - handles swapchain begin/end)
        engine.render_layer = RenderLayer.init(&engine.swapchain);
        try engine.layer_stack.pushLayer(&engine.render_layer.base);
        // Note: Asset manager requires additional initialization that may be app-specific
        // For now, leave it null and let the application initialize it if needed
        engine.asset_manager = null;

        // 10. Initialize ThreadPool (required for many engine systems)
        engine.thread_pool = try allocator.create(ThreadPool);
        errdefer allocator.destroy(engine.thread_pool);
        engine.thread_pool.* = try ThreadPool.init(allocator, 16); // Max 16 workers

        // Register core subsystems with thread pool
        // NOTE: System-specific subsystems are automatically registered by the systems themselves:
        //   - "hot_reload" → FileWatcher.init()
        //   - "bvh_building" → MultithreadedBvhBuilder.init()
        //   - "ecs_update" → World.init()
        //   - "render_extraction" → RenderSystem.init()

        // Start the thread pool with configured workers
        try engine.thread_pool.start(config.max_worker_threads);
        log(.INFO, "engine", "ThreadPool initialized with {} workers", .{config.max_worker_threads});

        // 11. Optional: Initialize render thread (Phase 2.0)
        engine.use_render_thread = config.enable_render_thread;
        engine.render_thread_context = null; // Explicitly initialize to null
        if (config.enable_render_thread) {
            log(.INFO, "render_thread", "Render thread ENABLED in config", .{});

            engine.render_thread_context = RenderThreadContext.init(
                allocator,
                engine.thread_pool,
                &engine.graphics_context,
                &engine.swapchain,
            );
            errdefer if (engine.render_thread_context) |*ctx| ctx.deinit();

            // Set engine pointer so render thread can call beginFrame/render/endFrame
            engine.render_thread_context.?.setEngine(engine);

            try startRenderThread(&engine.render_thread_context.?);
            log(.INFO, "render_thread", "Render thread started successfully", .{});
        } else {
            log(.INFO, "render_thread", "Render thread DISABLED in config", .{});
        }

        // 12. Initialize frame info
        engine.frame_info = FrameInfo{
            .current_frame = 0,
            .command_buffer = undefined, // Will be set in beginFrame
            .compute_buffer = undefined, // Will be set in beginFrame
            .dt = 0.0, // DEPRECATED: Will be set from snapshot
            .performance_monitor = engine.performance_monitor,
        };
        engine.last_frame_time = c.glfwGetTime();

        return engine;
    }

    /// Shutdown the engine and cleanup all resources
    pub fn deinit(self: *Engine) void {
        log(.INFO, "engine", "Beginning engine shutdown...", .{});

        // Render thread (if enabled) - stop first to prevent accessing systems during cleanup
        if (self.render_thread_context) |*ctx| {
            log(.INFO, "render_thread", "Stopping render thread...", .{});
            stopRenderThread(ctx);
            ctx.deinit();
            log(.INFO, "render_thread", "Render thread stopped", .{});
        } else {
            log(.INFO, "render_thread", "No render thread to stop (was not enabled)", .{});
        }

        // Wait for all GPU operations to complete AFTER stopping render thread
        log(.INFO, "engine", "Waiting for GPU idle...", .{});
        _ = self.graphics_context.vkd.deviceWaitIdle(self.graphics_context.dev) catch {};
        self.swapchain.waitForAllFences() catch {};
        log(.INFO, "engine", "GPU idle complete", .{});

        // Clean up in reverse order of initialization

        // Performance monitor
        log(.INFO, "engine", "Cleaning up performance monitor...", .{});
        if (self.performance_monitor) |pm| {
            pm.deinit();
            self.allocator.destroy(pm);
        }

        log(.INFO, "engine", "Cleaning up MaterialSystem...", .{});
        if (self.material_system) |ms| {
            ms.deinit();
        }

        log(.INFO, "engine", "Cleaning up ResourceBinder...", .{});
        if (self.resource_binder) |rb| {
            rb.deinit();
            self.allocator.destroy(rb);
        }

        log(.INFO, "engine", "Cleaning up UnifiedPipelineSystem...", .{});
        if (self.unified_pipeline_system) |ups| {
            ups.deinit();
            self.allocator.destroy(ups);
        }

        // FileWatcher FIRST (has worker threads in ThreadPool that must be stopped before other systems)
        log(.INFO, "engine", "Cleaning up FileWatcher...", .{});
        if (self.file_watcher) |fw| {
            fw.deinit();
            self.allocator.destroy(fw);
        }

        log(.INFO, "engine", "Cleaning up ShaderManager...", .{});
        if (self.shader_manager) |sm| {
            sm.deinit();
            self.allocator.destroy(sm);
        }

        // ECS world
        log(.INFO, "engine", "Cleaning up ECS World...", .{});
        if (self.ecs_world) |world| {
            world.deinit();
            self.allocator.destroy(world);
        }

        log(.INFO, "engine", "Cleaning up AssetManager...", .{});
        if (self.asset_manager) |am| {
            am.deinit();
            self.allocator.destroy(am);
        }

        // Layer stack
        log(.INFO, "engine", "Cleaning up LayerStack...", .{});
        self.layer_stack.deinit();

        // Command buffers
        log(.INFO, "engine", "Destroying command buffers...", .{});
        self.graphics_context.destroyCommandBuffers(self.compute_buffers, self.allocator);
        self.graphics_context.destroyCommandBuffers(self.command_buffers, self.allocator);

        // Event bus
        log(.INFO, "engine", "Cleaning up EventBus...", .{});
        self.event_bus.deinit();

        // Swapchain
        log(.INFO, "engine", "Cleaning up Swapchain...", .{});
        self.swapchain.deinit();

        log(.INFO, "engine", "Cleaning up TextureManager...", .{});
        if (self.texture_manager) |tm| {
            tm.deinit();
            self.allocator.destroy(tm);
        }

        log(.INFO, "engine", "Cleaning up BufferManager...", .{});
        if (self.buffer_manager) |bm| {
            bm.deinit();

            // Graphics context
            log(.INFO, "engine", "Cleaning up GraphicsContext...", .{});
            self.graphics_context.deinit();
        }
        // Memory tracker (print statistics before cleanup)
        log(.INFO, "engine", "Cleaning up MemoryTracker...", .{});
        if (self.memory_tracker) |tracker| {
            log(.INFO, "engine", "=== Memory Tracking Statistics ===", .{});
            tracker.printStatistics();
            tracker.deinit(); // This also destroys the pointer
        }

        // ThreadPool (cleanup after all systems that might use it but before window)
        log(.INFO, "engine", "Cleaning up ThreadPool...", .{});
        self.thread_pool.deinit();
        self.allocator.destroy(self.thread_pool);
        log(.INFO, "engine", "ThreadPool cleaned up", .{});

        // Window (very last)
        log(.INFO, "engine", "Cleaning up Window...", .{});
        self.window.deinit();

        log(.INFO, "engine", "Engine shutdown complete", .{});
        // Finally, destroy the engine itself
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    /// Check if engine should continue running
    pub fn isRunning(self: *Engine) bool {
        return self.window.isRunning();
    }

    /// Begin a new frame
    /// Returns frame info for rendering
    pub fn beginFrame(self: *Engine) !*FrameInfo {
        // 1. Check if window is still running
        if (!self.window.isRunning()) {
            return error.WindowClosed;
        }

        // 2. Process queued events through layers
        self.event_bus.processEvents(&self.layer_stack);

        // 3. Calculate delta time
        const current_time = c.glfwGetTime();
        const dt = current_time - self.last_frame_time;
        self.frame_info.dt = @floatCast(dt);
        self.last_frame_time = current_time;

        // 4. Set up command buffers for this frame
        self.frame_info.command_buffer = self.command_buffers[self.frame_info.current_frame];
        self.frame_info.compute_buffer = self.compute_buffers[self.frame_info.current_frame];

        // 4.5. Begin frame for buffer manager (cleanup old buffers)
        if (self.buffer_manager) |bm| {
            bm.beginFrame(self.frame_info.current_frame);
        }

        // 5. Get window size for extent
        var width: c_int = 0;
        var height: c_int = 0;
        c.glfwGetWindowSize(@ptrCast(self.window.window.?), &width, &height);
        self.frame_info.extent = .{
            .width = @as(u32, @intCast(width)),
            .height = @as(u32, @intCast(height)),
        };

        // 6. Begin all layers (RenderLayer will call swapchain.beginFrame)
        try self.layer_stack.begin(&self.frame_info);

        return &self.frame_info;
    }

    /// PHASE 2.1: Prepare frame on MAIN THREAD (game logic, ECS - no Vulkan)
    pub fn prepare(self: *Engine, dt: f32) !void {
        // Prepare all layers
        try self.layer_stack.prepare(dt);
    }

    /// Update engine logic (RENDER THREAD - Vulkan descriptor updates)
    pub fn update(self: *Engine, frame_info: *FrameInfo) !void {
        // Update all layers
        try self.layer_stack.update(frame_info);
    }

    /// Render the frame (RENDER THREAD - Vulkan draw commands)
    pub fn render(self: *Engine, frame_info: *FrameInfo) !void {
        // Render all layers
        try self.layer_stack.render(frame_info);
    }

    /// End the frame and present
    /// Note: frame_info.current_frame will be incremented by swapchain.endFrame
    pub fn endFrame(self: *Engine, frame_info: *FrameInfo) !void {
        // 1. End all layers (RenderLayer will submit and present)
        try self.layer_stack.end(frame_info);
    }

    /// Get the layer stack for adding custom layers
    pub fn getLayerStack(self: *Engine) *LayerStack {
        return &self.layer_stack;
    }

    /// Get the event bus for queuing events
    pub fn getEventBus(self: *Engine) *EventBus {
        return &self.event_bus;
    }

    /// Get the asset manager (if enabled)
    pub fn getAssetManager(self: *Engine) ?*AssetManager {
        return self.asset_manager;
    }

    /// Get the window instance
    pub fn getWindow(self: *Engine) *Window {
        return &self.window;
    }

    /// Get the graphics context
    pub fn getGraphicsContext(self: *Engine) *GraphicsContext {
        return &self.graphics_context;
    }

    /// Get the swapchain
    pub fn getSwapchain(self: *Engine) *Swapchain {
        return &self.swapchain;
    }

    // ==================== Render Thread API (Phase 2.0) ====================
    //
    // Render thread mode decouples game logic from rendering for better performance.
    //
    // Usage Example:
    // ```zig
    // var thread_pool = try ThreadPool.init(allocator, 4);
    // defer thread_pool.deinit();
    //
    // const engine = try Engine.init(allocator, .{
    //     .window = .{ .width = 1280, .height = 720 },
    //     .enable_render_thread = true,
    //     .thread_pool = &thread_pool,
    // });
    // defer engine.deinit();
    //
    // while (engine.isRunning()) {
    //     // 1. Update game logic
    //     updateGameLogic(world, camera);
    //
    //     // 2. Capture state and signal render thread (non-blocking)
    //     try engine.captureAndSignalRenderThread(&world, &camera);
    //
    //     // 3. Continue with engine frame (will render previous frame in parallel)
    //     const frame_info = try engine.beginFrame();
    //     try engine.update(frame_info);
    //     try engine.render(frame_info);
    //     try engine.endFrame(frame_info);
    // }
    // ```

    /// Check if render thread mode is enabled
    pub fn isRenderThreadEnabled(self: *Engine) bool {
        return self.use_render_thread;
    }

    /// Capture game state and signal render thread (Phase 2.0)
    /// Only call this if render thread is enabled
    /// This should be called from the main/game thread before beginFrame()
    pub fn captureAndSignalRenderThread(
        self: *Engine,
        world: anytype, // *ecs.World or compatible
        camera: anytype, // *Camera or compatible
        imgui_draw_data: ?*anyopaque, // ImGui draw data from UI layer
    ) !void {
        if (!self.use_render_thread) {
            return error.RenderThreadNotEnabled;
        }

        if (self.render_thread_context) |*ctx| {
            try mainThreadUpdate(
                ctx,
                world,
                camera,
                self.frame_info.dt,
                imgui_draw_data,
            );
        } else {
            return error.RenderThreadNotInitialized;
        }
    }

    /// Get the effective frame count (slowest thread - the bottleneck)
    /// Returns min(main_thread_frames, rendered_frames)
    /// Use this for scheduling assets/events based on actual displayed frames
    pub fn getEffectiveFrameCount(self: *Engine) u64 {
        if (self.render_thread_context) |*ctx| {
            return rtGetEffectiveFrameCount(ctx);
        }
        return 0;
    }

    // === Rendering System Management ===

    /// Initialize core rendering systems (ShaderManager, UnifiedPipelineSystem, etc.)
    /// This should be called after engine init but before creating scenes
    pub fn initRenderingSystems(self: *Engine) !void {
        // Initialize FileWatcher for hot reload
        self.file_watcher = try self.allocator.create(FileWatcher);
        errdefer self.allocator.destroy(self.file_watcher.?);
        self.file_watcher.?.* = try FileWatcher.init(self.allocator, self.thread_pool);
        try self.file_watcher.?.start();
        log(.INFO, "engine", "FileWatcher initialized for hot reload", .{});

        // Initialize AssetManager
        self.asset_manager = try AssetManager.init(self.allocator, &self.graphics_context, self.thread_pool);

        // Initialize ShaderManager
        self.shader_manager = try self.allocator.create(ShaderManager);
        errdefer self.allocator.destroy(self.shader_manager.?);
        self.shader_manager.?.* = try ShaderManager.init(self.allocator, self.thread_pool, self.file_watcher);

        try self.shader_manager.?.addShaderDirectory("assets/shaders");
        try self.shader_manager.?.start();
        log(.INFO, "engine", "Shader hot reload system initialized", .{});

        // Initialize UnifiedPipelineSystem
        self.unified_pipeline_system = try self.allocator.create(UnifiedPipelineSystem);
        errdefer self.allocator.destroy(self.unified_pipeline_system.?);
        self.unified_pipeline_system.?.* = try UnifiedPipelineSystem.init(
            self.allocator,
            &self.graphics_context,
            self.shader_manager.?,
        );

        // Initialize ResourceBinder
        self.resource_binder = try self.allocator.create(ResourceBinder);
        errdefer self.allocator.destroy(self.resource_binder.?);
        self.resource_binder.?.* = ResourceBinder.init(self.allocator, self.unified_pipeline_system.?);

        // Connect pipeline system to shader manager for hot reload
        self.shader_manager.?.setPipelineSystem(self.unified_pipeline_system.?);

        // Initialize ECS World
        self.ecs_world = try self.allocator.create(World);
        errdefer self.allocator.destroy(self.ecs_world.?);
        self.ecs_world.?.* = try World.init(self.allocator, self.thread_pool);

        // Register core ECS components
        try self.ecs_world.?.registerComponent(ecs.Transform);
        try self.ecs_world.?.registerComponent(ecs.MeshRenderer);
        try self.ecs_world.?.registerComponent(ecs.Camera);
        try self.ecs_world.?.registerComponent(ecs.PointLight);
        try self.ecs_world.?.registerComponent(ecs.ParticleComponent);
        try self.ecs_world.?.registerComponent(ecs.ParticleEmitter);
        try self.ecs_world.?.registerComponent(ecs.ScriptComponent);

        // Register material components
        try self.ecs_world.?.registerComponent(ecs.MaterialSet);
        try self.ecs_world.?.registerComponent(ecs.AlbedoMaterial);
        try self.ecs_world.?.registerComponent(ecs.RoughnessMaterial);
        try self.ecs_world.?.registerComponent(ecs.MetallicMaterial);
        try self.ecs_world.?.registerComponent(ecs.NormalMaterial);
        try self.ecs_world.?.registerComponent(ecs.EmissiveMaterial);
        try self.ecs_world.?.registerComponent(ecs.OcclusionMaterial);

        // Initialize BufferManager with full integration
        self.buffer_manager = try BufferManager.init(
            self.allocator,
            &self.graphics_context,
            self.resource_binder.?,
        );

        // TextureManager was already initialized in Engine.init() before Swapchain
        // Just connect it to RenderLayer for update callbacks
        if (self.texture_manager) |tm| {
            self.render_layer.setTextureManager(tm);
        }

        // Initialize MaterialSystem (handles both materials and textures now)
        self.material_system = try MaterialSystem.init(
            self.allocator,
            self.buffer_manager.?,
            self.asset_manager.?,
        );

        log(.INFO, "engine", "Core systems initialized (AssetManager, ShaderManager, UnifiedPipelineSystem, ResourceBinder, BufferManager, MaterialSystem, ECS)", .{});
    }

    // === Rendering System Accessors ===

    /// Get the shader manager instance
    pub fn getShaderManager(self: *Engine) ?*ShaderManager {
        return self.shader_manager;
    }

    /// Get the unified pipeline system instance
    pub fn getUnifiedPipelineSystem(self: *Engine) ?*UnifiedPipelineSystem {
        return self.unified_pipeline_system;
    }

    /// Get the resource binder instance
    pub fn getResourceBinder(self: *Engine) ?*ResourceBinder {
        return self.resource_binder;
    }

    /// Get the buffer manager instance
    pub fn getBufferManager(self: *Engine) ?*BufferManager {
        return self.buffer_manager;
    }

    /// Get the material system instance
    pub fn getMaterialSystem(self: *Engine) ?*MaterialSystem {
        return self.material_system;
    }

    /// Get the texture manager instance
    pub fn getTextureManager(self: *Engine) ?*TextureManager {
        return self.texture_manager;
    }

    /// Get the ECS world instance
    pub fn getECSWorld(self: *Engine) ?*World {
        return self.ecs_world;
    }

    /// Get the thread pool instance
    pub fn getThreadPool(self: *Engine) *ThreadPool {
        return self.thread_pool;
    }
};
