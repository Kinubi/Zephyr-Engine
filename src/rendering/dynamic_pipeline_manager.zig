const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("../core/graphics_context.zig").GraphicsContext;
const Shader = @import("../core/shader.zig").Shader;
const PipelineBuilder = @import("pipeline_builder.zig").PipelineBuilder;
const VertexInputBinding = @import("pipeline_builder.zig").VertexInputBinding;
const VertexInputAttribute = @import("pipeline_builder.zig").VertexInputAttribute;
const DescriptorBinding = @import("pipeline_builder.zig").DescriptorBinding;
const PushConstantRange = @import("pipeline_builder.zig").PushConstantRange;
const DepthStencilState = @import("pipeline_builder.zig").DepthStencilState;
const RasterizationState = @import("pipeline_builder.zig").RasterizationState;
const MultisampleState = @import("pipeline_builder.zig").MultisampleState;
const ColorBlendAttachment = @import("pipeline_builder.zig").ColorBlendAttachment;
const PipelineCache = @import("pipeline_cache.zig").PipelineCache;
const AssetManager = @import("../assets/asset_manager.zig").AssetManager;
const ShaderManager = @import("../assets/shader_manager.zig").ShaderManager;
const CompilationOptions = @import("../assets/shader_compiler.zig").CompilationOptions;
const AssetId = @import("../assets/asset_types.zig").AssetId;
const log = @import("../utils/log.zig").log;

/// Pipeline template for dynamic creation
pub const PipelineTemplate = struct {
    name: []const u8,
    vertex_shader: []const u8, // Shader asset path
    fragment_shader: []const u8, // Shader asset path

    // Optional shaders
    geometry_shader: ?[]const u8 = null,
    tess_control_shader: ?[]const u8 = null,
    tess_eval_shader: ?[]const u8 = null,

    // Pipeline configuration
    vertex_bindings: []const VertexInputBinding = &[_]VertexInputBinding{},
    vertex_attributes: []const VertexInputAttribute = &[_]VertexInputAttribute{},
    descriptor_bindings: []const DescriptorBinding = &[_]DescriptorBinding{}, // Legacy single set
    descriptor_sets: ?[]const []const DescriptorBinding = null, // New multi-set support
    push_constant_ranges: []const PushConstantRange = &[_]PushConstantRange{},

    // Render state
    primitive_topology: vk.PrimitiveTopology = .triangle_list,
    polygon_mode: vk.PolygonMode = .fill,
    cull_mode: vk.CullModeFlags = .{ .back_bit = true },
    front_face: vk.FrontFace = .counter_clockwise,
    depth_test_enable: bool = true,
    depth_write_enable: bool = true,
    depth_compare_op: vk.CompareOp = .less,
    blend_enable: bool = false,

    // Dynamic state
    dynamic_states: []const vk.DynamicState = &[_]vk.DynamicState{
        .viewport,
        .scissor,
    },
};

