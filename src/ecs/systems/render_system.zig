const std = @import("std");
const World = @import("../world.zig").World;
const View = @import("../view.zig").View;
const Transform = @import("../components/transform.zig").Transform;
const MeshRenderer = @import("../components/mesh_renderer.zig").MeshRenderer;
const Camera = @import("../components/camera.zig").Camera;
const math = @import("../../utils/math.zig");
const SceneBridge = @import("../../rendering/scene_bridge.zig");
const AssetManager = @import("../../assets/asset_manager.zig").AssetManager;
const AssetId = @import("../../assets/asset_manager.zig").AssetId;
const Mesh = @import("../../core/graphics_context.zig").Mesh;

/// RenderSystem extracts rendering data from ECS entities
/// Queries entities with Transform + MeshRenderer and prepares data for rendering
pub const RenderSystem = struct {
    allocator: std.mem.Allocator,

    // Change tracking (similar to SceneBridge)
    last_renderable_count: usize = 0,
    last_mesh_asset_ids: std.ArrayList(AssetId) = .{},
    renderables_dirty: bool = true,

    pub fn init(allocator: std.mem.Allocator) RenderSystem {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RenderSystem) void {
        self.last_mesh_asset_ids.deinit(self.allocator);
    }

    /// Rendering data for a single frame
    pub const RenderData = struct {
        /// List of renderable entities with their transforms
        renderables: std.ArrayList(RenderableEntity),
        /// Primary camera data (if found)
        camera: ?CameraData,
        /// Allocator for cleanup
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) RenderData {
            return .{
                .renderables = .{},
                .camera = null,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *RenderData) void {
            self.renderables.deinit(self.allocator);
        }
    };

    /// Combined data from Transform + MeshRenderer
    pub const RenderableEntity = struct {
        model_asset: @import("../../assets/asset_types.zig").AssetId,
        material_asset: ?@import("../../assets/asset_types.zig").AssetId,
        texture_asset: ?@import("../../assets/asset_types.zig").AssetId,
        world_matrix: math.Mat4x4,
        layer: u8,
        casts_shadows: bool,
        receives_shadows: bool,
    };

    /// Camera data extracted from Camera + Transform
    pub const CameraData = struct {
        projection_matrix: math.Mat4x4,
        view_matrix: math.Mat4x4,
        position: math.Vec3,
    };

    /// Extract rendering data from the world
    /// This queries all entities with Transform + MeshRenderer
    /// and the primary Camera + Transform
    pub fn extractRenderData(self: *RenderSystem, world: *World) !RenderData {
        var render_data = RenderData.init(self.allocator);
        errdefer render_data.deinit();

        // Extract camera data first
        render_data.camera = try self.extractCamera(world);

        // Extract all renderable entities
        try self.extractRenderables(world, &render_data.renderables);

        // Check if renderable count or mesh asset IDs changed (detects async loading)
        const current_count = render_data.renderables.items.len;
        var mesh_ids_changed = false;

        // Build current mesh asset ID list
        var current_mesh_ids: std.ArrayList(AssetId) = .{};
        defer current_mesh_ids.deinit(self.allocator);

        for (render_data.renderables.items) |renderable| {
            try current_mesh_ids.append(self.allocator, renderable.model_asset);
        }

        // Compare with last mesh IDs (detects when async assets finish loading)
        if (current_mesh_ids.items.len != self.last_mesh_asset_ids.items.len) {
            mesh_ids_changed = true;
        } else {
            // Sort both lists for comparison
            std.sort.insertion(AssetId, current_mesh_ids.items, {}, assetIdLessThan);
            std.sort.insertion(AssetId, self.last_mesh_asset_ids.items, {}, assetIdLessThan);

            for (current_mesh_ids.items, self.last_mesh_asset_ids.items) |curr, last| {
                if (curr != last) {
                    mesh_ids_changed = true;
                    break;
                }
            }
        }

        // Update dirty flag if count or mesh IDs changed
        if (current_count != self.last_renderable_count or mesh_ids_changed) {
            if (current_count != self.last_renderable_count) {
                std.log.info("RenderSystem: Renderable count changed: {} -> {}", .{ self.last_renderable_count, current_count });
            }
            if (mesh_ids_changed) {
                std.log.info("RenderSystem: Mesh asset IDs changed (async loading detected)", .{});
            }
            self.renderables_dirty = true;
            self.last_renderable_count = current_count;

            // Update tracked mesh IDs
            self.last_mesh_asset_ids.clearRetainingCapacity();
            try self.last_mesh_asset_ids.appendSlice(self.allocator, current_mesh_ids.items);
        }

        // Sort by layer (optional, for render ordering)
        std.sort.insertion(RenderableEntity, render_data.renderables.items, {}, compareByLayer);

        return render_data;
    }

    /// Check if renderables have been updated (similar to SceneBridge.raytracingUpdated)
    pub fn renderablesUpdated(self: *RenderSystem) bool {
        return self.renderables_dirty;
    }

    /// Mark renderables as synced (similar to SceneBridge.markRaytracingSynced)
    pub fn markRenderablesSynced(self: *RenderSystem) void {
        self.renderables_dirty = false;
    }

    /// Force mark renderables as dirty (for when assets load asynchronously)
    pub fn markRenderablesDirty(self: *RenderSystem) void {
        self.renderables_dirty = true;
    }

    /// Extract primary camera data
    fn extractCamera(self: *RenderSystem, world: *World) !?CameraData {
        _ = self;

        // Find the first entity with Camera component that is primary
        var camera_view = try world.view(Camera);

        var iter = camera_view.iterator();
        while (iter.next()) |entry| {
            const camera = entry.component;
            if (camera.is_primary) {
                // Try to get the transform for this camera entity
                const transform = world.get(Transform, entry.entity);

                const position = if (transform) |t| t.position else math.Vec3.init(0, 0, 0);

                // Get view matrix from transform
                // TODO: Implement proper matrix inverse for view transform
                // For now, use identity as placeholder
                const view_matrix = if (transform) |_|
                    math.Mat4x4.identity()
                else
                    math.Mat4x4.identity();

                return CameraData{
                    .projection_matrix = camera.projection_matrix,
                    .view_matrix = view_matrix,
                    .position = position,
                };
            }
        }

        return null;
    }

    /// Extract all renderable entities
    fn extractRenderables(self: *RenderSystem, world: *World, renderables: *std.ArrayList(RenderableEntity)) !void {
        // Query all entities that have MeshRenderer
        var mesh_view = try world.view(MeshRenderer);

        var iter = mesh_view.iterator();
        while (iter.next()) |entry| {
            const renderer = entry.component;

            // Skip if not enabled or doesn't have valid assets
            if (!renderer.hasValidAssets()) {
                continue;
            }

            // Try to get transform (default to identity if missing)
            const transform = world.get(Transform, entry.entity);
            const world_matrix = if (transform) |t| t.world_matrix else math.Mat4x4.identity();

            // Create renderable entry
            try renderables.append(self.allocator, RenderableEntity{
                .model_asset = renderer.model_asset.?,
                .material_asset = renderer.material_asset,
                .texture_asset = renderer.getTextureAsset(),
                .world_matrix = world_matrix,
                .layer = renderer.layer,
                .casts_shadows = renderer.casts_shadows,
                .receives_shadows = renderer.receives_shadows,
            });
        }
    }

    /// Comparison function for sorting by layer
    fn compareByLayer(context: void, a: RenderableEntity, b: RenderableEntity) bool {
        _ = context;
        return a.layer < b.layer;
    }

    /// Comparison function for sorting AssetIds
    fn assetIdLessThan(context: void, a: AssetId, b: AssetId) bool {
        _ = context;
        return @intFromEnum(a) < @intFromEnum(b);
    }

    /// Check if BVH needs to be rebuilt (analogous to SceneBridge.checkBvhRebuildNeeded)
    pub fn checkBvhRebuildNeeded(self: *RenderSystem) bool {
        return self.renderables_dirty;
    }

    /// Get raytracing data from current renderables (analogous to SceneBridge.getRaytracingData)
    /// Caller must free the returned RaytracingData's instances and geometries slices
    pub fn getRaytracingData(
        self: *RenderSystem,
        world: *World,
        asset_manager: *AssetManager,
        allocator: std.mem.Allocator,
    ) !SceneBridge.RaytracingData {
        // First extract current render data
        var render_data = try self.extractRenderData(world);
        defer render_data.deinit();

        // Count total meshes across all models
        var total_meshes: usize = 0;
        for (render_data.renderables.items) |renderable| {
            const model = asset_manager.getModel(renderable.model_asset) orelse continue;
            total_meshes += model.meshes.items.len;
        }

        // Allocate slices for RT data based on total mesh count
        var geometries = try allocator.alloc(SceneBridge.RaytracingData.RTGeometry, total_meshes);
        errdefer allocator.free(geometries);

        var instances = try allocator.alloc(SceneBridge.RaytracingData.RTInstance, total_meshes);
        errdefer allocator.free(instances);

        // Empty materials for now (will be populated from asset_manager later)
        const materials = try allocator.alloc(SceneBridge.RasterizationData.MaterialData, 0);
        errdefer allocator.free(materials);

        // Convert renderables to RT format (one instance per mesh)
        var geometry_idx: usize = 0;
        for (render_data.renderables.items) |renderable| {
            // Get model from asset manager
            const model = asset_manager.getModel(renderable.model_asset) orelse {
                std.log.warn("RenderSystem: Failed to get model for asset {}", .{@intFromEnum(renderable.model_asset)});
                continue;
            };

            // Get material index from AssetManager (like SceneBridge does)
            var material_index: u32 = 0;
            if (renderable.material_asset) |material_asset_id| {
                if (asset_manager.getMaterialIndex(material_asset_id)) |mat_idx| {
                    material_index = @intCast(mat_idx);
                }
            }

            // Create geometry/instance pair for each mesh in the model
            for (model.meshes.items) |model_mesh| {
                // Create geometry entry
                geometries[geometry_idx] = .{
                    .mesh_ptr = model_mesh.geometry.mesh,
                    .blas = null, // Will be filled by rt_system
                };

                // Create instance entry with 3x4 transform matrix
                instances[geometry_idx] = .{
                    .transform = renderable.world_matrix.to_3x4(),
                    .instance_id = @intCast(geometry_idx),
                    .mask = 0xFF,
                    .geometry_index = @intCast(geometry_idx),
                    .material_index = material_index,
                };

                geometry_idx += 1;
            }
        }

        return SceneBridge.RaytracingData{
            .instances = instances,
            .geometries = geometries,
            .materials = materials,
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "RenderSystem: extract empty world" {
    const ecs = @import("../world.zig");

    var world = ecs.World.init(std.testing.allocator, null);
    defer world.deinit();

    // Register components even for empty world test
    try world.registerComponent(Camera);
    try world.registerComponent(MeshRenderer);

    var system = RenderSystem.init(std.testing.allocator);
    defer system.deinit();

    var render_data = try system.extractRenderData(&world);
    defer render_data.deinit();

    try std.testing.expectEqual(@as(usize, 0), render_data.renderables.items.len);
    try std.testing.expect(render_data.camera == null);
}

test "RenderSystem: extract single renderable" {
    const ecs = @import("../world.zig");

    var world = ecs.World.init(std.testing.allocator, null);
    defer world.deinit();

    try world.registerComponent(Camera);
    try world.registerComponent(Transform);
    try world.registerComponent(MeshRenderer);

    var system = RenderSystem.init(std.testing.allocator);
    defer system.deinit();

    // Create entity with transform and renderer
    const entity = try world.createEntity();

    const transform = Transform.initWithPosition(.{ .x = 1, .y = 2, .z = 3 });
    try world.emplace(Transform, entity, transform);

    const renderer = MeshRenderer.init(@enumFromInt(100), @enumFromInt(200));
    try world.emplace(MeshRenderer, entity, renderer);

    // Extract render data
    var render_data = try system.extractRenderData(&world);
    defer render_data.deinit();

    try std.testing.expectEqual(@as(usize, 1), render_data.renderables.items.len);

    const renderable = render_data.renderables.items[0];
    try std.testing.expectEqual(@as(AssetId, @enumFromInt(100)), renderable.model_asset);
    try std.testing.expectEqual(@as(AssetId, @enumFromInt(200)), renderable.material_asset.?);
}

test "RenderSystem: disabled renderer not extracted" {
    const ecs = @import("../world.zig");

    var world = ecs.World.init(std.testing.allocator, null);
    defer world.deinit();

    try world.registerComponent(Camera);
    try world.registerComponent(MeshRenderer);

    var system = RenderSystem.init(std.testing.allocator);
    defer system.deinit();

    // Create entity with disabled renderer
    const entity = try world.createEntity();
    var renderer = MeshRenderer.init(@enumFromInt(100), @enumFromInt(200));
    renderer.setEnabled(false);
    try world.emplace(MeshRenderer, entity, renderer);

    // Extract render data
    var render_data = try system.extractRenderData(&world);
    defer render_data.deinit();

    // Should be empty because renderer is disabled
    try std.testing.expectEqual(@as(usize, 0), render_data.renderables.items.len);
}

test "RenderSystem: extract primary camera" {
    const ecs = @import("../world.zig");

    var world = ecs.World.init(std.testing.allocator, null);
    defer world.deinit();

    try world.registerComponent(Camera);
    try world.registerComponent(Transform);
    try world.registerComponent(MeshRenderer);

    var system = RenderSystem.init(std.testing.allocator);
    defer system.deinit();

    // Create camera entity
    const entity = try world.createEntity();

    var camera = Camera.initPerspective(60.0, 16.0 / 9.0, 0.1, 100.0);
    camera.setPrimary(true);
    try world.emplace(Camera, entity, camera);

    const transform = Transform.initWithPosition(.{ .x = 0, .y = 5, .z = 10 });
    try world.emplace(Transform, entity, transform);

    // Extract render data
    var render_data = try system.extractRenderData(&world);
    defer render_data.deinit();

    try std.testing.expect(render_data.camera != null);

    const cam_data = render_data.camera.?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), cam_data.position.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), cam_data.position.y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), cam_data.position.z, 0.001);
}

