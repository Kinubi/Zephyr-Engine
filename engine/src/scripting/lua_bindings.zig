const std = @import("std");
const log = @import("../utils/log.zig").log;

const c = @cImport({
    @cInclude("lua.h");
    @cInclude("lauxlib.h");
    @cInclude("lualib.h");
    @cInclude("string.h");
});

const Scene = @import("../scene/scene.zig").Scene;
const ecs = @import("../ecs.zig");
const Transform = ecs.Transform;
const Math = @import("../utils/math.zig");
const Vec3 = Math.Vec3;
const EntityId = @import("../ecs/entity_registry.zig").EntityId;

/// Create a new lua_State. Returns null on failure.
pub fn createLuaState(_: std.mem.Allocator) ?*anyopaque {
    // We accept the allocator by value to match StatePool.CreateFn signature.
    // The Lua C API doesn't need the allocator, but we keep the parameter so
    // it can be used later if we need to attach allocator-backed userdata.
    const L = c.luaL_newstate();
    if (L == null) return null;
    c.luaL_openlibs(L);
    // Register minimal engine bindings
    registerEngineBindings(L.?);
    const out: *anyopaque = @ptrCast(L);
    return out;
}

/// Destroy a lua_State created with createLuaState
pub fn destroyLuaState(ptr: *anyopaque) void {
    const L: *c.lua_State = @ptrCast(ptr);
    c.lua_close(L);
}

pub const ExecuteResult = struct {
    success: bool,
    message: []const u8,
};

/// Execute a buffer as Lua code on the provided lua_State.
/// Allocates an error message using the provided allocator when there is an error.
pub fn executeLuaBuffer(allocator: std.mem.Allocator, state: *anyopaque, buf: []const u8, owner_entity: u32, user_ctx: ?*anyopaque) !ExecuteResult {
    const L: *c.lua_State = @ptrCast(state);

    // Lua's `luaL_loadbuffer` family can be a macro across Lua versions; to
    // avoid ABI differences, create a NUL-terminated copy and call
    // `luaL_loadstring` which is stable.
    const tmp = try allocator.alloc(u8, buf.len + 1);
    std.mem.copyForwards(u8, tmp[0..buf.len], buf);
    tmp[buf.len] = 0;
    defer allocator.free(tmp);

    const tmp_ptr: [*]const u8 = @ptrCast(tmp);

    // If an owner entity was provided (non-zero), expose it as a Lua integer
    // global named `entity_id`. Using an integer avoids lightuserdata pointer
    // lifetime issues when scripts might stash pointers.
    if (owner_entity != 0) {
        _ = c.lua_pushinteger(L, @as(c.lua_Integer, owner_entity));
        _ = c.lua_setglobal(L, "entity_id");
    }

    // If a user-provided context pointer was given, expose it as lightuserdata
    if (user_ctx) |ctx| {
        c.lua_pushlightuserdata(L, ctx);
        c.lua_setglobal(L, "zephyr_user_ctx");
    }

    const load_res = c.luaL_loadstring(L, tmp_ptr);
    if (load_res != 0) {
        var msg_len: usize = 0;
        const msg = c.lua_tolstring(L, -1, &msg_len);
        if (msg == null) {
            // Clear any leftover stack items to avoid leaking errors into
            // subsequent executions.
            _ = c.lua_settop(L, 0);
            return ExecuteResult{ .success = false, .message = "" };
        }
        // allocate +1 so we can NUL-terminate the copied message for safety
        const out = try allocator.alloc(u8, msg_len + 1);
        const msg_ptr: [*]const u8 = @ptrCast(msg);
        std.mem.copyForwards(u8, out[0..msg_len], msg_ptr[0..msg_len]);
        out[msg_len] = 0;
        // Pop the error message from the stack so it doesn't remain for
        // subsequent calls.
        _ = c.lua_settop(L, 0);
        return ExecuteResult{ .success = false, .message = out[0..msg_len] };
    }

    // pcall
    const pcall_res = c.lua_pcallk(L, 0, c.LUA_MULTRET, 0, @as(c.lua_KContext, 0), null);
    if (pcall_res != 0) {
        var msg_len2: usize = 0;
        const msg = c.lua_tolstring(L, -1, &msg_len2);
        if (msg == null) {
            _ = c.lua_settop(L, 0);
            return ExecuteResult{ .success = false, .message = "" };
        }
        const out = try allocator.alloc(u8, msg_len2 + 1);
        const msg_ptr2: [*]const u8 = @ptrCast(msg);
        std.mem.copyForwards(u8, out[0..msg_len2], msg_ptr2[0..msg_len2]);
        out[msg_len2] = 0;
        // Clear the stack so the error string doesn't persist.
        _ = c.lua_settop(L, 0);
        return ExecuteResult{ .success = false, .message = out[0..msg_len2] };
    }

    // If the chunk returned values, convert the top-most return value to a
    // string and return it as the message so callers can observe return values.
    const ret_count = c.lua_gettop(L);
    if (ret_count > 0) {
        var msg_len3: usize = 0;
        const msg = c.lua_tolstring(L, -1, &msg_len3);
        if (msg == null) {
            _ = c.lua_settop(L, 0);
            return ExecuteResult{ .success = true, .message = "" };
        }
        const out = try allocator.alloc(u8, msg_len3 + 1);
        const msg_ptr3: [*]const u8 = @ptrCast(msg);
        std.mem.copyForwards(u8, out[0..msg_len3], msg_ptr3[0..msg_len3]);
        out[msg_len3] = 0;
        // Pop any return values to leave the lua_State clean for the next call.
        _ = c.lua_settop(L, 0);
        return ExecuteResult{ .success = true, .message = out[0..msg_len3] };
    }

    return ExecuteResult{ .success = true, .message = "" };
}

