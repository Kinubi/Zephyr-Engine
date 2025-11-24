const std = @import("std");
const ScriptRunner = @import("../../scripting/script_runner.zig").ScriptRunner;
const ActionQueue = @import("../../scripting/action_queue.zig").ActionQueue;
const Action = @import("../../scripting/action_queue.zig").Action;
const World = @import("../world.zig").World;
const Scene = @import("../../scene/scene.zig").Scene;
const ScriptComponent = @import("../components/script.zig").ScriptComponent;
const ThreadPool = @import("../../threading/thread_pool.zig").ThreadPool;
const log = @import("../../utils/log.zig").log;
const lua = @import("../../scripting/lua_bindings.zig");
const cvar = @import("../../core/cvar.zig");
const ActionKind = @import("../../scripting/action_queue.zig").ActionKind;
const EntityId = @import("../entity_registry.zig").EntityId;

pub const NativeCallbackDescriptor = struct {
    cb: ?*const fn ([]const u8, []const u8, []const u8) void,
};

pub const ScriptingSystem = struct {
    allocator: std.mem.Allocator,
    thread_pool: *ThreadPool,
    runner: ScriptRunner,
    action_queue: *ActionQueue,

    /// Initialize the scripting system. caller must provide a ThreadPool pointer.
    pub fn init(allocator: std.mem.Allocator, tp: *ThreadPool, state_pool_size: usize) !ScriptingSystem {
        // Allocate the action queue on the global page allocator so it's
        // safe for worker threads to allocate/free messages into it.
        const aq_ptr = try std.heap.page_allocator.create(ActionQueue);
        aq_ptr.* = try ActionQueue.init(std.heap.page_allocator);
        var sys = ScriptingSystem{
            .allocator = allocator,
            .thread_pool = tp,
            .runner = try ScriptRunner.init(allocator, tp),
            .action_queue = aq_ptr,
        };

        // Pre-warm lua_State pool
        try sys.runner.setupLuaStatePool(state_pool_size);
        sys.runner.setResultQueue(sys.action_queue);

        return sys;
    }

    // Note: No instance `update` method; per-frame work is run via free function `update` below

    pub fn deinit(self: *ScriptingSystem) void {
        // Tear down runner and action queue
        self.runner.deinit();

        self.action_queue.deinit();
        std.heap.page_allocator.destroy(self.action_queue);
    }

    /// Enqueue a script to be executed on the thread pool. ctx is an opaque pointer
    /// that will be delivered with the Action; use null if not needed.
    pub fn runScript(self: *ScriptingSystem, script: []const u8, ctx: *anyopaque, owner: EntityId, scene_ptr: *anyopaque) !u64 {
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
pub fn prepare(world: *World, dt: f32) !void {
    _ = dt;
    // Scheduler wrapper: perform the per-frame scripting work directly (no call to
    // `update`) so the scheduler executes the system's logic inline. This mirrors
    // other scheduler functions which operate directly on Scene-owned state.
    const scene_ptr = world.getUserData("scene") orelse return;
    const scene: *Scene = @ptrCast(@alignCast(scene_ptr));

    // Use a local alias to the Scene-owned ScriptingSystem instance
    var sys: *ScriptingSystem = scene.scripting_system;

    // Process any pending CVar change events first so their Actions will be
    // available to be handled in the same frame. We allocate action messages
    // using the action_queue allocator so the existing drain code can free
    // them after processing.
    if (cvar.getGlobal()) |rp| {
        const reg: *cvar.CVarRegistry = @ptrCast(rp);
        const events = try reg.takePendingChanges(reg.allocator);
        defer reg.allocator.free(events);

        var ei: usize = 0;
        while (ei < events.len) : (ei += 1) {
            const ev = events[ei];

            if (reg.map.get(ev.name)) |cvp| {
                const cv = cvp.*;
                if (cv.on_change_lua.items.len > 0) {
                    // Build NUL-separated message: handler\0name\0old\0new
                    const hlen = cv.on_change_lua.items.len;
                    const nlen = ev.name.len;
                    const olen = ev.old.len;
                    const nlen2 = ev.new.len;
                    const total = hlen + 1 + nlen + 1 + olen + 1 + nlen2;
                    var msg_buf = try sys.action_queue.allocator.alloc(u8, total);
                    var off: usize = 0;
                    std.mem.copyForwards(u8, msg_buf[off .. off + hlen], cv.on_change_lua.items[0..hlen]);
                    off += hlen;
                    msg_buf[off] = 0;
                    off += 1;
                    if (nlen > 0) std.mem.copyForwards(u8, msg_buf[off .. off + nlen], ev.name);
                    off += nlen;
                    msg_buf[off] = 0;
                    off += 1;
                    if (olen > 0) std.mem.copyForwards(u8, msg_buf[off .. off + olen], ev.old);
                    off += olen;
                    msg_buf[off] = 0;
                    off += 1;
                    if (nlen2 > 0) std.mem.copyForwards(u8, msg_buf[off .. off + nlen2], ev.new);
                    off += nlen2;

                    const slice: []u8 = msg_buf[0..total];
                    const act = Action{ .id = 0, .kind = ActionKind.CVarLua, .ctx = @ptrCast(scene), .success = true, .message = slice };
                    sys.action_queue.push(act) catch {
                        sys.action_queue.allocator.free(slice);
                    };
                }
            }

            // Native on_change callbacks are not invoked here; they are disabled
            // in this build to avoid calling runtime function pointers across
            // module boundaries. If a native callback is registered it is
            // intentionally ignored.

            // Free event buffers allocated by the registry allocator
            if (ev.name.len > 0) reg.allocator.free(ev.name);
            if (ev.old.len > 0) reg.allocator.free(ev.old);
            if (ev.new.len > 0) reg.allocator.free(ev.new);
        }
    }

    // Drain the action queue non-blocking and process each action. Actions
    // with a NUL-separated payload are treated as CVAR on_change actions and
    // cause the named Lua handler to be invoked (using a leased lua_State).
    var drained_count: usize = 0;
    while (true) {
        const opt = sys.action_queue.tryPop();
        if (opt) |a| {
            switch (a.kind) {
                .ScriptResult => {
                    if (a.message) |m| {
                        const tmp: [*]const u8 = @ptrCast(m.ptr);
                        const msg_slice: []u8 = @constCast(tmp)[0..m.len];
                        if (msg_slice.len > 0) sys.action_queue.allocator.free(msg_slice);
                    }
                },
                .CVarLua => {
                    if (a.message) |m| {
                        const tmp: [*]const u8 = @ptrCast(m.ptr);
                        const msg_slice: []u8 = @constCast(tmp)[0..m.len];
                        // Parse four fields: handler, name, old, new
                        var p: usize = 0;
                        while (p < msg_slice.len and msg_slice[p] != 0) p += 1;
                        const handler = msg_slice[0..p];
                        p += 1;
                        var start = p;
                        while (p < msg_slice.len and msg_slice[p] != 0) p += 1;
                        const name_s = msg_slice[start..p];
                        p += 1;
                        start = p;
                        while (p < msg_slice.len and msg_slice[p] != 0) p += 1;
                        const old_s = msg_slice[start..p];
                        p += 1;
                        const new_s = if (p <= msg_slice.len) msg_slice[p..msg_slice.len] else "";

                        if (sys.runner.state_pool) |sp| {
                            const leased = sp.acquire();
                            if (lua.callNamedHandler(sys.runner.allocator, leased, handler, name_s, old_s, new_s)) |res| {
                                if (!res.success and res.message.len > 0) {
                                    const mp: [*]const u8 = @ptrCast(res.message.ptr);
                                    const msgstr: []const u8 = mp[0..res.message.len];
                                    log(.WARN, "scripting", "lua handler '{s}' failed: {s}", .{ handler, msgstr });
                                    sys.runner.allocator.free(res.message);
                                }
                            } else |err| {
                                log(.WARN, "scripting", "callNamedHandler failed: {}", .{err});
                            }
                            sp.release(leased);
                        } else {
                            log(.WARN, "scripting", "no lua state pool available to run cvar on_change handler", .{});
                        }

                        if (msg_slice.len > 0) sys.action_queue.allocator.free(msg_slice);
                    }
                },
                .CVarNative => {
                    if (a.message) |m| {
                        // We don't invoke native callbacks in this build; if a
                        // descriptor was attached, free it and free the message
                        if (a.ctx) |ctx_ptr| {
                            const desc: *NativeCallbackDescriptor = @ptrCast(@alignCast(ctx_ptr));
                            sys.action_queue.allocator.destroy(desc);
                        }
                        const tmp: [*]const u8 = @ptrCast(m.ptr);
                        const msg_slice: []u8 = @constCast(tmp)[0..m.len];
                        if (msg_slice.len > 0) sys.action_queue.allocator.free(msg_slice);
                    }
                },
            }
            drained_count += 1;
        } else break;
    }

    // Execute any ScriptComponent that requests per-frame execution
    var view = try world.view(ScriptComponent);
    var enqueued_count: usize = 0;
    const total_scripts = view.len();

    if (total_scripts < 2) {
        // For small numbers of per-frame scripts it's cheaper/simpler to run
        // them synchronously on the current thread to avoid thread pool
        // overhead and potential latency.
        var iter = view.iterator();
        while (iter.next()) |entry| {
            const sc = entry.component;
            if (!sc.enabled) continue;
            if (!sc.run_on_update) continue;

            if (sys.runner.state_pool) |sp| {
                const leased = sp.acquire();
                const owner_u32 = @intFromEnum(entry.entity);
                if (lua.executeLuaBuffer(sys.runner.allocator, leased, sc.script, owner_u32, @ptrCast(scene))) |res| {
                    if (res.message.len > 0) sys.runner.allocator.free(res.message);
                } else |err| {
                    log(.WARN, "scripting", "synchronous script execution failed: {}", .{err});
                }
                sp.release(leased);
            } else {
                log(.WARN, "scripting", "no lua state pool available to run per-frame script synchronously", .{});
            }
        }
    } else {
        var iter = view.iterator();
        while (iter.next()) |entry| {
            const sc = entry.component;
            if (!sc.enabled) continue;
            if (!sc.run_on_update) continue;

            // Enqueue per-frame ScriptComponent scripts as async jobs so they run
            // on the thread pool / state_pool instead of synchronously on the
            // system thread. This uses ScriptRunner.enqueueScript via runScript.
            _ = sys.runScript(sc.script, @ptrCast(sc), entry.entity, @ptrCast(scene)) catch {};
            enqueued_count += 1;
        }
    }
}
