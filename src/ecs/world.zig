const std = @import("std");
const thread_pool = @import("../threading/thread_pool.zig");
const EntityId = @import("entity_registry.zig").EntityId;
const EntityRegistry = @import("entity_registry.zig").EntityRegistry;
const DenseSet = @import("component_dense_set.zig").DenseSet;
const Scheduler = @import("scheduler.zig").Scheduler;
const Math = @import("../utils/math.zig");

pub const ComponentTypeId = u64;

fn guardTupleType(comptime ComponentTuple: type) type {
    const fields = std.meta.fields(ComponentTuple);
    comptime {
        if (fields.len == 0) @compileError("Component tuple must contain at least one type");
    }

    comptime var types: [fields.len]type = undefined;
    inline for (fields, 0..) |field, idx| {
        const Storage = DenseSet(field.type);
        types[idx] = Storage.ReadGuard;
    }
    return std.meta.Tuple(&types);
}

fn pointerTupleType(comptime ComponentTuple: type) type {
    const fields = std.meta.fields(ComponentTuple);
    comptime var types: [fields.len]type = undefined;
    inline for (fields, 0..) |field, idx| {
        types[idx] = *const field.type;
    }
    return std.meta.Tuple(&types);
}

fn fieldName(comptime idx: usize) []const u8 {
    return std.fmt.comptimePrint("{d}", .{idx});
}

pub fn componentTypeId(comptime T: type) ComponentTypeId {
    return std.hash.Wyhash.hash(0, @typeName(T));
}

