const std = @import("std");
const AssetId = @import("../../assets/asset_types.zig").AssetId;

/// MeshRenderer component for ECS entities
/// References Model and Material assets via AssetId from Phase 1 Asset Manager
/// Used by RenderSystem to extract renderable geometry and feed to GenericRenderer
pub const MeshRenderer = struct {
    /// Model asset reference (vertex/index buffers)
    model_asset: ?AssetId = null,

    /// Material asset reference (textures, properties)
    material_asset: ?AssetId = null,

    /// Optional texture override (if different from material's texture)
    texture_asset: ?AssetId = null,

    /// Whether this renderer is active (can be toggled for visibility culling)
    enabled: bool = true,

    /// Render layer/priority (for sorting/batching)
    layer: u8 = 0,

    /// Whether this mesh casts shadows
    casts_shadows: bool = true,

    /// Whether this mesh receives shadows
    receives_shadows: bool = true,

    /// Create a MeshRenderer with model and material
    pub fn init(model: AssetId, material: AssetId) MeshRenderer {
        return .{
            .model_asset = model,
            .material_asset = material,
            .texture_asset = null,
            .enabled = true,
            .layer = 0,
            .casts_shadows = true,
            .receives_shadows = true,
        };
    }

    /// Create a MeshRenderer with model, material, and texture override
    pub fn initWithTexture(model: AssetId, material: AssetId, texture: AssetId) MeshRenderer {
        return .{
            .model_asset = model,
            .material_asset = material,
            .texture_asset = texture,
            .enabled = true,
            .layer = 0,
            .casts_shadows = true,
            .receives_shadows = true,
        };
    }

    /// Create a MeshRenderer with only a model (material will be default)
    pub fn initModelOnly(model: AssetId) MeshRenderer {
        return .{
            .model_asset = model,
            .material_asset = null,
            .texture_asset = null,
            .enabled = true,
            .layer = 0,
            .casts_shadows = true,
            .receives_shadows = true,
        };
    }

    /// Set the model asset
    pub fn setModel(self: *MeshRenderer, model: AssetId) void {
        self.model_asset = model;
    }

    /// Set the material asset
    pub fn setMaterial(self: *MeshRenderer, material: AssetId) void {
        self.material_asset = material;
    }

    /// Set the texture override
    pub fn setTexture(self: *MeshRenderer, texture: ?AssetId) void {
        self.texture_asset = texture;
    }

    /// Set enabled state
    pub fn setEnabled(self: *MeshRenderer, enabled: bool) void {
        self.enabled = enabled;
    }

    /// Set render layer
    pub fn setLayer(self: *MeshRenderer, layer: u8) void {
        self.layer = layer;
    }

    /// Check if this renderer has valid assets to render
    pub fn hasValidAssets(self: *const MeshRenderer) bool {
        return self.enabled and self.model_asset != null;
    }

    /// Get the effective texture asset (override or from material)
    pub fn getTextureAsset(self: *const MeshRenderer) ?AssetId {
        if (self.texture_asset) |tex| {
            return tex;
        }
        // If no override, material system will provide texture
        return null;
    }

    /// ECS update method - no per-frame logic needed for static renderers
    /// (Future: could handle LOD transitions, animation state, etc.)
    pub fn update(self: *MeshRenderer, dt: f32) void {
        _ = self;
        _ = dt;
        // Static mesh renderers don't need per-frame updates
        // Animation/LOD systems would add logic here
    }

    /// Render extraction context for RenderSystem
    /// This will be passed to world.render() to extract all visible meshes
    pub const RenderContext = struct {
        /// List of renderable entities with their data
        renderables: *std.ArrayList(RenderableEntity),
        allocator: std.mem.Allocator,
    };

    /// Data extracted from MeshRenderer + Transform for rendering
    pub const RenderableEntity = struct {
        model_asset: AssetId,
        material_asset: ?AssetId,
        texture_asset: ?AssetId,
        world_matrix: [16]f32, // Transform's world matrix
        layer: u8,
        casts_shadows: bool,
        receives_shadows: bool,
    };

    /// ECS render method - extracts renderable data to context
    /// Called by world.render(MeshRenderer, context) during RenderSystem
    pub fn render(self: *const MeshRenderer, context: RenderContext) void {
        // Only extract if enabled and has valid model
        if (!self.hasValidAssets()) {
            return;
        }

        // Create renderable entry
        // Note: world_matrix will be filled by RenderSystem when it queries Transform
        const renderable = RenderableEntity{
            .model_asset = self.model_asset.?,
            .material_asset = self.material_asset,
            .texture_asset = self.getTextureAsset(),
            .world_matrix = [_]f32{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }, // Identity placeholder
            .layer = self.layer,
            .casts_shadows = self.casts_shadows,
            .receives_shadows = self.receives_shadows,
        };

        context.renderables.append(context.allocator, renderable) catch |err| {
            // Log error but don't crash rendering
            std.log.warn("Failed to append renderable: {}", .{err});
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "MeshRenderer: init with model and material" {
    const model_id: AssetId = @enumFromInt(1);
    const material_id: AssetId = @enumFromInt(2);

    const renderer = MeshRenderer.init(model_id, material_id);

    try std.testing.expect(renderer.model_asset != null);
    try std.testing.expect(renderer.material_asset != null);
    try std.testing.expect(renderer.texture_asset == null);
    try std.testing.expect(renderer.enabled);
    try std.testing.expectEqual(@as(u8, 0), renderer.layer);
}

test "MeshRenderer: init with texture override" {
    const model_id: AssetId = @enumFromInt(1);
    const material_id: AssetId = @enumFromInt(2);
    const texture_id: AssetId = @enumFromInt(3);

    const renderer = MeshRenderer.initWithTexture(model_id, material_id, texture_id);

    try std.testing.expect(renderer.model_asset != null);
    try std.testing.expect(renderer.material_asset != null);
    try std.testing.expect(renderer.texture_asset != null);
    try std.testing.expectEqual(texture_id, renderer.texture_asset.?);
}

test "MeshRenderer: model only init" {
    const model_id: AssetId = @enumFromInt(1);

    const renderer = MeshRenderer.initModelOnly(model_id);

    try std.testing.expect(renderer.model_asset != null);
    try std.testing.expect(renderer.material_asset == null);
    try std.testing.expect(renderer.texture_asset == null);
}

test "MeshRenderer: setters" {
    var renderer = MeshRenderer.init(@enumFromInt(1), @enumFromInt(2));

    renderer.setModel(@enumFromInt(10));
    try std.testing.expectEqual(@as(AssetId, @enumFromInt(10)), renderer.model_asset.?);

    renderer.setMaterial(@enumFromInt(20));
    try std.testing.expectEqual(@as(AssetId, @enumFromInt(20)), renderer.material_asset.?);

    renderer.setTexture(@enumFromInt(30));
    try std.testing.expectEqual(@as(AssetId, @enumFromInt(30)), renderer.texture_asset.?);

    renderer.setEnabled(false);
    try std.testing.expect(!renderer.enabled);

    renderer.setLayer(5);
    try std.testing.expectEqual(@as(u8, 5), renderer.layer);
}

test "MeshRenderer: hasValidAssets checks enabled and model" {
    var renderer = MeshRenderer.init(@enumFromInt(1), @enumFromInt(2));
    try std.testing.expect(renderer.hasValidAssets());

    renderer.setEnabled(false);
    try std.testing.expect(!renderer.hasValidAssets());

    renderer.setEnabled(true);
    renderer.model_asset = null;
    try std.testing.expect(!renderer.hasValidAssets());
}

test "MeshRenderer: getTextureAsset returns override or null" {
    var renderer = MeshRenderer.init(@enumFromInt(1), @enumFromInt(2));
    try std.testing.expect(renderer.getTextureAsset() == null);

    renderer.setTexture(@enumFromInt(30));
    try std.testing.expectEqual(@as(AssetId, @enumFromInt(30)), renderer.getTextureAsset().?);
}

test "MeshRenderer: render extraction" {
    const renderer = MeshRenderer.init(@enumFromInt(1), @enumFromInt(2));

    var renderables: std.ArrayList(MeshRenderer.RenderableEntity) = .{};
    defer renderables.deinit(std.testing.allocator);

    const context = MeshRenderer.RenderContext{
        .renderables = &renderables,
        .allocator = std.testing.allocator,
    };

    renderer.render(context);

    try std.testing.expectEqual(@as(usize, 1), renderables.items.len);
    try std.testing.expectEqual(@as(AssetId, @enumFromInt(1)), renderables.items[0].model_asset);
    try std.testing.expectEqual(@as(AssetId, @enumFromInt(2)), renderables.items[0].material_asset.?);
}

test "MeshRenderer: disabled renderer not extracted" {
    var renderer = MeshRenderer.init(@enumFromInt(1), @enumFromInt(2));
    renderer.setEnabled(false);

    var renderables: std.ArrayList(MeshRenderer.RenderableEntity) = .{};
    defer renderables.deinit(std.testing.allocator);

    const context = MeshRenderer.RenderContext{
        .renderables = &renderables,
        .allocator = std.testing.allocator,
    };

    renderer.render(context);

    try std.testing.expectEqual(@as(usize, 0), renderables.items.len);
}
