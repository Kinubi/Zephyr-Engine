const std = @import("std");
const ShaderManager = @import("shader_manager.zig").ShaderManager;
const AssetManager = @import("asset_manager.zig");
const ThreadPool = @import("../threading/thread_pool.zig").ThreadPool;

// Example integration of the shader hot reload system with ZulkanZengine
// This demonstrates how to integrate real-time shader compilation with the engine

pub const EngineShaderIntegration = struct {
    allocator: std.mem.Allocator,
    shader_manager: ShaderManager,
    
    // Engine integration state
    vulkan_device: ?*anyopaque, // VkDevice in real implementation
    pipeline_cache: std.HashMap([]const u8, PipelineInfo),
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, vulkan_device: ?*anyopaque) !Self {
        var asset_manager = AssetManager.init(allocator);
        
        // Create shader manager with hot reload support
        const shader_manager = try ShaderManager.createDefaultShaderManager(allocator, &asset_manager);
        
        var integration = Self{
            .allocator = allocator,
            .shader_manager = shader_manager,
            .vulkan_device = vulkan_device,
            .pipeline_cache = std.HashMap([]const u8, PipelineInfo).init(allocator),
        };
        
        // Register pipeline reload callback
        try integration.shader_manager.addPipelineReloadCallback(.{
            .context = &integration,
            .onPipelineReload = onPipelineReloadRequired,
        });
        
        return integration;
    }
    
    pub fn deinit(self: *Self) void {
        self.pipeline_cache.deinit();
        self.shader_manager.deinit();
    }
    
    pub fn start(self: *Self) !void {
        std.log.info("🚀 Starting ZulkanZengine Shader Integration...", .{});
        
        // Start shader manager
        try self.shader_manager.start();
        
        // Pre-load essential shaders
        try self.loadEssentialShaders();
        
        std.log.info("✅ ZulkanZengine Shader Integration started successfully", .{});
    }
    
    pub fn stop(self: *Self) void {
        std.log.info("Stopping ZulkanZengine Shader Integration...", .{});
        
        self.shader_manager.stop();
        
        std.log.info("✅ ZulkanZengine Shader Integration stopped", .{});
    }
    
    fn loadEssentialShaders(self: *Self) !void {
        const compile_options = ShaderManager.ShaderCompiler.CompilationOptions{
            .target = .vulkan,
            .optimization_level = .performance,
            .vulkan_semantics = true,
            .glsl_version = 450,
        };
        
        std.log.info("📚 Loading essential shaders...", .{});
        
        // Load core rendering shaders
        _ = try self.shader_manager.loadVertexFragmentPair(
            "shaders/simple.vert",
            "shaders/simple.frag", 
            compile_options,
        );
        
        _ = try self.shader_manager.loadVertexFragmentPair(
            "shaders/point_light.vert",
            "shaders/point_light.frag",
            compile_options,
        );
        
        _ = try self.shader_manager.loadVertexFragmentPair(
            "shaders/textured.vert",
            "shaders/textured.frag",
            compile_options,
        );
        
        // Load compute shaders
        _ = try self.shader_manager.loadComputeShader(
            "shaders/particles.comp",
            compile_options,
        );
        
        // Register pipeline dependencies
        try self.registerPipelineDependencies();
        
        std.log.info("✅ Essential shaders loaded successfully", .{});
    }
    
    fn registerPipelineDependencies(self: *Self) !void {
        const dependencies = &[_]struct{ shader: []const u8, pipeline: []const u8 }{
            .{ .shader = "shaders/simple.vert", .pipeline = "simple_pipeline" },
            .{ .shader = "shaders/simple.frag", .pipeline = "simple_pipeline" },
            .{ .shader = "shaders/point_light.vert", .pipeline = "point_light_pipeline" },
            .{ .shader = "shaders/point_light.frag", .pipeline = "point_light_pipeline" },
            .{ .shader = "shaders/textured.vert", .pipeline = "textured_pipeline" },
            .{ .shader = "shaders/textured.frag", .pipeline = "textured_pipeline" },
            .{ .shader = "shaders/particles.comp", .pipeline = "particles_compute_pipeline" },
        };
        
        for (dependencies) |dep| {
            try self.shader_manager.registerPipelineDependency(dep.shader, dep.pipeline);
        }
        
        std.log.debug("Registered {} pipeline dependencies", .{dependencies.len});
    }
    
    fn onPipelineReloadRequired(context: ?*anyopaque, shader_path: []const u8, pipeline_ids: []const []const u8) void {
        _ = context; // Cast back to EngineShaderIntegration in real implementation
        
        std.log.info("🔧 Pipeline reload required for shader: {s}", .{shader_path});
        std.log.info("   Affected pipelines: {}", .{pipeline_ids.len});
        
        for (pipeline_ids) |pipeline_id| {
            std.log.info("   - {s}", .{pipeline_id});
            
            // In real implementation:
            // 1. Invalidate existing Vulkan pipeline
            // 2. Recreate pipeline with new shader SPIR-V
            // 3. Update descriptor sets if needed
            // 4. Notify renderer systems of pipeline change
        }
    }
    
    pub fn getShaderByName(self: *Self, name: []const u8) ?*ShaderManager.LoadedShader {
        // Helper to get shaders by common names
        const shader_map = std.ComptimeStringMap([]const u8, .{
            .{ "simple_vertex", "shaders/simple.vert" },
            .{ "simple_fragment", "shaders/simple.frag" },
            .{ "point_light_vertex", "shaders/point_light.vert" },
            .{ "point_light_fragment", "shaders/point_light.frag" },
            .{ "textured_vertex", "shaders/textured.vert" },
            .{ "textured_fragment", "shaders/textured.frag" },
            .{ "particles_compute", "shaders/particles.comp" },
        });
        
        if (shader_map.get(name)) |file_path| {
            return self.shader_manager.getShader(file_path);
        }
        
        return null;
    }
    
    pub fn recompileAllShaders(self: *Self) !void {
        try self.shader_manager.recompileAllShaders();
    }
    
    pub fn getStats(self: *Self) IntegrationStats {
        const shader_stats = self.shader_manager.getStats();
        
        return IntegrationStats{
            .shader_manager_stats = shader_stats,
            .cached_pipelines = @intCast(self.pipeline_cache.count()),
            .vulkan_device_valid = self.vulkan_device != null,
        };
    }
};

