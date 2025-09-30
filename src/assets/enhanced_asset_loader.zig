const std = @import("std");
const vk = @import("vulkan");

// Core imports
const AssetId = @import("asset_types.zig").AssetId;
const AssetRegistry = @import("asset_registry.zig").AssetRegistry;
const GraphicsContext = @import("../core/graphics_context.zig").GraphicsContext;
const Texture = @import("../core/texture.zig").Texture;
const Model = @import("../rendering/mesh.zig").Model;
const Mesh = @import("../rendering/mesh.zig").Mesh;

// Enhanced thread pool
const EnhancedThreadPool = @import("../threading/enhanced_thread_pool.zig").EnhancedThreadPool;
const WorkItem = @import("../threading/enhanced_thread_pool.zig").WorkItem;
const WorkItemType = @import("../threading/enhanced_thread_pool.zig").WorkItemType;
const WorkPriority = @import("../threading/enhanced_thread_pool.zig").WorkPriority;
const SubsystemConfig = @import("../threading/enhanced_thread_pool.zig").SubsystemConfig;
const createAssetLoadingWork = @import("../threading/enhanced_thread_pool.zig").createAssetLoadingWork;
const createGPUWork = @import("../threading/enhanced_thread_pool.zig").createGPUWork;

// Logging
const log = @import("../utils/log.zig").log;
const LogLevel = @import("../utils/log.zig").LogLevel;

/// Forward declaration for AssetManager integration
const EnhancedAssetManager = @import("enhanced_asset_manager.zig").EnhancedAssetManager;

