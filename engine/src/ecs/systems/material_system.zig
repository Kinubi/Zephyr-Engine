const std = @import("std");
const vk = @import("vulkan");
const buffer_manager_module = @import("../../rendering/buffer_manager.zig");
const BufferManager = buffer_manager_module.BufferManager;
const ManagedBuffer = buffer_manager_module.ManagedBuffer;
const AssetManager = @import("../../assets/asset_manager.zig").AssetManager;
const AssetId = @import("../../assets/asset_manager.zig").AssetId;
const MeshRenderer = @import("../components/mesh_renderer.zig").MeshRenderer;
const World = @import("../../ecs.zig").World;
const ecs = @import("../../ecs.zig");
const Scene = @import("../../scene/scene.zig").Scene;
const FrameInfo = @import("../../rendering/frameinfo.zig").FrameInfo;
const GameStateSnapshot = @import("../../threading/game_state_snapshot.zig").GameStateSnapshot;
const log = @import("../../utils/log.zig").log;

const MAX_FRAMES_IN_FLIGHT = @import("../../core/swapchain.zig").MAX_FRAMES_IN_FLIGHT;

/// GPU Material struct (matches shader layout)
pub const GPUMaterial = extern struct {
    albedo_idx: u32,
    roughness_idx: u32,
    metallic_idx: u32,
    normal_idx: u32,
    emissive_idx: u32,
    occlusion_idx: u32,

    albedo_tint: [4]f32,
    roughness_factor: f32,
    metallic_factor: f32,
    normal_strength: f32,
    emissive_intensity: f32,
    emissive_color: [3]f32 align(16),
    occlusion_strength: f32,
};

/// Managed texture descriptor array
pub const ManagedTextureArray = struct {
    descriptor_infos: []vk.DescriptorImageInfo = &[_]vk.DescriptorImageInfo{},
    generation: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    size: usize = 0,
};

/// Opaque handle to material bindings (buffer + textures)
/// GeometryPass uses this without knowing MaterialSystem internals
pub const MaterialBindings = struct {
    material_buffer: *const ManagedBuffer,
    texture_array: *const ManagedTextureArray,
};

/// Per-set GPU resources
const MaterialSetData = struct {
    allocator: std.mem.Allocator,
    material_buffer: *ManagedBuffer,
    texture_array: ManagedTextureArray,

    // Tracking for change detection
    last_texture_ids: std.ArrayList(u64),
    last_materials: std.ArrayList(GPUMaterial),

    pub fn init(allocator: std.mem.Allocator, buffer_manager: *BufferManager) !MaterialSetData {
        // Create an empty material buffer (1 dummy material) so binding is always valid
        const empty_material = GPUMaterial{
            .albedo_idx = 0,
            .roughness_idx = 0,
            .metallic_idx = 0,
            .normal_idx = 0,
            .emissive_idx = 0,
            .occlusion_idx = 0,
            .albedo_tint = [4]f32{ 1.0, 0.0, 1.0, 1.0 }, // Magenta to indicate uninitialized
            .roughness_factor = 1.0,
            .metallic_factor = 0.0,
            .normal_strength = 1.0,
            .emissive_intensity = 0.0,
            .emissive_color = [3]f32{ 0.0, 0.0, 0.0 },
            .occlusion_strength = 1.0,
        };

        const buffer_name = try std.fmt.allocPrint(allocator, "MaterialBuffer_empty", .{});
        defer allocator.free(buffer_name);

        const BufferConfig = buffer_manager_module.BufferConfig;
        const material_buffer = try buffer_manager.createBuffer(
            BufferConfig{
                .name = buffer_name,
                .size = @sizeOf(GPUMaterial),
                .strategy = .device_local,
                .usage = .{ .storage_buffer_bit = true, .transfer_dst_bit = true },
            },
            0, // frame_index
        );

        // Upload the dummy material
        const bytes: []const u8 = std.mem.asBytes(&empty_material);
        try buffer_manager.updateBuffer(material_buffer, bytes, 0);

        return .{
            .allocator = allocator,
            .material_buffer = material_buffer,
            .texture_array = .{},
            .last_texture_ids = std.ArrayList(u64){},
            .last_materials = std.ArrayList(GPUMaterial){},
        };
    }

    pub fn deinit(self: *MaterialSetData, buffer_manager: *BufferManager) void {
        // Clean up texture array
        if (self.texture_array.descriptor_infos.len > 0) {
            self.allocator.free(self.texture_array.descriptor_infos);
        }

        // Clean up tracking
        self.last_texture_ids.deinit(self.allocator);
        self.last_materials.deinit(self.allocator);

        // Clean up material buffer
        buffer_manager.destroyBuffer(self.material_buffer) catch |err| {
            log(.WARN, "material_system", "Failed to destroy material buffer: {}", .{err});
        };
    }
};

