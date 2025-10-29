const std = @import("std");
const EntityId = @import("entity_registry.zig").EntityId;
const EntityRegistry = @import("entity_registry.zig").EntityRegistry;
const DenseSet = @import("dense_set.zig").DenseSet;
const View = @import("view.zig").View;
const ThreadPool = @import("view.zig").ThreadPool;
const log = @import("../utils/log.zig").log;

/// Metadata for type-erased component storages
const StorageMetadata = struct {
    deinit_fn: *const fn (*anyopaque) void,
    remove_fn: *const fn (*anyopaque, EntityId) void,
    free_fn: *const fn (*anyopaque, std.mem.Allocator) void,
};

/// World is the central ECS registry
pub const World = struct {
    allocator: std.mem.Allocator,
    entity_registry: EntityRegistry,
    storages: std.StringHashMap(*anyopaque),
    storage_metadata: std.StringHashMap(StorageMetadata),
    thread_pool: ?*ThreadPool,

    pub fn init(allocator: std.mem.Allocator, thread_pool: ?*ThreadPool) !World {
        // Register ecs_update subsystem with thread pool if provided
        if (thread_pool) |tp| {
            try tp.registerSubsystem(.{
                .name = "ecs_update",
                .min_workers = 2,
                .max_workers = 8,
                .priority = .normal,
                .work_item_type = .ecs_update,
            });
            log(.INFO, "ecs", "Registered ecs_update subsystem with thread pool", .{});
        }
        
        return .{
            .allocator = allocator,
            .entity_registry = EntityRegistry.init(allocator),
            .storages = std.StringHashMap(*anyopaque).init(allocator),
            .storage_metadata = std.StringHashMap(StorageMetadata).init(allocator),
            .thread_pool = thread_pool,
        };
    }

    pub fn deinit(self: *World) void {
        var it = self.storages.iterator();
        while (it.next()) |entry| {
            const metadata = self.storage_metadata.get(entry.key_ptr.*).?;
            metadata.deinit_fn(entry.value_ptr.*);
            metadata.free_fn(entry.value_ptr.*, self.allocator);
        }
        self.storages.deinit();
        self.storage_metadata.deinit();
        self.entity_registry.deinit();
    }

    pub fn createEntity(self: *World) !EntityId {
        return try self.entity_registry.create();
    }

    pub fn destroyEntity(self: *World, entity: EntityId) void {
        var it = self.storages.iterator();
        while (it.next()) |entry| {
            const metadata = self.storage_metadata.get(entry.key_ptr.*).?;
            metadata.remove_fn(entry.value_ptr.*, entity);
        }
        self.entity_registry.destroy(entity);
    }

    pub fn isValid(self: *const World, entity: EntityId) bool {
        return self.entity_registry.isValid(entity);
    }

    /// Returns the number of active entities
    pub fn entityCount(self: *const World) u32 {
        const total = self.entity_registry.next_index;
        const freed = self.entity_registry.free_list.items.len;
        return @as(u32, total) - @as(u32, @intCast(freed));
    }

    pub fn registerComponent(self: *World, comptime T: type) !void {
        const type_name = @typeName(T);
        if (self.storages.contains(type_name)) return;

        const storage = try self.allocator.create(DenseSet(T));
        storage.* = DenseSet(T).init(self.allocator);

        try self.storages.put(type_name, storage);
        try self.storage_metadata.put(type_name, StorageMetadata{
            .deinit_fn = struct {
                fn call(ptr: *anyopaque) void {
                    const s: *DenseSet(T) = @ptrCast(@alignCast(ptr));
                    s.deinit();
                }
            }.call,
            .remove_fn = struct {
                fn call(ptr: *anyopaque, entity: EntityId) void {
                    const s: *DenseSet(T) = @ptrCast(@alignCast(ptr));
                    _ = s.remove(entity);
                }
            }.call,
            .free_fn = struct {
                fn call(ptr: *anyopaque, allocator: std.mem.Allocator) void {
                    const s: *DenseSet(T) = @ptrCast(@alignCast(ptr));
                    allocator.destroy(s);
                }
            }.call,
        });
    }

    pub fn emplace(self: *World, comptime T: type, entity: EntityId, value: T) !void {
        const type_name = @typeName(T);
        const storage_ptr = self.storages.get(type_name) orelse return error.ComponentNotRegistered;
        const storage: *DenseSet(T) = @ptrCast(@alignCast(storage_ptr));
        try storage.emplace(entity, value);
    }

    pub fn get(self: *World, comptime T: type, entity: EntityId) ?*T {
        const type_name = @typeName(T);
        const storage_ptr = self.storages.get(type_name) orelse return null;
        const storage: *DenseSet(T) = @ptrCast(@alignCast(storage_ptr));
        return storage.get(entity);
    }

    pub fn has(self: *const World, comptime T: type, entity: EntityId) bool {
        const type_name = @typeName(T);
        const storage_ptr = self.storages.get(type_name) orelse return false;
        const storage: *DenseSet(T) = @ptrCast(@alignCast(storage_ptr));
        return storage.has(entity);
    }

    pub fn remove(self: *World, comptime T: type, entity: EntityId) bool {
        const type_name = @typeName(T);
        const storage_ptr = self.storages.get(type_name) orelse return false;
        const storage: *DenseSet(T) = @ptrCast(@alignCast(storage_ptr));
        return storage.remove(entity);
    }

    pub fn view(self: *World, comptime T: type) !View(T) {
        const type_name = @typeName(T);
        const storage_ptr = self.storages.get(type_name) orelse return error.ComponentNotRegistered;
        const storage: *DenseSet(T) = @ptrCast(@alignCast(storage_ptr));
        return View(T){ .storage = storage, .allocator = self.allocator, .thread_pool = self.thread_pool };
    }

    pub fn update(self: *World, comptime T: type, dt: f32) !void {
        comptime {
            if (!@hasDecl(T, "update")) {
                @compileError(@typeName(T) ++ " must implement update(self: *T, dt: f32)");
            }
        }
        var v = try self.view(T);

        // Use parallel dispatch if thread_pool is available
        if (self.thread_pool) |_| {
            const chunk_size = 256; // TODO: Make this configurable
            try v.each_parallel(chunk_size, struct {
                fn updateChunk(entities: []EntityId, components: []T, delta: f32) void {
                    _ = entities; // EntityId not needed for simple update
                    for (components) |*comp| {
                        comp.update(delta);
                    }
                }
            }.updateChunk, dt);
        } else {
            // Fall back to serial iteration
            var iter = v.iterator();
            while (iter.next()) |item| {
                item.component.update(dt);
            }
        }
    }

    pub fn render(self: *World, comptime T: type, context: anytype) !void {
        comptime {
            if (!@hasDecl(T, "render")) {
                @compileError(@typeName(T) ++ " must implement render(self: *const T, context: anytype)");
            }
        }
        const v = try self.view(T);
        var iter = v.constIterator();
        while (iter.next()) |item| {
            item.component.render(context);
        }
    }
};

