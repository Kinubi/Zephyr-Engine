const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("../core/graphics_context.zig").GraphicsContext;
const ShaderManager = @import("../assets/shader_manager.zig").ShaderManager;
const TP = @import("../threading/thread_pool.zig");
const ThreadPool = TP.ThreadPool;
const AssetId = @import("../assets/asset_types.zig").AssetId;
const PipelineBuilder = @import("pipeline_builder.zig").PipelineBuilder;
const RasterizationState = @import("pipeline_builder.zig").RasterizationState;
const MultisampleState = @import("pipeline_builder.zig").MultisampleState;
const Shader = @import("../core/shader.zig").Shader;
const ShaderCompiler = @import("../assets/shader_compiler.zig");
const DescriptorPool = @import("../core/descriptors.zig").DescriptorPool;
const DescriptorSetLayout = @import("../core/descriptors.zig").DescriptorSetLayout;
const DescriptorWriter = @import("../core/descriptors.zig").DescriptorWriter;
const Buffer = @import("../core/buffer.zig").Buffer;
const MAX_FRAMES_IN_FLIGHT = @import("../core/swapchain.zig").MAX_FRAMES_IN_FLIGHT;
const log = @import("../utils/log.zig").log;
const DescriptorUtils = @import("../utils/descriptor_utils.zig");

// (merge logic inlined into loops below)

// Deferred destruction for hot reload safety
const DeferredPipeline = struct {
    pipeline: Pipeline,
    frames_to_wait: u32,
};

