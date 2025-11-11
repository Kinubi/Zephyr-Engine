const std = @import("std");
const log = @import("../../utils/log.zig").log;
const vk = @import("vulkan");
const Math = @import("../../utils/math.zig");
const MultithreadedBvhBuilder = @import("multithreaded_bvh_builder.zig").MultithreadedBvhBuilder;
const BlasResult = @import("multithreaded_bvh_builder.zig").BlasResult;
const InstanceData = @import("multithreaded_bvh_builder.zig").InstanceData;
const GeometryData = @import("multithreaded_bvh_builder.zig").GeometryData;
const BvhWorkData = @import("multithreaded_bvh_builder.zig").BvhWorkData;
const TlasResult = @import("multithreaded_bvh_builder.zig").TlasResult;
const buildTlasSynchronous = @import("multithreaded_bvh_builder.zig").buildTlasSynchronous;
const blasWorkerFn = @import("multithreaded_bvh_builder.zig").blasWorkerFn;
const createBvhBuildingWork = @import("../../threading/thread_pool.zig").createBvhBuildingWork;
const RenderData = @import("../../rendering/render_data_types.zig");
const WorkItem = @import("../../threading/thread_pool.zig").WorkItem;

// TLAS worker implementation
// This file implements the per-job atomic BLAS result buffer and the event-driven
// TLAS worker that is spawned from rt_system.update() when scene changes are detected.
//
// Key design:
// - Create atomic buffer (array of atomic pointers) sized to number of geometries
// - BLAS workers fill their slot in the buffer atomically
// - TLAS worker loops checking filled_count until all slots are filled
// - Builds TLAS and publishes via atomic flip

pub const TlasJob = struct {
    // Job identification
    job_id: u64,

    // Atomic BLAS result buffer: one slot per UNIQUE geometry (not per instance!)
    // BLAS workers atomically fill their slot when complete
    blas_buffer: []std.atomic.Value(?*BlasResult),
    filled_count: std.atomic.Value(u32), // How many slots are filled
    expected_count: u32, // Total number of unique BLAS we need

    // Geometry IDs required for this TLAS build (one per instance, may have duplicates)
    required_geometry_ids: []const u32,
    
    // Mapping from geometry_id to blas_buffer index
    // This allows us to find the buffer slot for a given geometry ID
    geom_id_to_buffer_index: []u32,

    // Geometry data for spawning BLAS builds (includes mesh_ptr for each geometry)
    geometries: []const RenderData.RaytracingData.RTGeometry,

    // Runtime state: instances and their transforms for TLAS building
    instances: []const InstanceData,

    // Allocator for this job's resources
    allocator: std.mem.Allocator,

    // Semaphore signaled by BLAS workers when they fill a slot
    completion_sem: std.Thread.Semaphore,

    // Builder reference for spawning missing BLAS jobs and storing result
    builder: *MultithreadedBvhBuilder,
};

/// Called by BLAS workers to fill a slot in the job's BLAS buffer
/// geometry_index is the instance index - we map it to buffer index via geometry ID
pub fn fillBlasSlot(job: *TlasJob, geometry_index: u32, blas_result: *BlasResult) void {
    // Get the geometry ID for this instance
    const geom_id = job.required_geometry_ids[geometry_index];
    
    // Map geometry ID to buffer index
    const buffer_index = job.geom_id_to_buffer_index[geom_id];
    
    // Store the BLAS result pointer in the appropriate slot
    const slot = &job.blas_buffer[buffer_index];
    slot.store(blas_result, .release);

    // Increment filled count
    _ = job.filled_count.fetchAdd(1, .release);
    // Signal the TLAS job that a BLAS slot has been filled
    job.completion_sem.post();
}

pub fn tlasWorkerMain(context: *anyopaque, work_item: WorkItem) void {
    _ = work_item;
    const job = @as(*TlasJob, @ptrCast(@alignCast(context)));

    // Run with error handling
    tlasWorkerImpl(job) catch |err| {
        handleError(err, job);
    };
}

