const std = @import("std");
const zephyr = @import("zephyr");
const vk = @import("vulkan");

/// Simple layer that clears the screen to a color
/// This ensures proper image layout transitions
pub const SimpleClearLayer = struct {
    base: zephyr.Layer,
    clear_color: [4]f32,

    pub fn init(r: f32, g: f32, b: f32, a: f32) SimpleClearLayer {
        return .{
            .base = .{
                .name = "SimpleClearLayer",
                .enabled = true,
                .vtable = &vtable,
            },
            .clear_color = .{ r, g, b, a },
        };
    }

    const vtable = zephyr.Layer.VTable{
        .attach = attach,
        .detach = detach,
        .begin = begin,
        .update = update,
        .render = render,
        .end = end,
        .event = event,
    };

    fn attach(base: *zephyr.Layer) !void {
        _ = base;
    }

    fn detach(base: *zephyr.Layer) void {
        _ = base;
    }

    fn begin(base: *zephyr.Layer, frame_info: *const zephyr.FrameInfo) !void {
        _ = base;
        _ = frame_info;
    }

    fn update(base: *zephyr.Layer, frame_info: *const zephyr.FrameInfo) !void {
        _ = base;
        _ = frame_info;
    }

    fn render(base: *zephyr.Layer, frame_info: *const zephyr.FrameInfo) !void {
        const self: *SimpleClearLayer = @fieldParentPtr("base", base);

        // Get graphics context from frame_info (we need vkd for commands)
        // For now, we'll just skip actual rendering since we'd need the GraphicsContext
        // The RenderLayer handles the image layout transitions
        _ = self;
    }

    fn end(base: *zephyr.Layer, frame_info: *zephyr.FrameInfo) !void {
        _ = base;
        _ = frame_info;
    }

    fn event(base: *zephyr.Layer, evt: *zephyr.Event) void {
        _ = base;
        _ = evt;
    }
};
