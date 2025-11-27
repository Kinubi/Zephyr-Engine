const std = @import("std");
const vk = @import("vulkan");
const log = @import("../../utils/log.zig").log;
const Math = @import("../../utils/math.zig");

const World = @import("../world.zig").World;
const EntityId = @import("../entity_registry.zig").EntityId;
const Transform = @import("../components/transform.zig").Transform;
const PointLight = @import("../components/point_light.zig").PointLight;
const Scene = @import("../../scene/scene.zig").Scene;
const FrameInfo = @import("../../rendering/frameinfo.zig").FrameInfo;
const BufferManager = @import("../../rendering/buffer_manager.zig").BufferManager;
const BufferConfig = @import("../../rendering/buffer_manager.zig").BufferConfig;
const ManagedBuffer = @import("../../rendering/buffer_manager.zig").ManagedBuffer;
const MAX_FRAMES_IN_FLIGHT = @import("../../core/swapchain.zig").MAX_FRAMES_IN_FLIGHT;

/// Maximum number of shadow-casting point lights
pub const MAX_SHADOW_LIGHTS: u32 = 8;

/// Shadow map resolution (square, per face)
pub const SHADOW_MAP_SIZE: u32 = 1024;

/// Near and far planes for shadow cube projection
pub const SHADOW_NEAR: f32 = 0.1;
pub const SHADOW_FAR: f32 = 50.0;

/// Per-light shadow data for GPU SSBO (all data needed for shadow map rendering)
/// Contains light position and all 6 face view*projection matrices
pub const ShadowLightGPU = extern struct {
    light_pos: [4]f32 = .{ 0, 0, 0, 0 }, // xyz = position, w = far plane
    shadow_bias: f32 = 0.001,
    shadow_enabled: u32 = 0,
    light_index: u32 = 0, // Index into shadow cube array
    _padding: f32 = 0,
    // 6 face view*projection matrices (each 64 bytes = 16 floats)
    face_view_projs: [6][16]f32 = .{Math.Mat4x4.identity().data} ** 6,
};

/// Shadow data SSBO layout for GPU
/// Header + array of lights with all their data
pub const ShadowDataSSBO = extern struct {
    num_shadow_lights: u32 = 0,
    _padding: [3]u32 = .{ 0, 0, 0 },
    lights: [MAX_SHADOW_LIGHTS]ShadowLightGPU = .{ShadowLightGPU{}} ** MAX_SHADOW_LIGHTS,
};

/// Legacy single-light shadow data (for geometry pass UBO - backwards compatibility)
pub const ShadowData = extern struct {
    light_pos: [4]f32 = .{ 0, 0, 0, 0 }, // xyz = position, w = far plane
    shadow_bias: f32 = 0.02,
    shadow_enabled: u32 = 0,
    _padding: [2]f32 = .{ 0, 0 },
};

/// Cached light data for change detection and rendering
pub const ShadowLightCache = struct {
    entity: EntityId = EntityId.make(0, 0),
    position: Math.Vec3 = Math.Vec3.init(0, 0, 0),
    /// Pre-computed view*projection matrices for all 6 faces
    face_view_projs: [6]Math.Mat4x4 = .{Math.Mat4x4.identity()} ** 6,
    /// ECS version when last updated (for change detection)
    last_version: u32 = 0,
    /// Whether this slot is active
    active: bool = false,
};

/// Delta describing which lights need shadow map updates
pub const ShadowDelta = struct {
    /// Indices of lights that need their shadow maps re-rendered
    dirty_light_indices: std.ArrayListUnmanaged(u32) = .{},
    /// Whether the light list itself changed (added/removed)
    lights_changed: bool = false,
    /// Total active shadow lights
    active_count: u32 = 0,

    pub fn reset(self: *ShadowDelta, allocator: std.mem.Allocator) void {
        self.dirty_light_indices.clearRetainingCapacity();
        _ = allocator;
        self.lights_changed = false;
        self.active_count = 0;
    }

    pub fn deinit(self: *ShadowDelta, allocator: std.mem.Allocator) void {
        self.dirty_light_indices.deinit(allocator);
    }
};