// ========== Tests ==========

test "World basic operations" {
    const Position = struct { x: f32, y: f32 };

    var world = World.init(std.testing.allocator, null);
    defer world.deinit();

    try world.registerComponent(Position);

    const e1 = try world.createEntity();
    try world.emplace(Position, e1, .{ .x = 10, .y = 20 });

    const pos = world.get(Position, e1).?;
    try std.testing.expectEqual(@as(f32, 10), pos.x);
    try std.testing.expectEqual(@as(f32, 20), pos.y);
}

test "World multiple components per entity" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { x: f32, y: f32 };

    var world = World.init(std.testing.allocator, null);
    defer world.deinit();

    try world.registerComponent(Position);
    try world.registerComponent(Velocity);

    const e1 = try world.createEntity();
    try world.emplace(Position, e1, .{ .x = 10, .y = 20 });
    try world.emplace(Velocity, e1, .{ .x = 1, .y = 2 });

    try std.testing.expect(world.has(Position, e1));
    try std.testing.expect(world.has(Velocity, e1));

    const pos = world.get(Position, e1).?;
    const vel = world.get(Velocity, e1).?;

    try std.testing.expectEqual(@as(f32, 10), pos.x);
    try std.testing.expectEqual(@as(f32, 1), vel.x);
}

