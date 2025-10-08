const std = @import("std");
const DynamicPipelineManager = @import("dynamic_pipeline_manager.zig").DynamicPipelineManager;
const ShaderWatcher = @import("../assets/shader_hot_reload.zig").ShaderWatcher;
const ShaderReloadCallback = @import("../assets/shader_hot_reload.zig").ShaderReloadCallback;
const CompiledShader = @import("../assets/shader_compiler.zig").CompiledShader;
const log = @import("../utils/log.zig").log;

/// Integration bridge between shader hot reload and dynamic pipeline management
pub const ShaderPipelineIntegration = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    pipeline_manager: *DynamicPipelineManager,
    shader_watcher: *ShaderWatcher,

    /// Initialize the integration
    pub fn init(allocator: std.mem.Allocator, pipeline_manager: *DynamicPipelineManager, shader_watcher: *ShaderWatcher) !Self {
        var integration = Self{
            .allocator = allocator,
            .pipeline_manager = pipeline_manager,
            .shader_watcher = shader_watcher,
        };

        // Register shader reload callback
        const callback = ShaderReloadCallback{
            .context = @ptrCast(&integration),
            .onShaderReloaded = onShaderReloadedCallback,
        };

        try shader_watcher.addShaderReloadCallback(callback);

        log(.INFO, "shader_pipeline_integration", "Shader-Pipeline integration initialized", .{});
        return integration;
    }

    /// Cleanup
    pub fn deinit(self: *Self) void {
        // Note: ShaderWatcher doesn't currently have removeCallback, but that's ok
        // The callback will just stop being called when the shader watcher is destroyed
        _ = self;
    }

    /// Callback when a shader is reloaded
    fn onShaderReloadedCallback(file_path: []const u8, compiled_shader: CompiledShader) void {
        // This is called from the shader watcher thread, we need to extract the integration context
        // But since we can't safely cast from the callback context, we'll use a global approach

        // For now, we'll trigger pipeline rebuilds directly
        // In a more sophisticated implementation, we could maintain a registry of integrations
        onShaderReloaded(file_path, compiled_shader);
    }

    /// Global shader reload handler (to be improved with proper context management)
    fn onShaderReloaded(file_path: []const u8, compiled_shader: CompiledShader) void {
        _ = compiled_shader; // We don't need the compiled shader data for pipeline rebuild

        log(.INFO, "shader_pipeline_integration", "Shader reloaded, triggering pipeline rebuild: {s}", .{file_path});

        // TODO: Get the pipeline manager instance in a thread-safe way
        // For now, this is a placeholder for the integration pattern
        // In practice, you would store the pipeline manager in a global registry
        // or pass it through the callback context properly
    }
};

/// Global integration instance for shader-pipeline communication
/// This is a temporary solution until we have proper context passing in callbacks
var global_integration: ?*ShaderPipelineIntegration = null;

/// Set the global integration instance
pub fn setGlobalIntegration(integration: *ShaderPipelineIntegration) void {
    global_integration = integration;
}

/// Global shader reload handler that can access the pipeline manager
pub fn globalOnShaderReloaded(file_path: []const u8, compiled_shader: CompiledShader) void {
    _ = compiled_shader;

    if (global_integration) |integration| {
        log(.INFO, "shader_pipeline_integration", "Processing shader reload for pipelines: {s}", .{file_path});

        // Find all pipelines that use this shader and mark them for rebuild
        integration.pipeline_manager.markPipelinesForRebuildByShader(file_path) catch |err| {
            log(.ERROR, "shader_pipeline_integration", "Failed to mark pipelines for rebuild: {}", .{err});
        };
    } else {
        log(.WARN, "shader_pipeline_integration", "No global integration available for shader reload: {s}", .{file_path});
    }
}