/// Unified Pipeline and Descriptor Set Management System
///
/// This system provides a high-level abstraction over Vulkan pipelines and descriptor sets,
/// automatically extracting descriptor layouts from shaders and managing resource bindings.
pub const UnifiedPipelineSystem = struct {
    allocator: std.mem.Allocator,
    graphics_context: *GraphicsContext,
    shader_manager: *ShaderManager,

    // Pipeline and descriptor management
    pipelines: std.HashMap(PipelineId, Pipeline, PipelineIdContext, std.hash_map.default_max_load_percentage),
    descriptor_pools: std.HashMap(u32, *DescriptorPool, std.hash_map.AutoContext(u32), std.hash_map.default_max_load_percentage),

    // Resource binding state
    bound_resources: std.HashMap(ResourceBindingKey, BoundResource, ResourceBindingKeyContext, std.hash_map.default_max_load_percentage),

    // Hot-reload integration
    // Flag to skip descriptor updates during hot reload
    hot_reload_in_progress: bool = false,
    // Flag to prevent recursive shader reload
    rebuilding_pipelines: bool = false,
    shader_to_pipelines: std.HashMap([]const u8, std.ArrayList(PipelineId), std.hash_map.StringContext, std.hash_map.default_max_load_percentage), // shader_path -> pipeline_ids

    // Deferred destruction for hot reload safety
    deferred_destroys: std.ArrayList(DeferredPipeline),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, graphics_context: *GraphicsContext, shader_manager: *ShaderManager) !Self {
        const self = Self{
            .allocator = allocator,
            .graphics_context = graphics_context,
            .shader_manager = shader_manager,
            .pipelines = std.HashMap(PipelineId, Pipeline, PipelineIdContext, std.hash_map.default_max_load_percentage).init(allocator),
            .descriptor_pools = std.HashMap(u32, *DescriptorPool, std.hash_map.AutoContext(u32), std.hash_map.default_max_load_percentage).init(allocator),
            .bound_resources = std.HashMap(ResourceBindingKey, BoundResource, ResourceBindingKeyContext, std.hash_map.default_max_load_percentage).init(allocator),
            .shader_to_pipelines = std.HashMap([]const u8, std.ArrayList(PipelineId), std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
            .deferred_destroys = .{},
        };

        return self;
    }

    /// Register this pipeline system to receive shader compilation notifications
    /// Call this after the system is fully initialized and has a stable address
    pub fn registerForShaderUpdates(self: *Self) void {
        // Note: We don't register a delivery worker here because the shader_manager
        // already has its own delivery worker (shaderDeliveryWorker) that calls
        // onShaderReloaded. Instead, we rely on the shader_to_pipelines mapping
        // to track which pipelines need rebuilding when shaders are delivered.
        // The pipeline rebuilds are triggered by scheduleRebuildByName which is
        // called from the shader manager's delivery path.
        _ = self;
    }

    pub fn deinit(self: *Self) void {
        // Clean up pipelines
        var pipeline_iter = self.pipelines.valueIterator();
        while (pipeline_iter.next()) |pipeline| {
            pipeline.deinit(self.graphics_context, self.allocator);
        }
        self.pipelines.deinit();

        // Clean up descriptor pools
        var pool_iter = self.descriptor_pools.valueIterator();
        while (pool_iter.next()) |pool| {
            pool.*.deinit();
            self.allocator.destroy(pool.*);
        }
        self.descriptor_pools.deinit();

        // Clean up resources
        self.bound_resources.deinit();

        // Clean up any remaining deferred destroys
        for (self.deferred_destroys.items) |deferred| {
            var pipeline_mut = deferred.pipeline;
            pipeline_mut.deinit(self.graphics_context, self.allocator);
        }
        self.deferred_destroys.deinit(self.allocator);

        // Clean up shader-to-pipeline mapping
        var shader_iter = self.shader_to_pipelines.valueIterator();
        while (shader_iter.next()) |pipeline_list| {
            pipeline_list.deinit(self.allocator);
        }
        var key_iter = self.shader_to_pipelines.keyIterator();
        while (key_iter.next()) |key| {
            self.allocator.free(key.*);
        }
        self.shader_to_pipelines.deinit();
    }

    /// Create a unified pipeline with automatic descriptor layout extraction
    pub fn createPipeline(
        self: *Self,
        config: PipelineConfig,
    ) !PipelineId {
        // Generate pipeline ID
        const generated_pipeline_id = PipelineId{
            .name = try self.allocator.dupe(u8, config.name),
            .hash = self.calculatePipelineHash(config),
        };

        return self.createPipelineWithId(config, generated_pipeline_id);
    }

    /// Create a pipeline with a specific ID (used for rebuilding)
    fn createPipelineWithId(
        self: *Self,
        config: PipelineConfig,
        pipeline_id: PipelineId,
    ) !PipelineId {
        log(.INFO, "unified_pipeline", "Creating pipeline: {s}", .{config.name});

        // Load shaders and collect for pipeline building
        var shaders = std.ArrayList(*Shader){};
        var shaders_transferred = false;
        defer {
            if (!shaders_transferred) {
                // Clean up heap-allocated shaders on error
                for (shaders.items) |shader| {
                    shader.deinit(self.graphics_context.*);
                    self.allocator.destroy(shader);
                }
            }
            shaders.deinit(self.allocator);
        }

        var descriptor_layout_info = DescriptorLayoutInfo.init(self.allocator);
        defer descriptor_layout_info.deinit();

        // Load compute shader
        if (config.compute_shader) |compute_path| {
            const compiled_shader = try self.shader_manager.loadShader(compute_path, config.shader_options);
            const shader = try self.allocator.create(Shader);
            shader.* = try Shader.create(self.graphics_context.*, compiled_shader.compiled_shader.spirv_code, .{ .compute_bit = true }, null);
            try shaders.append(self.allocator, shader);

            // Extract descriptor layout from shader reflection
            try self.extractDescriptorLayout(&descriptor_layout_info, compiled_shader.compiled_shader.reflection, .{ .compute_bit = true });
        } // Load vertex shader
        if (config.vertex_shader) |vertex_path| {
            const compiled_shader = try self.shader_manager.loadShader(vertex_path, config.shader_options);
            const shader = try self.allocator.create(Shader);
            shader.* = try Shader.create(self.graphics_context.*, compiled_shader.compiled_shader.spirv_code, .{ .vertex_bit = true }, null);
            try shaders.append(self.allocator, shader);

            // Extract descriptor layout from shader reflection
            try self.extractDescriptorLayout(&descriptor_layout_info, compiled_shader.compiled_shader.reflection, .{ .vertex_bit = true });
        }

        // Load fragment shader
        if (config.fragment_shader) |fragment_path| {
            const compiled_shader = try self.shader_manager.loadShader(fragment_path, config.shader_options);
            const shader = try self.allocator.create(Shader);
            shader.* = try Shader.create(self.graphics_context.*, compiled_shader.compiled_shader.spirv_code, .{ .fragment_bit = true }, null);
            try shaders.append(self.allocator, shader);

            // Extract and merge descriptor layout from shader reflection
            try self.extractDescriptorLayout(&descriptor_layout_info, compiled_shader.compiled_shader.reflection, .{ .fragment_bit = true });
        }

        // Create descriptor set layouts from extracted information
        const descriptor_set_layouts = try self.createDescriptorSetLayouts(&descriptor_layout_info);
        defer self.allocator.free(descriptor_set_layouts);

        // Create pipeline layout
        const pipeline_layout = try self.createPipelineLayout(descriptor_set_layouts, config.push_constant_ranges);

        // Determine pipeline type
        const is_compute_pipeline = config.compute_shader != null;

        // Build the actual Vulkan pipeline
        var builder = PipelineBuilder.init(self.allocator, self.graphics_context);
        defer builder.deinit();

        var vulkan_pipeline: vk.Pipeline = undefined;

        if (is_compute_pipeline) {
            // For compute pipelines, set compute mode and shader
            _ = builder.compute();

            for (shaders.items) |shader| {
                if (shader.shader_type.compute_bit) {
                    _ = try builder.computeShader(shader);
                    break; // Only one compute shader allowed
                }
            }

            // Build compute pipeline
            vulkan_pipeline = try builder.buildComputePipeline(pipeline_layout);
        } else {
            // For graphics pipelines, configure vertex input and state

            // Add required graphics pipeline configuration
            _ = try builder.dynamicViewportScissor();
            _ = try builder.addColorBlendAttachment(@import("pipeline_builder.zig").ColorBlendAttachment.disabled());

            // Configure vertex input
            if (config.vertex_input_bindings) |bindings| {
                for (bindings) |binding| {
                    _ = try builder.addVertexBinding(binding);
                }
            }
            if (config.vertex_input_attributes) |attributes| {
                for (attributes) |attribute| {
                    _ = try builder.addVertexAttribute(attribute);
                }
            }

            // Configure pipeline state

            // Set topology
            switch (config.topology) {
                .triangle_list => _ = builder.triangleList(),
                .triangle_strip => _ = builder.triangleStrip(),
                .line_list => _ = builder.lineList(),
                .point_list => _ = builder.pointList(),
                else => _ = builder.triangleList(), // Default fallback
            }

            // Configure rasterization state
            var raster_state = RasterizationState.default();
            raster_state.polygon_mode = config.polygon_mode;
            raster_state.cull_mode = config.cull_mode;
            raster_state.front_face = config.front_face;
            _ = builder.withRasterizationState(raster_state);

            // Configure multisample state
            if (config.multisample_state) |ms_state| {
                _ = builder.withMultisampleState(MultisampleState{ .rasterization_samples = ms_state.rasterization_samples });
            }

            // Set render pass
            _ = builder.withRenderPass(config.render_pass, config.subpass);

            // Add shader stages (vertex and fragment only) in the correct order
            // Skip compute shaders for graphics pipelines
            for (shaders.items) |shader| {
                if (shader.shader_type.vertex_bit and !shader.shader_type.compute_bit) {
                    _ = try builder.addShaderStage(shader.shader_type, shader);
                }
            }
            for (shaders.items) |shader| {
                if (shader.shader_type.fragment_bit and !shader.shader_type.compute_bit) {
                    _ = try builder.addShaderStage(shader.shader_type, shader);
                }
            }

            // Build graphics pipeline
            vulkan_pipeline = try builder.buildGraphicsPipeline(pipeline_layout);
        }

        // Create descriptor pools and sets
        const descriptor_resources = try self.createDescriptorSets(&descriptor_layout_info, descriptor_set_layouts);

        // Transfer ownership of shaders to the pipeline (don't free them in defer)
        const owned_shaders = try shaders.toOwnedSlice(self.allocator);
        shaders_transferred = true; // Mark as transferred so defer won't clean them up

        // Create unified pipeline object
        const pipeline = Pipeline{
            .vulkan_pipeline = vulkan_pipeline,
            .pipeline_layout = pipeline_layout,
            .descriptor_layout_info = descriptor_layout_info,
            .descriptor_pools = descriptor_resources.pools,
            .descriptor_layouts = descriptor_resources.layouts,
            .descriptor_sets = descriptor_resources.sets,
            .shaders = owned_shaders,
            .config = config,
            .is_compute = is_compute_pipeline,
        };

        // Use the provided pipeline ID
        try self.pipelines.put(pipeline_id, pipeline);

        // Track shader dependencies for hot-reload
        try self.registerShaderDependency(config.compute_shader, pipeline_id);
        try self.registerShaderDependency(config.vertex_shader, pipeline_id);
        try self.registerShaderDependency(config.fragment_shader, pipeline_id);

        log(.INFO, "unified_pipeline", "✅ Created pipeline: {s} (hash: {})", .{ config.name, pipeline_id.hash });

        return pipeline_id;
    }

    /// Bind a pipeline for rendering
    pub fn bindPipeline(self: *Self, command_buffer: vk.CommandBuffer, pipeline_id: PipelineId) !void {
        const pipeline = self.pipelines.get(pipeline_id) orelse {
            log(.ERROR, "unified_pipeline", "❌ Pipeline not found when binding: {s} (hash: {})", .{ pipeline_id.name, pipeline_id.hash });
            log(.ERROR, "unified_pipeline", "Available pipelines: {}", .{self.pipelines.count()});
            var iter = self.pipelines.keyIterator();
            while (iter.next()) |key| {
                log(.ERROR, "unified_pipeline", "  - {s} (hash: {})", .{ key.name, key.hash });
            }
            return error.PipelineNotFound;
        };

        // Bind the Vulkan pipeline with correct bind point
        const bind_point: vk.PipelineBindPoint = if (pipeline.is_compute) .compute else .graphics;
        self.graphics_context.vkd.cmdBindPipeline(command_buffer, bind_point, pipeline.vulkan_pipeline);

        // Bind descriptor sets
        if (pipeline.descriptor_sets.items.len > 0) {
            // For now, bind all sets from frame 0 (we'll update this when we implement frame indexing)
            var descriptor_sets_to_bind = std.ArrayList(vk.DescriptorSet){};
            defer descriptor_sets_to_bind.deinit(self.allocator);

            for (pipeline.descriptor_sets.items) |frame_sets| {
                try descriptor_sets_to_bind.append(self.allocator, frame_sets[0]); // Use frame 0 for now
            }

            if (descriptor_sets_to_bind.items.len > 0) {
                self.graphics_context.vkd.cmdBindDescriptorSets(
                    command_buffer,
                    bind_point,
                    pipeline.pipeline_layout,
                    0, // First set
                    @intCast(descriptor_sets_to_bind.items.len),
                    descriptor_sets_to_bind.items.ptr,
                    0,
                    null,
                );
            }
        }
    }

    /// Get the pipeline layout for a given pipeline
    pub fn getPipelineLayout(self: *Self, pipeline_id: PipelineId) !vk.PipelineLayout {
        const pipeline = self.pipelines.get(pipeline_id) orelse return error.PipelineNotFound;
        return pipeline.pipeline_layout;
    }

    /// Bind a resource to a descriptor set
    pub fn bindResource(
        self: *Self,
        pipeline_id: PipelineId,
        set: u32,
        binding: u32,
        resource: Resource,
        frame_index: u32,
    ) !void {
        const key = ResourceBindingKey{
            .pipeline_id = pipeline_id,
            .set = set,
            .binding = binding,
            .frame_index = frame_index,
        };

        const bound_resource = BoundResource{
            .resource = resource,
            .dirty = true,
        };

        try self.bound_resources.put(key, bound_resource);
    }

    /// Mark all bound resources for a pipeline as dirty (useful after pipeline recreation)
    pub fn markPipelineResourcesDirty(self: *Self, pipeline_id: PipelineId) void {
        var resource_iter = self.bound_resources.iterator();
        while (resource_iter.next()) |entry| {
            const key = entry.key_ptr.*;
            if (std.mem.eql(u8, key.pipeline_id.name, pipeline_id.name)) {
                entry.value_ptr.dirty = true;
            }
        }
    }

    /// Update all dirty descriptor sets
    pub fn updateDescriptorSets(self: *Self, frame_index: u32) !void {

        // Skip descriptor updates if hot reload is in progress to avoid validation errors
        if (self.hot_reload_in_progress) {
            return;
        }

        // Group updates by pipeline and set
        var updates_by_pipeline = std.HashMap(PipelineId, std.ArrayList(DescriptorUpdate), PipelineIdContext, std.hash_map.default_max_load_percentage).init(self.allocator);
        defer {
            var iter = updates_by_pipeline.valueIterator();
            while (iter.next()) |list| {
                list.deinit(self.allocator);
            }
            updates_by_pipeline.deinit();
        }

        // Collect all dirty bindings for this frame
        var resource_iter = self.bound_resources.iterator();
        var dirty_count: u32 = 0;
        while (resource_iter.next()) |entry| {
            const key = entry.key_ptr.*;
            const bound_resource = entry.value_ptr.*;

            if (key.frame_index == frame_index and bound_resource.dirty) {
                dirty_count += 1;

                const update = DescriptorUpdate{
                    .set = key.set,
                    .binding = key.binding,
                    .resource = bound_resource.resource,
                };

                var result = try updates_by_pipeline.getOrPut(key.pipeline_id);
                if (!result.found_existing) {
                    result.value_ptr.* = std.ArrayList(DescriptorUpdate){};
                }
                try result.value_ptr.append(self.allocator, update);

                // Mark as clean
                entry.value_ptr.dirty = false;
            }
        }

        // Apply updates
        var update_iter = updates_by_pipeline.iterator();
        while (update_iter.next()) |entry| {
            const pipeline_id = entry.key_ptr.*;
            const updates = entry.value_ptr.*;

            try self.applyDescriptorUpdates(pipeline_id, updates.items, frame_index);
        }
    }

    /// Manually rebuild a pipeline (useful for debugging or forced reloads)
    pub fn rebuildPipelineManual(self: *Self, pipeline_id: PipelineId) !void {
        try self.rebuildPipeline(pipeline_id);
    }

    // Private implementation methods

    fn registerShaderDependency(self: *Self, shader_path: ?[]const u8, pipeline_id: PipelineId) !void {
        if (shader_path) |path| {
            const owned_path = try self.allocator.dupe(u8, path);

            // Get or create the pipeline list for this shader
            var result = try self.shader_to_pipelines.getOrPut(owned_path);
            if (!result.found_existing) {
                result.value_ptr.* = std.ArrayList(PipelineId){};
            }

            try result.value_ptr.append(self.allocator, pipeline_id);
        }
    }

    fn onShaderReloaded(context: ?*anyopaque, shader_path: []const u8, _: []const []const u8) void {
        const self = @as(*Self, @ptrCast(@alignCast(context.?)));
        self.handleShaderReload(shader_path) catch |err| {
            log(.ERROR, "unified_pipeline", "Failed to handle shader reload for {s}: {}", .{ shader_path, err });
        };
    }

    /// Schedule a pipeline rebuild by pipeline name. This submits a ThreadPool
    /// work item which will wait for any in-progress shader compilations for
    /// that pipeline to complete before calling rebuildPipeline.
    /// NOTE: This function is currently unused - pipeline rebuilds are triggered
    /// by shader compilation completion via ShaderRebuildJob.
    pub fn scheduleRebuildByName(self: *Self, pipeline_name: []const u8) !void {
        // Allocate a small RebuildJob on this system's allocator and submit
        // a custom WorkItem into the shader manager's thread pool.
        const name_copy = try self.allocator.dupe(u8, pipeline_name);
        const job = try self.allocator.create(Self.RebuildJob);
        job.* = Self.RebuildJob{ .pipeline_name = name_copy, .allocator = self.allocator, .system = self };

        const work_item = TP.createCustomWork(
            0, // id
            @as(*anyopaque, job), // user_data - the RebuildJob
            @sizeOf(RebuildJob), // size
            .high, // priority
            pipelineRebuildWorker, // Note: This worker signature doesn't match ShaderRebuildJob!
            @as(*anyopaque, self), // context - the UnifiedPipelineSystem
        );

        // Submit into the ThreadPool owned by the shader manager
        try self.shader_manager.thread_pool.submitWork(work_item);
    }

    pub fn handleShaderReload(self: *Self, shader_path: []const u8) !void {
        // Prevent recursive shader reload calls
        if (self.rebuilding_pipelines) {
            log(.WARN, "unified_pipeline", "Skipping shader reload for {s} - already rebuilding pipelines", .{shader_path});
            return;
        }

        log(.INFO, "unified_pipeline", "🔥 Handling shader reload: {s}", .{shader_path});

        // Set flag to prevent recursive calls
        self.rebuilding_pipelines = true;
        defer self.rebuilding_pipelines = false;

        // Find all pipelines that use this shader
        const affected_pipelines = self.shader_to_pipelines.get(shader_path) orelse return;

        log(.INFO, "unified_pipeline", "Found {} pipelines affected by shader reload", .{affected_pipelines.items.len});

        // Rebuild each affected pipeline
        for (affected_pipelines.items) |pipeline_id| {
            self.rebuildPipeline(pipeline_id) catch |err| {
                log(.ERROR, "unified_pipeline", "Failed to rebuild pipeline {s}: {}", .{ pipeline_id.name, err });
                continue;
            };
        }
    }

    fn rebuildPipeline(self: *Self, pipeline_id: PipelineId) !void {
        log(.INFO, "unified_pipeline", "🔄 Rebuilding pipeline: {s} (hot-reload)", .{pipeline_id.name});

        // Set hot reload flag to prevent descriptor updates during rebuild
        self.hot_reload_in_progress = true;
        defer self.hot_reload_in_progress = false;

        // Get the existing pipeline to extract its config
        const old_pipeline = self.pipelines.get(pipeline_id) orelse return error.PipelineNotFound;
        const config = old_pipeline.config;

        // Clear dirty flags for all resources of this pipeline to prevent descriptor updates on old sets
        var resource_iter = self.bound_resources.iterator();
        var cleared_count: u32 = 0;
        while (resource_iter.next()) |entry| {
            const key = entry.key_ptr.*;
            if (std.mem.eql(u8, key.pipeline_id.name, pipeline_id.name)) {
                // Clear dirty flag to prevent updateDescriptorSets from trying to update old descriptor sets
                if (entry.value_ptr.dirty) {
                    entry.value_ptr.dirty = false;
                    cleared_count += 1;
                }
            }
        }

        log(.INFO, "unified_pipeline", "Cleared {} dirty flags for pipeline: {s}", .{ cleared_count, pipeline_id.name });

        // Get reference to the old pipeline before we replace it
        const old_pipeline_to_destroy = self.pipelines.get(pipeline_id).?;

        // Remove shader dependencies for the old pipeline before creating new one
        try self.unregisterPipelineDependencies(pipeline_id);

        // Create the new pipeline - this will atomically replace the old one in the hashmap
        const new_pipeline_id = try self.createPipelineWithId(config, pipeline_id);
        _ = new_pipeline_id; // Should be the same as input

        // Schedule the old pipeline for destruction after a few frames
        // This ensures any in-flight command buffers finish using it
        const frames_to_wait = MAX_FRAMES_IN_FLIGHT + 1; // Wait for all frames in flight plus one more
        try self.deferred_destroys.append(self.allocator, DeferredPipeline{
            .pipeline = old_pipeline_to_destroy,
            .frames_to_wait = frames_to_wait,
        });

        log(.INFO, "unified_pipeline", "Scheduled old pipeline for deferred destruction in {} frames", .{frames_to_wait});

        log(.INFO, "unified_pipeline", "✅ Pipeline rebuilt with new descriptor sets: {s}", .{pipeline_id.name});
    }

    // Rebuild job allocated by shader hot reload system
    // Contains compiled shader and file path. The system pointer is passed via WorkItem.context.
    // Allocator and other references (shader_manager, watcher) are accessed through the system.
    pub const ShaderRebuildJob = struct {
        file_path: []const u8,
        compiled_shader: ShaderCompiler.CompiledShader,
    };

    /// ThreadPool worker that receives compiled shader from hot reload,
    /// updates shader_manager, clears compilation flag, then rebuilds affected pipelines.
    pub fn pipelineRebuildWorker(context: *anyopaque, work_item: TP.WorkItem) void {
        const sys: *Self = @ptrCast(@alignCast(context));

        // Get the job from work_item.data (not from context!)
        const job: *Self.ShaderRebuildJob = @ptrCast(@alignCast(work_item.data.gpu_work.data));
        const file_path = job.file_path;
        var compiled_shader = job.compiled_shader; // var so we can deinit on error

        // Get references through the system
        const shader_manager = sys.shader_manager;
        const allocator = sys.allocator;

        defer {
            // Job is freed but compiled_shader ownership is transferred to shader_manager
            allocator.destroy(job);
        }

        // Update shader_manager with the compiled shader (transfers ownership)
        shader_manager.onShaderCompiledFromHotReload(file_path, compiled_shader) catch |err| {
            std.log.err("[unified_pipeline] Failed to update shader_manager for {s}: {}", .{ file_path, err });
            // Clean up on error
            compiled_shader.deinit(allocator);
            return;
        };

        // Clear compilation flag in the watcher (accessed through shader_manager)
        if (shader_manager.hot_reload.watched_shaders.getPtr(file_path)) |fi| {
            fi.compilation_in_progress = false;
        }

        // Find all pipelines that use this shader and rebuild them
        sys.handleShaderReload(file_path) catch |err| {
            std.log.err("[unified_pipeline] Failed to handle shader reload for pipelines: {}", .{err});
            return;
        };
    }

    /// Process deferred pipeline destructions - call this each frame
    pub fn processDeferredDestroys(self: *Self) void {
        var i: usize = 0;
        while (i < self.deferred_destroys.items.len) {
            var deferred = &self.deferred_destroys.items[i];
            if (deferred.frames_to_wait == 0) {
                // Time to destroy this pipeline
                var pipeline_to_destroy = deferred.pipeline;
                pipeline_to_destroy.deinit(self.graphics_context, self.allocator);

                // Remove from the list
                _ = self.deferred_destroys.swapRemove(i);
                // Don't increment i since we removed an element
            } else {
                // Decrement the wait counter
                deferred.frames_to_wait -= 1;
                i += 1;
            }
        }
    }

    fn unregisterPipelineDependencies(self: *Self, pipeline_id: PipelineId) !void {
        // Remove this pipeline from all shader dependency lists
        var shader_iter = self.shader_to_pipelines.iterator();
        while (shader_iter.next()) |entry| {
            const pipeline_list = entry.value_ptr;
            var i: usize = 0;
            while (i < pipeline_list.items.len) {
                if (std.mem.eql(u8, pipeline_list.items[i].name, pipeline_id.name)) {
                    _ = pipeline_list.swapRemove(i);
                } else {
                    i += 1;
                }
            }
        }
    }

    fn extractDescriptorLayout(
        self: *Self,
        layout_info: *DescriptorLayoutInfo,
        reflection: ShaderCompiler.ShaderReflection,
        stage_flags: vk.ShaderStageFlags,
    ) !void {
        // Build per-set lists by scanning existing layout_info and reflection
        var max_set_idx: u32 = 0;

        // Scan existing layout_info for max set
        var idx: usize = 0;
        while (idx < layout_info.sets.items.len) : (idx += 1) {
            if (layout_info.sets.items[idx].len != 0) {
                const s = @as(u32, @intCast(idx));
                if (s > max_set_idx) max_set_idx = s;
            }
        }

        // Scan reflection for max set
        for (reflection.uniform_buffers.items) |ub| {
            if (ub.set > max_set_idx) max_set_idx = ub.set;
        }
        for (reflection.storage_buffers.items) |sb| {
            if (sb.set > max_set_idx) max_set_idx = sb.set;
        }
        for (reflection.textures.items) |t| {
            if (t.set > max_set_idx) max_set_idx = t.set;
        }
        for (reflection.samplers.items) |s| {
            if (s.set > max_set_idx) max_set_idx = s.set;
        }

        // Create per-set array of binding lists
        var per_set_lists = std.ArrayList(std.ArrayList(vk.DescriptorSetLayoutBinding)){};
        var s: usize = 0;
        while (s <= @as(usize, max_set_idx)) : (s += 1) {
            try per_set_lists.append(self.allocator, std.ArrayList(vk.DescriptorSetLayoutBinding){});
        }

        // Copy existing layout_info bindings into per_set_lists
        idx = 0;
        while (idx < layout_info.sets.items.len) : (idx += 1) {
            const bindings = layout_info.sets.items[idx];
            if (bindings.len == 0) continue;
            var list = per_set_lists.items[idx];
            for (bindings) |b| {
                try list.append(self.allocator, b);
            }
            per_set_lists.items[idx] = list;
        }

        // Merge helper: use shared util to merge/append bindings

        // Walk uniform buffers
        for (reflection.uniform_buffers.items) |ub| {
            const set_idx = ub.set;
            var list = per_set_lists.items[@as(usize, set_idx)];
            try DescriptorUtils.mergeDescriptorBinding(self.allocator, &list, ub.binding, .uniform_buffer, stage_flags, 1);
            per_set_lists.items[@as(usize, set_idx)] = list;
        }

        // Walk storage buffers
        for (reflection.storage_buffers.items) |sb| {
            const set_idx = sb.set;
            var list = per_set_lists.items[@as(usize, set_idx)];
            try DescriptorUtils.mergeDescriptorBinding(self.allocator, &list, sb.binding, .storage_buffer, stage_flags, 1);
            per_set_lists.items[@as(usize, set_idx)] = list;
        }

        // Walk textures (sampled images) -> combined_image_sampler by default
        for (reflection.textures.items) |tex| {
            const set_idx = tex.set;
            var list = per_set_lists.items[@as(usize, set_idx)];
            try DescriptorUtils.mergeDescriptorBinding(self.allocator, &list, tex.binding, .combined_image_sampler, stage_flags, 1);
            per_set_lists.items[@as(usize, set_idx)] = list;
        }

        // Walk separate samplers
        for (reflection.samplers.items) |samp| {
            const set_idx = samp.set;
            var list = per_set_lists.items[@as(usize, set_idx)];
            try DescriptorUtils.mergeDescriptorBinding(self.allocator, &list, samp.binding, .sampler, stage_flags, 1);
            per_set_lists.items[@as(usize, set_idx)] = list;
        }

        // Convert per_set_lists into layout_info.sets (owned slices)
        var idx_u: usize = 0;
        while (idx_u < per_set_lists.items.len) : (idx_u += 1) {
            var list_ptr = &per_set_lists.items[idx_u];
            if (list_ptr.items.len == 0) continue;
            const slice = try list_ptr.toOwnedSlice(self.allocator);
            // Ensure layout_info.sets has enough entries
            if (layout_info.sets.items.len <= idx_u) {
                // Append an empty slice placeholder
                try layout_info.sets.append(self.allocator, &[_]vk.DescriptorSetLayoutBinding{});
            }
            // free previous placeholder if any
            if (layout_info.sets.items[idx_u].len != 0) {
                self.allocator.free(layout_info.sets.items[idx_u]);
            }
            layout_info.sets.items[idx_u] = slice;
        }

        // Cleanup per_set_lists
        var cleanup_i: usize = 0;
        while (cleanup_i < per_set_lists.items.len) : (cleanup_i += 1) {
            per_set_lists.items[cleanup_i].deinit(self.allocator);
        }
        per_set_lists.deinit(self.allocator);
    }

    fn createDescriptorSetLayouts(self: *Self, layout_info: *const DescriptorLayoutInfo) ![]vk.DescriptorSetLayout {
        var layouts = std.ArrayList(vk.DescriptorSetLayout){};
        defer layouts.deinit(self.allocator);

        for (layout_info.sets.items) |set_bindings| {
            if (set_bindings.len == 0) continue;

            const layout_create_info = vk.DescriptorSetLayoutCreateInfo{
                .binding_count = @intCast(set_bindings.len),
                .p_bindings = set_bindings.ptr,
            };

            const layout = try self.graphics_context.vkd.createDescriptorSetLayout(self.graphics_context.dev, &layout_create_info, null);
            try layouts.append(self.allocator, layout);
        }

        return try layouts.toOwnedSlice(self.allocator);
    }

    fn createPipelineLayout(
        self: *Self,
        descriptor_set_layouts: []const vk.DescriptorSetLayout,
        push_constant_ranges: ?[]const vk.PushConstantRange,
    ) !vk.PipelineLayout {
        const create_info = vk.PipelineLayoutCreateInfo{
            .set_layout_count = @intCast(descriptor_set_layouts.len),
            .p_set_layouts = if (descriptor_set_layouts.len > 0) descriptor_set_layouts.ptr else null,
            .push_constant_range_count = if (push_constant_ranges) |ranges| @intCast(ranges.len) else 0,
            .p_push_constant_ranges = if (push_constant_ranges) |ranges| ranges.ptr else null,
        };

        return try self.graphics_context.vkd.createPipelineLayout(self.graphics_context.dev, &create_info, null);
    }

    fn createDescriptorSets(
        self: *Self,
        layout_info: *const DescriptorLayoutInfo,
        set_layouts: []const vk.DescriptorSetLayout,
    ) !struct {
        pools: std.ArrayList(*DescriptorPool),
        layouts: std.ArrayList(*DescriptorSetLayout),
        sets: std.ArrayList([]vk.DescriptorSet),
    } {
        _ = set_layouts; // We'll build our own layouts with the builder pattern

        var pools = std.ArrayList(*DescriptorPool){};
        var layouts = std.ArrayList(*DescriptorSetLayout){};
        var sets = std.ArrayList([]vk.DescriptorSet){};
        errdefer {
            for (pools.items) |pool| {
                pool.deinit();
                self.allocator.destroy(pool);
            }
            pools.deinit(self.allocator);
            for (layouts.items) |layout| {
                layout.deinit();
                self.allocator.destroy(layout);
            }
            layouts.deinit(self.allocator);
            for (sets.items) |set_array| {
                self.allocator.free(set_array);
            }
            sets.deinit(self.allocator);
        }

        // For each descriptor set in the layout
        for (layout_info.sets.items) |set_bindings| {
            if (set_bindings.len == 0) continue;

            // Count descriptor types for pool sizing
            var uniform_buffers: u32 = 0;
            var storage_buffers: u32 = 0;
            var combined_samplers: u32 = 0;

            for (set_bindings) |binding| {
                switch (binding.descriptor_type) {
                    .uniform_buffer => uniform_buffers += binding.descriptor_count,
                    .storage_buffer => storage_buffers += binding.descriptor_count,
                    .combined_image_sampler => combined_samplers += binding.descriptor_count,
                    else => {},
                }
            }

            // Create descriptor pool using builder pattern
            var pool_builder = DescriptorPool.Builder{
                .gc = self.graphics_context,
                .poolSizes = std.ArrayList(vk.DescriptorPoolSize){},
                .poolFlags = .{ .free_descriptor_set_bit = true },
                .maxSets = 0,
                .allocator = self.allocator,
            };
            defer pool_builder.poolSizes.deinit(self.allocator);

            const pool = try self.allocator.create(DescriptorPool);
            pool.* = try pool_builder
                .setMaxSets(MAX_FRAMES_IN_FLIGHT * 4) // Allow for multiple pipelines per frame
                .addPoolSize(.uniform_buffer, @max(uniform_buffers * MAX_FRAMES_IN_FLIGHT * 2, 1))
                .addPoolSize(.storage_buffer, @max(storage_buffers * MAX_FRAMES_IN_FLIGHT * 2, 1))
                .addPoolSize(.combined_image_sampler, @max(combined_samplers * MAX_FRAMES_IN_FLIGHT * 2, 1))
                .build();

            try pools.append(self.allocator, pool);

            // Create descriptor set layout using builder pattern
            var layout_builder = DescriptorSetLayout.Builder{
                .gc = self.graphics_context,
                .bindings = std.AutoHashMap(u32, vk.DescriptorSetLayoutBinding).init(self.allocator),
            };

            for (set_bindings) |binding| {
                _ = layout_builder.addBinding(binding.binding, binding.descriptor_type, binding.stage_flags, binding.descriptor_count);
            }

            const layout = try self.allocator.create(DescriptorSetLayout);
            layout.* = try layout_builder.build();
            try layouts.append(self.allocator, layout);

            // Allocate descriptor sets for all frames
            const frame_sets = try self.allocator.alloc(vk.DescriptorSet, MAX_FRAMES_IN_FLIGHT);
            for (frame_sets) |*set| {
                try pool.allocateDescriptor(layout.descriptor_set_layout, set);
            }
            try sets.append(self.allocator, frame_sets);
        }

        return .{
            .pools = pools,
            .layouts = layouts,
            .sets = sets,
        };
    }

    fn applyDescriptorUpdates(
        self: *Self,
        pipeline_id: PipelineId,
        updates: []const DescriptorUpdate,
        frame_index: u32,
    ) !void {
        if (updates.len == 0) return;

        // Get the pipeline to access its descriptor sets
        const pipeline_ptr = self.pipelines.getPtr(pipeline_id) orelse {
            std.log.err("Pipeline {} not found when applying descriptor updates", .{pipeline_id});
            return;
        };

        // Group updates by descriptor set
        var updates_by_set = std.HashMap(u32, std.ArrayList(DescriptorUpdate), std.hash_map.AutoContext(u32), std.hash_map.default_max_load_percentage).init(self.allocator);
        defer {
            var iter = updates_by_set.valueIterator();
            while (iter.next()) |list| {
                list.deinit(self.allocator);
            }
            updates_by_set.deinit();
        }

        // Group updates by set number
        for (updates) |update| {
            var result = try updates_by_set.getOrPut(update.set);
            if (!result.found_existing) {
                result.value_ptr.* = std.ArrayList(DescriptorUpdate){};
            }
            try result.value_ptr.append(self.allocator, update);
        }

        // Apply updates to each descriptor set
        var set_iter = updates_by_set.iterator();
        while (set_iter.next()) |entry| {
            const set_index = entry.key_ptr.*;
            const set_updates = entry.value_ptr.*;

            if (set_index >= pipeline_ptr.descriptor_sets.items.len) {
                std.log.err("Descriptor set index {} out of range for pipeline {s} (has {} sets)", .{ set_index, pipeline_id.name, pipeline_ptr.descriptor_sets.items.len });
                continue;
            }

            // Get the descriptor set for this frame
            const descriptor_sets = pipeline_ptr.descriptor_sets.items[set_index];
            if (frame_index >= descriptor_sets.len) {
                std.log.err("Frame index {} out of range for descriptor set", .{frame_index});
                continue;
            }

            // Use DescriptorWriter to update the descriptor set
            const pool = pipeline_ptr.descriptor_pools.items[set_index];
            const layout = pipeline_ptr.descriptor_layouts.items[set_index];
            var writer = DescriptorWriter.init(self.graphics_context, layout, pool, self.allocator);
            defer writer.deinit();

            // Apply each update to the writer
            for (set_updates.items) |update| {
                switch (update.resource) {
                    .buffer => |buffer| {
                        const buffer_info = vk.DescriptorBufferInfo{
                            .buffer = buffer.buffer,
                            .offset = buffer.offset,
                            .range = buffer.range,
                        };
                        _ = writer.writeBuffer(update.binding, @constCast(&buffer_info));
                    },
                    .image => |image| {
                        const image_info = vk.DescriptorImageInfo{
                            .sampler = image.sampler,
                            .image_view = image.image_view,
                            .image_layout = image.layout,
                        };
                        _ = writer.writeImage(update.binding, @constCast(&image_info));
                    },
                    .acceleration_structure => |accel_struct| {
                        const accel_info = vk.WriteDescriptorSetAccelerationStructureKHR{
                            .acceleration_structure_count = 1,
                            .p_acceleration_structures = @ptrCast(&accel_struct),
                        };
                        _ = writer.writeAccelerationStructure(update.binding, @constCast(&accel_info));
                    },
                }
            }

            // Build and apply the updates to the descriptor set
            const descriptor_set = descriptor_sets[frame_index];
            writer.update(descriptor_set);
        }
    }

    fn calculatePipelineHash(self: *Self, config: PipelineConfig) u64 {
        // TODO: Calculate a hash from the pipeline configuration
        _ = self;
        _ = config;
        return 0;
    }
};

