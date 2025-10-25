const vk = @import("vulkan");
const pipeline_builder = @import("pipeline_builder.zig");
const mesh = @import("mesh.zig");

const VertexInputBinding = pipeline_builder.VertexInputBinding;
const VertexInputAttribute = pipeline_builder.VertexInputAttribute;

/// Shared vertex layouts for common geometry types.
///
/// Each layout uses the pipeline builder representations so renderers
/// can feed them directly into `PipelineConfig` without re-declaring
/// bindings or attributes.
pub const mesh_bindings = [_]VertexInputBinding{
    .{
        .binding = 0,
        .stride = @as(u32, @intCast(@sizeOf(mesh.Vertex))),
        .input_rate = .vertex,
    },
};

pub const mesh_attributes = [_]VertexInputAttribute{
    .{
        .location = 0,
        .binding = 0,
        .format = .r32g32b32_sfloat,
        .offset = @as(u32, @intCast(@offsetOf(mesh.Vertex, "pos"))),
    },
    .{
        .location = 1,
        .binding = 0,
        .format = .r32g32b32_sfloat,
        .offset = @as(u32, @intCast(@offsetOf(mesh.Vertex, "color"))),
    },
    .{
        .location = 2,
        .binding = 0,
        .format = .r32g32b32_sfloat,
        .offset = @as(u32, @intCast(@offsetOf(mesh.Vertex, "normal"))),
    },
    .{
        .location = 3,
        .binding = 0,
        .format = .r32g32_sfloat,
        .offset = @as(u32, @intCast(@offsetOf(mesh.Vertex, "uv"))),
    },
};

/// Particle vertex definition shared between particle systems and any
/// legacy renderer helpers that still rely on it.
pub const Particle = extern struct {
    position: [3]f32 align(16), // vec3 aligns to 16 bytes in std430
    velocity: [3]f32 align(16), // vec3 aligns to 16 bytes in std430
    color: [4]f32 align(16), // vec4 aligns to 16 bytes in std430
    lifetime: f32 align(4), // float aligns to 4 bytes
    max_lifetime: f32 align(4), // float aligns to 4 bytes
    emitter_id: u32 align(4), // uint aligns to 4 bytes
};

/// GPU-side emitter definition for particle spawning on the GPU.
/// This struct is stored in an SSBO and read by the compute shader.
/// Each emitter spawns particles independently on the GPU.
pub const GPUEmitter = extern struct {
    position: [3]f32 align(16), // vec3 aligns to 16 bytes in std140
    is_active: u32 align(4), // uint aligns to 4 bytes

    velocity_min: [3]f32 align(16), // vec3 aligns to 16 bytes in std140
    velocity_max: [3]f32 align(16), // vec3 aligns to 16 bytes in std140

    color_start: [4]f32 align(16), // vec4 aligns to 16 bytes in std140
    color_end: [4]f32 align(16), // vec4 aligns to 16 bytes in std140

    lifetime_min: f32 align(4), // float aligns to 4 bytes
    lifetime_max: f32 align(4), // float aligns to 4 bytes
    spawn_rate: f32 align(4), // float aligns to 4 bytes
    accumulated_spawn_time: f32 align(4), // float aligns to 4 bytes

    particles_per_spawn: u32 align(4), // uint aligns to 4 bytes
};

pub const particle_bindings = [_]VertexInputBinding{
    .{
        .binding = 0,
        .stride = @as(u32, @intCast(@sizeOf(Particle))),
        .input_rate = .vertex,
    },
};

pub const particle_attributes = [_]VertexInputAttribute{
    .{
        .location = 0,
        .binding = 0,
        .format = .r32g32b32_sfloat, // 3D position
        .offset = @as(u32, @intCast(@offsetOf(Particle, "position"))),
    },
    .{
        .location = 1,
        .binding = 0,
        .format = .r32g32b32_sfloat, // 3D velocity
        .offset = @as(u32, @intCast(@offsetOf(Particle, "velocity"))),
    },
    .{
        .location = 2,
        .binding = 0,
        .format = .r32g32b32a32_sfloat,
        .offset = @as(u32, @intCast(@offsetOf(Particle, "color"))),
    },
};
