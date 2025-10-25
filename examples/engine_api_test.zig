const std = @import("std");
const zulkan = @import("zulkan");

/// Simple example demonstrating the Engine API
/// This shows how to use the engine without directly managing systems
///
/// NOTE: This example doesn't render anything, so you'll see validation warnings
/// about image layouts. In a real application, you would add a SceneLayer or
/// custom rendering layer that records actual rendering commands.
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== ZulkanEngine API Test ===\n", .{});
    std.debug.print("This is a minimal example - no rendering is performed.\n", .{});
    std.debug.print("Validation warnings about image layouts are expected.\n\n", .{});

    // Initialize engine with configuration
    var engine = try zulkan.Engine.init(allocator, .{
        .window = .{
            .width = 800,
            .height = 600,
            .title = "Engine API Test",
            .vsync = false,
        },
        .enable_validation = false, // Disabled to avoid expected warnings
        .enable_performance_monitoring = true,
    });
    defer engine.deinit();

    std.debug.print("✓ Engine initialized successfully!\n", .{});
    std.debug.print("✓ Window: 800x600\n", .{});
    std.debug.print("✓ Layers: RenderLayer, PerformanceLayer\n", .{});
    std.debug.print("✓ Starting frame loop...\n\n", .{});

    // Main loop
    var frame_count: u32 = 0;
    const max_frames: u32 = 60; // Run for 60 frames (about 1 second)

    const start_time = std.time.milliTimestamp();

    while (engine.isRunning() and frame_count < max_frames) : (frame_count += 1) {
        // Simple frame loop using engine API
        const frame_info = engine.beginFrame() catch |err| {
            if (err == error.WindowClosed) break;
            return err;
        };

        try engine.update(frame_info);
        try engine.render(frame_info);
        try engine.endFrame(frame_info);

        if (frame_count % 15 == 0) {
            std.debug.print("Frame {}: dt={d:.3}ms\n", .{ frame_count, frame_info.dt * 1000.0 });
        }
    }

    const end_time = std.time.milliTimestamp();
    const elapsed_ms = end_time - start_time;

    std.debug.print("\n✓ Completed {} frames in {}ms\n", .{ frame_count, elapsed_ms });
    std.debug.print("✓ Average: {d:.2}ms/frame ({d:.1} FPS)\n", .{
        @as(f64, @floatFromInt(elapsed_ms)) / @as(f64, @floatFromInt(frame_count)),
        @as(f64, @floatFromInt(frame_count)) / (@as(f64, @floatFromInt(elapsed_ms)) / 1000.0),
    });
    std.debug.print("✓ Engine shutting down...\n", .{});
}
