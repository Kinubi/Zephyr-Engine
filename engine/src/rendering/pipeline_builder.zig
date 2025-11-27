const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("../core/graphics_context.zig").GraphicsContext;
const Shader = @import("../core/shader.zig").Shader;

/// Vertex input binding description builder
pub const VertexInputBinding = struct {
    binding: u32,
    stride: u32,
    input_rate: vk.VertexInputRate = .vertex,

    pub fn create(binding: u32, stride: u32) VertexInputBinding {
        return VertexInputBinding{
            .binding = binding,
            .stride = stride,
        };
    }

    pub fn instanceRate(self: VertexInputBinding) VertexInputBinding {
        var result = self;
        result.input_rate = .instance;
        return result;
    }
};

/// Vertex input attribute description builder
pub const VertexInputAttribute = struct {
    location: u32,
    binding: u32,
    format: vk.Format,
    offset: u32,

    pub fn create(location: u32, binding: u32, format: vk.Format, offset: u32) VertexInputAttribute {
        return VertexInputAttribute{
            .location = location,
            .binding = binding,
            .format = format,
            .offset = offset,
        };
    }
};

/// Descriptor set layout binding builder
pub const DescriptorBinding = struct {
    binding: u32,
    descriptor_type: vk.DescriptorType,
    descriptor_count: u32 = 1,
    stage_flags: vk.ShaderStageFlags,
    immutable_samplers: ?[*]const vk.Sampler = null,

    pub fn uniformBuffer(binding: u32, stage_flags: vk.ShaderStageFlags) DescriptorBinding {
        return DescriptorBinding{
            .binding = binding,
            .descriptor_type = .uniform_buffer,
            .stage_flags = stage_flags,
        };
    }

    pub fn storageBuffer(binding: u32, stage_flags: vk.ShaderStageFlags) DescriptorBinding {
        return DescriptorBinding{
            .binding = binding,
            .descriptor_type = .storage_buffer,
            .stage_flags = stage_flags,
        };
    }

    pub fn combinedImageSampler(binding: u32, stage_flags: vk.ShaderStageFlags) DescriptorBinding {
        return DescriptorBinding{
            .binding = binding,
            .descriptor_type = .combined_image_sampler,
            .stage_flags = stage_flags,
        };
    }

    pub fn storageImage(binding: u32, stage_flags: vk.ShaderStageFlags) DescriptorBinding {
        return DescriptorBinding{
            .binding = binding,
            .descriptor_type = .storage_image,
            .stage_flags = stage_flags,
        };
    }

    pub fn accelerationStructure(binding: u32, stage_flags: vk.ShaderStageFlags) DescriptorBinding {
        return DescriptorBinding{
            .binding = binding,
            .descriptor_type = .acceleration_structure_khr,
            .stage_flags = stage_flags,
        };
    }

    pub fn withCount(self: DescriptorBinding, count: u32) DescriptorBinding {
        var result = self;
        result.descriptor_count = count;
        return result;
    }
};

/// Push constant range builder
pub const PushConstantRange = struct {
    stage_flags: vk.ShaderStageFlags,
    offset: u32 = 0,
    size: u32,

    pub fn create(stage_flags: vk.ShaderStageFlags, size: u32) PushConstantRange {
        return PushConstantRange{
            .stage_flags = stage_flags,
            .size = size,
        };
    }

    pub fn withOffset(self: PushConstantRange, offset: u32) PushConstantRange {
        var result = self;
        result.offset = offset;
        return result;
    }
};

/// Rasterization state builder
pub const RasterizationState = struct {
    depth_clamp_enable: bool = false,
    rasterizer_discard_enable: bool = false,
    polygon_mode: vk.PolygonMode = .fill,
    cull_mode: vk.CullModeFlags = .{ .back_bit = true },
    front_face: vk.FrontFace = .counter_clockwise,
    depth_bias_enable: bool = false,
    depth_bias_constant_factor: f32 = 0.0,
    depth_bias_clamp: f32 = 0.0,
    depth_bias_slope_factor: f32 = 0.0,
    line_width: f32 = 1.0,

    pub fn default() RasterizationState {
        return RasterizationState{};
    }

    pub fn wireframe(self: RasterizationState) RasterizationState {
        var result = self;
        result.polygon_mode = .line;
        return result;
    }

    pub fn noCulling(self: RasterizationState) RasterizationState {
        var result = self;
        result.cull_mode = .{};
        return result;
    }

    pub fn frontCulling(self: RasterizationState) RasterizationState {
        var result = self;
        result.cull_mode = .{ .front_bit = true };
        return result;
    }

    pub fn clockwise(self: RasterizationState) RasterizationState {
        var result = self;
        result.front_face = .clockwise;
        return result;
    }

    pub fn withDepthBias(self: RasterizationState, constant: f32, slope: f32) RasterizationState {
        var result = self;
        result.depth_bias_enable = true;
        result.depth_bias_constant_factor = constant;
        result.depth_bias_slope_factor = slope;
        return result;
    }
};

