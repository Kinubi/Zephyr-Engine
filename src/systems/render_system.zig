const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("../core/graphics_context.zig").GraphicsContext;
const Swapchain = @import("../core/swapchain.zig").Swapchain;
const FrameInfo = @import("../rendering/frameinfo.zig").FrameInfo;

/// Render system for managing render passes and ergonomic begin/end API.
pub const RenderSystem = struct {
    gc: *GraphicsContext,
    swapchain: *Swapchain,

    pub fn init(gc: *GraphicsContext, swapchain: *Swapchain) RenderSystem {
        return RenderSystem{
            .gc = gc,
            .swapchain = swapchain,
        };
    }

    pub fn beginRender(self: *RenderSystem, frame_info: FrameInfo) void {
        self.swapchain.beginSwapChainRenderPass(frame_info);
    }

    pub fn endRender(self: *RenderSystem, frame_info: FrameInfo) void {
        self.swapchain.endSwapChainRenderPass(frame_info);
    }
};
