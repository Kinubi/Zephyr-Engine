const std = @import("std");
const FileWatcher = @import("../utils/file_watcher.zig").FileWatcher;
const AssetManager = @import("asset_manager.zig").AssetManager;
const AssetId = @import("asset_types.zig").AssetId;
const AssetType = @import("asset_types.zig").AssetType;
const LoadPriority = @import("asset_manager.zig").LoadPriority;
const ThreadPool = @import("../threading/thread_pool.zig").ThreadPool;
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
    file_watcher: FileWatcher,

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

    // Priority-based reload queue
    reload_queue: std.ArrayList(ReloadRequest),
    queue_mutex: std.Thread.Mutex = std.Thread.Mutex{},

    // Debouncing state for batch processing
    pending_reloads: std.StringHashMap(i64), // path -> timestamp
    batch_timer: ?std.Thread = null,
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

    const Self = @This();

    /// Initialize enhanced hot reload manager
    pub fn init(allocator: std.mem.Allocator, asset_manager: *AssetManager) !Self {
        var manager = Self{
            .allocator = allocator,
            .asset_manager = asset_manager,
            .file_watcher = FileWatcher.init(allocator),
            .path_to_asset = std.StringHashMap(AssetId).init(allocator),
            .asset_to_type = std.AutoHashMap(AssetId, AssetType).init(allocator),
            .file_metadata = std.StringHashMap(FileMetadata).init(allocator),
            .pending_reloads = std.StringHashMap(i64).init(allocator),
            .reload_queue = std.ArrayList(ReloadRequest){},
            .reload_callbacks = std.ArrayList(AssetReloadCallback){},
        };

        // Set up file watcher callback
        manager.file_watcher.setCallback(globalFileEventCallback);

        // Set this instance as the global manager for file events
        global_hot_reload_manager = &manager;

        // DON'T start the file watcher immediately - start it lazily when first asset is registered
        // This avoids race conditions during initialization

        // Start batch processing timer - DISABLED to fix crashes
        // manager.batch_timer = try std.Thread.spawn(.{}, batchProcessingWorker, .{&manager});

        log(.INFO, "enhanced_hot_reload", "Enhanced hot reload manager initialized (hot reload {s})", .{if (manager.enabled) "enabled" else "disabled"});
        return manager;
    }

    /// Clean up resources
    pub fn deinit(self: *Self) void {
        // Signal shutdown
        self.shutdown_requested.store(true, .release);

        // Wait for batch timer to finish
        if (self.batch_timer) |thread| {
            thread.join();
        }

        self.file_watcher.deinit();

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

        // Free pending reloads
        var pending_iter = self.pending_reloads.iterator();
        while (pending_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.pending_reloads.deinit();

        // Free reload queue
        for (self.reload_queue.items) |request| {
            self.allocator.free(request.file_path);
        }
        self.reload_queue.deinit(self.allocator);

        self.reload_callbacks.deinit(self.allocator);

        log(.INFO, "enhanced_hot_reload", "Enhanced hot reload manager deinitialized", .{});
    }

    /// Enable or disable hot reloading
    pub fn setEnabled(self: *Self, enabled: bool) void {
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
    pub fn start(self: *Self) !void {
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
    pub fn watchDirectory(self: *Self, dir_path: []const u8) !void {
        try self.file_watcher.addWatch(dir_path, true);
        log(.INFO, "enhanced_hot_reload", "Watching directory for changes: {s}", .{dir_path});
    }

    /// Register an asset for hot reloading when its file changes
    pub fn registerAsset(self: *Self, asset_id: AssetId, file_path: []const u8, asset_type: AssetType) !void {
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
        self.file_watcher.addWatch(file_path, false) catch |err| {
            log(.WARN, "enhanced_hot_reload", "Failed to watch file {s}: {}", .{ file_path, err });
            return;
        };

        _ = self.stats.files_watched.fetchAdd(1, .monotonic);
    }

    /// Add callback for reload notifications
    pub fn addReloadCallback(self: *Self, callback: AssetReloadCallback) !void {
        try self.reload_callbacks.append(callback);
    }

    /// Set debounce time for file change detection
    pub fn setDebounceTime(self: *Self, ms: u64) void {
        self.debounce_ms = ms;
    }

    /// Process file change event (called by file watcher)
    pub fn onFileChanged(self: *Self, file_path: []const u8) void {
        if (!self.enabled) return;

        // Early safety check - avoid processing if we're not fully initialized
        if (!self.watcher_started) {
            log(.DEBUG, "enhanced_hot_reload", "Ignoring file change before watcher fully started: {s}", .{file_path});
            return;
        }

        // TEMPORARILY DISABLED to debug crashes
        log(.DEBUG, "enhanced_hot_reload", "File change detected (processing disabled): {s}", .{file_path});
        return;

        // const now = std.time.milliTimestamp();

        // // Check if this is a registered asset (with mutex protection and additional safety)
        // self.asset_map_mutex.lock();
        // defer self.asset_map_mutex.unlock();
        
        // // Double-check the HashMap is valid before accessing
        // const asset_id = if (self.path_to_asset.count() > 0) 
        //     self.path_to_asset.get(file_path) 
        // else 
        //     null;
        
        // const asset_type = if (asset_id) |id| 
        //     if (self.asset_to_type.count() > 0) 
        //         self.asset_to_type.get(id) orelse .texture 
        //     else 
        //         .texture
        // else 
        //     null;

        // if (asset_id) |id| {
        //     log(.DEBUG, "enhanced_hot_reload", "Processing file change for registered asset: {s} (ID: {})", .{ file_path, id });
        //     // Check for actual file changes
        //     if (self.hasFileChanged(file_path, asset_type.?)) {
        //         self.queueReload(id, file_path, asset_type.?, .file_changed, now);
        //     }
        // } else {
        //     log(.DEBUG, "enhanced_hot_reload", "File change detected but not a registered asset: {s}", .{file_path});
        //     // Check directory for any matching assets
        //     self.scanDirectoryForAssets(file_path);
        // }
    }

    /// Queue a reload request with priority
    fn queueReload(self: *Self, asset_id: AssetId, file_path: []const u8, asset_type: AssetType, event_type: ReloadEvent, timestamp: i64) void {
        // Determine priority based on asset type and usage
        const priority = self.calculateReloadPriority(asset_type, file_path);

        const request = ReloadRequest{
            .asset_id = asset_id,
            .file_path = self.allocator.dupe(u8, file_path) catch return,
            .asset_type = asset_type,
            .event_type = event_type,
            .priority = priority,
            .timestamp = timestamp,
        };

        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();

        // Remove any existing request for this asset
        var i: usize = 0;
        while (i < self.reload_queue.items.len) {
            if (self.reload_queue.items[i].asset_id == asset_id) {
                const old_request = self.reload_queue.swapRemove(i);
                self.allocator.free(old_request.file_path);
            } else {
                i += 1;
            }
        }

        // Add new request in priority order
        var insert_index: usize = 0;
        for (self.reload_queue.items, 0..) |queued_request, index| {
            if (@intFromEnum(request.priority) < @intFromEnum(queued_request.priority)) {
                insert_index = index;
                break;
            }
            insert_index = index + 1;
        }

        self.reload_queue.insert(self.allocator, insert_index, request) catch {
            log(.ERROR, "enhanced_hot_reload", "Failed to queue reload request for asset {}", .{asset_id});
            self.allocator.free(request.file_path);
            return;
        };

        _ = self.stats.reload_events.fetchAdd(1, .monotonic);
    }

    /// Calculate reload priority based on asset type and usage
    fn calculateReloadPriority(self: *Self, asset_type: AssetType, file_path: []const u8) LoadPriority {
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
    fn hasFileChanged(self: *Self, file_path: []const u8, asset_type: AssetType) bool {
        const current_metadata = self.getFileMetadata(file_path, asset_type) catch return false;

        if (self.file_metadata.get(file_path)) |stored_metadata| {
            return current_metadata.last_modified != stored_metadata.last_modified or
                current_metadata.file_size != stored_metadata.file_size;
        }

        return true; // Assume changed if no stored metadata
    }

    /// Get current file metadata
    fn getFileMetadata(self: *Self, file_path: []const u8, asset_type: AssetType) !FileMetadata {
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
    fn scanDirectoryForAssets(self: *Self, dir_path: []const u8) void {
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

    /// Batch processing worker thread
    fn batchProcessingWorker(self: *Self) void {
        while (!self.shutdown_requested.load(.acquire)) {
            std.Thread.sleep(50_000_000); // 50ms cycle

            self.processPendingReloads();
        }
    }

    /// Process pending reload requests
    fn processPendingReloads(self: *Self) void {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();

        // Early return if no pending reloads
        if (self.reload_queue.items.len == 0) return;

        const now = std.time.milliTimestamp();

        // Process items backwards to avoid index shifting issues
        var i = self.reload_queue.items.len;
        while (i > 0) {
            i -= 1; // Process from end to beginning

            const request = &self.reload_queue.items[i];
            if (now - request.timestamp >= self.debounce_ms) {
                // Make a copy of the request before removing it
                const request_copy = request.*;

                // Remove the processed request from queue
                _ = self.reload_queue.swapRemove(i);

                // Process the request outside of the mutex lock
                self.queue_mutex.unlock();
                self.processReloadRequest(request_copy);
                self.queue_mutex.lock();

                // After unlocking/locking, the queue might have changed
                // Adjust i to stay within bounds
                if (i >= self.reload_queue.items.len) {
                    i = self.reload_queue.items.len;
                }
            }
        }
    }

    /// Process a single reload request
    fn processReloadRequest(self: *Self, request: ReloadRequest) void {
        const start_time = std.time.milliTimestamp();

        // Attempt to reload the asset
        const success = self.reloadAsset(request) catch false;

        const load_time = @as(f32, @floatFromInt(std.time.milliTimestamp() - start_time));

        if (success) {
            _ = self.stats.successful_reloads.fetchAdd(1, .monotonic);

            // Update average reload time
            const current_avg = self.stats.average_reload_time_ms.load(.monotonic);
            const new_avg = (current_avg * 0.9) + (load_time * 0.1);
            self.stats.average_reload_time_ms.store(new_avg, .monotonic);

            // Notify callbacks
            for (self.reload_callbacks.items) |callback| {
                callback(request.file_path, request.asset_id, request.asset_type);
            }

            log(.INFO, "enhanced_hot_reload", "Successfully reloaded asset {} ({s}) in {d:.1}ms", .{ request.asset_id, request.file_path, load_time });
        } else {
            _ = self.stats.failed_reloads.fetchAdd(1, .monotonic);

            // Retry if under limit
            if (request.retry_count < self.max_retries) {
                var retry_request = request;
                retry_request.retry_count += 1;
                retry_request.timestamp = std.time.milliTimestamp() + @as(i64, @intCast(self.debounce_ms));

                self.queue_mutex.lock();
                defer self.queue_mutex.unlock();
                self.reload_queue.append(self.allocator, retry_request) catch {};

                log(.WARN, "enhanced_hot_reload", "Retrying reload for asset {} ({s}) - attempt {}/{}", .{ request.asset_id, request.file_path, request.retry_count + 1, self.max_retries });
                return; // Don't free file_path, it's being reused
            }

            log(.ERROR, "enhanced_hot_reload", "Failed to reload asset {} ({s}) after {} attempts", .{ request.asset_id, request.file_path, self.max_retries });
        }

        // Clean up request
        self.allocator.free(request.file_path);
    }

    /// Reload a single asset
    fn reloadAsset(self: *Self, request: ReloadRequest) !bool {
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
    pub fn getStatistics(self: *Self) struct {
        files_watched: u64,
        reload_events: u64,
        successful_reloads: u64,
        failed_reloads: u64,
        pending_reloads: u64,
        average_reload_time_ms: f32,
        batched_reloads: u64,
    } {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();

        return .{
            .files_watched = self.stats.files_watched.load(.monotonic),
            .reload_events = self.stats.reload_events.load(.monotonic),
            .successful_reloads = self.stats.successful_reloads.load(.monotonic),
            .failed_reloads = self.stats.failed_reloads.load(.monotonic),
            .pending_reloads = self.reload_queue.items.len,
            .average_reload_time_ms = self.stats.average_reload_time_ms.load(.monotonic),
            .batched_reloads = self.stats.batched_reloads.load(.monotonic),
        };
    }
};

/// Global file event callback (required by FileWatcher)
var global_hot_reload_manager: ?*HotReloadManager = null;

pub fn setGlobalHotReloadManager(manager: *HotReloadManager) void {
    global_hot_reload_manager = manager;
}

fn globalFileEventCallback(event: FileWatcher.FileEvent) void {
    if (global_hot_reload_manager) |manager| {
        manager.onFileChanged(event.path);
    }
}
