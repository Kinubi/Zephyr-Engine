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
const AssetTypeId = @import("../../assets/asset_types.zig").AssetId;
const Mesh = @import("../../rendering/mesh.zig").Mesh;
const ThreadPool = @import("../../threading/thread_pool.zig").ThreadPool;
const WorkItem = @import("../../threading/thread_pool.zig").WorkItem;
const log = @import("../../utils/log.zig").log;
const Scene = @import("../../scene/scene.zig").Scene;
const ecs = @import("../world.zig");
const BufferManager = @import("../../rendering/buffer_manager.zig").BufferManager;
const BufferConfig = @import("../../rendering/buffer_manager.zig").BufferConfig;
const ManagedBuffer = @import("../../rendering/buffer_manager.zig").ManagedBuffer;
const components = @import("../../ecs.zig"); // Import to access MaterialSet component
const GameStateSnapshot = @import("../../threading/game_state_snapshot.zig").GameStateSnapshot;
const FrameInfo = @import("../../rendering/frameinfo.zig").FrameInfo;

/// RenderSystem extracts rendering data from ECS entities
/// Queries entities with Transform + MeshRenderer and prepares data for rendering
pub const RenderSystem = struct {
    allocator: std.mem.Allocator,
    thread_pool: ?*ThreadPool,
    buffer_manager: ?*BufferManager, // For creating instance buffer

    // Change tracking
    last_renderable_count: usize = 0,
    last_geometry_count: usize = 0,

    // Descriptor update flags
    raster_descriptors_dirty: bool = true,
    raytracing_descriptors_dirty: bool = true,

    // Transform-only change flag (set by update(), read by raytracing system)
    transform_only_change: bool = false,

    // Cache generation tracking for instanced rendering
    cache_generation: u32 = 0,

    // Double-buffered cached render data (lock-free main/render thread access)
    // Main thread writes to inactive buffer, render thread reads from active buffer
    cached_raster_data: [2]?RasterizationData = .{ null, null },
    cached_raytracing_data: [2]?RaytracingData = .{ null, null },
    active_cache_index: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),

    // Instance data SSBO for instanced rendering
    // RenderSystem owns and uploads this buffer (parallel to MaterialSystem owning material_buffer)
    // Always valid - starts as dummy buffer, gets replaced with real data
    instance_buffer: *ManagedBuffer,

    pub fn init(allocator: std.mem.Allocator, thread_pool: ?*ThreadPool, buffer_manager: *BufferManager) !RenderSystem {
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

        // Create empty dummy instance buffer so descriptor binding is always valid
        // BufferManager should always be provided
        const bm = buffer_manager;

        const dummy_instance = render_data_types.RasterizationData.InstanceData{
            .transform = [_]f32{1} ** 16, // Identity matrix
            .material_index = 0,
        };

        const dummy_buffer = try bm.createBuffer(
            BufferConfig{
                .name = "instance_data_buffer_dummy",
                .size = @sizeOf(render_data_types.RasterizationData.InstanceData),
                .strategy = .device_local,
                .usage = .{ .storage_buffer_bit = true, .transfer_dst_bit = true },
            },
            0, // frame_index
        );

        // Upload dummy data
        const bytes: []const u8 = std.mem.asBytes(&dummy_instance);
        try bm.updateBuffer(dummy_buffer, bytes, 0);

        return .{
            .allocator = allocator,
            .thread_pool = thread_pool,
            .buffer_manager = buffer_manager,
            .instance_buffer = dummy_buffer,
        };
    }

    pub fn deinit(self: *RenderSystem) void {
        // Clean up instance buffer
        if (self.buffer_manager) |bm| {
            bm.destroyBuffer(self.instance_buffer) catch |err| {
                log(.ERROR, "render_system", "Failed to destroy instance buffer: {}", .{err});
            };
        }

        // Clean up both cache buffers
        for (&self.cached_raster_data) |*data| {
            if (data.*) |cache| {
                self.allocator.free(cache.objects);
                // Clean up instanced batches
                for (cache.batches) |batch| {
                    self.allocator.free(batch.instances);
                }
                self.allocator.free(cache.batches);
            }
        }
        for (&self.cached_raytracing_data) |*data| {
            if (data.*) |cache| {
                self.allocator.free(cache.instances);
                self.allocator.free(cache.geometries);
                self.allocator.free(cache.materials);
            }
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
        model_asset: AssetTypeId,
        material_buffer_index: ?u32, // Index into MaterialSystem's per-set material buffer
        texture_asset: ?AssetTypeId,
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

            // Get material buffer index from MaterialSet component
            const material_set = world.get(components.MaterialSet, entry.entity);
            const material_buffer_index = if (material_set) |ms| ms.material_buffer_index else null;

            // Create renderable entry
            try renderables.append(self.allocator, RenderableEntity{
                .model_asset = renderer.model_asset.?,
                .material_buffer_index = material_buffer_index,
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
        // Per-worker results buffer (allocated by parent) to avoid locking
        results: *std.ArrayList(RenderableEntity),
        completion: *std.atomic.Value(usize),
    };

    /// Worker function for parallel extraction
    fn extractionWorker(context: *anyopaque, work_item: WorkItem) void {
        const ctx = @as(*ExtractionWorkContext, @ptrCast(@alignCast(context)));
        _ = work_item;

        // Extract renderables for this chunk into the per-worker results buffer
        const out = ctx.results; // preallocated per-worker buffer

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

            // Get material buffer index from MaterialSet component
            const material_set = ctx.world.get(components.MaterialSet, entity);
            const material_buffer_index = if (material_set) |ms| ms.material_buffer_index else null;

            // Create renderable entry directly into worker-local buffer
            out.append(ctx.system.allocator, RenderableEntity{
                .model_asset = renderer.model_asset.?,
                .material_buffer_index = material_buffer_index,
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

        // Create atomic completion counter and per-worker result buffers
        var completion = std.atomic.Value(usize).init(worker_count);

        // Allocate per-worker result buffers (worker-local ArrayList) to avoid locking
        var worker_results = try self.allocator.alloc(std.ArrayList(RenderableEntity), worker_count);
        defer self.allocator.free(worker_results);

        // Initialize each worker's local results list
        for (0..worker_count) |wi| {
            worker_results[wi] = std.ArrayList(RenderableEntity){};
        }

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
                // Give each worker its own results buffer
                .results = &worker_results[i],
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

        // Merge per-worker results serially into the shared renderables list
        for (0..submitted_count) |i| {
            const wr = &worker_results[i];
            for (wr.items) |item| {
                renderables.append(self.allocator, item) catch |err| {
                    std.log.err("Failed to merge worker results (post): {}", .{err});
                    // continue merging remaining items
                };
            }
            // Deinit worker-local list (free its backing memory)
            wr.deinit(self.allocator);
        }
    }

    // ============================================================================
    // SNAPSHOT-BASED FUNCTIONS (Phase 2.1 - Render Thread Support)
    // ============================================================================

    /// Rebuild caches from a GameStateSnapshot instead of World
    /// This is called by the render thread with an immutable snapshot
    /// Writes to INACTIVE buffer, then atomically flips to make it active
    pub fn rebuildCachesFromSnapshot(
        self: *RenderSystem,
        snapshot: *const GameStateSnapshot,
        asset_manager: *AssetManager,
    ) !void {
        const start_time = std.time.nanoTimestamp();

        // Determine which buffer to write to (inactive = opposite of active)
        const active_idx = self.active_cache_index.load(.acquire);
        const write_idx = 1 - active_idx;

        // Clean up old cached data in the WRITE buffer (safe - render thread reads ACTIVE buffer)
        if (self.cached_raster_data[write_idx]) |data| {
            self.allocator.free(data.objects);
            // Clean up instanced batches
            for (data.batches) |batch| {
                self.allocator.free(batch.instances);
            }
            self.allocator.free(data.batches);
        }
        if (self.cached_raytracing_data[write_idx]) |*data| {
            self.allocator.free(data.instances);
            self.allocator.free(data.geometries);
            self.allocator.free(data.materials);
        }

        const cache_build_start = std.time.nanoTimestamp();

        // Build caches from snapshot entities
        const entities = snapshot.entities[0..snapshot.entity_count];

        // Use parallel cache building if thread_pool available and enough work
        if (self.thread_pool != null and entities.len >= 50) {
            try self.buildCachesFromSnapshotParallel(entities, asset_manager, write_idx);
        } else {
            try self.buildCachesFromSnapshotSingleThreaded(entities, asset_manager, write_idx);
        }

        const cache_build_time_ns = std.time.nanoTimestamp() - cache_build_start;
        const cache_build_time_ms = @as(f64, @floatFromInt(cache_build_time_ns)) / 1_000_000.0;

        const total_time_ns = std.time.nanoTimestamp() - start_time;
        const total_time_ms = @as(f64, @floatFromInt(total_time_ns)) / 1_000_000.0;

        // Frame budget enforcement
        const budget_ms: f64 = 2.0;
        if (total_time_ms > budget_ms) {
            log(.WARN, "render_system", "Frame budget exceeded in snapshot rebuild! Total: {d:.2}ms (cache: {d:.2}ms) Budget: {d:.2}ms", .{ total_time_ms, cache_build_time_ms, budget_ms });
        }

        // Upload instance data to GPU if we have batches
        try self.uploadInstanceDataToGPU();
    }

    /// Upload instance data from batches to GPU buffer
    /// Called after cache rebuild when batches are updated
    fn uploadInstanceDataToGPU(self: *RenderSystem) !void {
        const buffer_manager = self.buffer_manager orelse return;

        // Get active cache with batches
        const active_idx = self.active_cache_index.load(.acquire);
        const raster_data = self.cached_raster_data[active_idx] orelse return;

        if (raster_data.batches.len == 0) return;

        // Count total instances across all batches
        var total_instances: usize = 0;
        for (raster_data.batches) |batch| {
            total_instances += batch.instances.len;
        }

        if (total_instances == 0) return;

        // Calculate buffer size
        const buffer_size = total_instances * @sizeOf(render_data_types.RasterizationData.InstanceData);

        // Create or resize buffer if needed (dummy buffer has size of 1 instance)
        const needs_realloc = self.instance_buffer.size < buffer_size;

        if (needs_realloc) {
            // Create new buffer FIRST (before destroying old one)
            const new_buffer = try buffer_manager.createBuffer(
                BufferConfig{
                    .name = "instance_data_buffer",
                    .size = buffer_size,
                    .strategy = .device_local,
                    .usage = .{ .storage_buffer_bit = true, .transfer_dst_bit = true },
                },
                0, // frame_index
            );

            // Destroy old buffer AFTER new one is created
            try buffer_manager.destroyBuffer(self.instance_buffer);

            // Set the new buffer
            self.instance_buffer = new_buffer;

            log(.INFO, "render_system", "Created instance buffer for {} instances ({} bytes)", .{ total_instances, buffer_size });
        }

        // Upload instance data from all batches
        var upload_buffer = std.ArrayList(u8){};
        defer upload_buffer.deinit(self.allocator);

        try upload_buffer.ensureTotalCapacity(self.allocator, buffer_size);

        for (raster_data.batches) |batch| {
            const batch_bytes = std.mem.sliceAsBytes(batch.instances);
            try upload_buffer.appendSlice(self.allocator, batch_bytes);
        }

        try buffer_manager.updateBuffer(self.instance_buffer, upload_buffer.items, 0);
    }

    /// Build caches from snapshot entities (single-threaded)
    /// Builds caches in the WRITE buffer at write_idx
    ///
    /// TODO(MAINTENANCE): IMPLEMENT MESH DEDUPLICATION FOR INSTANCING - HIGH PRIORITY
    /// Currently creates one cache entry per mesh instance (no deduplication).
    ///
    /// Problem: 1000 identical trees = 1000 separate RasterizationData.RenderableObject entries
    /// Solution: Group identical meshes, store instance data separately
    ///
    /// Required changes:
    /// 1. Use HashMap to track unique mesh_ptr values
    /// 2. For each unique mesh, build instance buffer (transforms + material_indices)
    /// 3. Store in cache as: { mesh_ptr, instance_count, instance_buffer_offset }
    /// 4. GeometryPass uses this to make single instanced draw call per unique mesh
    ///
    /// Data structure change:
    /// Old: RenderableObject { transform, mesh_ptr, material_index } x 1000
    /// New: InstancedRenderBatch { mesh_ptr, instance_count, instance_data_buffer } x 1
    ///      where instance_data_buffer = [InstanceData { transform, material_index }] x 1000
    ///
    /// Complexity: HIGH - requires cache structure refactor + shader changes
    /// Branch recommended: features/instanced-rendering (coordinate with geometry_pass.zig changes)
    /// Helper struct for building instanced batches
    const BatchBuilder = struct {
        // Map mesh_ptr → list of instance indices
        mesh_to_instances: std.AutoHashMap(usize, std.ArrayList(usize)),
        allocator: std.mem.Allocator,

        fn init(allocator: std.mem.Allocator) BatchBuilder {
            return .{
                .mesh_to_instances = std.AutoHashMap(usize, std.ArrayList(usize)).init(allocator),
                .allocator = allocator,
            };
        }

        fn deinit(self: *BatchBuilder) void {
            var iter = self.mesh_to_instances.valueIterator();
            while (iter.next()) |list| {
                list.deinit(self.allocator);
            }
            self.mesh_to_instances.deinit();
        }

        /// Add an object to the batch builder
        fn addObject(self: *BatchBuilder, mesh_ptr: *const Mesh, object_idx: usize) !void {
            const mesh_key = @intFromPtr(mesh_ptr);
            const result = try self.mesh_to_instances.getOrPut(mesh_key);
            if (!result.found_existing) {
                result.value_ptr.* = std.ArrayList(usize){};
            }
            try result.value_ptr.append(self.allocator, object_idx);
        }

        /// Build final InstancedBatch array from collected data
        fn buildBatches(
            self: *BatchBuilder,
            objects: []const RasterizationData.RenderableObject,
            allocator: std.mem.Allocator,
        ) ![]RasterizationData.InstancedBatch {
            const batch_count = self.mesh_to_instances.count();
            const batches = try allocator.alloc(RasterizationData.InstancedBatch, batch_count);

            var batch_idx: usize = 0;
            var iter = self.mesh_to_instances.iterator();
            while (iter.next()) |entry| {
                const indices = entry.value_ptr;
                const instances = try allocator.alloc(RasterizationData.InstanceData, indices.items.len);

                // Copy instance data from objects
                for (indices.items, 0..) |obj_idx, inst_idx| {
                    const obj = objects[obj_idx];
                    instances[inst_idx] = .{
                        .transform = obj.transform,
                        .material_index = obj.material_index,
                    };
                }

                // Get mesh_ptr from first object in batch
                const first_obj = objects[indices.items[0]];
                batches[batch_idx] = .{
                    .mesh_handle = .{ .mesh_ptr = first_obj.mesh_handle.mesh_ptr },
                    .instances = instances,
                    .visible = true,
                };
                batch_idx += 1;
            }

            return batches;
        }
    };

    fn buildCachesFromSnapshotSingleThreaded(
        self: *RenderSystem,
        entities: []const GameStateSnapshot.EntityRenderData,
        asset_manager: *AssetManager,
        write_idx: u8,
    ) !void {
        // Count total meshes
        var total_meshes: usize = 0;
        for (entities) |entity_data| {
            const model = asset_manager.getModel(entity_data.model_asset) orelse continue;
            total_meshes += model.meshes.items.len;
        }

        // Allocate output arrays (still needed for legacy per-object data and RT)
        const raster_objects = try self.allocator.alloc(RasterizationData.RenderableObject, total_meshes);
        errdefer self.allocator.free(raster_objects);

        const geometries = try self.allocator.alloc(RaytracingData.RTGeometry, total_meshes);
        errdefer self.allocator.free(geometries);

        const instances = try self.allocator.alloc(RaytracingData.RTInstance, total_meshes);
        errdefer self.allocator.free(instances);

        const materials = try self.allocator.alloc(RasterizationData.MaterialData, 0);
        errdefer self.allocator.free(materials);

        // NEW: Build instanced batches
        var batch_builder = BatchBuilder.init(self.allocator);
        defer batch_builder.deinit();

        var mesh_idx: usize = 0;
        for (entities) |entity_data| {
            const model = asset_manager.getModel(entity_data.model_asset) orelse continue;

            // Use material_buffer_index from MaterialSet component
            var material_index: u32 = 0;
            if (entity_data.material_buffer_index) |idx| {
                material_index = idx;
            }

            for (model.meshes.items) |model_mesh| {
                raster_objects[mesh_idx] = .{
                    .transform = entity_data.transform.data,
                    .mesh_handle = .{ .mesh_ptr = model_mesh.geometry.mesh },
                    .material_index = material_index,
                    .visible = true,
                };

                // Register this object with the batch builder
                try batch_builder.addObject(model_mesh.geometry.mesh, mesh_idx);

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

        // Build instanced batches from deduplicated data
        const batches = try batch_builder.buildBatches(raster_objects, self.allocator);

        // Increment cache generation to invalidate GPU buffers
        self.cache_generation +%= 1;

        // Store cached data in WRITE buffer
        self.cached_raster_data[write_idx] = .{
            .objects = raster_objects,
            .batches = batches, // NEW: Add instanced batches
        };

        self.cached_raytracing_data[write_idx] = .{
            .instances = instances,
            .geometries = geometries,
            .materials = materials,
        };

        // Atomically flip to make the new cache active
        self.active_cache_index.store(write_idx, .release);
    }

    /// Build caches from snapshot entities (parallel)
    fn buildCachesFromSnapshotParallel(
        self: *RenderSystem,
        entities: []const GameStateSnapshot.EntityRenderData,
        asset_manager: *AssetManager,
        write_idx: u8,
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

        // Build instanced batches from deduplicated data
        var batch_builder = BatchBuilder.init(self.allocator);
        defer batch_builder.deinit();

        for (raster_objects, 0..) |obj, idx| {
            try batch_builder.addObject(obj.mesh_handle.mesh_ptr, idx);
        }

        const batches = try batch_builder.buildBatches(raster_objects, self.allocator);

        // Increment cache generation to invalidate GPU buffers
        self.cache_generation +%= 1;

        // Store cached data in WRITE buffer
        self.cached_raster_data[write_idx] = .{
            .objects = raster_objects,
            .batches = batches, // NEW: Add instanced batches
        };

        self.cached_raytracing_data[write_idx] = .{
            .instances = instances,
            .geometries = geometries,
            .materials = materials,
        };

        // Atomically flip to make the new cache active
        self.active_cache_index.store(write_idx, .release);
    }

    /// Context for snapshot-based parallel cache building
    const SnapshotCacheBuildContext = struct {
        entities: []const GameStateSnapshot.EntityRenderData,
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

            // Get material_buffer_index from MaterialSet component instead of AssetManager
            var material_index: u32 = 0;
            if (entity_data.material_buffer_index) |idx| {
                material_index = idx;
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

    /// Single-threaded cache building
    /// Builds caches in the WRITE buffer at write_idx
    fn buildCachesSingleThreaded(self: *RenderSystem, renderables: []const RenderableEntity, asset_manager: *AssetManager, write_idx: u8) !void {
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

            // Use material_buffer_index from MaterialSet component
            var material_index: u32 = 0;
            if (renderable.material_buffer_index) |idx| {
                material_index = idx;
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

        // NEW: Build instanced batches from deduplicated data
        var batch_builder = BatchBuilder.init(self.allocator);
        defer batch_builder.deinit();

        const batches = try batch_builder.buildBatches(raster_objects, self.allocator);

        // Increment cache generation to invalidate GPU buffers
        self.cache_generation +%= 1;

        // Store caches in WRITE buffer
        self.cached_raster_data[write_idx] = RasterizationData{
            .objects = raster_objects,
            .batches = batches, // NEW: Add instanced batches
        };
        self.cached_raytracing_data[write_idx] = RaytracingData{
            .instances = instances,
            .geometries = geometries,
            .materials = materials,
        };

        // Atomically flip to make the new cache active (render thread will see it on next frame)
        self.active_cache_index.store(write_idx, .release);
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

            // Use material_buffer_index from MaterialSet component
            var material_index: u32 = 0;
            if (renderable.material_buffer_index) |idx| {
                material_index = idx;
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
        write_idx: u8,
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

        // NEW: Build instanced batches from deduplicated data
        var batch_builder = BatchBuilder.init(self.allocator);
        defer batch_builder.deinit();

        const batches = try batch_builder.buildBatches(raster_objects, self.allocator);

        // Increment cache generation to invalidate GPU buffers
        self.cache_generation +%= 1;

        // Store caches in WRITE buffer
        self.cached_raster_data[write_idx] = RasterizationData{
            .objects = raster_objects,
            .batches = batches, // NEW: Add instanced batches
        };
        self.cached_raytracing_data[write_idx] = RaytracingData{
            .instances = instances,
            .geometries = geometries,
            .materials = materials,
        };

        // Atomically flip to make the new cache active
        self.active_cache_index.store(write_idx, .release);
    }

    /// Get cached raster data from ACTIVE buffer (already built by checkForChanges on main thread)
    /// Returns a COPY of the cached data that the caller owns
    pub fn getRasterData(self: *RenderSystem) !RasterizationData {
        const active_idx = self.active_cache_index.load(.acquire);
        if (self.cached_raster_data[active_idx]) |cached| {
            const objects_copy = try self.allocator.alloc(RasterizationData.RenderableObject, cached.objects.len);
            for (cached.objects, 0..) |obj, i| {
                objects_copy[i] = obj;
            }

            const batches_copy = try self.allocator.alloc(RasterizationData.InstancedBatch, cached.batches.len);
            for (cached.batches, 0..) |batch, i| {
                batches_copy[i] = batch;
            }

            return RasterizationData{
                .objects = objects_copy,
                .batches = batches_copy,
            };
        }

        // If no cache exists, return empty data
        const empty_objects = try self.allocator.alloc(RasterizationData.RenderableObject, 0);
        const empty_batches = try self.allocator.alloc(RasterizationData.InstancedBatch, 0);
        return RasterizationData{
            .objects = empty_objects,
            .batches = empty_batches,
        };
    }

    /// Get cached raytracing data from ACTIVE buffer (already built by checkForChanges on main thread)
    /// Returns a COPY of the cached data that the caller owns
    pub fn getRaytracingData(self: *RenderSystem) !RaytracingData {
        const active_idx = self.active_cache_index.load(.acquire);
        if (self.cached_raytracing_data[active_idx]) |cached| {
            const instances_copy = try self.allocator.alloc(RaytracingData.RTInstance, cached.instances.len);
            for (cached.instances, 0..) |inst, i| {
                instances_copy[i] = inst;
            }

            const geometries_copy = try self.allocator.alloc(RaytracingData.RTGeometry, cached.geometries.len);
            for (cached.geometries, 0..) |geom, i| {
                geometries_copy[i] = geom;
            }

            const materials_copy = try self.allocator.alloc(RasterizationData.MaterialData, cached.materials.len);
            for (cached.materials, 0..) |mat, i| {
                materials_copy[i] = mat;
            }

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

/// MAIN THREAD: Prepare phase - change detection and dirty flag management
/// Runs RenderSystem change detection ONLY - does NOT build caches
/// Cache building happens on render thread via rebuildCachesFromSnapshot() (update phase)
/// MAIN THREAD: Prepare phase - query ECS and detect changes
/// This function is called on the main thread before captureSnapshot()
/// Extracts all renderable data and writes to RenderablesSet component (NO internal state)
pub fn prepare(world: *World, dt: f32) !void {
    _ = dt;

    const scene_ptr = world.getUserData("scene") orelse return;
    const scene: *Scene = @ptrCast(@alignCast(scene_ptr));

    var self: *RenderSystem = &scene.render_system;
    const asset_manager = scene.asset_manager;

    // Get or create the RenderablesSet singleton component
    const renderables_set_entity = try world.getOrCreateSingletonEntity();
    var renderables_set = world.get(components.RenderablesSet, renderables_set_entity) orelse blk: {
        const new_set = components.RenderablesSet.init();
        try world.emplace(components.RenderablesSet, renderables_set_entity, new_set);
        break :blk world.get(components.RenderablesSet, renderables_set_entity).?;
    };

    // FAST PATH: Check for changes BEFORE doing expensive extraction
    var changes_detected = false;
    var is_transform_only = false;
    var reason: []const u8 = "";

    // 1) Quick check: Cache missing (first frame) - NOT transform-only
    const active_idx = self.active_cache_index.load(.acquire);
    if (self.cached_raster_data[active_idx] == null) {
        changes_detected = true;
        is_transform_only = false;
        reason = "cache_missing";
    }

    // 2) Quick check: Entity count changed (cheap) - NOT transform-only
    if (!changes_detected) {
        const mesh_view = try world.view(MeshRenderer);
        const current_count = mesh_view.storage.entities.items.len;
        if (current_count != self.last_renderable_count) {
            changes_detected = true;
            is_transform_only = false;
            reason = "count_changed";
        }
    }

    // 3) EXPENSIVE check: Mesh pointers changed (iterate entities + asset lookups) - NOT transform-only
    // Check this BEFORE transforms so geometry changes take priority over transform-only changes
    if (!changes_detected) {
        const active_idx_check = self.active_cache_index.load(.acquire);
        if (self.cached_raster_data[active_idx_check]) |cached| {
            var mesh_view = try world.view(MeshRenderer);
            var iter = mesh_view.iterator();
            var mesh_idx: usize = 0;

            outer: while (iter.next()) |entry| {
                const renderer = entry.component;
                if (!renderer.enabled or !renderer.hasValidAssets()) continue;

                if (asset_manager.getModel(renderer.model_asset.?)) |model| {
                    for (model.meshes.items) |model_mesh| {
                        // Check if we've exceeded cached mesh count or mesh ptr changed
                        if (mesh_idx >= cached.objects.len or
                            cached.objects[mesh_idx].mesh_handle.mesh_ptr != model_mesh.geometry.mesh)
                        {
                            changes_detected = true;
                            is_transform_only = false;
                            reason = "mesh_ptr_changed";
                            break :outer;
                        }
                        mesh_idx += 1;
                    }
                }
            }

            // Also check if we have fewer meshes than before
            if (!changes_detected and mesh_idx != cached.objects.len) {
                changes_detected = true;
                is_transform_only = false;
                reason = "mesh_count_changed";
            }
        }
    }

    // 4) Medium check: Transform dirty flags (iterate entities, check flags) - IS transform-only
    // This runs LAST so it only triggers if no geometry changes were detected
    if (!changes_detected) {
        var mesh_view = try world.view(MeshRenderer);
        var iter = mesh_view.iterator();
        while (iter.next()) |entry| {
            if (world.get(Transform, entry.entity)) |transform| {
                if (transform.dirty) {
                    changes_detected = true;
                    is_transform_only = true;
                    reason = "transform_dirty";
                    break;
                }
            }
        }
    }

    // ONLY extract if changes detected - this is the expensive part!
    if (changes_detected) {
        // Clear transform dirty flags ONLY when we're about to extract
        // (No point clearing flags if we're not extracting)
        var mesh_view_clear = try world.view(MeshRenderer);
        var iter_clear = mesh_view_clear.iterator();
        while (iter_clear.next()) |entry_clear| {
            if (world.get(Transform, entry_clear.entity)) |transform| {
                transform.dirty = false;
            }
        }
        var extracted_renderables = std.ArrayList(components.ExtractedRenderable){};
        defer extracted_renderables.deinit(self.allocator);

        var mesh_view = try world.view(MeshRenderer);
        var iter = mesh_view.iterator();
        while (iter.next()) |entry| {
            const renderer = entry.component;

            if (!renderer.enabled) {
                continue;
            }
            if (!renderer.hasValidAssets()) {
                continue;
            }

            // Get transform (default to identity if missing)
            const transform = world.get(Transform, entry.entity);
            const world_matrix = if (transform) |t| t.world_matrix else math.Mat4x4.identity();

            // Get material buffer index from MaterialSet component
            const material_set = world.get(components.MaterialSet, entry.entity);
            const material_buffer_index = if (material_set) |ms| ms.material_buffer_index else null;

            try extracted_renderables.append(self.allocator, .{
                .entity_id = entry.entity,
                .transform = world_matrix,
                .model_asset = renderer.model_asset.?,
                .material_buffer_index = material_buffer_index,
                .texture_asset = renderer.texture_asset,
                .layer = renderer.layer,
                .casts_shadows = renderer.casts_shadows,
                .receives_shadows = renderer.receives_shadows,
            });
        }

        // Count geometries for tracking
        const current_renderable_count = extracted_renderables.items.len;
        var current_geometry_count: usize = 0;
        for (extracted_renderables.items) |renderable| {
            if (asset_manager.getModel(renderable.model_asset)) |model| {
                current_geometry_count += model.meshes.items.len;
            }
        }

        // Update tracking state
        self.last_renderable_count = current_renderable_count;
        self.last_geometry_count = current_geometry_count;

        // Store extracted renderables in RenderablesSet component
        const renderables_copy = try self.allocator.dupe(components.ExtractedRenderable, extracted_renderables.items);
        renderables_set.setRenderables(self.allocator, renderables_copy);

        renderables_set.markDirty(is_transform_only);
    }
}

/// RENDER THREAD: Update phase - build GPU caches from snapshot
/// This function is called by the render thread with a snapshot
/// Reads change flags from snapshot and rebuilds GPU buffers if needed
pub fn update(world: *World, frame_info: *FrameInfo) !void {
    const scene_ptr = world.getUserData("scene") orelse return;
    const scene: *Scene = @ptrCast(@alignCast(scene_ptr));

    var self: *RenderSystem = &scene.render_system;
    const asset_manager = scene.asset_manager;

    // Snapshot may be null if render thread is not enabled
    const snapshot = frame_info.snapshot orelse return;

    // Read change flags from snapshot (set by prepare phase)
    if (snapshot.render_changes.renderables_dirty) {
        try self.rebuildCachesFromSnapshot(snapshot, asset_manager);

        // Update transform_only_change flag from snapshot for raytracing system to read
        self.transform_only_change = snapshot.render_changes.transform_only_change;
        const renderables_set_entity = try world.getOrCreateSingletonEntity();
        if (world.get(components.RenderablesSet, renderables_set_entity)) |renderables_set| {
            renderables_set.clearDirty();
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

test "RenderSystem: extract empty world" {
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
    var world = ecs.World.init(std.testing.allocator, null);
    defer world.deinit();

    try world.registerComponent(Camera);
    try world.registerComponent(Transform);
    try world.registerComponent(MeshRenderer);

    var system = try RenderSystem.init(std.testing.allocator, null);
    defer system.deinit();

    // Create camera entity
    const entity = try world.createEntity();

    var camera = Camera.initPerspective(90.0, 16.0 / 9.0, 0.1, 100.0);
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
