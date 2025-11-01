const std = @import("std");
const log = @import("../utils/log.zig").log;
const StatePool = @import("state_pool.zig").StatePool;
const EntityId = @import("../ecs/entity_registry.zig").EntityId;
const ThreadPool = @import("../threading/thread_pool.zig").ThreadPool;
const lua = @import("lua_bindings.zig");
const ActionQueue = @import("action_queue.zig").ActionQueue;
const Action = @import("action_queue.zig").Action;
const ThreadPoolMod = @import("../threading/thread_pool.zig");
const WorkItem = ThreadPoolMod.WorkItem;
const WorkItemType = ThreadPoolMod.WorkItemType;
const WorkPriority = ThreadPoolMod.WorkPriority;

/// Minimal, self-contained ScriptRunner implementation (Phase 1)
/// - Dedicated script worker pool
/// - Job queue protected by a mutex and signaled with a semaphore
/// - Worker threads currently run a placeholder "execute" step (no actual Lua yet)
///
pub const ScriptJob = struct {
    id: u64,
    // Script bytes - copied at enqueue time
    script: []u8,
    // Opaque user context
    context: *anyopaque,
    // Owning entity (invalid == no owner)
    owner: EntityId,
    // Optional user context passed through to Lua (e.g., Scene pointer)
    user_ctx: ?*anyopaque,
    // Optional callback executed when job finishes (executed on worker thread)
    // Signature: fn(job_id: u64, ctx: *anyopaque, success: bool, message: []const u8) void
    callback: ?*const fn (u64, *anyopaque, bool, []const u8) void,
    allocator: std.mem.Allocator,
};

pub const ScriptRunner = struct {
    allocator: std.mem.Allocator,
    // Note: ScriptRunner uses the engine ThreadPool for job execution. We keep num_workers
    // only for API compatibility but do not spawn local threads.

    thread_pool: *ThreadPool,

    // Job queue
    job_queue: std.ArrayList(*ScriptJob),
    queue_mutex: std.Thread.Mutex = .{},
    queue_sem: std.Thread.Semaphore,

    // Optional resource pool (e.g. lua_State pool) used for leasing per-job state
    state_pool: ?*StatePool,

    // Optional main-thread action queue for delivering results to the main thread
    action_queue: ?*@import("action_queue.zig").ActionQueue,

    running: std.atomic.Value(bool),
    next_job_id: std.atomic.Value(u64),

    pub fn init(allocator: std.mem.Allocator, thread_pool: *ThreadPool) !ScriptRunner {
        const s = ScriptRunner{
            .allocator = allocator,
            .job_queue = std.ArrayList(*ScriptJob){},
            .queue_mutex = .{},
            .queue_sem = std.Thread.Semaphore{},
            .state_pool = null,
            .action_queue = null,
            .thread_pool = thread_pool,
            .running = std.atomic.Value(bool).init(false),
            .next_job_id = std.atomic.Value(u64).init(1),
        };

        // job_queue was initialized in the struct literal as an empty ArrayList

        // Register a scripting subsystem so ThreadPool workers will accept scripting WorkItems.
        // Use WorkItemType.custom for now and allow up to num_workers workers.;
        const cfg = ThreadPoolMod.SubsystemConfig{
            .name = "scripting",
            .min_workers = 1,
            .max_workers = @as(u32, @intCast(8)),
            .priority = ThreadPoolMod.WorkPriority.normal,
            .work_item_type = ThreadPoolMod.WorkItemType.custom,
        };
        s.thread_pool.registerSubsystem(cfg) catch |err| {
            // If registration fails, log and continue; submission will likely fail later
            log(.WARN, "scripting", "failed to register subsystem with ThreadPool: {}", .{err});
        };

        return s;
    }

    pub fn deinit(self: *ScriptRunner) void {
        // When using the engine ThreadPool we don't manage local threads here.
        // Drain and free any remaining jobs in the local queue (should be empty when using ThreadPool)

        // Drain and free any remaining jobs
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();
        for (self.job_queue.items) |*jobPtr| {
            const job = jobPtr.*;
            job.allocator.free(job.script);
            job.allocator.destroy(jobPtr);
        }
        self.job_queue.deinit(self.allocator);

        if (self.state_pool) |sp| {
            sp.deinit();
            self.allocator.destroy(sp);
            self.state_pool = null;
        }
        // Note: we do not own action_queue; caller must manage its lifetime
        self.action_queue = null;
    }

    pub fn setResultQueue(self: *ScriptRunner, q: *ActionQueue) void {
        self.action_queue = q;
    }

    /// Initialize a resource/state pool for leasing per-job state (e.g. lua_State).
    pub fn setupStatePool(self: *ScriptRunner, initial_capacity: usize, create_fn: @import("state_pool.zig").CreateFn, destroy_fn: @import("state_pool.zig").DestroyFn) !void {
        // Create pool value then store on heap
        const pool_value = try StatePool.init(self.allocator, initial_capacity, create_fn, destroy_fn);
        const pool_ptr = try self.allocator.create(StatePool);
        pool_ptr.* = pool_value;
        self.state_pool = pool_ptr;
    }

    /// Convenience helper specifically for Lua states: pre-warm a pool using
    /// `lua_bindings.createLuaState` and `lua_bindings.destroyLuaState`.
    pub fn setupLuaStatePool(self: *ScriptRunner, initial_capacity: usize) !void {
        try self.setupStatePool(initial_capacity, &lua.createLuaState, &lua.destroyLuaState);
    }

    pub fn enqueueScript(self: *ScriptRunner, script_str: []const u8, ctx: *anyopaque, callback: ?*const fn (u64, *anyopaque, bool, []const u8) void, owner: EntityId, user_ctx: ?*anyopaque) !u64 {
        // Copy script into allocator-owned buffer
        const n = script_str.len;
        const buf = try self.allocator.alloc(u8, n);
        std.mem.copyForwards(u8, buf, script_str);

        const job_ptr = try self.allocator.create(ScriptJob);
        job_ptr.* = ScriptJob{
            .id = self.next_job_id.fetchAdd(1, .monotonic),
            .script = buf,
            .context = ctx,
            .owner = owner,
            .user_ctx = user_ctx,
            .callback = callback,
            .allocator = self.allocator,
        };

        // Submit to ThreadPool as a WorkItem

        const wi = WorkItem{
            .id = job_ptr.*.id,
            .item_type = WorkItemType.custom,
            .priority = WorkPriority.normal,
            .data = .{ .custom = .{ .user_data = job_ptr, .size = 0 } },
            .worker_fn = &threadPoolWorker,
            .context = @as(*anyopaque, self),
        };

        // Try submit; on failure fall back to local queue append
        const tp = self.thread_pool;
        // Attempt to submit; on error fall back to local enqueue
        var did_submit: bool = true;
        tp.submitWork(wi) catch |err| {
            did_submit = false;
            log(.WARN, "scripting", "ThreadPool submit failed for job {}: {}", .{ job_ptr.*.id, err });
        };
        if (did_submit) {
            log(.INFO, "scripting", "submitted job {} to ThreadPool", .{job_ptr.*.id});
            return job_ptr.*.id;
        }

        // Fallback: enqueue locally (should not be used in the ThreadPool-only mode)
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();
        try self.job_queue.append(self.allocator, job_ptr);
        log(.INFO, "scripting", "enqueued job {} (local fallback)", .{job_ptr.*.id});
        self.queue_sem.post();

        return job_ptr.*.id;
    }
};

