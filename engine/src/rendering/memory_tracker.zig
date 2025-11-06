const std = @import("std");
const vk = @import("vulkan");
const log = @import("../utils/log.zig").log;
const cvar = @import("../core/cvar.zig");

/// Memory category for tracking GPU allocations
pub const MemoryCategory = enum {
    buffer,
    texture,
    blas,
    tlas,
    other,
};

/// Memory allocation info
pub const AllocationInfo = struct {
    size: vk.DeviceSize,
    category: MemoryCategory,
    name: []const u8,
};

/// Memory budget limits (MB)
pub const MemoryBudget = struct {
    max_buffer_mb: f32 = 256.0,
    max_texture_mb: f32 = 512.0,
    max_blas_mb: f32 = 128.0,
    max_tlas_mb: f32 = 64.0,
    max_total_mb: f32 = 1024.0,
};

/// Global GPU memory tracker
/// Tracks allocations across buffers, textures, and acceleration structures
pub const MemoryTracker = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,

    // Per-category usage (bytes)
    buffer_usage: std.atomic.Value(u64),
    texture_usage: std.atomic.Value(u64),
    blas_usage: std.atomic.Value(u64),
    tlas_usage: std.atomic.Value(u64),
    other_usage: std.atomic.Value(u64),

    // Total usage (bytes)
    total_usage: std.atomic.Value(u64),

    // Peak usage tracking
    peak_buffer: std.atomic.Value(u64),
    peak_texture: std.atomic.Value(u64),
    peak_blas: std.atomic.Value(u64),
    peak_tlas: std.atomic.Value(u64),
    peak_total: std.atomic.Value(u64),

    // Budget limits
    budget: MemoryBudget,

    // Allocation registry for debugging
    allocations: std.StringHashMap(AllocationInfo),

    pub fn init(allocator: std.mem.Allocator, budget: MemoryBudget) !*MemoryTracker {
        const self = try allocator.create(MemoryTracker);
        self.* = .{
            .allocator = allocator,
            .mutex = std.Thread.Mutex{},
            .buffer_usage = std.atomic.Value(u64).init(0),
            .texture_usage = std.atomic.Value(u64).init(0),
            .blas_usage = std.atomic.Value(u64).init(0),
            .tlas_usage = std.atomic.Value(u64).init(0),
            .other_usage = std.atomic.Value(u64).init(0),
            .total_usage = std.atomic.Value(u64).init(0),
            .peak_buffer = std.atomic.Value(u64).init(0),
            .peak_texture = std.atomic.Value(u64).init(0),
            .peak_blas = std.atomic.Value(u64).init(0),
            .peak_tlas = std.atomic.Value(u64).init(0),
            .peak_total = std.atomic.Value(u64).init(0),
            .budget = budget,
            .allocations = std.StringHashMap(AllocationInfo).init(allocator),
        };
        return self;
    }

    /// Check if memory logging is enabled via CVar
    fn shouldLogAllocations() bool {
        if (cvar.getGlobal()) |registry_ptr| {
            const registry: *cvar.CVarRegistry = @ptrCast(registry_ptr);
            if (registry.getAsStringAlloc("r_logMemoryAllocs", std.heap.page_allocator)) |value| {
                defer std.heap.page_allocator.free(value);
                return std.mem.eql(u8, value, "true");
            }
        }
        return false;
    }

    /// Track a new allocation
    pub fn trackAllocation(
        self: *MemoryTracker,
        name: []const u8,
        size: vk.DeviceSize,
        category: MemoryCategory,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Update category usage
        const category_usage = switch (category) {
            .buffer => &self.buffer_usage,
            .texture => &self.texture_usage,
            .blas => &self.blas_usage,
            .tlas => &self.tlas_usage,
            .other => &self.other_usage,
        };

        const new_category_usage = category_usage.fetchAdd(size, .monotonic) + size;
        const new_total = self.total_usage.fetchAdd(size, .monotonic) + size;

        // Update peaks
        self.updatePeak(category, new_category_usage);
        _ = self.peak_total.fetchMax(new_total, .monotonic);

        // Check budget
        self.checkBudget(category, new_category_usage, new_total);

        // Register allocation
        const owned_name = try self.allocator.dupe(u8, name);
        try self.allocations.put(owned_name, .{
            .size = size,
            .category = category,
            .name = owned_name,
        });

        // Only log if CVar is enabled
        if (shouldLogAllocations()) {
            log(.INFO, "memory_tracker", "Allocated: {s} ({} bytes, {})", .{
                name, size, category,
            });
        }
    }

    /// Untrack an allocation
    pub fn untrackAllocation(self: *MemoryTracker, name: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.allocations.fetchRemove(name)) |kv| {
            const info = kv.value;

            // Update category usage
            const category_usage = switch (info.category) {
                .buffer => &self.buffer_usage,
                .texture => &self.texture_usage,
                .blas => &self.blas_usage,
                .tlas => &self.tlas_usage,
                .other => &self.other_usage,
            };

            _ = category_usage.fetchSub(info.size, .monotonic);
            _ = self.total_usage.fetchSub(info.size, .monotonic);

            // Only log if CVar is enabled
            if (shouldLogAllocations()) {
                log(.INFO, "memory_tracker", "Freed: {s} ({} bytes, {})", .{
                    name, info.size, info.category,
                });
            }

            self.allocator.free(info.name);
        }
    }

    /// Get current usage for category (MB)
    pub fn getCategoryUsageMB(self: *MemoryTracker, category: MemoryCategory) f32 {
        const bytes = switch (category) {
            .buffer => self.buffer_usage.load(.monotonic),
            .texture => self.texture_usage.load(.monotonic),
            .blas => self.blas_usage.load(.monotonic),
            .tlas => self.tlas_usage.load(.monotonic),
            .other => self.other_usage.load(.monotonic),
        };
        return @as(f32, @floatFromInt(bytes)) / (1024.0 * 1024.0);
    }

    /// Get total usage (MB)
    pub fn getTotalUsageMB(self: *MemoryTracker) f32 {
        const bytes = self.total_usage.load(.monotonic);
        return @as(f32, @floatFromInt(bytes)) / (1024.0 * 1024.0);
    }

    /// Get peak usage for category (MB)
    pub fn getPeakUsageMB(self: *MemoryTracker, category: MemoryCategory) f32 {
        const bytes = switch (category) {
            .buffer => self.peak_buffer.load(.monotonic),
            .texture => self.peak_texture.load(.monotonic),
            .blas => self.peak_blas.load(.monotonic),
            .tlas => self.peak_tlas.load(.monotonic),
            .other => 0, // No peak tracking for "other"
        };
        return @as(f32, @floatFromInt(bytes)) / (1024.0 * 1024.0);
    }

    /// Get peak total usage (MB)
    pub fn getPeakTotalUsageMB(self: *MemoryTracker) f32 {
        const bytes = self.peak_total.load(.monotonic);
        return @as(f32, @floatFromInt(bytes)) / (1024.0 * 1024.0);
    }

    /// Print memory statistics
    pub fn printStatistics(self: *MemoryTracker) void {
        log(.INFO, "memory_tracker", "=== GPU Memory Statistics ===", .{});
        log(.INFO, "memory_tracker", "Buffers:  {d:.2} MB / {d:.2} MB (peak: {d:.2} MB)", .{
            self.getCategoryUsageMB(.buffer),
            self.budget.max_buffer_mb,
            self.getPeakUsageMB(.buffer),
        });
        log(.INFO, "memory_tracker", "Textures: {d:.2} MB / {d:.2} MB (peak: {d:.2} MB)", .{
            self.getCategoryUsageMB(.texture),
            self.budget.max_texture_mb,
            self.getPeakUsageMB(.texture),
        });
        log(.INFO, "memory_tracker", "BLAS:     {d:.2} MB / {d:.2} MB (peak: {d:.2} MB)", .{
            self.getCategoryUsageMB(.blas),
            self.budget.max_blas_mb,
            self.getPeakUsageMB(.blas),
        });
        log(.INFO, "memory_tracker", "TLAS:     {d:.2} MB / {d:.2} MB (peak: {d:.2} MB)", .{
            self.getCategoryUsageMB(.tlas),
            self.budget.max_tlas_mb,
            self.getPeakUsageMB(.tlas),
        });
        log(.INFO, "memory_tracker", "Total:    {d:.2} MB / {d:.2} MB (peak: {d:.2} MB)", .{
            self.getTotalUsageMB(),
            self.budget.max_total_mb,
            self.getPeakTotalUsageMB(),
        });
        log(.INFO, "memory_tracker", "============================", .{});
    }

    fn updatePeak(self: *MemoryTracker, category: MemoryCategory, new_usage: u64) void {
        const peak = switch (category) {
            .buffer => &self.peak_buffer,
            .texture => &self.peak_texture,
            .blas => &self.peak_blas,
            .tlas => &self.peak_tlas,
            .other => return, // No peak tracking for "other"
        };
        _ = peak.fetchMax(new_usage, .monotonic);
    }

    fn checkBudget(
        self: *MemoryTracker,
        category: MemoryCategory,
        category_usage: u64,
        total_usage: u64,
    ) void {
        const category_mb = @as(f32, @floatFromInt(category_usage)) / (1024.0 * 1024.0);
        const total_mb = @as(f32, @floatFromInt(total_usage)) / (1024.0 * 1024.0);

        // Check category budget
        const category_limit = switch (category) {
            .buffer => self.budget.max_buffer_mb,
            .texture => self.budget.max_texture_mb,
            .blas => self.budget.max_blas_mb,
            .tlas => self.budget.max_tlas_mb,
            .other => return, // No budget for "other"
        };

        if (category_mb > category_limit) {
            log(.WARN, "memory_tracker", "{} memory exceeded budget: {d:.2} MB / {d:.2} MB", .{
                category, category_mb, category_limit,
            });
        }

        // Check total budget
        if (total_mb > self.budget.max_total_mb) {
            log(.WARN, "memory_tracker", "Total GPU memory exceeded budget: {d:.2} MB / {d:.2} MB", .{
                total_mb, self.budget.max_total_mb,
            });
        }
    }

    pub fn deinit(self: *MemoryTracker) void {
        var iter = self.allocations.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.allocations.deinit();
        self.allocator.destroy(self);
    }
};