pub const World = struct {
    allocator: std.mem.Allocator,
    registry: EntityRegistry,
    storages: std.AutoHashMap(ComponentTypeId, ComponentEntry),
    scheduler: Scheduler,
    frame_index: u64 = 0,
    frame_dt: f32 = 0,
    extraction_positions: std.ArrayList(Math.Vec3) = std.ArrayList(Math.Vec3){},

    pub const Config = struct {
        thread_pool: *thread_pool.ThreadPool,
        scheduler: Scheduler.Config = .{},
    };

    const ComponentEntry = struct {
        storage_ptr: *anyopaque,
        destroy_fn: *const fn (*anyopaque, std.mem.Allocator) void,
        remove_fn: *const fn (*anyopaque, EntityId) bool,
        type_name: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) !World {
        var registry = try EntityRegistry.init(allocator);
        errdefer registry.deinit();

        var storages = std.AutoHashMap(ComponentTypeId, ComponentEntry).init(allocator);
        errdefer storages.deinit();

        var scheduler = try Scheduler.init(allocator, config.thread_pool, config.scheduler);
        errdefer scheduler.deinit();

        return .{
            .allocator = allocator,
            .registry = registry,
            .storages = storages,
            .scheduler = scheduler,
            .frame_index = 0,
            .frame_dt = 0,
            .extraction_positions = std.ArrayList(Math.Vec3){},
        };
    }

    pub fn deinit(self: *World) void {
        var it = self.storages.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.destroy_fn(entry.value_ptr.storage_ptr, self.allocator);
        }
        self.storages.deinit();
        self.scheduler.deinit();
        self.registry.deinit();
        self.extraction_positions.deinit(self.allocator);
    }

    pub fn registryPtr(self: *World) *EntityRegistry {
        return &self.registry;
    }

    pub fn schedulerPtr(self: *World) *Scheduler {
        return &self.scheduler;
    }

    pub fn createEntity(self: *World, tag: u8) EntityId {
        return self.registry.create(tag);
    }

    pub fn destroyEntity(self: *World, entity: EntityId) void {
        if (!self.registry.isAlive(entity)) return;

        var it = self.storages.iterator();
        while (it.next()) |entry| {
            _ = entry.value_ptr.remove_fn(entry.value_ptr.storage_ptr, entity);
        }

        self.registry.destroy(entity);
    }

    pub fn beginFrame(self: *World, frame_index: u64, dt: f32) !void {
        self.frame_index = frame_index;
        self.frame_dt = dt;
        try self.ensureExtractionCapacity(0);
    }

    pub fn frameIndex(self: *const World) u64 {
        return self.frame_index;
    }

    pub fn frameDt(self: *const World) f32 {
        return self.frame_dt;
    }

    pub fn ensureExtractionCapacity(self: *World, count: usize) !void {
        if (count == 0) {
            self.extraction_positions.clearRetainingCapacity();
            return;
        }

        try self.extraction_positions.resize(self.allocator, count);
    }

    pub fn extractionPositions(self: *const World) []const Math.Vec3 {
        return self.extraction_positions.items;
    }

    pub fn extractionPositionsMut(self: *World) []Math.Vec3 {
        return self.extraction_positions.items;
    }

    pub fn addComponent(self: *World, entity: EntityId, component: anytype) !bool {
        const T = @TypeOf(component);
        var storage = try self.ensureStorage(T);
        var guard = storage.acquireWrite();
        defer guard.release();
        return try guard.put(entity, component);
    }

    pub fn removeComponent(self: *World, comptime T: type, entity: EntityId) bool {
        const storage = self.getStorage(T) catch return false;
        var guard = storage.acquireWrite();
        defer guard.release();
        return guard.remove(entity);
    }

    pub fn hasComponent(self: *World, comptime T: type, entity: EntityId) bool {
        const storage = self.getStorage(T) catch return false;
        var guard = storage.acquireRead();
        defer guard.release();
        return guard.get(entity) != null;
    }

    pub fn borrowComponent(self: *World, comptime T: type, entity: EntityId) ?ComponentReadHandle(T) {
        const storage = self.getStorage(T) catch return null;
        var guard = storage.acquireRead();
        if (guard.get(entity)) |ptr| {
            return ComponentReadHandle(T){ .guard = guard, .ptr = ptr };
        }
        guard.release();
        return null;
    }

    pub fn borrowComponentMut(self: *World, comptime T: type, entity: EntityId) ?ComponentWriteHandle(T) {
        const storage = self.getStorage(T) catch return null;
        var guard = storage.acquireWrite();
        if (guard.get(entity)) |ptr| {
            return ComponentWriteHandle(T){ .guard = guard, .ptr = ptr };
        }
        guard.release();
        return null;
    }

    pub fn forEach(self: *World, comptime ComponentTuple: type, context: anytype, callback: anytype) !void {
        const fields = std.meta.fields(ComponentTuple);
        comptime {
            if (fields.len == 0) @compileError("Component tuple must not be empty");
        }

        const GuardTuple = guardTupleType(ComponentTuple);
        var guards: GuardTuple = undefined;

        inline for (fields, 0..) |field, idx| {
            const storage = try self.getStorage(field.type);
            const guard = storage.acquireRead();
            const name = fieldName(idx);
            @field(guards, name) = guard;
        }

        defer {
            inline for (fields, 0..) |_, idx| {
                const name = fieldName(idx);
                @field(guards, name).release();
            }
        }

        var driver_index: usize = 0;
        var driver_len: usize = std.math.maxInt(usize);
        inline for (fields, 0..) |_, idx| {
            const name = fieldName(idx);
            const guard_ptr = &@field(guards, name);
            const len = guard_ptr.len();
            if (len < driver_len) {
                driver_len = len;
                driver_index = idx;
            }
        }

        if (driver_len == 0) return;

        const PtrTuple = pointerTupleType(ComponentTuple);
        var ptrs: PtrTuple = undefined;

        var cursor: usize = 0;
        while (cursor < driver_len) : (cursor += 1) {
            var entity_opt: ?EntityId = null;
            var missing = false;

            inline for (fields, 0..) |_, idx| {
                const name = fieldName(idx);
                const guard_ptr = &@field(guards, name);
                if (missing) continue;

                if (idx == driver_index) {
                    const entity_value = guard_ptr.entityAt(cursor);
                    entity_opt = entity_value;
                    @field(ptrs, name) = guard_ptr.valueAt(cursor);
                } else {
                    if (entity_opt) |ent| {
                        if (guard_ptr.get(ent)) |ptr| {
                            @field(ptrs, name) = ptr;
                        } else {
                            missing = true;
                        }
                    } else {
                        missing = true;
                    }
                }
            }

            if (missing or entity_opt == null) continue;

            const ptrs_copy = ptrs;
            try callback(context, entity_opt.?, ptrs_copy);
        }
    }

    fn ensureStorage(self: *World, comptime T: type) !*DenseSet(T) {
        const type_id = componentTypeId(T);
        if (self.storages.getPtr(type_id)) |entry| {
            return castStoragePtr(T, entry.storage_ptr);
        }

        const storage = try self.allocator.create(DenseSet(T));
        storage.* = DenseSet(T).init(self.allocator);
        const entry = ComponentEntry{
            .storage_ptr = storage,
            .destroy_fn = DenseSet(T).destroyAny,
            .remove_fn = DenseSet(T).removeAny,
            .type_name = @typeName(T),
        };
        try self.storages.put(type_id, entry);
        return storage;
    }

    pub fn getStorage(self: *World, comptime T: type) !*DenseSet(T) {
        const type_id = componentTypeId(T);
        if (self.storages.getPtr(type_id)) |entry| {
            return castStoragePtr(T, entry.storage_ptr);
        }
        return error.ComponentNotRegistered;
    }
};

pub fn ComponentReadHandle(comptime T: type) type {
    return struct {
        guard: DenseSet(T).ReadGuard,
        ptr: *const T,

        pub fn release(self: *ComponentReadHandle(T)) void {
            self.guard.release();
        }

        pub fn value(self: *const ComponentReadHandle(T)) *const T {
            return self.ptr;
        }
    };
}

pub fn ComponentWriteHandle(comptime T: type) type {
    return struct {
        guard: DenseSet(T).WriteGuard,
        ptr: *T,

        pub fn release(self: *ComponentWriteHandle(T)) void {
            self.guard.release();
        }

        pub fn value(self: *const ComponentWriteHandle(T)) *T {
            return self.ptr;
        }
    };
}

fn castStoragePtr(comptime T: type, ptr: *anyopaque) *DenseSet(T) {
    return @ptrFromInt(@intFromPtr(ptr));
}