test "World entity destruction removes all components" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { x: f32, y: f32 };

    var world = World.init(std.testing.allocator, null);
    defer world.deinit();

    try world.registerComponent(Position);
    try world.registerComponent(Velocity);

    const e1 = try world.createEntity();
    try world.emplace(Position, e1, .{ .x = 10, .y = 20 });
    try world.emplace(Velocity, e1, .{ .x = 1, .y = 2 });

    world.destroyEntity(e1);

    try std.testing.expect(!world.has(Position, e1));
    try std.testing.expect(!world.has(Velocity, e1));
    try std.testing.expect(!world.isValid(e1));
}

test "World view iteration" {
    const Position = struct { x: f32, y: f32 };

    var world = World.init(std.testing.allocator, null);
    defer world.deinit();

    try world.registerComponent(Position);

    const e1 = try world.createEntity();
    const e2 = try world.createEntity();
    const e3 = try world.createEntity();

    try world.emplace(Position, e1, .{ .x = 1, .y = 2 });
    try world.emplace(Position, e2, .{ .x = 3, .y = 4 });
    try world.emplace(Position, e3, .{ .x = 5, .y = 6 });

    var v = try world.view(Position);
    var count: usize = 0;
    var iter = v.iterator();
    while (iter.next()) |_| {
        count += 1;
    }

    try std.testing.expectEqual(@as(usize, 3), count);
}

test "World update dispatch" {
    const Counter = struct {
        count: i32,

        pub fn update(self: *@This(), dt: f32) void {
            _ = dt;
            self.count += 1;
        }
    };

    var world = World.init(std.testing.allocator, null);
    defer world.deinit();

    try world.registerComponent(Counter);

    const e1 = try world.createEntity();
    const e2 = try world.createEntity();

    try world.emplace(Counter, e1, .{ .count = 0 });
    try world.emplace(Counter, e2, .{ .count = 5 });

    try world.update(Counter, 0.016);

    try std.testing.expectEqual(@as(i32, 1), world.get(Counter, e1).?.count);
    try std.testing.expectEqual(@as(i32, 6), world.get(Counter, e2).?.count);
}

test "World render dispatch" {
    const Particle = struct {
        position: [2]f32,

        pub fn render(self: *const @This(), context: *std.ArrayList([2]f32)) void {
            context.append(std.testing.allocator, self.position) catch {};
        }
    };

    var world = World.init(std.testing.allocator, null);
    defer world.deinit();

    try world.registerComponent(Particle);

    const e1 = try world.createEntity();
    const e2 = try world.createEntity();

    try world.emplace(Particle, e1, .{ .position = .{ 1, 2 } });
    try world.emplace(Particle, e2, .{ .position = .{ 3, 4 } });

    var batch: std.ArrayList([2]f32) = .{};
    defer batch.deinit(std.testing.allocator);

    try world.render(Particle, &batch);

    try std.testing.expectEqual(@as(usize, 2), batch.items.len);
    try std.testing.expectEqual(@as(f32, 1), batch.items[0][0]);
    try std.testing.expectEqual(@as(f32, 3), batch.items[1][0]);
}

