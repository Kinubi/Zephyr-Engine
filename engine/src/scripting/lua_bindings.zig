const std = @import("std");
const log = @import("../utils/log.zig").log;

const c = @cImport({
    @cInclude("lua.h");
    @cInclude("lauxlib.h");
    @cInclude("lualib.h");
    @cInclude("string.h");
    @cInclude("GLFW/glfw3.h");
});

const Scene = @import("../scene/scene.zig").Scene;
const ecs = @import("../ecs.zig");
const Transform = ecs.Transform;
const PointLight = ecs.PointLight;
const ParticleEmitter = ecs.ParticleEmitter;
const Name = ecs.Name;
const RigidBody = @import("../ecs/components/physics_components.zig").RigidBody;
const Math = @import("../utils/math.zig");
const Vec3 = Math.Vec3;
const Quat = Math.Quat;
const EntityId = @import("../ecs/entity_registry.zig").EntityId;
const cvar = @import("../core/cvar.zig");
const zphysics = @import("zphysics");

// =============================================================================
// Global Script Context (set per-frame by ScriptingSystem)
// =============================================================================
pub var g_delta_time: f32 = 0.0;
pub var g_time_since_start: f64 = 0.0;
pub var g_frame_count: u64 = 0;
pub var g_glfw_window: ?*anyopaque = null; // For input queries

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

    // Register the comprehensive zephyr.* API
    registerZephyrAPI(L);
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

// =============================================================================
// ZEPHYR SCRIPTING API
// =============================================================================

// Helper to get Scene pointer from Lua global
fn getSceneFromLua(L: *c.lua_State) ?*Scene {
    _ = c.lua_getglobal(L, "zephyr_user_ctx");
    const ptr = c.lua_touserdata(L, -1);
    c.lua_pop(L, 1);
    if (ptr == null) return null;
    return @ptrCast(@alignCast(ptr.?));
}

// Helper to get entity ID from Lua (accepts integer or userdata)
fn getEntityFromArg(L: *c.lua_State, idx: c_int) ?EntityId {
    if (c.lua_isinteger(L, idx) != 0) {
        var is_num: c_int = 0;
        const id = c.lua_tointegerx(L, idx, &is_num);
        return @enumFromInt(@as(u32, @intCast(id)));
    } else if (c.lua_isuserdata(L, idx) != 0) {
        const p = c.lua_touserdata(L, idx);
        if (p) |ptr| {
            const ud: *u32 = @ptrCast(@alignCast(ptr));
            return @enumFromInt(ud.*);
        }
    }
    return null;
}

// -----------------------------------------------------------------------------
// Entity API: zephyr.entity.*
// -----------------------------------------------------------------------------

/// zephyr.entity.create() -> entity_id
fn l_entity_create(L: ?*c.lua_State) callconv(.c) c_int {
    const Lnon = L orelse return 0;
    const scene = getSceneFromLua(Lnon) orelse {
        c.lua_pushnil(Lnon);
        return 1;
    };

    const game_object = scene.spawnEmpty(null) catch {
        c.lua_pushnil(Lnon);
        return 1;
    };

    c.lua_pushinteger(Lnon, @intCast(@intFromEnum(game_object.entity_id)));
    return 1;
}

/// zephyr.entity.destroy(entity_id)
fn l_entity_destroy(L: ?*c.lua_State) callconv(.c) c_int {
    const Lnon = L orelse return 0;
    const scene = getSceneFromLua(Lnon) orelse return 0;
    const entity = getEntityFromArg(Lnon, 1) orelse return 0;

    scene.ecs_world.destroyEntity(entity);
    return 0;
}

/// zephyr.entity.exists(entity_id) -> bool
fn l_entity_exists(L: ?*c.lua_State) callconv(.c) c_int {
    const Lnon = L orelse return 0;
    const scene = getSceneFromLua(Lnon) orelse {
        c.lua_pushboolean(Lnon, 0);
        return 1;
    };
    const entity = getEntityFromArg(Lnon, 1) orelse {
        c.lua_pushboolean(Lnon, 0);
        return 1;
    };

    const exists = scene.ecs_world.isValid(entity);
    c.lua_pushboolean(Lnon, if (exists) 1 else 0);
    return 1;
}

/// zephyr.entity.get_name(entity_id) -> string or nil
fn l_entity_get_name(L: ?*c.lua_State) callconv(.c) c_int {
    const Lnon = L orelse return 0;
    const scene = getSceneFromLua(Lnon) orelse {
        c.lua_pushnil(Lnon);
        return 1;
    };
    const entity = getEntityFromArg(Lnon, 1) orelse {
        c.lua_pushnil(Lnon);
        return 1;
    };

    if (scene.ecs_world.getConst(Name, entity)) |name| {
        const ptr: [*]const u8 = @ptrCast(name.name.ptr);
        _ = c.lua_pushlstring(Lnon, ptr, name.name.len);
        return 1;
    }
    c.lua_pushnil(Lnon);
    return 1;
}

/// zephyr.entity.set_name(entity_id, name)
fn l_entity_set_name(L: ?*c.lua_State) callconv(.c) c_int {
    const Lnon = L orelse return 0;
    const scene = getSceneFromLua(Lnon) orelse return 0;
    const entity = getEntityFromArg(Lnon, 1) orelse return 0;

    var name_len: usize = 0;
    const name_str = c.luaL_checklstring(Lnon, 2, &name_len);
    if (name_str == null) return 0;

    const name_ptr: [*]const u8 = @ptrCast(name_str);
    const name_comp = Name.init(scene.allocator, name_ptr[0..name_len]) catch return 0;

    // Remove old name if exists, then add new
    _ = scene.ecs_world.remove(Name, entity);
    scene.ecs_world.emplace(Name, entity, name_comp) catch {};
    return 0;
}

