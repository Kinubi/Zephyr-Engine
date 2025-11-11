const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("../../core/graphics_context.zig").GraphicsContext;
const Buffer = @import("../../core/buffer.zig").Buffer;
const Vertex = @import("../../rendering/mesh.zig").Vertex;
const Model = @import("../../rendering/mesh.zig").Model;
const ThreadPool = @import("../../threading/thread_pool.zig").ThreadPool;
const WorkItem = @import("../../threading/thread_pool.zig").WorkItem;
const WorkPriority = @import("../../threading/thread_pool.zig").WorkPriority;
const createBvhBuildingWork = @import("../../threading/thread_pool.zig").createBvhBuildingWork;
const log = @import("../../utils/log.zig").log;
const Math = @import("../../utils/math.zig");
const Mesh = @import("../../rendering/mesh.zig").Mesh;
const RaytracingData = @import("../../rendering/render_data_types.zig").RaytracingData;
const tlas_worker = @import("tlas_worker.zig");
const TlasJob = @import("tlas_worker.zig").TlasJob;

/// BVH acceleration structure types
pub const AccelerationStructureType = enum {
    bottom_level, // BLAS - for individual mesh geometry
    top_level, // TLAS - for scene instances
};

/// Individual geometry data for BVH building
pub const GeometryData = struct {
    mesh_ptr: *Mesh,
    material_id: u32,
    transform: Math.Mat4,
    mesh_id: u32,
};

/// BLAS building result
pub const BlasResult = struct {
    acceleration_structure: vk.AccelerationStructureKHR,
    buffer: Buffer,
    device_address: vk.DeviceAddress,
    geometry_id: u32,
    mesh_ptr: ?*const anyopaque, // For verifying correct BLAS (same geometry_id can have different meshes)
    build_time_ns: u64,
};

/// TLAS instance data
pub const InstanceData = struct {
    blas_address: vk.DeviceAddress,
    transform: [3][4]f32, // 3x4 transform matrix
    custom_index: u32, // Material ID or object ID
    mask: u8,
    sbt_offset: u32,
    flags: u32,
};

/// TLAS building result
pub const TlasResult = struct {
    acceleration_structure: vk.AccelerationStructureKHR,
    buffer: Buffer,
    instance_buffer: Buffer,
    device_address: vk.DeviceAddress,
    instance_count: u32,
    build_time_ns: u64,
};

/// BVH building work item data
pub const BvhWorkData = struct {
    work_type: BvhWorkType,
    geometry_data: ?*GeometryData,
    instance_data: ?[]const InstanceData,
    completion_callback: ?*const fn (*anyopaque, BvhBuildResult) void,
    callback_context: ?*anyopaque,
    work_id: u64,

    // Optional TlasJob for per-job BLAS tracking
    // If set, BLAS completion will fill the slot at geometry_index
    tlas_job: ?*TlasJob = null,
    geometry_index: u32 = 0, // Which slot in the job's blas_buffer to fill
};

pub const BvhWorkType = enum {
    build_blas,
    build_tlas,
    update_tlas,
};

pub const BvhBuildResult = union(BvhWorkType) {
    build_blas: BlasResult,
    build_tlas: TlasResult,
    update_tlas: TlasResult,
};

/// Node for lock-free linked list of old BLAS waiting for destruction
const BlasDestructionNode = struct {
    blas: BlasResult,
    next: ?*BlasDestructionNode,
};

