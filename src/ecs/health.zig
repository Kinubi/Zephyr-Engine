const std = @import("std");
const log = @import("../utils/log.zig").log;
const TP = @import("../threading/thread_pool.zig");

pub const Health = struct {
    current: f32,
    max: f32,
    phase: f32,
    // No ctx here; registry will provide context when submitting

    pub fn init(current: f32, max: f32) Health {
        return Health{ .current = current, .max = max, .phase = 0.0 };
    }

    pub fn update(self: *Health, dt: f32) void {
        // Advance phase by dt (seconds) and compute a sine wave in [0, max].
        self.phase += dt;
        const s = std.math.sin(self.phase);
        const norm = (s + 1.0) * 0.5; // maps [-1,1] -> [0,1]
        self.current = norm * self.max;
    }

    pub fn render(self: *const Health) void {
        _ = self;
    }

    // Updater trampoline used by the generic worker
    pub const updater_trampoline: *const fn (*anyopaque, f32) void = update_trampoline;

    // Submission is handled via Registry (handle-based) for safety
};

pub fn update_trampoline(comp_ptr: *anyopaque, dt: f32) void {
    const h: *Health = @ptrCast(@alignCast(comp_ptr));
    h.update(dt);
}
