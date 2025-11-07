const std = @import("std");
const Layer = @import("../core/layer.zig").Layer;
const Event = @import("../core/event.zig").Event;
const FrameInfo = @import("../rendering/frameinfo.zig").FrameInfo;
const Swapchain = @import("../core/swapchain.zig").Swapchain;
const TextureManager = @import("../rendering/texture_manager.zig").TextureManager;

/// Rendering infrastructure layer
/// Manages swapchain frame lifecycle (begin/present) and infrastructure textures
pub const RenderLayer = struct {
    base: Layer,
    swapchain: *Swapchain,
    texture_manager: ?*TextureManager = null,

    pub fn init(swapchain: *Swapchain) RenderLayer {
        return .{
            .base = .{
                .name = "RenderLayer",
                .enabled = true,
                .vtable = &vtable,
            },
            .swapchain = swapchain,
        };
    }

    /// Set the texture manager for infrastructure texture updates
    pub fn setTextureManager(self: *RenderLayer, texture_manager: *TextureManager) void {
        self.texture_manager = texture_manager;
    }

    const vtable = Layer.VTable{
        .attach = attach,
        .detach = detach,
        .prepare = null, // RenderLayer has no main thread work
        .begin = begin,
        .update = update,
        .render = render,
        .end = end,
        .event = event,
    };

    fn attach(base: *Layer) !void {
        const self: *RenderLayer = @fieldParentPtr("base", base);
        _ = self;
    }

    fn detach(base: *Layer) void {
        const self: *RenderLayer = @fieldParentPtr("base", base);
        _ = self;
    }

    fn begin(base: *Layer, frame_info: *const FrameInfo) !void {
        const self: *RenderLayer = @fieldParentPtr("base", base);

        // Begin frame - starts both graphics and compute command buffers
        // Update infrastructure textures (HDR/LDR resize checks)
        if (self.texture_manager) |tm| {
            tm.beginFrame(frame_info.current_frame);
        }
        try self.swapchain.beginFrame(frame_info.*);
        const mutable_frame_info: *FrameInfo = @constCast(frame_info);
        const current_hdr = self.swapchain.currentHdrTexture();
        mutable_frame_info.hdr_texture = &current_hdr.texture;

        if (self.swapchain.use_viewport_texture) {
            return;
        }

        // Populate image views for dynamic rendering (swapchain images are now ready)
        const swap_image = self.swapchain.currentSwapImage();
        // Note: We need to cast away const here to populate frame_info
        // This is safe because we're in the begin phase

        // Route all rendering into the HDR backbuffer managed by the swapchain
        mutable_frame_info.color_image = swap_image.image;
        mutable_frame_info.color_image_view = swap_image.view;
        mutable_frame_info.depth_image_view = swap_image.depth_image_view;
    }

    fn update(base: *Layer, frame_info: *const FrameInfo) !void {
        const self: *RenderLayer = @fieldParentPtr("base", base);
        _ = frame_info;

        // Update infrastructure textures (HDR/LDR resize checks)
        if (self.texture_manager) |tm| {
            try tm.updateTextures();
        }
    }

    fn render(base: *Layer, frame_info: *const FrameInfo) !void {
        _ = base;
        _ = frame_info;
        // Actual rendering happens in SceneLayer
    }

    fn end(base: *Layer, frame_info: *FrameInfo) !void {
        const self: *RenderLayer = @fieldParentPtr("base", base);
        try self.swapchain.endFrame(frame_info);
    }

    fn event(base: *Layer, evt: *Event) void {
        const self: *RenderLayer = @fieldParentPtr("base", base);
        _ = self;
        _ = evt;
    }
};