/// Thread-safe BVH builder with async capabilities
pub const MultithreadedBvhBuilder = struct {
    gc: *GraphicsContext,
    thread_pool: *ThreadPool,
    allocator: std.mem.Allocator,

    // Lock-free collections for results
    completed_tlas: std.atomic.Value(?*TlasResult),
    old_blas_head: std.atomic.Value(?*BlasDestructionNode), // Lock-free linked list head

    // TODO(FEATURE): REMOVE GLOBAL BLAS REGISTRY - HIGH PRIORITY
    // This global registry causes problems:
    // 1. BLAS rebuilt when mesh_ptr changes (even if geometry identical)
    // 2. No ownership semantics (who destroys the BLAS?)
    // 3. Difficult to implement reference counting for shared meshes
    //
    // Solution: Move BLAS ownership to Mesh/Geometry structures
    // - Mesh owns its BLAS (built once on load, destroyed with mesh)
    // - Registry becomes lookup table: geometry_id -> Mesh (which contains BLAS)
    // - Reference counting for shared meshes across multiple entities
    //
    // Required changes:
    // 1. Add BLAS field to Mesh/Geometry (see geometry.zig TODO)
    // 2. Build BLAS during mesh load (asset_loader.zig)
    // 3. Replace lookupBlas() with mesh.getBlas()
    // 4. Remove registerBlas(), updateBlas() methods
    // 5. BLAS destroyed when mesh ref-count reaches 0
    //
    // Complexity: HIGH - requires asset loading + raytracing system refactor
    // Branch: features/blas-ownership (coordinate with geometry.zig changes)
    //
    // Lock-free BLAS registry: array indexed by geometry_id with atomic pointers
    // Each slot holds an atomic pointer to a heap-allocated BlasResult
    // null = BLAS not built yet, non-null = BLAS available
    blas_registry: []std.atomic.Value(?*BlasResult),
    max_geometry_id: u32,

    // Persistent geometry data for async work (using pointers to avoid copies)
    persistent_geometry: std.ArrayList(GeometryData),
    geometry_mutex: std.Thread.Mutex,

    // Work tracking
    next_work_id: std.atomic.Value(u64),
    pending_work: std.atomic.Value(u32),

    // Performance metrics
    total_blas_built: std.atomic.Value(u32),
    total_build_time_ns: std.atomic.Value(u64),

    pub fn init(gc: *GraphicsContext, thread_pool: *ThreadPool, allocator: std.mem.Allocator) !MultithreadedBvhBuilder {
        // Register BVH building subsystem with thread pool
        try thread_pool.registerSubsystem(.{
            .name = "bvh_building",
            .min_workers = 1,
            .max_workers = 4,
            .priority = .critical,
            .work_item_type = .bvh_building,
        });
        log(.INFO, "bvh_builder", "Registered bvh_building subsystem with thread pool", .{});

        // Allocate lock-free BLAS registry
        // Start with 256 geometry slots (can grow if needed)
        const max_geom = 256;
        const registry = try allocator.alloc(std.atomic.Value(?*BlasResult), max_geom);
        for (registry) |*slot| {
            slot.* = std.atomic.Value(?*BlasResult).init(null);
        }

        return MultithreadedBvhBuilder{
            .gc = gc,
            .thread_pool = thread_pool,
            .allocator = allocator,
            .completed_tlas = std.atomic.Value(?*TlasResult).init(null),
            .old_blas_head = std.atomic.Value(?*BlasDestructionNode).init(null),
            .blas_registry = registry,
            .max_geometry_id = max_geom,
            .persistent_geometry = std.ArrayList(GeometryData){},
            .geometry_mutex = .{},
            .next_work_id = std.atomic.Value(u64).init(1),
            .pending_work = std.atomic.Value(u32).init(0),
            .total_blas_built = std.atomic.Value(u32).init(0),
            .total_build_time_ns = std.atomic.Value(u64).init(0),
        };
    }

    pub fn deinit(self: *MultithreadedBvhBuilder) void {
        // Clean up old BLAS waiting for destruction (lock-free linked list)
        var count: usize = 0;
        var current = self.old_blas_head.swap(null, .acquire);
        while (current) |node| {
            count += 1;
            var blas_result = node.blas;
            blas_result.buffer.deinit();
            self.gc.vkd.destroyAccelerationStructureKHR(self.gc.dev, blas_result.acceleration_structure, null);
            const next = node.next;
            self.allocator.destroy(node);
            current = next;
        }
        if (count > 0) {
            log(.WARN, "bvh_builder", "Deinit: cleaned up {} old BLAS waiting for destruction", .{count});
        }

        // Clean up lock-free BLAS registry
        // No lock needed - called during shutdown when no workers are active
        var registry_count: u32 = 0;
        for (self.blas_registry) |*slot| {
            if (slot.load(.acquire)) |blas_ptr| {
                registry_count += 1;
                blas_ptr.buffer.deinit();
                self.gc.vkd.destroyAccelerationStructureKHR(self.gc.dev, blas_ptr.acceleration_structure, null);
                self.allocator.destroy(blas_ptr);
            }
        }
        if (registry_count > 0) {
            log(.INFO, "bvh_builder", "Deinit: cleaned up {} BLAS from registry", .{registry_count});
        }
        self.allocator.free(self.blas_registry);

        // Clean up persistent geometry data
        self.geometry_mutex.lock();
        defer self.geometry_mutex.unlock();
        self.persistent_geometry.deinit(self.allocator);

        // Clean up TLAS if it exists (atomically take ownership)
        if (self.completed_tlas.swap(null, .acquire)) |tlas_ptr| {
            log(.WARN, "bvh_builder", "Deinit: unconsumed TLAS result - cleaning up", .{});
            tlas_ptr.buffer.deinit();
            tlas_ptr.instance_buffer.deinit();
            self.gc.vkd.destroyAccelerationStructureKHR(self.gc.dev, tlas_ptr.acceleration_structure, null);
            self.allocator.destroy(tlas_ptr);
        }
    }

    /// Check if all pending work is complete
    pub fn isWorkComplete(self: *const MultithreadedBvhBuilder) bool {
        return self.pending_work.load(.monotonic) == 0;
    }

    /// Take old BLAS that need deferred destruction (lock-free)
    /// Only returns BLAS that are no longer referenced in the registry
    pub fn takeOldBlasForDestruction(self: *MultithreadedBvhBuilder, allocator: std.mem.Allocator) ![]BlasResult {
        // Atomically take the entire linked list
        const head = self.old_blas_head.swap(null, .acquire);
        if (head == null) {
            return &[_]BlasResult{};
        }

        // First pass: collect all BLAS, filtering out those still in use
        var temp_results = std.ArrayList(BlasResult){};

        var current = head;
        while (current) |node| {
            const old_blas = node.blas;

            // Check if this BLAS handle is still referenced in the registry
            var still_in_use = false;
            for (self.blas_registry) |*slot| {
                if (slot.load(.acquire)) |blas_ptr| {
                    if (blas_ptr.acceleration_structure == old_blas.acceleration_structure) {
                        still_in_use = true;
                        break;
                    }
                }
            }

            if (!still_in_use) {
                // Safe to destroy - not referenced anywhere
                try temp_results.append(allocator, old_blas);
            } else {
                // Still in use - acceleration structure is shared, but buffer might not be
                // The old BlasResult has a buffer that was replaced, but the acceleration_structure is reused
                // We can't destroy the acceleration structure (still in use), but we CAN free the old buffer
                // if it's different from the one being used
                log(.DEBUG, "bvh_builder", "BLAS handle {d} still in use by registry, not queuing acceleration structure for destruction", .{@intFromEnum(old_blas.acceleration_structure)});

                // Check if this buffer is still being used (compare buffer handle)
                var buffer_still_in_use = false;
                for (self.blas_registry) |*slot| {
                    if (slot.load(.acquire)) |blas_ptr| {
                        if (blas_ptr.buffer.buffer == old_blas.buffer.buffer) {
                            buffer_still_in_use = true;
                            break;
                        }
                    }
                }

                if (!buffer_still_in_use) {
                    // Buffer is no longer used, free it
                    var buffer_to_free = old_blas.buffer;
                    buffer_to_free.deinit();
                    for (self.blas_registry) |*slot| {
                        if (slot.load(.acquire)) |blas_ptr| {
                            if (blas_ptr.buffer.buffer == buffer_to_free.buffer) {
                                slot.store(null, .release);
                            }
                        }
                    }
                }
            }

            const next = node.next;
            self.allocator.destroy(node);
            current = next;
        }

        // Convert to owned slice
        return temp_results.toOwnedSlice(allocator);
    }

    /// Try to pick up completed TLAS if available (lock-free) and take ownership
    pub fn tryPickupCompletedTlas(self: *MultithreadedBvhBuilder) ?TlasResult {
        if (self.completed_tlas.swap(null, .acquire)) |tlas_ptr| {
            const result = tlas_ptr.*;
            self.allocator.destroy(tlas_ptr);
            return result;
        }
        return null;
    }

    /// Take TLAS result if available (lock-free) and take ownership
    pub fn takeCompletedTlas(self: *MultithreadedBvhBuilder) ?TlasResult {
        return self.tryPickupCompletedTlas();
    }

    /// Get performance metrics
    pub fn getPerformanceMetrics(self: *const MultithreadedBvhBuilder) struct {
        total_blas_built: u32,
        total_build_time_ns: u64,
        average_build_time_ns: u64,
        pending_work: u32,
    } {
        const total_built = self.total_blas_built.load(.monotonic);
        const total_time = self.total_build_time_ns.load(.monotonic);

        return .{
            .total_blas_built = total_built,
            .total_build_time_ns = total_time,
            .average_build_time_ns = if (total_built > 0) total_time / total_built else 0,
            .pending_work = self.pending_work.load(.monotonic),
        };
    }

    /// Register a BLAS in the lock-free registry
    /// Returns the old BlasResult if one was replaced (should be queued for deferred destruction by caller)
    /// The old BLAS resources are still in use by GPU, so caller must defer destruction until safe
    pub fn registerBlas(self: *MultithreadedBvhBuilder, blas: BlasResult) !?BlasResult {
        if (blas.geometry_id >= self.max_geometry_id) {
            log(.ERROR, "bvh_builder", "Geometry ID {} exceeds max registry size {}", .{ blas.geometry_id, self.max_geometry_id });
            return error.GeometryIdOutOfBounds;
        }

        // Allocate heap copy of the BLAS result
        const blas_ptr = try self.allocator.create(BlasResult);
        blas_ptr.* = blas;

        // Atomically install it in the registry slot
        const slot = &self.blas_registry[blas.geometry_id];
        const old_ptr = slot.swap(blas_ptr, .acq_rel);

        // Return the old BLAS if there was one - caller is responsible for deferred destruction
        if (old_ptr) |old_blas| {
            const old_result = old_blas.*;
            self.allocator.destroy(old_blas); // Free the heap allocation, but return the contents
            return old_result;
        }

        return null;
    }

    /// Lock-free BLAS lookup by geometry_id
    /// Returns a pointer to the BlasResult in the registry if found AND mesh_ptr matches, null otherwise
    /// WARNING: The returned pointer remains valid until the BLAS is replaced in the registry
    pub fn lookupBlasPtr(self: *MultithreadedBvhBuilder, geometry_id: u32, mesh_ptr: ?*const anyopaque) ?*BlasResult {
        if (geometry_id >= self.max_geometry_id) {
            return null;
        }

        const slot = &self.blas_registry[geometry_id];
        const result_ptr = slot.load(.acquire);
        if (result_ptr) |ptr| {
            // Validate that the mesh_ptr matches
            if (ptr.mesh_ptr == mesh_ptr) {
                return ptr;
            }
        }
        return null;
    }

    /// Lock-free BLAS lookup by geometry_id with mesh_ptr validation
    /// Returns a copy of the BlasResult if found AND mesh_ptr matches, null otherwise
    pub fn lookupBlas(self: *MultithreadedBvhBuilder, geometry_id: u32, mesh_ptr: ?*const anyopaque) ?BlasResult {
        if (geometry_id >= self.max_geometry_id) {
            return null;
        }

        const slot = &self.blas_registry[geometry_id];
        if (slot.load(.acquire)) |blas_ptr| {
            // Validate that the mesh_ptr matches
            if (blas_ptr.mesh_ptr == mesh_ptr) {
                return blas_ptr.*; // Return a copy
            }
        }
        return null;
    }
};

