const std = @import("std");
const FileWatcher = @import("../utils/file_watcher.zig").FileWatcher;
const AssetManager = @import("asset_manager.zig").AssetManager;
const AssetId = @import("asset_types.zig").AssetId;
const AssetType = @import("asset_types.zig").AssetType;
const LoadPriority = @import("asset_manager.zig").LoadPriority;
const TP = @import("../threading/thread_pool.zig");
const ThreadPool = TP.ThreadPool;
const log = @import("../utils/log.zig").log;

/// Callback function type for asset reload notifications
pub const AssetReloadCallback = *const fn (file_path: []const u8, asset_id: AssetId, asset_type: AssetType) void;

/// Hot reload event types
pub const ReloadEvent = enum {
    file_changed,
    file_created,
    file_deleted,
    batch_complete,
};

/// Hot reload request with priority and context
pub const ReloadRequest = struct {
    asset_id: AssetId,
    file_path: []const u8,
    asset_type: AssetType,
    event_type: ReloadEvent,
    priority: LoadPriority,
    timestamp: i64,
    retry_count: u32 = 0,
};

/// Enhanced Hot Reload Manager with priority-based reloading and thread pool integration
pub const HotReloadManager = struct {
    allocator: std.mem.Allocator,
    asset_manager: *AssetManager,
    // FileWatcher is owned by the application and passed in during init so
    // it can be deinitialized after all dependents have been torn down.
    file_watcher: *FileWatcher,

    // Path to AssetId mapping for quick lookups during file events
    path_to_asset: std.StringHashMap(AssetId),
    asset_to_type: std.AutoHashMap(AssetId, AssetType),
    asset_map_mutex: std.Thread.Mutex = std.Thread.Mutex{}, // Protect HashMap access from multiple threads

    // Hot reload settings
    enabled: bool = true,
    watcher_started: bool = false, // Track if FileWatcher has been started
    debounce_ms: u64 = 300, // Wait 300ms after last change before reloading
    max_retries: u32 = 3,
    batch_timeout_ms: u64 = 1000, // Maximum time to wait for batch completion

    // File metadata tracking for change detection
    file_metadata: std.StringHashMap(FileMetadata),

    // This manager no longer performs local queuing. File events are delivered
    // directly into the engine ThreadPool and handled immediately.
    shutdown_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // Callbacks for reload notifications
    reload_callbacks: std.ArrayList(AssetReloadCallback),

    // Performance statistics
    stats: struct {
        files_watched: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        reload_events: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        successful_reloads: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        failed_reloads: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        average_reload_time_ms: std.atomic.Value(f32) = std.atomic.Value(f32).init(0.0),
        batched_reloads: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    } = .{},

    /// File metadata for change detection
    const FileMetadata = struct {
        last_modified: i128, // Nanoseconds since epoch
        file_size: u64,
        asset_type: AssetType,
    };

    /// Initialize enhanced hot reload manager
    pub fn init(allocator: std.mem.Allocator, asset_manager: *AssetManager, watcher: *FileWatcher) !HotReloadManager {
        const manager = HotReloadManager{
            .allocator = allocator,
            .asset_manager = asset_manager,
            .file_watcher = watcher,
            .path_to_asset = std.StringHashMap(AssetId).init(allocator),
            .asset_to_type = std.AutoHashMap(AssetId, AssetType).init(allocator),
            .file_metadata = std.StringHashMap(FileMetadata).init(allocator),
            .reload_callbacks = std.ArrayList(AssetReloadCallback){},
        };

        // File events are delivered via the ThreadPool; no global callback needed.

        // DON'T start the file watcher immediately - start it lazily when first asset is registered
        // This avoids race conditions during initialization

        log(.INFO, "enhanced_hot_reload", "Enhanced hot reload manager initialized (hot reload {s})", .{if (manager.enabled) "enabled" else "disabled"});
        return manager;
    }

    /// Clean up resources
    pub fn deinit(self: *HotReloadManager) void {
        // Signal shutdown first
        self.shutdown_requested.store(true, .release);

        // No local batch timer to wait on - processing uses ThreadPool workers

        // Now safely clean up HashMaps with mutex protection
        self.asset_map_mutex.lock();
        defer self.asset_map_mutex.unlock();

        // Free path strings
        var path_iter = self.path_to_asset.iterator();
        while (path_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.path_to_asset.deinit();
        self.asset_to_type.deinit();

        // Free file metadata path strings
        var metadata_iter = self.file_metadata.iterator();
        while (metadata_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.file_metadata.deinit();

        // No local reload queue to clean up

        self.reload_callbacks.deinit(self.allocator);

        log(.INFO, "enhanced_hot_reload", "Enhanced hot reload manager deinitialized", .{});
    }

    /// Enable or disable hot reloading
    pub fn setEnabled(self: *HotReloadManager, enabled: bool) void {
        self.enabled = enabled;
        if (enabled) {
            self.file_watcher.start() catch |err| {
                log(.ERROR, "enhanced_hot_reload", "Failed to start file watcher: {}", .{err});
            };
        } else {
            self.file_watcher.stop();
        }
        log(.INFO, "enhanced_hot_reload", "Enhanced hot reloading {s}", .{if (enabled) "enabled" else "disabled"});
    }

    /// Start hot reloading system with directory watching
    pub fn start(self: *HotReloadManager) !void {
        if (!self.enabled) {
            log(.WARN, "enhanced_hot_reload", "Hot reloading is disabled, not starting", .{});
            return;
        }

        // Start the file watcher
        try self.file_watcher.start();
        self.watcher_started = true;

        // TEMPORARILY DISABLED directory watching to debug crashes
        // self.watchDirectory("textures") catch |err| {
        //     log(.WARN, "enhanced_hot_reload", "Could not watch textures directory: {}", .{err});
        // };

        // self.watchDirectory("shaders") catch |err| {
        //     log(.WARN, "enhanced_hot_reload", "Could not watch shaders directory: {}", .{err});
        // };

        // self.watchDirectory("models") catch |err| {
        //     log(.WARN, "enhanced_hot_reload", "Could not watch models directory: {}", .{err});
        // };

        log(.INFO, "enhanced_hot_reload", "Enhanced hot reload system started (directory watching temporarily disabled)", .{});
    }

    /// Watch a directory for file changes
    pub fn watchDirectory(self: *HotReloadManager, dir_path: []const u8) !void {
        try self.file_watcher.addWatch(dir_path, true);
        log(.INFO, "enhanced_hot_reload", "Watching directory for changes: {s}", .{dir_path});
    }

    /// Register an asset for hot reloading when its file changes
    pub fn registerAsset(self: *HotReloadManager, asset_id: AssetId, file_path: []const u8, asset_type: AssetType) !void {
        // Start FileWatcher with directory watching on first asset registration
        if (!self.watcher_started) {
            self.start() catch |err| {
                log(.ERROR, "enhanced_hot_reload", "Failed to start hot reload system: {}", .{err});
                self.enabled = false;
                return err;
            };
        }

        // Clone the path
        const owned_path = try self.allocator.dupe(u8, file_path);
        errdefer self.allocator.free(owned_path);

        // Store mappings (with mutex protection)
        self.asset_map_mutex.lock();
        defer self.asset_map_mutex.unlock();
        try self.path_to_asset.put(owned_path, asset_id);
        try self.asset_to_type.put(asset_id, asset_type);

        // Get file metadata for change detection
        const metadata = self.getFileMetadata(file_path, asset_type) catch |err| {
            log(.WARN, "enhanced_hot_reload", "Failed to get metadata for {s}: {}", .{ file_path, err });
            return;
        };

        const owned_metadata_path = try self.allocator.dupe(u8, file_path);
        try self.file_metadata.put(owned_metadata_path, metadata);

        // Also watch the specific file (in addition to directory watching)
        // Use per-watch worker so events for this file are delivered directly
        // to this HotReloadManager via the ThreadPool worker function.
        self.file_watcher.addWatchWithWorker(file_path, false, threadPoolFileEventWorker, @as(*anyopaque, self)) catch |err| {
            log(.WARN, "enhanced_hot_reload", "Failed to watch file {s}: {}", .{ file_path, err });
            return;
        };

        _ = self.stats.files_watched.fetchAdd(1, .monotonic);
    }

    /// Add callback for reload notifications
    pub fn addReloadCallback(self: *HotReloadManager, callback: AssetReloadCallback) !void {
        try self.reload_callbacks.append(callback);
    }

    /// Set debounce time for file change detection
    pub fn setDebounceTime(self: *HotReloadManager, ms: u64) void {
        self.debounce_ms = ms;
    }

    /// Process file change event (called by file watcher)
    pub fn onFileChanged(self: *HotReloadManager, file_path: []const u8) void {
        if (!self.enabled) return;

        // Early safety check - avoid processing if we're not fully initialized
        if (!self.watcher_started) {
            log(.WARN, "enhanced_hot_reload", "Ignoring file change before watcher fully started: {s}", .{file_path});
            return;
        }

        // Check if this is a registered asset (with mutex protection)
        self.asset_map_mutex.lock();
        defer self.asset_map_mutex.unlock();

        const asset_id = if (self.path_to_asset.count() > 0)
            self.path_to_asset.get(file_path)
        else
            null;

        if (asset_id) |id| {
            // Force registry into unloaded state so AssetLoader will accept
            // a fresh load request even if the asset was previously loaded.
            self.asset_manager.registry.forceMarkUnloaded(id);

            const asset_type = if (self.asset_to_type.count() > 0) self.asset_to_type.get(id) orelse .texture else .texture;
            log(.INFO, "enhanced_hot_reload", "Processing file change for registered asset: {s} (ID: {})", .{ file_path, id });

            // We already received a file-changed event, no need to re-stat here.
            // Submit an immediate load request to the AssetLoader via the ThreadPool.
            const reload_priority = self.calculateReloadPriority(asset_type, file_path);
            const work_priority = switch (reload_priority) {
                .critical => TP.WorkPriority.critical,
                .high => TP.WorkPriority.high,
                .normal => TP.WorkPriority.normal,
                .low => TP.WorkPriority.low,
            };

            // AssetManager.loader is set during AssetManager init; request a load directly.
            self.asset_manager.loader.requestLoad(id, work_priority) catch |err| {
                log(.ERROR, "enhanced_hot_reload", "Failed to request load for changed asset {s}: {}", .{ file_path, err });
            };
        } else {
            log(.DEBUG, "enhanced_hot_reload", "File change detected but not a registered asset: {s}", .{file_path});
        }
    }

    /// Calculate reload priority based on asset type and usage
    fn calculateReloadPriority(self: *HotReloadManager, asset_type: AssetType, file_path: []const u8) LoadPriority {
        _ = self;

        // UI and shader assets get highest priority
        if (std.mem.indexOf(u8, file_path, "ui/") != null or
            std.mem.indexOf(u8, file_path, "shaders/") != null)
        {
            return .critical;
        }

        return switch (asset_type) {
            .texture => .high,
            .mesh => .normal,
            .shader => .critical,
            else => .low,
        };
    }

    /// Check if file has actually changed
    fn hasFileChanged(self: *HotReloadManager, file_path: []const u8, asset_type: AssetType) bool {
        const current_metadata = self.getFileMetadata(file_path, asset_type) catch return false;

        if (self.file_metadata.get(file_path)) |stored_metadata| {
            return current_metadata.last_modified != stored_metadata.last_modified or
                current_metadata.file_size != stored_metadata.file_size;
        }

        return true; // Assume changed if no stored metadata
    }

    /// Get current file metadata
    fn getFileMetadata(self: *HotReloadManager, file_path: []const u8, asset_type: AssetType) !FileMetadata {
        _ = self;
        const file = std.fs.cwd().openFile(file_path, .{}) catch return error.FileNotFound;
        defer file.close();

        const stat = try file.stat();
        return FileMetadata{
            .last_modified = stat.mtime,
            .file_size = stat.size,
            .asset_type = asset_type,
        };
    }

    /// Scan directory for asset files that might match registered assets
    fn scanDirectoryForAssets(self: *HotReloadManager, dir_path: []const u8) void {
        self.asset_map_mutex.lock();
        defer self.asset_map_mutex.unlock();

        var path_iter = self.path_to_asset.iterator();
        while (path_iter.next()) |entry| {
            const asset_path = entry.key_ptr.*;
            if (std.mem.startsWith(u8, asset_path, dir_path)) {
                const asset_id = entry.value_ptr.*;
                if (self.asset_to_type.get(asset_id)) |asset_type| {
                    if (self.hasFileChanged(asset_path, asset_type)) {
                        self.queueReload(asset_id, asset_path, asset_type, .file_changed, std.time.milliTimestamp());
                    }
                }
            }
        }
    }

    /// Reload a single asset
    fn reloadAsset(self: *HotReloadManager, request: ReloadRequest) !bool {
        // Update file metadata first
        const new_metadata = self.getFileMetadata(request.file_path, request.asset_type) catch return false;

        const owned_path = try self.allocator.dupe(u8, request.file_path);
        defer self.allocator.free(owned_path);

        try self.file_metadata.put(owned_path, new_metadata);

        // Trigger asset manager to reload
        _ = self.asset_manager.loadAssetAsync(request.file_path, request.asset_type, request.priority) catch return false;

        return true;
    }

    /// Get hot reload statistics
    pub fn getStatistics(self: *HotReloadManager) struct {
        files_watched: u64,
        reload_events: u64,
        successful_reloads: u64,
        failed_reloads: u64,
        pending_reloads: u64,
        average_reload_time_ms: f32,
        batched_reloads: u64,
    } {
        return .{
            .files_watched = self.stats.files_watched.load(.monotonic),
            .reload_events = self.stats.reload_events.load(.monotonic),
            .successful_reloads = self.stats.successful_reloads.load(.monotonic),
            .failed_reloads = self.stats.failed_reloads.load(.monotonic),
            .pending_reloads = 0,
            .average_reload_time_ms = self.stats.average_reload_time_ms.load(.monotonic),
            .batched_reloads = self.stats.batched_reloads.load(.monotonic),
        };
    }
};

// Legacy global callback support removed - file events are routed into the
// ThreadPool and delivered via `threadPoolFileEventWorker`.

// ThreadPool worker function that will be called when FileWatcher enqueues
// a hot_reload WorkItem. It extracts the file path from the WorkItem and
// delegates to HotReloadManager.onFileChanged.
pub fn threadPoolFileEventWorker(context: *anyopaque, work_item: TP.WorkItem) void {
    const manager: *HotReloadManager = @ptrCast(@alignCast(context));
    const file_path = work_item.data.hot_reload.file_path;
    manager.onFileChanged(file_path);
}
