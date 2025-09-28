const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("../core/graphics_context.zig").GraphicsContext;
const FrameInfo = @import("../rendering/frameinfo.zig").FrameInfo;

/// Render pass types for categorization and optimization
pub const PassType = enum {
    rasterization,
    raytracing,
    compute,
    present,
};

/// Render pass execution priority (lower numbers execute first)
pub const PassPriority = enum(u8) {
    shadow_maps = 10,
    early_depth = 20,
    geometry = 30,
    lighting = 40,
    transparency = 50,
    post_process = 60,
    ui_overlay = 70,
    present = 80,
};

/// Resource access pattern for dependency tracking
pub const ResourceAccess = enum {
    read,
    write,
    read_write,
};

/// Resource binding description for automatic tracking
pub const ResourceBinding = struct {
    resource_name: []const u8,
    access: ResourceAccess,
    stage: vk.PipelineStageFlags,
};

/// Render pass configuration and metadata
pub const PassConfig = struct {
    name: []const u8,
    pass_type: PassType,
    priority: PassPriority,
    resource_bindings: []const ResourceBinding,
    enabled: bool = true,
};

/// Vulkan render pass resources for rasterization passes
pub const VulkanRenderPassResources = struct {
    render_pass: vk.RenderPass = .null_handle,
    framebuffers: []vk.Framebuffer = &[_]vk.Framebuffer{},
    attachments: []AttachmentInfo = &[_]AttachmentInfo{},
    clear_values: []vk.ClearValue = &[_]vk.ClearValue{},
    graphics_context: *GraphicsContext = undefined,
    allocator: std.mem.Allocator = undefined,

    pub const AttachmentInfo = struct {
        format: vk.Format,
        samples: vk.SampleCountFlags = .{ .@"1_bit" = true },
        load_op: vk.AttachmentLoadOp = .clear,
        store_op: vk.AttachmentStoreOp = .store,
        initial_layout: vk.ImageLayout = .undefined,
        final_layout: vk.ImageLayout,
        is_depth: bool = false,
    };

    /// Create render pass and framebuffers from attachment descriptions
    pub fn init(graphics_context: *GraphicsContext, allocator: std.mem.Allocator, attachments: []const AttachmentInfo, extent: vk.Extent2D, image_views: []const vk.ImageView) !VulkanRenderPassResources {
        var self = VulkanRenderPassResources{
            .graphics_context = graphics_context,
            .allocator = allocator,
        };

        // Store attachment info
        self.attachments = try allocator.dupe(AttachmentInfo, attachments);

        // Create Vulkan attachments
        var vk_attachments = try allocator.alloc(vk.AttachmentDescription, attachments.len);
        defer allocator.free(vk_attachments);

        for (attachments, 0..) |att_info, i| {
            vk_attachments[i] = vk.AttachmentDescription{
                .flags = .{},
                .format = att_info.format,
                .samples = att_info.samples,
                .load_op = att_info.load_op,
                .store_op = att_info.store_op,
                .stencil_load_op = .dont_care,
                .stencil_store_op = .dont_care,
                .initial_layout = att_info.initial_layout,
                .final_layout = att_info.final_layout,
            };
        }

        // Create attachment references
        var color_refs = std.ArrayList(vk.AttachmentReference).init(allocator);
        defer color_refs.deinit();
        var depth_ref: ?vk.AttachmentReference = null;

        for (attachments, 0..) |att_info, i| {
            if (att_info.is_depth) {
                depth_ref = vk.AttachmentReference{
                    .attachment = @intCast(i),
                    .layout = .depth_stencil_attachment_optimal,
                };
            } else {
                try color_refs.append(vk.AttachmentReference{
                    .attachment = @intCast(i),
                    .layout = .color_attachment_optimal,
                });
            }
        }

        // Create subpass
        const subpass = vk.SubpassDescription{
            .flags = .{},
            .pipeline_bind_point = .graphics,
            .input_attachment_count = 0,
            .p_input_attachments = null,
            .color_attachment_count = @intCast(color_refs.items.len),
            .p_color_attachments = color_refs.items.ptr,
            .p_resolve_attachments = null,
            .p_depth_stencil_attachment = if (depth_ref) |*ref| ref else null,
            .preserve_attachment_count = 0,
            .p_preserve_attachments = null,
        };

        // Create render pass
        self.render_pass = try graphics_context.vkd.createRenderPass(graphics_context.dev, &vk.RenderPassCreateInfo{
            .flags = .{},
            .attachment_count = @intCast(vk_attachments.len),
            .p_attachments = vk_attachments.ptr,
            .subpass_count = 1,
            .p_subpasses = @ptrCast(&subpass),
            .dependency_count = 0,
            .p_dependencies = null,
        }, null);

        // Create framebuffer
        self.framebuffers = try allocator.alloc(vk.Framebuffer, 1);
        self.framebuffers[0] = try graphics_context.vkd.createFramebuffer(graphics_context.dev, &vk.FramebufferCreateInfo{
            .flags = .{},
            .render_pass = self.render_pass,
            .attachment_count = @intCast(image_views.len),
            .p_attachments = image_views.ptr,
            .width = extent.width,
            .height = extent.height,
            .layers = 1,
        }, null);

        // Set up default clear values
        self.clear_values = try allocator.alloc(vk.ClearValue, attachments.len);
        for (attachments, 0..) |att_info, i| {
            if (att_info.is_depth) {
                self.clear_values[i] = vk.ClearValue{
                    .depth_stencil = .{ .depth = 1.0, .stencil = 0 },
                };
            } else {
                self.clear_values[i] = vk.ClearValue{
                    .color = .{ .float_32 = [4]f32{ 0.0, 0.0, 0.0, 1.0 } },
                };
            }
        }

        return self;
    }

    /// Cleanup Vulkan resources
    pub fn deinit(self: *VulkanRenderPassResources) void {
        for (self.framebuffers) |fb| {
            if (fb != .null_handle) {
                self.graphics_context.vkd.destroyFramebuffer(self.graphics_context.dev, fb, null);
            }
        }
        if (self.render_pass != .null_handle) {
            self.graphics_context.vkd.destroyRenderPass(self.graphics_context.dev, self.render_pass, null);
        }

        self.allocator.free(self.framebuffers);
        self.allocator.free(self.attachments);
        self.allocator.free(self.clear_values);
    }

    /// Begin this render pass
    pub fn beginRenderPass(self: *const VulkanRenderPassResources, context: RenderContext, framebuffer_index: u32) void {
        const fb_index = @min(framebuffer_index, @as(u32, @intCast(self.framebuffers.len - 1)));
        context.beginVulkanRenderPass(self.render_pass, self.framebuffers[fb_index], self.clear_values);
    }

    /// End this render pass
    pub fn endRenderPass(self: *const VulkanRenderPassResources, context: RenderContext) void {
        _ = self;
        context.endVulkanRenderPass();
    }
};

