const std = @import("std");
const zephyr = @import("../../zephyr.zig");
const vk = @import("vulkan");
const RenderPass = @import("../render_graph.zig").RenderPass;
const RenderPassVTable = @import("../render_graph.zig").RenderPassVTable;
const RenderGraph = @import("../render_graph.zig").RenderGraph;
const UnifiedPipelineSystem = @import("../unified_pipeline_system.zig").UnifiedPipelineSystem;
const PipelineId = @import("../unified_pipeline_system.zig").PipelineId;
const UnifiedPipelineConfig = @import("../unified_pipeline_system.zig").PipelineConfig;
const ResourceBinder = @import("../resource_binder.zig").ResourceBinder;
const RenderSystem = @import("../../ecs/systems/render_system.zig").RenderSystem;
const FrameInfo = @import("../frameinfo.zig").FrameInfo;
const GraphicsContext = @import("../../core/graphics_context.zig").GraphicsContext;
const render_data_types = @import("../render_data_types.zig");
const DynamicRenderingHelper = @import("../../utils/dynamic_rendering.zig").DynamicRenderingHelper;
const ManagedBuffer = @import("../buffer_manager.zig").ManagedBuffer;
const ManagedTexture = @import("../texture_manager.zig").ManagedTexture;
const ManagedTextureArray = @import("../../ecs/systems/material_system.zig").ManagedTextureArray;
const pipeline_builder = @import("../pipeline_builder.zig");
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
    resource_binder: ResourceBinder,
    render_system: *RenderSystem,

    // Configuration queues (filled during setup, consumed in bake())
    shader_paths: std.ArrayList([]const u8),
    resource_bindings: std.ArrayList(ResourceBinding),
    pipeline_config: PipelineConfig,
    allocated_buffer_arrays: std.ArrayList([]*ManagedBuffer), // Track allocated arrays for cleanup
    push_constant_range_storage: ?[]vk.PushConstantRange = null, // Stable storage for push constant range slice

    // Runtime state (created in bake())
    pipeline: ?PipelineId = null,
    cached_pipeline_handle: vk.Pipeline = .null_handle,
    is_baked: bool = false,

    // Render data extraction callback
    render_data_fn: ?*const RenderDataFn = null,
    render_data_context: ?*anyopaque = null,

    // Push constant generation callback
    push_constant_fn: PushConstantFn = null,

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

    /// Function pointer type for generating push constants per object
    /// Called once per rendered object before drawing
    ///
    /// Example:
    /// ```zig
    /// fn generatePushConstants(object: *const anyopaque, out_buffer: []u8) void {
    ///     const obj: *const RenderableObject = @ptrCast(@alignCast(object));
    ///     const push: *MyPushConstants = @ptrCast(@alignCast(out_buffer.ptr));
    ///     push.* = .{
    ///         .transform = obj.transform,
    ///         .material_index = obj.material_index,
    ///     };
    /// }
    /// ```
    pub const PushConstantFn = ?*const fn (object: *const anyopaque, out_buffer: []u8) void;

    /// Render data returned by extraction function
    pub const RenderData = struct {
        // Different passes need different data
        // Store as opaque pointers since we can't create slices of anyopaque
        batches: ?*const anyopaque = null, // Instanced batches
        batches_len: usize = 0,
        objects: ?*const anyopaque = null, // Individual objects
        objects_len: usize = 0,
        particles: ?*const anyopaque = null, // Particle systems
        particles_len: usize = 0,
        lights: ?*const anyopaque = null, // Light data
        lights_len: usize = 0,
        custom: ?*anyopaque = null, // Pass-specific data
    };

    const ResourceBinding = struct {
        name: []const u8,
        resource: Resource,
    };

    const Resource = union(enum) {
        buffer: *const anyopaque, // Points to ManagedBuffer
        buffer_array: *const anyopaque, // Points to array of ManagedBuffer (for frame-in-flight)
        texture: *const anyopaque, // Points to ManagedTexture
        texture_array: *const anyopaque, // Points to ManagedTextureArray
        system: *const anyopaque, // Points to a system that provides resources
    };

    pub const PipelineConfig = struct {
        // Render target config
        color_formats: []const vk.Format,
        depth_format: ?vk.Format = null,

        // Pipeline state
        cull_mode: vk.CullModeFlags = .{ .back_bit = true },
        depth_test: bool = true,
        depth_write: bool = true,
        blend_enable: bool = false,

        // Viewport/scissor (dynamic by default)
        dynamic_viewport: bool = true,
        dynamic_scissor: bool = true,

        // Vertex input (required for vertex shaders)
        vertex_input_bindings: []const pipeline_builder.VertexInputBinding = &[_]pipeline_builder.VertexInputBinding{},
        vertex_input_attributes: []const pipeline_builder.VertexInputAttribute = &[_]pipeline_builder.VertexInputAttribute{},

        // Push constants
        push_constant_size: u32 = 0,
        push_constant_stages: vk.ShaderStageFlags = .{ .vertex_bit = true, .fragment_bit = true },
    };

    /// Create a new BaseRenderPass
    pub fn create(
        allocator: std.mem.Allocator,
        name: []const u8,
        graphics_context: *GraphicsContext,
        pipeline_system: *UnifiedPipelineSystem,
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
                .dependencies = .{},
            },
            .allocator = allocator,
            .name = name_copy,
            .graphics_context = graphics_context,
            .pipeline_system = pipeline_system,
            .resource_binder = ResourceBinder.init(allocator, pipeline_system),
            .render_system = render_system,
            .shader_paths = .{},
            .resource_bindings = .{},
            .pipeline_config = config,
            .allocated_buffer_arrays = .{},
        };

        return self;
    }

    /// Register a shader to be used in this pass
    /// Shaders are queued and compiled during bake()
    pub fn registerShader(self: *BaseRenderPass, path: []const u8) !void {
        if (self.is_baked) return error.AlreadyBaked;
        const path_copy = try self.allocator.dupe(u8, path);
        try self.shader_paths.append(self.allocator, path_copy);
    }

    /// Bind a resource by name (uses ResourceBinder's named binding)
    /// Resources are queued and bound during bake()
    pub fn bind(self: *BaseRenderPass, name: []const u8, resource: anytype) !void {
        if (self.is_baked) return error.AlreadyBaked;

        const name_copy = try self.allocator.dupe(u8, name);

        // Detect the resource type at comptime
        const T = @TypeOf(resource);
        const type_info = @typeInfo(T);

        const res: Resource = switch (type_info) {
            .pointer => |ptr_info| blk: {
                // Direct pointer types
                if (ptr_info.child == ManagedBuffer) {
                    break :blk .{ .buffer = @ptrCast(resource) };
                } else if (ptr_info.child == ManagedTexture) {
                    break :blk .{ .texture = @ptrCast(resource) };
                } else if (ptr_info.child == ManagedTextureArray) {
                    break :blk .{ .texture_array = @ptrCast(resource) };
                }
                break :blk .{ .system = @ptrCast(&resource) };
            },
            .array => |arr_info| blk: {
                // Array of pointers to ManagedBuffer (frame-in-flight buffers)
                if (arr_info.child == *ManagedBuffer or arr_info.child == *const ManagedBuffer) {
                    // Allocate and copy the array to stable storage
                    const array_copy = try self.allocator.alloc(*ManagedBuffer, arr_info.len);
                    for (resource, 0..) |buf, i| {
                        array_copy[i] = buf;
                    }
                    // Track for cleanup
                    try self.allocated_buffer_arrays.append(self.allocator, array_copy);
                    break :blk .{ .buffer_array = @ptrCast(array_copy.ptr) };
                }
                break :blk .{ .system = @ptrCast(&resource) };
            },
            else => .{ .system = @ptrCast(&resource) },
        };

        try self.resource_bindings.append(self.allocator, .{
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

    /// Set the push constant generation function
    /// This function is called for each object before drawing
    pub fn setPushConstantFn(
        self: *BaseRenderPass,
        func: PushConstantFn,
    ) !void {
        if (self.is_baked) return error.AlreadyBaked;
        self.push_constant_fn = func;
    }

    /// Bake the pass: create pipeline, populate shader reflection, bind resources
    /// Call this after registering all shaders and resources
    pub fn bake(self: *BaseRenderPass) !void {
        if (self.is_baked) return error.AlreadyBaked;

        log(.INFO, "base_render_pass", "Baking pass: {s}", .{self.name});

        // 1. Create pipeline with registered shaders
        // Note: Currently only supports vertex + fragment shader
        // TODO: Support compute, raytracing, etc.

        // Setup push constants if specified
        if (self.pipeline_config.push_constant_size > 0) {
            // Allocate stable storage for the push constant range
            const range_slice = try self.allocator.alloc(vk.PushConstantRange, 1);
            range_slice[0] = .{
                .stage_flags = self.pipeline_config.push_constant_stages,
                .offset = 0,
                .size = self.pipeline_config.push_constant_size,
            };
            self.push_constant_range_storage = range_slice;
        }
        const push_constant_ranges: ?[]const vk.PushConstantRange = self.push_constant_range_storage;

        const pipeline_create_info = UnifiedPipelineConfig{
            .name = self.name,
            .vertex_shader = if (self.shader_paths.items.len > 0) self.shader_paths.items[0] else null,
            .fragment_shader = if (self.shader_paths.items.len > 1) self.shader_paths.items[1] else null,
            .render_pass = .null_handle, // Use dynamic rendering
            .vertex_input_bindings = self.pipeline_config.vertex_input_bindings,
            .vertex_input_attributes = self.pipeline_config.vertex_input_attributes,
            .push_constant_ranges = push_constant_ranges,
            .dynamic_rendering_color_formats = self.pipeline_config.color_formats,
            .dynamic_rendering_depth_format = self.pipeline_config.depth_format,
            .cull_mode = self.pipeline_config.cull_mode,
            .depth_stencil_state = if (self.pipeline_config.depth_test) .{
                .depth_test_enable = true,
                .depth_write_enable = self.pipeline_config.depth_write,
                .depth_compare_op = .less,
                .depth_bounds_test_enable = false,
                .stencil_test_enable = false,
                .front = std.mem.zeroes(vk.StencilOpState),
                .back = std.mem.zeroes(vk.StencilOpState),
                .min_depth_bounds = 0.0,
                .max_depth_bounds = 1.0,
            } else null,
        };

        const result = try self.pipeline_system.createPipeline(pipeline_create_info);
        self.pipeline = result.id;

        if (!result.success) {
            log(.WARN, "base_render_pass", "Pipeline creation failed: {s}", .{self.name});
            return error.PipelineCreationFailed;
        }

        // Cache the pipeline handle for hot-reload detection
        const pipeline_entry = self.pipeline_system.pipelines.get(self.pipeline.?) orelse return error.PipelineNotFound;
        self.cached_pipeline_handle = pipeline_entry.vulkan_pipeline;

        // 2. Populate binding registry from shader reflection
        const reflection = try self.pipeline_system.getPipelineReflection(self.pipeline.?);
        if (reflection) |refl| {
            try self.resource_binder.populateFromReflection(refl);
        }

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
                // Single ManagedBuffer - use storage buffer binding
                try self.resource_binder.bindStorageBufferNamed(
                    self.pipeline.?,
                    name,
                    @ptrCast(@alignCast(buf_ptr)),
                );
            },
            .buffer_array => |array_ptr| {
                // Array of ManagedBuffer (frame-in-flight) - use uniform buffer binding
                // The array_ptr points to [MAX_FRAMES_IN_FLIGHT]*ManagedBuffer
                // Cast to the array type and pass it by value
                const buffers_ptr: *const [3]*ManagedBuffer = @ptrCast(@alignCast(array_ptr));
                // Convert to [3]*const ManagedBuffer for the function signature
                const const_buffers: [3]*const ManagedBuffer = buffers_ptr.*;
                try self.resource_binder.bindUniformBufferNamed(
                    self.pipeline.?,
                    name,
                    const_buffers,
                );
            },
            .texture => |tex_ptr| {
                // ManagedTexture - cast and bind (tracked automatically)
                try self.resource_binder.bindManagedTextureNamed(
                    self.pipeline.?,
                    name,
                    @ptrCast(@alignCast(tex_ptr)),
                );
            },
            .texture_array => |array_ptr| {
                // ManagedTextureArray - cast and bind (tracked automatically)
                try self.resource_binder.bindTextureArrayNamed(
                    self.pipeline.?,
                    name,
                    @ptrCast(@alignCast(array_ptr)),
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
        // Deinit resource binder
        self.resource_binder.deinit();

        // Free shader paths
        for (self.shader_paths.items) |path| {
            self.allocator.free(path);
        }
        self.shader_paths.deinit(self.allocator);

        // Free resource binding names
        for (self.resource_bindings.items) |binding| {
            self.allocator.free(binding.name);
        }
        self.resource_bindings.deinit(self.allocator);

        self.allocator.free(self.name);
        self.allocator.destroy(self);
    }

    // RenderPass vtable implementation
    const vtable = RenderPassVTable{
        .setup = setupImpl,
        .update = updateImpl,
        .execute = executeImpl,
        .teardown = teardownImpl,
        .checkValidity = checkValidityImpl,
    };

    fn setupImpl(base: *RenderPass, graph: *RenderGraph) !void {
        const self: *BaseRenderPass = @fieldParentPtr("base", base);
        _ = graph; // We don't use render graph in BaseRenderPass

        if (!self.is_baked) {
            log(.ERROR, "base_render_pass", "Pass not baked before setup: {s}", .{self.name});
            return error.NotBaked;
        }

        log(.DEBUG, "base_render_pass", "Setup: {s}", .{self.name});
    }

    fn updateImpl(base: *RenderPass, frame_info: *const FrameInfo) !void {
        const self: *BaseRenderPass = @fieldParentPtr("base", base);

        if (self.pipeline == null) return;

        // Check for pipeline hot-reload
        const pipeline_entry = self.pipeline_system.pipelines.get(self.pipeline.?) orelse return;
        const pipeline_rebuilt = pipeline_entry.vulkan_pipeline != self.cached_pipeline_handle;

        if (pipeline_rebuilt) {
            log(.INFO, "base_render_pass", "Pipeline hot-reloaded, rebinding resources: {s}", .{self.name});
            self.cached_pipeline_handle = pipeline_entry.vulkan_pipeline;
            self.resource_binder.clearPipeline(self.pipeline.?);

            // Rebind all resources after hot reload
            for (self.resource_bindings.items) |binding| {
                try self.bindResource(binding.name, binding.resource);
            }
        }

        // Update ResourceBinder - this automatically rebinds changed resources
        try self.resource_binder.updateFrame(self.pipeline.?, frame_info.current_frame);
    }

    fn executeImpl(base: *RenderPass, frame_info: FrameInfo) !void {
        const self: *BaseRenderPass = @fieldParentPtr("base", base);

        if (self.pipeline == null) return error.PipelineNotCreated;

        // Extract render data using registered callback
        const render_data = if (self.render_data_fn) |func|
            func(self.render_system, self.render_data_context)
        else
            RenderData{}; // Empty data if no extractor

        // Setup dynamic rendering with helper
        const rendering = DynamicRenderingHelper.init(
            frame_info.hdr_texture.?.image_view,
            frame_info.depth_image_view,
            frame_info.extent,
            .{ 0.01, 0.01, 0.01, 1.0 }, // clear color (dark gray)
            1.0, // clear depth
        );

        // Begin rendering (also sets viewport and scissor)
        rendering.begin(self.graphics_context, frame_info.command_buffer);

        // Bind pipeline with descriptor sets
        try self.pipeline_system.bindPipelineWithDescriptorSets(
            frame_info.command_buffer,
            self.pipeline.?,
            frame_info.current_frame,
        );

        // Render objects if present
        if (render_data.objects) |objects_ptr| {
            // Cast single-item pointer to many-item pointer for slicing
            const objects_many: [*]const render_data_types.RasterizationData.RenderableObject = @ptrCast(@alignCast(objects_ptr));
            const objects_slice = objects_many[0..render_data.objects_len];

            // Prepare push constant buffer (256 bytes is Vulkan minimum guaranteed size)
            var push_buffer: [256]u8 = undefined;

            for (objects_slice) |object| {
                if (!object.visible) continue;

                const mesh = object.mesh_handle.getMesh();

                // Push constants if configured and callback provided
                if (self.pipeline_config.push_constant_size > 0 and self.push_constant_fn != null) {
                    // Call user callback to generate push constants
                    const push_fn = self.push_constant_fn.?;
                    push_fn(&object, push_buffer[0..self.pipeline_config.push_constant_size]);

                    const pipeline_entry = self.pipeline_system.pipelines.get(self.pipeline.?) orelse return error.PipelineNotFound;
                    const stages: vk.ShaderStageFlags = self.pipeline_config.push_constant_stages;

                    self.graphics_context.vkd.cmdPushConstants(
                        frame_info.command_buffer,
                        pipeline_entry.pipeline_layout,
                        stages,
                        0,
                        self.pipeline_config.push_constant_size,
                        &push_buffer,
                    );
                }

                mesh.draw(self.graphics_context.*, frame_info.command_buffer);
            }
        }

        // End rendering
        rendering.end(self.graphics_context, frame_info.command_buffer);
    }

    fn teardownImpl(base: *RenderPass) void {
        const self: *BaseRenderPass = @fieldParentPtr("base", base);
        log(.INFO, "base_render_pass", "Tearing down: {s}", .{self.name});

        // Clean up resource binder
        self.resource_binder.deinit();

        // Free shader paths
        for (self.shader_paths.items) |path| {
            self.allocator.free(path);
        }
        self.shader_paths.deinit(self.allocator);

        // Free resource binding names
        for (self.resource_bindings.items) |binding| {
            self.allocator.free(binding.name);
        }
        self.resource_bindings.deinit(self.allocator);

        // Free allocated buffer arrays
        for (self.allocated_buffer_arrays.items) |array| {
            self.allocator.free(array);
        }
        self.allocated_buffer_arrays.deinit(self.allocator);

        // Free push constant range storage
        if (self.push_constant_range_storage) |range_slice| {
            self.allocator.free(range_slice);
        }

        self.allocator.free(self.name);

        // Pipeline cleanup handled by UnifiedPipelineSystem
        self.allocator.destroy(self);
        log(.INFO, "base_render_pass", "Teardown complete", .{});
    }

    fn checkValidityImpl(base: *RenderPass) bool {
        const self: *BaseRenderPass = @fieldParentPtr("base", base);
        // Simple validity check: pipeline must exist
        return self.pipeline != null;
    }
};
