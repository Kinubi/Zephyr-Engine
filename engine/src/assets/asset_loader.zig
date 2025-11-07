const std = @import("std");
const vk = @import("vulkan");

// Core imports
const AssetId = @import("asset_types.zig").AssetId;
const AssetRegistry = @import("asset_registry.zig").AssetRegistry;
const GraphicsContext = @import("../core/graphics_context.zig").GraphicsContext;
const Texture = @import("../core/texture.zig").Texture;
const Model = @import("../rendering/mesh.zig").Model;

// Thread pool
const ThreadPool = @import("../threading/thread_pool.zig").ThreadPool;
const WorkItem = @import("../threading/thread_pool.zig").WorkItem;
const WorkPriority = @import("../threading/thread_pool.zig").WorkPriority;
const SubsystemConfig = @import("../threading/thread_pool.zig").SubsystemConfig;
const createAssetLoadingWork = @import("../threading/thread_pool.zig").createAssetLoadingWork;
const createGPUWork = @import("../threading/thread_pool.zig").createGPUWork;

// Logging
const log = @import("../utils/log.zig").log;

/// Forward declaration for AssetManager integration
const AssetManager = @import("asset_manager.zig").AssetManager;

/// Enhanced asset loader using the new thread pool system
pub const AssetLoader = struct {
    // Core components
    allocator: std.mem.Allocator,
    registry: *AssetRegistry,
    graphics_context: *GraphicsContext,

    // Enhanced thread pool integration
    thread_pool: *ThreadPool,
    work_id_counter: std.atomic.Value(u64),

    // Statistics and monitoring
    stats: LoaderStatistics,

    // Integration with asset manager
    asset_manager: *AssetManager,

    /// Statistics for monitoring loader performance
    pub const LoaderStatistics = struct {
        total_requests: std.atomic.Value(u64),
        completed_loads: std.atomic.Value(u64),
        failed_loads: std.atomic.Value(u64),
        average_load_time_us: std.atomic.Value(u64),
        active_workers: std.atomic.Value(u32),
        queue_size: std.atomic.Value(u32),

        pub fn init() LoaderStatistics {
            return .{
                .total_requests = std.atomic.Value(u64).init(0),
                .completed_loads = std.atomic.Value(u64).init(0),
                .failed_loads = std.atomic.Value(u64).init(0),
                .average_load_time_us = std.atomic.Value(u64).init(0),
                .active_workers = std.atomic.Value(u32).init(0),
                .queue_size = std.atomic.Value(u32).init(0),
            };
        }
    };

    /// Staging data for textures loaded by worker threads
    const TextureStaging = struct {
        asset_id: AssetId,
        path: []const u8, // Owned by staging queue
        image_data: []u8, // Owned by staging queue
        load_time_us: u64,
    };

    /// Staging data for meshes loaded by worker threads
    const MeshStaging = struct {
        asset_id: AssetId,
        path: []const u8, // Owned by staging queue
        obj_data: []u8, // Owned by staging queue
        load_time_us: u64,
    };

    /// Initialize the enhanced asset loader
    pub fn init(
        allocator: std.mem.Allocator,
        registry: *AssetRegistry,
        graphics_context: *GraphicsContext,
        thread_pool: *ThreadPool,
        asset_manager: *AssetManager,
    ) !AssetLoader {
        log(.INFO, "enhanced_asset_loader", "Initializing AssetLoader", .{});

        // Register asset loading subsystem with thread pool (for file I/O)
        try thread_pool.registerSubsystem(SubsystemConfig{
            .name = "Enhanced Asset Loading",
            .min_workers = 1, // Always keep 2 workers ready for asset loading
            .max_workers = 6, // Can scale up to 6 workers during heavy loading
            .priority = .normal, // Normal priority by default
            .work_item_type = .asset_loading,
        });

        // Register GPU work subsystem (for GPU resource creation)
        try thread_pool.registerSubsystem(SubsystemConfig{
            .name = "GPU Asset Processing",
            .min_workers = 1, // Single worker for GPU queue serialization
            .max_workers = 4, // Only one worker for GPU operations
            .priority = .high, // High priority for GPU work
            .work_item_type = .gpu_work,
        });

        const loader = AssetLoader{
            .allocator = allocator,
            .registry = registry,
            .graphics_context = graphics_context,
            .thread_pool = thread_pool,
            .work_id_counter = std.atomic.Value(u64).init(0),
            .stats = LoaderStatistics.init(),
            .asset_manager = asset_manager,
        };

        log(.INFO, "enhanced_asset_loader", "AssetLoader initialized successfully", .{});
        return loader;
    }

    /// Deinitialize the loader
    pub fn deinit(self: *AssetLoader) void {
        log(.INFO, "enhanced_asset_loader", "Shutting down AssetLoader", .{});
        _ = self;

        log(.INFO, "enhanced_asset_loader", "AssetLoader shutdown complete", .{});
    }

    /// Request async loading of an asset with specified priority
    pub fn requestLoad(self: *AssetLoader, asset_id: AssetId, priority: WorkPriority) !void {
        // Atomically check and mark as loading to prevent race conditions
        if (!self.registry.markAsLoadingAtomic(asset_id)) {
            // Asset is already being processed by another thread
            return;
        }

        // Get asset path from registry (validate asset exists)
        _ = if (self.registry.getAsset(asset_id)) |metadata| metadata.path else {
            log(.ERROR, "enhanced_asset_loader", "No path found for asset {}", .{asset_id.toU64()});
            return error.AssetNotFound;
        };

        // Determine requested workers based on priority and current load
        const requested_workers: u32 = switch (priority) {
            .critical => 6, // Use maximum workers for critical assets
            .high => 4, // Use more workers for high priority
            .normal => 2, // Use normal allocation
            .low => 1, // Use minimal workers for low priority
        };

        // Request workers from thread pool
        _ = self.thread_pool.requestWorkers(.asset_loading, requested_workers);

        // Create work item
        const work_id = self.work_id_counter.fetchAdd(1, .monotonic);
        const work_item = createAssetLoadingWork(
            work_id,
            asset_id,
            @as(*anyopaque, @ptrCast(self)),
            priority,
            assetLoadingWorker,
        );

        // // Mark asset as loading
        // self.registry.markAsLoading(asset_id);

        // Submit work to thread pool
        try self.thread_pool.submitWork(work_item);

        // Update statistics
        _ = self.stats.total_requests.fetchAdd(1, .monotonic);
        self.stats.queue_size.store(self.thread_pool.work_queue.size(), .release);
    }

    /// Process texture staging on GPU thread
    fn processTextureStaging(self: *AssetLoader, staging: *TextureStaging) !void {
        defer {
            self.allocator.free(staging.image_data);
            self.allocator.free(staging.path);
            self.allocator.destroy(staging);
        }

        // Note: Reduced logging to avoid thread safety issues with debug output

        // Create Vulkan texture from image data (heap-allocated)
        const texture = try self.allocator.create(Texture);
        texture.* = try Texture.initFromMemory(
            self.graphics_context,
            self.allocator,
            staging.image_data,
            .rgba8, // Assume RGBA8 for now
        );

        // Add to asset manager if available

        try self.asset_manager.addLoadedTexture(staging.asset_id, texture);
        self.registry.markAsLoaded(staging.asset_id, staging.image_data.len);
        self.asset_manager.texture_descriptors_dirty = true;

        // Mark asset as loaded

        // Update average load time
        const current_avg = self.stats.average_load_time_us.load(.acquire);
        const new_avg = if (current_avg == 0) staging.load_time_us else (current_avg + staging.load_time_us) / 2;
        self.stats.average_load_time_us.store(new_avg, .release);

        log(.INFO, "enhanced_asset_loader", "Successfully processed texture asset {} in {}μs", .{ staging.asset_id.toU64(), staging.load_time_us });
    }

    /// Process mesh staging on GPU thread
    fn processMeshStaging(self: *AssetLoader, staging: *MeshStaging) !void {
        defer {
            self.allocator.free(staging.obj_data);
            self.allocator.free(staging.path);
            self.allocator.destroy(staging);
        }

        // Note: Reduced logging to avoid thread safety issues with debug output

        // Parse OBJ data and create Model
        const model = try Model.create(
            self.allocator,
            self.graphics_context,
            staging.obj_data,
            staging.path,
        );

        // Add to asset manager if available

        try self.asset_manager.addLoadedModel(staging.asset_id, model);

        // Mark asset as loaded
        self.registry.markAsLoaded(staging.asset_id, staging.obj_data.len);

        // Update average load time
        const current_avg = self.stats.average_load_time_us.load(.acquire);
        const new_avg = if (current_avg == 0) staging.load_time_us else (current_avg + staging.load_time_us) / 2;
        self.stats.average_load_time_us.store(new_avg, .release);

        log(.INFO, "enhanced_asset_loader", "Successfully processed mesh asset {} in {}μs", .{ staging.asset_id.toU64(), staging.load_time_us });
    }

    /// Implementation of async loading logic
    pub fn performAsyncLoad(self: *AssetLoader, asset_id: AssetId, start_time: i64) !void {
        // Get asset path
        const asset_path = if (self.registry.getAsset(asset_id)) |metadata| metadata.path else {
            return error.AssetNotFound;
        };

        // Determine asset type from file extension
        if (std.mem.endsWith(u8, asset_path, ".png") or
            std.mem.endsWith(u8, asset_path, ".jpg") or
            std.mem.endsWith(u8, asset_path, ".jpeg"))
        {
            try self.loadTextureAsync(asset_id, asset_path, start_time);
        } else if (std.mem.endsWith(u8, asset_path, ".obj") or
            std.mem.endsWith(u8, asset_path, ".gltf"))
        {
            try self.loadMeshAsync(asset_id, asset_path, start_time);
        } else if (std.mem.endsWith(u8, asset_path, ".lua") or
            std.mem.endsWith(u8, asset_path, ".txt") or
            std.mem.endsWith(u8, asset_path, ".zs"))
        {
            try self.loadScriptAsync(asset_id, asset_path, start_time);
        } else {
            log(.ERROR, "enhanced_asset_loader", "Unknown asset type for path: {s}", .{asset_path});
            return error.UnsupportedAssetType;
        }
    }

    /// Load script asynchronously (reads file and registers script with AssetManager)
    fn loadScriptAsync(self: *AssetLoader, asset_id: AssetId, path: []const u8, start_time: i64) !void {
        const data = std.fs.cwd().readFileAlloc(self.allocator, path, 64 * 1024) catch |err| {
            log(.ERROR, "enhanced_asset_loader", "Failed to read script file {s}: {}", .{ path, err });
            return err;
        };

        const end_time = std.time.microTimestamp();
        const load_time = if (end_time >= start_time) @as(u64, @intCast(end_time - start_time)) else 0;

        // Add script to AssetManager (it will duplicate into its own allocator)
        self.asset_manager.addLoadedScript(asset_id, data) catch |err| {
            log(.ERROR, "enhanced_asset_loader", "Failed to add script asset {}: {}", .{ asset_id.toU64(), err });
            // Free local buffer
            self.allocator.free(data);
            self.registry.markAsFailed(asset_id, @errorName(err));
            return err;
        };

        // Free local buffer - AssetManager duplicates the content
        self.allocator.free(data);

        // Update statistics
        const current_avg = self.stats.average_load_time_us.load(.acquire);
        const new_avg = if (current_avg == 0) load_time else (current_avg + load_time) / 2;
        self.stats.average_load_time_us.store(new_avg, .release);

        log(.INFO, "enhanced_asset_loader", "Loaded script asset {} in {}μs", .{ asset_id.toU64(), load_time });
    }

    /// Load texture asynchronously
    fn loadTextureAsync(self: *AssetLoader, asset_id: AssetId, path: []const u8, start_time: i64) !void {
        // Read image file data
        const image_data = std.fs.cwd().readFileAlloc(self.allocator, path, 100 * 1024 * 1024) catch |err| {
            log(.ERROR, "enhanced_asset_loader", "Failed to read texture file {s}: {}", .{ path, err });
            return err;
        };

        const end_time = std.time.microTimestamp();
        const load_time = if (end_time >= start_time) @as(u64, @intCast(end_time - start_time)) else 0;

        // Create staging entry
        const staging = try self.allocator.create(TextureStaging);
        staging.* = TextureStaging{
            .asset_id = asset_id,
            .path = try self.allocator.dupe(u8, path),
            .image_data = image_data,
            .load_time_us = load_time,
        };

        // Submit GPU work to thread pool instead of staging queue
        const work_id = self.work_id_counter.fetchAdd(1, .monotonic);
        const gpu_work_item = createGPUWork(
            work_id,
            .texture,
            asset_id,
            @as(*anyopaque, @ptrCast(staging)),
            .critical, // GPU work should have high priority
            gpuWorker,
            @as(*anyopaque, @ptrCast(self)),
        );

        self.registry.markAsStaged(asset_id, image_data.len);

        // Request GPU worker from thread pool
        _ = self.thread_pool.requestWorkers(.gpu_work, 2);

        // Submit to thread pool
        try self.thread_pool.submitWork(gpu_work_item);

        log(.INFO, "enhanced_asset_loader", "Loaded texture data for asset {} in {}μs, submitted for GPU processing", .{ asset_id.toU64(), load_time });
    }

    /// Load mesh asynchronously
    fn loadMeshAsync(self: *AssetLoader, asset_id: AssetId, path: []const u8, start_time: i64) !void {
        // Read OBJ file data
        const obj_data = std.fs.cwd().readFileAlloc(self.allocator, path, 100 * 1024 * 1024) catch |err| {
            log(.ERROR, "enhanced_asset_loader", "Failed to read mesh file {s}: {}", .{ path, err });
            return err;
        };

        const end_time = std.time.microTimestamp();
        const load_time = if (end_time >= start_time) @as(u64, @intCast(end_time - start_time)) else 0;

        // Create staging entry
        const staging = try self.allocator.create(MeshStaging);
        staging.* = MeshStaging{
            .asset_id = asset_id,
            .path = try self.allocator.dupe(u8, path),
            .obj_data = obj_data,
            .load_time_us = load_time,
        };

        // Submit GPU work to thread pool instead of staging queue
        const work_id = self.work_id_counter.fetchAdd(1, .monotonic);
        const gpu_work_item = createGPUWork(
            work_id,
            .mesh,
            asset_id,
            @as(*anyopaque, @ptrCast(staging)),
            .critical, // GPU work should have high priority
            gpuWorker,
            @as(*anyopaque, @ptrCast(self)),
        );

        // Request GPU worker from thread pool
        _ = self.thread_pool.requestWorkers(.gpu_work, 2);

        // Submit to thread pool
        try self.thread_pool.submitWork(gpu_work_item);

        log(.INFO, "enhanced_asset_loader", "Loaded mesh data for asset {} in {}μs, submitted for GPU processing", .{ asset_id.toU64(), load_time });
    }
};

