const std = @import("std");
const Allocator = std.mem.Allocator;
const GameStateSnapshot = @import("game_state_snapshot.zig").GameStateSnapshot;
const captureSnapshot = @import("game_state_snapshot.zig").captureSnapshot;
const freeSnapshot = @import("game_state_snapshot.zig").freeSnapshot;
const ecs = @import("../ecs.zig");
const Camera = @import("../rendering/camera.zig").Camera;
const GraphicsContext = @import("../core/graphics_context.zig").GraphicsContext;
const Swapchain = @import("../core/swapchain.zig").Swapchain;
const ThreadPool = @import("thread_pool.zig").ThreadPool;
const log = @import("../utils/log.zig").log;
const Engine = @import("../core/engine.zig").Engine;

/// Context for managing the render thread and double-buffered game state.
pub const RenderThreadContext = struct {
    allocator: Allocator,

    // Double-buffered game state (ping-pong buffers)
    game_state: [2]GameStateSnapshot,
    current_read: std.atomic.Value(usize), // Which buffer render thread reads (0 or 1)

    // Synchronization primitives
    state_ready: std.Thread.Semaphore, // Main thread signals: new state available
    frame_consumed: std.Thread.Semaphore, // Render thread signals: frame consumed, main can continue

    // Thread management
    render_thread: ?std.Thread,
    shutdown: std.atomic.Value(bool),

    // Shared resources (owned externally, borrowed here)
    worker_pool: *ThreadPool,
    graphics_context: *anyopaque, // Can be *GraphicsContext or test mock
    swapchain: *anyopaque, // Can be *Swapchain or test mock
    engine: ?*anyopaque, // Engine pointer for full frame rendering (null for tests)

    // Frame tracking
    frame_index: std.atomic.Value(u64),
    last_rendered_frame: std.atomic.Value(u64), // Track which frame was last rendered to avoid duplicates
    // Uses maxInt as sentinel to indicate "not started yet"

    pub fn init(
        allocator: Allocator,
        worker_pool: *ThreadPool,
        graphics_context: anytype,
        swapchain: anytype,
    ) RenderThreadContext {
        return .{
            .allocator = allocator,
            .game_state = .{
                GameStateSnapshot.init(allocator),
                GameStateSnapshot.init(allocator),
            },
            .current_read = std.atomic.Value(usize).init(0),
            .state_ready = .{},
            .frame_consumed = .{},
            .render_thread = null,
            .shutdown = std.atomic.Value(bool).init(false),
            .worker_pool = worker_pool,
            .graphics_context = graphics_context,
            .swapchain = swapchain,
            .engine = null, // Will be set after engine is fully initialized
            .frame_index = std.atomic.Value(u64).init(0),
            .last_rendered_frame = std.atomic.Value(u64).init(std.math.maxInt(u64)), // Sentinel: not started yet
        };
    }

    /// Set the engine pointer after engine initialization is complete.
    /// This must be called before starting the render thread.
    pub fn setEngine(self: *RenderThreadContext, engine: anytype) void {
        self.engine = engine;
    }

    pub fn deinit(self: *RenderThreadContext) void {
        // Clean up both snapshot buffers
        self.game_state[0].deinit();
        self.game_state[1].deinit();
    }
};

/// Start the render thread.
/// This spawns a new thread that will loop calling renderThreadLoop().
pub fn startRenderThread(ctx: *RenderThreadContext) !void {
    if (ctx.render_thread != null) {
        return error.RenderThreadAlreadyRunning;
    }

    ctx.shutdown.store(false, .release);

    // Post frame_consumed semaphore initially so main thread can start producing first frame
    ctx.frame_consumed.post();

    ctx.render_thread = try std.Thread.spawn(.{}, renderThreadLoop, .{ctx});
}

/// Stop the render thread gracefully.
/// Signals shutdown and waits for the thread to exit.
pub fn stopRenderThread(ctx: *RenderThreadContext) void {
    if (ctx.render_thread) |thread| {
        // Signal shutdown
        ctx.shutdown.store(true, .release);

        // Wake up render thread if it's waiting
        ctx.state_ready.post();

        // Wait for thread to finish
        thread.join();

        ctx.render_thread = null;
    }
}

/// MAIN THREAD: Submit new game state to render thread
/// This is non-blocking - main thread continues immediately
pub fn mainThreadUpdate(
    ctx: *RenderThreadContext,
    world: *ecs.World,
    camera: anytype,
    delta_time: f32,
    imgui_draw_data: ?*anyopaque, // ImGui draw data from UI layer
) !void {
    // BACKPRESSURE: Wait for render thread to consume previous frame
    // This prevents main thread from getting more than 1 frame ahead
    // Ensures: no wasted work, low input latency, natural throttling
    ctx.frame_consumed.wait();

    // Determine which buffer to write to (the one render thread is NOT reading)
    const read_idx = ctx.current_read.load(.acquire);
    const write_idx = 1 - read_idx;

    // Free old snapshot in the write buffer
    if (ctx.game_state[write_idx].entity_count > 0) {
        freeSnapshot(&ctx.game_state[write_idx]);
    }

    // Capture new snapshot (material deltas captured via World → Scene → MaterialSystem)
    const frame_idx = ctx.frame_index.fetchAdd(1, .monotonic);
    ctx.game_state[write_idx] = try captureSnapshot(
        ctx.allocator,
        world,
        camera,
        frame_idx,
        delta_time,
        imgui_draw_data,
    );

    // Atomically flip buffers
    ctx.current_read.store(write_idx, .release);

    // Signal render thread that new state is available
    ctx.state_ready.post();
}

