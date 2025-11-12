// Integration test for architectural improvements
// Tests that the new systems can be imported and used together

const std = @import("std");
const testing = std.testing;

// Import the new architectural systems
const errors = @import("core/errors.zig");
const resource = @import("core/resource_manager.zig");
const config = @import("core/config.zig");

// Test type for resource management
const TestResource = struct {
    value: i32,
    name: []const u8,
    
    pub fn deinit(self: *TestResource) void {
        _ = self;
        // Cleanup if needed
    }
};

test "architectural improvements integration" {
    const allocator = testing.allocator;
    
    // Test 1: Error handling system
    {
        const ctx = errors.ErrorContext.init(
            errors.EngineError.InitializationFailed,
            "Test error",
            @src(),
        );
        try testing.expectEqual(errors.EngineError.InitializationFailed, ctx.error_code);
    }
    
    // Test 2: Resource management system
    {
        var manager = resource.ResourceManager(TestResource).init(allocator);
        defer manager.deinit();
        
        const res = TestResource{ .value = 42, .name = "test" };
        const handle = try manager.create("test_resource", res);
        
        const retrieved = manager.get(handle);
        try testing.expect(retrieved != null);
        try testing.expectEqual(@as(i32, 42), retrieved.?.value);
    }
    
    // Test 3: Configuration system
    {
        var cfg = config.ConfigManager.init(allocator);
        defer cfg.deinit();
        
        try cfg.register(
            "test.enabled",
            .{ .bool = true },
            "Test flag",
            "test",
            .{},
        );
        
        const value = cfg.getBool("test.enabled", false);
        try testing.expectEqual(true, value);
    }
    
    // Test 4: Integration - all systems working together
    {
        var cfg = config.ConfigManager.init(allocator);
        defer cfg.deinit();
        
        var manager = resource.ResourceManager(TestResource).init(allocator);
        defer manager.deinit();
        
        // Register configuration
        try cfg.register(
            "resource.max_count",
            .{ .int = 100 },
            "Max resource count",
            "resource",
            .{},
        );
        
        // Create resources based on configuration
        const max_count = cfg.getInt("resource.max_count", 10);
        try testing.expectEqual(@as(i64, 100), max_count);
        
        // Create a resource
        const res = TestResource{ .value = @intCast(max_count), .name = "integrated" };
        const handle = try manager.create("integrated_resource", res);
        
        // Verify resource exists
        const retrieved = manager.get(handle);
        try testing.expect(retrieved != null);
        try testing.expectEqual(@as(i32, 100), retrieved.?.value);
        
        // Test statistics
        const stats = manager.getStats();
        try testing.expectEqual(@as(u32, 1), stats.active);
    }
}

test "error recovery strategies" {
    var recovery = errors.Recovery.init(.retry);
    recovery.max_retries = 3;
    
    var attempts: u32 = 0;
    while (recovery.shouldRetry()) {
        attempts += 1;
        if (attempts >= 3) break;
    }
    
    try testing.expectEqual(@as(u32, 3), attempts);
}

test "resource reference counting" {
    const allocator = testing.allocator;
    
    var manager = resource.ResourceManager(TestResource).init(allocator);
    defer manager.deinit();
    
    const res = TestResource{ .value = 123, .name = "refcount" };
    const handle = try manager.create("refcount_test", res);
    
    // Add references
    try manager.addRef(handle);
    try manager.addRef(handle);
    
    const stats = manager.getStats();
    try testing.expectEqual(@as(u32, 1), stats.active);
    
    // Remove references
    manager.removeRef(handle);
    manager.removeRef(handle);
}

test "configuration validation" {
    const allocator = testing.allocator;
    
    const validator = struct {
        fn validate(value: config.ConfigValue) config.ValidationError!void {
            if (value == .int and (value.int < 0 or value.int > 100)) {
                return config.ValidationError.OutOfRange;
            }
        }
    }.validate;
    
    var cfg = config.ConfigManager.init(allocator);
    defer cfg.deinit();
    
    try cfg.register(
        "test.range",
        .{ .int = 50 },
        "Test range value",
        "test",
        .{ .validator = validator },
    );
    
    // Valid value
    try cfg.set("test.range", .{ .int = 75 });
    
    // Invalid value
    const result = cfg.set("test.range", .{ .int = 150 });
    try testing.expectError(config.ValidationError.OutOfRange, result);
}
