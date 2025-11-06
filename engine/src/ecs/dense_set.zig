const std = @import("std");
const EntityId = @import("entity_registry.zig").EntityId;

/// DenseSet is a sparse-set data structure for storing components.
/// Provides O(1) insertion, removal, and lookup with cache-friendly iteration.
///
/// Structure:
///   - sparse: HashMap(EntityId -> dense_index) - for fast lookup
///   - entities: ArrayList(EntityId) - dense array of entity IDs
///   - components: ArrayList(T) - dense array of component data (parallel to entities)
///   - versions: ArrayList(u32) - version counter per component for change detection
///
/// Benefits:
///   - Iteration is cache-friendly (linear scan of dense arrays)
///   - Lookup is O(1) via sparse map
///   - Removal is O(1) via swap-remove
///   - Change detection via version tracking
pub fn DenseSet(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,

        // Dense arrays (contiguous, cache-friendly)
        entities: std.ArrayList(EntityId),
        components: std.ArrayList(T),

        // Change detection: version counter per component
        versions: std.ArrayList(u32),
        global_version: u32 = 0,

        // Sparse mapping (entity → dense index)
        sparse: std.AutoHashMap(EntityId, u32),

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .entities = .{},
                .components = .{},
                .versions = .{},
                .sparse = std.AutoHashMap(EntityId, u32).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.entities.deinit(self.allocator);
            self.components.deinit(self.allocator);
            self.versions.deinit(self.allocator);
            self.sparse.deinit();
        }

        /// Add a component for an entity
        pub fn emplace(self: *Self, entity: EntityId, value: T) !void {
            // Check if already exists
            if (self.sparse.contains(entity)) {
                return error.ComponentAlreadyExists;
            }

            const dense_idx: u32 = @intCast(self.components.items.len);

            self.global_version +%= 1; // Increment global version
            try self.entities.append(self.allocator, entity);
            try self.components.append(self.allocator, value);
            try self.versions.append(self.allocator, self.global_version);
            try self.sparse.put(entity, dense_idx);
        }

        /// Get a mutable reference to a component
        /// Marks component as modified (increments version)
        pub fn get(self: *Self, entity: EntityId) ?*T {
            const idx = self.sparse.get(entity) orelse return null;
            self.global_version +%= 1;
            self.versions.items[idx] = self.global_version;
            return &self.components.items[idx];
        }

        /// Get a mutable reference without marking as modified
        pub fn getNoMark(self: *Self, entity: EntityId) ?*T {
            const idx = self.sparse.get(entity) orelse return null;
            return &self.components.items[idx];
        }

        /// Get a const reference to a component
        pub fn getConst(self: *const Self, entity: EntityId) ?*const T {
            const idx = self.sparse.get(entity) orelse return null;
            return &self.components.items[idx];
        }

        /// Check if an entity has this component
        pub fn has(self: *const Self, entity: EntityId) bool {
            return self.sparse.contains(entity);
        }

        /// Remove a component from an entity
        /// Uses swap-remove to maintain dense packing
        pub fn remove(self: *Self, entity: EntityId) bool {
            const idx = self.sparse.get(entity) orelse return false;

            const last_idx = self.components.items.len - 1;

            // If not the last element, swap with last
            if (idx != last_idx) {
                self.components.items[idx] = self.components.items[last_idx];
                self.entities.items[idx] = self.entities.items[last_idx];
                self.versions.items[idx] = self.versions.items[last_idx];

                // Update sparse index for swapped entity
                self.sparse.put(self.entities.items[idx], idx) catch {
                    // This shouldn't fail since we're replacing an existing entry
                    unreachable;
                };
            }

            // Remove last element
            _ = self.components.pop();
            _ = self.entities.pop();
            _ = self.versions.pop();
            _ = self.sparse.remove(entity);

            return true;
        }

        /// Get the number of components stored
        pub fn len(self: *const Self) usize {
            return self.components.items.len;
        }

        /// Clear all components
        pub fn clear(self: *Self) void {
            self.entities.clearRetainingCapacity();
            self.components.clearRetainingCapacity();
            self.versions.clearRetainingCapacity();
            self.sparse.clearRetainingCapacity();
        }

        /// Check if component changed since given version
        pub fn hasChanged(self: *const Self, entity: EntityId, since_version: u32) bool {
            const idx = self.sparse.get(entity) orelse return false;
            return self.versions.items[idx] > since_version;
        }

        /// Get current version of component
        pub fn getVersion(self: *const Self, entity: EntityId) ?u32 {
            const idx = self.sparse.get(entity) orelse return null;
            return self.versions.items[idx];
        }

        /// Get global version counter
        pub fn getGlobalVersion(self: *const Self) u32 {
            return self.global_version;
        }
    };
}

// Tests
test "DenseSet basic operations" {
    const Position = struct { x: f32, y: f32 };

    var set = DenseSet(Position).init(std.testing.allocator);
    defer set.deinit();

    const e1 = EntityId.make(0, 1);
    const e2 = EntityId.make(0, 2);

    // Test emplace
    try set.emplace(e1, .{ .x = 10, .y = 20 });
    try set.emplace(e2, .{ .x = 5, .y = 15 });

    try std.testing.expectEqual(@as(usize, 2), set.len());

    // Test get
    const pos1 = set.get(e1).?;
    try std.testing.expectEqual(@as(f32, 10), pos1.x);
    try std.testing.expectEqual(@as(f32, 20), pos1.y);

    // Test has
    try std.testing.expect(set.has(e1));
    try std.testing.expect(set.has(e2));

    const e3 = EntityId.make(0, 3);
    try std.testing.expect(!set.has(e3));
}

test "DenseSet remove with swap" {
    const Value = struct { val: i32 };

    var set = DenseSet(Value).init(std.testing.allocator);
    defer set.deinit();

    const e1 = EntityId.make(0, 1);
    const e2 = EntityId.make(0, 2);
    const e3 = EntityId.make(0, 3);

    try set.emplace(e1, .{ .val = 100 });
    try set.emplace(e2, .{ .val = 200 });
    try set.emplace(e3, .{ .val = 300 });

    // Remove middle element
    try std.testing.expect(set.remove(e2));

    // Should have 2 elements left
    try std.testing.expectEqual(@as(usize, 2), set.len());

    // e1 and e3 should still be accessible
    try std.testing.expect(set.has(e1));
    try std.testing.expect(set.has(e3));
    try std.testing.expect(!set.has(e2));

    const val1 = set.get(e1).?;
    const val3 = set.get(e3).?;
    try std.testing.expectEqual(@as(i32, 100), val1.val);
    try std.testing.expectEqual(@as(i32, 300), val3.val);
}

test "DenseSet mutation" {
    const Counter = struct { count: i32 };

    var set = DenseSet(Counter).init(std.testing.allocator);
    defer set.deinit();

    const e1 = EntityId.make(0, 1);
    try set.emplace(e1, .{ .count = 0 });

    // Mutate component
    const counter = set.get(e1).?;
    counter.count += 1;

    // Verify mutation
    const counter2 = set.get(e1).?;
    try std.testing.expectEqual(@as(i32, 1), counter2.count);
}

test "DenseSet duplicate emplace fails" {
    const Value = struct { val: i32 };

    var set = DenseSet(Value).init(std.testing.allocator);
    defer set.deinit();

    const e1 = EntityId.make(0, 1);
    try set.emplace(e1, .{ .val = 100 });

    // Trying to emplace again should fail
    const result = set.emplace(e1, .{ .val = 200 });
    try std.testing.expectError(error.ComponentAlreadyExists, result);
}