/// BLAS worker function - can be called directly from TLAS worker
pub fn blasWorkerFn(context: *anyopaque, work_item: WorkItem) void {
    const builder = @as(*MultithreadedBvhBuilder, @ptrCast(@alignCast(context)));
    const start_time = std.time.nanoTimestamp();

    const work_data = @as(*BvhWorkData, @ptrCast(@alignCast(work_item.data.bvh_building.work_data)));
    defer {
        // Clean up heap-allocated work data
        if (work_data.geometry_data) |geom_data| {
            builder.allocator.destroy(geom_data);
        }
        builder.allocator.destroy(work_data);
    }

    const result = buildBlasSynchronous(builder, work_data.geometry_data.?) catch |err| {
        log(.ERROR, "bvh_builder", "BLAS build failed: {}", .{err});
        _ = builder.pending_work.fetchSub(1, .monotonic);
        return;
    };

    const build_time = @as(u64, @intCast(std.time.nanoTimestamp() - start_time));
    var final_result = result;
    final_result.build_time_ns = build_time;

    // Update metrics
    _ = builder.total_blas_built.fetchAdd(1, .monotonic);
    _ = builder.total_build_time_ns.fetchAdd(build_time, .monotonic);
    _ = builder.pending_work.fetchSub(1, .monotonic);

    // ALWAYS register BLAS in the lock-free registry for future lookups
    // If an old BLAS is replaced, queue it for deferred destruction (still in use by GPU)
    const old_blas_opt = builder.registerBlas(final_result) catch |err| {
        log(.ERROR, "bvh_builder", "Failed to register BLAS in registry: {}", .{err});
        return;
    };

    if (old_blas_opt) |old_blas| {
        // Old BLAS was replaced - queue for deferred destruction using lock-free list
        // Can't destroy immediately because:
        // 1. GPU commands may still be using it (secondary command buffers not yet executed)
        // 2. Old TLAS may still reference it
        // 3. Other geometries may still be using the same BLAS handle (shared)
        // The takeOldBlasForDestruction() will filter out BLAS still in use before returning them
        const node = builder.allocator.create(BlasDestructionNode) catch |err| {
            log(.ERROR, "bvh_builder", "Failed to allocate destruction node: {}", .{err});
            // Last resort: destroy immediately (may cause validation errors)
            var old_buffer = old_blas.buffer;
            old_buffer.deinit();
            builder.gc.vkd.destroyAccelerationStructureKHR(builder.gc.dev, old_blas.acceleration_structure, null);
            return;
        };
        node.blas = old_blas;

        // Lock-free push to head of linked list
        var current_head = builder.old_blas_head.load(.acquire);
        while (true) {
            node.next = current_head;
            if (builder.old_blas_head.cmpxchgWeak(current_head, node, .release, .acquire)) |new_head| {
                current_head = new_head;
            } else {
                break;
            }
        }
    }

    // If this BLAS is part of a TLAS job, fill the slot in the job's buffer
    if (work_data.tlas_job) |job| {

        // Allocate BlasResult on heap for the job's buffer
        const blas_ptr = builder.allocator.create(BlasResult) catch |err| {
            log(.ERROR, "bvh_builder", "Failed to allocate BlasResult: {}", .{err});
            // Still continue - BLAS is registered, just can't notify job
            return;
        };
        blas_ptr.* = final_result;

        // Fill the appropriate slot in the job's atomic buffer
        tlas_worker.fillBlasSlot(job, work_data.geometry_index, blas_ptr);

        return; // Don't call callback or store in completed_blas
    }
}