fn tlasWorkerImpl(job: *TlasJob) !void {
    // Step 0: Deduplicate required_geometry_ids to avoid spawning multiple builds for the same geometry
    // Use a simple approach: only process the first occurrence of each geometry_id
    const processed_geom_ids = try job.allocator.alloc(bool, job.builder.max_geometry_id);
    defer job.allocator.free(processed_geom_ids);
    @memset(processed_geom_ids, false);

    // Step 1: Check BLAS registry for all required geometry IDs

    var all_blas_ready = true;
    var missing_count: u32 = 0;

    for (job.required_geometry_ids, 0..) |geom_id, geom_index| {
        // Skip if we've already processed this geometry ID
        if (processed_geom_ids[geom_id]) {
            continue;
        }
        processed_geom_ids[geom_id] = true;

        const mesh_ptr = job.geometries[geom_index].mesh_ptr;
        if (job.builder.lookupBlas(geom_id, mesh_ptr)) |_| {
            // BLAS exists in registry AND matches our mesh
        } else {
            // BLAS not built yet OR different mesh - need to spawn worker
            all_blas_ready = false;
            missing_count += 1;
        }
    }

    // Step 2: Fill buffer from registry or spawn BLAS workers
    if (all_blas_ready) {
        // Transform-only update: all BLAS already in registry, copy them to our buffer
        for (job.required_geometry_ids, 0..) |geom_id, geom_index| {
            const mesh_ptr = job.geometries[geom_index].mesh_ptr;
            if (job.builder.lookupBlasPtr(geom_id, mesh_ptr)) |blas_ptr| {
                // BLAS exists in registry AND mesh matches - make a heap copy to avoid stale pointer issues
                const blas_copy = try job.allocator.create(BlasResult);
                blas_copy.* = blas_ptr.*;
                
                // Map geometry ID to buffer index
                const buffer_index = job.geom_id_to_buffer_index[geom_id];
                job.blas_buffer[buffer_index].store(blas_copy, .release);
                _ = job.filled_count.fetchAdd(1, .release);
            } else {
                // This shouldn't happen if all_blas_ready was true
                log(.ERROR, "tlas_worker", "BLAS for geometry {} disappeared from registry or mesh changed!", .{geom_id});
                return error.MissingBlas;
            }
        }
    } else {
        log(.INFO, "tlas_worker", "Building TLAS with {} new BLAS (job {})", .{ missing_count, job.job_id });

        // Reset processed flags for second pass
        @memset(processed_geom_ids, false);

        // Spawn BLAS workers for missing geometry IDs (deduplicated)
        for (job.required_geometry_ids, 0..) |geom_id, geom_index| {
            const mesh_ptr = job.geometries[geom_index].mesh_ptr;

            // Check if BLAS exists AND matches our mesh
            if (job.builder.lookupBlasPtr(geom_id, mesh_ptr)) |blas_ptr| {
                // BLAS exists in registry AND mesh matches - use it for ALL instances of this geometry
                const blas_copy = try job.allocator.create(BlasResult);
                blas_copy.* = blas_ptr.*;
                
                // Map geometry ID to buffer index
                const buffer_index = job.geom_id_to_buffer_index[geom_id];
                job.blas_buffer[buffer_index].store(blas_copy, .release);
                _ = job.filled_count.fetchAdd(1, .release);
                continue;
            }

            // Skip if we've already spawned a build for this geometry ID
            if (processed_geom_ids[geom_id]) {
                continue;
            }
            processed_geom_ids[geom_id] = true;

            // BLAS doesn't exist - spawn build (ONCE per unique geometry)
            // Create GeometryData for this BLAS build
            const geom_data = try job.allocator.create(GeometryData);
            geom_data.* = .{
                .mesh_ptr = job.geometries[geom_index].mesh_ptr,
                // TODO(ARCHITECTURE): REMOVE material_id FROM GeometryData - MEDIUM PRIORITY
                // Problem: GeometryData.material_id is per-geometry, but material should be per-instance
                // Reality: Different instances of same geometry can have different materials
                // Solution: Material ID stored in InstanceData.custom_index (already exists!)
                // Refactor: Remove material_id from GeometryData, use only InstanceData.custom_index
                // Impact: BLAS doesn't need material info (geometry only), TLAS instances have material
                // Branch: features/raytracing-architecture
                .material_id = 0, // Placeholder - should be removed from GeometryData entirely
                .transform = Math.Mat4.identity(), // Identity transform for BLAS (transforms applied at TLAS level)
                .mesh_id = geom_id,
            };

            // Build BLAS asynchronously - worker will fill slot when done
            const work_data = try job.allocator.create(BvhWorkData);
            work_data.* = .{
                .work_type = .build_blas,
                .geometry_data = geom_data,
                .instance_data = null,
                .completion_callback = null,
                .callback_context = null,
                .work_id = job.builder.next_work_id.fetchAdd(1, .monotonic),
                .tlas_job = job, // Link to our job for result publishing
                .geometry_index = @intCast(geom_index), // Tell worker which slot to fill
            };

            // Submit to thread pool using BLAS worker function
            const blas_work_item = createBvhBuildingWork(
                work_data.work_id,
                .blas,
                @ptrCast(work_data),
                .full_rebuild,
                .normal,
                blasWorkerFn,
                job.builder,
            );

            try job.builder.thread_pool.submitWork(blas_work_item);
        }

        // Step 3: Wait for all BLAS workers to signal completion of their slots.
        // We only wait for the number of missing slots we spawned.
        if (missing_count > 0) {
            for (0..missing_count) |_| {
                job.completion_sem.wait();
            }

            // After waiting, verify all slots are filled
            const filled_after = job.filled_count.load(.acquire);
            if (filled_after < job.expected_count) {
                log(.ERROR, "tlas_worker", "TLAS job {} timed out: {}/{} slots filled", .{ job.job_id, filled_after, job.expected_count });
                return error.TlasJobTimeout;
            }
        }
    }

    // Step 4: Create instances with BLAS addresses from our atomic buffer
    // Map each instance's geometry_id to its BLAS in the buffer
    const instances_with_blas = try job.allocator.alloc(InstanceData, job.instances.len);
    defer job.allocator.free(instances_with_blas);

    for (job.instances, 0..) |inst, i| {
        // Get geometry ID for this instance
        const geom_id = job.required_geometry_ids[i];
        
        // Map to buffer index
        const buffer_index = job.geom_id_to_buffer_index[geom_id];
        
        // Get BLAS from buffer
        const slot = &job.blas_buffer[buffer_index];
        if (slot.load(.acquire)) |blas_result| {
            // Copy the instance and set the actual BLAS device address
            instances_with_blas[i] = inst;
            instances_with_blas[i].blas_address = blas_result.device_address;
        } else {
            log(.ERROR, "tlas_worker", "BLAS slot {} (geom_id {}) is unexpectedly null after filling", .{ buffer_index, geom_id });
            return error.IncompleteBlas;
        }
    }

    // Step 5: Build TLAS with updated instances (now have correct BLAS addresses)
    // Build TLAS synchronously on this worker thread
    // Note: We use the synchronous buildTlasSynchronous since we're already on a worker thread
    const tlas_result = try buildTlasSynchronous(job.builder, instances_with_blas);

    // Step 6: Store TLAS result in builder (lock-free atomic store)
    // The raytracing_system will pick this up on next frame and swap to render_tlas
    const tlas_ptr = try job.allocator.create(TlasResult);
    tlas_ptr.* = tlas_result;

    // Atomically store the pointer - if there's an old one, free it (shouldn't happen but be safe)
    if (job.builder.completed_tlas.swap(tlas_ptr, .release)) |old_ptr| {
        log(.WARN, "tlas_worker", "Overwriting unconsumed TLAS result - freeing old", .{});
        old_ptr.buffer.deinit();
        old_ptr.instance_buffer.deinit();
        job.builder.gc.vkd.destroyAccelerationStructureKHR(job.builder.gc.dev, old_ptr.acceleration_structure, null);
        job.allocator.destroy(old_ptr);
    }

    return;
}

// Error handler wrapping the main implementation
fn handleError(err: anyerror, job: *TlasJob) void {
    log(.ERROR, "tlas_worker", "TLAS worker failed for job {}: {}", .{ job.job_id, err });
}
