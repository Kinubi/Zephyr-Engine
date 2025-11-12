// Zephyr Engine - Resource Manager
// Provides unified resource lifetime management with RAII patterns

const std = @import("std");
const log = @import("../utils/log.zig").log;

/// Resource handle with generation for detecting use-after-free
pub fn Handle(comptime T: type) type {
    return struct {
        index: u32,
        generation: u32,
        
        const Self = @This();
        
        pub fn invalid() Self {
            return .{ .index = std.math.maxInt(u32), .generation = 0 };
        }
        
        pub fn isValid(self: Self) bool {
            return self.index != std.math.maxInt(u32);
        }
        
        pub fn format(
            self: Self,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;
            _ = options;
            try writer.print("Handle({s}){{.index={d}, .gen={d}}}", .{
                @typeName(T),
                self.index,
                self.generation,
            });
        }
    };
}

/// Resource state for tracking lifecycle
pub const ResourceState = enum {
    uninitialized,
    loading,
    ready,
    error_state,
    disposed,
};

/// Resource metadata
pub fn ResourceMeta(comptime T: type) type {
    return struct {
        state: ResourceState,
        generation: u32,
        ref_count: u32,
        name: []const u8,
        
        pub fn init(name: []const u8) @This() {
            return .{
                .state = .uninitialized,
                .generation = 1,
                .ref_count = 0,
                .name = name,
            };
        }
    };
}

/// RAII resource wrapper
pub fn Resource(comptime T: type) type {
    return struct {
        handle: Handle(T),
        manager: *ResourceManager(T),
        
        const Self = @This();
        
        /// Acquire a reference to the resource
        pub fn acquire(handle: Handle(T), manager: *ResourceManager(T)) !Self {
            try manager.addRef(handle);
            return .{ .handle = handle, .manager = manager };
        }
        
        /// Release the resource reference
        pub fn release(self: *Self) void {
            self.manager.removeRef(self.handle);
        }
        
        /// Get the resource data
        pub fn get(self: *const Self) ?*T {
            return self.manager.get(self.handle);
        }
    };
}

/// Generic resource manager with reference counting and lifecycle management
pub fn ResourceManager(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        resources: std.ArrayList(T),
        metadata: std.ArrayList(ResourceMeta(T)),
        free_list: std.ArrayList(u32),
        mutex: std.Thread.Mutex,
        
        const Self = @This();
        
        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .resources = std.ArrayList(T).init(allocator),
                .metadata = std.ArrayList(ResourceMeta(T)).init(allocator),
                .free_list = std.ArrayList(u32).init(allocator),
                .mutex = .{},
            };
        }
        
        pub fn deinit(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            
            // Clean up all resources
            for (self.metadata.items, 0..) |*meta, i| {
                if (meta.state == .ready or meta.state == .loading) {
                    log(.warn, "Resource '{s}' still allocated during manager shutdown (refs: {d})", .{
                        meta.name,
                        meta.ref_count,
                    });
                    if (comptime std.meta.hasFn(T, "deinit")) {
                        self.resources.items[i].deinit();
                    }
                    meta.state = .disposed;
                }
            }
            
            self.resources.deinit();
            self.metadata.deinit();
            self.free_list.deinit();
        }
        
        /// Create a new resource
        pub fn create(self: *Self, name: []const u8, resource: T) !Handle(T) {
            self.mutex.lock();
            defer self.mutex.unlock();
            
            const index = if (self.free_list.items.len > 0)
                self.free_list.pop()
            else blk: {
                const idx = @as(u32, @intCast(self.resources.items.len));
                try self.resources.append(resource);
                try self.metadata.append(ResourceMeta(T).init(name));
                break :blk idx;
            };
            
            self.resources.items[index] = resource;
            self.metadata.items[index] = ResourceMeta(T).init(name);
            self.metadata.items[index].state = .ready;
            
            return Handle(T){
                .index = index,
                .generation = self.metadata.items[index].generation,
            };
        }
        
        /// Get a resource by handle
        pub fn get(self: *Self, handle: Handle(T)) ?*T {
            if (handle.index >= self.metadata.items.len) return null;
            
            const meta = &self.metadata.items[handle.index];
            if (meta.generation != handle.generation) return null;
            if (meta.state != .ready) return null;
            
            return &self.resources.items[handle.index];
        }
        
        /// Add a reference to a resource
        pub fn addRef(self: *Self, handle: Handle(T)) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            
            if (handle.index >= self.metadata.items.len) {
                return error.InvalidResourceHandle;
            }
            
            const meta = &self.metadata.items[handle.index];
            if (meta.generation != handle.generation) {
                return error.InvalidResourceHandle;
            }
            
            meta.ref_count += 1;
        }
        
        /// Remove a reference from a resource
        pub fn removeRef(self: *Self, handle: Handle(T)) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            
            if (handle.index >= self.metadata.items.len) return;
            
            const meta = &self.metadata.items[handle.index];
            if (meta.generation != handle.generation) return;
            
            if (meta.ref_count > 0) {
                meta.ref_count -= 1;
                
                // Auto-dispose when ref count reaches zero
                if (meta.ref_count == 0 and meta.state == .ready) {
                    self.disposeResource(handle.index);
                }
            }
        }
        
        /// Manually destroy a resource
        pub fn destroy(self: *Self, handle: Handle(T)) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            
            if (handle.index >= self.metadata.items.len) return;
            
            const meta = &self.metadata.items[handle.index];
            if (meta.generation != handle.generation) return;
            
            if (meta.ref_count > 0) {
                log(.warn, "Destroying resource '{s}' with {d} active references", .{
                    meta.name,
                    meta.ref_count,
                });
            }
            
            self.disposeResource(handle.index);
        }
        
        fn disposeResource(self: *Self, index: u32) void {
            const meta = &self.metadata.items[index];
            
            if (meta.state == .disposed) return;
            
            // Call deinit if available
            if (comptime std.meta.hasFn(T, "deinit")) {
                self.resources.items[index].deinit();
            }
            
            meta.state = .disposed;
            meta.generation += 1;
            meta.ref_count = 0;
            
            self.free_list.append(index) catch {
                log(.err, "Failed to add index to free list", .{});
            };
        }
        
        /// Get resource statistics
        pub fn getStats(self: *Self) ResourceStats {
            self.mutex.lock();
            defer self.mutex.unlock();
            
            var stats = ResourceStats{};
            stats.total = @intCast(self.resources.items.len);
            stats.free = @intCast(self.free_list.items.len);
            stats.active = stats.total - stats.free;
            
            for (self.metadata.items) |meta| {
                if (meta.state == .ready) {
                    stats.total_refs += meta.ref_count;
                }
            }
            
            return stats;
        }
    };
}

