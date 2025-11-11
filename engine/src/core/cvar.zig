const std = @import("std");
const log = @import("../utils/log.zig").log;

pub const CVarType = enum {
    Int,
    Float,
    Bool,
    String,
};

pub const CVarFlags = packed struct {
    archived: bool = false,
    read_only: bool = false,
};

pub const CVarError = error{
    ParseError,
    OutOfBounds,
    ReadOnly,
};

pub const CVar = struct {
    name: []const u8,
    ctype: CVarType,
    // storage for values (only one is authoritative based on ctype)
    int_val: i64,
    float_val: f64,
    bool_val: bool,
    str_val: std.ArrayList(u8),
    // optional metadata
    description: std.ArrayList(u8),
    flags: CVarFlags,
    // default value stored so reset can restore
    default_int: i64,
    default_float: f64,
    default_bool: bool,
    default_str: std.ArrayList(u8),
    // optional validation bounds
    min_int: ?i64 = null,
    max_int: ?i64 = null,
    min_float: ?f64 = null,
    max_float: ?f64 = null,
    // optional change callback: (name, old_str, new_str)
    // optional change callback: pointer to function (callers may invoke)
    on_change: ?*const fn ([]const u8, []const u8, []const u8) void = null,
    // optional Lua handler name to call asynchronously (stored as bytes)
    on_change_lua: std.ArrayList(u8),

    pub fn deinit(self: *CVar, allocator: std.mem.Allocator) void {
        // free owned buffers
        if (self.str_val.items.len > 0) self.str_val.deinit(allocator);
        if (self.default_str.items.len > 0) self.default_str.deinit(allocator);
        if (self.description.items.len > 0) self.description.deinit(allocator);
        if (self.on_change_lua.items.len > 0) self.on_change_lua.deinit(allocator);
    }
};

pub const CVarChange = struct {
    name: []const u8,
    old: []const u8,
    new: []const u8,
    on_change: ?*const fn ([]const u8, []const u8, []const u8) void,
};