/// Get the effective frame count (slowest of main thread and render thread)
/// This represents the actual progress through frames that both threads have completed
pub fn getEffectiveFrameCount(ctx: *RenderThreadContext) u64 {
    const main_frame = ctx.frame_index.load(.monotonic);
    const rendered_frame = ctx.last_rendered_frame.load(.acquire);
    // Return the minimum - the slowest thread dictates the effective frame rate
    return @min(main_frame, rendered_frame);
}

/// Render thread entry point - runs in separate thread.
/// This is the function that the render thread executes in a loop.
fn renderThreadLoop(ctx: *RenderThreadContext) void {
    renderThreadLoopImpl(ctx) catch |err| {
        log(.ERROR, "render_thread", "Render thread crashed with error: {}", .{err});
    };
}

fn renderThreadLoopImpl(ctx: *RenderThreadContext) !void {
    // Get engine pointer (null check for tests)
    const engine_ptr = if (ctx.engine) |eng| @as(*Engine, @ptrCast(@alignCast(eng))) else null;

    while (!ctx.shutdown.load(.acquire)) {
        // Wait for main thread to signal new state (with timeout for shutdown checks)
        ctx.state_ready.wait();

        // Check shutdown again in case we were woken to exit
        if (ctx.shutdown.load(.acquire)) break;

        // Get the current snapshot (lock-free read)
        const read_idx = ctx.current_read.load(.acquire);
        const snapshot = &ctx.game_state[read_idx];

        // Skip if snapshot is empty (shouldn't happen in normal operation)
        if (snapshot.entity_count == 0) {
            // Signal frame consumed before skipping
            ctx.frame_consumed.post();
            continue;
        }

        // Check if we've already rendered this frame (main thread controls frame rate)
        const last_rendered = ctx.last_rendered_frame.load(.acquire);
        // Skip if we've already rendered this frame (unless it's the first frame - sentinel value)
        if (last_rendered != std.math.maxInt(u64) and snapshot.frame_index <= last_rendered) {
            // We've already rendered this frame, wait for next signal
            // Signal frame consumed before skipping
            ctx.frame_consumed.post();
            continue;
        }

        // If we have an engine, do the full frame rendering
        if (engine_ptr) |engine| {
            // ============================================
            // PHASE 2.1 Render Thread Responsibilities:
            //
            // 1. Begin frame (acquire swapchain image)
            // 2. Update (Vulkan descriptor updates)
            // 3. Render (Vulkan draw commands)
            // 4. End frame (submit & present)
            //
            // IMPORTANT: NO ECS queries on render thread!
            // - Main thread called scene.prepareFrame() which did ECS queries AND applied PT toggles
            // - Main thread captured snapshot for us to use
            // - We only do Vulkan work (descriptor updates + draw commands)
            // ============================================

            const frame_info = engine.beginFrame() catch |err| {
                // If window is closed, treat as shutdown signal
                if (err == error.WindowClosed) {
                    break;
                }
                // DeviceLost is fatal - panic to see stack trace
                if (err == error.DeviceLost) {
                    log(.ERROR, "render_thread", "FATAL: DeviceLost error - panicking to see stack trace", .{});
                    @panic("DeviceLost - check stack trace for cause");
                }
                log(.ERROR, "render_thread", "beginFrame failed: {}", .{err});
                // Signal frame consumed before skipping
                ctx.frame_consumed.post();
                continue;
            };

            // Set snapshot reference in frame_info for thread-safe access
            frame_info.snapshot = snapshot;

            // PHASE 2.1: Update phase does Vulkan descriptor updates (render thread)
            // This calls render_graph.update() which updates descriptor sets
            engine.update(frame_info) catch |err| {
                log(.ERROR, "render_thread", "update failed: {}", .{err});
                // Still try to end frame to avoid getting stuck
                _ = engine.endFrame(frame_info) catch {};
                // Signal frame consumed before skipping
                ctx.frame_consumed.post();
                continue;
            };

            // PHASE 2.1: Render phase does Vulkan draw commands (render thread)
            // This calls render_graph.execute() which records command buffers
            engine.render(frame_info) catch |err| {
                log(.ERROR, "render_thread", "render failed: {}", .{err});
                // Still try to end frame to avoid getting stuck
                _ = engine.endFrame(frame_info) catch {};
                // Signal frame consumed before skipping
                ctx.frame_consumed.post();
                continue;
            };

            engine.endFrame(frame_info) catch |err| {
                log(.ERROR, "render_thread", "endFrame failed: {}", .{err});
                // Signal frame consumed before skipping
                ctx.frame_consumed.post();
                continue;
            };

            // Mark this frame as rendered (main thread controls frame rate)
            ctx.last_rendered_frame.store(snapshot.frame_index, .release);

            // Signal main thread that frame is consumed, can produce next snapshot
            ctx.frame_consumed.post();
        } else {
            // Test mode: Just simulate work without actual engine
            std.Thread.sleep(std.time.ns_per_ms);

            // Mark frame as rendered even in test mode
            ctx.last_rendered_frame.store(snapshot.frame_index, .release);

            // Signal main thread even in test mode
            ctx.frame_consumed.post();
        }

        // NOTE: Don't free snapshot here - mainThreadUpdate will free it
        // when it overwrites this buffer with a new snapshot
    }
}
