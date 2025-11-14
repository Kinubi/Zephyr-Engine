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
const CVars = @import("../core/cvar.zig");

pub const MAX_SNAPSHOT_BUFFERS = 3; // Maximum supported buffer count

// Main thread maintains its own cycling index (stored in threadlocal)
threadlocal var main_thread_write_idx: usize = 0;

/// Get the current write buffer index (main thread only)
pub fn getCurrentWriteIndex() usize {
    return main_thread_write_idx;
}

/// Context for managing the render thread and multi-buffered game state.
/// Supports 2 (double) or 3 (triple) buffering controlled by r_snapshot_buffers CVAR.
pub const RenderThreadContext = struct {
    allocator: Allocator,

    // Multi-buffered game state (2-3 buffers)
    game_state: []GameStateSnapshot,
    buffer_count: u32, // Actual number of buffers in use (2 or 3)

    // Vulkan-style per-buffer semaphores (token passing)
    main_thread_ready: []std.Thread.Semaphore, // Signaled when main thread can write to this buffer
    render_thread_ready: []std.Thread.Semaphore, // Signaled when render thread can read this buffer

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
    last_completed_frame: std.atomic.Value(u64), // Last frame completed by render thread

    pub fn init(
        allocator: Allocator,
        worker_pool: *ThreadPool,
        graphics_context: anytype,
        swapchain: anytype,
    ) !RenderThreadContext {
        // Read buffer count from CVAR (default 3 for triple buffering)
        const buffer_count: u32 = blk: {
            if (CVars.getGlobal()) |registry| {
                if (registry.getAsStringAlloc("r_snapshot_buffers", allocator)) |value| {
                    defer allocator.free(value);
                    if (std.fmt.parseInt(u32, value, 10)) |parsed| {
                        break :blk @min(@max(parsed, 2), MAX_SNAPSHOT_BUFFERS);
                    } else |_| {}
                }
            }
            break :blk 3; // Default to triple buffering
        };

        // Allocate semaphore arrays based on buffer_count
        const main_ready = try allocator.alloc(std.Thread.Semaphore, buffer_count);
        errdefer allocator.free(main_ready);

        const render_ready = try allocator.alloc(std.Thread.Semaphore, buffer_count);
        errdefer allocator.free(render_ready);

        // Initialize all semaphores
        for (0..buffer_count) |i| {
            main_ready[i] = .{};
            render_ready[i] = .{};
            // Initially, main thread owns all buffers (can write to them)
            main_ready[i].post();
        }

        // Allocate and initialize game state snapshots
        const game_state = try allocator.alloc(GameStateSnapshot, buffer_count);
        errdefer {
            allocator.free(main_ready);
            allocator.free(render_ready);
            allocator.free(game_state);
        }

        for (0..buffer_count) |i| {
            game_state[i] = GameStateSnapshot.init(allocator);
        }

        return .{
            .allocator = allocator,
            .game_state = game_state,
            .buffer_count = buffer_count,
            .main_thread_ready = main_ready,
            .render_thread_ready = render_ready,
            .render_thread = null,
            .shutdown = std.atomic.Value(bool).init(false),
            .worker_pool = worker_pool,
            .graphics_context = graphics_context,
            .swapchain = swapchain,
            .engine = null, // Will be set after engine is fully initialized
            .frame_index = std.atomic.Value(u64).init(0),
            .last_completed_frame = std.atomic.Value(u64).init(0),
        };
    }

    /// Set the engine pointer after engine initialization is complete.
    /// This must be called before starting the render thread.
    pub fn setEngine(self: *RenderThreadContext, engine: anytype) void {
        self.engine = engine;
    }

    pub fn deinit(self: *RenderThreadContext) void {
        // Clean up all snapshot buffers
        for (0..self.buffer_count) |i| {
            self.game_state[i].deinit();
        }
        // Free allocated arrays
        self.allocator.free(self.game_state);
        self.allocator.free(self.main_thread_ready);
        self.allocator.free(self.render_thread_ready);
    }
};

/// Start the render thread.
/// This spawns a new thread that will loop calling renderThreadLoop().
pub fn startRenderThread(ctx: *RenderThreadContext) !void {
    if (ctx.render_thread != null) {
        return error.RenderThreadAlreadyRunning;
    }

    ctx.shutdown.store(false, .release);

    log(.INFO, "render_thread", "Starting render thread with {} snapshot buffers ({s})", .{ ctx.buffer_count, if (ctx.buffer_count == 2) "double" else "triple" });

    ctx.render_thread = try std.Thread.spawn(.{}, renderThreadLoop, .{ctx});
}

/// Stop the render thread gracefully.
/// Signals shutdown and waits for the thread to exit.
pub fn stopRenderThread(ctx: *RenderThreadContext) void {
    if (ctx.render_thread) |thread| {
        // Signal shutdown
        ctx.shutdown.store(true, .release);

        // Wake up render thread if it's waiting on any buffer
        for (0..ctx.buffer_count) |i| {
            ctx.render_thread_ready[i].post();
        }

        // Wait for thread to finish
        thread.join();

        ctx.render_thread = null;
    }
}

