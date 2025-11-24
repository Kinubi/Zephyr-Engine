const std = @import("std");
const vk = @import("vulkan");
const buffer_manager_module = @import("../../rendering/buffer_manager.zig");
const BufferManager = buffer_manager_module.BufferManager;
const ManagedBuffer = buffer_manager_module.ManagedBuffer;
const TextureDescriptorManager = @import("../../rendering/texture_descriptor_manager.zig").TextureDescriptorManager;
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

// Re-export GPUMaterial from component (single source of truth)
pub const GPUMaterial = ecs.GPUMaterial;

/// Managed texture descriptor array - CRITICAL TRIPLE BUFFERING DESIGN
///
/// WHY PER-FRAME OFFSETS IN A SINGLE STRUCT:
/// ==========================================
///
/// This struct manages texture descriptor arrays for triple-buffered rendering.
/// It stores MULTIPLE offsets (one per frame-in-flight) within a SINGLE struct instance.
///
/// DESIGN RATIONALE:
/// -----------------
/// With triple buffering, we have 3 render frames executing simultaneously:
///   - Frame 0 might be rendering data from 3 frames ago
///   - Frame 1 might be rendering data from 2 frames ago
///   - Frame 2 might be rendering data from 1 frame ago
///
/// Each frame needs its OWN snapshot of texture descriptors from when that frame
/// was prepared. If we only stored one offset, all frames would share the same
/// descriptor array, causing race conditions and incorrect rendering.
///
/// WHY NOT [MAX_FRAMES_IN_FLIGHT]ManagedTextureArray:
/// ---------------------------------------------------
/// You might think: "Just make an array of 3 separate ManagedTextureArray structs!"
/// This DOES NOT WORK because:
///
/// 1. SYNCHRONIZATION PROBLEM:
///    When textures change, we allocate to all 3 frame arenas simultaneously.
///    All 3 struct instances would get updated with the SAME offset values (e.g., all get offset=25).
///    This defeats the purpose of having separate instances.
///
/// 2. TEMPORAL COUPLING:
///    Each frame's descriptor array should be allocated INDEPENDENTLY when that frame
///    is prepared, not all at once. The current frame (frame N) should allocate to
///    arena[N], and the offset should be stored in arena_offsets[N].
///
/// 3. NO HISTORY:
///    With separate instances, there's no way to store "frame 0's offset from 3 frames ago"
///    vs "frame 0's offset from 2 frames ago". We need all 3 historical offsets accessible
///    from a single struct so each rendering frame can use the correct snapshot.
///
/// CORRECT PATTERN:
/// ----------------
/// MaterialSetData has:
///   - texture_arrays: [MAX_FRAMES_IN_FLIGHT]ManagedTextureArray  // 3 struct instances
///
/// But WAIT - this looks like what we said doesn't work! The difference is:
///   - Each ManagedTextureArray in the array represents a DIFFERENT MATERIAL SET
///   - Within EACH ManagedTextureArray, we store [3] offsets for triple buffering
///   - So we have: material_set[i].texture_arrays[frame_idx].arena_offsets[frame_idx]
///
/// Actually, looking at the code below, we have:
///   - texture_arrays: [MAX_FRAMES_IN_FLIGHT]ManagedTextureArray
///
/// This means we DO have 3 separate struct instances per material set.
/// Each instance should maintain its own [3] arena offsets for proper triple buffering.
///
/// ALTERNATIVE DESIGN (what we tried and failed):
/// -----------------------------------------------
/// If we changed to: arena_offset: usize (single offset)
/// Then each of the 3 ManagedTextureArray instances would store ONE offset.
/// Problem: When we allocate in a loop, all 3 get the SAME offset value:
///   - texture_arrays[0].arena_offset = 25  (in arena 0)
///   - texture_arrays[1].arena_offset = 25  (in arena 1)
///   - texture_arrays[2].arena_offset = 25  (in arena 2)
///
/// This means frame 0 always uses offset 25 from arena 0, frame 1 uses offset 25 from arena 1.
/// BUT: The arenas grow linearly! Next allocation gives offset 30 to all frames.
/// Result: All frames constantly update to the NEWEST offset, losing the per-frame history.
/// Without history, frames don't have stable descriptor snapshots → black textures or flickering.
///
/// CORRECT USAGE:
/// --------------
/// - Each ManagedTextureArray stores [3] offsets (one per frame-in-flight)
/// - When frame N prepares, it allocates to arena[N] and stores in arena_offsets[N]
/// - When frame N renders, it reads arena_offsets[N] to get its stable descriptor snapshot
/// - Other frames (N-1, N-2) still read their own stable offsets from the same struct
///
pub const ManagedTextureArray = struct {
    arena_offsets: [MAX_FRAMES_IN_FLIGHT]usize = [_]usize{0} ** MAX_FRAMES_IN_FLIGHT, // Per-frame offset into descriptor manager's frame arenas
    generation: u32 = 0,
    size: usize = 0, // Number of descriptors in the array (same for all frames)
    pending_bind_mask: std.atomic.Value(u8) = std.atomic.Value(u8).init((@as(u8, 1) << MAX_FRAMES_IN_FLIGHT) - 1),

    /// Mark this texture array as updated - increments generation and sets mask
    /// Call this after updating arena allocation to trigger rebinding
    pub fn markUpdated(self: *ManagedTextureArray) void {
        self.generation +%= 1;
        const all_frames_mask = (@as(u8, 1) << MAX_FRAMES_IN_FLIGHT) - 1;
        self.pending_bind_mask.store(all_frames_mask, .release); // All frames need rebinding
    }
};

