const std = @import("std");
const asset_types = @import("asset_types.zig");
const asset_registry = @import("asset_registry.zig");
const asset_loader = @import("asset_loader.zig");
const HotReloadManager = @import("hot_reload_manager.zig").HotReloadManager;
const log = @import("../utils/log.zig").log;

// Re-export key types for convenience
pub const AssetId = asset_types.AssetId;
pub const AssetType = asset_types.AssetType;
pub const AssetState = asset_types.AssetState;
pub const LoadPriority = asset_types.LoadPriority;
pub const AssetMetadata = asset_types.AssetMetadata;
pub const AssetRegistry = asset_registry.AssetRegistry;
pub const AssetLoader = asset_loader.AssetLoader;

/// Types of fallback assets for different scenarios
pub const FallbackType = enum {
    missing, // Pink checkerboard for missing textures
    loading, // Animated or static "loading..." texture
    @"error", // Red X or error indicator (error is keyword)
    default, // Basic white texture for materials
};

/// Pre-loaded fallback assets for safe rendering
pub const FallbackAssets = struct {
    missing_texture: ?AssetId = null,
    loading_texture: ?AssetId = null,
    error_texture: ?AssetId = null,
    default_texture: ?AssetId = null,

    const Self = @This();

    /// Initialize fallback assets by loading them synchronously
    pub fn init(asset_manager: *AssetManager) !FallbackAssets {
        var fallbacks = FallbackAssets{};

        // Try to load each fallback texture, but don't fail if missing
        fallbacks.missing_texture = asset_manager.loadTextureSync("textures/missing.png") catch |err| blk: {
            std.log.warn("Could not load missing.png fallback: {}", .{err});
            break :blk null;
        };

        fallbacks.loading_texture = asset_manager.loadTextureSync("textures/loading.png") catch |err| blk: {
            std.log.warn("Could not load loading.png fallback: {}", .{err});
            break :blk null;
        };

        fallbacks.error_texture = asset_manager.loadTextureSync("textures/error.png") catch |err| blk: {
            std.log.warn("Could not load error.png fallback: {}", .{err});
            break :blk null;
        };

        fallbacks.default_texture = asset_manager.loadTextureSync("textures/default.png") catch |err| blk: {
            std.log.warn("Could not load default.png fallback: {}", .{err});
            break :blk null;
        };

        return fallbacks;
    }

    /// Get fallback asset ID for given type
    pub fn getAssetId(self: *const Self, fallback_type: FallbackType) ?AssetId {
        return switch (fallback_type) {
            .missing => self.missing_texture,
            .loading => self.loading_texture,
            .@"error" => self.error_texture,
            .default => self.default_texture,
        };
    }
};