/// Multisample state builder
pub const MultisampleState = struct {
    rasterization_samples: vk.SampleCountFlags = .{ .@"1_bit" = true },
    sample_shading_enable: bool = false,
    min_sample_shading: f32 = 1.0,
    sample_mask: ?*const u32 = null,
    alpha_to_coverage_enable: bool = false,
    alpha_to_one_enable: bool = false,

    pub fn default() MultisampleState {
        return MultisampleState{};
    }

    pub fn withSamples(self: MultisampleState, samples: vk.SampleCountFlags) MultisampleState {
        var result = self;
        result.rasterization_samples = samples;
        return result;
    }

    pub fn withSampleShading(self: MultisampleState, min_sample_shading: f32) MultisampleState {
        var result = self;
        result.sample_shading_enable = true;
        result.min_sample_shading = min_sample_shading;
        return result;
    }
};

/// Depth stencil state builder
pub const DepthStencilState = struct {
    depth_test_enable: bool = true,
    depth_write_enable: bool = true,
    depth_compare_op: vk.CompareOp = .less,
    depth_bounds_test_enable: bool = false,
    stencil_test_enable: bool = false,
    front: vk.StencilOpState = std.mem.zeroes(vk.StencilOpState),
    back: vk.StencilOpState = std.mem.zeroes(vk.StencilOpState),
    min_depth_bounds: f32 = 0.0,
    max_depth_bounds: f32 = 1.0,

    pub fn default() DepthStencilState {
        return DepthStencilState{};
    }

    pub fn disabled() DepthStencilState {
        return DepthStencilState{
            .depth_test_enable = false,
            .depth_write_enable = false,
        };
    }

    pub fn readOnly() DepthStencilState {
        return DepthStencilState{
            .depth_test_enable = true,
            .depth_write_enable = false,
        };
    }

    pub fn withCompareOp(self: DepthStencilState, compare_op: vk.CompareOp) DepthStencilState {
        var result = self;
        result.depth_compare_op = compare_op;
        return result;
    }
};

/// Color blend attachment state builder
pub const ColorBlendAttachment = struct {
    color_write_mask: vk.ColorComponentFlags = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
    blend_enable: bool = false,
    src_color_blend_factor: vk.BlendFactor = .one,
    dst_color_blend_factor: vk.BlendFactor = .zero,
    color_blend_op: vk.BlendOp = .add,
    src_alpha_blend_factor: vk.BlendFactor = .one,
    dst_alpha_blend_factor: vk.BlendFactor = .zero,
    alpha_blend_op: vk.BlendOp = .add,

    pub fn disabled() ColorBlendAttachment {
        return ColorBlendAttachment{};
    }

    pub fn alphaBlend() ColorBlendAttachment {
        return ColorBlendAttachment{
            .blend_enable = true,
            .src_color_blend_factor = .src_alpha,
            .dst_color_blend_factor = .one_minus_src_alpha,
            .src_alpha_blend_factor = .one,
            .dst_alpha_blend_factor = .zero,
        };
    }

    pub fn additiveBlend() ColorBlendAttachment {
        return ColorBlendAttachment{
            .blend_enable = true,
            .src_color_blend_factor = .one,
            .dst_color_blend_factor = .one,
            .src_alpha_blend_factor = .one,
            .dst_alpha_blend_factor = .one,
        };
    }
};

/// Pipeline type enumeration
pub const PipelineType = enum {
    graphics,
    compute,
    raytracing,
};

/// Shader stage configuration
pub const ShaderStage = struct {
    stage: vk.ShaderStageFlags,
    shader: *const Shader,
    entry_point: [:0]const u8 = "main",
    specialization_info: ?*const vk.SpecializationInfo = null,
};