/// Synchronous BLAS building function
fn buildBlasSynchronous(builder: *MultithreadedBvhBuilder, geometry: *const GeometryData) !BlasResult {
    const mesh = geometry.mesh_ptr;
    const vertex_count = mesh.vertices.items.len;
    const index_count = mesh.indices.items.len;
    const primitive_count = index_count / 3;

    if (primitive_count == 0) {
        return error.EmptyGeometry;
    }

    // Get device addresses
    var vertex_address_info = vk.BufferDeviceAddressInfo{
        .s_type = vk.StructureType.buffer_device_address_info,
        .buffer = mesh.vertex_buffer.?.buffer,
    };
    var index_address_info = vk.BufferDeviceAddressInfo{
        .s_type = vk.StructureType.buffer_device_address_info,
        .buffer = mesh.index_buffer.?.buffer,
    };

    const vertex_device_address = builder.gc.vkd.getBufferDeviceAddress(builder.gc.dev, &vertex_address_info);
    const index_device_address = builder.gc.vkd.getBufferDeviceAddress(builder.gc.dev, &index_address_info);

    // Create geometry description
    var geometry_vk = vk.AccelerationStructureGeometryKHR{
        .s_type = vk.StructureType.acceleration_structure_geometry_khr,
        .geometry_type = vk.GeometryTypeKHR.triangles_khr,
        .geometry = .{
            .triangles = vk.AccelerationStructureGeometryTrianglesDataKHR{
                .s_type = vk.StructureType.acceleration_structure_geometry_triangles_data_khr,
                .vertex_format = vk.Format.r32g32b32_sfloat,
                .vertex_data = .{ .device_address = vertex_device_address },
                .vertex_stride = @sizeOf(Vertex),
                .max_vertex = @intCast(vertex_count),
                .index_type = vk.IndexType.uint32,
                .index_data = .{ .device_address = index_device_address },
                .transform_data = .{ .device_address = 0 },
            },
        },
        .flags = vk.GeometryFlagsKHR{ .opaque_bit_khr = true },
    };

    // Create build info
    var range_info = vk.AccelerationStructureBuildRangeInfoKHR{
        .primitive_count = @intCast(primitive_count),
        .primitive_offset = 0,
        .first_vertex = 0,
        .transform_offset = 0,
    };

    var build_info = vk.AccelerationStructureBuildGeometryInfoKHR{
        .s_type = vk.StructureType.acceleration_structure_build_geometry_info_khr,
        .type = vk.AccelerationStructureTypeKHR.bottom_level_khr,
        // prefer_fast_trace: We trace more often than we rebuild, optimize for traversal performance
        .flags = vk.BuildAccelerationStructureFlagsKHR{ .prefer_fast_trace_bit_khr = true },
        .mode = vk.BuildAccelerationStructureModeKHR.build_khr,
        .geometry_count = 1,
        .p_geometries = @ptrCast(&geometry_vk),
        .scratch_data = .{ .device_address = 0 },
    };

    // Get build sizes
    var size_info = vk.AccelerationStructureBuildSizesInfoKHR{
        .s_type = vk.StructureType.acceleration_structure_build_sizes_info_khr,
        .build_scratch_size = 0,
        .acceleration_structure_size = 0,
        .update_scratch_size = 0,
    };

    var primitive_count_u32: u32 = @intCast(primitive_count);
    builder.gc.vkd.getAccelerationStructureBuildSizesKHR(builder.gc.dev, vk.AccelerationStructureBuildTypeKHR.device_khr, &build_info, @ptrCast(&primitive_count_u32), &size_info);

    // Create BLAS buffer
    const blas_buffer = try Buffer.init(
        builder.gc,
        size_info.acceleration_structure_size,
        1,
        .{ .acceleration_structure_storage_bit_khr = true, .shader_device_address_bit = true },
        .{ .device_local_bit = true },
    );

    // Create acceleration structure
    var as_create_info = vk.AccelerationStructureCreateInfoKHR{
        .s_type = vk.StructureType.acceleration_structure_create_info_khr,
        .buffer = blas_buffer.buffer,
        .size = size_info.acceleration_structure_size,
        .type = vk.AccelerationStructureTypeKHR.bottom_level_khr,
        .device_address = 0,
        .offset = 0,
    };

    const blas = try builder.gc.vkd.createAccelerationStructureKHR(builder.gc.dev, &as_create_info, null);

    // Track BLAS memory allocation with unique handle-based name
    if (builder.gc.memory_tracker) |tracker| {
        var name_buf: [64]u8 = undefined;
        const blas_name = std.fmt.bufPrint(&name_buf, "blas_{d}", .{@intFromEnum(blas)}) catch "blas_unknown";
        tracker.trackAllocation(blas_name, size_info.acceleration_structure_size, .blas) catch |err| {
            log(.WARN, "bvh_builder", "Failed to track BLAS allocation: {}", .{err});
        };
    }

    // Create scratch buffer
    const scratch_buffer = try Buffer.init(
        builder.gc,
        size_info.build_scratch_size,
        1,
        .{ .storage_buffer_bit = true, .shader_device_address_bit = true },
        .{ .device_local_bit = true },
    );

    // Get scratch buffer device address
    var scratch_address_info = vk.BufferDeviceAddressInfo{
        .s_type = vk.StructureType.buffer_device_address_info,
        .buffer = scratch_buffer.buffer,
    };
    const scratch_device_address = builder.gc.vkd.getBufferDeviceAddress(builder.gc.dev, &scratch_address_info);

    // Update build info with addresses
    build_info.scratch_data.device_address = scratch_device_address;
    build_info.dst_acceleration_structure = blas;

    // Use secondary command buffer approach for worker threads
    var secondary_cmd = try builder.gc.beginWorkerCommandBuffer();
    const p_range_info = &range_info;
    builder.gc.vkd.cmdBuildAccelerationStructuresKHR(secondary_cmd.command_buffer, 1, @ptrCast(&build_info), @ptrCast(&p_range_info));

    // Add scratch buffer to pending resources for cleanup after command execution
    try secondary_cmd.addPendingResource(scratch_buffer.buffer, scratch_buffer.memory);
    try builder.gc.endWorkerCommandBuffer(&secondary_cmd);

    // Get BLAS device address
    var blas_address_info = vk.AccelerationStructureDeviceAddressInfoKHR{
        .s_type = vk.StructureType.acceleration_structure_device_address_info_khr,
        .acceleration_structure = blas,
    };
    const blas_device_address = builder.gc.vkd.getAccelerationStructureDeviceAddressKHR(builder.gc.dev, &blas_address_info);

    return BlasResult{
        .acceleration_structure = blas,
        .buffer = blas_buffer,
        .device_address = blas_device_address,
        .geometry_id = geometry.mesh_id,
        .mesh_ptr = geometry.mesh_ptr,
        .build_time_ns = 0, // Will be set by caller
    };
}

