const std = @import("std");
const asset_types = @import("asset_types.zig");
const asset_registry = @import("asset_registry.zig");
const log = @import("../utils/log.zig").log;
const vk = @import("vulkan");

// Import rendering types for actual asset loading
const Model = @import("../rendering/mesh.zig").Model;
const Texture = @import("../core/texture.zig").Texture;
const GraphicsContext = @import("../core/graphics_context.zig").GraphicsContext;
const EnhancedScene = @import("../scene/scene_enhanced.zig").EnhancedScene;

// Import utility functions
const loadFileAlloc = @import("../utils/file.zig").loadFileAlloc;

const AssetId = asset_types.AssetId;
const AssetType = asset_types.AssetType;
const AssetState = asset_types.AssetState;
const LoadRequest = asset_types.LoadRequest;
const LoadResult = asset_types.LoadResult;
const AssetRegistry = asset_registry.AssetRegistry;
const AssetManager = @import("asset_manager.zig").AssetManager;

// Import the new ThreadPool implementation
const ThreadPool = @import("../threading/thread_pool.zig").ThreadPool;
const WorkItem = @import("../threading/thread_pool.zig").WorkItem;

// Staging struct for mesh data loaded on worker thread
const MeshStaging = struct {
    asset_id: AssetId,
    path: []const u8,
    obj_data: []u8, // Raw OBJ file contents
};

// GPU worker thread implementation (takes GpuWorkerContext)
fn gpuWorkerThread(ctx: *GpuWorkerContext) void {
    const loader = ctx.loader;
    const asset_manager = ctx.asset_manager;

    std.log.info("GPU Worker Thread: Starting up and ready to process staging queue", .{});

    while (loader.gpu_running.load(.acquire)) {
        var processed = false;
        const q = loader.completed_queue;
        if (q.popTexture()) |staging| {
            std.log.info("GPU Worker: Processing texture staging for asset {} ({s})", .{ staging.asset_id.toU64(), staging.path });
            loader.registry.markAsLoading(staging.asset_id);
            const texture = loader.processCompletedTextureFromStaging(staging) catch |err| {
                loader.registry.markAsFailed(staging.asset_id, @errorName(err));
                continue;
            };
            asset_manager.addLoadedTexture(staging.asset_id, texture) catch |err| {
                loader.registry.markAsFailed(staging.asset_id, @errorName(err));
            };
            // Set dirty flag after texture is loaded
            asset_manager.materials_dirty = true; // Mark materials as dirty when textures change
            loader.registry.markAsLoaded(staging.asset_id, staging.img_data.len);
            std.log.info("GPU Worker: Completed processing texture asset {} and marked materials dirty", .{staging.asset_id.toU64()});

            processed = true;
        }
        if (q.popMesh()) |staging| {
            loader.registry.markAsLoading(staging.asset_id);
            const model_ptr = loader.processCompletedMeshFromStaging(staging) catch |err| {
                loader.registry.markAsFailed(staging.asset_id, @errorName(err));
                continue;
            };
            asset_manager.addLoadedModel(staging.asset_id, model_ptr) catch |err| {
                loader.registry.markAsFailed(staging.asset_id, @errorName(err));
            };
            loader.registry.markAsLoaded(staging.asset_id, staging.obj_data.len);
            processed = true;
        }

        if (!processed) std.Thread.sleep(std.time.ns_per_ms * 2);
    }
}

// Staging struct for texture data loaded on worker thread
const TextureStaging = struct {
    asset_id: AssetId,
    path: []const u8,
    img_data: []u8, // Raw image file contents
};

