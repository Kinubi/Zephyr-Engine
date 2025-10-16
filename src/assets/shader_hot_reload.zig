const std = @import("std");
const ShaderCompiler = @import("shader_compiler.zig").ShaderCompiler;
const CompiledShader = @import("shader_compiler.zig").CompiledShader;
const CompilationOptions = @import("shader_compiler.zig").CompilationOptions;
const AssetManager = @import("asset_manager.zig").AssetManager;
const TP = @import("../threading/thread_pool.zig");
const ThreadPool = TP.ThreadPool;
const AssetId = @import("asset_types.zig").AssetId;

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
    compilation_mutex: std.Thread.Mutex = .{},
    compilation_queue: std.ArrayList(CompilationJob),
    // For compatibility with existing stats reporting (no internal compiler threads when using ThreadPool)
    compiler_threads: std.ArrayList(?std.Thread),
    // Compilation is handled via the global ThreadPool - we submit work items for compile + delivery

    // Hot reload callbacks
    shader_reloaded_callbacks: std.ArrayList(ShaderReloadCallback),

    // Threading and lifecycle
    watcher_thread: ?std.Thread,
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
            .compilation_queue = std.ArrayList(CompilationJob){},
            .compiler_threads = std.ArrayList(?std.Thread){},
            .shader_reloaded_callbacks = undefined,
            .watcher_thread = null,
            .should_stop = std.atomic.Value(bool).init(false),
        };

        watcher.watch_directories = std.ArrayList([]const u8){};
        watcher.shader_reloaded_callbacks = std.ArrayList(ShaderReloadCallback){};

        return watcher;
    }

    pub fn deinit(self: *Self) void {
        self.stop();

        self.shader_compiler.deinit();
        self.watch_directories.deinit(self.allocator);
        self.watched_shaders.deinit();
        self.shader_reloaded_callbacks.deinit(self.allocator);
        self.compilation_queue.deinit(self.allocator);
        self.compiler_threads.deinit(self.allocator);
    }

    pub fn start(self: *Self) !void {
        self.should_stop.store(false, .monotonic);

        // Start file watcher thread
        self.watcher_thread = try std.Thread.spawn(.{}, watcherThreadFn, .{self});

        // Compilation handled by ThreadPool - submit compile work items from watcher
    }

    pub fn stop(self: *Self) void {
        self.should_stop.store(true, .monotonic);

        // Wait for watcher thread
        if (self.watcher_thread) |thread| {
            thread.join();
            self.watcher_thread = null;
        }

        // No internal compiler threads to join (ThreadPool handles compilation workers)
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

            // Drain compilation queue and submit compile work to the ThreadPool
            self.compilation_mutex.lock();
            while (self.compilation_queue.items.len > 0) {
                const job = self.compilation_queue.orderedRemove(0);
                // Build a WorkItem for hot_reload compilation
                const work_item = TP.WorkItem{
                    .id = 0,
                    .item_type = TP.WorkItemType.hot_reload,
                    .priority = TP.WorkPriority.high,
                    .data = .{ .hot_reload = .{ .file_path = job.file_path, .asset_id = AssetId.fromU64(0) } },
                    .worker_fn = compileWorker,
                    .context = @as(*anyopaque, self),
                };

                // Submit compile job to the thread pool
                self.compilation_mutex.unlock();
                self.thread_pool.submitWork(work_item) catch |err| {
                    std.log.err("Failed to submit shader compile job for {s}: {}", .{ job.file_path, err });
                    // mark compilation as not in progress so watcher can retry
                    if (self.watched_shaders.getPtr(job.file_path)) |fi| fi.compilation_in_progress = false;
                };
                self.compilation_mutex.lock();
            }
            self.compilation_mutex.unlock();

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

    // Removed internal compiler thread function; compilation is submitted to ThreadPool

    // Worker run by ThreadPool to compile a shader. Runs on a pool thread.
    pub fn compileWorker(context: *anyopaque, _work_item: TP.WorkItem) void {
        const watcher: *ShaderWatcher = @ptrCast(@alignCast(context));
        const file_path = _work_item.data.hot_reload.file_path;
        const options = CompilationOptions{
            .target = .vulkan,
            .optimization_level = .none,
            .debug_info = true,
            .vulkan_semantics = true,
        };

        var compiled = watcher.shader_compiler.compileFromFile(file_path, options) catch |err| {
            std.log.err("[hot_reload] Shader compilation failed for {s}: {}", .{ file_path, err });
            // clear flag
            if (watcher.watched_shaders.getPtr(file_path)) |fi| fi.compilation_in_progress = false;
            return;
        };

        // Allocate delivery job (owned by the GPU worker job)
        const delivery = watcher.allocator.create(DeliveryJob) catch |err| {
            // If allocation fails, clean up compiled shader and clear flag
            compiled.deinit(watcher.allocator);
            if (watcher.watched_shaders.getPtr(file_path)) |fi| fi.compilation_in_progress = false;
            std.log.err("Failed to allocate delivery job: {}", .{err});
            return;
        };
        delivery.* = DeliveryJob{ .file_path = file_path, .compiled_shader = compiled };

        // Submit GPU/worker job to perform pipeline rebuild (may use thread-local command pool)
        const gpu_work_item = TP.createGPUWork(
            0,
            TP.GPUWork.texture,
            AssetId.fromU64(0),
            @as(*anyopaque, delivery),
            TP.WorkPriority.high,
            rebuildWorker,
            @as(*anyopaque, watcher),
        );

        watcher.thread_pool.submitWork(gpu_work_item) catch |err| {
            // On submit failure, cleanup
            delivery.compiled_shader.deinit(watcher.allocator);
            watcher.allocator.destroy(delivery);
            if (watcher.watched_shaders.getPtr(file_path)) |fi| fi.compilation_in_progress = false;
            std.log.err("Failed to submit rebuild work: {}", .{err});
            return;
        };

        // optional timing omitted
    }

    // Delivery job structure (heap allocated) to transfer ownership into ThreadPool worker
    const DeliveryJob = struct {
        file_path: []const u8,
        compiled_shader: CompiledShader,
    };

    // Worker run by ThreadPool (GPU worker) to call pipeline rebuild callbacks and perform GPU work
    pub fn rebuildWorker(context: *anyopaque, work_item: TP.WorkItem) void {
        const watcher: *ShaderWatcher = @ptrCast(@alignCast(context));
        const delivery: *DeliveryJob = @ptrCast(@alignCast(work_item.data.gpu_work.data));

        for (watcher.shader_reloaded_callbacks.items) |callback| {
            callback.onShaderReloaded(callback.context, delivery.file_path, delivery.compiled_shader);
        }

        // Clean up and clear compilation flag
        delivery.compiled_shader.deinit(watcher.allocator);
        watcher.allocator.destroy(delivery);
        if (watcher.watched_shaders.getPtr(delivery.file_path)) |fi| fi.compilation_in_progress = false;
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
    onShaderReloaded: *const fn (context: ?*anyopaque, file_path: []const u8, compiled_shader: CompiledShader) void,
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
