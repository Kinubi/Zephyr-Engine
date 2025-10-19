const std = @import("std");

/// EntityId packs index, generation, and debug tag into 64 bits.
pub const EntityId = struct {
    raw: u64,

    pub const invalid = EntityId{ .raw = 0 };

    pub fn index(self: EntityId) u32 {
        return @intCast(self.raw & 0xFFFF_FFFF);
    }

    pub fn generation(self: EntityId) u32 {
        return @intCast((self.raw >> 32) & 0x00FF_FFFF);
    }

    pub fn tag(self: EntityId) u8 {
        return @intCast(self.raw >> 56);
    }

    pub fn eql(a: EntityId, b: EntityId) bool {
        return a.raw == b.raw;
    }

    pub fn hash(self: EntityId) u64 {
        return std.hash.Wyhash.hash(0, std.mem.asBytes(&self.raw));
    }
};

/// Thread-safe registry handing out recycled entity ids.
pub const EntityRegistry = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    generations: std.ArrayList(u32),
    free_list: std.ArrayList(u32),

    pub fn init(allocator: std.mem.Allocator) !EntityRegistry {
        return .{
            .allocator = allocator,
            .generations = try std.ArrayList(u32).initCapacity(allocator, 1024),
            .free_list = std.ArrayList(u32).init(allocator),
        };
    }

    pub fn deinit(self: *EntityRegistry) void {
        self.generations.deinit();
        self.free_list.deinit();
    }

    pub fn create(self: *EntityRegistry, tag: u8) EntityId {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.free_list.popOrNull()) |idx| {
            const old_generation = self.generations.items[idx];
            const new_generation = (old_generation + 1) & 0x00FF_FFFF;
            self.generations.items[idx] = new_generation;
            return composeId(idx, new_generation, tag);
        }

        const idx: u32 = @intCast(self.generations.items.len);
        self.generations.appendAssumeCapacity(0);
        return composeId(idx, 1, tag);
    }

    pub fn destroy(self: *EntityRegistry, id: EntityId) void {
        if (!self.isAlive(id)) return;

        self.mutex.lock();
        defer self.mutex.unlock();

        const idx = id.index();
        if (idx >= self.generations.items.len) return;

        if (self.free_list.contains(idx)) return;
        self.free_list.append(idx) catch return;
    }

    pub fn isAlive(self: *EntityRegistry, id: EntityId) bool {
        const idx = id.index();
        if (idx >= self.generations.items.len) return false;

        const stored = self.generations.items[idx];
        return stored == id.generation();
    }

    pub fn setTag(id: *EntityId, tag: u8) void {
        const composed = composeId(id.index(), id.generation(), tag);
        id.* = composed;
    }

    pub fn reserve(self: *EntityRegistry, count: usize) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (count <= self.generations.capacity) return;
        try self.generations.ensureTotalCapacity(self.allocator, count);
    }

    fn composeId(index: u32, generation: u32, tag: u8) EntityId {
        const raw = (@as(u64, tag) << 56) | (@as(u64, generation & 0x00FF_FFFF) << 32) | @as(u64, index);
        return .{ .raw = raw };
    }
};

comptime {
    std.debug.assert(EntityId.invalid.raw == 0);
}
