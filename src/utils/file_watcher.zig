const std = @import("std");
const log = @import("log.zig").log;

/// Cross-platform file system watcher for hot reloading
pub const FileWatcher = struct {
    allocator: std.mem.Allocator,
    watched_paths: std.StringHashMap(WatchedPath),
    thread: ?std.Thread = null,
    running: bool = false,
    mutex: std.Thread.Mutex = .{},

    // Event callback function
    callback: ?*const fn (event: FileEvent) void = null,

    const Self = @This();

    /// Information about a watched path
    const WatchedPath = struct {
        path: []const u8,
        recursive: bool,
        last_modified: i128, // Nanoseconds since epoch
        file_size: u64,
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
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .watched_paths = std.StringHashMap(WatchedPath).init(allocator),
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

    /// Set the callback function for file events
    pub fn setCallback(self: *Self, callback: *const fn (event: FileEvent) void) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.callback = callback;
    }

    /// Set callback with context (better design for object-oriented callbacks)
    pub fn setCallbackWithContext(self: *Self, context: *anyopaque, callback: *const fn (context: *anyopaque, event: FileEvent) void) void {
        _ = self;
        _ = context;
        _ = callback;
        // Context-based callbacks not yet implemented - using global callback approach
        // Future enhancement: store context and callback per watch for better isolation
    }

    /// Add a path to watch for changes
    pub fn addWatch(self: *Self, path: []const u8, recursive: bool) !void {
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
        };

        try self.watched_paths.put(owned_key, watched_path);
        log(.INFO, "file_watcher", "Added watch for: {s} (recursive: {}, kind: {})", .{ path, recursive, stat.kind });
    }

    /// Remove a path from watching
    pub fn removeWatch(self: *Self, path: []const u8) void {
        if (self.watched_paths.fetchRemove(path)) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value.path);
            log(.INFO, "file_watcher", "Removed watch for: {s}", .{path});
        }
    }

    /// Start the file watching thread
    pub fn start(self: *Self) !void {
        if (self.running) return;

        self.running = true;
        self.thread = try std.Thread.spawn(.{}, watcherThread, .{self});
        log(.INFO, "file_watcher", "FileWatcher started monitoring {} paths", .{self.watched_paths.count()});
    }

    /// Stop the file watching thread
    pub fn stop(self: *Self) void {
        if (!self.running) return;

        self.running = false;

        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }

        log(.INFO, "file_watcher", "FileWatcher stopped", .{});
    }

    /// Main watcher thread function - polls for file changes
    fn watcherThread(self: *Self) void {
        log(.DEBUG, "file_watcher", "Watcher thread started", .{});

        while (self.running) {
            self.checkForChanges();

            // Sleep for polling interval (100ms)
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }

        log(.DEBUG, "file_watcher", "Watcher thread exiting", .{});
    }

    /// Check all watched paths for changes
    fn checkForChanges(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var iterator = self.watched_paths.iterator();
        while (iterator.next()) |entry| {
            const path = entry.value_ptr.path;
            const watched = entry.value_ptr;

            // Check if file still exists
            const stat = std.fs.cwd().statFile(path) catch |err| {
                // File was deleted or became inaccessible
                if (self.callback) |callback| {
                    const event = FileEvent{
                        .event_type = .deleted,
                        .path = path,
                    };
                    callback(event);
                }
                log(.DEBUG, "file_watcher", "File deleted or inaccessible: {s} ({})", .{ path, err });
                continue;
            };

            // Check for modifications
            if (stat.mtime > watched.last_modified or stat.size != watched.file_size) {
                // Update our records
                entry.value_ptr.last_modified = stat.mtime;
                entry.value_ptr.file_size = stat.size;

                // Notify callback
                if (self.callback) |callback| {
                    const event = FileEvent{
                        .event_type = .modified,
                        .path = path,
                    };
                    callback(event);
                }

                log(.DEBUG, "file_watcher", "File modified: {s}", .{path});
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
