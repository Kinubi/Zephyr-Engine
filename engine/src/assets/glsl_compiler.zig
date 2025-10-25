const std = @import("std");
const ShaderCompiler = @import("shader_compiler.zig");

// Direct C import for shaderc library
pub const c = @cImport({
    @cInclude("shaderc/shaderc.h");
});

// Zig wrapper for Google shaderc library for GLSL compilation
// This provides a more direct integration than calling external glslc command

pub const ShaderKind = enum(c_uint) {
    vertex_shader = c.shaderc_vertex_shader,
    fragment_shader = c.shaderc_fragment_shader,
    compute_shader = c.shaderc_compute_shader,
    geometry_shader = c.shaderc_geometry_shader,
    tess_control_shader = c.shaderc_tess_control_shader,
    tess_evaluation_shader = c.shaderc_tess_evaluation_shader,
    raygen_shader = c.shaderc_raygen_shader,
    anyhit_shader = c.shaderc_anyhit_shader,
    closesthit_shader = c.shaderc_closesthit_shader,
    miss_shader = c.shaderc_miss_shader,
    intersection_shader = c.shaderc_intersection_shader,
    callable_shader = c.shaderc_callable_shader,
    task_shader = c.shaderc_task_shader,
    mesh_shader = c.shaderc_mesh_shader,
};

pub const CompilationStatus = enum(c_uint) {
    success = c.shaderc_compilation_status_success,
    invalid_stage = c.shaderc_compilation_status_invalid_stage,
    compilation_error = c.shaderc_compilation_status_compilation_error,
    internal_error = c.shaderc_compilation_status_internal_error,
    null_result_object = c.shaderc_compilation_status_null_result_object,
    invalid_assembly = c.shaderc_compilation_status_invalid_assembly,
    validation_error = c.shaderc_compilation_status_validation_error,
    transformation_error = c.shaderc_compilation_status_transformation_error,
    configuration_error = c.shaderc_compilation_status_configuration_error,
};

pub const OptimizationLevel = enum(c_uint) {
    zero = c.shaderc_optimization_level_zero,
    size = c.shaderc_optimization_level_size,
    performance = c.shaderc_optimization_level_performance,
};

pub const TargetEnv = enum(c_uint) {
    vulkan = c.shaderc_target_env_vulkan,
    opengl = c.shaderc_target_env_opengl,
    opengl_compat = c.shaderc_target_env_opengl_compat,
    webgpu = c.shaderc_target_env_webgpu,
};

pub const CompileOptions = struct {
    optimization_level: OptimizationLevel = .performance,
    target_env: TargetEnv = .vulkan,
    target_env_version: u32 = 0,
    source_language: c_uint = c.shaderc_source_language_glsl,
    generate_debug_info: bool = false,
    suppress_warnings: bool = false,
    warnings_as_errors: bool = false,
};

/// Result of a GLSL compilation operation
pub const CompilationResult = struct {
    spirv_data: []u8,
    warnings: []u8,
    errors: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *CompilationResult, allocator: std.mem.Allocator) void {
        allocator.free(self.spirv_data);
        allocator.free(self.warnings);
        allocator.free(self.errors);
    }
};

