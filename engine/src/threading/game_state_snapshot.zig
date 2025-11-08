const std = @import("std");
const Math = @import("../utils/math.zig");
const ecs = @import("../ecs.zig");
const Camera = @import("../rendering/camera.zig").Camera;
const Transform = @import("../ecs/components/transform.zig").Transform;
const MeshRenderer = @import("../ecs/components/mesh_renderer.zig").MeshRenderer;
const AssetId = @import("../assets/asset_types.zig").AssetId;

const Allocator = std.mem.Allocator;

/// Flat, cache-friendly snapshot of game state for rendering.
/// Passed from main thread to render thread via double-buffering.
pub const GameStateSnapshot = struct {
    allocator: Allocator,

    // Frame metadata
    frame_index: u64,
    delta_time: f32,

    // Camera state (copied directly)
    camera_position: Math.Vec3,
    camera_view_matrix: Math.Mat4x4,
    camera_projection_matrix: Math.Mat4x4,
    camera_view_projection_matrix: Math.Mat4x4,

    // Entity data (flat arrays, cache-friendly)
    entities: []EntityRenderData,
    entity_count: usize,

    // Light data
    point_lights: []PointLightData,
    point_light_count: usize,

    // ImGui draw data (cloned from main thread for render thread)
    imgui_draw_data: ?*anyopaque, // Pointer to cloned ImDrawData

    // Particle system data (if needed)
    // particles: []ParticleData,

    pub const EntityRenderData = struct {
        entity_id: ecs.EntityId,
        transform: Math.Mat4x4, // World transform matrix
        model_asset: AssetId,
        material_buffer_index: ?u32, // Index into MaterialSystem's per-set material buffer
        texture_asset: ?AssetId,
        layer: u8,
        casts_shadows: bool,
        receives_shadows: bool,
    };

    pub const PointLightData = struct {
        position: Math.Vec3,
        color: Math.Vec3,
        intensity: f32,
        radius: f32,
    };

    pub fn init(allocator: Allocator) GameStateSnapshot {
        return .{
            .allocator = allocator,
            .frame_index = 0,
            .delta_time = 0.0,
            .camera_position = Math.Vec3.zero(),
            .camera_view_matrix = Math.Mat4x4.identity(),
            .camera_projection_matrix = Math.Mat4x4.identity(),
            .camera_view_projection_matrix = Math.Mat4x4.identity(),
            .entities = &.{},
            .entity_count = 0,
            .point_lights = &.{},
            .point_light_count = 0,
            .imgui_draw_data = null,
        };
    }

    pub fn deinit(self: *GameStateSnapshot) void {
        if (self.entities.len > 0) {
            self.allocator.free(self.entities);
        }
        if (self.point_lights.len > 0) {
            self.allocator.free(self.point_lights);
        }
        // Note: imgui_draw_data cleanup handled by ImGuiContext
        self.* = undefined;
    }
};

/// Captures current game state from ECS World into a flat snapshot.
/// This function is called by the main thread before signaling the render thread.
/// Capture a snapshot of the current game state for rendering
pub fn captureSnapshot(
    allocator: Allocator,
    world: *ecs.World,
    camera: anytype,
    frame_index: u64,
    delta_time: f32,
    imgui_draw_data: ?*anyopaque, // ImGui draw data from UI layer
) !GameStateSnapshot {
    var snapshot = GameStateSnapshot{
        .allocator = allocator,
        .frame_index = frame_index,
        .delta_time = delta_time,
        .imgui_draw_data = imgui_draw_data,
        .camera_position = undefined,
        .camera_view_matrix = undefined,
        .camera_projection_matrix = undefined,
        .camera_view_projection_matrix = undefined,
        .entities = undefined,
        .entity_count = 0,
        .point_lights = undefined,
        .point_light_count = 0,
    };

    // Copy camera state
    // Camera position is stored in the translation column of inverseViewMatrix
    snapshot.camera_position = .{
        .x = camera.inverseViewMatrix.get(3, 0).*,
        .y = camera.inverseViewMatrix.get(3, 1).*,
        .z = camera.inverseViewMatrix.get(3, 2).*,
    };
    snapshot.camera_view_matrix = camera.viewMatrix;
    snapshot.camera_projection_matrix = camera.projectionMatrix;
    snapshot.camera_view_projection_matrix = snapshot.camera_projection_matrix.mul(snapshot.camera_view_matrix);

    // Query for entities with MeshRenderer (they may or may not have Transform)
    const mesh_view = try world.view(MeshRenderer);
    const renderable_entities = mesh_view.storage.entities.items;

    // Allocate array for entity data
    snapshot.entities = try allocator.alloc(GameStateSnapshot.EntityRenderData, renderable_entities.len);

    // Extract entity data
    var entity_index: usize = 0;
    for (renderable_entities) |entity| {
        const renderer = world.get(MeshRenderer, entity) orelse continue;

        // Skip disabled renderers or those without a model
        if (!renderer.enabled or renderer.model_asset == null) continue;

        // Get transform (default to identity if missing)
        const transform = world.get(Transform, entity);
        const world_matrix = if (transform) |t| t.world_matrix else Math.Mat4x4.identity();

        // Get material buffer index from MaterialSet component
        const material_set = world.get(ecs.MaterialSet, entity);
        const material_buffer_index = if (material_set) |ms| ms.material_buffer_index else null;

        // Store entity render data
        snapshot.entities[entity_index] = .{
            .entity_id = entity,
            .transform = world_matrix,
            .model_asset = renderer.model_asset.?,
            .material_buffer_index = material_buffer_index,
            .texture_asset = renderer.texture_asset,
            .layer = renderer.layer,
            .casts_shadows = renderer.casts_shadows,
            .receives_shadows = renderer.receives_shadows,
        };
        entity_index += 1;
    }
    snapshot.entity_count = entity_index;

    // TODO: Extract light data from PointLight components - MEDIUM PRIORITY
    // PointLight component exists (engine/src/ecs/components/point_light.zig)
    // Need to query entities with PointLight component and extract to snapshot
    // Required: Iterate over entities with (Transform, PointLight), populate point_lights array
    // Branch: features/light-snapshot-extraction
    snapshot.point_lights = try allocator.alloc(GameStateSnapshot.PointLightData, 0);
    snapshot.point_light_count = 0;

    return snapshot;
}

/// Helper to free a snapshot (called when overwriting old buffer)
pub fn freeSnapshot(snapshot: *GameStateSnapshot) void {
    const allocator = snapshot.allocator;
    snapshot.deinit();
    snapshot.* = GameStateSnapshot.init(allocator);
}
