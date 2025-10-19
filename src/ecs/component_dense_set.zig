const std = @import("std");
const EntityId = @import("entity_registry.zig").EntityId;
const simd = @import("../utils/simd.zig");

pub fn DenseSet(comptime T: type) type {
    return struct {
        const Self = @This();
        const invalid_index: u32 = std.math.maxInt(u32);

        allocator: std.mem.Allocator,
        dense: std.ArrayList(T),
        entities: std.ArrayList(EntityId),
        sparse: std.ArrayList(u32),
        rwlock: std.Thread.RwLock = .{},

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .dense = std.ArrayList(T).init(allocator),
                .entities = std.ArrayList(EntityId).init(allocator),
                .sparse = std.ArrayList(u32).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.dense.deinit();
            self.entities.deinit();
            self.sparse.deinit();
        }

        pub fn len(self: *const Self) usize {
            return self.dense.items.len;
        }

        fn ensureSparseCapacity(self: *Self, desired_len: usize) !void {
            if (desired_len <= self.sparse.items.len) return;
            const old_len = self.sparse.items.len;
            try self.sparse.resize(desired_len);
            simd.fillU32(self.sparse.items[old_len..desired_len], invalid_index);
        }

        fn getIndexAssumeLocked(self: *const Self, entity: EntityId) ?u32 {
            const idx = @as(usize, entity.index());
            if (idx >= self.sparse.items.len) return null;
            const dense_index = self.sparse.items[idx];
            if (dense_index == invalid_index) return null;
            return dense_index;
        }

        fn putAssumeLocked(self: *Self, entity: EntityId, value: T) !bool {
            const idx = @as(usize, entity.index());
            try self.ensureSparseCapacity(idx + 1);

            if (self.getIndexAssumeLocked(entity)) |dense_index| {
                self.dense.items[dense_index] = value;
                return false;
            }

            const dense_index = @as(u32, @intCast(self.dense.items.len));
            try self.dense.append(value);
            try self.entities.append(entity);
            self.sparse.items[idx] = dense_index;
            return true;
        }

        fn removeAssumeLocked(self: *Self, entity: EntityId) bool {
            const idx = @as(usize, entity.index());
            if (idx >= self.sparse.items.len) return false;

            const dense_index = self.sparse.items[idx];
            if (dense_index == invalid_index) return false;

            const last_index = self.dense.items.len - 1;
            if (dense_index != last_index) {
                self.dense.items[dense_index] = self.dense.items[last_index];
                const swapped_entity = self.entities.items[last_index];
                self.entities.items[dense_index] = swapped_entity;
                self.sparse.items[@as(usize, swapped_entity.index())] = dense_index;
            }

            _ = self.dense.pop();
            _ = self.entities.pop();
            self.sparse.items[idx] = invalid_index;
            return true;
        }

        fn valueAtConstAssumeLocked(self: *const Self, index: usize) *const T {
            return &self.dense.items[index];
        }

        fn valueAtMutAssumeLocked(self: *Self, index: usize) *T {
            return &self.dense.items[index];
        }

        fn entityAtAssumeLocked(self: *const Self, index: usize) EntityId {
            return self.entities.items[index];
        }

        pub fn acquireRead(self: *Self) ReadGuard {
            self.rwlock.lockShared();
            return .{ .storage = self, .active = true };
        }

        pub fn acquireWrite(self: *Self) WriteGuard {
            self.rwlock.lockExclusive();
            return .{ .storage = self, .active = true };
        }

        pub fn destroyAny(ptr: *anyopaque, allocator: std.mem.Allocator) void {
            const storage: *Self = @ptrCast(ptr);
            storage.deinit();
            allocator.destroy(storage);
        }

        pub fn removeAny(ptr: *anyopaque, entity: EntityId) bool {
            const storage: *Self = @ptrCast(ptr);
            storage.rwlock.lockExclusive();
            defer storage.rwlock.unlockExclusive();
            return storage.removeAssumeLocked(entity);
        }

        pub const ReadGuard = struct {
            storage: *Self,
            active: bool = false,

            pub fn len(self: *const ReadGuard) usize {
                return self.storage.len();
            }

            pub fn release(self: *ReadGuard) void {
                if (!self.active) return;
                self.active = false;
                self.storage.rwlock.unlockShared();
            }

            pub fn entityAt(self: *const ReadGuard, index: usize) EntityId {
                return self.storage.entityAtAssumeLocked(index);
            }

            pub fn valueAt(self: *const ReadGuard, index: usize) *const T {
                return self.storage.valueAtConstAssumeLocked(index);
            }

            pub fn get(self: *const ReadGuard, entity: EntityId) ?*const T {
                if (self.storage.getIndexAssumeLocked(entity)) |dense_index| {
                    return self.storage.valueAtConstAssumeLocked(dense_index);
                }
                return null;
            }

            pub fn items(self: *const ReadGuard) []const T {
                return self.storage.dense.items;
            }
        };

        pub const WriteGuard = struct {
            storage: *Self,
            active: bool = false,

            pub fn len(self: *const WriteGuard) usize {
                return self.storage.len();
            }

            pub fn release(self: *WriteGuard) void {
                if (!self.active) return;
                self.active = false;
                self.storage.rwlock.unlockExclusive();
            }

            pub fn put(self: *WriteGuard, entity: EntityId, value: T) !bool {
                return self.storage.putAssumeLocked(entity, value);
            }

            pub fn get(self: *WriteGuard, entity: EntityId) ?*T {
                if (self.storage.getIndexAssumeLocked(entity)) |dense_index| {
                    return self.storage.valueAtMutAssumeLocked(dense_index);
                }
                return null;
            }

            pub fn remove(self: *WriteGuard, entity: EntityId) bool {
                return self.storage.removeAssumeLocked(entity);
            }

            pub fn items(self: *WriteGuard) []T {
                return self.storage.dense.items;
            }
        };
    };
}