/// MAIN THREAD: Submit new game state to render thread
/// With triple buffering, main thread can be up to 2 frames ahead
pub fn mainThreadUpdate(
    ctx: *RenderThreadContext,
    world: *ecs.World,
    camera: anytype,
    delta_time: f32,
    imgui_draw_data: ?*anyopaque, // ImGui draw data from UI layer
) !void {
    // Get the current write buffer (ring buffer: 0, 1, 2, 0, 1, 2, ...)
    const write_idx = main_thread_write_idx;

    // BACKPRESSURE: Wait for this buffer to be available (Vulkan-style token passing)
    // This semaphore was posted by render thread when it finished with this buffer,
    // or was initially signaled at startup
    ctx.main_thread_ready[write_idx].wait();

    // Free old snapshot in the write buffer
    if (ctx.game_state[write_idx].entity_count > 0) {
        freeSnapshot(&ctx.game_state[write_idx]);
    }

    // Capture new snapshot (material deltas captured directly from MaterialDeltasComponent)
    const frame_idx = ctx.frame_index.fetchAdd(1, .monotonic);
    ctx.game_state[write_idx] = try captureSnapshot(
        ctx.allocator,
        world,
        camera,
        frame_idx,
        delta_time,
        imgui_draw_data,
        write_idx, // Pass buffer index so snapshot knows which buffer its ImGui data is in
    );

    // Advance write index for next frame AFTER capturing snapshot
    // This ensures getCurrentWriteIndex() returns the index we just wrote to
    // during the same frame's prepare phase (for ImGui synchronization)
    main_thread_write_idx = (write_idx + 1) % ctx.buffer_count;

    // Signal render thread that this buffer is ready (pass the token)
    ctx.render_thread_ready[write_idx].post();
}

/// Get the effective frame count (slowest of main thread and render thread)
pub fn getEffectiveFrameCount(ctx: *RenderThreadContext) u64 {
    const main_frame = ctx.frame_index.load(.monotonic);
    const completed_frame = ctx.last_completed_frame.load(.acquire);
    return @min(main_frame, completed_frame);
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

    // Render thread maintains its own cycling index independently
    var read_idx: usize = 0;

    while (!ctx.shutdown.load(.acquire)) {
        // Wait for main thread to signal this buffer is ready (Vulkan-style token passing)
        ctx.render_thread_ready[read_idx].wait();

        // Check shutdown again in case we were woken to exit
        if (ctx.shutdown.load(.acquire)) break;

        const snapshot = &ctx.game_state[read_idx];

        // Skip if snapshot is empty (shouldn't happen in normal operation)
        if (snapshot.entity_count == 0) {
            // Return buffer to main thread (pass token back)
            ctx.main_thread_ready[read_idx].post();
            // Advance to next buffer
            read_idx = (read_idx + 1) % ctx.buffer_count;
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
                // Return buffer to main thread on error
                ctx.main_thread_ready[read_idx].post();
                // Advance to next buffer before continuing
                read_idx = (read_idx + 1) % ctx.buffer_count;
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
                // Return buffer to main thread on error
                ctx.main_thread_ready[read_idx].post();
                // Advance to next buffer before continuing
                read_idx = (read_idx + 1) % ctx.buffer_count;
                continue;
            };

            // PHASE 2.1: Render phase does Vulkan draw commands (render thread)
            // This calls render_graph.execute() which records command buffers
            engine.render(frame_info) catch |err| {
                log(.ERROR, "render_thread", "render failed: {}", .{err});
                // Still try to end frame to avoid getting stuck
                _ = engine.endFrame(frame_info) catch {};
                // Return buffer to main thread on error
                ctx.main_thread_ready[read_idx].post();
                // Advance to next buffer before continuing
                read_idx = (read_idx + 1) % ctx.buffer_count;
                continue;
            };

            engine.endFrame(frame_info) catch |err| {
                log(.ERROR, "render_thread", "endFrame failed: {}", .{err});
                // Return buffer to main thread on error
                ctx.main_thread_ready[read_idx].post();
                // Advance to next buffer before continuing
                read_idx = (read_idx + 1) % ctx.buffer_count;
                continue;
            };

            // Mark frame as completed
            ctx.last_completed_frame.store(snapshot.frame_index, .release);
        }

        // Return buffer to main thread (pass token back)
        // Post BEFORE advancing so main thread gets the token for the buffer we just finished
        ctx.main_thread_ready[read_idx].post();
        // Advance read index for next iteration (ring buffer: 0, 1, 2, 0, 1, 2, ...)
        read_idx = (read_idx + 1) % ctx.buffer_count;

        // NOTE: Don't free snapshot here - mainThreadUpdate will free it
        // when it overwrites this buffer with a new snapshot
    }
}
