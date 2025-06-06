const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("graphics_context.zig").GraphicsContext;
const Scene = @import("scene.zig").Scene;
const Pipeline = @import("pipeline.zig").Pipeline;
const ShaderLibrary = @import("shader.zig").ShaderLibrary;
const Math = @import("utils/math.zig");
const glfw = @import("mach-glfw");
const Camera = @import("camera.zig").Camera;
const FrameInfo = @import("frameinfo.zig").FrameInfo;
const GlobalUbo = @import("frameinfo.zig").GlobalUbo;
const Geometry = @import("geometry.zig").Geometry;
const ComputeShaderSystem = @import("systems/compute_shader_system.zig").ComputeShaderSystem;
const Buffer = @import("buffer.zig").Buffer;
const DescriptorPool = @import("descriptors.zig").DescriptorPool;
const DescriptorSetLayout = @import("descriptors.zig").DescriptorSetLayout;
const DescriptorWriter = @import("descriptors.zig").DescriptorWriter;
const Texture = @import("texture.zig").Texture;
const deinitDescriptorResources = @import("descriptors.zig").deinitDescriptorResources;
const MAX_FRAMES_IN_FLIGHT = @import("swapchain.zig").MAX_FRAMES_IN_FLIGHT;

const SimplePushConstantData = extern struct {
    transform: [16]f32 = Math.Mat4x4.identity().data,
    normal_matrix: [16]f32 = Math.Mat4x4.identity().data,
};

const PointLightPushConstant = struct {
    position: Math.Vec4 = Math.Vec4.init(0, 0, 0, 1),
    color: Math.Vec4 = Math.Vec4.init(1, 1, 1, 1),
    radius: f32 = 1.0,
};

pub const Particle = extern struct {
    position: [2]f32,
    velocity: [2]f32,
    color: [4]f32,

    pub const binding_description = vk.VertexInputBindingDescription{
        .binding = 0,
        .stride = @sizeOf(Particle),
        .input_rate = .vertex,
    };

    pub const attribute_description = [_]vk.VertexInputAttributeDescription{
        .{
            .binding = 0,
            .location = 0,
            .format = .r32g32_sfloat,
            .offset = @offsetOf(Particle, "position"),
        },
        .{
            .binding = 0,
            .location = 1,
            .format = .r32g32_sfloat,
            .offset = @offsetOf(Particle, "velocity"),
        },
        .{
            .binding = 0,
            .location = 2,
            .format = .r32g32b32a32_sfloat,
            .offset = @offsetOf(Particle, "color"),
        },
    };
};

// All pipeline, buffer, and descriptor management uses abstractions (Pipeline, Buffer, DescriptorPool, DescriptorSetLayout, DescriptorWriter, etc.)
// No raw Vulkan resource management is used directly in this file.