/// zephyr.entity.find(name) -> entity_id or nil
fn l_entity_find(L: ?*c.lua_State) callconv(.c) c_int {
    const Lnon = L orelse return 0;
    const scene = getSceneFromLua(Lnon) orelse {
        c.lua_pushnil(Lnon);
        return 1;
    };

    var name_len: usize = 0;
    const name_str = c.luaL_checklstring(Lnon, 1, &name_len);
    if (name_str == null) {
        c.lua_pushnil(Lnon);
        return 1;
    }
    const name_ptr: [*]const u8 = @ptrCast(name_str);
    const search_name = name_ptr[0..name_len];

    // Iterate through all entities with Name component
    var view = scene.ecs_world.view(Name) catch {
        c.lua_pushnil(Lnon);
        return 1;
    };
    var iter = view.iterator();
    while (iter.next()) |item| {
        if (std.mem.eql(u8, item.component.name, search_name)) {
            c.lua_pushinteger(Lnon, @intCast(@intFromEnum(item.entity)));
            return 1;
        }
    }

    c.lua_pushnil(Lnon);
    return 1;
}

// -----------------------------------------------------------------------------
// Transform API: zephyr.transform.*
// -----------------------------------------------------------------------------

/// zephyr.transform.get_position(entity_id) -> x, y, z
fn l_transform_get_position(L: ?*c.lua_State) callconv(.c) c_int {
    const Lnon = L orelse return 0;
    const scene = getSceneFromLua(Lnon) orelse return 0;
    const entity = getEntityFromArg(Lnon, 1) orelse return 0;

    if (scene.ecs_world.getConst(Transform, entity)) |t| {
        c.lua_pushnumber(Lnon, @floatCast(t.position.x));
        c.lua_pushnumber(Lnon, @floatCast(t.position.y));
        c.lua_pushnumber(Lnon, @floatCast(t.position.z));
        return 3;
    }
    return 0;
}

/// zephyr.transform.set_position(entity_id, x, y, z)
fn l_transform_set_position(L: ?*c.lua_State) callconv(.c) c_int {
    const Lnon = L orelse return 0;
    const scene = getSceneFromLua(Lnon) orelse return 0;
    const entity = getEntityFromArg(Lnon, 1) orelse return 0;

    const x = c.luaL_checknumber(Lnon, 2);
    const y = c.luaL_checknumber(Lnon, 3);
    const z = c.luaL_checknumber(Lnon, 4);

    if (scene.ecs_world.get(Transform, entity)) |t| {
        t.setPosition(Vec3.init(@floatCast(x), @floatCast(y), @floatCast(z)));
    }
    return 0;
}

/// zephyr.transform.translate(entity_id, dx, dy, dz)
fn l_transform_translate(L: ?*c.lua_State) callconv(.c) c_int {
    const Lnon = L orelse return 0;
    const scene = getSceneFromLua(Lnon) orelse return 0;
    const entity = getEntityFromArg(Lnon, 1) orelse return 0;

    const dx = c.luaL_checknumber(Lnon, 2);
    const dy = c.luaL_checknumber(Lnon, 3);
    const dz = c.luaL_checknumber(Lnon, 4);

    if (scene.ecs_world.get(Transform, entity)) |t| {
        t.translate(Vec3.init(@floatCast(dx), @floatCast(dy), @floatCast(dz)));
    }
    return 0;
}

/// zephyr.transform.get_rotation(entity_id) -> pitch, yaw, roll (Euler angles in radians)
fn l_transform_get_rotation(L: ?*c.lua_State) callconv(.c) c_int {
    const Lnon = L orelse return 0;
    const scene = getSceneFromLua(Lnon) orelse return 0;
    const entity = getEntityFromArg(Lnon, 1) orelse return 0;

    if (scene.ecs_world.getConst(Transform, entity)) |t| {
        const euler = t.rotation.toEuler();
        c.lua_pushnumber(Lnon, @floatCast(euler.x));
        c.lua_pushnumber(Lnon, @floatCast(euler.y));
        c.lua_pushnumber(Lnon, @floatCast(euler.z));
        return 3;
    }
    return 0;
}

/// zephyr.transform.set_rotation(entity_id, pitch, yaw, roll)
fn l_transform_set_rotation(L: ?*c.lua_State) callconv(.c) c_int {
    const Lnon = L orelse return 0;
    const scene = getSceneFromLua(Lnon) orelse return 0;
    const entity = getEntityFromArg(Lnon, 1) orelse return 0;

    const pitch = c.luaL_checknumber(Lnon, 2);
    const yaw = c.luaL_checknumber(Lnon, 3);
    const roll = c.luaL_checknumber(Lnon, 4);

    if (scene.ecs_world.get(Transform, entity)) |t| {
        t.setRotation(Vec3.init(@floatCast(pitch), @floatCast(yaw), @floatCast(roll)));
    }
    return 0;
}

/// zephyr.transform.rotate(entity_id, dpitch, dyaw, droll)
fn l_transform_rotate(L: ?*c.lua_State) callconv(.c) c_int {
    const Lnon = L orelse return 0;
    const scene = getSceneFromLua(Lnon) orelse return 0;
    const entity = getEntityFromArg(Lnon, 1) orelse return 0;

    const dpitch = c.luaL_checknumber(Lnon, 2);
    const dyaw = c.luaL_checknumber(Lnon, 3);
    const droll = c.luaL_checknumber(Lnon, 4);

    if (scene.ecs_world.get(Transform, entity)) |t| {
        t.rotate(Vec3.init(@floatCast(dpitch), @floatCast(dyaw), @floatCast(droll)));
    }
    return 0;
}

