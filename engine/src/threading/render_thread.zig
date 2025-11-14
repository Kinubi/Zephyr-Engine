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
        }

        // Initially signal all buffers as available for main thread
        // Dynamic gap is managed by tryWait logic in mainThreadUpdate
        for (0..buffer_count) |i| {
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
/// Returns the buffer index that was just freed (for cleanup)
pub fn mainThreadUpdate(
    ctx: *RenderThreadContext,
    world: *ecs.World,
    camera: anytype,
    delta_time: f32,
    imgui_draw_data: ?*anyopaque, // ImGui draw data from UI layer
) !usize {
    const write_idx = main_thread_write_idx;

    // DYNAMIC BACKPRESSURE MECHANISM:
    // This implements a variable-gap triple buffering system that adapts to render thread performance.
    //
    // Traditional triple buffering enforces a fixed 3-frame gap between main and render threads,
    // which means UI changes take 3 frames to appear on screen. This dynamic approach reduces
    // latency during normal operation while still providing headroom when the render thread stutters.
    //
    // Strategy: Try to acquire buffers in order of preference (smallest gap first):
    //   1. Try 2 frames back (write_idx - 2): If available, gap is only 1 frame - minimal latency
    //   2. Try 1 frame back (write_idx - 1): If available, gap is 2 frames - moderate latency
    //   3. Wait on current (write_idx):       Block until available - enforces max 3-frame gap
    //
    // How it works:
    // - If render thread is keeping up, it frees buffers quickly and main thread can proceed
    //   with minimal gap (often running just 1 frame ahead instead of 3)
    // - If render thread stutters (shader compilation, heavy GPU work), main thread will
    //   eventually hit the blocking wait(), preventing runaway frame generation
    // - Each successful timedWait(0) consumes a semaphore token, allowing write to write_idx
    //
    // Example scenarios:
    // Buffer sequence: 0 -> 1 -> 2 -> 0 -> 1 -> 2...
    //
    // Scenario A (render keeping up):
    //   - Main at buffer 0, tries buffer 1 (2 back) - SUCCESS - proceeds immediately, 1 frame gap
    //   - Render thread is fast enough to keep freeing buffers ahead of main thread
    //
    // Scenario B (render behind):
    //   - Main at buffer 0, tries buffer 1 (2 back) - TIMEOUT (render still using it)
    //   - Tries buffer 2 (1 back) - TIMEOUT (render still using it)
    //   - Waits on buffer 0 (current) - BLOCKS until render frees it, enforces max gap
    //
    // Benefits:
    // - UI responsiveness: Changes appear faster when GPU is not bottleneck
    // - Stutter isolation: Render thread stutters don't immediately block main thread
    // - Automatic adaptation: System naturally adjusts gap based on relative thread speeds

    // Calculate the two previous buffer indices (wrapping around at buffer_count)
    const prev_1 = if (write_idx == 0) ctx.buffer_count - 1 else write_idx - 1;
    const prev_2 = if (prev_1 == 0) ctx.buffer_count - 1 else prev_1 - 1;

    // Try to acquire the oldest buffer first (smallest gap = best latency)
    if (ctx.main_thread_ready[prev_2].timedWait(0)) |_| {
        // Success: Render thread already finished with prev_2, we can proceed with minimal gap
        // The main thread is running close behind the render thread (1 frame gap)
    } else |_| {
        // Timeout: prev_2 not available yet, try the next oldest buffer
        if (ctx.main_thread_ready[prev_1].timedWait(0)) |_| {
            // Success: prev_1 is available, proceed with moderate gap (2 frame gap)
        } else |_| {
            // Both old buffers still in use - must wait for current buffer to be freed
            // This is a blocking wait that enforces the maximum gap of (buffer_count - 1) frames
            // Only happens when render thread is significantly behind main thread
            ctx.main_thread_ready[write_idx].wait();
        }
    }
    // At this point, we have successfully acquired a semaphore token and can safely
    // write to write_idx. The render thread won't touch this buffer until we signal it.

    // Free old snapshot and capture new one
    if (ctx.game_state[write_idx].entity_count > 0) {
        freeSnapshot(&ctx.game_state[write_idx]);
    }

    const frame_idx = ctx.frame_index.fetchAdd(1, .monotonic);
    ctx.game_state[write_idx] = try captureSnapshot(
        ctx.allocator,
        world,
        camera,
        frame_idx,
        delta_time,
        imgui_draw_data,
        write_idx,
    );

    main_thread_write_idx = (write_idx + 1) % ctx.buffer_count;
    ctx.render_thread_ready[write_idx].post();

    return write_idx;
}

/// Get the effective frame count (slowest of main thread and render thread)
pub fn getEffectiveFrameCount(ctx: *RenderThreadContext) u64 {
    const main_frame = ctx.frame_index.load(.monotonic);
    const completed_frame = ctx.last_completed_frame.load(.acquire);
    return @min(main_frame, completed_frame);
}

fn renderThreadLoop(ctx: *RenderThreadContext) void {
    renderThreadLoopImpl(ctx) catch |err| {
        log(.ERROR, "render_thread", "Render thread crashed: {}", .{err});
    };
}

fn renderThreadLoopImpl(ctx: *RenderThreadContext) !void {
    const engine_ptr = if (ctx.engine) |eng| @as(*Engine, @ptrCast(@alignCast(eng))) else null;
    var read_idx: usize = 0;

    while (!ctx.shutdown.load(.acquire)) {
        ctx.render_thread_ready[read_idx].wait();

        if (ctx.shutdown.load(.acquire)) break;

        const snapshot = &ctx.game_state[read_idx];

        if (snapshot.entity_count == 0) {
            ctx.main_thread_ready[read_idx].post();
            read_idx = (read_idx + 1) % ctx.buffer_count;
            continue;
        }

        if (engine_ptr) |engine| {
            // Render thread: beginFrame -> update -> render -> endFrame
            // No ECS queries - main thread captured snapshot for us

            const frame_info = engine.beginFrame() catch |err| {
                if (err == error.WindowClosed) break;
                if (err == error.DeviceLost) {
                    log(.ERROR, "render_thread", "FATAL: DeviceLost", .{});
                    @panic("DeviceLost - check stack trace");
                }
                log(.ERROR, "render_thread", "beginFrame failed: {}", .{err});
                ctx.main_thread_ready[read_idx].post();
                read_idx = (read_idx + 1) % ctx.buffer_count;
                continue;
            };

            frame_info.snapshot = snapshot;

            engine.update(frame_info) catch |err| {
                log(.ERROR, "render_thread", "update failed: {}", .{err});
                _ = engine.endFrame(frame_info) catch {};
                ctx.main_thread_ready[read_idx].post();
                read_idx = (read_idx + 1) % ctx.buffer_count;
                continue;
            };

            engine.render(frame_info) catch |err| {
                log(.ERROR, "render_thread", "render failed: {}", .{err});
                _ = engine.endFrame(frame_info) catch {};
                ctx.main_thread_ready[read_idx].post();
                read_idx = (read_idx + 1) % ctx.buffer_count;
                continue;
            };

            engine.endFrame(frame_info) catch |err| {
                log(.ERROR, "render_thread", "endFrame failed: {}", .{err});
                ctx.main_thread_ready[read_idx].post();
                read_idx = (read_idx + 1) % ctx.buffer_count;
                continue;
            };

            ctx.last_completed_frame.store(snapshot.frame_index, .release);
        }

        ctx.main_thread_ready[read_idx].post();
        read_idx = (read_idx + 1) % ctx.buffer_count;
    }
}
