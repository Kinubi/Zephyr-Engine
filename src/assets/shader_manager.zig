const std = @import("std");
const ShaderCompiler = @import("shader_compiler.zig");
const ShaderHotReload = @import("shader_hot_reload.zig");
const TP = @import("../threading/thread_pool.zig");
const FileWatcher = @import("../utils/file_watcher.zig").FileWatcher;
const ShaderCache = @import("shader_cache.zig");
const AssetManager = @import("asset_manager.zig").AssetManager;
const ThreadPool = @import("../threading/thread_pool.zig").ThreadPool;

// High-level shader management system that coordinates compilation, hot reload,
// and Vulkan pipeline integration

pub const ShaderManager = struct {
    allocator: std.mem.Allocator,

    // Protects loaded_shaders and shader_dependencies from concurrent access
    manager_mutex: std.Thread.Mutex = .{},

    // Core systems
    compiler: ShaderCompiler.ShaderCompiler,
    hot_reload: ShaderHotReload.ShaderWatcher,
    // (FileWatcher is not owned by the manager; it's passed into the
    // hot_reload subsystem when available.)
    cache: ShaderCache.ShaderCache,

    thread_pool: *ThreadPool,

    // Shader registry and caching
    loaded_shaders: std.HashMap([]const u8, *LoadedShader, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),
    shader_dependencies: std.HashMap([]const u8, std.ArrayList([]const u8), std.hash_map.StringContext, std.hash_map.default_max_load_percentage), // shader -> dependent pipelines

    // Pipeline integration

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, thread_pool: *ThreadPool, file_watcher: ?*FileWatcher) !Self {
        var manager = Self{
            .allocator = allocator,
            .compiler = try ShaderCompiler.ShaderCompiler.init(allocator),
            .hot_reload = try ShaderHotReload.ShaderWatcher.init(allocator, thread_pool),
            .cache = try ShaderCache.ShaderCache.init(allocator, "shaders/cached"),
            .thread_pool = thread_pool,
            .loaded_shaders = std.HashMap([]const u8, *LoadedShader, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
            .shader_dependencies = std.HashMap([]const u8, std.ArrayList([]const u8), std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
        };

        // If the application provided a FileWatcher, forward it to the hot_reload subsystem
        if (file_watcher) |fw| manager.hot_reload.setFileWatcher(fw);

        return manager;
    }

    pub fn deinit(self: *Self) void {
        self.hot_reload.deinit();
        self.cache.deinit();
        self.compiler.deinit();

        // Clean up shader registry (guard against concurrent access)
        self.manager_mutex.lock();
        var shader_iterator = self.loaded_shaders.iterator();
        while (shader_iterator.next()) |entry| {
            entry.value_ptr.*.compiled_shader.deinit(self.allocator);
            self.allocator.free(entry.value_ptr.*.file_path);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.loaded_shaders.deinit();
        self.manager_mutex.unlock();

        // Clean up dependencies (guard)
        self.manager_mutex.lock();
        var dep_iterator = self.shader_dependencies.iterator();
        while (dep_iterator.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.shader_dependencies.deinit();
        self.manager_mutex.unlock();
    }

    pub fn start(self: *Self) !void {
        // Start hot reload system
        try self.hot_reload.start();
    }

    pub fn stop(self: *Self) void {
        self.hot_reload.stop();
    }

    pub fn setPipelineSystem(self: *Self, pipeline_system: *anyopaque) void {
        self.hot_reload.setPipelineSystem(pipeline_system);
    }

    pub fn addShaderDirectory(self: *Self, directory: []const u8) !void {
        try self.hot_reload.addWatchDirectory(directory);
    }

    pub fn loadShader(self: *Self, file_path: []const u8, options: ShaderCompiler.CompilationOptions) !*LoadedShader {
        const path_key = try self.allocator.dupe(u8, file_path);

        // Check if already loaded
        self.manager_mutex.lock();
        if (self.loaded_shaders.get(path_key)) |existing| {
            self.manager_mutex.unlock();
            self.allocator.free(path_key); // Free the duplicate key
            return existing;
        }
        self.manager_mutex.unlock();

        // Use cache for compilation - this will automatically handle file hashing and caching
        const compiled = try self.cache.getCompiledShader(&self.compiler, file_path, options);

        // Create loaded shader entry (heap allocated)
        const loaded = try self.allocator.create(LoadedShader);
        loaded.* = LoadedShader{
            .file_path = path_key,
            .compiled_shader = compiled,
            .options = options,
            .load_time = std.time.timestamp(),
            .reload_count = 0,
        };

        self.manager_mutex.lock();
        try self.loaded_shaders.put(path_key, loaded);
        self.manager_mutex.unlock();

        return loaded;
    }

    /// Load shader from raw GLSL/HLSL source code
    pub fn loadShaderFromSource(self: *Self, source: ShaderCompiler.ShaderSource, identifier: []const u8, options: ShaderCompiler.CompilationOptions) !*LoadedShader {
        const id_key = try self.allocator.dupe(u8, identifier);

        // Check if already loaded
        self.manager_mutex.lock();
        if (self.loaded_shaders.get(id_key)) |existing| {
            self.manager_mutex.unlock();
            self.allocator.free(id_key); // Free the duplicate key
            return existing;
        }
        self.manager_mutex.unlock();

        // Use cache for compilation - this will automatically handle source hashing and caching
        const compiled = try self.cache.getCompiledShaderFromSource(&self.compiler, source, identifier, options);

        // Create loaded shader entry (heap allocated)
        const loaded = try self.allocator.create(LoadedShader);
        loaded.* = LoadedShader{
            .file_path = id_key,
            .compiled_shader = compiled,
            .options = options,
            .load_time = std.time.timestamp(),
            .reload_count = 0,
        };

        self.manager_mutex.lock();
        try self.loaded_shaders.put(id_key, loaded);
        self.manager_mutex.unlock();

        return loaded;
    }

    pub fn getShader(self: *Self, file_path: []const u8) ?*LoadedShader {
        self.manager_mutex.lock();
        const res = self.loaded_shaders.get(file_path);
        self.manager_mutex.unlock();
        return res;
    }

    pub fn registerPipelineDependency(self: *Self, shader_path: []const u8, pipeline_id: []const u8) !void {
        const shader_key = try self.allocator.dupe(u8, shader_path);
        const pipeline_key = try self.allocator.dupe(u8, pipeline_id);

        self.manager_mutex.lock();
        if (self.shader_dependencies.getPtr(shader_key)) |deps| {
            try deps.append(self.allocator, pipeline_key);
        } else {
            var deps = std.ArrayList([]const u8){};
            try deps.append(self.allocator, pipeline_key);
            try self.shader_dependencies.put(shader_key, deps);
        }
        self.manager_mutex.unlock();
    }

    /// Clear all cached shaders (useful for development/debugging)
    pub fn clearShaderCache(self: *Self) !void {
        try self.cache.clearCache();
    }

    /// Force recompilation of a specific shader (bypasses cache)
    pub fn forceRecompileShader(self: *Self, file_path: []const u8, options: ShaderCompiler.CompilationOptions) !*LoadedShader {
        // Invalidate and unload the shader (if loaded), then recompile
        try self.invalidateShader(file_path);

        // Recompile directly (bypassing cache)
        const compiled = try self.compiler.compileFromFile(file_path, options);
        const path_key = try self.allocator.dupe(u8, file_path);

        const loaded = try self.allocator.create(LoadedShader);
        loaded.* = LoadedShader{
            .file_path = path_key,
            .compiled_shader = compiled,
            .options = options,
            .load_time = std.time.timestamp(),
            .reload_count = 0,
        };

        try self.loaded_shaders.put(path_key, loaded);

        return loaded;
    }

    /// Invalidate a shader: remove loaded entry, clear cache, and notify dependent pipelines
    pub fn invalidateShader(self: *Self, file_path: []const u8) !void {
        // Remove from loaded_shaders if present (guarded)
        self.manager_mutex.lock();
        // Check if the shader exists before trying to remove it
        // This prevents HashMap panics when the shader is being compiled for the first time
        if (self.loaded_shaders.contains(file_path)) {
            if (self.loaded_shaders.fetchRemove(file_path)) |entry| {
                entry.value.compiled_shader.deinit(self.allocator);
                self.allocator.free(entry.value.file_path);
                self.allocator.destroy(entry.value);
            }
        }
        self.manager_mutex.unlock();

        // Invalidate cache entry
        self.cache.removeCacheEntry(file_path) catch |err| {
            std.log.warn("Failed to remove shader cache entry for {s}: {}", .{ file_path, err });
        };
    }

    /// Public method called by the pipeline rebuild worker after shader compilation
    /// Takes ownership of the compiled_shader
    pub fn onShaderCompiledFromHotReload(self: *Self, file_path: []const u8, compiled_shader: ShaderCompiler.CompiledShader) !void {
        // Invalidate cache and unload old shader if present
        self.invalidateShader(file_path) catch |err| {
            std.log.warn("Failed to invalidate shader on reload for {s}: {}", .{ file_path, err });
        };

        // Update loaded_shaders with the newly compiled shader
        // Note: compiled_shader already contains owned spirv_code and reflection
        // Create a new LoadedShader entry and insert it
        const path_key = try self.allocator.dupe(u8, file_path);
        errdefer self.allocator.free(path_key);

        const loaded = try self.allocator.create(LoadedShader);
        errdefer self.allocator.destroy(loaded);

        loaded.* = LoadedShader{
            .file_path = path_key,
            .compiled_shader = compiled_shader,
            .options = ShaderCompiler.CompilationOptions{ .target = .vulkan, .optimization_level = .none, .debug_info = false, .vulkan_semantics = true },
            .load_time = std.time.timestamp(),
            .reload_count = 1,
        };

        // Insert into loaded_shaders (fresh entry) under lock
        self.manager_mutex.lock();
        defer self.manager_mutex.unlock();

        try self.loaded_shaders.put(path_key, loaded);
    }

    pub fn recompileAllShaders(self: *Self) !void {
        var iterator = self.loaded_shaders.iterator();
        var recompiled_count: u32 = 0;

        while (iterator.next()) |entry| {
            const loaded_shader = entry.value_ptr.*;

            // Recompile with the same options
            const new_compiled = self.compiler.compileFromFile(loaded_shader.file_path, loaded_shader.options) catch |err| {
                std.log.err("Failed to recompile shader {s}: {}", .{ loaded_shader.file_path, err });
                continue;
            };

            // Clean up old shader data
            loaded_shader.compiled_shader.deinit(self.allocator);

            // Update with new data
            loaded_shader.compiled_shader = new_compiled;
            loaded_shader.reload_count += 1;

            recompiled_count += 1;
        }
    }

    pub fn getStats(self: *Self) ShaderManagerStats {
        const cache_stats = self.cache.getCacheStats();
        return ShaderManagerStats{
            .loaded_shaders = @intCast(self.loaded_shaders.count()),
            .watched_directories = @intCast(self.hot_reload.watch_directories.items.len),
            .pipeline_dependencies = @intCast(self.shader_dependencies.count()),
            .active_compiler_threads = @intCast(self.hot_reload.compiler_threads.items.len),
            .cached_shaders = cache_stats.total_cached_shaders,
            .cache_directory = cache_stats.cache_directory,
        };
    }

    // Utility functions for common shader loading patterns
    pub fn loadVertexFragmentPair(self: *Self, vertex_path: []const u8, fragment_path: []const u8, options: ShaderCompiler.CompilationOptions) !ShaderPair {
        const vertex = try self.loadShader(vertex_path, options);
        const fragment = try self.loadShader(fragment_path, options);

        return ShaderPair{
            .vertex = vertex,
            .fragment = fragment,
        };
    }

    pub fn loadComputeShader(self: *Self, compute_path: []const u8, options: ShaderCompiler.CompilationOptions) !*LoadedShader {
        return try self.loadShader(compute_path, options);
    }
};

// Supporting types
pub const LoadedShader = struct {
    file_path: []const u8,
    compiled_shader: ShaderCompiler.CompiledShader,
    options: ShaderCompiler.CompilationOptions,
    load_time: i64,
    reload_count: u32,
};

pub const ShaderPair = struct {
    vertex: *LoadedShader,
    fragment: *LoadedShader,
};

pub const ShaderManagerStats = struct {
    loaded_shaders: u32,
    watched_directories: u32,
    pipeline_dependencies: u32,
    active_compiler_threads: u32,
    cached_shaders: u32,
    cache_directory: []const u8,
};
