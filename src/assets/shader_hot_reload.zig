const std = @import("std");
const ShaderCompiler = @import("shader_compiler.zig").ShaderCompiler;
const CompiledShader = @import("shader_compiler.zig").CompiledShader;
const CompilationOptions = @import("shader_compiler.zig").CompilationOptions;
const AssetManager = @import("asset_manager.zig").AssetManager;
const ThreadPool = @import("../threading/thread_pool.zig").ThreadPool;

// Real-time multithreaded shader hot reload system
// Watches shader files for changes and automatically recompiles them

pub const ShaderWatcher = struct {
    allocator: std.mem.Allocator,
    thread_pool: *ThreadPool,
    shader_compiler: ShaderCompiler,
    asset_manager: *AssetManager,

    // File watching and hot reload state
    watch_directories: std.ArrayList([]const u8),
    watched_shaders: std.HashMap([]const u8, ShaderFileInfo, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),
    compilation_queue: std.ArrayList(CompilationJob),
    compilation_mutex: std.Thread.Mutex,

    // Hot reload callbacks
    shader_reloaded_callbacks: std.ArrayList(ShaderReloadCallback),

    // Threading and lifecycle
    watcher_thread: ?std.Thread,
    compiler_threads: std.ArrayList(std.Thread),
    should_stop: std.atomic.Value(bool),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, thread_pool: *ThreadPool, asset_manager: *AssetManager) !Self {
        var watcher = Self{
            .allocator = allocator,
            .thread_pool = thread_pool,
            .shader_compiler = try ShaderCompiler.init(allocator),
            .asset_manager = asset_manager,
            .watch_directories = undefined,
            .watched_shaders = std.HashMap([]const u8, ShaderFileInfo, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
            .compilation_queue = undefined,
            .compilation_mutex = std.Thread.Mutex{},
            .shader_reloaded_callbacks = undefined,
            .watcher_thread = null,
            .compiler_threads = undefined,
            .should_stop = std.atomic.Value(bool).init(false),
        };

        watcher.watch_directories = std.ArrayList([]const u8){};
        watcher.compilation_queue = std.ArrayList(CompilationJob){};
        watcher.shader_reloaded_callbacks = std.ArrayList(ShaderReloadCallback){};
        watcher.compiler_threads = std.ArrayList(std.Thread){};

        return watcher;
    }

    pub fn deinit(self: *Self) void {
        self.stop();

        self.shader_compiler.deinit();
        self.watch_directories.deinit(self.allocator);
        self.watched_shaders.deinit();
        self.compilation_queue.deinit(self.allocator);
        self.shader_reloaded_callbacks.deinit(self.allocator);
        self.compiler_threads.deinit(self.allocator);
    }

    pub fn start(self: *Self) !void {
        self.should_stop.store(false, .monotonic);

        // Start file watcher thread
        self.watcher_thread = try std.Thread.spawn(.{}, watcherThreadFn, .{self});

        // Start compiler worker threads (4 threads for parallel compilation)
        const num_compiler_threads = @min(4, std.Thread.getCpuCount() catch 4);
        for (0..num_compiler_threads) |i| {
            const thread = try std.Thread.spawn(.{}, compilerThreadFn, .{ self, i });
            try self.compiler_threads.append(self.allocator, thread);
        }
    }

    pub fn stop(self: *Self) void {
        self.should_stop.store(true, .monotonic);

        // Wait for watcher thread
        if (self.watcher_thread) |thread| {
            thread.join();
            self.watcher_thread = null;
        }

        // Wait for all compiler threads
        for (self.compiler_threads.items) |thread| {
            thread.join();
        }
        self.compiler_threads.clearRetainingCapacity();
    }

    pub fn addWatchDirectory(self: *Self, directory: []const u8) !void {
        const dir_copy = try self.allocator.dupe(u8, directory);
        try self.watch_directories.append(self.allocator, dir_copy);

        // Scan for existing shaders in the directory
        try self.scanDirectory(directory);
    }

    pub fn addShaderReloadCallback(self: *Self, callback: ShaderReloadCallback) !void {
        try self.shader_reloaded_callbacks.append(self.allocator, callback);
    }

    fn scanDirectory(self: *Self, directory_path: []const u8) !void {
        var dir = std.fs.cwd().openDir(directory_path, .{ .iterate = true }) catch |err| {
            std.log.warn("Failed to open shader directory {s}: {}", .{ directory_path, err });
            return;
        };
        defer dir.close();

        var iterator = dir.iterate();
        while (try iterator.next()) |entry| {
            if (entry.kind == .file) {
                if (isShaderFile(entry.name)) {
                    const full_path = try std.fs.path.join(self.allocator, &.{ directory_path, entry.name });
                    try self.addShaderFile(full_path);
                }
            }
        }
    }

    fn addShaderFile(self: *Self, file_path: []const u8) !void {
        const stat = std.fs.cwd().statFile(file_path) catch |err| {
            std.log.warn("Failed to stat shader file {s}: {}", .{ file_path, err });
            return;
        };

        const file_info = ShaderFileInfo{
            .path = try self.allocator.dupe(u8, file_path),
            .last_modified = stat.mtime,
            .size = stat.size,
            .compilation_in_progress = false,
        };

        try self.watched_shaders.put(file_info.path, file_info);
    }

    fn watcherThreadFn(self: *Self) void {
        while (!self.should_stop.load(.monotonic)) {
            self.checkForFileChanges() catch |err| {
                std.log.err("Error checking for file changes: {}", .{err});
            };

            // Check every 100ms for file changes
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }
    }

    fn checkForFileChanges(self: *Self) !void {
        var iterator = self.watched_shaders.iterator();
        while (iterator.next()) |entry| {
            const file_info = entry.value_ptr;

            // Skip if compilation is already in progress
            if (file_info.compilation_in_progress) continue;

            const current_stat = std.fs.cwd().statFile(file_info.path) catch |err| {
                switch (err) {
                    error.FileNotFound => {
                        std.log.warn("Shader file deleted: {s}", .{file_info.path});
                        continue;
                    },
                    else => {
                        std.log.err("Failed to stat file {s}: {}", .{ file_info.path, err });
                        continue;
                    },
                }
            };

            // Check if file was modified
            if (current_stat.mtime > file_info.last_modified or current_stat.size != file_info.size) {
                // Mark as compilation in progress
                file_info.compilation_in_progress = true;
                file_info.last_modified = current_stat.mtime;
                file_info.size = current_stat.size;

                // Queue for compilation
                const job = CompilationJob{
                    .file_path = file_info.path,
                    .priority = .high, // File changes get high priority
                    .queued_time = std.time.timestamp(),
                };

                self.compilation_mutex.lock();
                defer self.compilation_mutex.unlock();

                try self.compilation_queue.append(self.allocator, job);
            }
        }
    }

    fn compilerThreadFn(self: *Self, thread_id: usize) void {
        while (!self.should_stop.load(.monotonic)) {
            const job = blk: {
                self.compilation_mutex.lock();
                defer self.compilation_mutex.unlock();

                if (self.compilation_queue.items.len > 0) {
                    break :blk self.compilation_queue.orderedRemove(0);
                } else {
                    break :blk null;
                }
            };

            if (job) |compilation_job| {
                self.processCompilationJob(compilation_job, thread_id) catch |err| {
                    std.log.err("Compilation job failed in thread {}: {}", .{ thread_id, err });
                };
            } else {
                // No jobs available, sleep briefly
                std.Thread.sleep(10 * std.time.ns_per_ms);
            }
        }
    }

    fn processCompilationJob(self: *Self, job: CompilationJob, thread_id: usize) !void {
        const start_time = std.time.microTimestamp();

        // Compile shader with optimized settings for hot reload
        const options = CompilationOptions{
            .target = .vulkan,
            .optimization_level = .none, // Fast compilation for hot reload
            .debug_info = true, // Enable debug info for better error messages
            .vulkan_semantics = true,
        };

        const compiled_shader = self.shader_compiler.compileFromFile(job.file_path, options) catch |err| {
            std.log.err("❌ [Thread {}] Shader compilation failed for {s}: {}", .{ thread_id, job.file_path, err });

            // Mark compilation as no longer in progress
            if (self.watched_shaders.getPtr(job.file_path)) |file_info| {
                file_info.compilation_in_progress = false;
            }

            return err;
        };

        const end_time = std.time.microTimestamp();
        const compile_time_ms = @as(f64, @floatFromInt(end_time - start_time)) / 1000.0;
        _ = compile_time_ms; // Suppress unused variable warning

        // TODO: Update asset manager with new shader when asset integration is complete
        // try self.asset_manager.updateAsset(job.file_path, compiled_shader.asset_data);

        // Notify all callbacks about the reload
        for (self.shader_reloaded_callbacks.items) |callback| {
            callback.onShaderReloaded(job.file_path, compiled_shader);
        }

        // Mark compilation as complete
        if (self.watched_shaders.getPtr(job.file_path)) |file_info| {
            file_info.compilation_in_progress = false;
        }
    }

    fn isShaderFile(filename: []const u8) bool {
        const extensions = &[_][]const u8{ ".glsl", ".vert", ".frag", ".comp", ".geom", ".tesc", ".tese", ".hlsl", ".rchit", ".rgen", ".rmiss", ".rint", ".rahit", ".rcall" };

        for (extensions) |ext| {
            if (std.mem.endsWith(u8, filename, ext)) {
                return true;
            }
        }
        return false;
    }
};

// Supporting types for the shader hot reload system
pub const ShaderFileInfo = struct {
    path: []const u8,
    last_modified: i128,
    size: u64,
    compilation_in_progress: bool,
};

pub const CompilationJob = struct {
    file_path: []const u8,
    priority: Priority,
    queued_time: i64,

    pub const Priority = enum {
        low,
        normal,
        high,
        critical,
    };
};

pub const ShaderReloadCallback = struct {
    context: ?*anyopaque = null,
    onShaderReloaded: *const fn (file_path: []const u8, compiled_shader: CompiledShader) void,
};

// Performance metrics
pub const ShaderWatcherStats = struct {
    files_watched: u32,
    compilations_completed: u32,
    compilations_failed: u32,
    average_compile_time_ms: f64,
    total_reloads: u32,
};

// Tests
test "ShaderWatcher creation" {
    const gpa = std.testing.allocator;

    // Note: This is a basic smoke test - full testing would require mock filesystem
    var thread_pool = try ThreadPool.init(gpa, 4);
    defer thread_pool.deinit();

    var asset_manager = AssetManager.init(gpa);
    defer asset_manager.deinit();

    var watcher = try ShaderWatcher.init(gpa, &thread_pool, &asset_manager);
    defer watcher.deinit();
}