/// Opaque handle to shadow GPU resources (buffer references)
/// ShadowMapPass uses this without knowing ShadowSystem internals
pub const ShadowGPUResources = struct {
    shadow_data_buffers: *const [MAX_FRAMES_IN_FLIGHT]*ManagedBuffer,
    max_shadow_lights: u32,
};

/// ShadowSystem manages shadow-casting lights with efficient change detection
///
/// Two-phase update pattern (for SystemScheduler):
/// - prepare(): Query ECS for shadow lights, detect moved/added/removed lights (main thread)
/// - update(): Recompute view matrices only for changed lights, update GPU buffer (render thread)
///
/// The system maintains a cache of light positions and pre-computed view*projection matrices.
/// Only lights whose Transform changed since last frame have their matrices recomputed.
pub const ShadowSystem = struct {
    allocator: std.mem.Allocator,
    buffer_manager: ?*BufferManager = null,

    // Light cache (persistent across frames)
    light_cache: [MAX_SHADOW_LIGHTS]ShadowLightCache = .{ShadowLightCache{}} ** MAX_SHADOW_LIGHTS,
    active_light_count: u32 = 0,

    // Shared projection matrix (same for all lights/faces - 90° FOV)
    shadow_projection: Math.Mat4x4,

    // Pending delta from prepare phase
    pending_delta: ShadowDelta = .{},

    // GPU SSBO buffers (one per frame in flight) - contains all light data
    shadow_data_buffers: [MAX_FRAMES_IN_FLIGHT]*ManagedBuffer = undefined,
    buffers_initialized: bool = false,

    // Current GPU buffer data (CPU-side copy for upload)
    gpu_ssbo: ShadowDataSSBO = .{},

    // Legacy single-light data (for geometry pass UBO - backwards compatibility)
    legacy_shadow_data: ShadowData = .{},

    // Change tracking
    last_transform_version: u32 = 0,
    last_light_version: u32 = 0,

    // System generation - incremented on any change
    generation: u32 = 0,

    // Track which frame buffers have been initialized with data
    // Each bit corresponds to a frame index - set when that buffer is updated
    frame_buffers_initialized: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) ShadowSystem {
        return .{
            .allocator = allocator,
            .shadow_projection = buildShadowProjection(),
        };
    }

    /// Initialize GPU buffers (called when BufferManager becomes available)
    pub fn initGPUBuffers(self: *ShadowSystem, buffer_manager: *BufferManager) !void {
        if (self.buffers_initialized) return;

        self.buffer_manager = buffer_manager;

        // Create shadow data SSBO buffers (one per frame) - contains all lights with view_proj matrices
        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            self.shadow_data_buffers[i] = try buffer_manager.createBuffer(
                BufferConfig{
                    .name = "shadow_data_ssbo",
                    .size = @sizeOf(ShadowDataSSBO),
                    .usage = .{ .storage_buffer_bit = true },
                    .strategy = .host_visible,
                },
                @intCast(i),
            );
        }

        self.buffers_initialized = true;
        log(.INFO, "shadow_system", "Initialized {} shadow data buffers", .{MAX_FRAMES_IN_FLIGHT});
    }

    pub fn deinit(self: *ShadowSystem) void {
        log(.INFO, "shadow_system", "deinit called, buffers_initialized={}", .{self.buffers_initialized});

        // Clean up pending delta
        self.pending_delta.deinit(self.allocator);

        if (self.buffers_initialized) {
            if (self.buffer_manager) |bm| {
                log(.INFO, "shadow_system", "Destroying {} shadow data buffers", .{MAX_FRAMES_IN_FLIGHT});
                for (0..MAX_FRAMES_IN_FLIGHT) |i| {
                    bm.destroyBuffer(self.shadow_data_buffers[i]) catch |err| {
                        log(.WARN, "shadow_system", "Failed to destroy buffer {}: {}", .{ i, err });
                    };
                }
            } else {
                log(.WARN, "shadow_system", "buffer_manager is null, cannot destroy buffers!", .{});
            }
            self.buffers_initialized = false;
        }
    }

    /// Get GPU resources for rendering (opaque handle)
    pub fn getGPUResources(self: *ShadowSystem) ?ShadowGPUResources {
        if (!self.buffers_initialized) return null;
        return .{
            .shadow_data_buffers = &self.shadow_data_buffers,
            .max_shadow_lights = MAX_SHADOW_LIGHTS,
        };
    }

    // ========================================================================
    // Prepare Phase - Query ECS for changes (called from main thread)
    // ========================================================================

    /// Query ECS for shadow-casting lights and detect changes
    /// Stores pending delta for update phase to process
    pub fn prepareFromECS(self: *ShadowSystem, world: *World) !void {
        // Only reset delta if all frame buffers have been initialized
        // Otherwise we lose the "dirty" state before all buffers are updated
        const all_frames_init = self.frame_buffers_initialized == ((@as(u32, 1) << MAX_FRAMES_IN_FLIGHT) - 1);
        if (all_frames_init) {
            self.pending_delta.reset(self.allocator);
        }

        // Query for all shadow-casting lights (include EntityId to track which entity)
        var query = world.query(struct {
            entity: EntityId,
            transform: *Transform,
            light: *PointLight,
        }) catch |err| {
            log(.WARN, "shadow_system", "Failed to query lights: {}", .{err});
            return;
        };
        defer query.deinit();

        // Collect active shadow lights
        var new_light_count: u32 = 0;
        var found_entities: [MAX_SHADOW_LIGHTS]EntityId = undefined;
        var found_positions: [MAX_SHADOW_LIGHTS]Math.Vec3 = undefined;

        while (query.next()) |data| {
            if (!data.light.cast_shadows) continue;
            if (new_light_count >= MAX_SHADOW_LIGHTS) {
                log(.WARN, "shadow_system", "Exceeded max shadow lights ({}), some will be ignored", .{MAX_SHADOW_LIGHTS});
                break;
            }

            const pos = Math.Vec3.init(
                data.transform.position.x,
                data.transform.position.y,
                data.transform.position.z,
            );

            found_entities[new_light_count] = data.entity;
            found_positions[new_light_count] = pos;
            new_light_count += 1;
        }

        self.pending_delta.active_count = new_light_count;

        // Detect if light list changed (added/removed)
        if (new_light_count != self.active_light_count) {
            self.pending_delta.lights_changed = true;
            log(.DEBUG, "shadow_system", "Light count changed: {} -> {}", .{ self.active_light_count, new_light_count });
        }

        // Check each light for changes
        for (0..new_light_count) |i| {
            const idx: u32 = @intCast(i);
            const entity = found_entities[i];
            const new_pos = found_positions[i];

            // Check if this slot's entity changed or slot was inactive
            var slot_changed = false;
            if (!self.light_cache[i].active or
                !std.meta.eql(self.light_cache[i].entity, entity))
            {
                slot_changed = true;
                self.pending_delta.lights_changed = true;
                log(.DEBUG, "shadow_system", "Light {} slot changed (was_active={}, entity_match={})", .{
                    i,
                    self.light_cache[i].active,
                    std.meta.eql(self.light_cache[i].entity, entity),
                });
            }

            // Check if position changed (comparing floats with tolerance)
            const old_pos = self.light_cache[i].position;
            const pos_diff = Math.Vec3.sub(new_pos, old_pos);
            const pos_changed = Math.Vec3.dot(pos_diff, pos_diff) > 0.0001;

            if (slot_changed or pos_changed) {
                // Mark this light as dirty
                try self.pending_delta.dirty_light_indices.append(self.allocator, idx);
                log(.DEBUG, "shadow_system", "Marked light {} dirty (slot_changed={}, pos_changed={})", .{ i, slot_changed, pos_changed });
            }

            // Update cache immediately (prepare can modify state)
            self.light_cache[i].entity = entity;
            self.light_cache[i].position = new_pos;
            self.light_cache[i].active = true;
        }

        // Deactivate removed lights
        for (new_light_count..MAX_SHADOW_LIGHTS) |i| {
            if (self.light_cache[i].active) {
                self.light_cache[i].active = false;
                self.pending_delta.lights_changed = true;
            }
        }

        self.active_light_count = new_light_count;
    }

    // ========================================================================
    // Update Phase - Process changes (called from render thread)
    // ========================================================================

    /// Process pending delta: recompute view matrices for dirty lights and update GPU buffers
    /// frame_index specifies which buffer to update
    /// Returns true if anything changed
    pub fn processPendingChanges(self: *ShadowSystem, frame_index: u32) bool {
        const delta = &self.pending_delta;

        // Check if this frame buffer needs initialization
        const frame_bit: u32 = @as(u32, 1) << @intCast(frame_index);
        const frame_needs_init = (self.frame_buffers_initialized & frame_bit) == 0;

        // Early exit if nothing changed AND this frame buffer is already initialized
        if (delta.dirty_light_indices.items.len == 0 and !delta.lights_changed and !frame_needs_init) {
            return false;
        }

        log(.DEBUG, "shadow_system", "processPendingChanges: frame={}, dirty={}, lights_changed={}, frame_needs_init={}", .{
            frame_index,
            delta.dirty_light_indices.items.len,
            delta.lights_changed,
            frame_needs_init,
        });

        // If frame needs init, compute matrices for ALL active lights (not just dirty ones)
        // This ensures all frame buffers have complete data
        if (frame_needs_init) {
            for (0..self.active_light_count) |i| {
                const cache = &self.light_cache[i];
                if (!cache.active) continue;

                // Compute all 6 face view*projection matrices
                for (0..6) |face| {
                    const view = buildFaceViewMatrix(cache.position, @intCast(face));
                    cache.face_view_projs[face] = self.shadow_projection.mul(view);
                }

                log(.DEBUG, "shadow_system", "Init: Computed view matrices for light {} at ({d:.2}, {d:.2}, {d:.2})", .{
                    i, cache.position.x, cache.position.y, cache.position.z,
                });
            }
        } else {
            // Only recompute for dirty lights
            for (delta.dirty_light_indices.items) |light_idx| {
                if (light_idx >= MAX_SHADOW_LIGHTS) continue;

                const cache = &self.light_cache[light_idx];
                if (!cache.active) continue;

                // Compute all 6 face view*projection matrices
                for (0..6) |face| {
                    const view = buildFaceViewMatrix(cache.position, @intCast(face));
                    cache.face_view_projs[face] = self.shadow_projection.mul(view);
                }

                log(.DEBUG, "shadow_system", "Recomputed view matrices for light {} at ({d:.2}, {d:.2}, {d:.2})", .{
                    light_idx, cache.position.x, cache.position.y, cache.position.z,
                });
            }
        }

        // Update GPU SSBO struct with all light data including view_proj matrices
        self.gpu_ssbo.num_shadow_lights = self.active_light_count;
        for (0..MAX_SHADOW_LIGHTS) |i| {
            const cache = &self.light_cache[i];
            self.gpu_ssbo.lights[i] = ShadowLightGPU{
                .light_pos = .{ cache.position.x, cache.position.y, cache.position.z, SHADOW_FAR },
                .shadow_bias = 0.001,
                .shadow_enabled = if (cache.active) 1 else 0,
                .light_index = @intCast(i),
                .face_view_projs = .{
                    cache.face_view_projs[0].data,
                    cache.face_view_projs[1].data,
                    cache.face_view_projs[2].data,
                    cache.face_view_projs[3].data,
                    cache.face_view_projs[4].data,
                    cache.face_view_projs[5].data,
                },
            };
        }

        // Update legacy single-light data (first shadow light) for geometry pass
        if (self.active_light_count > 0) {
            const first = &self.light_cache[0];
            self.legacy_shadow_data = ShadowData{
                .light_pos = .{ first.position.x, first.position.y, first.position.z, SHADOW_FAR },
                .shadow_bias = 0.001,
                .shadow_enabled = 1,
            };
        } else {
            self.legacy_shadow_data = ShadowData{
                .shadow_enabled = 0,
            };
        }

        // Upload SSBO to GPU buffer for this frame
        if (self.buffers_initialized and frame_index < MAX_FRAMES_IN_FLIGHT) {
            if (self.buffer_manager) |bm| {
                const buffer = self.shadow_data_buffers[frame_index];
                const data = std.mem.asBytes(&self.gpu_ssbo);
                bm.updateBuffer(buffer, data, frame_index) catch |err| {
                    log(.WARN, "shadow_system", "Failed to update shadow SSBO: {}", .{err});
                };
                // Mark this frame buffer as initialized
                self.frame_buffers_initialized |= (@as(u32, 1) << @intCast(frame_index));
            }
        }

        // Handle lights_changed: need to update all frame buffers
        // We track this separately so we don't keep resetting frame_buffers_initialized
        if (delta.lights_changed) {
            log(.INFO, "shadow_system", "Shadow lights changed: {} active", .{self.active_light_count});
            // Clear lights_changed but keep dirty indices until all frames are updated
            self.pending_delta.lights_changed = false;
        }

        // Check if all frame buffers are now initialized
        const all_frames_mask: u32 = (@as(u32, 1) << MAX_FRAMES_IN_FLIGHT) - 1;
        if (self.frame_buffers_initialized == all_frames_mask) {
            // All frames have valid data - clear the pending delta
            const cleared_count = self.pending_delta.dirty_light_indices.items.len;
            self.pending_delta.dirty_light_indices.clearRetainingCapacity();
            if (cleared_count > 0) {
                log(.INFO, "shadow_system", "All {} frame buffers initialized, cleared {} dirty indices", .{ MAX_FRAMES_IN_FLIGHT, cleared_count });
            }
        }

        self.generation +%= 1;

        return true;
    }

    // ========================================================================
    // Accessors for render pass
    // ========================================================================

    /// Get the number of active shadow-casting lights
    pub fn getActiveLightCount(self: *const ShadowSystem) u32 {
        return self.active_light_count;
    }

    /// Get cached light data for a specific light index
    pub fn getLightCache(self: *const ShadowSystem, index: u32) ?*const ShadowLightCache {
        if (index >= MAX_SHADOW_LIGHTS or !self.light_cache[index].active) {
            return null;
        }
        return &self.light_cache[index];
    }

    /// Get the pre-computed view*projection matrix for a light's face
    pub fn getFaceViewProj(self: *const ShadowSystem, light_index: u32, face: u32) ?Math.Mat4x4 {
        if (light_index >= MAX_SHADOW_LIGHTS or face >= 6) return null;
        if (!self.light_cache[light_index].active) return null;
        return self.light_cache[light_index].face_view_projs[face];
    }

    /// Get GPU SSBO data
    pub fn getGPUSSBO(self: *const ShadowSystem) *const ShadowDataSSBO {
        return &self.gpu_ssbo;
    }

    /// Get legacy single-light shadow data (for geometry pass UBO)
    pub fn getLegacyShadowData(self: *const ShadowSystem) *const ShadowData {
        return &self.legacy_shadow_data;
    }

    /// Get managed buffer for a specific frame (for render pass binding)
    pub fn getShadowDataBuffer(self: *const ShadowSystem, frame: u32) ?*ManagedBuffer {
        if (!self.buffers_initialized) return null;
        if (frame >= MAX_FRAMES_IN_FLIGHT) return null;
        return self.shadow_data_buffers[frame];
    }

    /// Get indices of lights that need shadow map re-rendering this frame
    pub fn getDirtyLightIndices(self: *const ShadowSystem) []const u32 {
        return self.pending_delta.dirty_light_indices.items;
    }

    /// Check if any lights changed (for full shadow map rebuild)
    pub fn didLightsChange(self: *const ShadowSystem) bool {
        return self.pending_delta.lights_changed;
    }

    /// Get system generation (for change detection)
    pub fn getGeneration(self: *const ShadowSystem) u32 {
        return self.generation;
    }

    // ========================================================================
    // Matrix builders (pure functions, can be called in parallel)
    // ========================================================================

    /// Build perspective projection matrix for cube shadow map (90 degree FOV)
    /// Uses Vulkan conventions: Z range [0,1], Y flipped
    fn buildShadowProjection() Math.Mat4x4 {
        const aspect: f32 = 1.0; // Square faces
        const fov: f32 = std.math.pi / 2.0; // 90 degrees - required for cube maps
        const near = SHADOW_NEAR;
        const far = SHADOW_FAR;

        const tan_half_fov = @tan(fov / 2.0);
        var proj = Math.Mat4x4.identity();
        proj.data[0] = 1.0 / (aspect * tan_half_fov);
        proj.data[5] = -1.0 / tan_half_fov; // Negative for Vulkan Y-flip
        proj.data[10] = far / (far - near); // Vulkan depth range [0,1]
        proj.data[11] = 1.0;
        proj.data[14] = -(far * near) / (far - near);
        proj.data[15] = 0.0;
        return proj;
    }

    /// Build view matrix for a cube face.
    ///
    /// Cube map face indices: 0=+X, 1=-X, 2=+Y, 3=-Y, 4=+Z, 5=-Z
    ///
    /// Standard cube map convention - look toward face direction.
    pub fn buildFaceViewMatrix(light_pos: Math.Vec3, face: u32) Math.Mat4x4 {
        // Look toward face direction - but X faces are swapped to match cube map convention
        const directions = [6]Math.Vec3{
            Math.Vec3.init(-1, 0, 0), // Face 0 (+X): look toward -X (swapped)
            Math.Vec3.init(1, 0, 0), // Face 1 (-X): look toward +X (swapped)
            Math.Vec3.init(0, 1, 0), // Face 2 (+Y): look toward +Y
            Math.Vec3.init(0, -1, 0), // Face 3 (-Y): look toward -Y
            Math.Vec3.init(0, 0, 1), // Face 4 (+Z): look toward +Z
            Math.Vec3.init(0, 0, -1), // Face 5 (-Z): look toward -Z
        };

        // Up vectors - standard for cube maps
        const ups = [6]Math.Vec3{
            Math.Vec3.init(0, -1, 0), // +X: up is -Y
            Math.Vec3.init(0, -1, 0), // -X: up is -Y
            Math.Vec3.init(0, 0, 1), // +Y: up is +Z
            Math.Vec3.init(0, 0, -1), // -Y: up is -Z
            Math.Vec3.init(0, -1, 0), // +Z: up is -Y
            Math.Vec3.init(0, -1, 0), // -Z: up is -Y
        };

        const target = Math.Vec3.add(light_pos, directions[face]);
        return Math.Mat4x4.lookAt(light_pos, target, ups[face]);
    }
};

// ============================================================================
// System entry points for SystemScheduler
// ============================================================================

/// Prepare phase - query ECS for shadow light changes (main thread)
pub fn prepare(world: *World, dt: f32) !void {
    _ = dt;

    // Get the scene from world userdata
    const scene_ptr = world.getUserData("scene") orelse return;
    const scene: *Scene = @ptrCast(@alignCast(scene_ptr));

    // Get shadow system from scene
    if (scene.shadow_system) |shadow_system| {
        try shadow_system.prepareFromECS(world);
    }
}

/// Update phase - process pending changes and recompute matrices (render thread)
pub fn update(world: *World, frame_info: *FrameInfo) !void {
    // Get the scene from world userdata
    const scene_ptr = world.getUserData("scene") orelse return;
    const scene: *Scene = @ptrCast(@alignCast(scene_ptr));

    // Get shadow system from scene
    if (scene.shadow_system) |shadow_system| {
        _ = shadow_system.processPendingChanges(frame_info.current_frame);
    }
}