/// Synchronous TLAS building function
pub fn buildTlasSynchronous(builder: *MultithreadedBvhBuilder, instances: []const InstanceData) !TlasResult {
    if (instances.len == 0) {
        return error.NoInstances;
    }

    // Convert to Vulkan instance format
    var vk_instances = try builder.allocator.alloc(vk.AccelerationStructureInstanceKHR, instances.len);
    defer builder.allocator.free(vk_instances);
    for (instances, 0..) |inst_data, i| {
        vk_instances[i] = vk.AccelerationStructureInstanceKHR{
            .transform = .{ .matrix = inst_data.transform },
            .instance_custom_index_and_mask = .{
                .instance_custom_index = @intCast(inst_data.custom_index),
                .mask = inst_data.mask,
            },
            .instance_shader_binding_table_record_offset_and_flags = .{
                .instance_shader_binding_table_record_offset = @intCast(inst_data.sbt_offset),
                .flags = @intCast(inst_data.flags),
            },
            .acceleration_structure_reference = inst_data.blas_address,
        };
    }

    const instance_buffer_size = @sizeOf(vk.AccelerationStructureInstanceKHR) * instances.len;

    // Create instance buffer
    var instance_buffer = try Buffer.init(
        builder.gc,
        instance_buffer_size,
        1,
        .{
            .shader_device_address_bit = true,
            .transfer_dst_bit = true,
            .acceleration_structure_build_input_read_only_bit_khr = true,
        },
        .{ .host_visible_bit = true, .host_coherent_bit = true },
    );

    try instance_buffer.map(instance_buffer_size, 0);
    instance_buffer.writeToBuffer(std.mem.sliceAsBytes(vk_instances), instance_buffer_size, 0);

    // Get instance buffer device address
    var instance_addr_info = vk.BufferDeviceAddressInfo{
        .s_type = vk.StructureType.buffer_device_address_info,
        .buffer = instance_buffer.buffer,
    };
    const instance_device_address = builder.gc.vkd.getBufferDeviceAddress(builder.gc.dev, &instance_addr_info);

    // Create TLAS geometry
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

    // Create TLAS build info
    var tlas_range_info = vk.AccelerationStructureBuildRangeInfoKHR{
        .primitive_count = @intCast(instances.len),
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
        .scratch_data = .{ .device_address = 0 },
    };

    // Get build sizes
    var tlas_size_info = vk.AccelerationStructureBuildSizesInfoKHR{
        .s_type = vk.StructureType.acceleration_structure_build_sizes_info_khr,
        .build_scratch_size = 0,
        .acceleration_structure_size = 0,
        .update_scratch_size = 0,
    };

    var tlas_primitive_count: u32 = @intCast(instances.len);
    builder.gc.vkd.getAccelerationStructureBuildSizesKHR(builder.gc.dev, vk.AccelerationStructureBuildTypeKHR.device_khr, &tlas_build_info, @ptrCast(&tlas_primitive_count), &tlas_size_info);

    // Create TLAS buffer
    const tlas_buffer = try Buffer.init(
        builder.gc,
        tlas_size_info.acceleration_structure_size,
        1,
        .{ .acceleration_structure_storage_bit_khr = true, .shader_device_address_bit = true },
        .{ .device_local_bit = true },
    );

    // Create TLAS acceleration structure
    var tlas_create_info = vk.AccelerationStructureCreateInfoKHR{
        .s_type = vk.StructureType.acceleration_structure_create_info_khr,
        .buffer = tlas_buffer.buffer,
        .size = tlas_size_info.acceleration_structure_size,
        .type = vk.AccelerationStructureTypeKHR.top_level_khr,
        .device_address = 0,
        .offset = 0,
    };

    const tlas = try builder.gc.vkd.createAccelerationStructureKHR(builder.gc.dev, &tlas_create_info, null);

    // Track TLAS memory allocation with unique handle-based name
    if (builder.gc.memory_tracker) |tracker| {
        var name_buf: [64]u8 = undefined;
        const tlas_name = std.fmt.bufPrint(&name_buf, "tlas_{d}", .{@intFromEnum(tlas)}) catch "tlas_unknown";
        tracker.trackAllocation(tlas_name, tlas_size_info.acceleration_structure_size, .tlas) catch |err| {
            log(.WARN, "bvh_builder", "Failed to track TLAS allocation: {}", .{err});
        };
    }

    // Create scratch buffer
    const tlas_scratch_buffer = try Buffer.init(
        builder.gc,
        tlas_size_info.build_scratch_size,
        1,
        .{ .storage_buffer_bit = true, .shader_device_address_bit = true },
        .{ .device_local_bit = true },
    );

    // Get scratch buffer device address
    var scratch_address_info = vk.BufferDeviceAddressInfo{
        .s_type = vk.StructureType.buffer_device_address_info,
        .buffer = tlas_scratch_buffer.buffer,
    };
    const scratch_device_address = builder.gc.vkd.getBufferDeviceAddress(builder.gc.dev, &scratch_address_info);

    // Update build info
    tlas_build_info.scratch_data.device_address = scratch_device_address;
    tlas_build_info.dst_acceleration_structure = tlas;

    // Use secondary command buffer approach for worker threads
    var secondary_cmd = try builder.gc.beginWorkerCommandBuffer();
    const p_tlas_range_info = &tlas_range_info;
    builder.gc.vkd.cmdBuildAccelerationStructuresKHR(secondary_cmd.command_buffer, 1, @ptrCast(&tlas_build_info), @ptrCast(&p_tlas_range_info));

    // Add scratch buffer to pending resources for cleanup after command execution
    try secondary_cmd.addPendingResource(tlas_scratch_buffer.buffer, tlas_scratch_buffer.memory);
    try builder.gc.endWorkerCommandBuffer(&secondary_cmd);

    // Get TLAS device address
    var tlas_address_info = vk.AccelerationStructureDeviceAddressInfoKHR{
        .s_type = vk.StructureType.acceleration_structure_device_address_info_khr,
        .acceleration_structure = tlas,
    };
    const tlas_device_address = builder.gc.vkd.getAccelerationStructureDeviceAddressKHR(builder.gc.dev, &tlas_address_info);

    return TlasResult{
        .acceleration_structure = tlas,
        .buffer = tlas_buffer,
        .instance_buffer = instance_buffer,
        .device_address = tlas_device_address,
        .instance_count = @intCast(instances.len),
        .build_time_ns = 0, // Will be set by caller
    };
}
