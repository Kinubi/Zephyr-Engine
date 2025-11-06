const std = @import("std");
const vk = @import("vulkan");
const buffer_manager_module = @import("../../rendering/buffer_manager.zig");
const BufferManager = buffer_manager_module.BufferManager;
const ManagedBuffer = buffer_manager_module.ManagedBuffer;
const Buffer = @import("../../core/buffer.zig").Buffer;
const AssetManager = @import("../../assets/asset_manager.zig").AssetManager;
const Material = @import("../../assets/asset_manager.zig").Material;
const texture_system_module = @import("texture_system.zig");
const TextureSystem = texture_system_module.TextureSystem;
const TextureSet = texture_system_module.TextureSet;
const AssetId = @import("../../assets/asset_manager.zig").AssetId;
const World = @import("../../ecs.zig").World;
const Scene = @import("../../scene/scene.zig").Scene;
const log = @import("../../utils/log.zig").log;

const MAX_FRAMES_IN_FLIGHT = @import("../../core/swapchain.zig").MAX_FRAMES_IN_FLIGHT;

/// Material buffer set - manages a named collection of materials
pub const MaterialBufferSet = struct {
    allocator: std.mem.Allocator,
    buffer: ManagedBuffer,
    material_ids: std.ArrayList(AssetId), // Which materials belong to this set
    texture_set: *TextureSet, // Which texture set to use for lookups
    last_texture_generation: u32 = 0,

    fn init(allocator: std.mem.Allocator, name: []const u8, texture_set: *TextureSet) MaterialBufferSet {
        return .{
            .allocator = allocator,
            .buffer = .{
                .buffer = undefined,
                .name = name,
                .size = 0,
                .generation = 0,
                .strategy = .device_local,
                .created_frame = 0,
            },
            .material_ids = std.ArrayList(AssetId){},
            .texture_set = texture_set,
        };
    }

    fn deinit(self: *MaterialBufferSet) void {
        self.material_ids.deinit(self.allocator);
    }

    /// Get the managed texture array for this material set
    pub fn getManagedTextures(self: *const MaterialBufferSet) *const texture_system_module.ManagedTextureArray {
        return &self.texture_set.managed_textures;
    }
};

