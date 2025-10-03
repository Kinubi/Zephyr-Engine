const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("../core/graphics_context.zig").GraphicsContext;
const Transform = @import("../rendering/mesh.zig").Transform;
const Math = @import("../utils/math.zig");
const PointLightComponent = @import("components.zig").PointLightComponent;
const Model = @import("../rendering/mesh.zig").Model;
const AssetId = @import("../assets/asset_manager.zig").AssetId;

pub const GameObject = struct {
    id: u64, // Unique object id
    transform: Transform = .{},
    // Legacy direct model pointer (will be deprecated)
    model: ?*Model = null,
    // New canonical asset identifiers
    model_asset: ?AssetId = null,
    material_asset: ?AssetId = null,
    texture_asset: ?AssetId = null, // primary texture (could be expanded to multiple textures later)
    point_light: ?PointLightComponent = null,
    has_model: bool = false,

    pub fn render(self: GameObject, gc: GraphicsContext, cmdbuf: vk.CommandBuffer) !void {
        if (self.model) |model| {
            for (model.meshes.items) |mesh| {
                // Use the mesh's draw method which handles binding
                mesh.geometry.mesh.*.draw(gc, cmdbuf);
            }
        }
    }

    pub fn deinit(self: GameObject) void {
        if (self.model) |model| {
            model.deinit();
        }
    }
};