/// Dynamic pipeline instance with hot reload support
pub const DynamicPipeline = struct {
    template: PipelineTemplate,
    pipeline: ?vk.Pipeline = null,
    pipeline_layout: ?vk.PipelineLayout = null,
    descriptor_set_layout: ?vk.DescriptorSetLayout = null,

    // Shader asset tracking for hot reload
    shader_assets: std.ArrayList(AssetId),
    last_rebuild_time: i64 = 0,
    rebuild_needed: bool = false,
    rebuild_failure_count: u32 = 0, // Track consecutive rebuild failures
    max_rebuild_attempts: u32 = 5,  // Maximum rebuild attempts before giving up

    // Usage statistics
    usage_count: u32 = 0,
    last_used_frame: u32 = 0,

    pub fn init(template: PipelineTemplate) DynamicPipeline {
        return DynamicPipeline{
            .template = template,
            .shader_assets = std.ArrayList(AssetId){},
        };
    }

    pub fn deinit(self: *DynamicPipeline, graphics_context: *GraphicsContext, allocator: std.mem.Allocator) void {
        self.destroyVulkanObjects(graphics_context);
        self.shader_assets.deinit(allocator);
    }

    pub fn destroyVulkanObjects(self: *DynamicPipeline, graphics_context: *GraphicsContext) void {
        if (self.pipeline) |pipeline| {
            graphics_context.vkd.destroyPipeline(graphics_context.dev, pipeline, null);
            self.pipeline = null;
        }
        if (self.pipeline_layout) |layout| {
            graphics_context.vkd.destroyPipelineLayout(graphics_context.dev, layout, null);
            self.pipeline_layout = null;
        }
        if (self.descriptor_set_layout) |layout| {
            graphics_context.vkd.destroyDescriptorSetLayout(graphics_context.dev, layout, null);
            self.descriptor_set_layout = null;
        }
    }

    pub fn markRebuildNeeded(self: *DynamicPipeline) void {
        self.rebuild_needed = true;
        log(.INFO, "dynamic_pipeline", "Pipeline '{}' marked for rebuild due to shader changes", .{self.template.name});
    }

    pub fn isValid(self: *const DynamicPipeline) bool {
        // Consider pipeline invalid if we've failed too many rebuild attempts
        if (self.rebuild_failure_count >= self.max_rebuild_attempts) {
            return false; // Give up rebuilding
        }
        return self.pipeline != null and self.pipeline_layout != null and !self.rebuild_needed;
    }
};

