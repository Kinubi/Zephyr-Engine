const std = @import("std");
const ShaderCompiler = @import("shader_compiler.zig").ShaderCompiler;
const CompiledShader = @import("shader_compiler.zig").CompiledShader;
const CompilationOptions = @import("shader_compiler.zig").CompilationOptions;
const AssetManager = @import("asset_manager.zig").AssetManager;
const TP = @import("../threading/thread_pool.zig");
const ThreadPool = TP.ThreadPool;
const AssetId = @import("asset_types.zig").AssetId;
const FileWatcher = @import("../utils/file_watcher.zig").FileWatcher;
const log = @import("../utils/log.zig").log;
const UnifiedPipelineModule = @import("../rendering/unified_pipeline_system.zig");

// Real-time multithreaded shader hot reload system
// Watches shader files for changes and automatically recompiles them

pub const ShaderWatcher = struct {
    allocator: std.mem.Allocator,
    thread_pool: *ThreadPool,
    shader_compiler: ShaderCompiler,

    // File watching and hot reload state
    watch_directories: std.ArrayList([]const u8),
    watched_shaders: std.HashMap([]const u8, ShaderFileInfo, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),
    // Compilation is handled via the global ThreadPool - we submit work items for compile + delivery

    // Threading and lifecycle (no local threads; rely on app FileWatcher + ThreadPool)
    // Optional external FileWatcher (owned by the application). If set,
    // ShaderWatcher will register directories with the FileWatcher so the
    // centralized watcher can enqueue WorkItems into the ThreadPool.
    external_watcher: ?*FileWatcher = null,

    // Optional pipeline system for shader rebuilds (owned by the application)
    pipeline_system: ?*anyopaque = null,

    pub fn init(allocator: std.mem.Allocator, thread_pool: *ThreadPool) !ShaderWatcher {
        var watcher = ShaderWatcher{
            .allocator = allocator,
            .thread_pool = thread_pool,
            .shader_compiler = try ShaderCompiler.init(allocator),
            .watch_directories = undefined,
            .watched_shaders = std.HashMap([]const u8, ShaderFileInfo, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
            .external_watcher = null,
        };

        watcher.watch_directories = std.ArrayList([]const u8){};

        return watcher;
    }

    /// Configure an external FileWatcher (owned by the application).
    pub fn setFileWatcher(self: *ShaderWatcher, watcher: *FileWatcher) void {
        self.external_watcher = watcher;
    }

    /// Configure the pipeline system for shader rebuilds (owned by the application).
    pub fn setPipelineSystem(self: *ShaderWatcher, pipeline_system: *anyopaque) void {
        self.pipeline_system = pipeline_system;
    }

    pub fn deinit(self: *ShaderWatcher) void {
        self.stop();

        self.shader_compiler.deinit();
        self.watch_directories.deinit(self.allocator);
        self.watched_shaders.deinit();
    }

    pub fn start(self: *ShaderWatcher) !void {
        // ShaderWatcher uses the project's ThreadPool for compilation and
        // relies on an external FileWatcher (if configured) to deliver
        // file events into the pool. Do not spawn an internal thread here.
        _ = self;
        // no local should_stop state when using external FileWatcher.
        // If an external watcher is present, it must be started by the
        // application or the HotReloadManager. We only initialize internal
        // state here.
    }

    pub fn stop(self: *ShaderWatcher) void {
        _ = self;
        // No internal watcher thread to join when running under FileWatcher
    }

    pub fn addWatchDirectory(self: *ShaderWatcher, directory: []const u8) !void {
        const dir_copy = try self.allocator.dupe(u8, directory);
        try self.watch_directories.append(self.allocator, dir_copy);

        // If an external FileWatcher is configured, register the directory with it
        // and also scan the directory to register individual shader files so
        // events include precise file paths and per-file workers can be used.
        if (self.external_watcher) |fw| {
            // Register the directory with a per-watch worker so directory
            // events are delivered to this ShaderWatcher's threadPoolFileEventWorker
            // (mirrors how HotReloadManager registers its per-watch worker).
            try fw.addWatchWithWorker(dir_copy, true, threadPoolFileEventWorker, @as(*anyopaque, self));

            // Scan directory and add individual shader files (this will
            // call addShaderFile which registers per-file watches)
            try self.scanDirectory(directory);
        } else {
            // No external watcher: scan and use internal watcher thread
            try self.scanDirectory(directory);
        }
    }

    fn scanDirectory(self: *ShaderWatcher, directory_path: []const u8) !void {
        var dir = std.fs.cwd().openDir(directory_path, .{ .iterate = true }) catch |err| {
            std.log.warn("Failed to open shader directory {s}: {}", .{ directory_path, err });
            return;
        };
        defer dir.close();

        var iterator = dir.iterate();
        while (try iterator.next()) |entry| {
            // Skip the cached directory to avoid watching compiled shader cache
            if (entry.kind == .directory and std.mem.eql(u8, entry.name, "cached")) {
                continue;
            }

            if (entry.kind == .directory and std.mem.eql(u8, entry.name, "shaders")) {
                continue;
            }

            if (entry.kind == .file) {
                if (isShaderFile(entry.name)) {
                    const full_path = try std.fs.path.join(self.allocator, &.{ directory_path, entry.name });
                    try self.addShaderFile(full_path);
                }
            }
        }
    }

    fn addShaderFile(self: *ShaderWatcher, file_path: []const u8) !void {
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

        if (self.external_watcher) |fw| {
            fw.addWatchWithWorker(file_info.path, false, threadPoolFileEventWorker, @as(*anyopaque, self)) catch |err| {
                std.log.warn("Failed to register shader file with FileWatcher {s}: {}", .{ file_info.path, err });
            };
        }
    }

    /// Handle a file-change event delivered from the FileWatcher inside the ThreadPool.
    /// Compiles the shader immediately and signals the pipeline to rebuild when finished.
    /// This follows the same pattern as hot_reload_manager.onFileChanged.
    pub fn onFileChanged(self: *ShaderWatcher, file_path: []const u8) void {
        // Skip cached outputs - only rebuild from source shaders
        if (std.mem.indexOf(u8, file_path, "assets/shaders/cached") != null or
            std.mem.indexOf(u8, file_path, "shaders/cached") != null)
        {
            log(.DEBUG, "shader_hot_reload", "Ignoring cached shader artifact {s}", .{file_path});
            return;
        }

        const base_name = std.fs.path.basename(file_path);

        // Handle directory-level events by rescanning for new shader files
        if (!isShaderFile(base_name)) {
            // If the path refers to a directory, rescan it to pick up new shaders
            const dir_path = file_path;
            if (std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch null) |dir_val| {
                var dir = dir_val;
                defer dir.close();
                self.scanDirectory(dir_path) catch |err| {
                    std.log.warn("[hot_reload] Failed to rescan shader directory {s}: {}", .{ dir_path, err });
                };
            }
            return;
        }

        // Lookup watched shader entry
        if (self.watched_shaders.getPtr(file_path)) |fi| {
            if (fi.compilation_in_progress) {
                std.log.debug("[hot_reload] Shader {s} already compiling, skipping", .{file_path});
                return;
            }

            // Mark compilation in progress and attempt to update metadata
            fi.compilation_in_progress = true;
            const stat = std.fs.cwd().statFile(file_path) catch |err| {
                std.log.warn("Failed to stat shader on change {s}: {}", .{ file_path, err });
                // clear flag so future events can retry
                fi.compilation_in_progress = false;
                return;
            };
            fi.last_modified = stat.mtime;
            fi.size = stat.size;

            // Compile immediately (we're already on a ThreadPool worker thread)
            const options = CompilationOptions{
                .target = .vulkan,
                .optimization_level = .none,
                .debug_info = true,
                .vulkan_semantics = true,
            };

            var compiled = self.shader_compiler.compileFromFile(file_path, options) catch |err| {
                std.log.err("[hot_reload] Shader compilation failed for {s}: {}", .{ file_path, err });
                fi.compilation_in_progress = false;
                return;
            };

            // Submit to pipeline rebuild worker directly
            if (self.pipeline_system) |pipeline_system_opaque| {
                const pipeline_system: *UnifiedPipelineModule.UnifiedPipelineSystem = @ptrCast(@alignCast(pipeline_system_opaque));

                // Allocate rebuild job to transfer ownership of compiled shader
                // Job only contains file_path and compiled_shader; everything else accessed via system
                const job = pipeline_system.allocator.create(UnifiedPipelineModule.UnifiedPipelineSystem.ShaderRebuildJob) catch |err| {
                    std.log.err("Failed to allocate shader rebuild job: {}", .{err});
                    compiled.deinit(self.allocator);
                    fi.compilation_in_progress = false;
                    return;
                };
                job.* = UnifiedPipelineModule.UnifiedPipelineSystem.ShaderRebuildJob{
                    .file_path = file_path,
                    .compiled_shader = compiled,
                };

                // Submit to pipeline rebuild worker using GPU work (shader_rebuild type)
                const rebuild_work = TP.createGPUWork(
                    0, // id
                    .shader_rebuild, // staging_type
                    AssetId.fromU64(0), // asset_id (unused for shader rebuilds)
                    @as(*anyopaque, job), // staging_data - the ShaderRebuildJob
                    .high, // priority
                    UnifiedPipelineModule.UnifiedPipelineSystem.pipelineRebuildWorker,
                    @as(*anyopaque, pipeline_system), // context - the UnifiedPipelineSystem
                );

                self.thread_pool.submitWork(rebuild_work) catch |err| {
                    std.log.err("Failed to submit pipeline rebuild work for {s}: {}", .{ file_path, err });
                    compiled.deinit(self.allocator);
                    pipeline_system.allocator.destroy(job);
                    fi.compilation_in_progress = false;
                    return;
                };

                log(.INFO, "shader_hot_reload", "Pipeline rebuild work submitted for: {s}", .{file_path});
            } else {
                // No pipeline system available, clean up
                std.log.warn("[hot_reload] No pipeline system available for {s}", .{file_path});
                compiled.deinit(self.allocator);
                fi.compilation_in_progress = false;
            }
        } else {
            // Not currently watching this file — try to add it so future events are tracked
            self.addShaderFile(file_path) catch |err| {
                std.log.warn("Failed to add shader file on change {s}: {}", .{ file_path, err });
            };
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

// Module-level ThreadPool worker is declared below the struct

/// Module-level ThreadPool worker that forwards FileWatcher events into
/// the ShaderWatcher instance. This is registered with FileWatcher so
/// the watcher can enqueue a function pointer (free function).
pub fn threadPoolFileEventWorker(context: *anyopaque, work_item: TP.WorkItem) void {
    const watcher: *ShaderWatcher = @ptrCast(@alignCast(context));

    // Extract file path from custom work item data
    const file_path_ptr: [*]const u8 = @ptrCast(@alignCast(work_item.data.custom.user_data));
    const file_path = file_path_ptr[0..work_item.data.custom.size];

    watcher.onFileChanged(file_path);
} // Supporting types for the shader hot reload system
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

// Performance metrics
pub const ShaderWatcherStats = struct {
    files_watched: u32,
    compilations_completed: u32,
    compilations_failed: u32,
    average_compile_time_ms: f64,
    total_reloads: u32,
};
