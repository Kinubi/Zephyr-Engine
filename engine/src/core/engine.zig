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

    /// Engine configuration
    pub const Config = struct {
        window: WindowConfig,
        renderer: RendererConfig = .{},
        enable_validation: bool = false,
        enable_performance_monitoring: bool = true,

        pub const WindowConfig = struct {
            width: u32 = 1280,
            height: u32 = 720,
            title: [:0]const u8 = "ZulkanEngine",
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

        // 3. Create swapchain
        engine.swapchain = try Swapchain.init(
            &engine.graphics_context,
            allocator,
            .{
                .width = config.window.width,
                .height = config.window.height,
            },
        );
        errdefer engine.swapchain.deinit();

        // 4. Create command pool (required before creating command buffers)
        try engine.graphics_context.createCommandPool();

        // 5. Create command buffers
        engine.command_buffers = try engine.graphics_context.createCommandBuffers(allocator);
        errdefer engine.graphics_context.destroyCommandBuffers(engine.command_buffers, allocator);

        engine.compute_buffers = try engine.graphics_context.createCommandBuffers(allocator);
        errdefer engine.graphics_context.destroyCommandBuffers(engine.compute_buffers, allocator);

        engine.swapchain.compute = true;

        // 6. Optional: Performance monitoring (must be before layers)
        if (config.enable_performance_monitoring) {
            engine.performance_monitor = try allocator.create(PerformanceMonitor);
            errdefer allocator.destroy(engine.performance_monitor.?);
            engine.performance_monitor.?.* = try PerformanceMonitor.init(allocator, &engine.graphics_context);
        }

        // 7. Initialize event system and layer stack
        engine.event_bus = EventBus.init(allocator);
        errdefer engine.event_bus.deinit();

        engine.window.setEventBus(&engine.event_bus);

        engine.layer_stack = LayerStack.init(allocator);
        errdefer engine.layer_stack.deinit();

        // 8. Create and add layers in order
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

        // 10. Initialize frame info
        engine.frame_info = FrameInfo{
            .current_frame = 0,
            .command_buffer = undefined, // Will be set in beginFrame
            .compute_buffer = undefined, // Will be set in beginFrame
            .camera = undefined,
            .dt = 0.0,
            .performance_monitor = engine.performance_monitor,
        };
        engine.last_frame_time = c.glfwGetTime();

        return engine;
    }

    /// Shutdown the engine and cleanup all resources
    pub fn deinit(self: *Engine) void {
        // Wait for all GPU operations to complete
        _ = self.graphics_context.vkd.deviceWaitIdle(self.graphics_context.dev) catch {};
        self.swapchain.waitForAllFences() catch {};

        // Clean up in reverse order of initialization

        // Asset manager (if initialized by application)
        if (self.asset_manager) |am| {
            am.deinit();
            self.allocator.destroy(am);
        }

        // Performance monitor
        if (self.performance_monitor) |pm| {
            pm.deinit();
            self.allocator.destroy(pm);
        }

        // Layer stack
        self.layer_stack.deinit();

        // Command buffers
        self.graphics_context.destroyCommandBuffers(self.compute_buffers, self.allocator);
        self.graphics_context.destroyCommandBuffers(self.command_buffers, self.allocator);

        // Event bus
        self.event_bus.deinit();

        // Swapchain
        self.swapchain.deinit();

        // Graphics context
        self.graphics_context.deinit();

        // Window (last)
        self.window.deinit();

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

    /// Update engine logic
    pub fn update(self: *Engine, frame_info: *FrameInfo) !void {
        // Update all layers
        try self.layer_stack.update(frame_info);
    }

    /// Render the frame
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
};