/// zephyr.transform.get_scale(entity_id) -> sx, sy, sz
fn l_transform_get_scale(L: ?*c.lua_State) callconv(.c) c_int {
    const Lnon = L orelse return 0;
    const scene = getSceneFromLua(Lnon) orelse return 0;
    const entity = getEntityFromArg(Lnon, 1) orelse return 0;

    if (scene.ecs_world.getConst(Transform, entity)) |t| {
        c.lua_pushnumber(Lnon, @floatCast(t.scale.x));
        c.lua_pushnumber(Lnon, @floatCast(t.scale.y));
        c.lua_pushnumber(Lnon, @floatCast(t.scale.z));
        return 3;
    }
    return 0;
}

/// zephyr.transform.set_scale(entity_id, sx, sy, sz)
fn l_transform_set_scale(L: ?*c.lua_State) callconv(.c) c_int {
    const Lnon = L orelse return 0;
    const scene = getSceneFromLua(Lnon) orelse return 0;
    const entity = getEntityFromArg(Lnon, 1) orelse return 0;

    const sx = c.luaL_checknumber(Lnon, 2);
    const sy = c.luaL_checknumber(Lnon, 3);
    const sz = c.luaL_checknumber(Lnon, 4);

    if (scene.ecs_world.get(Transform, entity)) |t| {
        t.setScale(Vec3.init(@floatCast(sx), @floatCast(sy), @floatCast(sz)));
    }
    return 0;
}

/// zephyr.transform.get_forward(entity_id) -> x, y, z
fn l_transform_get_forward(L: ?*c.lua_State) callconv(.c) c_int {
    const Lnon = L orelse return 0;
    const scene = getSceneFromLua(Lnon) orelse return 0;
    const entity = getEntityFromArg(Lnon, 1) orelse return 0;

    if (scene.ecs_world.getConst(Transform, entity)) |t| {
        const fwd = t.forward();
        c.lua_pushnumber(Lnon, @floatCast(fwd.x));
        c.lua_pushnumber(Lnon, @floatCast(fwd.y));
        c.lua_pushnumber(Lnon, @floatCast(fwd.z));
        return 3;
    }
    return 0;
}

/// zephyr.transform.get_right(entity_id) -> x, y, z
fn l_transform_get_right(L: ?*c.lua_State) callconv(.c) c_int {
    const Lnon = L orelse return 0;
    const scene = getSceneFromLua(Lnon) orelse return 0;
    const entity = getEntityFromArg(Lnon, 1) orelse return 0;

    if (scene.ecs_world.getConst(Transform, entity)) |t| {
        const r = t.right();
        c.lua_pushnumber(Lnon, @floatCast(r.x));
        c.lua_pushnumber(Lnon, @floatCast(r.y));
        c.lua_pushnumber(Lnon, @floatCast(r.z));
        return 3;
    }
    return 0;
}

/// zephyr.transform.get_up(entity_id) -> x, y, z
fn l_transform_get_up(L: ?*c.lua_State) callconv(.c) c_int {
    const Lnon = L orelse return 0;
    const scene = getSceneFromLua(Lnon) orelse return 0;
    const entity = getEntityFromArg(Lnon, 1) orelse return 0;

    if (scene.ecs_world.getConst(Transform, entity)) |t| {
        const u = t.up();
        c.lua_pushnumber(Lnon, @floatCast(u.x));
        c.lua_pushnumber(Lnon, @floatCast(u.y));
        c.lua_pushnumber(Lnon, @floatCast(u.z));
        return 3;
    }
    return 0;
}

/// zephyr.transform.look_at(entity_id, target_x, target_y, target_z)
fn l_transform_look_at(L: ?*c.lua_State) callconv(.c) c_int {
    const Lnon = L orelse return 0;
    const scene = getSceneFromLua(Lnon) orelse return 0;
    const entity = getEntityFromArg(Lnon, 1) orelse return 0;

    const tx = c.luaL_checknumber(Lnon, 2);
    const ty = c.luaL_checknumber(Lnon, 3);
    const tz = c.luaL_checknumber(Lnon, 4);

    if (scene.ecs_world.get(Transform, entity)) |t| {
        const target = Vec3.init(@floatCast(tx), @floatCast(ty), @floatCast(tz));
        const dir = Vec3.sub(target, t.position);
        if (Vec3.dot(dir, dir) > 0.0001) {
            const normalized = Vec3.normalize(dir);
            // Calculate yaw and pitch from direction
            const yaw = std.math.atan2(normalized.x, normalized.z);
            const pitch = -std.math.asin(normalized.y);
            t.setRotation(Vec3.init(pitch, yaw, 0));
        }
    }
    return 0;
}

// -----------------------------------------------------------------------------
// Input API: zephyr.input.*
// -----------------------------------------------------------------------------

/// zephyr.input.is_key_down(key) -> bool
fn l_input_is_key_down(L: ?*c.lua_State) callconv(.c) c_int {
    const Lnon = L orelse return 0;
    const key = c.luaL_checkinteger(Lnon, 1);

    if (g_glfw_window) |window| {
        const state = c.glfwGetKey(@ptrCast(window), @intCast(key));
        c.lua_pushboolean(Lnon, if (state == c.GLFW_PRESS) 1 else 0);
    } else {
        c.lua_pushboolean(Lnon, 0);
    }
    return 1;
}

/// zephyr.input.is_mouse_button_down(button) -> bool
fn l_input_is_mouse_button_down(L: ?*c.lua_State) callconv(.c) c_int {
    const Lnon = L orelse return 0;
    const button = c.luaL_checkinteger(Lnon, 1);

    if (g_glfw_window) |window| {
        const state = c.glfwGetMouseButton(@ptrCast(window), @intCast(button));
        c.lua_pushboolean(Lnon, if (state == c.GLFW_PRESS) 1 else 0);
    } else {
        c.lua_pushboolean(Lnon, 0);
    }
    return 1;
}

