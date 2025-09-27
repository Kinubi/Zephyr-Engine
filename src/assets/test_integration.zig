const std = @import("std");

// Simple test file to verify the asset manager compiles
const asset_types = @import("asset_types.zig");
const asset_registry = @import("asset_registry.zig");
const asset_loader = @import("asset_loader.zig");

test "Basic imports work" {
    const AssetId = asset_types.AssetId;
    const id = AssetId.generate();
    try std.testing.expect(id.isValid());
}

test "Registry creation works" {
    var registry = asset_registry.AssetRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const texture_id = try registry.registerAsset("missing.png", .texture);
    try std.testing.expect(texture_id.isValid());
}