// Placeholder: per-worker teardown (destroy lua_State)

// Worker wrapper invoked by ThreadPool workers. Matches signature: fn (*anyopaque, WorkItem) void
fn threadPoolWorker(context: *anyopaque, wi: @import("../threading/thread_pool.zig").WorkItem) void {
    const runner = @as(*ScriptRunner, @ptrCast(@alignCast(context)));

    log(.DEBUG, "scripting", "ThreadPool worker invoked for job {}", .{wi.id});

    // Extract the job pointer from the work item custom data
    const job_ptr_any: *anyopaque = wi.data.custom.user_data;
    const job = @as(*ScriptJob, @ptrCast(@alignCast(job_ptr_any)));

    // Run the same per-job logic as the local worker
    // Acquire leased state from the configured StatePool. We require a pool
    // to be present; ScriptRunner should be configured with `setupLuaStatePool`.
    var leased_state: ?*anyopaque = null;
    if (runner.state_pool) |sp| {
        leased_state = sp.acquire();
    } else {
        log(.WARN, "scripting", "no state_pool configured; cannot execute job {}", .{job.id});
        const msg_no_pool: []const u8 = "(no lua state pool configured)";
        if (job.callback) |cb| cb(job.id, job.context, false, msg_no_pool);
        job.allocator.free(job.script);
        job.allocator.destroy(job);
        return;
    }

    var res = lua.ExecuteResult{ .success = false, .message = "" };
    const owner_u32 = @intFromEnum(job.owner);
    if (lua.executeLuaBuffer(runner.allocator, leased_state.?, job.script, owner_u32, job.user_ctx)) |v| {
        res = v;
    } else |err| {
        log(.WARN, "scripting", "executeLuaBuffer failed: {}", .{err});
        res = lua.ExecuteResult{ .success = false, .message = "" };
    }

    if (runner.action_queue) |aq| {
        var msg_slice: ?[]u8 = null;
        if (res.message.len > 0) {
            const tmp: [*]const u8 = @ptrCast(res.message.ptr);
            msg_slice = @constCast(tmp)[0..res.message.len];
        }
        const act = Action{
            .id = job.id,
            .ctx = job.context,
            .success = res.success,
            .message = msg_slice,
        };
        aq.push(act) catch {
            if (job.callback) |cb| cb(job.id, job.context, res.success, res.message);
            if (msg_slice) |m| if (m.len > 0) runner.allocator.free(m);
        };
    } else {
        if (job.callback) |cb| cb(job.id, job.context, res.success, res.message);
        if (res.message.len > 0) runner.allocator.free(@constCast(res.message));
    }

    // Release leased state back to the pool
    runner.state_pool.?.release(leased_state.?);

    job.allocator.free(job.script);
    job.allocator.destroy(job);
}
