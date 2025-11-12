// Zephyr Engine - Configuration Management System
// Centralized configuration with validation, hot-reload, and type-safe access

const std = @import("std");
const log = @import("../utils/log.zig").log;

/// Configuration value type
pub const ConfigValue = union(enum) {
    bool: bool,
    int: i64,
    float: f64,
    string: []const u8,
    
    pub fn format(
        self: ConfigValue,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        switch (self) {
            .bool => |v| try writer.print("{}", .{v}),
            .int => |v| try writer.print("{d}", .{v}),
            .float => |v| try writer.print("{d:.2}", .{v}),
            .string => |v| try writer.print("\"{s}\"", .{v}),
        }
    }
};

/// Configuration entry with metadata
pub const ConfigEntry = struct {
    value: ConfigValue,
    default_value: ConfigValue,
    description: []const u8,
    category: []const u8,
    read_only: bool = false,
    requires_restart: bool = false,
    
    pub fn reset(self: *ConfigEntry) void {
        self.value = self.default_value;
    }
};

/// Configuration validation error
pub const ValidationError = error{
    InvalidType,
    OutOfRange,
    ReadOnly,
    RequiresRestart,
};

/// Configuration validator function type
pub const Validator = *const fn (value: ConfigValue) ValidationError!void;

/// Central configuration manager
pub const ConfigManager = struct {
    allocator: std.mem.Allocator,
    entries: std.StringHashMap(ConfigEntry),
    validators: std.StringHashMap(Validator),
    mutex: std.Thread.Mutex,
    dirty: bool,
    
    pub fn init(allocator: std.mem.Allocator) ConfigManager {
        return .{
            .allocator = allocator,
            .entries = std.StringHashMap(ConfigEntry).init(allocator),
            .validators = std.StringHashMap(Validator).init(allocator),
            .mutex = .{},
            .dirty = false,
        };
    }
    
    pub fn deinit(self: *ConfigManager) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.value == .string) {
                self.allocator.free(entry.value_ptr.value.string);
            }
            if (entry.value_ptr.default_value == .string) {
                self.allocator.free(entry.value_ptr.default_value.string);
            }
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.description);
            self.allocator.free(entry.value_ptr.category);
        }
        
        var vit = self.validators.iterator();
        while (vit.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        
        self.entries.deinit();
        self.validators.deinit();
    }
    
    /// Register a configuration entry
    pub fn register(
        self: *ConfigManager,
        name: []const u8,
        default_value: ConfigValue,
        description: []const u8,
        category: []const u8,
        options: struct {
            read_only: bool = false,
            requires_restart: bool = false,
            validator: ?Validator = null,
        },
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);
        
        const desc_copy = try self.allocator.dupe(u8, description);
        errdefer self.allocator.free(desc_copy);
        
        const cat_copy = try self.allocator.dupe(u8, category);
        errdefer self.allocator.free(cat_copy);
        
        const value_copy = try self.copyValue(default_value);
        errdefer self.freeValue(value_copy);
        
        const default_copy = try self.copyValue(default_value);
        errdefer self.freeValue(default_copy);
        
        const entry = ConfigEntry{
            .value = value_copy,
            .default_value = default_copy,
            .description = desc_copy,
            .category = cat_copy,
            .read_only = options.read_only,
            .requires_restart = options.requires_restart,
        };
        
        try self.entries.put(name_copy, entry);
        
        if (options.validator) |validator| {
            const val_name = try self.allocator.dupe(u8, name);
            try self.validators.put(val_name, validator);
        }
        
        log(.info, "Registered config: {s} = {}", .{ name, default_value });
    }
    
    /// Get a configuration value
    pub fn get(self: *ConfigManager, name: []const u8) ?ConfigValue {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.entries.get(name)) |entry| {
            return entry.value;
        }
        return null;
    }
    
    /// Get a boolean configuration value
    pub fn getBool(self: *ConfigManager, name: []const u8, default: bool) bool {
        if (self.get(name)) |value| {
            return switch (value) {
                .bool => |v| v,
                else => default,
            };
        }
        return default;
    }
    
    /// Get an integer configuration value
    pub fn getInt(self: *ConfigManager, name: []const u8, default: i64) i64 {
        if (self.get(name)) |value| {
            return switch (value) {
                .int => |v| v,
                else => default,
            };
        }
        return default;
    }
    
    /// Get a float configuration value
    pub fn getFloat(self: *ConfigManager, name: []const u8, default: f64) f64 {
        if (self.get(name)) |value| {
            return switch (value) {
                .float => |v| v,
                else => default,
            };
        }
        return default;
    }
    
    /// Get a string configuration value
    pub fn getString(self: *ConfigManager, name: []const u8, default: []const u8) []const u8 {
        if (self.get(name)) |value| {
            return switch (value) {
                .string => |v| v,
                else => default,
            };
        }
        return default;
    }
    
    /// Set a configuration value
    pub fn set(self: *ConfigManager, name: []const u8, value: ConfigValue) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        var entry = self.entries.getPtr(name) orelse return error.ConfigNotFound;
        
        if (entry.read_only) {
            return ValidationError.ReadOnly;
        }
        
        // Validate if validator exists
        if (self.validators.get(name)) |validator| {
            try validator(value);
        }
        
        // Type check
        if (@as(std.meta.Tag(ConfigValue), entry.value) != @as(std.meta.Tag(ConfigValue), value)) {
            return ValidationError.InvalidType;
        }
        
        // Free old string if needed
        if (entry.value == .string) {
            self.allocator.free(entry.value.string);
        }
        
        entry.value = try self.copyValue(value);
        self.dirty = true;
        
        log(.info, "Config updated: {s} = {}", .{ name, value });
        
        if (entry.requires_restart) {
            log(.warn, "Config '{s}' requires restart to take effect", .{name});
        }
    }
    
    /// Reset a configuration value to default
    pub fn reset(self: *ConfigManager, name: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        var entry = self.entries.getPtr(name) orelse return error.ConfigNotFound;
        
        if (entry.read_only) {
            return ValidationError.ReadOnly;
        }
        
        if (entry.value == .string) {
            self.allocator.free(entry.value.string);
        }
        
        entry.value = try self.copyValue(entry.default_value);
        self.dirty = true;
        
        log(.info, "Config reset: {s}", .{name});
    }
    
    /// Reset all configuration values to defaults
    pub fn resetAll(self: *ConfigManager) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            if (!kv.value_ptr.read_only) {
                kv.value_ptr.reset();
            }
        }
        
        self.dirty = true;
        log(.info, "All configs reset to defaults", .{});
    }
    
    /// Load configuration from file
    pub fn loadFromFile(self: *ConfigManager, path: []const u8) !void {
        log(.info, "Loading config from: {s}", .{path});
        
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        
        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(content);
        
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
            if (trimmed.len == 0 or trimmed[0] == '#') continue;
            
            if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
                const key = std.mem.trim(u8, trimmed[0..eq_pos], &std.ascii.whitespace);
                const value_str = std.mem.trim(u8, trimmed[eq_pos + 1 ..], &std.ascii.whitespace);
                
                if (self.entries.getPtr(key)) |entry| {
                    const value = try self.parseValue(value_str, entry.value);
                    self.set(key, value) catch |err| {
                        log(.err, "Failed to set config {s}: {}", .{ key, err });
                    };
                }
            }
        }
        
        self.dirty = false;
    }
    
    /// Save configuration to file
    pub fn saveToFile(self: *ConfigManager, path: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        log(.info, "Saving config to: {s}", .{path});
        
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        
        const writer = file.writer();
        
        try writer.writeAll("# Zephyr Engine Configuration\n");
        try writer.writeAll("# Auto-generated - edit with caution\n\n");
        
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            const name = kv.key_ptr.*;
            const entry = kv.value_ptr;
            
            try writer.print("# {s}\n", .{entry.description});
            try writer.print("# Category: {s}\n", .{entry.category});
            if (entry.read_only) {
                try writer.writeAll("# [READ ONLY]\n");
            }
            if (entry.requires_restart) {
                try writer.writeAll("# [REQUIRES RESTART]\n");
            }
            try writer.print("{}={}\n\n", .{ name, entry.value });
        }
        
        self.dirty = false;
    }
    
    /// Check if configuration has unsaved changes
    pub fn isDirty(self: *ConfigManager) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.dirty;
    }
    
    /// Get all configuration entries in a category
    pub fn getCategory(self: *ConfigManager, category: []const u8, allocator: std.mem.Allocator) ![][]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        var result = std.ArrayList([]const u8).init(allocator);
        errdefer result.deinit();
        
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            if (std.mem.eql(u8, kv.value_ptr.category, category)) {
                try result.append(kv.key_ptr.*);
            }
        }
        
        return result.toOwnedSlice();
    }
    
    fn copyValue(self: *ConfigManager, value: ConfigValue) !ConfigValue {
        return switch (value) {
            .string => |s| .{ .string = try self.allocator.dupe(u8, s) },
            else => value,
        };
    }
    
    fn freeValue(self: *ConfigManager, value: ConfigValue) void {
        if (value == .string) {
            self.allocator.free(value.string);
        }
    }
    
    fn parseValue(self: *ConfigManager, str: []const u8, template: ConfigValue) !ConfigValue {
        return switch (template) {
            .bool => .{ .bool = std.mem.eql(u8, str, "true") },
            .int => .{ .int = try std.fmt.parseInt(i64, str, 10) },
            .float => .{ .float = try std.fmt.parseFloat(f64, str) },
            .string => .{ .string = try self.allocator.dupe(u8, str) },
        };
    }
};