test "World parallel dispatch with ThreadPool" {
    const Velocity = struct {
        const Self = @This();
        x: f32,
        y: f32,
        update_count: u32 = 0,

        pub fn update(self: *Self, dt: f32) void {
            self.x += dt;
            self.y += dt * 2;
            self.update_count += 1;
        }
    };

    // Initialize ThreadPool with 4 worker threads
    var thread_pool = ThreadPool.init(std.testing.allocator, 4) catch |err| {
        std.debug.print("Failed to initialize ThreadPool: {}\n", .{err});
        return error.SkipZigTest;
    };
    defer thread_pool.deinit();

    //Register ECS subsystem
    const SubsystemConfig = @import("view.zig").SubsystemConfig;
    const WorkItemType = @import("view.zig").WorkItemType;
    const WorkPriority = @import("view.zig").WorkPriority;

    const ecs_subsystem = SubsystemConfig{
        .name = "ecs_update",
        .min_workers = 1,
        .max_workers = 4,
        .priority = WorkPriority.normal,
        .work_item_type = WorkItemType.ecs_update,
    };
    try thread_pool.registerSubsystem(ecs_subsystem);

    // Start the thread pool with 4 workers
    try thread_pool.start(4);

    var world = World.init(std.testing.allocator, &thread_pool);
    defer world.deinit();

    try world.registerComponent(Velocity);

    // Create 1000 entities for parallel testing
    const num_entities = 1000;
    var entities: [num_entities]EntityId = undefined;

    for (0..num_entities) |i| {
        entities[i] = try world.createEntity();
        try world.emplace(Velocity, entities[i], Velocity{
            .x = @as(f32, @floatFromInt(i)),
            .y = @as(f32, @floatFromInt(i)) * 2,
        });
    }

    // Update with parallel dispatch
    const dt: f32 = 0.016;
    try world.update(Velocity, dt);

    // Verify all entities were updated
    for (0..num_entities) |i| {
        const vel = world.get(Velocity, entities[i]) orelse unreachable;
        const expected_x = @as(f32, @floatFromInt(i)) + dt;
        const expected_y = @as(f32, @floatFromInt(i)) * 2 + dt * 2;

        try std.testing.expectApproxEqAbs(expected_x, vel.x, 0.001);
        try std.testing.expectApproxEqAbs(expected_y, vel.y, 0.001);
        try std.testing.expectEqual(@as(u32, 1), vel.update_count);
    }
}

test "World parallel vs serial correctness" {
    const Counter = struct {
        const Self = @This();
        value: i32,

        pub fn update(self: *Self, dt: f32) void {
            self.value += @as(i32, @intFromFloat(dt * 100));
        }
    };

    const num_entities = 500;
    const dt: f32 = 0.016;

    // Test with parallel dispatch
    {
        var thread_pool = ThreadPool.init(std.testing.allocator, 4) catch return error.SkipZigTest;
        defer thread_pool.deinit();

        // Register ECS subsystem
        const SubsystemConfig = @import("view.zig").SubsystemConfig;
        const WorkItemType = @import("view.zig").WorkItemType;
        const WorkPriority = @import("view.zig").WorkPriority;

        const ecs_subsystem = SubsystemConfig{
            .name = "ecs_update",
            .min_workers = 1,
            .max_workers = 4,
            .priority = WorkPriority.normal,
            .work_item_type = WorkItemType.ecs_update,
        };
        try thread_pool.registerSubsystem(ecs_subsystem);

        // Start the thread pool with 4 workers
        try thread_pool.start(4);

        var world = World.init(std.testing.allocator, &thread_pool);
        defer world.deinit();

        try world.registerComponent(Counter);

        var entities: [num_entities]EntityId = undefined;
        for (0..num_entities) |i| {
            entities[i] = try world.createEntity();
            try world.emplace(Counter, entities[i], Counter{ .value = @as(i32, @intCast(i)) });
        }

        try world.update(Counter, dt);

        // Verify results
        for (0..num_entities) |i| {
            const counter = world.get(Counter, entities[i]) orelse unreachable;
            const expected = @as(i32, @intCast(i)) + @as(i32, @intFromFloat(dt * 100));
            try std.testing.expectEqual(expected, counter.value);
        }
    }

    // Test with serial dispatch (null thread_pool)
    {
        var world = World.init(std.testing.allocator, null);
        defer world.deinit();

        try world.registerComponent(Counter);

        var entities: [num_entities]EntityId = undefined;
        for (0..num_entities) |i| {
            entities[i] = try world.createEntity();
            try world.emplace(Counter, entities[i], Counter{ .value = @as(i32, @intCast(i)) });
        }

        try world.update(Counter, dt);

        // Verify results match parallel
        for (0..num_entities) |i| {
            const counter = world.get(Counter, entities[i]) orelse unreachable;
            const expected = @as(i32, @intCast(i)) + @as(i32, @intFromFloat(dt * 100));
            try std.testing.expectEqual(expected, counter.value);
        }
    }
}
