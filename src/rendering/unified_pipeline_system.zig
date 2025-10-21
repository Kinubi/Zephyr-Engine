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
const DepthStencilState = @import("pipeline_builder.zig").DepthStencilState;
const ColorBlendAttachment = @import("pipeline_builder.zig").ColorBlendAttachment;
const VertexInputBinding = @import("pipeline_builder.zig").VertexInputBinding;
const VertexInputAttribute = @import("pipeline_builder.zig").VertexInputAttribute;
const Shader = @import("../core/shader.zig").Shader;
const entry_point_definition = @import("../core/shader.zig").entry_point_definition;
const ShaderCompiler = @import("../assets/shader_compiler.zig");
const DescriptorPool = @import("../core/descriptors.zig").DescriptorPool;
const DescriptorSetLayout = @import("../core/descriptors.zig").DescriptorSetLayout;
const DescriptorWriter = @import("../core/descriptors.zig").DescriptorWriter;
const Buffer = @import("../core/buffer.zig").Buffer;
const MAX_FRAMES_IN_FLIGHT = @import("../core/swapchain.zig").MAX_FRAMES_IN_FLIGHT;
const log = @import("../utils/log.zig").log;
const DescriptorUtils = @import("../utils/descriptor_utils.zig");
const math = std.math;

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

    // Descriptor update tracking - signals when descriptors have been updated for each frame
    descriptor_update_signals: [MAX_FRAMES_IN_FLIGHT]bool = [_]bool{false} ** MAX_FRAMES_IN_FLIGHT,

    // Hot-reload integration
    // Flag to skip descriptor updates during hot reload
    hot_reload_in_progress: bool = false,
    // Flag to prevent recursive shader reload
    rebuilding_pipelines: bool = false,
    shader_to_pipelines: std.HashMap([]const u8, std.ArrayList(PipelineId), std.hash_map.StringContext, std.hash_map.default_max_load_percentage), // shader_path -> pipeline_ids

    // Deferred destruction for hot reload safety
    deferred_destroys: std.ArrayList(DeferredPipeline),

    // Vulkan pipeline cache for faster pipeline creation
    vulkan_pipeline_cache: vk.PipelineCache,
    binding_overrides: std.AutoHashMap(u64, BindingOverrideMap),

    pub fn init(allocator: std.mem.Allocator, graphics_context: *GraphicsContext, shader_manager: *ShaderManager) !UnifiedPipelineSystem {
        // Try to load existing pipeline cache
        var cache_data: ?[]u8 = null;
        errdefer if (cache_data) |data| allocator.free(data);

        const cache_path = "cache/unified_pipeline_cache.bin";

        // Attempt to load cache from disk
        if (std.fs.cwd().openFile(cache_path, .{})) |file| {
            defer file.close();
            cache_data = blk: {
                const result = file.readToEndAlloc(allocator, 100 * 1024 * 1024) catch |err| {
                    log(.WARN, "unified_pipeline", "Failed to read cache file: {}", .{err});
                    break :blk null;
                };
                break :blk result;
            };

            if (cache_data) |data| {
                log(.INFO, "unified_pipeline", "✅ Loaded pipeline cache from disk ({} bytes)", .{data.len});
            }
        } else |_| {
            log(.INFO, "unified_pipeline", "No existing pipeline cache found, creating new cache", .{});
        }

        // Create Vulkan pipeline cache
        const cache_create_info = vk.PipelineCacheCreateInfo{
            .initial_data_size = if (cache_data) |data| data.len else 0,
            .p_initial_data = if (cache_data) |data| data.ptr else null,
        };

        const vulkan_cache = try graphics_context.vkd.createPipelineCache(graphics_context.dev, &cache_create_info, null);

        // Free cache_data after creating Vulkan cache
        if (cache_data) |data| allocator.free(data);

        const self = UnifiedPipelineSystem{
            .allocator = allocator,
            .graphics_context = graphics_context,
            .shader_manager = shader_manager,
            .pipelines = std.HashMap(PipelineId, Pipeline, PipelineIdContext, std.hash_map.default_max_load_percentage).init(allocator),
            .descriptor_pools = std.HashMap(u32, *DescriptorPool, std.hash_map.AutoContext(u32), std.hash_map.default_max_load_percentage).init(allocator),
            .bound_resources = std.HashMap(ResourceBindingKey, BoundResource, ResourceBindingKeyContext, std.hash_map.default_max_load_percentage).init(allocator),
            .shader_to_pipelines = std.HashMap([]const u8, std.ArrayList(PipelineId), std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
            .deferred_destroys = .{},
            .vulkan_pipeline_cache = vulkan_cache,
            .binding_overrides = std.AutoHashMap(u64, BindingOverrideMap).init(allocator),
        };

        return self;
    }

    pub fn deinit(self: *UnifiedPipelineSystem) void {
        // Save pipeline cache to disk before cleaning up
        self.savePipelineCacheToDisk() catch |err| {
            log(.WARN, "unified_pipeline", "Failed to save pipeline cache: {any}", .{err});
        };

        // Destroy Vulkan pipeline cache
        self.graphics_context.vkd.destroyPipelineCache(self.graphics_context.dev, self.vulkan_pipeline_cache, null);

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

        var overrides_iter = self.binding_overrides.valueIterator();
        while (overrides_iter.next()) |override_map| {
            override_map.deinit();
        }
        self.binding_overrides.deinit();
    }

    /// Create a unified pipeline with automatic descriptor layout extraction
    pub fn createPipeline(
        self: *UnifiedPipelineSystem,
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
        self: *UnifiedPipelineSystem,
        config: PipelineConfig,
        pipeline_id: PipelineId,
    ) !PipelineId {
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
        errdefer descriptor_layout_info.deinit();

        const is_raytracing_pipeline = config.raygen_shader != null;
        const is_compute_pipeline = (config.compute_shader != null) and !is_raytracing_pipeline;

        // Track shader indices for raytracing groups
        var raygen_stage_index: ?u32 = null;
        var miss_stage_index: ?u32 = null;
        var closest_hit_stage_index: ?u32 = null;
        var any_hit_stage_index: ?u32 = null;
        var intersection_stage_index: ?u32 = null;

        if (is_raytracing_pipeline) {
            if (config.raygen_shader) |raygen_path| {
                const compiled_shader = try self.shader_manager.loadShader(raygen_path, config.shader_options);
                const shader = try self.allocator.create(Shader);
                const entry_point = if (config.raygen_entry_point) |name| entry_point_definition{ .name = name } else null;
                shader.* = try Shader.create(self.graphics_context.*, compiled_shader.compiled_shader.spirv_code, .{ .raygen_bit_khr = true }, entry_point);
                try shaders.append(self.allocator, shader);
                raygen_stage_index = @as(u32, @intCast(shaders.items.len - 1));
                try self.extractDescriptorLayout(&descriptor_layout_info, compiled_shader.compiled_shader.reflection, .{ .raygen_bit_khr = true });
            }

            if (config.miss_shader) |miss_path| {
                const compiled_shader = try self.shader_manager.loadShader(miss_path, config.shader_options);
                const shader = try self.allocator.create(Shader);
                const entry_point = if (config.miss_entry_point) |name| entry_point_definition{ .name = name } else null;
                shader.* = try Shader.create(self.graphics_context.*, compiled_shader.compiled_shader.spirv_code, .{ .miss_bit_khr = true }, entry_point);
                try shaders.append(self.allocator, shader);
                miss_stage_index = @as(u32, @intCast(shaders.items.len - 1));
                try self.extractDescriptorLayout(&descriptor_layout_info, compiled_shader.compiled_shader.reflection, .{ .miss_bit_khr = true });
            }

            if (config.closest_hit_shader) |chit_path| {
                const compiled_shader = try self.shader_manager.loadShader(chit_path, config.shader_options);
                const shader = try self.allocator.create(Shader);
                const entry_point = if (config.closest_hit_entry_point) |name| entry_point_definition{ .name = name } else null;
                shader.* = try Shader.create(self.graphics_context.*, compiled_shader.compiled_shader.spirv_code, .{ .closest_hit_bit_khr = true }, entry_point);
                try shaders.append(self.allocator, shader);
                closest_hit_stage_index = @as(u32, @intCast(shaders.items.len - 1));
                try self.extractDescriptorLayout(&descriptor_layout_info, compiled_shader.compiled_shader.reflection, .{ .closest_hit_bit_khr = true });
            }

            if (config.any_hit_shader) |ahit_path| {
                const compiled_shader = try self.shader_manager.loadShader(ahit_path, config.shader_options);
                const shader = try self.allocator.create(Shader);
                const entry_point = if (config.any_hit_entry_point) |name| entry_point_definition{ .name = name } else null;
                shader.* = try Shader.create(self.graphics_context.*, compiled_shader.compiled_shader.spirv_code, .{ .any_hit_bit_khr = true }, entry_point);
                try shaders.append(self.allocator, shader);
                any_hit_stage_index = @as(u32, @intCast(shaders.items.len - 1));
                try self.extractDescriptorLayout(&descriptor_layout_info, compiled_shader.compiled_shader.reflection, .{ .any_hit_bit_khr = true });
            }

            if (config.intersection_shader) |intersection_path| {
                const compiled_shader = try self.shader_manager.loadShader(intersection_path, config.shader_options);
                const shader = try self.allocator.create(Shader);
                const entry_point = if (config.intersection_entry_point) |name| entry_point_definition{ .name = name } else null;
                shader.* = try Shader.create(self.graphics_context.*, compiled_shader.compiled_shader.spirv_code, .{ .intersection_bit_khr = true }, entry_point);
                try shaders.append(self.allocator, shader);
                intersection_stage_index = @as(u32, @intCast(shaders.items.len - 1));
                try self.extractDescriptorLayout(&descriptor_layout_info, compiled_shader.compiled_shader.reflection, .{ .intersection_bit_khr = true });
            }
        } else {
            if (is_compute_pipeline) {
                if (config.compute_shader) |compute_path| {
                    const compiled_shader = try self.shader_manager.loadShader(compute_path, config.shader_options);
                    const shader = try self.allocator.create(Shader);
                    shader.* = try Shader.create(self.graphics_context.*, compiled_shader.compiled_shader.spirv_code, .{ .compute_bit = true }, null);
                    try shaders.append(self.allocator, shader);
                    try self.extractDescriptorLayout(&descriptor_layout_info, compiled_shader.compiled_shader.reflection, .{ .compute_bit = true });
                }
            } else {
                if (config.vertex_shader) |vertex_path| {
                    const compiled_shader = try self.shader_manager.loadShader(vertex_path, config.shader_options);
                    const shader = try self.allocator.create(Shader);
                    shader.* = try Shader.create(self.graphics_context.*, compiled_shader.compiled_shader.spirv_code, .{ .vertex_bit = true }, null);
                    try shaders.append(self.allocator, shader);
                    try self.extractDescriptorLayout(&descriptor_layout_info, compiled_shader.compiled_shader.reflection, .{ .vertex_bit = true });
                }

                if (config.fragment_shader) |fragment_path| {
                    const compiled_shader = try self.shader_manager.loadShader(fragment_path, config.shader_options);
                    const shader = try self.allocator.create(Shader);
                    shader.* = try Shader.create(self.graphics_context.*, compiled_shader.compiled_shader.spirv_code, .{ .fragment_bit = true }, null);
                    try shaders.append(self.allocator, shader);
                    try self.extractDescriptorLayout(&descriptor_layout_info, compiled_shader.compiled_shader.reflection, .{ .fragment_bit = true });
                }
            }
        }

        self.applyBindingOverrides(&descriptor_layout_info, pipeline_id);

        // Create descriptor set layouts from extracted information
        const descriptor_set_layouts = try self.createDescriptorSetLayouts(&descriptor_layout_info);
        var descriptor_layouts_owned = false;
        defer if (!descriptor_layouts_owned) {
            self.destroyDescriptorSetLayouts(descriptor_set_layouts);
            self.allocator.free(descriptor_set_layouts);
        };

        // Create pipeline layout
        const pipeline_layout = try self.createPipelineLayout(descriptor_set_layouts, config.push_constant_ranges);

        var vulkan_pipeline: vk.Pipeline = undefined;

        if (is_raytracing_pipeline) {
            if (raygen_stage_index == null or miss_stage_index == null or closest_hit_stage_index == null) {
                return error.InvalidPipelineConfig;
            }

            var stage_infos = std.ArrayList(vk.PipelineShaderStageCreateInfo){};
            defer stage_infos.deinit(self.allocator);

            for (shaders.items) |shader| {
                try stage_infos.append(self.allocator, vk.PipelineShaderStageCreateInfo{
                    .flags = .{},
                    .stage = shader.shader_type,
                    .module = shader.module,
                    .p_name = @ptrCast(shader.entry_point.name.ptr),
                    .p_specialization_info = null,
                });
            }

            var group_infos = std.ArrayList(vk.RayTracingShaderGroupCreateInfoKHR){};
            defer group_infos.deinit(self.allocator);

            const raygen_idx = raygen_stage_index.?;
            const miss_idx = miss_stage_index.?;
            const closest_hit_idx = closest_hit_stage_index.?;

            try group_infos.append(self.allocator, vk.RayTracingShaderGroupCreateInfoKHR{
                .s_type = vk.StructureType.ray_tracing_shader_group_create_info_khr,
                .p_next = null,
                .type = vk.RayTracingShaderGroupTypeKHR.general_khr,
                .general_shader = raygen_idx,
                .closest_hit_shader = vk.SHADER_UNUSED_KHR,
                .any_hit_shader = vk.SHADER_UNUSED_KHR,
                .intersection_shader = vk.SHADER_UNUSED_KHR,
                .p_shader_group_capture_replay_handle = null,
            });

            try group_infos.append(self.allocator, vk.RayTracingShaderGroupCreateInfoKHR{
                .s_type = vk.StructureType.ray_tracing_shader_group_create_info_khr,
                .p_next = null,
                .type = vk.RayTracingShaderGroupTypeKHR.general_khr,
                .general_shader = miss_idx,
                .closest_hit_shader = vk.SHADER_UNUSED_KHR,
                .any_hit_shader = vk.SHADER_UNUSED_KHR,
                .intersection_shader = vk.SHADER_UNUSED_KHR,
                .p_shader_group_capture_replay_handle = null,
            });

            const hit_group_type: vk.RayTracingShaderGroupTypeKHR = if (intersection_stage_index != null)
                vk.RayTracingShaderGroupTypeKHR.procedural_hit_group_khr
            else
                vk.RayTracingShaderGroupTypeKHR.triangles_hit_group_khr;

            const any_hit_idx_value: u32 = if (any_hit_stage_index) |idx| idx else vk.SHADER_UNUSED_KHR;
            const intersection_idx_value: u32 = if (intersection_stage_index) |idx| idx else vk.SHADER_UNUSED_KHR;

            try group_infos.append(self.allocator, vk.RayTracingShaderGroupCreateInfoKHR{
                .s_type = vk.StructureType.ray_tracing_shader_group_create_info_khr,
                .p_next = null,
                .type = hit_group_type,
                .general_shader = vk.SHADER_UNUSED_KHR,
                .closest_hit_shader = closest_hit_idx,
                .any_hit_shader = any_hit_idx_value,
                .intersection_shader = intersection_idx_value,
                .p_shader_group_capture_replay_handle = null,
            });

            var pipeline_ci = vk.RayTracingPipelineCreateInfoKHR{
                .s_type = vk.StructureType.ray_tracing_pipeline_create_info_khr,
                .p_next = null,
                .flags = config.raytracing_flags,
                .stage_count = @intCast(stage_infos.items.len),
                .p_stages = stage_infos.items.ptr,
                .group_count = @intCast(group_infos.items.len),
                .p_groups = group_infos.items.ptr,
                .max_pipeline_ray_recursion_depth = @max(1, config.raytracing_max_recursion_depth),
                .layout = pipeline_layout,
                .base_pipeline_handle = vk.Pipeline.null_handle,
                .base_pipeline_index = -1,
                .p_library_info = null,
                .p_library_interface = null,
                .p_dynamic_state = null,
            };

            var pipeline_handle: vk.Pipeline = undefined;
            _ = try self.graphics_context.vkd.createRayTracingPipelinesKHR(
                self.graphics_context.dev,
                vk.DeferredOperationKHR.null_handle,
                self.vulkan_pipeline_cache,
                1,
                @as([*]const vk.RayTracingPipelineCreateInfoKHR, @ptrCast(&pipeline_ci)),
                null,
                @as([*]vk.Pipeline, @ptrCast(&pipeline_handle)),
            );

            vulkan_pipeline = pipeline_handle;
        } else if (is_compute_pipeline) {
            var builder = PipelineBuilder.init(self.allocator, self.graphics_context);
            defer builder.deinit();
            _ = builder.setPipelineCache(self.vulkan_pipeline_cache);
            _ = builder.compute();

            for (shaders.items) |shader| {
                if (shader.shader_type.compute_bit) {
                    _ = try builder.computeShader(shader);
                    break;
                }
            }

            vulkan_pipeline = try builder.buildComputePipeline(pipeline_layout);
        } else {
            var builder = PipelineBuilder.init(self.allocator, self.graphics_context);
            defer builder.deinit();
            _ = builder.setPipelineCache(self.vulkan_pipeline_cache);

            _ = try builder.dynamicViewportScissor();
            if (config.color_blend_attachment) |attachment| {
                _ = try builder.addColorBlendAttachment(attachment);
            } else {
                _ = try builder.addColorBlendAttachment(ColorBlendAttachment.disabled());
            }

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

            switch (config.topology) {
                .triangle_list => _ = builder.triangleList(),
                .triangle_strip => _ = builder.triangleStrip(),
                .line_list => _ = builder.lineList(),
                .point_list => _ = builder.pointList(),
                else => _ = builder.triangleList(),
            }

            var raster_state = RasterizationState.default();
            raster_state.polygon_mode = config.polygon_mode;
            raster_state.cull_mode = config.cull_mode;
            raster_state.front_face = config.front_face;
            _ = builder.withRasterizationState(raster_state);

            if (config.depth_stencil_state) |depth_state| {
                _ = builder.withDepthStencilState(depth_state);
            }

            if (config.multisample_state) |ms_state| {
                _ = builder.withMultisampleState(MultisampleState{ .rasterization_samples = ms_state.rasterization_samples });
            }

            // Use dynamic rendering if no render pass specified
            if (config.render_pass == .null_handle) {
                // Use provided formats or fall back to defaults
                const color_formats = config.dynamic_rendering_color_formats orelse &[_]vk.Format{.r16g16b16a16_sfloat};
                const depth_format = config.dynamic_rendering_depth_format orelse .d32_sfloat_s8_uint;
                _ = builder.withDynamicRendering(color_formats, depth_format);
            } else {
                _ = builder.withRenderPass(config.render_pass, config.subpass);
            }

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

            vulkan_pipeline = try builder.buildGraphicsPipeline(pipeline_layout);
        }

        // Create descriptor pools and sets
        const descriptor_resources = try self.createDescriptorSets(&descriptor_layout_info, descriptor_set_layouts);

        // Transfer ownership of shaders to the pipeline (don't free them in defer)
        const owned_shaders = try shaders.toOwnedSlice(self.allocator);
        shaders_transferred = true; // Mark as transferred so defer won't clean them up

        // Deep copy the config to ensure dynamic rendering formats outlive the original
        var owned_config = config;
        if (config.dynamic_rendering_color_formats) |formats| {
            const formats_copy = try self.allocator.alloc(vk.Format, formats.len);
            @memcpy(formats_copy, formats);
            owned_config.dynamic_rendering_color_formats = formats_copy;
        }

        // Create unified pipeline object
        const pipeline = Pipeline{
            .vulkan_pipeline = vulkan_pipeline,
            .pipeline_layout = pipeline_layout,
            .pipeline_set_layout_handles = descriptor_set_layouts,
            .descriptor_layout_info = descriptor_layout_info,
            .descriptor_pools = descriptor_resources.pools,
            .descriptor_layouts = descriptor_resources.layouts,
            .descriptor_sets = descriptor_resources.sets,
            .shaders = owned_shaders,
            .config = owned_config,
            .is_compute = is_compute_pipeline,
            .is_raytracing = is_raytracing_pipeline,
        };

        // Use the provided pipeline ID
        var pipeline_inserted = false;
        errdefer if (pipeline_inserted) {
            if (self.pipelines.fetchRemove(pipeline_id)) |removed| {
                var removed_pipeline = removed.value;
                removed_pipeline.deinit(self.graphics_context, self.allocator);
            }
        };

        try self.pipelines.put(pipeline_id, pipeline);
        pipeline_inserted = true;
        descriptor_layouts_owned = true;

        // Track shader dependencies for hot-reload
        try self.registerShaderDependency(config.compute_shader, pipeline_id);
        try self.registerShaderDependency(config.vertex_shader, pipeline_id);
        try self.registerShaderDependency(config.fragment_shader, pipeline_id);
        try self.registerShaderDependency(config.raygen_shader, pipeline_id);
        try self.registerShaderDependency(config.miss_shader, pipeline_id);
        try self.registerShaderDependency(config.closest_hit_shader, pipeline_id);
        try self.registerShaderDependency(config.any_hit_shader, pipeline_id);
        try self.registerShaderDependency(config.intersection_shader, pipeline_id);

        return pipeline_id;
    }

    /// Bind a pipeline for rendering
    pub fn bindPipeline(self: *UnifiedPipelineSystem, command_buffer: vk.CommandBuffer, pipeline_id: PipelineId) !void {
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
        const bind_point: vk.PipelineBindPoint = if (pipeline.is_raytracing)
            .ray_tracing_khr
        else if (pipeline.is_compute)
            .compute
        else
            .graphics;
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
    pub fn getPipelineLayout(self: *UnifiedPipelineSystem, pipeline_id: PipelineId) !vk.PipelineLayout {
        const pipeline = self.pipelines.get(pipeline_id) orelse return error.PipelineNotFound;
        return pipeline.pipeline_layout;
    }

    /// Bind a resource to a descriptor set
    pub fn bindResource(
        self: *UnifiedPipelineSystem,
        pipeline_id: PipelineId,
        set: u32,
        binding: u32,
        resource: Resource,
        frame_index: u32,
    ) !void {
        switch (resource) {
            .buffer_array => |buffer_infos| {
                if (buffer_infos.len > 0) {
                    try self.ensureDescriptorCapacity(pipeline_id, set, binding, buffer_infos.len);
                }
            },
            .image_array => |image_infos| {
                if (image_infos.len > 0) {
                    try self.ensureDescriptorCapacity(pipeline_id, set, binding, image_infos.len);
                }
            },
            else => {},
        }

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

    fn getBindingDescriptorCount(_: *UnifiedPipelineSystem, pipeline: *const Pipeline, set: u32, binding_index: u32) ?u32 {
        if (set >= pipeline.descriptor_layout_info.sets.items.len) return null;
        const bindings_slice = pipeline.descriptor_layout_info.sets.items[set];
        for (bindings_slice) |binding_info| {
            if (binding_info.binding == binding_index) {
                return binding_info.descriptor_count;
            }
        }
        return null;
    }

    fn ensureDescriptorCapacity(
        self: *UnifiedPipelineSystem,
        pipeline_id: PipelineId,
        set: u32,
        binding: u32,
        required_len: usize,
    ) !void {
        if (required_len == 0) return;

        const required_u32 = math.clamp(@as(u32, @intCast(required_len)), 1, MAX_DESCRIPTOR_BINDING_COUNT);
        const pipeline_ptr = self.pipelines.getPtr(pipeline_id) orelse return error.PipelineNotFound;

        const current_count: u32 = self.getBindingDescriptorCount(pipeline_ptr, set, binding) orelse 0;
        var existing_override: u32 = current_count;

        if (self.binding_overrides.get(pipeline_id.hash)) |override_map| {
            if (override_map.get(BindingKey{ .set = set, .binding = binding })) |override_value| {
                existing_override = @max(existing_override, override_value);
            }
        }

        const current_capacity = if (existing_override > 0) existing_override else current_count;
        const target = math.clamp(@max(required_u32, 1), 1, MAX_DESCRIPTOR_BINDING_COUNT);

        if (target == current_capacity) return;

        const overrides_entry = try self.binding_overrides.getOrPut(pipeline_id.hash);
        if (!overrides_entry.found_existing) {
            overrides_entry.value_ptr.* = BindingOverrideMap.init(self.allocator);
        }

        const map_ptr = overrides_entry.value_ptr;
        const binding_key = BindingKey{ .set = set, .binding = binding };
        const override_entry = try map_ptr.getOrPut(binding_key);
        override_entry.value_ptr.* = target;

        try self.rebuildPipeline(pipeline_id);
        self.markPipelineResourcesDirty(pipeline_id);
        try self.forceUpdateAllFrames(pipeline_id);
    }

    fn forceUpdateAllFrames(self: *UnifiedPipelineSystem, pipeline_id: PipelineId) !void {
        var frame_index: u32 = 0;
        while (frame_index < MAX_FRAMES_IN_FLIGHT) : (frame_index += 1) {
            self.descriptor_update_signals[frame_index] = false;
            try self.updateDescriptorSetsForPipeline(pipeline_id, frame_index);
        }
    }

    fn applyBindingOverrides(self: *UnifiedPipelineSystem, layout_info: *DescriptorLayoutInfo, pipeline_id: PipelineId) void {
        if (self.binding_overrides.get(pipeline_id.hash)) |override_map| {
            var iter = override_map.iterator();
            while (iter.next()) |entry| {
                const key = entry.key_ptr.*;
                const desired_count = entry.value_ptr.*;
                if (key.set >= layout_info.sets.items.len) continue;
                if (layout_info.sets.items[key.set].len == 0) continue;

                const bindings_slice = @constCast(layout_info.sets.items[key.set]);
                for (bindings_slice) |*binding_info| {
                    if (binding_info.binding == key.binding) {
                        binding_info.descriptor_count = desired_count;
                        break;
                    }
                }
            }
        }
    }

    /// Check if descriptors have been updated for a specific frame
    pub fn areDescriptorsUpdated(self: *UnifiedPipelineSystem, frame_index: u32) bool {
        return self.descriptor_update_signals[frame_index];
    }

    /// Mark all bound resources for a pipeline as dirty (useful after pipeline recreation)
    pub fn markPipelineResourcesDirty(self: *UnifiedPipelineSystem, pipeline_id: PipelineId) void {
        var resource_iter = self.bound_resources.iterator();
        while (resource_iter.next()) |entry| {
            const key = entry.key_ptr.*;
            if (std.mem.eql(u8, key.pipeline_id.name, pipeline_id.name)) {
                entry.value_ptr.dirty = true;
            }
        }
    }

    /// Update all dirty descriptor sets
    /// Update descriptors for a specific pipeline only
    pub fn updateDescriptorSetsForPipeline(self: *UnifiedPipelineSystem, pipeline_id: PipelineId, frame_index: u32) !void {
        if (self.hot_reload_in_progress) {
            return;
        }

        var updates = std.ArrayList(DescriptorUpdate){};
        defer updates.deinit(self.allocator);

        // Collect dirty bindings for this specific pipeline and frame
        var resource_iter = self.bound_resources.iterator();
        while (resource_iter.next()) |entry| {
            const key = entry.key_ptr.*;
            const bound_resource = entry.value_ptr.*;

            if (key.frame_index == frame_index and
                key.pipeline_id.hash == pipeline_id.hash and
                std.mem.eql(u8, key.pipeline_id.name, pipeline_id.name) and
                bound_resource.dirty)
            {
                const update = DescriptorUpdate{
                    .set = key.set,
                    .binding = key.binding,
                    .resource = bound_resource.resource,
                };

                try updates.append(self.allocator, update);
                entry.value_ptr.dirty = false;
            }
        }

        if (updates.items.len > 0) {
            try self.applyDescriptorUpdates(pipeline_id, updates.items, frame_index);
        }

        self.descriptor_update_signals[frame_index] = true;
    }

    /// Update descriptors for ALL pipelines (legacy method)
    pub fn updateDescriptorSets(self: *UnifiedPipelineSystem, frame_index: u32) !void {

        // Skip descriptor updates if hot reload is in progress to avoid validation errors
        if (self.hot_reload_in_progress) {
            log(.DEBUG, "unified_pipeline", "Skipping descriptor updates for frame {} (hot reload in progress)", .{frame_index});
            return;
        }

        log(.DEBUG, "unified_pipeline", "=== Starting descriptor update for frame {} ===", .{frame_index});

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

                log(.DEBUG, "unified_pipeline", "Found dirty resource: pipeline={s}, set={}, binding={}, frame={}", .{
                    key.pipeline_id.name,
                    key.set,
                    key.binding,
                    key.frame_index,
                });

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

        log(.DEBUG, "unified_pipeline", "Found {} dirty descriptors for frame {}", .{ dirty_count, frame_index });

        // Apply updates
        var update_count: u32 = 0;
        var update_iter = updates_by_pipeline.iterator();
        while (update_iter.next()) |entry| {
            const pipeline_id = entry.key_ptr.*;
            const updates = entry.value_ptr.*;

            log(.DEBUG, "unified_pipeline", "Applying {} updates to pipeline {s}", .{ updates.items.len, pipeline_id.name });

            try self.applyDescriptorUpdates(pipeline_id, updates.items, frame_index);
            update_count += 1;
        }

        // Signal that descriptors have been updated for this frame
        self.descriptor_update_signals[frame_index] = true;

        log(.DEBUG, "unified_pipeline", "=== Completed descriptor update for frame {}: {} pipelines, {} descriptors ===", .{ frame_index, update_count, dirty_count });
    }

    /// Manually rebuild a pipeline (useful for debugging or forced reloads)
    pub fn rebuildPipelineManual(self: *UnifiedPipelineSystem, pipeline_id: PipelineId) !void {
        try self.rebuildPipeline(pipeline_id);
    }

    // Private implementation methods

    fn registerShaderDependency(self: *UnifiedPipelineSystem, shader_path: ?[]const u8, pipeline_id: PipelineId) !void {
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
        const self = @as(*UnifiedPipelineSystem, @ptrCast(@alignCast(context.?)));
        self.handleShaderReload(shader_path) catch |err| {
            log(.ERROR, "unified_pipeline", "Failed to handle shader reload for {s}: {}", .{ shader_path, err });
        };
    }

    /// Schedule a pipeline rebuild by pipeline name. This submits a ThreadPool
    /// work item which will wait for any in-progress shader compilations for
    /// that pipeline to complete before calling rebuildPipeline.
    /// NOTE: This function is currently unused - pipeline rebuilds are triggered
    /// by shader compilation completion via ShaderRebuildJob.
    pub fn scheduleRebuildByName(self: *UnifiedPipelineSystem, pipeline_name: []const u8) !void {
        // Allocate a small RebuildJob on this system's allocator and submit
        // a custom WorkItem into the shader manager's thread pool.
        const name_copy = try self.allocator.dupe(u8, pipeline_name);
        const job = try self.allocator.create(UnifiedPipelineSystem.RebuildJob);
        job.* = UnifiedPipelineSystem.RebuildJob{ .pipeline_name = name_copy, .allocator = self.allocator, .system = self };

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

    pub fn handleShaderReload(self: *UnifiedPipelineSystem, shader_path: []const u8) !void {
        // Prevent recursive shader reload calls
        if (self.rebuilding_pipelines) {
            log(.WARN, "unified_pipeline", "Skipping shader reload for {s} - already rebuilding pipelines", .{shader_path});
            return;
        }

        // Set flag to prevent recursive calls
        self.rebuilding_pipelines = true;
        defer self.rebuilding_pipelines = false;

        // Find all pipelines that use this shader
        const affected_pipelines = self.shader_to_pipelines.get(shader_path) orelse return;

        log(
            .INFO,
            "unified_pipeline",
            "Shader reload detected for {s}; rebuilding {} pipelines",
            .{ shader_path, affected_pipelines.items.len },
        );

        // Rebuild each affected pipeline
        for (affected_pipelines.items) |pipeline_id| {
            log(.INFO, "unified_pipeline", "Rebuilding pipeline {s}", .{pipeline_id.name});
            self.rebuildPipeline(pipeline_id) catch |err| {
                log(.ERROR, "unified_pipeline", "Failed to rebuild pipeline {s}: {}", .{ pipeline_id.name, err });
                continue;
            };
            log(.INFO, "unified_pipeline", "Pipeline {s} rebuilt successfully", .{pipeline_id.name});
        }
    }

    fn rebuildPipeline(self: *UnifiedPipelineSystem, pipeline_id: PipelineId) !void {
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

        // Get reference to the old pipeline before we replace it
        const old_pipeline_to_destroy = self.pipelines.get(pipeline_id).?;

        // Remove shader dependencies for the old pipeline before creating new one
        try self.unregisterPipelineDependencies(pipeline_id);

        // Create the new pipeline - this will atomically replace the old one in the hashmap
        const new_pipeline_id = try self.createPipelineWithId(config, pipeline_id);
        _ = new_pipeline_id; // Should be the same as input

        // Schedule the old pipeline for destruction after a few frames
        // This ensures any in-flight command buffers finish using it
        const frames_to_wait: u32 = MAX_FRAMES_IN_FLIGHT + 1; // Wait for all frames in flight plus one more
        try self.deferred_destroys.append(self.allocator, DeferredPipeline{
            .pipeline = old_pipeline_to_destroy,
            .frames_to_wait = frames_to_wait,
        });
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
        const sys: *UnifiedPipelineSystem = @ptrCast(@alignCast(context));

        // Get the job from work_item.data (not from context!)
        const job: *UnifiedPipelineSystem.ShaderRebuildJob = @ptrCast(@alignCast(work_item.data.gpu_work.data));
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
    pub fn processDeferredDestroys(self: *UnifiedPipelineSystem) void {
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

    fn unregisterPipelineDependencies(self: *UnifiedPipelineSystem, pipeline_id: PipelineId) !void {
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
        self: *UnifiedPipelineSystem,
        layout_info: *DescriptorLayoutInfo,
        reflection: ShaderCompiler.ShaderReflection,
        stage_flags: vk.ShaderStageFlags,
    ) !void {
        // Build per-set lists by scanning existing layout_info and reflection
        var max_set_idx: u32 = 0;

        var idx: usize = 0;
        while (idx < layout_info.sets.items.len) : (idx += 1) {
            if (layout_info.sets.items[idx].len != 0) {
                const set_index = @as(u32, @intCast(idx));
                if (set_index > max_set_idx) max_set_idx = set_index;
            }
        }

        for (reflection.uniform_buffers.items) |ub| {
            if (ub.set > max_set_idx) max_set_idx = ub.set;
        }
        for (reflection.storage_buffers.items) |sb| {
            if (sb.set > max_set_idx) max_set_idx = sb.set;
        }
        for (reflection.textures.items) |tex| {
            if (tex.set > max_set_idx) max_set_idx = tex.set;
        }
        for (reflection.storage_images.items) |img| {
            if (img.set > max_set_idx) max_set_idx = img.set;
        }
        for (reflection.acceleration_structures.items) |accel| {
            if (accel.set > max_set_idx) max_set_idx = accel.set;
        }
        for (reflection.samplers.items) |samp| {
            if (samp.set > max_set_idx) max_set_idx = samp.set;
        }

        var per_set_lists = std.ArrayList(std.ArrayList(vk.DescriptorSetLayoutBinding)){};
        var set_i: usize = 0;
        while (set_i <= @as(usize, max_set_idx)) : (set_i += 1) {
            try per_set_lists.append(self.allocator, std.ArrayList(vk.DescriptorSetLayoutBinding){});
        }

        idx = 0;
        while (idx < layout_info.sets.items.len) : (idx += 1) {
            const bindings = layout_info.sets.items[idx];
            if (bindings.len == 0) continue;
            var list = per_set_lists.items[idx];
            for (bindings) |binding_info| {
                try list.append(self.allocator, binding_info);
            }
            per_set_lists.items[idx] = list;
        }

        for (reflection.uniform_buffers.items) |ub| {
            const set_idx = ub.set;
            var list = per_set_lists.items[@as(usize, set_idx)];
            const array_size = if (ub.array_size == 0) 0x10000 else ub.array_size;
            try DescriptorUtils.mergeDescriptorBinding(self.allocator, &list, ub.binding, .uniform_buffer, stage_flags, array_size);
            per_set_lists.items[@as(usize, set_idx)] = list;
        }

        for (reflection.storage_buffers.items) |sb| {
            const set_idx = sb.set;
            var list = per_set_lists.items[@as(usize, set_idx)];
            const array_size = if (sb.array_size == 0) 0x10000 else sb.array_size;
            try DescriptorUtils.mergeDescriptorBinding(self.allocator, &list, sb.binding, .storage_buffer, stage_flags, array_size);
            per_set_lists.items[@as(usize, set_idx)] = list;
        }

        for (reflection.textures.items) |tex| {
            const set_idx = tex.set;
            var list = per_set_lists.items[@as(usize, set_idx)];
            const array_size = if (tex.array_size == 0) 0x10000 else tex.array_size;
            try DescriptorUtils.mergeDescriptorBinding(self.allocator, &list, tex.binding, .combined_image_sampler, stage_flags, array_size);
            per_set_lists.items[@as(usize, set_idx)] = list;
        }

        for (reflection.storage_images.items) |img| {
            const set_idx = img.set;
            var list = per_set_lists.items[@as(usize, set_idx)];
            const array_size = if (img.array_size == 0) 0x10000 else img.array_size;
            try DescriptorUtils.mergeDescriptorBinding(self.allocator, &list, img.binding, .storage_image, stage_flags, array_size);
            per_set_lists.items[@as(usize, set_idx)] = list;
        }

        for (reflection.acceleration_structures.items) |accel| {
            const set_idx = accel.set;
            var list = per_set_lists.items[@as(usize, set_idx)];
            const array_size = if (accel.array_size == 0) 0x10000 else accel.array_size;
            try DescriptorUtils.mergeDescriptorBinding(self.allocator, &list, accel.binding, .acceleration_structure_khr, stage_flags, array_size);
            per_set_lists.items[@as(usize, set_idx)] = list;
        }

        // Skip separate samplers if the same binding already maps to a combined image sampler.
        for (reflection.samplers.items) |samp| {
            const set_idx = samp.set;
            var list = per_set_lists.items[@as(usize, set_idx)];

            var skip_sampler = false;
            var found_matching_binding = false;
            var existing_i: usize = 0;
            while (existing_i < list.items.len) : (existing_i += 1) {
                const existing = list.items[existing_i];
                if (existing.binding == samp.binding) {
                    found_matching_binding = true;

                    switch (existing.descriptor_type) {
                        .combined_image_sampler, .sampled_image => skip_sampler = true,
                        else => {},
                    }
                    if (skip_sampler) break;
                }
            }

            if (skip_sampler) {
                per_set_lists.items[@as(usize, set_idx)] = list;
                continue;
            }

            const array_size = if (samp.array_size == 0) 0x10000 else samp.array_size;
            try DescriptorUtils.mergeDescriptorBinding(self.allocator, &list, samp.binding, .sampler, stage_flags, array_size);
            per_set_lists.items[@as(usize, set_idx)] = list;
        }

        var idx_u: usize = 0;
        while (idx_u < per_set_lists.items.len) : (idx_u += 1) {
            var list_ptr = &per_set_lists.items[idx_u];
            if (list_ptr.items.len == 0) continue;
            const slice = try list_ptr.toOwnedSlice(self.allocator);
            if (layout_info.sets.items.len <= idx_u) {
                try layout_info.sets.append(self.allocator, &[_]vk.DescriptorSetLayoutBinding{});
            }
            if (layout_info.sets.items[idx_u].len != 0) {
                self.allocator.free(layout_info.sets.items[idx_u]);
            }
            layout_info.sets.items[idx_u] = slice;
        }

        var cleanup_i: usize = 0;
        while (cleanup_i < per_set_lists.items.len) : (cleanup_i += 1) {
            per_set_lists.items[cleanup_i].deinit(self.allocator);
        }
        per_set_lists.deinit(self.allocator);
    }

    fn createDescriptorSetLayouts(self: *UnifiedPipelineSystem, layout_info: *const DescriptorLayoutInfo) ![]vk.DescriptorSetLayout {
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

    fn destroyDescriptorSetLayouts(self: *UnifiedPipelineSystem, layouts: []const vk.DescriptorSetLayout) void {
        for (layouts) |layout| {
            self.graphics_context.vkd.destroyDescriptorSetLayout(self.graphics_context.dev, layout, null);
        }
    }

    fn createPipelineLayout(
        self: *UnifiedPipelineSystem,
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
        self: *UnifiedPipelineSystem,
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
            var sampler_only: u32 = 0;
            var storage_images: u32 = 0;
            var accel_structures: u32 = 0;

            for (set_bindings) |binding| {
                switch (binding.descriptor_type) {
                    .uniform_buffer => uniform_buffers += binding.descriptor_count,
                    .storage_buffer => storage_buffers += binding.descriptor_count,
                    .combined_image_sampler => combined_samplers += binding.descriptor_count,
                    .sampler => sampler_only += binding.descriptor_count,
                    .storage_image => storage_images += binding.descriptor_count,
                    .acceleration_structure_khr => accel_structures += binding.descriptor_count,
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
            const scale = MAX_FRAMES_IN_FLIGHT * 2;

            _ = pool_builder.setMaxSets(MAX_FRAMES_IN_FLIGHT * 4); // Allow for multiple pipelines per frame
            if (uniform_buffers > 0) {
                const pool_size = @max(uniform_buffers * scale, 1);
                _ = pool_builder.addPoolSize(.uniform_buffer, pool_size);
            }
            if (storage_buffers > 0) {
                const pool_size = @max(storage_buffers * scale, 1);
                _ = pool_builder.addPoolSize(.storage_buffer, pool_size);
            }
            if (combined_samplers > 0) {
                const pool_size = @max(combined_samplers * scale, 1);
                _ = pool_builder.addPoolSize(.combined_image_sampler, pool_size);
            }
            if (sampler_only > 0) {
                const pool_size = @max(sampler_only * scale, 1);
                _ = pool_builder.addPoolSize(.sampler, pool_size);
            }
            if (storage_images > 0) {
                const pool_size = @max(storage_images * scale, 1);
                _ = pool_builder.addPoolSize(.storage_image, pool_size);
            }
            if (accel_structures > 0) {
                const pool_size = @max(accel_structures * scale, 1);
                _ = pool_builder.addPoolSize(.acceleration_structure_khr, pool_size);
            }

            pool.* = try pool_builder.build();

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
        self: *UnifiedPipelineSystem,
        pipeline_id: PipelineId,
        updates: []const DescriptorUpdate,
        frame_index: u32,
    ) !void {
        if (updates.len == 0) return;

        // Get the pipeline to access its descriptor sets
        const pipeline_ptr = self.pipelines.getPtr(pipeline_id) orelse {
            log(.ERROR, "unified_pipeline", "Pipeline {s} not found when applying descriptor updates", .{pipeline_id.name});
            return error.PipelineNotFound;
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
                log(.ERROR, "unified_pipeline", "Descriptor set index {} out of range for pipeline {s} (has {} sets)", .{ set_index, pipeline_id.name, pipeline_ptr.descriptor_sets.items.len });
                continue;
            }

            // Get the descriptor set for this frame
            const descriptor_sets = pipeline_ptr.descriptor_sets.items[set_index];
            if (frame_index >= descriptor_sets.len) {
                log(.ERROR, "unified_pipeline", "Frame index {} out of range for descriptor set", .{frame_index});
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
                    .image_array => |image_infos| {
                        for (image_infos, 0..) |info, idx| {
                            if (info.sampler == vk.Sampler.null_handle) {
                                log(
                                    .WARN,
                                    "unified_pipeline",
                                    "Descriptor image array binding {} index {} has null sampler",
                                    .{ update.binding, idx },
                                );
                            }
                        }
                        _ = writer.writeImages(update.binding, image_infos);
                    },
                    .buffer_array => |buffer_infos| {
                        _ = writer.writeBuffers(update.binding, buffer_infos);
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

    fn calculatePipelineHash(self: *UnifiedPipelineSystem, config: PipelineConfig) u64 {
        _ = self;
        var hasher = std.hash.Wyhash.init(0);

        // Hash pipeline name
        hasher.update(config.name);

        // Hash shader paths
        if (config.vertex_shader) |vs| hasher.update(vs);
        if (config.fragment_shader) |fs| hasher.update(fs);
        if (config.geometry_shader) |gs| hasher.update(gs);
        if (config.compute_shader) |cs| hasher.update(cs);
        if (config.raygen_shader) |rs| hasher.update(rs);
        if (config.miss_shader) |ms| hasher.update(ms);
        if (config.closest_hit_shader) |chs| hasher.update(chs);
        if (config.any_hit_shader) |ahs| hasher.update(ahs);
        if (config.intersection_shader) |is| hasher.update(is);

        // Hash entry points
        if (config.vertex_entry_point) |ep| hasher.update(ep);
        if (config.fragment_entry_point) |ep| hasher.update(ep);
        if (config.geometry_entry_point) |ep| hasher.update(ep);
        if (config.compute_entry_point) |ep| hasher.update(ep);
        if (config.raygen_entry_point) |ep| hasher.update(ep);
        if (config.miss_entry_point) |ep| hasher.update(ep);
        if (config.closest_hit_entry_point) |ep| hasher.update(ep);
        if (config.any_hit_entry_point) |ep| hasher.update(ep);
        if (config.intersection_entry_point) |ep| hasher.update(ep);

        // Hash vertex input configuration
        if (config.vertex_input_bindings) |bindings| {
            for (bindings) |binding| {
                hasher.update(std.mem.asBytes(&binding));
            }
        }
        if (config.vertex_input_attributes) |attributes| {
            for (attributes) |attribute| {
                hasher.update(std.mem.asBytes(&attribute));
            }
        }

        // Hash topology
        hasher.update(std.mem.asBytes(&config.topology));

        // Hash render state
        hasher.update(std.mem.asBytes(&config.polygon_mode));
        hasher.update(std.mem.asBytes(&config.cull_mode));
        hasher.update(std.mem.asBytes(&config.front_face));

        // Hash multisample state if present
        if (config.multisample_state) |ms| {
            hasher.update(std.mem.asBytes(&ms));
        }

        // Hash push constant ranges
        if (config.push_constant_ranges) |ranges| {
            for (ranges) |range| {
                hasher.update(std.mem.asBytes(&range));
            }
        }

        // Hash render pass (use handle as identifier)
        hasher.update(std.mem.asBytes(&config.render_pass));
        hasher.update(std.mem.asBytes(&config.subpass));

        // Hash shader options
        hasher.update(std.mem.asBytes(&config.shader_options.target));
        hasher.update(std.mem.asBytes(&config.shader_options.optimization_level));
        hasher.update(std.mem.asBytes(&config.shader_options.debug_info));
        hasher.update(std.mem.asBytes(&config.shader_options.vulkan_semantics));
        hasher.update(std.mem.asBytes(&config.raytracing_flags));
        hasher.update(std.mem.asBytes(&config.raytracing_max_recursion_depth));

        return hasher.final();
    }

    /// Save the Vulkan pipeline cache to disk
    fn savePipelineCacheToDisk(self: *UnifiedPipelineSystem) !void {
        const cache_path = "cache/unified_pipeline_cache.bin";

        // Get cache data size
        var cache_size: usize = 0;
        _ = try self.graphics_context.vkd.getPipelineCacheData(
            self.graphics_context.dev,
            self.vulkan_pipeline_cache,
            &cache_size,
            null,
        );

        if (cache_size == 0) {
            log(.INFO, "unified_pipeline", "Pipeline cache is empty, skipping save", .{});
            return;
        }

        // Allocate buffer and get cache data
        const cache_data = try self.allocator.alloc(u8, cache_size);
        defer self.allocator.free(cache_data);

        _ = try self.graphics_context.vkd.getPipelineCacheData(
            self.graphics_context.dev,
            self.vulkan_pipeline_cache,
            &cache_size,
            cache_data.ptr,
        );

        // Ensure cache directory exists
        std.fs.cwd().makeDir("cache") catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        // Write to file
        const file = try std.fs.cwd().createFile(cache_path, .{});
        defer file.close();
        try file.writeAll(cache_data);

        log(.INFO, "unified_pipeline", "Saved pipeline cache ({d} bytes) to {s}", .{ cache_size, cache_path });
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
    raygen_shader: ?[]const u8 = null,
    miss_shader: ?[]const u8 = null,
    closest_hit_shader: ?[]const u8 = null,
    any_hit_shader: ?[]const u8 = null,
    intersection_shader: ?[]const u8 = null,
    raytracing_flags: vk.PipelineCreateFlags = .{},
    raytracing_max_recursion_depth: u32 = 1,

    vertex_entry_point: ?[]const u8 = null,
    fragment_entry_point: ?[]const u8 = null,
    geometry_entry_point: ?[]const u8 = null,
    compute_entry_point: ?[]const u8 = null,
    raygen_entry_point: ?[]const u8 = null,
    miss_entry_point: ?[]const u8 = null,
    closest_hit_entry_point: ?[]const u8 = null,
    any_hit_entry_point: ?[]const u8 = null,
    intersection_entry_point: ?[]const u8 = null,

    shader_options: ShaderCompiler.CompilationOptions = .{ .target = .vulkan },

    // Vertex input configuration
    vertex_input_bindings: ?[]const VertexInputBinding = null,
    vertex_input_attributes: ?[]const VertexInputAttribute = null,

    // Pipeline state
    topology: vk.PrimitiveTopology = .triangle_list,
    polygon_mode: vk.PolygonMode = .fill,
    cull_mode: vk.CullModeFlags = .{ .back_bit = true },
    front_face: vk.FrontFace = .counter_clockwise,
    multisample_state: ?vk.PipelineMultisampleStateCreateInfo = null,
    depth_stencil_state: ?DepthStencilState = null,
    color_blend_attachment: ?ColorBlendAttachment = null,

    // Push constants
    push_constant_ranges: ?[]const vk.PushConstantRange = null,

    // Render pass
    render_pass: vk.RenderPass,
    subpass: u32 = 0,

    // Dynamic rendering formats (used when render_pass is .null_handle)
    dynamic_rendering_color_formats: ?[]const vk.Format = null,
    dynamic_rendering_depth_format: ?vk.Format = null,
};

/// Unified pipeline representation
const Pipeline = struct {
    vulkan_pipeline: vk.Pipeline,
    pipeline_layout: vk.PipelineLayout,
    pipeline_set_layout_handles: []vk.DescriptorSetLayout,
    descriptor_layout_info: DescriptorLayoutInfo,
    descriptor_pools: std.ArrayList(*DescriptorPool),
    descriptor_layouts: std.ArrayList(*DescriptorSetLayout),
    descriptor_sets: std.ArrayList([]vk.DescriptorSet), // [set_index][frame_index]
    shaders: []*Shader,
    config: PipelineConfig,
    is_compute: bool,
    is_raytracing: bool,

    fn deinit(self: *Pipeline, graphics_context: *GraphicsContext, allocator: std.mem.Allocator) void {
        // Clean up Vulkan objects
        graphics_context.vkd.destroyPipeline(graphics_context.dev, self.vulkan_pipeline, null);
        graphics_context.vkd.destroyPipelineLayout(graphics_context.dev, self.pipeline_layout, null);

        for (self.pipeline_set_layout_handles) |layout_handle| {
            graphics_context.vkd.destroyDescriptorSetLayout(graphics_context.dev, layout_handle, null);
        }
        allocator.free(self.pipeline_set_layout_handles);

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
        allocator.free(self.shaders);

        // Free copied dynamic rendering formats
        if (self.config.dynamic_rendering_color_formats) |formats| {
            allocator.free(formats);
        }

        self.descriptor_layout_info.deinit();

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
    image_array: []const vk.DescriptorImageInfo,
    buffer_array: []const vk.DescriptorBufferInfo,
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

const BindingKey = struct {
    set: u32,
    binding: u32,
};

const BindingKeyContext = struct {
    pub fn hash(_: @This(), key: BindingKey) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&key.set));
        hasher.update(std.mem.asBytes(&key.binding));
        return hasher.final();
    }

    pub fn eql(_: @This(), a: BindingKey, b: BindingKey) bool {
        return a.set == b.set and a.binding == b.binding;
    }
};

const BindingOverrideMap = std.HashMap(BindingKey, u32, BindingKeyContext, std.hash_map.default_max_load_percentage);
const MAX_DESCRIPTOR_BINDING_COUNT: u32 = 0x10000;

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
