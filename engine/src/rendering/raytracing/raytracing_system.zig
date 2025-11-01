const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("../../core/graphics_context.zig").GraphicsContext;
const Buffer = @import("../../core/buffer.zig").Buffer;
const FrameInfo = @import("../../rendering/frameinfo.zig").FrameInfo;
const log = @import("../../utils/log.zig").log;
const ThreadPoolMod = @import("../../threading/thread_pool.zig");

const RenderData = @import("../../rendering/render_data_types.zig");
const RenderSystem = @import("../../ecs/systems/render_system.zig").RenderSystem;
const MAX_FRAMES_IN_FLIGHT = @import("../../core/swapchain.zig").MAX_FRAMES_IN_FLIGHT;
// Import the new multithreaded BVH builder
const MultithreadedBvhBuilder = @import("multithreaded_bvh_builder.zig").MultithreadedBvhBuilder;
const BlasResult = @import("multithreaded_bvh_builder.zig").BlasResult;
const TlasResult = @import("multithreaded_bvh_builder.zig").TlasResult;
const InstanceData = @import("multithreaded_bvh_builder.zig").InstanceData;
const BvhBuildResult = @import("multithreaded_bvh_builder.zig").BvhBuildResult;
const TlasWorker = @import("tlas_worker.zig");
const TlasJob = TlasWorker.TlasJob;
const ThreadPool = ThreadPoolMod.ThreadPool;

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

/// TLAS Registry: Double-buffered TLAS for safe lifecycle management
/// Similar to BLAS registry, but single entry since we only have one scene TLAS
const TlasRegistry = struct {
    current: std.atomic.Value(?*TlasEntry) = std.atomic.Value(?*TlasEntry).init(null),

    const TlasEntry = struct {
        acceleration_structure: vk.AccelerationStructureKHR,
        buffer: Buffer,
        instance_buffer: Buffer,
        device_address: vk.DeviceAddress,
        instance_count: u32,
        build_time_ns: u64,
    };
};