pub const Compiler = struct {
    compiler_handle: c.shaderc_compiler_t,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Compiler {
        const compiler_handle = c.shaderc_compiler_initialize();
        if (compiler_handle == null) {
            return error.CompilerInitializationFailed;
        }

        return Compiler{
            .compiler_handle = compiler_handle,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Compiler) void {
        c.shaderc_compiler_release(self.compiler_handle);
    }

    /// Compile GLSL source code to SPIR-V
    pub fn compileGlslToSpirv(
        self: *Compiler,
        source_text: []const u8,
        stage: ShaderKind,
        input_file_name: []const u8,
        entry_point_name: []const u8,
        options: ?*const CompileOptions,
    ) !CompilationResult {
        const compile_options = c.shaderc_compile_options_initialize();
        if (compile_options == null) {
            return error.OptionsInitializationFailed;
        }
        defer if (compile_options != null) c.shaderc_compile_options_release(compile_options.?);

        if (options != null) {
            c.shaderc_compile_options_set_optimization_level(compile_options.?, @intFromEnum(options.?.optimization_level));
            c.shaderc_compile_options_set_target_env(compile_options.?, @intFromEnum(options.?.target_env), options.?.target_env_version);
            c.shaderc_compile_options_set_source_language(compile_options.?, options.?.source_language);

            if (options.?.generate_debug_info) {
                c.shaderc_compile_options_set_generate_debug_info(compile_options.?);
            }
            if (options.?.suppress_warnings) {
                c.shaderc_compile_options_set_suppress_warnings(compile_options.?);
            }
            if (options.?.warnings_as_errors) {
                c.shaderc_compile_options_set_warnings_as_errors(compile_options.?);
            }
        }

        const result = c.shaderc_compile_into_spv(
            self.compiler_handle,
            source_text.ptr,
            source_text.len,
            @intFromEnum(stage),
            input_file_name.ptr,
            entry_point_name.ptr,
            compile_options.?,
        );

        if (result == null) {
            return error.CompilationFailed;
        }
        defer c.shaderc_result_release(result.?);

        const status: CompilationStatus = @enumFromInt(c.shaderc_result_get_compilation_status(result.?));
        if (status != .success) {
            const error_message = std.mem.span(c.shaderc_result_get_error_message(result.?));
            std.log.err("GLSL compilation failed: {s}", .{error_message});
            return error.CompilationFailed;
        }

        const spirv_length = c.shaderc_result_get_length(result.?);
        const spirv_bytes = c.shaderc_result_get_bytes(result.?);

        if (spirv_bytes == null or spirv_length == 0) {
            return error.NoSpirvOutput;
        }

        // Copy SPIR-V data
        const spirv_data = try self.allocator.alloc(u8, spirv_length);
        @memcpy(spirv_data, @as([*]const u8, @ptrCast(spirv_bytes))[0..spirv_length]);

        // Get warnings (if any)
        const warnings = try self.allocator.dupe(u8, std.mem.span(c.shaderc_result_get_error_message(result.?)));

        return CompilationResult{
            .spirv_data = spirv_data,
            .warnings = warnings,
            .errors = try self.allocator.dupe(u8, ""),
            .allocator = self.allocator,
        };
    }

    /// Preprocess GLSL source code
    pub fn preprocessGlsl(
        self: *Compiler,
        source_text: []const u8,
        stage: ShaderKind,
        input_file_name: []const u8,
        entry_point_name: []const u8,
        options: ?*const CompileOptions,
    ) ![]u8 {
        const compile_options = c.shaderc_compile_options_initialize();
        if (compile_options == null) {
            return error.OptionsInitializationFailed;
        }
        defer if (compile_options != null) c.shaderc_compile_options_release(compile_options.?);

        if (options != null) {
            c.shaderc_compile_options_set_optimization_level(compile_options.?, @intFromEnum(options.?.optimization_level));
            c.shaderc_compile_options_set_target_env(compile_options.?, @intFromEnum(options.?.target_env), options.?.target_env_version);
            c.shaderc_compile_options_set_source_language(compile_options.?, options.?.source_language);
        }

        const result = c.shaderc_compile_into_preprocessed_text(
            self.compiler_handle,
            source_text.ptr,
            source_text.len,
            @intFromEnum(stage),
            input_file_name.ptr,
            entry_point_name.ptr,
            compile_options.?,
        );

        if (result == null) {
            return error.PreprocessingFailed;
        }
        defer c.shaderc_result_release(result.?);

        const status: CompilationStatus = @enumFromInt(c.shaderc_result_get_compilation_status(result.?));
        if (status != .success) {
            const error_message = std.mem.span(c.shaderc_result_get_error_message(result.?));
            std.log.err("GLSL preprocessing failed: {s}", .{error_message});
            return error.PreprocessingFailed;
        }

        const result_length = c.shaderc_result_get_length(result.?);
        const result_bytes = c.shaderc_result_get_bytes(result.?);

        if (result_bytes == null or result_length == 0) {
            return error.NoPreprocessedOutput;
        }

        // Copy preprocessed data
        const preprocessed_data = try self.allocator.alloc(u8, result_length);
        @memcpy(preprocessed_data, @as([*]const u8, @ptrCast(result_bytes))[0..result_length]);

        return preprocessed_data;
    }
};

/// Configuration and helper functions
/// Convert shader stage from engine types to shaderc types
pub fn shaderStageToShaderKind(stage: ShaderCompiler.ShaderStage) ShaderKind {
    return switch (stage) {
        .vertex => .vertex_shader,
        .fragment => .fragment_shader,
        .compute => .compute_shader,
        .geometry => .geometry_shader,
        .tessellation_control => .tess_control_shader,
        .tessellation_evaluation => .tess_evaluation_shader,
        .raygen => .raygen_shader,
        .any_hit => .anyhit_shader,
        .closest_hit => .closesthit_shader,
        .miss => .miss_shader,
        .intersection => .intersection_shader,
        .callable => .callable_shader,
    };
}

/// Convenience function to compile GLSL from file path
pub fn compileGlslFile(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    stage: ShaderCompiler.ShaderStage,
    entry_point: []const u8,
    options: ?*const CompileOptions,
) !CompilationResult {
    var compiler = try Compiler.init(allocator);
    defer compiler.deinit();

    const source_text = try std.fs.cwd().readFileAlloc(allocator, file_path, 1024 * 1024); // 1MB max
    defer allocator.free(source_text);

    return compiler.compileGlslToSpirv(
        source_text,
        shaderStageToShaderKind(stage),
        file_path,
        entry_point,
        options,
    );
}

/// Test if shaderc is available and working
pub fn testShadercAvailability(allocator: std.mem.Allocator) bool {
    var compiler = Compiler.init(allocator) catch return false;
    defer compiler.deinit();

    // Try a simple compilation test
    const test_source = "#version 450\nvoid main() {}";
    const result = compiler.compileGlslToSpirv(
        test_source,
        .vertex_shader,
        "test.vert",
        "main",
        null,
    ) catch return false;

    var mut_result = result;
    mut_result.deinit(allocator);
    return true;
}