// Thread-safe queue for completed asset loads (to be processed on main thread)
const CompletedLoadQueue = struct {
    allocator: std.mem.Allocator,
    mesh_queue: std.ArrayList(MeshStaging),
    texture_queue: std.ArrayList(TextureStaging),
    // Index maps for efficient lookups by AssetId
    mesh_index: std.HashMap(AssetId, usize, std.hash_map.AutoContext(AssetId), 80),
    texture_index: std.HashMap(AssetId, usize, std.hash_map.AutoContext(AssetId), 80),
    mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator) CompletedLoadQueue {
        return CompletedLoadQueue{
            .allocator = allocator,
            .mesh_queue = std.ArrayList(MeshStaging){},
            .texture_queue = std.ArrayList(TextureStaging){},
            .mesh_index = std.HashMap(AssetId, usize, std.hash_map.AutoContext(AssetId), 80).init(allocator),
            .texture_index = std.HashMap(AssetId, usize, std.hash_map.AutoContext(AssetId), 80).init(allocator),
        };
    }

    pub fn deinit(self: *CompletedLoadQueue) void {
        self.mesh_queue.deinit(self.allocator);
        self.texture_queue.deinit(self.allocator);
        self.mesh_index.deinit();
        self.texture_index.deinit();
    }

    pub fn pushMesh(self: *CompletedLoadQueue, mesh: MeshStaging) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const index = self.mesh_queue.items.len;
        self.mesh_queue.append(self.allocator, mesh) catch |err| {
            log(.ERROR, "CompletedLoadQueue", "Failed to push mesh: asset_id={d}, err={}", .{ mesh.asset_id.toU64(), err });
            return;
        };
        self.mesh_index.put(mesh.asset_id, index) catch |err| {
            log(.ERROR, "CompletedLoadQueue", "Failed to index mesh: asset_id={d}, err={}", .{ mesh.asset_id.toU64(), err });
        };
    }

    pub fn pushTexture(self: *CompletedLoadQueue, tex: TextureStaging) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        std.log.info("CompletedLoadQueue: Pushing texture asset {} to GPU queue", .{tex.asset_id.toU64()});
        const index = self.texture_queue.items.len;
        self.texture_queue.append(self.allocator, tex) catch |err| {
            log(.ERROR, "CompletedLoadQueue", "Failed to push texture: asset_id={d}, err={}", .{ tex.asset_id.toU64(), err });
            return;
        };
        self.texture_index.put(tex.asset_id, index) catch |err| {
            log(.ERROR, "CompletedLoadQueue", "Failed to index texture: asset_id={d}, err={}", .{ tex.asset_id.toU64(), err });
        };
        std.log.info("CompletedLoadQueue: Successfully queued texture asset {} for GPU processing", .{tex.asset_id.toU64()});
    }

    /// Get a mesh by asset_id (does not remove)
    pub fn getMesh(self: *CompletedLoadQueue, asset_id: AssetId) ?MeshStaging {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.mesh_index.get(asset_id)) |index| {
            if (index < self.mesh_queue.items.len) {
                return self.mesh_queue.items[index];
            }
        }
        return null;
    }

    /// Get a texture by asset_id (does not remove)
    pub fn getTexture(self: *CompletedLoadQueue, asset_id: AssetId) ?TextureStaging {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.texture_index.get(asset_id)) |index| {
            if (index < self.texture_queue.items.len) {
                return self.texture_queue.items[index];
            }
        }
        return null;
    }

    /// Pop any one texture staging entry (remove and return) or null if empty
    pub fn popTexture(self: *CompletedLoadQueue) ?TextureStaging {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.texture_queue.items.len > 0) {
            const staging = self.texture_queue.orderedRemove(0);
            // Update all indices since we removed from front
            self.updateTextureIndicesAfterRemoval();
            std.log.info("CompletedLoadQueue: GPU worker popping texture asset {} from queue", .{staging.asset_id.toU64()});
            return staging;
        }
        return null;
    }

    /// Pop any one mesh staging entry (remove and return) or null if empty
    pub fn popMesh(self: *CompletedLoadQueue) ?MeshStaging {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.mesh_queue.items.len > 0) {
            const staging = self.mesh_queue.orderedRemove(0);
            // Update all indices since we removed from front
            self.updateMeshIndicesAfterRemoval();
            return staging;
        }
        return null;
    }

    // Helper function to update indices after removing from front
    fn updateTextureIndicesAfterRemoval(self: *CompletedLoadQueue) void {
        self.texture_index.clearRetainingCapacity();
        for (self.texture_queue.items, 0..) |item, i| {
            self.texture_index.put(item.asset_id, i) catch {};
        }
    }

    // Helper function to update indices after removing from front
    fn updateMeshIndicesAfterRemoval(self: *CompletedLoadQueue) void {
        self.mesh_index.clearRetainingCapacity();
        for (self.mesh_queue.items, 0..) |item, i| {
            self.mesh_index.put(item.asset_id, i) catch {};
        }
    }
};

