const std = @import("std");
const vk = @import("vulkan");
const AssetManager = @import("../../assets/asset_manager.zig").AssetManager;
const AssetId = @import("../../assets/asset_manager.zig").AssetId;
const Texture = @import("../../assets/asset_manager.zig").Texture;
const World = @import("../../ecs.zig").World;
const Scene = @import("../../scene/scene.zig").Scene;
const log = @import("../../utils/log.zig").log;

/// Managed texture array - descriptor array with generation tracking
pub const ManagedTextureArray = struct {
    name: []const u8,
    descriptor_infos: []vk.DescriptorImageInfo = &[_]vk.DescriptorImageInfo{},
    generation: u32 = 0,
    size: usize = 0,
    created_frame: u32 = 0,
};

/// Texture set - manages a named collection of textures with descriptor array
pub const TextureSet = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    texture_ids: std.ArrayList(AssetId), // Which textures belong to this set
    managed_textures: ManagedTextureArray, // Descriptor array with generation tracking

    fn init(allocator: std.mem.Allocator, name: []const u8) TextureSet {
        return .{
            .allocator = allocator,
            .name = name,
            .texture_ids = std.ArrayList(AssetId){},
            .managed_textures = .{
                .name = name,
                .generation = 0,
                .size = 0,
                .created_frame = 0,
            },
        };
    }

    fn deinit(self: *TextureSet) void {
        if (self.managed_textures.descriptor_infos.len > 0) {
            self.allocator.free(self.managed_textures.descriptor_infos);
        }
        self.texture_ids.deinit(self.allocator);
    }
};

