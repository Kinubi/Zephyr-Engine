const std = @import("std");
const vk = @import("vulkan");
const AssetManager = @import("../../assets/asset_manager.zig").AssetManager;
const AssetId = @import("../../assets/asset_manager.zig").AssetId;
const Texture = @import("../../assets/asset_manager.zig").Texture;
const World = @import("../../ecs.zig").World;
const Scene = @import("../../scene/scene.zig").Scene;
const log = @import("../../utils/log.zig").log;

/// TextureSystem - Domain manager for texture descriptor arrays
///
/// Responsibilities:
/// - Build texture descriptor array from loaded textures
/// - Provide texture index lookup for MaterialSystem
/// - Rebuild descriptor array when textures load/unload
/// - Track generation for cache invalidation
///
/// This system separates GPU descriptor management from CPU data storage,
/// following the proper layering: AssetManager (CPU) → TextureSystem (GPU descriptors)
///
/// NOTE: Does NOT handle binding - that's ResourceBinder's responsibility.
/// TextureSystem just provides the data via getDescriptorArray().
pub const TextureSystem = struct {
    allocator: std.mem.Allocator,
    asset_manager: *AssetManager,

    descriptor_infos: []vk.DescriptorImageInfo = &[_]vk.DescriptorImageInfo{},
    generation: u32 = 0,
    last_texture_count: usize = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        asset_manager: *AssetManager,
    ) !*TextureSystem {
        const self = try allocator.create(TextureSystem);
        self.* = .{
            .allocator = allocator,
            .asset_manager = asset_manager,
        };

        log(.INFO, "texture_system", "TextureSystem initialized", .{});
        return self;
    }

    /// Check if textures changed and rebuild if needed
    /// Called internally
    fn updateInternal(self: *TextureSystem) !void {
        // Lock textures mutex for thread-safe access
        self.asset_manager.textures_mutex.lock();
        const textures = self.asset_manager.loaded_textures.items;
        const count_changed = textures.len != self.last_texture_count;
        self.asset_manager.textures_mutex.unlock();

        // Rebuild if texture count changed
        if (count_changed or self.asset_manager.texture_descriptors_dirty) {
            if (textures.len > 0) {
                try self.rebuildDescriptorArray();
            } else {
                // No textures - clean up descriptor array
                if (self.descriptor_infos.len > 0) {
                    self.allocator.free(self.descriptor_infos);
                    self.descriptor_infos = &[_]vk.DescriptorImageInfo{};
                    self.last_texture_count = 0;
                }
            }
        }
    }

    /// Rebuild descriptor array from loaded textures
    pub fn rebuildDescriptorArray(self: *TextureSystem) !void {
        // Lock textures mutex for thread-safe access
        self.asset_manager.textures_mutex.lock();
        defer self.asset_manager.textures_mutex.unlock();

        const textures = self.asset_manager.loaded_textures.items;
        if (textures.len == 0) {
            log(.WARN, "texture_system", "No textures loaded, using empty descriptor array", .{});
            return;
        }

        // Free old array
        if (self.descriptor_infos.len > 0) {
            self.allocator.free(self.descriptor_infos);
        }

        // Build new array - we need textures.len slots (no +1 needed)
        // Descriptor array directly mirrors loaded_textures array
        const infos = try self.allocator.alloc(vk.DescriptorImageInfo, textures.len);

        // Copy all texture descriptors 1:1
        for (textures, 0..) |texture, i| {
            infos[i] = texture.getDescriptorInfo();
            log(.DEBUG, "texture_system", "[TRACE] descriptor[{}] = texture imageView={}, sampler={}", .{ i, @intFromEnum(infos[i].image_view), @intFromEnum(infos[i].sampler) });
        }

        self.descriptor_infos = infos;
        self.generation += 1;
        self.last_texture_count = textures.len;
        self.asset_manager.texture_descriptors_dirty = false;

        log(.INFO, "texture_system", "Rebuilt texture descriptors: {} textures (indices 0-{}), generation {}", .{ textures.len, textures.len - 1, self.generation });
    }

    /// Get GPU array index for a texture asset ID
    /// Used by MaterialSystem to resolve texture references
    pub fn getTextureIndex(self: *TextureSystem, asset_id: AssetId) ?u32 {
        const asset_path = if (self.asset_manager.registry.getAsset(asset_id)) |a| a.path else "unknown";

        // Resolve to actual asset (handles fallbacks for loading/missing textures)
        const resolved_id = self.asset_manager.getAssetIdForRendering(asset_id);
        const resolved_path = if (self.asset_manager.registry.getAsset(resolved_id)) |a| a.path else "unknown";

        // Lock textures mutex for thread-safe access
        self.asset_manager.textures_mutex.lock();
        defer self.asset_manager.textures_mutex.unlock();

        // Look up index in asset_to_texture map
        if (self.asset_manager.asset_to_texture.get(resolved_id)) |index| {
            // Descriptor array directly mirrors loaded_textures (1:1 mapping)
            log(.DEBUG, "texture_system", "[TRACE] getTextureIndex: assetId={} (path={s}) -> resolved to {} (path={s}) -> index {}", .{ asset_id.toU64(), asset_path, resolved_id.toU64(), resolved_path, index });
            return @intCast(index);
        }

        // Return 0 (fallback texture) if not found
        log(.DEBUG, "texture_system", "[TRACE] getTextureIndex: assetId={} (path={s}) -> resolved to {} (path={s}) -> NOT FOUND, returning 0", .{ asset_id.toU64(), asset_path, resolved_id.toU64(), resolved_path });
        return 0;
    }

    /// Get the current descriptor array (for legacy code)
    pub fn getDescriptorArray(self: *TextureSystem) []const vk.DescriptorImageInfo {
        return self.descriptor_infos;
    }

    pub fn deinit(self: *TextureSystem) void {
        if (self.descriptor_infos.len > 0) {
            self.allocator.free(self.descriptor_infos);
        }
        log(.INFO, "texture_system", "TextureSystem deinitialized", .{});
        self.allocator.destroy(self);
    }
};

/// Free update function for SystemScheduler compatibility
/// Updates texture descriptor array when textures load/unload
pub fn update(world: *World, dt: f32) !void {
    _ = dt;

    // Get the scene from world userdata
    const scene_ptr = world.getUserData("scene") orelse return;
    const scene: *Scene = @ptrCast(@alignCast(scene_ptr));

    // Get texture system from scene
    if (scene.texture_system) |texture_system| {
        try texture_system.updateInternal();
    }
}
