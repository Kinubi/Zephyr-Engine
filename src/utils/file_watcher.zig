const std = @import("std");
const log = @import("log.zig").log;
const TP = @import("../threading/thread_pool.zig");
const ThreadPool = TP.ThreadPool;
const AssetId = @import("../assets/asset_types.zig").AssetId;

/// Cross-platform file system watcher for hot reloading
pub const FileWatcher = struct {
    allocator: std.mem.Allocator,
    watched_paths: std.HashMap([]const u8, WatchedPath, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),
    // The FileWatcher runs exclusively inside the project's ThreadPool.
    // No local std.Thread is spawned by this module.
    running: bool = false,
    mutex: std.Thread.Mutex = .{},

    // Legacy callback support removed. FileWatcher enqueues events into
    // the project's ThreadPool and does not perform local queuing or
    // callback-based dispatch anymore.

    // Optional ThreadPool target: when set, file events will be enqueued as
    // ThreadPool WorkItems of type `hot_reload` instead of direct callbacks.
    thread_pool: ?*ThreadPool = null,

    const Self = @This();

    /// Information about a watched path
    const WatchedPath = struct {
        path: []const u8,
        recursive: bool,
        last_modified: i128, // Nanoseconds since epoch
        file_size: u64,
        // Optional per-watch ThreadPool worker and context. If set, this
        // worker_fn/context take precedence over the FileWatcher's global
        // pool_worker_fn/pool_worker_context when enqueuing WorkItems.
        pool_worker_fn: ?*const fn (*anyopaque, TP.WorkItem) void = null,
        pool_worker_context: ?*anyopaque = null,
    };

    /// File system event types
    pub const FileEventType = enum {
        modified,
        created,
        deleted,
        moved,
    };

    /// File system event information
    pub const FileEvent = struct {
        event_type: FileEventType,
        path: []const u8,
        old_path: ?[]const u8 = null, // For move events
    };

    /// Initialize the file watcher
    pub fn init(allocator: std.mem.Allocator, thread_pool: *ThreadPool) Self {
        return Self{
            .allocator = allocator,
            .watched_paths = std.HashMap([]const u8, WatchedPath, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
            .thread_pool = thread_pool,
        };
    }

    /// Clean up resources
    pub fn deinit(self: *Self) void {
        self.stop();

        // Free all watched path strings
        var iterator = self.watched_paths.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.path);
        }

        self.watched_paths.deinit();
        log(.INFO, "file_watcher", "FileWatcher deinitialized", .{});
    }

    // Callback APIs removed. Use `setThreadPoolTarget` / per-watch worker
    // functions to receive file events inside the engine ThreadPool.

    /// Add a path to watch for changes
    pub fn addWatch(self: *Self, path: []const u8, recursive: bool) !void {
        // Default addWatch uses no per-watch worker (falls back to global)
        try self.addWatchWithWorker(path, recursive, null, null);
    }

    /// Add a path to watch for changes and optionally supply a pool worker
    /// function + context which will be used when submitting the hot_reload
    /// WorkItem for this specific watched path.
    pub fn addWatchWithWorker(self: *Self, path: []const u8, recursive: bool, worker_fn: ?*const fn (*anyopaque, TP.WorkItem) void, context: ?*anyopaque) !void {
        // Check if path exists and determine if it's a directory
        const stat = std.fs.cwd().statFile(path) catch |err| {
            log(.WARN, "file_watcher", "Cannot stat path to watch: {s} ({})", .{ path, err });
            return err;
        };

        // Clone the path string
        const owned_path = try self.allocator.dupe(u8, path);
        const owned_key = try self.allocator.dupe(u8, path);

        // For directories, we watch the directory's modification time
        // which changes when files are added/removed/modified within it
        const watched_path = WatchedPath{
            .path = owned_path,
            .recursive = recursive,
            .last_modified = stat.mtime,
            .file_size = if (stat.kind == .directory) 0 else stat.size, // Directory size is not meaningful
            .pool_worker_fn = worker_fn,
            .pool_worker_context = context,
        };

        self.mutex.lock();
        defer self.mutex.unlock();
        try self.watched_paths.put(owned_key, watched_path);
    }

    /// Remove a path from watching
    pub fn removeWatch(self: *Self, path: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.watched_paths.fetchRemove(path)) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value.path);
            log(.INFO, "file_watcher", "Removed watch for: {s}", .{path});
        }
    }

    /// Start the file watcher. This MUST be called after `setThreadPoolTarget`.
    pub fn start(self: *Self) !void {
        if (self.running) return;

        // FileWatcher requires a ThreadPool target; we don't spawn local threads.
        if (self.thread_pool) |pool| {
            self.running = true;

            const work_item = TP.createCustomWork(
                0, // id
                @as(*anyopaque, self), // user_data (unused but required)
                0, // size (unused)
                .low, // priority
                watcherThreadWorker,
                @as(*anyopaque, self), // context - the FileWatcher itself
            );

            try pool.submitWork(work_item);
            log(.INFO, "file_watcher", "FileWatcher started in ThreadPool (monitoring {} paths)", .{self.watched_paths.count()});
            return;
        } else {
            log(.ERROR, "file_watcher", "Cannot start FileWatcher: no ThreadPool target configured", .{});
            return error.InvalidState;
        }
    }

    /// Stop the file watcher. Signals the pool worker loop to exit.
    pub fn stop(self: *Self) void {
        if (!self.running) return;
        self.running = false;
        log(.INFO, "file_watcher", "FileWatcher stopping", .{});
    }

    /// Main watcher thread function - polls for file changes
    // Legacy local-thread polling loop removed. The watcher runs in the ThreadPool
    // via `watcherThreadWorker` which invokes `checkForChanges` periodically.

    // Worker function that runs in the ThreadPool; simply executes the same
    // polling loop but adheres to the ThreadPool worker signature.
    pub fn watcherThreadWorker(_context: *anyopaque, _work_item: TP.WorkItem) void {
        const self: *FileWatcher = @ptrCast(@alignCast(_context));
        _ = _work_item;

        while (self.running) {
            self.checkForChanges();

            // Sleep for polling interval (100ms)
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }
    }

    /// Check all watched paths for changes
    fn checkForChanges(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const path_count = self.watched_paths.count();
        if (path_count == 0) {
            // No paths to check - this is normal when starting up
            return;
        }

        var iterator = self.watched_paths.iterator();
        while (iterator.next()) |entry| {
            if (self.running == false) {
                return;
            }
            const path = entry.value_ptr.path;
            const watched = entry.value_ptr;

            // Check if file still exists
            const stat = std.fs.cwd().statFile(path) catch {
                // File was deleted or became inaccessible
                continue;
            };

            // Check for modifications
            if (stat.mtime > watched.last_modified or stat.size != watched.file_size) {
                log(.INFO, "file_watcher", "🔥 File change detected: {s} (mtime changed: {}, size changed: {})", .{ path, stat.mtime > watched.last_modified, stat.size != watched.file_size });

                // Update our records
                entry.value_ptr.last_modified = stat.mtime;
                entry.value_ptr.file_size = stat.size;

                // If a ThreadPool target is configured, enqueue a hot_reload WorkItem
                if (self.thread_pool) |pool| {
                    // Prefer a per-watch worker if provided; otherwise use global pool worker
                    var chosen_worker: ?*const fn (*anyopaque, TP.WorkItem) void = null;
                    var chosen_ctx: *anyopaque = @as(*anyopaque, self);

                    if (entry.value_ptr.pool_worker_fn) |pwf| {
                        chosen_worker = pwf;
                        if (entry.value_ptr.pool_worker_context) |pctx| chosen_ctx = pctx;
                        log(.INFO, "file_watcher", "Using per-watch worker for {s}", .{path});
                    }

                    if (chosen_worker) |worker_fn| {
                        log(.INFO, "file_watcher", "Creating work item for {s} (path.len={})", .{ path, path.len });

                        const work_item = TP.createCustomWork(
                            0, // id
                            @as(*anyopaque, @constCast(path.ptr)), // user_data - file path
                            path.len, // size
                            .high, // priority
                            worker_fn,
                            chosen_ctx, // context - the watcher/manager that registered this
                        );

                        log(.INFO, "file_watcher", "Submitting work item for {s} to thread pool", .{path});
                        pool.submitWork(work_item) catch |err| {
                            log(.ERROR, "file_watcher", "Failed to submit hot_reload WorkItem for {s}: {}", .{ path, err });
                        };
                        log(.INFO, "file_watcher", "✅ Work item submitted successfully for {s}", .{path});
                    } else {
                        // No worker configured for this event; log and continue.
                        log(.WARN, "file_watcher", "File change detected but no ThreadPool worker configured for {s}", .{path});
                    }
                } else {
                    // This should not happen: FileWatcher should be configured with a ThreadPool target
                    log(.WARN, "file_watcher", "File change detected but FileWatcher has no ThreadPool target: {s}", .{path});
                }
            }
        }

        // Recursive directory watching could be enhanced to detect new file creation
        // Current implementation handles existing file modifications effectively
    }

    /// Utility function to check if a path matches any watched pattern
    pub fn isWatched(self: *Self, path: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        var iterator = self.watched_paths.iterator();
        while (iterator.next()) |entry| {
            const watched_path = entry.value_ptr.path;

            // Exact match
            if (std.mem.eql(u8, path, watched_path)) {
                return true;
            }

            // Recursive directory match
            if (entry.value_ptr.recursive and std.mem.startsWith(u8, path, watched_path)) {
                return true;
            }
        }

        return false;
    }
};

// Simple test for file watching
test "file_watcher basic functionality" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var watcher = FileWatcher.init(allocator);
    defer watcher.deinit();

    // Test adding a watch (use a file that should exist)
    watcher.addWatch("src/utils/file_watcher.zig", false) catch |err| {
        std.debug.print("Could not add watch: {}\n", .{err});
        return err;
    };

    std.debug.print("✅ FileWatcher test passed!\n", .{});
}