/// Complete pipeline builder
pub const PipelineBuilder = struct {
    allocator: std.mem.Allocator,
    graphics_context: *GraphicsContext,

    // Optional pipeline cache for faster pipeline creation
    pipeline_cache: vk.PipelineCache = .null_handle,

    // Pipeline type
    pipeline_type: PipelineType = .graphics,

    // Shader stages
    shader_stages: std.ArrayList(ShaderStage),

    // Vertex input
    vertex_bindings: std.ArrayList(VertexInputBinding),
    vertex_attributes: std.ArrayList(VertexInputAttribute),

    // Input assembly
    topology: vk.PrimitiveTopology = .triangle_list,
    primitive_restart_enable: bool = false,

    // Descriptor set layout
    descriptor_bindings: std.ArrayList(DescriptorBinding),
    push_constant_ranges: std.ArrayList(PushConstantRange),

    // Pipeline state
    rasterization_state: RasterizationState = RasterizationState.default(),
    multisample_state: MultisampleState = MultisampleState.default(),
    depth_stencil_state: DepthStencilState = DepthStencilState.default(),
    color_blend_attachments: std.ArrayList(ColorBlendAttachment),

    // Dynamic state
    dynamic_states: std.ArrayList(vk.DynamicState),

    // Render pass compatibility (legacy)
    render_pass: ?vk.RenderPass = null,
    subpass: u32 = 0,

    // Dynamic rendering (VK_KHR_dynamic_rendering)
    // If color_attachment_formats is set, use dynamic rendering instead of render pass
    color_attachment_formats: ?[]const vk.Format = null,
    depth_attachment_format: vk.Format = .undefined,
    stencil_attachment_format: vk.Format = .undefined,
    view_mask: u32 = 0, // For VK_KHR_multiview support

    // Compute specific
    compute_shader: ?*const Shader = null,

    // Raytracing specific
    raygen_shader: ?*const Shader = null,
    miss_shaders: std.ArrayList(*const Shader),
    hit_shaders: std.ArrayList(*const Shader),

    pub fn init(allocator: std.mem.Allocator, graphics_context: *GraphicsContext) PipelineBuilder {
        return PipelineBuilder{
            .allocator = allocator,
            .graphics_context = graphics_context,
            .shader_stages = .{},
            .vertex_bindings = .{},
            .vertex_attributes = .{},
            .descriptor_bindings = .{},
            .push_constant_ranges = .{},
            .color_blend_attachments = .{},
            .dynamic_states = .{},
            .miss_shaders = .{},
            .hit_shaders = .{},
        };
    }

    pub fn deinit(self: *PipelineBuilder) void {
        self.shader_stages.deinit(self.allocator);
        self.vertex_bindings.deinit(self.allocator);
        self.vertex_attributes.deinit(self.allocator);
        self.descriptor_bindings.deinit(self.allocator);
        self.push_constant_ranges.deinit(self.allocator);
        self.color_blend_attachments.deinit(self.allocator);
        self.dynamic_states.deinit(self.allocator);
        self.miss_shaders.deinit(self.allocator);
        self.hit_shaders.deinit(self.allocator);
    }

    /// Set the pipeline cache to use for pipeline creation
    pub fn setPipelineCache(self: *PipelineBuilder, cache: vk.PipelineCache) *PipelineBuilder {
        self.pipeline_cache = cache;
        return self;
    }

    // Pipeline type configuration
    pub fn graphics(self: *PipelineBuilder) *PipelineBuilder {
        self.pipeline_type = .graphics;
        return self;
    }

    pub fn compute(self: *PipelineBuilder) *PipelineBuilder {
        self.pipeline_type = .compute;
        return self;
    }

    pub fn raytracing(self: *PipelineBuilder) *PipelineBuilder {
        self.pipeline_type = .raytracing;
        return self;
    }

    // Shader stage configuration
    pub fn addShaderStage(self: *PipelineBuilder, stage: vk.ShaderStageFlags, shader: *const Shader) !*PipelineBuilder {
        try self.shader_stages.append(self.allocator, ShaderStage{
            .stage = stage,
            .shader = shader,
        });
        return self;
    }

    pub fn vertexShader(self: *PipelineBuilder, shader: *const Shader) !*PipelineBuilder {
        return self.addShaderStage(.{ .vertex_bit = true }, shader);
    }

    pub fn fragmentShader(self: *PipelineBuilder, shader: *const Shader) !*PipelineBuilder {
        return self.addShaderStage(.{ .fragment_bit = true }, shader);
    }

    pub fn computeShader(self: *PipelineBuilder, shader: *const Shader) !*PipelineBuilder {
        self.compute_shader = shader;
        self.pipeline_type = .compute;
        return self;
    }

    // Vertex input configuration
    pub fn addVertexBinding(self: *PipelineBuilder, binding: VertexInputBinding) !*PipelineBuilder {
        try self.vertex_bindings.append(self.allocator, binding);
        return self;
    }

    pub fn addVertexAttribute(self: *PipelineBuilder, attribute: VertexInputAttribute) !*PipelineBuilder {
        try self.vertex_attributes.append(self.allocator, attribute);
        return self;
    }

    // Input assembly
    pub fn triangleList(self: *PipelineBuilder) *PipelineBuilder {
        self.topology = .triangle_list;
        return self;
    }

    pub fn triangleStrip(self: *PipelineBuilder) *PipelineBuilder {
        self.topology = .triangle_strip;
        return self;
    }

    pub fn lineList(self: *PipelineBuilder) *PipelineBuilder {
        self.topology = .line_list;
        return self;
    }

    pub fn pointList(self: *PipelineBuilder) *PipelineBuilder {
        self.topology = .point_list;
        return self;
    }

    // Descriptor layout
    pub fn addDescriptorBinding(self: *PipelineBuilder, binding: DescriptorBinding) !*PipelineBuilder {
        // Ensure the ArrayList is properly initialized
        if (self.descriptor_bindings.capacity == 0) {
            try self.descriptor_bindings.ensureTotalCapacity(self.allocator, 8);
        }
        try self.descriptor_bindings.append(self.allocator, binding);
        return self;
    }

    pub fn addPushConstantRange(self: *PipelineBuilder, range: PushConstantRange) !*PipelineBuilder {
        try self.push_constant_ranges.append(self.allocator, range);
        return self;
    }

    // Pipeline state
    pub fn withRasterizationState(self: *PipelineBuilder, state: RasterizationState) *PipelineBuilder {
        self.rasterization_state = state;
        return self;
    }

    pub fn withMultisampleState(self: *PipelineBuilder, state: MultisampleState) *PipelineBuilder {
        self.multisample_state = state;
        return self;
    }

    pub fn withDepthStencilState(self: *PipelineBuilder, state: DepthStencilState) *PipelineBuilder {
        self.depth_stencil_state = state;
        return self;
    }

    pub fn addColorBlendAttachment(self: *PipelineBuilder, attachment: ColorBlendAttachment) !*PipelineBuilder {
        try self.color_blend_attachments.append(self.allocator, attachment);
        return self;
    }

    // Dynamic state
    pub fn addDynamicState(self: *PipelineBuilder, state: vk.DynamicState) !*PipelineBuilder {
        // Check if this dynamic state is already added to avoid duplicates
        for (self.dynamic_states.items) |existing_state| {
            if (existing_state == state) {
                return self; // Already exists, don't add duplicate
            }
        }
        try self.dynamic_states.append(self.allocator, state);
        return self;
    }

    pub fn dynamicViewportScissor(self: *PipelineBuilder) !*PipelineBuilder {
        _ = try self.addDynamicState(.viewport);
        _ = try self.addDynamicState(.scissor);
        return self;
    }

    // Render pass
    pub fn withRenderPass(self: *PipelineBuilder, render_pass: vk.RenderPass, subpass: u32) *PipelineBuilder {
        self.render_pass = render_pass;
        self.subpass = subpass;
        return self;
    }

    /// Configure pipeline for dynamic rendering (VK_KHR_dynamic_rendering)
    /// Use this instead of withRenderPass for modern Vulkan 1.3+ rendering
    pub fn withDynamicRendering(
        self: *PipelineBuilder,
        color_formats: []const vk.Format,
        depth_format: vk.Format,
    ) *PipelineBuilder {
        self.color_attachment_formats = color_formats;
        self.depth_attachment_format = depth_format;
        self.stencil_attachment_format = .undefined;
        self.render_pass = null; // Clear render pass
        return self;
    }

    /// Configure pipeline for dynamic rendering with multiview support
    pub fn withDynamicRenderingMultiview(
        self: *PipelineBuilder,
        color_formats: []const vk.Format,
        depth_format: vk.Format,
        view_mask: u32,
    ) *PipelineBuilder {
        self.color_attachment_formats = color_formats;
        self.depth_attachment_format = depth_format;
        self.stencil_attachment_format = .undefined;
        self.view_mask = view_mask;
        self.render_pass = null; // Clear render pass
        return self;
    }

    /// Configure pipeline for dynamic rendering with stencil
    pub fn withDynamicRenderingStencil(
        self: *PipelineBuilder,
        color_formats: []const vk.Format,
        depth_format: vk.Format,
        stencil_format: vk.Format,
    ) *PipelineBuilder {
        self.color_attachment_formats = color_formats;
        self.depth_attachment_format = depth_format;
        self.stencil_attachment_format = stencil_format;
        self.render_pass = null; // Clear render pass
        return self;
    }

    // Build methods
    pub fn buildDescriptorSetLayout(self: *PipelineBuilder) !vk.DescriptorSetLayout {
        var bindings: std.ArrayList(vk.DescriptorSetLayoutBinding) = .{};
        try bindings.ensureTotalCapacity(self.allocator, self.descriptor_bindings.items.len);
        defer bindings.deinit(self.allocator);

        for (self.descriptor_bindings.items) |binding| {
            try bindings.append(self.allocator, vk.DescriptorSetLayoutBinding{
                .binding = binding.binding,
                .descriptor_type = binding.descriptor_type,
                .descriptor_count = binding.descriptor_count,
                .stage_flags = binding.stage_flags,
                .p_immutable_samplers = binding.immutable_samplers,
            });
        }

        const create_info = vk.DescriptorSetLayoutCreateInfo{
            .binding_count = @intCast(bindings.items.len),
            .p_bindings = if (bindings.items.len > 0) bindings.items.ptr else null,
        };

        return try self.graphics_context.vkd.createDescriptorSetLayout(self.graphics_context.dev, &create_info, null);
    }

    pub fn buildDescriptorSetLayouts(self: *PipelineBuilder, descriptor_sets: []const []const DescriptorBinding, allocator: std.mem.Allocator) ![]vk.DescriptorSetLayout {
        var layouts = try allocator.alloc(vk.DescriptorSetLayout, descriptor_sets.len);

        for (descriptor_sets, 0..) |set_bindings, set_index| {
            var bindings: std.ArrayList(vk.DescriptorSetLayoutBinding) = .{};
            try bindings.ensureTotalCapacity(allocator, set_bindings.len);
            defer bindings.deinit(allocator);

            for (set_bindings) |binding| {
                try bindings.append(allocator, vk.DescriptorSetLayoutBinding{
                    .binding = binding.binding,
                    .descriptor_type = binding.descriptor_type,
                    .descriptor_count = binding.descriptor_count,
                    .stage_flags = binding.stage_flags,
                    .p_immutable_samplers = binding.immutable_samplers,
                });
            }

            const create_info = vk.DescriptorSetLayoutCreateInfo{
                .binding_count = @intCast(bindings.items.len),
                .p_bindings = if (bindings.items.len > 0) bindings.items.ptr else null,
            };

            layouts[set_index] = try self.graphics_context.vkd.createDescriptorSetLayout(self.graphics_context.dev, &create_info, null);
        }

        return layouts;
    }

    pub fn buildPipelineLayout(self: *PipelineBuilder, descriptor_set_layouts: []const vk.DescriptorSetLayout) !vk.PipelineLayout {
        var push_constants: std.ArrayList(vk.PushConstantRange) = .{};
        try push_constants.ensureTotalCapacity(self.allocator, self.push_constant_ranges.items.len);
        defer push_constants.deinit(self.allocator);

        for (self.push_constant_ranges.items) |range| {
            try push_constants.append(self.allocator, vk.PushConstantRange{
                .stage_flags = range.stage_flags,
                .offset = range.offset,
                .size = range.size,
            });
        }

        const create_info = vk.PipelineLayoutCreateInfo{
            .set_layout_count = @intCast(descriptor_set_layouts.len),
            .p_set_layouts = if (descriptor_set_layouts.len > 0) descriptor_set_layouts.ptr else null,
            .push_constant_range_count = @intCast(push_constants.items.len),
            .p_push_constant_ranges = if (push_constants.items.len > 0) push_constants.items.ptr else null,
        };

        return try self.graphics_context.vkd.createPipelineLayout(self.graphics_context.dev, &create_info, null);
    }

    pub fn buildGraphicsPipeline(self: *PipelineBuilder, pipeline_layout: vk.PipelineLayout) !vk.Pipeline {
        if (self.pipeline_type != .graphics) return error.InvalidPipelineType;

        // Either render pass OR dynamic rendering must be configured
        const use_dynamic_rendering = self.color_attachment_formats != null;
        if (!use_dynamic_rendering and self.render_pass == null) {
            return error.MissingRenderPassOrDynamicRendering;
        }

        // Build shader stages
        var stages: std.ArrayList(vk.PipelineShaderStageCreateInfo) = .{};
        try stages.ensureTotalCapacity(self.allocator, self.shader_stages.items.len);
        defer stages.deinit(self.allocator);

        for (self.shader_stages.items, 0..) |stage, i| {
            _ = i; // suppress unused variable warning
            try stages.append(self.allocator, vk.PipelineShaderStageCreateInfo{
                .stage = @bitCast(stage.stage),
                .module = stage.shader.module,
                .p_name = stage.entry_point.ptr,
                .p_specialization_info = stage.specialization_info,
            });
        }

        // Build vertex input state
        var vertex_bindings_vk: std.ArrayList(vk.VertexInputBindingDescription) = .{};
        try vertex_bindings_vk.ensureTotalCapacity(self.allocator, self.vertex_bindings.items.len);
        defer vertex_bindings_vk.deinit(self.allocator);
        var vertex_attributes_vk: std.ArrayList(vk.VertexInputAttributeDescription) = .{};
        try vertex_attributes_vk.ensureTotalCapacity(self.allocator, self.vertex_attributes.items.len);
        defer vertex_attributes_vk.deinit(self.allocator);

        for (self.vertex_bindings.items) |binding| {
            try vertex_bindings_vk.append(self.allocator, vk.VertexInputBindingDescription{
                .binding = binding.binding,
                .stride = binding.stride,
                .input_rate = binding.input_rate,
            });
        }

        for (self.vertex_attributes.items) |attribute| {
            try vertex_attributes_vk.append(self.allocator, vk.VertexInputAttributeDescription{
                .location = attribute.location,
                .binding = attribute.binding,
                .format = attribute.format,
                .offset = attribute.offset,
            });
        }

        const vertex_input_state = vk.PipelineVertexInputStateCreateInfo{
            .vertex_binding_description_count = @intCast(vertex_bindings_vk.items.len),
            .p_vertex_binding_descriptions = if (vertex_bindings_vk.items.len > 0) vertex_bindings_vk.items.ptr else null,
            .vertex_attribute_description_count = @intCast(vertex_attributes_vk.items.len),
            .p_vertex_attribute_descriptions = if (vertex_attributes_vk.items.len > 0) vertex_attributes_vk.items.ptr else null,
        };

        // Input assembly state
        const input_assembly_state = vk.PipelineInputAssemblyStateCreateInfo{
            .topology = self.topology,
            .primitive_restart_enable = if (self.primitive_restart_enable) .true else .false,
        };

        // Viewport state (using dynamic state)
        const viewport_state = vk.PipelineViewportStateCreateInfo{
            .viewport_count = 1,
            .scissor_count = 1,
        };

        // Rasterization state
        const rasterization_state = vk.PipelineRasterizationStateCreateInfo{
            .depth_clamp_enable = if (self.rasterization_state.depth_clamp_enable) .true else .false,
            .rasterizer_discard_enable = if (self.rasterization_state.rasterizer_discard_enable) .true else .false,
            .polygon_mode = self.rasterization_state.polygon_mode,
            .cull_mode = self.rasterization_state.cull_mode,
            .front_face = self.rasterization_state.front_face,
            .depth_bias_enable = if (self.rasterization_state.depth_bias_enable) .true else .false,
            .depth_bias_constant_factor = self.rasterization_state.depth_bias_constant_factor,
            .depth_bias_clamp = self.rasterization_state.depth_bias_clamp,
            .depth_bias_slope_factor = self.rasterization_state.depth_bias_slope_factor,
            .line_width = self.rasterization_state.line_width,
        };

        // Multisample state
        const multisample_state = vk.PipelineMultisampleStateCreateInfo{
            .rasterization_samples = @bitCast(self.multisample_state.rasterization_samples),
            .sample_shading_enable = if (self.multisample_state.sample_shading_enable) .true else .false,
            .min_sample_shading = self.multisample_state.min_sample_shading,
            .p_sample_mask = if (self.multisample_state.sample_mask) |mask| @ptrCast(mask) else null,
            .alpha_to_coverage_enable = if (self.multisample_state.alpha_to_coverage_enable) .true else .false,
            .alpha_to_one_enable = if (self.multisample_state.alpha_to_one_enable) .true else .false,
        };

        // Depth stencil state
        const depth_stencil_state = vk.PipelineDepthStencilStateCreateInfo{
            .depth_test_enable = if (self.depth_stencil_state.depth_test_enable) .true else .false,
            .depth_write_enable = if (self.depth_stencil_state.depth_write_enable) .true else .false,
            .depth_compare_op = self.depth_stencil_state.depth_compare_op,
            .depth_bounds_test_enable = if (self.depth_stencil_state.depth_bounds_test_enable) .true else .false,
            .stencil_test_enable = if (self.depth_stencil_state.stencil_test_enable) .true else .false,
            .front = self.depth_stencil_state.front,
            .back = self.depth_stencil_state.back,
            .min_depth_bounds = self.depth_stencil_state.min_depth_bounds,
            .max_depth_bounds = self.depth_stencil_state.max_depth_bounds,
        };

        // Color blend state
        var color_blend_attachments_vk: std.ArrayList(vk.PipelineColorBlendAttachmentState) = .{};
        try color_blend_attachments_vk.ensureTotalCapacity(self.allocator, self.color_blend_attachments.items.len);
        defer color_blend_attachments_vk.deinit(self.allocator);

        for (self.color_blend_attachments.items) |attachment| {
            try color_blend_attachments_vk.append(self.allocator, vk.PipelineColorBlendAttachmentState{
                .color_write_mask = attachment.color_write_mask,
                .blend_enable = if (attachment.blend_enable) .true else .false,
                .src_color_blend_factor = attachment.src_color_blend_factor,
                .dst_color_blend_factor = attachment.dst_color_blend_factor,
                .color_blend_op = attachment.color_blend_op,
                .src_alpha_blend_factor = attachment.src_alpha_blend_factor,
                .dst_alpha_blend_factor = attachment.dst_alpha_blend_factor,
                .alpha_blend_op = attachment.alpha_blend_op,
            });
        }

        const color_blend_state = vk.PipelineColorBlendStateCreateInfo{
            .logic_op_enable = .false,
            .logic_op = .copy,
            .attachment_count = @intCast(color_blend_attachments_vk.items.len),
            .p_attachments = if (color_blend_attachments_vk.items.len > 0) color_blend_attachments_vk.items.ptr else null,
            .blend_constants = [4]f32{ 0.0, 0.0, 0.0, 0.0 },
        };

        // Dynamic state
        const dynamic_state = vk.PipelineDynamicStateCreateInfo{
            .dynamic_state_count = @intCast(self.dynamic_states.items.len),
            .p_dynamic_states = if (self.dynamic_states.items.len > 0) self.dynamic_states.items.ptr else null,
        };

        // Dynamic rendering info (VK_KHR_dynamic_rendering)
        var dynamic_rendering_info: vk.PipelineRenderingCreateInfo = undefined;
        if (use_dynamic_rendering) {
            dynamic_rendering_info = vk.PipelineRenderingCreateInfo{
                .s_type = .pipeline_rendering_create_info,
                .p_next = null,
                .view_mask = self.view_mask,
                .color_attachment_count = @intCast(self.color_attachment_formats.?.len),
                .p_color_attachment_formats = self.color_attachment_formats.?.ptr,
                .depth_attachment_format = self.depth_attachment_format,
                .stencil_attachment_format = self.stencil_attachment_format,
            };
        }

        // Create pipeline
        var create_info = vk.GraphicsPipelineCreateInfo{
            .s_type = .graphics_pipeline_create_info,
            .p_next = if (use_dynamic_rendering) &dynamic_rendering_info else null,
            .flags = .{},
            .stage_count = @intCast(stages.items.len),
            .p_stages = stages.items.ptr,
            .p_vertex_input_state = &vertex_input_state,
            .p_input_assembly_state = &input_assembly_state,
            .p_tessellation_state = null,
            .p_viewport_state = &viewport_state,
            .p_rasterization_state = &rasterization_state,
            .p_multisample_state = &multisample_state,
            .p_depth_stencil_state = &depth_stencil_state,
            .p_color_blend_state = &color_blend_state,
            .p_dynamic_state = if (self.dynamic_states.items.len > 0) &dynamic_state else null,
            .layout = pipeline_layout,
            .render_pass = if (use_dynamic_rendering) .null_handle else self.render_pass.?,
            .subpass = self.subpass,
            .base_pipeline_handle = .null_handle,
            .base_pipeline_index = -1,
        };

        var pipeline: vk.Pipeline = undefined;
        _ = try self.graphics_context.vkd.createGraphicsPipelines(self.graphics_context.dev, self.pipeline_cache, 1, @ptrCast(&create_info), null, @ptrCast(&pipeline));

        return pipeline;
    }

    pub fn buildComputePipeline(self: *PipelineBuilder, pipeline_layout: vk.PipelineLayout) !vk.Pipeline {
        if (self.pipeline_type != .compute) return error.InvalidPipelineType;
        if (self.compute_shader == null) return error.MissingComputeShader;

        const create_info = vk.ComputePipelineCreateInfo{
            .stage = vk.PipelineShaderStageCreateInfo{
                .stage = .{ .compute_bit = true },
                .module = self.compute_shader.?.module,
                .p_name = "main",
            },
            .layout = pipeline_layout,
            .base_pipeline_handle = .null_handle,
            .base_pipeline_index = -1,
        };

        var pipeline: vk.Pipeline = undefined;
        _ = try self.graphics_context.vkd.createComputePipelines(self.graphics_context.dev, self.pipeline_cache, 1, @ptrCast(&create_info), null, @ptrCast(&pipeline));

        return pipeline;
    }

    /// Build a raytracing pipeline
    /// NOTE: This is a placeholder - full raytracing pipeline implementation requires:
    /// - Shader binding table setup
    /// - Ray generation, miss, and hit shader groups
    /// - Proper raytracing pipeline creation info
    pub fn buildRaytracingPipeline(self: *PipelineBuilder, pipeline_layout: vk.PipelineLayout) !vk.Pipeline {
        _ = self;
        _ = pipeline_layout;

        // TODO: Implement full raytracing pipeline creation
        // For now, return an error indicating this needs implementation
        return error.RaytracingPipelineNotImplemented;
    }
};

