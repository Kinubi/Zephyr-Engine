const std = @import("std");
const CS = @import("component_storage.zig");
const worker = @import("worker.zig");
const TP = @import("../threading/thread_pool.zig");

pub const EntityId = usize;

pub const Registry = struct {
    allocator: std.mem.Allocator,
    next_id: EntityId,
    next_component_type_id: usize,
    // Map type_id -> ComponentStorageAny
    storages: std.HashMap(usize, CS.ComponentStorageAny, std.hash_map.AutoContext(usize), 64),
    // Map type_id -> pointer to inner map (EntityId -> handle)
    entity_maps: std.HashMap(usize, *std.HashMap(EntityId, usize, std.hash_map.AutoContext(EntityId), 16), std.hash_map.AutoContext(usize), 64),

    pub fn init(allocator: std.mem.Allocator) Registry {
        return Registry{
            .allocator = allocator,
            .next_id = 1,
            .next_component_type_id = 1,
            .storages = std.HashMap(usize, CS.ComponentStorageAny, std.hash_map.AutoContext(usize), 64).init(allocator),
            .entity_maps = std.HashMap(usize, *std.HashMap(EntityId, usize, std.hash_map.AutoContext(EntityId), 16), std.hash_map.AutoContext(usize), 64).init(allocator),
        };
    }

    pub fn create(self: *Registry) EntityId {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    /// Register a component type T and create its storage. Returns a runtime type id.
    pub fn registerComponentType(self: *Registry) !usize {
        const type_id = self.next_component_type_id;
        self.next_component_type_id += 1;

        const any = try CS.create_storage(self.allocator);
        try self.storages.put(type_id, any);

        const InnerMap = std.HashMap(EntityId, usize, std.hash_map.AutoContext(EntityId), 16);
        const im_ptr = try self.allocator.create(InnerMap);
        im_ptr.* = InnerMap.init(self.allocator);
        try self.entity_maps.put(type_id, im_ptr);

        return type_id;
    }

    /// NOTE: emplaceComponent (runtime-typed insertion) is intentionally not
    /// implemented in this PoC. Use `emplaceComponentFor(comptime T, ...)` when
    /// the caller knows T at compile time so the storage can allocate T.
    /// Comptime emplace for use when the caller knows T at compile-time.
    pub fn emplaceComponentFor(self: *Registry, comptime T: type, type_id: usize, entity: EntityId, value_ptr: *T) !usize {
        const storage_any = self.storages.get(type_id) orelse return error.InvalidComponentType;
        const handle = try CS.emplaceTyped(T, storage_any, self.allocator, value_ptr.*);
        const im_ptr = self.entity_maps.get(type_id) orelse return error.InvalidComponentType;
        try im_ptr.put(entity, handle);
        return handle;
    }

    pub fn getComponent(self: *Registry, type_id: usize, handle: usize) ?*anyopaque {
        const storage_any = self.storages.get(type_id) orelse return null;
        return CS.getOpaque(storage_any, handle);
    }

    pub fn getComponentByEntity(self: *Registry, type_id: usize, entity: EntityId) ?*anyopaque {
        const im_ptr = self.entity_maps.get(type_id) orelse return null;
        const handle = im_ptr.get(entity) orelse return null;
        return self.getComponent(type_id, handle);
    }

    pub fn submitComponent(self: *Registry, type_id: usize, handle: usize, pool: *TP.ThreadPool, priority: TP.WorkPriority, dt: f32, updater: *const fn (*anyopaque, f32) void) !void {
        const alloc = pool.allocator;
        const job = try alloc.create(worker.ComponentJob);
        job.* = worker.ComponentJob{ .type_id = type_id, .comp_handle = handle, .registry_ctx = @as(*anyopaque, self), .updater = updater, .dt = dt };

        const work_item = TP.createCustomWork(0, @as(*anyopaque, job), @sizeOf(worker.ComponentJob), priority, worker.worker_fn, @as(*anyopaque, pool));
        try pool.submitWork(work_item);
    }

    pub fn submitComponentTypeChunked(self: *Registry, type_id: usize, pool: *TP.ThreadPool, priority: TP.WorkPriority, chunk_size: usize, dt: f32, updater: *const fn (*anyopaque, f32) void) !void {
        if (chunk_size == 0) return error.InvalidChunkSize;

        const im_ptr = self.entity_maps.get(type_id) orelse return error.InvalidComponentType;

        var handles = std.ArrayList(usize){};
        defer handles.deinit(self.allocator);
        var entities = std.ArrayList(EntityId){};
        defer entities.deinit(self.allocator);

        var it = im_ptr.iterator();
        while (it.next()) |entry| {
            const entity = entry.key_ptr.*;
            const handle = entry.value_ptr.*;

            try entities.append(self.allocator, entity);
            try handles.append(self.allocator, handle);

            if (handles.items.len == chunk_size) {
                try self.submitChunkJob(type_id, handles.items, entities.items, pool, priority, dt, updater);
                handles.clearRetainingCapacity();
                entities.clearRetainingCapacity();
            }
        }

        if (handles.items.len > 0) {
            try self.submitChunkJob(type_id, handles.items, entities.items, pool, priority, dt, updater);
        }
    }

    fn submitChunkJob(self: *Registry, type_id: usize, handles_src: []const usize, entities_src: []const EntityId, pool: *TP.ThreadPool, priority: TP.WorkPriority, dt: f32, updater: *const fn (*anyopaque, f32) void) !void {
        if (handles_src.len == 0) return;
        std.debug.assert(handles_src.len == entities_src.len);

        const alloc = pool.allocator;

        const handles_copy = try alloc.alloc(usize, handles_src.len);
        const entities_copy = try alloc.alloc(EntityId, entities_src.len);
        std.mem.copy(usize, handles_copy, handles_src);
        std.mem.copy(EntityId, entities_copy, entities_src);

        const job = try alloc.create(worker.ComponentChunkJob);
        job.* = worker.ComponentChunkJob{
            .type_id = type_id,
            .handles = handles_copy,
            .entities = entities_copy,
            .registry_ctx = @as(*anyopaque, self),
            .updater = updater,
            .dt = dt,
            .allocator = alloc,
        };

        const work_item = TP.createCustomWork(0, @as(*anyopaque, job), @sizeOf(worker.ComponentChunkJob), priority, worker.chunk_worker_fn, null);
        try pool.submitWork(work_item);
    }

    pub fn deinit(self: *Registry) void {
        // Deinitialize inner maps and storages
        var it = self.entity_maps.valueIterator();
        while (it.next()) |im_ptr| {
            const inner = im_ptr.*;
            inner.deinit();
            self.allocator.destroy(inner);
        }

        var sit = self.storages.valueIterator();
        while (sit.next()) |any| {
            CS.deinit_storage(any.*);
            CS.destroy_storage(any.*, self.allocator);
        }

        // finally deinit the hashmaps themselves
        self.entity_maps.deinit();
        self.storages.deinit();
    }
};
