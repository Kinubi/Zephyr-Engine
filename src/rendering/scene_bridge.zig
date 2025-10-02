const std = @import("std");
const vk = @import("vulkan");
const Scene = @import("../scene/scene.zig").Scene;
const GameObject = @import("../scene/game_object.zig").GameObject;
const SceneView = @import("render_pass.zig").SceneView;
const RasterizationData = @import("scene_view.zig").RasterizationData;
const RaytracingData = @import("scene_view.zig").RaytracingData;
const ComputeData = @import("scene_view.zig").ComputeData;
const Mesh = @import("mesh.zig").Mesh;
const Math = @import("../utils/math.zig");
const log = @import("../utils/log.zig").log;

/// Bridge between existing Scene and new SceneView system
pub const SceneBridge = struct {
    scene: *Scene,
    rasterization_cache: ?RasterizationData = null,
    raytracing_cache: ?RaytracingData = null,
    compute_cache: ?ComputeData = null,
    allocator: std.mem.Allocator,
    cache_dirty: bool = true,

    // BVH change tracking for efficient raytracing updates
    last_object_count: usize = 0,
    last_geometry_count: usize = 0,
    last_model_asset_ids: std.ArrayList(u64), // Track model asset IDs to detect changes
    bvh_needs_rebuild: bool = true, // Start with needing rebuild

    const Self = @This();

    /// Initialize scene bridge
    pub fn init(scene: *Scene, allocator: std.mem.Allocator) Self {
        return Self{
            .scene = scene,
            .allocator = allocator,
            .last_model_asset_ids = std.ArrayList(u64){},
        };
    }

    /// Create SceneView that bridges to existing Scene
    pub fn createSceneView(self: *Self) SceneView {
        const vtable = &SceneViewVTable{
            .getRasterizationData = getRasterizationDataImpl,
            .getRaytracingData = getRaytracingDataImpl,
            .getComputeData = getComputeDataImpl,
        };

        return SceneView{
            .scene_ptr = self,
            .vtable = vtable,
        };
    }

    /// Mark scene data as dirty (call when objects/assets change)
    pub fn invalidateCache(self: *Self) void {
        self.cache_dirty = true;
        self.rasterization_cache = null;
        self.compute_cache = null;
    }

    /// Mark only geometry as dirty (for BVH rebuilding) - textures/materials don't need BVH rebuild
    pub fn invalidateGeometry(self: *Self) void {
        self.bvh_needs_rebuild = true;
        // Only invalidate raytracing cache since geometry changed
        self.raytracing_cache = null;
    }

    /// Check if BVH needs rebuilding based on geometry changes (not texture/material changes)
    pub fn checkBvhRebuildNeeded(self: *Self, _: bool) bool {
        const current_object_count = self.scene.objects.items.len;

        // Collect current model asset IDs and count geometry
        var current_geometry_count: usize = 0;
        var current_model_asset_ids = std.ArrayList(u64){};
        defer current_model_asset_ids.deinit(self.allocator);

        for (self.scene.objects.items) |*obj| {
            if (!obj.has_model) continue;
            if (obj.model_asset) |model_asset_id| {
                const safe_asset_id = self.scene.asset_manager.getAssetIdForRendering(model_asset_id);
                // Track the safe asset ID (what's actually used for rendering)
                current_model_asset_ids.append(self.allocator, safe_asset_id.toU64()) catch continue;

                if (self.scene.asset_manager.getLoadedModelConst(safe_asset_id)) |model| {
                    current_geometry_count += model.meshes.items.len;
                }
            }
        }

        // Check if model asset IDs changed (async loads completed, hot reloads, etc.)
        // Check this when object/geometry counts are the same, OR when we have more assets than before
        var asset_ids_changed = false;
        if (current_model_asset_ids.items.len == self.last_model_asset_ids.items.len and
            current_object_count == self.last_object_count and
            current_geometry_count == self.last_geometry_count)
        {
            // Check per-object asset ID changes if counts are all the same
            for (current_model_asset_ids.items, 0..) |current_id, i| {
                if (current_id != self.last_model_asset_ids.items[i]) {
                    asset_ids_changed = true;
                    log(.DEBUG, "scene_bridge", "Model asset ID changed at index {}: {d} -> {d}", .{ i, self.last_model_asset_ids.items[i], current_id });
                    break;
                }
            }
        } else if (current_model_asset_ids.items.len > self.last_model_asset_ids.items.len and
            current_object_count == self.last_object_count and
            current_geometry_count == self.last_geometry_count)
        {
            // New objects added but same geometry count - check if existing objects' assets changed
            // This catches the case where new objects are added with async assets, then those assets finish loading
            for (0..self.last_model_asset_ids.items.len) |i| {
                if (current_model_asset_ids.items[i] != self.last_model_asset_ids.items[i]) {
                    asset_ids_changed = true;
                    break;
                }
            }
        }

        // BVH rebuild is needed if:
        // 1. Forced rebuild flag is set
        // 2. Object count changed (new objects added/removed)
        // 3. Geometry count changed (new models loaded)
        // 4. Model asset IDs changed (async loads completed, hot reloads)
        const needs_rebuild = self.bvh_needs_rebuild or
            (current_object_count != self.last_object_count) or
            (current_geometry_count != self.last_geometry_count) or
            asset_ids_changed;

        if (needs_rebuild) {
            log(.DEBUG, "scene_bridge", "🔄 BVH rebuild: forced={}, obj_count_changed={}->{}, geo_count_changed={}->{}, asset_ids_changed={}, current_ids={any}, last_ids={any}", .{ self.bvh_needs_rebuild, self.last_object_count, current_object_count, self.last_geometry_count, current_geometry_count, asset_ids_changed, current_model_asset_ids.items, self.last_model_asset_ids.items });

            // Only invalidate cache if it hasn't already been rebuilt this frame
            if (self.raytracing_cache != null) {
                log(.DEBUG, "scene_bridge", "Invalidating existing raytracing cache due to BVH changes", .{});
                self.invalidateGeometry();
            } else {
                log(.DEBUG, "scene_bridge", "Cache already null, no need to invalidate", .{});
            }
        }

        // Always update tracking state to prevent infinite loops
        self.last_object_count = current_object_count;
        self.last_geometry_count = current_geometry_count;

        // Update asset ID tracking
        self.last_model_asset_ids.clearRetainingCapacity();
        if (self.last_model_asset_ids.ensureTotalCapacity(self.allocator, current_model_asset_ids.items.len)) |_| {
            self.last_model_asset_ids.appendSliceAssumeCapacity(current_model_asset_ids.items);
        } else |err| {
            log(.WARN, "scene_bridge", "Failed to update model asset ID tracking: {}", .{err});
        }

        self.bvh_needs_rebuild = false; // Clear force flag

        return needs_rebuild;
    }

    /// Get rasterization data from scene
    fn getRasterizationData(self: *Self) RasterizationData {
        self.buildRasterizationCache() catch |err| {
            log(.ERROR, "scene_bridge", "Failed to build rasterization cache: {}", .{err});
            return RasterizationData{
                .objects = &[_]RasterizationData.RenderableObject{},
            };
        };
        return self.rasterization_cache.?;
    }

    /// Get raytracing data from scene - with BVH change tracking integration
    fn getRaytracingData(self: *Self) RaytracingData {
        // Only rebuild raytracing cache if geometry actually changed, not just textures/materials
        if (self.raytracing_cache == null) {
            log(.DEBUG, "scene_bridge", "Raytracing cache is null, rebuilding", .{});
            self.buildRaytracingCache() catch |err| {
                log(.ERROR, "scene_bridge", "Failed to build raytracing cache: {}", .{err});
                return RaytracingData{
                    .instances = &[_]RaytracingData.RTInstance{},
                    .geometries = &[_]RaytracingData.RTGeometry{},
                    .materials = &[_]RasterizationData.MaterialData{},
                    .change_tracker = .{}, // Initialize change tracker
                };
            };
        }
        // Return cached data
        return self.raytracing_cache.?;
    }

    /// Get compute data from scene
    fn getComputeData(self: *Self) ComputeData {
        if (self.compute_cache == null or self.cache_dirty) {
            self.buildComputeCache() catch |err| {
                log(.ERROR, "scene_bridge", "Failed to build compute cache: {}", .{err});
                return ComputeData{
                    .particle_systems = &[_]ComputeData.ParticleSystem{},
                    .compute_tasks = &[_]ComputeData.ComputeTask{},
                };
            };
        }
        return self.compute_cache.?;
    }

    /// Build rasterization cache from scene objects
    fn buildRasterizationCache(self: *Self) !void {
        var objects = std.ArrayList(RasterizationData.RenderableObject){};
        defer objects.deinit(self.allocator);

        for (self.scene.objects.items, 0..) |*obj, obj_idx| {
            if (!obj.has_model) continue;
            var model_opt: ?*const @import("mesh.zig").Model = null;

            // Asset-based approach: prioritize asset IDs (same as scene system)
            if (obj.model_asset) |model_asset_id| {
                // Get asset ID with fallback and then get the loaded model
                const safe_asset_id = self.scene.asset_manager.getAssetIdForRendering(model_asset_id);
                if (self.scene.asset_manager.getLoadedModelConst(safe_asset_id)) |loaded_model| {
                    model_opt = loaded_model;
                }
            }

            if (model_opt) |model| {
                // Convert each mesh in the model to a renderable object
                for (model.meshes.items) |*mesh| {
                    // Skip meshes without valid buffers
                    if (mesh.geometry.mesh.vertex_buffer == null or mesh.geometry.mesh.index_buffer == null) {
                        log(.WARN, "scene_bridge", "Object {}: Skipping render - missing vertex/index buffers", .{obj_idx});
                        continue;
                    }

                    var material_index: u32 = 0;
                    // Get material index from AssetManager
                    if (obj.material_asset) |material_asset_id| {
                        if (self.scene.asset_manager.getMaterialIndex(material_asset_id)) |mat_idx| {
                            material_index = @intCast(mat_idx);
                        }
                    }

                    const renderable = RasterizationData.RenderableObject{
                        .transform = obj.transform.local2world.data,
                        .mesh_handle = RasterizationData.RenderableObject.MeshHandle{
                            .mesh_ptr = mesh.geometry.mesh,
                        },
                        .material_index = material_index,
                        .visible = true,
                    };
                    try objects.append(self.allocator, renderable);
                }
            }
        }

        // Store cache (need to allocate persistent storage)
        const objects_slice = try self.allocator.dupe(RasterizationData.RenderableObject, objects.items);

        self.rasterization_cache = RasterizationData{
            .objects = objects_slice,
        };
    }

    /// Build raytracing cache from scene objects
    fn buildRaytracingCache(self: *Self) !void {
        var instances = std.ArrayList(RaytracingData.RTInstance){};
        defer instances.deinit(self.allocator);

        var geometries = std.ArrayList(RaytracingData.RTGeometry){};
        defer geometries.deinit(self.allocator);

        for (self.scene.objects.items, 0..) |*obj, obj_idx| {
            if (!obj.has_model) continue;
            var model_opt: ?*const @import("mesh.zig").Model = null;

            // Asset-based approach: prioritize asset IDs (same as rasterization system)
            if (obj.model_asset) |model_asset_id| {
                // Get asset ID with fallback and then get the loaded model
                const safe_asset_id = self.scene.asset_manager.getAssetIdForRendering(model_asset_id);
                if (self.scene.asset_manager.getLoadedModelConst(safe_asset_id)) |loaded_model| {
                    model_opt = loaded_model;
                } else {
                    log(.DEBUG, "scene_bridge", "Object {}: No loaded model found for safe_asset_id={}", .{ obj_idx, safe_asset_id });
                }
            }

            if (model_opt) |model| {
                for (model.meshes.items, 0..) |*mesh, mesh_idx| {
                    // Skip meshes without valid buffers
                    if (mesh.geometry.mesh.vertex_buffer == null or mesh.geometry.mesh.index_buffer == null) {
                        log(.WARN, "scene_bridge", "Object {}, Mesh {}: Skipping raytracing - missing vertex/index buffers", .{ obj_idx, mesh_idx });
                        continue;
                    }

                    var material_index: u32 = 0;
                    // Get material index from AssetManager
                    if (obj.material_asset) |material_asset_id| {
                        if (self.scene.asset_manager.getMaterialIndex(material_asset_id)) |mat_idx| {
                            material_index = @intCast(mat_idx);
                        }
                    }

                    const instance = RaytracingData.RTInstance{
                        .transform = obj.transform.local2world.to_3x4(),
                        .instance_id = @intCast(instances.items.len),
                        .mask = 0xFF,
                        .geometry_index = @intCast(geometries.items.len + mesh_idx),
                        .material_index = material_index,
                    };
                    try instances.append(self.allocator, instance);

                    // Create RT geometry - store mesh pointer like RenderableObject does
                    const geometry = RaytracingData.RTGeometry{
                        .mesh_ptr = mesh.geometry.mesh,
                        .blas = null, // Will be built by raytracing pass
                    };

                    try geometries.append(self.allocator, geometry);
                }
            }
        }

        // Store caches
        const instances_slice = try self.allocator.dupe(RaytracingData.RTInstance, instances.items);
        const geometries_slice = try self.allocator.dupe(RaytracingData.RTGeometry, geometries.items);

        self.raytracing_cache = RaytracingData{
            .instances = instances_slice,
            .geometries = geometries_slice,
            .materials = &[_]RasterizationData.MaterialData{}, // TODO: Extract materials
            .change_tracker = RaytracingData.BvhChangeTracker{
                .last_object_count = instances_slice.len,
                .last_geometry_count = geometries_slice.len,
                .last_instance_count = instances_slice.len,
                .resources_updated = false,
                .force_rebuild = false,
            },
        };
        self.cache_dirty = false; // Clear dirty flag after rebuilding
    }

    /// Build compute cache from scene objects
    fn buildComputeCache(self: *Self) !void {
        // For now, return empty compute data
        // TODO: Extract particle systems and compute tasks from scene
        self.compute_cache = ComputeData{
            .particle_systems = &[_]ComputeData.ParticleSystem{},
            .compute_tasks = &[_]ComputeData.ComputeTask{},
        };
    }

    /// Free cached data
    pub fn deinit(self: *Self) void {
        if (self.rasterization_cache) |cache| {
            self.allocator.free(cache.objects);
        }
        if (self.raytracing_cache) |cache| {
            self.allocator.free(cache.instances);
            self.allocator.free(cache.geometries);
        }
        // compute_cache uses static slices, no cleanup needed
        self.last_model_asset_ids.deinit(self.allocator);
    }

    // VTable implementations
    const SceneViewVTable = SceneView.SceneViewVTable;

    fn getRasterizationDataImpl(scene_ptr: *anyopaque) RasterizationData {
        const self: *Self = @ptrCast(@alignCast(scene_ptr));
        return self.getRasterizationData();
    }

    fn getRaytracingDataImpl(scene_ptr: *anyopaque) RaytracingData {
        const self: *Self = @ptrCast(@alignCast(scene_ptr));
        return self.getRaytracingData();
    }

    fn getComputeDataImpl(scene_ptr: *anyopaque) ComputeData {
        const self: *Self = @ptrCast(@alignCast(scene_ptr));
        return self.getComputeData();
    }
};