/// Pipeline builder factory with common configurations
pub const PipelineBuilders = struct {
    /// Create a basic 3D rendering pipeline
    pub fn basic3D(allocator: std.mem.Allocator, graphics_context: *GraphicsContext, vertex_shader: *const Shader, fragment_shader: *const Shader) !*PipelineBuilder {
        var builder = try allocator.create(PipelineBuilder);
        builder.* = PipelineBuilder.init(allocator, graphics_context);

        _ = try builder.graphics()
            .vertexShader(vertex_shader)
            .fragmentShader(fragment_shader)
            .triangleList()
            .dynamicViewportScissor()
            .withRasterizationState(RasterizationState.default())
            .withDepthStencilState(DepthStencilState.default())
            .addColorBlendAttachment(ColorBlendAttachment.disabled());

        return builder;
    }

    /// Create a compute pipeline
    pub fn computePipeline(allocator: std.mem.Allocator, graphics_context: *GraphicsContext, compute_shader: *const Shader) !*PipelineBuilder {
        var builder = try allocator.create(PipelineBuilder);
        builder.* = PipelineBuilder.init(allocator, graphics_context);

        _ = builder.compute().computeShader(compute_shader);

        return builder;
    }

    /// Create a shadow mapping pipeline
    pub fn shadowMap(allocator: std.mem.Allocator, graphics_context: *GraphicsContext, vertex_shader: *const Shader) !*PipelineBuilder {
        var builder = try allocator.create(PipelineBuilder);
        builder.* = PipelineBuilder.init(allocator, graphics_context);

        _ = try builder.graphics()
            .vertexShader(vertex_shader)
            .triangleList()
            .dynamicViewportScissor()
            .withRasterizationState(RasterizationState.default().withDepthBias(1.25, 1.75))
            .withDepthStencilState(DepthStencilState.default());

        return builder;
    }

    /// Create a post-processing pipeline
    pub fn postProcess(allocator: std.mem.Allocator, graphics_context: *GraphicsContext, vertex_shader: *const Shader, fragment_shader: *const Shader) !*PipelineBuilder {
        var builder = try allocator.create(PipelineBuilder);
        builder.* = PipelineBuilder.init(allocator, graphics_context);

        _ = try builder.graphics()
            .vertexShader(vertex_shader)
            .fragmentShader(fragment_shader)
            .triangleList()
            .dynamicViewportScissor()
            .withRasterizationState(RasterizationState.default().noCulling())
            .withDepthStencilState(DepthStencilState.disabled())
            .addColorBlendAttachment(ColorBlendAttachment.disabled());

        return builder;
    }
};
