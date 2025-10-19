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
    position: [2]f32,
    velocity: [2]f32,
    color: [4]f32,
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
        .format = .r32g32_sfloat,
        .offset = @as(u32, @intCast(@offsetOf(Particle, "position"))),
    },
    .{
        .location = 1,
        .binding = 0,
        .format = .r32g32_sfloat,
        .offset = @as(u32, @intCast(@offsetOf(Particle, "velocity"))),
    },
    .{
        .location = 2,
        .binding = 0,
        .format = .r32g32b32a32_sfloat,
        .offset = @as(u32, @intCast(@offsetOf(Particle, "color"))),
    },
};
