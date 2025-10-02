const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("../core/graphics_context.zig").GraphicsContext;
const Mesh = @import("../rendering/mesh.zig").Mesh;
const Model = @import("../rendering/mesh.zig").Model;
const Math = @import("../utils/math.zig");
const GameObject = @import("game_object.zig").GameObject;
const PointLightComponent = @import("components.zig").PointLightComponent;
const fromMesh = @import("../rendering/mesh.zig").fromMesh;
const Texture = @import("../core/texture.zig").Texture;
const FallbackMeshes = @import("../utils/fallback_meshes.zig").FallbackMeshes;
const Buffer = @import("../core/buffer.zig").Buffer;
const loadFileAlloc = @import("../utils/file.zig").loadFileAlloc;
const log = @import("../utils/log.zig").log;
const LogLevel = @import("../utils/log.zig").LogLevel;

// Asset management imports
const AssetManager = @import("../assets/asset_manager.zig").AssetManager;
const AssetId = @import("../assets/asset_manager.zig").AssetId;
const AssetType = @import("../assets/asset_manager.zig").AssetType;
const LoadPriority = @import("../assets/asset_manager.zig").LoadPriority;

/// Global mutex for texture loading to prevent zstbi init conflicts
var texture_loading_mutex = std.Thread.Mutex{};

/// Asset completion callback function type
pub const AssetCompletionCallback = *const fn (asset_id: AssetId, asset_type: AssetType, user_data: ?*anyopaque) void;

