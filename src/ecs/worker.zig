const std = @import("std");
const TP = @import("../threading/thread_pool.zig");
const RegistryModule = @import("registry.zig");
const EntityId = RegistryModule.EntityId;

pub const ComponentJob = struct {
    type_id: usize,
    comp_handle: usize,
    registry_ctx: *anyopaque,
    updater: *const fn (*anyopaque, f32) void, // (component_ptr, dt)
    dt: f32,
};

pub const ComponentChunkJob = struct {
    type_id: usize,
    handles: []usize,
    entities: []EntityId,
    registry_ctx: *anyopaque,
    updater: *const fn (*anyopaque, f32) void,
    dt: f32,
    allocator: std.mem.Allocator,
};

pub fn generic_worker(_context: *anyopaque, work: TP.WorkItem) void {
    _ = _context;
    const custom = work.data.custom;
    const job: *ComponentJob = @ptrCast(@alignCast(custom.user_data));

    // Resolve the concrete component pointer using the registry context and handle
    const registry: *RegistryModule.Registry = @ptrCast(@alignCast(job.registry_ctx));
    const comp = registry.getComponent(job.type_id, job.comp_handle) orelse null;
    if (comp) |cptr| {
        job.updater(@as(*anyopaque, cptr), job.dt);
    } else {
        // Component not found; nothing to do
    }

    // Free the job using the thread-pool allocator provided via work.context
    const pool: *TP.ThreadPool = @ptrCast(@alignCast(work.context));
    pool.allocator.destroy(job);
}

pub const worker_fn: *const fn (*anyopaque, TP.WorkItem) void = generic_worker;

pub fn chunk_worker(_context: *anyopaque, work: TP.WorkItem) void {
    _ = _context;
    const custom = work.data.custom;
    const job: *ComponentChunkJob = @ptrCast(@alignCast(custom.user_data));

    const registry: *RegistryModule.Registry = @ptrCast(@alignCast(job.registry_ctx));

    var i: usize = 0;
    while (i < job.handles.len) : (i += 1) {
        const handle = job.handles[i];
        if (registry.getComponent(job.type_id, handle)) |comp| {
            job.updater(comp, job.dt);
        }
    }

    job.allocator.free(job.handles);
    job.allocator.free(job.entities);
    job.allocator.destroy(job);
}

pub const chunk_worker_fn: *const fn (*anyopaque, TP.WorkItem) void = chunk_worker;
