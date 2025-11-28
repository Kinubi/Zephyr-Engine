const std = @import("std");
const vk = @import("vulkan");
const log = @import("../../utils/log.zig").log;
const Math = @import("../../utils/math.zig");

const AssetManager = @import("../../assets/asset_manager.zig").AssetManager;
const AssetId = @import("../../assets/asset_manager.zig").AssetId;
const Texture = @import("../../core/texture.zig").Texture;
const TextureManager = @import("../../rendering/texture_manager.zig").TextureManager;
const ManagedTexture = @import("../../rendering/texture_manager.zig").ManagedTexture;
const World = @import("../../ecs.zig").World;
const Scene = @import("../../scene/scene.zig").Scene;
const FrameInfo = @import("../../rendering/frameinfo.zig").FrameInfo;
const ecs = @import("../../ecs.zig");
const Skybox = ecs.Skybox;

/// Skybox GPU data for rendering (matches shader UBO)
pub const SkyboxGPUData = extern struct {
    rotation: f32,
    exposure: f32,
    _pad0: [2]f32 = .{ 0, 0 },
    tint: [4]f32,
    source_type: i32,
    _pad1: [3]i32 = .{ 0, 0, 0 },
    sun_direction: [4]f32,
    ground_color: [4]f32,
    horizon_color: [4]f32,
    zenith_color: [4]f32,
};

