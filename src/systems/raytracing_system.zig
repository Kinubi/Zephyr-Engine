const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("../graphics_context.zig").GraphicsContext;
const Buffer = @import("../buffer.zig").Buffer;
const Scene = @import("../scene.zig").Scene;
const Vertex = @import("../mesh.zig").Vertex;
const FrameInfo = @import("../frameinfo.zig").FrameInfo;
const Pipeline = @import("../pipeline.zig").Pipeline;
const ShaderLibrary = @import("../shader.zig").ShaderLibrary;
const Swapchain = @import("../swapchain.zig").Swapchain;
const DescriptorWriter = @import("../descriptors.zig").DescriptorWriter;
const DescriptorSetLayout = @import("../descriptors.zig").DescriptorSetLayout;
const DescriptorPool = @import("../descriptors.zig").DescriptorPool;
const GlobalUbo = @import("../frameinfo.zig").GlobalUbo;

fn alignForward(val: usize, alignment: usize) usize {
    return ((val + alignment - 1) / alignment) * alignment;
}

/// Raytracing system for Vulkan: manages BLAS/TLAS, pipeline, shader table, output, and dispatch.
pub const RaytracingSystem = struct {
    gc: *GraphicsContext, // Use 'gc' for consistency with Swapchain
    pipeline: Pipeline = undefined,
    pipeline_layout: vk.PipelineLayout = undefined,
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
    descriptor_set_layout: DescriptorSetLayout = undefined,
    descriptor_pool: DescriptorPool = undefined,
    tlas_instance_buffer: Buffer = undefined,

    /// Idiomatic init, matching renderer.SimpleRenderer
    pub fn init(
        gc: *GraphicsContext,
        render_pass: vk.RenderPass,
        shader_library: ShaderLibrary,
        alloc: std.mem.Allocator,
        descriptor_set_layout: DescriptorSetLayout,
        descriptor_pool: DescriptorPool,
        output_image: vk.Image,
        output_image_view: vk.ImageView,
        output_memory: vk.DeviceMemory,
    ) !RaytracingSystem {
        const dsl = [_]vk.DescriptorSetLayout{descriptor_set_layout.descriptor_set_layout};
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
            .descriptor_set_layout = descriptor_set_layout,
            .descriptor_pool = descriptor_pool,
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
            .flags = vk.GeometryFlagsKHR{ .opaque_bit_khr = true },
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
        var primitive_count: u32 = @intCast(index_count / 3);
        self.gc.vkd.getAccelerationStructureBuildSizesKHR(self.gc.*.dev, vk.AccelerationStructureBuildTypeKHR.device_khr, &build_info, @ptrCast(&primitive_count), &size_info);

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
        const si = vk.SubmitInfo{
            .wait_semaphore_count = 0,
            .p_wait_semaphores = undefined,
            .p_wait_dst_stage_mask = undefined,
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast(&cmdbuf),
            .signal_semaphore_count = 0,
            .p_signal_semaphores = undefined,
        };
        try self.gc.vkd.queueSubmit(self.gc.graphics_queue.handle, 1, @ptrCast(&si), .null_handle);
        try self.gc.vkd.queueWaitIdle(self.gc.graphics_queue.handle);
        std.debug.print("BLAS created with size: {}\n", .{size_info.acceleration_structure_size});
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
        const mesh = &scene.objects.slice()[0]; // Assume first object has a mesh
        // Only the mesh is used for instance reference, not for geometry data

        // 1. Create instance buffer for TLAS
        // --- TLAS instance buffer setup ---
        // Get BLAS device address
        var blas_addr_info = vk.AccelerationStructureDeviceAddressInfoKHR{
            .s_type = vk.StructureType.acceleration_structure_device_address_info_khr,
            .acceleration_structure = self.blas,
        };
        const blas_device_address = self.gc.vkd.getAccelerationStructureDeviceAddressKHR(self.gc.dev, &blas_addr_info);

        // Create instance struct (identity transform, instance 0)
        var instance = vk.AccelerationStructureInstanceKHR{
            .transform = .{
                .matrix = mesh.transform.local2world.to_3x4(), // Use mesh transform
            },
            .instance_custom_index_and_mask = .{ .instance_custom_index = 0, .mask = 0xFF },
            .instance_shader_binding_table_record_offset_and_flags = .{ .instance_shader_binding_table_record_offset = 0, .flags = 0 },
            .acceleration_structure_reference = blas_device_address,
        };
        // Create a host-visible buffer for the instance data
        var instance_buffer = try Buffer.init(
            self.gc,
            @sizeOf(vk.AccelerationStructureInstanceKHR),
            1,
            .{
                .shader_device_address_bit = true,
                .transfer_dst_bit = true,
                .acceleration_structure_build_input_read_only_bit_khr = true,
            },
            .{ .host_visible_bit = true, .host_coherent_bit = true },
        );
        try instance_buffer.map(@sizeOf(vk.AccelerationStructureInstanceKHR), 0);
        instance_buffer.writeToBuffer(std.mem.asBytes(&instance), @sizeOf(vk.AccelerationStructureInstanceKHR), 0);
        // Fix: flush with correct size (multiple of nonCoherentAtomSize or use WHOLE_SIZE)
        //try instance_buffer.flush(std.math.max(@sizeOf(vk.AccelerationStructureInstanceKHR), 256), 0);

        // Get device address for TLAS geometry
        var instance_addr_info = vk.BufferDeviceAddressInfo{
            .s_type = vk.StructureType.buffer_device_address_info,
            .buffer = instance_buffer.buffer,
        };
        const instance_device_address = self.gc.vkd.getBufferDeviceAddress(self.gc.dev, &instance_addr_info);

        // --- TLAS BUILD SIZES SETUP ---
        // Fill TLAS geometry with instance buffer address
        var tlas_geometry = vk.AccelerationStructureGeometryKHR{
            .s_type = vk.StructureType.acceleration_structure_geometry_khr,
            .geometry_type = vk.GeometryTypeKHR.instances_khr,
            .geometry = .{
                .instances = vk.AccelerationStructureGeometryInstancesDataKHR{
                    .s_type = vk.StructureType.acceleration_structure_geometry_instances_data_khr,
                    .array_of_pointers = vk.FALSE,
                    .data = .{ .device_address = instance_device_address },
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
        var tlas_primitive_count: u32 = 1;
        self.gc.vkd.getAccelerationStructureBuildSizesKHR(self.gc.*.dev, vk.AccelerationStructureBuildTypeKHR.device_khr, &tlas_build_info, @ptrCast(&tlas_primitive_count), &tlas_size_info);

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
        const tlas_scratch_buffer = try Buffer.init(
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
        const si = vk.SubmitInfo{
            .wait_semaphore_count = 0,
            .p_wait_semaphores = undefined,
            .p_wait_dst_stage_mask = undefined,
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast(&cmdbuf),
            .signal_semaphore_count = 0,
            .p_signal_semaphores = undefined,
        };
        try self.gc.vkd.queueSubmit(self.gc.graphics_queue.handle, 1, @ptrCast(&si), .null_handle);
        try self.gc.vkd.queueWaitIdle(self.gc.graphics_queue.handle);
        std.debug.print("TLAS created with number of instances: {}\n", .{1});
        //tlas_scratch_buffer.deinit();
        // Store instance buffer for later deinit
        self.tlas_instance_buffer = instance_buffer;
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
        const base_alignment = rt_props.shader_group_base_alignment;
        const sbt_stride = alignForward(handle_size, base_alignment);
        const sbt_size = sbt_stride * group_count;

        // 1. Query shader group handles
        const handles = try std.heap.page_allocator.alloc(u8, handle_size * group_count);
        defer std.heap.page_allocator.free(handles);
        try gc.vkd.getRayTracingShaderGroupHandlesKHR(gc.dev, self.pipeline.pipeline, 0, group_count, handle_size * group_count, handles.ptr);

        // 2. Allocate device-local SBT buffer
        var device_sbt_buffer = try Buffer.init(
            gc,
            sbt_size,
            1,
            .{ .shader_binding_table_bit_khr = true, .shader_device_address_bit = true, .transfer_dst_bit = true },
            .{ .device_local_bit = true },
        );

        // 3. Allocate host-visible upload buffer
        var upload_buffer = try Buffer.init(
            gc,
            sbt_size,
            1,
            .{ .transfer_src_bit = true },
            .{ .host_visible_bit = true, .host_coherent_bit = true },
        );
        try upload_buffer.map(sbt_size, 0);

        // 4. Write handles into upload buffer at aligned offsets, zeroing padding
        var dst = @as([*]u8, @ptrCast(upload_buffer.mapped.?));
        for (0..group_count) |i| {
            const src_offset = i * handle_size;
            const dst_offset = i * sbt_stride;
            std.mem.copyForwards(u8, dst[dst_offset..][0..handle_size], handles[src_offset..][0..handle_size]);
            // Zero padding if any
            if (sbt_stride > handle_size) {
                for (dst[dst_offset + handle_size .. dst_offset + sbt_stride]) |*b| b.* = 0;
            }
        }
        // No need to flush due to host_coherent

        // 5. Copy from upload to device-local SBT buffer
        try gc.copyBuffer(device_sbt_buffer.buffer, upload_buffer.buffer, sbt_size);

        // 6. Clean up upload buffer

        // 7. Store device-local SBT buffer (take ownership, don't deinit)
        self.shader_binding_table = device_sbt_buffer.buffer;
        self.shader_binding_table_memory = device_sbt_buffer.memory;
        device_sbt_buffer.buffer = undefined;
        device_sbt_buffer.memory = undefined;
    }

    /// Record the ray tracing command buffer for a frame (multi-mesh/instance)
    pub fn recordCommandBuffer(self: *RaytracingSystem, frame_info: FrameInfo, swapchain: *Swapchain, group_count: u32, global_ubo_buffer_info: vk.DescriptorBufferInfo) !void {
        const gc = self.gc;
        _ = group_count;
        try self.descriptor_pool.resetPool();
        var set_writer = DescriptorWriter.init(gc.*, &self.descriptor_set_layout, &self.descriptor_pool);
        const dummy_as_info = try self.getAccelerationStructureDescriptorInfo();
        try set_writer.writeAccelerationStructure(0, @constCast(&dummy_as_info)).build(&self.descriptor_set); // Storage image binding
        const output_image_info = try self.getOutputImageDescriptorInfo();
        try set_writer.writeImage(1, @constCast(&output_image_info)).build(&self.descriptor_set);
        try set_writer.writeBuffer(2, @constCast(&global_ubo_buffer_info)).build(&self.descriptor_set);
        // --- existing code for binding pipeline, descriptor sets, SBT, etc...

        gc.vkd.cmdBindPipeline(frame_info.command_buffer, vk.PipelineBindPoint.ray_tracing_khr, self.pipeline.pipeline);
        gc.vkd.cmdBindDescriptorSets(frame_info.command_buffer, vk.PipelineBindPoint.ray_tracing_khr, self.pipeline_layout, 0, 1, @ptrCast(&self.descriptor_set), 0, null);

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
        const base_alignment = rt_props.shader_group_base_alignment;
        // Use Zig's std.math.alignForwardPow2 for power-of-two alignment, or implement alignForward manually

        const sbt_stride = alignForward(handle_size, base_alignment);
        const sbt_addr_info = vk.BufferDeviceAddressInfo{
            .s_type = vk.StructureType.buffer_device_address_info,
            .buffer = self.shader_binding_table,
        };
        const sbt_addr = gc.vkd.getBufferDeviceAddress(gc.dev, &sbt_addr_info);
        var raygen_region = vk.StridedDeviceAddressRegionKHR{
            .device_address = sbt_addr,
            .stride = sbt_stride,
            .size = sbt_stride,
        };
        var miss_region = vk.StridedDeviceAddressRegionKHR{
            .device_address = sbt_addr + sbt_stride,
            .stride = sbt_stride,
            .size = sbt_stride,
        };
        var hit_region = vk.StridedDeviceAddressRegionKHR{
            .device_address = sbt_addr + sbt_stride * 2,
            .stride = sbt_stride,
            .size = sbt_stride,
        };
        var callable_region = vk.StridedDeviceAddressRegionKHR{
            .device_address = 0,
            .stride = 0,
            .size = 0,
        };
        gc.vkd.cmdTraceRaysKHR(frame_info.command_buffer, &raygen_region, &miss_region, &hit_region, &callable_region, 1280, 720, 1);

        // --- Image layout transitions before ray tracing ---
        // 1. Transition output image to GENERAL for storage write (ray tracing)
        var old_layout = vk.ImageLayout.undefined; // Use general layout for ray tracing
        var old_access_mask = vk.AccessFlags{};
        if (frame_info.current_frame == 0) {
            old_layout = vk.ImageLayout.undefined;
        } else {
            old_layout = vk.ImageLayout.general;
            old_access_mask = vk.AccessFlags.fromInt(0);
            // If reusing swapchain image, use present layout
        }
        var output_barrier = vk.ImageMemoryBarrier{
            .s_type = vk.StructureType.image_memory_barrier,
            .src_access_mask = old_access_mask,
            .dst_access_mask = vk.AccessFlags{ .transfer_read_bit = true },
            .old_layout = old_layout,
            .new_layout = vk.ImageLayout.transfer_src_optimal,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = self.output_image,
            .subresource_range = .{
                .aspect_mask = vk.ImageAspectFlags{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        };
        gc.vkd.cmdPipelineBarrier(
            frame_info.command_buffer,
            vk.PipelineStageFlags{ .all_commands_bit = true },
            vk.PipelineStageFlags{ .transfer_bit = true },
            .{},
            0,
            null,
            0,
            null,
            1,
            @ptrCast(&output_barrier),
        );

        // 2. Transition swapchain image to TRANSFER_DST for copy
        var swapchain_barrier = vk.ImageMemoryBarrier{
            .s_type = vk.StructureType.image_memory_barrier,
            .src_access_mask = vk.AccessFlags.fromInt(0),
            .dst_access_mask = .{ .transfer_write_bit = true },
            .old_layout = vk.ImageLayout.present_src_khr, // or .present_src_khr if reused
            .new_layout = vk.ImageLayout.transfer_dst_optimal,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = swapchain.swap_images[frame_info.current_frame].image, // <-- pass this in FrameInfo
            .subresource_range = .{
                .aspect_mask = vk.ImageAspectFlags{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        };
        gc.vkd.cmdPipelineBarrier(
            frame_info.command_buffer,
            vk.PipelineStageFlags{ .top_of_pipe_bit = true },
            vk.PipelineStageFlags{ .transfer_bit = true },
            undefined,
            0,
            null,
            0,
            null,
            1,
            @ptrCast(&swapchain_barrier),
        );

        const copy_info: vk.ImageCopy = vk.ImageCopy{
            .src_subresource = .{ .aspect_mask = vk.ImageAspectFlags{ .color_bit = true }, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 },
            .src_offset = vk.Offset3D{ .x = 0, .y = 0, .z = 0 },
            .dst_subresource = .{ .aspect_mask = vk.ImageAspectFlags{ .color_bit = true }, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 },
            .extent = vk.Extent3D{ .width = swapchain.extent.width, .height = swapchain.extent.height, .depth = 1 },
            .dst_offset = vk.Offset3D{ .x = 0, .y = 0, .z = 0 },
        };

        gc.vkd.cmdCopyImage(frame_info.command_buffer, self.output_image, vk.ImageLayout.transfer_src_optimal, swapchain.swap_images[frame_info.current_frame].image, vk.ImageLayout.transfer_dst_optimal, 1, @ptrCast(&copy_info));
        // --- Image layout transitions after ray tracing, before copy ---
        var output_to_copy_barrier = vk.ImageMemoryBarrier{
            .s_type = vk.StructureType.image_memory_barrier,
            .src_access_mask = vk.AccessFlags{ .transfer_read_bit = true },
            .dst_access_mask = vk.AccessFlags{},
            .old_layout = vk.ImageLayout.transfer_src_optimal,
            .new_layout = vk.ImageLayout.general,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = self.output_image,
            .subresource_range = .{
                .aspect_mask = vk.ImageAspectFlags{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        };

        gc.vkd.cmdPipelineBarrier(
            frame_info.command_buffer,
            vk.PipelineStageFlags{ .all_commands_bit = true },
            vk.PipelineStageFlags{ .transfer_bit = true },
            undefined,
            0,
            null,
            0,
            null,
            1,
            @ptrCast(&output_to_copy_barrier),
        );
        // --- Image layout transition after copy, before present ---
        var swapchain_to_present_barrier = vk.ImageMemoryBarrier{
            .s_type = vk.StructureType.image_memory_barrier,
            .src_access_mask = .{ .transfer_write_bit = true },
            .dst_access_mask = .{},
            .old_layout = vk.ImageLayout.transfer_dst_optimal,
            .new_layout = vk.ImageLayout.present_src_khr,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = swapchain.swap_images[frame_info.current_frame].image, // <-- pass this in FrameInfo
            .subresource_range = .{
                .aspect_mask = vk.ImageAspectFlags{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        };
        gc.vkd.cmdPipelineBarrier(
            frame_info.command_buffer,
            vk.PipelineStageFlags{ .transfer_bit = true },
            vk.PipelineStageFlags{ .bottom_of_pipe_bit = true },
            undefined,
            0,
            null,
            0,
            null,
            1,
            @ptrCast(&swapchain_to_present_barrier),
        );
        std.debug.print("Output image created with handle: {any}, and swapchain image: {any}\n", .{ self.output_image, swapchain.swap_images[frame_info.current_frame].image });
        return;
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
            .format = vk.Format.a2b10g10r10_unorm_pack32,
            .extent = .{ .width = width, .height = height, .depth = 1 },
            .mip_levels = 1,
            .array_layers = 1,
            .samples = vk.SampleCountFlags{ .@"1_bit" = true },
            .tiling = vk.ImageTiling.optimal,
            .usage = vk.ImageUsageFlags{
                .storage_bit = true,
                .transfer_src_bit = true,
            },
            .sharing_mode = vk.SharingMode.exclusive,
            .queue_family_index_count = 0,
            .p_queue_family_indices = null,
            .initial_layout = vk.ImageLayout.undefined,
        };
        const image = try vkd.createImage(dev, &image_ci, null);

        // Allocate memory
        const mem_reqs = vkd.getImageMemoryRequirements(dev, image);
        const memory = try gc.allocate(mem_reqs, .{}, .{});
        try vkd.bindImageMemory(dev, image, memory, 0);
        // Create image view
        var view_ci = vk.ImageViewCreateInfo{
            .s_type = vk.StructureType.image_view_create_info,
            .p_next = null,
            .flags = .{},
            .image = image,
            .view_type = vk.ImageViewType.@"2d",
            .format = vk.Format.a2b10g10r10_unorm_pack32,
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

        // Use a one-time command buffer for Image transition build
        var cmdbuf: vk.CommandBuffer = undefined;
        try gc.vkd.allocateCommandBuffers(gc.dev, &.{
            .command_pool = gc.command_pool,
            .level = .primary,
            .command_buffer_count = 1,
        }, @ptrCast(&cmdbuf));

        try gc.vkd.beginCommandBuffer(cmdbuf, &.{
            .flags = .{ .one_time_submit_bit = true },
            .p_inheritance_info = null,
        });

        var output_to_copy_barrier = vk.ImageMemoryBarrier{
            .s_type = vk.StructureType.image_memory_barrier,
            .src_access_mask = vk.AccessFlags{},
            .dst_access_mask = vk.AccessFlags{},
            .old_layout = vk.ImageLayout.undefined,
            .new_layout = vk.ImageLayout.general,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = image,
            .subresource_range = .{
                .aspect_mask = vk.ImageAspectFlags{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        };

        gc.vkd.cmdPipelineBarrier(
            cmdbuf,
            vk.PipelineStageFlags{ .all_commands_bit = true },
            vk.PipelineStageFlags{ .all_commands_bit = true },
            undefined,
            0,
            null,
            0,
            null,
            1,
            @ptrCast(&output_to_copy_barrier),
        );

        try gc.vkd.endCommandBuffer(cmdbuf);
        const si = vk.SubmitInfo{
            .wait_semaphore_count = 0,
            .p_wait_semaphores = undefined,
            .p_wait_dst_stage_mask = undefined,
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast(&cmdbuf),
            .signal_semaphore_count = 0,
            .p_signal_semaphores = undefined,
        };
        try gc.vkd.queueSubmit(gc.graphics_queue.handle, 1, @ptrCast(&si), .null_handle);
        try gc.vkd.queueWaitIdle(gc.graphics_queue.handle);

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
};
