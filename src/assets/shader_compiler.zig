const std = @import("std");
const spirv_cross = @import("spirv_cross.zig");
const AssetTypes = @import("asset_types.zig");
const glsl_compiler = @import("glsl_compiler.zig");

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
    file_path: ?[]const u8 = null,

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
    storage_images: std.ArrayList(ShaderStorageImage),
    samplers: std.ArrayList(ShaderSampler),

    // Push constants
    push_constants: ?ShaderPushConstants = null,

    // Specialization constants
    specialization_constants: std.ArrayList(ShaderSpecializationConstant),
    acceleration_structures: std.ArrayList(ShaderAccelerationStructure),

    const Self = @This();

    pub fn init() Self {
        return Self{
            .inputs = std.ArrayList(ShaderVariable){},
            .outputs = std.ArrayList(ShaderVariable){},
            .uniform_buffers = std.ArrayList(ShaderBuffer){},
            .storage_buffers = std.ArrayList(ShaderBuffer){},
            .textures = std.ArrayList(ShaderTexture){},
            .storage_images = std.ArrayList(ShaderStorageImage){},
            .samplers = std.ArrayList(ShaderSampler){},
            .specialization_constants = std.ArrayList(ShaderSpecializationConstant){},
            .acceleration_structures = std.ArrayList(ShaderAccelerationStructure){},
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.inputs.deinit(allocator);
        self.outputs.deinit(allocator);
        self.uniform_buffers.deinit(allocator);
        self.storage_buffers.deinit(allocator);
        self.textures.deinit(allocator);
        self.storage_images.deinit(allocator);
        self.samplers.deinit(allocator);
        self.specialization_constants.deinit(allocator);
        self.acceleration_structures.deinit(allocator);
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
    array_size: u32 = 1, // Number of array elements (1 for non-arrays, 0 for unbounded)
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
    array_size: u32 = 1, // Number of array elements (1 for non-arrays, 0 for unbounded)
};

pub const ShaderStorageImage = struct {
    name: []const u8,
    binding: u32,
    set: u32,
    array_size: u32 = 1,
};

pub const ShaderSampler = struct {
    name: []const u8,
    binding: u32,
    set: u32,
    array_size: u32 = 1, // Number of array elements (1 for non-arrays, 0 for unbounded)
};

pub const ShaderAccelerationStructure = struct {
    name: []const u8,
    binding: u32,
    set: u32,
    array_size: u32 = 1,
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

fn parseDescriptorArraySize(array_value_opt: ?std.json.Value) u32 {
    if (array_value_opt) |value| {
        switch (value) {
            .integer => {
                const raw_size = value.integer;
                return if (raw_size == 0) 0 else @as(u32, @intCast(raw_size));
            },
            .array => {
                if (value.array.items.len > 0) {
                    const first = value.array.items[0];
                    if (first == .integer) {
                        const raw_size = first.integer;
                        return if (raw_size == 0) 0 else @as(u32, @intCast(raw_size));
                    }
                }
                return 0;
            },
            else => return 1,
        }
    }
    return 1;
}

fn hasTokenIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var matched = true;
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }
    return false;
}

fn mapTextureDimension(type_name: []const u8) TextureDimension {
    if (hasTokenIgnoreCase(type_name, "cube")) {
        if (hasTokenIgnoreCase(type_name, "array")) return .texture_cube_array;
        return .texture_cube;
    }
    if (hasTokenIgnoreCase(type_name, "3d")) return .texture_3d;
    if (hasTokenIgnoreCase(type_name, "2d")) {
        if (hasTokenIgnoreCase(type_name, "array")) return .texture_2d_array;
        return .texture_2d;
    }
    if (hasTokenIgnoreCase(type_name, "1d")) return .texture_1d;
    return .texture_2d;
}

fn appendTextureResource(
    reflection: *ShaderReflection,
    allocator: std.mem.Allocator,
    name: []const u8,
    set: u32,
    binding: u32,
    dimension: TextureDimension,
    array_size: u32,
) !void {
    for (reflection.textures.items) |*existing| {
        if (existing.set == set and existing.binding == binding) {
            if (existing.array_size < array_size) existing.array_size = array_size;
            return;
        }
    }

    const name_copy = try allocator.dupe(u8, name);
    try reflection.textures.append(allocator, ShaderTexture{
        .name = name_copy,
        .binding = binding,
        .set = set,
        .dimension = dimension,
        .format = null,
        .array_size = array_size,
    });
}

fn appendStorageImageResource(
    reflection: *ShaderReflection,
    allocator: std.mem.Allocator,
    name: []const u8,
    set: u32,
    binding: u32,
    array_size: u32,
) !void {
    for (reflection.storage_images.items) |*existing| {
        if (existing.set == set and existing.binding == binding) {
            if (existing.array_size < array_size) existing.array_size = array_size;
            return;
        }
    }

    const name_copy = try allocator.dupe(u8, name);
    try reflection.storage_images.append(allocator, ShaderStorageImage{
        .name = name_copy,
        .binding = binding,
        .set = set,
        .array_size = array_size,
    });
}

fn appendAccelerationStructureResource(
    reflection: *ShaderReflection,
    allocator: std.mem.Allocator,
    name: []const u8,
    set: u32,
    binding: u32,
    array_size: u32,
) !void {
    for (reflection.acceleration_structures.items) |*existing| {
        if (existing.set == set and existing.binding == binding) {
            if (existing.array_size < array_size) existing.array_size = array_size;
            return;
        }
    }

    const name_copy = try allocator.dupe(u8, name);
    try reflection.acceleration_structures.append(allocator, ShaderAccelerationStructure{
        .name = name_copy,
        .binding = binding,
        .set = set,
        .array_size = array_size,
    });
}

const PendingCombinedTexture = struct {
    name: []const u8,
    set: u32,
    binding: u32,
    array_size: u32,
    dimension: TextureDimension,
    has_sampler: bool,
};

fn findPendingCombinedTexture(
    list: *std.ArrayList(PendingCombinedTexture),
    set: u32,
    binding: u32,
) ?*PendingCombinedTexture {
    for (list.items) |*entry| {
        if (entry.set == set and entry.binding == binding) {
            return entry;
        }
    }
    return null;
}