// Supporting types
const PipelineInfo = struct {
    id: []const u8,
    vulkan_pipeline: ?*anyopaque, // VkPipeline in real implementation
    dependent_shaders: std.ArrayList([]const u8),
    creation_time: i64,
};

const IntegrationStats = struct {
    shader_manager_stats: ShaderManager.ShaderManagerStats,
    cached_pipelines: u32,
    vulkan_device_valid: bool,
};

// Example usage in main engine
pub fn demonstrateIntegration() !void {
    std.log.info("🎮 ZulkanZengine Shader Hot Reload Demo", .{});
    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Initialize shader integration
    var integration = try EngineShaderIntegration.init(allocator, null);
    defer integration.deinit();
    
    // Start hot reload system
    try integration.start();
    defer integration.stop();
    
    // Get loaded shaders
    if (integration.getShaderByName("simple_vertex")) |vertex_shader| {
        std.log.info("✅ Simple vertex shader loaded: {} bytes SPIR-V", .{vertex_shader.compiled_shader.spirv_code.len});
    }
    
    if (integration.getShaderByName("point_light_fragment")) |fragment_shader| {
        std.log.info("✅ Point light fragment shader loaded: {} bytes SPIR-V", .{fragment_shader.compiled_shader.spirv_code.len});
    }
    
    // Print stats
    const stats = integration.getStats();
    std.log.info("📊 Shader System Stats:", .{});
    std.log.info("   - Loaded shaders: {}", .{stats.shader_manager_stats.loaded_shaders});
    std.log.info("   - Watched directories: {}", .{stats.shader_manager_stats.watched_directories});
    std.log.info("   - Compiler threads: {}", .{stats.shader_manager_stats.active_compiler_threads});
    std.log.info("   - Cached pipelines: {}", .{stats.cached_pipelines});
    
    std.log.info("🔥 Hot reload active - modify shaders in 'shaders/' directory to see live recompilation!", .{});
    std.log.info("⚡ System ready for real-time shader development!", .{});
}

// Test integration
test "EngineShaderIntegration basic functionality" {
    const allocator = std.testing.allocator;
    
    var integration = try EngineShaderIntegration.init(allocator, null);
    defer integration.deinit();
    
    const stats = integration.getStats();
    try std.testing.expect(stats.shader_manager_stats.loaded_shaders == 0);
    try std.testing.expect(!stats.vulkan_device_valid);
}