/// zephyr.input.get_mouse_position() -> x, y
fn l_input_get_mouse_position(L: ?*c.lua_State) callconv(.c) c_int {
    const Lnon = L orelse return 0;

    if (g_glfw_window) |window| {
        var x: f64 = 0;
        var y: f64 = 0;
        c.glfwGetCursorPos(@ptrCast(window), &x, &y);
        c.lua_pushnumber(Lnon, x);
        c.lua_pushnumber(Lnon, y);
    } else {
        c.lua_pushnumber(Lnon, 0);
        c.lua_pushnumber(Lnon, 0);
    }
    return 2;
}

// -----------------------------------------------------------------------------
// Time API: zephyr.time.*
// -----------------------------------------------------------------------------

/// zephyr.time.delta() -> dt (seconds)
fn l_time_delta(L: ?*c.lua_State) callconv(.c) c_int {
    const Lnon = L orelse return 0;
    c.lua_pushnumber(Lnon, @floatCast(g_delta_time));
    return 1;
}

/// zephyr.time.elapsed() -> time since start (seconds)
fn l_time_elapsed(L: ?*c.lua_State) callconv(.c) c_int {
    const Lnon = L orelse return 0;
    c.lua_pushnumber(Lnon, g_time_since_start);
    return 1;
}

/// zephyr.time.frame() -> frame count
fn l_time_frame(L: ?*c.lua_State) callconv(.c) c_int {
    const Lnon = L orelse return 0;
    c.lua_pushinteger(Lnon, @intCast(g_frame_count));
    return 1;
}

// -----------------------------------------------------------------------------
// PointLight API: zephyr.light.*
// -----------------------------------------------------------------------------

/// zephyr.light.get_color(entity_id) -> r, g, b
fn l_light_get_color(L: ?*c.lua_State) callconv(.c) c_int {
    const Lnon = L orelse return 0;
    const scene = getSceneFromLua(Lnon) orelse return 0;
    const entity = getEntityFromArg(Lnon, 1) orelse return 0;

    if (scene.ecs_world.getConst(PointLight, entity)) |light| {
        c.lua_pushnumber(Lnon, @floatCast(light.color.x));
        c.lua_pushnumber(Lnon, @floatCast(light.color.y));
        c.lua_pushnumber(Lnon, @floatCast(light.color.z));
        return 3;
    }
    return 0;
}

/// zephyr.light.set_color(entity_id, r, g, b)
fn l_light_set_color(L: ?*c.lua_State) callconv(.c) c_int {
    const Lnon = L orelse return 0;
    const scene = getSceneFromLua(Lnon) orelse return 0;
    const entity = getEntityFromArg(Lnon, 1) orelse return 0;

    const r = c.luaL_checknumber(Lnon, 2);
    const g = c.luaL_checknumber(Lnon, 3);
    const b = c.luaL_checknumber(Lnon, 4);

    if (scene.ecs_world.get(PointLight, entity)) |light| {
        light.color = Vec3.init(@floatCast(r), @floatCast(g), @floatCast(b));
    }
    return 0;
}

/// zephyr.light.get_intensity(entity_id) -> intensity
fn l_light_get_intensity(L: ?*c.lua_State) callconv(.c) c_int {
    const Lnon = L orelse return 0;
    const scene = getSceneFromLua(Lnon) orelse return 0;
    const entity = getEntityFromArg(Lnon, 1) orelse return 0;

    if (scene.ecs_world.getConst(PointLight, entity)) |light| {
        c.lua_pushnumber(Lnon, @floatCast(light.intensity));
        return 1;
    }
    return 0;
}

/// zephyr.light.set_intensity(entity_id, intensity)
fn l_light_set_intensity(L: ?*c.lua_State) callconv(.c) c_int {
    const Lnon = L orelse return 0;
    const scene = getSceneFromLua(Lnon) orelse return 0;
    const entity = getEntityFromArg(Lnon, 1) orelse return 0;

    const intensity = c.luaL_checknumber(Lnon, 2);

    if (scene.ecs_world.get(PointLight, entity)) |light| {
        light.intensity = @floatCast(intensity);
    }
    return 0;
}

/// zephyr.light.set_range(entity_id, range)
fn l_light_set_range(L: ?*c.lua_State) callconv(.c) c_int {
    const Lnon = L orelse return 0;
    const scene = getSceneFromLua(Lnon) orelse return 0;
    const entity = getEntityFromArg(Lnon, 1) orelse return 0;

    const range = c.luaL_checknumber(Lnon, 2);

    if (scene.ecs_world.get(PointLight, entity)) |light| {
        light.range = @floatCast(range);
    }
    return 0;
}

// -----------------------------------------------------------------------------
// ParticleEmitter API: zephyr.particles.*
// -----------------------------------------------------------------------------

/// zephyr.particles.set_rate(entity_id, rate)
fn l_particles_set_rate(L: ?*c.lua_State) callconv(.c) c_int {
    const Lnon = L orelse return 0;
    const scene = getSceneFromLua(Lnon) orelse return 0;
    const entity = getEntityFromArg(Lnon, 1) orelse return 0;

    const rate = c.luaL_checknumber(Lnon, 2);

    if (scene.ecs_world.get(ParticleEmitter, entity)) |emitter| {
        emitter.emission_rate = @floatCast(rate);
    }
    return 0;
}

