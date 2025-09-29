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
const LoadPriority = asset_types.LoadPriority;
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
fn gpuWorkerThread(ctx: GpuWorkerContext) void {
    const loader = ctx.loader;
    while (loader.gpu_running.load(.acquire)) {
        var processed = false;

        const q = loader.completed_queue;
        if (q.popTexture()) |staging| {
            loader.processCompletedTextureFromStaging(staging);

            processed = true;
        }
        if (q.popMesh()) |staging| {
            loader.processCompletedMeshFromStaging(staging);
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
    mesh_queue: std.HashMap(AssetId, MeshStaging, std.hash_map.AutoContext(AssetId), 32),
    texture_queue: std.HashMap(AssetId, TextureStaging, std.hash_map.AutoContext(AssetId), 32),
    mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator) CompletedLoadQueue {
        return CompletedLoadQueue{
            .mesh_queue = std.HashMap(AssetId, MeshStaging, std.hash_map.AutoContext(AssetId), 32).init(allocator),
            .texture_queue = std.HashMap(AssetId, TextureStaging, std.hash_map.AutoContext(AssetId), 32).init(allocator),
        };
    }

    pub fn deinit(self: *CompletedLoadQueue) void {
        self.mesh_queue.deinit();
        self.texture_queue.deinit();
    }

    pub fn pushMesh(self: *CompletedLoadQueue, mesh: MeshStaging) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.mesh_queue.put(mesh.asset_id, mesh) catch |err| {
            log(.ERROR, "CompletedLoadQueue", "Failed to push mesh: asset_id={d}, err={}", .{ mesh.asset_id.toU64(), err });
        };
    }

    pub fn pushTexture(self: *CompletedLoadQueue, tex: TextureStaging) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.texture_queue.put(tex.asset_id, tex) catch |err| {
            log(.ERROR, "CompletedLoadQueue", "Failed to push texture: asset_id={d}, err={}", .{ tex.asset_id.toU64(), err });
        };
    }

    /// Get a mesh by asset_id (does not remove)
    pub fn getMesh(self: *CompletedLoadQueue, asset_id: AssetId) ?MeshStaging {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.mesh_queue.fetchRemove(asset_id).?.value;
    }

    /// Get a texture by asset_id (does not remove)
    pub fn getTexture(self: *CompletedLoadQueue, asset_id: AssetId) ?TextureStaging {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.texture_queue.fetchRemove(asset_id).?.value;
    }

    /// Pop any one texture staging entry (remove and return) or null if empty
    pub fn popTexture(self: *CompletedLoadQueue) ?TextureStaging {
        self.mutex.lock();
        defer self.mutex.unlock();
        var it = self.texture_queue.iterator();
        if (it.next()) |entry| {
            return self.texture_queue.fetchRemove(entry.key_ptr.*).?.value;
        }
        return null;
    }

    /// Pop any one mesh staging entry (remove and return) or null if empty
    pub fn popMesh(self: *CompletedLoadQueue) ?MeshStaging {
        self.mutex.lock();
        defer self.mutex.unlock();
        var it = self.mesh_queue.iterator();
        if (it.next()) |entry| {
            return self.mesh_queue.fetchRemove(entry.key_ptr.*).?.value;
        }
        return null;
    }
};

const GpuWorkerContext = struct {
    loader: *AssetLoader,
    asset_manager: ?*anyopaque, // Forward declaration to avoid circular dependency

};

// Worker function for the ThreadPool
fn assetWorkerThread(pool: *ThreadPool, worker_id: usize) void {
    // Mark this thread as ready
    pool.markThreadReady(worker_id);

    while (pool.running) {
        // Try to get a job
        if (pool.getWork()) |work_item| {
            // Cast the loader pointer back to AssetLoader
            const loader: *AssetLoader = @ptrCast(@alignCast(work_item.loader));

            // Execute job
            loader.performLoadAsync(work_item.asset_id) catch |err| {
                // Log error and mark asset as failed

                // Convert error to string for registry
                var error_buf: [256]u8 = undefined;
                const error_msg = std.fmt.bufPrint(&error_buf, "Async loading error: {}", .{err}) catch "Unknown async loading error";
                loader.registry.markAsFailed(work_item.asset_id, error_msg);

                // Update failed loads counter
                _ = @atomicRmw(u32, &loader.failed_loads, .Add, 1, .monotonic);
            };
        } else {
            // No job available, sleep briefly to avoid busy waiting
            std.Thread.sleep(std.time.ns_per_ms * 1); // 1ms sleep
        }
    }

    // Mark this thread as shutting down
    pool.markThreadShuttingDown(worker_id);
}