/// Worker function called by enhanced thread pool
fn assetLoadingWorker(context: *anyopaque, work_item: WorkItem) void {
    const loader: *AssetLoader = @ptrCast(@alignCast(context));
    const asset_data = work_item.data.asset_loading;
    const start_time = std.time.microTimestamp();

    // Note: Reduced logging to avoid thread safety issues

    // Asset is already marked as loading atomically in requestLoad, so we can proceed directly
    loader.performAsyncLoad(asset_data.asset_id, start_time) catch |err| {
        log(.ERROR, "enhanced_asset_loader", "Failed to load asset {}: {}", .{ asset_data.asset_id.toU64(), err });

        loader.registry.markAsFailed(asset_data.asset_id, @errorName(err));
        _ = loader.stats.failed_loads.fetchAdd(1, .monotonic);
        return;
    };

    const end_time = std.time.microTimestamp();
    const duration = if (end_time >= start_time) @as(u64, @intCast(end_time - start_time)) else 0;

    log(.INFO, "enhanced_asset_loader", "Worker completed asset {} in {}μs", .{ asset_data.asset_id.toU64(), duration });
}

fn gpuWorker(context: *anyopaque, work_item: WorkItem) void {
    // Reduced logging to prevent spam - only log when we actually process work
    var processed_any = false;
    const loader: *AssetLoader = @ptrCast(@alignCast(context));

    // Process texture staging
    switch (work_item.data.gpu_work.staging_type) {
        .texture => {
            const staging: *AssetLoader.TextureStaging = @ptrCast(@alignCast(work_item.data.gpu_work.data));
            loader.processTextureStaging(staging) catch |err| {
                log(.ERROR, "enhanced_asset_loader", "Failed to process texture staging for asset {}: {}", .{ staging.asset_id.toU64(), err });
                loader.registry.markAsFailed(staging.asset_id, @errorName(err));
                _ = loader.stats.failed_loads.fetchAdd(1, .monotonic);
            };
            processed_any = true;
        },
        .mesh => {
            const staging: *AssetLoader.MeshStaging = @ptrCast(@alignCast(work_item.data.gpu_work.data));
            loader.processMeshStaging(staging) catch |err| {
                log(.ERROR, "enhanced_asset_loader", "Failed to process mesh staging for asset {}: {}", .{ staging.asset_id.toU64(), err });
                loader.registry.markAsFailed(staging.asset_id, @errorName(err));
                _ = loader.stats.failed_loads.fetchAdd(1, .monotonic);
            };
            processed_any = true;
        },
        .shader_rebuild => {
            // Shader rebuilds are not handled by asset_loader - they use a different worker
            // This case should never be reached in the asset loader's GPU worker
            log(.ERROR, "enhanced_asset_loader", "Unexpected shader_rebuild work in asset loader GPU worker!", .{});
        },
    }
}
