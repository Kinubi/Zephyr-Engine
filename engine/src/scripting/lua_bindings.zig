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
const cvar = @import("../core/cvar.zig");

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

/// Call a named global Lua function (no module lookup) with three string
/// arguments: (cvar_name, old, new). Allocates an error message via the
/// provided allocator on failure.
pub fn callNamedHandler(allocator: std.mem.Allocator, state: *anyopaque, handler: []const u8, name: []const u8, old: []const u8, new: []const u8) !ExecuteResult {
    const L: *c.lua_State = @ptrCast(state);
    // push function by global name
    const h_ptr_tmp: [*]const u8 = @ptrCast(handler.ptr);
    _ = c.lua_getglobal(L, h_ptr_tmp);
    // check it's callable
    if (!c.lua_isfunction(L, -1)) {
        // pop non-function
        _ = c.lua_settop(L, 0);
        return ExecuteResult{ .success = false, .message = "" };
    }

    // push args as strings
    const n_ptr_tmp: [*]const u8 = @ptrCast(name.ptr);
    _ = c.lua_pushlstring(L, n_ptr_tmp, name.len);
    const o_ptr_tmp: [*]const u8 = @ptrCast(old.ptr);
    _ = c.lua_pushlstring(L, o_ptr_tmp, old.len);
    const nn_ptr_tmp: [*]const u8 = @ptrCast(new.ptr);
    _ = c.lua_pushlstring(L, nn_ptr_tmp, new.len);

    const pcall_res = c.lua_pcallk(L, 3, 0, 0, @as(c.lua_KContext, 0), null);
    if (pcall_res != 0) {
        var msg_len: usize = 0;
        const msg = c.lua_tolstring(L, -1, &msg_len);
        if (msg == null) {
            _ = c.lua_settop(L, 0);
            return ExecuteResult{ .success = false, .message = "" };
        }
        const out = try allocator.alloc(u8, msg_len + 1);
        const msg_ptr2: [*]const u8 = @ptrCast(msg);
        std.mem.copyForwards(u8, out[0..msg_len], msg_ptr2[0..msg_len]);
        out[msg_len] = 0;
        _ = c.lua_settop(L, 0);
        return ExecuteResult{ .success = false, .message = out[0..msg_len] };
    }

    return ExecuteResult{ .success = true, .message = "" };
}

