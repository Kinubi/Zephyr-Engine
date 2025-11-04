const std = @import("std");

pub const CVarType = enum {
    Int,
    Float,
    Bool,
    String,
};

pub const CVar = struct {
    name: []const u8,
    ctype: CVarType,
    // storage for values (only one is authoritative based on ctype)
    int_val: i64,
    float_val: f64,
    bool_val: bool,
    str_val: std.ArrayList(u8),
    // default value stored so reset can restore
    default_int: i64,
    default_float: f64,
    default_bool: bool,
    default_str: std.ArrayList(u8),

    pub fn deinit(self: *CVar) void {
        // free owned buffers
        self.str_val.deinit();
        self.default_str.deinit();
    }
};

pub const CVarRegistry = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMap(*CVar),

    pub fn init(allocator: std.mem.Allocator) !CVarRegistry {
        return CVarRegistry{ .allocator = allocator, .map = std.StringHashMap(*CVar).init(allocator) };
    }

    pub fn deinit(self: *CVarRegistry) void {
        // free all entries
        var it = self.map.iterator();
        while (it.next()) |entry| {
            const cv = entry.value.*;
            cv.deinit();
            // free the struct memory
            self.allocator.destroy(cv);
        }
        self.map.deinit();
    }

    fn allocName(self: *CVarRegistry, name: []const u8) ![]const u8 {
        const buf = try self.allocator.alloc(u8, name.len);
        std.mem.copyForwards(u8, buf, name);
        return buf;
    }

    pub fn listAllAlloc(self: *CVarRegistry, allocator: std.mem.Allocator) ![][]const u8 {
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
        // If exists, set typed value according to existing type, else infer type
        if (self.map.get(name)) |cvp| {
            // parse according to stored CVar type and mutate in-place
            switch (cvp.*.ctype) {
                .Int => {
                    const parsed = std.fmt.parseInt(i64, val, 10) catch return;
                    cvp.*.int_val = parsed;
                },
                .Float => {
                    const parsed = std.fmt.parseFloat(f64, val) catch return;
                    cvp.*.float_val = parsed;
                },
                .Bool => {
                    if (std.mem.eql(u8, val, "true")) {
                        cvp.*.bool_val = true;
                    } else if (std.mem.eql(u8, val, "false")) {
                        cvp.*.bool_val = false;
                    } else {
                        return;
                    }
                },
                .String => {
                    cvp.*.str_val.clearRetainingCapacity();
                    try cvp.*.str_val.appendSlice(self.allocator, val);
                },
            }
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
        cvar_ptr.*.default_int = 0;
        cvar_ptr.*.default_float = 0.0;
        cvar_ptr.*.default_bool = false;
        cvar_ptr.*.default_str = std.ArrayList(u8){};

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

    pub fn reset(self: *CVarRegistry, name: []const u8) !bool {
        if (self.map.get(name)) |cvp| {
            const cv = cvp.*;
            switch (cv.ctype) {
                .Int => cv.int_val = cv.default_int,
                .Float => cv.float_val = cv.default_float,
                .Bool => cv.bool_val = cv.default_bool,
                .String => {
                    cv.str_val.clearRetainingCapacity();
                    try cv.str_val.appendSlice(self.allocator, cv.default_str.items[0..]);
                },
            }
            return true;
        }
        return false;
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
    return boxed;
}

pub fn getGlobal() ?*CVarRegistry {
    return global;
}

pub fn deinitGlobal() void {
    if (global) |g| {
        g.deinit();
        // destroy struct wrapper using its allocator
        g.allocator.destroy(g);
        global = null;
    }
}