/// Pipeline configuration for creation
pub const PipelineConfig = struct {
    name: []const u8,

    // Shader configuration
    vertex_shader: ?[]const u8 = null,
    fragment_shader: ?[]const u8 = null,
    geometry_shader: ?[]const u8 = null,
    compute_shader: ?[]const u8 = null,

    vertex_entry_point: ?[]const u8 = null,
    fragment_entry_point: ?[]const u8 = null,
    geometry_entry_point: ?[]const u8 = null,
    compute_entry_point: ?[]const u8 = null,

    shader_options: @import("../assets/shader_compiler.zig").CompilationOptions = .{ .target = .vulkan },

    // Vertex input configuration
    vertex_input_bindings: ?[]const @import("pipeline_builder.zig").VertexInputBinding = null,
    vertex_input_attributes: ?[]const @import("pipeline_builder.zig").VertexInputAttribute = null,

    // Pipeline state
    topology: vk.PrimitiveTopology = .triangle_list,
    polygon_mode: vk.PolygonMode = .fill,
    cull_mode: vk.CullModeFlags = .{ .back_bit = true },
    front_face: vk.FrontFace = .counter_clockwise,
    multisample_state: ?vk.PipelineMultisampleStateCreateInfo = null,

    // Push constants
    push_constant_ranges: ?[]const vk.PushConstantRange = null,

    // Render pass
    render_pass: vk.RenderPass,
    subpass: u32 = 0,
};