test "RenderSystem: sort by layer" {
    const ecs = @import("../world.zig");

    var world = ecs.World.init(std.testing.allocator, null);
    defer world.deinit();

    try world.registerComponent(Camera);
    try world.registerComponent(MeshRenderer);

    var system = RenderSystem.init(std.testing.allocator);
    defer system.deinit();

    // Create entities with different layers (in reverse order)
    const entity1 = try world.createEntity();
    var renderer1 = MeshRenderer.init(@enumFromInt(1), @enumFromInt(1));
    renderer1.setLayer(10);
    try world.emplace(MeshRenderer, entity1, renderer1);

    const entity2 = try world.createEntity();
    var renderer2 = MeshRenderer.init(@enumFromInt(2), @enumFromInt(2));
    renderer2.setLayer(5);
    try world.emplace(MeshRenderer, entity2, renderer2);

    const entity3 = try world.createEntity();
    var renderer3 = MeshRenderer.init(@enumFromInt(3), @enumFromInt(3));
    renderer3.setLayer(20);
    try world.emplace(MeshRenderer, entity3, renderer3);

    // Extract render data (should be sorted by layer)
    var render_data = try system.extractRenderData(&world);
    defer render_data.deinit();

    try std.testing.expectEqual(@as(usize, 3), render_data.renderables.items.len);

    // Should be sorted: 5, 10, 20
    try std.testing.expectEqual(@as(u8, 5), render_data.renderables.items[0].layer);
    try std.testing.expectEqual(@as(u8, 10), render_data.renderables.items[1].layer);
    try std.testing.expectEqual(@as(u8, 20), render_data.renderables.items[2].layer);
}
