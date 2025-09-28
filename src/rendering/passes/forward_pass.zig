const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("../../core/graphics_context.zig").GraphicsContext;
const RenderPass = @import("../render_pass.zig").RenderPass;
const RenderContext = @import("../render_pass.zig").RenderContext;
const PassConfig = @import("../render_pass.zig").PassConfig;
const PassType = @import("../render_pass.zig").PassType;
const PassPriority = @import("../render_pass.zig").PassPriority;
const ResourceBinding = @import("../render_pass.zig").ResourceBinding;
const VulkanRenderPassResources = @import("../render_pass.zig").VulkanRenderPassResources;
const TexturedRenderer = @import("../../renderers/textured_renderer.zig").TexturedRenderer;
const PointLightRenderer = @import("../../renderers/point_light_renderer.zig").PointLightRenderer;

/// Forward rendering pass - renders opaque geometry with lighting
/// Uses existing swapchain render pass and integrates with existing renderers
pub const ForwardPass = struct {
    // External renderer references (not owned)
    textured_renderer: ?*TexturedRenderer = null,
    point_light_renderer: ?*PointLightRenderer = null,

    // Configuration
    config: PassConfig,
    allocator: std.mem.Allocator,
    initialized: bool = false,

    pub fn init(self: *ForwardPass, graphics_context: *GraphicsContext) !void {
        if (self.initialized) return;
        _ = graphics_context;

        self.initialized = true;
        std.log.info("ForwardPass: Initialized (using external renderers)", .{});
    }

    /// Set external renderer references
    pub fn setRenderers(self: *ForwardPass, textured_renderer: *TexturedRenderer, point_light_renderer: *PointLightRenderer) void {
        self.textured_renderer = textured_renderer;
        self.point_light_renderer = point_light_renderer;
        self.initialized = true;
        std.log.info("ForwardPass: Renderers set - TexturedRenderer and PointLightRenderer", .{});
    }

    pub fn execute(self: *ForwardPass, context: RenderContext) !void {
        //std.log.info("ForwardPass: Executing forward rendering", .{});

        // Get scene data to show we can access it
        const raster_data = context.scene_view.getRasterizationData();
        //std.log.info("  - Processing {d} objects with {d} materials", .{ raster_data.objects.len, raster_data.materials.len });

        // Render opaque objects using TexturedRenderer
        if (self.textured_renderer) |renderer| {
            //std.log.info("  - Rendering objects with TexturedRenderer", .{});
            try renderer.render(context.frame_info.*, raster_data);
        } else {
            //std.log.warn("  - TexturedRenderer not configured!", .{});
        }

        // Render point lights using existing PointLightRenderer
        if (self.point_light_renderer) |renderer| {
            //std.log.info("  - Rendering point lights with PointLightRenderer", .{});
            try renderer.render(context.frame_info.*);
        } else {
            std.log.warn("  - PointLightRenderer not configured!", .{});
        }
    }

    pub fn deinit(self: *ForwardPass) void {
        if (self.initialized) {
            // Don't deinit renderers - they're owned externally
            self.initialized = false;
        }
        std.log.info("ForwardPass: Deinitialized", .{});
    }

    pub fn getVulkanRenderPass(self: *ForwardPass) ?vk.RenderPass {
        _ = self;
        // We use the swapchain's render pass, not our own
        return null;
    }

    pub fn beginPass(self: *ForwardPass, context: RenderContext) !void {
        _ = self;
        std.log.info("ForwardPass: Beginning pass setup", .{});

        // Could set additional render state here
        // - Bind global descriptor sets
        // - Set up dynamic rendering state
        // - Configure viewport/scissor if needed
        _ = context;
    }

    pub fn endPass(self: *ForwardPass, context: RenderContext) !void {
        _ = self;
        _ = context;
        std.log.info("ForwardPass: Ending pass cleanup", .{});

        // Could do cleanup here
        // - Unbind resources
        // - Generate mip-maps
        // - Transition layouts
    }

    pub fn shouldExecute(self: *ForwardPass, context: RenderContext) bool {
        _ = self;
        // Could check if there are any objects to render
        const raster_data = context.scene_view.getRasterizationData();
        return raster_data.objects.len > 0;
    }

    pub fn getResourceRequirements(self: *ForwardPass) []const ResourceBinding {
        _ = self;
        // Define what resources this pass needs
        const bindings = [_]ResourceBinding{
            .{
                .resource_name = "color_target",
                .access = .write,
                .stage = .{ .color_attachment_output_bit = true },
            },
            .{
                .resource_name = "depth_target",
                .access = .write,
                .stage = .{ .early_fragment_tests_bit = true, .late_fragment_tests_bit = true },
            },
        };
        return &bindings;
    }

    /// Create a configured ForwardPass
    pub fn create(allocator: std.mem.Allocator) !ForwardPass {
        const config = PassConfig{
            .name = "forward_pass",
            .pass_type = .rasterization,
            .priority = .geometry,
            .resource_bindings = &[_]ResourceBinding{},
            .enabled = true,
        };

        return ForwardPass{
            .config = config,
            .allocator = allocator,
        };
    }

    /// Convert to RenderPass trait object
    pub fn asRenderPass(self: *ForwardPass) RenderPass {
        return RenderPass.create(ForwardPass, self, self.config);
    }
};
