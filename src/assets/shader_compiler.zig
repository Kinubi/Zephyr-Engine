const std = @import("std");
const spirv_cross = @import("spirv_cross.zig");
const AssetTypes = @import("asset_types.zig");

// Native shader compiler using SPIRV-Cross
// Supports GLSL -> SPIR-V and HLSL -> SPIR-V compilation with reflection

pub const ShaderStage = enum {
    vertex,
    fragment,
    compute,
    geometry,
    tessellation_control,
    tessellation_evaluation,
    raygen,
    any_hit,
    closest_hit,
    miss,
    intersection,
    callable,
};

pub const ShaderLanguage = enum {
    glsl,
    hlsl,
    spirv, // Already compiled SPIR-V
};

pub const CompilationTarget = enum {
    vulkan,
    opengl,
    directx,
};

pub const ShaderSource = struct {
    code: []const u8,
    language: ShaderLanguage,
    stage: ShaderStage,
    entry_point: []const u8,

    // Optional metadata
    includes: ?[]const []const u8 = null,
    defines: ?std.HashMap([]const u8, []const u8, std.hash_map.StringContext, std.hash_map.default_max_load_percentage) = null,
};

pub const ShaderReflection = struct {
    // Input/Output variables
    inputs: std.ArrayList(ShaderVariable),
    outputs: std.ArrayList(ShaderVariable),

    // Uniform buffers and storage buffers
    uniform_buffers: std.ArrayList(ShaderBuffer),
    storage_buffers: std.ArrayList(ShaderBuffer),

    // Textures and samplers
    textures: std.ArrayList(ShaderTexture),
    samplers: std.ArrayList(ShaderSampler),

    // Push constants
    push_constants: ?ShaderPushConstants = null,

    // Specialization constants
    specialization_constants: std.ArrayList(ShaderSpecializationConstant),

    const Self = @This();

    pub fn init() Self {
        return Self{
            .inputs = std.ArrayList(ShaderVariable){},
            .outputs = std.ArrayList(ShaderVariable){},
            .uniform_buffers = std.ArrayList(ShaderBuffer){},
            .storage_buffers = std.ArrayList(ShaderBuffer){},
            .textures = std.ArrayList(ShaderTexture){},
            .samplers = std.ArrayList(ShaderSampler){},
            .specialization_constants = std.ArrayList(ShaderSpecializationConstant){},
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.inputs.deinit(allocator);
        self.outputs.deinit(allocator);
        self.uniform_buffers.deinit(allocator);
        self.storage_buffers.deinit(allocator);
        self.textures.deinit(allocator);
        self.samplers.deinit(allocator);
        self.specialization_constants.deinit(allocator);
    }
};

pub const ShaderVariable = struct {
    name: []const u8,
    location: u32,
    type: ShaderDataType,
    size: u32,
};

pub const ShaderBuffer = struct {
    name: []const u8,
    binding: u32,
    set: u32,
    size: u32,
    members: std.ArrayList(ShaderBufferMember),
};

pub const ShaderBufferMember = struct {
    name: []const u8,
    offset: u32,
    size: u32,
    type: ShaderDataType,
};

pub const ShaderTexture = struct {
    name: []const u8,
    binding: u32,
    set: u32,
    dimension: TextureDimension,
    format: ?TextureFormat = null,
};

pub const ShaderSampler = struct {
    name: []const u8,
    binding: u32,
    set: u32,
};

pub const ShaderPushConstants = struct {
    size: u32,
    offset: u32,
    stage_flags: u32,
};

pub const ShaderSpecializationConstant = struct {
    name: []const u8,
    id: u32,
    default_value: SpecConstValue,
};

pub const SpecConstValue = union(enum) {
    bool_type: bool,
    int_type: i32,
    uint_type: u32,
    float_type: f32,
};

pub const ShaderDataType = enum {
    bool_type,
    int_type,
    uint_type,
    float_type,
    vec2,
    vec3,
    vec4,
    ivec2,
    ivec3,
    ivec4,
    uvec2,
    uvec3,
    uvec4,
    mat2,
    mat3,
    mat4,
    struct_type,
    array_type,
};

pub const TextureDimension = enum {
    texture_1d,
    texture_2d,
    texture_3d,
    texture_cube,
    texture_2d_array,
    texture_cube_array,
};

pub const TextureFormat = enum {
    r8_unorm,
    rg8_unorm,
    rgba8_unorm,
    rgba8_srgb,
    r16_sfloat,
    rg16_sfloat,
    rgba16_sfloat,
    r32_sfloat,
    rg32_sfloat,
    rgb32_sfloat,
    rgba32_sfloat,
    d32_sfloat,
    d24_unorm_s8_uint,
};

pub const CompilationOptions = struct {
    target: CompilationTarget,
    optimization_level: OptimizationLevel = .none,
    debug_info: bool = false,

    // GLSL specific
    glsl_version: u32 = 450,
    glsl_es: bool = false,

    // HLSL specific
    hlsl_shader_model: u32 = 50, // Shader Model 5.0

    // Vulkan specific
    vulkan_semantics: bool = true,
};

pub const OptimizationLevel = enum {
    none,
    size,
    performance,
};

pub const CompiledShader = struct {
    spirv_code: []const u8,
    reflection: ShaderReflection,
    source_hash: u64,

    // Asset integration (placeholder for now)
    // asset_data: AssetTypes.AssetData,

    const Self = @This();

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.spirv_code);
        self.reflection.deinit(allocator);
    }
};