/// Asset loader that manages the loading pipeline
/// Supports priority queues, dependency resolution, sync loading, and async loading with thread pool
pub const AssetLoader = struct {
    // Core components
    registry: *AssetRegistry,
    allocator: std.mem.Allocator,
    graphics_context: *GraphicsContext,

    // Priority queues for load requests
    high_priority_queue: RequestQueue,
    medium_priority_queue: RequestQueue,
    low_priority_queue: RequestQueue,

    // Async loading thread pool (heap allocated to prevent move corruption)
    thread_pool: ?*ThreadPool = null,
    async_enabled: bool = false,

    // Loaded asset storage (temporary until we extend AssetRegistry)
    loaded_models: std.ArrayList(*Model),
    loaded_models_map: std.HashMap(AssetId, usize, std.hash_map.AutoContext(AssetId), 80),
    loaded_textures: std.HashMap(AssetId, Texture, std.hash_map.AutoContext(AssetId), 80),

    // Statistics
    active_loads: u32 = 0,
    completed_loads: u32 = 0,
    failed_loads: u32 = 0,

    // Queue for completed loads (for main-thread GPU upload)
    completed_queue: *CompletedLoadQueue,

    // GPU worker thread for performing GPU uploads off the main thread
    gpu_thread: ?*std.Thread = null,
    gpu_running: std.atomic.Value(bool),

    // Callback for texture array updates
    texture_array_update_callback: ?*const fn () void = null,

    const Self = @This();

    /// Queue for managing load requests with thread-safe access
    const RequestQueue = struct {
        items: std.ArrayList(LoadRequest),
        mutex: std.Thread.Mutex = .{},

        pub fn init(allocator: std.mem.Allocator) RequestQueue {
            _ = allocator; // Will be used when we implement proper initialization
            return RequestQueue{
                .items = std.ArrayList(LoadRequest){},
            };
        }

        pub fn deinit(self: *RequestQueue, allocator: std.mem.Allocator) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.items.deinit(allocator);
        }

        pub fn push(self: *RequestQueue, request: LoadRequest, allocator: std.mem.Allocator) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            try self.items.append(allocator, request);
        }

        pub fn pop(self: *RequestQueue, allocator: std.mem.Allocator) ?LoadRequest {
            self.mutex.lock();
            defer self.mutex.unlock();
            _ = allocator; // Not needed for pop
            return self.items.popOrNull();
        }

        pub fn len(self: *const RequestQueue) usize {
            // Note: This is a simple approximation for const access
            // In a real implementation, we might want to avoid mutex operations for const methods
            return self.items.items.len;
        }
    };

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
            .high_priority_queue = RequestQueue.init(allocator),
            .medium_priority_queue = RequestQueue.init(allocator),
            .low_priority_queue = RequestQueue.init(allocator),
            .thread_pool = thread_pool,
            .async_enabled = max_threads > 0,
            .loaded_models = std.ArrayList(*Model){},
            .loaded_models_map = std.HashMap(AssetId, usize, std.hash_map.AutoContext(AssetId), 80).init(allocator),
            .loaded_textures = std.HashMap(AssetId, Texture, std.hash_map.AutoContext(AssetId), 80).init(allocator),
            .completed_queue = completed_queue_ptr,
            .gpu_thread = null,
            .gpu_running = std.atomic.Value(bool).init(false),
        };

        // Don't start GPU worker here: caller (AssetManager) will start it after
        // the loader is heap-allocated so the thread function may safely take
        // a stable pointer to the loader.
        return result;
    }

    pub fn startGpuWorker(self: *Self, asset_manager: *anyopaque) !void {
        if (self.gpu_thread != null) return; // already running
        self.gpu_running.store(true, .release);
        const tptr = try self.allocator.create(std.Thread);
        // Spawn takes a function and a tuple of arguments; create a small context
        const ctx = GpuWorkerContext{ .loader = self, .asset_manager = asset_manager };
        tptr.* = try std.Thread.spawn(.{}, gpuWorkerThread, .{ctx});
        self.gpu_thread = tptr;
    }

    pub fn stopGpuWorker(self: *Self) void {
        if (self.gpu_thread) |t| {
            self.gpu_running.store(false, .release);
            t.join();
            self.allocator.destroy(t);
            self.gpu_thread = null;
        }
    }

    pub fn deinit(self: *Self) void {
        // Clean up thread pool first
        if (self.thread_pool) |pool| {
            pool.deinit();
            self.allocator.destroy(pool);
        }

        // Clean up queues
        self.high_priority_queue.deinit(self.allocator);
        self.medium_priority_queue.deinit(self.allocator);
        self.low_priority_queue.deinit(self.allocator);

        // Clean up loaded assets
        for (self.loaded_models.items) |model_ptr| {
            self.allocator.destroy(model_ptr);
        }
        self.loaded_models.deinit(self.allocator);
        self.loaded_models_map.deinit();
        self.loaded_textures.deinit();

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
    pub fn processCompletedMeshFromStaging(self: *Self, staging: MeshStaging) void {
        // Create model directly on heap to avoid ownership transfer issues
        const model_ptr = Model.create(self.allocator, self.graphics_context, staging.obj_data, staging.path) catch |err| {
            log(.ERROR, "asset_loader", "Failed to create Model from OBJ on GPU worker for asset {d}: {}", .{ staging.asset_id.toU64(), err });
            return;
        };

        // Add to storage containers
        self.loaded_models.append(self.allocator, model_ptr) catch |err| {
            log(.ERROR, "asset_loader", "Failed to append model for asset {d}: {}", .{ staging.asset_id.toU64(), err });
            model_ptr.deinit();
            self.allocator.destroy(model_ptr);
            return;
        };

        const index = self.loaded_models.items.len - 1;
        self.loaded_models_map.put(staging.asset_id, index) catch |err| {
            log(.ERROR, "asset_loader", "Failed to set loaded model for asset {d}: {}", .{ staging.asset_id.toU64(), err });
            _ = self.loaded_models.pop(); // Remove the model we just added
            model_ptr.deinit();
            self.allocator.destroy(model_ptr);
            return;
        };

        // Mark asset as loaded in registry (no callbacks needed - scene will pick up changes automatically)
        self.registry.markAsLoaded(staging.asset_id, staging.obj_data.len);
    }

    /// Process a texture staging entry that was popped by the GPU worker
    pub fn processCompletedTextureFromStaging(self: *Self, staging: TextureStaging) void {
        const texture = Texture.initFromMemory(self.graphics_context, self.allocator, staging.img_data, .rgba8) catch |err| {
            log(.ERROR, "asset_loader", "Failed to create Texture from memory on GPU worker for asset {d}: {}", .{ staging.asset_id.toU64(), err });
            return;
        };
        self.setLoadedTexture(staging.asset_id, texture);

        // Mark asset as loaded in registry (no callbacks needed - scene will pick up changes automatically)
        self.registry.markAsLoaded(staging.asset_id, staging.img_data.len);
    }

    /// Manually set a loaded model for an asset ID (for hot-reload, tests, or manual injection)
    pub fn setLoadedModel(self: *Self, asset_id: AssetId, model: Model) void {
        const model_ptr = self.allocator.create(Model) catch |err| {
            log(.ERROR, "asset_loader", "Failed to allocate model for asset {d}: {}", .{ asset_id.toU64(), err });
            return;
        };
        // Move model to heap to avoid buffer handle invalidation
        model_ptr.* = model;

        self.loaded_models.append(self.allocator, model_ptr) catch |err| {
            log(.ERROR, "asset_loader", "Failed to append model for asset {d}: {}", .{ asset_id.toU64(), err });
            self.allocator.destroy(model_ptr);
            return;
        };

        const index = self.loaded_models.items.len - 1;
        self.loaded_models_map.put(asset_id, index) catch |err| {
            log(.ERROR, "asset_loader", "Failed to set loaded model for asset {d}: {}", .{ asset_id.toU64(), err });
            _ = self.loaded_models.pop(); // Remove the model we just added
            self.allocator.destroy(model_ptr);
        };
    }

    /// Manually set a loaded texture for an asset ID (for hot-reload, tests, or manual injection)
    pub fn setLoadedTexture(self: *Self, asset_id: AssetId, texture: Texture) void {
        self.loaded_textures.put(asset_id, texture) catch |err| {
            log(.ERROR, "asset_loader", "Failed to set loaded texture for asset {d}: {}", .{ asset_id.toU64(), err });
        };
    }

    /// Get a loaded model by AssetId (non-destructive). Deprecated destructive
    /// semantics have been removed to allow multiple systems to access assets.
    pub fn getLoadedModelConst(self: *Self, asset_id: AssetId) ?*const Model {
        if (self.loaded_models_map.get(asset_id)) |index| {
            if (index < self.loaded_models.items.len) {
                return self.loaded_models.items[index];
            }
        }
        return null;
    }

    /// Get a loaded texture by AssetId (non-destructive).
    pub fn getLoadedTextureConst(self: *Self, asset_id: AssetId) ?*const Texture {
        return self.loaded_textures.getPtr(asset_id);
    }

    /// Deprecated: legacy API returning a copy (no removal). Prefer *Const versions.
    pub fn getLoadedModel(self: *Self, asset_id: AssetId) ?Model {
        if (self.loaded_models_map.get(asset_id)) |index| {
            if (index < self.loaded_models.items.len) {
                return self.loaded_models.items[index].*;
            }
        }
        return null;
    }

    /// Deprecated: legacy API returning a copy (no removal). Prefer *Const versions.
    pub fn getLoadedTexture(self: *Self, asset_id: AssetId) ?Texture {
        if (self.loaded_textures.getPtr(asset_id)) |ptr| {
            return ptr.*;
        } else {
            return null;
        }
    }

    /// Request an asset to be loaded with the given priority
    pub fn requestLoad(self: *Self, asset_id: AssetId, priority: LoadPriority) !void {
        // Check if asset exists in registry
        const asset = self.registry.getAsset(asset_id) orelse return error.AssetNotRegistered;
        // Skip if already loaded or loading
        switch (asset.state) {
            .loaded => return,
            .loading => return,
            .unloaded, .failed => {},
        }

        // Mark as loading
        self.registry.markAsLoading(asset_id);

        // Create load request
        const request = LoadRequest{
            .asset_id = asset_id,
            .asset_type = asset.asset_type,
            .path = asset.path,
            .priority = priority,
        };

        // Add to appropriate queue
        switch (priority) {
            .high, .critical => try self.high_priority_queue.push(request, self.allocator),
            .normal => try self.medium_priority_queue.push(request, self.allocator),
            .low => try self.low_priority_queue.push(request, self.allocator),
        }

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
    pub fn loadAsync(self: *Self, asset_id: AssetId, priority: LoadPriority) !void {
        return self.requestLoad(asset_id, priority);
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
        queue_lengths: struct {
            high_priority: usize,
            medium_priority: usize,
            low_priority: usize,
        },
    } {
        return .{
            .active_loads = @atomicLoad(u32, &self.active_loads, .monotonic),
            .completed_loads = @atomicLoad(u32, &self.completed_loads, .monotonic),
            .failed_loads = @atomicLoad(u32, &self.failed_loads, .monotonic),
            .queue_lengths = .{
                .high_priority = self.high_priority_queue.len(),
                .medium_priority = self.medium_priority_queue.len(),
                .low_priority = self.low_priority_queue.len(),
            },
        };
    }

    /// Get the next load request from queues (prioritized)
    fn getNextRequest(self: *Self) ?LoadRequest {
        // Try high priority first
        if (self.high_priority_queue.pop(self.allocator)) |request| {
            return request;
        }

        // Then medium priority
        if (self.medium_priority_queue.pop(self.allocator)) |request| {
            return request;
        }

        // Finally low priority
        if (self.low_priority_queue.pop(self.allocator)) |request| {
            return request;
        }

        return null;
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
        // Load dependencies first (async)
        for (asset.dependencies.items) |dep_id| {
            const dependency = self.registry.getAsset(dep_id) orelse continue;
            if (dependency.state != .loaded and dependency.state != .loading) {
                // Submit dependency for async loading and wait
                if (self.thread_pool) |pool| {
                    try pool.submitWork(.{ .asset_id = dep_id, .loader = self });
                }
            }
        }

        // Wait for dependencies to load (simple polling for now)
        for (asset.dependencies.items) |dep_id| {
            const dependency = self.registry.getAsset(dep_id) orelse continue;
            while (dependency.state == .loading) {
                std.Thread.sleep(1_000_000); // 1ms
            }
            if (dependency.state != .loaded) {
                return error.DependencyLoadFailed;
            }
        }

        // Simulate actual file loading based on asset type
        const file_size = try self.loadAssetFromDisk(asset);

        // Mark as loaded (thread-safe)
        self.registry.markAsLoaded(asset_id, file_size);
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
        log(.DEBUG, "asset_loader", "[Worker] Loading mesh file data: {s}", .{asset.path});
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
        log(.DEBUG, "asset_loader", "[Worker] Loading texture from file: {s}", .{asset.path});
        // Load the texture directly using Texture.initFromFile
        const img_data = loadFileAlloc(self.allocator, asset.path, 10 * 1024 * 1024) catch |err| {
            log(.ERROR, "asset_loader", "Failed to load mesh file {s}: {}", .{ asset.path, err });
            return err;
        };
        // Push the loaded texture to the completed queue
        completed_queue.pushTexture(TextureStaging{
            .asset_id = asset.id,
            .path = asset.path,
            .img_data = img_data,
        });
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
            .queued_high = self.high_priority_queue.len(),
            .queued_medium = self.medium_priority_queue.len(),
            .queued_low = self.low_priority_queue.len(),
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
    queued_high: usize,
    queued_medium: usize,
    queued_low: usize,

    pub fn getTotalQueued(self: LoaderStatistics) usize {
        return self.queued_high + self.queued_medium + self.queued_low;
    }

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
    try loader.requestLoad(texture_id, .high);
    try loader.requestLoad(mesh_id, .normal);

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