/// zephyr.particles.set_color(entity_id, r, g, b)
fn l_particles_set_color(L: ?*c.lua_State) callconv(.c) c_int {
    const Lnon = L orelse return 0;
    const scene = getSceneFromLua(Lnon) orelse return 0;
    const entity = getEntityFromArg(Lnon, 1) orelse return 0;

    const r = c.luaL_checknumber(Lnon, 2);
    const g = c.luaL_checknumber(Lnon, 3);
    const b = c.luaL_checknumber(Lnon, 4);

    if (scene.ecs_world.get(ParticleEmitter, entity)) |emitter| {
        emitter.setColor(Vec3.init(@floatCast(r), @floatCast(g), @floatCast(b)));
    }
    return 0;
}

/// zephyr.particles.set_active(entity_id, active)
fn l_particles_set_active(L: ?*c.lua_State) callconv(.c) c_int {
    const Lnon = L orelse return 0;
    const scene = getSceneFromLua(Lnon) orelse return 0;
    const entity = getEntityFromArg(Lnon, 1) orelse return 0;

    const active = c.lua_toboolean(Lnon, 2);

    if (scene.ecs_world.get(ParticleEmitter, entity)) |emitter| {
        emitter.active = active != 0;
    }
    return 0;
}

// -----------------------------------------------------------------------------
// Physics API: zephyr.physics.*
// -----------------------------------------------------------------------------

/// zephyr.physics.get_velocity(entity_id) -> vx, vy, vz
fn l_physics_get_velocity(L: ?*c.lua_State) callconv(.c) c_int {
    const Lnon = L orelse return 0;
    const scene = getSceneFromLua(Lnon) orelse return 0;
    const entity = getEntityFromArg(Lnon, 1) orelse return 0;

    if (scene.ecs_world.getConst(RigidBody, entity)) |rb| {
        if (rb.body_id != .invalid) {
            if (scene.physics_system) |ps| {
                const body_interface = ps.physics_system.getBodyInterface();
                const vel = body_interface.getLinearVelocity(rb.body_id);
                c.lua_pushnumber(Lnon, @floatCast(vel[0]));
                c.lua_pushnumber(Lnon, @floatCast(vel[1]));
                c.lua_pushnumber(Lnon, @floatCast(vel[2]));
                return 3;
            }
        }
    }
    c.lua_pushnumber(Lnon, 0);
    c.lua_pushnumber(Lnon, 0);
    c.lua_pushnumber(Lnon, 0);
    return 3;
}

/// zephyr.physics.set_velocity(entity_id, vx, vy, vz)
fn l_physics_set_velocity(L: ?*c.lua_State) callconv(.c) c_int {
    const Lnon = L orelse return 0;
    const scene = getSceneFromLua(Lnon) orelse return 0;
    const entity = getEntityFromArg(Lnon, 1) orelse return 0;

    const vx = c.luaL_checknumber(Lnon, 2);
    const vy = c.luaL_checknumber(Lnon, 3);
    const vz = c.luaL_checknumber(Lnon, 4);

    if (scene.ecs_world.getConst(RigidBody, entity)) |rb| {
        if (rb.body_id != .invalid) {
            if (scene.physics_system) |ps| {
                const body_interface = ps.physics_system.getBodyInterfaceMut();
                body_interface.setLinearVelocity(
                    rb.body_id,
                    .{ @floatCast(vx), @floatCast(vy), @floatCast(vz) },
                );
            }
        }
    }
    return 0;
}

/// zephyr.physics.add_force(entity_id, fx, fy, fz)
fn l_physics_add_force(L: ?*c.lua_State) callconv(.c) c_int {
    const Lnon = L orelse return 0;
    const scene = getSceneFromLua(Lnon) orelse return 0;
    const entity = getEntityFromArg(Lnon, 1) orelse return 0;

    const fx = c.luaL_checknumber(Lnon, 2);
    const fy = c.luaL_checknumber(Lnon, 3);
    const fz = c.luaL_checknumber(Lnon, 4);

    if (scene.ecs_world.getConst(RigidBody, entity)) |rb| {
        if (rb.body_id != .invalid) {
            if (scene.physics_system) |ps| {
                const body_interface = ps.physics_system.getBodyInterfaceMut();
                body_interface.addForce(
                    rb.body_id,
                    .{ @floatCast(fx), @floatCast(fy), @floatCast(fz) },
                );
            }
        }
    }
    return 0;
}

/// zephyr.physics.add_impulse(entity_id, ix, iy, iz)
fn l_physics_add_impulse(L: ?*c.lua_State) callconv(.c) c_int {
    const Lnon = L orelse return 0;
    const scene = getSceneFromLua(Lnon) orelse return 0;
    const entity = getEntityFromArg(Lnon, 1) orelse return 0;

    const ix = c.luaL_checknumber(Lnon, 2);
    const iy = c.luaL_checknumber(Lnon, 3);
    const iz = c.luaL_checknumber(Lnon, 4);

    if (scene.ecs_world.getConst(RigidBody, entity)) |rb| {
        if (rb.body_id != .invalid) {
            if (scene.physics_system) |ps| {
                const body_interface = ps.physics_system.getBodyInterfaceMut();
                body_interface.addImpulse(
                    rb.body_id,
                    .{ @floatCast(ix), @floatCast(iy), @floatCast(iz) },
                );
            }
        }
    }
    return 0;
}

// -----------------------------------------------------------------------------
// Math utilities: zephyr.math.*
// -----------------------------------------------------------------------------

/// zephyr.math.vec3(x, y, z) -> table {x, y, z}
fn l_math_vec3(L: ?*c.lua_State) callconv(.c) c_int {
    const Lnon = L orelse return 0;
    const x = c.luaL_checknumber(Lnon, 1);
    const y = c.luaL_checknumber(Lnon, 2);
    const z = c.luaL_checknumber(Lnon, 3);

    c.lua_newtable(Lnon);
    c.lua_pushnumber(Lnon, x);
    c.lua_setfield(Lnon, -2, "x");
    c.lua_pushnumber(Lnon, y);
    c.lua_setfield(Lnon, -2, "y");
    c.lua_pushnumber(Lnon, z);
    c.lua_setfield(Lnon, -2, "z");
    return 1;
}

