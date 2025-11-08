const std = @import("std");
const zephyr = @import("../../zephyr.zig");

const RenderPass = @import("render_pass.zig").RenderPass;
const UnifiedPipelineSystem = @import("../unified_pipeline_system.zig").UnifiedPipelineSystem;
const ResourceBinder = @import("../resource_binder.zig").ResourceBinder;
const RenderSystem = @import("../../ecs/systems/render_system.zig").RenderSystem;
const FrameInfo = @import("../frameinfo.zig").FrameInfo;
const GraphicsContext = @import("../../core/graphics_context.zig").GraphicsContext;
const log = @import("../../utils/log.zig").log;

/// Zero-boilerplate render pass using builder pattern
/// 
/// Example usage:
/// ```zig
/// const pass = try BaseRenderPass.create(allocator, "my_pass", config);
/// defer pass.destroy();
/// 
/// // Register shaders
/// try pass.registerShader("my.vert");
/// try pass.registerShader("my.frag");
/// 
/// // Bind resources (uses named binding)
/// try pass.bind("GlobalUBO", &global_ubo);
/// try pass.bind("MaterialBuffer", material_system);
/// 
/// // Register render data extractor
/// try pass.setRenderDataFn(myRenderDataExtractor);
/// 
/// // Bake pipeline and bind resources
/// try pass.bake();
/// 
/// // Done! RenderGraph calls execute() automatically
/// // updateFrame() handles automatic rebinding
/// ```
pub const BaseRenderPass = struct {
    base: RenderPass,
    allocator: std.mem.Allocator,
    name: []const u8,
    
    // Core rendering systems
    graphics_context: *GraphicsContext,
    pipeline_system: *UnifiedPipelineSystem,
    resource_binder: *ResourceBinder,
    render_system: *RenderSystem,
    
    // Configuration queues (filled during setup, consumed in bake())
    shader_paths: std.ArrayList([]const u8),
    resource_bindings: std.ArrayList(ResourceBinding),
    pipeline_config: PipelineConfig,
    
    // Runtime state (created in bake())
    pipeline: ?UnifiedPipelineSystem.PipelineHandle = null,
    is_baked: bool = false,
    
    // Render data extraction callback
    render_data_fn: ?*const RenderDataFn = null,
    render_data_context: ?*anyopaque = null,
    
    /// Function pointer type for extracting render data from RenderSystem
    /// This allows each pass to get exactly what it needs
    /// 
    /// Example:
    /// ```zig
    /// fn getOpaqueGeometry(render_system: *RenderSystem, ctx: ?*anyopaque) RenderData {
    ///     const batches = render_system.getOpaqueBatches();
    ///     return .{ .batches = batches };
    /// }
    /// ```
    pub const RenderDataFn = fn (render_system: *RenderSystem, context: ?*anyopaque) RenderData;
    
    /// Render data returned by extraction function
    pub const RenderData = struct {
        // Different passes need different data
        batches: ?[]const anyopaque = null, // Instanced batches
        objects: ?[]const anyopaque = null, // Individual objects
        particles: ?[]const anyopaque = null, // Particle systems
        lights: ?[]const anyopaque = null, // Light data
        custom: ?*anyopaque = null, // Pass-specific data
    };
    
    const ResourceBinding = struct {
        name: []const u8,
        resource: Resource,
    };
    
    const Resource = union(enum) {
        buffer: *const anyopaque, // Points to ManagedBuffer
        texture: *const anyopaque, // Points to Texture
        texture_array: []const anyopaque, // Points to descriptor array
        system: *const anyopaque, // Points to a system that provides resources
    };
    
    pub const PipelineConfig = struct {
        // Render target config
        color_formats: []const @import("vulkan").Format,
        depth_format: ?@import("vulkan").Format = null,
        
        // Pipeline state
        cull_mode: @import("vulkan").CullModeFlags = .{ .back_bit = true },
        depth_test: bool = true,
        depth_write: bool = true,
        blend_enable: bool = false,
        
        // Viewport/scissor (dynamic by default)
        dynamic_viewport: bool = true,
        dynamic_scissor: bool = true,
    };
    
    /// Create a new BaseRenderPass
    pub fn create(
        allocator: std.mem.Allocator,
        name: []const u8,
        graphics_context: *GraphicsContext,
        pipeline_system: *UnifiedPipelineSystem,
        resource_binder: *ResourceBinder,
        render_system: *RenderSystem,
        config: PipelineConfig,
    ) !*BaseRenderPass {
        const self = try allocator.create(BaseRenderPass);
        errdefer allocator.destroy(self);
        
        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);
        
        self.* = .{
            .base = .{
                .name = name_copy,
                .enabled = true,
                .vtable = &vtable,
            },
            .allocator = allocator,
            .name = name_copy,
            .graphics_context = graphics_context,
            .pipeline_system = pipeline_system,
            .resource_binder = resource_binder,
            .render_system = render_system,
            .shader_paths = std.ArrayList([]const u8).init(allocator),
            .resource_bindings = std.ArrayList(ResourceBinding).init(allocator),
            .pipeline_config = config,
        };
        
        return self;
    }
    
    /// Register a shader to be used in this pass
    /// Shaders are queued and compiled during bake()
    pub fn registerShader(self: *BaseRenderPass, path: []const u8) !void {
        if (self.is_baked) return error.AlreadyBaked;
        const path_copy = try self.allocator.dupe(u8, path);
        try self.shader_paths.append(path_copy);
    }
    
    /// Bind a resource by name (uses ResourceBinder's named binding)
    /// Resources are queued and bound during bake()
    pub fn bind(self: *BaseRenderPass, name: []const u8, resource: anytype) !void {
        if (self.is_baked) return error.AlreadyBaked;
        
        const name_copy = try self.allocator.dupe(u8, name);
        const resource_type = @TypeOf(resource);
        
        // Determine resource type and store appropriately
        const res = if (@typeInfo(resource_type) == .Pointer) blk: {
            const child = @typeInfo(resource_type).Pointer.child;
            if (@hasDecl(child, "buffer") or @hasField(child, "buffer")) {
                // Looks like a buffer or system with buffer
                break :blk Resource{ .buffer = @ptrCast(resource) };
            } else if (@hasDecl(child, "texture") or @hasField(child, "texture")) {
                // Looks like a texture or system with texture
                break :blk Resource{ .texture = @ptrCast(resource) };
            } else {
                // Generic system that provides resources
                break :blk Resource{ .system = @ptrCast(resource) };
            }
        } else if (@typeInfo(resource_type) == .Slice) blk: {
            // Texture array or descriptor array
            break :blk Resource{ .texture_array = @ptrCast(resource) };
        } else {
            return error.UnsupportedResourceType;
        };
        
        try self.resource_bindings.append(.{
            .name = name_copy,
            .resource = res,
        });
    }
    
    /// Set the render data extraction function
    /// This function will be called each frame to get data from RenderSystem
    pub fn setRenderDataFn(
        self: *BaseRenderPass,
        func: *const RenderDataFn,
        context: ?*anyopaque,
    ) !void {
        if (self.is_baked) return error.AlreadyBaked;
        self.render_data_fn = func;
        self.render_data_context = context;
    }
    
    /// Bake the pass: create pipeline, populate shader reflection, bind resources
    /// Call this after registering all shaders and resources
    pub fn bake(self: *BaseRenderPass) !void {
        if (self.is_baked) return error.AlreadyBaked;
        
        log(.INFO, "base_render_pass", "Baking pass: {s}", .{self.name});
        
        // 1. Create pipeline with registered shaders
        const pipeline_create_info = UnifiedPipelineSystem.PipelineCreateInfo{
            .name = self.name,
            .shader_paths = self.shader_paths.items,
            .color_formats = self.pipeline_config.color_formats,
            .depth_format = self.pipeline_config.depth_format,
            .cull_mode = self.pipeline_config.cull_mode,
            .depth_test_enable = self.pipeline_config.depth_test,
            .depth_write_enable = self.pipeline_config.depth_write,
            .blend_enable = self.pipeline_config.blend_enable,
            .dynamic_state = .{
                .viewport = self.pipeline_config.dynamic_viewport,
                .scissor = self.pipeline_config.dynamic_scissor,
            },
        };
        
        self.pipeline = try self.pipeline_system.createPipeline(pipeline_create_info);
        
        // 2. Populate binding registry from shader reflection
        const reflection = try self.pipeline_system.getPipelineReflection(self.pipeline.?);
        try self.resource_binder.populateFromReflection(reflection);
        
        // 3. Bind all registered resources using named binding
        // This happens once during bake - ResourceBinder will auto-rebind if handles change
        for (self.resource_bindings.items) |binding| {
            try self.bindResource(binding.name, binding.resource);
        }
        
        self.is_baked = true;
        log(.INFO, "base_render_pass", "Pass baked successfully: {s}", .{self.name});
    }
    
    /// Internal: Bind a single resource using ResourceBinder
    fn bindResource(self: *BaseRenderPass, name: []const u8, resource: Resource) !void {
        switch (resource) {
            .buffer => |buf_ptr| {
                // Assume it's a ManagedBuffer - ResourceBinder handles the details
                try self.resource_binder.bindStorageBufferNamed(
                    name,
                    @ptrCast(@alignCast(buf_ptr)),
                    self.pipeline.?,
                    0, // frame_index not needed for initial binding
                );
            },
            .texture => |tex_ptr| {
                try self.resource_binder.bindTextureNamed(
                    name,
                    @ptrCast(@alignCast(tex_ptr)),
                    self.pipeline.?,
                    0,
                );
            },
            .texture_array => |array| {
                try self.resource_binder.bindTextureArrayNamed(
                    name,
                    @ptrCast(@alignCast(array.ptr)),
                    array.len,
                    self.pipeline.?,
                    0,
                );
            },
            .system => |sys_ptr| {
                // System provides resources - query it
                // This requires systems to have a standard interface
                // For now, just log - we'll need to enhance this
                _ = sys_ptr;
                log(.WARN, "base_render_pass", "System binding not yet implemented for: {s}", .{name});
            },
        }
    }
    
    pub fn destroy(self: *BaseRenderPass) void {
        // Free shader paths
        for (self.shader_paths.items) |path| {
            self.allocator.free(path);
        }
        self.shader_paths.deinit();
        
        // Free resource binding names
        for (self.resource_bindings.items) |binding| {
            self.allocator.free(binding.name);
        }
        self.resource_bindings.deinit();
        
        self.allocator.free(self.name);
        self.allocator.destroy(self);
    }
    
    // RenderPass vtable implementation
    const vtable = RenderPass.VTable{
        .setup = setupImpl,
        .update = updateImpl,
        .execute = executeImpl,
        .teardown = teardownImpl,
    };
    
    fn setupImpl(base: *RenderPass) !void {
        const self: *BaseRenderPass = @fieldParentPtr("base", base);
        
        if (!self.is_baked) {
            log(.ERR, "base_render_pass", "Pass not baked before setup: {s}", .{self.name});
            return error.NotBaked;
        }
        
        log(.DEBUG, "base_render_pass", "Setup: {s}", .{self.name});
    }
    
    fn updateImpl(base: *RenderPass, delta_time: f32) !void {
        const self: *BaseRenderPass = @fieldParentPtr("base", base);
        _ = delta_time;
        
        // Update ResourceBinder - this automatically rebinds changed resources
        try self.resource_binder.updateFrame();
        
        log(.TRACE, "base_render_pass", "Update: {s}", .{self.name});
    }
    
    fn executeImpl(base: *RenderPass, frame_info: FrameInfo) !void {
        const self: *BaseRenderPass = @fieldParentPtr("base", base);
        
        if (self.pipeline == null) return error.PipelineNotCreated;
        
        // Extract render data using registered callback
        const render_data = if (self.render_data_fn) |func|
            func(self.render_system, self.render_data_context)
        else
            RenderData{}; // Empty data if no extractor
        
        // Bind pipeline with descriptor sets
        try self.pipeline_system.bindPipelineWithDescriptorSets(
            frame_info.command_buffer,
            self.pipeline.?,
            self.resource_binder,
            frame_info.current_frame,
        );
        
        // TODO: Actual rendering based on render_data
        // For now, just log
        log(.TRACE, "base_render_pass", "Execute: {s} (render data present: {})", .{
            self.name,
            render_data.batches != null or render_data.objects != null,
        });
        
        // Subclasses can override executeImpl to do actual drawing
        // Or we can add a draw callback system
    }
    
    fn teardownImpl(base: *RenderPass) void {
        const self: *BaseRenderPass = @fieldParentPtr("base", base);
        log(.DEBUG, "base_render_pass", "Teardown: {s}", .{self.name});
        // Pipeline cleanup handled by UnifiedPipelineSystem
    }
};