/// Context passed to render passes during execution
pub const RenderContext = struct {
    graphics_context: *GraphicsContext,
    frame_info: *const FrameInfo,
    command_buffer: vk.CommandBuffer,
    frame_index: u32,
    scene_view: *SceneView,

    /// Get current render area
    pub fn getRenderArea(self: *const RenderContext) vk.Rect2D {
        return vk.Rect2D{
            .offset = vk.Offset2D{ .x = 0, .y = 0 },
            .extent = self.graphics_context.swapchain_extent,
        };
    }

    /// Get current viewport
    pub fn getViewport(self: *const RenderContext) vk.Viewport {
        const extent = self.graphics_context.swapchain_extent;
        return vk.Viewport{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(extent.width),
            .height = @floatFromInt(extent.height),
            .min_depth = 0.0,
            .max_depth = 1.0,
        };
    }

    /// Begin a Vulkan render pass with the given parameters
    pub fn beginVulkanRenderPass(self: *const RenderContext, render_pass: vk.RenderPass, framebuffer: vk.Framebuffer, clear_values: []const vk.ClearValue) void {
        const render_area = self.getRenderArea();
        const render_pass_info = vk.RenderPassBeginInfo{
            .render_pass = render_pass,
            .framebuffer = framebuffer,
            .render_area = render_area,
            .clear_value_count = @intCast(clear_values.len),
            .p_clear_values = clear_values.ptr,
        };

        self.graphics_context.vkd.cmdBeginRenderPass(self.command_buffer, &render_pass_info, .@"inline");

        // Set viewport
        const viewport = self.getViewport();
        self.graphics_context.vkd.cmdSetViewport(self.command_buffer, 0, 1, @ptrCast(&viewport));

        // Set scissor
        const scissor = render_area;
        self.graphics_context.vkd.cmdSetScissor(self.command_buffer, 0, 1, @ptrCast(&scissor));
    }

    /// End the current Vulkan render pass
    pub fn endVulkanRenderPass(self: *const RenderContext) void {
        self.graphics_context.vkd.cmdEndRenderPass(self.command_buffer);
    }
};