/// zephyr.math.distance(x1, y1, z1, x2, y2, z2) -> distance
fn l_math_distance(L: ?*c.lua_State) callconv(.c) c_int {
    const Lnon = L orelse return 0;
    const x1: f32 = @floatCast(c.luaL_checknumber(Lnon, 1));
    const y1: f32 = @floatCast(c.luaL_checknumber(Lnon, 2));
    const z1: f32 = @floatCast(c.luaL_checknumber(Lnon, 3));
    const x2: f32 = @floatCast(c.luaL_checknumber(Lnon, 4));
    const y2: f32 = @floatCast(c.luaL_checknumber(Lnon, 5));
    const z2: f32 = @floatCast(c.luaL_checknumber(Lnon, 6));

    const dx = x2 - x1;
    const dy = y2 - y1;
    const dz = z2 - z1;
    const dist = @sqrt(dx * dx + dy * dy + dz * dz);
    c.lua_pushnumber(Lnon, @floatCast(dist));
    return 1;
}

/// zephyr.math.lerp(a, b, t) -> interpolated value
fn l_math_lerp(L: ?*c.lua_State) callconv(.c) c_int {
    const Lnon = L orelse return 0;
    const a = c.luaL_checknumber(Lnon, 1);
    const b = c.luaL_checknumber(Lnon, 2);
    const t = c.luaL_checknumber(Lnon, 3);

    const result = a + (b - a) * t;
    c.lua_pushnumber(Lnon, result);
    return 1;
}

/// zephyr.math.clamp(value, min, max) -> clamped value
fn l_math_clamp(L: ?*c.lua_State) callconv(.c) c_int {
    const Lnon = L orelse return 0;
    const v = c.luaL_checknumber(Lnon, 1);
    const min_v = c.luaL_checknumber(Lnon, 2);
    const max_v = c.luaL_checknumber(Lnon, 3);

    var result = v;
    if (result < min_v) result = min_v;
    if (result > max_v) result = max_v;
    c.lua_pushnumber(Lnon, result);
    return 1;
}

/// zephyr.math.normalize(x, y, z) -> nx, ny, nz
fn l_math_normalize(L: ?*c.lua_State) callconv(.c) c_int {
    const Lnon = L orelse return 0;
    const x: f32 = @floatCast(c.luaL_checknumber(Lnon, 1));
    const y: f32 = @floatCast(c.luaL_checknumber(Lnon, 2));
    const z: f32 = @floatCast(c.luaL_checknumber(Lnon, 3));

    const len = @sqrt(x * x + y * y + z * z);
    if (len > 0.0001) {
        c.lua_pushnumber(Lnon, @floatCast(x / len));
        c.lua_pushnumber(Lnon, @floatCast(y / len));
        c.lua_pushnumber(Lnon, @floatCast(z / len));
    } else {
        c.lua_pushnumber(Lnon, 0);
        c.lua_pushnumber(Lnon, 0);
        c.lua_pushnumber(Lnon, 0);
    }
    return 3;
}

/// zephyr.math.dot(x1, y1, z1, x2, y2, z2) -> dot product
fn l_math_dot(L: ?*c.lua_State) callconv(.c) c_int {
    const Lnon = L orelse return 0;
    const x1 = c.luaL_checknumber(Lnon, 1);
    const y1 = c.luaL_checknumber(Lnon, 2);
    const z1 = c.luaL_checknumber(Lnon, 3);
    const x2 = c.luaL_checknumber(Lnon, 4);
    const y2 = c.luaL_checknumber(Lnon, 5);
    const z2 = c.luaL_checknumber(Lnon, 6);

    const result = x1 * x2 + y1 * y2 + z1 * z2;
    c.lua_pushnumber(Lnon, result);
    return 1;
}

/// zephyr.math.cross(x1, y1, z1, x2, y2, z2) -> rx, ry, rz
fn l_math_cross(L: ?*c.lua_State) callconv(.c) c_int {
    const Lnon = L orelse return 0;
    const x1: f32 = @floatCast(c.luaL_checknumber(Lnon, 1));
    const y1: f32 = @floatCast(c.luaL_checknumber(Lnon, 2));
    const z1: f32 = @floatCast(c.luaL_checknumber(Lnon, 3));
    const x2: f32 = @floatCast(c.luaL_checknumber(Lnon, 4));
    const y2: f32 = @floatCast(c.luaL_checknumber(Lnon, 5));
    const z2: f32 = @floatCast(c.luaL_checknumber(Lnon, 6));

    c.lua_pushnumber(Lnon, @floatCast(y1 * z2 - z1 * y2));
    c.lua_pushnumber(Lnon, @floatCast(z1 * x2 - x1 * z2));
    c.lua_pushnumber(Lnon, @floatCast(x1 * y2 - y1 * x2));
    return 3;
}

// -----------------------------------------------------------------------------
// Scene API: zephyr.scene.*
// -----------------------------------------------------------------------------

/// zephyr.scene.get_name() -> string
fn l_scene_get_name(L: ?*c.lua_State) callconv(.c) c_int {
    const Lnon = L orelse return 0;
    const scene = getSceneFromLua(Lnon) orelse {
        c.lua_pushnil(Lnon);
        return 1;
    };

    const ptr: [*]const u8 = @ptrCast(scene.name.ptr);
    _ = c.lua_pushlstring(Lnon, ptr, scene.name.len);
    return 1;
}