const GpuWorkerContext = struct {
    loader: *AssetLoader,
    asset_manager: *AssetManager,
};

// Worker function for the ThreadPool
fn assetWorkerThread(pool: *ThreadPool, worker_id: usize) void {
    // Mark this thread as ready
    pool.markThreadReady(worker_id);

    while (pool.running) {
        // Try to get a job
        if (pool.getWork()) |work_item| {
            std.log.info("Asset Worker Thread {}: Got work item for asset {}", .{ worker_id, work_item.asset_id.toU64() });
            // Cast the loader pointer back to AssetLoader
            const loader: *AssetLoader = @ptrCast(@alignCast(work_item.loader));

            // Execute job
            loader.performLoadAsync(work_item.asset_id) catch |err| {
                std.log.err("Asset Worker Thread {}: Failed to load asset {}: {}", .{ worker_id, work_item.asset_id.toU64(), err });
                // Log error and mark asset as failed

                // Convert error to string for registry
                var error_buf: [256]u8 = undefined;
                const error_msg = std.fmt.bufPrint(&error_buf, "Async loading error: {}", .{err}) catch "Unknown async loading error";
                loader.registry.markAsFailed(work_item.asset_id, error_msg);

                // Update failed loads counter
                _ = @atomicRmw(u32, &loader.failed_loads, .Add, 1, .monotonic);
            };
            std.log.info("Asset Worker Thread {}: Completed work for asset {}", .{ worker_id, work_item.asset_id.toU64() });
        } else {
            // No job available, sleep briefly to avoid busy waiting
            std.Thread.sleep(std.time.ns_per_ms * 1); // 1ms sleep
        }
    }

    // Mark this thread as shutting down
    pool.markThreadShuttingDown(worker_id);
}

