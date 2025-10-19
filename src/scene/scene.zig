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
const FileWatcher = @import("../utils/file_watcher.zig").FileWatcher;
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

    // Core dependencies
    gc: *GraphicsContext,
    allocator: std.mem.Allocator,

    /// Initialize the Scene
    pub fn init(gc: *GraphicsContext, allocator: std.mem.Allocator, asset_manager: *AssetManager) Scene {
        return Scene{
            .objects = std.ArrayList(GameObject){},
            .next_object_id = 1,
            .asset_manager = asset_manager,
            .gc = gc,
            .allocator = allocator,
        };
    }

    /// Deinitialize the Enhanced Scene
    pub fn deinit(self: *Scene) void {
        log(.INFO, "enhanced_scene", "Deinitializing Enhanced Scene with {} objects", .{self.objects.items.len});

        // Deinit GameObjects
        for (self.objects.items) |object| {
            object.deinit();
        }
        self.objects.deinit(self.allocator);

        log(.INFO, "enhanced_scene", "Enhanced Scene deinit complete", .{});
    }

    /// Convert Enhanced Scene to Scene for compatibility with legacy renderers
    pub fn asScene(self: *Scene) *Scene {
        return @ptrCast(self);
    }

    // === Legacy API Compatibility ===

    pub fn addEmpty(self: *Scene) !*GameObject {
        const object_id = self.next_object_id;
        self.next_object_id += 1;
        try self.objects.append(self.allocator, .{ .id = object_id, .model = null, .point_light = null });
        return &self.objects.items[self.objects.items.len - 1];
    }

    pub fn addObject(self: *Scene, model: ?*Model, point_light: ?PointLightComponent) !*GameObject {
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
        self: *Scene,
        model_path: []const u8,
        texture_path: []const u8,
        position: Math.Vec3,
        rotation: Math.Vec3,
        scale: Math.Vec3,
    ) !*GameObject {
        _ = rotation; // TODO: Use rotation parameter in the future

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
    pub fn createMaterial(self: *Scene, albedo_texture_id: AssetId) !AssetId {
        // For now, we'll create a simple material reference
        // This could be expanded to use the asset manager's material system
        return try self.asset_manager.createMaterial(albedo_texture_id);
    }

    /// Load texture with priority
    pub fn preloadTextureAsync(self: *Scene, texture_path: []const u8) !AssetId {
        return try self.asset_manager.loadAssetAsync(texture_path, .texture, .normal);
    }

    /// Load mesh with priority
    pub fn preloadModelAsync(self: *Scene, mesh_path: []const u8) !AssetId {
        return try self.asset_manager.loadAssetAsync(mesh_path, .mesh, .normal);
    }

    /// Update async resources (required by app.zig) - detects when dirty flags transition to clean
    pub fn updateAsyncResources(self: *Scene, allocator: std.mem.Allocator) !bool {
        _ = allocator; // unused since AssetManager handles resource updates

        // Track dirty states to detect when work completes
        const prev_tex_dirty = self.asset_manager.texture_descriptors_dirty;
        const prev_mat_dirty = self.asset_manager.materials_dirty;
        var work_started = false;

        // Check if texture descriptors need updating and queue async work
        if (self.asset_manager.texture_descriptors_dirty and !self.asset_manager.texture_descriptors_updating.load(.acquire)) {
            try self.asset_manager.queueTextureDescriptorUpdate();
            work_started = true;
        }

        // Check if materials need updating and queue async work
        if (self.asset_manager.materials_dirty and !self.asset_manager.material_buffer_updating.load(.acquire)) {
            try self.asset_manager.queueMaterialBufferUpdate();
            work_started = true;
        }

        // Check current dirty states after potential work completion
        const curr_tex_dirty = self.asset_manager.texture_descriptors_dirty;
        const curr_mat_dirty = self.asset_manager.materials_dirty;

        // Work completed if dirty flag transitions from true to false
        const texture_work_completed = prev_tex_dirty and !curr_tex_dirty;
        const material_work_completed = prev_mat_dirty and !curr_mat_dirty;

        const work_completed = texture_work_completed or material_work_completed;

        return work_started or (self.asset_manager.material_buffer_updating.load(.acquire) or self.asset_manager.texture_descriptors_updating.load(.acquire) == false and work_completed);
    }

    /// Synchronous resource update - waits for all pending async operations to complete
    /// Use this during initialization when you need guaranteed completion before proceeding
    pub fn updateSyncResources(self: *Scene, allocator: std.mem.Allocator) !bool {
        _ = allocator; // unused since AssetManager handles resource updates
        var any_updates = false;

        // Force update texture descriptors if dirty (synchronous)
        if (self.asset_manager.texture_descriptors_dirty) {
            try self.asset_manager.buildTextureDescriptorArray();
            self.asset_manager.texture_descriptors_dirty = false;
            any_updates = true;
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
    pub fn updateTextureImageInfos(self: *Scene) !bool {
        // Enhanced asset manager handles this internally
        const was_dirty = self.asset_manager.texture_descriptors_dirty;

        if (was_dirty) {
            try self.asset_manager.buildTextureDescriptorArray();

            log(.DEBUG, "enhanced_scene", "Updated texture descriptors due to dirty flag", .{});
        }

        return was_dirty;
    }

    /// Enable hot reloading (requires an app-owned FileWatcher)
    pub fn enableHotReload(self: *Scene, watcher: *FileWatcher) !void {
        try self.asset_manager.initHotReload(watcher);
    }

    /// Get texture descriptor array (API compatibility)
    pub fn getTextureDescriptorArray(self: *Scene) []const vk.DescriptorImageInfo {
        return self.asset_manager.texture_image_infos;
    }

    /// Render the scene
    pub fn render(self: Scene, gc: GraphicsContext, cmdbuf: vk.CommandBuffer) !void {
        // Only render ready objects
        for (self.objects.items) |object| {
            try object.render(gc, cmdbuf);
        }
    }

    /// Get scene statistics for debugging
    pub fn getStatistics(self: *Scene) struct {
        objects: usize,
        asset_manager_stats: @TypeOf(self.asset_manager.getStatistics()),
    } {
        return .{
            .objects = self.objects.items.len,
            .asset_manager_stats = self.asset_manager.getStatistics(),
        };
    }
};