// Tests
test "ConfigManager basic operations" {
    var manager = ConfigManager.init(std.testing.allocator);
    defer manager.deinit();
    
    try manager.register("test.enabled", .{ .bool = true }, "Test flag", "test", .{});
    try manager.register("test.count", .{ .int = 42 }, "Test count", "test", .{});
    
    try std.testing.expectEqual(true, manager.getBool("test.enabled", false));
    try std.testing.expectEqual(@as(i64, 42), manager.getInt("test.count", 0));
    
    try manager.set("test.enabled", .{ .bool = false });
    try std.testing.expectEqual(false, manager.getBool("test.enabled", true));
}

test "ConfigManager validation" {
    var manager = ConfigManager.init(std.testing.allocator);
    defer manager.deinit();
    
    const rangeValidator = struct {
        fn validate(value: ConfigValue) ValidationError!void {
            if (value == .int and (value.int < 0 or value.int > 100)) {
                return ValidationError.OutOfRange;
            }
        }
    }.validate;
    
    try manager.register("test.value", .{ .int = 50 }, "Test value", "test", .{
        .validator = rangeValidator,
    });
    
    try manager.set("test.value", .{ .int = 75 });
    try std.testing.expectError(ValidationError.OutOfRange, manager.set("test.value", .{ .int = 150 }));
}

test "ConfigManager read-only" {
    var manager = ConfigManager.init(std.testing.allocator);
    defer manager.deinit();
    
    try manager.register("version", .{ .string = "1.0.0" }, "Engine version", "system", .{
        .read_only = true,
    });
    
    try std.testing.expectError(ValidationError.ReadOnly, manager.set("version", .{ .string = "2.0.0" }));
}
