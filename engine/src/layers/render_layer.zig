const std = @import("std");
const Layer = @import("../core/layer.zig").Layer;
const Event = @import("../core/event.zig").Event;
const FrameInfo = @import("../rendering/frameinfo.zig").FrameInfo;
const Swapchain = @import("../core/swapchain.zig").Swapchain;

/// Rendering infrastructure layer
/// Manages swapchain frame lifecycle (begin/present)
pub const RenderLayer = struct {
    base: Layer,
    swapchain: *Swapchain,

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
        try self.swapchain.beginFrame(frame_info.*);
        if (self.swapchain.use_viewport_texture) {
            return;
        }

        // Populate image views for dynamic rendering (swapchain images are now ready)
        const swap_image = self.swapchain.currentSwapImage();
        // Note: We need to cast away const here to populate frame_info
        // This is safe because we're in the begin phase
        const mutable_frame_info: *FrameInfo = @constCast(frame_info);
        mutable_frame_info.color_image = self.swapchain.currentImage();
        mutable_frame_info.color_image_view = swap_image.view;
        mutable_frame_info.depth_image_view = swap_image.depth_image_view;
    }

    fn update(base: *Layer, frame_info: *const FrameInfo) !void {
        _ = base;
        _ = frame_info;
        // Frame already began in begin()
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