pub const CVarRegistry = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMap(*CVar),
    mutex: std.Thread.Mutex = .{},
    pending_changes: std.ArrayList(CVarChange),

    pub fn init(allocator: std.mem.Allocator) !CVarRegistry {
        return CVarRegistry{ .allocator = allocator, .map = std.StringHashMap(*CVar).init(allocator), .mutex = .{}, .pending_changes = .{} };
    }

    pub fn deinit(self: *CVarRegistry) void {
        // free all entries
        self.mutex.lock();
        defer self.mutex.unlock();
        var it = self.map.iterator();
        while (it.next()) |entry| {
            const cv = entry.value_ptr.*;
            cv.deinit(self.allocator);
            // free the struct memory
            self.allocator.destroy(cv);
        }
        self.map.deinit();
        // free pending change buffers
        for (self.pending_changes.items) |e| {
            if (e.name.len > 0) self.allocator.free(e.name);
            if (e.old.len > 0) self.allocator.free(e.old);
            if (e.new.len > 0) self.allocator.free(e.new);
        }
        self.pending_changes.deinit(self.allocator);
    }

    /// Take pending change events. Returns an allocated array of CVarChange
    /// entries which the caller must free (and free each event's name/old/new
    /// buffers using the provided allocator when done).
    pub fn takePendingChanges(self: *CVarRegistry, allocator: std.mem.Allocator) ![]CVarChange {
        self.mutex.lock();
        defer self.mutex.unlock();

        const count = self.pending_changes.items.len;
        if (count == 0) return &[_]CVarChange{};

        const out = try allocator.alloc(CVarChange, count);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            out[i] = self.pending_changes.items[i];
        }
        // clear internal list without freeing buffers (ownership transferred)
        self.pending_changes.clearRetainingCapacity();
        return out[0..count];
    }

    /// Process pending changes by invoking stored callbacks (if any) and
    /// freeing event buffers. This calls callbacks synchronously on the
    /// caller's thread.
    pub fn processPendingChanges(self: *CVarRegistry) !void {
        // Steal pending events using the registry allocator
        const events = try self.takePendingChanges(self.allocator);
        defer self.allocator.free(events);

        var i: usize = 0;
        while (i < events.len) : (i += 1) {
            const ev = events[i];
            // Native callbacks are intentionally disabled in this build.
            // ev.on_change, if present, will be ignored to avoid calling
            // runtime-known function pointers across module boundaries.
            // free buffers allocated for the event
            if (ev.name.len > 0) self.allocator.free(ev.name);
            if (ev.old.len > 0) self.allocator.free(ev.old);
            if (ev.new.len > 0) self.allocator.free(ev.new);
        }
        return;
    }

    /// Helper to invoke a native on_change callback. Placed here so the
    /// invocation occurs in the same translation unit as the CVar definition
    /// (which avoids certain Zig restrictions about calling function values
    /// from runtime-loaded pointers in other modules).
    pub fn invokeCallback(cb: ?*const fn ([]const u8, []const u8, []const u8) void, name: []const u8, old: []const u8, new: []const u8) void {
        if (cb) |c| {
            const f = c.*;
            f(name, old, new);
        }
    }

    fn allocName(self: *CVarRegistry, name: []const u8) ![]const u8 {
        const buf = try self.allocator.alloc(u8, name.len);
        std.mem.copyForwards(u8, buf, name);
        return buf;
    }

    pub fn listAllAlloc(self: *CVarRegistry, allocator: std.mem.Allocator) ![][]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Count entries first
        var count: usize = 0;
        var it = self.map.iterator();
        while (it.next()) |entry| {
            _ = entry;
            count += 1;
        }

        // Allocate an array of slices and fill with keys
        var arr = try allocator.alloc([]const u8, count);
        var i: usize = 0;
        it = self.map.iterator();
        while (it.next()) |entry| {
            // StringHashMap iterator exposes key_ptr which points to the stored key
            arr[i] = entry.key_ptr.*;
            i += 1;
        }
        return arr[0..count];
    }

    pub fn getAsStringAlloc(self: *CVarRegistry, name: []const u8, allocator: std.mem.Allocator) ?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.map.get(name)) |cvp| {
            const cv = cvp.*;
            switch (cv.ctype) {
                .Int => {
                    // allocate a formatted string for the integer
                    const s = std.fmt.allocPrint(allocator, "{}", .{cv.int_val}) catch return null;
                    return s;
                },
                .Float => {
                    // allocate a formatted string for the float
                    const s = std.fmt.allocPrint(allocator, "{}", .{cv.float_val}) catch return null;
                    return s;
                },
                .Bool => {
                    const s = if (cv.bool_val) "true" else "false";
                    const buf = allocator.alloc(u8, s.len) catch return null;
                    std.mem.copyForwards(u8, buf, s);
                    return buf;
                },
                .String => {
                    // return a copy of stored string
                    const buf = allocator.alloc(u8, cv.str_val.items.len) catch return null;
                    std.mem.copyForwards(u8, buf, cv.str_val.items[0..]);
                    return buf[0..cv.str_val.items.len];
                },
            }
        }
        return null;
    }

    pub fn setFromString(self: *CVarRegistry, name: []const u8, val: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // If exists, set typed value according to existing type, else infer type
        if (self.map.get(name)) |cvp| {
            // Prevent writes to read-only CVARs
            if (cvp.*.flags.read_only) return CVarError.ReadOnly;

            // we'll collect callback and optional old value buffer, then unlock before calling
            var old_buf: ?[]u8 = null;
            var cb_ptr: ?*const fn ([]const u8, []const u8, []const u8) void = null;
            cb_ptr = cvp.*.on_change;

            // parse according to stored CVar type and mutate in-place (with bounds checks)
            switch (cvp.*.ctype) {
                .Int => {
                    const parsed = std.fmt.parseInt(i64, val, 10) catch return CVarError.ParseError;
                    if (cvp.*.min_int) |mi| if (parsed < mi) return CVarError.OutOfBounds;
                    if (cvp.*.max_int) |ma| if (parsed > ma) return CVarError.OutOfBounds;
                    // format old value
                    old_buf = std.fmt.allocPrint(self.allocator, "{}", .{cvp.*.int_val}) catch null;
                    cvp.*.int_val = parsed;
                },
                .Float => {
                    const parsed = std.fmt.parseFloat(f64, val) catch return CVarError.ParseError;
                    if (cvp.*.min_float) |mf| if (parsed < mf) return CVarError.OutOfBounds;
                    if (cvp.*.max_float) |Mf| if (parsed > Mf) return CVarError.OutOfBounds;
                    old_buf = std.fmt.allocPrint(self.allocator, "{}", .{cvp.*.float_val}) catch null;
                    cvp.*.float_val = parsed;
                },
                .Bool => {
                    if (std.mem.eql(u8, val, "true")) {
                        old_buf = if (cvp.*.bool_val) std.fmt.allocPrint(self.allocator, "true", .{}) catch null else std.fmt.allocPrint(self.allocator, "false", .{}) catch null;
                        cvp.*.bool_val = true;
                    } else if (std.mem.eql(u8, val, "false")) {
                        old_buf = if (cvp.*.bool_val) std.fmt.allocPrint(self.allocator, "true", .{}) catch null else std.fmt.allocPrint(self.allocator, "false", .{}) catch null;
                        cvp.*.bool_val = false;
                    } else {
                        return CVarError.ParseError;
                    }
                },
                .String => {
                    // store old copy for callback
                    if (cvp.*.str_val.items.len > 0) {
                        old_buf = self.allocator.alloc(u8, cvp.*.str_val.items.len) catch null;
                        if (old_buf) |b| std.mem.copyForwards(u8, b, cvp.*.str_val.items[0..]);
                    }
                    cvp.*.str_val.clearRetainingCapacity();
                    try cvp.*.str_val.appendSlice(self.allocator, val);
                },
            }

            // Record change as a pending event so higher-level code can process
            // it (and invoke callbacks) outside the registry mutex.
            // Prepare name/old/new slices (transfer ownership where possible).
            var name_copy: []const u8 = &[_]u8{};
            // allocate a copy of the name
            name_copy = try self.allocName(cvp.*.name);

            // new value copy
            var new_copy: []const u8 = &[_]u8{};
            if (val.len > 0) {
                const nb = try self.allocator.alloc(u8, val.len);
                std.mem.copyForwards(u8, nb, val);
                new_copy = nb[0..val.len];
            } else {
                new_copy = "";
            }

            // old value: if we have an allocated buffer from above, reuse it,
            // otherwise create an empty slice
            const old_slice: []const u8 = if (old_buf) |b| b else "";

            // append pending change (store on_change pointer so caller can decide)
            const evt = CVarChange{ .name = name_copy, .old = old_slice, .new = new_copy, .on_change = cvp.*.on_change };
            try self.pending_changes.append(self.allocator, evt);

            // note: ownership of old_buf (if any) was transferred into the event
            // so do not free it here. Caller who consumes pending changes is
            // responsible for freeing the event buffers.
            return;
        }

        // Create new CVar and infer type
        const cvar_ptr = try self.allocator.create(CVar);
        // initialize fields and arraylists
        cvar_ptr.*.name = &[_]u8{};
        cvar_ptr.*.ctype = .String;
        cvar_ptr.*.int_val = 0;
        cvar_ptr.*.float_val = 0.0;
        cvar_ptr.*.bool_val = false;
        cvar_ptr.*.str_val = std.ArrayList(u8){};
        cvar_ptr.*.description = std.ArrayList(u8){};
        cvar_ptr.*.flags = CVarFlags{};
        cvar_ptr.*.default_int = 0;
        cvar_ptr.*.default_float = 0.0;
        cvar_ptr.*.default_bool = false;
        cvar_ptr.*.default_str = std.ArrayList(u8){};
        cvar_ptr.*.on_change_lua = std.ArrayList(u8){};

        // infer
        if (val.len > 0) {
            // try int
            var parsed_i: i64 = 0;
            var int_ok: bool = false;
            if (std.fmt.parseInt(i64, val, 10) catch null) |pv| {
                parsed_i = pv;
                int_ok = true;
            }
            if (int_ok) {
                cvar_ptr.*.ctype = .Int;
                cvar_ptr.*.int_val = parsed_i;
                cvar_ptr.*.default_int = parsed_i;
            } else {
                var parsed_f: f64 = 0.0;
                var float_ok: bool = false;
                if (std.fmt.parseFloat(f64, val) catch null) |pf| {
                    parsed_f = pf;
                    float_ok = true;
                }
                if (float_ok) {
                    cvar_ptr.*.ctype = .Float;
                    cvar_ptr.*.float_val = parsed_f;
                    cvar_ptr.*.default_float = parsed_f;
                } else if (std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "false")) {
                    cvar_ptr.*.ctype = .Bool;
                    cvar_ptr.*.bool_val = if (std.mem.eql(u8, val, "true")) true else false;
                    cvar_ptr.*.default_bool = cvar_ptr.*.bool_val;
                } else {
                    cvar_ptr.*.ctype = .String;
                    try cvar_ptr.*.str_val.appendSlice(self.allocator, val);
                    try cvar_ptr.*.default_str.appendSlice(self.allocator, val);
                }
            }
        }

        // copy name
        const name_copy = try self.allocName(name);
        cvar_ptr.*.name = name_copy;

        // insert into map
        _ = try self.map.put(name_copy, cvar_ptr);
    }

    pub fn registerCVar(self: *CVarRegistry, name: []const u8, ctype: CVarType, default_val: []const u8, description: []const u8, flags: CVarFlags, min_int: ?i64, max_int: ?i64, min_float: ?f64, max_float: ?f64, on_change: ?*const fn ([]const u8, []const u8, []const u8) void) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // if already exists, update metadata and set value to default
        if (self.map.get(name)) |cvp| {
            cvp.*.flags = flags;
            cvp.*.min_int = min_int;
            cvp.*.max_int = max_int;
            cvp.*.min_float = min_float;
            cvp.*.max_float = max_float;
            cvp.*.on_change = on_change;
            cvp.*.description.clearRetainingCapacity();
            if (description.len > 0) try cvp.*.description.appendSlice(self.allocator, description);
            // set the default/current value
            // temporarily unlock to reuse setFromString which takes the lock
            self.mutex.unlock();
            defer self.mutex.lock();
            try self.setFromString(name, default_val);
            return;
        }

        const cvar_ptr = try self.allocator.create(CVar);
        // initialize
        cvar_ptr.*.name = &[_]u8{};
        cvar_ptr.*.ctype = ctype;
        cvar_ptr.*.int_val = 0;
        cvar_ptr.*.float_val = 0.0;
        cvar_ptr.*.bool_val = false;
        cvar_ptr.*.str_val = std.ArrayList(u8){};
        cvar_ptr.*.description = std.ArrayList(u8){};
        cvar_ptr.*.flags = flags;
        cvar_ptr.*.default_int = 0;
        cvar_ptr.*.default_float = 0.0;
        cvar_ptr.*.default_bool = false;
        cvar_ptr.*.default_str = std.ArrayList(u8){};
        cvar_ptr.*.on_change_lua = std.ArrayList(u8){};
        cvar_ptr.*.min_int = min_int;
        cvar_ptr.*.max_int = max_int;
        cvar_ptr.*.min_float = min_float;
        cvar_ptr.*.max_float = max_float;
        cvar_ptr.*.on_change = on_change;

        if (description.len > 0) try cvar_ptr.*.description.appendSlice(self.allocator, description);

        // set default/current based on provided ctype and default_val
        switch (ctype) {
            .Int => {
                const parsed = std.fmt.parseInt(i64, default_val, 10) catch 0;
                cvar_ptr.*.int_val = parsed;
                cvar_ptr.*.default_int = parsed;
            },
            .Float => {
                const parsed = std.fmt.parseFloat(f64, default_val) catch 0.0;
                cvar_ptr.*.float_val = parsed;
                cvar_ptr.*.default_float = parsed;
            },
            .Bool => {
                const b = if (std.mem.eql(u8, default_val, "true")) true else false;
                cvar_ptr.*.bool_val = b;
                cvar_ptr.*.default_bool = b;
            },
            .String => {
                try cvar_ptr.*.str_val.appendSlice(self.allocator, default_val);
                try cvar_ptr.*.default_str.appendSlice(self.allocator, default_val);
            },
        }

        const name_copy = try self.allocName(name);
        cvar_ptr.*.name = name_copy;
        _ = try self.map.put(name_copy, cvar_ptr);
    }

    pub fn setLuaOnChange(self: *CVarRegistry, name: []const u8, handler: []const u8) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.map.get(name)) |cvp| {
            cvp.*.on_change_lua.clearRetainingCapacity();
            if (handler.len > 0) try cvp.*.on_change_lua.appendSlice(self.allocator, handler);
            return true;
        }
        return false;
    }

    pub fn getLuaOnChangeAlloc(self: *CVarRegistry, name: []const u8, allocator: std.mem.Allocator) ?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.map.get(name)) |cvp| {
            const h = cvp.*.on_change_lua;
            if (h.items.len == 0) return null;
            const buf = allocator.alloc(u8, h.items.len) catch return null;
            std.mem.copyForwards(u8, buf, h.items[0..]);
            return buf[0..h.items.len];
        }
        return null;
    }

    pub fn reset(self: *CVarRegistry, name: []const u8) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.map.get(name)) |cvp| {
            switch (cvp.*.ctype) {
                .Int => cvp.*.int_val = cvp.*.default_int,
                .Float => cvp.*.float_val = cvp.*.default_float,
                .Bool => cvp.*.bool_val = cvp.*.default_bool,
                .String => {
                    cvp.*.str_val.clearRetainingCapacity();
                    try cvp.*.str_val.appendSlice(self.allocator, cvp.*.default_str.items[0..]);
                },
            }
            return true;
        }
        return false;
    }

    pub fn setArchived(self: *CVarRegistry, name: []const u8, archived: bool) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.map.get(name)) |cvp| {
            cvp.*.flags.archived = archived;
            return true;
        }
        return false;
    }

    pub fn getDescriptionAlloc(self: *CVarRegistry, name: []const u8, allocator: std.mem.Allocator) ?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.map.get(name)) |cvp| {
            const desc = cvp.*.description;
            if (desc.items.len == 0) return null;
            const buf = allocator.alloc(u8, desc.items.len) catch return null;
            std.mem.copyForwards(u8, buf, desc.items[0..]);
            return buf[0..desc.items.len];
        }
        return null;
    }
};

