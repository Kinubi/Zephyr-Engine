const std = @import("std");
const Window = @import("window.zig").Window;
const GraphicsContext = @import("graphics_context.zig").GraphicsContext;
const Swapchain = @import("swapchain.zig").Swapchain;
const LayerStack = @import("layer_stack.zig").LayerStack;
const EventBus = @import("event_bus.zig").EventBus;
const FrameInfo = @import("../rendering/frameinfo.zig").FrameInfo;
const AssetManager = @import("../assets/asset_manager.zig").AssetManager;
const PerformanceMonitor = @import("../rendering/performance_monitor.zig").PerformanceMonitor;

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
    pub fn init(allocator: std.mem.Allocator, config: Config) !Engine {
        // TODO: Implement full initialization
        // For now, this is a stub to get compilation working
        _ = allocator;
        _ = config;
        @panic("Engine.init() not yet implemented");
    }

    /// Shutdown the engine and cleanup all resources
    pub fn deinit(self: *Engine) void {
        // TODO: Implement cleanup
        _ = self;
    }

    /// Check if engine should continue running
    pub fn isRunning(self: *Engine) bool {
        return self.window.isRunning();
    }

    /// Begin a new frame
    /// Returns frame info for rendering
    pub fn beginFrame(self: *Engine) !FrameInfo {
        // TODO: Implement frame begin
        _ = self;
        @panic("Engine.beginFrame() not yet implemented");
    }

    /// Update engine logic
    pub fn update(self: *Engine, frame_info: *const FrameInfo) !void {
        // TODO: Implement update
        _ = self;
        _ = frame_info;
    }

    /// Render the frame
    pub fn render(self: *Engine, frame_info: *const FrameInfo) !void {
        // TODO: Implement render
        _ = self;
        _ = frame_info;
    }

    /// End the frame and present
    pub fn endFrame(self: *Engine, frame_info: *const FrameInfo) !void {
        // TODO: Implement frame end
        _ = self;
        _ = frame_info;
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
