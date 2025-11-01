const std = @import("std");
const ScriptRunner = @import("../../scripting/script_runner.zig").ScriptRunner;
const ActionQueue = @import("../../scripting/action_queue.zig").ActionQueue;
const World = @import("../world.zig").World;
const Scene = @import("../../scene/scene.zig").Scene;
const ScriptComponent = @import("../components/script.zig").ScriptComponent;
const ThreadPool = @import("../../threading/thread_pool.zig").ThreadPool;
const log = @import("../../utils/log.zig").log;
const lua = @import("../../scripting/lua_bindings.zig");

pub const ScriptingSystem = struct {
    allocator: std.mem.Allocator,
    thread_pool: *ThreadPool,
    runner: ScriptRunner,
    action_queue: ActionQueue,

    /// Initialize the scripting system. caller must provide a ThreadPool pointer.
    pub fn init(allocator: std.mem.Allocator, tp: *ThreadPool, state_pool_size: usize) !ScriptingSystem {
        var sys = ScriptingSystem{
            .allocator = allocator,
            .thread_pool = tp,
            .runner = try ScriptRunner.init(allocator, tp),
            .action_queue = try ActionQueue.init(allocator),
        };

        // Pre-warm lua_State pool
        try sys.runner.setupLuaStatePool(state_pool_size);
        sys.runner.setResultQueue(&sys.action_queue);

        return sys;
    }

    // Note: No instance `update` method; per-frame work is run via free function `update` below

    pub fn deinit(self: *ScriptingSystem) void {
        // Tear down runner and action queue
        self.runner.deinit();
        self.action_queue.deinit();
    }

    /// Enqueue a script to be executed on the thread pool. ctx is an opaque pointer
    /// that will be delivered with the Action; use null if not needed.
    pub fn runScript(self: *ScriptingSystem, script: []const u8, ctx: *anyopaque, owner: @import("../entity_registry.zig").EntityId, scene_ptr: *anyopaque) !u64 {
        return self.runner.enqueueScript(script, ctx, null, owner, scene_ptr);
    }

    // NOTE: The ScriptingSystem instance is owned by the Scene. Call the instance
    // `update` method (ScriptingSystem.update) from the Scene/SceneLayer where the
    // Scene instance is available. We intentionally do NOT store a global
    // `scripting_system` pointer in World.userdata to avoid global mutable state.

    /// Poll the action queue and run a user-provided handler for each action.
    pub fn pollActions(self: *ScriptingSystem, handler: fn (ActionQueue.Action) void) void {
        // Non-blocking pop until empty
        while (true) {
            const opt = self.action_queue.tryPop();
            if (opt) |a| {
                handler(a);
            } else return;
        }
    }
};

/// Static wrapper for use with SystemScheduler
/// Looks up the scene-owned ScriptingSystem instance from World.userdata
/// (key: "scripting_system") and invokes its instance update method.
pub fn update(world: *World, dt: f32) !void {
    _ = dt;
    // Scheduler wrapper: perform the per-frame scripting work directly (no call to
    // `update`) so the scheduler executes the system's logic inline. This mirrors
    // other scheduler functions which operate directly on Scene-owned state.
    const scene_ptr = world.getUserData("scene") orelse return;
    const scene: *Scene = @ptrCast(@alignCast(scene_ptr));

    // Use a local alias to the Scene-owned ScriptingSystem instance
    var sys: *ScriptingSystem = &scene.scripting_system;

    // Drain the action queue non-blocking and free any returned message by default.
    var drained_count: usize = 0;
    while (true) {
        const opt = sys.action_queue.tryPop();
        if (opt) |a| {
            if (a.message) |m| {
                if (m.len > 0) {
                    const tmp: [*]const u8 = @ptrCast(m.ptr);
                    const msg_slice: []u8 = @constCast(tmp)[0..m.len];
                    sys.action_queue.allocator.free(msg_slice);
                }
            }
            drained_count += 1;
        } else break;
    }

    // Execute any ScriptComponent that requests per-frame execution
    var view = try world.view(ScriptComponent);
    var iter = view.iterator();
    var enqueued_count: usize = 0;
    while (iter.next()) |entry| {
        const sc = entry.component;
        if (!sc.enabled) continue;
        if (!sc.run_on_update) continue;

        // If we have a state pool available, execute the script synchronously on
        // the main thread to allow scripts to safely mutate scene/ECS state.
        if (sys.runner.state_pool) |sp| {
            // Acquire a lua_State from the pool (blocks until available)
            const leased = sp.acquire();
            const owner_u32 = @intFromEnum(entry.entity);
            // Execute on main thread; pass scene pointer as user_ctx so bindings can access it
            var res: lua.ExecuteResult = lua.ExecuteResult{ .success = false, .message = "" };
            if (lua.executeLuaBuffer(sys.runner.allocator, leased, sc.script, owner_u32, @ptrCast(scene))) |v| {
                res = v;
            } else |err| {
                // Log and continue
                log(.WARN, "scripting", "synchronous executeLuaBuffer failed: {}", .{err});
            }

            // Release leased state
            sp.release(leased);
            enqueued_count += 1;
        } else {
            // Fallback to async enqueue if no state pool is available
            _ = sys.runScript(sc.script, @ptrCast(sc), entry.entity, @ptrCast(scene)) catch {};
            enqueued_count += 1;
        }

        if (sc.run_once) sc.enabled = false;
    }
}
