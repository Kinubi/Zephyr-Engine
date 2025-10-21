const std = @import("std");
const TP = @import("../threading/thread_pool.zig");
const Registry = @import("registry.zig").Registry;

pub const World = struct {
    allocator: std.mem.Allocator,
    thread_pool: *TP.ThreadPool,
    registry: Registry,

    pub const Config = struct {
        thread_pool: *TP.ThreadPool,
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) !World {
        const w = World{ .allocator = allocator, .thread_pool = config.thread_pool, .registry = Registry.init(allocator) };
        return w;
    }

    pub fn deinit(self: *World) void {
        // Deinit owned registry storage
        self.registry.deinit();
    }

    pub fn beginFrame(self: *World, _frame_counter: u64, _dt: f32) !void {
        // Silence unused parameter warnings by referencing them.
        _ = self;
        _ = _frame_counter;
        _ = _dt;
    }

    pub fn submitComponentTypeChunked(self: *World, type_id: usize, chunk_size: usize, dt: f32, updater: *const fn (*anyopaque, f32) void, priority: TP.WorkPriority) !void {
        try self.registry.submitComponentTypeChunked(type_id, self.thread_pool, priority, chunk_size, dt, updater);
    }
};
