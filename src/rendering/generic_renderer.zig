const std = @import("std");
const FrameInfo = @import("frameinfo.zig").FrameInfo;
const SceneBridge = @import("scene_bridge.zig").SceneBridge;

/// Renderer execution type classification
pub const RendererType = enum {
    raster, // Traditional rasterization (TexturedRenderer, etc.)
    compute, // Compute shaders (ParticleRenderer, etc.)
    raytracing, // Ray tracing shaders
    lighting, // Light rendering (PointLightRenderer, etc.)
    postprocess, // Post-processing effects
};

/// Renderer entry storing callbacks for a specific renderer instance
pub const RendererEntry = struct {
    name: []const u8,
    renderer_type: RendererType,
    data_ptr: *anyopaque,
    callbacks: Callbacks,

    pub const Callbacks = struct {
        update: *const fn (data_ptr: *anyopaque, frame_info: *const FrameInfo, scene_bridge: *SceneBridge) anyerror!bool,
        render: *const fn (data_ptr: *anyopaque, frame_info: FrameInfo, scene_bridge: *SceneBridge) anyerror!void,
        on_create: ?*const fn (data_ptr: *anyopaque, scene_bridge: *SceneBridge) anyerror!void = null,
        should_execute: ?*const fn (data_ptr: *anyopaque, frame_info: FrameInfo) bool = null,
        deinit: ?*const fn (data_ptr: *anyopaque) void = null,
    };

    pub fn update(self: *RendererEntry, frame_info: *const FrameInfo, scene_bridge: *SceneBridge) !bool {
        return self.callbacks.update(self.data_ptr, frame_info, scene_bridge);
    }

    pub fn render(self: *RendererEntry, frame_info: FrameInfo, scene_bridge: *SceneBridge) !void {
        try self.callbacks.render(self.data_ptr, frame_info, scene_bridge);
    }

    pub fn onCreate(self: *RendererEntry, scene_bridge: *SceneBridge) !void {
        if (self.callbacks.on_create) |func| {
            try func(self.data_ptr, scene_bridge);
        }
    }

    pub fn shouldExecute(self: *RendererEntry, frame_info: FrameInfo) bool {
        if (self.callbacks.should_execute) |func| {
            return func(self.data_ptr, frame_info);
        }
        return true;
    }

    pub fn deinit(self: *RendererEntry) void {
        if (self.callbacks.deinit) |func| {
            func(self.data_ptr);
        }
    }
};

