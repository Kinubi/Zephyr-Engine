const std = @import("std");
const ShaderCompiler = @import("shader_compiler.zig");
const ShaderHotReload = @import("shader_hot_reload.zig");
const ShaderCache = @import("shader_cache.zig");
const AssetManager = @import("asset_manager.zig").AssetManager;
const ThreadPool = @import("../threading/thread_pool.zig").ThreadPool;

// High-level shader management system that coordinates compilation, hot reload,
// and Vulkan pipeline integration

pub const ShaderManager = struct {
    allocator: std.mem.Allocator,

    // Core systems
    compiler: ShaderCompiler.ShaderCompiler,
    hot_reload: ShaderHotReload.ShaderWatcher,
    cache: ShaderCache.ShaderCache,
    asset_manager: *AssetManager,
    thread_pool: *ThreadPool,

    // Shader registry and caching
    loaded_shaders: std.HashMap([]const u8, *LoadedShader, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),
    shader_dependencies: std.HashMap([]const u8, std.ArrayList([]const u8), std.hash_map.StringContext, std.hash_map.default_max_load_percentage), // shader -> dependent pipelines

    // Pipeline integration
    pipeline_reload_callbacks: std.ArrayList(PipelineReloadCallback),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, asset_manager: *AssetManager, thread_pool: *ThreadPool) !Self {
        var manager = Self{
            .allocator = allocator,
            .compiler = try ShaderCompiler.ShaderCompiler.init(allocator),
            .hot_reload = try ShaderHotReload.ShaderWatcher.init(allocator, thread_pool, asset_manager),
            .cache = try ShaderCache.ShaderCache.init(allocator, "shaders/cached"),
            .asset_manager = asset_manager,
            .thread_pool = thread_pool,
            .loaded_shaders = std.HashMap([]const u8, *LoadedShader, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
            .shader_dependencies = std.HashMap([]const u8, std.ArrayList([]const u8), std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
            .pipeline_reload_callbacks = std.ArrayList(PipelineReloadCallback){},
        };

        // Register hot reload callback
        try manager.hot_reload.addShaderReloadCallback(.{
            .context = &manager,
            .onShaderReloaded = onShaderReloaded,
        });

        return manager;
    }

    pub fn deinit(self: *Self) void {
        self.hot_reload.deinit();
        self.cache.deinit();
        self.compiler.deinit();

        // Clean up shader registry
        var shader_iterator = self.loaded_shaders.iterator();
        while (shader_iterator.next()) |entry| {
            entry.value_ptr.*.compiled_shader.deinit(self.allocator);
            self.allocator.free(entry.value_ptr.*.file_path);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.loaded_shaders.deinit();

        // Clean up dependencies
        var dep_iterator = self.shader_dependencies.iterator();
        while (dep_iterator.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.shader_dependencies.deinit();

        self.pipeline_reload_callbacks.deinit(self.allocator);
    }

    pub fn start(self: *Self) !void {
        // Start hot reload system
        try self.hot_reload.start();
    }

    pub fn stop(self: *Self) void {
        self.hot_reload.stop();
    }

    pub fn addShaderDirectory(self: *Self, directory: []const u8) !void {
        try self.hot_reload.addWatchDirectory(directory);
    }

    pub fn loadShader(self: *Self, file_path: []const u8, options: ShaderCompiler.CompilationOptions) !*LoadedShader {
        const path_key = try self.allocator.dupe(u8, file_path);

        // Check if already loaded
        if (self.loaded_shaders.get(path_key)) |existing| {
            self.allocator.free(path_key); // Free the duplicate key
            return existing;
        }

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

        try self.loaded_shaders.put(path_key, loaded);

        return loaded;
    }

    /// Load shader from raw GLSL/HLSL source code
    pub fn loadShaderFromSource(self: *Self, source: ShaderCompiler.ShaderSource, identifier: []const u8, options: ShaderCompiler.CompilationOptions) !*LoadedShader {
        const id_key = try self.allocator.dupe(u8, identifier);

        // Check if already loaded
        if (self.loaded_shaders.get(id_key)) |existing| {
            self.allocator.free(id_key); // Free the duplicate key
            return existing;
        }

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

        try self.loaded_shaders.put(id_key, loaded);

        return loaded;
    }

    pub fn getShader(self: *Self, file_path: []const u8) ?*LoadedShader {
        return self.loaded_shaders.get(file_path);
    }

    pub fn registerPipelineDependency(self: *Self, shader_path: []const u8, pipeline_id: []const u8) !void {
        const shader_key = try self.allocator.dupe(u8, shader_path);
        const pipeline_key = try self.allocator.dupe(u8, pipeline_id);

        if (self.shader_dependencies.getPtr(shader_key)) |deps| {
            try deps.append(self.allocator, pipeline_key);
        } else {
            var deps = std.ArrayList([]const u8){};
            try deps.append(self.allocator, pipeline_key);
            try self.shader_dependencies.put(shader_key, deps);
        }
    }

    pub fn addPipelineReloadCallback(self: *Self, callback: PipelineReloadCallback) !void {
        try self.pipeline_reload_callbacks.append(self.allocator, callback);
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
        // Remove from loaded_shaders if present
        if (self.loaded_shaders.fetchRemove(file_path)) |entry| {
            entry.value.compiled_shader.deinit(self.allocator);
            self.allocator.free(entry.value.file_path);
            self.allocator.destroy(entry.value);
        }

        // Invalidate cache entry
        self.cache.removeCacheEntry(file_path) catch |err| {
            std.log.warn("Failed to remove shader cache entry for {s}: {}", .{ file_path, err });
        };

        // Notify dependent pipelines (if any) via registered callbacks
        if (self.shader_dependencies.getPtr(file_path)) |deps| {
            for (deps.items) |pipeline_name| {
                for (self.pipeline_reload_callbacks.items) |callback| {
                    if (callback.context) |ctx| {
                        callback.onPipelineReload(ctx, file_path, &[_][]const u8{pipeline_name});
                    } else {
                        // No context available for this callback signature; ignore
                    }
                }
            }
        }
    }

    fn onShaderReloaded(context: ?*anyopaque, file_path: []const u8, compiled_shader: ShaderCompiler.CompiledShader) void {
        if (context == null) return;

        const manager = @as(*ShaderManager, @ptrCast(@alignCast(context.?)));

        // Invalidate cache and unload old shader if present
        manager.invalidateShader(file_path) catch |err| {
            std.log.warn("Failed to invalidate shader on reload for {s}: {}", .{ file_path, err });
        };

        // Update loaded_shaders with the newly compiled shader
        // Note: compiled_shader already contains owned spirv_code and reflection
        // Create a new LoadedShader entry and insert it
        const path_key = manager.allocator.dupe(u8, file_path) catch |err| {
            std.log.warn("Failed to duplicate file path for loaded shader: {s} - {}", .{ file_path, err });
            return;
        };

        const loaded = manager.allocator.create(LoadedShader) catch |err| {
            std.log.warn("Failed to allocate LoadedShader for {s}: {}", .{ file_path, err });
            manager.allocator.free(path_key);
            return;
        };

        loaded.* = LoadedShader{
            .file_path = path_key,
            .compiled_shader = compiled_shader,
            .options = ShaderCompiler.CompilationOptions{ .target = .vulkan, .optimization_level = .none, .debug_info = false, .vulkan_semantics = true },
            .load_time = std.time.timestamp(),
            .reload_count = 1,
        };

        // Insert into loaded_shaders (fresh entry)
        manager.loaded_shaders.put(path_key, loaded) catch |err| {
            std.log.warn("Failed to insert loaded shader entry for {s}: {}", .{ file_path, err });
            manager.allocator.free(path_key);
            manager.allocator.destroy(loaded);
            return;
        };

        // Notify pipelines via registered callbacks
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

pub const PipelineReloadCallback = struct {
    context: ?*anyopaque = null,
    onPipelineReload: *const fn (context: ?*anyopaque, shader_path: []const u8, pipeline_ids: []const []const u8) void,
};

pub const ShaderManagerStats = struct {
    loaded_shaders: u32,
    watched_directories: u32,
    pipeline_dependencies: u32,
    active_compiler_threads: u32,
    cached_shaders: u32,
    cache_directory: []const u8,
};

// Convenience functions for common operations
pub fn createDefaultShaderManager(allocator: std.mem.Allocator, asset_manager: *AssetManager) !ShaderManager {
    // Create thread pool for parallel compilation
    var thread_pool = try ThreadPool.init(allocator, std.Thread.getCpuCount() catch 4);

    var manager = try ShaderManager.init(allocator, asset_manager, &thread_pool);

    // Add common shader directories
    try manager.addShaderDirectory("shaders");
    try manager.addShaderDirectory("assets/shaders");

    return manager;
}