/// Enhanced Scene with Asset Manager integration (using existing AssetManager)
pub const Scene = struct {
    // Core scene data - only GameObjects with asset references
    objects: std.ArrayList(GameObject),
    next_object_id: u64,

    // Asset Manager integration - all assets handled here
    asset_manager: *AssetManager,

    // Raytracing system reference for descriptor updates
    raytracing_system: ?*@import("../systems/raytracing_system.zig").RaytracingSystem,

    // Scene bridge for SceneView integration with BVH change tracking
    scene_bridge: ?@import("../rendering/scene_bridge.zig").SceneBridge = null,

    // Core dependencies
    gc: *GraphicsContext,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Initialize the Scene
    pub fn init(gc: *GraphicsContext, allocator: std.mem.Allocator, asset_manager: *AssetManager) Self {
        return Self{
            .objects = std.ArrayList(GameObject){},
            .next_object_id = 1,
            .asset_manager = asset_manager,
            .raytracing_system = null,
            .gc = gc,
            .allocator = allocator,
        };
    }

    /// Deinitialize the Enhanced Scene
    pub fn deinit(self: *Self) void {
        log(.INFO, "enhanced_scene", "Deinitializing Enhanced Scene with {} objects", .{self.objects.items.len});

        // Deinit GameObjects
        for (self.objects.items) |object| {
            object.deinit();
        }
        self.objects.deinit(self.allocator);

        log(.INFO, "enhanced_scene", "Enhanced Scene deinit complete", .{});
    }

    /// Convert Enhanced Scene to Scene for compatibility with legacy renderers
    pub fn asScene(self: *Self) *Scene {
        return @ptrCast(self);
    }

    // === Legacy API Compatibility ===

    pub fn addEmpty(self: *Self) !*GameObject {
        const object_id = self.next_object_id;
        self.next_object_id += 1;
        try self.objects.append(self.allocator, .{ .id = object_id, .model = null, .point_light = null });
        return &self.objects.items[self.objects.items.len - 1];
    }

    pub fn addObject(self: *Self, model: ?*Model, point_light: ?PointLightComponent) !*GameObject {
        const object_id = self.next_object_id;
        self.next_object_id += 1;
        try self.objects.append(.{
            .id = object_id,
            .model = model,
            .point_light = point_light,
        });
        return &self.objects.items[self.objects.items.len - 1];
    }

    /// Add model with async asset loading (API compatible method signature)
    pub fn addModelAssetAsync(
        self: *Self,
        model_path: []const u8,
        texture_path: []const u8,
        position: Math.Vec3,
        rotation: Math.Vec3,
        scale: Math.Vec3,
    ) !*GameObject {
        _ = rotation; // TODO: Use rotation parameter in the future
        log(.DEBUG, "enhanced_scene", "addModelAssetAsync: registering assets model={s} texture={s}", .{ model_path, texture_path });

        // Calculate priority based on position (distance from origin)
        const distance = position.length();
        const priority = LoadPriority.fromDistance(distance);

        // Start async loads using enhanced asset manager with priority
        log(.INFO, "enhanced_scene", "Requesting async texture preload: {s}", .{texture_path});
        const texture_asset_id = try self.asset_manager.loadAssetAsync(texture_path, .texture, priority);
        const material_asset_id = try self.createMaterial(texture_asset_id);

        log(.INFO, "enhanced_scene", "Requesting async model preload: {s}", .{model_path});
        const model_asset_id = try self.asset_manager.loadAssetAsync(model_path, .mesh, priority);

        // Create GameObject with asset IDs - fallbacks will be used automatically at render time
        const obj = try self.addEmpty();
        obj.transform.translate(position);
        obj.transform.scale(scale);
        obj.model_asset = model_asset_id;
        obj.material_asset = material_asset_id;
        obj.texture_asset = texture_asset_id;
        obj.has_model = true;

        log(.INFO, "enhanced_scene", "addModelAssetAsync created object with REAL asset IDs: model={}, material={}, texture={}", .{ model_asset_id, material_asset_id, texture_asset_id });

        return obj;
    }

    /// Create a material with Enhanced Asset Manager integration
    pub fn createMaterial(self: *Self, albedo_texture_id: AssetId) !AssetId {
        // For now, we'll create a simple material reference
        // This could be expanded to use the asset manager's material system
        return try self.asset_manager.createMaterial(albedo_texture_id);
    }

    /// Load texture with priority
    pub fn preloadTextureAsync(self: *Self, texture_path: []const u8) !AssetId {
        return try self.asset_manager.loadAssetAsync(texture_path, .texture, .normal);
    }

    /// Load mesh with priority
    pub fn preloadModelAsync(self: *Self, mesh_path: []const u8) !AssetId {
        return try self.asset_manager.loadAssetAsync(mesh_path, .mesh, .normal);
    }

    /// Update async resources (required by app.zig) - detects when dirty flags transition to clean
    pub fn updateAsyncResources(self: *Self, allocator: std.mem.Allocator) !bool {
        _ = allocator; // unused since AssetManager handles resource updates

        // Track dirty states to detect when work completes
        const prev_tex_dirty = self.asset_manager.texture_descriptors_dirty;
        const prev_mat_dirty = self.asset_manager.materials_dirty;
        var work_started = false;

        // Check if texture descriptors need updating and queue async work
        if (self.asset_manager.texture_descriptors_dirty and !self.asset_manager.texture_descriptors_updating.load(.acquire)) {
            try self.asset_manager.queueTextureDescriptorUpdate();
            log(.DEBUG, "enhanced_scene", "Queued texture descriptor update", .{});
            work_started = true;
        }

        // Check if materials need updating and queue async work
        if (self.asset_manager.materials_dirty and !self.asset_manager.material_buffer_updating.load(.acquire)) {
            try self.asset_manager.queueMaterialBufferUpdate();
            log(.DEBUG, "enhanced_scene", "Queued material buffer update", .{});
            work_started = true;
        }

        // Check current dirty states after potential work completion
        const curr_tex_dirty = self.asset_manager.texture_descriptors_dirty;
        const curr_mat_dirty = self.asset_manager.materials_dirty;

        // Work completed if dirty flag transitions from true to false
        const texture_work_completed = prev_tex_dirty and !curr_tex_dirty;
        const material_work_completed = prev_mat_dirty and !curr_mat_dirty;

        const work_completed = texture_work_completed or material_work_completed;

        // Add debug logging to understand what's happening
        if (work_completed) {
            log(.DEBUG, "enhanced_scene", "Work completed: tex_completed={}, mat_completed={}, prev_tex_dirty={}, curr_tex_dirty={}, prev_mat_dirty={}, curr_mat_dirty={}", .{ texture_work_completed, material_work_completed, prev_tex_dirty, curr_tex_dirty, prev_mat_dirty, curr_mat_dirty });
        }

        return work_started or (self.asset_manager.material_buffer_updating.load(.acquire) or self.asset_manager.texture_descriptors_updating.load(.acquire) == false and work_completed);
    }

    /// Synchronous resource update - waits for all pending async operations to complete
    /// Use this during initialization when you need guaranteed completion before proceeding
    pub fn updateSyncResources(self: *Self, allocator: std.mem.Allocator) !bool {
        _ = allocator; // unused since AssetManager handles resource updates
        var any_updates = false;

        // Force update texture descriptors if dirty (synchronous)
        if (self.asset_manager.texture_descriptors_dirty) {
            try self.asset_manager.buildTextureDescriptorArray();
            self.asset_manager.texture_descriptors_dirty = false;
            any_updates = true;

            // Notify raytracing system
            if (self.raytracing_system) |rt_system| {
                rt_system.requestTextureDescriptorUpdate();
            }
        }

        // Force update materials if dirty (synchronous)
        if (self.asset_manager.materials_dirty) {
            try self.asset_manager.createMaterialBuffer(self.gc);
            self.asset_manager.materials_dirty = false;
            any_updates = true;
        }

        // Wait for any pending async operations to complete
        while (self.asset_manager.texture_descriptors_updating.load(.acquire) or
            self.asset_manager.material_buffer_updating.load(.acquire))
        {
            std.Thread.sleep(1_000_000); // Sleep 1ms
        }

        return any_updates;
    }

    /// Enhanced texture descriptor updates for backward compatibility
    pub fn updateTextureImageInfos(self: *Self) !bool {
        // Enhanced asset manager handles this internally
        const was_dirty = self.asset_manager.texture_descriptors_dirty;

        if (was_dirty) {
            try self.asset_manager.buildTextureDescriptorArray();

            // Notify raytracing system
            if (self.raytracing_system) |rt_system| {
                rt_system.requestTextureDescriptorUpdate();
            }

            log(.DEBUG, "enhanced_scene", "Updated texture descriptors due to dirty flag", .{});
        }

        return was_dirty;
    }

    /// Register raytracing system for texture updates
    pub fn setRaytracingSystem(self: *Self, rt_system: *@import("../systems/raytracing_system.zig").RaytracingSystem) void {
        self.raytracing_system = rt_system;
        log(.DEBUG, "enhanced_scene", "Raytracing system registered for texture updates", .{});
    }

    /// Enable hot reloading (API compatibility)
    pub fn enableHotReload(self: *Self) !void {
        try self.asset_manager.initHotReload();
        log(.INFO, "enhanced_scene", "Hot reloading enabled for scene assets", .{});
    }

    /// Get texture descriptor array (API compatibility)
    pub fn getTextureDescriptorArray(self: *Self) []const vk.DescriptorImageInfo {
        return self.asset_manager.texture_image_infos;
    }

    /// Render the scene
    pub fn render(self: Self, gc: GraphicsContext, cmdbuf: vk.CommandBuffer) !void {
        // Only render ready objects
        for (self.objects.items) |object| {
            try object.render(gc, cmdbuf);
        }
    }

    /// Get scene statistics for debugging
    pub fn getStatistics(self: *Self) struct {
        objects: usize,
        asset_manager_stats: @TypeOf(self.asset_manager.getStatistics()),
    } {
        return .{
            .objects = self.objects.items.len,
            .asset_manager_stats = self.asset_manager.getStatistics(),
        };
    }

    /// Create scene view for rendering passes
    pub fn createSceneView(self: *Self) @import("../rendering/render_pass.zig").SceneView {
        // Initialize SceneBridge if not already done
        if (self.scene_bridge == null) {
            self.scene_bridge = @import("../rendering/scene_bridge.zig").SceneBridge.init(self, self.allocator);
        }

        // Use SceneBridge for better BVH change tracking and caching
        return self.scene_bridge.?.createSceneView();
    }

    fn getRasterizationDataImpl(scene_ptr: *anyopaque) @import("../rendering/scene_view.zig").RasterizationData {
        const self: *Self = @ptrCast(@alignCast(scene_ptr));
        const RasterizationData = @import("../rendering/scene_view.zig").RasterizationData;
        const allocator = std.heap.c_allocator;

        // Allocate arrays on the heap
        const max_objects = self.objects.items.len * 4; // rough upper bound
        var renderable_objects = allocator.alloc(RasterizationData.RenderableObject, max_objects) catch @panic("OOM: renderable_objects");
        var obj_count: usize = 0;

        for (self.objects.items, 0..) |*obj, obj_idx| {
            if (!obj.has_model) continue;
            var model_opt: ?*const Model = null;

            // Asset-based approach: prioritize asset IDs
            if (obj.model_asset) |model_asset_id| {
                // Get asset ID with fallback and then get the loaded model
                const safe_asset_id = self.asset_manager.getAssetIdForRendering(model_asset_id);
                if (self.asset_manager.getLoadedModelConst(safe_asset_id)) |loaded_model| {
                    model_opt = loaded_model;
                }
                //log(.DEBUG, "enhanced_scene", "Object {d}: Using model asset ID {d} (safe ID {d})", .{ obj_idx, model_asset_id.toU64(), safe_asset_id.toU64() });
            }

            if (model_opt) |model| {
                //log(.DEBUG, "enhanced_scene", "Object {d}: Resolving model for rendering with {} meshes", .{ obj_idx, model.meshes.items.len });
                for (model.meshes.items, 0..) |model_mesh, mesh_idx| {
                    // Skip meshes without valid buffers
                    if (model_mesh.geometry.mesh.*.vertex_buffer == null or model_mesh.geometry.mesh.*.index_buffer == null) {
                        log(.WARN, "enhanced_scene", "Object {d}, Mesh {d}: Skipping render - missing vertex/index buffers", .{ obj_idx, mesh_idx });
                        continue;
                    }

                    var material_index: u32 = 0;

                    // Materials now come from AssetManager
                    if (obj.material_asset) |material_asset_id| {
                        // Get material index from AssetManager
                        if (self.asset_manager.getMaterialIndex(material_asset_id)) |mat_idx| {
                            material_index = @intCast(mat_idx);
                        }
                    }
                    // Fallback: material index 0 (default)

                    renderable_objects[obj_count] = RasterizationData.RenderableObject{
                        .transform = obj.transform.local2world.data,
                        .mesh_handle = RasterizationData.RenderableObject.MeshHandle{ .mesh_ptr = model_mesh.geometry.mesh },
                        .material_index = material_index,
                        .visible = true,
                    };
                    obj_count += 1;
                }
            } else {
                //log(.WARN, "enhanced_scene", "Object {d}: No valid model available (asset loading or resolution failed)", .{obj_idx});
            }
        }

        return RasterizationData{
            .objects = renderable_objects[0..obj_count],
        };
    }

    fn getRaytracingDataImpl(scene_ptr: *anyopaque) @import("../rendering/scene_view.zig").RaytracingData {
        const self: *Self = @ptrCast(@alignCast(scene_ptr));
        const RaytracingData = @import("../rendering/scene_view.zig").RaytracingData;
        const allocator = std.heap.c_allocator;

        // Count objects with models for raytracing
        var rt_instance_count: usize = 0;
        var rt_geometry_count: usize = 0;

        for (self.objects.items) |*obj| {
            if (obj.model != null) {
                // Direct model pointer
                if (obj.model) |model| {
                    rt_geometry_count += model.meshes.items.len;
                    rt_instance_count += model.meshes.items.len;
                }
            } else if (obj.has_model and obj.model_asset != null) {
                // Asset-based model
                if (obj.model_asset) |model_asset_id| {
                    const resolved_asset_id = self.asset_manager.getAssetIdForRendering(model_asset_id);
                    if (self.asset_manager.getModel(resolved_asset_id)) |model| {
                        rt_geometry_count += model.meshes.items.len;
                        rt_instance_count += model.meshes.items.len;
                    }
                }
            }
        }

        // Allocate arrays for raytracing data
        var rt_instances = allocator.alloc(RaytracingData.RTInstance, rt_instance_count) catch @panic("OOM: rt_instances");
        var rt_geometries = allocator.alloc(RaytracingData.RTGeometry, rt_geometry_count) catch @panic("OOM: rt_geometries");

        var instance_idx: usize = 0;
        var geometry_idx: usize = 0;

        // Extract raytracing data from scene objects
        for (self.objects.items, 0..) |*obj, obj_idx| {
            var model: ?*Model = null;

            // Get model from either direct pointer or asset system
            if (obj.model) |direct_model| {
                model = direct_model;
            } else if (obj.has_model and obj.model_asset != null) {
                if (obj.model_asset) |model_asset_id| {
                    const resolved_asset_id = self.asset_manager.getAssetIdForRendering(model_asset_id);
                    model = self.asset_manager.getModel(resolved_asset_id);
                }
            }

            if (model) |mdl| {
                for (mdl.meshes.items) |*model_mesh| {
                    if (instance_idx >= rt_instance_count or geometry_idx >= rt_geometry_count) break;

                    const geometry = &model_mesh.geometry;

                    // Create RT geometry description
                    rt_geometries[geometry_idx] = RaytracingData.RTGeometry{
                        .vertex_buffer = if (geometry.mesh.vertex_buffer) |buf| buf.buffer else @panic("Missing vertex buffer"),
                        .vertex_offset = 0,
                        .vertex_stride = @sizeOf(@import("../rendering/mesh.zig").Vertex),
                        .vertex_count = @intCast(geometry.mesh.vertices.items.len),
                        .index_buffer = if (geometry.mesh.index_buffer) |buf| buf.buffer else null,
                        .index_offset = 0,
                        .index_count = @intCast(geometry.mesh.indices.items.len),
                        .blas = null, // Will be filled by BVH system
                    };

                    // Create RT instance
                    const transform_3x4 = obj.transform.local2world.to_3x4();
                    rt_instances[instance_idx] = RaytracingData.RTInstance{
                        .transform = transform_3x4,
                        .instance_id = @intCast(obj_idx),
                        .mask = 0xFF,
                        .geometry_index = @intCast(geometry_idx),
                        .material_index = @min(geometry.mesh.material_id, 255), // Clamp for safety
                    };

                    instance_idx += 1;
                    geometry_idx += 1;
                }
            }
        }

        // Create raytracing data with BVH tracking
        return RaytracingData{
            .instances = rt_instances[0..instance_idx],
            .geometries = rt_geometries[0..geometry_idx],
            .materials = &[_]@import("../rendering/scene_view.zig").RasterizationData.MaterialData{}, // Empty for now
            .change_tracker = .{}, // Initialize with defaults
        };
    }

    fn getComputeDataImpl(scene_ptr: *anyopaque) @import("../rendering/scene_view.zig").ComputeData {
        const self: *Self = @ptrCast(@alignCast(scene_ptr));
        _ = self;
        // TODO: Implement compute data extraction
        return @import("../rendering/scene_view.zig").ComputeData{
            .particle_systems = &[_]@import("../rendering/scene_view.zig").ComputeData.ParticleSystem{},
            .compute_tasks = &[_]@import("../rendering/scene_view.zig").ComputeData.ComputeTask{},
        };
    }

    /// Process pending hot reloads
    pub fn processPendingReloads(self: *Self) void {
        self.asset_manager.processPendingReloads();
    }
};