// Simple global registry (initialized on demand)
var global: ?*CVarRegistry = null;

pub fn ensureGlobal(allocator: std.mem.Allocator) !*CVarRegistry {
    if (global) |g| return g;
    const reg = try CVarRegistry.init(allocator);
    // allocate reg on allocator
    const boxed = try allocator.create(CVarRegistry);
    boxed.* = reg;
    global = boxed;

    // Register a few basic CVARs used by editor/engine by default
    // These are lightweight defaults; systems may override or register richer metadata later.
    _ = boxed.registerCVar("r_vsync", .Bool, "true", "Enable/disable vertical sync", CVarFlags{ .archived = true, .read_only = false }, null, null, null, null, null) catch {};
    _ = boxed.registerCVar("r_msaa", .Int, "1", "MSAA sample count (0 = off)", CVarFlags{ .archived = true, .read_only = false }, null, null, null, null, null) catch {};
    _ = boxed.registerCVar("e_show_stats", .Bool, "true", "Show engine stats overlay", CVarFlags{ .archived = false, .read_only = false }, null, null, null, null, null) catch {};
    _ = boxed.registerCVar("d_wireframe", .Bool, "false", "Render in wireframe mode", CVarFlags{ .archived = false, .read_only = false }, null, null, null, null, null) catch {};

    // Additional defaults: common engine/game CVARs
    _ = boxed.registerCVar("r_resolution", .String, "1280x720", "Render resolution in WxH format", CVarFlags{ .archived = true, .read_only = false }, null, null, null, null, null) catch {};
    _ = boxed.registerCVar("r_fullscreen", .Bool, "false", "Enable fullscreen rendering", CVarFlags{ .archived = true, .read_only = false }, null, null, null, null, null) catch {};
    _ = boxed.registerCVar("audio_master", .Float, "1.0", "Master audio volume (0.0-1.0)", CVarFlags{ .archived = true, .read_only = false }, null, null, null, null, null) catch {};
    _ = boxed.registerCVar("debug_log_level", .Int, "2", "Logging verbosity (0=off..5=debug)", CVarFlags{ .archived = true, .read_only = false }, null, null, null, null, null) catch {};
    _ = boxed.registerCVar("r_texture_quality", .Int, "2", "Texture quality level (0=low..3=high)", CVarFlags{ .archived = true, .read_only = false }, null, null, null, null, null) catch {};

    // Memory tracking CVARs
    _ = boxed.registerCVar("r_trackMemory", .Bool, "false", "Enable GPU memory allocation tracking", CVarFlags{ .archived = true, .read_only = false }, null, null, null, null, null) catch {};
    _ = boxed.registerCVar("r_logMemoryAllocs", .Bool, "false", "Log individual memory allocations", CVarFlags{ .archived = false, .read_only = false }, null, null, null, null, null) catch {};
    _ = boxed.registerCVar("r_frame_arena_size_mb", .Int, "64", "Frame arena size in megabytes", CVarFlags{ .archived = true, .read_only = false }, null, null, null, null, null) catch {};

    // attempt to load archived CVARs persisted on disk
    _ = loadArchivedFromFile(boxed, "cache/cvars.cfg") catch {};

    return boxed;
}