/// Unified pipeline representation
const Pipeline = struct {
    vulkan_pipeline: vk.Pipeline,
    pipeline_layout: vk.PipelineLayout,
    descriptor_layout_info: DescriptorLayoutInfo,
    descriptor_pools: std.ArrayList(*DescriptorPool),
    descriptor_layouts: std.ArrayList(*DescriptorSetLayout),
    descriptor_sets: std.ArrayList([]vk.DescriptorSet), // [set_index][frame_index]
    shaders: []*Shader,
    config: PipelineConfig,
    is_compute: bool,

    fn deinit(self: *Pipeline, graphics_context: *GraphicsContext, allocator: std.mem.Allocator) void {
        // Clean up Vulkan objects
        graphics_context.vkd.destroyPipeline(graphics_context.dev, self.vulkan_pipeline, null);
        graphics_context.vkd.destroyPipelineLayout(graphics_context.dev, self.pipeline_layout, null);

        // Clean up descriptor resources using proper builders
        for (self.descriptor_pools.items) |pool| {
            pool.deinit();
            allocator.destroy(pool);
        }
        for (self.descriptor_layouts.items) |layout| {
            layout.deinit();
            allocator.destroy(layout);
        }
        for (self.descriptor_sets.items) |sets| {
            allocator.free(sets);
        }

        for (self.shaders) |shader| {
            shader.deinit(graphics_context.*);
            allocator.destroy(shader);
        }

        self.descriptor_pools.deinit(allocator);
        self.descriptor_layouts.deinit(allocator);
        self.descriptor_sets.deinit(allocator);
    }
};

