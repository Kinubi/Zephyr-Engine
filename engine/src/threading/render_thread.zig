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

/// Context for managing the render thread and double-buffered game state.
pub const RenderThreadContext = struct {
    allocator: Allocator,
    
    // Double-buffered game state (ping-pong buffers)
    game_state: [2]GameStateSnapshot,
    current_read: std.atomic.Value(usize),  // Which buffer render thread reads (0 or 1)
    
    // Synchronization primitives
    state_ready: std.Thread.Semaphore,      // Main thread signals: new state available
    
    // Thread management
    render_thread: ?std.Thread,
    shutdown: std.atomic.Value(bool),
    
    // Shared resources (owned externally, borrowed here)
    worker_pool: *ThreadPool,
    graphics_context: *anyopaque,  // Can be *GraphicsContext or test mock
    swapchain: *anyopaque,          // Can be *Swapchain or test mock
    
    // Frame tracking
    frame_index: std.atomic.Value(u64),
    
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
            .render_thread = null,
            .shutdown = std.atomic.Value(bool).init(false),
            .worker_pool = worker_pool,
            .graphics_context = graphics_context,
            .swapchain = swapchain,
            .frame_index = std.atomic.Value(u64).init(0),
        };
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

/// Main thread function: Captures game state and signals render thread.
/// Call this from your main loop after updating game logic.
pub fn mainThreadUpdate(
    ctx: *RenderThreadContext,
    world: *ecs.World,
    camera: anytype,
    delta_time: f32,
) !void {
    // Determine which buffer to write to (the one render thread is NOT reading)
    const read_idx = ctx.current_read.load(.acquire);
    const write_idx = 1 - read_idx;
    
    // Free old snapshot in the write buffer
    if (ctx.game_state[write_idx].entity_count > 0) {
        freeSnapshot(&ctx.game_state[write_idx]);
    }
    
    // Capture new snapshot
    const frame_idx = ctx.frame_index.fetchAdd(1, .monotonic);
    ctx.game_state[write_idx] = try captureSnapshot(
        ctx.allocator,
        world,
        camera,
        frame_idx,
        delta_time,
    );
    
    // Atomically flip buffers
    ctx.current_read.store(write_idx, .release);
    
    // Signal render thread that new state is ready
    ctx.state_ready.post();
}

/// Render thread entry point - runs in separate thread.
/// This is the function that the render thread executes in a loop.
fn renderThreadLoop(ctx: *RenderThreadContext) void {
    renderThreadLoopImpl(ctx) catch |err| {
        std.log.err("Render thread crashed with error: {}", .{err});
    };
}

fn renderThreadLoopImpl(ctx: *RenderThreadContext) !void {
    while (!ctx.shutdown.load(.acquire)) {
        // Wait for main thread to signal new state
        ctx.state_ready.wait();
        
        // Check shutdown again in case we were woken to exit
        if (ctx.shutdown.load(.acquire)) break;
        
        // Get the current snapshot (lock-free read)
        const read_idx = ctx.current_read.load(.acquire);
        const snapshot = &ctx.game_state[read_idx];
        
        // Skip if snapshot is empty (shouldn't happen in normal operation)
        if (snapshot.entity_count == 0) continue;
        
        // ============================================
        // Phase 1.1: Parallel ECS Extraction (already implemented)
        // TODO: Call extractRenderablesFromSnapshot() with worker pool
        // ============================================
        
        // ============================================
        // Phase 1.2: Parallel Cache Building (already implemented)
        // TODO: Call buildCachesParallel() with worker pool
        // ============================================
        
        // ============================================
        // Command Recording (sequential for now, Phase 2.2 will parallelize)
        // TODO: 
        // 1. Acquire next swapchain image
        // 2. Begin command buffer
        // 3. Execute render graph passes
        // 4. End command buffer
        // 5. Submit to GPU
        // 6. Present
        // ============================================
        
        // Placeholder: Just log that we received a frame
        std.log.debug("Render thread processing frame {}", .{snapshot.frame_index});
        
        // Simulate some rendering work (check shutdown periodically)
        const sleep_chunks = 16; // Split 16ms into chunks
        const sleep_per_chunk = std.time.ns_per_ms;
        var i: usize = 0;
        while (i < sleep_chunks) : (i += 1) {
            if (ctx.shutdown.load(.acquire)) break;
            std.Thread.sleep(sleep_per_chunk);
        }
        
        // NOTE: Don't free snapshot here - mainThreadUpdate will free it 
        // when it overwrites this buffer with a new snapshot
    }
    
    std.log.info("Render thread shutting down gracefully", .{});
}