/// SkyboxSystem manages environment map loading and skybox state
///
/// Two-phase update pattern (for SystemScheduler):
/// - prepare(): Query ECS for changes, detect if texture reload needed (main thread)
/// - update(): Process pending changes, load textures (render thread)
///
/// The environment map is stored as a ManagedTexture for automatic version tracking
/// when bound via ResourceBinder.
pub const SkyboxSystem = struct {
    allocator: std.mem.Allocator,
    asset_manager: *AssetManager,
    texture_manager: *TextureManager,

    // Managed environment texture (version tracked for ResourceBinder)
    env_texture: *ManagedTexture = undefined,
    env_asset_id: ?AssetId = null,

    // Cached GPU data (updated when skybox component changes)
    gpu_data: SkyboxGPUData = undefined,

    // Track which skybox entity is active
    active_entity: ?ecs.EntityId = null,

    // Pending state from prepare phase
    pending_path_hash: u64 = 0,
    pending_source_type: Skybox.SourceType = .equirectangular,
    pending_gpu_data: ?SkyboxGPUData = null,
    pending_texture_load: bool = false,

    // Current state for change detection
    current_path_hash: u64 = 0,

    // System generation - incremented on any change
    generation: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, asset_manager: *AssetManager, texture_manager: *TextureManager) !SkyboxSystem {
        // Create empty ManagedTexture with generation 0 for ResourceBinder tracking
        // The texture field is undefined until a real texture is loaded,
        // but generation = 0 tells ResourceBinder to skip the actual binding
        const env_texture = try allocator.create(ManagedTexture);
        env_texture.* = ManagedTexture{
            .texture = undefined, // Will be set when actual texture is loaded
            .name = "skybox_env_map",
            .format = .r16g16b16a16_sfloat,
            .extent = .{ .width = 1, .height = 1, .depth = 1 },
            .usage = .{ .sampled_bit = true },
            .samples = .{ .@"1_bit" = true },
            .created_frame = 0,
            .generation = 0, // Not loaded yet - ResourceBinder will skip binding
        };

        var system = SkyboxSystem{
            .allocator = allocator,
            .asset_manager = asset_manager,
            .texture_manager = texture_manager,
            .gpu_data = undefined,
            .env_texture = env_texture,
        };
        // Initialize gpu_data with zeroes
        system.gpu_data = std.mem.zeroes(SkyboxGPUData);
        return system;
    }

    pub fn deinit(self: *SkyboxSystem) void {
        // Free the ManagedTexture wrapper (not the actual texture - that's owned by asset_manager)
        self.allocator.destroy(self.env_texture);
    }

    // ========================================================================
    // Prepare Phase - Query ECS for changes (called from main thread)
    // ========================================================================

    /// Query ECS world for skybox changes
    /// Stores pending changes for update phase to process
    pub fn prepareFromECS(self: *SkyboxSystem, world: *World) !void {
        // Find active skybox in scene
        var active_skybox: ?*const Skybox = null;
        var active_entity: ?ecs.EntityId = null;

        var skybox_view = try world.view(Skybox);
        var iter = skybox_view.iterator();
        while (iter.next()) |entry| {
            const skybox = world.get(Skybox, entry.entity) orelse continue;
            if (skybox.is_active) {
                active_skybox = skybox;
                active_entity = entry.entity;
                break;
            }
        }

        // No active skybox
        if (active_skybox == null) {
            if (self.active_entity != null) {
                // Skybox was removed
                self.active_entity = null;
                self.pending_gpu_data = null;
                self.pending_texture_load = false;
                self.generation +%= 1;
            }
            return;
        }

        const skybox = active_skybox.?;

        // Build GPU data from component
        const new_gpu_data = SkyboxGPUData{
            .rotation = skybox.rotation,
            .exposure = skybox.exposure,
            .tint = .{ skybox.tint.x, skybox.tint.y, skybox.tint.z, 1.0 },
            .source_type = @intFromEnum(skybox.source_type),
            .sun_direction = .{ skybox.sun_direction.x, skybox.sun_direction.y, skybox.sun_direction.z, 0.0 },
            .ground_color = .{ skybox.ground_color.x, skybox.ground_color.y, skybox.ground_color.z, 1.0 },
            .horizon_color = .{ skybox.horizon_color.x, skybox.horizon_color.y, skybox.horizon_color.z, 1.0 },
            .zenith_color = .{ skybox.zenith_color.x, skybox.zenith_color.y, skybox.zenith_color.z, 1.0 },
        };

        // Check if texture path changed AND is confirmed
        const path = skybox.getTexturePath();
        const path_hash = std.hash.Wyhash.hash(0, path);
        const texture_changed = path_hash != self.current_path_hash or
            skybox.source_type != self.pending_source_type;

        // Check if GPU data changed (compare bytes)
        const old_bytes = std.mem.asBytes(&self.gpu_data);
        const new_bytes = std.mem.asBytes(&new_gpu_data);
        const gpu_data_changed = !std.mem.eql(u8, old_bytes, new_bytes);

        // Store pending state only if something changed
        self.active_entity = active_entity;
        self.pending_path_hash = path_hash;
        self.pending_source_type = skybox.source_type;

        // Only set pending_gpu_data if it actually changed
        if (gpu_data_changed) {
            self.pending_gpu_data = new_gpu_data;
        }

        // Only load texture if path is confirmed by user (Enter pressed)
        self.pending_texture_load = texture_changed and skybox.source_type != .procedural and path.len > 0 and skybox.path_confirmed;
    }

    // ========================================================================
    // Update Phase - Process changes (called from render thread)
    // ========================================================================

    /// Process pending changes from prepare phase
    /// Returns true if anything changed
    pub fn processPendingChanges(self: *SkyboxSystem, world: *World) !bool {
        // Early exit if nothing to do
        if (self.pending_gpu_data == null and !self.pending_texture_load) {
            return false;
        }

        var changed = false;

        // Update GPU data if changed
        if (self.pending_gpu_data) |pending_data| {
            self.gpu_data = pending_data;
            self.pending_gpu_data = null;
            changed = true;
        }

        // Load texture if needed
        if (self.pending_texture_load) {
            // Get the path from the active skybox component
            if (self.active_entity) |entity| {
                if (world.get(Skybox, entity)) |skybox| {
                    const path = skybox.getTexturePath();
                    if (try self.loadEnvironmentMap(path, skybox.source_type)) {
                        self.current_path_hash = self.pending_path_hash;
                    }
                }
            }
            self.pending_texture_load = false;
            changed = true;
        } else if (self.pending_source_type == .procedural and self.env_texture.generation > 0) {
            // Switching to procedural, reset texture to unloaded state
            self.env_texture.generation = 0;
            self.env_asset_id = null;
            self.current_path_hash = 0;
            changed = true;
        }

        if (changed) {
            self.generation +%= 1;
        }

        return changed;
    }

    /// Load an environment map from path using asset system
    /// Updates the ManagedTexture for version tracking
    fn loadEnvironmentMap(self: *SkyboxSystem, path: []const u8, source_type: Skybox.SourceType) !bool {
        _ = source_type;
        log(.INFO, "skybox_system", "Loading environment map: {s}", .{path});

        // Load HDR texture through asset manager (handles caching and hot reload)
        const result = self.asset_manager.loadHdrTextureSync(path) catch |err| {
            log(.WARN, "skybox_system", "Failed to load environment map '{s}': {}", .{ path, err });
            return false;
        };

        // Update existing ManagedTexture wrapper (always initialized in init)
        self.env_texture.* = ManagedTexture{
            .texture = result.texture.*,
            .name = "skybox_env_map",
            .format = result.texture.format,
            .extent = .{
                .width = result.texture.extent.width,
                .height = result.texture.extent.height,
                .depth = 1,
            },
            .usage = .{ .sampled_bit = true },
            .samples = .{ .@"1_bit" = true },
            .created_frame = 0,
            .generation = self.generation +% 1, // Increment to trigger rebind
        };

        self.env_asset_id = result.id;

        log(.INFO, "skybox_system", "Loaded environment map: {s} (asset_id={}, gen={})", .{ path, @intFromEnum(result.id), self.env_texture.generation });
        return true;
    }

    // ========================================================================
    // Accessors for render pass
    // ========================================================================

    /// Check if there's an active skybox
    pub fn hasActiveSkybox(self: *const SkyboxSystem) bool {
        return self.active_entity != null;
    }

    /// Check if skybox can render (has required resources)
    pub fn canRender(self: *const SkyboxSystem) bool {
        if (!self.hasActiveSkybox()) return false;

        // Procedural sky doesn't need a texture
        if (self.gpu_data.source_type == @intFromEnum(Skybox.SourceType.procedural)) {
            return true;
        }

        // Equirectangular/cubemap need a texture (generation > 0 means texture loaded)
        return self.env_texture.generation > 0;
    }

    /// Get the managed environment texture (for ResourceBinder binding)
    pub fn getEnvironmentTexture(self: *SkyboxSystem) *ManagedTexture {
        return self.env_texture;
    }

    /// Get current GPU data for UBO upload
    pub fn getGPUData(self: *const SkyboxSystem) SkyboxGPUData {
        return self.gpu_data;
    }

    /// Get overall system generation (for detecting any changes)
    pub fn getGeneration(self: *const SkyboxSystem) u32 {
        return self.generation;
    }
};

// ============================================================================
// System entry points for SystemScheduler
// ============================================================================

/// Prepare phase - query ECS for skybox changes (main thread)
pub fn prepare(world: *World, dt: f32) !void {
    _ = dt;

    // Get the scene from world userdata
    const scene_ptr = world.getUserData("scene") orelse return;
    const scene: *Scene = @ptrCast(@alignCast(scene_ptr));

    // Get skybox system from scene
    if (scene.skybox_system) |skybox_system| {
        try skybox_system.prepareFromECS(world);
    }
}

/// Update phase - process pending changes (render thread)
pub fn update(world: *World, frame_info: *FrameInfo) !void {
    _ = frame_info;

    // Get the scene from world userdata
    const scene_ptr = world.getUserData("scene") orelse return;
    const scene: *Scene = @ptrCast(@alignCast(scene_ptr));

    // Get skybox system from scene
    if (scene.skybox_system) |skybox_system| {
        _ = try skybox_system.processPendingChanges(world);
    }
}