/// Pipeline identifier
pub const PipelineId = struct {
    name: []const u8,
    hash: u64,
};

/// Shader module representation
/// Descriptor layout information extracted from shaders
const DescriptorLayoutInfo = struct {
    sets: std.ArrayList([]const vk.DescriptorSetLayoutBinding),
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) DescriptorLayoutInfo {
        return DescriptorLayoutInfo{
            .sets = std.ArrayList([]const vk.DescriptorSetLayoutBinding){},
            .allocator = allocator,
        };
    }

    fn deinit(self: *DescriptorLayoutInfo) void {
        for (self.sets.items) |bindings| {
            self.allocator.free(bindings);
        }
        self.sets.deinit(self.allocator);
    }
};

/// Resource types that can be bound to descriptors
pub const Resource = union(enum) {
    buffer: struct {
        buffer: vk.Buffer,
        offset: vk.DeviceSize = 0,
        range: vk.DeviceSize = vk.WHOLE_SIZE,
    },
    image: struct {
        image_view: vk.ImageView,
        sampler: vk.Sampler,
        layout: vk.ImageLayout = .shader_read_only_optimal,
    },
    acceleration_structure: vk.AccelerationStructureKHR,
};

// Rebuild job allocated by scheduleRebuildByName
pub const RebuildJob = struct {
    pipeline_name: []const u8,
    allocator: std.mem.Allocator,
    system: *UnifiedPipelineSystem,
};

