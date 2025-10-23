const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("../core/graphics_context.zig").GraphicsContext;
const log = @import("../utils/log.zig").log;

/// Performance monitoring with CPU and GPU timing
pub const PerformanceMonitor = struct {
    const MAX_FRAMES = 3; // Match MAX_FRAMES_IN_FLIGHT
    const MAX_PASSES = 16; // Maximum number of passes to track

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
        gpu_query_start: u32 = 0,
        gpu_query_end: u32 = 0,

        pub fn getCpuTimeMs(self: PassTiming) f32 {
            const duration_ns = self.cpu_end_ns - self.cpu_start_ns;
            return @as(f32, @floatFromInt(duration_ns)) / 1_000_000.0;
        }

        pub fn getGpuTimeMs(self: PassTiming, timestamp_period: f32) f32 {
            if (self.gpu_query_start == 0 and self.gpu_query_end == 0) return 0.0;
            const duration_ticks = self.gpu_query_end - self.gpu_query_start;
            const duration_ns = @as(f32, @floatFromInt(duration_ticks)) * timestamp_period;
            return duration_ns / 1_000_000.0;
        }
    };

    pub const FrameTiming = struct {
        frame_cpu_start: i128 = 0,
        frame_cpu_end: i128 = 0,
        frame_gpu_start_query: u32 = 0,
        frame_gpu_end_query: u32 = 0,
        frame_gpu_time_ns: u64 = 0,
        pass_count: usize = 0,
        passes: [MAX_PASSES]PassTiming = [_]PassTiming{.{ .name = "", .cpu_start_ns = 0, .cpu_end_ns = 0, .gpu_query_start = 0, .gpu_query_end = 0 }} ** MAX_PASSES,

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
        const query_count: u32 = MAX_FRAMES * (MAX_PASSES * 2 + 2); // Start and end for each pass + frame start/end
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
        for (&monitor.frame_times) |*ft| {
            ft.* = FrameTiming{};
            ft.pass_count = 0;
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
        current.frame_gpu_start_query = 0; // Reset GPU start query marker
        current.frame_gpu_end_query = 0; // Reset GPU end query marker
        self.queries_reset_for_frame = false;
    }

    /// Reset query pool for this frame (call from FIRST command buffer that records - compute or graphics)
    pub fn resetQueriesForFrame(self: *PerformanceMonitor, command_buffer: vk.CommandBuffer) !void {
        if (self.queries_reset_for_frame) return; // Already reset this frame

        const queries_per_frame = MAX_PASSES * 2 + 2; // +2 for frame start/end
        const first_query = @as(u32, @intCast(self.current_frame_idx)) * queries_per_frame;
        self.gc.vkd.cmdResetQueryPool(command_buffer, self.query_pool, first_query, queries_per_frame);

        // Initialize query index for this frame
        self.next_query_idx = first_query;
        self.queries_reset_for_frame = true;
    }

    /// Write frame start timestamp (call from whichever command buffer starts first)
    pub fn writeFrameStartTimestamp(self: *PerformanceMonitor, command_buffer: vk.CommandBuffer) !void {
        const current = &self.frame_times[self.current_frame_idx];
        if (current.frame_gpu_start_query != 0) return; // Already written

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

    /// Retrieve GPU query results for previous frame (call after fence wait)
    pub fn updateGpuTimings(self: *PerformanceMonitor, frame_index: u32) !void {
        _ = frame_index;

        // Don't try to read queries until we've recorded at least MAX_FRAMES frames
        // Otherwise we'll try to wait on queries that haven't been written yet
        if (self.total_frames_recorded < MAX_FRAMES) return;

        // Get results from the previous frame (GPU work should be complete by now)
        const result_idx = if (self.current_frame_idx == 0) MAX_FRAMES - 1 else self.current_frame_idx - 1;
        const frame = &self.frame_times[result_idx];

        // Skip if no GPU timestamps were written this frame
        if (frame.frame_gpu_start_query == 0 or frame.frame_gpu_end_query == 0) return;
        if (frame.pass_count == 0) return; // No passes to query

        // Calculate query range for this frame
        const queries_per_frame = MAX_PASSES * 2 + 2;
        const first_query = @as(u32, @intCast(result_idx)) * queries_per_frame;
        const query_count: u32 = @intCast(2 + frame.pass_count * 2); // frame start/end + all pass start/ends

        // Retrieve all timestamps for this frame (don't wait - skip if not ready)
        var timestamps: [64]u64 = undefined; // MAX_PASSES * 2 + 2 = 34 max
        const result = self.gc.vkd.getQueryPoolResults(
            self.gc.dev,
            self.query_pool,
            first_query,
            query_count,
            @sizeOf(u64) * timestamps.len,
            &timestamps,
            @sizeOf(u64),
            .{ .@"64_bit" = true },
        ) catch |err| {
            if (err == error.NotReady) return; // Queries not ready yet, skip this frame
            return err;
        };

        if (result == .not_ready) return;

        // Calculate frame GPU time
        const frame_start_idx = frame.frame_gpu_start_query - first_query;
        const frame_end_idx = frame.frame_gpu_end_query - first_query;
        const frame_gpu_ticks = timestamps[frame_end_idx] - timestamps[frame_start_idx];
        frame.frame_gpu_time_ns = @as(u64, @intFromFloat(@as(f32, @floatFromInt(frame_gpu_ticks)) * self.timestamp_period));

        // Update rolling average for GPU time
        const gpu_time_ms = frame.getFrameGpuTimeMs();
        self.avg_gpu_time_ms = self.avg_gpu_time_ms * 0.95 + gpu_time_ms * 0.05;

        // Store GPU timestamps in passes for individual pass timings
        for (0..frame.pass_count) |i| {
            const pass = &frame.passes[i];
            if (pass.gpu_query_start == 0) continue; // No GPU timing for this pass

            const start_idx = pass.gpu_query_start - first_query;
            const end_idx = pass.gpu_query_end - first_query;

            // Store raw tick values - will be converted to ms when needed
            const start_ticks: u32 = @truncate(timestamps[start_idx]);
            const end_ticks: u32 = @truncate(timestamps[end_idx]);
            pass.gpu_query_start = start_ticks;
            pass.gpu_query_end = end_ticks;
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
