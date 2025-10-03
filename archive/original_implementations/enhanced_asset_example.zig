const std = @import("std");
const EnhancedAssetManager = @import("enhanced_asset_manager.zig").EnhancedAssetManager;
const EnhancedHotReloadManager = @import("enhanced_hot_reload_manager.zig").EnhancedHotReloadManager;
const EnhancedThreadPool = @import("../threading/enhanced_thread_pool.zig").EnhancedThreadPool;
const LoadPriority = @import("enhanced_asset_manager.zig").LoadPriority;
const AssetType = @import("asset_types.zig").AssetType;
const AssetId = @import("asset_types.zig").AssetId;
const GraphicsContext = @import("../core/graphics_context.zig").GraphicsContext;

/// Example demonstrating enhanced asset manager and hot reload functionality
pub fn runEnhancedAssetExample(allocator: std.mem.Allocator, graphics_context: *GraphicsContext) !void {
    std.debug.print("=== Enhanced Asset Manager Example ===\n");

    // 1. Initialize enhanced thread pool with subsystem configuration
    var thread_pool = try EnhancedThreadPool.init(allocator, 16); // Max 16 workers
    defer thread_pool.deinit();

    // Register subsystems with thread pool
    try thread_pool.registerSubsystem("asset_loading", .{
        .max_workers = 6,
        .priority_weights = .{ .critical = 0.4, .high = 0.3, .normal = 0.2, .low = 0.1 },
    });

    try thread_pool.registerSubsystem("hot_reload", .{
        .max_workers = 2,
        .priority_weights = .{ .critical = 0.6, .high = 0.3, .normal = 0.1, .low = 0.0 },
    });

    try thread_pool.registerSubsystem("bvh_building", .{
        .max_workers = 4,
        .priority_weights = .{ .critical = 0.3, .high = 0.3, .normal = 0.3, .low = 0.1 },
    });

    // 2. Initialize enhanced asset manager
    var asset_manager = try EnhancedAssetManager.init(allocator, graphics_context, &thread_pool);
    defer asset_manager.deinit();

    std.debug.print("Enhanced asset manager initialized\n");

    // 3. Initialize hot reloading
    try asset_manager.initHotReload();
    std.debug.print("Hot reload system enabled\n");

    // 4. Demonstrate priority-based asset loading
    std.debug.print("\n--- Priority-based Asset Loading ---\n");

    // Load critical UI textures first
    const ui_texture = try asset_manager.loadAssetAsync("textures/ui/button.png", .texture, .critical);
    std.debug.print("Queued critical UI texture: {}\n", .{ui_texture});

    // Load player-visible assets with high priority
    const player_model = try asset_manager.loadAssetAsync("models/player.obj", .mesh, .high);
    const player_texture = try asset_manager.loadAssetAsync("textures/player_diffuse.png", .texture, .high);
    std.debug.print("Queued high priority player assets: model={}, texture={}\n", .{ player_model, player_texture });

    // Load background objects with normal priority
    const background_models = [_]AssetId{
        try asset_manager.loadAssetAsync("models/tree.obj", .mesh, .normal),
        try asset_manager.loadAssetAsync("models/rock.obj", .mesh, .normal),
        try asset_manager.loadAssetAsync("models/grass.obj", .mesh, .normal),
    };
    std.debug.print("Queued normal priority background assets: {any}\n", .{background_models});

    // Preload distant objects with low priority
    const distant_assets = [_]AssetId{
        try asset_manager.loadAssetAsync("models/distant_mountain.obj", .mesh, .low),
        try asset_manager.loadAssetAsync("textures/skybox.png", .texture, .low),
    };
    std.debug.print("Queued low priority distant assets: {any}\n", .{distant_assets});

    // 5. Demonstrate hot reload registration
    std.debug.print("\n--- Hot Reload Registration ---\n");

    if (asset_manager.hot_reload_manager) |*hot_reload| {
        // Register assets for hot reloading
        try hot_reload.registerAsset(ui_texture, "textures/ui/button.png", .texture);
        try hot_reload.registerAsset(player_model, "models/player.obj", .mesh);
        try hot_reload.registerAsset(player_texture, "textures/player_diffuse.png", .texture);

        std.debug.print("Registered {} assets for hot reloading\n", .{3});

        // Add reload callback
        try hot_reload.addReloadCallback(onAssetReloaded);
        std.debug.print("Added reload callback\n");
    }

    // 6. Wait for some assets to load and show statistics
    std.debug.print("\n--- Loading Progress ---\n");

    var check_count: u32 = 0;
    while (check_count < 20) { // Check for up to 2 seconds
        std.time.sleep(100_000_000); // 100ms

        const stats = asset_manager.getStatistics();
        const pool_stats = thread_pool.getStatistics();

        std.debug.print("Assets: {} total, {} completed, {} failed, {} pending | Workers: {}/{} active\n", .{ stats.total_requests, stats.completed_loads, stats.failed_loads, stats.pending_requests, pool_stats.active_workers, pool_stats.total_workers });

        // Check if critical assets are loaded
        if (asset_manager.isAssetReady(ui_texture)) {
            std.debug.print("✓ Critical UI texture loaded\n");
        }

        if (asset_manager.isAssetReady(player_model) and asset_manager.isAssetReady(player_texture)) {
            std.debug.print("✓ High priority player assets loaded\n");
            break;
        }

        check_count += 1;
    }

    // 7. Demonstrate asset retrieval with fallbacks
    std.debug.print("\n--- Asset Retrieval ---\n");

    if (asset_manager.getTexture(ui_texture)) |texture| {
        std.debug.print("Retrieved UI texture: {*}\n", .{texture});
    } else {
        std.debug.print("UI texture not ready, using fallback\n");
    }

    if (asset_manager.getModel(player_model)) |model| {
        std.debug.print("Retrieved player model: {*}\n", .{model});
    } else {
        std.debug.print("Player model not ready, using fallback\n");
    }

    // 8. Demonstrate priority calculation
    std.debug.print("\n--- Priority Calculation ---\n");

    const priorities = [_]struct { distance: f32, visible: bool, ui: bool, expected: LoadPriority }{
        .{ .distance = 5.0, .visible = true, .ui = false, .expected = .high },
        .{ .distance = 100.0, .visible = true, .ui = false, .expected = .normal },
        .{ .distance = 500.0, .visible = false, .ui = false, .expected = .low },
        .{ .distance = 1000.0, .visible = false, .ui = true, .expected = .critical },
    };

    for (priorities) |priority_test| {
        const calculated = EnhancedAssetManager.calculatePriority(priority_test.distance, priority_test.visible, priority_test.ui);
        const match = calculated == priority_test.expected;
        std.debug.print("Distance: {d:>6.1f}, Visible: {}, UI: {} → Priority: {} {s}\n", .{ priority_test.distance, priority_test.visible, priority_test.ui, calculated, if (match) "✓" else "✗" });
    }

    // 9. Final statistics
    std.debug.print("\n--- Final Statistics ---\n");

    const final_stats = asset_manager.getStatistics();
    const final_pool_stats = thread_pool.getStatistics();

    std.debug.print("Asset Manager:\n");
    std.debug.print("  Total Requests: {}\n", .{final_stats.total_requests});
    std.debug.print("  Completed: {}\n", .{final_stats.completed_loads});
    std.debug.print("  Failed: {}\n", .{final_stats.failed_loads});
    std.debug.print("  Cache Hits: {}\n", .{final_stats.cache_hits});
    std.debug.print("  Average Load Time: {d:.1f}ms\n", .{final_stats.average_load_time_ms});
    std.debug.print("  Loaded Assets: {} textures, {} models, {} materials\n", .{ final_stats.loaded_textures, final_stats.loaded_models, final_stats.loaded_materials });

    std.debug.print("\nThread Pool:\n");
    std.debug.print("  Workers: {}/{} active/total\n", .{ final_pool_stats.active_workers, final_pool_stats.total_workers });
    std.debug.print("  Tasks: {} completed, {} failed\n", .{ final_pool_stats.completed_tasks, final_pool_stats.failed_tasks });
    std.debug.print("  Queue: {} pending\n", .{final_pool_stats.queue_length});

    if (asset_manager.hot_reload_manager) |*hot_reload| {
        const reload_stats = hot_reload.getStatistics();
        std.debug.print("\nHot Reload:\n");
        std.debug.print("  Files Watched: {}\n", .{reload_stats.files_watched});
        std.debug.print("  Reload Events: {}\n", .{reload_stats.reload_events});
        std.debug.print("  Successful: {}\n", .{reload_stats.successful_reloads});
        std.debug.print("  Failed: {}\n", .{reload_stats.failed_reloads});
        std.debug.print("  Average Reload Time: {d:.1f}ms\n", .{reload_stats.average_reload_time_ms});
    }

    std.debug.print("\n=== Enhanced Asset Manager Example Complete ===\n");
}

