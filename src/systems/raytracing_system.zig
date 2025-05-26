const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("../graphics_context.zig").GraphicsContext;
const Buffer = @import("../buffer.zig").Buffer;
const Scene = @import("../scene.zig").Scene;
const Vertex = @import("../mesh.zig").Vertex;
const FrameInfo = @import("../frameinfo.zig").FrameInfo;
const Pipeline = @import("../pipeline.zig").Pipeline;
const ShaderLibrary = @import("../shader.zig").ShaderLibrary;

/// Raytracing system for Vulkan: manages BLAS/TLAS, pipeline, shader table, output, and dispatch.
pub const RaytracingSystem = struct {
    gc: *GraphicsContext, // Use 'gc' for consistency with Swapchain
    pipeline: Pipeline = undefined,
    pipeline_layout: vk.PipelineLayout = undefined,
    descriptor_set_layout: vk.DescriptorSetLayout = undefined,
    output_image: vk.Image = undefined,
    output_image_view: vk.ImageView = undefined,
    output_memory: vk.DeviceMemory = undefined,
    blas: vk.AccelerationStructureKHR = undefined,
    tlas: vk.AccelerationStructureKHR = undefined,
    tlas_buffer: Buffer = undefined,
    shader_binding_table: vk.Buffer = undefined,
    shader_binding_table_memory: vk.DeviceMemory = undefined,
    current_frame_index: usize = 0,
    frame_count: usize = 0,
    descriptor_set: vk.DescriptorSet = undefined,
    output_image_sampler: vk.Sampler = undefined,
    descriptor_pool: vk.DescriptorPool = undefined,

    /// Idiomatic init, matching renderer.SimpleRenderer
    pub fn init(
        gc: *GraphicsContext,
        render_pass: vk.RenderPass,
        shader_library: ShaderLibrary,
        alloc: std.mem.Allocator,
        descriptor_set_layout: vk.DescriptorSetLayout,
        output_image: vk.Image,
        output_image_view: vk.ImageView,
        output_memory: vk.DeviceMemory,
    ) !RaytracingSystem {
        const dsl = [_]vk.DescriptorSetLayout{descriptor_set_layout};
        const layout = try gc.*.vkd.createPipelineLayout(
            gc.*.dev,
            &vk.PipelineLayoutCreateInfo{
                .flags = .{},
                .set_layout_count = dsl.len,
                .p_set_layouts = &dsl,
                .push_constant_range_count = 0,
                .p_push_constant_ranges = null,
            },
            null,
        );
        const pipeline = try Pipeline.initRaytracing(gc.*, render_pass, shader_library, Pipeline.defaultRaytracingLayout(layout), alloc);
        return RaytracingSystem{
            .gc = gc,
            .pipeline = pipeline,
            .pipeline_layout = layout,
            .output_image = output_image,
            .output_image_view = output_image_view,
            .output_memory = output_memory,
            // ...other fields left at default/undefined...
        };
    }

    /// Create BLAS (bottom-level acceleration structure)
    pub fn createBLAS(self: *RaytracingSystem, scene: *Scene) !void {
        // For each mesh in the scene, create a BLAS (here, just one mesh for demo)
        // We'll use the first mesh in the scene for this example
        var object_count: u32 = 0;
        for (scene.objects.slice()) |*object| {
            if (object.model == null) {
                continue;
            } else {
                object_count += 1;
            }
        }
        if (object_count == 0) {
            return error.NoMeshes;
        }
        const mesh = &scene.objects.slice()[0].model.?.primitives.slice()[0].mesh.?; // Assume first object has a mesh
        const vertex_count = mesh.vertices.items.len;
        const index_count = mesh.indices.items.len;
        const vertex_size = @sizeOf(Vertex);

        // 3. Get device addresses
        var vertex_address_info = vk.BufferDeviceAddressInfo{
            .s_type = vk.StructureType.buffer_device_address_info,
            .buffer = mesh.vertex_buffer,
        };
        var index_address_info = vk.BufferDeviceAddressInfo{
            .s_type = vk.StructureType.buffer_device_address_info,
            .buffer = mesh.index_buffer,
        };
        const vertex_device_address = self.gc.vkd.getBufferDeviceAddress(self.gc.dev, &vertex_address_info);
        const index_device_address = self.gc.vkd.getBufferDeviceAddress(self.gc.dev, &index_address_info);

        // 4. Fill geometry
        var geometry = vk.AccelerationStructureGeometryKHR{
            .s_type = vk.StructureType.acceleration_structure_geometry_khr,
            .geometry_type = vk.GeometryTypeKHR.triangles_khr,
            .geometry = .{
                .triangles = vk.AccelerationStructureGeometryTrianglesDataKHR{
                    .s_type = vk.StructureType.acceleration_structure_geometry_triangles_data_khr,
                    .vertex_format = vk.Format.r32g32b32_sfloat,
                    .vertex_data = .{ .device_address = vertex_device_address },
                    .vertex_stride = vertex_size,
                    .max_vertex = @intCast(vertex_count - 1),
                    .index_type = vk.IndexType.uint32,
                    .index_data = .{ .device_address = index_device_address },
                    .transform_data = .{ .device_address = 0 },
                },
            },
            .flags = vk.GeometryFlagsKHR{},
        };
        var range_info = vk.AccelerationStructureBuildRangeInfoKHR{
            .primitive_count = @intCast(index_count / 3),
            .primitive_offset = 0,
            .first_vertex = 0,
            .transform_offset = 0,
        };
        var build_info = vk.AccelerationStructureBuildGeometryInfoKHR{
            .s_type = vk.StructureType.acceleration_structure_build_geometry_info_khr,
            .type = vk.AccelerationStructureTypeKHR.bottom_level_khr,
            .flags = vk.BuildAccelerationStructureFlagsKHR{ .prefer_fast_build_bit_khr = true },
            .mode = vk.BuildAccelerationStructureModeKHR.build_khr,
            .geometry_count = 1,
            .p_geometries = @ptrCast(&geometry),
            .scratch_data = .{ .device_address = 0 }, // Will set below

        };
        var size_info = vk.AccelerationStructureBuildSizesInfoKHR{
            .s_type = vk.StructureType.acceleration_structure_build_sizes_info_khr,
            .build_scratch_size = 0,
            .acceleration_structure_size = 0,
            .update_scratch_size = 0,
        };

        self.gc.vkd.getAccelerationStructureBuildSizesKHR(self.gc.*.dev, vk.AccelerationStructureBuildTypeKHR.device_khr, &build_info, null, &size_info);

        // 5. Create BLAS buffer
        const blas_buffer = try Buffer.init(
            self.gc,
            size_info.acceleration_structure_size,
            1,
            .{ .acceleration_structure_storage_bit_khr = true, .shader_device_address_bit = true },
            .{ .device_local_bit = true },
        );
        // 6. Create acceleration structure
        var as_create_info = vk.AccelerationStructureCreateInfoKHR{
            .s_type = vk.StructureType.acceleration_structure_create_info_khr,
            .buffer = blas_buffer.buffer,
            .size = size_info.acceleration_structure_size,
            .type = vk.AccelerationStructureTypeKHR.bottom_level_khr,
            .device_address = 0,
            .offset = 0,
        };
        const blas = try self.gc.vkd.createAccelerationStructureKHR(self.gc.dev, &as_create_info, null);

        self.blas = blas;
        // 7. Allocate scratch buffer
        const scratch_buffer = try Buffer.init(
            self.gc,
            size_info.build_scratch_size,
            1,
            .{ .storage_buffer_bit = true, .shader_device_address_bit = true },
            .{ .device_local_bit = true },
        );
        var scratch_address_info = vk.BufferDeviceAddressInfo{
            .s_type = vk.StructureType.buffer_device_address_info,
            .buffer = scratch_buffer.buffer,
        };
        const scratch_device_address = self.gc.vkd.getBufferDeviceAddress(self.gc.dev, &scratch_address_info);
        build_info.scratch_data.device_address = scratch_device_address;
        build_info.dst_acceleration_structure = blas;
        // 8. Record build command
        // Use a one-time command buffer for BLAS build
        var cmdbuf: vk.CommandBuffer = undefined;
        try self.gc.vkd.allocateCommandBuffers(self.gc.dev, &.{
            .command_pool = self.gc.command_pool,
            .level = .primary,
            .command_buffer_count = 1,
        }, @ptrCast(&cmdbuf));

        try self.gc.vkd.beginCommandBuffer(cmdbuf, &.{
            .flags = .{ .one_time_submit_bit = true },
            .p_inheritance_info = null,
        });

        const p_range_info = &range_info;
        self.gc.vkd.cmdBuildAccelerationStructuresKHR(cmdbuf, 1, @ptrCast(&build_info), @ptrCast(&p_range_info));
        try self.gc.vkd.endCommandBuffer(cmdbuf);
        // 9. The caller (e.g. swapchain or renderer) must now submit and wait for this command buffer
        // (vertex_buffer and index_buffer can be kept for TLAS or deinit here if not needed)
        // (blas_buffer should be kept for the lifetime of the BLAS)
        return;
    }

    /// Create TLAS (top-level acceleration structure) for multiple meshes/instances
    pub fn createTLAS(self: *RaytracingSystem, scene: *Scene) !void {
        // For each mesh in the scene, create a TLAS (here, just one mesh for demo)
        // We'll use the first mesh in the scene for this example
        var object_count: u32 = 0;
        for (scene.objects.slice()) |*object| {
            if (object.model == null) {
                continue;
            } else {
                object_count += 1;
            }
        }
        if (object_count == 0) {
            return error.NoMeshes;
        }
        //const mesh = &scene.objects.slice()[0].model.?.primitives.slice()[0].mesh.?; // Assume first object has a mesh
        // Only the mesh is used for instance reference, not for geometry data

        // 1. Fill geometry for TLAS (instances)
        var tlas_geometry = vk.AccelerationStructureGeometryKHR{
            .s_type = vk.StructureType.acceleration_structure_geometry_khr,
            .geometry_type = vk.GeometryTypeKHR.instances_khr,
            .geometry = .{
                .instances = vk.AccelerationStructureGeometryInstancesDataKHR{
                    .s_type = vk.StructureType.acceleration_structure_geometry_instances_data_khr,
                    .array_of_pointers = vk.FALSE,
                    .data = .{ .device_address = 0 }, // Will set below
                },
            },
            .flags = vk.GeometryFlagsKHR{},
        };
        var tlas_range_info = vk.AccelerationStructureBuildRangeInfoKHR{
            .primitive_count = 1, // One instance
            .primitive_offset = 0,
            .first_vertex = 0,
            .transform_offset = 0,
        };
        var tlas_build_info = vk.AccelerationStructureBuildGeometryInfoKHR{
            .s_type = vk.StructureType.acceleration_structure_build_geometry_info_khr,
            .type = vk.AccelerationStructureTypeKHR.top_level_khr,
            .flags = vk.BuildAccelerationStructureFlagsKHR{ .prefer_fast_build_bit_khr = true },
            .mode = vk.BuildAccelerationStructureModeKHR.build_khr,
            .geometry_count = 1,
            .p_geometries = @ptrCast(&tlas_geometry),
            .scratch_data = .{ .device_address = 0 }, // Will set below
        };
        var tlas_size_info = vk.AccelerationStructureBuildSizesInfoKHR{
            .s_type = vk.StructureType.acceleration_structure_build_sizes_info_khr,
            .build_scratch_size = 0,
            .acceleration_structure_size = 0,
            .update_scratch_size = 0,
        };
        self.gc.vkd.getAccelerationStructureBuildSizesKHR(self.gc.*.dev, vk.AccelerationStructureBuildTypeKHR.device_khr, &tlas_build_info, null, &tlas_size_info);

        // 2. Create TLAS buffer
        self.tlas_buffer = try Buffer.init(
            self.gc,
            tlas_size_info.acceleration_structure_size,
            1,
            .{ .acceleration_structure_storage_bit_khr = true, .shader_device_address_bit = true },
            .{ .device_local_bit = true },
        );
        // 3. Create acceleration structure
        var tlas_create_info = vk.AccelerationStructureCreateInfoKHR{
            .s_type = vk.StructureType.acceleration_structure_create_info_khr,
            .buffer = self.tlas_buffer.buffer,
            .size = tlas_size_info.acceleration_structure_size,
            .type = vk.AccelerationStructureTypeKHR.top_level_khr,
            .device_address = 0,
            .offset = 0,
        };
        const tlas = try self.gc.vkd.createAccelerationStructureKHR(self.gc.dev, &tlas_create_info, null);
        self.tlas = tlas;
        // 4. Allocate scratch buffer
        var tlas_scratch_buffer = try Buffer.init(
            self.gc,
            tlas_size_info.build_scratch_size,
            1,
            .{ .storage_buffer_bit = true, .shader_device_address_bit = true },
            .{ .device_local_bit = true },
        );
        var tlas_scratch_addr_info = vk.BufferDeviceAddressInfo{
            .s_type = vk.StructureType.buffer_device_address_info,
            .buffer = tlas_scratch_buffer.buffer,
        };
        const tlas_scratch_device_address = self.gc.vkd.getBufferDeviceAddress(self.gc.dev, &tlas_scratch_addr_info);
        tlas_build_info.scratch_data.device_address = tlas_scratch_device_address;
        tlas_build_info.dst_acceleration_structure = tlas;
        // 5. Record build command
        var cmdbuf: vk.CommandBuffer = undefined;
        try self.gc.vkd.allocateCommandBuffers(self.gc.dev, &.{
            .command_pool = self.gc.command_pool,
            .level = .primary,
            .command_buffer_count = 1,
        }, @ptrCast(&cmdbuf));
        try self.gc.vkd.beginCommandBuffer(cmdbuf, &.{
            .flags = .{ .one_time_submit_bit = true },
            .p_inheritance_info = null,
        });
        const tlas_p_range_info = &tlas_range_info;
        self.gc.vkd.cmdBuildAccelerationStructuresKHR(cmdbuf, 1, @ptrCast(&tlas_build_info), @ptrCast(&tlas_p_range_info));
        try self.gc.vkd.endCommandBuffer(cmdbuf);
        // 6. The caller (e.g. swapchain or renderer) must now submit and wait for this command buffer
        // (tlas_buffer should be kept for the lifetime of the TLAS)
        tlas_scratch_buffer.deinit();
        return;
    }

    /// Create the shader binding table for ray tracing (multi-mesh/instance)
    pub fn createShaderBindingTable(self: *RaytracingSystem, group_count: u32) !void {
        const gc = self.gc;
        // Query pipeline properties for SBT sizes
        var rt_props = vk.PhysicalDeviceRayTracingPipelinePropertiesKHR{
            .s_type = vk.StructureType.physical_device_ray_tracing_pipeline_properties_khr,
            .p_next = null,
            .shader_group_handle_size = 0,
            .max_ray_recursion_depth = 0,
            .max_shader_group_stride = 0,
            .shader_group_base_alignment = 0,
            .shader_group_handle_capture_replay_size = 0,
            .max_ray_dispatch_invocation_count = 0,
            .shader_group_handle_alignment = 0,
            .max_ray_hit_attribute_size = 0,
        };
        var props2 = vk.PhysicalDeviceProperties2{
            .s_type = vk.StructureType.physical_device_properties_2,
            .p_next = &rt_props,
            .properties = self.gc.props,
        };
        gc.vki.getPhysicalDeviceProperties2(gc.pdev, &props2);
        const handle_size = rt_props.shader_group_handle_size;
        const sbt_size = handle_size * group_count;
        // 1. Query shader group handles
        const handles = try std.heap.page_allocator.alloc(u8, sbt_size);
        defer std.heap.page_allocator.free(handles);
        try gc.vkd.getRayTracingShaderGroupHandlesKHR(gc.dev, self.pipeline.pipeline, 0, group_count, sbt_size, handles.ptr);

        // 2. Allocate SBT buffer
        var sbt_buffer = try Buffer.init(
            gc,
            sbt_size,
            1,
            .{ .shader_binding_table_bit_khr = true, .shader_device_address_bit = true },
            .{ .host_visible_bit = true, .host_coherent_bit = true },
        );
        try sbt_buffer.map(sbt_size, 0);
        sbt_buffer.writeToBuffer(handles, sbt_size, 0);
        try sbt_buffer.flush(sbt_size, 0);
        sbt_buffer.unmap();
        self.shader_binding_table = sbt_buffer.buffer;
        self.shader_binding_table_memory = sbt_buffer.memory;
        return;
    }

    /// Record the ray tracing command buffer for a frame (multi-mesh/instance)
    pub fn recordCommandBuffer(self: *RaytracingSystem, frame_info: FrameInfo, group_count: u32) !void {
        const gc = self.gc;
        const cmd = frame_info.command_buffer;
        var begin_info = vk.CommandBufferBeginInfo{
            .s_type = vk.StructureType.command_buffer_begin_info,
        };
        try gc.vkd.beginCommandBuffer(cmd, &begin_info);
        gc.vkd.cmdBindPipeline(cmd, vk.PipelineBindPoint.ray_tracing_khr, self.pipeline.pipeline);
        gc.vkd.cmdBindDescriptorSets(cmd, vk.PipelineBindPoint.ray_tracing_khr, self.pipeline_layout, 0, 1, @ptrCast(&frame_info.ray_tracing_descriptor_set), 0, null);
        // SBT region setup
        var rt_props = vk.PhysicalDeviceRayTracingPipelinePropertiesKHR{
            .s_type = vk.StructureType.physical_device_ray_tracing_pipeline_properties_khr,
            .p_next = null,
            .shader_group_handle_size = 0,
            .max_ray_recursion_depth = 0,
            .max_shader_group_stride = 0,
            .shader_group_base_alignment = 0,
            .shader_group_handle_capture_replay_size = 0,
            .max_ray_dispatch_invocation_count = 0,
            .shader_group_handle_alignment = 0,
            .max_ray_hit_attribute_size = 0,
        };
        var props2 = vk.PhysicalDeviceProperties2{
            .s_type = vk.StructureType.physical_device_properties_2,
            .p_next = &rt_props,
            .properties = gc.props,
        };
        gc.vki.getPhysicalDeviceProperties2(gc.pdev, &props2);
        const handle_size = rt_props.shader_group_handle_size;
        const sbt_addr_info = vk.BufferDeviceAddressInfo{
            .s_type = vk.StructureType.buffer_device_address_info,
            .buffer = self.shader_binding_table,
        };
        const sbt_addr = gc.vkd.getBufferDeviceAddress(gc.dev, &sbt_addr_info);
        var raygen_region = vk.StridedDeviceAddressRegionKHR{
            .device_address = sbt_addr,
            .stride = handle_size,
            .size = handle_size,
        };
        var miss_region = vk.StridedDeviceAddressRegionKHR{
            .device_address = sbt_addr + handle_size,
            .stride = handle_size,
            .size = handle_size,
        };
        var hit_region = vk.StridedDeviceAddressRegionKHR{
            .device_address = sbt_addr + handle_size * 2,
            .stride = handle_size,
            .size = handle_size * (group_count - 2),
        };
        var callable_region = vk.StridedDeviceAddressRegionKHR{
            .device_address = 0,
            .stride = 0,
            .size = 0,
        };
        gc.vkd.cmdTraceRaysKHR(cmd, &raygen_region, &miss_region, &hit_region, &callable_region, 1280, 720, 1);
        try gc.vkd.endCommandBuffer(cmd);
        return;
    }

    /// Create descriptor set layout for raytracing (TLAS, output image, uniform buffer, etc)
    pub fn createDescriptorSetLayout(self: *RaytracingSystem) !void {
        const gc = self.gc;
        // Example: binding 0 = TLAS, binding 1 = output image, binding 2 = uniform buffer
        var bindings = [_]vk.DescriptorSetLayoutBinding{
            vk.DescriptorSetLayoutBinding{
                .binding = 0,
                .descriptorType = vk.DESCRIPTOR_TYPE_ACCELERATION_STRUCTURE_KHR,
                .descriptorCount = 1,
                .stageFlags = vk.SHADER_STAGE_RAYGEN_BIT_KHR,
                .pImmutableSamplers = null,
            },
            vk.DescriptorSetLayoutBinding{
                .binding = 1,
                .descriptorType = vk.DESCRIPTOR_TYPE_STORAGE_IMAGE,
                .descriptorCount = 1,
                .stageFlags = vk.SHADER_STAGE_RAYGEN_BIT_KHR,
                .pImmutableSamplers = null,
            },
            // Add more bindings as needed (e.g., uniform buffer)
        };
        var layout_info = vk.DescriptorSetLayoutCreateInfo{
            .s_type = vk.StructureType.descriptor_set_layout_create_info,
            .bindingCount = bindings.len,
            .pBindings = &bindings,
        };
        var layout: vk.DescriptorSetLayout = undefined;
        if (gc.vkd.createDescriptorSetLayout(gc.dev, &layout_info, null, &layout) != vk.SUCCESS) {
            return error.DescriptorSetLayoutCreateFailed;
        }
        self.descriptor_set_layout = layout;
    }

    /// Create descriptor pool for raytracing
    pub fn createDescriptorPool(self: *RaytracingSystem) !void {
        const gc = self.gc;
        var pool_sizes = [_]vk.DescriptorPoolSize{
            vk.DescriptorPoolSize{ .type = vk.DESCRIPTOR_TYPE_ACCELERATION_STRUCTURE_KHR, .descriptorCount = 1 },
            vk.DescriptorPoolSize{ .type = vk.DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = 1 },
            // Add more as needed
        };
        var pool_info = vk.DescriptorPoolCreateInfo{
            .s_type = vk.StructureType.descriptor_pool_create_info,
            .maxSets = 1,
            .poolSizeCount = pool_sizes.len,
            .pPoolSizes = &pool_sizes,
        };
        var pool: vk.DescriptorPool = undefined;
        if (gc.vkd.createDescriptorPool(gc.dev, &pool_info, null, &pool) != vk.SUCCESS) {
            return error.DescriptorPoolCreateFailed;
        }
        self.descriptor_pool = pool;
    }

    /// Allocate and write descriptor set for raytracing
    pub fn createAndWriteDescriptorSet(self: *RaytracingSystem) !void {
        const gc = self.gc;
        // Allocate
        var alloc_info = vk.DescriptorSetAllocateInfo{
            .s_type = vk.StructureType.descriptor_set_allocate_info,
            .descriptorPool = self.descriptor_pool,
            .descriptorSetCount = 1,
            .pSetLayouts = &self.descriptor_set_layout,
        };
        var set: vk.DescriptorSet = undefined;
        if (gc.vkd.allocateDescriptorSets(gc.dev, &alloc_info, &set) != vk.SUCCESS) {
            return error.DescriptorSetAllocFailed;
        }
        self.descriptor_set = set;
        // Write TLAS
        const tlas_info = vk.WriteDescriptorSetAccelerationStructureKHR{
            .s_type = vk.StructureType.write_descriptor_set_acceleration_structure_khr,
            .accelerationStructureCount = 1,
            .pAccelerationStructures = &self.tlas,
        };
        const tlas_write = vk.WriteDescriptorSet{
            .s_type = vk.StructureType.write_descriptor_set,
            .dstSet = set,
            .dstBinding = 0,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = vk.DESCRIPTOR_TYPE_ACCELERATION_STRUCTURE_KHR,
            .pImageInfo = null,
            .pBufferInfo = null,
            .pTexelBufferView = null,
            .pNext = &tlas_info,
        };
        const image_info = vk.DescriptorImageInfo{
            .sampler = null,
            .imageView = self.output_image_view,
            .imageLayout = vk.IMAGE_LAYOUT_GENERAL,
        };
        const image_write = vk.WriteDescriptorSet{
            .s_type = vk.StructureType.write_descriptor_set,
            .dstSet = set,
            .dstBinding = 1,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = vk.DESCRIPTOR_TYPE_STORAGE_IMAGE,
            .pImageInfo = &image_info,
            .pBufferInfo = null,
            .pTexelBufferView = null,
            .pNext = null,
        };
        var writes = [_]vk.WriteDescriptorSet{ tlas_write, image_write };
        gc.vkd.updateDescriptorSets(gc.dev, writes.len, &writes, 0, null);
    }

    /// Call this after TLAS and output image are created
    pub fn setupDescriptors(self: *RaytracingSystem) !void {
        try self.createDescriptorSetLayout();
        try self.createDescriptorPool();
        try self.createAndWriteDescriptorSet();
    }

    /// Create the output storage image and image view for raytracing output
    pub fn createOutputImage(gc: *GraphicsContext, width: u32, height: u32) !struct {
        image: vk.Image,
        image_view: vk.ImageView,
        memory: vk.DeviceMemory,
    } {
        const vkd = gc.vkd;
        const dev = gc.dev;

        // Create image
        var image_ci = vk.ImageCreateInfo{
            .s_type = vk.StructureType.image_create_info,
            .p_next = null,
            .flags = .{},
            .image_type = vk.ImageType.@"2d",
            .format = vk.Format.r32g32b32a32_sfloat,
            .extent = .{ .width = width, .height = height, .depth = 1 },
            .mip_levels = 1,
            .array_layers = 1,
            .samples = vk.SampleCountFlags{ .@"1_bit" = true },
            .tiling = vk.ImageTiling.optimal,
            .usage = vk.ImageUsageFlags{
                .storage_bit = true,
                .sampled_bit = true,
            },
            .sharing_mode = vk.SharingMode.exclusive,
            .queue_family_index_count = 0,
            .p_queue_family_indices = null,
            .initial_layout = vk.ImageLayout.undefined,
        };
        const image = try vkd.createImage(dev, &image_ci, null);
        // Allocate memory
        const mem_reqs = vkd.getImageMemoryRequirements(dev, image);
        const memory = try gc.allocate(mem_reqs, .{});
        try vkd.bindImageMemory(dev, image, memory, 0);
        // Create image view
        var view_ci = vk.ImageViewCreateInfo{
            .s_type = vk.StructureType.image_view_create_info,
            .p_next = null,
            .flags = .{},
            .image = image,
            .view_type = vk.ImageViewType.@"2d",
            .format = vk.Format.r32g32b32a32_sfloat,
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
            .subresource_range = .{
                .aspect_mask = vk.ImageAspectFlags{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        };
        const image_view = try vkd.createImageView(dev, &view_ci, null);

        return .{ .image = image, .image_view = image_view, .memory = memory };
    }

    pub fn deinit(self: *RaytracingSystem) void {
        _ = self;
        // if (self.pipeline != undefined) self.gc.vkd.destroyPipeline(self.gc.dev, self.pipeline, null);
        // if (self.pipeline_layout != undefined) self.gc.vkd.destroyPipelineLayout(self.gc.dev, self.pipeline_layout, null);
        // if (self.output_image_view != undefined) self.gc.vkd.destroyImageView(self.gc.dev, self.output_image_view, null);
        // if (self.output_image != undefined) self.gc.vkd.destroyImage(self.gc.dev, self.output_image, null);
        // if (self.output_memory != undefined) self.gc.vkd.freeMemory(self.gc.dev, self.output_memory, null);
        // if (self.shader_binding_table != undefined) self.gc.vkd.destroyBuffer(self.gc.dev, self.shader_binding_table, null);
        // if (self.shader_binding_table_memory != undefined) self.gc.vkd.freeMemory(self.gc.dev, self.shader_binding_table_memory, null);
        // if (self.blas != undefined) self.gc.vkd.destroyAccelerationStructureKHR(self.gc.dev, self.blas, null);
        // if (self.tlas != undefined) self.gc.vkd.destroyAccelerationStructureKHR(self.gc.dev, self.tlas, null);
    }

    pub fn getAccelerationStructureDescriptorInfo(self: *RaytracingSystem) !vk.WriteDescriptorSetAccelerationStructureKHR {
        // Assumes self.tlas is a valid VkAccelerationStructureKHR handle
        return vk.WriteDescriptorSetAccelerationStructureKHR{
            .s_type = vk.StructureType.write_descriptor_set_acceleration_structure_khr,
            .p_next = null,
            .acceleration_structure_count = 1,
            .p_acceleration_structures = @ptrCast(&self.tlas),
        };
    }

    pub fn getOutputImageDescriptorInfo(self: *RaytracingSystem) !vk.DescriptorImageInfo {
        // Assumes self.output_image_view is a valid VkImageView and self.output_image_sampler is a valid VkSampler (or VK_NULL_HANDLE)
        return vk.DescriptorImageInfo{
            .sampler = self.output_image_sampler, // VK_NULL_HANDLE if not used
            .image_view = self.output_image_view,
            .image_layout = vk.ImageLayout.general,
        };
    }

    pub fn setDescriptorSet(self: *RaytracingSystem, set: vk.DescriptorSet, layout: vk.DescriptorSetLayout) !void {
        self.descriptor_set = set;
        self.descriptor_set_layout = layout;
    }
};
