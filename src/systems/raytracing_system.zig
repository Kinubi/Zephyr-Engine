const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("../core/graphics_context.zig").GraphicsContext;
const Buffer = @import("../core/buffer.zig").Buffer;
const MAX_FRAMES_IN_FLIGHT = @import("../core/swapchain.zig").MAX_FRAMES_IN_FLIGHT;
const Scene = @import("../scene/scene.zig").Scene;
const Vertex = @import("../rendering/mesh.zig").Vertex;
const FrameInfo = @import("../rendering/frameinfo.zig").FrameInfo;
const Pipeline = @import("../core/pipeline.zig").Pipeline;
const ShaderLibrary = @import("../core/shader.zig").ShaderLibrary;
const Swapchain = @import("../core/swapchain.zig").Swapchain;
const DescriptorWriter = @import("../core/descriptors.zig").DescriptorWriter;
const DescriptorSetLayout = @import("../core/descriptors.zig").DescriptorSetLayout;
const DescriptorPool = @import("../core/descriptors.zig").DescriptorPool;
const RenderPassDescriptorManager = @import("../rendering/render_pass_descriptors.zig").RenderPassDescriptorManager;
const DescriptorSetConfig = @import("../rendering/render_pass_descriptors.zig").DescriptorSetConfig;
const ResourceBinding = @import("../rendering/render_pass_descriptors.zig").ResourceBinding;
const GlobalUbo = @import("../rendering/frameinfo.zig").GlobalUbo;
const Texture = @import("../core/texture.zig").Texture;
const log = @import("../utils/log.zig").log;
const LogLevel = @import("../utils/log.zig").LogLevel;
const deinitDescriptorResources = @import("../core/descriptors.zig").deinitDescriptorResources;
const ThreadPool = @import("../threading/thread_pool.zig").ThreadPool;

// Import the new multithreaded BVH builder
const MultithreadedBvhBuilder = @import("multithreaded_bvh_builder.zig").MultithreadedBvhBuilder;
const BlasResult = @import("multithreaded_bvh_builder.zig").BlasResult;
const TlasResult = @import("multithreaded_bvh_builder.zig").TlasResult;
const GeometryData = @import("multithreaded_bvh_builder.zig").GeometryData;
const InstanceData = @import("multithreaded_bvh_builder.zig").InstanceData;
const BvhBuildResult = @import("multithreaded_bvh_builder.zig").BvhBuildResult;

fn alignForward(val: usize, alignment: usize) usize {
    return ((val + alignment - 1) / alignment) * alignment;
}

