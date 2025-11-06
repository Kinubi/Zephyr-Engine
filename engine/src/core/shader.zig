const std = @import("std");
const vk = @import("vulkan");
const GC = @import("graphics_context.zig").GraphicsContext;
const ShaderCompiler = @import("../assets/shader_compiler.zig");

pub const entry_point_definition = struct { name: []const u8 = "main" };

pub const Shader = struct {
    module: vk.ShaderModule,
    shader_type: vk.ShaderStageFlags,
    entry_point: entry_point_definition = entry_point_definition{ .name = "main" },
    reflection: ShaderCompiler.ShaderReflection,

    pub fn create(gc: GC, code: []const u8, shader_type: vk.ShaderStageFlags, entry_point: ?entry_point_definition, reflection: ShaderCompiler.ShaderReflection) !Shader {
        const data: [*]const u32 = @ptrCast(@alignCast(code.ptr));

        const module = try gc.vkd.createShaderModule(gc.dev, &vk.ShaderModuleCreateInfo{
            .flags = .{},
            .code_size = code.len,
            .p_code = data,
        }, null);
        return Shader{
            .module = module,
            .shader_type = shader_type,
            .entry_point = entry_point orelse entry_point_definition{ .name = "main" },
            .reflection = reflection,
        };
    }

    pub fn deinit(self: Shader, gc: GC) void {
        gc.vkd.destroyShaderModule(gc.dev, self.module, null);
    }
};

pub const ShaderLibrary = struct {
    gc: GC,
    shaders: std.ArrayList(Shader),
    allocator: std.mem.Allocator,

    pub fn init(gc: GC, alloc: std.mem.Allocator) ShaderLibrary {
        return ShaderLibrary{ .gc = gc, .shaders = std.ArrayList(Shader){}, .allocator = alloc };
    }

    pub fn add(self: *ShaderLibrary, shader_codes: []const []const u8, shader_types: []const vk.ShaderStageFlags, entry_points: []const entry_point_definition) !void {
        if (shader_codes.len != shader_types.len) {
            return error.InvalidShaderCode;
        }

        for (shader_codes, shader_types, entry_points) |code, shader_type, entry_point| {
            // Legacy code: create empty reflection since we don't have reflection data here
            const empty_reflection = ShaderCompiler.ShaderReflection.init();
            const shader = try Shader.create(self.gc, @ptrCast(@constCast(code)), shader_type, entry_point, empty_reflection);
            try self.shaders.append(self.allocator, shader);
        }
    }

    pub fn deinit(self: *ShaderLibrary) void {
        for (self.shaders.items) |shader| {
            shader.deinit(self.gc);
        }
        self.shaders.deinit(self.allocator);
    }
};

// ShaderLibrary struct already stores gc as a member, matching the init signature. Allocator is not stored, as std.ArrayList handles it.
