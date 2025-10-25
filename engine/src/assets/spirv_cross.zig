const std = @import("std");
const c = @import("../core/c.zig");

// SPIRV-Cross C API bindings for Zig
// This provides a native interface to SPIRV-Cross for shader compilation

// Opaque types from SPIRV-Cross C API
pub const Context = ?*anyopaque;
pub const ParsedIr = ?*anyopaque;
pub const Compiler = ?*anyopaque;
pub const CompilerOptions = ?*anyopaque;
pub const Resources = ?*anyopaque;

// Result codes
pub const Result = enum(c_int) {
    success = 0,
    invalid_spirv = -1,
    unsupported_spirv = -2,
    out_of_memory = -3,
    invalid_argument = -4,
    _,
};

// Backend types for cross-compilation
pub const Backend = enum(c_int) {
    none = 0,
    glsl = 1, // GLSL output
    hlsl = 2, // HLSL output
    msl = 3, // Metal Shading Language
    cpp = 4, // C++ output
    json = 5, // JSON reflection data
    _,
};

// Compiler options for different backends
pub const CompilerOption = enum(c_int) {
    // Common options
    version = 0,
    es = 1,
    debug_info = 2,

    // GLSL specific
    glsl_version = 10,
    glsl_es = 11,
    glsl_vulkan_semantics = 12,
    glsl_separate_shader_objects = 13,
    glsl_enable_420pack_extension = 14,

    // HLSL specific
    hlsl_shader_model = 20,
    hlsl_point_size_compat = 21,
    hlsl_point_coord_compat = 22,
    hlsl_support_nonzero_base_vertex_base_instance = 23,

    _,
};

// External C function declarations
extern "c" fn spvc_context_create(context: *Context) Result;
extern "c" fn spvc_context_destroy(context: Context) void;
extern "c" fn spvc_context_parse_spirv(context: Context, spirv: [*]const u32, word_count: usize, parsed_ir: *ParsedIr) Result;
extern "c" fn spvc_context_create_compiler(context: Context, backend: Backend, parsed_ir: ParsedIr, mode: c_int, compiler: *Compiler) Result;
extern "c" fn spvc_compiler_create_compiler_options(compiler: Compiler, options: *CompilerOptions) Result;
extern "c" fn spvc_compiler_options_set_uint(options: CompilerOptions, option: CompilerOption, value: c_uint) Result;
extern "c" fn spvc_compiler_options_set_bool(options: CompilerOptions, option: CompilerOption, value: c_uint) Result;
extern "c" fn spvc_compiler_install_compiler_options(compiler: Compiler, options: CompilerOptions) Result;
extern "c" fn spvc_compiler_compile(compiler: Compiler, source: *[*:0]const u8) Result;
extern "c" fn spvc_compiler_get_declared_struct_size(compiler: Compiler, base_type_id: u32, size: *usize) Result;

// High-level Zig wrapper for SPIRV-Cross
pub const SpvCross = struct {
    context: Context,

    pub fn init() !SpvCross {
        var context: Context = undefined;
        const result = spvc_context_create(&context);

        return switch (result) {
            .success => SpvCross{ .context = context },
            .out_of_memory => error.OutOfMemory,
            else => error.SpvCrossInitFailed,
        };
    }

    pub fn deinit(self: *SpvCross) void {
        if (self.context) |ctx| {
            spvc_context_destroy(ctx);
        }
        self.context = null;
    }

    pub fn compileSpirv(self: *SpvCross, spirv_data: []const u32, backend: Backend, options: CompileOptions) ![]const u8 {
        // Parse SPIR-V bytecode
        var parsed_ir: ParsedIr = undefined;
        var result = spvc_context_parse_spirv(self.context, spirv_data.ptr, spirv_data.len, &parsed_ir);
        if (result != .success) {
            return switch (result) {
                .invalid_spirv => error.InvalidSpirv,
                .unsupported_spirv => error.UnsupportedSpirv,
                .out_of_memory => error.OutOfMemory,
                else => error.ParseFailed,
            };
        }

        // Create compiler for target backend
        var compiler: Compiler = undefined;
        result = spvc_context_create_compiler(self.context, backend, parsed_ir, 0, &compiler);
        if (result != .success) {
            return error.CompilerCreationFailed;
        }

        // Configure compiler options
        var compiler_options: CompilerOptions = undefined;
        result = spvc_compiler_create_compiler_options(compiler, &compiler_options);
        if (result != .success) {
            return error.OptionsCreationFailed;
        }

        // Apply user-specified options
        try self.applyCompileOptions(compiler_options, backend, options);

        result = spvc_compiler_install_compiler_options(compiler, compiler_options);
        if (result != .success) {
            return error.OptionsInstallFailed;
        }

        // Compile to target language
        var source_ptr: [*:0]const u8 = undefined;
        result = spvc_compiler_compile(compiler, &source_ptr);
        if (result != .success) {
            return switch (result) {
                .invalid_spirv => error.InvalidSpirv,
                .unsupported_spirv => error.UnsupportedSpirv,
                .out_of_memory => error.OutOfMemory,
                else => error.CompileFailed,
            };
        }

        // Convert C string to Zig slice
        return std.mem.span(source_ptr);
    }

    fn applyCompileOptions(self: *SpvCross, options: CompilerOptions, backend: Backend, compile_options: CompileOptions) !void {
        _ = self;

        switch (backend) {
            .glsl => {
                if (compile_options.glsl_version) |version| {
                    _ = spvc_compiler_options_set_uint(options, .glsl_version, version);
                }
                if (compile_options.glsl_es) |es| {
                    _ = spvc_compiler_options_set_bool(options, .glsl_es, if (es) 1 else 0);
                }
                if (compile_options.vulkan_semantics) |vulkan| {
                    _ = spvc_compiler_options_set_bool(options, .glsl_vulkan_semantics, if (vulkan) 1 else 0);
                }
            },
            .hlsl => {
                if (compile_options.hlsl_shader_model) |model| {
                    _ = spvc_compiler_options_set_uint(options, .hlsl_shader_model, model);
                }
            },
            else => {},
        }
    }
};

// Compilation options for different backends
pub const CompileOptions = struct {
    // GLSL options
    glsl_version: ?u32 = null,
    glsl_es: ?bool = null,
    vulkan_semantics: ?bool = null,

    // HLSL options
    hlsl_shader_model: ?u32 = null,

    // Common options
    debug_info: ?bool = null,
};

// Convenience functions for common use cases
pub fn compileGlslToSpirv(spirv_data: []const u32, version: u32, vulkan_semantics: bool) ![]const u8 {
    var spv_cross = try SpvCross.init();
    defer spv_cross.deinit();

    const options = CompileOptions{
        .glsl_version = version,
        .vulkan_semantics = vulkan_semantics,
    };

    return try spv_cross.compileSpirv(spirv_data, .glsl, options);
}

pub fn compileHlslToSpirv(spirv_data: []const u32, shader_model: u32) ![]const u8 {
    var spv_cross = try SpvCross.init();
    defer spv_cross.deinit();

    const options = CompileOptions{
        .hlsl_shader_model = shader_model,
    };

    return try spv_cross.compileSpirv(spirv_data, .hlsl, options);
}

// Error handling
pub const SpvCrossError = error{
    SpvCrossInitFailed,
    InvalidSpirv,
    UnsupportedSpirv,
    OutOfMemory,
    ParseFailed,
    CompilerCreationFailed,
    OptionsCreationFailed,
    OptionsInstallFailed,
    CompileFailed,
};

// Tests
test "SpvCross initialization" {
    var spv_cross = try SpvCross.init();
    defer spv_cross.deinit();
}
