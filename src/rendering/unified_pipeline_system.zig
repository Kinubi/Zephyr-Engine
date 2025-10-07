const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("../core/graphics_context.zig").GraphicsContext;
const ShaderManager = @import("../assets/shader_manager.zig").ShaderManager;
const PipelineBuilder = @import("pipeline_builder.zig").PipelineBuilder;
const RasterizationState = @import("pipeline_builder.zig").RasterizationState;
const MultisampleState = @import("pipeline_builder.zig").MultisampleState;
const Shader = @import("../core/shader.zig").Shader;
const DescriptorPool = @import("../core/descriptors.zig").DescriptorPool;
const DescriptorSetLayout = @import("../core/descriptors.zig").DescriptorSetLayout;
const DescriptorWriter = @import("../core/descriptors.zig").DescriptorWriter;
const Buffer = @import("../core/buffer.zig").Buffer;
const MAX_FRAMES_IN_FLIGHT = @import("../core/swapchain.zig").MAX_FRAMES_IN_FLIGHT;
const log = @import("../utils/log.zig").log;

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
    pipeline_reload_callbacks: std.ArrayList(PipelineReloadCallback),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, graphics_context: *GraphicsContext, shader_manager: *ShaderManager) !Self {
        var system = Self{
            .allocator = allocator,
            .graphics_context = graphics_context,
            .shader_manager = shader_manager,
            .pipelines = std.HashMap(PipelineId, Pipeline, PipelineIdContext, std.hash_map.default_max_load_percentage).init(allocator),
            .descriptor_pools = std.HashMap(u32, *DescriptorPool, std.hash_map.AutoContext(u32), std.hash_map.default_max_load_percentage).init(allocator),
            .bound_resources = std.HashMap(ResourceBindingKey, BoundResource, ResourceBindingKeyContext, std.hash_map.default_max_load_percentage).init(allocator),
            .pipeline_reload_callbacks = std.ArrayList(PipelineReloadCallback){},
        };

        // Register with shader manager for hot-reload notifications
        try system.registerForShaderReload();

        return system;
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
        self.pipeline_reload_callbacks.deinit(self.allocator);
    }

    /// Create a unified pipeline with automatic descriptor layout extraction
    pub fn createPipeline(
        self: *Self,
        config: PipelineConfig,
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
            std.log.info("[unified_pipeline] Debug: Loading COMPUTE shader: {s}", .{compute_path});
            const compiled_shader = try self.shader_manager.loadShader(compute_path, config.shader_options);
            const shader = try self.allocator.create(Shader);
            shader.* = try Shader.create(self.graphics_context.*, compiled_shader.compiled_shader.spirv_code, .{ .compute_bit = true }, null);
            try shaders.append(self.allocator, shader);
            std.log.info("[unified_pipeline] Debug: Added compute shader at index {}", .{shaders.items.len - 1});

            // Extract descriptor layout from shader reflection
            try self.extractDescriptorLayout(&descriptor_layout_info, compiled_shader.compiled_shader.reflection, .{ .compute_bit = true });
        } // Load vertex shader
        if (config.vertex_shader) |vertex_path| {
            std.log.info("[unified_pipeline] Debug: Loading VERTEX shader: {s}", .{vertex_path});
            const compiled_shader = try self.shader_manager.loadShader(vertex_path, config.shader_options);
            const shader = try self.allocator.create(Shader);
            shader.* = try Shader.create(self.graphics_context.*, compiled_shader.compiled_shader.spirv_code, .{ .vertex_bit = true }, null);
            std.log.info("[unified_pipeline] Debug: Created vertex shader object: ptr={*}, module={any}, vertex_bit={}, fragment_bit={}", .{ shader, shader.module, shader.shader_type.vertex_bit, shader.shader_type.fragment_bit });
            try shaders.append(self.allocator, shader);
            std.log.info("[unified_pipeline] Debug: Added vertex shader at index {}", .{shaders.items.len - 1});

            // Extract descriptor layout from shader reflection
            try self.extractDescriptorLayout(&descriptor_layout_info, compiled_shader.compiled_shader.reflection, .{ .vertex_bit = true });
        }

        // Load fragment shader
        if (config.fragment_shader) |fragment_path| {
            std.log.info("[unified_pipeline] Debug: Loading FRAGMENT shader: {s}", .{fragment_path});
            const compiled_shader = try self.shader_manager.loadShader(fragment_path, config.shader_options);
            const shader = try self.allocator.create(Shader);
            shader.* = try Shader.create(self.graphics_context.*, compiled_shader.compiled_shader.spirv_code, .{ .fragment_bit = true }, null);
            std.log.info("[unified_pipeline] Debug: Created fragment shader object: ptr={*}, module={any}, vertex_bit={}, fragment_bit={}", .{ shader, shader.module, shader.shader_type.vertex_bit, shader.shader_type.fragment_bit });
            try shaders.append(self.allocator, shader);
            std.log.info("[unified_pipeline] Debug: Added fragment shader at index {}", .{shaders.items.len - 1});

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
            std.log.info("[unified_pipeline] Debug: Processing {} shaders for graphics pipeline", .{shaders.items.len});
            for (shaders.items, 0..) |shader, i| {
                std.log.info("[unified_pipeline] Debug: Shader {}: vertex_bit={}, fragment_bit={}, compute_bit={}", .{ i, shader.shader_type.vertex_bit, shader.shader_type.fragment_bit, shader.shader_type.compute_bit });
                if (shader.shader_type.vertex_bit and !shader.shader_type.compute_bit) {
                    std.log.info("[unified_pipeline] Debug: Adding shader {} as VERTEX stage", .{i});
                    _ = try builder.addShaderStage(shader.shader_type, shader);
                }
            }
            for (shaders.items, 0..) |shader, i| {
                if (shader.shader_type.fragment_bit and !shader.shader_type.compute_bit) {
                    std.log.info("[unified_pipeline] Debug: Adding shader {} as FRAGMENT stage", .{i});
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

        // Generate pipeline ID and store
        const pipeline_id = PipelineId{
            .name = try self.allocator.dupe(u8, config.name),
            .hash = self.calculatePipelineHash(config),
        };

        try self.pipelines.put(pipeline_id, pipeline);

        log(.INFO, "unified_pipeline", "✅ Created pipeline: {s} (hash: {})", .{ config.name, pipeline_id.hash });

        return pipeline_id;
    }

    /// Bind a pipeline for rendering
    pub fn bindPipeline(self: *Self, command_buffer: vk.CommandBuffer, pipeline_id: PipelineId) !void {
        const pipeline = self.pipelines.get(pipeline_id) orelse return error.PipelineNotFound;

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
        std.log.info("Marked all resources for pipeline {s} as dirty", .{pipeline_id.name});
    }

    /// Update all dirty descriptor sets
    pub fn updateDescriptorSets(self: *Self, frame_index: u32) !void {

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

    /// Register a callback for pipeline reloads
    pub fn registerPipelineReloadCallback(self: *Self, callback: PipelineReloadCallback) !void {
        try self.pipeline_reload_callbacks.append(self.allocator, callback);
    }

    // Private implementation methods

    fn registerForShaderReload(self: *Self) !void {
        _ = self; // TODO: Integrate with shader manager hot-reload system
        // This would register a callback that gets called when shaders change
        // The callback would trigger pipeline recreation
    }

    fn extractDescriptorLayout(
        self: *Self,
        layout_info: *DescriptorLayoutInfo,
        reflection: anytype,
        stage_flags: vk.ShaderStageFlags,
    ) !void {
        // TODO: Implement SPIR-V reflection to extract descriptor bindings
        // For now, hardcode layouts for known shaders
        _ = reflection;

        // Hardcoded layout for particle compute shader
        if (stage_flags.compute_bit) {
            // Set 0: Uniform buffer (binding 0), Storage buffer (binding 1), Storage buffer (binding 2)
            const set0_bindings = [_]vk.DescriptorSetLayoutBinding{
                vk.DescriptorSetLayoutBinding{
                    .binding = 0,
                    .descriptor_type = .uniform_buffer,
                    .descriptor_count = 1,
                    .stage_flags = .{ .compute_bit = true },
                    .p_immutable_samplers = null,
                },
                vk.DescriptorSetLayoutBinding{
                    .binding = 1,
                    .descriptor_type = .storage_buffer,
                    .descriptor_count = 1,
                    .stage_flags = .{ .compute_bit = true },
                    .p_immutable_samplers = null,
                },
                vk.DescriptorSetLayoutBinding{
                    .binding = 2,
                    .descriptor_type = .storage_buffer,
                    .descriptor_count = 1,
                    .stage_flags = .{ .compute_bit = true },
                    .p_immutable_samplers = null,
                },
            };

            try layout_info.sets.append(self.allocator, try self.allocator.dupe(vk.DescriptorSetLayoutBinding, &set0_bindings));
        }

        // This would analyze the shader reflection data and populate layout_info
        // with the descriptor bindings found in the shader
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

        std.log.info("createDescriptorSets: Creating descriptor sets for {} sets", .{layout_info.sets.items.len});

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
        for (layout_info.sets.items, 0..) |set_bindings, set_index| {
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

            std.log.info("createDescriptorSets: Created descriptor set {} with {} frames", .{ set_index, MAX_FRAMES_IN_FLIGHT });
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

            std.log.info("Applied {} descriptor updates to set {} for pipeline {s} frame {}", .{ set_updates.items.len, set_index, pipeline_id.name, frame_index });
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

/// Pipeline reload callback
pub const PipelineReloadCallback = struct {
    context: *anyopaque,
    onPipelineReloaded: *const fn (context: *anyopaque, pipeline_id: PipelineId) void,
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
