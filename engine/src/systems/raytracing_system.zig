const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("../core/graphics_context.zig").GraphicsContext;
const Buffer = @import("../core/buffer.zig").Buffer;
const FrameInfo = @import("../rendering/frameinfo.zig").FrameInfo;
const log = @import("../utils/log.zig").log;
const ThreadPool = @import("../threading/thread_pool.zig").ThreadPool;
const RenderData = @import("../rendering/render_data_types.zig");
const MAX_FRAMES_IN_FLIGHT = @import("../core/swapchain.zig").MAX_FRAMES_IN_FLIGHT;
// Import the new multithreaded BVH builder
const MultithreadedBvhBuilder = @import("multithreaded_bvh_builder.zig").MultithreadedBvhBuilder;
const BlasResult = @import("multithreaded_bvh_builder.zig").BlasResult;
const TlasResult = @import("multithreaded_bvh_builder.zig").TlasResult;
const InstanceData = @import("multithreaded_bvh_builder.zig").InstanceData;
const BvhBuildResult = @import("multithreaded_bvh_builder.zig").BvhBuildResult;

fn alignForward(val: usize, alignment: usize) usize {
    return ((val + alignment - 1) / alignment) * alignment;
}

/// Per-frame resources queued for destruction
const PerFrameDestroyQueue = struct {
    blas_handles: std.ArrayList(vk.AccelerationStructureKHR),
    blas_buffers: std.ArrayList(Buffer),
    tlas_handles: std.ArrayList(vk.AccelerationStructureKHR),
    tlas_buffers: std.ArrayList(Buffer),
    tlas_instance_buffers: std.ArrayList(Buffer),

    fn init() PerFrameDestroyQueue {
        return .{
            .blas_handles = .{},
            .blas_buffers = .{},
            .tlas_handles = .{},
            .tlas_buffers = .{},
            .tlas_instance_buffers = .{},
        };
    }

    fn deinit(self: *PerFrameDestroyQueue, allocator: std.mem.Allocator) void {
        self.blas_handles.deinit(allocator);
        self.blas_buffers.deinit(allocator);
        self.tlas_handles.deinit(allocator);
        self.tlas_buffers.deinit(allocator);
        self.tlas_instance_buffers.deinit(allocator);
    }
};

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

    // Per-frame destruction queues
    per_frame_destroy: [MAX_FRAMES_IN_FLIGHT]PerFrameDestroyQueue = undefined,

    // Orphaned TLAS from async callbacks (processed in next update with proper frame context)
    orphaned_tlas: ?struct {
        handle: vk.AccelerationStructureKHR,
        buffer: Buffer,
        instance_buffer: Buffer,
        buffer_initialized: bool,
        instance_buffer_initialized: bool,
    } = null,

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

        // Initialize per-frame destruction queues
        var per_frame_destroy: [MAX_FRAMES_IN_FLIGHT]PerFrameDestroyQueue = undefined;
        for (&per_frame_destroy) |*queue| {
            queue.* = PerFrameDestroyQueue.init();
        }

        return RaytracingSystem{
            .gc = gc,
            .bvh_builder = bvh_builder,
            .completed_tlas = null,
            .bvh_build_in_progress = false,
            .blas_handles = try std.ArrayList(vk.AccelerationStructureKHR).initCapacity(allocator, 8),
            .blas_buffers = try std.ArrayList(Buffer).initCapacity(allocator, 8),
            .per_frame_destroy = per_frame_destroy,
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

    /// Rebuild TLAS using existing BLAS with updated transforms (optimization for transform-only changes)
    fn rebuildTlasWithExistingBlas(self: *RaytracingSystem, rt_data: RenderData.RaytracingData, completion_callback: ?*const fn (*anyopaque, BvhBuildResult) void, callback_context: ?*anyopaque) !void {
        // Create instance data from RT data using existing BLAS handles
        var instances = std.ArrayList(InstanceData){};
        defer instances.deinit(self.allocator);

        // Match RT instances to existing BLAS by index
        for (rt_data.instances, 0..) |rt_instance, rt_index| {
            if (rt_index >= self.blas_handles.items.len) {
                log(.WARN, "raytracing", "RT instance {} exceeds BLAS count {}", .{ rt_index, self.blas_handles.items.len });
                continue;
            }

            // Get BLAS device address from existing BLAS
            const blas_handle = self.blas_handles.items[rt_index];
            var addr_info = vk.AccelerationStructureDeviceAddressInfoKHR{
                .s_type = vk.StructureType.acceleration_structure_device_address_info_khr,
                .acceleration_structure = blas_handle,
            };
            const blas_address = self.gc.vkd.getAccelerationStructureDeviceAddressKHR(self.gc.dev, &addr_info);

            const clamped_material_id = @min(rt_instance.material_index, 255);

            const instance_data = InstanceData{
                .blas_address = blas_address,
                .transform = rt_instance.transform, // NEW transforms!
                .custom_index = clamped_material_id,
                .mask = 0xFF,
                .sbt_offset = 0,
                .flags = 0,
            };

            try instances.append(self.allocator, instance_data);
        }

        if (instances.items.len == 0) {
            log(.ERROR, "raytracing", "No instances created for TLAS rebuild!", .{});
            return error.NoInstances;
        }

        // Build new TLAS with existing BLAS and new transforms
        _ = try self.bvh_builder.buildTlasAsync(instances.items, .high, completion_callback, callback_context);
    }

    /// Update TLAS instance transforms without rebuilding BVH
    /// This is much faster than rebuilding when only transforms have changed
    fn updateTlasInstanceTransforms(self: *RaytracingSystem, render_system: *@import("../ecs/systems/render_system.zig").RenderSystem) !void {
        // Get updated instance data
        const rt_data = try render_system.getRaytracingData();
        defer {
            self.allocator.free(rt_data.instances);
            self.allocator.free(rt_data.geometries);
            self.allocator.free(rt_data.materials);
        }

        // Map the instance buffer if not already mapped
        const instance_buffer_size = self.tlas_instance_buffer.buffer_size;
        const was_mapped = self.tlas_instance_buffer.mapped != null;
        if (!was_mapped) {
            try self.tlas_instance_buffer.map(instance_buffer_size, 0);
        }
        defer {
            if (!was_mapped) {
                self.tlas_instance_buffer.unmap();
            }
        }

        // Get the mapped memory as an array of acceleration structure instances
        const instance_data = @as([*]vk.AccelerationStructureInstanceKHR, @ptrCast(@alignCast(self.tlas_instance_buffer.mapped.?)));
        const instance_count = @min(rt_data.instances.len, instance_buffer_size / @sizeOf(vk.AccelerationStructureInstanceKHR));

        // Update each instance's transform matrix
        for (rt_data.instances[0..instance_count], 0..) |rt_instance, i| {
            // Copy the 3x4 transform matrix (first 12 floats of the instance)
            const transform_3x4 = rt_instance.transform;
            @memcpy(&instance_data[i].transform.matrix, &transform_3x4);
        }

        // Flush the changes to ensure GPU sees them
        try self.tlas_instance_buffer.flush(instance_buffer_size, 0);
    }

    /// Create BLAS asynchronously using pre-computed raytracing data from the scene bridge
    pub fn createBlasAsyncFromRtData(self: *RaytracingSystem, rt_data: RenderData.RaytracingData, completion_callback: ?*const fn (*anyopaque, []const BlasResult, ?TlasResult) void, callback_context: ?*anyopaque) !void {
        if (self.bvh_build_in_progress) {
            // Reset progress flag to allow new build to supersede
            self.bvh_build_in_progress = false;
        }

        self.bvh_build_in_progress = true;
        try self.bvh_builder.buildRtDataBvhAsync(rt_data, completion_callback, callback_context);
    }

    /// Create TLAS asynchronously using pre-computed raytracing data from the scene bridge
    pub fn createTlasAsyncFromRtData(self: *RaytracingSystem, rt_data: RenderData.RaytracingData, completion_callback: ?*const fn (*anyopaque, BvhBuildResult) void, callback_context: ?*anyopaque) !void {
        // Use BLAS results that were already stored in RT system arrays via blasCompletionCallback
        // Don't call takeCompletedBlas() - that would try to consume results that were already consumed by the callback

        if (self.blas_handles.items.len == 0) {
            log(.WARN, "RaytracingSystem", "No BLAS results available for TLAS creation", .{});
            return error.NoBlasResults;
        }

        // Create instance data from RT data and stored BLAS results
        var instances = std.ArrayList(InstanceData){};
        defer instances.deinit(self.allocator);

        // Match RT instances to BLAS by geometry_id
        // BLAS are stored in order of geometry_id, so we can use indices directly
        for (rt_data.instances, 0..) |rt_instance, rt_index| {
            // Get BLAS device address using geometry_id as index
            if (rt_index >= self.blas_handles.items.len) {
                log(.WARN, "RaytracingSystem", "No BLAS found for RT instance {} (out of bounds)", .{rt_index});
                continue;
            }

            // Get BLAS device address from stored acceleration structure
            var blas_address_info = vk.AccelerationStructureDeviceAddressInfoKHR{
                .s_type = vk.StructureType.acceleration_structure_device_address_info_khr,
                .acceleration_structure = self.blas_handles.items[rt_index],
            };
            const blas_device_address = self.gc.vkd.getAccelerationStructureDeviceAddressKHR(self.gc.dev, &blas_address_info);

            const clamped_material_id = @min(rt_instance.material_index, 255); // Clamp to 8 bits for safety

            const instance_data = InstanceData{
                .blas_address = blas_device_address,
                .transform = rt_instance.transform,
                .custom_index = clamped_material_id,
                .mask = 0xFF,
                .sbt_offset = 0,
                .flags = 0,
            };

            try instances.append(self.allocator, instance_data);
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
        frame_info: *const FrameInfo,
        geo_changed: bool,
    ) !bool {
        const frame_index = frame_info.current_frame;

        // Process any orphaned TLAS from async callbacks
        // When a new TLAS completes while another is still in use, the old one is marked as orphaned
        // We queue it here with proper frame context rather than destroying it immediately in the callback
        if (self.orphaned_tlas) |orphan| {
            self.per_frame_destroy[frame_index].tlas_handles.append(self.allocator, orphan.handle) catch |err| {
                log(.ERROR, "raytracing", "Failed to queue orphaned TLAS handle: {}", .{err});
            };
            if (orphan.buffer_initialized) {
                self.per_frame_destroy[frame_index].tlas_buffers.append(self.allocator, orphan.buffer) catch |err| {
                    log(.ERROR, "raytracing", "Failed to queue orphaned TLAS buffer: {}", .{err});
                };
            }
            if (orphan.instance_buffer_initialized) {
                self.per_frame_destroy[frame_index].tlas_instance_buffers.append(self.allocator, orphan.instance_buffer) catch |err| {
                    log(.ERROR, "raytracing", "Failed to queue orphaned TLAS instance buffer: {}", .{err});
                };
            }

            self.orphaned_tlas = null;
        }

        // OPTIMIZATION: Transform-only rebuild path
        // If only entity transforms changed (no new/deleted geometry), we can keep existing BLAS
        // and just rebuild the TLAS with updated instance transforms - much faster than full rebuild
        const is_transform_only = render_system.transform_only_change and render_system.renderables_dirty;

        if (is_transform_only and self.tlas != .null_handle and self.blas_handles.items.len > 0 and !self.bvh_build_in_progress) {
            // Get updated RT data to verify geometry count matches
            const rt_data_check = try render_system.getRaytracingData();
            defer {
                self.allocator.free(rt_data_check.instances);
                self.allocator.free(rt_data_check.geometries);
                self.allocator.free(rt_data_check.materials);
            }

            // Verify BLAS count matches current geometry count (safety check)
            // If counts don't match, geometry changed and we need a full rebuild instead
            if (self.blas_handles.items.len == rt_data_check.geometries.len) {
                // Safe to do transform-only update - just rebuild TLAS, keep BLAS
                self.bvh_build_in_progress = true;

                // Queue old TLAS resources for destruction (BLAS stays - geometry unchanged)
                if (self.tlas != .null_handle) {
                    self.per_frame_destroy[frame_index].tlas_handles.append(self.allocator, self.tlas) catch |err| {
                        log(.ERROR, "raytracing", "Failed to queue TLAS handle for destruction: {}", .{err});
                        self.gc.vkd.destroyAccelerationStructureKHR(self.gc.dev, self.tlas, null);
                    };
                    // Clear handle immediately to prevent async callback from creating an orphan
                    self.tlas = vk.AccelerationStructureKHR.null_handle;
                }

                if (self.tlas_buffer_initialized) {
                    self.per_frame_destroy[frame_index].tlas_buffers.append(self.allocator, self.tlas_buffer) catch |err| {
                        log(.ERROR, "raytracing", "Failed to queue TLAS buffer for destruction: {}", .{err});
                        var immediate = self.tlas_buffer;
                        immediate.deinit();
                    };
                    self.tlas_buffer_initialized = false;
                }

                if (self.tlas_instance_buffer_initialized) {
                    self.per_frame_destroy[frame_index].tlas_instance_buffers.append(self.allocator, self.tlas_instance_buffer) catch |err| {
                        log(.ERROR, "raytracing", "Failed to queue TLAS instance buffer for destruction: {}", .{err});
                        var immediate = self.tlas_instance_buffer;
                        immediate.deinit();
                    };
                    self.tlas_instance_buffer_initialized = false;
                }

                // Rebuild TLAS with existing BLAS and updated instance transforms
                self.completed_tlas = null;
                try self.rebuildTlasWithExistingBlas(rt_data_check, tlasCompletionCallback, self);

                // Clear dirty flags immediately to prevent triggering another rebuild next frame
                render_system.renderables_dirty = false;
                render_system.transform_only_change = false;

                return true;
            } else {
                // Geometry count mismatch detected - need full rebuild instead
                log(.WARN, "raytracing", "Transform-only rebuild aborted: BLAS count ({}) != geometry count ({}). Falling back to full rebuild.", .{ self.blas_handles.items.len, rt_data_check.geometries.len });
                // Fall through to full rebuild path below
            }
        }

        // Full BVH rebuild path - triggered when geometry changes or BLAS/TLAS don't exist
        // This rebuilds both BLAS (geometry acceleration structures) and TLAS (instance hierarchy)
        const rebuild_needed = try render_system.checkBvhRebuildNeeded();
        if ((rebuild_needed or geo_changed) and !self.bvh_build_in_progress) {
            // Mark build as in progress immediately to prevent duplicate builds
            self.bvh_build_in_progress = true;

            // Get raytracing data from RenderSystem
            const rebuild_rt_data = try render_system.getRaytracingData();
            defer {
                self.allocator.free(rebuild_rt_data.instances);
                self.allocator.free(rebuild_rt_data.geometries);
                self.allocator.free(rebuild_rt_data.materials);
            }

            // Queue old TLAS resources for destruction (will be destroyed after GPU finishes)
            if (self.tlas != .null_handle) {
                self.per_frame_destroy[frame_index].tlas_handles.append(self.allocator, self.tlas) catch |err| {
                    log(.ERROR, "raytracing", "Failed to queue TLAS handle for destruction: {}", .{err});
                    self.gc.vkd.destroyAccelerationStructureKHR(self.gc.dev, self.tlas, null);
                };
                // Clear handle immediately so async callback won't try to queue it again
                self.tlas = vk.AccelerationStructureKHR.null_handle;
            }

            if (self.tlas_buffer_initialized) {
                self.per_frame_destroy[frame_index].tlas_buffers.append(self.allocator, self.tlas_buffer) catch |err| {
                    log(.ERROR, "raytracing", "Failed to queue TLAS buffer for destruction: {}", .{err});
                    var immediate = self.tlas_buffer;
                    immediate.deinit();
                };
                self.tlas_buffer_initialized = false;
            }

            if (self.tlas_instance_buffer_initialized) {
                self.per_frame_destroy[frame_index].tlas_instance_buffers.append(self.allocator, self.tlas_instance_buffer) catch |err| {
                    log(.ERROR, "raytracing", "Failed to queue TLAS instance buffer for destruction: {}", .{err});
                    var immediate = self.tlas_instance_buffer;
                    immediate.deinit();
                };
                self.tlas_instance_buffer_initialized = false;
            }

            // Queue all old BLAS resources for destruction
            for (self.blas_handles.items, self.blas_buffers.items) |handle, buffer| {
                self.per_frame_destroy[frame_index].blas_handles.append(self.allocator, handle) catch |err| {
                    log(.ERROR, "raytracing", "Failed to queue BLAS handle for destruction: {}", .{err});
                    if (handle != .null_handle) self.gc.vkd.destroyAccelerationStructureKHR(self.gc.dev, handle, null);
                    var immediate = buffer;
                    immediate.deinit();
                    continue;
                };

                self.per_frame_destroy[frame_index].blas_buffers.append(self.allocator, buffer) catch |err| {
                    log(.ERROR, "raytracing", "Failed to queue BLAS buffer for destruction: {}", .{err});
                    if (handle != .null_handle) self.gc.vkd.destroyAccelerationStructureKHR(self.gc.dev, handle, null);
                    var temp = buffer;
                    temp.deinit();
                    if (self.per_frame_destroy[frame_index].blas_handles.items.len > 0) {
                        self.per_frame_destroy[frame_index].blas_handles.items.len -= 1;
                    }
                    continue;
                };
            }

            // Clear local arrays - new BLAS will be added by async callbacks
            self.blas_handles.clearRetainingCapacity();
            self.blas_buffers.clearRetainingCapacity();

            // Clear any stale results from previous builds
            self.bvh_builder.clearResults();
            self.completed_tlas = null;

            // Start async BLAS building - completion callbacks will trigger TLAS build
            self.createBlasAsyncFromRtData(rebuild_rt_data, blasCompletionCallback, self) catch |err| {
                log(.ERROR, "raytracing", "Failed to start BVH rebuild from RT data: {}", .{err});
                self.bvh_build_in_progress = false;
                return false;
            };

            // Clear ALL dirty flags immediately after starting rebuild
            // This is critical to prevent rebuild spam - without this, the flags would still be set
            // on the next frame, triggering another rebuild even though one is already in progress
            render_system.renderables_dirty = false;
            render_system.transform_only_change = false;
            render_system.raytracing_descriptors_dirty = false;

            return true;
        }

        // TLAS creation check - happens after BLAS building completes
        // If BLAS exist but no TLAS, create one from the current geometry
        // Get current raytracing data for checks (BLAS building creates raytracing cache)
        const rt_data = try render_system.getRaytracingData();
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
            self.bvh_build_in_progress = true;
            log(.INFO, "raytracing", "Starting TLAS creation from RT data ({} geometries)", .{geometry_count});
            // Use RT data-based TLAS creation for consistency with callback
            self.createTlasAsyncFromRtData(rt_data, tlasCompletionCallback, self) catch |err| {
                log(.ERROR, "raytracing", "Failed to start TLAS creation from RT data: {}", .{err});
            };

            return true; // TLAS creation started
        }

        return false; // No rebuild needed or already in progress
    }

    /// Update BVH state using data gathered from the scene bridge
    /// Update using RenderData (for legacy scene system)
    pub fn updateFromRenderData(self: *RaytracingSystem, scene_bridge: *RenderData.RenderData, frame_info: *const FrameInfo) !bool {
        const frame_index = frame_info.current_frame;

        // Check if BVH rebuild is needed using RenderData's intelligent tracking
        if (scene_bridge.checkBvhRebuildNeeded(false)) {
            // Get current raytracing data (will be rebuilt if cache is dirty)
            const rebuild_rt_data = scene_bridge.getRaytracingData();

            // Debug the condition evaluation
            if (self.tlas != .null_handle) {
                self.per_frame_destroy[frame_index].tlas_handles.append(self.allocator, self.tlas) catch |err| {
                    log(.ERROR, "raytracing", "Failed to queue TLAS handle for destruction: {}", .{err});
                    self.gc.vkd.destroyAccelerationStructureKHR(self.gc.dev, self.tlas, null);
                };
                self.tlas = vk.AccelerationStructureKHR.null_handle;
            }

            if (self.tlas_buffer_initialized) {
                self.per_frame_destroy[frame_index].tlas_buffers.append(self.allocator, self.tlas_buffer) catch |err| {
                    log(.ERROR, "raytracing", "Failed to queue TLAS buffer for destruction: {}", .{err});
                    var immediate = self.tlas_buffer;
                    immediate.deinit();
                };
                self.tlas_buffer_initialized = false;
            }

            if (self.tlas_instance_buffer_initialized) {
                self.per_frame_destroy[frame_index].tlas_instance_buffers.append(self.allocator, self.tlas_instance_buffer) catch |err| {
                    log(.ERROR, "raytracing", "Failed to queue TLAS instance buffer for destruction: {}", .{err});
                    var immediate = self.tlas_instance_buffer;
                    immediate.deinit();
                };
                self.tlas_instance_buffer_initialized = false;
            }

            for (self.blas_handles.items, self.blas_buffers.items) |handle, buffer| {
                self.per_frame_destroy[frame_index].blas_handles.append(self.allocator, handle) catch |err| {
                    log(.ERROR, "raytracing", "Failed to queue BLAS handle for destruction: {}", .{err});
                    if (handle != .null_handle) self.gc.vkd.destroyAccelerationStructureKHR(self.gc.dev, handle, null);
                    var immediate = buffer;
                    immediate.deinit();
                    continue;
                };

                self.per_frame_destroy[frame_index].blas_buffers.append(self.allocator, buffer) catch |err| {
                    log(.ERROR, "raytracing", "Failed to queue BLAS buffer for destruction: {}", .{err});
                    if (handle != .null_handle) self.gc.vkd.destroyAccelerationStructureKHR(self.gc.dev, handle, null);
                    var temp = buffer;
                    temp.deinit();
                    if (self.per_frame_destroy[frame_index].blas_handles.items.len > 0) {
                        self.per_frame_destroy[frame_index].blas_handles.items.len -= 1;
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

    /// BLAS completion callback - called asynchronously when BLAS builds finish
    /// Updates internal arrays with new acceleration structures
    fn blasCompletionCallback(context: *anyopaque, blas_results: []const BlasResult, tlas_result: ?TlasResult) void {
        const self = @as(*RaytracingSystem, @ptrCast(@alignCast(context)));

        // Store completed BLAS in internal arrays
        for (blas_results) |blas_result| {
            self.blas_handles.append(self.allocator, blas_result.acceleration_structure) catch |err| {
                log(.ERROR, "raytracing", "Failed to append BLAS handle: {}", .{err});
            };
            self.blas_buffers.append(self.allocator, blas_result.buffer) catch |err| {
                log(.ERROR, "raytracing", "Failed to append BLAS buffer: {}", .{err});
            };
        }

        // If TLAS was also built (full rebuild path), update it
        if (tlas_result) |tlas| {
            self.tlas = tlas.acceleration_structure;
            self.tlas_buffer = tlas.buffer;
            self.tlas_buffer_initialized = true;
            self.tlas_instance_buffer = tlas.instance_buffer;
            self.tlas_instance_buffer_initialized = true;
            self.bvh_build_in_progress = false;
            self.completed_tlas = tlas;
        }
    }

    /// TLAS completion callback - called when TLAS build finishes
    fn tlasCompletionCallback(context: *anyopaque, result: BvhBuildResult) void {
        const self = @as(*RaytracingSystem, @ptrCast(@alignCast(context)));

        switch (result) {
            .build_tlas => |tlas_result| {
                // TLAS build completed asynchronously - update system state

                // Handle case where a new TLAS completes while an old one still exists
                // This can happen during rapid rebuilds (e.g., hot-reload scenarios)
                // Mark old TLAS as orphaned rather than destroying immediately - we don't have frame context here
                if (self.tlas != .null_handle) {
                    self.orphaned_tlas = .{
                        .handle = self.tlas,
                        .buffer = self.tlas_buffer,
                        .instance_buffer = self.tlas_instance_buffer,
                        .buffer_initialized = self.tlas_buffer_initialized,
                        .instance_buffer_initialized = self.tlas_instance_buffer_initialized,
                    };
                }

                // Update raytracing system state with completed TLAS
                self.tlas = tlas_result.acceleration_structure;
                self.tlas_buffer = tlas_result.buffer;
                self.tlas_buffer_initialized = true;
                self.tlas_instance_buffer = tlas_result.instance_buffer;
                self.tlas_instance_buffer_initialized = true;
                self.completed_tlas = tlas_result;
                self.bvh_build_in_progress = false;
                self.tlas_dirty = true;

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
            log(.WARN, "raytracing", "Failed to wait for device idle during deinit: {}", .{err});
        };

        // Clean up current resources first (before flushing queues)
        // This ensures we don't double-free if current resources were queued for destruction
        if (self.tlas_instance_buffer_initialized) {
            self.tlas_instance_buffer.deinit();
            self.tlas_instance_buffer_initialized = false;
        }
        if (self.tlas_buffer_initialized) {
            self.tlas_buffer.deinit();
            self.tlas_buffer_initialized = false;
        }
        if (self.tlas != .null_handle) {
            self.gc.vkd.destroyAccelerationStructureKHR(self.gc.dev, self.tlas, null);
            self.tlas = .null_handle;
        }

        // Destroy all current BLAS
        for (self.blas_buffers.items, self.blas_handles.items) |*buf, blas| {
            buf.deinit();
            if (blas != .null_handle) self.gc.vkd.destroyAccelerationStructureKHR(self.gc.dev, blas, null);
        }
        self.blas_buffers.clearRetainingCapacity();
        self.blas_handles.clearRetainingCapacity();

        // Flush all per-frame destruction queues (old resources queued for deferred destruction)
        for (&self.per_frame_destroy) |*queue| {
            self.flushDestroyQueue(queue);
        }

        // Deinit multithreaded BVH builder (heap allocated)
        self.bvh_builder.deinit();
        self.allocator.destroy(self.bvh_builder);

        // Free the per-frame queue allocations
        for (&self.per_frame_destroy) |*queue| {
            queue.deinit(self.allocator);
        }

        self.blas_buffers.deinit(self.allocator);
        self.blas_handles.deinit(self.allocator);
        // Destroy shader binding table buffer and free its memory
        if (self.shader_binding_table != .null_handle) self.gc.vkd.destroyBuffer(self.gc.dev, self.shader_binding_table, null);
        if (self.shader_binding_table_memory != .null_handle) self.gc.vkd.freeMemory(self.gc.dev, self.shader_binding_table_memory, null);
        // Destroy output image/texture

    }

    /// Flush a single destroy queue (used during deinit)
    /// Flush a destruction queue, destroying all queued resources
    /// Called after GPU has finished using resources for a particular frame
    fn flushDestroyQueue(self: *RaytracingSystem, queue: *PerFrameDestroyQueue) void {
        // Destroy BLAS acceleration structures first, then their backing buffers
        for (queue.blas_handles.items) |handle| {
            if (handle != .null_handle) {
                self.gc.vkd.destroyAccelerationStructureKHR(self.gc.dev, handle, null);
            }
        }
        queue.blas_handles.clearRetainingCapacity();

        for (queue.blas_buffers.items) |*buf| {
            if (buf.buffer != .null_handle or buf.memory != .null_handle) {
                buf.deinit();
            }
        }
        queue.blas_buffers.clearRetainingCapacity();

        // Destroy TLAS acceleration structures first, then their backing buffers
        for (queue.tlas_handles.items) |handle| {
            if (handle != .null_handle) {
                self.gc.vkd.destroyAccelerationStructureKHR(self.gc.dev, handle, null);
            }
        }
        queue.tlas_handles.clearRetainingCapacity();

        for (queue.tlas_buffers.items) |*buf| {
            if (buf.buffer != .null_handle or buf.memory != .null_handle) {
                buf.deinit();
            }
        }
        queue.tlas_buffers.clearRetainingCapacity();

        for (queue.tlas_instance_buffers.items) |*buf| {
            if (buf.buffer != .null_handle or buf.memory != .null_handle) {
                buf.deinit();
            }
        }
        queue.tlas_instance_buffers.clearRetainingCapacity();
    }

    /// Flush deferred resources for a specific frame
    /// Call this AFTER waiting for that frame's fence to ensure GPU is done
    pub fn flushDeferredFrame(self: *RaytracingSystem, frame_index: u32) void {
        self.flushDestroyQueue(&self.per_frame_destroy[frame_index]);
    }

    /// Flush ALL pending destruction queues immediately
    /// Use this when disabling the RT pass to clean up before re-enabling
    pub fn flushAllPendingDestruction(self: *RaytracingSystem) void {
        for (&self.per_frame_destroy) |*queue| {
            self.flushDestroyQueue(queue);
        }
    }
};