/// Enhanced Raytracing system with multithreaded BVH building
pub const RaytracingSystem = struct {
    gc: *GraphicsContext, // Use 'gc' for consistency with Swapchain
    pipeline: Pipeline = undefined,
    pipeline_layout: vk.PipelineLayout = undefined,
    output_texture: Texture = undefined,

    // Legacy single AS support (for compatibility)
    blas: vk.AccelerationStructureKHR = undefined,
    tlas: vk.AccelerationStructureKHR = undefined,
    tlas_buffer: Buffer = undefined,
    tlas_buffer_initialized: bool = false,
    tlas_instance_buffer: Buffer = undefined,
    tlas_instance_buffer_initialized: bool = false,
    tlas_dirty: bool = false,

    // New multithreaded BVH system
    bvh_builder: *MultithreadedBvhBuilder = undefined,
    completed_blas_list: std.ArrayList(BlasResult) = undefined,
    completed_tlas: ?TlasResult = null,
    bvh_build_in_progress: bool = false,
    bvh_rebuild_pending: bool = false,

    shader_binding_table: vk.Buffer = undefined,
    shader_binding_table_memory: vk.DeviceMemory = undefined,
    sbt_created: bool = false,
    current_frame_index: usize = 0,
    frame_count: usize = 0,

    // New descriptor manager
    descriptor_manager: RenderPassDescriptorManager = undefined,

    width: u32 = 1280,
    height: u32 = 720,

    // Legacy BLAS arrays (for compatibility)
    blas_handles: std.ArrayList(vk.AccelerationStructureKHR) = undefined,
    blas_buffers: std.ArrayList(Buffer) = undefined,
    allocator: std.mem.Allocator = undefined,

    // Texture update tracking
    descriptors_need_update: bool = false,

    /// Enhanced init with multithreaded BVH support
    pub fn init(
        gc: *GraphicsContext,
        allocator: std.mem.Allocator,
        width: u32,
        height: u32,
        thread_pool: *ThreadPool,
    ) !RaytracingSystem {
        // RaytracingSystem now focuses only on BVH building and management
        // Rendering/descriptor management is handled by RaytracingRenderer

        // Initialize BVH builder
        const bvh_builder = try allocator.create(MultithreadedBvhBuilder);
        bvh_builder.* = try MultithreadedBvhBuilder.init(gc, thread_pool, allocator);

        return RaytracingSystem{
            .gc = gc,
            .pipeline = undefined, // No longer managed by system
            .pipeline_layout = vk.PipelineLayout.null_handle,
            .bvh_builder = bvh_builder,
            .completed_blas_list = std.ArrayList(BlasResult){},
            .completed_tlas = null,
            .bvh_build_in_progress = false,
            .bvh_rebuild_pending = false,
            .width = width,
            .height = height,
            .blas_handles = try std.ArrayList(vk.AccelerationStructureKHR).initCapacity(allocator, 8),
            .blas_buffers = try std.ArrayList(Buffer).initCapacity(allocator, 8),
            .allocator = allocator,
            .descriptors_need_update = false,
            .tlas_buffer_initialized = false,
            .tlas_instance_buffer_initialized = false,
            .current_frame_index = 0,
            .frame_count = 0,
            .blas = vk.AccelerationStructureKHR.null_handle,
            .tlas = vk.AccelerationStructureKHR.null_handle,
            .tlas_buffer = undefined,
            .tlas_instance_buffer = undefined,
            .shader_binding_table = vk.Buffer.null_handle,
            .shader_binding_table_memory = vk.DeviceMemory.null_handle,
        };
    }

    /// Update the Shader Binding Table when the pipeline changes
    pub fn updateShaderBindingTable(self: *RaytracingSystem, pipeline: vk.Pipeline) !void {
        if (pipeline == vk.Pipeline.null_handle) {
            log(.WARN, "RaytracingSystem", "Cannot update SBT: pipeline is null", .{});
            return;
        }

        // Get shader group handles from the pipeline
        const group_count: u32 = 3; // raygen, miss, closest hit

        // Query raytracing pipeline properties - validate each field access
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

        // Use existing graphics context properties
        var props2 = vk.PhysicalDeviceProperties2{
            .s_type = vk.StructureType.physical_device_properties_2,
            .p_next = &rt_props,
            .properties = self.gc.props,
        };

        // Safely query properties
        self.gc.vki.getPhysicalDeviceProperties2(self.gc.pdev, &props2);

        const handle_size = rt_props.shader_group_handle_size;
        const base_alignment = rt_props.shader_group_base_alignment;

        // Use the same stride calculation as the renderer
        const sbt_stride = alignForward(handle_size, base_alignment);

        var group_handles = try self.allocator.alloc(u8, group_count * handle_size);
        defer self.allocator.free(group_handles);

        try self.gc.*.vkd.getRayTracingShaderGroupHandlesKHR(
            self.gc.*.dev,
            pipeline,
            0,
            group_count,
            @intCast(group_handles.len),
            group_handles.ptr,
        );

        // Create shader binding table buffer with enough space for all regions
        // We need space for: raygen (1) + miss (1) + hit (1) = 3 entries minimum
        // The renderer accesses at offsets: 0, stride, stride*2
        // So we need at least 3 * stride bytes total
        const min_entries = 3;
        const actual_entries = @max(group_count, min_entries);
        const sbt_size = actual_entries * sbt_stride;

        // Clean up existing SBT if it exists
        if (self.shader_binding_table != vk.Buffer.null_handle) {
            self.gc.*.vkd.destroyBuffer(self.gc.*.dev, self.shader_binding_table, null);
            self.gc.*.vkd.freeMemory(self.gc.*.dev, self.shader_binding_table_memory, null);
        }

        // Create new SBT buffer
        const sbt_buffer_info = vk.BufferCreateInfo{
            .size = sbt_size,
            .usage = vk.BufferUsageFlags{
                .shader_binding_table_bit_khr = true,
                .shader_device_address_bit = true,
            },
            .sharing_mode = .exclusive,
            .queue_family_index_count = 0,
            .p_queue_family_indices = null,
            .flags = .{},
        };

        self.shader_binding_table = try self.gc.*.vkd.createBuffer(self.gc.*.dev, &sbt_buffer_info, null);

        const memory_requirements = self.gc.*.vkd.getBufferMemoryRequirements(self.gc.*.dev, self.shader_binding_table);
        const memory_type_index = try self.gc.*.findMemoryTypeIndex(memory_requirements.memory_type_bits, vk.MemoryPropertyFlags{
            .host_visible_bit = true,
            .host_coherent_bit = true,
        });

        // Add device address flag for SBT memory allocation
        const alloc_flags = vk.MemoryAllocateFlagsInfo{
            .s_type = vk.StructureType.memory_allocate_flags_info,
            .p_next = null,
            .flags = vk.MemoryAllocateFlags{
                .device_address_bit = true,
            },
            .device_mask = 0,
        };

        const alloc_info = vk.MemoryAllocateInfo{
            .s_type = vk.StructureType.memory_allocate_info,
            .p_next = &alloc_flags,
            .allocation_size = memory_requirements.size,
            .memory_type_index = memory_type_index,
        };

        self.shader_binding_table_memory = try self.gc.*.vkd.allocateMemory(self.gc.*.dev, &alloc_info, null);
        try self.gc.*.vkd.bindBufferMemory(self.gc.*.dev, self.shader_binding_table, self.shader_binding_table_memory, 0);

        // Map memory and copy shader handles
        const mapped_memory = try self.gc.*.vkd.mapMemory(self.gc.*.dev, self.shader_binding_table_memory, 0, sbt_size, .{});
        defer self.gc.*.vkd.unmapMemory(self.gc.*.dev, self.shader_binding_table_memory);

        const sbt_data: [*]u8 = @ptrCast(mapped_memory);

        // Zero out the entire buffer first
        @memset(sbt_data[0..sbt_size], 0);

        // Copy handles with proper alignment using consistent stride
        for (0..group_count) |i| {
            const src_offset = i * handle_size;
            const dst_offset = i * sbt_stride;

            if (dst_offset + handle_size <= sbt_size) {
                @memcpy(sbt_data[dst_offset .. dst_offset + handle_size], group_handles[src_offset .. src_offset + handle_size]);
            }
        }

        self.sbt_created = true;
    }

    /// Create BLAS asynchronously using pre-computed raytracing data from the scene bridge
    pub fn createBlasAsyncFromRtData(self: *RaytracingSystem, rt_data: @import("../rendering/scene_view.zig").RaytracingData, completion_callback: ?*const fn (*anyopaque, []const BlasResult, ?TlasResult) void, callback_context: ?*anyopaque) !void {
        if (self.bvh_build_in_progress) {
            // Reset progress flag to allow new build to supersede
            self.bvh_build_in_progress = false;
        }

        self.bvh_build_in_progress = true;
        try self.bvh_builder.buildRtDataBvhAsync(rt_data, completion_callback, callback_context);
    }

    /// Create BLAS asynchronously using the multithreaded builder (legacy)
    pub fn createBlasAsync(self: *RaytracingSystem, scene: *Scene, completion_callback: ?*const fn (*anyopaque, []const BlasResult, ?TlasResult) void, callback_context: ?*anyopaque) !void {
        if (self.bvh_build_in_progress) {
            // Reset progress flag to allow new build to supersede
            self.bvh_build_in_progress = false;
        }

        self.bvh_build_in_progress = true;
        try self.bvh_builder.buildSceneBvhAsync(scene, completion_callback, callback_context);
    }

    /// Create TLAS asynchronously using pre-computed raytracing data from the scene bridge
    pub fn createTlasAsyncFromRtData(self: *RaytracingSystem, rt_data: @import("../rendering/scene_view.zig").RaytracingData, completion_callback: ?*const fn (*anyopaque, BvhBuildResult) void, callback_context: ?*anyopaque) !void {
        // Wait for BLAS to complete first
        // if (!self.bvh_builder.isWorkComplete()) {
        //     log(.WARN, "RaytracingSystem", "BLAS builds still in progress, cannot create TLAS yet", .{});
        //     return error.BlasNotReady;
        // }

        // Get completed BLAS results
        const blas_results = try self.bvh_builder.takeCompletedBlas(self.allocator);
        defer self.allocator.free(blas_results);

        if (blas_results.len == 0) {
            log(.WARN, "RaytracingSystem", "No BLAS results available for TLAS creation", .{});
            return error.NoBlasResults;
        }

        // Create instance data from RT data and BLAS results
        var instances = std.ArrayList(InstanceData){};
        defer instances.deinit(self.allocator);

        // Match RT instances to BLAS results by geometry_id
        for (rt_data.instances, 0..) |rt_instance, rt_index| {
            // Find the corresponding BLAS result for this RT instance by geometry_id
            var found_blas: ?BlasResult = null;
            for (blas_results) |blas_result| {
                // Match by geometry_id (which corresponds to the RT geometry index)
                if (blas_result.geometry_id == rt_index) {
                    found_blas = blas_result;
                    break;
                }
            }

            if (found_blas) |blas_result| {
                const clamped_material_id = @min(rt_instance.material_index, 255); // Clamp to 8 bits for safety

                const instance_data = InstanceData{
                    .blas_address = blas_result.device_address,
                    .transform = rt_instance.transform,
                    .custom_index = clamped_material_id,
                    .mask = 0xFF,
                    .sbt_offset = 0,
                    .flags = 0,
                };

                try instances.append(self.allocator, instance_data);
            } else {
                log(.WARN, "RaytracingSystem", "No BLAS found for RT instance {} (geometry_id={})", .{ rt_index, rt_index });
            }
        }

        if (instances.items.len == 0) {
            log(.ERROR, "RaytracingSystem", "No instances created for TLAS from RT data! Check if RT instances match BLAS count", .{});
            return error.NoInstances;
        }

        _ = try self.bvh_builder.buildTlasAsync(instances.items, .high, completion_callback, callback_context);
    }

    /// Create TLAS asynchronously after BLAS completion
    pub fn createTlasAsync(self: *RaytracingSystem, scene: *Scene, completion_callback: ?*const fn (*anyopaque, BvhBuildResult) void, callback_context: ?*anyopaque) !void {
        // Wait for BLAS to complete first
        if (!self.bvh_builder.isWorkComplete()) {
            log(.WARN, "RaytracingSystem", "BLAS builds still in progress, cannot create TLAS yet", .{});
            return error.BlasNotReady;
        }

        // Get completed BLAS results
        const blas_results = try self.bvh_builder.takeCompletedBlas(self.allocator);
        defer self.allocator.free(blas_results);

        if (blas_results.len == 0) {
            log(.WARN, "RaytracingSystem", "No BLAS results available for TLAS creation", .{});
            return error.NoBlasResults;
        }

        // Create instance data from scene and BLAS results
        var instances = std.ArrayList(InstanceData){};
        defer instances.deinit(self.allocator);

        var blas_index: usize = 0;
        var objects_with_model: u32 = 0;
        for (scene.objects.items) |*object| {
            // Check for both direct model pointers and asset-based models
            const has_model = (object.model != null) or (object.has_model and object.model_asset != null);

            if (has_model) {
                objects_with_model += 1;

                if (object.model) |model| {
                    // Handle direct model pointers (legacy path)
                    for (model.meshes.items) |*model_mesh| {
                        if (blas_index >= blas_results.len) break;

                        const blas_result = blas_results[blas_index];
                        const clamped_material_id = @min(model_mesh.geometry.mesh.material_id, 255); // Clamp to 8 bits for safety

                        const instance_data = InstanceData{
                            .blas_address = blas_result.device_address,
                            .transform = object.transform.local2world.to_3x4(),
                            .custom_index = clamped_material_id,
                            .mask = 0xFF,
                            .sbt_offset = 0,
                            .flags = 0,
                        };

                        try instances.append(self.allocator, instance_data);
                        blas_index += 1;
                    }
                } else if (object.model_asset) |model_asset_id| {
                    // Handle asset-based models (new path)
                    const resolved_asset_id = scene.asset_manager.getAssetIdForRendering(model_asset_id);

                    // Get the model from asset manager to count meshes
                    if (scene.asset_manager.getModel(resolved_asset_id)) |model| {
                        if (model.meshes.items.len > 0) {
                            for (model.meshes.items) |*model_mesh| {
                                if (blas_index >= blas_results.len) break;

                                const blas_result = blas_results[blas_index];
                                const clamped_material_id = @min(model_mesh.geometry.mesh.material_id, 255); // Clamp to 8 bits for safety

                                const instance_data = InstanceData{
                                    .blas_address = blas_result.device_address,
                                    .transform = object.transform.local2world.to_3x4(),
                                    .custom_index = clamped_material_id,
                                    .mask = 0xFF,
                                    .sbt_offset = 0,
                                    .flags = 0,
                                };

                                try instances.append(self.allocator, instance_data);
                                blas_index += 1;
                            }
                        }
                    } else {
                        log(.WARN, "RaytracingSystem", "Asset-based object has unresolved model asset: {}", .{model_asset_id});
                    }
                }
            }
        }

        if (instances.items.len == 0) {
            log(.ERROR, "RaytracingSystem", "No instances created for TLAS! Check if scene objects have valid models with meshes", .{});
            return error.NoInstances;
        }

        _ = try self.bvh_builder.buildTlasAsync(instances.items, .high, completion_callback, callback_context);
    }

    /// Check if BVH build is complete and update internal state
    pub fn updateBvhBuildStatus(self: *RaytracingSystem) !bool {
        if (!self.bvh_build_in_progress) return true;

        if (self.bvh_builder.isWorkComplete()) {
            // Update our internal state with completed results
            const blas_results = try self.bvh_builder.takeCompletedBlas(self.allocator);

            // Update legacy arrays for compatibility
            self.blas_handles.clearRetainingCapacity();
            self.blas_buffers.clearRetainingCapacity();

            for (blas_results) |blas_result| {
                try self.blas_handles.append(self.allocator, blas_result.acceleration_structure);
                try self.blas_buffers.append(self.allocator, blas_result.buffer);
            }

            // Check if we should trigger TLAS creation now that BLAS is complete
            const blas_count = blas_results.len;
            self.allocator.free(blas_results);

            // Update TLAS if available
            if (self.bvh_builder.takeCompletedTlas()) |tlas_result| {
                self.tlas = tlas_result.acceleration_structure;
                self.tlas_buffer = tlas_result.buffer;
                self.tlas_instance_buffer = tlas_result.instance_buffer;
                self.tlas_buffer_initialized = true;
                self.tlas_instance_buffer_initialized = true;
                self.completed_tlas = tlas_result;

                // Mark descriptors as needing update since we have a new TLAS
                self.descriptors_need_update = true;
            } else if (blas_count > 0) {
                // BLAS is complete but no TLAS yet - we need a scene reference to build TLAS
                // This will be handled by the scene view update mechanism
            }

            self.bvh_build_in_progress = false;

            // Check if there's a pending rebuild request
            if (self.bvh_rebuild_pending) {
                self.bvh_rebuild_pending = false;
                // The next frame's update() call will detect the changes and trigger a new rebuild
            }

            return true;
        }

        return false;
    }

    /// Update BVH state using data gathered from the scene bridge
    pub fn update(self: *RaytracingSystem, scene_bridge: *@import("../rendering/scene_bridge.zig").SceneBridge, frame_info: *const @import("../rendering/frameinfo.zig").FrameInfo) !bool {
        _ = frame_info;
        // Check if there's a pending rebuild that can now be started (build completed)
        if (self.bvh_rebuild_pending and !self.bvh_build_in_progress) {
            self.bvh_rebuild_pending = false;
            // Force a rebuild by calling this function recursively with the current scene state
            return false;
            // return try self.update(scene_bridge, frame_info); // Force resources_updated=true
        }

        // Check if BVH rebuild is needed using SceneBridge's intelligent tracking
        if (scene_bridge.checkBvhRebuildNeeded(false)) {
            // Get current raytracing data (will be rebuilt if cache is dirty)
            const rebuild_rt_data = scene_bridge.getRaytracingData();

            // Debug the condition evaluation
            self.blas_handles.clearRetainingCapacity();
            self.blas_buffers.clearRetainingCapacity();

            // Check if we can start rebuild immediately or need to queue it
            self.bvh_build_in_progress = true;

            // Clear existing results to prevent accumulation from previous rebuilds
            self.bvh_builder.clearResults();
            self.completed_tlas = null;
            self.bvh_rebuild_pending = false; // Clear any pending flag since we're starting now

            // Use the new RT data-based BVH building to ensure consistency with BLAS callback
            self.createBlasAsyncFromRtData(rebuild_rt_data, blasCompletionCallback, self) catch |err| {
                log(.ERROR, "raytracing", "Failed to start BVH rebuild from RT data: {}", .{err});
                return false;
            };
        }

        // Get current raytracing data for checks (BLAS building creates raytracing cache)
        const rt_data = scene_bridge.getRaytracingData();

        // Simple TLAS creation check: BLAS count matches geometry count AND no TLAS exists
        const blas_count = self.blas_handles.items.len;
        const geometry_count = rt_data.geometries.len;
        const has_tlas = self.completed_tlas != null;
        const counts_match = blas_count == geometry_count;
        const has_blas = blas_count > 0;
        const should_create_tlas = counts_match and !has_tlas and has_blas;

        if (should_create_tlas) {
            // Use RT data-based TLAS creation for consistency with callback
            self.createTlasAsyncFromRtData(rt_data, tlasCompletionCallback, self) catch |err| {
                log(.ERROR, "raytracing", "Failed to start TLAS creation from RT data: {}", .{err});
            };
            return true; // TLAS creation started
        }

        return false; // No rebuild needed or already in progress
    }

    /// BLAS completion callback - called when BLAS builds finish
    fn blasCompletionCallback(context: *anyopaque, blas_results: []const BlasResult, tlas_result: ?TlasResult) void {
        const self = @as(*RaytracingSystem, @ptrCast(@alignCast(context)));

        // Update legacy arrays for compatibility with existing conditional logic

        for (blas_results) |blas_result| {
            self.blas_handles.append(self.allocator, blas_result.acceleration_structure) catch |err| {
                log(.ERROR, "raytracing", "Failed to append BLAS handle: {}", .{err});
            };
            self.blas_buffers.append(self.allocator, blas_result.buffer) catch |err| {
                log(.ERROR, "raytracing", "Failed to append BLAS buffer: {}", .{err});
            };
        }

        // Update TLAS if provided
        if (tlas_result) |tlas| {
            self.tlas = tlas.acceleration_structure;
            self.tlas_buffer = tlas.buffer;
            self.tlas_instance_buffer = tlas.instance_buffer;
            self.tlas_buffer_initialized = true;
            self.tlas_instance_buffer_initialized = true;
            self.completed_tlas = tlas;
            self.descriptors_need_update = true;
        }

        // Mark BVH build as no longer in progress
        self.bvh_build_in_progress = false;
    }

    /// TLAS completion callback - called when TLAS build finishes
    fn tlasCompletionCallback(context: *anyopaque, result: @import("multithreaded_bvh_builder.zig").BvhBuildResult) void {
        const self = @as(*RaytracingSystem, @ptrCast(@alignCast(context)));

        switch (result) {
            .build_tlas => |tlas_result| {
                // Update raytracing system state with completed TLAS
                self.tlas = tlas_result.acceleration_structure;
                self.tlas_buffer = tlas_result.buffer;
                self.tlas_instance_buffer = tlas_result.instance_buffer;
                self.tlas_buffer_initialized = true;
                self.tlas_instance_buffer_initialized = true;
                self.completed_tlas = tlas_result;
                self.bvh_build_in_progress = false;
                self.tlas_dirty = true;

                // Mark descriptors as needing update since we have a new TLASRenderPassDescriptorManager
                self.descriptors_need_update = true;

                // Clear builder ownership now that the system tracks this TLAS
                _ = self.bvh_builder.takeCompletedTlas();

                // Check if there was a pending rebuild and trigger it
                if (self.bvh_rebuild_pending) {
                    // Next frame will detect and trigger the pending rebuild
                }
            },
            else => {
                log(.WARN, "raytracing", "TLAS callback received unexpected result type", .{});
            },
        }
    }

    /// Legacy createBLAS method for compatibility
    pub fn createBLAS(self: *RaytracingSystem, scene: *Scene) !void {
        self.blas_handles.clearRetainingCapacity();
        self.blas_buffers.clearRetainingCapacity();
        var mesh_count: usize = 0;
        for (scene.objects.items) |*object| {
            if (object.model) |model| {
                for (model.meshes.items) |*model_mesh| {
                    const geometry = model_mesh.geometry;
                    mesh_count += 1;
                    const vertex_buffer = geometry.mesh.vertex_buffer;
                    const index_buffer = geometry.mesh.index_buffer;
                    const vertex_count = geometry.mesh.vertices.items.len;
                    const index_count = geometry.mesh.indices.items.len;
                    const vertex_size = @sizeOf(Vertex);
                    var vertex_address_info = vk.BufferDeviceAddressInfo{
                        .s_type = vk.StructureType.buffer_device_address_info,
                        .buffer = vertex_buffer.?.buffer,
                    };
                    var index_address_info = vk.BufferDeviceAddressInfo{
                        .s_type = vk.StructureType.buffer_device_address_info,
                        .buffer = index_buffer.?.buffer,
                    };
                    const vertex_device_address = self.gc.vkd.getBufferDeviceAddress(self.gc.dev, &vertex_address_info);
                    const index_device_address = self.gc.vkd.getBufferDeviceAddress(self.gc.dev, &index_address_info);
                    var geometry_vk = vk.AccelerationStructureGeometryKHR{
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
                        .p_geometries = @ptrCast(&geometry_vk),
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
                    // Record build command using secondary command buffer (no queue submission)
                    var secondary_cmd = try self.gc.beginWorkerCommandBuffer();
                    const p_range_info = &range_info;
                    self.gc.vkd.cmdBuildAccelerationStructuresKHR(secondary_cmd.command_buffer, 1, @ptrCast(&build_info), @ptrCast(&p_range_info));
                    // Add scratch buffer to deferred cleanup (will be cleaned up after command execution)
                    try secondary_cmd.addPendingResource(scratch_buffer.buffer, scratch_buffer.memory);
                    // End secondary command buffer and add to pending collection
                    try self.gc.endWorkerCommandBuffer(&secondary_cmd);
                    // Don't call scratch_buffer.deinit() - it will be cleaned up after command execution
                    try self.blas_handles.append(self.allocator, blas);
                    try self.blas_buffers.append(self.allocator, blas_buffer);
                    // Optionally deinit scratch_buffer here
                }
            }
        }
        if (mesh_count == 0) {
            log(.WARN, "RaytracingSystem", "No meshes found in scene, skipping BLAS creation.", .{});
            return;
        }
    }

    /// Create TLAS for all mesh instances in the scene
    pub fn createTLAS(self: *RaytracingSystem, scene: *Scene) !void {
        var instances = try std.ArrayList(vk.AccelerationStructureInstanceKHR).initCapacity(self.allocator, self.blas_handles.items.len);
        var mesh_index: u32 = 0;
        for (scene.objects.items) |*object| {
            if (object.model) |model| {
                for (model.meshes.items) |mesh| {
                    var blas_addr_info = vk.AccelerationStructureDeviceAddressInfoKHR{
                        .s_type = vk.StructureType.acceleration_structure_device_address_info_khr,
                        .acceleration_structure = self.blas_handles.items[mesh_index],
                    };
                    const blas_device_address = self.gc.vkd.getAccelerationStructureDeviceAddressKHR(self.gc.dev, &blas_addr_info);
                    try instances.append(self.allocator, vk.AccelerationStructureInstanceKHR{
                        .transform = .{ .matrix = object.transform.local2world.to_3x4() },
                        .instance_custom_index_and_mask = .{ .instance_custom_index = @intCast(mesh.geometry.mesh.*.material_id), .mask = 0xFF },
                        .instance_shader_binding_table_record_offset_and_flags = .{ .instance_shader_binding_table_record_offset = 0, .flags = 0 },
                        .acceleration_structure_reference = blas_device_address,
                    });
                    mesh_index += 1;
                }
            }
        }
        if (instances.items.len == 0) {
            log(.WARN, "RaytracingSystem", "No mesh instances found in scene, skipping TLAS creation.", .{});
            return;
        }
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
        // --- TLAS instance buffer setup ---
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
                    .array_of_pointers = .false,
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
        // 5. Record build command using secondary command buffer
        var secondary_cmd = try self.gc.beginWorkerCommandBuffer();
        const tlas_p_range_info = &tlas_range_info;
        self.gc.vkd.cmdBuildAccelerationStructuresKHR(secondary_cmd.command_buffer, 1, @ptrCast(&tlas_build_info), @ptrCast(&tlas_p_range_info));
        // Add TLAS scratch buffer to deferred cleanup (will be cleaned up after command execution)
        try secondary_cmd.addPendingResource(tlas_scratch_buffer.buffer, tlas_scratch_buffer.memory);
        // End secondary command buffer and add to pending collection
        try self.gc.endWorkerCommandBuffer(&secondary_cmd);
        // Don't call tlas_scratch_buffer.deinit() - it will be cleaned up after command execution
        // Store instance buffer for later deinit (this buffer persists for rendering)
        self.tlas_instance_buffer = instance_buffer;
        self.tlas_instance_buffer_initialized = true;
        return;
    }

    /// Record the ray tracing command buffer for a frame (multi-mesh/instance)
    pub fn recordCommandBuffer(self: *RaytracingSystem, frame_info: FrameInfo, swapchain: *Swapchain, group_count: u32, global_ubo_buffer_info: vk.DescriptorBufferInfo) !void {
        const gc = self.gc;
        _ = group_count;
        const swapchain_changed = swapchain.extent.width != self.width or swapchain.extent.height != self.height;

        // Only update descriptors if we have a valid TLAS and need updates
        if ((swapchain_changed) and self.tlas != .null_handle) {
            // Only recreate output texture if swapchain changed
            if (swapchain_changed) {
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
            }

            // Update descriptors with valid TLAS
            try self.descriptor_pool.resetPool();
            const output_image_info = self.output_texture.getDescriptorInfo();
            var set_writer = DescriptorWriter.init(gc, self.descriptor_set_layout, self.descriptor_pool, self.allocator);
            _ = set_writer.writeImage(1, @constCast(&output_image_info))
                .writeBuffer(2, @constCast(&global_ubo_buffer_info));
            try set_writer.build(&self.descriptor_sets[frame_info.current_frame]);

            // Clear the update flag
            self.descriptors_need_update = false;
        }

        // --- existing code for binding pipeline, descriptor sets, SBT, etc...

        gc.vkd.cmdBindPipeline(frame_info.command_buffer, vk.PipelineBindPoint.ray_tracing_khr, self.pipeline.pipeline);

        // Get descriptor set from the descriptor manager
        if (self.descriptor_manager.getDescriptorSet(0, frame_info.current_frame)) |descriptor_set| {
            gc.vkd.cmdBindDescriptorSets(frame_info.command_buffer, vk.PipelineBindPoint.ray_tracing_khr, self.pipeline_layout, 0, 1, @ptrCast(&descriptor_set), 0, null);
        } else {
            // Fallback to legacy descriptor sets if new system not ready
            gc.vkd.cmdBindDescriptorSets(frame_info.command_buffer, vk.PipelineBindPoint.ray_tracing_khr, self.pipeline_layout, 0, 1, @ptrCast(&self.descriptor_sets[frame_info.current_frame]), 0, null);
        }

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
        // Wait for all GPU operations to complete before cleanup
        self.gc.vkd.deviceWaitIdle(self.gc.dev) catch |err| {
            log(.WARN, "RaytracingSystem", "Failed to wait for device idle during deinit: {}", .{err});
        };

        // Deinit multithreaded BVH builder first (heap allocated)
        self.bvh_builder.deinit();
        self.allocator.destroy(self.bvh_builder);
        self.completed_blas_list.deinit(self.allocator);

        if (self.tlas_instance_buffer_initialized) self.tlas_instance_buffer.deinit();
        // Deinit all BLAS buffers and destroy BLAS acceleration structures
        for (self.blas_buffers.items, self.blas_handles.items) |*buf, blas| {
            buf.deinit();
            if (blas != .null_handle) self.gc.vkd.destroyAccelerationStructureKHR(self.gc.dev, blas, null);
        }

        self.blas_buffers.deinit(self.allocator);
        self.blas_handles.deinit(self.allocator);
        // Destroy TLAS acceleration structure and deinit TLAS buffer
        if (self.tlas != .null_handle) self.gc.vkd.destroyAccelerationStructureKHR(self.gc.dev, self.tlas, null);
        self.tlas_buffer.deinit();
        // Destroy shader binding table buffer and free its memory
        if (self.shader_binding_table != .null_handle) self.gc.vkd.destroyBuffer(self.gc.dev, self.shader_binding_table, null);
        if (self.shader_binding_table_memory != .null_handle) self.gc.vkd.freeMemory(self.gc.dev, self.shader_binding_table_memory, null);
        // Destroy output image/texture

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

    /// Request texture descriptor update on next frame
    pub fn requestTextureDescriptorUpdate(self: *RaytracingSystem) void {
        //log(.DEBUG, "raytracing", "Raytracing texture descriptor update requested", .{});
        self.descriptors_need_update = true;
    }

    /// Create initial descriptor sets for all frames (called during init)
    pub fn createInitialDescriptorSets(self: *RaytracingSystem, ubo_infos: []const vk.DescriptorBufferInfo, material_buffer_info: vk.DescriptorBufferInfo, texture_image_infos: []const vk.DescriptorImageInfo) !void {
        for (0..MAX_FRAMES_IN_FLIGHT) |frame_index| {
            try self.descriptor_pool.allocateDescriptor(self.descriptor_set_layout.descriptor_set_layout, &self.descriptor_sets[frame_index]);

            // Create initial descriptor set with available data (without AS for now)
            const output_image_info = self.output_texture.getDescriptorInfo();
            var set_writer = DescriptorWriter.init(self.gc, self.descriptor_set_layout, self.descriptor_pool, self.allocator);

            // Write image, UBO, material and texture data (skip AS binding 0 for now)
            _ = set_writer.writeImage(1, @constCast(&output_image_info));
            // Only use the UBO info for the current frame, not all frames
            if (frame_index < ubo_infos.len) {
                _ = set_writer.writeBuffer(2, @constCast(&ubo_infos[frame_index]));
            }
            _ = set_writer.writeBuffer(5, @constCast(&material_buffer_info))
                .writeImages(6, texture_image_infos);

            try set_writer.build(&self.descriptor_sets[frame_index]);
        }
    }

    /// Create/update acceleration structure descriptors when TLAS is ready (per-frame)
    pub fn updateASData(self: *RaytracingSystem) !void {
        if (self.completed_tlas == null) {
            return; // TLAS not ready yet
        }

        // This function now just sets a flag - the actual descriptor update
        // happens in updateFullRaytracingData which combines AS + materials + textures
        self.descriptors_need_update = true;
    }

    /// Update material buffer and texture descriptors using descriptor manager
    pub fn updateMaterialData(self: *RaytracingSystem) !void {
        // This function now just sets a flag - the actual descriptor update
        // happens in updateFullRaytracingData which combines AS + materials + textures
        self.descriptors_need_update = true;
    }

    /// Update all raytracing descriptors using the new descriptor manager
    pub fn updateFullRaytracingData(
        self: *RaytracingSystem,
        frame_index: u32,
        global_ubo_buffer_info: vk.DescriptorBufferInfo,
        vertex_buffer_infos: []const vk.DescriptorBufferInfo,
        index_buffer_infos: []const vk.DescriptorBufferInfo,
        material_buffer_info: vk.DescriptorBufferInfo,
        texture_image_infos: []const vk.DescriptorImageInfo,
    ) !void {
        if (self.completed_tlas == null) {
            return; // TLAS not ready yet
        }

        // Get acceleration structure info
        const as_info = try self.getAccelerationStructureDescriptorInfo();

        // Get output image info
        const output_image_info = self.output_texture.getDescriptorInfo();

        // Create resource bindings for all descriptors
        var bindings = std.ArrayList(ResourceBinding).init(self.allocator);
        defer bindings.deinit();

        // Acceleration structure (special handling needed)
        const accel_binding = ResourceBinding{
            .set_index = 0,
            .binding = 0,
            .resource = .{ .acceleration_structure = @constCast(&as_info) },
        };
        try bindings.append(accel_binding);

        // Output image
        const output_binding = ResourceBinding{
            .set_index = 0,
            .binding = 1,
            .resource = .{ .image = output_image_info },
        };
        try bindings.append(output_binding);

        // UBO
        const ubo_binding = ResourceBinding{
            .set_index = 0,
            .binding = 2,
            .resource = .{ .buffer = global_ubo_buffer_info },
        };
        try bindings.append(ubo_binding);

        // Vertex buffers
        if (vertex_buffer_infos.len > 0) {
            const vertex_binding = ResourceBinding{
                .set_index = 0,
                .binding = 3,
                .resource = .{ .buffer_array = vertex_buffer_infos },
            };
            try bindings.append(vertex_binding);
        }

        // Index buffers
        if (index_buffer_infos.len > 0) {
            const index_binding = ResourceBinding{
                .set_index = 0,
                .binding = 4,
                .resource = .{ .buffer_array = index_buffer_infos },
            };
            try bindings.append(index_binding);
        }

        // Material buffer
        const material_binding = ResourceBinding{
            .set_index = 0,
            .binding = 5,
            .resource = .{ .buffer = material_buffer_info },
        };
        try bindings.append(material_binding);

        // Texture array
        if (texture_image_infos.len > 0) {
            const texture_binding = ResourceBinding{
                .set_index = 0,
                .binding = 6,
                .resource = .{ .image_array = texture_image_infos },
            };
            try bindings.append(texture_binding);
        }

        // Update descriptors using the render pass descriptor manager
        try self.descriptor_manager.updateDescriptorSet(frame_index, bindings.items);

        // Clear the update flag
        self.descriptors_need_update = false;
    }
};
