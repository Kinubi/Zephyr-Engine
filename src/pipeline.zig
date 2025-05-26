const std = @import("std");
const vk = @import("vulkan");
const GC = @import("graphics_context.zig").GraphicsContext;
const Vertex = @import("mesh.zig").Vertex;
const ShaderLibrary = @import("shader.zig").ShaderLibrary;

pub const Pipeline = struct {
    gc: GC,
    pipeline: vk.Pipeline,
    render_pass: vk.RenderPass,

    pub fn init(
        gc: GC,
        render_pass: vk.RenderPass,
        shader_library: ShaderLibrary,
        gpci: vk.GraphicsPipelineCreateInfo,
        alloc: std.mem.Allocator,
    ) !Pipeline {
        var pssci = std.ArrayList(vk.PipelineShaderStageCreateInfo).init(alloc);
        for (shader_library.shaders.items) |shader| {
            try pssci.append(vk.PipelineShaderStageCreateInfo{
                .flags = .{},
                .stage = shader.shader_type,
                .module = shader.module,
                .p_name = @ptrCast(shader.entry_point.name.ptr),
                .p_specialization_info = null,
            });
        }
        errdefer shader_library.deinit();

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
        };
    }

    pub fn deinit(self: *Pipeline) void {
        self.gc.vkd.destroyPipeline(self.gc.dev, self.pipeline, null);
    }

    pub fn defaultLayout(layout: vk.PipelineLayout) !vk.GraphicsPipelineCreateInfo {
        const piasci = vk.PipelineInputAssemblyStateCreateInfo{
            .flags = .{},
            .topology = .triangle_list,
            .primitive_restart_enable = vk.FALSE,
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
            .depth_clamp_enable = vk.FALSE,
            .rasterizer_discard_enable = vk.FALSE,
            .polygon_mode = .fill,
            .cull_mode = .{},
            .front_face = .clockwise,
            .depth_bias_enable = vk.FALSE,
            .depth_bias_constant_factor = 0,
            .depth_bias_clamp = 0,
            .depth_bias_slope_factor = 0,
            .line_width = 1,
        };

        const pmsci = vk.PipelineMultisampleStateCreateInfo{
            .flags = .{},
            .rasterization_samples = .{ .@"1_bit" = true },
            .sample_shading_enable = vk.FALSE,
            .min_sample_shading = 1,
            .p_sample_mask = null,
            .alpha_to_coverage_enable = vk.FALSE,
            .alpha_to_one_enable = vk.FALSE,
        };

        const pdssci = vk.PipelineDepthStencilStateCreateInfo{
            .flags = .{},
            .depth_test_enable = vk.TRUE,
            .depth_write_enable = vk.TRUE,
            .depth_compare_op = vk.CompareOp.less_or_equal,
            .depth_bounds_test_enable = vk.FALSE,
            .stencil_test_enable = vk.FALSE,
            .front = undefined,
            .back = undefined,
            .min_depth_bounds = 0,
            .max_depth_bounds = 1,
        };

        const pcbas = vk.PipelineColorBlendAttachmentState{
            .blend_enable = vk.FALSE,
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
            .logic_op_enable = vk.FALSE,
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
        rpcik: vk.RayTracingPipelineCreateInfoKHR,
        alloc: std.mem.Allocator,
    ) !Pipeline {
        var pssci = std.ArrayList(vk.PipelineShaderStageCreateInfo).init(alloc);
        for (shader_library.shaders.items) |shader| {
            try pssci.append(vk.PipelineShaderStageCreateInfo{
                .flags = .{},
                .stage = shader.shader_type,
                .module = shader.module,
                .p_name = @ptrCast(shader.entry_point.name.ptr),
                .p_specialization_info = null,
            });
        }
        errdefer shader_library.deinit();

        var rpcik_var = rpcik;
        rpcik_var.stage_count = @intCast(pssci.items.len);
        rpcik_var.p_stages = pssci.items.ptr;

        // --- Begin group array setup ---
        // Use shader_library.shaders.items for group info (revert to previous logic)
        const group_count = shader_library.shaders.items.len;
        const group_array = try alloc.alloc(vk.RayTracingShaderGroupCreateInfoKHR, group_count);
        for (group_array) |*dst_group| {
            dst_group.* = vk.RayTracingShaderGroupCreateInfoKHR{
                .s_type = vk.StructureType.ray_tracing_shader_group_create_info_khr,
                .p_next = null,
                .type = undefined, // Set below
                .general_shader = vk.SHADER_UNUSED_KHR,
                .closest_hit_shader = vk.SHADER_UNUSED_KHR,
                .any_hit_shader = vk.SHADER_UNUSED_KHR,
                .intersection_shader = vk.SHADER_UNUSED_KHR,
                .p_shader_group_capture_replay_handle = null,
            };
            // Set type based on general_shader/intersection_shader as before
            if (dst_group.intersection_shader != vk.SHADER_UNUSED_KHR) {
                dst_group.type = vk.RayTracingShaderGroupTypeKHR.procedural_hit_group_khr;
            } else if (dst_group.general_shader != vk.SHADER_UNUSED_KHR) {
                dst_group.type = vk.RayTracingShaderGroupTypeKHR.general_khr;
            } else {
                dst_group.type = vk.RayTracingShaderGroupTypeKHR.triangles_hit_group_khr;
            }
        }
        rpcik_var.group_count = @intCast(group_count);
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
        };
    }
};
