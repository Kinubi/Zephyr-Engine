const std = @import("std");

const c = @cImport({
    @cInclude("lua.h");
    @cInclude("lauxlib.h");
    @cInclude("lualib.h");
    @cInclude("string.h");
});

/// Create a new lua_State. Returns null on failure.
pub fn createLuaState(_: std.mem.Allocator) ?*anyopaque {
    // We accept the allocator by value to match StatePool.CreateFn signature.
    // The Lua C API doesn't need the allocator, but we keep the parameter so
    // it can be used later if we need to attach allocator-backed userdata.
    const L = c.luaL_newstate();
    if (L == null) return null;
    c.luaL_openlibs(L);
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
pub fn executeLuaBuffer(allocator: std.mem.Allocator, state: *anyopaque, buf: []const u8) !ExecuteResult {
    const L: *c.lua_State = @ptrCast(state);

    // Lua's `luaL_loadbuffer` family can be a macro across Lua versions; to
    // avoid ABI differences, create a NUL-terminated copy and call
    // `luaL_loadstring` which is stable.
    const tmp = try allocator.alloc(u8, buf.len + 1);
    std.mem.copyForwards(u8, tmp[0..buf.len], buf);
    tmp[buf.len] = 0;
    defer allocator.free(tmp);

    const tmp_ptr: [*]const u8 = @ptrCast(tmp);
    const load_res = c.luaL_loadstring(L, tmp_ptr);
    if (load_res != 0) {
        const msg = c.lua_tolstring(L, -1, null);
        if (msg == null) {
            return ExecuteResult{ .success = false, .message = "" };
        }
        const len = c.strlen(msg);
        // allocate +1 so we can NUL-terminate the copied message for safety
        const out = try allocator.alloc(u8, len + 1);
        const msg_ptr: [*]const u8 = @ptrCast(msg);
        std.mem.copyForwards(u8, out[0..len], msg_ptr[0..len]);
        out[len] = 0;
        return ExecuteResult{ .success = false, .message = out[0..len] };
    }

    // pcall
    const pcall_res = c.lua_pcallk(L, 0, c.LUA_MULTRET, 0, @as(c.lua_KContext, 0), null);
    if (pcall_res != 0) {
        const msg = c.lua_tolstring(L, -1, null);
        if (msg == null) {
            return ExecuteResult{ .success = false, .message = "" };
        }
        const len = c.strlen(msg);
        const out = try allocator.alloc(u8, len + 1);
        const msg_ptr2: [*]const u8 = @ptrCast(msg);
        std.mem.copyForwards(u8, out[0..len], msg_ptr2[0..len]);
        out[len] = 0;
        return ExecuteResult{ .success = false, .message = out[0..len] };
    }

    return ExecuteResult{ .success = true, .message = "" };
}