// -----------------------
// Engine Lua bindings
// -----------------------

/// C-callable function: engine_log(msg)
/// Also used to override the global `print` to route through engine logging.
fn l_engine_log(L: ?*c.lua_State) callconv(.c) c_int {
    const Lnon = L orelse return 0;
    var len: usize = 0;
    const s = c.luaL_checklstring(Lnon, 1, &len);
    if (s != null) {
        const ptr: [*]const u8 = @ptrCast(s);
        const msg: []const u8 = ptr[0..@intCast(len)];
        log(.INFO, "lua", "{s}", .{msg});
    }
    return 0;
}

/// Translate the owning entity by dx,dy,dz.
fn l_translate_entity(L: ?*c.lua_State) callconv(.c) c_int {
    const Lnon = L orelse return 0;
    // Expect three numeric args: dx, dy, dz
    const dx = c.luaL_checknumber(Lnon, 1);
    const dy = c.luaL_checknumber(Lnon, 2);
    const dz = c.luaL_checknumber(Lnon, 3);

    // Retrieve owning entity id from global `entity_id`
    _ = c.lua_getglobal(Lnon, "entity_id");
    const ent_i = c.luaL_checkinteger(Lnon, -1);
    const ent_u32: u32 = @as(u32, @intCast(ent_i));

    // Retrieve scene pointer from global `zephyr_user_ctx`
    _ = c.lua_getglobal(Lnon, "zephyr_user_ctx");
    const scene_ptr_any = c.lua_touserdata(Lnon, -1);
    if (scene_ptr_any == null) return 0;
    const scene: *Scene = @ptrCast(@alignCast(scene_ptr_any.?));

    // Convert to EntityId and perform transform translate
    const ent: EntityId = @enumFromInt(ent_u32);

    if (scene.ecs_world.get(Transform, ent)) |t| {
        // Translate by vector
        const delta = Vec3.init(@floatCast(dx), @floatCast(dy), @floatCast(dz));
        t.translate(delta);
    }

    return 0; // no return values
}

fn l_engine_entity(L: ?*c.lua_State) callconv(.c) c_int {
    const Lnon = L orelse return 0;
    const id = c.luaL_checkinteger(Lnon, 1);
    const ent_u32: u32 = @as(u32, @intCast(id));
    // Allocate userdata to hold u32 entity id
    const p = c.lua_newuserdata(Lnon, @as(usize, @sizeOf(u32)));
    if (p == null) return 0;
    const ud_ptr: *u32 = @ptrCast(@alignCast(p));
    ud_ptr.* = ent_u32;
    // Set metatable
    _ = c.luaL_setmetatable(Lnon, "ZephyrEntity");
    return 1; // userdata on stack
}

fn registerEngineBindings(L: *c.lua_State) void {
    // engine_log(msg)
    c.lua_pushcfunction(L, l_engine_log);
    c.lua_setglobal(L, "engine_log");
    // Override print with engine_log for convenience
    c.lua_pushcfunction(L, l_engine_log);
    c.lua_setglobal(L, "print");
    // Entity helpers
    c.lua_pushcfunction(L, l_translate_entity);
    c.lua_setglobal(L, "translate_entity");
}
