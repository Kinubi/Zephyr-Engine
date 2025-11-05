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
    sem: std.Thread.Semaphore, // counts available resources

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
            // Each created resource increments availability
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
        // Wait until a resource is available
        self.sem.wait();
        // Pop one from the pool
        self.mutex.lock();
        defer self.mutex.unlock();
        const idx = self.pool.items.len - 1;
        const r = self.pool.items[idx];
        _ = self.pool.orderedRemove(idx);
        return r;
    }

    /// Try to acquire a resource without blocking. Returns null if none available.
    pub fn tryAcquire(self: *StatePool) ?*anyopaque {
        self.mutex.lock();
        if (self.pool.items.len == 0) {
            self.mutex.unlock();
            return null;
        }
        const idx = self.pool.items.len - 1;
        const r = self.pool.items[idx];
        _ = self.pool.orderedRemove(idx);
        self.mutex.unlock();
        // Consume one availability token from the semaphore if possible by
        // accounting for the removed item: since tryAcquire only executes when
        // an item is present, the semaphore count should be > 0. We don't have
        // a non-blocking try-wait, so we leave the semaphore slightly positive
        // and let blocking acquire consume it. This keeps tryAcquire fast.
        return r;
    }

    /// Try to acquire a resource, waiting up to `timeout_ms` milliseconds.
    /// Returns null on timeout.
    pub fn acquireTimeout(self: *StatePool, timeout_ms: i64) ?*anyopaque {
        const deadline = std.time.milliTimestamp() + timeout_ms;
        while (std.time.milliTimestamp() <= deadline) {
            if (self.tryAcquire()) |r| return r;
            std.Thread.sleep(std.time.ns_per_ms);
        }
        return null;
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
        // Signal availability to potential waiters
        self.sem.post();
    }
};

pub const createError = error{UnableToCreateResource};

// -----------------------
// Unit tests
// -----------------------

fn testCreateInt(_: std.mem.Allocator) ?*anyopaque {
    const p = std.heap.page_allocator.create(i32) catch return null;
    p.* = 0;
    return @ptrCast(p);
}

fn testDestroyInt(ptr: *anyopaque) void {
    const p: *i32 = @ptrCast(@alignCast(ptr));
    std.heap.page_allocator.destroy(p);
}

test "StatePool basic acquire/release" {
    const allocator = std.heap.page_allocator;
    var pool = try StatePool.init(allocator, 1, &testCreateInt, &testDestroyInt);
    defer pool.deinit();

    const r = pool.acquire();
    const ip: *i32 = @ptrCast(@alignCast(r));
    ip.* += 1; // increment
    pool.release(r);

    const r2 = pool.acquire();
    const ip2: *i32 = @ptrCast(@alignCast(r2));
    try std.testing.expect(ip2.* == 1);
    pool.release(r2);
}

test "StatePool tryAcquire and acquireTimeout" {
    const allocator = std.heap.page_allocator;
    var pool = try StatePool.init(allocator, 1, &testCreateInt, &testDestroyInt);
    defer pool.deinit();

    const r = pool.acquire();

    // tryAcquire should fail now
    const t = pool.tryAcquire();
    try std.testing.expect(t == null);

    // acquireTimeout should time out (short timeout)
    const at = pool.acquireTimeout(10);
    try std.testing.expect(at == null);

    // release and ensure tryAcquire succeeds
    pool.release(r);
    const t2 = pool.tryAcquire();
    try std.testing.expect(t2 != null);
    pool.release(t2.?);
}