/// Central Asset Manager that coordinates all asset operations
/// This is the main interface for the game engine to interact with assets
pub const AssetManager = struct {
    // Core components (using pointers to avoid HashMap moves)
    registry: *AssetRegistry,
    loader: *AssetLoader,
    allocator: std.mem.Allocator,

    // Fallback assets for safe rendering
    fallbacks: FallbackAssets,

    // Hot reloading
    hot_reload_manager: ?HotReloadManager = null,

    // Configuration
    max_loader_threads: u32 = 4,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        // Allocate registry on heap to avoid HashMap corruption
        const registry = try allocator.create(AssetRegistry);
        registry.* = AssetRegistry.init(allocator);

        // Allocate loader on heap
        const loader = try allocator.create(AssetLoader);
        loader.* = try AssetLoader.init(allocator, registry, 4);

        var self = Self{
            .registry = registry,
            .loader = loader,
            .allocator = allocator,
            .fallbacks = FallbackAssets{}, // Initialize empty first
        };

        // Initialize fallback assets after AssetManager is created
        self.fallbacks = try FallbackAssets.init(&self);

        return self;
    }

    pub fn deinit(self: *Self) void {
        // Clean up hot reload manager
        if (self.hot_reload_manager) |*manager| {
            manager.deinit();
        }

        self.loader.deinit();
        self.registry.deinit();

        // Free heap allocations
        self.allocator.destroy(self.loader);
        self.allocator.destroy(self.registry);
    }

    /// Set callback for ThreadPool running status changes
    pub fn setThreadPoolCallback(self: *Self, callback: *const fn (bool) void) void {
        self.loader.setThreadPoolCallback(callback);
    }

    // Asset Registration

    /// Register a new asset at the given path
    /// Returns the asset ID for future reference
    pub fn registerAsset(self: *Self, path: []const u8, asset_type: AssetType) !AssetId {
        return try self.registry.registerAsset(path, asset_type);
    }

    /// Register multiple assets from a directory (mock implementation)
    pub fn registerAssetsFromDirectory(self: *Self, directory: []const u8, recursive: bool) ![]AssetId {
        _ = self;
        _ = directory;
        _ = recursive;
        // TODO: Implement directory scanning
        return &[_]AssetId{};
    }

    // Asset Loading

    /// Load an asset synchronously (blocks until complete)
    /// Returns the asset ID if successful
    pub fn loadAsset(self: *Self, path: []const u8, asset_type: AssetType) !AssetId {
        const asset_id = try self.registerAsset(path, asset_type);
        try self.loader.loadSync(asset_id);

        // Auto-register for hot reloading
        self.registerAssetForHotReload(asset_id, path) catch |err| {
            log(.WARN, "asset_manager", "Failed to register asset for hot reload: {} ({})", .{ asset_id, err });
        };

        return asset_id;
    }

    /// Load an asset asynchronously with priority
    /// Returns the asset ID immediately, asset loads in background
    pub fn loadAssetAsync(self: *Self, path: []const u8, asset_type: AssetType, priority: LoadPriority) !AssetId {
        const asset_id = try self.registerAsset(path, asset_type);
        try self.loader.requestLoad(asset_id, priority);

        // Auto-register for hot reloading
        self.registerAssetForHotReload(asset_id, path) catch |err| {
            log(.WARN, "asset_manager", "Failed to register asset for hot reload: {} ({})", .{ asset_id, err });
        };

        return asset_id;
    }

    /// Load an asset by ID if already registered
    pub fn loadAssetById(self: *Self, asset_id: AssetId, priority: LoadPriority) !void {
        try self.loader.requestLoad(asset_id, priority);
    }

    /// Load a texture synchronously (blocks until complete)
    /// Used for fallback assets that must be available immediately
    pub fn loadTextureSync(self: *Self, path: []const u8) !AssetId {
        return try self.loadAsset(path, .texture);
    }

    // Asset Access

    /// Get asset metadata by ID
    pub fn getAsset(self: *Self, asset_id: AssetId) ?*AssetMetadata {
        return self.registry.getAsset(asset_id);
    }

    /// Get asset metadata by path
    pub fn getAssetByPath(self: *Self, path: []const u8) ?*AssetMetadata {
        return self.registry.getAssetByPath(path);
    }

    /// Get asset ID from path
    pub fn getAssetId(self: *Self, path: []const u8) ?AssetId {
        return self.registry.getAssetId(path);
    }

    /// Check if an asset is loaded and ready for use
    pub fn isAssetLoaded(self: *Self, asset_id: AssetId) bool {
        if (self.getAsset(asset_id)) |asset| {
            return asset.state == .loaded;
        }
        return false;
    }

    // Safe Asset Access with Fallbacks

    /// Get asset ID for rendering - returns fallback if asset not ready
    /// This is the SAFE way to access assets that might still be loading
    pub fn getAssetIdForRendering(self: *Self, asset_id: AssetId) AssetId {
        if (self.getAsset(asset_id)) |asset| {
            switch (asset.state) {
                .loaded => {
                    // Return actual asset if loaded
                    return asset_id;
                },
                .loading => {
                    // Show loading indicator while asset loads
                    if (self.fallbacks.getAssetId(.loading)) |fallback_id| {
                        return fallback_id;
                    }
                    // Fallback to missing if no loading texture
                    return self.fallbacks.getAssetId(.missing) orelse asset_id;
                },
                .failed => {
                    // Show error texture for failed loads
                    if (self.fallbacks.getAssetId(.@"error")) |fallback_id| {
                        return fallback_id;
                    }
                    // Fallback to missing if no error texture
                    return self.fallbacks.getAssetId(.missing) orelse asset_id;
                },
                .unloaded => {
                    // Start loading and show missing texture
                    self.loadAssetById(asset_id, .normal) catch {};
                    return self.fallbacks.getAssetId(.missing) orelse asset_id;
                },
            }
        }
        // Asset doesn't exist at all - return missing fallback
        return self.fallbacks.getAssetId(.missing) orelse asset_id;
    }

    /// Get fallback asset ID for a specific type
    pub fn getFallbackAssetId(self: *Self, fallback_type: FallbackType) ?AssetId {
        return self.fallbacks.getAssetId(fallback_type);
    }

    // Reference Counting

    /// Increment reference count for an asset (marks as "in use")
    pub fn addRef(self: *Self, asset_id: AssetId) void {
        self.registry.incrementRef(asset_id);
    }

    /// Decrement reference count for an asset
    /// Returns true if asset can be unloaded (ref count reached zero)
    pub fn removeRef(self: *Self, asset_id: AssetId) bool {
        return self.registry.decrementRef(asset_id);
    }

    // Dependency Management

    /// Add a dependency relationship between assets
    /// The dependent asset will not unload while the dependency is referenced
    pub fn addDependency(self: *Self, dependent_id: AssetId, dependency_id: AssetId) !void {
        try self.registry.addDependency(dependent_id, dependency_id);
    }

    /// Remove a dependency relationship
    pub fn removeDependency(self: *Self, dependent_id: AssetId, dependency_id: AssetId) void {
        self.registry.removeDependency(dependent_id, dependency_id);
    }

    /// Get all assets that depend on the given asset
    pub fn getDependents(self: *Self, asset_id: AssetId) ?[]AssetId {
        if (self.getAsset(asset_id)) |asset| {
            return asset.dependents.items;
        }
        return null;
    }

    /// Get all assets that the given asset depends on
    pub fn getDependencies(self: *Self, asset_id: AssetId) ?[]AssetId {
        if (self.getAsset(asset_id)) |asset| {
            return asset.dependencies.items;
        }
        return null;
    }

    // Memory Management

    /// Unload assets that have zero reference count
    pub fn unloadUnusedAssets(self: *Self) !u32 {
        const unloadable = try self.registry.getUnloadableAssets(self.allocator);
        defer self.allocator.free(unloadable);

        var unloaded_count: u32 = 0;
        for (unloadable) |asset_id| {
            if (self.getAsset(asset_id)) |asset| {
                // TODO: Actually free the asset data
                asset.state = .unloaded;
                asset.file_size = 0;
                unloaded_count += 1;
            }
        }

        return unloaded_count;
    }

    /// Get assets of a specific type
    pub fn getAssetsByType(self: *Self, asset_type: AssetType) ![]AssetId {
        return try self.registry.getAssetsByType(asset_type, self.allocator);
    }

    // Statistics and Debugging

    /// Get comprehensive statistics about the asset system
    pub fn getStatistics(self: *Self) AssetManagerStatistics {
        const registry_stats = self.registry.getStatistics();
        const loader_stats = self.loader.getStatistics();

        return AssetManagerStatistics{
            .total_assets = registry_stats.total_assets,
            .loaded_assets = registry_stats.loaded_assets,
            .failed_assets = registry_stats.failed_assets,
            .loading_assets = registry_stats.loading_assets,
            .active_loads = loader_stats.active_loads,
            .completed_loads = loader_stats.completed_loads,
            .failed_loads = loader_stats.failed_loads,
            .queued_loads = @intCast(loader_stats.getTotalQueued()),

            // Basic defaults for compatibility
            .memory_used_bytes = 0,
            .memory_allocated_bytes = 0,
            .average_load_time_ms = 0.0,
            .hot_reload_count = 0,
            .cache_hit_ratio = 0.0,
            .files_watched = 0,
            .directories_watched = 0,
            .reload_events_processed = 0,
        };
    }

    /// Print detailed debug information about all assets
    pub fn printDebugInfo(self: *Self) void {
        std.debug.print("\n=== Asset Manager Debug Info ===\n");

        const stats = self.getStatistics();
        std.debug.print("Total Assets: {d}\n", .{stats.total_assets});
        std.debug.print("Loaded: {d}, Loading: {d}, Failed: {d}\n", .{ stats.loaded_assets, stats.loading_assets, stats.failed_assets });
        std.debug.print("Active Loads: {d}, Queued: {d}\n", .{ stats.active_loads, stats.queued_loads });

        std.debug.print("\nAssets by Type:\n");
        inline for (std.meta.fields(AssetType)) |field| {
            const asset_type: AssetType = @enumFromInt(field.value);
            if (self.getAssetsByType(asset_type)) |assets| {
                defer self.allocator.free(assets);
                std.debug.print("  {s}: {d}\n", .{ field.name, assets.len });
            } else |_| {}
        }

        std.debug.print("\n");
    }

    /// Wait for all pending asset loads to complete
    pub fn waitForAllLoads(self: *Self) void {
        self.loader.waitForCompletion();
    }

    // Convenience methods for common asset types

    /// Load a texture asset
    pub fn loadTexture(self: *Self, path: []const u8, priority: LoadPriority) !AssetId {
        return try self.loadAssetAsync(path, .texture, priority);
    }

    /// Load a mesh asset
    pub fn loadMesh(self: *Self, path: []const u8, priority: LoadPriority) !AssetId {
        return try self.loadAssetAsync(path, .mesh, priority);
    }

    /// Load a material asset
    pub fn loadMaterial(self: *Self, path: []const u8, priority: LoadPriority) !AssetId {
        return try self.loadAssetAsync(path, .material, priority);
    }

    /// Load a shader asset
    pub fn loadShader(self: *Self, path: []const u8, priority: LoadPriority) !AssetId {
        return try self.loadAssetAsync(path, .shader, priority);
    }

    /// Load an audio asset
    pub fn loadAudio(self: *Self, path: []const u8, priority: LoadPriority) !AssetId {
        return try self.loadAssetAsync(path, .audio, priority);
    }

    /// Load a scene asset
    pub fn loadScene(self: *Self, path: []const u8, priority: LoadPriority) !AssetId {
        return try self.loadAssetAsync(path, .scene, priority);
    }

    // Hot Reloading

    /// Enable hot reloading for assets
    pub fn enableHotReload(self: *Self) !void {
        if (self.hot_reload_manager == null) {
            self.hot_reload_manager = HotReloadManager.init(self.allocator, self);
        }

        if (self.hot_reload_manager) |*manager| {
            try manager.start();
            const hot_reload_module = @import("hot_reload_manager.zig");
            hot_reload_module.setGlobalHotReloadManager(manager);
        }
    }

    /// Disable hot reloading
    pub fn disableHotReload(self: *Self) void {
        if (self.hot_reload_manager) |*manager| {
            manager.stop();
        }
    }

    /// Process pending hot reloads (call this regularly from main thread)
    pub fn processPendingReloads(self: *Self) void {
        if (self.hot_reload_manager) |*manager| {
            manager.processPendingReloads();
        }
    }

    /// Reload a specific asset from disk
    pub fn reloadAsset(self: *Self, asset_id: AssetId, file_path: []const u8) !void {
        if (self.getAsset(asset_id)) |asset| {
            const previous_state = asset.state;

            log(.INFO, "asset_manager", "Reloading asset {} from {s} (was: {s})", .{ asset_id, file_path, @tagName(previous_state) });

            // Mark asset as loading (this will trigger fallback rendering)
            asset.state = .loading;

            // Queue for async reload with high priority
            try self.loader.loadAsync(asset_id, .high);

            log(.DEBUG, "asset_manager", "Asset {} reload queued", .{asset_id});
        } else {
            log(.WARN, "asset_manager", "Cannot reload asset {}: not found in registry", .{asset_id});
            return error.AssetNotFound;
        }
    }

    /// Register an asset for hot reloading when its file changes
    pub fn registerAssetForHotReload(self: *Self, asset_id: AssetId, file_path: []const u8) !void {
        if (self.hot_reload_manager) |*manager| {
            try manager.registerAsset(asset_id, file_path);
        }
    }

    /// Get detailed performance and memory statistics
    pub fn getDetailedStatistics(self: *Self) AssetManagerStatistics {
        const basic_stats = self.getStatistics();

        // Calculate memory usage (approximation based on loaded assets)
        const memory_per_texture = 4 * 1024 * 1024; // Rough estimate: 4MB per texture

        var memory_used: u64 = 0;
        memory_used += basic_stats.loaded_assets * memory_per_texture; // Simplified calculation

        // Get hot reload statistics if available
        var files_watched: u32 = 0;
        var directories_watched: u32 = 0;
        var reload_events: u32 = 0;
        var total_reloads: u32 = 0;

        if (self.hot_reload_manager) |*manager| {
            // Get basic metrics from hot reload manager
            files_watched = manager.getWatchedFileCount();
            directories_watched = 3; // textures, shaders, models
            reload_events = manager.getProcessedEventCount();
            total_reloads = manager.getTotalReloadCount();
        }

        return AssetManagerStatistics{
            .total_assets = basic_stats.total_assets,
            .loaded_assets = basic_stats.loaded_assets,
            .failed_assets = basic_stats.failed_assets,
            .loading_assets = basic_stats.loading_assets,
            .active_loads = basic_stats.active_loads,
            .completed_loads = basic_stats.completed_loads,
            .failed_loads = basic_stats.failed_loads,
            .queued_loads = basic_stats.queued_loads,

            // Enhanced metrics
            .memory_used_bytes = memory_used,
            .memory_allocated_bytes = memory_used + (basic_stats.loading_assets * memory_per_texture),
            .average_load_time_ms = 50.0, // TODO: Track actual load times
            .hot_reload_count = total_reloads,
            .cache_hit_ratio = 0.95, // TODO: Track actual cache hits

            // Hot reload metrics
            .files_watched = files_watched,
            .directories_watched = directories_watched,
            .reload_events_processed = reload_events,
        };
    }

    /// Print comprehensive performance report
    pub fn printPerformanceReport(self: *Self) void {
        const stats = self.getDetailedStatistics();

        log(.INFO, "asset_manager", "=== Asset Manager Performance Report ===", .{});
        log(.INFO, "asset_manager", "Assets: {d} total, {d} loaded, {d} loading, {d} failed", .{ stats.total_assets, stats.loaded_assets, stats.loading_assets, stats.failed_assets });
        log(.INFO, "asset_manager", "Memory: {d:.1} MB used, {d:.1} MB allocated", .{ @as(f64, @floatFromInt(stats.memory_used_bytes)) / (1024.0 * 1024.0), @as(f64, @floatFromInt(stats.memory_allocated_bytes)) / (1024.0 * 1024.0) });
        log(.INFO, "asset_manager", "Performance: {d:.1}ms avg load, {d:.1}% cache hit ratio", .{ stats.average_load_time_ms, stats.cache_hit_ratio * 100.0 });
        log(.INFO, "asset_manager", "Hot Reload: {d} reloads, {d} files watched, {d} dirs watched", .{ stats.hot_reload_count, stats.files_watched, stats.directories_watched });
        log(.INFO, "asset_manager", "ThreadPool: {d} active loads, {d} completed loads", .{ stats.active_loads, stats.completed_loads });
    }
};

