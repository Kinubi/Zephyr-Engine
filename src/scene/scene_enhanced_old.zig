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
    // Core scene data - only GameObjects with asset references
    objects: std.ArrayList(GameObject),
    next_object_id: u64,

    // Asset Manager integration - all assets handled here
    asset_manager: *AssetManager,

    // Raytracing system reference for descriptor updates
    raytracing_system: ?*@import("../systems/raytracing_system.zig").RaytracingSystem,

    // Core dependencies
    gc: *GraphicsContext,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Initialize the EnhancedScene
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

    /// Deinitialize the EnhancedScene
    pub fn deinit(self: *Self) void {
        log(.INFO, "enhanced_scene", "Deinitializing EnhancedScene with {d} objects", .{self.objects.items.len});

        // Deinit GameObjects
        for (self.objects.items) |object| {
            object.deinit();
        }
        self.objects.deinit(self.allocator);

        log(.INFO, "enhanced_scene", "EnhancedScene deinit complete", .{});
    }

    /// Convert EnhancedScene to Scene for compatibility with legacy renderers
    /// This is safe because EnhancedScene has the same memory layout as Scene for the first fields
    pub fn asScene(self: *Self) *Scene {
        return @ptrCast(self);
    }

    // Legacy API Compatibility

    pub fn addEmpty(self: *Self) !*GameObject {
        const object_id = self.next_object_id;
        self.next_object_id += 1;
        try self.objects.append(self.allocator, .{ .id = object_id, .model = null, .point_light = null });
        return &self.objects.items[self.objects.items.len - 1];
    }

    pub fn addObject(self: *Self, model: ?*Model, point_light: ?PointLightComponent) !*GameObject {
        const object_id = self.next_object_id;
        self.next_object_id += 1;
        try self.objects.append(self.allocator, .{
            .id = object_id,
            .model = if (model) |m| m else null,
            .point_light = point_light,
        });
        return &self.objects.items[self.objects.items.len - 1];
    }

    pub fn addModelFromMesh(self: *Self, mesh: Mesh, name: []const u8, transform: ?Math.Vec3) !*GameObject {
        // Clone the mesh to ensure a unique mesh pointer for each object
        var mesh_clone = Mesh.init(self.allocator);
        try mesh_clone.vertices.appendSlice(self.allocator, mesh.vertices.items);
        try mesh_clone.indices.appendSlice(self.allocator, mesh.indices.items);
        mesh_clone.material_id = mesh.material_id;
        if (mesh.vertex_buffer) |vb| mesh_clone.vertex_buffer = vb;
        if (mesh.index_buffer) |ib| mesh_clone.index_buffer = ib;

        const model = try fromMesh(self.allocator, mesh_clone, name);
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

    // Asset Manager API

    /// Load a texture using Asset Manager
    pub fn loadTexture(self: *Self, path: []const u8) !AssetId {
        const asset_id = try self.asset_manager.loadTexture(path);
        self.asset_manager.addRef(asset_id);

        // If we need immediate compatibility with legacy system, we could load it into the texture array
        // For now, we'll keep it as AssetId only
        log(.INFO, "enhanced_scene", "Loaded texture asset: {s} -> {d}", .{ path, asset_id.toU64() });
        return asset_id;
    }

    /// Load a mesh/model using Asset Manager
    pub fn loadMesh(self: *Self, path: []const u8) !AssetId {
        const asset_id = try self.asset_manager.loadMesh(path);
        self.asset_manager.addRef(asset_id);

        log(.INFO, "enhanced_scene", "Loaded mesh asset: {s} -> {d}", .{ path, asset_id.toU64() });
        return asset_id;
    }

    /// Create a material with Asset Manager integration
    pub fn createMaterial(self: *Self, albedo_texture_id: AssetId) !AssetId {
        // Use AssetManager to create materials properly
        return try self.asset_manager.createMaterial(albedo_texture_id);
    }

    /// Add a model with Asset Manager workflow
    pub fn addModelWithAssets(self: *Self, model_path: []const u8, texture_path: []const u8) !*GameObject {
        // Load assets through Asset Manager
        const texture_asset_id = try self.loadTexture(texture_path);
        const mesh_asset_id = try self.loadMesh(model_path);
        const material_asset_id = try self.createMaterial(texture_asset_id);

        // Log the asset IDs for debugging
        log(.DEBUG, "enhanced_scene", "Loaded assets: texture={d}, mesh={d}, material={d}", .{ texture_asset_id.toU64(), mesh_asset_id.toU64(), material_asset_id.toU64() });

        // Wait for assets to load
        self.asset_manager.waitForAllLoads();

        // Use legacy loading for GameObject creation (assets are pre-loaded above)
        return try self.addModelWithMaterial(model_path, texture_path);
    }

    // Legacy compatibility methods (unchanged)

    /// Asset Manager texture descriptor updates
    pub fn updateTextureImageInfos(self: *Self) !bool {
        // Get the current texture descriptor array from asset manager
        // Lazy initialization: build descriptor array if dirty flag is set
        const is_dirty = self.asset_manager.texture_descriptors_dirty.load(.acquire);

        if (is_dirty) {
            self.asset_manager.texture_image_infos = self.asset_manager.buildTextureDescriptorArray(self.allocator) catch |err| blk: {
                std.log.err("AssetManager: Failed to build texture descriptor array: {}", .{err});
                break :blk &[_]vk.DescriptorImageInfo{};
            };
            // Clear the dirty flag after successful rebuild
            self.asset_manager.texture_descriptors_dirty.store(false, .release);
        }

        // Notify raytracing system that texture descriptors need to be updated
        if (self.raytracing_system) |rt_system| {
            rt_system.requestTextureDescriptorUpdate();
        }
        return is_dirty;
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
            mesh.geometry.mesh.*.material_id = @intCast(material_id);
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
        log(.WARN, "enhanced_scene", "LEGACY addModelWithMaterialAndTransformAsync called - creating fallback cube for {s}", .{model_path});
        const fallback_model = try FallbackMeshes.createCubeModel(self.allocator, self.gc, "fallback_cube");

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
            mesh_model.geometry.mesh.*.material_id = @intCast(material_id);
        }

        // Create the game object with fallback model
        const obj = try self.addModel(fallback_model, null);
        obj.transform.translate(transform);
        obj.transform.scale(scale);

        // Start async model loading (asset manager will handle completion)
        _ = self.preloadModelAsync(model_path, .high) catch |err| {
            log(.WARN, "enhanced_scene", "Failed to start async model load for {s}: {}", .{ model_path, err });
        };

        log(.INFO, "enhanced_scene", "Created fallback object for: {s} (async loading started)", .{model_path});
        return obj;
    }

    /// Simplified async add: store real asset IDs, use fallbacks at render time
    pub fn addModelAssetAsync(
        self: *Self,
        model_path: []const u8,
        texture_path: []const u8,
        transform: Math.Vec3,
        scale: Math.Vec3,
    ) !*GameObject {
        log(.DEBUG, "enhanced_scene", "addModelAssetAsync: registering assets model={s} texture={s}", .{ model_path, texture_path });

        // Start async loads for real assets (high priority for demo)
        const real_texture_asset = try self.preloadTextureAsync(texture_path);
        const real_model_asset = try self.preloadModelAsync(model_path);
        const real_material_asset = try self.createMaterial(real_texture_asset);

        // Create GameObject with REAL asset IDs - fallbacks will be used automatically at render time
        const obj = try self.addEmpty();
        obj.transform.translate(transform);
        obj.transform.scale(scale);
        obj.model_asset = real_model_asset; // Always store the real asset ID
        obj.material_asset = real_material_asset; // Always store the real asset ID
        obj.texture_asset = real_texture_asset; // Always store the real asset ID
        obj.has_model = true;

        log(.INFO, "enhanced_scene", "addModelAssetAsync created object with REAL asset IDs: model={d}, material={d}, texture={d}", .{ real_model_asset.toU64(), real_material_asset.toU64(), real_texture_asset.toU64() });
        return obj;
    }

    // Async Loading Features

    /// Request a texture to be loaded asynchronously
    pub fn preloadTextureAsync(self: *Self, texture_path: []const u8) !AssetId {
        log(.INFO, "enhanced_scene", "Requesting async texture preload: {s}", .{texture_path});
        return try self.asset_manager.loadTexture(texture_path);
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
        if (self.asset_manager.getTextureIndex(safe_asset_id)) |texture_index| {
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
        return self.asset_manager.getTextureIndexForRendering(texture_index);
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
        try self.asset_manager.registerTextureMapping(asset_id, texture_index);

        // Update cache
        try self.texture_cache.put(path, texture_index);
        _ = self.loading_textures.put(path, false) catch {};

        log(.INFO, "enhanced_scene", "Added async texture at index {d} with AssetId {d} for path: {s}", .{ texture_index, asset_id.toU64(), path });
        return texture_index;
    }

    /// Update texture image infos when new textures are added asynchronously
    /// This must be called from the main thread for Vulkan descriptor updates
    pub fn updateAsyncTextures(self: *Self, allocator: std.mem.Allocator) !void {
        _ = allocator; // Suppress unused parameter warning
        self.texture_mutex.lock();
        defer self.texture_mutex.unlock();

        // DISABLED: Old texture system - now handled by asset manager
        // Only update if texture descriptors are actually dirty
        // if (self.texture_descriptors_dirty and self.textures.items.len > 0) {
        //     try self.updateTextureImageInfos(allocator);
        //     self.texture_descriptors_dirty = false; // Reset the flag
        // }
        std.log.info("updateAsyncTextures: DISABLED - using asset manager instead", .{});
    }

    pub fn updateAsyncResources(self: *Self, allocator: std.mem.Allocator) !bool {
        _ = allocator; // unused since AssetManager handles resource updates
        var textures_updated = false;
        var materials_updated = false;
        const models_updated = false;

        textures_updated = try self.updateTextureImageInfos();
        if (textures_updated) {
            log(.DEBUG, "enhanced_scene", "Updated texture descriptors due to dirty flag", .{});
        }

        // Check if materials are dirty and need updating
        if (self.asset_manager.materials_dirty) {
            log(.DEBUG, "enhanced_scene", "Materials are dirty, creating material buffer", .{});
            try self.asset_manager.createMaterialBuffer(self.gc);
            self.asset_manager.materials_dirty = false;
            materials_updated = true;
        }

        // Model updates are now handled directly by AssetManager

        return textures_updated or materials_updated or models_updated;
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
    pub fn preloadModelAsync(self: *Self, model_path: []const u8) !AssetId {
        log(.INFO, "enhanced_scene", "Requesting async model preload: {s}", .{model_path});
        return try self.asset_manager.loadMesh(model_path);
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
        std.log.info("HOT_RELOAD: About to call updateTextureImageInfos from hot reload callback", .{});
        _ = self.updateTextureImageInfos() catch |err| {
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
                log(.WARN, "enhanced_scene", "Object {d}: No valid model available (asset loading or resolution failed)", .{obj_idx});
            }
        }

        return RasterizationData{
            .objects = renderable_objects[0..obj_count],
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