/// Delta update tracking for a material set
const MaterialSetDelta = struct {
    allocator: std.mem.Allocator,

    // Material data changes (compact list of changed materials)
    changed_materials: std.ArrayList(ChangedMaterial),

    // Texture descriptor changes
    texture_array_dirty: bool = false,
    texture_descriptors: []vk.DescriptorImageInfo = &[_]vk.DescriptorImageInfo{},
    texture_count: u32 = 0,

    pub const ChangedMaterial = struct {
        index: u32, // Index in material buffer
        data: GPUMaterial, // New material data
    };

    pub fn init(allocator: std.mem.Allocator) MaterialSetDelta {
        return .{
            .allocator = allocator,
            .changed_materials = std.ArrayList(ChangedMaterial){},
        };
    }

    pub fn deinit(self: *MaterialSetDelta) void {
        self.changed_materials.deinit(self.allocator);
        if (self.texture_descriptors.len > 0) {
            self.allocator.free(self.texture_descriptors);
        }
    }

    pub fn clear(self: *MaterialSetDelta) void {
        self.changed_materials.clearRetainingCapacity();
        self.texture_array_dirty = false;
    }
};

/// Per-set GPU resources (public for GeometryPass access)
pub const MaterialSetData = struct {
    allocator: std.mem.Allocator,
    material_buffers: [MAX_FRAMES_IN_FLIGHT]*ManagedBuffer, // Per-frame arena-allocated buffers (heap pointers)
    current_capacity: usize, // Number of materials current buffers can hold
    texture_arrays: [MAX_FRAMES_IN_FLIGHT]ManagedTextureArray, // Per-frame texture descriptor arrays (each frame has its own copy)

    // Tracking for change detection
    last_texture_ids: std.ArrayList(u64),
    last_materials: std.AutoHashMap(ecs.EntityId, GPUMaterial), // Track by entity ID, not array index
    next_materials: std.ArrayList(GPUMaterial), // Staging area for next frame's materials

    // Delta tracking for incremental GPU updates (main thread)
    pending_delta: MaterialSetDelta,

    // Per-frame ephemeral deltas (render thread) - latest delta supersedes old ones
    pending_deltas: [MAX_FRAMES_IN_FLIGHT]MaterialSetDelta,

    // Scratch buffers for prepareMaterialSet (reuse memory to avoid allocations)
    scratch_unique_textures: std.AutoHashMap(u64, void),
    scratch_current_texture_ids: std.ArrayList(u64),
    scratch_texture_map: std.AutoHashMap(u64, u32),
    scratch_gpu_materials: std.ArrayList(GPUMaterial),

    pub fn init(allocator: std.mem.Allocator, buffer_manager: *BufferManager) !MaterialSetData {
        // Create dummy per-frame buffers (1 material each) from frame arenas
        // This ensures binding is always valid even before any materials are added
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

        var material_buffers: [MAX_FRAMES_IN_FLIGHT]*ManagedBuffer = undefined;

        // Allocate from each frame's arena
        for (&material_buffers, 0..) |*buf_ptr, frame_idx| {
            const frame = @as(u32, @intCast(frame_idx));

            // Allocate heap storage for ManagedBuffer
            const buf = try allocator.create(ManagedBuffer);
            errdefer allocator.destroy(buf);
            buf_ptr.* = buf;

            // Create unique name for each frame's buffer
            const buffer_name = try std.fmt.allocPrint(allocator, "MaterialBuffer_frame_{d}", .{frame});
            errdefer allocator.free(buffer_name);

            // Create a managed buffer placeholder (will point to arena)
            buf.* = ManagedBuffer{
                .buffer = undefined, // Will be set by allocateFromFrameArena
                .name = buffer_name,
                .size = @sizeOf(GPUMaterial),
                .strategy = .host_visible,
                .created_frame = 0,
                .generation = 1,
                .binding_info = null,
                .arena_offset = 0,
                .pending_bind_mask = std.atomic.Value(u8).init((@as(u8, 1) << MAX_FRAMES_IN_FLIGHT) - 1),
            };

            // Allocate from frame arena
            const alloc_result = buffer_manager.allocateFromFrameArena(
                frame,
                buf,
                @sizeOf(GPUMaterial),
                16, // alignment
            ) catch |err| {
                // If arena allocation fails, fall back to dedicated buffer
                log(.WARN, "material_system", "Arena allocation failed for frame {}, using dedicated buffer: {}", .{ frame, err });
                allocator.free(buffer_name);
                allocator.destroy(buf);

                const dedicated_name = try std.fmt.allocPrint(allocator, "MaterialBuffer_dedicated_{d}", .{frame});
                defer allocator.free(dedicated_name); // createBuffer duplicates the name
                const BufferConfig = buffer_manager_module.BufferConfig;
                const dedicated = try buffer_manager.createBuffer(
                    BufferConfig{
                        .name = dedicated_name,
                        .size = @sizeOf(GPUMaterial),
                        .strategy = .device_local,
                        .usage = .{ .storage_buffer_bit = true, .transfer_dst_bit = true },
                    },
                    frame,
                );
                buf_ptr.* = dedicated;
                dedicated.markUpdated();
                continue;
            };

            // Set buffer to arena buffer with correct offset
            buf.buffer = alloc_result.buffer.buffer;
            buf.arena_offset = alloc_result.offset;
            buf.size = @sizeOf(GPUMaterial);

            // Write dummy material to this frame's allocation
            try alloc_result.buffer.buffer.map(@sizeOf(GPUMaterial), alloc_result.offset);
            const data_ptr: [*]u8 = @ptrCast(alloc_result.buffer.buffer.mapped.?);
            @memcpy(data_ptr[0..@sizeOf(GPUMaterial)], std.mem.asBytes(&empty_material));
            alloc_result.buffer.buffer.unmap();
        }
        return .{
            .allocator = allocator,
            .material_buffers = material_buffers,
            .current_capacity = 1, // Currently holds 1 dummy material
            .texture_arrays = [_]ManagedTextureArray{.{}} ** MAX_FRAMES_IN_FLIGHT,
            .last_texture_ids = std.ArrayList(u64){},
            .last_materials = std.AutoHashMap(ecs.EntityId, GPUMaterial).init(allocator),
            .next_materials = std.ArrayList(GPUMaterial){}, // Staging area
            .pending_delta = MaterialSetDelta.init(allocator),
            .pending_deltas = [_]MaterialSetDelta{MaterialSetDelta.init(allocator)} ** MAX_FRAMES_IN_FLIGHT,
            .scratch_unique_textures = std.AutoHashMap(u64, void).init(allocator),
            .scratch_current_texture_ids = std.ArrayList(u64){},
            .scratch_texture_map = std.AutoHashMap(u64, u32).init(allocator),
            .scratch_gpu_materials = std.ArrayList(GPUMaterial){},
        };
    }

    pub fn deinit(self: *MaterialSetData, buffer_manager: *BufferManager) void {
        // Texture descriptors are managed by TextureDescriptorManager's frame arenas
        // No manual cleanup needed here - arenas are reset each frame

        // Clean up scratch buffers
        self.scratch_unique_textures.deinit();
        self.scratch_current_texture_ids.deinit(self.allocator);
        self.scratch_texture_map.deinit();
        self.scratch_gpu_materials.deinit(self.allocator);

        // Clean up tracking
        self.last_texture_ids.deinit(self.allocator);
        self.last_materials.deinit();
        self.next_materials.deinit(self.allocator);

        // Clean up deltas
        self.pending_delta.deinit();
        for (&self.pending_deltas) |*delta| {
            delta.deinit();
        }

        // Free per-frame material buffers
        for (&self.material_buffers, 0..) |buf_ptr, frame_idx| {
            const frame = @as(u32, @intCast(frame_idx));
            const buf = buf_ptr;

            if (buf.arena_offset != 0) {
                // Arena-allocated: only free tracking and heap-allocated struct
                // Don't call destroyBuffer - the arena owns the Vulkan buffer
                buffer_manager.freeFromFrameArena(frame, buf);
                self.allocator.free(buf.name);
                self.allocator.destroy(buf);
            } else {
                // Dedicated buffer: use destroyBuffer for full cleanup
                buffer_manager.destroyBuffer(buf) catch |err| {
                    log(.WARN, "material_system", "Failed to destroy material buffer for frame {}: {}", .{ frame, err });
                };
            }
        }
    }
};

