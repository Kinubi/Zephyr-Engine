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

        var parser = std.json.parseFromSlice(std.json.Value, self.allocator, json_owned, .{}) catch |err| {
            std.log.err("Failed to parse SPIRV-Cross JSON reflection: {}", .{err});
            return error.ReflectionGenerationFailed;
        };
        defer parser.deinit();

        const root = parser.value;
        if (root != .object) return ShaderReflection.init();

        var refl = ShaderReflection.init();

        // Populate arrays (they were zero-initialized in init)
        refl.inputs = std.ArrayList(ShaderVariable){};
        refl.outputs = std.ArrayList(ShaderVariable){};
        refl.uniform_buffers = std.ArrayList(ShaderBuffer){};
        refl.storage_buffers = std.ArrayList(ShaderBuffer){};
        refl.textures = std.ArrayList(ShaderTexture){};
        refl.samplers = std.ArrayList(ShaderSampler){};
        refl.specialization_constants = std.ArrayList(ShaderSpecializationConstant){};

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

                                                try refl.uniform_buffers.append(self.allocator, ShaderBuffer{ .name = name_copy, .binding = binding, .set = set, .size = size, .members = members });
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

                // sampled_images -> textures
                if (res_obj.get("sampled_images")) |v| {
                    if (v == .array) {
                        for (v.array.items) |elem| {
                            if (elem == .object) {
                                const name_opt = elem.object.get("name");
                                const set_opt = elem.object.get("set");
                                const binding_opt = elem.object.get("binding");
                                if (name_opt) |name_v| {
                                    if (set_opt) |set_v| {
                                        if (binding_opt) |bind_v| {
                                            if (name_v == .string and set_v == .integer and bind_v == .integer) {
                                                const name = name_v.string;
                                                const set = @as(u32, @intCast(set_v.integer));
                                                const binding = @as(u32, @intCast(bind_v.integer));
                                                const name_copy = try self.allocator.dupe(u8, name);
                                                try refl.textures.append(self.allocator, ShaderTexture{ .name = name_copy, .binding = binding, .set = set, .dimension = TextureDimension.texture_2d, .format = null });
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
                                if (name_opt) |name_v| {
                                    if (set_opt) |set_v| {
                                        if (binding_opt) |bind_v| {
                                            if (name_v == .string and set_v == .integer and bind_v == .integer) {
                                                const name = name_v.string;
                                                const set = @as(u32, @intCast(set_v.integer));
                                                const binding = @as(u32, @intCast(bind_v.integer));
                                                const name_copy = try self.allocator.dupe(u8, name);
                                                try refl.samplers.append(self.allocator, ShaderSampler{ .name = name_copy, .binding = binding, .set = set });
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