/// Asset loader that manages the loading pipeline
/// Supports dependency resolution, sync loading, and async loading with thread pool
pub const AssetLoader = struct {
    // Core components
    registry: *AssetRegistry,
    allocator: std.mem.Allocator,
    graphics_context: *GraphicsContext,

    // Async loading thread pool (heap allocated to prevent move corruption)
    thread_pool: ?*ThreadPool = null,
    async_enabled: bool = false,

    // Statistics
    active_loads: u32 = 0,
    completed_loads: u32 = 0,
    failed_loads: u32 = 0,

    // Queue for completed loads (for main-thread GPU upload)
    completed_queue: *CompletedLoadQueue,

    // GPU worker thread for performing GPU uploads off the main thread
    gpu_thread: ?*std.Thread = null,
    gpu_context: ?*GpuWorkerContext = null,
    gpu_running: std.atomic.Value(bool),

    // Callback for texture array updates
    texture_array_update_callback: ?*const fn () void = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, registry: *AssetRegistry, graphics_context: *GraphicsContext, max_threads: u32) !Self {
        // Allocate ThreadPool on heap if needed
        const thread_pool = if (max_threads > 0) blk: {
            const pool_ptr = try allocator.create(ThreadPool);
            pool_ptr.* = try ThreadPool.init(allocator, max_threads, assetWorkerThread);
            // Start the ThreadPool after initialization
            try pool_ptr.start();
            break :blk pool_ptr;
        } else null;

        // Allocate completed_queue on heap
        const completed_queue_ptr = try allocator.create(CompletedLoadQueue);
        completed_queue_ptr.* = CompletedLoadQueue.init(allocator);

        const result = Self{
            .registry = registry,
            .allocator = allocator,
            .graphics_context = graphics_context,
            .thread_pool = thread_pool,
            .async_enabled = max_threads > 0,
            .completed_queue = completed_queue_ptr,
            .gpu_thread = null,
            .gpu_running = std.atomic.Value(bool).init(false),
        };

        // Don't start GPU worker here: caller (AssetManager) will start it after
        // the loader is heap-allocated so the thread function may safely take
        // a stable pointer to the loader.
        return result;
    }

    pub fn startGpuWorker(self: *Self, asset_manager: *AssetManager) !void {
        if (self.gpu_thread != null) return; // already running
        self.gpu_running.store(true, .release);
        const tptr = try self.allocator.create(std.Thread);
        // Heap-allocate the context with proper alignment for thread safety
        const ctx = try self.allocator.create(GpuWorkerContext);
        errdefer self.allocator.destroy(ctx);
        ctx.* = GpuWorkerContext{ .loader = self, .asset_manager = asset_manager };

        tptr.* = try std.Thread.spawn(.{}, gpuWorkerThread, .{ctx});
        self.gpu_thread = tptr;
        self.gpu_context = ctx;
    }

    pub fn stopGpuWorker(self: *Self) void {
        if (self.gpu_thread) |t| {
            self.gpu_running.store(false, .release);
            t.join();
            self.allocator.destroy(t);
            self.gpu_thread = null;
        }
        if (self.gpu_context) |ctx| {
            self.allocator.destroy(ctx);
            self.gpu_context = null;
        }
    }

    pub fn deinit(self: *Self) void {
        // Clean up thread pool first
        if (self.thread_pool) |pool| {
            pool.deinit();
            self.allocator.destroy(pool);
        }

        // Stop GPU worker if running
        if (self.gpu_thread) |t| {
            self.gpu_running.store(false, .release);
            t.join();
            self.allocator.destroy(t);
            self.gpu_thread = null;
        }

        // Free completed queue
        const q = self.completed_queue;
        q.deinit();
        self.allocator.destroy(q);
    }

    /// Set callback for ThreadPool running status changes
    pub fn setThreadPoolCallback(self: *Self, callback: *const fn (bool) void) void {
        if (self.thread_pool) |pool| {
            pool.setOnRunningChangedCallback(callback);
        }
    }

    /// Process a mesh staging entry that was popped by the GPU worker
    pub fn processCompletedMeshFromStaging(self: *Self, staging: MeshStaging) !*Model {
        // Create model directly on heap to avoid ownership transfer issues
        const model_ptr = Model.create(self.allocator, self.graphics_context, staging.obj_data, staging.path) catch |err| {
            log(.ERROR, "asset_loader", "Failed to create Model from OBJ on GPU worker for asset {d}: {}", .{ staging.asset_id.toU64(), err });
            return err;
        };
        return model_ptr;
    }

    /// Process a texture staging entry that was popped by the GPU worker
    pub fn processCompletedTextureFromStaging(self: *Self, staging: TextureStaging) !*Texture {
        const texture = Texture.initFromMemory(self.graphics_context, self.allocator, staging.img_data, .rgba8) catch |err| {
            log(.ERROR, "asset_loader", "Failed to create Texture from memory on GPU worker for asset {d}: {}", .{ staging.asset_id.toU64(), err });
            return err;
        };

        // Allocate texture on heap to avoid dangling pointer
        const texture_ptr = self.allocator.create(Texture) catch |err| {
            log(.ERROR, "asset_loader", "Failed to allocate texture for asset {d}: {}", .{ staging.asset_id.toU64(), err });
            return err;
        };
        texture_ptr.* = texture;

        return texture_ptr;
    }

    /// Set callback for ThreadPool running status changes
    /// Request an asset to be loaded
    pub fn requestLoad(self: *Self, asset_id: AssetId) !void {
        // Check if asset exists in registry
        const asset = self.registry.getAsset(asset_id) orelse return error.AssetNotRegistered;
        // Skip if already loaded or loading
        switch (asset.state) {
            .loaded => return,
            .loading => {
                return;
            },
            .unloaded, .failed => {},
            .staged => {
                return;
            }, // Already staged, waiting for main-thread processing
        }

        // Mark as loading
        self.registry.markAsLoading(asset_id);

        // Use async loading if available, otherwise process synchronously
        if (self.async_enabled and self.thread_pool != null) {
            // Check if thread pool has available workers
            if (!self.thread_pool.?.hasAvailableWorkers()) {
                log(.WARN, "asset_loader", "No worker threads available, falling back to sync load for asset {d}", .{asset_id});
                try self.performLoad(asset_id);
                return;
            }

            // Submit to thread pool, with fallback to sync loading on error
            const work_item = WorkItem{ .asset_id = asset_id, .loader = self };
            self.thread_pool.?.submitWork(work_item) catch |err| switch (err) {
                error.ThreadPoolNotRunning, error.NoWorkerThreadsAvailable => {
                    log(.WARN, "asset_loader", "Thread pool unavailable ({any}), falling back to sync load for asset {d}", .{ err, asset_id });
                    try self.performLoad(asset_id);
                },
                else => return err,
            };
        } else {
            try self.performLoad(asset_id);
        }
    }

    /// Load an asset synchronously (blocks until complete)
    pub fn loadSync(self: *Self, asset_id: AssetId) !void {
        const asset = self.registry.getAsset(asset_id) orelse return error.AssetNotRegistered;

        // Skip if already loaded
        if (asset.state == .loaded) return;

        // Perform the actual load
        try self.performLoad(asset_id);
    }

    /// Request an asset to be loaded asynchronously (non-blocking)
    pub fn loadAsync(self: *Self, asset_id: AssetId) !void {
        return self.requestLoad(asset_id);
    }

    /// Wait for an asset to finish loading (blocks until complete)
    pub fn waitForAsset(self: *Self, asset_id: AssetId) void {
        const asset = self.registry.getAsset(asset_id) orelse return;

        // Poll until asset is loaded or failed
        while (asset.state == .loading) {
            std.Thread.sleep(1_000_000); // 1ms
        }
    }

    /// Check if async loading is enabled
    pub fn isAsyncEnabled(self: *const Self) bool {
        return self.async_enabled;
    }

    /// Check if async loading is available and ready
    pub fn isAsyncReady(self: *const Self) bool {
        if (!self.async_enabled or self.thread_pool == null) return false;
        return self.thread_pool.?.hasAvailableWorkers();
    }

    /// Get current loading statistics
    pub fn getLoadingStats(self: *const Self) struct {
        active_loads: u32,
        completed_loads: u32,
        failed_loads: u32,
    } {
        return .{
            .active_loads = @atomicLoad(u32, &self.active_loads, .monotonic),
            .completed_loads = @atomicLoad(u32, &self.completed_loads, .monotonic),
            .failed_loads = @atomicLoad(u32, &self.failed_loads, .monotonic),
        };
    }

    /// Perform the actual asset loading (synchronous)
    fn performLoad(self: *Self, asset_id: AssetId) !void {
        self.active_loads += 1;
        defer self.active_loads -= 1;

        const asset = self.registry.getAsset(asset_id) orelse return error.AssetNotFound;

        // Load dependencies first
        for (asset.dependencies.items) |dep_id| {
            const dependency = self.registry.getAsset(dep_id) orelse continue;
            if (dependency.state != .loaded) {
                try self.performLoad(dep_id);
            }
        }

        // Simulate actual file loading based on asset type
        const file_size = try self.loadAssetFromDisk(asset);

        // Mark as loaded
        self.registry.markAsLoaded(asset_id, file_size);
        self.completed_loads += 1;
    }

    /// Perform the actual asset loading (asynchronous - called from worker threads)
    fn performLoadAsync(self: *Self, asset_id: AssetId) !void {
        // Use atomic increment for thread safety
        _ = @atomicRmw(u32, &self.active_loads, .Add, 1, .monotonic);
        defer _ = @atomicRmw(u32, &self.active_loads, .Sub, 1, .monotonic);

        const asset = self.registry.getAsset(asset_id) orelse return error.AssetNotFound;

        // Simulate actual file loading based on asset type
        const file_size = try self.loadAssetFromDisk(asset);

        // Mark as loaded (thread-safe)
        // Mark as staged after successfully loading from disk
        self.registry.markAsStaged(asset.id, file_size);

        // Main-thread processing: convert staging to final asset and store

        _ = @atomicRmw(u32, &self.completed_loads, .Add, 1, .monotonic);

        // IMPORTANT: Do NOT call the completion callback from the worker thread.
        // The staging entry for GPU uploads must be processed on the main thread
        // where Vulkan single-threaded helpers are allowed. The main thread will
        // call the completion callback after processing the staging entry.
    }

    /// Real implementation of asset loading from disk
    fn loadAssetFromDisk(self: *Self, asset: *const asset_types.AssetMetadata) !u64 {
        switch (asset.asset_type) {
            .mesh => {
                return try self.loadMeshFromDisk(asset, self.completed_queue);
            },
            .texture => {
                return try self.loadTextureFromDisk(asset, self.completed_queue);
            },
            .material, .shader, .audio, .scene, .animation => {
                // For now, simulate these asset types until we implement them
                log(.WARN, "asset_loader", "Asset type {} not yet implemented, using mock loading", .{asset.asset_type});
                const mock_size: u64 = switch (asset.asset_type) {
                    .material => 4 * 1024, // 4KB
                    .shader => 16 * 1024, // 16KB
                    .audio => 2 * 1024 * 1024, // 2MB
                    .scene => 256 * 1024, // 256KB
                    .animation => 128 * 1024, // 128KB
                    else => unreachable,
                };
                std.Thread.sleep(50_000_000); // 50ms simulated loading
                return mock_size;
            },
        }
    }

    /// Load a mesh asset from disk (worker thread): only loads file data, does not create GPU resources
    fn loadMeshFromDisk(self: *Self, asset: *const asset_types.AssetMetadata, completed_queue: *CompletedLoadQueue) !u64 {
        // Load OBJ file contents into memory (max 10MB)
        const obj_data = loadFileAlloc(self.allocator, asset.path, 10 * 1024 * 1024) catch |err| {
            log(.ERROR, "asset_loader", "Failed to load mesh file {s}: {}", .{ asset.path, err });
            return err;
        };

        // Push to completed queue for main thread to process
        completed_queue.pushMesh(MeshStaging{
            .asset_id = asset.id,
            .path = asset.path,
            .obj_data = obj_data,
        });
        log(.INFO, "asset_loader", "[Worker] Queued mesh for GPU upload: {s}", .{asset.path});
        return obj_data.len;
    }

    /// Load a texture asset from disk (worker thread): only loads file data, does not create GPU resources
    fn loadTextureFromDisk(self: *Self, asset: *const asset_types.AssetMetadata, completed_queue: *CompletedLoadQueue) !u64 {
        std.log.warn("loadTextureFromDisk: Starting load for asset {} path '{s}'", .{ asset.id.toU64(), asset.path });
        // Load the texture directly using Texture.initFromFile
        const img_data = loadFileAlloc(self.allocator, asset.path, 10 * 1024 * 1024) catch |err| {
            std.log.err("loadTextureFromDisk: FAILED to load texture file '{s}' for asset {}: {}", .{ asset.path, asset.id.toU64(), err });
            log(.ERROR, "asset_loader", "Failed to load texture file {s}: {}", .{ asset.path, err });
            return err;
        };
        std.log.warn("loadTextureFromDisk: Successfully loaded {} bytes from '{s}' for asset {}", .{ img_data.len, asset.path, asset.id.toU64() });
        // Push the loaded texture to the completed queue
        completed_queue.pushTexture(TextureStaging{
            .asset_id = asset.id,
            .path = asset.path,
            .img_data = img_data,
        });
        std.log.warn("loadTextureFromDisk: Queued texture staging for asset {} path '{s}'", .{ asset.id.toU64(), asset.path });
        log(.INFO, "asset_loader", "[Worker] Loaded and queued texture: {s}", .{asset.path});
        // Return a dummy size (actual size not tracked here)
        return 0;
    }

    /// Get current loading statistics
    pub fn getStatistics(self: *Self) LoaderStatistics {
        return LoaderStatistics{
            .active_loads = self.active_loads,
            .completed_loads = self.completed_loads,
            .failed_loads = self.failed_loads,
        };
    }

    /// Wait for all pending loads to complete (simplified for sync version)
    pub fn waitForCompletion(self: *Self) void {
        // In synchronous mode, everything is already complete when this is called
        _ = self;
    }
};