/// Enhanced asset loader using the new thread pool system
pub const EnhancedAssetLoader = struct {
    // Core components
    allocator: std.mem.Allocator,
    registry: *AssetRegistry,
    graphics_context: *GraphicsContext,

    // Enhanced thread pool integration
    thread_pool: *EnhancedThreadPool,
    work_id_counter: std.atomic.Value(u64),

    // Asset staging queues (thread-safe)
    texture_staging_queue: TextureStagingQueue,
    mesh_staging_queue: MeshStagingQueue,

    // Statistics and monitoring
    stats: LoaderStatistics,

    // GPU worker thread for processing staged assets
    gpu_worker_thread: ?std.Thread = null,
    gpu_worker_running: std.atomic.Value(bool),

    // GPU work serialization (prevent concurrent VkQueue access)
    gpu_queue_mutex: std.Thread.Mutex = .{},

    // Integration with asset manager
    asset_manager: *EnhancedAssetManager,

    const Self = @This();

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

    /// Thread-safe staging queue for textures
    const TextureStagingQueue = struct {
        items: std.ArrayList(TextureStaging),
        mutex: std.Thread.Mutex = .{},
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) TextureStagingQueue {
            return .{
                .items = std.ArrayList(TextureStaging){},
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *TextureStagingQueue) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            // Free image data for any remaining items
            for (self.items.items) |item| {
                self.allocator.free(item.image_data);
                self.allocator.free(item.path);
            }
            self.items.deinit(self.allocator);
        }

        pub fn push(self: *TextureStagingQueue, item: TextureStaging) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            try self.items.append(self.allocator, item);

            log(.DEBUG, "enhanced_asset_loader", "Staged texture asset {} for GPU processing", .{item.asset_id.toU64()});
        }

        pub fn pop(self: *TextureStagingQueue) ?TextureStaging {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.items.items.len > 0) {
                return self.items.orderedRemove(0);
            }
            return null;
        }

        pub fn size(self: *TextureStagingQueue) u32 {
            self.mutex.lock();
            defer self.mutex.unlock();
            const len = self.items.items.len;
            return if (len > std.math.maxInt(u32)) std.math.maxInt(u32) else @intCast(len);
        }
    };

    /// Thread-safe staging queue for meshes
    const MeshStagingQueue = struct {
        items: std.ArrayList(MeshStaging),
        mutex: std.Thread.Mutex = .{},
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) MeshStagingQueue {
            return .{
                .items = std.ArrayList(MeshStaging){},
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *MeshStagingQueue) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            // Free mesh data for any remaining items
            for (self.items.items) |item| {
                self.allocator.free(item.obj_data);
                self.allocator.free(item.path);
            }
            self.items.deinit(self.allocator);
        }

        pub fn push(self: *MeshStagingQueue, item: MeshStaging) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            try self.items.append(self.allocator, item);

            log(.DEBUG, "enhanced_asset_loader", "Staged mesh asset {} for GPU processing", .{item.asset_id.toU64()});
        }

        pub fn pop(self: *MeshStagingQueue) ?MeshStaging {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.items.items.len > 0) {
                return self.items.orderedRemove(0);
            }
            return null;
        }

        pub fn size(self: *MeshStagingQueue) u32 {
            self.mutex.lock();
            defer self.mutex.unlock();
            const len = self.items.items.len;
            return if (len > std.math.maxInt(u32)) std.math.maxInt(u32) else @intCast(len);
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
        thread_pool: *EnhancedThreadPool,
        asset_manager: *EnhancedAssetManager,
    ) !EnhancedAssetLoader {
        log(.INFO, "enhanced_asset_loader", "Initializing EnhancedAssetLoader", .{});

        // Register asset loading subsystem with thread pool (for file I/O)
        try thread_pool.registerSubsystem(SubsystemConfig{
            .name = "Enhanced Asset Loading",
            .min_workers = 2, // Always keep 2 workers ready for asset loading
            .max_workers = 6, // Can scale up to 6 workers during heavy loading
            .priority = .normal, // Normal priority by default
            .work_item_type = .asset_loading,
        });

        // Register GPU work subsystem (for GPU resource creation)
        try thread_pool.registerSubsystem(SubsystemConfig{
            .name = "GPU Asset Processing",
            .min_workers = 1, // Single worker for GPU queue serialization
            .max_workers = 1, // Only one worker for GPU operations
            .priority = .high, // High priority for GPU work
            .work_item_type = .gpu_work,
        });

        const loader = EnhancedAssetLoader{
            .allocator = allocator,
            .registry = registry,
            .graphics_context = graphics_context,
            .thread_pool = thread_pool,
            .work_id_counter = std.atomic.Value(u64).init(0),
            .texture_staging_queue = TextureStagingQueue.init(allocator),
            .mesh_staging_queue = MeshStagingQueue.init(allocator),
            .stats = LoaderStatistics.init(),
            .gpu_worker_running = std.atomic.Value(bool).init(false),
            .asset_manager = asset_manager,
        };

        log(.INFO, "enhanced_asset_loader", "EnhancedAssetLoader initialized successfully", .{});
        return loader;
    }

    /// Deinitialize the loader
    pub fn deinit(self: *Self) void {
        log(.INFO, "enhanced_asset_loader", "Shutting down EnhancedAssetLoader", .{});

        // Clean up staging queues
        self.texture_staging_queue.deinit();
        self.mesh_staging_queue.deinit();

        log(.INFO, "enhanced_asset_loader", "EnhancedAssetLoader shutdown complete", .{});
    }

    /// Set the asset manager for integration
    pub fn setAssetManager(self: *Self, asset_manager: *EnhancedAssetManager) void {
        self.asset_manager = asset_manager;
    }

    /// Request async loading of an asset with specified priority
    pub fn requestLoad(self: *Self, asset_id: AssetId, priority: WorkPriority) !void {
        // Check if asset is already loaded or loading
        if (self.registry.getAsset(asset_id)) |metadata| {
            if (metadata.state == .loaded or metadata.state == .loading) {
                log(.DEBUG, "enhanced_asset_loader", "Asset {} already loaded/loading, skipping", .{asset_id.toU64()});
                return;
            }
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
        const allocated_workers = self.thread_pool.requestWorkers(.asset_loading, requested_workers);
        log(.DEBUG, "enhanced_asset_loader", "Requested {} workers for priority {s}, allocated {}", .{ requested_workers, @tagName(priority), allocated_workers });

        // Create work item
        const work_id = self.work_id_counter.fetchAdd(1, .monotonic);
        log(.DEBUG, "enhanced_asset_loader", "asset_manager: {}", .{self.asset_manager});
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

        log(.INFO, "enhanced_asset_loader", "Submitted {s} priority load request for asset {} (work_id: {})", .{ @tagName(priority), asset_id.toU64(), work_id });
    }

    /// Request high-priority loading (for critical assets)
    pub fn requestHighPriorityLoad(self: *Self, asset_id: AssetId) !void {
        try self.requestLoad(asset_id, .high);
    }

    /// Request critical loading (for frame-critical assets)
    pub fn requestCriticalLoad(self: *Self, asset_id: AssetId) !void {
        try self.requestLoad(asset_id, .critical);
    }

    /// Get current loader statistics
    pub fn getStatistics(self: *Self) LoaderStatistics {
        // Update queue size
        self.stats.queue_size.store(self.thread_pool.work_queue.size(), .release);

        // Update active workers (simplified - could query thread pool for actual count)
        _ = self.thread_pool.getStatistics();
        self.stats.active_workers.store(self.thread_pool.current_worker_count.load(.acquire), .release);

        return self.stats;
    }

    // /// Start the GPU worker thread
    // fn startGpuWorker(self: *Self) !void {
    //     if (self.gpu_worker_running.load(.acquire)) {
    //         log(.WARN, "enhanced_asset_loader", "GPU worker already running", .{});
    //         return;
    //     }

    //     self.gpu_worker_running.store(true, .release);
    //     self.gpu_worker_thread = try std.Thread.spawn(.{}, gpuWorkerMain, .{self});

    //     log(.INFO, "enhanced_asset_loader", "GPU worker thread started", .{});
    // }

    // /// Stop the GPU worker thread
    // fn stopGpuWorker(self: *Self) void {
    //     if (!self.gpu_worker_running.load(.acquire)) {
    //         return;
    //     }

    //     self.gpu_worker_running.store(false, .release);

    //     if (self.gpu_worker_thread) |thread| {
    //         thread.join();
    //         self.gpu_worker_thread = null;
    //     }

    //     log(.INFO, "enhanced_asset_loader", "GPU worker thread stopped", .{});
    // }

    /// Process texture staging on GPU thread
    fn processTextureStaging(self: *Self, staging: *TextureStaging) !void {
        defer {
            self.allocator.free(staging.image_data);
            self.allocator.free(staging.path);
            self.allocator.destroy(staging);
        }

        // Note: Reduced logging to avoid thread safety issues with debug output
        // log(.DEBUG, "enhanced_asset_loader", "Processing texture staging for asset {} ({s})", .{ staging.asset_id.toU64(), staging.path });

        // Create Vulkan texture from image data
        var texture = try Texture.initFromMemory(
            self.graphics_context,
            self.allocator,
            staging.image_data,
            .rgba8, // Assume RGBA8 for now
        );

        // Add to asset manager if available

        log(.DEBUG, "enhanced_asset_loader", "Adding loaded texture asset {} to asset manager", .{staging.asset_id.toU64()});
        try self.asset_manager.addLoadedTexture(staging.asset_id, &texture);
        self.asset_manager.texture_descriptors_dirty = true;
        self.asset_manager.materials_dirty = true;

        // Mark asset as loaded
        self.registry.markAsLoaded(staging.asset_id, staging.image_data.len);

        // Update statistics
        _ = self.stats.completed_loads.fetchAdd(1, .monotonic);

        // Update average load time
        const current_avg = self.stats.average_load_time_us.load(.acquire);
        const new_avg = if (current_avg == 0) staging.load_time_us else (current_avg + staging.load_time_us) / 2;
        self.stats.average_load_time_us.store(new_avg, .release);

        log(.INFO, "enhanced_asset_loader", "Successfully processed texture asset {} in {}μs", .{ staging.asset_id.toU64(), staging.load_time_us });
    }

    /// Process mesh staging on GPU thread
    fn processMeshStaging(self: *Self, staging: *MeshStaging) !void {
        defer {
            self.allocator.free(staging.obj_data);
            self.allocator.free(staging.path);
            self.allocator.destroy(staging);
        }

        // Note: Reduced logging to avoid thread safety issues with debug output
        // log(.DEBUG, "enhanced_asset_loader", "Processing mesh staging for asset {} ({s})", .{ staging.asset_id.toU64(), staging.path });

        // Parse OBJ data and create Model
        const model = try Model.create(
            self.allocator,
            self.graphics_context,
            staging.obj_data,
            staging.path,
        );

        // Add to asset manager if available

        log(.DEBUG, "enhanced_asset_loader", "Adding loaded model asset {} to asset manager", .{staging.asset_id.toU64()});
        try self.asset_manager.addLoadedModel(staging.asset_id, model);

        // Mark asset as loaded
        self.registry.markAsLoaded(staging.asset_id, staging.obj_data.len);

        // Update statistics
        _ = self.stats.completed_loads.fetchAdd(1, .monotonic);

        // Update average load time
        const current_avg = self.stats.average_load_time_us.load(.acquire);
        const new_avg = if (current_avg == 0) staging.load_time_us else (current_avg + staging.load_time_us) / 2;
        self.stats.average_load_time_us.store(new_avg, .release);

        log(.INFO, "enhanced_asset_loader", "Successfully processed mesh asset {} in {}μs", .{ staging.asset_id.toU64(), staging.load_time_us });
    }

    /// Implementation of async loading logic
    pub fn performAsyncLoad(self: *EnhancedAssetLoader, asset_id: AssetId, start_time: i64) !void {
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
        } else {
            log(.ERROR, "enhanced_asset_loader", "Unknown asset type for path: {s}", .{asset_path});
            return error.UnsupportedAssetType;
        }
    }

    /// Load texture asynchronously
    fn loadTextureAsync(self: *EnhancedAssetLoader, asset_id: AssetId, path: []const u8, start_time: i64) !void {
        log(.DEBUG, "enhanced_asset_loader", "Loading texture from file: {s}", .{path});

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
            .high, // GPU work should have high priority
            gpuWorker,
            @as(*anyopaque, @ptrCast(self)),
        );

        self.registry.markAsStaged(asset_id, image_data.len);

        // Request GPU worker from thread pool
        _ = self.thread_pool.requestWorkers(.gpu_work, 1);

        // Submit to thread pool
        try self.thread_pool.submitWork(gpu_work_item);

        log(.INFO, "enhanced_asset_loader", "Loaded texture data for asset {} in {}μs, submitted for GPU processing", .{ asset_id.toU64(), load_time });
    }

    /// Load mesh asynchronously
    fn loadMeshAsync(self: *EnhancedAssetLoader, asset_id: AssetId, path: []const u8, start_time: i64) !void {
        log(.DEBUG, "enhanced_asset_loader", "Loading mesh from file: {s}", .{path});

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
            .high, // GPU work should have high priority
            gpuWorker,
            @as(*anyopaque, @ptrCast(self)),
        );

        // Request GPU worker from thread pool
        _ = self.thread_pool.requestWorkers(.gpu_work, 1);

        // Submit to thread pool
        try self.thread_pool.submitWork(gpu_work_item);

        log(.INFO, "enhanced_asset_loader", "Loaded mesh data for asset {} in {}μs, submitted for GPU processing", .{ asset_id.toU64(), load_time });
    }
};