/// Comprehensive statistics for the asset manager
pub const AssetManagerStatistics = struct {
    // Registry statistics
    total_assets: u32,
    loaded_assets: u32,
    failed_assets: u32,
    loading_assets: u32,

    // Loader statistics
    active_loads: u32,
    completed_loads: u32,
    failed_loads: u32,
    queued_loads: u32,

    // Memory tracking
    memory_used_bytes: u64,
    memory_allocated_bytes: u64,

    // Performance metrics
    average_load_time_ms: f64,
    hot_reload_count: u32,
    cache_hit_ratio: f32,

    // Hot reload statistics
    files_watched: u32,
    directories_watched: u32,
    reload_events_processed: u32,

    pub fn getLoadProgress(self: AssetManagerStatistics) f32 {
        if (self.total_assets == 0) return 1.0;
        return @as(f32, @floatFromInt(self.loaded_assets)) / @as(f32, @floatFromInt(self.total_assets));
    }

    pub fn getSuccessRate(self: AssetManagerStatistics) f32 {
        const total_processed = self.completed_loads + self.failed_loads;
        if (total_processed == 0) return 1.0;
        return @as(f32, @floatFromInt(self.completed_loads)) / @as(f32, @floatFromInt(total_processed));
    }
};

// Tests
test "AssetManager basic operations" {
    var manager = try AssetManager.init(std.testing.allocator);
    defer manager.deinit();

    // Register and load a texture
    const texture_id = try manager.loadTexture("missing.png", .high);

    try std.testing.expect(texture_id.isValid());
    try std.testing.expect(manager.isAssetLoaded(texture_id));

    // Test reference counting
    manager.addRef(texture_id);
    manager.addRef(texture_id);

    try std.testing.expect(!manager.removeRef(texture_id));
    try std.testing.expect(manager.removeRef(texture_id));
}

