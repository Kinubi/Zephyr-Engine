const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("../core/graphics_context.zig").GraphicsContext;
const Buffer = @import("../core/buffer.zig").Buffer;
const FrameInfo = @import("../rendering/frameinfo.zig").FrameInfo;
const log = @import("../utils/log.zig").log;
const ThreadPool = @import("../threading/thread_pool.zig").ThreadPool;
const SceneBridge = @import("../rendering/scene_bridge.zig");

// Import the new multithreaded BVH builder
const MultithreadedBvhBuilder = @import("multithreaded_bvh_builder.zig").MultithreadedBvhBuilder;
const BlasResult = @import("multithreaded_bvh_builder.zig").BlasResult;
const TlasResult = @import("multithreaded_bvh_builder.zig").TlasResult;
const InstanceData = @import("multithreaded_bvh_builder.zig").InstanceData;
const BvhBuildResult = @import("multithreaded_bvh_builder.zig").BvhBuildResult;

fn alignForward(val: usize, alignment: usize) usize {
    return ((val + alignment - 1) / alignment) * alignment;
}

/// Enhanced Raytracing system with multithreaded BVH building
pub const RaytracingSystem = struct {
    gc: *GraphicsContext, // Use 'gc' for consistency with Swapchain

    // Legacy single AS support (for compatibility)
    blas: vk.AccelerationStructureKHR = undefined,
    tlas: vk.AccelerationStructureKHR = undefined,
    tlas_buffer: Buffer = undefined,
    tlas_instance_buffer: Buffer = undefined,
    tlas_instance_buffer_initialized: bool = false,
    tlas_buffer_initialized: bool = false,
    tlas_dirty: bool = false,

    // New multithreaded BVH system
    bvh_builder: *MultithreadedBvhBuilder = undefined,
    completed_tlas: ?TlasResult = null,
    bvh_build_in_progress: bool = false,

    shader_binding_table: vk.Buffer = undefined,
    shader_binding_table_memory: vk.DeviceMemory = undefined,

    // Legacy BLAS arrays (for compatibility)
    blas_handles: std.ArrayList(vk.AccelerationStructureKHR) = undefined,
    blas_buffers: std.ArrayList(Buffer) = undefined,
    destroy_blas_handles: std.ArrayList(vk.AccelerationStructureKHR) = undefined,
    destroy_blas_buffers: std.ArrayList(Buffer) = undefined,
    destroy_tlas_handles: std.ArrayList(vk.AccelerationStructureKHR) = undefined,
    destroy_tlas_buffers: std.ArrayList(Buffer) = undefined,
    destroy_tlas_instance_buffers: std.ArrayList(Buffer) = undefined,
    allocator: std.mem.Allocator = undefined,

    /// Enhanced init with multithreaded BVH support
    pub fn init(
        gc: *GraphicsContext,
        allocator: std.mem.Allocator,
        thread_pool: *ThreadPool,
    ) !RaytracingSystem {
        // RaytracingSystem now focuses only on BVH building and management
        // Rendering/descriptor management is handled by RaytracingRenderer

        // Initialize BVH builder
        const bvh_builder = try allocator.create(MultithreadedBvhBuilder);
        bvh_builder.* = try MultithreadedBvhBuilder.init(gc, thread_pool, allocator);

        return RaytracingSystem{
            .gc = gc,
            .bvh_builder = bvh_builder,
            .completed_tlas = null,
            .bvh_build_in_progress = false,
            .blas_handles = try std.ArrayList(vk.AccelerationStructureKHR).initCapacity(allocator, 8),
            .blas_buffers = try std.ArrayList(Buffer).initCapacity(allocator, 8),
            .destroy_blas_handles = try std.ArrayList(vk.AccelerationStructureKHR).initCapacity(allocator, 8),
            .destroy_blas_buffers = try std.ArrayList(Buffer).initCapacity(allocator, 8),
            .destroy_tlas_handles = try std.ArrayList(vk.AccelerationStructureKHR).initCapacity(allocator, 1),
            .destroy_tlas_buffers = try std.ArrayList(Buffer).initCapacity(allocator, 1),
            .destroy_tlas_instance_buffers = try std.ArrayList(Buffer).initCapacity(allocator, 1),
            .allocator = allocator,
            .tlas_instance_buffer_initialized = false,
            .tlas_buffer_initialized = false,
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
    }

    /// Create BLAS asynchronously using pre-computed raytracing data from the scene bridge
    pub fn createBlasAsyncFromRtData(self: *RaytracingSystem, rt_data: SceneBridge.RaytracingData, completion_callback: ?*const fn (*anyopaque, []const BlasResult, ?TlasResult) void, callback_context: ?*anyopaque) !void {
        if (self.bvh_build_in_progress) {
            // Reset progress flag to allow new build to supersede
            self.bvh_build_in_progress = false;
        }

        self.bvh_build_in_progress = true;
        try self.bvh_builder.buildRtDataBvhAsync(rt_data, completion_callback, callback_context);
    }

    /// Create TLAS asynchronously using pre-computed raytracing data from the scene bridge
    pub fn createTlasAsyncFromRtData(self: *RaytracingSystem, rt_data: SceneBridge.RaytracingData, completion_callback: ?*const fn (*anyopaque, BvhBuildResult) void, callback_context: ?*anyopaque) !void {
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

    /// Update BVH state using data from RenderSystem (for modern ECS-based rendering)
    pub fn update(
        self: *RaytracingSystem,
        render_system: *@import("../ecs/systems/render_system.zig").RenderSystem,
        world: *@import("../ecs/world.zig").World,
        asset_manager: *@import("../assets/asset_manager.zig").AssetManager,
        frame_info: *const FrameInfo,
    ) !bool {
        _ = frame_info;

        // Check if BVH rebuild is needed
        if (render_system.checkBvhRebuildNeeded()) {
            // Get raytracing data from RenderSystem
            const rebuild_rt_data = try render_system.getRaytracingData(world, asset_manager, self.allocator);
            defer {
                self.allocator.free(rebuild_rt_data.instances);
                self.allocator.free(rebuild_rt_data.geometries);
                self.allocator.free(rebuild_rt_data.materials);
            }

            // Destroy old TLAS if it exists
            if (self.tlas != .null_handle) {
                self.destroy_tlas_handles.append(self.allocator, self.tlas) catch |err| {
                    log(.ERROR, "raytracing", "Failed to queue TLAS handle for destruction: {}", .{err});
                    self.gc.vkd.destroyAccelerationStructureKHR(self.gc.dev, self.tlas, null);
                };
                self.tlas = vk.AccelerationStructureKHR.null_handle;
            }

            if (self.tlas_buffer_initialized) {
                self.destroy_tlas_buffers.append(self.allocator, self.tlas_buffer) catch |err| {
                    log(.ERROR, "raytracing", "Failed to queue TLAS buffer for destruction: {}", .{err});
                    var immediate = self.tlas_buffer;
                    immediate.deinit();
                };
                self.tlas_buffer_initialized = false;
            }

            if (self.tlas_instance_buffer_initialized) {
                self.destroy_tlas_instance_buffers.append(self.allocator, self.tlas_instance_buffer) catch |err| {
                    log(.ERROR, "raytracing", "Failed to queue TLAS instance buffer for destruction: {}", .{err});
                    var immediate = self.tlas_instance_buffer;
                    immediate.deinit();
                };
                self.tlas_instance_buffer_initialized = false;
            }

            for (self.blas_handles.items, self.blas_buffers.items) |handle, buffer| {
                self.destroy_blas_handles.append(self.allocator, handle) catch |err| {
                    log(.ERROR, "raytracing", "Failed to queue BLAS handle for destruction: {}", .{err});
                    if (handle != .null_handle) self.gc.vkd.destroyAccelerationStructureKHR(self.gc.dev, handle, null);
                    var immediate = buffer;
                    immediate.deinit();
                    continue;
                };

                self.destroy_blas_buffers.append(self.allocator, buffer) catch |err| {
                    log(.ERROR, "raytracing", "Failed to queue BLAS buffer for destruction: {}", .{err});
                    if (handle != .null_handle) self.gc.vkd.destroyAccelerationStructureKHR(self.gc.dev, handle, null);
                    var temp = buffer;
                    temp.deinit();
                    if (self.destroy_blas_handles.items.len > 0) {
                        self.destroy_blas_handles.items.len -= 1;
                    }
                    continue;
                };
            }

            self.blas_handles.clearRetainingCapacity();
            self.blas_buffers.clearRetainingCapacity();

            // Check if we can start rebuild immediately or need to queue it
            self.bvh_build_in_progress = true;

            // Clear existing results to prevent accumulation from previous rebuilds
            self.bvh_builder.clearResults();
            self.completed_tlas = null;

            // Use the new RT data-based BVH building to ensure consistency with BLAS callback
            self.createBlasAsyncFromRtData(rebuild_rt_data, blasCompletionCallback, self) catch |err| {
                log(.ERROR, "raytracing", "Failed to start BVH rebuild from RT data: {}", .{err});
                return false;
            };
            
            log(.INFO, "raytracing", "Started BLAS rebuild from RT data ({} geometries)", .{rebuild_rt_data.geometries.len});
            
            // Mark renderables as synced after starting rebuild
            render_system.markRenderablesSynced();
            
            // Return true to indicate rebuild started
            return true;
        }

        // Get current raytracing data for checks (BLAS building creates raytracing cache)
        const rt_data = try render_system.getRaytracingData(world, asset_manager, self.allocator);
        defer {
            self.allocator.free(rt_data.instances);
            self.allocator.free(rt_data.geometries);
            self.allocator.free(rt_data.materials);
        }

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

            // Mark renderables as synced
            render_system.markRenderablesSynced();

            return true; // TLAS creation started
        }

        // Mark renderables as synced even if no TLAS was created
        render_system.markRenderablesSynced();

        return false; // No rebuild needed or already in progress
    }

    /// Update BVH state using data gathered from the scene bridge
    /// Update using SceneBridge (for legacy scene system)
    pub fn updateFromSceneBridge(self: *RaytracingSystem, scene_bridge: *SceneBridge.SceneBridge, frame_info: *const FrameInfo) !bool {
        _ = frame_info;
        // Check if BVH rebuild is needed using SceneBridge's intelligent tracking
        if (scene_bridge.checkBvhRebuildNeeded(false)) {
            // Get current raytracing data (will be rebuilt if cache is dirty)
            const rebuild_rt_data = scene_bridge.getRaytracingData();

            // Debug the condition evaluation
            if (self.tlas != .null_handle) {
                self.destroy_tlas_handles.append(self.allocator, self.tlas) catch |err| {
                    log(.ERROR, "raytracing", "Failed to queue TLAS handle for destruction: {}", .{err});
                    self.gc.vkd.destroyAccelerationStructureKHR(self.gc.dev, self.tlas, null);
                };
                self.tlas = vk.AccelerationStructureKHR.null_handle;
            }

            if (self.tlas_buffer_initialized) {
                self.destroy_tlas_buffers.append(self.allocator, self.tlas_buffer) catch |err| {
                    log(.ERROR, "raytracing", "Failed to queue TLAS buffer for destruction: {}", .{err});
                    var immediate = self.tlas_buffer;
                    immediate.deinit();
                };
                self.tlas_buffer_initialized = false;
            }

            if (self.tlas_instance_buffer_initialized) {
                self.destroy_tlas_instance_buffers.append(self.allocator, self.tlas_instance_buffer) catch |err| {
                    log(.ERROR, "raytracing", "Failed to queue TLAS instance buffer for destruction: {}", .{err});
                    var immediate = self.tlas_instance_buffer;
                    immediate.deinit();
                };
                self.tlas_instance_buffer_initialized = false;
            }

            for (self.blas_handles.items, self.blas_buffers.items) |handle, buffer| {
                self.destroy_blas_handles.append(self.allocator, handle) catch |err| {
                    log(.ERROR, "raytracing", "Failed to queue BLAS handle for destruction: {}", .{err});
                    if (handle != .null_handle) self.gc.vkd.destroyAccelerationStructureKHR(self.gc.dev, handle, null);
                    var immediate = buffer;
                    immediate.deinit();
                    continue;
                };

                self.destroy_blas_buffers.append(self.allocator, buffer) catch |err| {
                    log(.ERROR, "raytracing", "Failed to queue BLAS buffer for destruction: {}", .{err});
                    if (handle != .null_handle) self.gc.vkd.destroyAccelerationStructureKHR(self.gc.dev, handle, null);
                    var temp = buffer;
                    temp.deinit();
                    if (self.destroy_blas_handles.items.len > 0) {
                        self.destroy_blas_handles.items.len -= 1;
                    }
                    continue;
                };
            }

            self.blas_handles.clearRetainingCapacity();
            self.blas_buffers.clearRetainingCapacity();

            // Check if we can start rebuild immediately or need to queue it
            self.bvh_build_in_progress = true;

            // Clear existing results to prevent accumulation from previous rebuilds
            self.bvh_builder.clearResults();
            self.completed_tlas = null;

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
            self.tlas_buffer_initialized = true;
            self.tlas_instance_buffer = tlas.instance_buffer;
            self.tlas_instance_buffer_initialized = true;
            self.completed_tlas = tlas;
        }

        // Mark BVH build as no longer in progress
        self.bvh_build_in_progress = false;
    }

    /// TLAS completion callback - called when TLAS build finishes
    fn tlasCompletionCallback(context: *anyopaque, result: BvhBuildResult) void {
        const self = @as(*RaytracingSystem, @ptrCast(@alignCast(context)));

        switch (result) {
            .build_tlas => |tlas_result| {
                // Update raytracing system state with completed TLAS
                self.tlas = tlas_result.acceleration_structure;
                self.tlas_buffer = tlas_result.buffer;
                self.tlas_buffer_initialized = true;
                self.tlas_instance_buffer = tlas_result.instance_buffer;
                self.tlas_instance_buffer_initialized = true;
                self.completed_tlas = tlas_result;
                self.bvh_build_in_progress = false;
                self.tlas_dirty = true;

                // Mark descriptors as needing update since we have a new TLAS

                self.flushDeferredAccelerationStructures();

                // Clear builder ownership now that the system tracks this TLAS
                _ = self.bvh_builder.takeCompletedTlas();
            },
            else => {
                log(.WARN, "raytracing", "TLAS callback received unexpected result type", .{});
            },
        }
    }

    pub fn deinit(self: *RaytracingSystem) void {
        // Wait for all GPU operations to complete before cleanup
        self.gc.vkd.deviceWaitIdle(self.gc.dev) catch |err| {
            log(.WARN, "RaytracingSystem", "Failed to wait for device idle during deinit: {}", .{err});
        };

        // Deinit multithreaded BVH builder first (heap allocated)
        self.bvh_builder.deinit();
        self.allocator.destroy(self.bvh_builder);

        if (self.tlas_instance_buffer_initialized) self.tlas_instance_buffer.deinit();
        if (self.tlas_buffer_initialized) self.tlas_buffer.deinit();
        self.flushDeferredAccelerationStructures();
        // Deinit all BLAS buffers and destroy BLAS acceleration structures
        for (self.blas_buffers.items, self.blas_handles.items) |*buf, blas| {
            buf.deinit();
            if (blas != .null_handle) self.gc.vkd.destroyAccelerationStructureKHR(self.gc.dev, blas, null);
        }

        self.blas_buffers.deinit(self.allocator);
        self.blas_handles.deinit(self.allocator);
        self.destroy_blas_buffers.deinit(self.allocator);
        self.destroy_blas_handles.deinit(self.allocator);
        self.destroy_tlas_buffers.deinit(self.allocator);
        self.destroy_tlas_handles.deinit(self.allocator);
        self.destroy_tlas_instance_buffers.deinit(self.allocator);
        // Destroy TLAS acceleration structure and deinit TLAS buffer
        if (self.tlas != .null_handle) self.gc.vkd.destroyAccelerationStructureKHR(self.gc.dev, self.tlas, null);
        // Destroy shader binding table buffer and free its memory
        if (self.shader_binding_table != .null_handle) self.gc.vkd.destroyBuffer(self.gc.dev, self.shader_binding_table, null);
        if (self.shader_binding_table_memory != .null_handle) self.gc.vkd.freeMemory(self.gc.dev, self.shader_binding_table_memory, null);
        // Destroy output image/texture

    }

    fn flushDeferredAccelerationStructures(self: *RaytracingSystem) void {
        for (self.destroy_blas_buffers.items, self.destroy_blas_handles.items) |*buf, handle| {
            buf.deinit();
            if (handle != .null_handle) {
                self.gc.vkd.destroyAccelerationStructureKHR(self.gc.dev, handle, null);
            }
        }
        self.destroy_blas_buffers.clearRetainingCapacity();
        self.destroy_blas_handles.clearRetainingCapacity();

        for (self.destroy_tlas_buffers.items) |*buf| {
            buf.deinit();
        }
        self.destroy_tlas_buffers.clearRetainingCapacity();

        for (self.destroy_tlas_instance_buffers.items) |*buf| {
            buf.deinit();
        }
        self.destroy_tlas_instance_buffers.clearRetainingCapacity();

        for (self.destroy_tlas_handles.items) |handle| {
            if (handle != .null_handle) {
                self.gc.vkd.destroyAccelerationStructureKHR(self.gc.dev, handle, null);
            }
        }
        self.destroy_tlas_handles.clearRetainingCapacity();
    }
};