pub const ResourceStats = struct {
    total: u32 = 0,
    active: u32 = 0,
    free: u32 = 0,
    total_refs: u32 = 0,
};

// Tests
test "ResourceManager lifecycle" {
    const TestResource = struct {
        value: i32,
        deinit_called: *bool,
        
        pub fn deinit(self: *@This()) void {
            self.deinit_called.* = true;
        }
    };
    
    var deinit_called = false;
    var manager = ResourceManager(TestResource).init(std.testing.allocator);
    defer manager.deinit();
    
    const handle = try manager.create("test", .{
        .value = 42,
        .deinit_called = &deinit_called,
    });
    
    const resource = manager.get(handle);
    try std.testing.expect(resource != null);
    try std.testing.expectEqual(@as(i32, 42), resource.?.value);
    
    manager.destroy(handle);
    try std.testing.expect(deinit_called);
    
    const destroyed = manager.get(handle);
    try std.testing.expect(destroyed == null);
}

test "ResourceManager reference counting" {
    const TestResource = struct { value: i32 };
    
    var manager = ResourceManager(TestResource).init(std.testing.allocator);
    defer manager.deinit();
    
    const handle = try manager.create("test", .{ .value = 100 });
    
    try manager.addRef(handle);
    try manager.addRef(handle);
    
    const stats = manager.getStats();
    try std.testing.expectEqual(@as(u32, 1), stats.active);
    
    manager.removeRef(handle);
    manager.removeRef(handle);
    
    // Should still be alive with one implicit reference from create
    const resource = manager.get(handle);
    try std.testing.expect(resource != null);
}

test "Handle generation invalidation" {
    const TestResource = struct { value: i32 };
    
    var manager = ResourceManager(TestResource).init(std.testing.allocator);
    defer manager.deinit();
    
    const handle1 = try manager.create("test", .{ .value = 1 });
    manager.destroy(handle1);
    
    // Old handle should be invalid
    try std.testing.expect(manager.get(handle1) == null);
    
    // New resource reuses slot but with new generation
    const handle2 = try manager.create("test2", .{ .value = 2 });
    try std.testing.expect(handle1.index == handle2.index);
    try std.testing.expect(handle1.generation != handle2.generation);
}
