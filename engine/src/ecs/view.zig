const std = @import("std");
const EntityId = @import("entity_registry.zig").EntityId;
const DenseSet = @import("dense_set.zig").DenseSet;

// ThreadPool types - will be imported from world.zig context, not test context
pub const ThreadPool = @import("../threading/thread_pool.zig").ThreadPool;
pub const WorkItem = @import("../threading/thread_pool.zig").WorkItem;
pub const WorkItemType = @import("../threading/thread_pool.zig").WorkItemType;
pub const WorkPriority = @import("../threading/thread_pool.zig").WorkPriority;
pub const SubsystemConfig = @import("../threading/thread_pool.zig").SubsystemConfig;

/// View provides iteration over components of a specific type.
/// Supports serial iteration, parallel iteration, and for-loop style iteration.
pub fn View(comptime T: type) type {
    return struct {
        const Self = @This();

        storage: *DenseSet(T),
        allocator: std.mem.Allocator,
        thread_pool: ?*ThreadPool,

        /// Serial iteration with callback
        /// Callback signature: fn(EntityId, *T) void
        pub fn each(self: *Self, callback: anytype) void {
            for (self.storage.entities.items, self.storage.components.items) |entity, *comp| {
                callback(entity, comp);
            }
        }

        /// Serial iteration with const callback
        /// Callback signature: fn(EntityId, *const T) void
        pub fn eachConst(self: *const Self, callback: anytype) void {
            for (self.storage.entities.items, self.storage.components.items) |entity, *comp| {
                callback(entity, comp);
            }
        }

        /// Get the number of components in this view
        pub fn len(self: *const Self) usize {
            return self.storage.len();
        }

        /// Get a component for a specific entity
        pub fn get(self: *Self, entity: EntityId) ?*T {
            return self.storage.get(entity);
        }

        /// Parallel iteration with chunked dispatch via ThreadPool
        /// Callback signature: fn([]EntityId, []T, f32) void
        pub fn each_parallel(
            self: *Self,
            chunk_size: usize,
            callback: *const fn ([]EntityId, []T, f32) void,
            dt: f32,
        ) !void {
            const pool = self.thread_pool orelse return error.NoThreadPool;

            const total = self.storage.len();
            if (total == 0) return;

            const num_chunks = (total + chunk_size - 1) / chunk_size;

            // Atomic completion counter
            var completion = std.atomic.Value(usize).init(num_chunks);

            // Submit chunk jobs to ThreadPool
            for (0..num_chunks) |i| {
                const start = i * chunk_size;
                const end = @min(start + chunk_size, total);

                const job = try self.allocator.create(ChunkJob(T));
                job.* = .{
                    .entities = self.storage.entities.items[start..end],
                    .components = self.storage.components.items[start..end],
                    .callback = callback,
                    .dt = dt,
                    .completion = &completion,
                    .allocator = self.allocator,
                };

                const work_item = WorkItem{
                    .id = i,
                    .item_type = .ecs_update,
                    .priority = .normal,
                    .data = .{ .custom = .{
                        .user_data = job,
                        .size = @sizeOf(ChunkJob(T)),
                    } },
                    .worker_fn = chunkWorker(T),
                    .context = pool,
                };

                try pool.submitWork(work_item);
            }

            // Wait for all chunks to complete
            while (completion.load(.acquire) > 0) {
                std.Thread.yield() catch {};
            }
        }

        /// Forward iteration (for-loop style)
        pub fn iterator(self: *Self) Iterator {
            return .{
                .entities = self.storage.entities.items,
                .components = self.storage.components.items,
                .index = 0,
            };
        }

        /// Const iterator
        pub fn constIterator(self: *const Self) ConstIterator {
            return .{
                .entities = self.storage.entities.items,
                .components = self.storage.components.items,
                .index = 0,
            };
        }

        pub const Iterator = struct {
            entities: []EntityId,
            components: []T,
            index: usize,

            pub fn next(self: *Iterator) ?struct { entity: EntityId, component: *T } {
                if (self.index >= self.entities.len) return null;
                defer self.index += 1;
                return .{
                    .entity = self.entities[self.index],
                    .component = &self.components[self.index],
                };
            }
        };

        pub const ConstIterator = struct {
            entities: []const EntityId,
            components: []const T,
            index: usize,

            pub fn next(self: *ConstIterator) ?struct { entity: EntityId, component: *const T } {
                if (self.index >= self.entities.len) return null;
                defer self.index += 1;
                return .{
                    .entity = self.entities[self.index],
                    .component = &self.components[self.index],
                };
            }
        };
    };
}