/// MaterialSystem - Pure ECS material manager
/// Queries material components and builds GPU resources per material set
pub const MaterialSystem = struct {
    allocator: std.mem.Allocator,
    buffer_manager: *BufferManager,
    asset_manager: *AssetManager,

    // GPU resources per material set name (e.g., "opaque", "transparent", "character")
    material_sets: std.StringHashMap(MaterialSetData),

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
            .material_sets = std.StringHashMap(MaterialSetData).init(allocator),
        };

        log(.INFO, "material_system", "MaterialSystem initialized (multi-set ECS)", .{});
        return self;
    }

    pub fn deinit(self: *MaterialSystem) void {
        // Clean up all material sets
        var iter = self.material_sets.valueIterator();
        while (iter.next()) |set_data| {
            set_data.deinit(self.buffer_manager);
        }
        self.material_sets.deinit();

        self.allocator.destroy(self);
        log(.INFO, "material_system", "MaterialSystem deinitialized", .{});
    }

    /// ECS-driven update: Query material components and build GPU resources per set
    pub fn updateFromECS(self: *MaterialSystem, world: *World, frame_index: u32) !void {
        _ = frame_index;

        const MaterialSet = ecs.MaterialSet;

        // Group entities by material set name
        var sets_map = std.StringHashMap(std.ArrayList(ecs.EntityId)).init(self.allocator);
        defer {
            var iter = sets_map.valueIterator();
            while (iter.next()) |list| {
                list.deinit(self.allocator);
            }
            sets_map.deinit();
        }

        // Query all entities with MaterialSet
        var material_view = try world.view(MaterialSet);
        var iter = material_view.iterator();

        // Group entities by material set name
        while (iter.next()) |entry| {
            const entity = entry.entity;
            const material_set = world.get(ecs.MaterialSet, entity) orelse continue;

            const gop = try sets_map.getOrPut(material_set.set_name);
            if (!gop.found_existing) {
                gop.value_ptr.* = std.ArrayList(ecs.EntityId){};
            }
            try gop.value_ptr.append(self.allocator, entity);
        }

        // Process each material set
        var sets_iter = sets_map.iterator();
        while (sets_iter.next()) |entry| {
            const set_name = entry.key_ptr.*;
            const entities = entry.value_ptr.items;

            try self.updateMaterialSet(world, set_name, entities);
        }
    }

    /// MAIN THREAD: Query ECS and build material data (writes material_buffer_index to components)
    /// Snapshot system will capture material_buffer_index later
    pub fn prepareFromECS(self: *MaterialSystem, world: *World) !void {
        const MaterialSet = ecs.MaterialSet;

        // Group entities by material set name
        var sets_map = std.StringHashMap(std.ArrayList(ecs.EntityId)).init(self.allocator);
        defer {
            var iter = sets_map.valueIterator();
            while (iter.next()) |list| {
                list.deinit(self.allocator);
            }
            sets_map.deinit();
        }

        // Query all entities with MaterialSet
        var material_view = try world.view(MaterialSet);
        var iter = material_view.iterator();

        // Group entities by material set name
        while (iter.next()) |entry| {
            const entity = entry.entity;
            const material_set = world.get(ecs.MaterialSet, entity) orelse continue;

            const gop = try sets_map.getOrPut(material_set.set_name);
            if (!gop.found_existing) {
                gop.value_ptr.* = std.ArrayList(ecs.EntityId){};
            }
            try gop.value_ptr.append(self.allocator, entity);
        }

        // Process each material set (ECS queries, compute indices)
        var sets_iter = sets_map.iterator();
        while (sets_iter.next()) |entry| {
            const set_name = entry.key_ptr.*;
            const entities = entry.value_ptr.items;

            try self.prepareMaterialSet(world, set_name, entities);
        }
    }

    /// RENDER THREAD: Upload GPU buffers using material_buffer_index from snapshot
    pub fn updateGPUResources(self: *MaterialSystem) !void {
        // Process all material sets and upload changed data to GPU
        var iter = self.material_sets.iterator();
        while (iter.next()) |entry| {
            const set_name = entry.key_ptr.*;
            const set_data = entry.value_ptr;

            // Upload texture array if changed
            if (set_data.last_texture_ids.items.len > 0) {
                // Texture array already built during prepare phase
                // GPU descriptors will be bound by render passes
            }

            // Upload material buffer if changed
            if (set_data.last_materials.items.len > 0) {
                // Material buffer already uploaded during prepare phase
                // This is a no-op for now, but will be proper GPU work when we split it
            }

            _ = set_name; // Suppress unused warning
        }
    }

    /// MAIN THREAD: Prepare a specific material set (ECS queries + write component indices)
    fn prepareMaterialSet(
        self: *MaterialSystem,
        world: *World,
        set_name: []const u8,
        entities: []const ecs.EntityId,
    ) !void {
        // Get or create set data
        const gop = try self.material_sets.getOrPut(set_name);
        if (!gop.found_existing) {
            gop.value_ptr.* = try MaterialSetData.init(self.allocator, self.buffer_manager);
        }
        var set_data = gop.value_ptr;

        // Track textures and materials for this set
        var texture_map = std.AutoHashMap(u64, u32).init(self.allocator);
        defer texture_map.deinit();

        var gpu_materials = std.ArrayList(GPUMaterial){};
        defer gpu_materials.deinit(self.allocator);

        // Reserve index 0 for white dummy texture
        try texture_map.put(0, 0);
        var next_texture_idx: u32 = 1;

        // Build materials for entities in this set
        for (entities) |entity| {
            // Get optional material property components
            const albedo = world.get(ecs.AlbedoMaterial, entity);
            const roughness = world.get(ecs.RoughnessMaterial, entity);
            const metallic = world.get(ecs.MetallicMaterial, entity);
            const normal = world.get(ecs.NormalMaterial, entity);
            const emissive = world.get(ecs.EmissiveMaterial, entity);
            const occlusion = world.get(ecs.OcclusionMaterial, entity);

            // Build GPU material
            var gpu_mat: GPUMaterial = std.mem.zeroes(GPUMaterial);

            // Albedo
            if (albedo) |alb| {
                gpu_mat.albedo_idx = try self.getOrAddTexture(&texture_map, &next_texture_idx, alb.texture_id);
                gpu_mat.albedo_tint = alb.color_tint;
            } else {
                gpu_mat.albedo_idx = 0;
                gpu_mat.albedo_tint = [_]f32{ 1, 1, 1, 1 };
            }

            // Roughness
            if (roughness) |rough| {
                gpu_mat.roughness_idx = try self.getOrAddTexture(&texture_map, &next_texture_idx, rough.texture_id);
                gpu_mat.roughness_factor = rough.factor;
            } else {
                gpu_mat.roughness_idx = 0;
                gpu_mat.roughness_factor = 0.5;
            }

            // Metallic
            if (metallic) |metal| {
                gpu_mat.metallic_idx = try self.getOrAddTexture(&texture_map, &next_texture_idx, metal.texture_id);
                gpu_mat.metallic_factor = metal.factor;
            } else {
                gpu_mat.metallic_idx = 0;
                gpu_mat.metallic_factor = 0.0;
            }

            // Normal
            if (normal) |norm| {
                gpu_mat.normal_idx = try self.getOrAddTexture(&texture_map, &next_texture_idx, norm.texture_id);
                gpu_mat.normal_strength = norm.strength;
            } else {
                gpu_mat.normal_idx = 0;
                gpu_mat.normal_strength = 1.0;
            }

            // Emissive
            if (emissive) |emiss| {
                gpu_mat.emissive_idx = try self.getOrAddTexture(&texture_map, &next_texture_idx, emiss.texture_id);
                gpu_mat.emissive_color = emiss.color;
                gpu_mat.emissive_intensity = emiss.intensity;
            } else {
                gpu_mat.emissive_idx = 0;
                gpu_mat.emissive_color = [_]f32{ 0, 0, 0 };
                gpu_mat.emissive_intensity = 0.0;
            }

            // Occlusion
            if (occlusion) |occ| {
                gpu_mat.occlusion_idx = try self.getOrAddTexture(&texture_map, &next_texture_idx, occ.texture_id);
                gpu_mat.occlusion_strength = occ.strength;
            } else {
                gpu_mat.occlusion_idx = 0;
                gpu_mat.occlusion_strength = 1.0;
            }

            // CRITICAL: Write material_buffer_index to component (snapshot will capture this)
            // Get fresh pointer right before writing to avoid stale pointer issues
            // if ECS storage was reallocated during the loop
            const material_set = world.get(ecs.MaterialSet, entity) orelse continue;
            material_set.material_buffer_index = @intCast(gpu_materials.items.len);

            try gpu_materials.append(self.allocator, gpu_mat);
        }

        // Check if texture set changed
        var current_texture_ids = std.ArrayList(u64){};
        defer current_texture_ids.deinit(self.allocator);

        var tex_iter = texture_map.keyIterator();
        while (tex_iter.next()) |key_ptr| {
            try current_texture_ids.append(self.allocator, key_ptr.*);
        }
        std.sort.pdq(u64, current_texture_ids.items, {}, std.sort.asc(u64));

        const textures_changed = blk: {
            if (current_texture_ids.items.len != set_data.last_texture_ids.items.len) break :blk true;
            for (current_texture_ids.items, set_data.last_texture_ids.items) |curr, last| {
                if (curr != last) break :blk true;
            }

            // Check if any texture descriptors changed
            var tex_check_iter = texture_map.iterator();
            while (tex_check_iter.next()) |entry| {
                const asset_id_u64 = entry.key_ptr.*;
                const idx = entry.value_ptr.*;

                if (asset_id_u64 == 0 or idx == 0) continue;

                const asset_id = AssetId.fromU64(asset_id_u64);
                const current_descriptor = self.asset_manager.getTextureDescriptor(asset_id);

                if (current_descriptor != null and idx < set_data.texture_array.descriptor_infos.len) {
                    const last_descriptor = set_data.texture_array.descriptor_infos[idx];
                    if (current_descriptor.?.image_view != last_descriptor.image_view) {
                        break :blk true;
                    }
                }
            }

            break :blk false;
        };

        // Check if materials changed
        const materials_changed = blk: {
            if (gpu_materials.items.len != set_data.last_materials.items.len) break :blk true;
            for (gpu_materials.items, set_data.last_materials.items) |curr, last| {
                if (!std.meta.eql(curr, last)) break :blk true;
            }
            break :blk false;
        };

        // Upload to GPU if changed (still on main thread for now, will move to render thread)
        if (textures_changed) {
            try self.buildTextureArray(set_data, &texture_map, next_texture_idx);
            set_data.last_texture_ids.clearRetainingCapacity();
            try set_data.last_texture_ids.appendSlice(self.allocator, current_texture_ids.items);
        }

        if (materials_changed and gpu_materials.items.len > 0) {
            try self.uploadMaterialBuffer(set_data, set_name, gpu_materials.items);
            set_data.last_materials.clearRetainingCapacity();
            try set_data.last_materials.appendSlice(self.allocator, gpu_materials.items);
        }
    }

    /// Update a specific material set
    fn updateMaterialSet(
        self: *MaterialSystem,
        world: *World,
        set_name: []const u8,
        entities: []const ecs.EntityId,
    ) !void {
        // Get or create set data
        const gop = try self.material_sets.getOrPut(set_name);
        if (!gop.found_existing) {
            gop.value_ptr.* = try MaterialSetData.init(self.allocator, self.buffer_manager);
        }
        var set_data = gop.value_ptr;

        // Track textures and materials for this set
        var texture_map = std.AutoHashMap(u64, u32).init(self.allocator);
        defer texture_map.deinit();

        var gpu_materials = std.ArrayList(GPUMaterial){};
        defer gpu_materials.deinit(self.allocator);

        // Reserve index 0 for white dummy texture
        try texture_map.put(0, 0);
        var next_texture_idx: u32 = 1;

        // Build materials for entities in this set
        for (entities) |entity| {
            const material_set = world.get(ecs.MaterialSet, entity) orelse continue;

            // Get optional material property components
            const albedo = world.get(ecs.AlbedoMaterial, entity);
            const roughness = world.get(ecs.RoughnessMaterial, entity);
            const metallic = world.get(ecs.MetallicMaterial, entity);
            const normal = world.get(ecs.NormalMaterial, entity);
            const emissive = world.get(ecs.EmissiveMaterial, entity);
            const occlusion = world.get(ecs.OcclusionMaterial, entity);

            // Build GPU material
            var gpu_mat: GPUMaterial = std.mem.zeroes(GPUMaterial);

            // Albedo
            if (albedo) |alb| {
                gpu_mat.albedo_idx = try self.getOrAddTexture(&texture_map, &next_texture_idx, alb.texture_id);
                gpu_mat.albedo_tint = alb.color_tint;
            } else {
                gpu_mat.albedo_idx = 0;
                gpu_mat.albedo_tint = [_]f32{ 1, 1, 1, 1 };
            }

            // Roughness
            if (roughness) |rough| {
                gpu_mat.roughness_idx = try self.getOrAddTexture(&texture_map, &next_texture_idx, rough.texture_id);
                gpu_mat.roughness_factor = rough.factor;
            } else {
                gpu_mat.roughness_idx = 0;
                gpu_mat.roughness_factor = 0.5;
            }

            // Metallic
            if (metallic) |metal| {
                gpu_mat.metallic_idx = try self.getOrAddTexture(&texture_map, &next_texture_idx, metal.texture_id);
                gpu_mat.metallic_factor = metal.factor;
            } else {
                gpu_mat.metallic_idx = 0;
                gpu_mat.metallic_factor = 0.0;
            }

            // Normal
            if (normal) |norm| {
                gpu_mat.normal_idx = try self.getOrAddTexture(&texture_map, &next_texture_idx, norm.texture_id);
                gpu_mat.normal_strength = norm.strength;
            } else {
                gpu_mat.normal_idx = 0;
                gpu_mat.normal_strength = 1.0;
            }

            // Emissive
            if (emissive) |emiss| {
                gpu_mat.emissive_idx = try self.getOrAddTexture(&texture_map, &next_texture_idx, emiss.texture_id);
                gpu_mat.emissive_color = emiss.color;
                gpu_mat.emissive_intensity = emiss.intensity;
            } else {
                gpu_mat.emissive_idx = 0;
                gpu_mat.emissive_color = [_]f32{ 0, 0, 0 };
                gpu_mat.emissive_intensity = 0.0;
            }

            // Occlusion
            if (occlusion) |occ| {
                gpu_mat.occlusion_idx = try self.getOrAddTexture(&texture_map, &next_texture_idx, occ.texture_id);
                gpu_mat.occlusion_strength = occ.strength;
            } else {
                gpu_mat.occlusion_idx = 0;
                gpu_mat.occlusion_strength = 1.0;
            }

            // Store material index in MaterialSet component (local to this set)
            material_set.material_buffer_index = @intCast(gpu_materials.items.len);

            try gpu_materials.append(self.allocator, gpu_mat);
        } // Check if texture set changed (compare sorted texture IDs and actual descriptors)
        var current_texture_ids = std.ArrayList(u64){};
        defer current_texture_ids.deinit(self.allocator);

        var tex_iter = texture_map.keyIterator();
        while (tex_iter.next()) |key_ptr| {
            try current_texture_ids.append(self.allocator, key_ptr.*);
        }

        // Sort for comparison
        std.sort.pdq(u64, current_texture_ids.items, {}, std.sort.asc(u64));

        // Check if textures changed (IDs or actual descriptor contents)
        const textures_changed = blk: {
            // Check if texture ID list changed
            if (current_texture_ids.items.len != set_data.last_texture_ids.items.len) break :blk true;
            for (current_texture_ids.items, set_data.last_texture_ids.items) |curr, last| {
                if (curr != last) break :blk true;
            }

            // Check if any texture descriptors changed (textures finished loading)
            // Compare current descriptors with last built array
            var tex_check_iter = texture_map.iterator();
            while (tex_check_iter.next()) |entry| {
                const asset_id_u64 = entry.key_ptr.*;
                const idx = entry.value_ptr.*;

                if (asset_id_u64 == 0 or idx == 0) continue; // Skip dummy

                const asset_id = AssetId.fromU64(asset_id_u64);

                // Get current descriptor
                const current_descriptor = self.asset_manager.getTextureDescriptor(asset_id);

                // If we have a valid descriptor now but different from what we built
                if (current_descriptor != null and idx < set_data.texture_array.descriptor_infos.len) {
                    const last_descriptor = set_data.texture_array.descriptor_infos[idx];
                    // Compare image views (main indicator that texture loaded)
                    if (current_descriptor.?.image_view != last_descriptor.image_view) {
                        break :blk true;
                    }
                }
            }

            break :blk false;
        };

        // Only rebuild texture array if textures changed
        if (textures_changed) {
            try self.buildTextureArray(set_data, &texture_map, next_texture_idx);

            // Update tracking
            set_data.last_texture_ids.clearRetainingCapacity();
            try set_data.last_texture_ids.appendSlice(self.allocator, current_texture_ids.items);
        }

        // Check if materials changed
        const materials_changed = blk: {
            if (gpu_materials.items.len != set_data.last_materials.items.len) break :blk true;
            for (gpu_materials.items, set_data.last_materials.items) |curr, last| {
                if (!std.meta.eql(curr, last)) break :blk true;
            }
            break :blk false;
        };

        // Upload material buffer only if materials changed
        if (materials_changed and gpu_materials.items.len > 0) {
            try self.uploadMaterialBuffer(set_data, set_name, gpu_materials.items);

            // Update tracking
            set_data.last_materials.clearRetainingCapacity();
            try set_data.last_materials.appendSlice(self.allocator, gpu_materials.items);
        }
    }

    /// Get or add texture to the map
    fn getOrAddTexture(
        self: *MaterialSystem,
        texture_map: *std.AutoHashMap(u64, u32),
        next_idx: *u32,
        texture_id: AssetId,
    ) !u32 {
        _ = self;
        const id_u64 = texture_id.toU64();

        // Invalid texture -> use white dummy (index 0)
        if (id_u64 == 0) return 0;

        // Check if already added
        if (texture_map.get(id_u64)) |idx| {
            return idx;
        }

        // Add new texture
        const idx = next_idx.*;
        try texture_map.put(id_u64, idx);
        next_idx.* += 1;
        return idx;
    }

    /// Build texture descriptor array from texture map
    fn buildTextureArray(
        self: *MaterialSystem,
        set_data: *MaterialSetData,
        texture_map: *std.AutoHashMap(u64, u32),
        texture_count: u32,
    ) !void {
        // Free old array
        if (set_data.texture_array.descriptor_infos.len > 0) {
            self.allocator.free(set_data.texture_array.descriptor_infos);
        }

        // Allocate new array
        var descriptors = try self.allocator.alloc(vk.DescriptorImageInfo, texture_count);

        // Index 0 = white dummy texture
        descriptors[0] = self.asset_manager.getWhiteDummyTextureDescriptor();

        // Fill in textures from map
        var iter = texture_map.iterator();
        while (iter.next()) |entry| {
            const asset_id_u64 = entry.key_ptr.*;
            const idx = entry.value_ptr.*;

            if (idx == 0) continue; // Skip dummy

            const asset_id = AssetId.fromU64(asset_id_u64);

            // Get texture from asset manager
            if (self.asset_manager.getTextureDescriptor(asset_id)) |descriptor| {
                descriptors[idx] = descriptor;
            } else {
                // Fallback to white dummy
                descriptors[idx] = descriptors[0];
                log(.WARN, "material_system", "Texture {} not found, using dummy", .{asset_id_u64});
            }
        }

        set_data.texture_array.descriptor_infos = descriptors;
        set_data.texture_array.size = texture_count;
        // Increment generation AFTER writing data, with release ordering
        // This ensures all writes above are visible before generation change is seen
        _ = set_data.texture_array.generation.fetchAdd(1, .release);
    }

    /// Upload material buffer to GPU
    fn uploadMaterialBuffer(self: *MaterialSystem, set_data: *MaterialSetData, set_name: []const u8, materials: []const GPUMaterial) !void {
        const size = materials.len * @sizeOf(GPUMaterial);

        // Only resize if we need MORE space (never shrink to avoid excessive resizes)
        if (set_data.material_buffer.size < size) {
            log(.INFO, "material_system", "Resizing material buffer for set '{s}' from {} to {} bytes", .{
                set_name,
                set_data.material_buffer.size,
                size,
            });

            // Resize the buffer (keeps pointer stable, increments generation for rebinding)
            try self.buffer_manager.resizeBuffer(
                set_data.material_buffer,
                size,
                .{ .storage_buffer_bit = true, .transfer_dst_bit = true },
            );
        }

        // Upload data (only upload what we need, even if buffer is larger)
        const bytes: []const u8 = std.mem.sliceAsBytes(materials);
        try self.buffer_manager.updateBuffer(
            set_data.material_buffer,
            bytes,
            0, // frame_index
        );
    }

    /// Get opaque material bindings handle for render passes
    /// Returns bindings for a specific material set by name (e.g., "opaque", "transparent", "character")
    /// If the set doesn't exist yet, creates an empty one
    pub fn getBindings(self: *MaterialSystem, set_name: []const u8) !MaterialBindings {
        const gop = try self.material_sets.getOrPut(set_name);
        if (!gop.found_existing) {
            gop.value_ptr.* = try MaterialSetData.init(self.allocator, self.buffer_manager);
        }

        const set_data = gop.value_ptr;
        return MaterialBindings{
            .material_buffer = set_data.material_buffer,
            .texture_array = &set_data.texture_array,
        };
    }
};