/// Manager for dynamic pipeline creation and hot reload
pub const DynamicPipelineManager = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    graphics_context: *GraphicsContext,
    asset_manager: *AssetManager,
    shader_manager: *ShaderManager,
    pipeline_cache: PipelineCache,

    // Pipeline registry
    pipelines: std.StringHashMap(DynamicPipeline),
    pipeline_mutex: std.Thread.Mutex = std.Thread.Mutex{},

    // Hot reload tracking
    current_frame: u32 = 0,
    rebuild_pending: std.ArrayList([]const u8), // Pipeline names pending rebuild

    pub fn init(allocator: std.mem.Allocator, graphics_context: *GraphicsContext, asset_manager: *AssetManager, shader_manager: *ShaderManager) !Self {
        const manager = Self{
            .allocator = allocator,
            .graphics_context = graphics_context,
            .asset_manager = asset_manager,
            .shader_manager = shader_manager,
            .pipeline_cache = try PipelineCache.init(allocator, graphics_context),
            .pipelines = std.StringHashMap(DynamicPipeline).init(allocator),
            .rebuild_pending = std.ArrayList([]const u8){},
        };

        log(.INFO, "dynamic_pipeline", "Dynamic pipeline manager initialized", .{});
        return manager;
    }

    pub fn deinit(self: *Self) void {
        // Clean up all pipelines
        var pipeline_iter = self.pipelines.iterator();
        while (pipeline_iter.next()) |entry| {
            entry.value_ptr.deinit(self.graphics_context, self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.pipelines.deinit();

        // Clean up rebuild queue
        for (self.rebuild_pending.items) |name| {
            self.allocator.free(name);
        }
        self.rebuild_pending.deinit(self.allocator);

        self.pipeline_cache.deinit();
        log(.INFO, "dynamic_pipeline", "Dynamic pipeline manager deinitialized", .{});
    }

    /// Register a pipeline template for dynamic creation
    pub fn registerPipeline(self: *Self, template: PipelineTemplate) !void {
        self.pipeline_mutex.lock();
        defer self.pipeline_mutex.unlock();

        // Clone the template name for storage
        const owned_name = try self.allocator.dupe(u8, template.name);
        errdefer self.allocator.free(owned_name);

        // Create dynamic pipeline instance
        var dynamic_pipeline = DynamicPipeline.init(template);

        // Register shader assets for hot reload
        try self.registerShaderAssets(&dynamic_pipeline);

        // Store in registry
        try self.pipelines.put(owned_name, dynamic_pipeline);

        log(.INFO, "dynamic_pipeline", "Registered pipeline template: {s}", .{template.name});
    }

    /// Get a pipeline by name, building it if necessary
    pub fn getPipeline(self: *Self, name: []const u8, render_pass: vk.RenderPass) !?vk.Pipeline {
        self.pipeline_mutex.lock();
        defer self.pipeline_mutex.unlock();

        if (self.pipelines.getPtr(name)) |dynamic_pipeline| {
            // Update usage statistics
            dynamic_pipeline.usage_count += 1;
            dynamic_pipeline.last_used_frame = self.current_frame;

            // Check if pipeline needs rebuilding
            if (!dynamic_pipeline.isValid()) {
                // Check if we've exceeded max rebuild attempts
                if (dynamic_pipeline.rebuild_failure_count >= dynamic_pipeline.max_rebuild_attempts) {
                    log(.ERROR, "dynamic_pipeline", "Pipeline {s} exceeded max rebuild attempts ({}), skipping", .{ name, dynamic_pipeline.max_rebuild_attempts });
                    return null;
                }
                
                // Attempt to rebuild pipeline
                self.rebuildPipeline(dynamic_pipeline, render_pass) catch |err| {
                    dynamic_pipeline.rebuild_failure_count += 1;
                    log(.ERROR, "dynamic_pipeline", "Failed to rebuild pipeline {s} (attempt {}): {}", .{ name, dynamic_pipeline.rebuild_failure_count, err });
                    return null;
                };
            }

            return dynamic_pipeline.pipeline;
        } else {
            log(.WARN, "dynamic_pipeline", "Pipeline not found: {s}", .{name});
            return null;
        }
    }

    /// Process pending pipeline rebuilds (call once per frame)
    pub fn processRebuildQueue(self: *Self, render_pass: vk.RenderPass) void {
        self.current_frame += 1;

        if (self.rebuild_pending.items.len == 0) return;

        self.pipeline_mutex.lock();
        defer self.pipeline_mutex.unlock();

        // Process all pending rebuilds
        for (self.rebuild_pending.items) |pipeline_name| {
            if (self.pipelines.getPtr(pipeline_name)) |dynamic_pipeline| {
                self.rebuildPipeline(dynamic_pipeline, render_pass) catch |err| {
                    log(.ERROR, "dynamic_pipeline", "Failed to rebuild pipeline {s}: {}", .{ pipeline_name, err });
                };
            }
            self.allocator.free(pipeline_name);
        }

        self.rebuild_pending.clearRetainingCapacity();
    }

    /// Mark pipelines for rebuild based on shader path (called by hot reload system)
    pub fn markPipelinesForRebuildByShader(self: *Self, shader_path: []const u8) !void {
        self.pipeline_mutex.lock();
        defer self.pipeline_mutex.unlock();

        log(.INFO, "dynamic_pipeline", "Checking pipelines for shader: {s}", .{shader_path});

        var rebuild_count: u32 = 0;
        var pipeline_iter = self.pipelines.iterator();

        while (pipeline_iter.next()) |entry| {
            const pipeline_name = entry.key_ptr.*;
            const dynamic_pipeline = entry.value_ptr;
            const template = &dynamic_pipeline.template;

            // Check if this pipeline uses the changed shader
            var uses_shader = false;
            if (std.mem.eql(u8, template.vertex_shader, shader_path)) uses_shader = true;
            if (std.mem.eql(u8, template.fragment_shader, shader_path)) uses_shader = true;
            if (template.geometry_shader) |path| {
                if (std.mem.eql(u8, path, shader_path)) uses_shader = true;
            }
            if (template.tess_control_shader) |path| {
                if (std.mem.eql(u8, path, shader_path)) uses_shader = true;
            }
            if (template.tess_eval_shader) |path| {
                if (std.mem.eql(u8, path, shader_path)) uses_shader = true;
            }

            if (uses_shader) {
                dynamic_pipeline.markRebuildNeeded();

                // Add to rebuild queue
                const owned_name = try self.allocator.dupe(u8, pipeline_name);
                try self.rebuild_pending.append(self.allocator, owned_name);
                rebuild_count += 1;

                log(.INFO, "dynamic_pipeline", "Marked pipeline '{s}' for rebuild due to shader change", .{pipeline_name});
            }
        }

        log(.INFO, "dynamic_pipeline", "Marked {} pipelines for rebuild due to shader change: {s}", .{ rebuild_count, shader_path });
    }

    /// Mark a pipeline for rebuild by name (internal use)
    pub fn markForRebuild(self: *Self, pipeline_name: []const u8) !void {
        self.pipeline_mutex.lock();
        defer self.pipeline_mutex.unlock();

        if (self.pipelines.getPtr(pipeline_name)) |dynamic_pipeline| {
            dynamic_pipeline.markRebuildNeeded();

            // Add to rebuild queue
            const owned_name = try self.allocator.dupe(u8, pipeline_name);
            try self.rebuild_pending.append(self.allocator, owned_name);
        }
    }

    /// Register shader assets for hot reload monitoring
    fn registerShaderAssets(self: *Self, dynamic_pipeline: *DynamicPipeline) !void {
        const template = &dynamic_pipeline.template;

        // Register vertex shader
        if (self.asset_manager.registry.getAssetId(template.vertex_shader)) |asset_id| {
            try dynamic_pipeline.shader_assets.append(self.allocator, asset_id);
        }

        // Register fragment shader
        if (self.asset_manager.registry.getAssetId(template.fragment_shader)) |asset_id| {
            try dynamic_pipeline.shader_assets.append(self.allocator, asset_id);
        }

        // Register optional shaders
        if (template.geometry_shader) |path| {
            if (self.asset_manager.registry.getAssetId(path)) |asset_id| {
                try dynamic_pipeline.shader_assets.append(self.allocator, asset_id);
            }
        }

        if (template.tess_control_shader) |path| {
            if (self.asset_manager.registry.getAssetId(path)) |asset_id| {
                try dynamic_pipeline.shader_assets.append(self.allocator, asset_id);
            }
        }

        if (template.tess_eval_shader) |path| {
            if (self.asset_manager.registry.getAssetId(path)) |asset_id| {
                try dynamic_pipeline.shader_assets.append(self.allocator, asset_id);
            }
        }

        log(.DEBUG, "dynamic_pipeline", "Registered {} shader assets for pipeline '{s}'", .{ dynamic_pipeline.shader_assets.items.len, template.name });
    }

    /// Rebuild a pipeline from its template
    fn rebuildPipeline(self: *Self, dynamic_pipeline: *DynamicPipeline, render_pass: vk.RenderPass) !void {
        const template = &dynamic_pipeline.template;

        log(.INFO, "dynamic_pipeline", "Rebuilding pipeline: {s}", .{template.name});

        // Destroy existing Vulkan objects
        dynamic_pipeline.destroyVulkanObjects(self.graphics_context);

        // Create new pipeline using PipelineBuilder
        var builder = PipelineBuilder.init(self.allocator, self.graphics_context);
        defer builder.deinit();

        // Load and set shaders - try to get existing, otherwise load from file
        const vertex_loaded_shader = self.shader_manager.getShader(template.vertex_shader) orelse blk: {
            log(.INFO, "dynamic_pipeline", "Loading vertex shader: {s}", .{template.vertex_shader});
            const options = CompilationOptions{
                .target = .vulkan,
                .optimization_level = .none,
                .debug_info = false,
            };
            break :blk self.shader_manager.loadShader(template.vertex_shader, options) catch |err| {
                log(.ERROR, "dynamic_pipeline", "Failed to load vertex shader: {s} - {}", .{ template.vertex_shader, err });
                return error.ShaderLoadFailed;
            };
        };
        const fragment_loaded_shader = self.shader_manager.getShader(template.fragment_shader) orelse blk: {
            log(.INFO, "dynamic_pipeline", "Loading fragment shader: {s}", .{template.fragment_shader});
            const options = CompilationOptions{
                .target = .vulkan,
                .optimization_level = .none,
                .debug_info = false,
            };
            break :blk self.shader_manager.loadShader(template.fragment_shader, options) catch |err| {
                log(.ERROR, "dynamic_pipeline", "Failed to load fragment shader: {s} - {}", .{ template.fragment_shader, err });
                return error.ShaderLoadFailed;
            };
        };

        // Create Shader objects from LoadedShader
        const vertex_shader = try Shader.create(self.graphics_context.*, vertex_loaded_shader.compiled_shader.spirv_code, .{ .vertex_bit = true }, null);
        defer vertex_shader.deinit(self.graphics_context.*);
        const fragment_shader = try Shader.create(self.graphics_context.*, fragment_loaded_shader.compiled_shader.spirv_code, .{ .fragment_bit = true }, null);
        defer fragment_shader.deinit(self.graphics_context.*);

        _ = try builder.vertexShader(&vertex_shader);
        _ = try builder.fragmentShader(&fragment_shader); // Set optional shaders
        var geometry_shader: ?Shader = null;
        var tess_control_shader: ?Shader = null;
        var tess_eval_shader: ?Shader = null;
        defer {
            if (geometry_shader) |shader| shader.deinit(self.graphics_context.*);
            if (tess_control_shader) |shader| shader.deinit(self.graphics_context.*);
            if (tess_eval_shader) |shader| shader.deinit(self.graphics_context.*);
        }

        if (template.geometry_shader) |path| {
            if (self.shader_manager.getShader(path)) |loaded_shader| {
                geometry_shader = try Shader.create(self.graphics_context.*, loaded_shader.compiled_shader.spirv_code, .{ .geometry_bit = true }, null);
                _ = try builder.addShaderStage(.{ .geometry_bit = true }, &geometry_shader.?);
            } else {
                log(.WARN, "dynamic_pipeline", "Failed to load geometry shader: {s}", .{path});
            }
        }

        if (template.tess_control_shader) |path| {
            if (self.shader_manager.getShader(path)) |loaded_shader| {
                tess_control_shader = try Shader.create(self.graphics_context.*, loaded_shader.compiled_shader.spirv_code, .{ .tessellation_control_bit = true }, null);
                _ = try builder.addShaderStage(.{ .tessellation_control_bit = true }, &tess_control_shader.?);
            } else {
                log(.WARN, "dynamic_pipeline", "Failed to load tessellation control shader: {s}", .{path});
            }
        }

        if (template.tess_eval_shader) |path| {
            if (self.shader_manager.getShader(path)) |loaded_shader| {
                tess_eval_shader = try Shader.create(self.graphics_context.*, loaded_shader.compiled_shader.spirv_code, .{ .tessellation_evaluation_bit = true }, null);
                _ = try builder.addShaderStage(.{ .tessellation_evaluation_bit = true }, &tess_eval_shader.?);
            } else {
                log(.WARN, "dynamic_pipeline", "Failed to load tessellation evaluation shader: {s}", .{path});
            }
        }

        // Configure vertex input
        for (template.vertex_bindings) |binding| {
            _ = try builder.addVertexBinding(binding);
        }

        for (template.vertex_attributes) |attribute| {
            _ = try builder.addVertexAttribute(attribute);
        }

        // Configure descriptor bindings - support both single and multi-set layouts
        var descriptor_set_layouts: []vk.DescriptorSetLayout = undefined;
        var single_layout: vk.DescriptorSetLayout = undefined;
        var managed_layouts: bool = false;
        
        if (template.descriptor_sets) |multi_sets| {
            // Use new multi-set support
            descriptor_set_layouts = try builder.buildDescriptorSetLayouts(multi_sets, self.allocator);
            managed_layouts = true;
        } else {
            // Use legacy single descriptor set
            for (template.descriptor_bindings) |binding| {
                _ = try builder.addDescriptorBinding(binding);
            }
            single_layout = try builder.buildDescriptorSetLayout();
            descriptor_set_layouts = try self.allocator.alloc(vk.DescriptorSetLayout, 1);
            descriptor_set_layouts[0] = single_layout;
            managed_layouts = true;
        }        // Configure push constants
        for (template.push_constant_ranges) |range| {
            _ = try builder.addPushConstantRange(range);
        }

        // Configure render state - use predefined states for now
        _ = builder.graphics();
        _ = builder.triangleList();
        _ = try builder.dynamicViewportScissor();

        // Set basic depth/stencil state
        _ = builder.withDepthStencilState(DepthStencilState.default());

        // Set default rasterization state
        _ = builder.withRasterizationState(RasterizationState.default());

        // Set default multisampling
        _ = builder.withMultisampleState(MultisampleState.default());

        // Configure color blending - add a color attachment for the render pass
        if (template.blend_enable) {
            _ = try builder.addColorBlendAttachment(ColorBlendAttachment.alphaBlend());
        } else {
            _ = try builder.addColorBlendAttachment(ColorBlendAttachment.disabled());
        }

        // Set dynamic states
        for (template.dynamic_states) |state| {
            _ = try builder.addDynamicState(state);
        }

        // Set render pass
        _ = builder.withRenderPass(render_pass, 0);

        // Build the pipeline components
        const pipeline_layout = try builder.buildPipelineLayout(descriptor_set_layouts);
        const pipeline = try builder.buildGraphicsPipeline(pipeline_layout);

        dynamic_pipeline.pipeline = pipeline;
        dynamic_pipeline.pipeline_layout = pipeline_layout;
        
        // For single descriptor set, store the layout; for multi-set, store the first one
        dynamic_pipeline.descriptor_set_layout = descriptor_set_layouts[0];
        
        dynamic_pipeline.rebuild_needed = false;
        dynamic_pipeline.rebuild_failure_count = 0; // Reset failure counter on success
        dynamic_pipeline.last_rebuild_time = std.time.timestamp();

        // Clean up managed layouts if we allocated them
        if (managed_layouts) {
            self.allocator.free(descriptor_set_layouts);
        }

        log(.INFO, "dynamic_pipeline", "Successfully rebuilt pipeline: {s}", .{template.name});
    }

    /// Get pipeline layout for a named pipeline
    pub fn getPipelineLayout(self: *Self, name: []const u8) ?vk.PipelineLayout {
        self.pipeline_mutex.lock();
        defer self.pipeline_mutex.unlock();

        if (self.pipelines.get(name)) |dynamic_pipeline| {
            return dynamic_pipeline.pipeline_layout;
        }
        return null;
    }

    /// Get descriptor set layout for a named pipeline
    pub fn getDescriptorSetLayout(self: *Self, name: []const u8) ?vk.DescriptorSetLayout {
        self.pipeline_mutex.lock();
        defer self.pipeline_mutex.unlock();

        if (self.pipelines.get(name)) |dynamic_pipeline| {
            return dynamic_pipeline.descriptor_set_layout;
        }
        return null;
    }

    /// Get usage statistics for all pipelines
    pub fn getStatistics(self: *Self) PipelineStatistics {
        self.pipeline_mutex.lock();
        defer self.pipeline_mutex.unlock();

        var stats = PipelineStatistics{};
        var pipeline_iter = self.pipelines.iterator();

        while (pipeline_iter.next()) |entry| {
            const pipeline = entry.value_ptr;
            stats.total_pipelines += 1;
            stats.total_usage += pipeline.usage_count;

            if (pipeline.isValid()) {
                stats.active_pipelines += 1;
            }

            if (pipeline.rebuild_needed) {
                stats.pending_rebuilds += 1;
            }
        }

        return stats;
    }
};

/// Pipeline usage statistics
pub const PipelineStatistics = struct {
    total_pipelines: u32 = 0,
    active_pipelines: u32 = 0,
    pending_rebuilds: u32 = 0,
    total_usage: u32 = 0,
};