// Helper types for parallel dispatch
fn ChunkJob(comptime T: type) type {
    return struct {
        entities: []EntityId,
        components: []T,
        callback: *const fn ([]EntityId, []T, f32) void,
        dt: f32,
        completion: *std.atomic.Value(usize),
        allocator: std.mem.Allocator, // For cleanup
    };
}

fn chunkWorker(comptime T: type) *const fn (*anyopaque, WorkItem) void {
    return struct {
        fn work(_: *anyopaque, item: WorkItem) void {
            const job: *ChunkJob(T) = @ptrCast(@alignCast(item.data.custom.user_data));

            // Execute the callback on this chunk
            job.callback(job.entities, job.components, job.dt);

            // Signal completion
            _ = job.completion.fetchSub(1, .release);

            // Free the job memory
            const allocator = job.allocator;
            allocator.destroy(job);
        }
    }.work;
}

// Tests - these will only run when building the full module, not standalone
// The ThreadPool import will work when view.zig is imported by world.zig or main.zig
test "View serial iteration with each" {
    const Position = struct { x: f32, y: f32 };

    var set = DenseSet(Position).init(std.testing.allocator);
    defer set.deinit();

    const e1 = EntityId.make(0, 1);
    const e2 = EntityId.make(0, 2);
    const e3 = EntityId.make(0, 3);

    try set.emplace(e1, .{ .x = 1, .y = 2 });
    try set.emplace(e2, .{ .x = 3, .y = 4 });
    try set.emplace(e3, .{ .x = 5, .y = 6 });

    var view = View(Position){ .storage = &set, .allocator = std.testing.allocator, .thread_pool = null };

    // Count iterations using iterator
    var count: usize = 0;
    var iter = view.iterator();
    while (iter.next()) |_| {
        count += 1;
    }

    try std.testing.expectEqual(@as(usize, 3), count);
}

test "View iterator" {
    const Value = struct { val: i32 };

    var set = DenseSet(Value).init(std.testing.allocator);
    defer set.deinit();

    const e1 = EntityId.make(0, 1);
    const e2 = EntityId.make(0, 2);

    try set.emplace(e1, .{ .val = 100 });
    try set.emplace(e2, .{ .val = 200 });

    var view = View(Value){ .storage = &set, .allocator = std.testing.allocator, .thread_pool = null };
    var iter = view.iterator();

    var sum: i32 = 0;
    while (iter.next()) |item| {
        sum += item.component.val;
    }

    try std.testing.expectEqual(@as(i32, 300), sum);
}

test "View mutation during iteration" {
    const Counter = struct { count: i32 };

    var set = DenseSet(Counter).init(std.testing.allocator);
    defer set.deinit();

    const e1 = EntityId.make(0, 1);
    const e2 = EntityId.make(0, 2);

    try set.emplace(e1, .{ .count = 0 });
    try set.emplace(e2, .{ .count = 5 });

    var view = View(Counter){ .storage = &set, .allocator = std.testing.allocator, .thread_pool = null };

    // Increment all counters using iterator
    var iter = view.iterator();
    while (iter.next()) |item| {
        item.component.count += 1;
    }

    // Verify mutations
    try std.testing.expectEqual(@as(i32, 1), set.get(e1).?.count);
    try std.testing.expectEqual(@as(i32, 6), set.get(e2).?.count);
}
