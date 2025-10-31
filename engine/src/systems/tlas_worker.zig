const std = @import("std");
const log = @import("../utils/log.zig").log;
const vk = @import("vulkan");
const MultithreadedBvhBuilder = @import("multithreaded_bvh_builder.zig").MultithreadedBvhBuilder;
const BlasResult = @import("multithreaded_bvh_builder.zig").BlasResult;
const InstanceData = @import("multithreaded_bvh_builder.zig").InstanceData;
const RenderData = @import("../rendering/render_data_types.zig");

// TLAS worker implementation
// This file implements the per-job atomic BLAS result lists and the event-driven
// TLAS worker that is spawned from rt_system.update() when scene changes are detected.
//
// Key design:
// - BLAS workers push completed results to per-job atomic linked lists
// - TLAS worker checks BLAS registry for required geometry IDs
// - Spawns missing BLAS builds if needed
// - Polls completed_count until all BLAS ready
// - Builds TLAS and publishes via atomic flip

pub const BlasNode = extern struct {
    next: ?*BlasNode,
    work_id: u64,
    result: BlasResult,
    status: std.atomic.Value(u8), // 0=init,1=done,2=failed
};

pub const TlasJob = struct {
    // Job identification
    job_id: u64,
    
    // Atomic tracking for BLAS completion
    expected_count: u32, // How many BLAS we're waiting for
    completed_count: std.atomic.Value(u32), // How many have completed
    head: std.atomic.Value(?*BlasNode), // Lock-free linked list of completed BLAS
    
    // Geometry IDs required for this TLAS build
    required_geometry_ids: []const u32,
    
    // Runtime state: instances and their transforms for TLAS building
    instances: []const InstanceData,
    
    // Allocator for this job's resources
    allocator: std.mem.Allocator,
    
    // Builder reference for spawning missing BLAS jobs
    builder: *MultithreadedBvhBuilder,
    
    // Completion callback (optional) - called when TLAS is built
    completion_callback: ?*const fn (*anyopaque, vk.AccelerationStructureKHR) void = null,
    callback_context: ?*anyopaque = null,
};

/// Lock-protected registry of active TLAS jobs. Registration/deregistration
/// are rare and can use a short mutex.
var jobs_mutex: std.Thread.Mutex = std.Thread.Mutex{};
var jobs: std.AutoHashMap(u64, *TlasJob) = undefined;

pub fn initJobsRegistry(allocator: std.mem.Allocator) !void {
    jobs = std.AutoHashMap(u64, *TlasJob).init(allocator);
}

/// Called by BVH subsystem when submitting a TLAS job.
pub fn registerJob(job: *TlasJob) !void {
    jobs_mutex.lock();
    defer jobs_mutex.unlock();
    try jobs.put(job.job_id, job);
}

pub fn deregisterJob(job_id: u64) void {
    jobs_mutex.lock();
    defer jobs_mutex.unlock();
    _ = jobs.remove(job_id);
}

/// Lock-free push for BLAS workers to publish a completed BLAS into a job head.
pub fn pushBlasResult(job: *TlasJob, node: *BlasNode) void {
    // Ensure node.result is fully initialized before publishing
    node.status.store(1, .release);

    while (true) {
        const old_head = job.head.load(.acquire);
        node.next = old_head;
        if (job.head.cmpxchgWeak(old_head, node, .release, .relaxed)) {
            // Optionally increment completed_count for quick polling
            _ = job.completed_count.fetchAdd(1, .release);
            return;
        }
        // otherwise loop and retry
    }
}

/// Consumer: take all nodes currently published for the job
pub fn takeAllBlasNodes(job: *TlasJob) ?*BlasNode {
    const head = job.head.exchange(null, .acquire);
    if (head == null) return null;
    return head;
}

/// Process ready TLAS jobs (called from rt_system.update() - event-driven, not polling)
/// This function should be invoked once per frame during the raytracing system's update phase.
/// It checks all active jobs and builds TLAS for any job where completed_count >= expected_count.
pub fn processReadyJobs(allocator: std.mem.Allocator) void {
    // Collect job pointers under mutex (short lock)
    jobs_mutex.lock();
    var iter = jobs.valueIterator();
    var job_ptrs = std.ArrayList(*TlasJob).init(allocator);
    defer job_ptrs.deinit();
    while (iter.next()) |job| {
        job_ptrs.append(job) catch {};
    }
    jobs_mutex.unlock();

    // Process each job outside of the mutex
    for (job_ptrs.items) |job| {
        const completed = job.completed_count.load(.acquire);
        if (completed >= job.expected_count) {
            // Consume published BLAS nodes
            const head = takeAllBlasNodes(job);
            if (head) |nodes| {
                // Traverse nodes, collect BlasResult entries into an array
                var results = std.ArrayList(BlasResult).init(allocator);
                defer results.deinit();
                
                var cursor: ?*BlasNode = nodes;
                while (cursor) |n| {
                    // move data out (copy) and free node later
                    results.append(n.result) catch {};
                    cursor = n.next;
                }

                // Build TLAS using results (synchronous call into BVH/TLAS build)
                // buildTlasFromResults(job, results.items);

                // Free nodes after use (consumer frees)
                cursor = nodes;
                while (cursor) |n| {
                    const next = n.next;
                    // allocator.destroy(n); -- free via correct allocator
                    cursor = next;
                }

                // Publish TLAS via engine double-buffer (atomic flip) - implementation-specific
                // publishTlas(job.tlas_result);
                
                // Mark job completed and deregister
                deregisterJob(job.job_id);
            }
        }
    }
}

