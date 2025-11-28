const vk = @import("vulkan");
const GraphicsContext = @import("../core/graphics_context.zig").GraphicsContext;

/// Helper for setting up dynamic rendering with less boilerplate
pub const DynamicRenderingHelper = struct {
    color_attachment: vk.RenderingAttachmentInfo,
    depth_attachment: ?vk.RenderingAttachmentInfo,
    rendering_info: vk.RenderingInfo,
    viewport: vk.Viewport,
    scissor: vk.Rect2D,

    pub fn init(
        color_view: vk.ImageView,
        depth_view: ?vk.ImageView,
        extent: vk.Extent2D,
        clear_color: [4]f32,
        clear_depth: f32,
    ) DynamicRenderingHelper {
        const color_attachment = vk.RenderingAttachmentInfo{
            .s_type = .rendering_attachment_info,
            .p_next = null,
            .image_view = color_view,
            .image_layout = .general, // Unified layout - no transitions needed
            .resolve_mode = .{},
            .resolve_image_view = .null_handle,
            .resolve_image_layout = .undefined,
            .load_op = .clear,
            .store_op = .store,
            .clear_value = .{ .color = .{ .float_32 = clear_color } },
        };

        const depth_attachment: ?vk.RenderingAttachmentInfo = if (depth_view) |dv| vk.RenderingAttachmentInfo{
            .s_type = .rendering_attachment_info,
            .p_next = null,
            .image_view = dv,
            .image_layout = .general, // Unified layout - no transitions needed
            .resolve_mode = .{},
            .resolve_image_view = .null_handle,
            .resolve_image_layout = .undefined,
            .load_op = .clear,
            .store_op = .store,
            .clear_value = .{ .depth_stencil = .{ .depth = clear_depth, .stencil = 0 } },
        } else null;

        var helper = DynamicRenderingHelper{
            .color_attachment = color_attachment,
            .depth_attachment = depth_attachment,
            .rendering_info = undefined,
            .viewport = vk.Viewport{
                .x = 0.0,
                .y = 0.0,
                .width = @floatFromInt(extent.width),
                .height = @floatFromInt(extent.height),
                .min_depth = 0.0,
                .max_depth = 1.0,
            },
            .scissor = vk.Rect2D{
                .offset = .{ .x = 0, .y = 0 },
                .extent = extent,
            },
        };

        // Build rendering info
        helper.rendering_info = vk.RenderingInfo{
            .s_type = .rendering_info,
            .p_next = null,
            .flags = .{},
            .render_area = helper.scissor,
            .layer_count = 1,
            .view_mask = 0,
            .color_attachment_count = 1,
            .p_color_attachments = @ptrCast(&helper.color_attachment),
            .p_depth_attachment = if (depth_attachment != null) @ptrCast(&helper.depth_attachment) else null,
            .p_stencil_attachment = null,
        };

        return helper;
    }

    /// Initialize with load operation (don't clear, load existing content)
    pub fn initLoad(
        color_view: vk.ImageView,
        depth_view: ?vk.ImageView,
        extent: vk.Extent2D,
    ) DynamicRenderingHelper {
        const color_attachment = vk.RenderingAttachmentInfo{
            .s_type = .rendering_attachment_info,
            .p_next = null,
            .image_view = color_view,
            .image_layout = .general, // Unified layout - no transitions needed
            .resolve_mode = .{},
            .resolve_image_view = .null_handle,
            .resolve_image_layout = .undefined,
            .load_op = .load, // Load existing content
            .store_op = .store,
            .clear_value = undefined,
        };

        const depth_attachment: ?vk.RenderingAttachmentInfo = if (depth_view) |dv| vk.RenderingAttachmentInfo{
            .s_type = .rendering_attachment_info,
            .p_next = null,
            .image_view = dv,
            .image_layout = .general, // Unified layout - no transitions needed
            .resolve_mode = .{},
            .resolve_image_view = .null_handle,
            .resolve_image_layout = .undefined,
            .load_op = .load, // Load existing depth
            .store_op = .store,
            .clear_value = undefined,
        } else null;

        var helper = DynamicRenderingHelper{
            .color_attachment = color_attachment,
            .depth_attachment = depth_attachment,
            .rendering_info = undefined,
            .viewport = vk.Viewport{
                .x = 0.0,
                .y = 0.0,
                .width = @floatFromInt(extent.width),
                .height = @floatFromInt(extent.height),
                .min_depth = 0.0,
                .max_depth = 1.0,
            },
            .scissor = vk.Rect2D{
                .offset = .{ .x = 0, .y = 0 },
                .extent = extent,
            },
        };

        // Build rendering info
        helper.rendering_info = vk.RenderingInfo{
            .s_type = .rendering_info,
            .p_next = null,
            .flags = .{},
            .render_area = helper.scissor,
            .layer_count = 1,
            .view_mask = 0,
            .color_attachment_count = 1,
            .p_color_attachments = @ptrCast(&helper.color_attachment),
            .p_depth_attachment = if (depth_attachment != null) @ptrCast(&helper.depth_attachment) else null,
            .p_stencil_attachment = null,
        };

        return helper;
    }

    pub fn begin(self: *const DynamicRenderingHelper, gc: *GraphicsContext, cmd: vk.CommandBuffer) void {
        gc.vkd.cmdBeginRendering(cmd, &self.rendering_info);
        gc.vkd.cmdSetViewport(cmd, 0, 1, @ptrCast(&self.viewport));
        gc.vkd.cmdSetScissor(cmd, 0, 1, @ptrCast(&self.scissor));
    }

    pub fn end(self: *const DynamicRenderingHelper, gc: *GraphicsContext, cmd: vk.CommandBuffer) void {
        _ = self;
        gc.vkd.cmdEndRendering(cmd);
    }

    /// Initialize for depth-only rendering (shadow maps)
    /// Supports multiview via view_mask for rendering to multiple layers simultaneously
    pub fn initDepthOnly(
        depth_view: vk.ImageView,
        extent: vk.Extent2D,
        clear_depth: f32,
        view_mask: u32,
        layer_count: u32,
    ) DynamicRenderingHelper {
        const depth_attachment = vk.RenderingAttachmentInfo{
            .s_type = .rendering_attachment_info,
            .p_next = null,
            .image_view = depth_view,
            .image_layout = .general, // Unified layout - no transitions needed
            .resolve_mode = .{},
            .resolve_image_view = .null_handle,
            .resolve_image_layout = .undefined,
            .load_op = .clear,
            .store_op = .store,
            .clear_value = .{ .depth_stencil = .{ .depth = clear_depth, .stencil = 0 } },
        };

        var helper = DynamicRenderingHelper{
            .color_attachment = undefined, // Not used for depth-only
            .depth_attachment = depth_attachment,
            .rendering_info = undefined,
            .viewport = vk.Viewport{
                .x = 0.0,
                .y = 0.0,
                .width = @floatFromInt(extent.width),
                .height = @floatFromInt(extent.height),
                .min_depth = 0.0,
                .max_depth = 1.0,
            },
            .scissor = vk.Rect2D{
                .offset = .{ .x = 0, .y = 0 },
                .extent = extent,
            },
        };

        // Build rendering info with multiview support
        helper.rendering_info = vk.RenderingInfo{
            .s_type = .rendering_info,
            .p_next = null,
            .flags = .{},
            .render_area = helper.scissor,
            .layer_count = layer_count,
            .view_mask = view_mask, // Multiview: bits indicate which views to render
            .color_attachment_count = 0,
            .p_color_attachments = null,
            .p_depth_attachment = @ptrCast(&helper.depth_attachment),
            .p_stencil_attachment = null,
        };

        return helper;
    }
};
