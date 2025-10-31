const std = @import("std");

pub const Action = struct {
    id: u64,
    ctx: *anyopaque,
    success: bool,
    // Owned message slice (allocator-owned). Empty slice means no message.
    message: ?[]u8,
};

pub const ActionQueue = struct {
    allocator: std.mem.Allocator,
    queue: std.ArrayList(Action),
    mutex: std.Thread.Mutex = .{},
    sem: std.Thread.Semaphore,

    pub fn init(allocator: std.mem.Allocator) !ActionQueue {
        return ActionQueue{
            .allocator = allocator,
            .queue = std.ArrayList(Action){},
            .mutex = .{},
            .sem = std.Thread.Semaphore{},
        };
    }

    pub fn deinit(self: *ActionQueue) void {
        // Drain and free any messages still in the queue
        self.mutex.lock();
        while (self.queue.items.len > 0) {
            const a = self.queue.items[self.queue.items.len - 1];
            _ = self.queue.orderedRemove(self.queue.items.len - 1);
            if (a.message) |m| {
                if (m.len > 0) {
                    const tmp: [*]const u8 = @ptrCast(m.ptr);
                    const msg_slice: []u8 = @constCast(tmp)[0..m.len];
                    self.allocator.free(msg_slice);
                }
            }
        }
        self.mutex.unlock();
        self.queue.deinit(self.allocator);
    }

    pub fn push(self: *ActionQueue, a: Action) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.queue.append(self.allocator, a);
        self.sem.post();
    }

    /// Blocking pop: waits until an action is available and returns it.
    pub fn pop(self: *ActionQueue) Action {
        self.sem.wait();
        self.mutex.lock();
        defer self.mutex.unlock();
        const act = self.queue.items[0];
        _ = self.queue.orderedRemove(0);
        return act;
    }

    /// Non-blocking try-pop
    pub fn tryPop(self: *ActionQueue) ?Action {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.queue.items.len == 0) return null;
        const act = self.queue.items[0];
        _ = self.queue.orderedRemove(0);
        return act;
    }
};
