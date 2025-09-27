const std = @import("std");

// Simple test to verify fallback texture files exist
test "fallback texture files exist" {
    const textures_to_check = [_][]const u8{
        "textures/missing.png",
        "textures/loading.png",
        "textures/error.png",
        "textures/default.png",
    };

    for (textures_to_check) |texture_path| {
        const file = std.fs.cwd().openFile(texture_path, .{}) catch |err| {
            std.debug.print("❌ Fallback texture missing: {s} (error: {})\n", .{ texture_path, err });
            return err;
        };
        defer file.close();

        const stat = file.stat() catch |err| {
            std.debug.print("❌ Cannot stat fallback texture: {s} (error: {})\n", .{ texture_path, err });
            return err;
        };

        std.debug.print("✅ Found fallback texture: {s} ({d} bytes)\n", .{ texture_path, stat.size });
    }

    std.debug.print("✅ All fallback textures verified!\n", .{});
}