/// MaterialSystem - Domain manager for material GPU buffers
///
/// Responsibilities:
/// - Create and manage multiple named material SSBOs via BufferManager
/// - Read material data from AssetManager (read-only)
/// - Rebuild buffers when materials change
/// - Support multiple material sets (e.g., "opaque", "transparent", "ui")
/// - Bind via ResourceBinder with named bindings
///
/// This system separates GPU resource management from CPU data storage,
/// following the proper layering: AssetManager (CPU) → MaterialSystem (GPU)
pub const MaterialSystem = struct {
    allocator: std.mem.Allocator,
    buffer_manager: *BufferManager,
    asset_manager: *AssetManager,
    texture_system: ?*TextureSystem = null,

    material_sets: std.StringHashMap(MaterialBufferSet),

    pub fn init(
        allocator: std.mem.Allocator,
        buffer_manager: *BufferManager,
        asset_manager: *AssetManager,
    ) !*MaterialSystem {
        const self = try allocator.create(MaterialSystem);
        self.* = .{
            .allocator = allocator,
            .buffer_manager = buffer_manager,
            .asset_manager = asset_manager,
            .material_sets = std.StringHashMap(MaterialBufferSet).init(allocator),
        };

        log(.INFO, "material_system", "MaterialSystem initialized with named buffer sets", .{});
        return self;
    }

    /// Set the texture system reference (called after both systems are initialized)
    pub fn setTextureSystem(self: *MaterialSystem, texture_system: *TextureSystem) void {
        self.texture_system = texture_system;
    }

    /// Create a named material buffer set linked to a texture set
    pub fn createSet(self: *MaterialSystem, name: []const u8, texture_set: *TextureSet) !*MaterialBufferSet {
        const result = try self.material_sets.getOrPut(name);
        if (result.found_existing) {
            log(.WARN, "material_system", "Material set '{s}' already exists", .{name});
            return result.value_ptr;
        }

        // Duplicate the name for storage
        const owned_name = try self.allocator.dupe(u8, name);
        result.value_ptr.* = MaterialBufferSet.init(self.allocator, owned_name, texture_set);
        log(.INFO, "material_system", "Created material set '{s}' linked to texture set '{s}'", .{ name, texture_set.name });

        return result.value_ptr;
    }

    /// Get a material set by name (returns null if doesn't exist)
    pub fn getSet(self: *MaterialSystem, name: []const u8) ?*MaterialBufferSet {
        return self.material_sets.getPtr(name);
    }

    /// Add a material to a named set
    /// Automatically adds the material's textures to the linked texture set
    pub fn addMaterialToSet(self: *MaterialSystem, set_name: []const u8, material_id: AssetId) !void {
        const set = self.getSet(set_name) orelse return error.MaterialSetNotFound;

        // Check if material already in set
        for (set.material_ids.items) |id| {
            if (id.toU64() == material_id.toU64()) {
                return; // Already added
            }
        }

        try set.material_ids.append(self.allocator, material_id);
        log(.DEBUG, "material_system", "Added material {} to set '{s}' (now {} materials)", .{ material_id.toU64(), set_name, set.material_ids.items.len });

        // Automatically add material's textures to the linked texture set
        if (self.texture_system) |texture_system| {
            // Find the material in AssetManager by index
            if (self.asset_manager.getMaterialIndex(material_id)) |mat_index| {
                if (mat_index < self.asset_manager.loaded_materials.items.len) {
                    const material_ptr = self.asset_manager.loaded_materials.items[mat_index];
                    
                    // Add albedo texture if present
                    if (material_ptr.albedo_texture_id != 0) {
                        const albedo_id = AssetId.fromU64(@as(u64, @intCast(material_ptr.albedo_texture_id)));
                        try texture_system.addTextureToSet(set.texture_set.name, albedo_id);
                    }

                    // Add roughness texture if present
                    if (material_ptr.roughness_texture_id != 0) {
                        const roughness_id = AssetId.fromU64(@as(u64, @intCast(material_ptr.roughness_texture_id)));
                        try texture_system.addTextureToSet(set.texture_set.name, roughness_id);
                    }
                }
            }
        }
    }

    /// Remove a material from a named set
    pub fn removeMaterialFromSet(self: *MaterialSystem, set_name: []const u8, material_id: AssetId) void {
        const set = self.getSet(set_name) orelse return;

        for (set.material_ids.items, 0..) |id, i| {
            if (id.toU64() == material_id.toU64()) {
                _ = set.material_ids.swapRemove(i);
                log(.DEBUG, "material_system", "Removed material {} from set '{s}' ({} remaining)", .{ material_id.toU64(), set_name, set.material_ids.items.len });
                return;
            }
        }
    }

    /// Clear all materials from a named set
    pub fn clearSet(self: *MaterialSystem, set_name: []const u8) void {
        if (self.getSet(set_name)) |set| {
            set.material_ids.clearRetainingCapacity();
            log(.INFO, "material_system", "Cleared material set '{s}'", .{set_name});
        }
    }

    /// Check if materials changed and rebuild if needed
    /// Called internally with frame_index
    fn updateInternal(self: *MaterialSystem, frame_index: u32) !void {
        const materials_dirty = self.asset_manager.materials_dirty;

        // Auto-populate "default" set with all loaded materials if it exists and is empty
        if (materials_dirty) {
            if (self.getSet("default")) |default_set| {
                if (default_set.material_ids.items.len == 0 and self.asset_manager.loaded_materials.items.len > 0) {
                    log(.INFO, "material_system", "Auto-populating default material set with {} materials", .{self.asset_manager.loaded_materials.items.len});

                    // Get material IDs from asset_to_material map
                    var mat_it = self.asset_manager.asset_to_material.iterator();
                    while (mat_it.next()) |mat_entry| {
                        const material_id = mat_entry.key_ptr.*;
                        try self.addMaterialToSet("default", material_id);
                    }
                }
            }
        }

        // Rebuild each material set if dirty
        var it = self.material_sets.iterator();
        while (it.next()) |entry| {
            const set_name = entry.key_ptr.*;
            var set = entry.value_ptr;

            // Check if linked texture set has changed
            const texture_gen_changed = set.texture_set.managed_textures.generation != set.last_texture_generation;

            if (materials_dirty or texture_gen_changed) {
                if (set.material_ids.items.len > 0) {
                    try self.rebuildMaterialSet(set_name, frame_index);
                    set.last_texture_generation = set.texture_set.managed_textures.generation;
                } else {
                    // No materials in set - reset to generation 0 if buffer was created
                    if (set.buffer.generation > 0) {
                        try self.buffer_manager.destroyBuffer(set.buffer);
                        set.buffer.generation = 0;
                    }
                }
            }
        }

        // Clear the global dirty flag since we've rebuilt all sets
        if (materials_dirty) {
            self.asset_manager.materials_dirty = false;
        }
    }

    /// Rebuild a specific material set from AssetManager data
    /// Resolves texture IDs and uploads to GPU via BufferManager
    pub fn rebuildMaterialSet(
        self: *MaterialSystem,
        set_name: []const u8,
        frame_index: u32,
    ) !void {
        var set = self.getSet(set_name) orelse return error.MaterialSetNotFound;
        if (set.material_ids.items.len == 0) return;

        // Gather materials from AssetManager that belong to this set
        var material_data = try self.allocator.alloc(Material, set.material_ids.items.len);
        defer self.allocator.free(material_data);

        for (set.material_ids.items, 0..) |material_id, i| {
            // Find material in AssetManager's loaded materials by index
            if (self.asset_manager.getMaterialIndex(material_id)) |mat_index| {
                if (mat_index < self.asset_manager.loaded_materials.items.len) {
                    // Copy the material
                    material_data[i] = self.asset_manager.loaded_materials.items[mat_index].*;
                } else {
                    log(.WARN, "material_system", "Material index {} out of bounds for set '{s}'", .{ mat_index, set_name });
                    material_data[i] = std.mem.zeroes(Material);
                    continue;
                }
            } else {
                log(.WARN, "material_system", "Material {} not found in AssetManager for set '{s}'", .{ material_id.toU64(), set_name });
                // Use a default/empty material as fallback
                material_data[i] = std.mem.zeroes(Material);
                continue;
            }

            // Resolve texture indices via TextureSystem using the linked texture set
            // Note: material_data[i] already has the copied material data
            if (self.texture_system) |texture_system| {
                // Resolve albedo texture (0 = no texture, use solid color)
                if (material_data[i].albedo_texture_id != 0) {
                    const albedo_asset_id = AssetId.fromU64(@as(u64, @intCast(material_data[i].albedo_texture_id)));
                    const albedo_index = texture_system.getTextureIndexInSet(set.texture_set.name, albedo_asset_id) orelse 0;
                    material_data[i].albedo_texture_id = albedo_index;
                } else {
                    material_data[i].albedo_texture_id = 0;
                }

                // Resolve roughness texture (0 = no texture, use roughness value)
                if (material_data[i].roughness_texture_id != 0) {
                    const roughness_asset_id = AssetId.fromU64(@as(u64, @intCast(material_data[i].roughness_texture_id)));
                    const roughness_index = texture_system.getTextureIndexInSet(set.texture_set.name, roughness_asset_id) orelse 0;
                    material_data[i].roughness_texture_id = roughness_index;
                } else {
                    material_data[i].roughness_texture_id = 0;
                }
            } else {
                // Fallback path without TextureSystem (direct asset manager lookup)
                if (material_data[i].albedo_texture_id != 0) {
                    const albedo_asset_id = AssetId.fromU64(@as(u64, @intCast(material_data[i].albedo_texture_id)));
                    const resolved_albedo_id = self.asset_manager.getAssetIdForRendering(albedo_asset_id);
                    const albedo_index = self.asset_manager.asset_to_texture.get(resolved_albedo_id) orelse 0;
                    material_data[i].albedo_texture_id = @as(u32, @intCast(albedo_index));
                } else {
                    material_data[i].albedo_texture_id = 0;
                }

                if (material_data[i].roughness_texture_id != 0) {
                    const roughness_asset_id = AssetId.fromU64(@as(u64, @intCast(material_data[i].roughness_texture_id)));
                    const resolved_roughness_id = self.asset_manager.getAssetIdForRendering(roughness_asset_id);
                    const roughness_index = self.asset_manager.asset_to_texture.get(resolved_roughness_id) orelse 0;
                    material_data[i].roughness_texture_id = @as(u32, @intCast(roughness_index));
                } else {
                    material_data[i].roughness_texture_id = 0;
                }
            }
        }

        const data_bytes = std.mem.sliceAsBytes(material_data);

        // Check if buffer exists (generation > 0 means it's been created)
        if (set.buffer.generation > 0) {
            // Buffer exists - check if size changed
            if (set.buffer.size != data_bytes.len) {
                log(.INFO, "material_system", "Material buffer '{s}' size changed ({} -> {} bytes), resizing", .{
                    set_name,
                    set.buffer.size,
                    data_bytes.len,
                });

                // Destroy the old Vulkan buffer
                set.buffer.buffer.deinit();

                // Create new Vulkan buffer with new size
                set.buffer.buffer = try Buffer.initNamed(
                    self.buffer_manager.graphics_context,
                    data_bytes.len,
                    1,
                    .{ .storage_buffer_bit = true, .transfer_dst_bit = true },
                    .{ .device_local_bit = true },
                    set.buffer.name,
                );

                // Update the size field
                set.buffer.size = data_bytes.len;

                // Upload the data (this will increment generation)
                try self.buffer_manager.updateBuffer(&set.buffer, data_bytes, frame_index);
            } else {
                // Same size - just update the data (this increments generation)
                try self.buffer_manager.updateBuffer(&set.buffer, data_bytes, frame_index);
            }
        } else {
            // First time - create the buffer (generation will go 0 → 1)
            const buffer_config = buffer_manager_module.BufferConfig{
                .name = set.buffer.name,
                .size = data_bytes.len,
                .strategy = .device_local,
                .usage = .{ .storage_buffer_bit = true, .transfer_dst_bit = true },
            };

            set.buffer = try self.buffer_manager.createBuffer(buffer_config, frame_index);
            try self.buffer_manager.updateBuffer(&set.buffer, data_bytes, frame_index);
        }

        log(.INFO, "material_system", "Rebuilt material set '{s}': {} materials, generation {}", .{
            set_name,
            set.material_ids.items.len,
            set.buffer.generation,
        });
    }

    /// Get material buffer for a specific set
    /// Returns pointer to ManagedBuffer (generation=0 if not created yet)
    pub fn getBuffer(self: *MaterialSystem, set_name: []const u8) ?*const ManagedBuffer {
        const set = self.getSet(set_name) orelse return null;
        return &set.buffer;
    }

    /// Get managed texture array for a specific material set
    /// Returns the ManagedTextureArray from the linked texture set (for generation tracking)
    pub fn getManagedTextures(self: *MaterialSystem, set_name: []const u8) ?*const texture_system_module.ManagedTextureArray {
        const set = self.getSet(set_name) orelse return null;
        return set.getManagedTextures();
    }

    pub fn deinit(self: *MaterialSystem) void {
        // Destroy all material set buffers
        var it = self.material_sets.iterator();
        while (it.next()) |entry| {
            var set = entry.value_ptr;

            // Destroy buffer if it was created (generation > 0)
            if (set.buffer.generation > 0) {
                self.buffer_manager.destroyBuffer(set.buffer) catch |err| {
                    log(.WARN, "material_system", "Failed to destroy material buffer '{s}' on deinit: {}", .{ set.buffer.name, err });
                };
            }

            // Free the owned name
            self.allocator.free(set.buffer.name);

            // Clean up material IDs
            set.deinit();
        }

        self.material_sets.deinit();
        self.allocator.destroy(self);
        log(.INFO, "material_system", "MaterialSystem deinitialized", .{});
    }
};

/// Free update function for SystemScheduler compatibility
/// Updates material buffer when materials change
pub fn update(world: *World, dt: f32) !void {
    _ = dt;

    // Get the scene from world userdata
    const scene_ptr = world.getUserData("scene") orelse return;
    const scene: *Scene = @ptrCast(@alignCast(scene_ptr));

    // Get material system from scene
    if (scene.material_system) |material_system| {
        // Frame index doesn't matter for deferred destruction - using 0
        try material_system.updateInternal(0);
    }
}
