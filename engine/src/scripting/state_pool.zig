const std = @import("std");

/// Factory used to create one resource. Called with the allocator (by value)
/// and must return a pointer to the created resource or null on failure.
/// Use a runtime function pointer type so the `StatePool` struct doesn't
/// force comptime evaluation.
pub const CreateFn = *const fn (std.mem.Allocator) ?*anyopaque;

/// Destructor used to free a resource previously created by CreateFn.
pub const DestroyFn = *const fn (*anyopaque) void;

pub const StatePool = struct {
    allocator: std.mem.Allocator,
    pool: std.ArrayList(*anyopaque),
    mutex: std.Thread.Mutex = .{},
    sem: std.Thread.Semaphore,

    create_fn: CreateFn,
    destroy_fn: DestroyFn,

    pub fn init(allocator: std.mem.Allocator, initial_capacity: usize, create_fn: CreateFn, destroy_fn: DestroyFn) !StatePool {
        var s = StatePool{
            .allocator = allocator,
            .pool = std.ArrayList(*anyopaque){},
            .mutex = .{},
            .sem = std.Thread.Semaphore{},
            .create_fn = create_fn,
            .destroy_fn = destroy_fn,
        };

        // Pre-create initial_capacity resources
        for (0..initial_capacity) |_| {
            const r = create_fn(allocator) orelse return createError.UnableToCreateResource;
            try s.pool.append(allocator, r);
            // Each appended resource corresponds to one semaphore post
            s.sem.post();
        }

        return s;
    }

    pub fn deinit(self: *StatePool) void {
        // Drain pool and destroy resources
        self.mutex.lock();
        while (self.pool.items.len > 0) {
            const r = self.pool.items[self.pool.items.len - 1];
            _ = self.pool.orderedRemove(self.pool.items.len - 1);
            self.destroy_fn(r);
        }
        self.mutex.unlock();
        self.pool.deinit(self.allocator);
    }

    /// Acquire a resource from the pool. Blocks until one is available.
    pub fn acquire(self: *StatePool) *anyopaque {
        self.sem.wait();
        self.mutex.lock();
        // Pop last
        const idx = self.pool.items.len - 1;
        const r = self.pool.items[idx];
        _ = self.pool.orderedRemove(idx);
        self.mutex.unlock();
        return r;
    }

    /// Release a resource back to the pool.
    pub fn release(self: *StatePool, r: *anyopaque) void {
        self.mutex.lock();
        _ = self.pool.append(self.allocator, r) catch {
            // If append fails, destroy resource to avoid leak
            self.mutex.unlock();
            self.destroy_fn(r);
            return;
        };
        self.mutex.unlock();
        self.sem.post();
    }
};

pub const createError = error{UnableToCreateResource};