pub fn getGlobal() ?*CVarRegistry {
    return global;
}

pub fn deinitGlobal() void {
    if (global) |g| {
        // persist archived CVARs before shutting down
        _ = saveArchivedToFile(g, "cache/cvars.cfg") catch {};

        g.deinit();
        // destroy struct wrapper using its allocator
        g.allocator.destroy(g);
        global = null;
    }
}

pub fn loadArchivedFromFile(self: *CVarRegistry, path: []const u8) !void {
    log(.INFO, "cvar", "Loading archived CVars from {s}", .{path});

    const fs = std.fs.cwd();
    var file = try fs.openFile(path, .{});
    defer file.close();
    const contents = try file.readToEndAlloc(self.allocator, 8192);
    defer self.allocator.free(contents);

    var loaded_count: usize = 0;
    var start: usize = 0;
    while (start < contents.len) {
        var end = start;
        while (end < contents.len and contents[end] != '\n') : (end += 1) {}
        const line = contents[start..end];
        if (line.len > 0) {
            // split at first '='
            var eq_index: usize = 0;
            var found = false;
            while (eq_index < line.len) : (eq_index += 1) {
                if (line[eq_index] == '=') {
                    found = true;
                    break;
                }
            }
            if (found and eq_index > 0) {
                const key = line[0..eq_index];
                var val = line[eq_index + 1 ..];
                // Trim trailing whitespace (including \r from Windows line endings)
                while (val.len > 0 and (val[val.len - 1] == ' ' or val[val.len - 1] == '\t' or val[val.len - 1] == '\r')) {
                    val = val[0 .. val.len - 1];
                }
                // set without erroring on parse issues
                self.setFromString(key, val) catch |err| {
                    log(.WARN, "cvar", "Failed to load {s}={s}: {}", .{ key, val, err });
                    start = end + 1;
                    continue;
                };
                loaded_count += 1;
            }
        }
        start = end + 1;
    }
    log(.INFO, "cvar", "Loaded {} archived CVars", .{loaded_count});
}