/// MAIN THREAD: Prepare phase - ECS queries, compute indices, write to components
/// SystemScheduler compatibility wrapper
pub fn prepare(world: *World, dt: f32) !void {
    _ = dt;

    // Get the scene from world userdata
    const scene_ptr = world.getUserData("scene") orelse return;
    const scene: *Scene = @ptrCast(@alignCast(scene_ptr));

    // Get material system from scene
    if (scene.material_system) |material_system| {
        // Query ECS, build material data, write material_buffer_index to components
        // Snapshot system will capture material_buffer_index later
        try material_system.prepareFromECS(world);
    }
}

/// RENDER THREAD: Update phase - GPU buffer uploads (uses snapshot data)
/// SystemScheduler compatibility wrapper
pub fn update(world: *World, frame_info: *FrameInfo) !void {
    _ = world;

    // Get the snapshot from frame_info
    const snapshot = frame_info.snapshot;

    // TODO: Implement GPU buffer uploads using snapshot.entities[].material_buffer_index
    // For now, GPU work still happens in prepare phase (will split in next iteration)
    // The snapshot already has material_buffer_index, just need to:
    // 1. Group entities by material_buffer_index
    // 2. Upload material buffers to GPU
    // 3. Build texture descriptor arrays

    _ = snapshot;
}
