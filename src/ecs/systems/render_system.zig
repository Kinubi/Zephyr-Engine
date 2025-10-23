const std = @import("std");
const World = @import("../world.zig").World;
const View = @import("../view.zig").View;
const Transform = @import("../components/transform.zig").Transform;
const MeshRenderer = @import("../components/mesh_renderer.zig").MeshRenderer;
const Camera = @import("../components/camera.zig").Camera;
const math = @import("../../utils/math.zig");
const render_data_types = @import("../../rendering/render_data_types.zig");
const RaytracingData = render_data_types.RaytracingData;
const RasterizationData = render_data_types.RasterizationData;
const AssetManager = @import("../../assets/asset_manager.zig").AssetManager;
const AssetId = @import("../../assets/asset_manager.zig").AssetId;
const Mesh = @import("../../core/graphics_context.zig").Mesh;

/// RenderSystem extracts rendering data from ECS entities
/// Queries entities with Transform + MeshRenderer and prepares data for rendering
pub const RenderSystem = struct {
    allocator: std.mem.Allocator,

    // Change tracking (similar to SceneBridge)
    last_renderable_count: usize = 0,
    last_geometry_count: usize = 0, // Track mesh count separately
    renderables_dirty: bool = true,

    // Separate flags for raster and ray tracing descriptor updates
    raster_descriptors_dirty: bool = true,
    raytracing_descriptors_dirty: bool = true,

    // Cached render data (rebuilt when changes detected)
    cached_raster_data: ?RasterizationData = null,
    cached_raytracing_data: ?RaytracingData = null,

    pub fn init(allocator: std.mem.Allocator) RenderSystem {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RenderSystem) void {
        if (self.cached_raster_data) |data| {
            self.allocator.free(data.objects);
        }
        if (self.cached_raytracing_data) |*data| {
            self.allocator.free(data.instances);
            self.allocator.free(data.geometries);
            self.allocator.free(data.materials);
        }
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

    /// Check for any changes that require cache/descriptor updates
    /// This runs every frame (very lightweight) and sets dirty flags
    pub fn checkForChanges(self: *RenderSystem, world: *World, asset_manager: *AssetManager) !void {
        // OPTIMIZATION: Fast-path count check first (no allocations)
        var current_renderable_count: usize = 0;
        var current_geometry_count: usize = 0;

        // Quick query to count entities and geometry
        var mesh_view = try world.view(MeshRenderer);
        var iter = mesh_view.iterator();
        while (iter.next()) |entry| {
            const renderer = entry.component;
            if (!renderer.hasValidAssets()) continue;

            current_renderable_count += 1;

            if (renderer.model_asset) |model_asset_id| {
                // Count geometry from loaded model
                if (asset_manager.getModel(model_asset_id)) |model| {
                    current_geometry_count += model.meshes.items.len;
                }
            }
        }

        // Progressive change detection - each check only runs if previous checks didn't detect changes
        var changes_detected = false;
        var reason: []const u8 = "";

        // Check 1: Count changes (cheap - no allocations!)
        if (current_renderable_count != self.last_renderable_count or
            current_geometry_count != self.last_geometry_count)
        {
            changes_detected = true;
            reason = "count_changed";
        }

        // Check 2: Cache missing (cheap)
        if (!changes_detected and self.cached_raster_data == null) {
            changes_detected = true;
            reason = "cache_missing";
        }

        // Check 3: Asset IDs and mesh pointers changed - async asset loading (medium cost)
        // OPTIMIZATION: Only do this expensive check if counts haven't changed
        if (!changes_detected) {
            // Now allocate ArrayList only if needed for deep comparison
            var current_mesh_asset_ids = std.ArrayList(AssetId){};
            defer current_mesh_asset_ids.deinit(self.allocator);

            // Re-iterate to collect asset IDs (only when needed)
            var mesh_view2 = try world.view(MeshRenderer);
            var iter2 = mesh_view2.iterator();
            while (iter2.next()) |entry| {
                const renderer = entry.component;
                if (!renderer.hasValidAssets()) continue;
                if (renderer.model_asset) |model_asset_id| {
                    try current_mesh_asset_ids.append(self.allocator, model_asset_id);
                }
            }

            if (self.cached_raytracing_data) |rt_cache| {
                if (current_mesh_asset_ids.items.len != rt_cache.geometries.len) {
                    changes_detected = true;
                    reason = "rt_geom_count_mismatch";
                } else {
                    var geom_idx: usize = 0;
                    for (current_mesh_asset_ids.items) |current_asset_id| {
                        const model = asset_manager.getModel(current_asset_id) orelse continue;

                        for (model.meshes.items) |model_mesh| {
                            if (geom_idx >= rt_cache.geometries.len) {
                                changes_detected = true;
                                reason = "rt_geom_overflow";
                                break;
                            }

                            const rt_geom = rt_cache.geometries[geom_idx];

                            // Compare asset ID AND mesh pointer (detects async asset loads)
                            if (rt_geom.model_asset != current_asset_id or
                                rt_geom.mesh_ptr != model_mesh.geometry.mesh)
                            {
                                changes_detected = true;
                                reason = "mesh_ptr_changed";
                                break;
                            }

                            geom_idx += 1;
                        }

                        if (changes_detected) break;
                    }
                }
            }
        }

        // Update tracking state
        self.last_renderable_count = current_renderable_count;
        self.last_geometry_count = current_geometry_count;

        // Rebuild if any changes detected
        if (changes_detected) {
            self.renderables_dirty = true;
            self.raster_descriptors_dirty = true;
            self.raytracing_descriptors_dirty = true;

            try self.rebuildCaches(world, asset_manager);
        }
    }

    /// Rebuild both raster and raytracing caches in one pass
    /// Called by checkForChanges when geometry changes detected
    fn rebuildCaches(self: *RenderSystem, world: *World, asset_manager: *AssetManager) !void {
        // Clean up old cached data
        if (self.cached_raster_data) |data| {
            self.allocator.free(data.objects);
        }
        if (self.cached_raytracing_data) |*data| {
            self.allocator.free(data.instances);
            self.allocator.free(data.geometries);
            self.allocator.free(data.materials);
        }

        // Extract renderables from ECS
        var temp_renderables = std.ArrayList(RenderableEntity){};
        defer temp_renderables.deinit(self.allocator);
        try self.extractRenderables(world, &temp_renderables);

        // Count total meshes
        var total_meshes: usize = 0;
        for (temp_renderables.items) |renderable| {
            const model = asset_manager.getModel(renderable.model_asset) orelse continue;
            total_meshes += model.meshes.items.len;
        }

        // Allocate arrays for both raster and RT data
        var raster_objects = try self.allocator.alloc(RasterizationData.RenderableObject, total_meshes);
        errdefer self.allocator.free(raster_objects);

        var geometries = try self.allocator.alloc(RaytracingData.RTGeometry, total_meshes);
        errdefer self.allocator.free(geometries);

        var instances = try self.allocator.alloc(RaytracingData.RTInstance, total_meshes);
        errdefer self.allocator.free(instances);

        const materials = try self.allocator.alloc(RasterizationData.MaterialData, 0);
        errdefer self.allocator.free(materials);

        // Build both raster and RT data in one loop
        var mesh_idx: usize = 0;
        for (temp_renderables.items) |renderable| {
            const model = asset_manager.getModel(renderable.model_asset) orelse continue;

            // Get material index
            var material_index: u32 = 0;
            if (renderable.material_asset) |material_asset_id| {
                if (asset_manager.getMaterialIndex(material_asset_id)) |mat_idx| {
                    material_index = @intCast(mat_idx);
                }
            }

            // Create raster and RT data for each mesh in the model
            for (model.meshes.items) |model_mesh| {
                // Raster data
                raster_objects[mesh_idx] = .{
                    .transform = renderable.world_matrix.data,
                    .mesh_handle = .{ .mesh_ptr = model_mesh.geometry.mesh },
                    .material_index = material_index,
                    .visible = true,
                };

                // RT geometry
                geometries[mesh_idx] = .{
                    .mesh_ptr = model_mesh.geometry.mesh,
                    .blas = null,
                    .model_asset = renderable.model_asset,
                };

                // RT instance
                instances[mesh_idx] = .{
                    .transform = renderable.world_matrix.to_3x4(),
                    .instance_id = @intCast(mesh_idx),
                    .mask = 0xFF,
                    .geometry_index = @intCast(mesh_idx),
                    .material_index = material_index,
                };

                mesh_idx += 1;
            }
        }

        // Store both caches
        self.cached_raster_data = RasterizationData{
            .objects = raster_objects,
        };
        self.cached_raytracing_data = RaytracingData{
            .instances = instances,
            .geometries = geometries,
            .materials = materials,
        };
    }

    /// Check if BVH needs to be rebuilt (for ray tracing system)
    /// Returns true if renderables_dirty flag is set OR if cache doesn't exist yet
    pub fn checkBvhRebuildNeeded(self: *RenderSystem) !bool {

        // The actual checking is done by checkForChanges() which runs every frame
        // Also check if cache doesn't exist yet (first frame)
        return self.renderables_dirty or self.cached_raytracing_data == null;
    }

    /// Get cached raster data (already built by checkForChanges)
    /// Returns a COPY of the cached data that the caller owns
    pub fn getRasterData(self: *RenderSystem) !RasterizationData {
        if (self.cached_raster_data) |cached| {
            // Return a copy with duplicated array
            const objects_copy = try self.allocator.dupe(RasterizationData.RenderableObject, cached.objects);

            return RasterizationData{
                .objects = objects_copy,
            };
        }

        // If no cache exists, return empty data
        const empty_objects = try self.allocator.alloc(RasterizationData.RenderableObject, 0);
        return RasterizationData{
            .objects = empty_objects,
        };
    }

    /// Get cached raytracing data (already built by checkForChanges)
    /// Returns a COPY of the cached data that the caller owns
    pub fn getRaytracingData(self: *RenderSystem) !RaytracingData {
        if (self.cached_raytracing_data) |cached| {
            // Return a copy with duplicated arrays
            const instances_copy = try self.allocator.dupe(RaytracingData.RTInstance, cached.instances);
            const geometries_copy = try self.allocator.dupe(RaytracingData.RTGeometry, cached.geometries);
            const materials_copy = try self.allocator.dupe(RasterizationData.MaterialData, cached.materials);

            return RaytracingData{
                .instances = instances_copy,
                .geometries = geometries_copy,
                .materials = materials_copy,
            };
        }

        // If no cache exists, return empty data
        return RaytracingData{
            .instances = &[_]RaytracingData.RTInstance{},
            .geometries = &[_]RaytracingData.RTGeometry{},
            .materials = &[_]RasterizationData.MaterialData{},
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
