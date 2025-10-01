const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("../core/graphics_context.zig").GraphicsContext;
const RenderGraph = @import("render_graph.zig").RenderGraph;
const PassHandle = @import("render_graph.zig").PassHandle;
const RenderPass = @import("render_pass.zig").RenderPass;
const RenderContext = @import("render_pass.zig").RenderContext;
const ForwardPass = @import("passes/forward_pass.zig").ForwardPass;
const SceneBridge = @import("scene_bridge.zig").SceneBridge;
const Scene = @import("../scene/scene.zig").Scene;
const TexturedRenderer = @import("../renderers/textured_renderer.zig").TexturedRenderer;
const PointLightRenderer = @import("../renderers/point_light_renderer.zig").PointLightRenderer;
const log = @import("../utils/log.zig").log;

/// Renderer registry entry
pub const RendererEntry = struct {
    name: []const u8,
    renderer_ptr: *anyopaque,
    pass_types: []const PassType,

    pub const PassType = enum {
        forward,
        deferred,
        shadow,
        postprocess,
        particles,
        ui,
    };
};

/// Render Pass Manager integrates the render pass system with the existing app
pub const RenderPassManager = struct {
    render_graph: RenderGraph,
    scene_bridge: SceneBridge,
    forward_pass: ForwardPass,
    forward_pass_handle: ?PassHandle = null,
    graphics_context: *GraphicsContext,
    allocator: std.mem.Allocator,
    initialized: bool = false,

    // Dynamic renderer registry
    registered_renderers: std.ArrayList(RendererEntry),

    const Self = @This();

    /// Initialize the render pass manager
    pub fn init(graphics_context: *GraphicsContext, scene: *Scene, allocator: std.mem.Allocator) !Self {
        const self = Self{
            .render_graph = RenderGraph.init(allocator),
            .scene_bridge = SceneBridge.init(scene, allocator),
            .forward_pass = try ForwardPass.create(allocator),
            .graphics_context = graphics_context,
            .allocator = allocator,
            .registered_renderers = std.ArrayList(RendererEntry){},
        };

        return self;
    }

    /// Register a renderer with the render pass manager
    pub fn registerRenderer(self: *Self, name: []const u8, renderer_ptr: anytype, pass_types: []const RendererEntry.PassType) !void {
        const entry = RendererEntry{
            .name = name,
            .renderer_ptr = @ptrCast(renderer_ptr),
            .pass_types = try self.allocator.dupe(RendererEntry.PassType, pass_types),
        };

        try self.registered_renderers.append(self.allocator, entry);
        log(.INFO, "render_pass_manager", "Registered renderer: {s} with {} pass types", .{ name, pass_types.len });

        // If we have both textured and point light renderers, update the forward pass
        self.updateForwardPassRenderers();
    }

    /// Get a registered renderer by name and type
    pub fn getRenderer(self: *Self, name: []const u8, comptime T: type) ?*T {
        for (self.registered_renderers.items) |entry| {
            if (std.mem.eql(u8, entry.name, name)) {
                return @ptrCast(@alignCast(entry.renderer_ptr));
            }
        }
        return null;
    }

    /// Update forward pass with registered renderers
    fn updateForwardPassRenderers(self: *Self) void {
        var textured_ptr: ?*TexturedRenderer = null;
        var point_light_ptr: ?*PointLightRenderer = null;

        // Find textured and point light renderers
        for (self.registered_renderers.items) |entry| {
            if (std.mem.eql(u8, entry.name, "textured")) {
                textured_ptr = @ptrCast(@alignCast(entry.renderer_ptr));
            } else if (std.mem.eql(u8, entry.name, "point_light")) {
                point_light_ptr = @ptrCast(@alignCast(entry.renderer_ptr));
            }
        }

        if (textured_ptr != null and point_light_ptr != null) {
            self.forward_pass.setRenderers(textured_ptr.?, point_light_ptr.?);
        }
    }

    /// Setup render passes and initialize the render graph
    pub fn setupRenderPasses(self: *Self) !void {
        if (self.initialized) return;

        // Initialize the forward pass
        try self.forward_pass.init(self.graphics_context);

        // Add forward pass to render graph
        const forward_render_pass = self.forward_pass.asRenderPass();
        self.forward_pass_handle = try self.render_graph.addPass(forward_render_pass);

        // Build execution order
        try self.render_graph.buildExecutionOrder();

        self.initialized = true;
        log(.INFO, "render_pass_manager", "Render pass system initialized with {} passes and {} registered renderers", .{ self.render_graph.passes.items.len, self.registered_renderers.items.len });
    }

    /// Set external renderer references for the forward pass (deprecated - use registerRenderer instead)
    pub fn setRenderers(self: *Self, textured_renderer: anytype, point_light_renderer: anytype) void {
        log(.WARN, "render_pass_manager", "setRenderers is deprecated, use registerRenderer instead", .{});
        self.forward_pass.setRenderers(textured_renderer, point_light_renderer);
    }

    /// Execute all render passes
    pub fn executeRenderPasses(self: *Self, context: RenderContext) !void {
        if (!self.initialized) {
            try self.setupRenderPasses();
        }

        // Invalidate scene cache if needed (should be called when scene changes)
        self.scene_bridge.invalidateCache();

        // Execute render graph
        try self.render_graph.execute(context);
    }

    /// Get scene view for render context
    pub fn getSceneView(self: *Self) @import("render_pass.zig").SceneView {
        return self.scene_bridge.createSceneView();
    }

    /// Add a new render pass to the graph
    pub fn addRenderPass(self: *Self, pass: RenderPass) !PassHandle {
        const handle = try self.render_graph.addPass(pass);
        try self.render_graph.buildExecutionOrder();
        return handle;
    }

    /// Add dependency between two passes
    pub fn addPassDependency(self: *Self, from: PassHandle, to: PassHandle) !void {
        try self.render_graph.addDependency(from, to);
        try self.render_graph.buildExecutionOrder();
    }

    /// Cleanup resources
    pub fn deinit(self: *Self) void {
        // Free pass types for each registered renderer
        for (self.registered_renderers.items) |entry| {
            self.allocator.free(entry.pass_types);
        }
        self.registered_renderers.deinit(self.allocator);

        self.forward_pass.deinit();
        self.scene_bridge.deinit();
        self.render_graph.deinit();
    }
};