/// Scene view abstraction for pass-specific data extraction
pub const SceneView = struct {
    // Forward declarations - will be implemented in separate file
    const RasterizationData = @import("scene_view.zig").RasterizationData;
    const RaytracingData = @import("scene_view.zig").RaytracingData;
    const ComputeData = @import("scene_view.zig").ComputeData;

    scene_ptr: *anyopaque,
    vtable: *const SceneViewVTable,

    pub const SceneViewVTable = struct {
        getRasterizationData: *const fn (scene_ptr: *anyopaque) RasterizationData,
        getRaytracingData: *const fn (scene_ptr: *anyopaque) RaytracingData,
        getComputeData: *const fn (scene_ptr: *anyopaque) ComputeData,
    };

    /// Get rasterization-specific scene data (meshes, materials, textures)
    pub fn getRasterizationData(self: *SceneView) RasterizationData {
        return self.vtable.getRasterizationData(self.scene_ptr);
    }

    /// Get raytracing-specific scene data (geometries, instances, BLAS/TLAS)
    pub fn getRaytracingData(self: *SceneView) RaytracingData {
        return self.vtable.getRaytracingData(self.scene_ptr);
    }

    /// Get compute-specific scene data (particle systems, compute buffers)
    pub fn getComputeData(self: *SceneView) ComputeData {
        return self.vtable.getComputeData(self.scene_ptr);
    }
};

/// RenderPass trait using VTable pattern for dynamic dispatch
pub const RenderPass = struct {
    impl: *anyopaque,
    vtable: *const VTable,
    config: PassConfig,

    pub const VTable = struct {
        /// Initialize render pass resources
        init: *const fn (impl: *anyopaque, graphics_context: *GraphicsContext) anyerror!void,

        /// Execute the render pass
        execute: *const fn (impl: *anyopaque, context: RenderContext) anyerror!void,

        /// Cleanup render pass resources
        deinit: *const fn (impl: *anyopaque) void,

        /// Check if pass needs to be executed this frame
        shouldExecute: *const fn (impl: *anyopaque, context: RenderContext) bool,

        /// Get resource requirements for dependency tracking
        getResourceRequirements: *const fn (impl: *anyopaque) []const ResourceBinding,

        /// Optional: Get Vulkan render pass for rasterization passes (can be null for compute/raytracing)
        getVulkanRenderPass: ?*const fn (impl: *anyopaque) ?vk.RenderPass,

        /// Optional: Begin custom render pass setup (called before execute)
        beginPass: ?*const fn (impl: *anyopaque, context: RenderContext) anyerror!void,

        /// Optional: End custom render pass cleanup (called after execute)
        endPass: ?*const fn (impl: *anyopaque, context: RenderContext) anyerror!void,
    };

    /// Initialize the render pass
    pub fn init(self: *RenderPass, graphics_context: *GraphicsContext) !void {
        return self.vtable.init(self.impl, graphics_context);
    }

    /// Execute the render pass
    pub fn execute(self: *RenderPass, context: RenderContext) !void {
        return self.vtable.execute(self.impl, context);
    }

    /// Cleanup the render pass
    pub fn deinit(self: *RenderPass) void {
        self.vtable.deinit(self.impl);
    }

    /// Check if pass should execute this frame
    pub fn shouldExecute(self: *RenderPass, context: RenderContext) bool {
        if (!self.config.enabled) return false;
        return self.vtable.shouldExecute(self.impl, context);
    }

    /// Get resource requirements
    pub fn getResourceRequirements(self: *RenderPass) []const ResourceBinding {
        return self.vtable.getResourceRequirements(self.impl);
    }

    /// Get Vulkan render pass (for rasterization passes)
    pub fn getVulkanRenderPass(self: *RenderPass) ?vk.RenderPass {
        if (self.vtable.getVulkanRenderPass) |func| {
            return func(self.impl);
        }
        return null;
    }

    /// Begin pass setup (called before execute)
    pub fn beginPass(self: *RenderPass, context: RenderContext) !void {
        if (self.vtable.beginPass) |func| {
            return func(self.impl, context);
        }
    }

    /// End pass cleanup (called after execute)
    pub fn endPass(self: *RenderPass, context: RenderContext) !void {
        if (self.vtable.endPass) |func| {
            return func(self.impl, context);
        }
    }

    /// Create a new render pass with the given implementation
    pub fn create(comptime T: type, impl: *T, config: PassConfig) RenderPass {
        const vtable = comptime blk: {
            break :blk &VTable{
                .init = T.init,
                .execute = T.execute,
                .deinit = T.deinit,
                .shouldExecute = if (@hasDecl(T, "shouldExecute")) T.shouldExecute else defaultShouldExecute,
                .getResourceRequirements = if (@hasDecl(T, "getResourceRequirements")) T.getResourceRequirements else defaultGetResourceRequirements,
                .getVulkanRenderPass = if (@hasDecl(T, "getVulkanRenderPass")) T.getVulkanRenderPass else null,
                .beginPass = if (@hasDecl(T, "beginPass")) T.beginPass else null,
                .endPass = if (@hasDecl(T, "endPass")) T.endPass else null,
            };
        };

        return RenderPass{
            .impl = impl,
            .vtable = vtable,
            .config = config,
        };
    }

    /// Default implementation for shouldExecute
    fn defaultShouldExecute(impl: *anyopaque, context: RenderContext) bool {
        _ = impl;
        _ = context;
        return true; // Execute by default
    }

    /// Default implementation for getResourceRequirements
    fn defaultGetResourceRequirements(impl: *anyopaque) []const ResourceBinding {
        _ = impl;
        return &[_]ResourceBinding{}; // No requirements by default
    }
};

