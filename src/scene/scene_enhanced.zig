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

// Re-export Material and Scene for compatibility
pub const Material = @import("scene.zig").Material;
const Scene = @import("scene.zig").Scene;

/// Asset completion callback function type
pub const AssetCompletionCallback = *const fn (asset_id: AssetId, asset_type: AssetType, user_data: ?*anyopaque) void;

/// Enhanced Scene with Asset Manager integration
/// Provides both legacy compatibility and new asset-based workflow
pub const EnhancedScene = struct {
    // Legacy compatibility - keep existing arrays for gradual migration
    objects: std.ArrayList(GameObject),
    materials: std.ArrayList(Material),
    textures: std.ArrayList(Texture),
    material_buffer: ?*Buffer = null,
    texture_image_infos: []const vk.DescriptorImageInfo = &[_]vk.DescriptorImageInfo{},

    // Asset Manager integration
    asset_manager: *AssetManager,

    // Asset ID mappings
    texture_assets: std.AutoHashMap(usize, AssetId), // legacy texture index -> AssetId
    material_assets: std.AutoHashMap(usize, AssetId), // legacy material index -> AssetId

    // Reverse mappings for compatibility
    asset_to_texture: std.AutoHashMap(AssetId, usize), // AssetId -> legacy texture index
    asset_to_material: std.AutoHashMap(AssetId, usize), // AssetId -> legacy material index

    // Direct texture cache for async loading
    texture_cache: std.StringHashMap(usize), // path -> texture index
    loading_textures: std.StringHashMap(bool), // path -> loading state

    // Async model loading tracking
    pending_model_loads: std.AutoHashMap(AssetId, *GameObject), // AssetId -> GameObject to update
    loading_models: std.StringHashMap(AssetId), // path -> AssetId

    // Dirty flags for different asset types
    textures_dirty: bool = false,
    models_dirty: bool = false,
    materials_dirty: bool = false,

    // Thread synchronization
    texture_mutex: std.Thread.Mutex = .{},

    // Track when texture descriptors need updates (legacy)
    texture_descriptors_dirty: bool = false,

    // Raytracing system reference for descriptor updates
    raytracing_system: ?*@import("../systems/raytracing_system.zig").RaytracingSystem = null,

    // Core dependencies
    gc: *GraphicsContext,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Callback function called when assets complete loading
    pub fn onAssetCompleted(asset_id: AssetId, asset_type: AssetType, user_data: ?*anyopaque) void {
        log(.DEBUG, "enhanced_scene", "onAssetCompleted called for asset {d} of type {}", .{ asset_id.toU64(), asset_type });

        if (user_data == null) return;

        const scene: *Self = @ptrCast(@alignCast(user_data));
        scene.handleAssetCompletion(asset_id, asset_type);
    }

    /// Handle completion of a specific asset type
    fn handleAssetCompletion(self: *Self, asset_id: AssetId, asset_type: AssetType) void {
        log(.INFO, "enhanced_scene", "Asset {d} of type {} completed loading", .{ asset_id.toU64(), asset_type });

        switch (asset_type) {
            .texture => {
                self.textures_dirty = true;
                self.texture_descriptors_dirty = true; // Legacy compatibility
                self.handleTextureCompletion(asset_id);
            },
            .mesh => {
                self.models_dirty = true;
                self.handleModelCompletion(asset_id);
            },
            .material => {
                self.materials_dirty = true;
                self.handleMaterialCompletion(asset_id);
            },
            .shader, .audio, .scene, .animation => {
                // Not handled by scene system yet
                log(.DEBUG, "enhanced_scene", "Asset type {} completion not handled by scene", .{asset_type});
            },
        }
    }

    /// Handle texture completion - update cached textures and descriptors
    fn handleTextureCompletion(self: *Self, asset_id: AssetId) void {
        log(.DEBUG, "enhanced_scene", "Processing texture completion for asset {d}", .{asset_id.toU64()});

        // Update raytracing descriptors if system is available
        if (self.raytracing_system) |rt_system| {
            rt_system.requestTextureDescriptorUpdate();
        }

        // TODO: Update texture cache and descriptor arrays
    }

    /// Handle model completion - replace fallback models with actual loaded models
    fn handleModelCompletion(self: *Self, asset_id: AssetId) void {
        log(.DEBUG, "enhanced_scene", "Processing model completion for asset {d}", .{asset_id.toU64()});

        // Check if we have a pending model load for this asset
        if (self.pending_model_loads.get(asset_id)) |game_object| {
            if (asset_id.toU64() == 14) {
                log(.ERROR, "enhanced_scene", "[ASSET 14] Replacing fallback model for asset 14!", .{});
            }
            log(.INFO, "enhanced_scene", "Replacing fallback model for asset {d}", .{asset_id.toU64()});

            // Get the loaded model from asset manager
            if (self.asset_manager.getLoadedModel(asset_id)) |loaded_model| {
                log(.INFO, "enhanced_scene", "Loaded model has {d} meshes", .{loaded_model.meshes.items.len});
                for (loaded_model.meshes.items, 0..) |model_mesh, mesh_idx| {
                    log(.INFO, "enhanced_scene", "  Mesh {d}: vertex_count={d}, index_count={d}", .{ mesh_idx, model_mesh.geometry.mesh.vertices.items.len, model_mesh.geometry.mesh.indices.items.len });
                }
                // Replace the fallback model with the loaded model
                if (game_object.model) |old_model| {
                    // Clean up old fallback model
                    old_model.deinit();
                    self.allocator.destroy(old_model);
                }

                // Assign the new model
                const model_ptr = self.allocator.create(Model) catch |err| {
                    log(.ERROR, "enhanced_scene", "Failed to allocate memory for model replacement: {}", .{err});
                    return;
                };
                model_ptr.* = loaded_model.*; // Copy the model data
                game_object.model = model_ptr;
                log(.INFO, "enhanced_scene", "Assigned loaded model to game object. Model ptr: {x}", .{@intFromPtr(model_ptr)});
                for (model_ptr.meshes.items, 0..) |model_mesh, mesh_idx| {
                    log(.INFO, "enhanced_scene", "  [Assigned] Mesh {d}: vertex_count={d}, index_count={d}", .{ mesh_idx, model_mesh.geometry.mesh.vertices.items.len, model_mesh.geometry.mesh.indices.items.len });
                }

                log(.INFO, "enhanced_scene", "Successfully replaced fallback with loaded model (asset {d}) - {d} meshes", .{ asset_id.toU64(), loaded_model.meshes.items.len });

                // TODO: Mark scene as needing rebuild for raytracing
                // The raytracing system will need to be updated to handle dynamic model changes
                _ = self.raytracing_system; // Suppress unused variable warning
            } else {
                log(.ERROR, "enhanced_scene", "Failed to get loaded model for asset {d}", .{asset_id.toU64()});
            }

            // Remove from pending loads
            _ = self.pending_model_loads.remove(asset_id);
        } else {
            log(.WARN, "enhanced_scene", "Model completion: asset_id {d} not found in pending_model_loads!", .{asset_id.toU64()});
            var it = self.pending_model_loads.iterator();
            var count: usize = 0;
            while (it.next()) |entry| {
                log(.DEBUG, "enhanced_scene", "  pending_model_loads key {d}", .{entry.key_ptr.*.toU64()});
                count += 1;
            }
            log(.DEBUG, "enhanced_scene", "  Total pending_model_loads: {d}", .{count});
        }
    }

    /// Handle material completion
    fn handleMaterialCompletion(self: *Self, asset_id: AssetId) void {
        _ = self; // Suppress unused warning
        log(.DEBUG, "enhanced_scene", "Processing material completion for asset {d}", .{asset_id.toU64()});
        // TODO: Update material buffer
    }

    pub fn init(gc: *GraphicsContext, allocator: std.mem.Allocator, asset_manager: *AssetManager) Self {
        const scene = Self{
            .objects = std.ArrayList(GameObject){},
            .materials = std.ArrayList(Material){},
            .textures = std.ArrayList(Texture){},
            .asset_manager = asset_manager,
            .texture_assets = std.AutoHashMap(usize, AssetId).init(allocator),
            .material_assets = std.AutoHashMap(usize, AssetId).init(allocator),
            .asset_to_texture = std.AutoHashMap(AssetId, usize).init(allocator),
            .asset_to_material = std.AutoHashMap(AssetId, usize).init(allocator),
            .texture_cache = std.StringHashMap(usize).init(allocator),
            .loading_textures = std.StringHashMap(bool).init(allocator),
            .pending_model_loads = std.AutoHashMap(AssetId, *GameObject).init(allocator),
            .loading_models = std.StringHashMap(AssetId).init(allocator),
            .textures_dirty = false,
            .models_dirty = false,
            .materials_dirty = false,
            .texture_descriptors_dirty = false,
            .gc = gc,
            .allocator = allocator,
        };

        // Note: We'll register the callback once we modify the scene to be heap-allocated
        // since we need a stable pointer for the callback
        // asset_manager.setAssetCompletionCallback(onAssetCompleted, &scene);

        return scene;
    }

    pub fn deinit(self: *Self) void {
        log(.INFO, "enhanced_scene", "Deinitializing EnhancedScene with {d} objects", .{self.objects.items.len});

        // Deinit GameObjects
        for (self.objects.items) |object| {
            object.deinit();
        }
        self.objects.deinit(self.allocator);

        // Deinit textures
        log(.DEBUG, "enhanced_scene", "Deinitializing {d} textures", .{self.textures.items.len});
        for (self.textures.items) |*tex| {
            tex.deinit();
        }
        self.textures.deinit(self.allocator);

        // Deinit material buffer
        if (self.material_buffer) |buf| {
            log(.DEBUG, "enhanced_scene", "Deinitializing material buffer", .{});
            buf.deinit();
            self.allocator.destroy(buf);
        }

        // Free texture image infos
        const static_empty_infos = &[_]vk.DescriptorImageInfo{};
        if (self.texture_image_infos.len > 0 and self.texture_image_infos.ptr != static_empty_infos.ptr) {
            log(.DEBUG, "enhanced_scene", "Freeing texture_image_infos array", .{});
            self.allocator.free(self.texture_image_infos);
        }

        // Clear materials
        self.materials.clearRetainingCapacity();
        self.materials.deinit(self.allocator);

        // Deinit asset mappings
        self.texture_assets.deinit();
        self.material_assets.deinit();
        self.asset_to_texture.deinit();
        self.asset_to_material.deinit();

        // Deinit texture cache
        self.texture_cache.deinit();
        self.loading_textures.deinit();

        // Deinit async model loading tracking
        self.pending_model_loads.deinit();
        self.loading_models.deinit();

        log(.INFO, "enhanced_scene", "EnhancedScene deinit complete", .{});
    }

    /// Convert EnhancedScene to Scene for compatibility with legacy renderers
    /// This is safe because EnhancedScene has the same memory layout as Scene for the first fields
    pub fn asScene(self: *Self) *Scene {
        return @ptrCast(self);
    }

    // Legacy API Compatibility

    pub fn addEmpty(self: *Self) !*GameObject {
        try self.objects.append(self.allocator, .{ .model = null });
        return &self.objects.items[self.objects.items.len - 1];
    }

    pub fn addObject(self: *Self, model: ?*Model, point_light: ?PointLightComponent) !*GameObject {
        try self.objects.append(self.allocator, .{
            .model = if (model) |m| m else null,
            .point_light = point_light,
        });
        return &self.objects.items[self.objects.items.len - 1];
    }

    pub fn addModelFromMesh(self: *Self, mesh: Mesh, name: []const u8, transform: ?Math.Vec3) !*GameObject {
        const model = try fromMesh(self.allocator, mesh, name);
        const object = try self.addObject(model, null);
        if (transform) |t| {
            object.transform.translate(t);
        }
        return object;
    }

    pub fn addModel(self: *Self, model: Model, point_light: ?PointLightComponent) !*GameObject {
        log(.DEBUG, "enhanced_scene", "addModel called with {d} meshes", .{model.meshes.items.len});
        // Heap-allocate the model internally
        const model_ptr = try self.allocator.create(Model);
        model_ptr.* = model;
        const object = try self.addObject(model_ptr, point_light);
        log(.DEBUG, "enhanced_scene", "addModel completed, object has model: {}", .{object.model != null});
        return object;
    }

    /// Legacy texture addition - automatically registers with Asset Manager
    pub fn addTexture(self: *Self, texture: Texture) !usize {
        try self.textures.append(self.allocator, texture);
        const index = self.textures.items.len - 1;
        self.texture_descriptors_dirty = true;
        try self.updateTextureImageInfos(self.allocator);

        // Register with Asset Manager (using a generated path)
        const path_buffer = try std.fmt.allocPrint(self.allocator, "legacy_texture_{d}", .{index});
        defer self.allocator.free(path_buffer);

        const asset_id = try self.asset_manager.registerAsset(path_buffer, .texture);
        try self.texture_assets.put(index, asset_id);
        try self.asset_to_texture.put(asset_id, index);

        log(.INFO, "enhanced_scene", "Added texture at index {d} with AssetId {d}", .{ index, asset_id.toU64() });
        return index;
    }

    /// Legacy material addition - automatically registers with Asset Manager
    pub fn addMaterial(self: *Self, material: Material) !usize {
        try self.materials.append(self.allocator, material);
        const index = self.materials.items.len - 1;
        try self.updateMaterialBuffer(self.gc, self.allocator);

        // Register with Asset Manager
        const path_buffer = try std.fmt.allocPrint(self.allocator, "legacy_material_{d}", .{index});
        defer self.allocator.free(path_buffer);

        const asset_id = try self.asset_manager.registerAsset(path_buffer, .material);
        try self.material_assets.put(index, asset_id);
        try self.asset_to_material.put(asset_id, index);

        // Set up dependencies if material references a texture
        if (material.albedo_texture_id > 0) {
            const texture_index = material.albedo_texture_id - 1; // Assuming 1-based indexing
            if (self.texture_assets.get(texture_index)) |texture_asset_id| {
                try self.asset_manager.addDependency(asset_id, texture_asset_id);
                log(.DEBUG, "enhanced_scene", "Added dependency: material {d} -> texture {d}", .{ asset_id.toU64(), texture_asset_id.toU64() });
            }
        }

        log(.INFO, "enhanced_scene", "Added material at index {d} with AssetId {d}", .{ index, asset_id.toU64() });
        return index;
    }

    // New Asset Manager API

    /// Load a texture using Asset Manager
    pub fn loadTexture(self: *Self, path: []const u8, priority: LoadPriority) !AssetId {
        const asset_id = try self.asset_manager.loadTexture(path, priority);
        self.asset_manager.addRef(asset_id);

        // If we need immediate compatibility with legacy system, we could load it into the texture array
        // For now, we'll keep it as AssetId only
        log(.INFO, "enhanced_scene", "Loaded texture asset: {s} -> {d}", .{ path, asset_id.toU64() });
        return asset_id;
    }

    /// Load a mesh/model using Asset Manager
    pub fn loadMesh(self: *Self, path: []const u8, priority: LoadPriority) !AssetId {
        const asset_id = try self.asset_manager.loadMesh(path, priority);
        self.asset_manager.addRef(asset_id);

        log(.INFO, "enhanced_scene", "Loaded mesh asset: {s} -> {d}", .{ path, asset_id.toU64() });
        return asset_id;
    }

    /// Create a material with Asset Manager integration
    pub fn createMaterial(self: *Self, albedo_texture_id: AssetId) !AssetId {
        // For now, we'll still create a legacy material but track it with Asset Manager
        var material = Material{
            .albedo_texture_id = 0, // Will be resolved when needed
        };

        // If the texture is in our legacy system, map it
        if (self.asset_to_texture.get(albedo_texture_id)) |texture_index| {
            material.albedo_texture_id = @intCast(texture_index + 1); // 1-based indexing
        }

        const material_index = try self.addMaterial(material);
        const asset_id = self.material_assets.get(material_index).?;

        // Add dependency
        try self.asset_manager.addDependency(asset_id, albedo_texture_id);

        return asset_id;
    }

    /// Add a model with Asset Manager workflow
    pub fn addModelWithAssets(self: *Self, model_path: []const u8, texture_path: []const u8, priority: LoadPriority) !*GameObject {
        // Load assets through Asset Manager
        const texture_asset_id = try self.loadTexture(texture_path, priority);
        const mesh_asset_id = try self.loadMesh(model_path, priority);
        const material_asset_id = try self.createMaterial(texture_asset_id);

        // Log the asset IDs for debugging
        log(.DEBUG, "enhanced_scene", "Loaded assets: texture={d}, mesh={d}, material={d}", .{ texture_asset_id.toU64(), mesh_asset_id.toU64(), material_asset_id.toU64() });

        // Wait for assets to load
        self.asset_manager.waitForAllLoads();

        // Use legacy loading for GameObject creation (assets are pre-loaded above)
        return try self.addModelWithMaterial(model_path, texture_path);
    }

    // Legacy compatibility methods (unchanged)

    pub fn updateMaterialBuffer(self: *Self, gc: *GraphicsContext, allocator: std.mem.Allocator) !void {
        if (self.materials.items.len == 0) return;
        if (self.material_buffer) |buf| {
            buf.deinit();
        }
        const buf = try allocator.create(Buffer);
        buf.* = try Buffer.init(
            gc,
            @sizeOf(Material),
            @as(u32, @intCast(self.materials.items.len)),
            .{
                .storage_buffer_bit = true,
            },
            .{ .host_visible_bit = true, .host_coherent_bit = true },
        );
        try buf.map(@sizeOf(Material) * self.materials.items.len, 0);
        log(.DEBUG, "enhanced_scene", "Updating material buffer with {d} materials", .{self.materials.items.len});
        buf.writeToBuffer(
            std.mem.sliceAsBytes(self.materials.items),
            @sizeOf(Material) * self.materials.items.len,
            0,
        );
        self.material_buffer = buf;
    }

    pub fn updateTextureImageInfos(self: *Self, allocator: std.mem.Allocator) !void {
        if (self.textures.items.len == 0) {
            self.texture_image_infos = &[_]vk.DescriptorImageInfo{};
        } else {
            // Ensure we have at least 32 textures to match forward renderer descriptor capacity
            // Fill missing indices with the first texture as fallback
            const min_texture_count = @max(self.textures.items.len, 32);
            const infos = try allocator.alloc(vk.DescriptorImageInfo, min_texture_count);

            for (0..min_texture_count) |i| {
                if (i < self.textures.items.len) {
                    infos[i] = self.textures.items[i].descriptor;
                } else {
                    // Use first texture as fallback for missing indices
                    infos[i] = self.textures.items[0].descriptor;
                }
            }
            self.texture_image_infos = infos;
        }

        // Notify raytracing system that texture descriptors need to be updated
        if (self.raytracing_system) |rt_system| {
            rt_system.requestTextureDescriptorUpdate();
        }
    }

    /// Check if any assets are dirty and need updates
    pub fn isDirty(self: *const Self) bool {
        return self.textures_dirty or self.models_dirty or self.materials_dirty;
    }

    /// Check if specific asset types are dirty
    pub fn areTexturesDirty(self: *const Self) bool {
        return self.textures_dirty;
    }

    pub fn areModelsDirty(self: *const Self) bool {
        return self.models_dirty;
    }

    pub fn areMaterialsDirty(self: *const Self) bool {
        return self.materials_dirty;
    }

    /// Clear dirty flags after updates are processed
    pub fn clearTexturesDirty(self: *Self) void {
        self.textures_dirty = false;
        self.texture_descriptors_dirty = false; // Legacy compatibility
    }

    pub fn clearModelsDirty(self: *Self) void {
        self.models_dirty = false;
    }

    pub fn clearMaterialsDirty(self: *Self) void {
        self.materials_dirty = false;
    }

    pub fn clearAllDirtyFlags(self: *Self) void {
        self.textures_dirty = false;
        self.models_dirty = false;
        self.materials_dirty = false;
        self.texture_descriptors_dirty = false;
    }

    pub fn render(self: Self, gc: GraphicsContext, cmdbuf: vk.CommandBuffer) !void {
        for (self.objects.items) |object| {
            try object.render(gc, cmdbuf);
        }
    }

    pub fn addModelWithMaterial(
        self: *Self,
        model_path: []const u8,
        texture_path: []const u8,
    ) !*GameObject {
        log(.DEBUG, "enhanced_scene", "Loading model from {s}", .{model_path});
        const model_data = try loadFileAlloc(self.allocator, model_path, 10 * 1024 * 1024);
        defer self.allocator.free(model_data);
        const model = try Model.loadFromObj(self.allocator, self.gc, model_data, model_path);

        var texture_id: usize = undefined;

        // Check if texture was already loaded asynchronously into cache
        if (self.getCachedTexture(texture_path)) |cached_texture_id| {
            log(.INFO, "enhanced_scene", "Using async-loaded cached texture for {s} -> index {d}", .{ texture_path, cached_texture_id });
            texture_id = cached_texture_id;
        } else if (self.isTextureLoading(texture_path)) {
            // Wait for loading to complete
            log(.INFO, "enhanced_scene", "Waiting for async texture to finish loading: {s}", .{texture_path});
            while (self.isTextureLoading(texture_path)) {
                std.Thread.sleep(1_000_000); // 1ms
            }
            // Check cache again after loading completes
            if (self.getCachedTexture(texture_path)) |cached_texture_id| {
                log(.INFO, "enhanced_scene", "Using completed async-loaded texture for {s} -> index {d}", .{ texture_path, cached_texture_id });
                texture_id = cached_texture_id;
            } else {
                // Async loading failed, fall back to sync with fallback
                log(.WARN, "enhanced_scene", "Async texture loading failed, falling back to sync: {s}", .{texture_path});
                const texture = Texture.initFromFile(self.gc, self.allocator, texture_path, .rgba8) catch |err| blk: {
                    log(.WARN, "enhanced_scene", "Failed to load texture {s}: {}, using fallback", .{ texture_path, err });
                    const fallback_texture = Texture.initFromFile(self.gc, self.allocator, "textures/error.png", .rgba8) catch {
                        log(.ERROR, "enhanced_scene", "Failed to load fallback texture, using missing.png", .{});
                        break :blk try Texture.initFromFile(self.gc, self.allocator, "textures/missing.png", .rgba8);
                    };
                    break :blk fallback_texture;
                };
                texture_id = try self.addTexture(texture);
            }
        } else {
            // No async loading was started, load synchronously with fallback
            log(.DEBUG, "enhanced_scene", "Loading texture synchronously from {s}", .{texture_path});
            const texture = Texture.initFromFile(self.gc, self.allocator, texture_path, .rgba8) catch |err| blk: {
                log(.WARN, "enhanced_scene", "Failed to load texture {s}: {}, using fallback", .{ texture_path, err });
                const fallback_texture = Texture.initFromFile(self.gc, self.allocator, "textures/error.png", .rgba8) catch {
                    log(.ERROR, "enhanced_scene", "Failed to load fallback texture, using missing.png", .{});
                    break :blk try Texture.initFromFile(self.gc, self.allocator, "textures/missing.png", .rgba8);
                };
                break :blk fallback_texture;
            };
            texture_id = try self.addTexture(texture);
        }

        const material = Material{ .albedo_texture_id = @intCast(texture_id + 1) }; // 1-based
        const material_id = try self.addMaterial(material);
        for (model.meshes.items) |*mesh| {
            mesh.geometry.mesh.material_id = @intCast(material_id);
        }
        log(.INFO, "enhanced_scene", "Assigned material {d} to all meshes in model {s}", .{ material_id, model_path });
        return try self.addModel(model, null);
    }

    pub fn addModelWithMaterialAndTransform(
        self: *Self,
        model_path: []const u8,
        texture_path: []const u8,
        transform: Math.Vec3,
        scale: Math.Vec3,
    ) !*GameObject {
        log(.ERROR, "enhanced_scene", "SYNC VERSION CALLED for: {s}", .{model_path});
        const obj = try self.addModelWithMaterial(model_path, texture_path);
        obj.transform.translate(transform);
        obj.transform.scale(scale);
        return obj;
    }

    /// Non-blocking version that uses fallback cube while model loads
    pub fn addModelWithMaterialAndTransformAsync(
        self: *Self,
        model_path: []const u8,
        texture_path: []const u8,
        transform: Math.Vec3,
        scale: Math.Vec3,
    ) !*GameObject {
        log(.ERROR, "enhanced_scene", "ASYNC VERSION CALLED: Creating fallback cube for {s} while loading asynchronously", .{model_path});
        const fallback_model = try FallbackMeshes.createCubeModel(self.allocator, self.gc, "fallback_cube");
        // Debug: Print current pending_model_loads before adding
        log(.DEBUG, "enhanced_scene", "[DEBUG] Before fallback creation, pending_model_loads count: {d}", .{self.pending_model_loads.count()});

        // Handle texture loading (can be async or cached)
        var texture_id: usize = undefined;

        // Check if texture was already loaded asynchronously into cache
        if (self.getCachedTexture(texture_path)) |cached_texture_id| {
            log(.INFO, "enhanced_scene", "Using cached texture for {s} -> index {d}", .{ texture_path, cached_texture_id });
            texture_id = cached_texture_id;
        } else {
            // Start async texture loading
            self.startAsyncTextureLoad(texture_path) catch |err| {
                log(.WARN, "enhanced_scene", "Failed to start async texture load for {s}: {}", .{ texture_path, err });
            };

            // Load texture synchronously with fallback on failure for immediate use
            log(.DEBUG, "enhanced_scene", "Loading fallback texture synchronously from {s}", .{texture_path});
            const texture = Texture.initFromFile(self.gc, self.allocator, texture_path, .rgba8) catch |err| blk: {
                log(.WARN, "enhanced_scene", "Failed to load texture {s}: {}, using fallback", .{ texture_path, err });
                const fallback_texture = Texture.initFromFile(self.gc, self.allocator, "textures/error.png", .rgba8) catch {
                    log(.ERROR, "enhanced_scene", "Failed to load fallback texture, using missing.png", .{});
                    break :blk try Texture.initFromFile(self.gc, self.allocator, "textures/missing.png", .rgba8);
                };
                break :blk fallback_texture;
            };
            texture_id = try self.addTexture(texture);
        }

        // Create material for the fallback
        const material = Material{ .albedo_texture_id = @intCast(texture_id + 1) }; // 1-based
        const material_id = try self.addMaterial(material);

        // Assign material to fallback mesh
        for (fallback_model.meshes.items) |*mesh_model| {
            mesh_model.geometry.mesh.material_id = @intCast(material_id);
        }

        // Create the game object with fallback model
        const obj = try self.addModel(fallback_model, null);
        obj.transform.translate(transform);
        obj.transform.scale(scale);
        // Debug: Print pointer and model_path
        log(.DEBUG, "enhanced_scene", "[DEBUG] Created fallback GameObject ptr: {x} for model_path: {s}", .{ @intFromPtr(obj), model_path });

        // Start async model loading and track it
        const model_asset_id = self.preloadModelAsync(model_path, .high) catch |err| blk: {
            log(.WARN, "enhanced_scene", "Failed to start async model load for {s}: {}", .{ model_path, err });
            // Continue with fallback model if async loading fails to start
            break :blk AssetId.invalid;
        };

        if (model_asset_id.isValid()) {
            // Debug: Print asset_id and pointer
            log(.DEBUG, "enhanced_scene", "[DEBUG] Registering pending_model_loads: asset_id={d} (model_path: {s}), GameObject ptr: {x}", .{ model_asset_id.toU64(), model_path, @intFromPtr(obj) });
            // Check for accidental overwrite
            if (self.pending_model_loads.get(model_asset_id)) |existing_obj| {
                log(.WARN, "enhanced_scene", "[DEBUG] Overwriting existing pending_model_loads for asset_id={d}, old GameObject ptr: {x}", .{ model_asset_id.toU64(), @intFromPtr(existing_obj) });
            }
            try self.pending_model_loads.put(model_asset_id, obj);
            try self.loading_models.put(model_path, model_asset_id);
            log(.INFO, "enhanced_scene", "Started async loading for model {s} with AssetId {d}", .{ model_path, model_asset_id.toU64() });
            // Debug: Print current pending_model_loads after adding
            log(.DEBUG, "enhanced_scene", "[DEBUG] After registration, pending_model_loads count: {d}", .{self.pending_model_loads.count()});
        } else {
            log(.ERROR, "enhanced_scene", "[DEBUG] Invalid model_asset_id for async model load: {s}", .{model_path});
        }

        log(.INFO, "enhanced_scene", "Created fallback object for: {s}", .{model_path});
        // Debug: Print all keys in pending_model_loads
        var it = self.pending_model_loads.iterator();
        var count: usize = 0;
        while (it.next()) |entry| {
            log(.DEBUG, "enhanced_scene", "[DEBUG] pending_model_loads key {d} -> GameObject ptr: {x}", .{ entry.key_ptr.*.toU64(), @intFromPtr(entry.value_ptr.*) });
            count += 1;
        }
        log(.DEBUG, "enhanced_scene", "[DEBUG] Total pending_model_loads after fallback creation: {d}", .{count});
        return obj;
    }

    // Async Loading Features

    /// Request a texture to be loaded asynchronously
    pub fn preloadTextureAsync(self: *Self, texture_path: []const u8, priority: LoadPriority) !AssetId {
        log(.INFO, "enhanced_scene", "Requesting async texture preload: {s}", .{texture_path});
        return try self.asset_manager.loadTexture(texture_path, priority);
    }

    /// Start loading a texture asynchronously using AssetManager
    pub fn startAsyncTextureLoad(self: *Self, texture_path: []const u8) !void {
        log(.INFO, "enhanced_scene", "Starting async texture load via AssetManager: {s}", .{texture_path});

        // Use AssetManager to start async loading with high priority
        const asset_id = try self.asset_manager.loadTexture(texture_path, .high);

        log(.DEBUG, "enhanced_scene", "AssetManager texture load queued: {s} -> AssetId: {d}", .{ texture_path, asset_id.toU64() });

        // For now, we'll just queue the load through AssetManager
        // The legacy texture loading system will handle the actual Texture object creation
    }

    /// Get a texture from cache if available, returns texture index or null
    pub fn getCachedTexture(self: *Self, texture_path: []const u8) ?usize {
        return self.texture_cache.get(texture_path);
    }

    /// SAFE texture access for rendering - always returns a valid texture
    /// Uses AssetManager fallback system to prevent crashes from unloaded assets
    pub fn getTextureForRendering(self: *Self, asset_id: AssetId) ?*Texture {
        // Get the safe asset ID (with fallback if needed)
        const safe_asset_id = self.asset_manager.getAssetIdForRendering(asset_id);

        // Try to get texture from legacy system first
        if (self.asset_to_texture.get(safe_asset_id)) |texture_index| {
            if (texture_index < self.textures.items.len) {
                return &self.textures.items[texture_index];
            }
        }

        // Asset not in legacy system, return null for graceful renderer handling
        return null;
    }

    /// SAFE texture index access for legacy compatibility
    /// Returns fallback texture index if original texture not ready
    pub fn getTextureIndexForRendering(self: *Self, texture_index: usize) usize {
        if (texture_index < self.textures.items.len) {
            // Check if this texture has an associated asset that might not be ready
            if (self.texture_assets.get(texture_index)) |asset_id| {
                const safe_asset_id = self.asset_manager.getAssetIdForRendering(asset_id);
                if (safe_asset_id != asset_id) {
                    // Asset was replaced with fallback, try to find fallback texture index
                    if (self.asset_to_texture.get(safe_asset_id)) |fallback_index| {
                        return fallback_index;
                    }
                }
            }
            return texture_index;
        }

        // Invalid index - try to return a fallback texture index
        if (self.asset_manager.getFallbackAssetId(.missing)) |fallback_id| {
            if (self.asset_to_texture.get(fallback_id)) |fallback_index| {
                return fallback_index;
            }
        }

        // Last resort - return 0 or clamp to valid range
        return if (self.textures.items.len > 0) 0 else texture_index;
    }

    /// Check if a texture is currently being loaded
    pub fn isTextureLoading(self: *Self, texture_path: []const u8) bool {
        return self.loading_textures.get(texture_path) orelse false;
    }

    /// Thread-safe method to add textures from background threads
    fn addTextureThreadSafe(self: *Self, texture: Texture, path: []const u8) !usize {
        self.texture_mutex.lock();
        defer self.texture_mutex.unlock();

        // Add texture to scene array
        try self.textures.append(self.allocator, texture);
        const texture_index = self.textures.items.len - 1;

        // Mark descriptors as needing update
        self.texture_descriptors_dirty = true;

        // Update texture image infos for Vulkan descriptors (must be done on main thread)
        // For now, we'll skip this and do it lazily when needed

        // Register with Asset Manager (using a generated path)
        const path_buffer = try std.fmt.allocPrint(self.allocator, "async_texture_{s}", .{path});
        defer self.allocator.free(path_buffer);

        const asset_id = try self.asset_manager.registerAsset(path_buffer, .texture);
        try self.texture_assets.put(texture_index, asset_id);
        try self.asset_to_texture.put(asset_id, texture_index);

        // Update cache
        try self.texture_cache.put(path, texture_index);
        _ = self.loading_textures.put(path, false) catch {};

        log(.INFO, "enhanced_scene", "Added async texture at index {d} with AssetId {d} for path: {s}", .{ texture_index, asset_id.toU64(), path });
        return texture_index;
    }

    /// Update texture image infos when new textures are added asynchronously
    /// This must be called from the main thread for Vulkan descriptor updates
    pub fn updateAsyncTextures(self: *Self, allocator: std.mem.Allocator) !void {
        self.texture_mutex.lock();
        defer self.texture_mutex.unlock();

        // Only update if texture descriptors are actually dirty
        if (self.texture_descriptors_dirty and self.textures.items.len > 0) {
            try self.updateTextureImageInfos(allocator);
            self.texture_descriptors_dirty = false; // Reset the flag
        }
    }

    /// Process dirty assets and update the scene (callback-driven)
    pub fn updateAsyncResources(self: *Self, allocator: std.mem.Allocator) !bool {
        var resources_updated = false;

        // Process dirty textures
        if (self.areTexturesDirty()) {
            try self.updateTextureImageInfos(allocator);
            self.clearTexturesDirty();
            resources_updated = true;
            log(.DEBUG, "enhanced_scene", "Updated texture descriptors due to dirty flag", .{});
        }

        // Process dirty models
        if (self.areModelsDirty()) {
            // Model updates are already handled in the completion callback
            self.clearModelsDirty();
            resources_updated = true;
            log(.DEBUG, "enhanced_scene", "Cleared models dirty flag", .{});
        }

        // Process dirty materials
        if (self.areMaterialsDirty()) {
            try self.updateMaterialBuffer(self.gc, allocator);
            self.clearMaterialsDirty();
            resources_updated = true;
            log(.DEBUG, "enhanced_scene", "Updated materials due to dirty flag", .{});
        }

        return resources_updated;
    }

    /// Update objects with completed async model loads
    fn updateAsyncModels(self: *Self, allocator: std.mem.Allocator) !u32 {
        var updates = @as(u32, 0);

        // Create a list of completed asset IDs to avoid modifying the map while iterating
        var completed_assets = try std.ArrayList(AssetId).initCapacity(allocator, 8);
        defer completed_assets.deinit(allocator);

        // Check which pending model loads have completed
        var iterator = self.pending_model_loads.iterator();
        while (iterator.next()) |entry| {
            const asset_id = entry.key_ptr.*;

            if (self.isAssetReady(asset_id)) {
                try completed_assets.append(allocator, asset_id);

                // For now, just log that the model is ready - actual replacement will be implemented later
                log(.INFO, "enhanced_scene", "Model asset {d} is ready for replacement (not yet implemented)", .{asset_id.toU64()});
                updates += 1;
            }
        }

        // Remove completed assets from tracking
        for (completed_assets.items) |asset_id| {
            _ = self.pending_model_loads.remove(asset_id);
        }

        return updates;
    }

    /// Preload multiple textures asynchronously
    pub fn preloadTextures(self: *Self, texture_paths: []const []const u8) !void {
        log(.INFO, "enhanced_scene", "Preloading {d} textures asynchronously", .{texture_paths.len});
        for (texture_paths) |path| {
            self.startAsyncTextureLoad(path) catch |err| {
                log(.ERROR, "enhanced_scene", "Failed to start async load for {s}: {}", .{ path, err });
            };
        }
    }

    /// Request a model to be loaded asynchronously
    pub fn preloadModelAsync(self: *Self, model_path: []const u8, priority: LoadPriority) !AssetId {
        log(.INFO, "enhanced_scene", "Requesting async model preload: {s}", .{model_path});
        return try self.asset_manager.loadMesh(model_path, priority);
    }

    /// Check if an asset is ready to use
    pub fn isAssetReady(self: *Self, asset_id: AssetId) bool {
        return self.asset_manager.isAssetLoaded(asset_id);
    }

    /// Wait for an asset to finish loading
    pub fn waitForAsset(self: *Self, asset_id: AssetId) void {
        log(.DEBUG, "enhanced_scene", "Waiting for asset {d} to load", .{asset_id.toU64()});
        self.asset_manager.loader.waitForAsset(asset_id);
        log(.DEBUG, "enhanced_scene", "Asset {d} loading complete", .{asset_id.toU64()});
    }

    /// Get current loading statistics from the Asset Manager
    pub fn getLoadingStats(self: *Self) @TypeOf(self.asset_manager.loader.getLoadingStats()) {
        return self.asset_manager.loader.getLoadingStats();
    }

    /// Check if async loading is enabled
    pub fn isAsyncLoadingEnabled(self: *const Self) bool {
        return self.asset_manager.loader.isAsyncEnabled();
    }

    // Asset Manager utility functions

    /// Get Asset Manager statistics
    pub fn getAssetStatistics(self: *Self) @import("../assets/asset_manager.zig").AssetManagerStatistics {
        return self.asset_manager.getStatistics();
    }

    /// Print debug information about assets
    pub fn printAssetDebugInfo(self: *Self) void {
        self.asset_manager.printDebugInfo();

        std.debug.print("\n=== Enhanced Scene Asset Mapping ===\n");
        std.debug.print("Legacy textures: {d}\n", .{self.textures.items.len});
        std.debug.print("Legacy materials: {d}\n", .{self.materials.items.len});
        std.debug.print("Asset mappings: {d} textures, {d} materials\n", .{ self.texture_assets.count(), self.material_assets.count() });
    }

    /// Cleanup unused assets based on reference counting
    pub fn cleanupUnusedAssets(self: *Self) !u32 {
        return try self.asset_manager.unloadUnusedAssets();
    }

    // Hot Reloading Support

    /// Enable hot reloading for this scene's assets
    pub fn enableHotReload(self: *Self) !void {
        try self.asset_manager.enableHotReload();
        log(.INFO, "enhanced_scene", "Hot reloading enabled for scene assets", .{});
    }

    /// Disable hot reloading
    pub fn disableHotReload(self: *Self) void {
        self.asset_manager.disableHotReload();
        log(.INFO, "enhanced_scene", "Hot reloading disabled", .{});
    }

    /// Process any pending hot reloads - call this each frame
    pub fn processPendingReloads(self: *Self) void {
        self.asset_manager.processPendingReloads();
    }

    /// Register a texture asset for hot reloading
    pub fn enableTextureHotReload(self: *Self, asset_id: AssetId, file_path: []const u8) !void {
        try self.asset_manager.registerAssetForHotReload(asset_id, file_path);
        log(.DEBUG, "enhanced_scene", "Enabled hot reload for texture: {s} (AssetId: {})", .{ file_path, asset_id });
    }

    /// Auto-register loaded textures for hot reloading
    pub fn enableAutoHotReload(self: *Self) !void {
        // Register all currently loaded textures for hot reloading
        var iter = self.texture_assets.iterator();
        while (iter.next()) |entry| {
            const asset_id = entry.value_ptr.*;

            // Get the asset metadata to find the file path
            if (self.asset_manager.getAsset(asset_id)) |_| {
                // AssetMetadata should have the path, but we need to access it
                // For now, we'll enable hot reload without automatic path detection
                log(.DEBUG, "enhanced_scene", "AssetId {} registered for hot reload", .{asset_id});
            }
        }

        log(.INFO, "enhanced_scene", "Auto hot reload enabled for {} texture assets", .{self.texture_assets.count()});
    }

    /// Callback function for when textures are hot reloaded
    pub fn onTextureReloaded(self: *Self, file_path: []const u8, asset_id: AssetId) void {
        log(.INFO, "enhanced_scene", "Texture hot reload completed: {s} (AssetId: {})", .{ file_path, asset_id });

        // Update texture descriptor infos to refresh raytracing system
        self.updateTextureImageInfos(self.allocator) catch |err| {
            log(.ERROR, "enhanced_scene", "Failed to update texture descriptors after reload: {}", .{err});
        };
    }

    /// Register raytracing system to receive texture update notifications
    pub fn setRaytracingSystem(self: *Self, raytracing_system: *@import("../systems/raytracing_system.zig").RaytracingSystem) void {
        self.raytracing_system = raytracing_system;
        log(.DEBUG, "enhanced_scene", "Raytracing system registered for texture updates", .{});
    }

    /// Register this scene instance for hot reload callbacks
    pub fn registerForHotReloadCallbacks(self: *Self) void {
        global_scene_instance = self;
        log(.DEBUG, "enhanced_scene", "Scene registered for hot reload callbacks", .{});
    }

    /// Static callback wrapper for hot reload manager - requires global scene instance
    pub fn textureReloadCallbackWrapper(file_path: []const u8, asset_id: AssetId) void {
        if (global_scene_instance) |scene| {
            scene.onTextureReloaded(file_path, asset_id);
        }
    }

    // ===== SceneView Implementation =====

    /// Create a SceneView for this EnhancedScene
    pub fn createSceneView(self: *Self) @import("../rendering/render_pass.zig").SceneView {
        const SceneView = @import("../rendering/render_pass.zig").SceneView;

        const vtable = &SceneView.SceneViewVTable{
            .getRasterizationData = getRasterizationDataImpl,
            .getRaytracingData = getRaytracingDataImpl,
            .getComputeData = getComputeDataImpl,
        };

        return SceneView{
            .scene_ptr = self,
            .vtable = vtable,
        };
    }

    fn getRasterizationDataImpl(scene_ptr: *anyopaque) @import("../rendering/scene_view.zig").RasterizationData {
        const self: *Self = @ptrCast(@alignCast(scene_ptr));
        const RasterizationData = @import("../rendering/scene_view.zig").RasterizationData;

        // Convert GameObject list to RenderableObject list
        // For now, we'll use stack allocation for demo purposes
        var renderable_objects: [32]RasterizationData.RenderableObject = undefined;
        var material_data: [32]RasterizationData.MaterialData = undefined;
        var texture_ptrs: [32]*const Texture = undefined;

        var obj_count: usize = 0;
        for (self.objects.items) |*obj| {
            if (obj.model) |model| {
                // For each mesh in the model
                for (model.meshes.items) |model_mesh| {
                    if (obj_count >= 32) break; // Safety limit for demo

                    renderable_objects[obj_count] = RasterizationData.RenderableObject{
                        .transform = obj.transform.local2world.data,
                        .mesh = &model_mesh.geometry.mesh,
                        .material_index = 0, // Default material
                        .texture_index = 0, // Default texture for now
                        .visible = true,
                    };
                    obj_count += 1;
                }
            }
        }

        // Convert materials
        const mat_count = @min(self.materials.items.len, 32);
        for (0..mat_count) |i| {
            const mat = &self.materials.items[i];
            material_data[i] = RasterizationData.MaterialData{
                .base_color = .{ 1.0, 1.0, 1.0, 1.0 },
                .metallic = mat.metallic,
                .roughness = mat.roughness,
                .emissive = mat.emissive,
                .texture_index = mat.albedo_texture_id,
            };
        }

        // Convert textures
        const tex_count = @min(self.textures.items.len, 32);
        for (0..tex_count) |i| {
            texture_ptrs[i] = &self.textures.items[i];
        }

        return RasterizationData{
            .objects = renderable_objects[0..obj_count],
            .materials = material_data[0..mat_count],
            .textures = texture_ptrs[0..tex_count],
        };
    }

    fn getRaytracingDataImpl(scene_ptr: *anyopaque) @import("../rendering/scene_view.zig").RaytracingData {
        const self: *Self = @ptrCast(@alignCast(scene_ptr));
        _ = self;
        // TODO: Implement raytracing data extraction
        return @import("../rendering/scene_view.zig").RaytracingData{
            .instances = &[_]@import("../rendering/scene_view.zig").RaytracingData.RTInstance{},
            .geometries = &[_]@import("../rendering/scene_view.zig").RaytracingData.RTGeometry{},
            .materials = &[_]@import("../rendering/scene_view.zig").RasterizationData.MaterialData{},
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
};

// Global scene instance for callback access - needed because C-style callbacks can't capture context
var global_scene_instance: ?*EnhancedScene = null;