/// TextureSystem - Domain manager for texture descriptor arrays
///
/// Responsibilities:
/// - Manage multiple named texture sets (descriptor arrays)
/// - Build texture descriptor arrays from loaded textures
/// - Provide texture index lookup for MaterialSystem per set
/// - Rebuild descriptor arrays when textures load/unload
/// - Track generation per set for cache invalidation
///
/// This system separates GPU descriptor management from CPU data storage,
/// following the proper layering: AssetManager (CPU) → TextureSystem (GPU descriptors)
///
/// NOTE: Does NOT handle binding - that's ResourceBinder's responsibility.
/// TextureSystem just provides the data via getDescriptorArray().
pub const TextureSystem = struct {
    allocator: std.mem.Allocator,
    asset_manager: *AssetManager,

    texture_sets: std.StringHashMap(TextureSet),

    pub fn init(
        allocator: std.mem.Allocator,
        asset_manager: *AssetManager,
    ) !*TextureSystem {
        const self = try allocator.create(TextureSystem);
        self.* = .{
            .allocator = allocator,
            .asset_manager = asset_manager,
            .texture_sets = std.StringHashMap(TextureSet).init(allocator),
        };

        log(.INFO, "texture_system", "TextureSystem initialized with named texture sets", .{});
        return self;
    }

    /// Create or get a named texture set
    pub fn createSet(self: *TextureSystem, name: []const u8) !*TextureSet {
        const result = try self.texture_sets.getOrPut(name);
        if (!result.found_existing) {
            // Duplicate the name for storage
            const owned_name = try self.allocator.dupe(u8, name);
            result.value_ptr.* = TextureSet.init(self.allocator, owned_name);
            log(.INFO, "texture_system", "Created texture set '{s}'", .{name});
        }
        return result.value_ptr;
    }

    /// Get a texture set by name (returns null if doesn't exist)
    pub fn getSet(self: *TextureSystem, name: []const u8) ?*TextureSet {
        return self.texture_sets.getPtr(name);
    }

    /// Add a texture to a named set
    pub fn addTextureToSet(self: *TextureSystem, set_name: []const u8, texture_id: AssetId) !void {
        const set = try self.createSet(set_name);

        // Check if texture already in set
        for (set.texture_ids.items) |id| {
            if (id.toU64() == texture_id.toU64()) {
                return; // Already added
            }
        }

        try set.texture_ids.append(set.allocator, texture_id);
        log(.DEBUG, "texture_system", "Added texture {} to set '{s}' (now {} textures)", .{ texture_id.toU64(), set_name, set.texture_ids.items.len });
    }

    /// Remove a texture from a named set
    pub fn removeTextureFromSet(self: *TextureSystem, set_name: []const u8, texture_id: AssetId) void {
        const set = self.getSet(set_name) orelse return;

        for (set.texture_ids.items, 0..) |id, i| {
            if (id.toU64() == texture_id.toU64()) {
                _ = set.texture_ids.swapRemove(i);
                log(.DEBUG, "texture_system", "Removed texture {} from set '{s}' ({} remaining)", .{ texture_id.toU64(), set_name, set.texture_ids.items.len });
                return;
            }
        }
    }

    /// Get texture index within a specific set
    /// Returns the index in that set's descriptor array
    pub fn getTextureIndexInSet(self: *TextureSystem, set_name: []const u8, texture_id: AssetId) ?u32 {
        const set = self.getSet(set_name) orelse return null;

        // Find the index of this texture in the set's texture list
        // Note: descriptor array has white dummy at index 0, so real textures are at indices 1..N
        for (set.texture_ids.items, 0..) |id, i| {
            if (id.toU64() == texture_id.toU64()) {
                return @intCast(i + 1); // +1 because index 0 is the white dummy
            }
        }

        return null; // Texture not in this set
    }

    /// Rebuild descriptor array for a specific texture set
    pub fn rebuildTextureSet(self: *TextureSystem, set_name: []const u8) !void {
        var set = self.getSet(set_name) orelse return error.TextureSetNotFound;

        if (set.texture_ids.items.len == 0) {
            log(.WARN, "texture_system", "Texture set '{s}' has no textures", .{set_name});
            return;
        }

        // Lock textures for thread-safe access
        self.asset_manager.textures_mutex.lock();
        defer self.asset_manager.textures_mutex.unlock();

        // First pass: Check if ALL textures are loaded
        var all_loaded = true;
        for (set.texture_ids.items) |texture_id| {
            if (self.asset_manager.asset_to_texture.get(texture_id)) |tex_index| {
                if (tex_index >= self.asset_manager.loaded_textures.items.len) {
                    all_loaded = false;
                    break;
                }
            } else {
                // Texture not loaded yet
                all_loaded = false;
                break;
            }
        }

        if (!all_loaded) {
            log(.DEBUG, "texture_system", "Texture set '{s}' has unloaded textures, skipping rebuild", .{set_name});
            return; // Don't rebuild until all textures are loaded
        }

        // Free old descriptor array
        if (set.managed_textures.descriptor_infos.len > 0) {
            self.allocator.free(set.managed_textures.descriptor_infos);
        }

        // Build new descriptor array for this set
        // Index 0 is ALWAYS the white dummy texture (loaded_textures[0])
        // Indices 1..N are the textures in texture_ids
        const infos = try self.allocator.alloc(vk.DescriptorImageInfo, set.texture_ids.items.len + 1);

        // Index 0: White dummy texture (reserved for "no texture" - texture ID 0)
        if (self.asset_manager.loaded_textures.items.len > 0) {
            infos[0] = self.asset_manager.loaded_textures.items[0].getDescriptorInfo();
        } else {
            log(.ERROR, "texture_system", "No white dummy texture at loaded_textures[0]!", .{});
            infos[0] = std.mem.zeroes(vk.DescriptorImageInfo);
        }

        // Indices 1..N: User textures from texture_ids
        for (set.texture_ids.items, 0..) |texture_id, i| {
            // We already checked all textures exist, so this should always succeed
            if (self.asset_manager.asset_to_texture.get(texture_id)) |tex_index| {
                infos[i + 1] = self.asset_manager.loaded_textures.items[tex_index].getDescriptorInfo();
            } else {
                // This shouldn't happen after our check, but handle it gracefully
                log(.ERROR, "texture_system", "Texture {} disappeared during rebuild of set '{s}'", .{ texture_id.toU64(), set_name });
                infos[i + 1] = std.mem.zeroes(vk.DescriptorImageInfo);
            }
        }

        set.managed_textures.descriptor_infos = infos;
        set.managed_textures.generation += 1;
        set.managed_textures.size = infos.len * @sizeOf(vk.DescriptorImageInfo);

        log(.INFO, "texture_system", "Rebuilt texture set '{s}': {} textures (index 0 = white dummy, indices 1-{}), generation {}", .{
            set_name,
            set.texture_ids.items.len,
            set.texture_ids.items.len,
            set.managed_textures.generation,
        });

        // Debug: Log texture IDs in this set
        log(.DEBUG, "texture_system", "Texture set '{s}' contents:", .{set_name});
        log(.DEBUG, "texture_system", "  [0] White dummy (reserved)", .{});
        for (set.texture_ids.items, 0..) |tex_id, idx| {
            log(.DEBUG, "texture_system", "  [{}] AssetId: {}", .{ idx + 1, tex_id.toU64() });
        }
    }

    /// Get descriptor array for a specific texture set
    pub fn getDescriptorArrayForSet(self: *TextureSystem, set_name: []const u8) ?[]const vk.DescriptorImageInfo {
        const set = self.getSet(set_name) orelse return null;
        return set.managed_textures.descriptor_infos;
    }

    /// Get managed texture array for a specific texture set
    pub fn getManagedTextures(self: *TextureSystem, set_name: []const u8) ?*const ManagedTextureArray {
        const set = self.getSet(set_name) orelse return null;
        return &set.managed_textures;
    }

    /// Check if textures changed and rebuild if needed
    /// Called internally - rebuilds all texture sets if dirty
    fn updateInternal(self: *TextureSystem) !void {
        // Check if textures are marked dirty
        if (self.asset_manager.texture_descriptors_dirty) {
            // Rebuild all texture sets
            var it = self.texture_sets.iterator();
            while (it.next()) |entry| {
                const set_name = entry.key_ptr.*;
                if (entry.value_ptr.texture_ids.items.len > 0) {
                    try self.rebuildTextureSet(set_name);
                }
            }

            // Clear dirty flag
            self.asset_manager.texture_descriptors_dirty = false;
        }
    }

    /// Get GPU array index for a texture asset ID (legacy method)
    /// Used by MaterialSystem to resolve texture references
    /// NOTE: This is for backwards compatibility - prefer getTextureIndexInSet()
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

    pub fn deinit(self: *TextureSystem) void {
        // Clean up all texture sets
        var it = self.texture_sets.iterator();
        while (it.next()) |entry| {
            var set = entry.value_ptr;

            // Free the owned name
            self.allocator.free(set.name);

            // Clean up the set
            set.deinit();
        }

        self.texture_sets.deinit();
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