pub fn saveArchivedToFile(self: *CVarRegistry, path: []const u8) !void {
    log(.INFO, "cvar", "Saving archived CVars to {s}", .{path});

    const fs = std.fs.cwd();
    var file = try fs.createFile(path, .{});
    defer file.close();

    self.mutex.lock();
    defer self.mutex.unlock();

    var saved_count: usize = 0;
    var it = self.map.iterator();
    while (it.next()) |entry| {
        const cv = entry.value_ptr.*;
        if (cv.flags.archived) {
            // write "key=value\n"
            const key = entry.key_ptr.*;
            _ = try file.writeAll(key);
            _ = try file.writeAll("=");

            // Format value directly without calling getAsStringAlloc (avoids deadlock)
            const value_str = switch (cv.ctype) {
                .Int => try std.fmt.allocPrint(self.allocator, "{}", .{cv.int_val}),
                .Float => try std.fmt.allocPrint(self.allocator, "{d}", .{cv.float_val}),
                .Bool => if (cv.bool_val) try self.allocator.dupe(u8, "true") else try self.allocator.dupe(u8, "false"),
                .String => try self.allocator.dupe(u8, cv.str_val.items),
            };
            defer self.allocator.free(value_str);

            _ = try file.writeAll(value_str);
            saved_count += 1;
            _ = try file.writeAll("\n");
        }
    }
    log(.INFO, "cvar", "Saved {} archived CVars", .{saved_count});
}
