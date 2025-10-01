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

// Enhanced Asset management imports
const EnhancedAssetManager = @import("../assets/enhanced_asset_manager.zig").EnhancedAssetManager;
const AssetId = @import("../assets/asset_manager.zig").AssetId; // Keep existing AssetId for compatibility
const AssetType = @import("../assets/asset_manager.zig").AssetType;
const LoadPriority = @import("../assets/enhanced_asset_manager.zig").LoadPriority;

/// Global mutex for texture loading to prevent zstbi init conflicts
var texture_loading_mutex = std.Thread.Mutex{};

// Re-export Material and Scene for compatibility
pub const Material = @import("scene.zig").Material;
const Scene = @import("scene.zig").Scene;

/// Asset completion callback function type
pub const AssetCompletionCallback = *const fn (asset_id: AssetId, asset_type: AssetType, user_data: ?*anyopaque) void;

/// Enhanced Scene with priority-based Enhanced Asset Manager integration
/// Maintains API compatibility with the original EnhancedScene while using the new asset system
pub const EnhancedScene = struct {
    // Core scene data - only GameObjects with asset references
    objects: std.ArrayList(GameObject),
    next_object_id: u64,

    // Enhanced Asset Manager integration - fully compatible interface
    asset_manager: *EnhancedAssetManager,

    // Raytracing system reference for descriptor updates
    raytracing_system: ?*@import("../systems/raytracing_system.zig").RaytracingSystem,

    // Core dependencies
    gc: *GraphicsContext,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Initialize the Enhanced Scene with Enhanced Asset Manager
    pub fn init(gc: *GraphicsContext, allocator: std.mem.Allocator, asset_manager: *EnhancedAssetManager) Self {
        log(.INFO, "enhanced_scene", "Initializing Enhanced Scene with Enhanced Asset Manager", .{});
        return Self{
            .objects = std.ArrayList(GameObject).init(allocator),
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
        self.objects.deinit();

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
        try self.objects.append(.{ .id = object_id, .model = null, .point_light = null });
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
        scale: Math.Vec3,
    ) !*GameObject {
        log(.DEBUG, "enhanced_scene", "addModelAssetAsync: registering assets model={s} texture={s}", .{ model_path, texture_path });

        // Calculate priority based on position (distance from origin) 
        const distance = Math.length(position);
        const priority = LoadPriority.fromDistance(distance);

        // Start async loads using enhanced asset manager with priority
        log(.INFO, "enhanced_scene", "Requesting async texture preload: {s}", .{texture_path});
        const texture_asset_id = try self.asset_manager.loadAssetAsync(texture_path, .texture, priority);

        log(.INFO, "enhanced_scene", "Requesting async model preload: {s}", .{model_path});
        const model_asset_id = try self.asset_manager.loadAssetAsync(model_path, .mesh, priority);
        
        const material_asset_id = try self.createMaterial(texture_asset_id);

        // Create GameObject with asset IDs - fallbacks will be used automatically at render time
        const obj = try self.addEmpty();
        obj.transform.translate(position);
        obj.transform.scale(scale);
        obj.model_asset = model_asset_id;
        obj.material_asset = material_asset_id;
        obj.texture_asset = texture_asset_id;
        obj.has_model = true;

        log(.INFO, "enhanced_scene", "addModelAssetAsync created object with REAL asset IDs: model={}, material={}, texture={}", 
            .{ model_asset_id, material_asset_id, texture_asset_id });

        return obj;
    }

    /// Create a material with Enhanced Asset Manager integration
    pub fn createMaterial(self: *Self, albedo_texture_id: AssetId) !AssetId {
        _ = self; // Unused for now
        // For now, we'll create a simple material reference
        // This could be expanded to use the asset manager's material system
        return albedo_texture_id; // Simplified - texture ID doubles as material ID
    }

    /// Load texture with priority
    pub fn preloadTextureAsync(self: *Self, texture_path: []const u8) !AssetId {
        return try self.asset_manager.loadAssetAsync(texture_path, .texture, .normal);
    }

    /// Load mesh with priority
    pub fn preloadModelAsync(self: *Self, mesh_path: []const u8) !AssetId {
        return try self.asset_manager.loadAssetAsync(mesh_path, .mesh, .normal);
    }

    /// Update async resources (required by app.zig)
    pub fn updateAsyncResources(self: *Self, allocator: std.mem.Allocator) !bool {
        _ = allocator;
        
        // Update texture descriptors if needed
        if (self.asset_manager.texture_descriptors_dirty.load(.acquire)) {
            try self.asset_manager.buildTextureDescriptorArray();
            
            // Notify raytracing system
            if (self.raytracing_system) |rt_system| {
                rt_system.requestTextureDescriptorUpdate();
            }
        }
        
        // For now, just return false (no pending updates)
        // In a full implementation, this could track pending asset loads
        return false;
    }

    /// Enhanced texture descriptor updates for backward compatibility
    pub fn updateTextureImageInfos(self: *Self) !bool {
        // Enhanced asset manager handles this internally
        const was_dirty = self.asset_manager.texture_descriptors_dirty.load(.acquire);
        
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

// Enhanced Asset management imports
const EnhancedAssetManager = @import("../assets/enhanced_asset_manager.zig").EnhancedAssetManager;
const AssetId = @import("../assets/asset_manager.zig").AssetId; // Keep existing AssetId for compatibility
const AssetType = @import("../assets/asset_manager.zig").AssetType;
const LoadPriority = @import("../assets/enhanced_asset_manager.zig").LoadPriority;

/// Global mutex for texture loading to prevent zstbi init conflicts
var texture_loading_mutex = std.Thread.Mutex{};

// Re-export Material and Scene for compatibility
pub const Material = @import("scene.zig").Material;
const Scene = @import("scene.zig").Scene;

/// Asset completion callback function type
pub const AssetCompletionCallback = *const fn (asset_id: AssetId, asset_type: AssetType, user_data: ?*anyopaque) void;

/// Enhanced Scene with priority-based Enhanced Asset Manager integration
/// Maintains API compatibility with the original EnhancedScene while using the new asset system
pub const EnhancedScene = struct {
    // Core scene data - only GameObjects with asset references
    objects: std.ArrayList(GameObject),
    next_object_id: u64,

    // Enhanced Asset Manager integration - fully compatible interface
    asset_manager: *EnhancedAssetManager,

    // Raytracing system reference for descriptor updates
    raytracing_system: ?*@import("../systems/raytracing_system.zig").RaytracingSystem,

    // Core dependencies
    gc: *GraphicsContext,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Initialize the Enhanced Scene with Enhanced Asset Manager
    pub fn init(gc: *GraphicsContext, allocator: std.mem.Allocator, asset_manager: *EnhancedAssetManager) Self {
        log(.INFO, "enhanced_scene", "Initializing Enhanced Scene with Enhanced Asset Manager", .{});
        return Self{
            .objects = std.ArrayList(GameObject).init(allocator),
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
        self.objects.deinit();

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
        try self.objects.append(.{ .id = object_id, .model = null, .point_light = null });
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
        scale: Math.Vec3,
    ) !*GameObject {
        log(.DEBUG, "enhanced_scene", "addModelAssetAsync: registering assets model={s} texture={s}", .{ model_path, texture_path });

        // Calculate priority based on position (distance from origin) 
        const distance = Math.length(position);
        const priority = LoadPriority.fromDistance(distance);

        // Start async loads using enhanced asset manager with priority
        log(.INFO, "enhanced_scene", "Requesting async texture preload: {s}", .{texture_path});
        const texture_asset_id = try self.asset_manager.loadAssetAsync(texture_path, .texture, priority);

        log(.INFO, "enhanced_scene", "Requesting async model preload: {s}", .{model_path});
        const model_asset_id = try self.asset_manager.loadAssetAsync(model_path, .mesh, priority);
        
        const material_asset_id = try self.createMaterial(texture_asset_id);

        // Create GameObject with asset IDs - fallbacks will be used automatically at render time
        const obj = try self.addEmpty();
        obj.transform.translate(position);
        obj.transform.scale(scale);
        obj.model_asset = model_asset_id;
        obj.material_asset = material_asset_id;
        obj.texture_asset = texture_asset_id;
        obj.has_model = true;

        log(.INFO, "enhanced_scene", "addModelAssetAsync created object with REAL asset IDs: model={}, material={}, texture={}", 
            .{ model_asset_id, material_asset_id, texture_asset_id });

        return obj;
    }

    /// Create a material with Enhanced Asset Manager integration
    pub fn createMaterial(self: *Self, albedo_texture_id: AssetId) !AssetId {
        _ = self; // Unused for now
        // For now, we'll create a simple material reference
        // This could be expanded to use the asset manager's material system
        return albedo_texture_id; // Simplified - texture ID doubles as material ID
    }

    /// Load texture with priority
    pub fn preloadTextureAsync(self: *Self, texture_path: []const u8) !AssetId {
        return try self.asset_manager.loadAssetAsync(texture_path, .texture, .normal);
    }

    /// Load mesh with priority
    pub fn preloadModelAsync(self: *Self, mesh_path: []const u8) !AssetId {
        return try self.asset_manager.loadAssetAsync(mesh_path, .mesh, .normal);
    }

    /// Update async resources (required by app.zig)
    pub fn updateAsyncResources(self: *Self, allocator: std.mem.Allocator) !bool {
        _ = allocator;
        
        // Update texture descriptors if needed
        if (self.asset_manager.texture_descriptors_dirty.load(.acquire)) {
            try self.asset_manager.buildTextureDescriptorArray();
            
            // Notify raytracing system
            if (self.raytracing_system) |rt_system| {
                rt_system.requestTextureDescriptorUpdate();
            }
        }
        
        // For now, just return false (no pending updates)
        // In a full implementation, this could track pending asset loads
        return false;
    }

    /// Enhanced texture descriptor updates for backward compatibility
    pub fn updateTextureImageInfos(self: *Self) !bool {
        // Enhanced asset manager handles this internally
        const was_dirty = self.asset_manager.texture_descriptors_dirty.load(.acquire);
        
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
};
            .material_asset_id = material_asset_id,
            .texture_asset_id = texture_asset_id,
            .transform = .{
                .translation = position,
                .rotation = rotation,
                .scale = scale,
            },
        };

        try self.asset_objects.append(asset_object);
        return &self.asset_objects.items[self.asset_objects.items.len - 1];
    }

    /// Add model with critical priority (for UI and essential objects)
    pub fn addModelAssetCritical(self: *Self, model_path: []const u8, texture_path: []const u8, position: Math.Vec3, rotation: Math.Vec3, scale: Math.Vec3) !*AssetGameObject {
        log(.DEBUG, "enhanced_scene_v2", "addModelAssetCritical: registering assets model={s} texture={s}", .{ model_path, texture_path });

        // Load with critical priority
        const texture_asset_id = try self.asset_manager.loadAssetAsync(texture_path, .texture, .critical);
        const model_asset_id = try self.asset_manager.loadAssetAsync(model_path, .mesh, .critical);
        const material_asset_id = try self.createMaterial(texture_asset_id);

        const object_id = self.next_object_id;
        self.next_object_id += 1;

        const asset_object = AssetGameObject{
            .object_id = object_id,
            .model_asset_id = model_asset_id,
            .material_asset_id = material_asset_id,
            .texture_asset_id = texture_asset_id,
            .transform = .{
                .translation = position,
                .rotation = rotation,
                .scale = scale,
            },
        };

        try self.asset_objects.append(asset_object);
        return &self.asset_objects.items[self.asset_objects.items.len - 1];
    }

    /// Preload assets for future use (low priority)
    pub fn preloadAssets(self: *Self, model_paths: []const []const u8, texture_paths: []const []const u8) !void {
        log(.INFO, "enhanced_scene_v2", "Preloading {} models and {} textures", .{ model_paths.len, texture_paths.len });

        // Preload textures
        for (texture_paths) |texture_path| {
            _ = self.asset_manager.loadAssetAsync(texture_path, .texture, .low) catch |err| {
                log(.WARN, "enhanced_scene_v2", "Failed to preload texture {s}: {}", .{ texture_path, err });
            };
        }

        // Preload models
        for (model_paths) |model_path| {
            _ = self.asset_manager.loadAssetAsync(model_path, .mesh, .low) catch |err| {
                log(.WARN, "enhanced_scene_v2", "Failed to preload model {s}: {}", .{ model_path, err });
            };
        }
    }

    /// Create a material with Enhanced Asset Manager integration
    pub fn createMaterial(self: *Self, albedo_texture_id: AssetId) !AssetId {
        _ = self; // Unused for now
        // For now, we'll create a simple material reference
        // This could be expanded to use the asset manager's material system
        return albedo_texture_id; // Simplified - texture ID doubles as material ID
    }

    /// Load texture with priority
    pub fn loadTexture(self: *Self, texture_path: []const u8, priority: LoadPriority) !AssetId {
        return try self.asset_manager.loadAssetAsync(texture_path, .texture, priority);
    }

    /// Load mesh with priority
    pub fn loadMesh(self: *Self, mesh_path: []const u8, priority: LoadPriority) !AssetId {
        return try self.asset_manager.loadAssetAsync(mesh_path, .mesh, priority);
    }

    // === Rendering and Updates ===

    /// Legacy texture descriptor updates for backward compatibility
    pub fn updateTextureImageInfos(self: *Self) !bool {
        // Enhanced asset manager handles this internally
        const was_dirty = self.asset_manager.texture_descriptors_dirty.load(.acquire);
        
        if (was_dirty) {
            try self.asset_manager.buildTextureDescriptorArray();
            
            // Notify raytracing system
            if (self.raytracing_system) |rt_system| {
                rt_system.requestTextureDescriptorUpdate();
            }
            
            log(.DEBUG, "enhanced_scene_v2", "Updated texture descriptors due to dirty flag", .{});
        }
        
        return was_dirty;
    }

    /// Register raytracing system for texture updates
    pub fn setRaytracingSystem(self: *Self, rt_system: *@import("../systems/raytracing_system.zig").RaytracingSystem) void {
        self.raytracing_system = rt_system;
        log(.DEBUG, "enhanced_scene_v2", "Raytracing system registered for texture updates", .{});
    }

    /// Get scene statistics
    pub fn getStatistics(self: *Self) struct {
        ready_objects: usize,
        pending_objects: usize,
        total_objects: usize,
        asset_manager_stats: @TypeOf(self.asset_manager.getStatistics()),
    } {
        const asset_stats = self.asset_manager.getStatistics();
        return .{
            .ready_objects = self.objects.items.len,
            .pending_objects = self.asset_objects.items.len,
            .total_objects = self.objects.items.len + self.asset_objects.items.len,
            .asset_manager_stats = asset_stats,
        };
    }

    /// Render the scene
    pub fn render(self: Self, gc: GraphicsContext, cmdbuf: vk.CommandBuffer) !void {
        // Only render ready objects
        for (self.objects.items) |object| {
            try object.render(gc, cmdbuf);
        }
    }

    // === Hot Reload Support ===

    /// Enable hot reloading for scene assets
    pub fn enableHotReload(self: *Self) !void {
        // Initialize hot reloading through asset manager
        try self.asset_manager.initHotReload();
        
        // Register all currently loaded assets for hot reloading
        for (self.asset_objects.items) |asset_object| {
            if (asset_object.texture_asset_id) |texture_id| {
                // We'd need the file path to register - this is a limitation of the current design
                // In a full implementation, we'd store file paths in AssetGameObject
                _ = texture_id;
            }
            if (asset_object.model_asset_id) |model_id| {
                _ = model_id;
            }
        }
        
        log(.INFO, "enhanced_scene_v2", "Hot reloading enabled for scene assets", .{});
    }

    /// Check if scene has pending asset loads
    pub fn hasPendingAssets(self: *const Self) bool {
        return self.asset_objects.items.len > 0;
    }

    /// Wait for all scene assets to load
    pub fn waitForAssets(self: *Self, timeout_ms: u64) !bool {
        const start_time = std.time.milliTimestamp();
        
        while (self.hasPendingAssets()) {
            if (std.time.milliTimestamp() - start_time > timeout_ms) {
                return false; // Timeout
            }
            
            try self.update(0); // Process asset updates
            std.time.sleep(10_000_000); // 10ms
        }
        
        return true; // All assets loaded
    }

    /// Get ready objects count for UI/debugging
    pub fn getReadyObjectCount(self: *const Self) usize {
        return self.objects.items.len;
    }

    /// Get pending objects count for UI/debugging  
    pub fn getPendingObjectCount(self: *const Self) usize {
        return self.asset_objects.items.len;
    }
};