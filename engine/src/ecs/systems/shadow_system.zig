const std = @import("std");
const vk = @import("vulkan");
const log = @import("../../utils/log.zig").log;
const Math = @import("../../utils/math.zig");

const World = @import("../world.zig").World;
const EntityId = @import("../entity_registry.zig").EntityId;
const Transform = @import("../components/transform.zig").Transform;
const PointLight = @import("../components/point_light.zig").PointLight;
const ShadowDataSet = @import("../components/shadow_data_set.zig").ShadowDataSet;
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
    // Start at 1 so first update always triggers (frame_generations start at 0)
    generation: u32 = 1,

    // Per-frame generation tracking - tracks what generation each frame buffer has
    // When snapshot.shadow_generation > frame_generations[frame], that buffer needs updating
    frame_generations: [MAX_FRAMES_IN_FLIGHT]u32 = .{0} ** MAX_FRAMES_IN_FLIGHT,

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

    /// Query ECS for shadow-casting lights, compute matrices, and store in ShadowDataSet
    /// The snapshot system will capture this data for each render frame
    pub fn prepareFromECS(self: *ShadowSystem, world: *World) !void {
        // Reset delta each frame
        self.pending_delta.reset(self.allocator);

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
        var any_change = false;
        if (new_light_count != self.active_light_count) {
            self.pending_delta.lights_changed = true;
            any_change = true;
            log(.DEBUG, "shadow_system", "Light count changed: {} -> {}", .{ self.active_light_count, new_light_count });
        }

        // Check each light for changes and update cache + compute matrices
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
            }

            // Check if position changed (comparing floats with tolerance)
            // Threshold 0.000001 = movement of ~0.001 units triggers update
            const old_pos = self.light_cache[i].position;
            const pos_diff = Math.Vec3.sub(new_pos, old_pos);
            const dist_sq = Math.Vec3.dot(pos_diff, pos_diff);
            const pos_changed = dist_sq > 0.000001; // Much more sensitive threshold

            if (slot_changed or pos_changed) {
                // Mark this light as dirty and recompute matrices
                try self.pending_delta.dirty_light_indices.append(self.allocator, idx);
                any_change = true;

                // Compute all 6 face view*projection matrices immediately (in prepare phase!)
                for (0..6) |face| {
                    const view = buildFaceViewMatrix(new_pos, @intCast(face));
                    self.light_cache[i].face_view_projs[face] = self.shadow_projection.mul(view);
                }
            }

            // Update cache
            self.light_cache[i].entity = entity;
            self.light_cache[i].position = new_pos;
            self.light_cache[i].active = true;
        }

        // Deactivate removed lights
        for (new_light_count..MAX_SHADOW_LIGHTS) |i| {
            if (self.light_cache[i].active) {
                self.light_cache[i].active = false;
                self.pending_delta.lights_changed = true;
                any_change = true;
            }
        }

        self.active_light_count = new_light_count;

        // Build GPU SSBO data from cache (always, so snapshot has latest data)
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

        // Update the ShadowDataSet singleton for snapshot capture
        if (any_change) {
            self.generation +%= 1;
        }

        const singleton_entity = try world.getOrCreateSingletonEntity();
        if (world.get(ShadowDataSet, singleton_entity)) |shadow_set| {
            shadow_set.gpu_ssbo = self.gpu_ssbo;
            shadow_set.legacy_shadow_data = self.legacy_shadow_data;
            shadow_set.active_light_count = self.active_light_count;
            shadow_set.changed = any_change;
            shadow_set.generation = self.generation;
        } else {
            // Create the component if it doesn't exist
            try world.emplace(ShadowDataSet, singleton_entity, ShadowDataSet{
                .gpu_ssbo = self.gpu_ssbo,
                .legacy_shadow_data = self.legacy_shadow_data,
                .active_light_count = self.active_light_count,
                .changed = any_change,
                .generation = self.generation,
            });
        }
    }

    // ========================================================================
    // Update Phase - Process changes (called from render thread)
    // ========================================================================

    /// Upload shadow data from snapshot to ALL GPU buffers when generation changes
    /// Matches material system pattern: update all frames at once for consistency
    pub fn processFromSnapshot(self: *ShadowSystem, frame_info: *FrameInfo) bool {
        const snapshot = frame_info.snapshot orelse return false;
        const current_frame = frame_info.current_frame;

        // Check if this snapshot has newer shadow data than what we've uploaded
        // Compare against current frame's generation to detect if ANY frame needs update
        if (snapshot.shadow_generation == self.frame_generations[current_frame]) {
            // This frame already has the latest data
            return false;
        }

        // Upload to ALL frame buffers at once (like material system does)
        if (self.buffers_initialized) {
            if (self.buffer_manager) |bm| {
                const data = std.mem.asBytes(&snapshot.shadow_gpu_ssbo);

                // Update all frame buffers to ensure consistency
                for (0..MAX_FRAMES_IN_FLIGHT) |i| {
                    const buffer = self.shadow_data_buffers[i];
                    bm.updateBuffer(buffer, data, @intCast(i)) catch |err| {
                        log(.WARN, "shadow_system", "Failed to update shadow SSBO frame {}: {}", .{ i, err });
                        continue;
                    };
                    // Mark buffer as updated - sets pending_bind_mask for descriptor rebinding
                    buffer.markUpdated();
                    // Mark this frame as having the latest generation
                    self.frame_generations[i] = snapshot.shadow_generation;
                }
            }
        }

        return true;
    }

    /// Legacy method - now just calls processFromSnapshot
    /// Returns true if anything changed
    pub fn processPendingChanges(self: *ShadowSystem, frame_index: u32) bool {
        _ = self;
        _ = frame_index;
        // This is now a no-op - use processFromSnapshot instead
        // Kept for backwards compatibility
        return false;
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

/// Update phase - upload shadow data from snapshot to GPU (render thread)
/// Uses triple-buffered snapshots for proper synchronization
pub fn update(world: *World, frame_info: *FrameInfo) !void {
    // Get the scene from world userdata
    const scene_ptr = world.getUserData("scene") orelse return;
    const scene: *Scene = @ptrCast(@alignCast(scene_ptr));

    // Use snapshot data for GPU upload
    if (scene.shadow_system) |shadow_system| {
        _ = shadow_system.processFromSnapshot(frame_info);
    }
}