/// Helper to create type-safe render pass implementations
pub fn RenderPassImpl(comptime T: type) type {
    return struct {
        const Self = @This();

        pub fn init(impl: *anyopaque, graphics_context: *GraphicsContext) !void {
            const self: *T = @ptrCast(@alignCast(impl));
            if (@hasDecl(T, "init")) {
                return self.init(graphics_context);
            }
        }

        pub fn execute(impl: *anyopaque, context: RenderContext) !void {
            const self: *T = @ptrCast(@alignCast(impl));
            return self.execute(context);
        }

        pub fn deinit(impl: *anyopaque) void {
            const self: *T = @ptrCast(@alignCast(impl));
            if (@hasDecl(T, "deinit")) {
                self.deinit();
            }
        }

        pub fn shouldExecute(impl: *anyopaque, context: RenderContext) bool {
            const self: *T = @ptrCast(@alignCast(impl));
            if (@hasDecl(T, "shouldExecute")) {
                return self.shouldExecute(context);
            }
            return true;
        }

        pub fn getResourceRequirements(impl: *anyopaque) []const ResourceBinding {
            const self: *T = @ptrCast(@alignCast(impl));
            if (@hasDecl(T, "getResourceRequirements")) {
                return self.getResourceRequirements();
            }
            return &[_]ResourceBinding{};
        }
    };
}

/// Example render pass implementation
pub const ExamplePass = struct {
    name: []const u8,

    pub fn init(self: *ExamplePass, graphics_context: *GraphicsContext) !void {
        _ = self;
        _ = graphics_context;
        // Initialize resources
    }

    pub fn execute(self: *ExamplePass, context: RenderContext) !void {
        _ = self;
        _ = context;
        // Render logic
    }

    pub fn deinit(self: *ExamplePass) void {
        _ = self;
        // Cleanup resources
    }

    pub fn shouldExecute(self: *ExamplePass, context: RenderContext) bool {
        _ = self;
        _ = context;
        return true;
    }

    pub fn getResourceRequirements(self: *ExamplePass) []const ResourceBinding {
        _ = self;
        return &[_]ResourceBinding{};
    }
};
