const std = @import("std");
const ecs = @import("../ecs.zig");
const World = ecs.World;

const Position = struct {
    x: f32,
    y: f32,
};

const Velocity = struct {
    x: f32,
    y: f32,
};

const Health = struct {
    hp: f32,
};

test "QueryIterator basic usage" {
    var world = try World.init(std.testing.allocator);
    defer world.deinit();

    // Register components
    try world.registerComponent(Position);
    try world.registerComponent(Velocity);
    try world.registerComponent(Health);

    // Create entities
    // 1. Pos + Vel
    const e1 = try world.createEntity();
    try world.add(e1, Position{ .x = 1, .y = 1 });
    try world.add(e1, Velocity{ .x = 1, .y = 0 });

    // 2. Pos only
    const e2 = try world.createEntity();
    try world.add(e2, Position{ .x = 2, .y = 2 });

    // 3. Pos + Vel + Health
    const e3 = try world.createEntity();
    try world.add(e3, Position{ .x = 3, .y = 3 });
    try world.add(e3, Velocity{ .x = 0, .y = 1 });
    try world.add(e3, Health{ .hp = 100 });

    // Query for Pos + Vel
    var query = try world.query(struct {
        pos: *Position,
        vel: *Velocity,
    });
    defer query.deinit();

    var count: usize = 0;
    while (query.next()) |item| {
        count += 1;
        // Verify data
        if (item.pos.x == 1) {
            try std.testing.expectEqual(item.vel.x, 1);
        } else if (item.pos.x == 3) {
            try std.testing.expectEqual(item.vel.x, 0);
        } else {
            try std.testing.expect(false); // Should not match e2
        }
    }
    try std.testing.expectEqual(count, 2);
}

test "QueryIterator optional components" {
    var world = try World.init(std.testing.allocator);
    defer world.deinit();

    try world.registerComponent(Position);
    try world.registerComponent(Velocity);

    const e1 = try world.createEntity();
    try world.add(e1, Position{ .x = 1, .y = 1 });
    try world.add(e1, Velocity{ .x = 1, .y = 0 });

    const e2 = try world.createEntity();
    try world.add(e2, Position{ .x = 2, .y = 2 });

    var query = try world.query(struct {
        pos: *Position,
        vel: ?*Velocity,
    });
    defer query.deinit();

    var count: usize = 0;
    while (query.next()) |item| {
        count += 1;
        if (item.pos.x == 1) {
            try std.testing.expect(item.vel != null);
        } else if (item.pos.x == 2) {
            try std.testing.expect(item.vel == null);
        }
    }
    try std.testing.expectEqual(count, 2);
}
