const std = @import("std");
const asset_types = @import("asset_types.zig");
const asset_registry = @import("asset_registry.zig");

const AssetId = asset_types.AssetId;
const AssetType = asset_types.AssetType;
const AssetState = asset_types.AssetState;
const LoadPriority = asset_types.LoadPriority;
const LoadRequest = asset_types.LoadRequest;
const LoadResult = asset_types.LoadResult;
const AssetRegistry = asset_registry.AssetRegistry;

/// Asset loader that manages the loading pipeline
/// Supports priority queues, dependency resolution, and sync loading
pub const AssetLoader = struct {
    // Core components
    registry: *AssetRegistry,
    allocator: std.mem.Allocator,

    // Priority queues for load requests (simplified for now)
    high_priority_queue: RequestQueue,
    medium_priority_queue: RequestQueue,
    low_priority_queue: RequestQueue,

    // Statistics
    active_loads: u32 = 0,
    completed_loads: u32 = 0,
    failed_loads: u32 = 0,

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

        pub fn len(self: *RequestQueue) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.items.items.len;
        }
    };

    pub fn init(allocator: std.mem.Allocator, registry: *AssetRegistry, max_threads: u32) !Self {
        _ = max_threads; // Not used in simplified version

        return Self{
            .registry = registry,
            .allocator = allocator,
            .high_priority_queue = RequestQueue.init(allocator),
            .medium_priority_queue = RequestQueue.init(allocator),
            .low_priority_queue = RequestQueue.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        // Clean up queues
        self.high_priority_queue.deinit(self.allocator);
        self.medium_priority_queue.deinit(self.allocator);
        self.low_priority_queue.deinit(self.allocator);
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

        // For simplified version, process immediately
        try self.performLoad(asset_id);
    }

    /// Load an asset synchronously (blocks until complete)
    pub fn loadSync(self: *Self, asset_id: AssetId) !void {
        const asset = self.registry.getAsset(asset_id) orelse return error.AssetNotRegistered;

        // Skip if already loaded
        if (asset.state == .loaded) return;

        // Perform the actual load
        try self.performLoad(asset_id);
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

    /// Perform the actual asset loading
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

    /// Mock implementation of disk loading (replace with real file I/O)
    fn loadAssetFromDisk(self: *Self, asset: *const asset_types.AssetMetadata) !u64 {
        _ = self; // Unused in mock

        // Simulate loading time based on asset type
        const load_time_ms: u64 = switch (asset.asset_type) {
            .texture => 50,
            .mesh => 100,
            .material => 25,
            .shader => 75,
            .audio => 200,
            .scene => 150,
            .animation => 120,
        };

        // Simulate loading delay
        std.Thread.sleep(load_time_ms * 1_000_000); // Convert ms to ns

        // Return mock file size
        return switch (asset.asset_type) {
            .texture => 1024 * 1024, // 1MB
            .mesh => 512 * 1024, // 512KB
            .material => 4 * 1024, // 4KB
            .shader => 16 * 1024, // 16KB
            .audio => 2 * 1024 * 1024, // 2MB
            .scene => 256 * 1024, // 256KB
            .animation => 128 * 1024, // 128KB
        };
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
