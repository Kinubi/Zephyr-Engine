const std = @import("std");
const vk = @import("vulkan");
const FrameInfo = @import("frameinfo.zig").FrameInfo;
const RenderContext = @import("render_pass.zig").RenderContext;

/// Renderer execution type classification
pub const RendererType = enum {
    raster,       // Traditional rasterization (TexturedRenderer, etc.)
    compute,      // Compute shaders (ParticleRenderer, etc.)
    raytracing,   // Ray tracing shaders
    lighting,     // Light rendering (PointLightRenderer, etc.)
    postprocess,  // Post-processing effects
};

/// Individual renderer entry
pub const RendererEntry = struct {
    name: []const u8,
    renderer_type: RendererType,
    renderer_ptr: *anyopaque,
    vtable: VTable,

    pub const VTable = struct {
        render: *const fn (renderer_ptr: *anyopaque, frame_info: FrameInfo, scene_data: *anyopaque) anyerror!void,
        shouldExecute: ?*const fn (renderer_ptr: *anyopaque, frame_info: FrameInfo) bool = null,
        deinit: ?*const fn (renderer_ptr: *anyopaque) void = null,
    };
};

/// Generic renderer that can execute multiple sub-renderers based on type
pub const GenericRenderer = struct {
    renderers: std.ArrayList(RendererEntry),
    allocator: std.mem.Allocator,
    scene_bridge_ptr: ?*anyopaque = null,  // Store scene bridge for renderers that need scene data
    swapchain_ptr: ?*anyopaque = null,     // Store swapchain for renderers that need it (like raytracing)
    
    // Execution order for renderer types
    execution_order: []const RendererType = &[_]RendererType{
        .raster,      // First render rasterized geometry
        .lighting,    // Then lighting passes
        .compute,     // Then compute effects  
        .raytracing,  // Then raytracing
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
        const entry = RendererEntry{
            .name = name,
            .renderer_type = renderer_type,
            .renderer_ptr = @ptrCast(renderer_ptr),
            .vtable = RendererEntry.VTable{
                .render = struct {
                    fn render(ptr: *anyopaque, frame_info: FrameInfo, scene_data_ptr: *anyopaque) !void {
                        const renderer: *RendererT = @ptrCast(@alignCast(ptr));
                        
                        // Handle different renderer signatures based on the renderer type
                        // This is determined by the renderer type stored in the entry
                        if (@hasDecl(RendererT, "render")) {
                            const render_fn = @field(RendererT, "render");
                            const render_info = @typeInfo(@TypeOf(render_fn));
                            
                            if (render_info == .@"fn") {
                                const params = render_info.@"fn".params;
                                
                                // Handle render(self, frame_info) - most renderers (PointLightRenderer, RaytracingRenderer, etc)
                                if (params.len == 2) {
                                    return renderer.render(frame_info);
                                }
                                
                                // Handle render(self, frame_info, raster_data) - TexturedRenderer
                                if (params.len == 3) {
                                    const RasterizationData = @import("scene_view.zig").RasterizationData;
                                    const raster_data: *RasterizationData = @ptrCast(@alignCast(scene_data_ptr));
                                    return renderer.render(frame_info, raster_data.*);
                                }
                            }
                        }
                        
                        return error.UnsupportedRenderSignature;
                    }
                }.render,
                .shouldExecute = if (@hasDecl(RendererT, "shouldExecute")) struct {
                    fn shouldExecute(ptr: *anyopaque, frame_info: FrameInfo) bool {
                        const renderer: *RendererT = @ptrCast(@alignCast(ptr));
                        return renderer.shouldExecute(frame_info);
                    }
                }.shouldExecute else null,
            },
        };
        
        try self.renderers.append(self.allocator, entry);
    }

    /// Execute all renderers in type order
    pub fn render(self: *GenericRenderer, frame_info: FrameInfo) !void {
        // Get scene bridge
        const SceneBridge = @import("scene_bridge.zig").SceneBridge;
        const scene_bridge: *SceneBridge = @ptrCast(@alignCast(self.scene_bridge_ptr orelse return error.NoSceneBridge));
        var scene_view = scene_bridge.createSceneView();
        
        for (self.execution_order) |renderer_type| {
            for (self.renderers.items) |*renderer| {
                if (renderer.renderer_type == renderer_type) {
                    // Check if renderer should execute
                    if (renderer.vtable.shouldExecute) |should_execute_fn| {
                        const should_execute = should_execute_fn(renderer.renderer_ptr, frame_info);
                        if (!should_execute) {
                            continue;
                        }
                    }
                    
                    // Get appropriate scene data based on renderer type
                    const scene_data_ptr: *anyopaque = switch (renderer_type) {
                        .raster => blk: {
                            var raster_data = scene_view.getRasterizationData();
                            break :blk @ptrCast(&raster_data);
                        },
                        .compute => blk: {
                            var compute_data = scene_view.getComputeData();
                            break :blk @ptrCast(&compute_data);
                        },
                        .raytracing => blk: {
                            // Raytracing renderers use standard render(frame_info) signature now
                            var dummy_data: u8 = 0;
                            break :blk @ptrCast(&dummy_data);
                        },
                        .lighting => blk: {
                            var raster_data = scene_view.getRasterizationData();  // Lighting uses raster data for lights
                            break :blk @ptrCast(&raster_data);
                        },
                        .postprocess => blk: {
                            var raster_data = scene_view.getRasterizationData();  // Post-process typically uses raster data
                            break :blk @ptrCast(&raster_data);
                        },
                    };
                    
                    // Execute the renderer
                    renderer.vtable.render(renderer.renderer_ptr, frame_info, scene_data_ptr) catch |err| {
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
            if (renderer.vtable.deinit) |deinit_fn| {
                deinit_fn(renderer.renderer_ptr);
            }
        }
        self.renderers.deinit(self.allocator);
    }
};