// -----------------------------------------------------------------------------
// Key constants for input
// -----------------------------------------------------------------------------

fn registerKeyConstants(L: *c.lua_State) void {
    c.lua_newtable(L);

    // Common keys
    c.lua_pushinteger(L, c.GLFW_KEY_SPACE);
    c.lua_setfield(L, -2, "SPACE");
    c.lua_pushinteger(L, c.GLFW_KEY_ESCAPE);
    c.lua_setfield(L, -2, "ESCAPE");
    c.lua_pushinteger(L, c.GLFW_KEY_ENTER);
    c.lua_setfield(L, -2, "ENTER");
    c.lua_pushinteger(L, c.GLFW_KEY_TAB);
    c.lua_setfield(L, -2, "TAB");

    // Arrow keys
    c.lua_pushinteger(L, c.GLFW_KEY_UP);
    c.lua_setfield(L, -2, "UP");
    c.lua_pushinteger(L, c.GLFW_KEY_DOWN);
    c.lua_setfield(L, -2, "DOWN");
    c.lua_pushinteger(L, c.GLFW_KEY_LEFT);
    c.lua_setfield(L, -2, "LEFT");
    c.lua_pushinteger(L, c.GLFW_KEY_RIGHT);
    c.lua_setfield(L, -2, "RIGHT");

    // WASD
    c.lua_pushinteger(L, c.GLFW_KEY_W);
    c.lua_setfield(L, -2, "W");
    c.lua_pushinteger(L, c.GLFW_KEY_A);
    c.lua_setfield(L, -2, "A");
    c.lua_pushinteger(L, c.GLFW_KEY_S);
    c.lua_setfield(L, -2, "S");
    c.lua_pushinteger(L, c.GLFW_KEY_D);
    c.lua_setfield(L, -2, "D");

    // Modifiers
    c.lua_pushinteger(L, c.GLFW_KEY_LEFT_SHIFT);
    c.lua_setfield(L, -2, "LSHIFT");
    c.lua_pushinteger(L, c.GLFW_KEY_RIGHT_SHIFT);
    c.lua_setfield(L, -2, "RSHIFT");
    c.lua_pushinteger(L, c.GLFW_KEY_LEFT_CONTROL);
    c.lua_setfield(L, -2, "LCTRL");
    c.lua_pushinteger(L, c.GLFW_KEY_RIGHT_CONTROL);
    c.lua_setfield(L, -2, "RCTRL");

    // Number keys
    c.lua_pushinteger(L, c.GLFW_KEY_0);
    c.lua_setfield(L, -2, "NUM_0");
    c.lua_pushinteger(L, c.GLFW_KEY_1);
    c.lua_setfield(L, -2, "NUM_1");
    c.lua_pushinteger(L, c.GLFW_KEY_2);
    c.lua_setfield(L, -2, "NUM_2");
    c.lua_pushinteger(L, c.GLFW_KEY_3);
    c.lua_setfield(L, -2, "NUM_3");
    c.lua_pushinteger(L, c.GLFW_KEY_4);
    c.lua_setfield(L, -2, "NUM_4");
    c.lua_pushinteger(L, c.GLFW_KEY_5);
    c.lua_setfield(L, -2, "NUM_5");
    c.lua_pushinteger(L, c.GLFW_KEY_6);
    c.lua_setfield(L, -2, "NUM_6");
    c.lua_pushinteger(L, c.GLFW_KEY_7);
    c.lua_setfield(L, -2, "NUM_7");
    c.lua_pushinteger(L, c.GLFW_KEY_8);
    c.lua_setfield(L, -2, "NUM_8");
    c.lua_pushinteger(L, c.GLFW_KEY_9);
    c.lua_setfield(L, -2, "NUM_9");

    // Function keys
    c.lua_pushinteger(L, c.GLFW_KEY_F1);
    c.lua_setfield(L, -2, "F1");
    c.lua_pushinteger(L, c.GLFW_KEY_F2);
    c.lua_setfield(L, -2, "F2");
    c.lua_pushinteger(L, c.GLFW_KEY_F3);
    c.lua_setfield(L, -2, "F3");
    c.lua_pushinteger(L, c.GLFW_KEY_F4);
    c.lua_setfield(L, -2, "F4");
    c.lua_pushinteger(L, c.GLFW_KEY_F5);
    c.lua_setfield(L, -2, "F5");

    // Mouse buttons
    c.lua_pushinteger(L, c.GLFW_MOUSE_BUTTON_LEFT);
    c.lua_setfield(L, -2, "MOUSE_LEFT");
    c.lua_pushinteger(L, c.GLFW_MOUSE_BUTTON_RIGHT);
    c.lua_setfield(L, -2, "MOUSE_RIGHT");
    c.lua_pushinteger(L, c.GLFW_MOUSE_BUTTON_MIDDLE);
    c.lua_setfield(L, -2, "MOUSE_MIDDLE");

    c.lua_setglobal(L, "Key");
}

// -----------------------------------------------------------------------------
// Registration: register all zephyr.* namespaces
// -----------------------------------------------------------------------------

