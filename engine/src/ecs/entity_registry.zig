const std = @import("std");

/// EntityId is an opaque handle to an entity.
/// Uses generational indices: upper 16 bits = generation, lower 16 bits = index
pub const EntityId = enum(u32) {
    invalid = 0,
    _,

    pub fn generation(self: EntityId) u16 {
        return @intCast((@intFromEnum(self) >> 16) & 0xFFFF);
    }

    pub fn index(self: EntityId) u16 {
        return @intCast(@intFromEnum(self) & 0xFFFF);
    }

    pub fn make(gen: u16, idx: u16) EntityId {
        const value: u32 = (@as(u32, gen) << 16) | @as(u32, idx);
        return @enumFromInt(value);
    }
};

/// EntityRegistry manages entity creation, destruction, and validation
pub const EntityRegistry = struct {
    allocator: std.mem.Allocator,

    // Free list of available entity indices
    free_list: std.ArrayList(u16),

    // Generation counter for each entity slot
    generations: std.ArrayList(u16),

    // Next entity index to allocate (if free_list is empty)
    next_index: u16,

    pub fn init(allocator: std.mem.Allocator) EntityRegistry {
        return .{
            .allocator = allocator,
            .free_list = .{},
            .generations = .{},
            .next_index = 0,
        };
    }

    pub fn deinit(self: *EntityRegistry) void {
        self.free_list.deinit(self.allocator);
        self.generations.deinit(self.allocator);
    }

    /// Create a new entity
    pub fn create(self: *EntityRegistry) !EntityId {
        // Try to reuse a freed slot
        if (self.free_list.items.len > 0) {
            const idx = self.free_list.pop().?; // We know it exists since len > 0
            const gen = self.generations.items[idx];
            return EntityId.make(gen, idx);
        }

        // Allocate a new slot
        const idx = self.next_index;
        if (idx == std.math.maxInt(u16)) {
            return error.TooManyEntities;
        }

        try self.generations.append(self.allocator, 1); // Reserve generation 0 for invalid handle
        self.next_index += 1;

        return EntityId.make(self.generations.items[idx], idx);
    }

    /// Destroy an entity (invalidates the handle)
    pub fn destroy(self: *EntityRegistry, entity: EntityId) void {
        const idx = entity.index();
        const gen = entity.generation();

        // Verify this entity is valid
        if (idx >= self.generations.items.len) return;
        if (self.generations.items[idx] != gen) return; // Already destroyed

        // Increment generation to invalidate old handles
        self.generations.items[idx] +%= 1;

        // Add to free list for reuse
        self.free_list.append(self.allocator, idx) catch {
            // If we can't append to free list, just leak the slot
            // This is better than crashing
        };
    }

    /// Check if an entity handle is still valid
    pub fn isValid(self: *const EntityRegistry, entity: EntityId) bool {
        const idx = entity.index();
        const gen = entity.generation();

        if (idx >= self.generations.items.len) return false;
        return self.generations.items[idx] == gen;
    }
};

// Tests
test "entity creation and validation" {
    var registry = EntityRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const e1 = try registry.create();
    const e2 = try registry.create();

    try std.testing.expect(registry.isValid(e1));
    try std.testing.expect(registry.isValid(e2));
    try std.testing.expect(e1 != e2);
}

test "entity destruction invalidates handle" {
    var registry = EntityRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const e1 = try registry.create();
    try std.testing.expect(registry.isValid(e1));

    registry.destroy(e1);
    try std.testing.expect(!registry.isValid(e1));
}

test "entity slot reuse with generation increment" {
    var registry = EntityRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const e1 = try registry.create();
    const gen1 = e1.generation();
    const idx1 = e1.index();

    registry.destroy(e1);

    const e2 = try registry.create();
    const gen2 = e2.generation();
    const idx2 = e2.index();

    // Should reuse the same index but with incremented generation
    try std.testing.expectEqual(idx1, idx2);
    try std.testing.expectEqual(gen1 + 1, gen2);
    try std.testing.expect(!registry.isValid(e1)); // Old handle is invalid
    try std.testing.expect(registry.isValid(e2)); // New handle is valid
}
