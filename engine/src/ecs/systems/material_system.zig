const std = @import("std");
const vk = @import("vulkan");
const buffer_manager_module = @import("../../rendering/buffer_manager.zig");
const BufferManager = buffer_manager_module.BufferManager;
const ManagedBuffer = buffer_manager_module.ManagedBuffer;
const AssetManager = @import("../../assets/asset_manager.zig").AssetManager;
const Material = @import("../../assets/asset_manager.zig").Material;
const TextureSystem = @import("texture_system.zig").TextureSystem;
const AssetId = @import("../../assets/asset_manager.zig").AssetId;
const World = @import("../../ecs.zig").World;
const Scene = @import("../../scene/scene.zig").Scene;
const log = @import("../../utils/log.zig").log;

const MAX_FRAMES_IN_FLIGHT = @import("../../core/swapchain.zig").MAX_FRAMES_IN_FLIGHT;

/// MaterialSystem - Domain manager for material GPU buffers
///
/// Responsibilities:
/// - Create and manage material SSBO via BufferManager
/// - Read material data from AssetManager (read-only)
/// - Rebuild buffer when materials change
/// - Bind via ResourceBinder with named binding "MaterialBuffer"
///
/// This system separates GPU resource management from CPU data storage,
/// following the proper layering: AssetManager (CPU) → MaterialSystem (GPU)
pub const MaterialSystem = struct {
    allocator: std.mem.Allocator,
    buffer_manager: *BufferManager,
    asset_manager: *AssetManager,
    texture_system: ?*TextureSystem = null,

    current_buffer: ?ManagedBuffer = null,
    generation: u32 = 0,
    last_material_count: usize = 0,
    last_texture_generation: u32 = 0,

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
        };

        log(.INFO, "material_system", "MaterialSystem initialized", .{});
        return self;
    }

    /// Set the texture system reference (called after both systems are initialized)
    pub fn setTextureSystem(self: *MaterialSystem, texture_system: *TextureSystem) void {
        self.texture_system = texture_system;
    }

    /// Check if materials changed and rebuild if needed
    /// Called internally with frame_index
    fn updateInternal(self: *MaterialSystem, frame_index: u32) !void {
        const materials = self.asset_manager.loaded_materials.items;

        // Check if material count changed OR materials are marked dirty (texture changes, etc.)
        const count_changed = materials.len != self.last_material_count;
        const materials_dirty = self.asset_manager.materials_dirty;

        // Also check if TextureSystem has new textures (generation changed)
        const texture_gen_changed = if (self.texture_system) |ts|
            ts.generation != self.last_texture_generation
        else
            false;

        if (count_changed or materials_dirty or texture_gen_changed) {
            if (materials.len > 0) {
                try self.rebuildMaterialBuffer(frame_index);
                // Clear the dirty flag since we've rebuilt
                self.asset_manager.materials_dirty = false;
                // Track texture generation
                if (self.texture_system) |ts| {
                    self.last_texture_generation = ts.generation;
                }
            } else {
                // No materials - clean up buffer
                if (self.current_buffer) |buffer| {
                    try self.buffer_manager.destroyBuffer(buffer);
                    self.current_buffer = null;
                    self.last_material_count = 0;
                }
            }
        }
    }

    /// Rebuild material buffer from AssetManager data
    /// Resolves texture IDs and uploads to GPU via BufferManager
    pub fn rebuildMaterialBuffer(
        self: *MaterialSystem,
        frame_index: u32,
    ) !void {
        const materials = self.asset_manager.loaded_materials.items;
        if (materials.len == 0) return;

        // Convert material pointers to material data with resolved texture indices
        var material_data = try self.allocator.alloc(Material, materials.len);
        defer self.allocator.free(material_data);

        for (materials, 0..) |material_ptr, i| {
            // Copy the base material
            material_data[i] = material_ptr.*;

            // Resolve texture indices via TextureSystem (if available)
            if (self.texture_system) |texture_system| {
                // Resolve albedo texture (0 = no texture, use solid color)
                if (material_ptr.albedo_texture_id != 0) {
                    const albedo_asset_id = AssetId.fromU64(@as(u64, @intCast(material_ptr.albedo_texture_id)));
                    const albedo_index = texture_system.getTextureIndex(albedo_asset_id) orelse 0;
                    material_data[i].albedo_texture_id = albedo_index;
                } else {
                    material_data[i].albedo_texture_id = 0;
                }

                // Resolve roughness texture (0 = no texture, use roughness value)
                if (material_ptr.roughness_texture_id != 0) {
                    const roughness_asset_id = AssetId.fromU64(@as(u64, @intCast(material_ptr.roughness_texture_id)));
                    const roughness_index = texture_system.getTextureIndex(roughness_asset_id) orelse 0;
                    material_data[i].roughness_texture_id = roughness_index;
                } else {
                    material_data[i].roughness_texture_id = 0;
                }
            } else {
                // Fallback path without TextureSystem (direct asset manager lookup)
                // Resolve albedo texture (0 = no texture, use solid color)
                if (material_ptr.albedo_texture_id != 0) {
                    const albedo_asset_id = AssetId.fromU64(@as(u64, @intCast(material_ptr.albedo_texture_id)));
                    const resolved_albedo_id = self.asset_manager.getAssetIdForRendering(albedo_asset_id);
                    const albedo_index = self.asset_manager.asset_to_texture.get(resolved_albedo_id) orelse 0;
                    material_data[i].albedo_texture_id = @as(u32, @intCast(albedo_index));
                } else {
                    material_data[i].albedo_texture_id = 0;
                }

                // Resolve roughness texture (0 = no texture, use roughness value)
                if (material_ptr.roughness_texture_id != 0) {
                    const roughness_asset_id = AssetId.fromU64(@as(u64, @intCast(material_ptr.roughness_texture_id)));
                    const resolved_roughness_id = self.asset_manager.getAssetIdForRendering(roughness_asset_id);
                    const roughness_index = self.asset_manager.asset_to_texture.get(resolved_roughness_id) orelse 0;
                    material_data[i].roughness_texture_id = @as(u32, @intCast(roughness_index));
                } else {
                    material_data[i].roughness_texture_id = 0;
                }
            }
        }

        const data_bytes = std.mem.sliceAsBytes(material_data);

        // Create new buffer via BufferManager with proper storage buffer usage
        const buffer_config = buffer_manager_module.BufferConfig{
            .name = "MaterialBuffer",
            .size = data_bytes.len,
            .strategy = .device_local,
            .usage = .{ .storage_buffer_bit = true, .transfer_dst_bit = true },
        };

        var new_buffer = try self.buffer_manager.createBuffer(buffer_config, frame_index);
        try self.buffer_manager.updateBuffer(&new_buffer, data_bytes, frame_index);

        // Destroy old buffer (BufferManager handles frame-safe cleanup)
        if (self.current_buffer) |old_buffer| {
            try self.buffer_manager.destroyBuffer(old_buffer);
        }

        self.current_buffer = new_buffer;
        self.generation += 1;
        self.last_material_count = materials.len;

        log(.INFO, "material_system", "Rebuilt material buffer: {} materials, generation {}", .{
            materials.len,
            self.generation,
        });
    }

    /// Get current material buffer for binding via ResourceBinder
    pub fn getCurrentBuffer(self: *MaterialSystem) ?*const ManagedBuffer {
        if (self.current_buffer) |*buf| return buf;
        return null;
    }

    /// Get current generation number (useful for cache invalidation)
    pub fn getGeneration(self: *MaterialSystem) u32 {
        return self.generation;
    }

    pub fn deinit(self: *MaterialSystem) void {
        // Destroy current buffer if it exists
        if (self.current_buffer) |buffer| {
            self.buffer_manager.destroyBuffer(buffer) catch |err| {
                log(.WARN, "material_system", "Failed to destroy material buffer on deinit: {}", .{err});
            };
        }

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