/// Statistics for the asset loader
pub const LoaderStatistics = struct {
    active_loads: u32,
    completed_loads: u32,
    failed_loads: u32,

    pub fn getTotalProcessed(self: LoaderStatistics) u32 {
        return self.completed_loads + self.failed_loads;
    }
};

// Tests
test "AssetLoader basic functionality" {
    var registry = AssetRegistry.init(std.testing.allocator);
    defer registry.deinit();

    // Register a test asset (using actual file)
    const texture_id = try registry.registerAsset("missing.png", .texture);

    // Create loader
    var loader = try AssetLoader.init(std.testing.allocator, &registry, 2);
    defer loader.deinit();

    // Load synchronously
    try loader.loadSync(texture_id);

    // Check that asset is loaded
    const asset = registry.getAsset(texture_id).?;
    try std.testing.expectEqual(AssetState.loaded, asset.state);
    try std.testing.expect(asset.file_size > 0);
}

test "AssetLoader async loading" {
    var registry = AssetRegistry.init(std.testing.allocator);
    defer registry.deinit();

    // Register test assets (using actual files)
    const texture_id = try registry.registerAsset("granitesmooth1-albedo.png", .texture);
    const mesh_id = try registry.registerAsset("cube.obj", .mesh);

    // Create loader
    var loader = try AssetLoader.init(std.testing.allocator, &registry, 2);
    defer loader.deinit();

    // Request async loads
    try loader.requestLoad(texture_id);
    try loader.requestLoad(mesh_id);

    // Wait for completion
    loader.waitForCompletion();

    // Check results
    const texture = registry.getAsset(texture_id).?;
    const mesh = registry.getAsset(mesh_id).?;

    try std.testing.expectEqual(AssetState.loaded, texture.state);
    try std.testing.expectEqual(AssetState.loaded, mesh.state);
}

test "AssetLoader dependency resolution" {
    var registry = AssetRegistry.init(std.testing.allocator);
    defer registry.deinit();

    // Register assets with dependencies (using actual files and shader instead of material)
    const texture_id = try registry.registerAsset("missing.png", .texture);
    const shader_id = try registry.registerAsset("simple.vert", .shader);
    const mesh_id = try registry.registerAsset("smooth_vase.obj", .mesh);

    // Set up dependencies: mesh -> shader -> texture
    try registry.addDependency(shader_id, texture_id);
    try registry.addDependency(mesh_id, shader_id);

    // Create loader
    var loader = try AssetLoader.init(std.testing.allocator, &registry, 2);
    defer loader.deinit();

    // Load only the mesh (should load dependencies automatically)
    try loader.loadSync(mesh_id);

    // All assets should be loaded
    try std.testing.expectEqual(AssetState.loaded, registry.getAsset(texture_id).?.state);
    try std.testing.expectEqual(AssetState.loaded, registry.getAsset(shader_id).?.state);
    try std.testing.expectEqual(AssetState.loaded, registry.getAsset(mesh_id).?.state);
}