/// MaterialSystem - Pure ECS material manager
/// Queries material components and builds GPU resources per material set
pub const MaterialSystem = struct {
    allocator: std.mem.Allocator,
    buffer_manager: *BufferManager,
    descriptor_manager: *TextureDescriptorManager,
    asset_manager: *AssetManager,

    // GPU resources per material set name (e.g., "opaque", "transparent", "character")
    material_sets: std.StringHashMap(MaterialSetData),

    pub fn init(
        allocator: std.mem.Allocator,
        buffer_manager: *BufferManager,
        descriptor_manager: *TextureDescriptorManager,
        asset_manager: *AssetManager,
    ) !*MaterialSystem {
        const self = try allocator.create(MaterialSystem);
        self.* = .{
            .allocator = allocator,
            .buffer_manager = buffer_manager,
            .descriptor_manager = descriptor_manager,
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

        // Pre-allocate space for common case (reduce allocations during grouping)
        const entity_count = material_view.storage.entities.items.len;

        // Group entities by material set name
        while (iter.next()) |entry| {
            const entity = entry.entity;
            const material_set = world.get(ecs.MaterialSet, entity) orelse continue;

            const gop = try sets_map.getOrPut(material_set.set_name);
            if (!gop.found_existing) {
                // Pre-allocate with estimated size to reduce reallocations
                gop.value_ptr.* = std.ArrayList(ecs.EntityId){};
                try gop.value_ptr.ensureTotalCapacity(self.allocator, @max(1, entity_count / 2));
            }
            gop.value_ptr.appendAssumeCapacity(entity);
        }

        // Process each material set (ECS queries, compute indices, build deltas)
        var sets_iter = sets_map.iterator();
        while (sets_iter.next()) |entry| {
            const set_name = entry.key_ptr.*;
            const entities = entry.value_ptr.items;

            try self.prepareMaterialSet(world, set_name, entities);
        }

        // Write deltas to MaterialDeltasSet component (ALWAYS, like RenderSystem)
        const singleton_entity = try world.getOrCreateSingletonEntity();
        var deltas_set = world.getMut(ecs.MaterialDeltasSet, singleton_entity) orelse blk: {
            try world.emplace(ecs.MaterialDeltasSet, singleton_entity, ecs.MaterialDeltasSet.init(self.allocator));
            break :blk world.getMut(ecs.MaterialDeltasSet, singleton_entity) orelse {
                log(.ERROR, "material_system", "MaterialDeltasSet component not found after emplace", .{});
                return error.ComponentNotRegistered;
            };
        };

        // Clear old deltas
        deltas_set.clear();

        // Build delta array from changed material sets
        var deltas_list = std.ArrayList(ecs.MaterialSetDelta){};
        defer deltas_list.deinit(self.allocator);

        // Pre-allocate with known size
        try deltas_list.ensureTotalCapacity(self.allocator, self.material_sets.count());

        var delta_iter = self.material_sets.iterator();
        while (delta_iter.next()) |entry| {
            const set_name = entry.key_ptr.*;
            const set_data = entry.value_ptr;

            // OPTIMIZATION: Skip if no changes
            if (!set_data.pending_delta.texture_array_dirty and set_data.pending_delta.changed_materials.items.len == 0) {
                continue;
            }

            // Copy changed materials (convert from ChangedMaterial to MaterialChange)
            const changed_materials = try self.allocator.alloc(
                ecs.MaterialChange,
                set_data.pending_delta.changed_materials.items.len,
            );
            for (set_data.pending_delta.changed_materials.items, 0..) |change, i| {
                changed_materials[i] = .{
                    .index = change.index,
                    .data = change.data,
                };
            }

            // Copy texture descriptors
            const texture_descriptors = try self.allocator.dupe(
                vk.DescriptorImageInfo,
                set_data.pending_delta.texture_descriptors,
            );

            deltas_list.appendAssumeCapacity(.{
                .set_name = set_name,
                .changed_materials = changed_materials,
                .texture_descriptors = texture_descriptors,
                .texture_count = set_data.pending_delta.texture_count,
                .texture_array_dirty = set_data.pending_delta.texture_array_dirty,
            });
        }

        // ALWAYS write deltas (even if all are empty arrays) - like RenderSystem
        deltas_set.deltas = try deltas_list.toOwnedSlice(self.allocator);

        // Update tracking for next frame (AFTER writing to component)
        var tracking_iter = self.material_sets.iterator();
        while (tracking_iter.next()) |entry| {
            const set_data = entry.value_ptr;

            // Clear pending_delta for next frame
            set_data.pending_delta.clear();
        }
    }

    /// RENDER THREAD: Apply material deltas from snapshot (thread-safe)
    pub fn applySnapshotDeltas(
        self: *MaterialSystem,
        material_set_snapshots: []const ecs.MaterialSetDelta,
    ) !void {
        for (material_set_snapshots) |snap| {
            // Get the material set data (must already exist - created during prepare)
            const set_data = self.material_sets.getPtr(snap.set_name) orelse {
                log(.WARN, "material_system", "Material set '{s}' not found during render thread update", .{snap.set_name});
                continue;
            };

            // Apply texture descriptor updates if needed
            if (snap.texture_array_dirty) {
                // TRIPLE BUFFERING TEXTURE DESCRIPTOR ALLOCATION - CRITICAL DESIGN
                // =================================================================
                //
                // STRUCTURE OVERVIEW:
                //   - MaterialSetData.texture_arrays: [3]ManagedTextureArray
                //     └─ Each ManagedTextureArray.arena_offsets: [3]usize
                //
                // WHY THE DOUBLE ARRAY?
                // ---------------------
                // The outer [3] array exists because MaterialSetData needs one texture array
                // PER FRAME IN FLIGHT. Each rendering frame maintains its own texture array instance.
                //
                // The inner [3] offsets within EACH ManagedTextureArray track the per-frame
                // descriptor snapshots in the arena system.
                //
                // ALLOCATION PATTERN:
                // -------------------
                // This loop iterates frame_idx = 0, 1, 2:
                //   1. Get pointer to texture_arrays[frame_idx]
                //   2. Allocate NEW descriptors to frame_arenas[frame_idx]
                //   3. Store offset in texture_arrays[frame_idx].arena_offsets[frame_idx]
                //
                // Result after loop:
                //   texture_arrays[0].arena_offsets = [new_offset, old, old]  // Only [0] updated
                //   texture_arrays[1].arena_offsets = [old, new_offset, old]  // Only [1] updated
                //   texture_arrays[2].arena_offsets = [old, old, new_offset]  // Only [2] updated
                //
                // WHY NOT UPDATE ALL 3 OFFSETS IN EACH STRUCT?
                // ---------------------------------------------
                // Because each rendering frame (0, 1, 2) uses its OWN ManagedTextureArray instance
                // and only reads the offset at index matching its frame number.
                //
                // When frame 0 renders: reads texture_arrays[0].arena_offsets[0]
                // When frame 1 renders: reads texture_arrays[1].arena_offsets[1]
                // When frame 2 renders: reads texture_arrays[2].arena_offsets[2]
                //
                // The "unused" offsets in each struct ([1], [2] in texture_arrays[0], etc.)
                // are effectively dead space in this design, but kept for API consistency
                // with the ManagedTextureArray structure.
                //
                // COMPARISON TO MATERIAL BUFFERS:
                // -------------------------------
                // Material buffers use: material_buffers: [3]*ManagedBuffer
                //   - Each frame has a separate buffer allocation
                //   - Single generation counter per buffer
                //   - No nested arrays needed
                //
                // Texture descriptors use: texture_arrays: [3]ManagedTextureArray
                //   - Each frame has a separate texture array instance
                //   - Each instance stores [3] offsets (only uses one matching its frame number)
                //   - Nested arrays for consistency with potential future multi-frame tracking
                //
                // THE ACTUAL POINT OF [3] OFFSETS:
                // --------------------------------
                // While currently we only use arena_offsets[frame_idx] for texture_arrays[frame_idx],
                // the [3] offset design allows for future flexibility where a single ManagedTextureArray
                // could track multiple historical snapshots for temporal effects or debugging.
                //
                // For now, it's effectively: texture_arrays[i] uses only arena_offsets[i].
                //
                
                for (&set_data.texture_arrays, 0..) |*tex_array, frame_idx| {
                    const frame = @as(u32, @intCast(frame_idx));

                    // Allocate from this frame's descriptor arena and get offset
                    // Compaction is handled proactively at frame boundaries via descriptor_manager.beginFrame()
                    // If we get ArenaRequiresCompaction here, it means we've exhausted the arena mid-frame
                    const result = self.descriptor_manager.allocateFromFrame(
                        frame,
                        snap.texture_descriptors,
                    ) catch |err| {
                        if (err == error.ArenaRequiresCompaction) {
                            log(.ERROR, "material_system", "Frame {} descriptor arena exhausted mid-frame (capacity too small or fragmentation issue)", .{frame});
                        } else {
                            log(.ERROR, "material_system", "Failed to allocate texture descriptors for frame {}: {}", .{ frame, err });
                        }
                        return err;
                    };

                    // Store ONLY the offset for THIS frame (each frame has its own offset)
                    // Descriptors will be resolved dynamically when binding via getDescriptorsAtOffset
                    tex_array.arena_offsets[frame] = result.offset;
                    tex_array.size = snap.texture_count;

                    // Mark this frame's array as updated (increments generation, sets mask to 0b111)
                    tex_array.markUpdated();
                }
            }

            // Apply material buffer updates from delta
            if (snap.changed_materials.len > 0) {
                // Find max index to determine required capacity
                var max_index: u32 = 0;
                for (snap.changed_materials) |change| {
                    if (change.index > max_index) {
                        max_index = change.index;
                    }
                }
                const required_capacity = max_index + 1;

                // Check if we need to reallocate
                if (required_capacity > set_data.current_capacity) {
                    const new_size = required_capacity * @sizeOf(GPUMaterial);

                    // Reallocate each frame's buffer from arena
                    for (&set_data.material_buffers, 0..) |*buf_ptr, frame_idx| {
                        const frame = @as(u32, @intCast(frame_idx));
                        const buf = buf_ptr.*;

                        const alloc_result = self.buffer_manager.allocateFromFrameArena(
                            frame,
                            buf,
                            new_size,
                            @alignOf(GPUMaterial),
                        ) catch |err| {
                            if (err == error.ArenaRequiresCompaction) {
                                log(.WARN, "material_system", "Arena full for frame {}, creating dedicated buffer", .{frame});
                                // Fall back to dedicated buffer - free old buffer and create new dedicated one
                                self.allocator.free(buf.name);
                                self.allocator.destroy(buf);

                                const dedicated_name = try std.fmt.allocPrint(self.allocator, "material_buffer_{s}_frame{d}_dedicated", .{ snap.set_name, frame });
                                defer self.allocator.free(dedicated_name); // createBuffer duplicates the name
                                const dedicated = try self.buffer_manager.createBuffer(
                                    .{
                                        .name = dedicated_name,
                                        .size = new_size,
                                        .strategy = .device_local,
                                        .usage = .{ .storage_buffer_bit = true, .transfer_dst_bit = true },
                                    },
                                    frame,
                                );
                                buf_ptr.* = dedicated;
                                dedicated.markUpdated();
                                continue;
                            }
                            return err;
                        };

                        buf.buffer = alloc_result.buffer.buffer;
                        buf.arena_offset = alloc_result.offset;
                        buf.size = new_size;
                        buf.markUpdated();
                    }

                    set_data.current_capacity = required_capacity;
                }

                // Apply all material changes to all 3 frame buffers
                // OPTIMIZATION: Batch all updates in a single map/unmap per buffer
                for (&set_data.material_buffers) |buf| {
                    if (snap.changed_materials.len == 0) continue;

                    // Find the range of updates to determine map size
                    var min_idx: u32 = std.math.maxInt(u32);
                    var max_idx: u32 = 0;
                    for (snap.changed_materials) |change| {
                        min_idx = @min(min_idx, change.index);
                        max_idx = @max(max_idx, change.index);
                    }

                    // Map the entire range once
                    const range_start = buf.arena_offset + (min_idx * @sizeOf(GPUMaterial));
                    const range_size = ((max_idx - min_idx + 1) * @sizeOf(GPUMaterial));

                    try buf.buffer.map(range_size, range_start);
                    const base_ptr: [*]u8 = @ptrCast(buf.buffer.mapped.?);

                    // Write all changes to the mapped region
                    for (snap.changed_materials) |change| {
                        const local_offset = (change.index - min_idx) * @sizeOf(GPUMaterial);
                        const bytes = std.mem.asBytes(&change.data);
                        @memcpy(base_ptr[local_offset..][0..bytes.len], bytes);
                    }

                    buf.buffer.unmap();
                }
            }
        }
    }

    fn getTextureIndex(map: *std.AutoHashMap(u64, u32), texture_id: AssetId) ?u32 {
        const id_u64 = texture_id.toU64();
        if (id_u64 == 0) return 0;
        return map.get(id_u64);
    }

    /// MAIN THREAD: Prepare a specific material set (ECS queries + write component indices)
    /// NO GPU UPLOADS - only compute deltas for render thread
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

        // DON'T clear delta here - it will be cleared AFTER writeDeltasToComponent copies it
        // Clearing here would lose the delta if prepareFromECS is called multiple times per frame

        // OPTIMIZATION: Try to reuse existing texture map (Optimistic Path)
        // If the set of textures hasn't changed (or is a subset), we can skip collection/sorting/map building
        const optimistic_success = blk: {
            if (set_data.scratch_texture_map.count() == 0) break :blk false;

            // Clear scratch buffers for optimistic run
            set_data.scratch_gpu_materials.clearRetainingCapacity();
            // Note: We don't clear pending_delta here, assuming it's empty from prepareFromECS
            // But if we fail optimistic run, we must clear it.

            const gpu_materials = &set_data.scratch_gpu_materials;
            const texture_map = &set_data.scratch_texture_map;

            // Check if we need to reallocate (heuristic based on current capacity)
            const needs_realloc = entities.len > set_data.current_capacity;

            // Pre-allocate with known entity count
            try gpu_materials.ensureTotalCapacity(self.allocator, entities.len);

            for (entities) |entity| {
                // Batch get all material components at once
                const albedo = world.get(ecs.AlbedoMaterial, entity);
                const roughness = world.get(ecs.RoughnessMaterial, entity);
                const metallic = world.get(ecs.MetallicMaterial, entity);
                const normal = world.get(ecs.NormalMaterial, entity);
                const emissive = world.get(ecs.EmissiveMaterial, entity);
                const occlusion = world.get(ecs.OcclusionMaterial, entity);

                // Build GPU material using EXISTING map
                // If any texture is missing from map, abort optimistic path
                const gpu_mat = GPUMaterial{
                    .albedo_idx = if (albedo) |alb| (getTextureIndex(texture_map, alb.texture_id) orelse break :blk false) else 0,
                    .albedo_tint = if (albedo) |alb| alb.color_tint else [_]f32{ 1, 1, 1, 1 },
                    .roughness_idx = if (roughness) |rough| (getTextureIndex(texture_map, rough.texture_id) orelse break :blk false) else 0,
                    .roughness_factor = if (roughness) |rough| rough.factor else 0.5,
                    .metallic_idx = if (metallic) |metal| (getTextureIndex(texture_map, metal.texture_id) orelse break :blk false) else 0,
                    .metallic_factor = if (metallic) |metal| metal.factor else 0.0,
                    .normal_idx = if (normal) |norm| (getTextureIndex(texture_map, norm.texture_id) orelse break :blk false) else 0,
                    .normal_strength = if (normal) |norm| norm.strength else 1.0,
                    .emissive_idx = if (emissive) |emiss| (getTextureIndex(texture_map, emiss.texture_id) orelse break :blk false) else 0,
                    .emissive_color = if (emissive) |emiss| emiss.color else [_]f32{ 0, 0, 0 },
                    .emissive_intensity = if (emissive) |emiss| emiss.intensity else 0.0,
                    .occlusion_idx = if (occlusion) |occ| (getTextureIndex(texture_map, occ.texture_id) orelse break :blk false) else 0,
                    .occlusion_strength = if (occlusion) |occ| occ.strength else 1.0,
                };

                // CRITICAL: Write material_buffer_index to component
                const material_set = world.getMut(ecs.MaterialSet, entity) orelse continue;
                const mat_index: u32 = @intCast(gpu_materials.items.len);
                material_set.material_buffer_index = mat_index;

                // Fast change detection
                var changed = false;
                if (needs_realloc) {
                    changed = true;
                } else if (set_data.last_materials.get(entity)) |last_mat| {
                    if (!std.mem.eql(u8, std.mem.asBytes(&gpu_mat), std.mem.asBytes(&last_mat))) {
                        changed = true;
                    }
                } else {
                    changed = true;
                }

                if (changed) {
                    try set_data.pending_delta.changed_materials.append(self.allocator, .{
                        .index = mat_index,
                        .data = gpu_mat,
                    });
                }

                try gpu_materials.append(self.allocator, gpu_mat);
            }

            // If we got here, all textures were found in the map!
            break :blk true;
        };

        if (!optimistic_success) {
            // Fallback to Full Path (Collect -> Sort -> Build Map -> Build Materials)
            
            // Clear partial results from failed optimistic run
            set_data.pending_delta.clear();
            set_data.scratch_gpu_materials.clearRetainingCapacity();
            
            // 1. Collect unique texture IDs
            set_data.scratch_unique_textures.clearRetainingCapacity();
            var unique_textures = &set_data.scratch_unique_textures;
            try unique_textures.put(0, {});

            for (entities) |entity| {
                if (world.get(ecs.AlbedoMaterial, entity)) |c| try unique_textures.put(c.texture_id.toU64(), {});
                if (world.get(ecs.RoughnessMaterial, entity)) |c| try unique_textures.put(c.texture_id.toU64(), {});
                if (world.get(ecs.MetallicMaterial, entity)) |c| try unique_textures.put(c.texture_id.toU64(), {});
                if (world.get(ecs.NormalMaterial, entity)) |c| try unique_textures.put(c.texture_id.toU64(), {});
                if (world.get(ecs.EmissiveMaterial, entity)) |c| try unique_textures.put(c.texture_id.toU64(), {});
                if (world.get(ecs.OcclusionMaterial, entity)) |c| try unique_textures.put(c.texture_id.toU64(), {});
            }

            // 2. Sort IDs
            set_data.scratch_current_texture_ids.clearRetainingCapacity();
            var current_texture_ids = &set_data.scratch_current_texture_ids;
            try current_texture_ids.ensureTotalCapacity(self.allocator, unique_textures.count());
            var key_iter = unique_textures.keyIterator();
            while (key_iter.next()) |key| {
                current_texture_ids.appendAssumeCapacity(key.*);
            }
            std.sort.pdq(u64, current_texture_ids.items, {}, std.sort.asc(u64));

            // 3. Build texture map
            set_data.scratch_texture_map.clearRetainingCapacity();
            var texture_map = &set_data.scratch_texture_map;
            try texture_map.ensureTotalCapacity(@intCast(current_texture_ids.items.len));
            for (current_texture_ids.items, 0..) |id, i| {
                try texture_map.put(id, @intCast(i));
            }

            // 4. Build materials (same loop as optimistic, but guaranteed to succeed)
            var gpu_materials = &set_data.scratch_gpu_materials;
            const needs_realloc = entities.len > set_data.current_capacity;
            try gpu_materials.ensureTotalCapacity(self.allocator, entities.len);

            for (entities) |entity| {
                const albedo = world.get(ecs.AlbedoMaterial, entity);
                const roughness = world.get(ecs.RoughnessMaterial, entity);
                const metallic = world.get(ecs.MetallicMaterial, entity);
                const normal = world.get(ecs.NormalMaterial, entity);
                const emissive = world.get(ecs.EmissiveMaterial, entity);
                const occlusion = world.get(ecs.OcclusionMaterial, entity);

                const gpu_mat = GPUMaterial{
                    .albedo_idx = if (albedo) |alb| (texture_map.get(alb.texture_id.toU64()) orelse 0) else 0,
                    .albedo_tint = if (albedo) |alb| alb.color_tint else [_]f32{ 1, 1, 1, 1 },
                    .roughness_idx = if (roughness) |rough| (texture_map.get(rough.texture_id.toU64()) orelse 0) else 0,
                    .roughness_factor = if (roughness) |rough| rough.factor else 0.5,
                    .metallic_idx = if (metallic) |metal| (texture_map.get(metal.texture_id.toU64()) orelse 0) else 0,
                    .metallic_factor = if (metallic) |metal| metal.factor else 0.0,
                    .normal_idx = if (normal) |norm| (texture_map.get(norm.texture_id.toU64()) orelse 0) else 0,
                    .normal_strength = if (normal) |norm| norm.strength else 1.0,
                    .emissive_idx = if (emissive) |emiss| (texture_map.get(emiss.texture_id.toU64()) orelse 0) else 0,
                    .emissive_color = if (emissive) |emiss| emiss.color else [_]f32{ 0, 0, 0 },
                    .emissive_intensity = if (emissive) |emiss| emiss.intensity else 0.0,
                    .occlusion_idx = if (occlusion) |occ| (texture_map.get(occ.texture_id.toU64()) orelse 0) else 0,
                    .occlusion_strength = if (occlusion) |occ| occ.strength else 1.0,
                };

                const material_set = world.getMut(ecs.MaterialSet, entity) orelse continue;
                const mat_index: u32 = @intCast(gpu_materials.items.len);
                material_set.material_buffer_index = mat_index;

                var changed = false;
                if (needs_realloc) {
                    changed = true;
                } else if (set_data.last_materials.get(entity)) |last_mat| {
                    if (!std.mem.eql(u8, std.mem.asBytes(&gpu_mat), std.mem.asBytes(&last_mat))) {
                        changed = true;
                    }
                } else {
                    changed = true;
                }

                if (changed) {
                    try set_data.pending_delta.changed_materials.append(self.allocator, .{
                        .index = mat_index,
                        .data = gpu_mat,
                    });
                }

                try gpu_materials.append(self.allocator, gpu_mat);
            }
        }

        // Common post-processing
        const gpu_materials = &set_data.scratch_gpu_materials;
        const texture_map = &set_data.scratch_texture_map;
        
        // Determine current texture IDs for change detection
        var current_texture_ids_slice: []const u64 = undefined;
        if (optimistic_success) {
            // In optimistic path, we used the old map, so IDs are effectively the same as last frame
            current_texture_ids_slice = set_data.last_texture_ids.items;
        } else {
            // In full path, we rebuilt the list
            current_texture_ids_slice = set_data.scratch_current_texture_ids.items;
        }

        // Check if texture set changed
        const textures_changed = blk: {
            // Quick count check
            if (current_texture_ids_slice.len != set_data.last_texture_ids.items.len) break :blk true;

            // Fast memcmp for sorted IDs
            if (!std.mem.eql(u64, current_texture_ids_slice, set_data.last_texture_ids.items)) break :blk true;

            // Only check descriptor changes if IDs match (uncommon case)
            var tex_check_iter = texture_map.iterator();
            while (tex_check_iter.next()) |entry| {
                const asset_id_u64 = entry.key_ptr.*;
                const idx = entry.value_ptr.*;

                if (asset_id_u64 == 0 or idx == 0) continue;

                const asset_id = AssetId.fromU64(asset_id_u64);
                const current_descriptor = self.asset_manager.getTextureDescriptor(asset_id);

                // Resolve descriptors from arena to check if they changed
                if (current_descriptor != null and idx < set_data.texture_arrays[0].size) {
                    const descriptors = self.descriptor_manager.getDescriptorsAtOffset(
                        0, // Check frame 0's descriptors
                        set_data.texture_arrays[0].arena_offsets[0],
                        set_data.texture_arrays[0].size,
                    );
                    if (idx < descriptors.len) {
                        const last_descriptor = descriptors[idx];
                        if (current_descriptor.?.image_view != last_descriptor.image_view) {
                            break :blk true;
                        }
                    }
                }
            }

            break :blk false;
        };

        // Build texture descriptor array if changed (NO GPU UPLOAD - just prepare data)
        if (textures_changed) {
            try self.buildTextureDescriptorArray(set_data, texture_map, @intCast(current_texture_ids_slice.len));
            set_data.pending_delta.texture_array_dirty = true;

            // Update last_texture_ids only if we rebuilt them (Full Path)
            // If Optimistic Path, they are already same (conceptually)
            if (!optimistic_success) {
                set_data.last_texture_ids.clearRetainingCapacity();
                try set_data.last_texture_ids.appendSlice(self.allocator, current_texture_ids_slice);
            }
        }

        // Update last_materials hash map with current frame's entity->material mappings
        set_data.last_materials.clearRetainingCapacity();
        for (entities, 0..) |entity, i| {
            try set_data.last_materials.put(entity, gpu_materials.items[i]);
        }

        // Store the current materials for next frame
        set_data.next_materials.clearRetainingCapacity();
        try set_data.next_materials.appendSlice(self.allocator, gpu_materials.items);
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
                // Resolve descriptors from arena to check if they changed
                if (current_descriptor != null and idx < set_data.texture_arrays[0].size) {
                    const descriptors = self.descriptor_manager.getDescriptorsAtOffset(
                        0, // Check frame 0's descriptors
                        set_data.texture_arrays[0].arena_offsets[0],
                        set_data.texture_arrays[0].size,
                    );
                    if (idx < descriptors.len) {
                        const last_descriptor = descriptors[idx];
                        // Compare image views (main indicator that texture loaded)
                        if (current_descriptor.?.image_view != last_descriptor.image_view) {
                            break :blk true;
                        }
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

    /// Build texture descriptor array from texture map (NO GPU binding - just prepare data)
    fn buildTextureDescriptorArray(
        self: *MaterialSystem,
        set_data: *MaterialSetData,
        texture_map: *std.AutoHashMap(u64, u32),
        texture_count: u32,
    ) !void {
        // Free old pending delta texture array if exists
        if (set_data.pending_delta.texture_descriptors.len > 0) {
            self.allocator.free(set_data.pending_delta.texture_descriptors);
        }

        // Allocate new array for delta
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

        // Store in delta (no GPU update yet)
        set_data.pending_delta.texture_descriptors = descriptors;
        set_data.pending_delta.texture_count = texture_count;
    }

    /// Upload material buffer to GPU
    fn uploadMaterialBuffer(self: *MaterialSystem, set_data: *MaterialSetData, set_name: []const u8, materials: []const GPUMaterial) !void {
        _ = set_name;
        const size = materials.len * @sizeOf(GPUMaterial);

        // Only resize if we need MORE space (never shrink to avoid excessive resizes)
        if (set_data.material_buffer.size < size) {
            // log(.INFO, "material_system", "Resizing material buffer for set '{s}' from {} to {} bytes", .{
            //     set_name,
            //     set_data.material_buffer.size,
            //     size,
            // });

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

    /// Write pending deltas to MaterialDeltasSet singleton component
    /// This allows snapshot system to read deltas without accessing MaterialSystem directly
    /// Get or create material set data for render passes
    /// Returns direct access to MaterialSetData for binding
    /// If the set doesn't exist yet, creates an empty one
    pub fn getOrCreateSet(self: *MaterialSystem, set_name: []const u8) !*MaterialSetData {
        const gop = try self.material_sets.getOrPut(set_name);
        if (!gop.found_existing) {
            gop.value_ptr.* = try MaterialSetData.init(self.allocator, self.buffer_manager);
        }
        return gop.value_ptr;
    }

    /// Reset the material system (clear all sets)
    pub fn reset(self: *MaterialSystem) void {
        var iter = self.material_sets.valueIterator();
        while (iter.next()) |set_data| {
            set_data.deinit(self.buffer_manager);
        }
        self.material_sets.clearRetainingCapacity();
        log(.INFO, "material_system", "MaterialSystem reset", .{});
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
    // Get the snapshot from frame_info
    const snapshot = frame_info.snapshot orelse return;

    // Get the scene from world userdata
    const scene_ptr = world.getUserData("scene") orelse {
        log(.WARN, "material_system", "No scene in world userdata", .{});
        return;
    };
    const scene: *Scene = @ptrCast(@alignCast(scene_ptr));

    // Get material system from scene
    const material_system = scene.material_system orelse {
        log(.WARN, "material_system", "[UPDATE] No material system in scene", .{});
        return;
    };

    // Apply material deltas from snapshot (thread-safe)
    try material_system.applySnapshotDeltas(snapshot.material_deltas);
}