pub fn registerZephyrAPI(L: *c.lua_State) void {
    // Create main 'zephyr' table
    c.lua_newtable(L);

    // zephyr.entity
    c.lua_newtable(L);
    c.lua_pushcfunction(L, l_entity_create);
    c.lua_setfield(L, -2, "create");
    c.lua_pushcfunction(L, l_entity_destroy);
    c.lua_setfield(L, -2, "destroy");
    c.lua_pushcfunction(L, l_entity_exists);
    c.lua_setfield(L, -2, "exists");
    c.lua_pushcfunction(L, l_entity_get_name);
    c.lua_setfield(L, -2, "get_name");
    c.lua_pushcfunction(L, l_entity_set_name);
    c.lua_setfield(L, -2, "set_name");
    c.lua_pushcfunction(L, l_entity_find);
    c.lua_setfield(L, -2, "find");
    c.lua_setfield(L, -2, "entity");

    // zephyr.transform
    c.lua_newtable(L);
    c.lua_pushcfunction(L, l_transform_get_position);
    c.lua_setfield(L, -2, "get_position");
    c.lua_pushcfunction(L, l_transform_set_position);
    c.lua_setfield(L, -2, "set_position");
    c.lua_pushcfunction(L, l_transform_translate);
    c.lua_setfield(L, -2, "translate");
    c.lua_pushcfunction(L, l_transform_get_rotation);
    c.lua_setfield(L, -2, "get_rotation");
    c.lua_pushcfunction(L, l_transform_set_rotation);
    c.lua_setfield(L, -2, "set_rotation");
    c.lua_pushcfunction(L, l_transform_rotate);
    c.lua_setfield(L, -2, "rotate");
    c.lua_pushcfunction(L, l_transform_get_scale);
    c.lua_setfield(L, -2, "get_scale");
    c.lua_pushcfunction(L, l_transform_set_scale);
    c.lua_setfield(L, -2, "set_scale");
    c.lua_pushcfunction(L, l_transform_get_forward);
    c.lua_setfield(L, -2, "get_forward");
    c.lua_pushcfunction(L, l_transform_get_right);
    c.lua_setfield(L, -2, "get_right");
    c.lua_pushcfunction(L, l_transform_get_up);
    c.lua_setfield(L, -2, "get_up");
    c.lua_pushcfunction(L, l_transform_look_at);
    c.lua_setfield(L, -2, "look_at");
    c.lua_setfield(L, -2, "transform");

    // zephyr.input
    c.lua_newtable(L);
    c.lua_pushcfunction(L, l_input_is_key_down);
    c.lua_setfield(L, -2, "is_key_down");
    c.lua_pushcfunction(L, l_input_is_mouse_button_down);
    c.lua_setfield(L, -2, "is_mouse_button_down");
    c.lua_pushcfunction(L, l_input_get_mouse_position);
    c.lua_setfield(L, -2, "get_mouse_position");
    c.lua_setfield(L, -2, "input");

    // zephyr.time
    c.lua_newtable(L);
    c.lua_pushcfunction(L, l_time_delta);
    c.lua_setfield(L, -2, "delta");
    c.lua_pushcfunction(L, l_time_elapsed);
    c.lua_setfield(L, -2, "elapsed");
    c.lua_pushcfunction(L, l_time_frame);
    c.lua_setfield(L, -2, "frame");
    c.lua_setfield(L, -2, "time");

    // zephyr.light
    c.lua_newtable(L);
    c.lua_pushcfunction(L, l_light_get_color);
    c.lua_setfield(L, -2, "get_color");
    c.lua_pushcfunction(L, l_light_set_color);
    c.lua_setfield(L, -2, "set_color");
    c.lua_pushcfunction(L, l_light_get_intensity);
    c.lua_setfield(L, -2, "get_intensity");
    c.lua_pushcfunction(L, l_light_set_intensity);
    c.lua_setfield(L, -2, "set_intensity");
    c.lua_pushcfunction(L, l_light_set_range);
    c.lua_setfield(L, -2, "set_range");
    c.lua_setfield(L, -2, "light");

    // zephyr.particles
    c.lua_newtable(L);
    c.lua_pushcfunction(L, l_particles_set_rate);
    c.lua_setfield(L, -2, "set_rate");
    c.lua_pushcfunction(L, l_particles_set_color);
    c.lua_setfield(L, -2, "set_color");
    c.lua_pushcfunction(L, l_particles_set_active);
    c.lua_setfield(L, -2, "set_active");
    c.lua_setfield(L, -2, "particles");

    // zephyr.physics
    c.lua_newtable(L);
    c.lua_pushcfunction(L, l_physics_get_velocity);
    c.lua_setfield(L, -2, "get_velocity");
    c.lua_pushcfunction(L, l_physics_set_velocity);
    c.lua_setfield(L, -2, "set_velocity");
    c.lua_pushcfunction(L, l_physics_add_force);
    c.lua_setfield(L, -2, "add_force");
    c.lua_pushcfunction(L, l_physics_add_impulse);
    c.lua_setfield(L, -2, "add_impulse");
    c.lua_setfield(L, -2, "physics");

    // zephyr.math
    c.lua_newtable(L);
    c.lua_pushcfunction(L, l_math_vec3);
    c.lua_setfield(L, -2, "vec3");
    c.lua_pushcfunction(L, l_math_distance);
    c.lua_setfield(L, -2, "distance");
    c.lua_pushcfunction(L, l_math_lerp);
    c.lua_setfield(L, -2, "lerp");
    c.lua_pushcfunction(L, l_math_clamp);
    c.lua_setfield(L, -2, "clamp");
    c.lua_pushcfunction(L, l_math_normalize);
    c.lua_setfield(L, -2, "normalize");
    c.lua_pushcfunction(L, l_math_dot);
    c.lua_setfield(L, -2, "dot");
    c.lua_pushcfunction(L, l_math_cross);
    c.lua_setfield(L, -2, "cross");
    c.lua_setfield(L, -2, "math");

    // zephyr.scene
    c.lua_newtable(L);
    c.lua_pushcfunction(L, l_scene_get_name);
    c.lua_setfield(L, -2, "get_name");
    c.lua_setfield(L, -2, "scene");

    // Set global 'zephyr'
    c.lua_setglobal(L, "zephyr");

    // Register Key constants
    registerKeyConstants(L);
}
