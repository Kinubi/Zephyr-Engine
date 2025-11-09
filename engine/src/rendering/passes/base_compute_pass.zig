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
const FrameInfo = @import("../frameinfo.zig").FrameInfo;
const GraphicsContext = @import("../../core/graphics_context.zig").GraphicsContext;
const ManagedBuffer = @import("../buffer_manager.zig").ManagedBuffer;
const ManagedTexture = @import("../texture_manager.zig").ManagedTexture;
const ManagedTextureArray = @import("../../ecs/systems/material_system.zig").ManagedTextureArray;
const log = @import("../../utils/log.zig").log;

/// Zero-boilerplate compute pass using builder pattern
///
/// Example usage:
/// ```zig
/// const pass = try BaseComputePass.create(allocator, "particle_sim", config);
/// defer pass.destroy();
///
/// // Register compute shader
/// try pass.registerShader("particle.comp");
///
/// // Bind resources (uses named binding)
/// try pass.bind("ParticleBuffer", .{ .buffer = &particle_buffer });
/// try pass.bind("Textures", .{ .texture_array = &texture_array });
///
/// // Set dispatch configuration
/// try pass.setDispatchFn(myDispatchFunction);
///
/// // Bake pipeline and bind resources
/// try pass.bake();
///
/// // Done! RenderGraph calls execute() automatically
/// ```
pub const BaseComputePass = struct {
    base: RenderPass,
    allocator: std.mem.Allocator,
    name: []const u8,

    // Core rendering systems
    graphics_context: *GraphicsContext,
    pipeline_system: *UnifiedPipelineSystem,
    resource_binder: ResourceBinder,

    // Configuration queues (filled during setup, consumed in bake())
    shader_path: ?[]const u8 = null,
    resource_bindings: std.ArrayList(ResourceBinding),
    pipeline_config: PipelineConfig,
    push_constant_range_storage: ?[]vk.PushConstantRange = null,

    // Runtime state (created in bake())
    pipeline: ?PipelineId = null,
    cached_pipeline_handle: vk.Pipeline = .null_handle,
    is_baked: bool = false,

    // Dispatch callback
    dispatch_fn: ?*const DispatchFn = null,
    dispatch_context: ?*anyopaque = null,

    // Push constant generation callback
    push_constant_fn: PushConstantFn = null,

    /// Function pointer type for determining dispatch parameters
    /// Called each frame to compute workgroup counts
    ///
    /// Example:
    /// ```zig
    /// fn getDispatchSize(ctx: ?*anyopaque) DispatchParams {
    ///     const particle_count: *const u32 = @ptrCast(@alignCast(ctx));
    ///     const workgroup_size: u32 = 256;
    ///     return .{
    ///         .group_count_x = (particle_count.* + workgroup_size - 1) / workgroup_size,
    ///         .group_count_y = 1,
    ///         .group_count_z = 1,
    ///     };
    /// }
    /// ```
    pub const DispatchFn = fn (context: ?*anyopaque) DispatchParams;

    /// Function pointer type for generating push constants
    /// Called once per dispatch before execution
    pub const PushConstantFn = ?*const fn (context: ?*anyopaque, out_buffer: []u8) void;

    pub const DispatchParams = struct {
        group_count_x: u32,
        group_count_y: u32,
        group_count_z: u32,
    };

    const ResourceBinding = struct {
        name: []const u8,
        resource: Resource,
    };

    /// Resource types that can be bound to the pipeline
    /// The tag indicates which ResourceBinder method to use
    pub const Resource = union(enum) {
        /// Single managed buffer (uses bindStorageBufferNamed)
        buffer: *const ManagedBuffer,

        /// Array of managed buffers for frame-in-flight (uses bindUniformBufferNamed)
        buffer_array: [zephyr.MAX_FRAMES_IN_FLIGHT]*const ManagedBuffer,

        /// Single managed texture (uses bindTextureNamed)
        texture: *const ManagedTexture,

        /// Texture array for shader descriptor array (uses bindTextureArrayNamed)
        texture_array: *const ManagedTextureArray,

        /// Per-frame texture array (uses bindManagedTexturePerFrameNamed)
        texture_per_frame: [zephyr.MAX_FRAMES_IN_FLIGHT]*const ManagedTexture,

        /// Dynamic buffer array (e.g., indirect buffers) (uses bindBufferArrayNamed)
        buffer_descriptor_array: BufferDescriptorArray,
    };

    pub const BufferDescriptorArray = struct {
        infos_ptr: *const std.ArrayList(vk.DescriptorBufferInfo),
        generation_ptr: *const u32,
    };

    pub const PipelineConfig = struct {
        // Push constants
        push_constant_size: u32 = 0,
        push_constant_stages: vk.ShaderStageFlags = .{ .compute_bit = true },
    };

    /// Create a new BaseComputePass
    pub fn create(
        allocator: std.mem.Allocator,
        name: []const u8,
        graphics_context: *GraphicsContext,
        pipeline_system: *UnifiedPipelineSystem,
        config: PipelineConfig,
    ) !*BaseComputePass {
        const self = try allocator.create(BaseComputePass);
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
            .resource_bindings = .{},
            .pipeline_config = config,
        };

        return self;
    }

    /// Register the compute shader to be used in this pass
    /// Must be called before bake()
    pub fn registerShader(self: *BaseComputePass, path: []const u8) !void {
        if (self.is_baked) return error.AlreadyBaked;
        const path_copy = try self.allocator.dupe(u8, path);
        self.shader_path = path_copy;
    }

    /// Bind a resource by name (uses ResourceBinder's named binding)
    /// Resources are queued and bound during bake()
    ///
    /// Example:
    /// ```zig
    /// try pass.bind("ParticleBuffer", .{ .buffer = &particle_buffer });
    /// try pass.bind("Textures", .{ .texture_array = &texture_array });
    /// ```
    pub fn bind(self: *BaseComputePass, name: []const u8, resource: Resource) !void {
        if (self.is_baked) return error.AlreadyBaked;

        const name_copy = try self.allocator.dupe(u8, name);

        try self.resource_bindings.append(self.allocator, .{
            .name = name_copy,
            .resource = resource,
        });
    }

    /// Set the dispatch function to determine workgroup counts each frame
    pub fn setDispatchFn(
        self: *BaseComputePass,
        func: *const DispatchFn,
        context: ?*anyopaque,
    ) !void {
        if (self.is_baked) return error.AlreadyBaked;
        self.dispatch_fn = func;
        self.dispatch_context = context;
    }

    /// Set the push constant generation function
    pub fn setPushConstantFn(
        self: *BaseComputePass,
        func: PushConstantFn,
    ) !void {
        if (self.is_baked) return error.AlreadyBaked;
        self.push_constant_fn = func;
    }

    /// Bake the pass: create pipeline, populate shader reflection, bind resources
    /// Call this after registering shader and resources
    pub fn bake(self: *BaseComputePass) !void {
        if (self.is_baked) return error.AlreadyBaked;

        log(.INFO, "base_compute_pass", "Baking pass: {s}", .{self.name});

        if (self.shader_path == null) {
            log(.ERROR, "base_compute_pass", "No compute shader registered: {s}", .{self.name});
            return error.NoShaderRegistered;
        }

        // Setup push constants if specified
        if (self.pipeline_config.push_constant_size > 0) {
            const range_slice = try self.allocator.alloc(vk.PushConstantRange, 1);
            range_slice[0] = .{
                .stage_flags = self.pipeline_config.push_constant_stages,
                .offset = 0,
                .size = self.pipeline_config.push_constant_size,
            };
            self.push_constant_range_storage = range_slice;
        }
        const push_constant_ranges: ?[]const vk.PushConstantRange = self.push_constant_range_storage;

        // Create compute pipeline
        const pipeline_create_info = UnifiedPipelineConfig{
            .name = self.name,
            .compute_shader = self.shader_path,
            .push_constant_ranges = push_constant_ranges,
        };

        const result = try self.pipeline_system.createPipeline(pipeline_create_info);
        self.pipeline = result.id;

        if (!result.success) {
            log(.WARN, "base_compute_pass", "Pipeline creation failed: {s}", .{self.name});
            return error.PipelineCreationFailed;
        }

        // Cache the pipeline handle for hot-reload detection
        const pipeline_entry = self.pipeline_system.pipelines.get(self.pipeline.?) orelse return error.PipelineNotFound;
        self.cached_pipeline_handle = pipeline_entry.vulkan_pipeline;

        // Populate binding registry from shader reflection
        const reflection = try self.pipeline_system.getPipelineReflection(self.pipeline.?);
        if (reflection) |refl| {
            try self.resource_binder.populateFromReflection(refl);
        }

        // Bind all registered resources using named binding
        for (self.resource_bindings.items) |binding| {
            try self.bindResource(binding.name, binding.resource);
        }

        self.is_baked = true;
        log(.INFO, "base_compute_pass", "Pass baked successfully: {s}", .{self.name});
    }

    /// Internal: Bind a single resource using ResourceBinder
    fn bindResource(self: *BaseComputePass, name: []const u8, resource: Resource) !void {
        switch (resource) {
            .buffer => |buf_ptr| {
                try self.resource_binder.bindStorageBufferNamed(
                    self.pipeline.?,
                    name,
                    buf_ptr,
                );
            },
            .buffer_array => |buffers| {
                try self.resource_binder.bindUniformBufferNamed(
                    self.pipeline.?,
                    name,
                    buffers,
                );
            },
            .texture => |tex_ptr| {
                try self.resource_binder.bindTextureNamed(
                    self.pipeline.?,
                    name,
                    tex_ptr,
                );
            },
            .texture_array => |array_ptr| {
                try self.resource_binder.bindTextureArrayNamed(
                    self.pipeline.?,
                    name,
                    array_ptr,
                );
            },
            .texture_per_frame => |textures| {
                try self.resource_binder.bindManagedTexturePerFrameNamed(
                    self.pipeline.?,
                    name,
                    textures,
                );
            },
            .buffer_descriptor_array => |buf_array| {
                try self.resource_binder.bindBufferArrayNamed(
                    self.pipeline.?,
                    name,
                    buf_array.infos_ptr.items,
                    buf_array.infos_ptr,
                    buf_array.generation_ptr,
                );
            },
        }
    }

    pub fn destroy(self: *BaseComputePass) void {
        self.cleanupResources();
        self.allocator.destroy(self);
    }

    /// Consolidated cleanup logic
    fn cleanupResources(self: *BaseComputePass) void {
        // Deinit resource binder
        self.resource_binder.deinit();

        // Free shader path
        if (self.shader_path) |path| {
            self.allocator.free(path);
        }

        // Free resource binding names
        for (self.resource_bindings.items) |binding| {
            self.allocator.free(binding.name);
        }
        self.resource_bindings.deinit(self.allocator);

        // Free push constant range storage
        if (self.push_constant_range_storage) |range_slice| {
            self.allocator.free(range_slice);
        }

        self.allocator.free(self.name);
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
        const self: *BaseComputePass = @fieldParentPtr("base", base);
        _ = graph;

        if (!self.is_baked) {
            log(.ERROR, "base_compute_pass", "Pass not baked before setup: {s}", .{self.name});
            return error.NotBaked;
        }

        log(.DEBUG, "base_compute_pass", "Setup: {s}", .{self.name});
    }

    fn updateImpl(base: *RenderPass, frame_info: *const FrameInfo) !void {
        const self: *BaseComputePass = @fieldParentPtr("base", base);

        if (self.pipeline == null) return;

        // Check for pipeline hot-reload
        const pipeline_entry = self.pipeline_system.pipelines.get(self.pipeline.?) orelse return;
        const pipeline_rebuilt = pipeline_entry.vulkan_pipeline != self.cached_pipeline_handle;

        if (pipeline_rebuilt) {
            log(.INFO, "base_compute_pass", "Pipeline hot-reloaded, rebinding resources: {s}", .{self.name});
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
        const self: *BaseComputePass = @fieldParentPtr("base", base);

        if (self.pipeline == null) return error.PipelineNotCreated;

        const cmd = frame_info.command_buffer;

        // Bind compute pipeline with descriptor sets
        try self.pipeline_system.bindPipelineWithDescriptorSets(
            cmd,
            self.pipeline.?,
            frame_info.current_frame,
        );

        // Push constants if configured
        if (self.pipeline_config.push_constant_size > 0 and self.push_constant_fn != null) {
            var push_buffer: [256]u8 = undefined;
            const push_fn = self.push_constant_fn.?;
            push_fn(self.dispatch_context, push_buffer[0..self.pipeline_config.push_constant_size]);

            const pipeline_entry = self.pipeline_system.pipelines.get(self.pipeline.?) orelse return error.PipelineNotFound;

            self.graphics_context.vkd.cmdPushConstants(
                cmd,
                pipeline_entry.pipeline_layout,
                self.pipeline_config.push_constant_stages,
                0,
                self.pipeline_config.push_constant_size,
                &push_buffer,
            );
        }

        // Dispatch compute shader using callback
        if (self.dispatch_fn) |func| {
            const params = func(self.dispatch_context);
            self.graphics_context.vkd.cmdDispatch(
                cmd,
                params.group_count_x,
                params.group_count_y,
                params.group_count_z,
            );
        } else {
            log(.WARN, "base_compute_pass", "No dispatch function set, skipping: {s}", .{self.name});
        }
    }

    fn teardownImpl(base: *RenderPass) void {
        const self: *BaseComputePass = @fieldParentPtr("base", base);
        log(.INFO, "base_compute_pass", "Tearing down: {s}", .{self.name});

        self.cleanupResources();
        self.allocator.destroy(self);
        log(.INFO, "base_compute_pass", "Teardown complete", .{});
    }

    fn checkValidityImpl(base: *RenderPass) bool {
        const self: *BaseComputePass = @fieldParentPtr("base", base);
        return self.pipeline != null;
    }
};
