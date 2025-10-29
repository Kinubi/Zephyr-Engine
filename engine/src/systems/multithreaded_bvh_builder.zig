const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("../core/graphics_context.zig").GraphicsContext;
const Buffer = @import("../core/buffer.zig").Buffer;
const Vertex = @import("../rendering/mesh.zig").Vertex;
const Model = @import("../rendering/mesh.zig").Model;
const ThreadPool = @import("../threading/thread_pool.zig").ThreadPool;
const WorkItem = @import("../threading/thread_pool.zig").WorkItem;
const WorkPriority = @import("../threading/thread_pool.zig").WorkPriority;
const createBvhBuildingWork = @import("../threading/thread_pool.zig").createBvhBuildingWork;
const log = @import("../utils/log.zig").log;
const Math = @import("../utils/math.zig");
const Mesh = @import("../rendering/mesh.zig").Mesh;

const RaytracingData = @import("../rendering/render_data_types.zig").RaytracingData;

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

/// Wrapper for storing both callback function and context
const CallbackWrapper = struct {
    callback_fn: *const fn (*anyopaque, []const BlasResult, ?TlasResult) void,
    callback_context: *anyopaque,
};

/// BVH building work item data
pub const BvhWorkData = struct {
    work_type: BvhWorkType,
    geometry_data: ?*GeometryData,
    instance_data: ?[]const InstanceData,
    completion_callback: ?*const fn (*anyopaque, BvhBuildResult) void,
    callback_context: ?*anyopaque,
    work_id: u64,
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

/// Thread-safe BVH builder with async capabilities
pub const MultithreadedBvhBuilder = struct {
    gc: *GraphicsContext,
    thread_pool: *ThreadPool,
    allocator: std.mem.Allocator,

    // Thread-safe collections for results
    completed_blas: std.ArrayList(BlasResult),
    completed_tlas: ?TlasResult,
    blas_mutex: std.Thread.Mutex,
    tlas_mutex: std.Thread.Mutex,
    queue_mutex: std.Thread.Mutex,

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

        var completed_blas = std.ArrayList(BlasResult){};
        try completed_blas.ensureTotalCapacity(allocator, 8);

        return MultithreadedBvhBuilder{
            .gc = gc,
            .thread_pool = thread_pool,
            .allocator = allocator,
            .completed_blas = completed_blas,
            .completed_tlas = null,
            .blas_mutex = .{},
            .tlas_mutex = .{},
            .queue_mutex = .{},
            .persistent_geometry = std.ArrayList(GeometryData){},
            .geometry_mutex = .{},
            .next_work_id = std.atomic.Value(u64).init(1),
            .pending_work = std.atomic.Value(u32).init(0),
            .total_blas_built = std.atomic.Value(u32).init(0),
            .total_build_time_ns = std.atomic.Value(u64).init(0),
        };
    }

    pub fn deinit(self: *MultithreadedBvhBuilder) void {
        // Clean up all BLAS results
        self.blas_mutex.lock();
        defer self.blas_mutex.unlock();

        // NOTE: If there are unconsumed BLAS results, it means the caller (RaytracingSystem)
        // never called takeCompletedBlas(). This can happen if path tracing is never enabled.
        // We need to clean up these buffers/AS properly to avoid memory leaks.
        if (self.completed_blas.items.len > 0) {
            log(.WARN, "bvh_builder", "Deinit: {} unconsumed BLAS results - cleaning up", .{self.completed_blas.items.len});
            for (self.completed_blas.items) |*blas_result| {
                blas_result.buffer.deinit();
                self.gc.vkd.destroyAccelerationStructureKHR(self.gc.dev, blas_result.acceleration_structure, null);
            }
        }
        self.completed_blas.deinit(self.allocator);

        // Clean up persistent geometry data
        self.geometry_mutex.lock();
        defer self.geometry_mutex.unlock();
        self.persistent_geometry.deinit(self.allocator);

        // Clean up TLAS if it exists
        // NOTE: Same as BLAS - if unconsumed, we need to clean it up
        if (self.completed_tlas) |*tlas_result| {
            log(.WARN, "bvh_builder", "Deinit: unconsumed TLAS result - cleaning up", .{});
            tlas_result.buffer.deinit();
            tlas_result.instance_buffer.deinit();
            self.gc.vkd.destroyAccelerationStructureKHR(self.gc.dev, tlas_result.acceleration_structure, null);
        }
    }

    /// Submit BLAS building work to thread pool
    pub fn buildBlasAsync(
        self: *MultithreadedBvhBuilder,
        geometry: *const GeometryData,
        priority: WorkPriority,
        completion_callback: ?*const fn (*anyopaque, BvhBuildResult) void,
        callback_context: ?*anyopaque,
    ) !u64 {
        const work_id = self.next_work_id.fetchAdd(1, .monotonic);
        _ = self.pending_work.fetchAdd(1, .monotonic);

        // Create work data on heap for persistent access by worker thread
        const work_data = try self.allocator.create(BvhWorkData);
        work_data.* = BvhWorkData{
            .work_type = .build_blas,
            .geometry_data = @constCast(geometry),
            .instance_data = null,
            .completion_callback = completion_callback,
            .callback_context = callback_context,
            .work_id = work_id,
        };

        // Submit work item
        const work_item = createBvhBuildingWork(
            work_id,
            .blas,
            @ptrCast(work_data),
            .full_rebuild,
            priority,
            bvhWorkerFunction,
            self,
        );

        try self.thread_pool.submitWork(work_item);
        return work_id;
    }

    /// Submit TLAS building work to thread pool
    pub fn buildTlasAsync(
        self: *MultithreadedBvhBuilder,
        instances: []const InstanceData,
        priority: WorkPriority,
        completion_callback: ?*const fn (*anyopaque, BvhBuildResult) void,
        callback_context: ?*anyopaque,
    ) !u64 {
        const work_id = self.next_work_id.fetchAdd(1, .monotonic);
        _ = self.pending_work.fetchAdd(1, .monotonic);

        // Make a heap-allocated copy of instances for persistent access by worker thread
        const instances_copy = try self.allocator.alloc(InstanceData, instances.len);
        @memcpy(instances_copy, instances);

        // Create work data on heap for persistent access by worker thread
        const work_data = try self.allocator.create(BvhWorkData);
        work_data.* = BvhWorkData{
            .work_type = .build_tlas,
            .geometry_data = null,
            .instance_data = instances_copy,
            .completion_callback = completion_callback,
            .callback_context = callback_context,
            .work_id = work_id,
        };

        // Submit work item
        const work_item = createBvhBuildingWork(
            work_id,
            .tlas,
            @ptrCast(work_data),
            .full_rebuild,
            priority,
            bvhWorkerFunction,
            self,
        );

        try self.thread_pool.submitWork(work_item);
        return work_id;
    }

    /// Build BVH structures asynchronously using pre-computed raytracing data
    pub fn buildRtDataBvhAsync(
        self: *MultithreadedBvhBuilder,
        rt_data: RaytracingData,
        completion_callback: ?*const fn (*anyopaque, []const BlasResult, ?TlasResult) void,
        callback_context: ?*anyopaque,
    ) !void {
        // Use the RT geometries directly for worker item creation - extract mesh data on main thread
        for (rt_data.geometries, 0..) |rt_geometry, geom_idx| {
            const mesh = rt_geometry.mesh_ptr;

            // Skip meshes without valid buffers (already filtered by SceneBridge)
            if (mesh.vertex_buffer == null or mesh.index_buffer == null) {
                log(.WARN, "bvh_builder", "Geometry {}: Skipping - missing vertex/index buffers", .{geom_idx});
                continue;
            }

            const material_id = mesh.material_id;

            // Create GeometryData with extracted data (no mesh pointer access needed on worker thread)
            // Create GeometryData for the mesh
            const geometry_data = try self.allocator.create(GeometryData);
            geometry_data.* = GeometryData{
                .mesh_ptr = mesh,
                .material_id = material_id,
                .transform = Math.Mat4.identity(), // Instance transform handled by RTInstance
                .mesh_id = @intCast(geom_idx),
            };

            // Create BvhWorkData with callback information
            const work_data = try self.allocator.create(BvhWorkData);
            const work_id = self.next_work_id.fetchAdd(1, .monotonic);
            // Store the original callback in a wrapper structure
            if (completion_callback != null and callback_context != null) {
                const wrapper = try self.allocator.create(CallbackWrapper);
                wrapper.* = CallbackWrapper{
                    .callback_fn = completion_callback.?,
                    .callback_context = callback_context.?,
                };

                work_data.* = BvhWorkData{
                    .work_type = .build_blas,
                    .geometry_data = geometry_data,
                    .instance_data = null,
                    .completion_callback = blasCallbackWrapper,
                    .callback_context = wrapper,
                    .work_id = work_id,
                };
            } else {
                work_data.* = BvhWorkData{
                    .work_type = .build_blas,
                    .geometry_data = geometry_data,
                    .instance_data = null,
                    .completion_callback = null,
                    .callback_context = null,
                    .work_id = work_id,
                };
            }

            _ = self.pending_work.fetchAdd(1, .monotonic);

            const work_item = createBvhBuildingWork(
                work_id,
                .blas,
                @ptrCast(work_data),
                .full_rebuild,
                .normal,
                bvhWorkerFunction,
                self,
            );
            _ = self.thread_pool.requestWorkers(.gpu_work, 2);
            try self.thread_pool.submitWork(work_item);
        }
    }

    /// Check if all pending work is complete
    pub fn isWorkComplete(self: *const MultithreadedBvhBuilder) bool {
        return self.pending_work.load(.monotonic) == 0;
    }

    /// Take current BLAS results (thread-safe) and clear builder ownership
    pub fn takeCompletedBlas(self: *MultithreadedBvhBuilder, allocator: std.mem.Allocator) ![]BlasResult {
        self.blas_mutex.lock();
        defer self.blas_mutex.unlock();
        log(.DEBUG, "bvh_builder", "Taking {} completed BLAS results", .{self.completed_blas.items.len});

        const results = try allocator.alloc(BlasResult, self.completed_blas.items.len);
        @memcpy(results, self.completed_blas.items);
        self.completed_blas.clearRetainingCapacity();
        return results;
    }

    /// Take TLAS result if available (thread-safe) and clear builder ownership
    pub fn takeCompletedTlas(self: *MultithreadedBvhBuilder) ?TlasResult {
        self.tlas_mutex.lock();
        defer self.tlas_mutex.unlock();
        log(.DEBUG, "bvh_builder", "Taking completed TLAS result", .{});

        const result = self.completed_tlas;
        if (result != null) {
            self.completed_tlas = null;
        }
        return result;
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

    /// Clear completed results
    pub fn clearResults(self: *MultithreadedBvhBuilder) void {
        self.blas_mutex.lock();
        defer self.blas_mutex.unlock();

        self.completed_blas.clearRetainingCapacity();
        self.completed_tlas = null;
    }
};

/// Unified worker function for BVH building (both BLAS and TLAS)
fn bvhWorkerFunction(context: *anyopaque, work_item: WorkItem) void {
    const builder = @as(*MultithreadedBvhBuilder, @ptrCast(@alignCast(context)));
    const start_time = std.time.nanoTimestamp();

    switch (work_item.data.bvh_building.as_type) {
        .blas => {
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

            // If callback provided, call it and transfer ownership to callback
            // Otherwise, store in completed_blas for later retrieval via takeCompletedBlas()
            if (work_data.completion_callback) |callback| {
                if (work_data.callback_context) |cb_context| {
                    callback(cb_context, .{ .build_blas = final_result });
                    // Ownership transferred to callback - don't store in completed_blas
                    return;
                }
            }

            // No callback - store result for later retrieval
            builder.blas_mutex.lock();
            defer builder.blas_mutex.unlock();

            builder.completed_blas.append(builder.allocator, final_result) catch |err| {
                log(.ERROR, "bvh_builder", "Failed to store BLAS result: {}", .{err});
                return;
            };
        },
        .tlas => {
            const work_data = @as(*BvhWorkData, @ptrCast(@alignCast(work_item.data.bvh_building.work_data)));

            defer {
                // Free the heap-allocated instances copy
                if (work_data.instance_data) |instances| {
                    builder.allocator.free(instances);
                }
                builder.allocator.destroy(work_data);
            }

            const result = buildTlasSynchronous(builder, work_data.instance_data.?) catch |err| {
                log(.ERROR, "bvh_builder", "TLAS build failed: {}", .{err});
                _ = builder.pending_work.fetchSub(1, .monotonic);
                return;
            };

            const build_time = @as(u64, @intCast(std.time.nanoTimestamp() - start_time));
            var final_result = result;
            final_result.build_time_ns = build_time;

            // Store result thread-safely
            builder.tlas_mutex.lock();
            builder.completed_tlas = final_result;
            builder.tlas_mutex.unlock();

            _ = builder.pending_work.fetchSub(1, .monotonic);

            // Call completion callback if provided
            if (work_data.completion_callback) |callback| {
                if (work_data.callback_context) |cb_context| {
                    callback(cb_context, .{ .build_tlas = final_result });
                }
            }
        },
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
        .flags = vk.BuildAccelerationStructureFlagsKHR{ .prefer_fast_build_bit_khr = true },
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
        .build_time_ns = 0, // Will be set by caller
    };
}

/// Synchronous TLAS building function
fn buildTlasSynchronous(builder: *MultithreadedBvhBuilder, instances: []const InstanceData) !TlasResult {
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

/// Wrapper callback that converts BvhBuildResult to the raytracing system callback format
fn blasCallbackWrapper(context: *anyopaque, result: BvhBuildResult) void {
    switch (result) {
        .build_blas => |blas_result| {
            // Extract the wrapper from the context
            const wrapper = @as(*CallbackWrapper, @ptrCast(@alignCast(context)));

            // Create single-item array for the callback
            const blas_array = [_]BlasResult{blas_result};

            // Call the original raytracing system callback
            wrapper.callback_fn(wrapper.callback_context, &blas_array, null);
        },
        else => {
            log(.WARN, "bvh_builder", "BLAS wrapper received unexpected result type", .{});
        },
    }
}

/// Callback for scene BLAS build completion
fn sceneBlasBuildCallback(context: *anyopaque, result: BvhBuildResult) void {
    _ = context;
    switch (result) {
        .build_blas => |blas_result| {
            _ = blas_result;
        },
        else => {},
    }
}
