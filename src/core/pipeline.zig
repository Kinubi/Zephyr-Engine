const std = @import("std");
const vk = @import("vulkan");
const GC = @import("graphics_context.zig").GraphicsContext;
const Vertex = @import("../rendering/mesh.zig").Vertex;
const ShaderLibrary = @import("shader.zig").ShaderLibrary;
const Particle = @import("../renderers/renderer.zig").Particle;

pub const Pipeline = struct {
    gc: GC,
    pipeline: vk.Pipeline,
    render_pass: vk.RenderPass,
    shader_library: ShaderLibrary,
    pipeline_layout: vk.PipelineLayout, // Store the layout

    pub fn init(
        gc: GC,
        render_pass: vk.RenderPass,
        shader_library: ShaderLibrary,
        layout: vk.PipelineLayout,
        gpci: vk.GraphicsPipelineCreateInfo,
        alloc: std.mem.Allocator,
    ) !Pipeline {
        var pssci = std.ArrayList(vk.PipelineShaderStageCreateInfo){};
        for (shader_library.shaders.items) |shader| {
            try pssci.append(alloc, vk.PipelineShaderStageCreateInfo{
                .flags = .{},
                .stage = shader.shader_type,
                .module = shader.module,
                .p_name = @ptrCast(shader.entry_point.name.ptr),
                .p_specialization_info = null,
            });
        }
        // Do not defer shader_library.deinit(); now owned by Pipeline

        const pvisci = vk.PipelineVertexInputStateCreateInfo{
            .flags = .{},
            .vertex_binding_description_count = 1,
            .p_vertex_binding_descriptions = @as([*]const vk.VertexInputBindingDescription, @ptrCast(&Vertex.binding_description)),
            .vertex_attribute_description_count = Vertex.attribute_description.len,
            .p_vertex_attribute_descriptions = &Vertex.attribute_description,
        };

        var gpci_var = gpci;
        gpci_var.render_pass = render_pass;
        gpci_var.stage_count = @intCast(pssci.items.len);
        gpci_var.p_stages = pssci.items.ptr;
        gpci_var.p_vertex_input_state = &pvisci;

        var pipeline: vk.Pipeline = undefined;
        _ = try gc.vkd.createGraphicsPipelines(
            gc.dev,
            .null_handle,
            1,
            @as([*]const vk.GraphicsPipelineCreateInfo, @ptrCast(&gpci_var)),
            null,
            @as([*]vk.Pipeline, @ptrCast(&pipeline)),
        );

        return Pipeline{
            .gc = gc,
            .pipeline = pipeline,
            .render_pass = render_pass,
            .shader_library = shader_library,
            .pipeline_layout = layout,
        };
    }

    pub fn initParticles(
        gc: GC,
        render_pass: vk.RenderPass,
        shader_library: ShaderLibrary,
        layout: vk.PipelineLayout,
        gpci: vk.GraphicsPipelineCreateInfo,
        alloc: std.mem.Allocator,
    ) !Pipeline {
        var pssci = std.ArrayList(vk.PipelineShaderStageCreateInfo){};
        for (shader_library.shaders.items) |shader| {
            try pssci.append(alloc, vk.PipelineShaderStageCreateInfo{
                .flags = .{},
                .stage = shader.shader_type,
                .module = shader.module,
                .p_name = @ptrCast(shader.entry_point.name.ptr),
                .p_specialization_info = null,
            });
        }
        // Do not defer shader_library.deinit(); now owned by Pipeline

        const pvisci = vk.PipelineVertexInputStateCreateInfo{
            .flags = .{},
            .vertex_binding_description_count = 1,
            .p_vertex_binding_descriptions = @as([*]const vk.VertexInputBindingDescription, @ptrCast(&Particle.binding_description)),
            .vertex_attribute_description_count = Particle.attribute_description.len,
            .p_vertex_attribute_descriptions = &Vertex.attribute_description,
        };

        var gpci_var = gpci;
        gpci_var.render_pass = render_pass;
        gpci_var.stage_count = @intCast(pssci.items.len);
        gpci_var.p_stages = pssci.items.ptr;
        gpci_var.p_vertex_input_state = &pvisci;

        var pipeline: vk.Pipeline = undefined;
        _ = try gc.vkd.createGraphicsPipelines(
            gc.dev,
            .null_handle,
            1,
            @as([*]const vk.GraphicsPipelineCreateInfo, @ptrCast(&gpci_var)),
            null,
            @as([*]vk.Pipeline, @ptrCast(&pipeline)),
        );

        return Pipeline{
            .gc = gc,
            .pipeline = pipeline,
            .render_pass = render_pass,
            .shader_library = shader_library,
            .pipeline_layout = layout,
        };
    }

    pub fn deinit(self: *Pipeline) void {
        // Destroy pipeline
        if (self.pipeline != .null_handle) {
            self.gc.vkd.destroyPipeline(self.gc.dev, self.pipeline, null);
            self.pipeline = .null_handle;
        }
        // Destroy pipeline layout
        if (self.pipeline_layout != .null_handle) {
            self.gc.vkd.destroyPipelineLayout(self.gc.dev, self.pipeline_layout, null);
            self.pipeline_layout = .null_handle;
        }
        // Destroy all shader modules in the owned shader library
        self.shader_library.deinit();
    }

    pub fn defaultLayout(layout: vk.PipelineLayout) !vk.GraphicsPipelineCreateInfo {
        const piasci = vk.PipelineInputAssemblyStateCreateInfo{
            .flags = .{},
            .topology = .triangle_list,
            .primitive_restart_enable = .false,
        };

        const pvsci = vk.PipelineViewportStateCreateInfo{
            .flags = .{},
            .viewport_count = 1,
            .p_viewports = undefined, // set in createCommandBuffers with cmdSetViewport
            .scissor_count = 1,
            .p_scissors = undefined, // set in createCommandBuffers with cmdSetScissor
        };

        const prsci = vk.PipelineRasterizationStateCreateInfo{
            .flags = .{},
            .depth_clamp_enable = .false,
            .rasterizer_discard_enable = .false,
            .polygon_mode = .fill,
            .cull_mode = .{},
            .front_face = .clockwise,
            .depth_bias_enable = .false,
            .depth_bias_constant_factor = 0,
            .depth_bias_clamp = 0,
            .depth_bias_slope_factor = 0,
            .line_width = 1,
        };

        const pmsci = vk.PipelineMultisampleStateCreateInfo{
            .flags = .{},
            .rasterization_samples = .{ .@"1_bit" = true },
            .sample_shading_enable = .false,
            .min_sample_shading = 1,
            .p_sample_mask = null,
            .alpha_to_coverage_enable = .false,
            .alpha_to_one_enable = .false,
        };

        const pdssci = vk.PipelineDepthStencilStateCreateInfo{
            .flags = .{},
            .depth_test_enable = .true,
            .depth_write_enable = .true,
            .depth_compare_op = vk.CompareOp.less_or_equal,
            .depth_bounds_test_enable = .false,
            .stencil_test_enable = .false,
            .front = .{
                .fail_op = .keep,
                .pass_op = .keep,
                .depth_fail_op = .keep,
                .compare_op = .never,
                .compare_mask = 0,
                .write_mask = 0,
                .reference = 0,
            },
            .back = .{
                .fail_op = .keep,
                .pass_op = .keep,
                .depth_fail_op = .keep,
                .compare_op = .never,
                .compare_mask = 0,
                .write_mask = 0,
                .reference = 0,
            },
            .min_depth_bounds = 0,
            .max_depth_bounds = 1,
        };

        const pcbas = vk.PipelineColorBlendAttachmentState{
            .blend_enable = .false,
            .src_color_blend_factor = .one,
            .dst_color_blend_factor = .zero,
            .color_blend_op = .add,
            .src_alpha_blend_factor = .one,
            .dst_alpha_blend_factor = .zero,
            .alpha_blend_op = .add,
            .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
        };

        const pcbsci = vk.PipelineColorBlendStateCreateInfo{
            .flags = .{},
            .logic_op_enable = .false,
            .logic_op = .copy,
            .attachment_count = 1,
            .p_attachments = @as([*]const vk.PipelineColorBlendAttachmentState, @ptrCast(&pcbas)),
            .blend_constants = [_]f32{ 0, 0, 0, 0 },
        };

        const dynstate = [_]vk.DynamicState{ .viewport, .scissor };
        const pdsci = vk.PipelineDynamicStateCreateInfo{
            .flags = .{},
            .dynamic_state_count = dynstate.len,
            .p_dynamic_states = &dynstate,
        };

        const gpci = vk.GraphicsPipelineCreateInfo{
            .flags = .{},
            .p_input_assembly_state = &piasci,
            .p_tessellation_state = null,
            .p_viewport_state = &pvsci,
            .p_rasterization_state = &prsci,
            .p_multisample_state = &pmsci,
            .p_depth_stencil_state = &pdssci,
            .p_color_blend_state = &pcbsci,
            .p_dynamic_state = &pdsci,
            .layout = layout,
            .subpass = 0,
            .base_pipeline_handle = .null_handle,
            .base_pipeline_index = -1,
        };
        return gpci;
    }

    pub fn defaultRaytracingLayout(layout: vk.PipelineLayout) vk.RayTracingPipelineCreateInfoKHR {
        return vk.RayTracingPipelineCreateInfoKHR{
            .s_type = vk.StructureType.ray_tracing_pipeline_create_info_khr,
            .p_next = null,
            .flags = .{},
            .stage_count = 0, // to be filled by caller
            .p_stages = null, // to be filled by caller
            .group_count = 3, // to be filled by caller
            .p_groups = null, // to be filled by caller
            .max_pipeline_ray_recursion_depth = 1,
            .layout = layout,
            .base_pipeline_handle = .null_handle,
            .base_pipeline_index = -1,
            .p_library_info = null,
            .p_library_interface = null,
            .p_dynamic_state = null,
        };
    }

    pub fn initRaytracing(
        gc: GC,
        render_pass: vk.RenderPass, // Unused for raytracing, but kept for API symmetry
        shader_library: ShaderLibrary,
        layout: vk.PipelineLayout,
        rpcik: vk.RayTracingPipelineCreateInfoKHR,
        alloc: std.mem.Allocator,
    ) !Pipeline {
        var pssci = std.ArrayList(vk.PipelineShaderStageCreateInfo){};
        for (shader_library.shaders.items) |shader| {
            try pssci.append(alloc, vk.PipelineShaderStageCreateInfo{
                .flags = .{},
                .stage = shader.shader_type,
                .module = shader.module,
                .p_name = @ptrCast(shader.entry_point.name.ptr),
                .p_specialization_info = null,
            });
        }

        var rpcik_var = rpcik;
        rpcik_var.stage_count = @intCast(pssci.items.len);
        rpcik_var.p_stages = pssci.items.ptr;

        // --- Begin group array setup ---
        // Explicitly set up raygen, miss, and hit groups in order
        const group_count = shader_library.shaders.items.len;
        if (group_count != 3) {
            return error.InvalidRayTracingShaderGroupCount;
        }
        const group_array = try alloc.alloc(vk.RayTracingShaderGroupCreateInfoKHR, 3);
        // Raygen group (index 0)
        group_array[0] = vk.RayTracingShaderGroupCreateInfoKHR{
            .s_type = vk.StructureType.ray_tracing_shader_group_create_info_khr,
            .p_next = null,
            .type = vk.RayTracingShaderGroupTypeKHR.general_khr,
            .general_shader = 0,
            .closest_hit_shader = vk.SHADER_UNUSED_KHR,
            .any_hit_shader = vk.SHADER_UNUSED_KHR,
            .intersection_shader = vk.SHADER_UNUSED_KHR,
            .p_shader_group_capture_replay_handle = null,
        };
        // Miss group (index 1)
        group_array[1] = vk.RayTracingShaderGroupCreateInfoKHR{
            .s_type = vk.StructureType.ray_tracing_shader_group_create_info_khr,
            .p_next = null,
            .type = vk.RayTracingShaderGroupTypeKHR.general_khr,
            .general_shader = 1,
            .closest_hit_shader = vk.SHADER_UNUSED_KHR,
            .any_hit_shader = vk.SHADER_UNUSED_KHR,
            .intersection_shader = vk.SHADER_UNUSED_KHR,
            .p_shader_group_capture_replay_handle = null,
        };
        // Closest hit group (index 2)
        group_array[2] = vk.RayTracingShaderGroupCreateInfoKHR{
            .s_type = vk.StructureType.ray_tracing_shader_group_create_info_khr,
            .p_next = null,
            .type = vk.RayTracingShaderGroupTypeKHR.triangles_hit_group_khr,
            .general_shader = vk.SHADER_UNUSED_KHR,
            .closest_hit_shader = 2,
            .any_hit_shader = vk.SHADER_UNUSED_KHR,
            .intersection_shader = vk.SHADER_UNUSED_KHR,
            .p_shader_group_capture_replay_handle = null,
        };
        rpcik_var.group_count = 3;
        rpcik_var.p_groups = group_array.ptr;
        // --- End group array setup ---

        var pipeline: vk.Pipeline = undefined;
        _ = try gc.vkd.createRayTracingPipelinesKHR(
            gc.dev,
            .null_handle,
            .null_handle,
            1,
            @as([*]const vk.RayTracingPipelineCreateInfoKHR, @ptrCast(&rpcik_var)),
            null,
            @as([*]vk.Pipeline, @ptrCast(&pipeline)),
        );

        return Pipeline{
            .gc = gc,
            .pipeline = pipeline,
            .render_pass = render_pass, // Not used for raytracing
            .shader_library = shader_library,
            .pipeline_layout = layout,
        };
    }

    pub fn defaultComputeLayout(layout: vk.PipelineLayout) vk.ComputePipelineCreateInfo {
        return vk.ComputePipelineCreateInfo{
            .s_type = vk.StructureType.compute_pipeline_create_info,
            .p_next = null,
            .flags = .{},
            .stage = undefined, // to be filled by caller
            .layout = layout,
            .base_pipeline_handle = .null_handle,
            .base_pipeline_index = -1,
        };
    }

    pub fn initCompute(
        gc: GC,
        render_pass: vk.RenderPass, // Unused for compute, kept for API symmetry
        shader_library: ShaderLibrary,
        layout: vk.PipelineLayout,
        cpci: vk.ComputePipelineCreateInfo,
    ) !Pipeline {
        if (shader_library.shaders.items.len != 1) {
            return error.InvalidComputeShaderCount;
        }
        const shader = shader_library.shaders.items[0];
        var cpci_var = cpci;
        cpci_var.stage = vk.PipelineShaderStageCreateInfo{
            .flags = .{},
            .stage = shader.shader_type,
            .module = shader.module,
            .p_name = @ptrCast(shader.entry_point.name.ptr),
            .p_specialization_info = null,
        };

        var pipeline: vk.Pipeline = undefined;
        _ = try gc.vkd.createComputePipelines(
            gc.dev,
            .null_handle,
            1,
            @as([*]const vk.ComputePipelineCreateInfo, @ptrCast(&cpci_var)),
            null,
            @as([*]vk.Pipeline, @ptrCast(&pipeline)),
        );

        return Pipeline{
            .gc = gc,
            .pipeline = pipeline,
            .render_pass = render_pass, // Not used for compute
            .shader_library = shader_library,
            .pipeline_layout = layout,
        };
    }
};
// Pipeline struct already stores gc as a member, matching the init signature. Allocator is not stored, as not needed after construction.
