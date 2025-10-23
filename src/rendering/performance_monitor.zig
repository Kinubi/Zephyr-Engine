const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("../core/graphics_context.zig").GraphicsContext;
const log = @import("../utils/log.zig").log;

/// Performance monitoring with CPU and GPU timing
pub const PerformanceMonitor = struct {
    const MAX_FRAMES = 3; // Match MAX_FRAMES_IN_FLIGHT
    const MAX_PASSES = 16; // Maximum number of passes to track
    const QUERIES_PER_FRAME = MAX_PASSES * 2 + 2; // Frame start/end + per-pass begin/end
    const QUERY_RESULT_CAPACITY = QUERIES_PER_FRAME * 2; // Timestamp + availability per query

    allocator: std.mem.Allocator,
    gc: *GraphicsContext,

    // Query pools for GPU timing
    query_pool: vk.QueryPool,
    query_count: u32,
    timestamp_period: f32, // Nanoseconds per timestamp tick

    // Per-frame timing data
    frame_times: [MAX_FRAMES]FrameTiming,
    current_frame_idx: usize = 0,
    next_query_idx: u32 = 0, // Track next available query index

    // Rolling averages
    avg_cpu_time_ms: f32 = 0.0,
    avg_gpu_time_ms: f32 = 0.0,

    // Statistics window
    stats_window_size: usize = 60, // Average over 60 frames (1 second at 60fps)

    // Frame tracking
    total_frames_recorded: u32 = 0, // Track total frames to avoid reading uninitialized queries
    queries_reset_for_frame: bool = false, // Track if queries have been reset this frame

    pub const PassTiming = struct {
        name: []const u8,
        cpu_start_ns: i128 = 0,
        cpu_end_ns: i128 = 0,
        gpu_query_start: u32 = 0, // Query index
        gpu_query_end: u32 = 0, // Query index
        gpu_start_ticks: u64 = 0, // Actual GPU timestamp value
        gpu_end_ticks: u64 = 0, // Actual GPU timestamp value

        pub fn getCpuTimeMs(self: PassTiming) f32 {
            const duration_ns = self.cpu_end_ns - self.cpu_start_ns;
            return @as(f32, @floatFromInt(duration_ns)) / 1_000_000.0;
        }

        pub fn getGpuTimeMs(self: PassTiming, timestamp_period: f32) f32 {
            if (self.gpu_start_ticks == 0 and self.gpu_end_ticks == 0) return 0.0;
            const duration_ticks = self.gpu_end_ticks - self.gpu_start_ticks;
            const duration_ns = @as(f32, @floatFromInt(duration_ticks)) * timestamp_period;
            return duration_ns / 1_000_000.0;
        }
    };

    pub const FrameTiming = struct {
        frame_cpu_start: i128 = 0,
        frame_cpu_end: i128 = 0,
        frame_gpu_start_query: u32 = std.math.maxInt(u32), // Use max value as "unset" sentinel
        frame_gpu_end_query: u32 = std.math.maxInt(u32),
        frame_gpu_time_ns: u64 = 0,
        query_base_offset: u32 = 0, // The first_query offset used for this frame's queries
        pass_count: usize = 0,
        passes: [MAX_PASSES]PassTiming = [_]PassTiming{.{ .name = "", .cpu_start_ns = 0, .cpu_end_ns = 0, .gpu_query_start = 0, .gpu_query_end = 0, .gpu_start_ticks = 0, .gpu_end_ticks = 0 }} ** MAX_PASSES,

        pub fn getFrameCpuTimeMs(self: FrameTiming) f32 {
            const duration_ns = self.frame_cpu_end - self.frame_cpu_start;
            return @as(f32, @floatFromInt(duration_ns)) / 1_000_000.0;
        }

        pub fn getFrameGpuTimeMs(self: FrameTiming) f32 {
            return @as(f32, @floatFromInt(self.frame_gpu_time_ns)) / 1_000_000.0;
        }
    };

    pub const PerformanceStats = struct {
        cpu_time_ms: f32,
        gpu_time_ms: f32,
        fps: f32,
        pass_timings: []const PassTiming,
        timestamp_period: f32, // For converting GPU ticks to ms
    };

    pub fn init(allocator: std.mem.Allocator, gc: *GraphicsContext) !PerformanceMonitor {
        // Create query pool for timestamp queries
        // +2 for frame start/end timestamps per frame
        const query_count: u32 = MAX_FRAMES * QUERIES_PER_FRAME; // Start and end for each pass + frame start/end
        const query_pool_info = vk.QueryPoolCreateInfo{
            .query_type = .timestamp,
            .query_count = query_count,
            .pipeline_statistics = .{},
            .flags = .{},
        };

        const query_pool = try gc.vkd.createQueryPool(gc.dev, &query_pool_info, null);

        // Get timestamp period from device properties
        const timestamp_period = gc.props.limits.timestamp_period;

        var monitor = PerformanceMonitor{
            .allocator = allocator,
            .gc = gc,
            .query_pool = query_pool,
            .query_count = query_count,
            .timestamp_period = timestamp_period,
            .frame_times = undefined,
        };

        // Initialize frame timings
        for (&monitor.frame_times, 0..) |*ft, i| {
            ft.* = FrameTiming{};
            ft.pass_count = 0;
            // Pre-calculate query base offset for each frame
            ft.query_base_offset = @as(u32, @intCast(i)) * QUERIES_PER_FRAME;
        }

        // Reset entire query pool on the host (required before first use)
        // Note: Requires hostQueryReset feature (Vulkan 1.2)
        gc.vkd.resetQueryPool(gc.dev, query_pool, 0, query_count);

        return monitor;
    }

    pub fn deinit(self: *PerformanceMonitor) void {
        self.gc.vkd.destroyQueryPool(self.gc.dev, self.query_pool, null);
    }

    /// Begin frame timing
    pub fn beginFrame(self: *PerformanceMonitor, frame_index: u32) !void {
        _ = frame_index;
        const current = &self.frame_times[self.current_frame_idx];
        current.frame_cpu_start = std.time.nanoTimestamp();
        current.pass_count = 0;
        // Don't reset GPU query markers - they need to persist for reading 2 frames later
        self.queries_reset_for_frame = false;
    }

    /// Reset query pool for this frame (call from FIRST command buffer that records - compute or graphics)
    pub fn resetQueriesForFrame(self: *PerformanceMonitor, command_buffer: vk.CommandBuffer) !void {
        if (self.queries_reset_for_frame) return; // Already reset this frame

        const first_query = @as(u32, @intCast(self.current_frame_idx)) * QUERIES_PER_FRAME;

        self.gc.vkd.cmdResetQueryPool(command_buffer, self.query_pool, first_query, QUERIES_PER_FRAME);

        // Initialize query index for this frame and store the base offset
        self.next_query_idx = first_query;
        const current = &self.frame_times[self.current_frame_idx];
        current.query_base_offset = first_query;

        // Reset GPU query markers for this frame (we're about to overwrite them)
        current.frame_gpu_start_query = std.math.maxInt(u32);
        current.frame_gpu_end_query = std.math.maxInt(u32);

        self.queries_reset_for_frame = true;
    }

    /// Write frame start timestamp (call from whichever command buffer starts first)
    pub fn writeFrameStartTimestamp(self: *PerformanceMonitor, command_buffer: vk.CommandBuffer) !void {
        const current = &self.frame_times[self.current_frame_idx];
        if (current.frame_gpu_start_query != std.math.maxInt(u32)) {
            return; // Already written
        }

        current.frame_gpu_start_query = self.next_query_idx;
        self.gc.vkd.cmdWriteTimestamp(command_buffer, .{ .top_of_pipe_bit = true }, self.query_pool, self.next_query_idx);
        self.next_query_idx += 1;
    }

    /// Write frame end timestamp (call from whichever command buffer ends last - typically graphics)
    pub fn writeFrameEndTimestamp(self: *PerformanceMonitor, command_buffer: vk.CommandBuffer) !void {
        const current = &self.frame_times[self.current_frame_idx];
        current.frame_gpu_end_query = self.next_query_idx;
        self.gc.vkd.cmdWriteTimestamp(command_buffer, .{ .bottom_of_pipe_bit = true }, self.query_pool, self.next_query_idx);
        self.next_query_idx += 1;
    }

    /// End frame timing and compute averages
    pub fn endFrame(self: *PerformanceMonitor, frame_index: u32) !void {
        _ = frame_index;
        const current = &self.frame_times[self.current_frame_idx];
        current.frame_cpu_end = std.time.nanoTimestamp();

        // Update rolling averages
        const cpu_time = current.getFrameCpuTimeMs();
        self.avg_cpu_time_ms = self.avg_cpu_time_ms * 0.95 + cpu_time * 0.05;

        // Increment total frames recorded
        self.total_frames_recorded += 1;

        // Advance frame index
        self.current_frame_idx = (self.current_frame_idx + 1) % MAX_FRAMES;
    }

    /// Begin timing a render pass (can use compute or graphics command buffer)
    pub fn beginPass(self: *PerformanceMonitor, pass_name: []const u8, frame_index: u32, command_buffer: ?vk.CommandBuffer) !void {
        _ = frame_index;
        const current = &self.frame_times[self.current_frame_idx];
        if (current.pass_count >= MAX_PASSES) return;

        const pass_idx = current.pass_count;

        var gpu_start_query: u32 = 0;

        // Write GPU start timestamp if command buffer is provided
        if (command_buffer) |cmdbuf| {
            gpu_start_query = self.next_query_idx;
            self.gc.vkd.cmdWriteTimestamp(cmdbuf, .{ .top_of_pipe_bit = true }, self.query_pool, gpu_start_query);
            self.next_query_idx += 1;
        }

        current.passes[pass_idx] = PassTiming{
            .name = pass_name,
            .cpu_start_ns = std.time.nanoTimestamp(),
            .gpu_query_start = gpu_start_query,
            .gpu_query_end = 0,
        };
    }

    /// End timing a render pass (can use compute or graphics command buffer)
    pub fn endPass(self: *PerformanceMonitor, pass_name: []const u8, frame_index: u32, command_buffer: ?vk.CommandBuffer) !void {
        _ = pass_name;
        _ = frame_index;
        const current = &self.frame_times[self.current_frame_idx];
        if (current.pass_count >= MAX_PASSES) return;

        const pass_idx = current.pass_count;
        current.passes[pass_idx].cpu_end_ns = std.time.nanoTimestamp();

        // Write GPU end timestamp if command buffer is provided
        if (command_buffer) |cmdbuf| {
            current.passes[pass_idx].gpu_query_end = self.next_query_idx;
            self.gc.vkd.cmdWriteTimestamp(cmdbuf, .{ .bottom_of_pipe_bit = true }, self.query_pool, self.next_query_idx);
            self.next_query_idx += 1;
        }

        current.pass_count += 1;
    }

    /// Retrieve GPU query results for the most recently completed frame.
    pub fn updateGpuTimings(
        self: *PerformanceMonitor,
        frame_index: u32,
        graphics_fences: []vk.Fence,
        compute_fences: []vk.Fence,
    ) !void {
        _ = frame_index;

        if (self.total_frames_recorded == 0) {
            return;
        }

        const completed_idx = if (self.current_frame_idx == 0) MAX_FRAMES - 1 else self.current_frame_idx - 1;
        if (completed_idx >= graphics_fences.len) {
            log(.ERROR, "perf", "Graphics fence array too small for completed_idx={} (len={})", .{ completed_idx, graphics_fences.len });
            return;
        }

        const frame = &self.frame_times[completed_idx];

        if (frame.frame_gpu_start_query == std.math.maxInt(u32) or frame.frame_gpu_end_query == std.math.maxInt(u32)) {
            return;
        }
        if (frame.pass_count == 0) {
            return;
        }

        _ = try self.gc.vkd.waitForFences(self.gc.dev, 1, @ptrCast(&graphics_fences[completed_idx]), .true, std.math.maxInt(u64));

        if (completed_idx < compute_fences.len) {
            _ = try self.gc.vkd.waitForFences(self.gc.dev, 1, @ptrCast(&compute_fences[completed_idx]), .true, std.math.maxInt(u64));
        }

        const first_query = frame.query_base_offset;
        const last_query = frame.frame_gpu_end_query;
        if (last_query < first_query) {
            return;
        }

        const query_count: u32 = last_query - first_query + 1;
        if (query_count == 0) {
            return;
        }

        const query_count_usize = @as(usize, @intCast(query_count));
        const required_entries = query_count_usize * 2;

        if (required_entries > QUERY_RESULT_CAPACITY) {
            log(.ERROR, "perf", "Query result capacity exceeded: required={}, capacity={}", .{ required_entries, QUERY_RESULT_CAPACITY });
            return;
        }
        if (query_count_usize > QUERIES_PER_FRAME) {
            log(.ERROR, "perf", "Timestamp buffer exceeded: queries={}, capacity={}", .{ query_count_usize, QUERIES_PER_FRAME });
            return;
        }

        var raw_results: [QUERY_RESULT_CAPACITY]u64 = undefined;
        const raw_slice = raw_results[0..required_entries];

        const result = self.gc.vkd.getQueryPoolResults(
            self.gc.dev,
            self.query_pool,
            first_query,
            query_count,
            raw_slice.len * @sizeOf(u64),
            raw_slice.ptr,
            @sizeOf(u64) * 2,
            .{ .@"64_bit" = true, .with_availability_bit = true, .wait_bit = true },
        ) catch |err| {
            log(.ERROR, "perf", "Query fetch error: {}", .{err});
            return err;
        };

        _ = result;

        var timestamps: [QUERIES_PER_FRAME]u64 = undefined;
        for (0..query_count_usize) |i| {
            const availability = raw_results[i * 2 + 1];
            if (availability == 0) {
                return;
            }

            timestamps[i] = raw_results[i * 2];
        }

        const frame_start_idx = @as(usize, @intCast(frame.frame_gpu_start_query - first_query));
        const frame_end_idx = @as(usize, @intCast(frame.frame_gpu_end_query - first_query));
        if (frame_end_idx >= query_count_usize or frame_start_idx >= query_count_usize) {
            log(.ERROR, "perf", "Timestamp indices out of range: start={}, end={}, available={}", .{ frame_start_idx, frame_end_idx, query_count_usize });
            return;
        }

        const frame_gpu_ticks = timestamps[frame_end_idx] - timestamps[frame_start_idx];
        frame.frame_gpu_time_ns = @as(u64, @intFromFloat(@as(f32, @floatFromInt(frame_gpu_ticks)) * self.timestamp_period));

        const gpu_time_ms = frame.getFrameGpuTimeMs();
        self.avg_gpu_time_ms = self.avg_gpu_time_ms * 0.95 + gpu_time_ms * 0.05;

        for (0..frame.pass_count) |i| {
            const pass = &frame.passes[i];
            if (pass.gpu_query_start == 0 or pass.gpu_query_end == 0) continue;

            if (pass.gpu_query_start < first_query or pass.gpu_query_end < first_query) continue;

            const start_idx = @as(usize, @intCast(pass.gpu_query_start - first_query));
            const end_idx = @as(usize, @intCast(pass.gpu_query_end - first_query));
            if (start_idx >= query_count_usize or end_idx >= query_count_usize) continue;

            pass.gpu_start_ticks = timestamps[start_idx];
            pass.gpu_end_ticks = timestamps[end_idx];
        }
    }

    /// Get current performance statistics
    pub fn getStats(self: *PerformanceMonitor) PerformanceStats {
        const prev_idx = if (self.current_frame_idx == 0) MAX_FRAMES - 1 else self.current_frame_idx - 1;
        const prev_frame = &self.frame_times[prev_idx];

        const fps = if (self.avg_cpu_time_ms > 0.0) 1000.0 / self.avg_cpu_time_ms else 0.0;

        return PerformanceStats{
            .cpu_time_ms = self.avg_cpu_time_ms,
            .gpu_time_ms = self.avg_gpu_time_ms,
            .fps = fps,
            .pass_timings = prev_frame.passes[0..prev_frame.pass_count],
            .timestamp_period = self.timestamp_period,
        };
    }

    /// Log performance statistics
    pub fn logStats(self: *PerformanceMonitor) void {
        const stats = self.getStats();

        log(.INFO, "perf", "=== Performance Statistics ===", .{});
        log(.INFO, "perf", "FPS: {d:.1} | CPU: {d:.2}ms | GPU: {d:.2}ms", .{
            stats.fps,
            stats.cpu_time_ms,
            stats.gpu_time_ms,
        });

        if (stats.pass_timings.len > 0) {
            log(.INFO, "perf", "Pass breakdown:", .{});
            for (stats.pass_timings) |pass| {
                const gpu_ms = pass.getGpuTimeMs(stats.timestamp_period);
                log(.INFO, "perf", "  {s}: CPU {d:.2}ms | GPU {d:.2}ms", .{ pass.name, pass.getCpuTimeMs(), gpu_ms });
            }
        }
    }
};
