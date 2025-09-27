const std = @import("std");
const FileWatcher = @import("../utils/file_watcher.zig").FileWatcher;
const AssetManager = @import("asset_manager.zig").AssetManager;
const AssetId = @import("asset_types.zig").AssetId;
const log = @import("../utils/log.zig").log;

/// Callback function type for texture reload notifications
pub const TextureReloadCallback = *const fn (file_path: []const u8, asset_id: AssetId) void;

/// Manages hot reloading of assets when files change
pub const HotReloadManager = struct {
    allocator: std.mem.Allocator,
    asset_manager: *AssetManager,
    file_watcher: FileWatcher,

    // Path to AssetId mapping for quick lookups during file events
    path_to_asset: std.StringHashMap(AssetId),

    // Hot reload settings
    enabled: bool = true,
    debounce_ms: u64 = 300, // Wait 300ms after last change before reloading

    // File metadata tracking for change detection
    file_metadata: std.StringHashMap(FileMetadata),

    // Debouncing state
    pending_reloads: std.StringHashMap(i64), // path -> timestamp
    mutex: std.Thread.Mutex = .{},

    // Callback for texture reload notifications
    texture_reload_callback: ?TextureReloadCallback = null,

    /// File metadata for change detection
    const FileMetadata = struct {
        last_modified: i128, // Nanoseconds since epoch
        file_size: u64,
    };

    const Self = @This();

    /// Initialize hot reload manager
    pub fn init(allocator: std.mem.Allocator, asset_manager: *AssetManager) Self {
        var manager = Self{
            .allocator = allocator,
            .asset_manager = asset_manager,
            .file_watcher = FileWatcher.init(allocator),
            .path_to_asset = std.StringHashMap(AssetId).init(allocator),
            .file_metadata = std.StringHashMap(FileMetadata).init(allocator),
            .pending_reloads = std.StringHashMap(i64).init(allocator),
        };

        // Set up file watcher callback to use the global callback
        manager.file_watcher.setCallback(globalFileEventCallback);

        return manager;
    }

    /// Clean up resources
    pub fn deinit(self: *Self) void {
        self.file_watcher.deinit();

        // Free path strings
        var path_iter = self.path_to_asset.iterator();
        while (path_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.path_to_asset.deinit();

        // Free file metadata path strings
        var metadata_iter = self.file_metadata.iterator();
        while (metadata_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.file_metadata.deinit();

        var pending_iter = self.pending_reloads.iterator();
        while (pending_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.pending_reloads.deinit();

        log(.INFO, "hot_reload", "HotReloadManager deinitialized", .{});
    }

    /// Enable or disable hot reloading
    pub fn setEnabled(self: *Self, enabled: bool) void {
        self.enabled = enabled;
        if (enabled) {
            self.file_watcher.start() catch |err| {
                log(.ERROR, "hot_reload", "Failed to start file watcher: {}", .{err});
            };
        } else {
            self.file_watcher.stop();
        }
        log(.INFO, "hot_reload", "Hot reloading {s}", .{if (enabled) "enabled" else "disabled"});
    }

    /// Register an asset for hot reloading when its file changes
    pub fn registerAsset(self: *Self, asset_id: AssetId, file_path: []const u8) !void {
        // Clone the path
        const owned_path = try self.allocator.dupe(u8, file_path);

        // Add to our mapping
        try self.path_to_asset.put(owned_path, asset_id);

        // Store initial file metadata
        if (self.getFileMetadata(file_path)) |metadata| {
            const metadata_path = try self.allocator.dupe(u8, file_path);
            try self.file_metadata.put(metadata_path, metadata);
        } else |err| {
            log(.WARN, "hot_reload", "Failed to get metadata for {s}: {}", .{ file_path, err });
        }

        // Add file watch
        try self.file_watcher.addWatch(file_path, false);

        log(.DEBUG, "hot_reload", "Registered asset {} for hot reload: {s}", .{ asset_id, file_path });
    }

    /// Unregister an asset from hot reloading
    pub fn unregisterAsset(self: *Self, file_path: []const u8) void {
        if (self.path_to_asset.fetchRemove(file_path)) |entry| {
            self.allocator.free(entry.key);
            self.file_watcher.removeWatch(file_path);

            // Also remove file metadata
            if (self.file_metadata.fetchRemove(file_path)) |metadata_entry| {
                self.allocator.free(metadata_entry.key);
            }

            log(.DEBUG, "hot_reload", "Unregistered asset from hot reload: {s}", .{file_path});
        }
    }

    /// Set callback to be called when textures are hot reloaded
    pub fn setTextureReloadCallback(self: *Self, callback: TextureReloadCallback) void {
        self.texture_reload_callback = callback;
    }

    /// Add a directory to watch for new asset files
    pub fn watchDirectory(self: *Self, dir_path: []const u8) !void {
        try self.file_watcher.addWatch(dir_path, true);
        log(.INFO, "hot_reload", "Watching directory for changes: {s}", .{dir_path});
    }

    /// Start hot reloading system
    pub fn start(self: *Self) !void {
        if (!self.enabled) {
            log(.WARN, "hot_reload", "Hot reloading is disabled, not starting", .{});
            return;
        }

        try self.file_watcher.start();

        // Set up common asset directories to watch
        self.watchDirectory("textures") catch |err| {
            log(.WARN, "hot_reload", "Could not watch textures directory: {}", .{err});
        };

        self.watchDirectory("shaders") catch |err| {
            log(.WARN, "hot_reload", "Could not watch shaders directory: {}", .{err});
        };

        self.watchDirectory("models") catch |err| {
            log(.WARN, "hot_reload", "Could not watch models directory: {}", .{err});
        };

        log(.INFO, "hot_reload", "Hot reload system started", .{});
    }

    /// Stop hot reloading system
    pub fn stop(self: *Self) void {
        self.file_watcher.stop();
        log(.INFO, "hot_reload", "Hot reload system stopped", .{});
    }

    /// Process pending reloads (call this from main thread regularly)
    pub fn processPendingReloads(self: *Self) void {
        if (!self.enabled) return;

        self.mutex.lock();
        defer self.mutex.unlock();

        const current_time = std.time.milliTimestamp();

        // Process one pending reload per frame to avoid dynamic allocation
        var iterator = self.pending_reloads.iterator();
        var found_path: ?[]const u8 = null;

        while (iterator.next()) |entry| {
            const path = entry.key_ptr.*;
            const timestamp = entry.value_ptr.*;

            if (current_time - timestamp >= self.debounce_ms) {
                found_path = path;
                break;
            }
        }

        // Process the found path
        if (found_path) |path| {
            // Reload the asset
            self.reloadAsset(path);

            // Remove from pending and free the key
            if (self.pending_reloads.fetchRemove(path)) |entry| {
                self.allocator.free(entry.key);
            }
        }
    }

    /// Reload a specific asset
    fn reloadAsset(self: *Self, file_path: []const u8) void {
        // First check if we have a specific asset registered for this path
        if (self.path_to_asset.get(file_path)) |asset_id| {
            log(.INFO, "hot_reload", "Hot reloading registered asset: {s} (ID: {})", .{ file_path, asset_id });

            // Use AssetManager to reload the asset
            self.asset_manager.reloadAsset(asset_id, file_path) catch |err| {
                log(.ERROR, "hot_reload", "Failed to reload asset {s}: {}", .{ file_path, err });
                return;
            };

            log(.INFO, "hot_reload", "Successfully hot reloaded: {s}", .{file_path});

            // Notify texture reload callback if this is a texture file
            if (self.texture_reload_callback) |callback| {
                if (std.mem.endsWith(u8, file_path, ".png") or
                    std.mem.endsWith(u8, file_path, ".jpg") or
                    std.mem.endsWith(u8, file_path, ".jpeg") or
                    std.mem.endsWith(u8, file_path, ".tga") or
                    std.mem.endsWith(u8, file_path, ".bmp"))
                {
                    callback(file_path, asset_id);
                }
            }
            return;
        }

        // Check if this is an asset file that might be loaded by the AssetManager
        if (self.isAssetFile(file_path)) |asset_id| {
            log(.INFO, "hot_reload", "Hot reloading discovered asset: {s} (ID: {})", .{ file_path, asset_id });

            // Reload the discovered asset
            self.asset_manager.reloadAsset(asset_id, file_path) catch |err| {
                log(.ERROR, "hot_reload", "Failed to reload discovered asset {s}: {}", .{ file_path, err });
                return;
            };

            log(.INFO, "hot_reload", "Successfully hot reloaded discovered asset: {s}", .{file_path});

            // Notify texture reload callback if this is a texture file
            if (self.texture_reload_callback) |callback| {
                if (std.mem.endsWith(u8, file_path, ".png") or
                    std.mem.endsWith(u8, file_path, ".jpg") or
                    std.mem.endsWith(u8, file_path, ".jpeg") or
                    std.mem.endsWith(u8, file_path, ".tga") or
                    std.mem.endsWith(u8, file_path, ".bmp"))
                {
                    callback(file_path, asset_id);
                }
            }
        } else {
            // Check if this is a directory change - scan for specific files
            if (self.isWatchedDirectory(file_path)) {
                log(.DEBUG, "hot_reload", "Directory changed, scanning for modified files: {s}", .{file_path});
                self.scanDirectoryForChanges(file_path);
            } else {
                // This might be a new file or untracked file
                log(.DEBUG, "hot_reload", "File changed but no corresponding asset found: {s}", .{file_path});

                // Try to auto-load new asset files
                self.tryAutoLoadAsset(file_path);
            }
        }
    }

    /// Check if a file path corresponds to a loaded asset and return its ID
    fn isAssetFile(self: *Self, file_path: []const u8) ?AssetId {
        // Ask AssetManager if this path corresponds to any loaded asset
        return self.asset_manager.getAssetId(file_path);
    }

    /// Check if a file should be auto-loaded based on its extension
    fn shouldAutoLoad(self: *Self, file_path: []const u8) bool {
        _ = self; // suppress unused parameter warning

        return std.mem.endsWith(u8, file_path, ".png") or
            std.mem.endsWith(u8, file_path, ".jpg") or
            std.mem.endsWith(u8, file_path, ".jpeg") or
            std.mem.endsWith(u8, file_path, ".tga") or
            std.mem.endsWith(u8, file_path, ".bmp") or
            std.mem.endsWith(u8, file_path, ".obj") or
            std.mem.endsWith(u8, file_path, ".gltf");
    }

    /// Try to automatically load a new asset file
    fn tryAutoLoadAsset(self: *Self, file_path: []const u8) void {
        // Determine asset type from file extension
        if (std.mem.endsWith(u8, file_path, ".png") or
            std.mem.endsWith(u8, file_path, ".jpg") or
            std.mem.endsWith(u8, file_path, ".jpeg"))
        {

            // Try to load as texture
            const asset_id = self.asset_manager.loadAssetAsync(file_path, .texture, .normal) catch {
                log(.DEBUG, "hot_reload", "Could not auto-load texture: {s}", .{file_path});
                return;
            };

            log(.INFO, "hot_reload", "Auto-loaded new texture: {s} (ID: {})", .{ file_path, asset_id });

            // Register for future hot reloading
            self.registerAsset(asset_id, file_path) catch {};

            // Notify texture reload callback for newly loaded texture
            if (self.texture_reload_callback) |callback| {
                callback(file_path, asset_id);
            }
        } else if (std.mem.endsWith(u8, file_path, ".obj") or
            std.mem.endsWith(u8, file_path, ".gltf"))
        {

            // Try to load as mesh
            const asset_id = self.asset_manager.loadAssetAsync(file_path, .mesh, .normal) catch {
                log(.DEBUG, "hot_reload", "Could not auto-load mesh: {s}", .{file_path});
                return;
            };

            log(.INFO, "hot_reload", "Auto-loaded new mesh: {s} (ID: {})", .{ file_path, asset_id });

            // Register for future hot reloading
            self.registerAsset(asset_id, file_path) catch {};
        } else {
            log(.DEBUG, "hot_reload", "Unknown asset type, skipping auto-load: {s}", .{file_path});
        }
    }

    /// Schedule a file for reload with debouncing
    fn scheduleReload(self: *Self, file_path: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.scheduleReloadInternal(file_path);
    }

    /// Internal version of scheduleReload that assumes mutex is already held
    fn scheduleReloadInternal(self: *Self, file_path: []const u8) void {
        const current_time = std.time.milliTimestamp();

        // Clone path if not already in pending
        if (!self.pending_reloads.contains(file_path)) {
            const owned_path = self.allocator.dupe(u8, file_path) catch {
                log(.ERROR, "hot_reload", "Failed to allocate path for reload: {s}", .{file_path});
                return;
            };

            self.pending_reloads.put(owned_path, current_time) catch {
                self.allocator.free(owned_path);
                log(.ERROR, "hot_reload", "Failed to schedule reload for: {s}", .{file_path});
                return;
            };
        } else {
            // Update timestamp for existing pending reload
            if (self.pending_reloads.getPtr(file_path)) |timestamp_ptr| {
                timestamp_ptr.* = current_time;
            }
        }

        log(.DEBUG, "hot_reload", "Scheduled reload for: {s}", .{file_path});
    }

    /// Check if a path is a watched directory (not a specific file)
    fn isWatchedDirectory(self: *Self, path: []const u8) bool {
        // Check if this path corresponds to one of our watched directories
        var iter = self.file_watcher.watched_paths.iterator();
        while (iter.next()) |entry| {
            const watched_path = entry.key_ptr.*;

            // If the path matches exactly a watched directory, it's a directory change
            if (std.mem.eql(u8, path, watched_path)) {
                return true;
            }
        }
        return false;
    }

    /// Scan a directory for recently changed files and process them
    fn scanDirectoryForChanges(self: *Self, directory_path: []const u8) void {
        // Open the directory
        var dir = std.fs.cwd().openDir(directory_path, .{ .iterate = true }) catch |err| {
            log(.ERROR, "hot_reload", "Failed to open directory {s}: {}", .{ directory_path, err });
            return;
        };
        defer dir.close();

        // Iterate through files in the directory
        var iterator = dir.iterate();
        while (iterator.next() catch null) |entry| {
            if (entry.kind == .file) {
                // Build full file path
                const allocator = self.allocator;
                const file_path = std.fs.path.join(allocator, &[_][]const u8{ directory_path, entry.name }) catch continue;
                defer allocator.free(file_path);

                // Check if this file has an associated asset
                if (self.isAssetFile(file_path)) |asset_id| {
                    // Only check files that are registered for hot reload (have metadata)
                    if (self.file_metadata.contains(file_path)) {
                        // Check if the file has actually changed by comparing metadata
                        if (self.hasFileChanged(file_path)) {
                            log(.DEBUG, "hot_reload", "File actually changed, scheduling reload: {s} (ID: {})", .{ file_path, asset_id });

                            // Update our stored metadata
                            self.updateFileMetadata(file_path);

                            // Schedule a reload for this specific asset (using internal version to avoid deadlock)
                            self.scheduleReloadInternal(file_path);
                        } else {
                            log(.DEBUG, "hot_reload", "File metadata unchanged, skipping reload: {s}", .{file_path});
                        }
                    } else {
                        log(.DEBUG, "hot_reload", "File not registered for hot reload, skipping: {s}", .{file_path});
                    }
                } else {
                    // File doesn't have an associated asset - check if it's a new asset file we should auto-load
                    if (self.shouldAutoLoad(file_path)) {
                        log(.INFO, "hot_reload", "Discovered new asset file in directory scan: {s}", .{file_path});
                        self.tryAutoLoadAsset(file_path);
                    }
                }
            }
        }
    }

    /// Get file metadata (modification time and size)
    fn getFileMetadata(self: *Self, file_path: []const u8) !FileMetadata {
        _ = self; // suppress unused parameter warning

        const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
            return err;
        };
        defer file.close();

        const stat = file.stat() catch |err| {
            return err;
        };

        return FileMetadata{
            .last_modified = stat.mtime,
            .file_size = stat.size,
        };
    }

    /// Check if a file has changed since we last saw it
    fn hasFileChanged(self: *Self, file_path: []const u8) bool {
        const current_metadata = self.getFileMetadata(file_path) catch {
            // If we can't get metadata, assume it changed
            return true;
        };

        if (self.file_metadata.get(file_path)) |stored_metadata| {
            return current_metadata.last_modified != stored_metadata.last_modified or
                current_metadata.file_size != stored_metadata.file_size;
        }

        // If we don't have stored metadata, assume it changed
        return true;
    }

    /// Update our stored metadata for a file
    fn updateFileMetadata(self: *Self, file_path: []const u8) void {
        if (self.getFileMetadata(file_path)) |new_metadata| {
            if (self.file_metadata.getPtr(file_path)) |stored_metadata| {
                stored_metadata.* = new_metadata;
                log(.DEBUG, "hot_reload", "Updated metadata for: {s}", .{file_path});
            }
        } else |err| {
            log(.WARN, "hot_reload", "Failed to update metadata for {s}: {}", .{ file_path, err });
        }
    }

    /// Get number of files currently being watched
    pub fn getWatchedFileCount(self: *Self) u32 {
        return @intCast(self.path_to_asset.count());
    }

    /// Get number of events processed (approximation)
    pub fn getProcessedEventCount(self: *Self) u32 {
        return @intCast(self.pending_reloads.count() * 2); // Rough estimate
    }

    /// Get total number of successful reloads (approximation)
    pub fn getTotalReloadCount(self: *Self) u32 {
        return @intCast(self.file_metadata.count()); // Files that have been updated at least once
    }
};

/// Global hot reload manager instance (workaround for callback limitation)
var g_hot_reload_manager: ?*HotReloadManager = null;

/// Set the global hot reload manager for callbacks
pub fn setGlobalHotReloadManager(manager: *HotReloadManager) void {
    g_hot_reload_manager = manager;
}

/// Global file event callback that forwards to the active hot reload manager
pub fn globalFileEventCallback(event: FileWatcher.FileEvent) void {
    if (g_hot_reload_manager) |manager| {
        switch (event.event_type) {
            .modified => {
                manager.scheduleReload(event.path);
            },
            .created => {
                log(.DEBUG, "hot_reload", "New file detected: {s}", .{event.path});
                // Auto-register new assets for known file types
                if (manager.shouldAutoLoad(event.path)) {
                    manager.tryAutoLoadAsset(event.path);
                }
            },
            .deleted => {
                manager.unregisterAsset(event.path);
            },
            .moved => {
                if (event.old_path) |old_path| {
                    manager.unregisterAsset(old_path);
                }
                // Auto-load at new path if it's a supported file type
                if (manager.shouldAutoLoad(event.path)) {
                    manager.tryAutoLoadAsset(event.path);
                }
            },
        }
    }
}