pub const CompilationOptions = struct {
    target: CompilationTarget,
    optimization_level: OptimizationLevel = .none,
    debug_info: bool = false,

    // Compiler selection
    use_embedded_compiler: bool = true, // Use libshaderc vs external glslc

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
            .glsl => if (options.use_embedded_compiler)
                try self.compileGlslEmbedded(source, options)
            else
                try self.compileGlslExternal(source, options),
            .hlsl => try self.compileHlsl(source, options),
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
        const reflection = try self.generateReflection(final_spirv);

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

    fn compileGlslExternal(self: *Self, source: ShaderSource, options: CompilationOptions) ![]const u32 {
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

    /// Public helper: generate reflection directly from SPIR-V bytes.
    pub fn generateReflectionFromSpirv(self: *Self, spirv_bytes: []const u8) !ShaderReflection {
        const spirv_words = try self.parseSpirv(spirv_bytes);
        const reflection = try self.generateReflection(spirv_words);
        // Free the parsed words allocated by parseSpirv
        self.allocator.free(spirv_words);
        return reflection;
    }

    fn compileGlslEmbedded(self: *Self, source: ShaderSource, options: CompilationOptions) ![]const u32 {
        // Use the embedded libshaderc compiler
        var compiler = glsl_compiler.Compiler.init(self.allocator) catch |err| {
            std.log.warn("Failed to initialize embedded GLSL compiler: {}, falling back to external glslc", .{err});
            return self.compileGlslExternal(source, options);
        };
        defer compiler.deinit();

        // Convert shader stage to shaderc format
        const shader_kind = glsl_compiler.shaderStageToShaderKind(source.stage);

        // Set up compilation options
        const compile_options = glsl_compiler.CompileOptions{
            .optimization_level = switch (options.optimization_level) {
                .none => .zero,
                .size => .size,
                .performance => .performance,
            },
            .target_env = if (options.vulkan_semantics) .vulkan else .opengl,
            .generate_debug_info = options.debug_info,
            .source_language = @import("glsl_compiler.zig").c.shaderc_source_language_glsl,
        };

        // Compile to SPIR-V
        const result = compiler.compileGlslToSpirv(
            source.code,
            shader_kind,
            "shader_source", // input file name for error reporting
            source.entry_point,
            &compile_options,
        ) catch |err| {
            std.log.err("Embedded GLSL compilation failed: {}", .{err});
            return err;
        };
        defer {
            // Note: result.spirv_data will be owned by the returned value
            // Only free warnings and errors here
            self.allocator.free(result.warnings);
            self.allocator.free(result.errors);
        }

        // Log any warnings
        if (result.warnings.len > 0) {
            std.log.warn("GLSL compilation warnings: {s}", .{result.warnings});
        }

        // Return the SPIR-V data (ownership transferred to caller)
        // SPIR-V data is stored as bytes but should be interpreted as u32 words
        const spirv_words = @as([*]const u32, @ptrCast(@alignCast(result.spirv_data.ptr)))[0 .. result.spirv_data.len / 4];

        // We need to duplicate the data since result will be deinitialized
        const spirv_copy = try self.allocator.alloc(u32, spirv_words.len);
        @memcpy(spirv_copy, spirv_words);

        // Clean up the result
        var mut_result = result;
        mut_result.deinit(self.allocator);

        return spirv_copy;
    }

    fn hlslProfileForStage(stage: ShaderStage, options: CompilationOptions, buffer: *[16]u8) ![]const u8 {
        var major = options.hlsl_shader_model / 10;
        var minor = options.hlsl_shader_model % 10;

        const prefix = switch (stage) {
            .vertex => "vs",
            .fragment => "ps",
            .compute => "cs",
            .geometry => "gs",
            .tessellation_control => "hs",
            .tessellation_evaluation => "ds",
            .raygen, .any_hit, .closest_hit, .miss, .intersection, .callable => blk: {
                if (major < 6 or (major == 6 and minor < 3)) {
                    major = 6;
                    minor = 3;
                }
                break :blk "lib";
            },
        };

        return std.fmt.bufPrint(buffer, "{s}_{d}_{d}", .{ prefix, major, minor });
    }

    fn compileHlsl(self: *Self, source: ShaderSource, options: CompilationOptions) ![]const u32 {
        const file_path = source.file_path orelse return error.HlslFilePathRequired;

        const cache_dir = "shaders/cached";
        std.fs.cwd().makePath(cache_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        const basename = std.fs.path.basename(file_path);
        const output_name = try std.fmt.allocPrint(self.allocator, "{s}.spv", .{basename});
        defer self.allocator.free(output_name);

        const output_path = try std.fs.path.join(self.allocator, &[_][]const u8{ cache_dir, output_name });
        defer self.allocator.free(output_path);

        var args = std.ArrayList([]const u8){};
        defer args.deinit(self.allocator);

        try args.appendSlice(self.allocator, &[_][]const u8{ "dxc", "-spirv", "-fspv-target-env=vulkan1.2" });

        try args.append(self.allocator, "-I");
        try args.append(self.allocator, "vendor/NRIFramework/External/NRI/Include");

        if (source.includes) |extra_includes| {
            for (extra_includes) |inc| {
                try args.append(self.allocator, "-I");
                try args.append(self.allocator, inc);
            }
        }

        try args.append(self.allocator, "-E");
        try args.append(self.allocator, source.entry_point);

        var profile_buffer: [16]u8 = undefined;
        const profile = try hlslProfileForStage(source.stage, options, &profile_buffer);
        try args.append(self.allocator, "-T");
        try args.append(self.allocator, profile);

        try args.append(self.allocator, "-Fo");
        try args.append(self.allocator, output_path);
        try args.append(self.allocator, file_path);

        var child = std.process.Child.init(args.items, self.allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;

        child.spawn() catch |err| {
            std.log.err("Failed to invoke dxc: {}", .{err});
            return error.HlslCompilationFailed;
        };

        const result = child.wait() catch |err| {
            std.log.err("dxc invocation failed: {}", .{err});
            return error.HlslCompilationFailed;
        };

        if (result != .Exited or result.Exited != 0) {
            std.log.err("dxc returned non-zero exit status ({}) for {s}", .{ result, file_path });
            return error.HlslCompilationFailed;
        }

        const spv_bytes = try std.fs.cwd().readFileAlloc(self.allocator, output_path, 16 * 1024 * 1024);
        defer self.allocator.free(spv_bytes);

        return try self.parseSpirv(spv_bytes);
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

    fn generateReflection(self: *Self, spirv_data: []const u32) !ShaderReflection {
        // Ask SPIRV-Cross for JSON reflection using the JSON backend
        const sc_opts = spirv_cross.CompileOptions{
            .glsl_version = null,
            .glsl_es = null,
            .vulkan_semantics = true,
            .hlsl_shader_model = null,
            .debug_info = false,
        };
        const json_cstr = try self.spv_cross.compileSpirv(spirv_data, spirv_cross.Backend.json, sc_opts);
        // Copy JSON into our allocator so parsing and returned slices are stable
        const json_owned = try self.allocator.dupe(u8, json_cstr);
        defer self.allocator.free(json_owned);

        // DEBUG: Write JSON to file for inspection
        if (std.mem.indexOf(u8, json_owned, "textures") != null) {
            std.fs.cwd().writeFile(.{ .sub_path = "spirv_reflection_debug.json", .data = json_owned }) catch {};
        }

        var parser = std.json.parseFromSlice(std.json.Value, self.allocator, json_owned, .{}) catch |err| {
            std.log.err("Failed to parse SPIRV-Cross JSON reflection: {}", .{err});
            return error.ReflectionGenerationFailed;
        };
        defer parser.deinit();

        const root = parser.value;
        if (root != .object) return ShaderReflection.init();

        // resources parsing handled below

        var refl = ShaderReflection.init();

        // Populate arrays (they were zero-initialized in init)
        refl.inputs = std.ArrayList(ShaderVariable){};
        refl.outputs = std.ArrayList(ShaderVariable){};
        refl.uniform_buffers = std.ArrayList(ShaderBuffer){};
        refl.storage_buffers = std.ArrayList(ShaderBuffer){};
        refl.textures = std.ArrayList(ShaderTexture){};
        refl.storage_images = std.ArrayList(ShaderStorageImage){};
        refl.samplers = std.ArrayList(ShaderSampler){};
        refl.specialization_constants = std.ArrayList(ShaderSpecializationConstant){};
        refl.acceleration_structures = std.ArrayList(ShaderAccelerationStructure){};

        var pending_combined = std.ArrayList(PendingCombinedTexture){};
        defer pending_combined.deinit(self.allocator);

        // SPIRV-Cross may emit a `resources` object with arrays of resources
        if (root.object.get("resources")) |res_val| {
            if (res_val == .object) {
                const res_obj = res_val.object;

                // stage_inputs
                if (res_obj.get("stage_inputs")) |v| {
                    if (v == .array) {
                        for (v.array.items) |elem| {
                            if (elem == .object) {
                                if (elem.object.get("name")) |name_v| {
                                    if (elem.object.get("location")) |loc_v| {
                                        if (name_v == .string and loc_v == .integer) {
                                            const name = name_v.string;
                                            const location = @as(u32, @intCast(loc_v.integer));
                                            const name_copy = try self.allocator.dupe(u8, name);
                                            try refl.inputs.append(self.allocator, ShaderVariable{ .name = name_copy, .location = location, .type = ShaderDataType.struct_type, .size = 0 });
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // stage_outputs
                if (res_obj.get("stage_outputs")) |v| {
                    if (v == .array) {
                        for (v.array.items) |elem| {
                            if (elem == .object) {
                                const name_opt = elem.object.get("name");
                                const loc_opt = elem.object.get("location");
                                if (name_opt) |name_v| {
                                    if (loc_opt) |loc_v| {
                                        if (name_v == .string and loc_v == .integer) {
                                            const name = name_v.string;
                                            const location = @as(u32, @intCast(loc_v.integer));
                                            const name_copy = try self.allocator.dupe(u8, name);
                                            try refl.outputs.append(self.allocator, ShaderVariable{ .name = name_copy, .location = location, .type = ShaderDataType.struct_type, .size = 0 });
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // uniform_buffers
                if (res_obj.get("uniform_buffers")) |v| {
                    if (v == .array) {
                        for (v.array.items) |elem| {
                            if (elem == .object) {
                                const name_opt = elem.object.get("name");
                                const set_opt = elem.object.get("set");
                                const binding_opt = elem.object.get("binding");
                                const size_opt = elem.object.get("size");
                                const array_size_opt = elem.object.get("array");
                                if (name_opt) |name_v| {
                                    if (set_opt) |set_v| {
                                        if (binding_opt) |bind_v| {
                                            if (name_v == .string and set_v == .integer and bind_v == .integer) {
                                                const name = name_v.string;
                                                const set = @as(u32, @intCast(set_v.integer));
                                                const binding = @as(u32, @intCast(bind_v.integer));
                                                var size: u32 = 0;
                                                if (size_opt) |s_v| {
                                                    if (s_v == .integer) {
                                                        size = @as(u32, @intCast(s_v.integer));
                                                    }
                                                }

                                                // Extract array size
                                                var array_size: u32 = 1;
                                                if (array_size_opt) |as_v| {
                                                    if (as_v == .array and as_v.array.items.len > 0) {
                                                        if (as_v.array.items[0] == .integer) {
                                                            const arr_size = as_v.array.items[0].integer;
                                                            array_size = if (arr_size == 0) 0 else @as(u32, @intCast(arr_size));
                                                        } else {
                                                            array_size = 0; // Unbounded
                                                        }
                                                    } else if (as_v == .integer) {
                                                        const arr_size = as_v.integer;
                                                        array_size = if (arr_size == 0) 0 else @as(u32, @intCast(arr_size));
                                                    }
                                                }

                                                const name_copy = try self.allocator.dupe(u8, name);
                                                var members = std.ArrayList(ShaderBufferMember){};
                                                _ = &members;

                                                try refl.uniform_buffers.append(self.allocator, ShaderBuffer{
                                                    .name = name_copy,
                                                    .binding = binding,
                                                    .set = set,
                                                    .size = size,
                                                    .array_size = array_size,
                                                    .members = members,
                                                });
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // storage_buffers
                if (res_obj.get("storage_buffers")) |v| {
                    if (v == .array) {
                        for (v.array.items) |elem| {
                            if (elem == .object) {
                                const name_opt = elem.object.get("name");
                                const set_opt = elem.object.get("set");
                                const binding_opt = elem.object.get("binding");
                                const size_opt = elem.object.get("size");
                                const array_size_opt = elem.object.get("array");
                                if (name_opt) |name_v| {
                                    if (set_opt) |set_v| {
                                        if (binding_opt) |bind_v| {
                                            if (name_v == .string and set_v == .integer and bind_v == .integer) {
                                                const name = name_v.string;
                                                const set = @as(u32, @intCast(set_v.integer));
                                                const binding = @as(u32, @intCast(bind_v.integer));
                                                var size: u32 = 0;
                                                if (size_opt) |s_v| {
                                                    if (s_v == .integer) {
                                                        size = @as(u32, @intCast(s_v.integer));
                                                    }
                                                }

                                                // Extract array size
                                                var array_size: u32 = 1;
                                                if (array_size_opt) |as_v| {
                                                    if (as_v == .array and as_v.array.items.len > 0) {
                                                        if (as_v.array.items[0] == .integer) {
                                                            const arr_size = as_v.array.items[0].integer;
                                                            array_size = if (arr_size == 0) 0 else @as(u32, @intCast(arr_size));
                                                        } else {
                                                            array_size = 0; // Unbounded
                                                        }
                                                    } else if (as_v == .integer) {
                                                        const arr_size = as_v.integer;
                                                        array_size = if (arr_size == 0) 0 else @as(u32, @intCast(arr_size));
                                                    }
                                                }

                                                const name_copy = try self.allocator.dupe(u8, name);
                                                var members = std.ArrayList(ShaderBufferMember){};
                                                _ = &members;
                                                try refl.storage_buffers.append(self.allocator, ShaderBuffer{
                                                    .name = name_copy,
                                                    .binding = binding,
                                                    .set = set,
                                                    .size = size,
                                                    .array_size = array_size,
                                                    .members = members,
                                                });
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // 'ssbos' is emitted by some SPIRV-Cross variants for storage buffers (SSBOs)
                if (res_obj.get("ssbos")) |v| {
                    if (v == .array) {
                        for (v.array.items) |elem| {
                            if (elem == .object) {
                                const name_opt = elem.object.get("name");
                                const set_opt = elem.object.get("set");
                                const binding_opt = elem.object.get("binding");
                                const size_opt = elem.object.get("size");
                                if (name_opt) |nv| std.log.debug("  name present: {s}", .{nv.string});
                                if (set_opt) |sv| std.log.debug("  set present: {}", .{sv.integer});
                                if (binding_opt) |bv| std.log.debug("  binding present: {}", .{bv.integer});
                                if (name_opt) |name_v| {
                                    if (set_opt) |set_v| {
                                        if (binding_opt) |bind_v| {
                                            if (name_v == .string and set_v == .integer and bind_v == .integer) {
                                                const name = name_v.string;
                                                const set = @as(u32, @intCast(set_v.integer));
                                                const binding = @as(u32, @intCast(bind_v.integer));
                                                var size: u32 = 0;
                                                if (size_opt) |s_v| {
                                                    if (s_v == .integer) {
                                                        size = @as(u32, @intCast(s_v.integer));
                                                    }
                                                }
                                                const name_copy = try self.allocator.dupe(u8, name);
                                                var members = std.ArrayList(ShaderBufferMember){};
                                                _ = &members;
                                                try refl.storage_buffers.append(self.allocator, ShaderBuffer{ .name = name_copy, .binding = binding, .set = set, .size = size, .members = members });
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // sampled_images -> combined textures
                if (res_obj.get("sampled_images")) |v| {
                    if (v == .array) {
                        for (v.array.items) |elem| {
                            if (elem == .object) {
                                const name_opt = elem.object.get("name");
                                const set_opt = elem.object.get("set");
                                const binding_opt = elem.object.get("binding");
                                const array_opt = elem.object.get("array");

                                if (name_opt) |name_v| {
                                    if (set_opt) |set_v| {
                                        if (binding_opt) |bind_v| {
                                            if (name_v == .string and set_v == .integer and bind_v == .integer) {
                                                const set = @as(u32, @intCast(set_v.integer));
                                                const binding = @as(u32, @intCast(bind_v.integer));
                                                const array_size = parseDescriptorArraySize(array_opt);
                                                const dimension = blk: {
                                                    if (elem.object.get("type")) |type_v| {
                                                        if (type_v == .string) break :blk mapTextureDimension(type_v.string);
                                                    }
                                                    break :blk TextureDimension.texture_2d;
                                                };

                                                try appendTextureResource(&refl, self.allocator, name_v.string, set, binding, dimension, array_size);
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // Process alternate "textures" field (e.g. from --reflect output)
                if (res_obj.get("textures")) |v| {
                    if (v == .array) {
                        for (v.array.items) |elem| {
                            if (elem == .object) {
                                const name_opt = elem.object.get("name");
                                const set_opt = elem.object.get("set");
                                const binding_opt = elem.object.get("binding");
                                const array_opt = elem.object.get("array");

                                if (name_opt) |name_v| {
                                    if (set_opt) |set_v| {
                                        if (binding_opt) |bind_v| {
                                            if (name_v == .string and set_v == .integer and bind_v == .integer) {
                                                const set = @as(u32, @intCast(set_v.integer));
                                                const binding = @as(u32, @intCast(bind_v.integer));
                                                const array_size = parseDescriptorArraySize(array_opt);
                                                const dimension = blk: {
                                                    if (elem.object.get("type")) |type_v| {
                                                        if (type_v == .string) break :blk mapTextureDimension(type_v.string);
                                                    }
                                                    break :blk TextureDimension.texture_2d;
                                                };

                                                try appendTextureResource(&refl, self.allocator, name_v.string, set, binding, dimension, array_size);
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // Storage images (typically RW images)
                if (res_obj.get("images")) |v| {
                    if (v == .array) {
                        for (v.array.items) |elem| {
                            if (elem == .object) {
                                const name_opt = elem.object.get("name");
                                const set_opt = elem.object.get("set");
                                const binding_opt = elem.object.get("binding");
                                const array_opt = elem.object.get("array");
                                if (name_opt) |name_v| {
                                    if (set_opt) |set_v| {
                                        if (binding_opt) |bind_v| {
                                            if (name_v == .string and set_v == .integer and bind_v == .integer) {
                                                const array_size = parseDescriptorArraySize(array_opt);
                                                try appendStorageImageResource(&refl, self.allocator, name_v.string, @as(u32, @intCast(set_v.integer)), @as(u32, @intCast(bind_v.integer)), array_size);
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // storage_images field (some JSON variants)
                if (res_obj.get("storage_images")) |v| {
                    if (v == .array) {
                        for (v.array.items) |elem| {
                            if (elem == .object) {
                                const name_opt = elem.object.get("name");
                                const set_opt = elem.object.get("set");
                                const binding_opt = elem.object.get("binding");
                                const array_opt = elem.object.get("array");
                                if (name_opt) |name_v| {
                                    if (set_opt) |set_v| {
                                        if (binding_opt) |bind_v| {
                                            if (name_v == .string and set_v == .integer and bind_v == .integer) {
                                                const array_size = parseDescriptorArraySize(array_opt);
                                                try appendStorageImageResource(&refl, self.allocator, name_v.string, @as(u32, @intCast(set_v.integer)), @as(u32, @intCast(bind_v.integer)), array_size);
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // Acceleration structures (ray tracing)
                if (res_obj.get("acceleration_structures")) |v| {
                    if (v == .array) {
                        for (v.array.items) |elem| {
                            if (elem == .object) {
                                const name_opt = elem.object.get("name");
                                const set_opt = elem.object.get("set");
                                const binding_opt = elem.object.get("binding");
                                const array_opt = elem.object.get("array");
                                if (name_opt) |name_v| {
                                    if (set_opt) |set_v| {
                                        if (binding_opt) |bind_v| {
                                            if (name_v == .string and set_v == .integer and bind_v == .integer) {
                                                const array_size = parseDescriptorArraySize(array_opt);
                                                try appendAccelerationStructureResource(
                                                    &refl,
                                                    self.allocator,
                                                    name_v.string,
                                                    @as(u32, @intCast(set_v.integer)),
                                                    @as(u32, @intCast(bind_v.integer)),
                                                    array_size,
                                                );
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // Separate images (to be paired with samplers later)
                if (res_obj.get("separate_images")) |v| {
                    if (v == .array) {
                        for (v.array.items) |elem| {
                            if (elem == .object) {
                                const name_opt = elem.object.get("name");
                                const set_opt = elem.object.get("set");
                                const binding_opt = elem.object.get("binding");
                                const array_opt = elem.object.get("array");
                                if (name_opt) |name_v| {
                                    if (set_opt) |set_v| {
                                        if (binding_opt) |bind_v| {
                                            if (name_v == .string and set_v == .integer and bind_v == .integer) {
                                                const set = @as(u32, @intCast(set_v.integer));
                                                const binding = @as(u32, @intCast(bind_v.integer));
                                                const array_size = parseDescriptorArraySize(array_opt);
                                                const dimension = blk: {
                                                    if (elem.object.get("type")) |type_v| {
                                                        if (type_v == .string) break :blk mapTextureDimension(type_v.string);
                                                    }
                                                    break :blk TextureDimension.texture_2d;
                                                };

                                                if (findPendingCombinedTexture(&pending_combined, set, binding)) |entry| {
                                                    if (array_size > entry.array_size) entry.array_size = array_size;
                                                    entry.dimension = dimension;
                                                    if (name_v.string.len != 0) entry.name = name_v.string;
                                                } else {
                                                    try pending_combined.append(self.allocator, PendingCombinedTexture{
                                                        .name = name_v.string,
                                                        .set = set,
                                                        .binding = binding,
                                                        .array_size = array_size,
                                                        .dimension = dimension,
                                                        .has_sampler = false,
                                                    });
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // separate_samplers
                if (res_obj.get("separate_samplers")) |v| {
                    if (v == .array) {
                        for (v.array.items) |elem| {
                            if (elem == .object) {
                                const name_opt = elem.object.get("name");
                                const set_opt = elem.object.get("set");
                                const binding_opt = elem.object.get("binding");
                                const array_size_opt = elem.object.get("array");
                                if (name_opt) |name_v| {
                                    if (set_opt) |set_v| {
                                        if (binding_opt) |bind_v| {
                                            if (name_v == .string and set_v == .integer and bind_v == .integer) {
                                                const name = name_v.string;
                                                const set = @as(u32, @intCast(set_v.integer));
                                                const binding = @as(u32, @intCast(bind_v.integer));

                                                const array_size = parseDescriptorArraySize(array_size_opt);
                                                if (findPendingCombinedTexture(&pending_combined, set, binding)) |entry| {
                                                    entry.has_sampler = true;
                                                    if (array_size > entry.array_size) entry.array_size = array_size;
                                                } else {
                                                    const name_copy = try self.allocator.dupe(u8, name);
                                                    try refl.samplers.append(self.allocator, ShaderSampler{
                                                        .name = name_copy,
                                                        .binding = binding,
                                                        .set = set,
                                                        .array_size = array_size,
                                                    });
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // push_constants
                if (res_obj.get("push_constants")) |v| {
                    if (v == .array and v.array.items.len > 0) {
                        const first = v.array.items[0];
                        if (first == .object) {
                            const size_opt = first.object.get("size");
                            if (size_opt) |s_v| {
                                if (s_v == .integer) {
                                    const pc = ShaderPushConstants{ .size = @as(u32, @intCast(s_v.integer)), .offset = 0, .stage_flags = 0 };
                                    refl.push_constants = pc;
                                }
                            }
                        }
                    }
                }

                // specialization_constants
                if (res_obj.get("specialization_constants")) |v| {
                    if (v == .array) {
                        for (v.array.items) |elem| {
                            if (elem == .object) {
                                const name_opt = elem.object.get("name");
                                const id_opt = elem.object.get("constant_id");
                                const default_opt = elem.object.get("default_value");
                                if (name_opt) |name_v| {
                                    if (id_opt) |id_v| {
                                        if (name_v == .string and id_v == .integer) {
                                            const name = name_v.string;
                                            const id = @as(u32, @intCast(id_v.integer));
                                            var def: SpecConstValue = .{ .uint_type = 0 };
                                            if (default_opt) |dv| {
                                                switch (dv) {
                                                    .integer => def = SpecConstValue{ .int_type = @as(i32, @intCast(dv.integer)) },
                                                    .float => def = SpecConstValue{ .float_type = @as(f32, @floatCast(dv.float)) },
                                                    .bool => def = SpecConstValue{ .bool_type = dv.bool },
                                                    else => {},
                                                }
                                            }
                                            const name_copy = try self.allocator.dupe(u8, name);
                                            try refl.specialization_constants.append(self.allocator, ShaderSpecializationConstant{ .name = name_copy, .id = id, .default_value = def });
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // Fallback: if SPIRV-Cross emitted top-level arrays like `inputs`, `outputs`, `ubos`, `push_constants`
        const types_val = root.object.get("types");

        // inputs
        if (root.object.get("inputs")) |in_val| {
            if (in_val == .array) {
                for (in_val.array.items) |elem| {
                    if (elem == .object) {
                        if (elem.object.get("name")) |name_v| {
                            if (elem.object.get("location")) |loc_v| {
                                if (name_v == .string and loc_v == .integer) {
                                    const name = name_v.string;
                                    const location = @as(u32, @intCast(loc_v.integer));
                                    const name_copy = try self.allocator.dupe(u8, name);
                                    try refl.inputs.append(self.allocator, ShaderVariable{ .name = name_copy, .location = location, .type = ShaderDataType.struct_type, .size = 0 });
                                }
                            }
                        }
                    }
                }
            }
        }

        // outputs
        if (root.object.get("outputs")) |out_val| {
            if (out_val == .array) {
                for (out_val.array.items) |elem| {
                    if (elem == .object) {
                        if (elem.object.get("name")) |name_v| {
                            if (elem.object.get("location")) |loc_v| {
                                if (name_v == .string and loc_v == .integer) {
                                    const name = name_v.string;
                                    const location = @as(u32, @intCast(loc_v.integer));
                                    const name_copy = try self.allocator.dupe(u8, name);
                                    try refl.outputs.append(self.allocator, ShaderVariable{ .name = name_copy, .location = location, .type = ShaderDataType.struct_type, .size = 0 });
                                }
                            }
                        }
                    }
                }
            }
        }

        // Combined textures at top-level
        if (root.object.get("textures")) |tex_val| {
            if (tex_val == .array) {
                for (tex_val.array.items) |elem| {
                    if (elem == .object) {
                        const name_opt = elem.object.get("name");
                        const set_opt = elem.object.get("set");
                        const binding_opt = elem.object.get("binding");
                        const array_opt = elem.object.get("array");
                        if (name_opt) |name_v| {
                            if (set_opt) |set_v| {
                                if (binding_opt) |bind_v| {
                                    if (name_v == .string and set_v == .integer and bind_v == .integer) {
                                        const set = @as(u32, @intCast(set_v.integer));
                                        const binding = @as(u32, @intCast(bind_v.integer));
                                        const array_size = parseDescriptorArraySize(array_opt);
                                        const dimension = blk: {
                                            if (elem.object.get("type")) |type_v| {
                                                if (type_v == .string) break :blk mapTextureDimension(type_v.string);
                                            }
                                            break :blk TextureDimension.texture_2d;
                                        };
                                        try appendTextureResource(&refl, self.allocator, name_v.string, set, binding, dimension, array_size);
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // Storage images at top-level
        if (root.object.get("images")) |img_val| {
            if (img_val == .array) {
                for (img_val.array.items) |elem| {
                    if (elem == .object) {
                        const name_opt = elem.object.get("name");
                        const set_opt = elem.object.get("set");
                        const binding_opt = elem.object.get("binding");
                        const array_opt = elem.object.get("array");
                        if (name_opt) |name_v| {
                            if (set_opt) |set_v| {
                                if (binding_opt) |bind_v| {
                                    if (name_v == .string and set_v == .integer and bind_v == .integer) {
                                        const array_size = parseDescriptorArraySize(array_opt);
                                        try appendStorageImageResource(&refl, self.allocator, name_v.string, @as(u32, @intCast(set_v.integer)), @as(u32, @intCast(bind_v.integer)), array_size);
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        if (root.object.get("storage_images")) |img_val| {
            if (img_val == .array) {
                for (img_val.array.items) |elem| {
                    if (elem == .object) {
                        const name_opt = elem.object.get("name");
                        const set_opt = elem.object.get("set");
                        const binding_opt = elem.object.get("binding");
                        const array_opt = elem.object.get("array");
                        if (name_opt) |name_v| {
                            if (set_opt) |set_v| {
                                if (binding_opt) |bind_v| {
                                    if (name_v == .string and set_v == .integer and bind_v == .integer) {
                                        const array_size = parseDescriptorArraySize(array_opt);
                                        try appendStorageImageResource(&refl, self.allocator, name_v.string, @as(u32, @intCast(set_v.integer)), @as(u32, @intCast(bind_v.integer)), array_size);
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // Acceleration structures at top-level
        if (root.object.get("acceleration_structures")) |accel_val| {
            if (accel_val == .array) {
                for (accel_val.array.items) |elem| {
                    if (elem == .object) {
                        const name_opt = elem.object.get("name");
                        const set_opt = elem.object.get("set");
                        const binding_opt = elem.object.get("binding");
                        const array_opt = elem.object.get("array");
                        if (name_opt) |name_v| {
                            if (set_opt) |set_v| {
                                if (binding_opt) |bind_v| {
                                    if (name_v == .string and set_v == .integer and bind_v == .integer) {
                                        const array_size = parseDescriptorArraySize(array_opt);
                                        try appendAccelerationStructureResource(
                                            &refl,
                                            self.allocator,
                                            name_v.string,
                                            @as(u32, @intCast(set_v.integer)),
                                            @as(u32, @intCast(bind_v.integer)),
                                            array_size,
                                        );
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // Separate image/sampler pairs at top-level
        if (root.object.get("separate_images")) |img_val| {
            if (img_val == .array) {
                for (img_val.array.items) |elem| {
                    if (elem == .object) {
                        const name_opt = elem.object.get("name");
                        const set_opt = elem.object.get("set");
                        const binding_opt = elem.object.get("binding");
                        const array_opt = elem.object.get("array");
                        if (name_opt) |name_v| {
                            if (set_opt) |set_v| {
                                if (binding_opt) |bind_v| {
                                    if (name_v == .string and set_v == .integer and bind_v == .integer) {
                                        const set = @as(u32, @intCast(set_v.integer));
                                        const binding = @as(u32, @intCast(bind_v.integer));
                                        const array_size = parseDescriptorArraySize(array_opt);
                                        const dimension = blk: {
                                            if (elem.object.get("type")) |type_v| {
                                                if (type_v == .string) break :blk mapTextureDimension(type_v.string);
                                            }
                                            break :blk TextureDimension.texture_2d;
                                        };

                                        if (findPendingCombinedTexture(&pending_combined, set, binding)) |entry| {
                                            if (array_size > entry.array_size) entry.array_size = array_size;
                                            entry.dimension = dimension;
                                            if (name_v.string.len != 0) entry.name = name_v.string;
                                        } else {
                                            try pending_combined.append(self.allocator, PendingCombinedTexture{
                                                .name = name_v.string,
                                                .set = set,
                                                .binding = binding,
                                                .array_size = array_size,
                                                .dimension = dimension,
                                                .has_sampler = false,
                                            });
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        if (root.object.get("separate_samplers")) |sam_val| {
            if (sam_val == .array) {
                for (sam_val.array.items) |elem| {
                    if (elem == .object) {
                        const name_opt = elem.object.get("name");
                        const set_opt = elem.object.get("set");
                        const binding_opt = elem.object.get("binding");
                        const array_opt = elem.object.get("array");
                        if (name_opt) |name_v| {
                            if (set_opt) |set_v| {
                                if (binding_opt) |bind_v| {
                                    if (name_v == .string and set_v == .integer and bind_v == .integer) {
                                        const set = @as(u32, @intCast(set_v.integer));
                                        const binding = @as(u32, @intCast(bind_v.integer));
                                        const array_size = parseDescriptorArraySize(array_opt);
                                        if (findPendingCombinedTexture(&pending_combined, set, binding)) |entry| {
                                            entry.has_sampler = true;
                                            if (array_size > entry.array_size) entry.array_size = array_size;
                                        } else {
                                            const name_copy = try self.allocator.dupe(u8, name_v.string);
                                            try refl.samplers.append(self.allocator, ShaderSampler{
                                                .name = name_copy,
                                                .binding = binding,
                                                .set = set,
                                                .array_size = array_size,
                                            });
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // ubos (top-level uniform blocks)
        if (root.object.get("ubos")) |ubos_val| {
            if (ubos_val == .array) {
                for (ubos_val.array.items) |elem| {
                    if (elem == .object) {
                        if (elem.object.get("name")) |name_v| {
                            if (elem.object.get("set")) |set_v| {
                                if (elem.object.get("binding")) |bind_v| {
                                    if (name_v == .string and set_v == .integer and bind_v == .integer) {
                                        const name = name_v.string;
                                        const set = @as(u32, @intCast(set_v.integer));
                                        const binding = @as(u32, @intCast(bind_v.integer));
                                        var size: u32 = 0;
                                        if (elem.object.get("block_size")) |s_v| {
                                            if (s_v == .integer) {
                                                size = @as(u32, @intCast(s_v.integer));
                                            }
                                        }
                                        const name_copy = try self.allocator.dupe(u8, name);
                                        var members = std.ArrayList(ShaderBufferMember){};

                                        // Resolve members via types if available
                                        if (elem.object.get("type")) |t_v| {
                                            if (t_v == .string) {
                                                const type_key = t_v.string;
                                                if (types_val) |tv| {
                                                    if (tv == .object) {
                                                        const tobj = tv.object;
                                                        if (tobj.get(type_key)) |type_def| {
                                                            if (type_def == .object) {
                                                                if (type_def.object.get("members")) |mval| {
                                                                    if (mval == .array) {
                                                                        for (mval.array.items) |memb| {
                                                                            if (memb == .object) {
                                                                                if (memb.object.get("name")) |mn| {
                                                                                    if (mn == .string) {
                                                                                        const m_name = mn.string;
                                                                                        var m_size: u32 = 0;
                                                                                        if (memb.object.get("offset")) |mo| {
                                                                                            if (mo == .integer) {
                                                                                                const m_offset = @as(u32, @intCast(mo.integer));
                                                                                                // size may be set below; use a temp const for offset
                                                                                                if (memb.object.get("size")) |ms| {
                                                                                                    if (ms == .integer) m_size = @as(u32, @intCast(ms.integer));
                                                                                                }
                                                                                                const m_name_copy = try self.allocator.dupe(u8, m_name);
                                                                                                try members.append(self.allocator, ShaderBufferMember{ .name = m_name_copy, .offset = m_offset, .size = m_size, .type = ShaderDataType.struct_type });
                                                                                                continue;
                                                                                            }
                                                                                        }
                                                                                        if (memb.object.get("size")) |ms| {
                                                                                            if (ms == .integer) m_size = @as(u32, @intCast(ms.integer));
                                                                                        }
                                                                                        // Fallback append (offset may be 0 if not found above)
                                                                                        const m_name_copy = try self.allocator.dupe(u8, m_name);
                                                                                        try members.append(self.allocator, ShaderBufferMember{ .name = m_name_copy, .offset = 0, .size = m_size, .type = ShaderDataType.struct_type });
                                                                                    }
                                                                                }
                                                                            }
                                                                        }
                                                                    }
                                                                }
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }

                                        try refl.uniform_buffers.append(self.allocator, ShaderBuffer{ .name = name_copy, .binding = binding, .set = set, .size = size, .members = members });
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // push_constants (take the first entry if present and resolve size from types)
            if (root.object.get("push_constants")) |pc_val| {
                if (pc_val == .array and pc_val.array.items.len > 0) {
                    const first = pc_val.array.items[0];
                    if (first == .object) {
                        if (first.object.get("type")) |t_v| {
                            if (t_v == .string) {
                                const type_key = t_v.string;
                                var pc_size: u32 = 0;
                                if (types_val) |tv| {
                                    if (tv == .object) {
                                        const tobj = tv.object;
                                        const type_def_opt = tobj.get(type_key);
                                        if (type_def_opt) |type_def| {
                                            if (type_def == .object) {
                                                const members_opt = type_def.object.get("members");
                                                if (members_opt) |mval| {
                                                    if (mval == .array) {
                                                        var max_end: u32 = 0;
                                                        for (mval.array.items) |memb| {
                                                            if (memb == .object) {
                                                                const offset_opt = memb.object.get("offset");
                                                                if (offset_opt) |mo| {
                                                                    if (mo == .integer) {
                                                                        const m_offset = @as(u32, @intCast(mo.integer));
                                                                        var m_size: u32 = 0;
                                                                        const size_opt = memb.object.get("size");
                                                                        if (size_opt) |ms| {
                                                                            if (ms == .integer) m_size = @as(u32, @intCast(ms.integer));
                                                                        }
                                                                        if (m_size == 0) m_size = 16; // conservative default
                                                                        if (m_offset + m_size > max_end) max_end = m_offset + m_size;
                                                                    }
                                                                }
                                                            }
                                                        }
                                                        pc_size = max_end;
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                                if (pc_size != 0) refl.push_constants = ShaderPushConstants{ .size = pc_size, .offset = 0, .stage_flags = 0 };
                            }
                        }
                    }
                }
            }
        }

        // ssbos (top-level storage buffer blocks) - some SPIRV-Cross variants emit 'ssbos'
        if (root.object.get("ssbos")) |ssbos_val| {
            if (ssbos_val == .array) {
                for (ssbos_val.array.items) |elem| {
                    if (elem == .object) {
                        if (elem.object.get("name")) |name_v| {
                            if (elem.object.get("set")) |set_v| {
                                if (elem.object.get("binding")) |bind_v| {
                                    if (name_v == .string and set_v == .integer and bind_v == .integer) {
                                        const name = name_v.string;
                                        const set = @as(u32, @intCast(set_v.integer));
                                        const binding = @as(u32, @intCast(bind_v.integer));
                                        var size: u32 = 0;
                                        if (elem.object.get("block_size")) |s_v| {
                                            if (s_v == .integer) {
                                                size = @as(u32, @intCast(s_v.integer));
                                            }
                                        }
                                        const name_copy = try self.allocator.dupe(u8, name);
                                        var members = std.ArrayList(ShaderBufferMember){};
                                        _ = &members;
                                        try refl.storage_buffers.append(self.allocator, ShaderBuffer{ .name = name_copy, .binding = binding, .set = set, .size = size, .members = members });
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // textures (top-level) - SPIRV-Cross JSON backend emits 'textures' at top level
        if (root.object.get("textures")) |textures_val| {
            if (textures_val == .array) {
                for (textures_val.array.items) |elem| {
                    if (elem == .object) {
                        const name_opt = elem.object.get("name");
                        const set_opt = elem.object.get("set");
                        const binding_opt = elem.object.get("binding");
                        const array_opt = elem.object.get("array");

                        if (name_opt) |name_v| {
                            if (set_opt) |set_v| {
                                if (binding_opt) |bind_v| {
                                    if (name_v == .string and set_v == .integer and bind_v == .integer) {
                                        const name = name_v.string;
                                        const set = @as(u32, @intCast(set_v.integer));
                                        const binding = @as(u32, @intCast(bind_v.integer));

                                        // Extract array size from "array" field
                                        var array_size: u32 = 1;
                                        if (array_opt) |arr_v| {
                                            if (arr_v == .array and arr_v.array.items.len > 0) {
                                                if (arr_v.array.items[0] == .integer) {
                                                    const size = arr_v.array.items[0].integer;
                                                    // 0 means unbounded array in SPIRV-Cross
                                                    array_size = if (size == 0) 0 else @as(u32, @intCast(size));
                                                }
                                            }
                                        }

                                        const name_copy = try self.allocator.dupe(u8, name);
                                        try refl.textures.append(self.allocator, ShaderTexture{
                                            .name = name_copy,
                                            .binding = binding,
                                            .set = set,
                                            .dimension = TextureDimension.texture_2d,
                                            .format = null,
                                            .array_size = array_size,
                                        });
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // Fold any pending combined image/sampler pairs into the texture list so descriptor layouts see them.
        for (pending_combined.items) |entry| {
            try appendTextureResource(&refl, self.allocator, entry.name, entry.set, entry.binding, entry.dimension, entry.array_size);
        }

        return refl;
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
            .file_path = file_path,
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
        if (std.mem.indexOf(u8, path, "rgen")) |_| return .raygen;
        if (std.mem.indexOf(u8, path, "rmiss")) |_| return .miss;
        if (std.mem.indexOf(u8, path, "rchit")) |_| return .closest_hit;
        if (std.mem.indexOf(u8, path, "rahit")) |_| return .any_hit;
        if (std.mem.indexOf(u8, path, "rint")) |_| return .intersection;
        if (std.mem.indexOf(u8, path, "rcall")) |_| return .callable;
        return .vertex; // Default
    }
};

// Error types
pub const ShaderCompilerError = error{
    InvalidSpirvFormat,
    InvalidSpirvMagic,
    GlslCompilationNotImplemented,
    HlslCompilationNotImplemented,
    HlslCompilationFailed,
    HlslFilePathRequired,
    ReflectionGenerationFailed,
    CrossCompilationFailed,
} || spirv_cross.SpvCrossError || std.mem.Allocator.Error;

// Tests
test "ShaderCompiler initialization" {
    const gpa = std.testing.allocator;

    var compiler = try ShaderCompiler.init(gpa);
    defer compiler.deinit();
}
