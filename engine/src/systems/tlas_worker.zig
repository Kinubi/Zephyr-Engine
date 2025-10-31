const std = @import("std");
const log = @import("../utils/log.zig").log;
const vk = @import("vulkan");
const Math = @import("../utils/math.zig");
const MultithreadedBvhBuilder = @import("multithreaded_bvh_builder.zig").MultithreadedBvhBuilder;
const BlasResult = @import("multithreaded_bvh_builder.zig").BlasResult;
const InstanceData = @import("multithreaded_bvh_builder.zig").InstanceData;
const GeometryData = @import("multithreaded_bvh_builder.zig").GeometryData;
const BvhWorkData = @import("multithreaded_bvh_builder.zig").BvhWorkData;
const buildTlasSynchronous = @import("multithreaded_bvh_builder.zig").buildTlasSynchronous;
const blasWorkerFn = @import("multithreaded_bvh_builder.zig").blasWorkerFn;
const createBvhBuildingWork = @import("../threading/thread_pool.zig").createBvhBuildingWork;
const RenderData = @import("../rendering/render_data_types.zig");
const WorkItem = @import("../threading/thread_pool.zig").WorkItem;

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

    // Atomic BLAS result buffer: each slot corresponds to a geometry index
    // BLAS workers atomically fill their slot when complete
    blas_buffer: []std.atomic.Value(?*BlasResult),
    filled_count: std.atomic.Value(u32), // How many slots are filled
    expected_count: u32, // Total number of BLAS we need

    // Geometry IDs required for this TLAS build (indexed same as blas_buffer)
    required_geometry_ids: []const u32,

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
/// Each BLAS worker knows its geometry index and fills that specific slot
pub fn fillBlasSlot(job: *TlasJob, geometry_index: u32, blas_result: *BlasResult) void {
    // Store the BLAS result pointer in the appropriate slot
    const slot = &job.blas_buffer[geometry_index];
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
    // Step 1: Check BLAS registry for all required geometry IDs

    var all_blas_ready = true;
    var missing_count: u32 = 0;

    for (job.required_geometry_ids, 0..) |geom_id, geom_index| {
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
                job.blas_buffer[geom_index].store(blas_copy, .release);
                _ = job.filled_count.fetchAdd(1, .release);
            } else {
                // This shouldn't happen if all_blas_ready was true
                log(.ERROR, "tlas_worker", "BLAS for geometry {} disappeared from registry or mesh changed!", .{geom_id});
                return error.MissingBlas;
            }
        }
    } else {
        log(.INFO, "tlas_worker", "Building TLAS with {} new BLAS (job {})", .{ missing_count, job.job_id });

        // Spawn BLAS workers for missing geometry IDs
        for (job.required_geometry_ids, 0..) |geom_id, geom_index| {
            const mesh_ptr = job.geometries[geom_index].mesh_ptr;

            // Check if BLAS exists AND matches our mesh
            if (job.builder.lookupBlasPtr(geom_id, mesh_ptr)) |blas_ptr| {
                // BLAS exists in registry AND mesh matches - use it
                const blas_copy = try job.allocator.create(BlasResult);
                blas_copy.* = blas_ptr.*;
                job.blas_buffer[geom_index].store(blas_copy, .release);
                _ = job.filled_count.fetchAdd(1, .release);
                continue;
            }

            // BLAS doesn't exist - spawn build
            // Create GeometryData for this BLAS build
            const geom_data = try job.allocator.create(GeometryData);
            geom_data.* = .{
                .mesh_ptr = job.geometries[geom_index].mesh_ptr,
                .material_id = 0, // TODO: Get from instance or geometry
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
    const instances_with_blas = try job.allocator.alloc(InstanceData, job.instances.len);
    defer job.allocator.free(instances_with_blas);

    for (job.blas_buffer, 0..) |*slot, i| {
        if (slot.load(.acquire)) |blas_result| {
            // Copy the instance and set the actual BLAS device address
            instances_with_blas[i] = job.instances[i];
            instances_with_blas[i].blas_address = blas_result.device_address;
        } else {
            log(.ERROR, "tlas_worker", "BLAS slot {} is unexpectedly null after filling", .{i});
            return error.IncompleteBlas;
        }
    }

    // Step 5: Build TLAS with updated instances (now have correct BLAS addresses)
    // Build TLAS synchronously on this worker thread
    // Note: We use the synchronous buildTlasSynchronous since we're already on a worker thread
    const tlas_result = try buildTlasSynchronous(job.builder, instances_with_blas);

    // Step 6: Store TLAS result in builder (lock-free atomic store)
    // The raytracing_system will pick this up on next frame and swap to render_tlas
    const tlas_ptr = try job.allocator.create(@import("multithreaded_bvh_builder.zig").TlasResult);
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
