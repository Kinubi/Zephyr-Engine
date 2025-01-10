const std = @import("std");
const vk = @import("vulkan");
const Camera = @import("camera.zig").Camera;

pub const FrameInfo = struct {
    command_buffer: vk.CommandBuffer = undefined,
    camera: *Camera = undefined,
    dt: f32 = 0,
    current_frame: u32 = 0,
    extent: vk.Extent2D = .{ .width = 1280, .height = 720 },
};