/// Main TLAS worker function - spawned from rt_system.update() when scene changes detected
/// This is event-driven (runs once per update), not a continuous polling loop
pub fn tlasWorkerMain(job: *TlasJob) !void {
    log(.INFO, "tlas_worker", "TLAS worker started for job {}", .{job.job_id});
    
    // Step 1: Check BLAS registry for all required geometry IDs
    var all_blas_ready = true;
    var missing_count: u32 = 0;
    
    for (job.required_geometry_ids) |geom_id| {
        if (job.builder.lookupBlas(geom_id)) |_| {
            // BLAS exists in registry
            log(.DEBUG, "tlas_worker", "BLAS for geometry {} found in registry", .{geom_id});
        } else {
            // BLAS not built yet - need to spawn worker
            all_blas_ready = false;
            missing_count += 1;
            log(.DEBUG, "tlas_worker", "BLAS for geometry {} missing - will spawn build", .{geom_id});
        }
    }
    
    // Step 2: If any BLAS missing, spawn BLAS workers
    if (!all_blas_ready) {
        log(.INFO, "tlas_worker", "Spawning {} BLAS builds for job {}", .{ missing_count, job.job_id });
        job.expected_count = missing_count;
        
        // TODO: Spawn BLAS workers for missing geometry IDs
        // This requires access to geometry data - will be implemented in integration phase
        // For now, mark that we're waiting for BLAS
        
        // Step 3: Poll until all BLAS complete (brief polling, not continuous)
        const max_poll_iterations = 1000;
        const poll_sleep_ns = 100_000; // 100 microseconds
        
        var iterations: u32 = 0;
        while (iterations < max_poll_iterations) : (iterations += 1) {
            const completed = job.completed_count.load(.acquire);
            if (completed >= job.expected_count) {
                log(.INFO, "tlas_worker", "All BLAS completed for job {} after {} iterations", .{ job.job_id, iterations });
                break;
            }
            std.time.sleep(poll_sleep_ns);
        }
        
        if (iterations >= max_poll_iterations) {
            log(.ERROR, "tlas_worker", "TLAS job {} timed out waiting for BLAS", .{job.job_id});
            return error.TlasJobTimeout;
        }
    } else {
        log(.INFO, "tlas_worker", "All BLAS ready in registry for job {} (transform-only update)", .{job.job_id});
    }
    
    // Step 4: Collect BLAS results from registry (not from atomic list since registry is source of truth)
    var blas_handles = std.ArrayList(vk.DeviceAddress).init(job.allocator);
    defer blas_handles.deinit();
    
    for (job.required_geometry_ids) |geom_id| {
        if (job.builder.lookupBlas(geom_id)) |blas_result| {
            try blas_handles.append(blas_result.device_address);
        } else {
            log(.ERROR, "tlas_worker", "BLAS for geometry {} disappeared from registry", .{geom_id});
            return error.BlasMissing;
        }
    }
    
    // Step 5: Build TLAS with current transforms and BLAS handles
    log(.INFO, "tlas_worker", "Building TLAS for job {} with {} instances", .{ job.job_id, job.instances.len });
    
    // TODO: Call actual TLAS building function from MultithreadedBvhBuilder
    // This will be wired up in the integration phase
    
    // Step 6: Publish TLAS via atomic flip (will be implemented in integration)
    // The raytracing_system will swap to the new TLAS on next frame
    
    // Step 7: Call completion callback if provided
    if (job.completion_callback) |callback| {
        if (job.callback_context) |ctx| {
            // TODO: Pass actual TLAS handle once building is implemented
            callback(ctx, vk.AccelerationStructureKHR.null_handle);
        }
    }
    
    log(.INFO, "tlas_worker", "TLAS worker completed for job {}", .{job.job_id});
}

// Integration notes:
// 1. Call tlasWorkerMain() from rt_system.update() as a ThreadPool job
// 2. BLAS workers call pushBlasResult(job, node) on completion
// 3. Transform-only TLAS jobs have all BLAS ready immediately
// 4. New geometry triggers BLAS builds, brief polling until ready
// 5. TLAS published via double-buffer atomic flip for stability