/// Enhanced Raytracing system with multithreaded BVH building
pub const RaytracingSystem = struct {
    gc: *GraphicsContext, // Use 'gc' for consistency with Swapchain

    // TLAS Registry: atomic pointer to current TLAS
    // When new TLAS arrives: get old, store new, queue old for destruction
    // Always know which TLAS to destroy - no handle juggling needed
    tlas_registry: TlasRegistry = .{},

    // Multithreaded BVH system
    bvh_builder: *MultithreadedBvhBuilder = undefined,
    bvh_build_in_progress: bool = false,
    next_tlas_job_id: u64 = 1,

    // Shader Binding Table (for raytracing)
    shader_binding_table: vk.Buffer = undefined,
    shader_binding_table_memory: vk.DeviceMemory = undefined,

    // Per-frame destruction queues for deferred resource cleanup
    // Flow: When spawning TLAS worker, we queue old TLAS/BLAS for destruction in per_frame_destroy[current_frame]
    // These are destroyed MAX_FRAMES_IN_FLIGHT frames later (after GPU finishes using them)
    // This ensures GPU synchronization without blocking or orphaning
    per_frame_destroy: [MAX_FRAMES_IN_FLIGHT]PerFrameDestroyQueue = undefined,

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
            .bvh_build_in_progress = false,
            .per_frame_destroy = per_frame_destroy,
            .allocator = allocator,
            .tlas_registry = .{}, // Registry starts empty (null)
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

    /// Update BVH state using data from RenderSystem (for modern ECS-based rendering)
    pub fn update(
        self: *RaytracingSystem,
        render_system: *RenderSystem,
        frame_info: *const FrameInfo,
        geo_changed: bool,
    ) !bool {
        const frame_index = frame_info.current_frame;

        // FIRST: Check if TLAS worker has completed and pick up the result
        if (self.bvh_build_in_progress) {
            if (self.bvh_builder.tryPickupCompletedTlas()) |tlas_result| {
                // TLAS build completed successfully!
                // Create heap-allocated TLAS entry for the registry
                const new_entry = try self.allocator.create(TlasRegistry.TlasEntry);
                new_entry.* = .{
                    .acceleration_structure = tlas_result.acceleration_structure,
                    .buffer = tlas_result.buffer,
                    .instance_buffer = tlas_result.instance_buffer,
                    .device_address = tlas_result.device_address,
                    .instance_count = tlas_result.instance_count,
                    .build_time_ns = tlas_result.build_time_ns,
                };

                // Atomically swap: get old TLAS, store new TLAS
                const old_entry = self.tlas_registry.current.swap(new_entry, .acq_rel);

                // Queue old TLAS for destruction (if it existed)
                if (old_entry) |old| {
                    // Queue handle for destruction
                    self.per_frame_destroy[frame_index].tlas_handles.append(self.allocator, old.acceleration_structure) catch |err| {
                        log(.ERROR, "raytracing", "Failed to queue old TLAS handle: {}", .{err});
                        self.gc.vkd.destroyAccelerationStructureKHR(self.gc.dev, old.acceleration_structure, null);
                    };

                    // Queue buffers for destruction
                    self.per_frame_destroy[frame_index].tlas_buffers.append(self.allocator, old.buffer) catch |err| {
                        log(.ERROR, "raytracing", "Failed to queue old TLAS buffer: {}", .{err});
                        var immediate = old.buffer;
                        immediate.deinit();
                    };

                    self.per_frame_destroy[frame_index].tlas_instance_buffers.append(self.allocator, old.instance_buffer) catch |err| {
                        log(.ERROR, "raytracing", "Failed to queue old TLAS instance buffer: {}", .{err});
                        var immediate = old.instance_buffer;
                        immediate.deinit();
                    };

                    // Free the old entry struct itself
                    self.allocator.destroy(old);
                }

                // Mark build as no longer in progress
                self.bvh_build_in_progress = false;
            }
        }

        // Pick up any old BLAS that were replaced in the registry and need deferred destruction
        const old_blas_list = self.bvh_builder.takeOldBlasForDestruction(self.allocator) catch |err| blk: {
            log(.ERROR, "raytracing", "Failed to take old BLAS for destruction: {}", .{err});
            break :blk &[_]BlasResult{};
        };
        defer self.allocator.free(old_blas_list);

        // Queue them for per-frame destruction
        for (old_blas_list) |old_blas| {
            self.per_frame_destroy[frame_index].blas_handles.append(self.allocator, old_blas.acceleration_structure) catch |err| {
                log(.ERROR, "raytracing", "Failed to queue old BLAS handle for destruction: {}", .{err});
                self.gc.vkd.destroyAccelerationStructureKHR(self.gc.dev, old_blas.acceleration_structure, null);
                var immediate = old_blas.buffer;
                immediate.deinit();
                continue;
            };

            self.per_frame_destroy[frame_index].blas_buffers.append(self.allocator, old_blas.buffer) catch |err| {
                log(.ERROR, "raytracing", "Failed to queue old BLAS buffer for destruction: {}", .{err});
                self.gc.vkd.destroyAccelerationStructureKHR(self.gc.dev, old_blas.acceleration_structure, null);
                var immediate = old_blas.buffer;
                immediate.deinit();
                if (self.per_frame_destroy[frame_index].blas_handles.items.len > 0) {
                    self.per_frame_destroy[frame_index].blas_handles.items.len -= 1;
                }
                continue;
            };
        }

        // Check if we need to spawn a TLAS worker for either transform-only or geometry changes
        const is_transform_only = render_system.transform_only_change and render_system.renderables_dirty;
        const rebuild_needed = try render_system.checkBvhRebuildNeeded();

        if ((is_transform_only or rebuild_needed or geo_changed) and !self.bvh_build_in_progress) {
            // Get current raytracing data
            const rt_data = try render_system.getRaytracingData();
            defer {
                self.allocator.free(rt_data.instances);
                self.allocator.free(rt_data.geometries);
                self.allocator.free(rt_data.materials);
            }

            // Mark build as in progress
            self.bvh_build_in_progress = true;

            // Create TlasJob and spawn TLAS worker
            // When it completes, registry will handle the swap automatically
            try self.spawnTlasWorker(rt_data);

            // Clear dirty flags
            render_system.renderables_dirty = false;
            render_system.transform_only_change = false;
            render_system.raytracing_descriptors_dirty = false;

            return true;
        }

        return false; // No rebuild needed or already in progress
    }

    /// Spawn TLAS worker as a ThreadPool job - event-driven approach
    fn spawnTlasWorker(self: *RaytracingSystem, rt_data: RenderData.RaytracingData) !void {
        // Extract stable geometry IDs from rt_data using asset IDs
        const required_geom_ids = try self.allocator.alloc(u32, rt_data.geometries.len);
        for (rt_data.geometries, 0..) |geom, i| {
            required_geom_ids[i] = geom.getGeometryId();
        }

        // Copy geometries for BLAS spawning
        const geometries_copy = try self.allocator.alloc(RenderData.RaytracingData.RTGeometry, rt_data.geometries.len);
        for (rt_data.geometries, 0..) |geom, i| {
            geometries_copy[i] = geom;
        }

        // Copy instances for the job
        const instances_copy = try self.allocator.alloc(InstanceData, rt_data.instances.len);
        for (rt_data.instances, 0..) |inst, i| {
            instances_copy[i] = InstanceData{
                .blas_address = 0, // Will be filled by TLAS worker from buffer
                .transform = inst.transform,
                .custom_index = inst.material_index,
                .mask = inst.mask,
                .sbt_offset = 0,
                .flags = 0,
            };
        }

        // Create atomic BLAS buffer: one slot per geometry
        // BLAS workers will fill their slots atomically
        const blas_buffer = try self.allocator.alloc(std.atomic.Value(?*BlasResult), rt_data.geometries.len);
        for (blas_buffer) |*slot| {
            slot.* = std.atomic.Value(?*BlasResult).init(null);
        }

        // Create TlasJob
        const job = try self.allocator.create(TlasJob);
        job.* = TlasJob{
            .job_id = @atomicRmw(u64, &self.next_tlas_job_id, .Add, 1, .monotonic),
            .blas_buffer = blas_buffer,
            .filled_count = std.atomic.Value(u32).init(0),
            .expected_count = @intCast(rt_data.geometries.len),
            .required_geometry_ids = required_geom_ids,
            .geometries = geometries_copy,
            .instances = instances_copy,
            .allocator = self.allocator,
            .builder = self.bvh_builder,
            .completion_sem = .{},
        };

        // Spawn TLAS worker asynchronously via ThreadPool
        // Create work item for TLAS building
        const work_id = job.job_id;
        const thread_pool = ThreadPoolMod;

        // Use createBvhBuildingWork for TLAS with job as work_data
        const work_item = thread_pool.createBvhBuildingWork(
            work_id,
            .tlas,
            @ptrCast(job),
            .full_rebuild,
            .high, // TLAS builds are high priority
            TlasWorker.tlasWorkerMain,
            @ptrCast(job), // Pass job as context
        );

        // Submit to thread pool
        // Note: Job cleanup will happen when system picks up completed_tlas
        // or in deinit if still pending
        try self.bvh_builder.thread_pool.submitWork(work_item);
    }

    /// Get the current TLAS handle for rendering
    /// Returns null if no TLAS has been built yet
    /// This is safe to call from any thread and stable for the entire frame
    pub fn getTlas(self: *const RaytracingSystem) ?vk.AccelerationStructureKHR {
        if (self.tlas_registry.current.load(.acquire)) |entry| {
            return entry.acceleration_structure;
        }
        return null;
    }

    /// Check if TLAS is valid/available
    pub fn isTlasValid(self: *const RaytracingSystem) bool {
        return self.tlas_registry.current.load(.acquire) != null;
    }

    pub fn deinit(self: *RaytracingSystem) void {
        // Wait for all GPU operations to complete before cleanup
        self.gc.vkd.deviceWaitIdle(self.gc.dev) catch |err| {
            log(.WARN, "raytracing", "Failed to wait for device idle during deinit: {}", .{err});
        };

        // Clean up TLAS registry - destroy the current TLAS if it exists
        if (self.tlas_registry.current.load(.acquire)) |entry| {
            log(.INFO, "raytracing", "Deinit: destroying TLAS from registry {x}", .{@intFromEnum(entry.acceleration_structure)});
            self.gc.vkd.destroyAccelerationStructureKHR(self.gc.dev, entry.acceleration_structure, null);
            var buf = entry.buffer;
            buf.deinit();
            var inst_buf = entry.instance_buffer;
            inst_buf.deinit();
            self.allocator.destroy(entry);
            _ = self.tlas_registry.current.swap(null, .release);
        }

        // Flush all per-frame destruction queues (old resources queued for deferred destruction)
        log(.INFO, "raytracing", "Deinit: flushing per-frame destruction queues", .{});
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

        // Destroy shader binding table buffer and free its memory
        if (self.shader_binding_table != .null_handle) self.gc.vkd.destroyBuffer(self.gc.dev, self.shader_binding_table, null);
        if (self.shader_binding_table_memory != .null_handle) self.gc.vkd.freeMemory(self.gc.dev, self.shader_binding_table_memory, null);
    }

    /// Flush a destruction queue, destroying all queued resources
    /// Called after GPU has finished using resources for a particular frame
    fn flushDestroyQueue(self: *RaytracingSystem, queue: *PerFrameDestroyQueue) void {
        // Destroy BLAS acceleration structures and their backing buffers
        for (queue.blas_handles.items) |handle| {
            self.gc.vkd.destroyAccelerationStructureKHR(self.gc.dev, handle, null);
        }
        queue.blas_handles.clearRetainingCapacity();

        for (queue.blas_buffers.items) |*buf| {
            buf.deinit();
        }
        queue.blas_buffers.clearRetainingCapacity();

        // Destroy TLAS acceleration structures and their backing buffers
        for (queue.tlas_handles.items) |handle| {
            self.gc.vkd.destroyAccelerationStructureKHR(self.gc.dev, handle, null);
        }
        queue.tlas_handles.clearRetainingCapacity();

        for (queue.tlas_buffers.items) |*buf| {
            buf.deinit();
        }
        queue.tlas_buffers.clearRetainingCapacity();

        for (queue.tlas_instance_buffers.items) |*buf| {
            buf.deinit();
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
        log(.INFO, "raytracing", "Flushing ALL pending destruction queues", .{});
        for (&self.per_frame_destroy, 0..) |*queue, i| {
            const blas_count = queue.blas_handles.items.len;
            const tlas_count = queue.tlas_handles.items.len;
            if (blas_count > 0 or tlas_count > 0) {
                log(.INFO, "raytracing", "  Frame {}: {} BLAS, {} TLAS", .{ i, blas_count, tlas_count });
            }
            self.flushDestroyQueue(queue);
        }
    }
};