/// Resource binding key for tracking bound resources
const ResourceBindingKey = struct {
    pipeline_id: PipelineId,
    set: u32,
    binding: u32,
    frame_index: u32,
};

/// Bound resource state
const BoundResource = struct {
    resource: Resource,
    dirty: bool,
};

/// Descriptor update information
const DescriptorUpdate = struct {
    set: u32,
    binding: u32,
    resource: Resource,
};

// Context types for HashMap
const PipelineIdContext = struct {
    pub fn hash(self: @This(), key: PipelineId) u64 {
        _ = self;
        return key.hash;
    }

    pub fn eql(self: @This(), a: PipelineId, b: PipelineId) bool {
        _ = self;
        return std.mem.eql(u8, a.name, b.name);
    }
};

const ResourceBindingKeyContext = struct {
    pub fn hash(self: @This(), key: ResourceBindingKey) u64 {
        _ = self;
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&key.pipeline_id.hash));
        hasher.update(std.mem.asBytes(&key.set));
        hasher.update(std.mem.asBytes(&key.binding));
        hasher.update(std.mem.asBytes(&key.frame_index));
        return hasher.final();
    }

    pub fn eql(self: @This(), a: ResourceBindingKey, b: ResourceBindingKey) bool {
        _ = self;
        return std.mem.eql(u8, a.pipeline_id.name, b.pipeline_id.name) and
            a.set == b.set and
            a.binding == b.binding and
            a.frame_index == b.frame_index;
    }
};
