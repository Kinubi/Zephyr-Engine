const std = @import("std");

pub const ComponentStorage = struct {
    allocator: std.mem.Allocator,
    // store opaque pointers so runtime lookup is type-erased
    items: std.ArrayList(?*anyopaque),
    free_list: std.ArrayList(usize),

    pub fn init(allocator: std.mem.Allocator) ComponentStorage {
        return ComponentStorage{ .allocator = allocator, .items = std.ArrayList(?*anyopaque){}, .free_list = std.ArrayList(usize){} };
    }

    pub fn deinit(self: *ComponentStorage) void {
        // We don't have type information to destroy the heap-allocated
        // component instances here. Ownership semantics: Registry owns the
        // component pointers but cannot call destructor without knowing T.
        // For now, we leak the component instances (acceptable for the
        // PoC). A future improvement is to store destructor callbacks per type.
        self.items.deinit(self.allocator);
        self.free_list.deinit(self.allocator);
    }

    /// Emplace a component of compile-time type T into this storage. The storage
    /// will allocate a T instance on the heap and keep an opaque pointer to it.
    pub fn emplaceTyped(self: *ComponentStorage, comptime T: type, allocator: std.mem.Allocator, value: T) !usize {
        const p = try allocator.create(T);
        p.* = value;
        const op: *anyopaque = @as(*anyopaque, p);
        if (self.free_list.items.len > 0) {
            const idx = self.free_list.items[self.free_list.items.len - 1];
            self.free_list.items.len -= 1;
            self.items.items[idx] = op;
            return idx;
        } else {
            try self.items.append(allocator, op);
            return self.items.items.len - 1;
        }
    }

    pub fn get(self: *ComponentStorage, handle: usize) ?*anyopaque {
        if (handle >= self.items.items.len) return null;
        return self.items.items[handle];
    }

    pub fn remove(self: *ComponentStorage, allocator: std.mem.Allocator, handle: usize) void {
        if (handle >= self.items.items.len) return;
        if (self.items.items[handle]) |p| {
            self.allocator.destroy(p);
            self.items.items[handle] = null;
            try self.free_list.append(allocator, handle) catch std.debug.panic("free_list append OOM");
        }
    }

    pub fn reserve(self: *ComponentStorage, allocator: std.mem.Allocator, n: usize) !void {
        try self.items.ensureCapacity(allocator, n);
        try self.free_list.ensureCapacity(allocator, n);
    }
};

/// A type-erased wrapper for component storages so Registry can store many types
pub const ComponentStorageAny = struct {
    storage_ptr: *anyopaque,
};

pub fn make_any(storage: *ComponentStorage) ComponentStorageAny {
    return ComponentStorageAny{ .storage_ptr = @as(*anyopaque, storage) };
}

/// Allocate a typed storage and return a ComponentStorageAny with vtable populated.
pub fn create_storage(allocator: std.mem.Allocator) !ComponentStorageAny {
    const s = try allocator.create(ComponentStorage);
    s.* = ComponentStorage.init(allocator);
    return ComponentStorageAny{ .storage_ptr = @as(*anyopaque, s) };
}

// Top-level comptime trampoline functions. Specializing these with `T` yields
// a concrete function value we can store in `ComponentStorageAny`.
// Helpers for operating on the runtime ComponentStorage
pub fn emplaceTyped(comptime T: type, storage_any: ComponentStorageAny, allocator: std.mem.Allocator, value: T) !usize {
    const s: *ComponentStorage = @ptrCast(@alignCast(storage_any.storage_ptr));
    return s.*.emplaceTyped(T, allocator, value);
}

pub fn getOpaque(storage_any: ComponentStorageAny, handle: usize) ?*anyopaque {
    const s: *ComponentStorage = @ptrCast(@alignCast(storage_any.storage_ptr));
    return s.get(handle);
}

pub fn deinit_storage(storage_any: ComponentStorageAny) void {
    const s: *ComponentStorage = @ptrCast(@alignCast(storage_any.storage_ptr));
    s.deinit();
}

pub fn destroy_storage(storage_any: ComponentStorageAny, allocator: std.mem.Allocator) void {
    const s: *ComponentStorage = @ptrCast(@alignCast(storage_any.storage_ptr));
    allocator.destroy(s);
}
