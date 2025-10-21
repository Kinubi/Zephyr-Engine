const std = @import("std");
const TP = @import("../threading/thread_pool.zig");
pub const EntityId = usize;

/// Small ECS system helper: dispatch chunked jobs for a single component storage.
/// - T: component type
/// - pool: thread pool to submit to
/// - allocator: to allocate per-chunk job payloads
/// - ents/comps: parallel slices
/// - dt: delta time passed to job
/// - priority: work priority
/// - chunk_size: max elements per chunk
/// - worker_fn: top-level worker function pointer that will be invoked with the job pointer
pub fn dispatch_chunked(
    comptime T: type,
    pool: *TP.ThreadPool,
    allocator: std.mem.Allocator,
    ents: []EntityId,
    comps: []T,
    dt: f32,
    priority: TP.WorkPriority,
    chunk_size: usize,
    worker_fn: *const fn (*anyopaque, TP.WorkItem) void,
) !void {
    const total = comps.len;
    var start: usize = 0;
    while (start < total) : (start += chunk_size) {
        const end = if (start + chunk_size > total) total else start + chunk_size;
        const ents_slice = ents[start..end];
        const comps_slice = comps[start..end];

        const ChunkJob = struct {
            ents: []EntityId,
            comps: []T,
            dt: f32,
        };

        const job = try allocator.create(ChunkJob);
        job.* = ChunkJob{ .ents = ents_slice, .comps = comps_slice, .dt = dt };

        const work_item = TP.createCustomWork(0, @ptrCast(*anyopaque, job), @sizeOf(ChunkJob), priority, worker_fn, job);
        try pool.submitWork(work_item);
    }
}