/// Example BVH building integration
pub fn runBVHBuildingExample(allocator: std.mem.Allocator, thread_pool: *EnhancedThreadPool) !void {
    std.debug.print("\n=== BVH Building Example ===\n");

    // Request BVH workers for BLAS building
    const blas_workers = try thread_pool.requestWorkers("bvh_building", 2);
    defer thread_pool.releaseWorkers("bvh_building", blas_workers);

    std.debug.print("Allocated {} workers for BLAS building\n", .{blas_workers});

    // Submit BLAS building tasks
    const blas_count = 5;
    var blas_tasks = std.ArrayList(EnhancedThreadPool.WorkItem).init(allocator);
    defer blas_tasks.deinit();

    for (0..blas_count) |i| {
        const task = EnhancedThreadPool.WorkItem{
            .subsystem = "bvh_building",
            .priority = if (i < 2) .high else .normal, // First 2 are high priority
            .work_fn = blasBuildWorker,
            .user_data = @ptrFromInt(i), // Just pass index as demo
        };
        try blas_tasks.append(task);
        try thread_pool.submitWork(task);
    }

    std.debug.print("Submitted {} BLAS building tasks\n", .{blas_count});

    // Request TLAS worker (typically needs results from BLAS)
    const tlas_workers = try thread_pool.requestWorkers("bvh_building", 1);
    defer thread_pool.releaseWorkers("bvh_building", tlas_workers);

    // Submit TLAS building task
    const tlas_task = EnhancedThreadPool.WorkItem{
        .subsystem = "bvh_building",
        .priority = .critical, // TLAS is critical for raytracing
        .work_fn = tlasBuildWorker,
        .user_data = null,
    };
    try thread_pool.submitWork(tlas_task);

    std.debug.print("Submitted TLAS building task\n");

    // Wait for completion
    std.time.sleep(1_000_000_000); // 1 second

    const stats = thread_pool.getStatistics();
    std.debug.print("BVH building complete - {} tasks completed\n", .{stats.completed_tasks});
}

/// Callback for asset reload notifications
fn onAssetReloaded(file_path: []const u8, asset_id: AssetId, asset_type: AssetType) void {
    std.debug.print("🔄 Asset reloaded: {} ({s}) - {s}\n", .{ asset_id, @tagName(asset_type), file_path });
}

/// Example BLAS building worker
fn blasBuildWorker(user_data: ?*anyopaque) void {
    const index = @intFromPtr(user_data);
    std.debug.print("Building BLAS {} on thread {}...\n", .{ index, std.Thread.getCurrentId() });

    // Simulate BLAS building work
    std.time.sleep(200_000_000); // 200ms

    std.debug.print("✓ BLAS {} complete\n", .{index});
}

/// Example TLAS building worker
fn tlasBuildWorker(user_data: ?*anyopaque) void {
    _ = user_data;
    std.debug.print("Building TLAS on thread {}...\n", .{std.Thread.getCurrentId()});

    // Simulate TLAS building work (typically faster than BLAS)
    std.time.sleep(100_000_000); // 100ms

    std.debug.print("✓ TLAS complete\n");
}