/// Worker function called by enhanced thread pool
fn assetLoadingWorker(context: *anyopaque, work_item: WorkItem) void {
    const loader: *EnhancedAssetLoader = @ptrCast(@alignCast(context));
    const asset_data = work_item.data.asset_loading;
    const start_time = std.time.microTimestamp();

    // Note: Reduced logging to avoid thread safety issues
    // log(.DEBUG, "enhanced_asset_loader", "Worker processing asset {} (priority: {s}, work_id: {})", .{ asset_data.asset_id.toU64(), @tagName(work_item.priority), work_item.id });

    // Perform the actual loading
    loader.registry.markAsLoading(asset_data.asset_id);
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
    log(.INFO, "enhanced_asset_loader", "GPU worker thread started", .{});

    var processed_any = false;
    const loader: *EnhancedAssetLoader = @ptrCast(@alignCast(context));

    // Serialize GPU operations to prevent concurrent VkQueue access
    loader.gpu_queue_mutex.lock();
    defer loader.gpu_queue_mutex.unlock();

    // Process texture staging
    switch (work_item.data.gpu_work.staging_type) {
        .texture => {
            const staging: *EnhancedAssetLoader.TextureStaging = @ptrCast(@alignCast(work_item.data.gpu_work.data));
            loader.processTextureStaging(staging) catch |err| {
                log(.ERROR, "enhanced_asset_loader", "Failed to process texture staging for asset {}: {}", .{ staging.asset_id.toU64(), err });
                loader.registry.markAsFailed(staging.asset_id, @errorName(err));
                _ = loader.stats.failed_loads.fetchAdd(1, .monotonic);
            };
            processed_any = true;
        },
        .mesh => {
            const staging: *EnhancedAssetLoader.MeshStaging = @ptrCast(@alignCast(work_item.data.gpu_work.data));
            loader.processMeshStaging(staging) catch |err| {
                log(.ERROR, "enhanced_asset_loader", "Failed to process mesh staging for asset {}: {}", .{ staging.asset_id.toU64(), err });
                loader.registry.markAsFailed(staging.asset_id, @errorName(err));
                _ = loader.stats.failed_loads.fetchAdd(1, .monotonic);
            };
        },
    }
}