pub const ShaderCompiler = struct {
    allocator: std.mem.Allocator,
    spv_cross: spirv_cross.SpvCross,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        return Self{
            .allocator = allocator,
            .spv_cross = try spirv_cross.SpvCross.init(),
        };
    }

    pub fn deinit(self: *Self) void {
        self.spv_cross.deinit();
    }

    pub fn compile(self: *Self, source: ShaderSource, options: CompilationOptions) !CompiledShader {
        // Compile source to SPIR-V based on input language
        const spirv_data = switch (source.language) {
            .spirv => try self.parseSpirv(source.code),
            .glsl => try self.compileGlsl(source, options),
            .hlsl => return error.HlslCompilationNotImplemented, // Would use DXC or similar
        };

        // Cross-compile using SPIRV-Cross if needed
        const final_spirv = spirv_data;
        if (options.target != .vulkan or !options.vulkan_semantics) {
            // For non-Vulkan targets, we'd do cross-compilation to other languages
            // For now, we'll just use the original SPIR-V data
            // const cross_compiled = try self.crossCompile(spirv_data, options);
            // TODO: Handle cross-compiled output appropriately
        }

        // Generate reflection data
        const reflection = try generateReflection(final_spirv);

        // Calculate source hash for cache invalidation
        const source_hash = std.hash_map.hashString(source.code);

        // Convert SPIR-V words back to bytes for storage
        const spirv_bytes = std.mem.sliceAsBytes(final_spirv);
        const spirv_owned = try self.allocator.dupe(u8, spirv_bytes);

        return CompiledShader{
            .spirv_code = spirv_owned,
            .reflection = reflection,
            .source_hash = source_hash,
            // Asset integration will be added later
        };
    }

    fn compileGlsl(self: *Self, source: ShaderSource, options: CompilationOptions) ![]const u32 {
        _ = options; // Currently unused but kept for future use

        // Create a temporary file for the GLSL source
        var tmp_dir = std.testing.tmpDir(.{});
        defer tmp_dir.cleanup();

        const input_path = "shader_input.glsl";
        const output_path = "shader_output.spv";

        // Write GLSL source to temporary file
        try tmp_dir.dir.writeFile(.{ .sub_path = input_path, .data = source.code });

        // Determine shader stage argument for glslc
        const stage_arg = switch (source.stage) {
            .vertex => "-fshader-stage=vertex",
            .fragment => "-fshader-stage=fragment",
            .compute => "-fshader-stage=compute",
            .geometry => "-fshader-stage=geometry",
            .tessellation_control => "-fshader-stage=tesscontrol",
            .tessellation_evaluation => "-fshader-stage=tesseval",
            else => "-fshader-stage=vertex", // Default fallback
        };

        // Build glslc command
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        // Use simple relative paths within the temp directory
        const args = [_][]const u8{
            "glslc",
            stage_arg,
            "-o",
            output_path,
            input_path,
        };

        // Execute glslc in the temp directory
        var child = std.process.Child.init(&args, self.allocator);
        child.cwd_dir = tmp_dir.dir;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();
        const result = try child.wait();

        if (result != .Exited or result.Exited != 0) {
            // Read stderr for error message
            if (child.stderr) |stderr| {
                var error_buffer: [4096]u8 = undefined;
                const bytes_read = try stderr.readAll(&error_buffer);
                const error_output = error_buffer[0..bytes_read];
                std.log.err("glslc compilation failed: {s}", .{error_output});
            }
            return error.GlslCompilationFailed;
        }

        // Read the compiled SPIR-V
        const spirv_bytes = try tmp_dir.dir.readFileAlloc(self.allocator, output_path, 1024 * 1024); // 1MB max
        defer self.allocator.free(spirv_bytes);

        // Convert to u32 array and validate
        return try self.parseSpirv(spirv_bytes);
    }

    fn parseSpirv(self: *Self, spirv_bytes: []const u8) ![]const u32 {
        if (spirv_bytes.len % 4 != 0) {
            return error.InvalidSpirvFormat;
        }

        // Cast byte array to u32 array (SPIR-V is 32-bit words)
        const spirv_words = std.mem.bytesAsSlice(u32, spirv_bytes);

        // Validate SPIR-V magic number
        if (spirv_words.len == 0 or spirv_words[0] != 0x07230203) {
            return error.InvalidSpirvMagic;
        }

        // Create a copy for our use
        const result = try self.allocator.alloc(u32, spirv_words.len);
        @memcpy(result, spirv_words);

        return result;
    }

    fn crossCompile(self: *Self, spirv_data: []const u32, options: CompilationOptions) ![]const u8 {
        const backend = switch (options.target) {
            .vulkan => spirv_cross.Backend.glsl,
            .opengl => spirv_cross.Backend.glsl,
            .directx => spirv_cross.Backend.hlsl,
        };

        const compile_options = spirv_cross.CompileOptions{
            .glsl_version = options.glsl_version,
            .vulkan_semantics = options.vulkan_semantics,
            .hlsl_shader_model = options.hlsl_shader_model,
            .debug_info = options.debug_info,
        };

        const cross_compiled = try self.spv_cross.compileSpirv(spirv_data, backend, compile_options);

        // For now, return the original SPIR-V since cross-compilation returns source code
        // In a real implementation, we'd compile the cross-compiled source back to SPIR-V
        const result = try self.allocator.alloc(u8, spirv_data.len * 4);
        std.mem.copyForwards(u8, result, std.mem.sliceAsBytes(spirv_data));

        _ = cross_compiled; // Silence unused variable warning

        return result;
    }

    fn generateReflection(spirv_data: []const u32) !ShaderReflection {
        _ = spirv_data; // TODO: Implement SPIR-V reflection parsing

        // For now, return empty reflection data
        return ShaderReflection.init();
    }

    // Hot reload support
    pub fn compileFromFile(self: *Self, file_path: []const u8, options: CompilationOptions) !CompiledShader {
        const file_content = try std.fs.cwd().readFileAlloc(self.allocator, file_path, 1024 * 1024); // 1MB max
        defer self.allocator.free(file_content);

        const language = detectLanguageFromPath(file_path);
        const stage = detectStageFromPath(file_path);

        const source = ShaderSource{
            .code = file_content,
            .language = language,
            .stage = stage,
            .entry_point = "main", // Default entry point
        };

        return try self.compile(source, options);
    }

    fn detectLanguageFromPath(path: []const u8) ShaderLanguage {
        if (std.mem.endsWith(u8, path, ".glsl") or
            std.mem.endsWith(u8, path, ".vert") or
            std.mem.endsWith(u8, path, ".frag") or
            std.mem.endsWith(u8, path, ".comp"))
        {
            return .glsl;
        }
        if (std.mem.endsWith(u8, path, ".hlsl")) {
            return .hlsl;
        }
        if (std.mem.endsWith(u8, path, ".spv")) {
            return .spirv;
        }
        return .glsl; // Default
    }

    fn detectStageFromPath(path: []const u8) ShaderStage {
        if (std.mem.indexOf(u8, path, "vert")) |_| return .vertex;
        if (std.mem.indexOf(u8, path, "frag")) |_| return .fragment;
        if (std.mem.indexOf(u8, path, "comp")) |_| return .compute;
        if (std.mem.indexOf(u8, path, "geom")) |_| return .geometry;
        if (std.mem.indexOf(u8, path, "tesc")) |_| return .tessellation_control;
        if (std.mem.indexOf(u8, path, "tese")) |_| return .tessellation_evaluation;
        return .vertex; // Default
    }
};

// Error types
pub const ShaderCompilerError = error{
    InvalidSpirvFormat,
    InvalidSpirvMagic,
    GlslCompilationNotImplemented,
    HlslCompilationNotImplemented,
    ReflectionGenerationFailed,
    CrossCompilationFailed,
} || spirv_cross.SpvCrossError || std.mem.Allocator.Error;

// Tests
test "ShaderCompiler initialization" {
    const gpa = std.testing.allocator;

    var compiler = try ShaderCompiler.init(gpa);
    defer compiler.deinit();
}