/// Generic renderer that can execute multiple sub-renderers based on type
pub const GenericRenderer = struct {
    renderers: std.ArrayList(RendererEntry),
    allocator: std.mem.Allocator,
    scene_bridge_ptr: ?*anyopaque = null, // Store scene bridge for renderers that need scene data
    swapchain_ptr: ?*anyopaque = null, // Store swapchain for renderers that need it (like raytracing)

    // Execution order for renderer types
    execution_order: []const RendererType = &[_]RendererType{
        .raster, // First render rasterized geometry
        .lighting, // Then lighting passes
        .compute, // Then compute effects
        .raytracing, // Then raytracing
        .postprocess, // Finally post-processing
    },

    /// Initialize a generic renderer
    pub fn init(allocator: std.mem.Allocator) GenericRenderer {
        return GenericRenderer{
            .renderers = std.ArrayList(RendererEntry){},
            .allocator = allocator,
        };
    }

    /// Set the scene bridge for renderers that need scene data
    pub fn setSceneBridge(self: *GenericRenderer, scene_bridge: anytype) void {
        self.scene_bridge_ptr = @ptrCast(scene_bridge);

        const bridge_ptr: *SceneBridge = @ptrCast(@alignCast(self.scene_bridge_ptr.?));
        for (self.renderers.items) |*renderer| {
            renderer.onCreate(bridge_ptr) catch |err| {
                std.log.err("GenericRenderer: Failed to run onCreate for '{s}': {}", .{ renderer.name, err });
            };
        }
    }

    /// Set the swapchain for renderers that need it (like raytracing)
    pub fn setSwapchain(self: *GenericRenderer, swapchain: anytype) void {
        self.swapchain_ptr = @ptrCast(swapchain);
    }

    /// Add a renderer to the generic renderer
    pub fn addRenderer(
        self: *GenericRenderer,
        name: []const u8,
        renderer_type: RendererType,
        renderer_ptr: anytype,
        comptime RendererT: type,
    ) !void {
        comptime {
            if (!@hasDecl(RendererT, "update")) @compileError("Renderer must implement update(frame_info, scene_bridge)");
            if (!@hasDecl(RendererT, "render")) @compileError("Renderer must implement render(frame_info, scene_bridge)");
        }

        const entry = RendererEntry{
            .name = name,
            .renderer_type = renderer_type,
            .data_ptr = @ptrCast(renderer_ptr),
            .callbacks = RendererEntry.Callbacks{
                .update = struct {
                    fn call(ptr: *anyopaque, frame_info: *const FrameInfo, scene_bridge: *SceneBridge) !bool {
                        const renderer: *RendererT = @ptrCast(@alignCast(ptr));
                        return renderer.update(frame_info, scene_bridge);
                    }
                }.call,
                .render = struct {
                    fn call(ptr: *anyopaque, frame_info: FrameInfo, scene_bridge: *SceneBridge) !void {
                        const renderer: *RendererT = @ptrCast(@alignCast(ptr));
                        return renderer.render(frame_info, scene_bridge);
                    }
                }.call,
                .on_create = if (@hasDecl(RendererT, "onCreate")) struct {
                    fn call(ptr: *anyopaque, scene_bridge: *SceneBridge) !void {
                        const renderer: *RendererT = @ptrCast(@alignCast(ptr));
                        return renderer.onCreate(scene_bridge);
                    }
                }.call else null,
                .should_execute = if (@hasDecl(RendererT, "shouldExecute")) struct {
                    fn call(ptr: *anyopaque, frame_info: FrameInfo) bool {
                        const renderer: *RendererT = @ptrCast(@alignCast(ptr));
                        return renderer.shouldExecute(frame_info);
                    }
                }.call else null,
                .deinit = if (@hasDecl(RendererT, "deinit")) struct {
                    fn call(ptr: *anyopaque) void {
                        const renderer: *RendererT = @ptrCast(@alignCast(ptr));
                        renderer.deinit();
                    }
                }.call else null,
            },
        };

        try self.renderers.append(self.allocator, entry);

        if (self.scene_bridge_ptr) |ptr| {
            const scene_bridge: *SceneBridge = @ptrCast(@alignCast(ptr));
            try self.renderers.items[self.renderers.items.len - 1].onCreate(scene_bridge);
        }
    }

    /// Update descriptor sets for all renderers that need material/texture updates
    /// Checks SceneBridge to determine if updates are needed for this frame
    pub fn update(self: *GenericRenderer, frame_info: *const FrameInfo) !void {
        const scene_bridge: *SceneBridge = @ptrCast(@alignCast(self.scene_bridge_ptr orelse return error.NoSceneBridge));

        for (self.renderers.items) |*renderer| {
            _ = try renderer.update(frame_info, scene_bridge);
        }
    }

    /// Execute all renderers in type order
    pub fn render(self: *GenericRenderer, frame_info: FrameInfo) !void {
        // Get scene bridge
        const scene_bridge: *SceneBridge = @ptrCast(@alignCast(self.scene_bridge_ptr orelse return error.NoSceneBridge));

        for (self.execution_order) |renderer_type| {
            for (self.renderers.items) |*renderer| {
                if (renderer.renderer_type == renderer_type) {
                    // Check if renderer should execute
                    if (!renderer.shouldExecute(frame_info)) {
                        continue;
                    }

                    renderer.render(frame_info, scene_bridge) catch |err| {
                        std.log.err("GenericRenderer: Failed to render with '{s}': {}", .{ renderer.name, err });
                        return err;
                    };
                }
            }
        }
    }

    /// Clean up all renderers
    pub fn deinit(self: *GenericRenderer) void {
        for (self.renderers.items) |*renderer| {
            renderer.deinit();
        }
        self.renderers.deinit(self.allocator);
    }
};
