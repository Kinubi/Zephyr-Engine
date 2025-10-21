const std = @import("std");
const vk = @import("vulkan");
const Camera = @import("camera.zig").Camera;
const Math = @import("../utils/math.zig");

const MAX_LIGHTS: usize = 16;

const PointLight = struct {
    position: Math.Vec4 = Math.Vec4.init(0, 0, 0, 1),
    color: Math.Vec4 = Math.Vec4.init(1, 1, 1, 1),
};

pub const GlobalUbo = struct {
    projection: Math.Mat4x4 = Math.Mat4x4.identity(),
    view: Math.Mat4x4 = Math.Mat4x4.identity(),
    ambient_color: Math.Vec4 = Math.Vec4.init(1, 1, 1, 0.2),
    point_lights: [MAX_LIGHTS]PointLight = undefined,
    num_point_lights: u32 = 6,
    dt: f32 = 0,
};

pub const FrameInfo = struct {
    command_buffer: vk.CommandBuffer = undefined,
    compute_buffer: vk.CommandBuffer = undefined,
    camera: *Camera = undefined,
    dt: f32 = 0,
    current_frame: u32 = 0,
    extent: vk.Extent2D = .{ .width = 1280, .height = 720 },
    global_descriptor_set: vk.DescriptorSet = undefined,
    ray_tracing_descriptor_set: vk.DescriptorSet = undefined,

    // Dynamic rendering attachments (for RenderGraph)
    color_image: vk.Image = .null_handle,
    color_image_view: vk.ImageView = .null_handle,
    depth_image_view: vk.ImageView = .null_handle,
};
