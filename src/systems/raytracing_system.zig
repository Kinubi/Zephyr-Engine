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
const Texture = @import("../texture.zig").Texture;

fn alignForward(val: usize, alignment: usize) usize {
    return ((val + alignment - 1) / alignment) * alignment;
}

/// Raytracing system for Vulkan: manages BLAS/TLAS, pipeline, shader table, output, and dispatch.
pub const RaytracingSystem = struct {
    gc: *GraphicsContext, // Use 'gc' for consistency with Swapchain
    pipeline: Pipeline = undefined,
    pipeline_layout: vk.PipelineLayout = undefined,
    output_texture: Texture = undefined,
    blas: vk.AccelerationStructureKHR = undefined,
    tlas: vk.AccelerationStructureKHR = undefined,
    tlas_buffer: Buffer = undefined,
    shader_binding_table: vk.Buffer = undefined,
    shader_binding_table_memory: vk.DeviceMemory = undefined,
    current_frame_index: usize = 0,
    frame_count: usize = 0,
    descriptor_set: vk.DescriptorSet = undefined,
    descriptor_set_layout: DescriptorSetLayout = undefined,
    descriptor_pool: *DescriptorPool = undefined,
    tlas_instance_buffer: Buffer = undefined,
    width: u32 = 1280,
    height: u32 = 720,
    blas_handles: std.ArrayList(vk.AccelerationStructureKHR) = undefined,
    blas_buffers: std.ArrayList(Buffer) = undefined,

    /// Idiomatic init, matching renderer.SimpleRenderer
    pub fn init(
        gc: *GraphicsContext,
        render_pass: vk.RenderPass,
        shader_library: ShaderLibrary,
        alloc: std.mem.Allocator,
        descriptor_set_layout: DescriptorSetLayout,
        descriptor_pool: *DescriptorPool,
        swapchain: *Swapchain,
        width: u32,
        height: u32,
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
        // Create output image using Texture abstraction
        std.debug.print("Swapchain surface format: {}\n", .{swapchain.surface_format.format});
        // If the swapchain format is ARGB, use ABGR for the output image format, else use the swapchain format.
        var output_format = swapchain.surface_format.format;
        if (output_format == vk.Format.a2r10g10b10_unorm_pack32) {
            output_format = vk.Format.a2b10g10r10_unorm_pack32;
        }
        const output_texture = try Texture.init(
            gc,
            output_format, // Use the swapchain format for output
            .{ .width = width, .height = height, .depth = 1 },
            vk.ImageUsageFlags{
                .storage_bit = true,
                .transfer_src_bit = true,
                .transfer_dst_bit = true,
                .sampled_bit = true,
            },
            vk.SampleCountFlags{ .@"1_bit" = true },
        );

        return RaytracingSystem{
            .gc = gc,
            .pipeline = pipeline,
            .pipeline_layout = layout,
            .output_texture = output_texture,
            .descriptor_set_layout = descriptor_set_layout,
            .descriptor_pool = descriptor_pool,
            .width = width,
            .height = height,
            .blas_handles = try std.ArrayList(vk.AccelerationStructureKHR).initCapacity(alloc, 8),
            .blas_buffers = try std.ArrayList(Buffer).initCapacity(alloc, 8),
            // ...other fields left at default/undefined...
        };
    }

    /// Create BLAS for every mesh in every model in the scene
    pub fn createBLAS(self: *RaytracingSystem, scene: *Scene) !void {
        self.blas_handles.clearRetainingCapacity();
        self.blas_buffers.clearRetainingCapacity();
        var mesh_count: usize = 0;
        for (scene.objects.slice()) |*object| {
            if (object.model) |model| {
                for (model.primitives.slice()) |*primitive| {
                    if (primitive.mesh) |mesh| {
                        mesh_count += 1;
                        const vertex_count = mesh.vertices.items.len;
                        const index_count = mesh.indices.items.len;
                        const vertex_size = @sizeOf(Vertex);
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
                        var geometry = vk.AccelerationStructureGeometryKHR{
                            .s_type = vk.StructureType.acceleration_structure_geometry_khr,
                            .geometry_type = vk.GeometryTypeKHR.triangles_khr,
                            .geometry = .{
                                .triangles = vk.AccelerationStructureGeometryTrianglesDataKHR{
                                    .s_type = vk.StructureType.acceleration_structure_geometry_triangles_data_khr,
                                    .vertex_format = vk.Format.r32g32b32_sfloat,
                                    .vertex_data = .{ .device_address = vertex_device_address },
                                    .vertex_stride = vertex_size,
                                    .max_vertex = @intCast(vertex_count),
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
                            .scratch_data = .{ .device_address = 0 },
                        };
                        var size_info = vk.AccelerationStructureBuildSizesInfoKHR{
                            .s_type = vk.StructureType.acceleration_structure_build_sizes_info_khr,
                            .build_scratch_size = 0,
                            .acceleration_structure_size = 0,
                            .update_scratch_size = 0,
                        };
                        var primitive_count: u32 = @intCast(index_count / 3);
                        self.gc.vkd.getAccelerationStructureBuildSizesKHR(self.gc.*.dev, vk.AccelerationStructureBuildTypeKHR.device_khr, &build_info, @ptrCast(&primitive_count), &size_info);
                        const blas_buffer = try Buffer.init(
                            self.gc,
                            size_info.acceleration_structure_size,
                            1,
                            .{ .acceleration_structure_storage_bit_khr = true, .shader_device_address_bit = true },
                            .{ .device_local_bit = true },
                        );
                        var as_create_info = vk.AccelerationStructureCreateInfoKHR{
                            .s_type = vk.StructureType.acceleration_structure_create_info_khr,
                            .buffer = blas_buffer.buffer,
                            .size = size_info.acceleration_structure_size,
                            .type = vk.AccelerationStructureTypeKHR.bottom_level_khr,
                            .device_address = 0,
                            .offset = 0,
                        };
                        const blas = try self.gc.vkd.createAccelerationStructureKHR(self.gc.dev, &as_create_info, null);
                        // Allocate scratch buffer
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
                        // Record build command
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
                        try self.blas_handles.append(blas);
                        try self.blas_buffers.append(blas_buffer);
                        // Optionally deinit scratch_buffer here
                    }
                }
            }
        }
        if (mesh_count == 0) return error.NoMeshes;
        std.debug.print("Created {d} BLASes for all meshes in scene\n", .{mesh_count});
    }

    /// Create TLAS for all mesh instances in the scene
    pub fn createTLAS(self: *RaytracingSystem, scene: *Scene, allocator: std.mem.Allocator) !void {
        var instances = try std.ArrayList(vk.AccelerationStructureInstanceKHR).initCapacity(allocator, self.blas_handles.items.len);
        var mesh_index: u32 = 0;
        std.debug.print("Creating TLAS for Scene with {} objects\n", .{scene.objects.len});
        for (scene.objects.slice()) |*object| {
            if (object.model) |model| {
                std.debug.print("Processing model with {} primitives\n", .{model.primitives.len});
                for (model.primitives.slice()) |*primitive| {
                    if (primitive.mesh) |_| {
                        var blas_addr_info = vk.AccelerationStructureDeviceAddressInfoKHR{
                            .s_type = vk.StructureType.acceleration_structure_device_address_info_khr,
                            .acceleration_structure = self.blas_handles.items[mesh_index],
                        };
                        const blas_device_address = self.gc.vkd.getAccelerationStructureDeviceAddressKHR(self.gc.dev, &blas_addr_info);
                        try instances.append(vk.AccelerationStructureInstanceKHR{
                            .transform = .{ .matrix = object.transform.local2world.to_3x4() },
                            .instance_custom_index_and_mask = .{ .instance_custom_index = @intCast(mesh_index), .mask = 0xFF },
                            .instance_shader_binding_table_record_offset_and_flags = .{ .instance_shader_binding_table_record_offset = 0, .flags = 0 },
                            .acceleration_structure_reference = blas_device_address,
                        });
                        mesh_index += 1;
                    }
                }
            }
        }
        if (instances.items.len == 0) return error.NoMeshes;
        // --- TLAS instance buffer setup ---
        // Create instance buffer
        var instance_buffer = try Buffer.init(
            self.gc,
            @sizeOf(vk.AccelerationStructureInstanceKHR) * instances.items.len,
            1,
            .{
                .shader_device_address_bit = true,
                .transfer_dst_bit = true,
                .acceleration_structure_build_input_read_only_bit_khr = true,
            },
            .{ .host_visible_bit = true, .host_coherent_bit = true },
        );
        try instance_buffer.map(@sizeOf(vk.AccelerationStructureInstanceKHR) * instances.items.len, 0);
        instance_buffer.writeToBuffer(std.mem.sliceAsBytes(instances.items), @sizeOf(vk.AccelerationStructureInstanceKHR) * instances.items.len, 0);
        // --- TLAS BUILD SIZES SETUP ---
        // Get device address for TLAS geometry
        var instance_addr_info = vk.BufferDeviceAddressInfo{
            .s_type = vk.StructureType.buffer_device_address_info,
            .buffer = instance_buffer.buffer,
        };
        const instance_device_address = self.gc.vkd.getBufferDeviceAddress(self.gc.dev, &instance_addr_info);

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
            .flags = vk.GeometryFlagsKHR{ .opaque_bit_khr = true },
        };
        var tlas_range_info = vk.AccelerationStructureBuildRangeInfoKHR{
            .primitive_count = @intCast(instances.items.len), // Number of instances
            .primitive_offset = 0,
            .first_vertex = 0,
            .transform_offset = 0,
        };
        var tlas_build_info = vk.AccelerationStructureBuildGeometryInfoKHR{
            .s_type = vk.StructureType.acceleration_structure_build_geometry_info_khr,
            .type = vk.AccelerationStructureTypeKHR.top_level_khr,
            .flags = vk.BuildAccelerationStructureFlagsKHR{ .prefer_fast_trace_bit_khr = true },
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
        var tlas_primitive_count: u32 = @intCast(instances.items.len);
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
        std.debug.print("TLAS created with number of instances: {}\n", .{instances.items.len});
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
        if (swapchain.extent.width != self.width or swapchain.extent.height != self.height) {
            self.width = swapchain.extent.width;
            self.height = swapchain.extent.height;
            const output_texture = try Texture.init(
                gc,
                swapchain.surface_format.format,
                .{ .width = self.width, .height = self.height, .depth = 1 },
                vk.ImageUsageFlags{
                    .storage_bit = true,
                    .transfer_src_bit = true,
                    .transfer_dst_bit = true,
                    .sampled_bit = true,
                },
                vk.SampleCountFlags{ .@"1_bit" = true },
            );

            self.output_texture = output_texture;
            try self.descriptor_pool.resetPool();
            const output_image_info = self.output_texture.getDescriptorInfo();
            var set_writer = DescriptorWriter.init(gc.*, &self.descriptor_set_layout, self.descriptor_pool);
            const dummy_as_info = try self.getAccelerationStructureDescriptorInfo();
            try set_writer.writeAccelerationStructure(0, @constCast(&dummy_as_info)).build(&self.descriptor_set); // Storage image binding
            try set_writer.writeImage(1, @constCast(&output_image_info)).build(&self.descriptor_set);
            try set_writer.writeBuffer(2, @constCast(&global_ubo_buffer_info)).build(&self.descriptor_set);
        }

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
        gc.vkd.cmdTraceRaysKHR(frame_info.command_buffer, &raygen_region, &miss_region, &hit_region, &callable_region, self.width, self.height, 1);

        // --- Image layout transitions before ray tracing ---

        // 2. Transition output image to TRANSFER_SRC for copy
        self.output_texture.transitionImageLayout(
            frame_info.command_buffer,
            vk.ImageLayout.general,
            vk.ImageLayout.transfer_src_optimal,
            .{
                .aspect_mask = vk.ImageAspectFlags{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        ) catch |err| return err;

        // 3. Transition swapchain image to TRANSFER_DST for copy
        gc.transitionImageLayout(
            frame_info.command_buffer,
            swapchain.swap_images[swapchain.image_index].image,
            vk.ImageLayout.present_src_khr,
            vk.ImageLayout.transfer_dst_optimal,
            .{
                .aspect_mask = vk.ImageAspectFlags{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        );

        const copy_info: vk.ImageCopy = vk.ImageCopy{
            .src_subresource = .{ .aspect_mask = vk.ImageAspectFlags{ .color_bit = true }, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 },
            .src_offset = vk.Offset3D{ .x = 0, .y = 0, .z = 0 },
            .dst_subresource = .{ .aspect_mask = vk.ImageAspectFlags{ .color_bit = true }, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 },
            .extent = vk.Extent3D{ .width = swapchain.extent.width, .height = swapchain.extent.height, .depth = 1 },
            .dst_offset = vk.Offset3D{ .x = 0, .y = 0, .z = 0 },
        };
        gc.vkd.cmdCopyImage(frame_info.command_buffer, self.output_texture.image, vk.ImageLayout.transfer_src_optimal, swapchain.swap_images[swapchain.image_index].image, vk.ImageLayout.transfer_dst_optimal, 1, @ptrCast(&copy_info));

        // --- Image layout transitions after copy ---
        // 4. Transition output image back to GENERAL
        self.output_texture.transitionImageLayout(
            frame_info.command_buffer,
            vk.ImageLayout.transfer_src_optimal,
            vk.ImageLayout.general,
            .{
                .aspect_mask = vk.ImageAspectFlags{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        ) catch |err| return err;
        // 5. Transition swapchain image to PRESENT_SRC for presentation
        gc.transitionImageLayout(
            frame_info.command_buffer,
            swapchain.swap_images[swapchain.image_index].image,
            vk.ImageLayout.transfer_dst_optimal,
            vk.ImageLayout.present_src_khr,
            .{
                .aspect_mask = vk.ImageAspectFlags{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        );

        return;
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
        // Assumes self.output_texture is valid
        return self.output_texture.getDescriptorInfo();
    }
};