/// Execute a buffer as Lua code on the provided lua_State.
/// Allocates an error message using the provided allocator when there is an error.
pub fn executeLuaBuffer(allocator: std.mem.Allocator, state: *anyopaque, buf: []const u8, owner_entity: u32, user_ctx: ?*anyopaque) !ExecuteResult {
    const L: *c.lua_State = @ptrCast(state);

    // Preprocess simple assignment shorthands typed into the console.
    // Users sometimes type `RenderSystem.PathTracing = enable` expecting
    // `enable` to be interpreted as a boolean. Lua treats bare identifiers
    // as globals (often nil). To be friendly, detect a simple `lhs = rhs`
    // pattern where rhs is a bare word and map common tokens:
    //  - enable,on,yes,1 -> true
    //  - disable,off,no,0 -> false
    //  - otherwise wrap the bare word as a string literal.
    // This is conservative and only applies when rhs is a single word
    // containing letters/digits/underscores.
    var processed: ?[]u8 = null;
    var eq_idx: usize = buf.len;
    var i: usize = 0;
    while (i < buf.len) : (i += 1) {
        if (buf[i] == '=') {
            eq_idx = i;
            break;
        }
    }
    if (eq_idx != buf.len) {
        // split and trim
        const lhs = buf[0..eq_idx];
        var rhs = buf[eq_idx + 1 .. buf.len];
        // trim spaces on rhs
        var start: usize = 0;
        while (start < rhs.len and (rhs[start] == ' ' or rhs[start] == '\t')) start += 1;
        var end: usize = rhs.len;
        while (end > start and (rhs[end - 1] == ' ' or rhs[end - 1] == '\t')) end -= 1;
        const rhs_trim = rhs[start..end];
        if (rhs_trim.len > 0) {
            // check if bare word (letters/digits/_)
            var is_word: bool = true;
            var j: usize = 0;
            while (j < rhs_trim.len) : (j += 1) {
                const ch = rhs_trim[j];
                if (!((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or (ch == '_'))) {
                    is_word = false;
                    break;
                }
            }
            if (is_word) {
                // lower-case copy
                var tmp_word = try allocator.alloc(u8, rhs_trim.len + 1);
                var k: usize = 0;
                while (k < rhs_trim.len) : (k += 1) {
                    var ch = rhs_trim[k];
                    if (ch >= 'A' and ch <= 'Z') ch = ch + 32;
                    tmp_word[k] = ch;
                }
                tmp_word[rhs_trim.len] = 0;
                const word_ptr: [*]const u8 = @ptrCast(tmp_word);
                const word_slice: []const u8 = word_ptr[0..rhs_trim.len];
                var mapped: ?[]const u8 = null;
                // If the bare word is an explicit boolean literal, leave it as-is.
                if (std.mem.eql(u8, word_slice, "true") or std.mem.eql(u8, word_slice, "false")) {
                    mapped = word_slice;
                } else {
                    // If the first character of the trimmed RHS is a digit or a
                    // minus sign followed by a digit, treat it as a numeric token
                    // and leave unquoted so CVar inference can parse it as int/float.
                    const first = rhs_trim[0];
                    var looks_numeric: bool = false;
                    if (first >= '0' and first <= '9') {
                        looks_numeric = true;
                    } else if (first == '-' and rhs_trim.len > 1 and (rhs_trim[1] >= '0' and rhs_trim[1] <= '9')) {
                        looks_numeric = true;
                    }
                    if (looks_numeric) {
                        mapped = rhs_trim;
                    } else {
                        // Not a literal boolean or number: quote it so it becomes a string
                        const qlen = rhs_trim.len + 2;
                        var qbuf = try allocator.alloc(u8, qlen + 1);
                        qbuf[0] = '"';
                        std.mem.copyForwards(u8, qbuf[1 .. 1 + rhs_trim.len], rhs_trim);
                        qbuf[1 + rhs_trim.len] = '"';
                        qbuf[qlen] = 0;
                        processed = qbuf[0..qlen];
                    }
                }
                if (mapped) |m| {
                    // assemble new buffer: lhs + " = " + m
                    const sep = " = ";
                    const new_len = lhs.len + sep.len + m.len;
                    var out = try allocator.alloc(u8, new_len + 1);
                    std.mem.copyForwards(u8, out[0..lhs.len], lhs);
                    const sep_ptr: [*]const u8 = @ptrCast(sep.ptr);
                    std.mem.copyForwards(u8, out[lhs.len .. lhs.len + sep.len], sep_ptr[0..sep.len]);
                    std.mem.copyForwards(u8, out[lhs.len + sep.len .. lhs.len + sep.len + m.len], m);
                    out[new_len] = 0;
                    processed = out[0..new_len];
                }
                allocator.free(tmp_word);
            }
        }
    }

    // Lua's `luaL_loadbuffer` family can be a macro across Lua versions; to
    // avoid ABI differences, create a NUL-terminated copy and call
    // `luaL_loadstring` which is stable.
    const src_buf: []const u8 = if (processed) |p| p else buf;
    const tmp = try allocator.alloc(u8, src_buf.len + 1);
    std.mem.copyForwards(u8, tmp[0..src_buf.len], src_buf);
    tmp[src_buf.len] = 0;
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

    var load_res = c.luaL_loadstring(L, tmp_ptr);
    if (load_res != 0) {
        // If the user typed a bare expression like `a.b.c`, Lua's
        // `luaL_loadstring` treats that as a syntax error (expression
        // is not a statement). The REPL usually prints such expressions
        // by wrapping them in a `return` or `print` call. Try to detect
        // that case and retry as `return <expr>` so the console prints
        // the value.
        var msg_len: usize = 0;
        const msg = c.lua_tolstring(L, -1, &msg_len);
        if (msg != null) {
            const msg_ptr: [*]const u8 = @ptrCast(msg);
            // look for '<eof>' marker in the error message
            const eof_marker: []const u8 = "<eof>";
            if (std.mem.indexOf(u8, msg_ptr[0..msg_len], eof_marker) != null) {
                // allocate 'return ' + original buffer + NUL
                const prefix = "return ";
                const expr_len = prefix.len + buf.len;
                const expr_tmp = try allocator.alloc(u8, expr_len + 1);
                const prefix_ptr: [*]const u8 = @ptrCast(prefix.ptr);
                std.mem.copyForwards(u8, expr_tmp[0..prefix.len], prefix_ptr[0..prefix.len]);
                std.mem.copyForwards(u8, expr_tmp[prefix.len .. prefix.len + buf.len], tmp[0..buf.len]);
                expr_tmp[expr_len] = 0;
                const expr_ptr: [*]const u8 = @ptrCast(expr_tmp);
                // clear the previous error message
                _ = c.lua_settop(L, 0);
                load_res = c.luaL_loadstring(L, expr_ptr);
                // free expr_tmp after use
                allocator.free(expr_tmp);
                if (load_res == 0) {
                    // successfully loaded the 'return <expr>' chunk; continue to pcall below
                } else {
                    // fall through to reporting original error
                }
            }
        }

        if (load_res != 0) {
            if (msg == null) {
                _ = c.lua_settop(L, 0);
                return ExecuteResult{ .success = false, .message = "" };
            }
            // allocate +1 so we can NUL-terminate the copied message for safety
            const out = try allocator.alloc(u8, msg_len + 1);
            const msg_ptr2: [*]const u8 = @ptrCast(msg);
            std.mem.copyForwards(u8, out[0..msg_len], msg_ptr2[0..msg_len]);
            out[msg_len] = 0;
            // Pop the error message from the stack so it doesn't remain for
            // subsequent calls.
            _ = c.lua_settop(L, 0);
            return ExecuteResult{ .success = false, .message = out[0..msg_len] };
        }
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

    // Expose a namespaced proxy table for CVars so Lua can use
    // `RenderSystem.PathTracing.RayCount` syntax for get/set.
    pushCVarNamespace(L, "RenderSystem");

    // Expose `cvar` helper table with listing and convenience functions
    c.lua_newtable(L);
    c.lua_pushcfunction(L, l_cvar_get);
    c.lua_setfield(L, -2, "get");
    c.lua_pushcfunction(L, l_cvar_set);
    c.lua_setfield(L, -2, "set");
    c.lua_pushcfunction(L, l_cvar_toggle);
    c.lua_setfield(L, -2, "toggle");
    c.lua_pushcfunction(L, l_cvar_reset);
    c.lua_setfield(L, -2, "reset");
    c.lua_pushcfunction(L, l_cvar_help);
    c.lua_setfield(L, -2, "help");
    c.lua_pushcfunction(L, l_cvar_list);
    c.lua_setfield(L, -2, "list");
    c.lua_pushcfunction(L, l_cvar_archive);
    c.lua_setfield(L, -2, "archive");
    // cvar.on_change(name, handler_name)
    c.lua_pushcfunction(L, l_cvar_on_change);
    c.lua_setfield(L, -2, "on_change");
    c.lua_setglobal(L, "cvar");
}

// Create a proxy table for a namespaced CVar root (e.g. "RenderSystem").
fn pushCVarNamespace(L: *c.lua_State, ns: []const u8) void {
    // table
    c.lua_newtable(L);
    // metatable
    c.lua_newtable(L);
    // set metatable.ns = ns
    const ns_ptr_tmp: [*]const u8 = @ptrCast(ns.ptr);
    _ = c.lua_pushlstring(L, ns_ptr_tmp, ns.len);
    c.lua_setfield(L, -2, "ns");
    // __index and __newindex
    c.lua_pushcfunction(L, l_cvar_namespace_index);
    c.lua_setfield(L, -2, "__index");
    c.lua_pushcfunction(L, l_cvar_namespace_newindex);
    c.lua_setfield(L, -2, "__newindex");
    // attach metatable to table
    _ = c.lua_setmetatable(L, -2);
    // set global name
    c.lua_setglobal(L, "RenderSystem");
}

fn l_cvar_namespace_index(L: ?*c.lua_State) callconv(.c) c_int {
    const Lnon = L orelse return 0;
    var key_len: usize = 0;
    const key = c.luaL_checklstring(Lnon, 2, &key_len);
    if (key == null) {
        _ = c.lua_pushnil(Lnon);
        return 1;
    }
    const key_ptr: [*]const u8 = @ptrCast(key);

    // get metatable and its ns field
    if (c.lua_getmetatable(Lnon, 1) == 0) {
        _ = c.lua_pushnil(Lnon);
        return 1;
    }
    _ = c.lua_getfield(Lnon, -1, "ns");
    var ns_len: usize = 0;
    const ns = c.lua_tolstring(Lnon, -1, &ns_len);
    if (ns == null) {
        _ = c.lua_pushnil(Lnon);
        return 1;
    }
    const ns_ptr: [*]const u8 = @ptrCast(ns);

    // Build fullname = ns + "." + key on stack buffer
    var buf: [1024]u8 = undefined;
    if (ns_len + 1 + key_len > buf.len) {
        _ = c.lua_pushnil(Lnon);
        return 1;
    }
    std.mem.copyForwards(u8, buf[0..ns_len], ns_ptr[0..ns_len]);
    buf[ns_len] = '.';
    std.mem.copyForwards(u8, buf[ns_len + 1 .. ns_len + 1 + key_len], key_ptr[0..key_len]);
    const full_len = ns_len + 1 + key_len;

    const reg = cvar.ensureGlobal(std.heap.page_allocator) catch {
        _ = c.lua_pushnil(Lnon);
        return 1;
    };
    var val_opt: ?[]u8 = null;
    if (reg.getAsStringAlloc(buf[0..full_len], std.heap.page_allocator)) |v| {
        val_opt = v;
    } else {
        val_opt = null;
    }
    if (val_opt) |v| {
        const v_ptr_tmp: [*]const u8 = @ptrCast(v);
        _ = c.lua_pushlstring(Lnon, v_ptr_tmp, v.len);
        std.heap.page_allocator.free(v);
        return 1;
    }

    // Not a leaf cvar — return a new proxy table representing the nested namespace
    c.lua_newtable(Lnon);
    c.lua_newtable(Lnon);
    const buf_ptr_tmp: [*]const u8 = @ptrCast(&buf[0]);
    _ = c.lua_pushlstring(Lnon, buf_ptr_tmp, full_len);
    c.lua_setfield(Lnon, -2, "ns");
    c.lua_pushcfunction(Lnon, l_cvar_namespace_index);
    c.lua_setfield(Lnon, -2, "__index");
    c.lua_pushcfunction(Lnon, l_cvar_namespace_newindex);
    c.lua_setfield(Lnon, -2, "__newindex");
    _ = c.lua_setmetatable(Lnon, -2);
    return 1;
}

fn l_cvar_namespace_newindex(L: ?*c.lua_State) callconv(.c) c_int {
    const Lnon = L orelse return 0;
    var key_len: usize = 0;
    const key = c.luaL_checklstring(Lnon, 2, &key_len);
    if (key == null) return 0;
    const key_ptr: [*]const u8 = @ptrCast(key);

    if (c.lua_getmetatable(Lnon, 1) == 0) return 0;
    _ = c.lua_getfield(Lnon, -1, "ns");
    var ns_len: usize = 0;
    const ns = c.lua_tolstring(Lnon, -1, &ns_len);
    if (ns == null) return 0;
    const ns_ptr: [*]const u8 = @ptrCast(ns);

    var buf: [1024]u8 = undefined;
    if (ns_len + 1 + key_len > buf.len) return 0;
    std.mem.copyForwards(u8, buf[0..ns_len], ns_ptr[0..ns_len]);
    buf[ns_len] = '.';
    std.mem.copyForwards(u8, buf[ns_len + 1 .. ns_len + 1 + key_len], key_ptr[0..key_len]);
    const full_len = ns_len + 1 + key_len;

    // Convert value at index 3 to string using luaL_tolstring
    var val_len: usize = 0;
    const vptr = c.luaL_tolstring(Lnon, 3, &val_len);
    if (vptr == null) return 0;
    const vptr_cast: [*]const u8 = @ptrCast(vptr);

    const reg = cvar.ensureGlobal(std.heap.page_allocator) catch {
        return 0;
    };
    reg.setFromString(buf[0..full_len], vptr_cast[0..val_len]) catch {};

    // pop the string produced by luaL_tolstring
    const top = c.lua_gettop(Lnon);
    _ = c.lua_settop(Lnon, top - 1);
    return 0;
}

// Lua helper: cvar.list()
fn l_cvar_list(L: ?*c.lua_State) callconv(.c) c_int {
    const Lnon = L orelse return 0;
    if (cvar.getGlobal()) |rp| {
        const reg_ptr_mut: *cvar.CVarRegistry = @ptrCast(rp);
        const list = reg_ptr_mut.listAllAlloc(std.heap.page_allocator) catch {
            _ = c.lua_pushnil(Lnon);
            return 1;
        };
        // Push a new table and fill with names
        c.lua_newtable(Lnon);
        var i: usize = 0;
        while (i < list.len) : (i += 1) {
            const s = list[i];
            const s_ptr: [*]const u8 = @ptrCast(s.ptr);
            _ = c.lua_pushlstring(Lnon, s_ptr, s.len);
            // lua_rawseti expects an integer index
            _ = c.lua_rawseti(Lnon, -2, @as(c.lua_Integer, @intCast(i + 1)));
        }
        std.heap.page_allocator.free(list);
        return 1;
    } else {
        _ = c.lua_pushnil(Lnon);
        return 1;
    }
}

// Lua helper: cvar.get(name)
fn l_cvar_get(L: ?*c.lua_State) callconv(.c) c_int {
    const Lnon = L orelse return 0;
    var name_len: usize = 0;
    const name = c.luaL_checklstring(Lnon, 1, &name_len);
    if (name == null) {
        _ = c.lua_pushnil(Lnon);
        return 1;
    }
    const name_ptr: [*]const u8 = @ptrCast(name);
    if (cvar.getGlobal()) |rp| {
        const reg: *cvar.CVarRegistry = @ptrCast(rp);
        if (reg.getAsStringAlloc(name_ptr[0..name_len], std.heap.page_allocator)) |v| {
            const vptr: [*]const u8 = @ptrCast(v);
            _ = c.lua_pushlstring(Lnon, vptr, v.len);
            std.heap.page_allocator.free(v);
            return 1;
        }
    }
    _ = c.lua_pushnil(Lnon);
    return 1;
}

// Lua helper: cvar.set(name, value) -> bool
fn l_cvar_set(L: ?*c.lua_State) callconv(.c) c_int {
    const Lnon = L orelse return 0;
    var name_len: usize = 0;
    const name = c.luaL_checklstring(Lnon, 1, &name_len);
    var val_len: usize = 0;
    const val = c.luaL_checklstring(Lnon, 2, &val_len);
    if (name == null or val == null) {
        _ = c.lua_pushboolean(Lnon, 0);
        return 1;
    }
    const name_ptr: [*]const u8 = @ptrCast(name);
    const val_ptr: [*]const u8 = @ptrCast(val);
    if (cvar.getGlobal()) |rp| {
        const reg: *cvar.CVarRegistry = @ptrCast(rp);
        reg.setFromString(name_ptr[0..name_len], val_ptr[0..val_len]) catch {
            _ = c.lua_pushboolean(Lnon, 0);
            return 1;
        };
        _ = c.lua_pushboolean(Lnon, 1);
        return 1;
    }
    _ = c.lua_pushboolean(Lnon, 0);
    return 1;
}

// Lua helper: cvar.toggle(name) -> new_value_string or nil
fn l_cvar_toggle(L: ?*c.lua_State) callconv(.c) c_int {
    const Lnon = L orelse return 0;
    var name_len: usize = 0;
    const name = c.luaL_checklstring(Lnon, 1, &name_len);
    if (name == null) {
        _ = c.lua_pushnil(Lnon);
        return 1;
    }
    const name_ptr: [*]const u8 = @ptrCast(name);
    if (cvar.getGlobal()) |rp| {
        const reg: *cvar.CVarRegistry = @ptrCast(rp);
        if (reg.getAsStringAlloc(name_ptr[0..name_len], std.heap.page_allocator)) |v| {
            var newv: []const u8 = "true";
            if (std.mem.eql(u8, v, "true")) {
                newv = "false";
            } else if (std.mem.eql(u8, v, "false")) {
                newv = "true";
            } else {
                // if not boolean, set to "true"
                newv = "true";
            }
            std.heap.page_allocator.free(v);
            reg.setFromString(name_ptr[0..name_len], newv) catch {};
            const nv_ptr: [*]const u8 = @ptrCast(newv);
            _ = c.lua_pushlstring(Lnon, nv_ptr, newv.len);
            return 1;
        }
    }
    _ = c.lua_pushnil(Lnon);
    return 1;
}

// Lua helper: cvar.reset(name) -> bool
fn l_cvar_reset(L: ?*c.lua_State) callconv(.c) c_int {
    const Lnon = L orelse return 0;
    var name_len: usize = 0;
    const name = c.luaL_checklstring(Lnon, 1, &name_len);
    if (name == null) {
        _ = c.lua_pushboolean(Lnon, 0);
        return 1;
    }
    const name_ptr: [*]const u8 = @ptrCast(name);
    if (cvar.getGlobal()) |rp| {
        const reg: *cvar.CVarRegistry = @ptrCast(rp);
        const ok = reg.reset(name_ptr[0..name_len]) catch false;
        _ = c.lua_pushboolean(Lnon, if (ok) 1 else 0);
        return 1;
    }
    _ = c.lua_pushboolean(Lnon, 0);
    return 1;
}

// Lua helper: cvar.help(name) -> nil (not implemented yet)
fn l_cvar_help(L: ?*c.lua_State) callconv(.c) c_int {
    const Lnon = L orelse return 0;
    // We don't have metadata/descriptions yet — return nil
    _ = c.lua_pushnil(Lnon);
    return 1;
}

// Lua helper: cvar.archive(name, bool) -> bool
fn l_cvar_archive(L: ?*c.lua_State) callconv(.c) c_int {
    const Lnon = L orelse return 0;
    var name_len: usize = 0;
    const name = c.luaL_checklstring(Lnon, 1, &name_len);
    if (name == null) {
        _ = c.lua_pushboolean(Lnon, 0);
        return 1;
    }
    const b = c.lua_toboolean(Lnon, 2);
    const name_ptr: [*]const u8 = @ptrCast(name);
    if (cvar.getGlobal()) |rp| {
        const reg: *cvar.CVarRegistry = @ptrCast(rp);
        const ok = reg.setArchived(name_ptr[0..name_len], b != 0) catch false;
        _ = c.lua_pushboolean(Lnon, if (ok) 1 else 0);
        return 1;
    }
    _ = c.lua_pushboolean(Lnon, 0);
    return 1;
}

// Lua helper: cvar.on_change(name, handler_name)
fn l_cvar_on_change(L: ?*c.lua_State) callconv(.c) c_int {
    const Lnon = L orelse return 0;
    var name_len: usize = 0;
    const name = c.luaL_checklstring(Lnon, 1, &name_len);
    if (name == null) {
        c.lua_pushboolean(Lnon, 0);
        return 1;
    }
    var handler_len: usize = 0;
    const handler = c.luaL_checklstring(Lnon, 2, &handler_len);
    if (handler == null) {
        c.lua_pushboolean(Lnon, 0);
        return 1;
    }

    const name_ptr: [*]const u8 = @ptrCast(name);
    const handler_ptr: [*]const u8 = @ptrCast(handler);

    const reg = cvar.getGlobal() orelse {
        c.lua_pushboolean(Lnon, 0);
        return 1;
    };

    const ok = reg.setLuaOnChange(name_ptr[0..name_len], handler_ptr[0..handler_len]) catch false;
    c.lua_pushboolean(Lnon, if (ok) 1 else 0);
    return 1;
}