test "AssetManager dependency management" {
    var manager = try AssetManager.init(std.testing.allocator);
    defer manager.deinit();

    // Load assets with dependencies (using actual files)
    const texture_id = try manager.loadTexture("granitesmooth1-albedo.png", .high);
    const mesh_id = try manager.loadMesh("cube.obj", .high);

    // Add dependency (mesh depends on texture)
    try manager.addDependency(mesh_id, texture_id);

    // Check dependencies
    const deps = manager.getDependencies(mesh_id);
    try std.testing.expect(deps != null);
    try std.testing.expectEqual(@as(usize, 1), deps.?.len);
    try std.testing.expectEqual(texture_id, deps.?[0]);
}
test "AssetManager statistics" {
    var manager = try AssetManager.init(std.testing.allocator);
    defer manager.deinit();

    // Load some assets (using actual files)
    _ = try manager.loadTexture("missing.png", .high);
    _ = try manager.loadTexture("granitesmooth1-albedo.png", .normal);
    _ = try manager.loadMesh("smooth_vase.obj", .low);

    const stats = manager.getStatistics();
    try std.testing.expectEqual(@as(u32, 3), stats.total_assets);
    try std.testing.expectEqual(@as(u32, 3), stats.loaded_assets);

    // Test asset type query
    const textures = try manager.getAssetsByType(.texture);
    defer std.testing.allocator.free(textures);
    try std.testing.expectEqual(@as(usize, 2), textures.len);
}
