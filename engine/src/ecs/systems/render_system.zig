const std = @import("std");
const World = @import("../world.zig").World;
const View = @import("../view.zig").View;
const Transform = @import("../components/transform.zig").Transform;
const MeshRenderer = @import("../components/mesh_renderer.zig").MeshRenderer;
const Camera = @import("../components/camera.zig").Camera;
const EntityId = @import("../entity_registry.zig").EntityId;
const math = @import("../../utils/math.zig");
const render_data_types = @import("../../rendering/render_data_types.zig");
const RaytracingData = render_data_types.RaytracingData;
const RasterizationData = render_data_types.RasterizationData;
const AssetManager = @import("../../assets/asset_manager.zig").AssetManager;
const AssetId = @import("../../assets/asset_manager.zig").AssetId;
const Mesh = @import("../../core/graphics_context.zig").Mesh;
const ThreadPool = @import("../../threading/thread_pool.zig").ThreadPool;
const WorkItem = @import("../../threading/thread_pool.zig").WorkItem;
const log = @import("../../utils/log.zig").log;

/// RenderSystem extracts rendering data from ECS entities
/// Queries entities with Transform + MeshRenderer and prepares data for rendering
pub const RenderSystem = struct {
    allocator: std.mem.Allocator,
    thread_pool: ?*ThreadPool,

    // Change tracking (similar to SceneBridge)
    last_renderable_count: usize = 0,
    last_geometry_count: usize = 0, // Track mesh count separately
    renderables_dirty: bool = true,

    // Separate flags for raster and ray tracing descriptor updates
    raster_descriptors_dirty: bool = true,
    raytracing_descriptors_dirty: bool = true,

    // NEW: Track what KIND of change occurred
    // transform_only_change: only transforms changed (TLAS update needed, no BLAS rebuild, no descriptor rebind)
    // geometry_change: mesh count/assets changed (full rebuild + descriptors)
    transform_only_change: bool = false,

    // Cached render data (rebuilt when changes detected)
    cached_raster_data: ?RasterizationData = null,
    cached_raytracing_data: ?RaytracingData = null,

    pub fn init(allocator: std.mem.Allocator, thread_pool: ?*ThreadPool) !RenderSystem {
        // Register with thread pool if provided
        if (thread_pool) |tp| {
            try tp.registerSubsystem(.{
                .name = "render_extraction",
                .min_workers = 2,
                .max_workers = 8,
                .priority = .high, // Frame-critical work
                .work_item_type = .render_extraction,
            });
            log(.INFO, "render_system", "Registered render_extraction subsystem with thread pool", .{});
        }
        
        return .{
            .allocator = allocator,
            .thread_pool = thread_pool,
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

    /// Extract all renderable entities (with optional parallelization)
    fn extractRenderables(self: *RenderSystem, world: *World, renderables: *std.ArrayList(RenderableEntity)) !void {
        // Use parallel extraction if thread_pool is available
        if (self.thread_pool) |pool| {
            try self.extractRenderablesParallel(world, renderables, pool);
        } else {
            try self.extractRenderablesSingleThreaded(world, renderables);
        }
    }

    /// Single-threaded extraction (fallback for tests)
    fn extractRenderablesSingleThreaded(self: *RenderSystem, world: *World, renderables: *std.ArrayList(RenderableEntity)) !void {
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

    /// Context for parallel extraction work
    const ExtractionWorkContext = struct {
        system: *RenderSystem,
        world: *World,
        entities: []const EntityId,
        start_idx: usize,
        end_idx: usize,
        results: *std.ArrayList(RenderableEntity),
        mutex: *std.Thread.Mutex,
        completion: *std.atomic.Value(usize),
    };

    /// Worker function for parallel extraction
    fn extractionWorker(context: *anyopaque, work_item: WorkItem) void {
        const ctx = @as(*ExtractionWorkContext, @ptrCast(@alignCast(context)));
        _ = work_item;

        // Extract renderables for this chunk
        var local_results = std.ArrayList(RenderableEntity){};
        defer local_results.deinit(ctx.system.allocator);

        for (ctx.entities[ctx.start_idx..ctx.end_idx]) |entity| {
            // Check if entity has MeshRenderer
            const renderer = ctx.world.get(MeshRenderer, entity) orelse continue;

            // Skip if not enabled or doesn't have valid assets
            if (!renderer.hasValidAssets()) {
                continue;
            }

            // Try to get transform (default to identity if missing)
            const transform = ctx.world.get(Transform, entity);
            const world_matrix = if (transform) |t| t.world_matrix else math.Mat4x4.identity();

            // Create renderable entry
            local_results.append(ctx.system.allocator, RenderableEntity{
                .model_asset = renderer.model_asset.?,
                .material_asset = renderer.material_asset,
                .texture_asset = renderer.getTextureAsset(),
                .world_matrix = world_matrix,
                .layer = renderer.layer,
                .casts_shadows = renderer.casts_shadows,
                .receives_shadows = renderer.receives_shadows,
            }) catch |err| {
                std.log.err("Failed to append renderable in worker: {}", .{err});
                _ = ctx.completion.fetchSub(1, .release);
                return;
            };
        }

        // Merge results with mutex protection
        ctx.mutex.lock();
        defer ctx.mutex.unlock();

        for (local_results.items) |item| {
            ctx.results.append(ctx.system.allocator, item) catch |err| {
                std.log.err("Failed to merge worker results: {}", .{err});
                _ = ctx.completion.fetchSub(1, .release);
                return;
            };
        }

        // Signal completion
        _ = ctx.completion.fetchSub(1, .release);
    }

    /// Parallel extraction using thread pool
    fn extractRenderablesParallel(
        self: *RenderSystem,
        world: *World,
        renderables: *std.ArrayList(RenderableEntity),
        pool: *ThreadPool,
    ) !void {
        // Get all entities that have MeshRenderer component
        const mesh_view = try world.view(MeshRenderer);
        const all_entities = mesh_view.storage.entities.items;
        if (all_entities.len == 0) return;

        // Use fixed chunk count for simplicity (can be tuned later)
        const worker_count: usize = 4; // Conservative default, balances overhead vs parallelism
        const chunk_size = (all_entities.len + worker_count - 1) / worker_count;

        // If entity count is too small, fall back to single-threaded
        if (all_entities.len < 100) {
            try self.extractRenderablesSingleThreaded(world, renderables);
            return;
        }

        log(.DEBUG, "render_system", "Parallel extraction: {} entities, {} workers, {} chunk size", .{ all_entities.len, worker_count, chunk_size });

        // Create mutex for result merging and atomic completion counter
        var mutex = std.Thread.Mutex{};
        var completion = std.atomic.Value(usize).init(worker_count);

        // Submit work for each chunk
        var contexts = try self.allocator.alloc(ExtractionWorkContext, worker_count);
        defer self.allocator.free(contexts);

        var submitted_count: usize = 0;
        for (0..worker_count) |i| {
            const start_idx = i * chunk_size;
            if (start_idx >= all_entities.len) break;
            const end_idx = @min(start_idx + chunk_size, all_entities.len);

            contexts[i] = ExtractionWorkContext{
                .system = self,
                .world = world,
                .entities = all_entities,
                .start_idx = start_idx,
                .end_idx = end_idx,
                .results = renderables,
                .mutex = &mutex,
                .completion = &completion,
            };

            try pool.submitWork(.{
                .id = i,
                .item_type = .render_extraction,
                .priority = .high,
                .data = .{ .render_extraction = .{
                    .chunk_index = @intCast(i),
                    .total_chunks = @intCast(worker_count),
                    .user_data = &contexts[i],
                } },
                .worker_fn = extractionWorker,
                .context = &contexts[i],
            });

            submitted_count += 1;
        }

        // Wait for all workers to complete
        while (completion.load(.acquire) > 0) {
            std.Thread.yield() catch {};
        }
    }

    // ============================================================================
    // SNAPSHOT-BASED FUNCTIONS (Phase 2.1 - Render Thread Support)
    // ============================================================================
    
    /// Rebuild caches from a GameStateSnapshot instead of World
    /// This is called by the render thread with an immutable snapshot
    pub fn rebuildCachesFromSnapshot(
        self: *RenderSystem,
        snapshot: *const @import("../../threading/game_state_snapshot.zig").GameStateSnapshot,
        asset_manager: *AssetManager,
    ) !void {
        const start_time = std.time.nanoTimestamp();

        // Clean up old cached data
        if (self.cached_raster_data) |data| {
            self.allocator.free(data.objects);
        }
        if (self.cached_raytracing_data) |*data| {
            self.allocator.free(data.instances);
            self.allocator.free(data.geometries);
            self.allocator.free(data.materials);
        }

        const cache_build_start = std.time.nanoTimestamp();

        // Build caches from snapshot entities
        const entities = snapshot.entities[0..snapshot.entity_count];
        
        // Use parallel cache building if thread_pool available and enough work
        if (self.thread_pool != null and entities.len >= 50) {
            try self.buildCachesFromSnapshotParallel(entities, asset_manager);
        } else {
            try self.buildCachesFromSnapshotSingleThreaded(entities, asset_manager);
        }

        const cache_build_time_ns = std.time.nanoTimestamp() - cache_build_start;
        const cache_build_time_ms = @as(f64, @floatFromInt(cache_build_time_ns)) / 1_000_000.0;

        const total_time_ns = std.time.nanoTimestamp() - start_time;
        const total_time_ms = @as(f64, @floatFromInt(total_time_ns)) / 1_000_000.0;

        // Frame budget enforcement
        const budget_ms: f64 = 2.0;
        if (total_time_ms > budget_ms) {
            log(.WARN, "render_system", "Frame budget exceeded in snapshot rebuild! Total: {d:.2}ms (cache: {d:.2}ms) Budget: {d:.2}ms", .{ total_time_ms, cache_build_time_ms, budget_ms });
        } else {
            log(.DEBUG, "render_system", "Snapshot rebuild complete: {d:.2}ms (cache: {d:.2}ms)", .{ total_time_ms, cache_build_time_ms });
        }

        self.renderables_dirty = false;
    }

    /// Build caches from snapshot entities (single-threaded)
    fn buildCachesFromSnapshotSingleThreaded(
        self: *RenderSystem,
        entities: []const @import("../../threading/game_state_snapshot.zig").GameStateSnapshot.EntityRenderData,
        asset_manager: *AssetManager,
    ) !void {
        // Count total meshes
        var total_meshes: usize = 0;
        for (entities) |entity_data| {
            const model = asset_manager.getModel(entity_data.model_asset) orelse continue;
            total_meshes += model.meshes.items.len;
        }

        // Allocate output arrays
        const raster_objects = try self.allocator.alloc(RasterizationData.RenderableObject, total_meshes);
        const geometries = try self.allocator.alloc(RaytracingData.RTGeometry, total_meshes);
        const instances = try self.allocator.alloc(RaytracingData.RTInstance, total_meshes);
        const materials = try self.allocator.alloc(RasterizationData.MaterialData, 0);

        var mesh_idx: usize = 0;
        for (entities) |entity_data| {
            const model = asset_manager.getModel(entity_data.model_asset) orelse continue;

            var material_index: u32 = 0;
            if (entity_data.material_asset) |material_asset_id| {
                if (asset_manager.getMaterialIndex(material_asset_id)) |mat_idx| {
                    material_index = @intCast(mat_idx);
                }
            }

            for (model.meshes.items) |model_mesh| {
                raster_objects[mesh_idx] = .{
                    .transform = entity_data.transform.data,
                    .mesh_handle = .{ .mesh_ptr = model_mesh.geometry.mesh },
                    .material_index = material_index,
                    .visible = true,
                };

                geometries[mesh_idx] = .{
                    .mesh_ptr = model_mesh.geometry.mesh,
                    .blas = null,
                    .model_asset = entity_data.model_asset,
                };

                instances[mesh_idx] = .{
                    .transform = entity_data.transform.to_3x4(),
                    .instance_id = @intCast(mesh_idx),
                    .mask = 0xFF,
                    .geometry_index = @intCast(mesh_idx),
                    .material_index = material_index,
                };

                mesh_idx += 1;
            }
        }

        // Store cached data
        self.cached_raster_data = .{
            .objects = raster_objects,
            .materials = materials,
        };

        self.cached_raytracing_data = .{
            .instances = instances,
            .geometries = geometries,
            .materials = materials,
        };
    }

    /// Build caches from snapshot entities (parallel)
    fn buildCachesFromSnapshotParallel(
        self: *RenderSystem,
        entities: []const @import("../../threading/game_state_snapshot.zig").GameStateSnapshot.EntityRenderData,
        asset_manager: *AssetManager,
    ) !void {
        const pool = self.thread_pool.?;

        // Count meshes per entity
        var mesh_counts = try self.allocator.alloc(usize, entities.len);
        defer self.allocator.free(mesh_counts);

        var total_meshes: usize = 0;
        for (entities, 0..) |entity_data, i| {
            const model = asset_manager.getModel(entity_data.model_asset) orelse {
                mesh_counts[i] = 0;
                continue;
            };
            mesh_counts[i] = model.meshes.items.len;
            total_meshes += model.meshes.items.len;
        }

        // Allocate output arrays
        const raster_objects = try self.allocator.alloc(RasterizationData.RenderableObject, total_meshes);
        errdefer self.allocator.free(raster_objects);

        const geometries = try self.allocator.alloc(RaytracingData.RTGeometry, total_meshes);
        errdefer self.allocator.free(geometries);

        const instances = try self.allocator.alloc(RaytracingData.RTInstance, total_meshes);
        errdefer self.allocator.free(instances);

        const materials = try self.allocator.alloc(RasterizationData.MaterialData, 0);
        errdefer self.allocator.free(materials);

        // Split work into chunks
        const worker_count: usize = 4;
        const chunk_size = (entities.len + worker_count - 1) / worker_count;

        var completion = std.atomic.Value(usize).init(worker_count);
        var contexts = try self.allocator.alloc(SnapshotCacheBuildContext, worker_count);
        defer self.allocator.free(contexts);

        // Calculate output offsets for each chunk
        var current_offset: usize = 0;
        for (0..worker_count) |i| {
            const start_idx = i * chunk_size;
            if (start_idx >= entities.len) break;
            const end_idx = @min(start_idx + chunk_size, entities.len);

            // Calculate this chunk's output offset
            var chunk_mesh_count: usize = 0;
            for (mesh_counts[start_idx..end_idx]) |count| {
                chunk_mesh_count += count;
            }

            contexts[i] = SnapshotCacheBuildContext{
                .entities = entities,
                .start_idx = start_idx,
                .end_idx = end_idx,
                .raster_objects = raster_objects,
                .geometries = geometries,
                .instances = instances,
                .asset_manager = asset_manager,
                .output_offset = current_offset,
                .completion = &completion,
            };

            try pool.submitWork(.{
                .id = i,
                .item_type = .render_extraction,
                .priority = .high,
                .data = .{ .render_extraction = .{
                    .chunk_index = @intCast(i),
                    .total_chunks = @intCast(worker_count),
                    .user_data = &contexts[i],
                } },
                .worker_fn = snapshotCacheBuilderWorker,
                .context = &contexts[i],
            });

            current_offset += chunk_mesh_count;
        }

        // Wait for completion
        while (completion.load(.acquire) > 0) {
            std.Thread.yield() catch {};
        }

        // Store cached data
        self.cached_raster_data = .{
            .objects = raster_objects,
            .materials = materials,
        };

        self.cached_raytracing_data = .{
            .instances = instances,
            .geometries = geometries,
            .materials = materials,
        };
    }

    /// Context for snapshot-based parallel cache building
    const SnapshotCacheBuildContext = struct {
        entities: []const @import("../../threading/game_state_snapshot.zig").GameStateSnapshot.EntityRenderData,
        start_idx: usize,
        end_idx: usize,
        raster_objects: []RasterizationData.RenderableObject,
        geometries: []RaytracingData.RTGeometry,
        instances: []RaytracingData.RTInstance,
        asset_manager: *AssetManager,
        output_offset: usize,
        completion: *std.atomic.Value(usize),
    };

    /// Worker function for snapshot-based parallel cache building
    fn snapshotCacheBuilderWorker(context: *anyopaque, work_item: WorkItem) void {
        const ctx = @as(*SnapshotCacheBuildContext, @ptrCast(@alignCast(context)));
        _ = work_item;

        var mesh_offset: usize = 0;

        for (ctx.entities[ctx.start_idx..ctx.end_idx]) |entity_data| {
            const model = ctx.asset_manager.getModel(entity_data.model_asset) orelse continue;

            var material_index: u32 = 0;
            if (entity_data.material_asset) |material_asset_id| {
                if (ctx.asset_manager.getMaterialIndex(material_asset_id)) |mat_idx| {
                    material_index = @intCast(mat_idx);
                }
            }

            for (model.meshes.items) |model_mesh| {
                const output_idx = ctx.output_offset + mesh_offset;

                ctx.raster_objects[output_idx] = .{
                    .transform = entity_data.transform.data,
                    .mesh_handle = .{ .mesh_ptr = model_mesh.geometry.mesh },
                    .material_index = material_index,
                    .visible = true,
                };

                ctx.geometries[output_idx] = .{
                    .mesh_ptr = model_mesh.geometry.mesh,
                    .blas = null,
                    .model_asset = entity_data.model_asset,
                };

                ctx.instances[output_idx] = .{
                    .transform = entity_data.transform.to_3x4(),
                    .instance_id = @intCast(output_idx),
                    .mask = 0xFF,
                    .geometry_index = @intCast(output_idx),
                    .material_index = material_index,
                };

                mesh_offset += 1;
            }
        }

        _ = ctx.completion.fetchSub(1, .release);
    }

    // ============================================================================
    // END OF SNAPSHOT-BASED FUNCTIONS
    // ============================================================================

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

        // Check 4: Transform dirty flags (cheap - detects inspector edits)
        // Check ALL transforms for dirty flags, not just renderables
        // This ensures inspector edits to any object are detected
        if (!changes_detected) {
            var transform_view = try world.view(Transform);
            var transform_iter = transform_view.iterator();
            while (transform_iter.next()) |entry| {
                if (entry.component.dirty) {
                    const has_mesh = world.has(MeshRenderer, entry.entity);
                    // Only trigger rebuild if this entity has a MeshRenderer
                    if (has_mesh) {
                        changes_detected = true;
                        reason = "transform_dirty";
                        break;
                    }
                }
            }
        }

        // Update tracking state
        self.last_renderable_count = current_renderable_count;
        self.last_geometry_count = current_geometry_count;

        // Rebuild if any changes detected
        if (changes_detected) {
            // Determine if this is ONLY a transform change (no geometry/asset changes)
            const is_transform_only = std.mem.eql(u8, reason, "transform_dirty");

            self.renderables_dirty = true;
            self.transform_only_change = is_transform_only; // Only mark descriptors dirty if geometry actually changed (not just transforms)
            if (!is_transform_only) {
                self.raster_descriptors_dirty = true;
                self.raytracing_descriptors_dirty = true;
            }

            try self.rebuildCaches(world, asset_manager);
        }
    }

    /// Rebuild both raster and raytracing caches in one pass
    /// Called by checkForChanges when geometry changes detected
    fn rebuildCaches(self: *RenderSystem, world: *World, asset_manager: *AssetManager) !void {
        const start_time = std.time.nanoTimestamp();

        // Clean up old cached data
        if (self.cached_raster_data) |data| {
            self.allocator.free(data.objects);
        }
        if (self.cached_raytracing_data) |*data| {
            self.allocator.free(data.instances);
            self.allocator.free(data.geometries);
            self.allocator.free(data.materials);
        }

        const extraction_start = std.time.nanoTimestamp();

        // Extract renderables from ECS (already parallel)
        var temp_renderables = std.ArrayList(RenderableEntity){};
        defer temp_renderables.deinit(self.allocator);
        try self.extractRenderables(world, &temp_renderables);

        const extraction_time_ns = std.time.nanoTimestamp() - extraction_start;
        const extraction_time_ms = @as(f64, @floatFromInt(extraction_time_ns)) / 1_000_000.0;

        const cache_build_start = std.time.nanoTimestamp();

        // Use parallel cache building if thread_pool available and enough work
        if (self.thread_pool != null and temp_renderables.items.len >= 50) {
            try self.buildCachesParallel(temp_renderables.items, asset_manager);
        } else {
            try self.buildCachesSingleThreaded(temp_renderables.items, asset_manager);
        }

        const cache_build_time_ns = std.time.nanoTimestamp() - cache_build_start;
        const cache_build_time_ms = @as(f64, @floatFromInt(cache_build_time_ns)) / 1_000_000.0;

        const total_time_ns = std.time.nanoTimestamp() - start_time;
        const total_time_ms = @as(f64, @floatFromInt(total_time_ns)) / 1_000_000.0;

        // Frame budget enforcement: warn if we exceed 2ms
        const budget_ms: f64 = 2.0;

        if (total_time_ms > budget_ms) {
            log(.WARN, "render_system", "Frame budget exceeded! Total: {d:.2}ms (extraction: {d:.2}ms, cache: {d:.2}ms) Budget: {d:.2}ms", .{ total_time_ms, extraction_time_ms, cache_build_time_ms, budget_ms });
        } else if (total_time_ms > budget_ms * 0.8) {
            // Warn at 80% of budget
            log(.INFO, "render_system", "Approaching frame budget: {d:.2}ms / {d:.2}ms (extraction: {d:.2}ms, cache: {d:.2}ms)", .{ total_time_ms, budget_ms, extraction_time_ms, cache_build_time_ms });
        } else {
            log(.DEBUG, "render_system", "Rebuild complete: {d:.2}ms (extraction: {d:.2}ms, cache: {d:.2}ms)", .{ total_time_ms, extraction_time_ms, cache_build_time_ms });
        }

        // Clear dirty flags only for renderable entities (not lights, cameras, etc.)
        var mesh_view_clear = try world.view(MeshRenderer);
        var mesh_iter_clear = mesh_view_clear.iterator();
        var cleared_count: usize = 0;
        while (mesh_iter_clear.next()) |entry| {
            if (world.get(Transform, entry.entity)) |transform| {
                if (transform.dirty) {
                    cleared_count += 1;
                }
                transform.dirty = false;
            }
        }
    }

    /// Single-threaded cache building
    fn buildCachesSingleThreaded(self: *RenderSystem, renderables: []const RenderableEntity, asset_manager: *AssetManager) !void {
        // Count total meshes
        var total_meshes: usize = 0;
        for (renderables) |renderable| {
            const model = asset_manager.getModel(renderable.model_asset) orelse continue;
            total_meshes += model.meshes.items.len;
        }

        // Allocate arrays
        var raster_objects = try self.allocator.alloc(RasterizationData.RenderableObject, total_meshes);
        errdefer self.allocator.free(raster_objects);

        var geometries = try self.allocator.alloc(RaytracingData.RTGeometry, total_meshes);
        errdefer self.allocator.free(geometries);

        var instances = try self.allocator.alloc(RaytracingData.RTInstance, total_meshes);
        errdefer self.allocator.free(instances);

        const materials = try self.allocator.alloc(RasterizationData.MaterialData, 0);
        errdefer self.allocator.free(materials);

        // Build data
        var mesh_idx: usize = 0;
        for (renderables) |renderable| {
            const model = asset_manager.getModel(renderable.model_asset) orelse continue;

            var material_index: u32 = 0;
            if (renderable.material_asset) |material_asset_id| {
                if (asset_manager.getMaterialIndex(material_asset_id)) |mat_idx| {
                    material_index = @intCast(mat_idx);
                }
            }

            for (model.meshes.items) |model_mesh| {
                raster_objects[mesh_idx] = .{
                    .transform = renderable.world_matrix.data,
                    .mesh_handle = .{ .mesh_ptr = model_mesh.geometry.mesh },
                    .material_index = material_index,
                    .visible = true,
                };

                geometries[mesh_idx] = .{
                    .mesh_ptr = model_mesh.geometry.mesh,
                    .blas = null,
                    .model_asset = renderable.model_asset,
                };

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

        // Store caches
        self.cached_raster_data = RasterizationData{
            .objects = raster_objects,
        };
        self.cached_raytracing_data = RaytracingData{
            .instances = instances,
            .geometries = geometries,
            .materials = materials,
        };
    }

    /// Context for parallel cache building
    const CacheBuildContext = struct {
        system: *RenderSystem,
        asset_manager: *AssetManager,
        renderables: []const RenderableEntity,
        raster_objects: []RasterizationData.RenderableObject,
        geometries: []RaytracingData.RTGeometry,
        instances: []RaytracingData.RTInstance,
        start_idx: usize,
        end_idx: usize,
        output_offset: usize, // Where to write in output arrays
        completion: *std.atomic.Value(usize),
    };

    /// Worker function for parallel cache building
    fn cacheBuilderWorker(context: *anyopaque, work_item: WorkItem) void {
        const ctx = @as(*CacheBuildContext, @ptrCast(@alignCast(context)));
        _ = work_item;

        var mesh_offset: usize = 0;

        // Process this chunk of renderables
        for (ctx.renderables[ctx.start_idx..ctx.end_idx]) |renderable| {
            const model = ctx.asset_manager.getModel(renderable.model_asset) orelse continue;

            var material_index: u32 = 0;
            if (renderable.material_asset) |material_asset_id| {
                if (ctx.asset_manager.getMaterialIndex(material_asset_id)) |mat_idx| {
                    material_index = @intCast(mat_idx);
                }
            }

            for (model.meshes.items) |model_mesh| {
                const output_idx = ctx.output_offset + mesh_offset;

                ctx.raster_objects[output_idx] = .{
                    .transform = renderable.world_matrix.data,
                    .mesh_handle = .{ .mesh_ptr = model_mesh.geometry.mesh },
                    .material_index = material_index,
                    .visible = true,
                };

                ctx.geometries[output_idx] = .{
                    .mesh_ptr = model_mesh.geometry.mesh,
                    .blas = null,
                    .model_asset = renderable.model_asset,
                };

                ctx.instances[output_idx] = .{
                    .transform = renderable.world_matrix.to_3x4(),
                    .instance_id = @intCast(output_idx),
                    .mask = 0xFF,
                    .geometry_index = @intCast(output_idx),
                    .material_index = material_index,
                };

                mesh_offset += 1;
            }
        }

        // Signal completion
        _ = ctx.completion.fetchSub(1, .release);
    }

    /// Parallel cache building
    fn buildCachesParallel(
        self: *RenderSystem,
        renderables: []const RenderableEntity,
        asset_manager: *AssetManager,
    ) !void {
        const pool = self.thread_pool.?;

        // First pass: count meshes per renderable to calculate offsets
        var mesh_counts = try self.allocator.alloc(usize, renderables.len);
        defer self.allocator.free(mesh_counts);

        var total_meshes: usize = 0;
        for (renderables, 0..) |renderable, i| {
            const model = asset_manager.getModel(renderable.model_asset) orelse {
                mesh_counts[i] = 0;
                continue;
            };
            mesh_counts[i] = model.meshes.items.len;
            total_meshes += model.meshes.items.len;
        }

        // Allocate output arrays
        const raster_objects = try self.allocator.alloc(RasterizationData.RenderableObject, total_meshes);
        errdefer self.allocator.free(raster_objects);

        const geometries = try self.allocator.alloc(RaytracingData.RTGeometry, total_meshes);
        errdefer self.allocator.free(geometries);

        const instances = try self.allocator.alloc(RaytracingData.RTInstance, total_meshes);
        errdefer self.allocator.free(instances);

        const materials = try self.allocator.alloc(RasterizationData.MaterialData, 0);
        errdefer self.allocator.free(materials);

        // Split work into chunks
        const worker_count: usize = 4;
        const chunk_size = (renderables.len + worker_count - 1) / worker_count;

        var completion = std.atomic.Value(usize).init(worker_count);
        var contexts = try self.allocator.alloc(CacheBuildContext, worker_count);
        defer self.allocator.free(contexts);

        log(.DEBUG, "render_system", "Parallel cache build: {} renderables, {} workers", .{ renderables.len, worker_count });

        // Calculate output offsets for each chunk
        var current_offset: usize = 0;
        for (0..worker_count) |i| {
            const start_idx = i * chunk_size;
            if (start_idx >= renderables.len) break;
            const end_idx = @min(start_idx + chunk_size, renderables.len);

            // Calculate offset for this chunk
            const chunk_offset = current_offset;
            for (mesh_counts[start_idx..end_idx]) |count| {
                current_offset += count;
            }

            contexts[i] = CacheBuildContext{
                .system = self,
                .asset_manager = asset_manager,
                .renderables = renderables,
                .raster_objects = raster_objects,
                .geometries = geometries,
                .instances = instances,
                .start_idx = start_idx,
                .end_idx = end_idx,
                .output_offset = chunk_offset,
                .completion = &completion,
            };

            try pool.submitWork(.{
                .id = i,
                .item_type = .render_extraction,
                .priority = .high,
                .data = .{ .render_extraction = .{
                    .chunk_index = @intCast(i),
                    .total_chunks = @intCast(worker_count),
                    .user_data = &contexts[i],
                } },
                .worker_fn = cacheBuilderWorker,
                .context = &contexts[i],
            });
        }

        // Wait for completion
        while (completion.load(.acquire) > 0) {
            std.Thread.yield() catch {};
        }

        // Store caches
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

    var system = try RenderSystem.init(std.testing.allocator, null);
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

    var system = try RenderSystem.init(std.testing.allocator, null);
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

    var system = try RenderSystem.init(std.testing.allocator, null);
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

    var system = try RenderSystem.init(std.testing.allocator, null);
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

    var system = try RenderSystem.init(std.testing.allocator, null);
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
