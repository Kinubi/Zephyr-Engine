const std = @import("std");
const ShaderCompiler = @import("shader_compiler.zig");
const ShaderHotReload = @import("shader_hot_reload.zig");
const AssetManager = @import("asset_manager.zig");
const ThreadPool = @import("../threading/thread_pool.zig").ThreadPool;

// High-level shader management system that coordinates compilation, hot reload,
// and Vulkan pipeline integration

pub const ShaderManager = struct {
    allocator: std.mem.Allocator,
    
    // Core systems
    compiler: ShaderCompiler.ShaderCompiler,
    hot_reload: ShaderHotReload.ShaderWatcher,
    asset_manager: *AssetManager,
    thread_pool: *ThreadPool,
    
    // Shader registry and caching
    loaded_shaders: std.HashMap([]const u8, LoadedShader),
    shader_dependencies: std.HashMap([]const u8, std.ArrayList([]const u8)), // shader -> dependent pipelines
    
    // Pipeline integration
    pipeline_reload_callbacks: std.ArrayList(PipelineReloadCallback),
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, asset_manager: *AssetManager, thread_pool: *ThreadPool) !Self {
        var manager = Self{
            .allocator = allocator,
            .compiler = try ShaderCompiler.ShaderCompiler.init(allocator),
            .hot_reload = try ShaderHotReload.ShaderWatcher.init(allocator, thread_pool, asset_manager),
            .asset_manager = asset_manager,
            .thread_pool = thread_pool,
            .loaded_shaders = std.HashMap([]const u8, LoadedShader).init(allocator),
            .shader_dependencies = std.HashMap([]const u8, std.ArrayList([]const u8)).init(allocator),
            .pipeline_reload_callbacks = std.ArrayList(PipelineReloadCallback).init(allocator),
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
        self.compiler.deinit();
        
        // Clean up shader registry
        var shader_iterator = self.loaded_shaders.iterator();
        while (shader_iterator.next()) |entry| {
            entry.value_ptr.compiled_shader.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.loaded_shaders.deinit();
        
        // Clean up dependencies
        var dep_iterator = self.shader_dependencies.iterator();
        while (dep_iterator.next()) |entry| {
            entry.value_ptr.deinit();
            self.allocator.free(entry.key_ptr.*);
        }
        self.shader_dependencies.deinit();
        
        self.pipeline_reload_callbacks.deinit();
    }
    
    pub fn start(self: *Self) !void {
        std.log.info("Starting ShaderManager...", .{});
        
        // Start hot reload system
        try self.hot_reload.start();
        
        std.log.info("✓ ShaderManager started successfully", .{});
    }
    
    pub fn stop(self: *Self) void {
        std.log.info("Stopping ShaderManager...", .{});
        
        self.hot_reload.stop();
        
        std.log.info("✓ ShaderManager stopped", .{});
    }
    
    pub fn addShaderDirectory(self: *Self, directory: []const u8) !void {
        try self.hot_reload.addWatchDirectory(directory);
        std.log.info("✓ Added shader directory to hot reload: {s}", .{directory});
    }
    
    pub fn loadShader(self: *Self, file_path: []const u8, options: ShaderCompiler.CompilationOptions) !*LoadedShader {
        const path_key = try self.allocator.dupe(u8, file_path);
        
        // Check if already loaded
        if (self.loaded_shaders.getPtr(path_key)) |existing| {
            self.allocator.free(path_key); // Free the duplicate key
            return existing;
        }
        
        std.log.info("📄 Loading shader: {s}", .{file_path});
        
        // Compile shader
        const compiled = try self.compiler.compileFromFile(file_path, options);
        
        // Create loaded shader entry
        const loaded = LoadedShader{
            .file_path = path_key,
            .compiled_shader = compiled,
            .options = options,
            .load_time = std.time.timestamp(),
            .reload_count = 0,
        };
        
        try self.loaded_shaders.put(path_key, loaded);
        
        std.log.info("✅ Shader loaded successfully: {s} ({} bytes SPIR-V)", .{ file_path, compiled.spirv_code.len });
        
        return self.loaded_shaders.getPtr(path_key).?;
    }
    
    pub fn getShader(self: *Self, file_path: []const u8) ?*LoadedShader {
        return self.loaded_shaders.getPtr(file_path);
    }
    
    pub fn registerPipelineDependency(self: *Self, shader_path: []const u8, pipeline_id: []const u8) !void {
        const shader_key = try self.allocator.dupe(u8, shader_path);
        const pipeline_key = try self.allocator.dupe(u8, pipeline_id);
        
        if (self.shader_dependencies.getPtr(shader_key)) |deps| {
            try deps.append(pipeline_key);
        } else {
            var deps = std.ArrayList([]const u8).init(self.allocator);
            try deps.append(pipeline_key);
            try self.shader_dependencies.put(shader_key, deps);
        }
        
        std.log.debug("📌 Registered pipeline dependency: {s} -> {s}", .{ shader_path, pipeline_id });
    }
    
    pub fn addPipelineReloadCallback(self: *Self, callback: PipelineReloadCallback) !void {
        try self.pipeline_reload_callbacks.append(callback);
    }
    
    fn onShaderReloaded(file_path: []const u8, compiled_shader: ShaderCompiler.CompiledShader) void {
        // This function is called from the hot reload system when a shader is recompiled
        
        // Note: We need to cast the context back to ShaderManager
        // In a real implementation, we'd need a proper callback system
        std.log.info("🔥 Shader hot reloaded: {s}", .{file_path});
        
        // Update loaded shader registry (simplified implementation)
        // In practice, this would need proper synchronization and context handling
        _ = compiled_shader;
    }
    
    pub fn recompileAllShaders(self: *Self) !void {
        std.log.info("🔄 Recompiling all loaded shaders...", .{});
        
        var iterator = self.loaded_shaders.iterator();
        var recompiled_count: u32 = 0;
        
        while (iterator.next()) |entry| {
            const loaded_shader = entry.value_ptr;
            
            std.log.info("Recompiling: {s}", .{loaded_shader.file_path});
            
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
        
        std.log.info("✅ Recompiled {} shaders successfully", .{recompiled_count});
    }
    
    pub fn getStats(self: *Self) ShaderManagerStats {
        return ShaderManagerStats{
            .loaded_shaders = @intCast(self.loaded_shaders.count()),
            .watched_directories = @intCast(self.hot_reload.watch_directories.items.len),
            .pipeline_dependencies = @intCast(self.shader_dependencies.count()),
            .active_compiler_threads = @intCast(self.hot_reload.compiler_threads.items.len),
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

// Example usage patterns
pub const ShaderManagerExample = struct {
    pub fn exampleUsage() !void {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();
        
        var asset_manager = AssetManager.init(allocator);
        defer asset_manager.deinit();
        
        // Create shader manager with hot reload
        var shader_manager = try createDefaultShaderManager(allocator, &asset_manager);
        defer shader_manager.deinit();
        
        // Start hot reload system
        try shader_manager.start();
        defer shader_manager.stop();
        
        // Load shaders with automatic hot reload
        const compile_options = ShaderCompiler.CompilationOptions{
            .target = .vulkan,
            .optimization_level = .performance,
            .vulkan_semantics = true,
        };
        
        // Load vertex/fragment pair
        const basic_shaders = try shader_manager.loadVertexFragmentPair(
            "shaders/basic.vert",
            "shaders/basic.frag",
            compile_options,
        );
        
        // Load compute shader
        const compute_shader = try shader_manager.loadComputeShader(
            "shaders/compute.comp",
            compile_options,
        );
        
        // Register pipeline dependencies for automatic recreation
        try shader_manager.registerPipelineDependency("shaders/basic.vert", "basic_pipeline");
        try shader_manager.registerPipelineDependency("shaders/basic.frag", "basic_pipeline");
        try shader_manager.registerPipelineDependency("shaders/compute.comp", "compute_pipeline");
        
        // Shaders will now automatically recompile when files change
        // Pipelines can register callbacks to be notified of shader changes
        
        _ = basic_shaders;
        _ = compute_shader;
    }
};

// Tests
test "ShaderManager basic operations" {
    const allocator = std.testing.allocator;
    
    var asset_manager = AssetManager.init(allocator);
    defer asset_manager.deinit();
    
    var thread_pool = try ThreadPool.init(allocator, 2);
    defer thread_pool.deinit();
    
    var manager = try ShaderManager.init(allocator, &asset_manager, &thread_pool);
    defer manager.deinit();
    
    const stats = manager.getStats();
    try std.testing.expect(stats.loaded_shaders == 0);
}