const std = @import("std");
const vk = @import("vulkan");
const buffer_manager_module = @import("buffer_manager.zig");
const BufferManager = buffer_manager_module.BufferManager;
const ManagedBuffer = buffer_manager_module.ManagedBuffer;
const AssetManager = @import("../assets/asset_manager.zig").AssetManager;
const Material = @import("../assets/asset_manager.zig").Material;
const log = @import("../utils/log.zig").log;

const MAX_FRAMES_IN_FLIGHT = @import("../core/swapchain.zig").MAX_FRAMES_IN_FLIGHT;

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

    current_buffer: ?ManagedBuffer = null,
    generation: u32 = 0,
    last_material_count: usize = 0,

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

    /// Check if materials changed and rebuild if needed
    /// Should be called once per frame
    pub fn update(self: *MaterialSystem, frame_index: u32) !void {
        const materials = self.asset_manager.loaded_materials.items;

        // Check if material count changed OR materials are marked dirty (texture changes, etc.)
        const count_changed = materials.len != self.last_material_count;
        const materials_dirty = self.asset_manager.materials_dirty;

        if (count_changed or materials_dirty) {
            if (materials.len > 0) {
                try self.rebuildMaterialBuffer(frame_index);
                // Clear the dirty flag since we've rebuilt
                self.asset_manager.materials_dirty = false;
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

            // Resolve the albedo_texture_id to an actual texture index
            const texture_asset_id = @import("../assets/asset_manager.zig").AssetId.fromU64(@as(u64, @intCast(material_ptr.albedo_texture_id)));
            const resolved_texture_id = self.asset_manager.getAssetIdForRendering(texture_asset_id);

            // Get the texture index from the resolved asset ID
            const texture_index = self.asset_manager.asset_to_texture.get(resolved_texture_id) orelse 0;
            material_data[i].albedo_texture_id = @as(u32, @intCast(texture_index));
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

    /// Bind material buffer to pipeline using named binding
    pub fn bindMaterialBuffer(
        self: *MaterialSystem,
        frame_index: u32,
    ) !void {
        if (self.current_buffer) |*buffer| {
            try self.buffer_manager.bindBuffer(
                buffer,
                "MaterialBuffer", // Matches shader reflection name
                frame_index,
            );
        }
    }

    /// Get current material buffer (for manual binding if needed)
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
