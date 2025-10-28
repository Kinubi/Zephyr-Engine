const std = @import("std");
const Allocator = std.mem.Allocator;
const Math = @import("../utils/math.zig");

const ecs = @import("../ecs.zig");
const Camera = @import("../rendering/camera.zig").Camera;
const Transform = @import("../ecs/components/transform.zig").Transform;
const MeshRenderer = @import("../ecs/components/mesh_renderer.zig").MeshRenderer;
const AssetId = @import("../assets/asset_types.zig").AssetId;

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
    
    // Particle system data (if needed)
    // particles: []ParticleData,
    
    pub const EntityRenderData = struct {
        entity_id: ecs.EntityId,
        transform: Math.Mat4x4,  // World transform matrix
        model_asset: AssetId,
        material_asset: ?AssetId,
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
        };
    }
    
    pub fn deinit(self: *GameStateSnapshot) void {
        if (self.entities.len > 0) {
            self.allocator.free(self.entities);
        }
        if (self.point_lights.len > 0) {
            self.allocator.free(self.point_lights);
        }
        self.* = undefined;
    }
};

/// Captures current game state from ECS World into a flat snapshot.
/// This function is called by the main thread before signaling the render thread.
pub fn captureSnapshot(
    allocator: Allocator,
    world: *ecs.World,
    camera: anytype,
    frame_index: u64,
    delta_time: f32,
) !GameStateSnapshot {
    var snapshot = GameStateSnapshot.init(allocator);
    
    snapshot.frame_index = frame_index;
    snapshot.delta_time = delta_time;
    
    // Copy camera state
    snapshot.camera_position = camera.position;
    snapshot.camera_view_matrix = camera.getViewMatrix();
    snapshot.camera_projection_matrix = camera.getProjectionMatrix();
    snapshot.camera_view_projection_matrix = snapshot.camera_projection_matrix.mul(snapshot.camera_view_matrix);
    
    // Query for entities with MeshRenderer (they may or may not have Transform)
    const mesh_view = try world.view(MeshRenderer);
    const renderable_entities = mesh_view.storage.entities.items;
    
    // Allocate array for entity data
    snapshot.entities = try allocator.alloc(
        GameStateSnapshot.EntityRenderData,
        renderable_entities.len
    );
    
    // Extract entity data
    var entity_index: usize = 0;
    for (renderable_entities) |entity| {
        const renderer = world.get(MeshRenderer, entity) orelse continue;
        
        // Skip disabled renderers or those without a model
        if (!renderer.enabled or renderer.model_asset == null) continue;
        
        // Get transform (default to identity if missing)
        const transform = world.get(Transform, entity);
        const world_matrix = if (transform) |t| t.world_matrix else Math.Mat4x4.identity();
        
        // Store entity render data
        snapshot.entities[entity_index] = .{
            .entity_id = entity,
            .transform = world_matrix,
            .model_asset = renderer.model_asset.?,
            .material_asset = renderer.material_asset,
            .texture_asset = renderer.texture_asset,
            .layer = renderer.layer,
            .casts_shadows = renderer.casts_shadows,
            .receives_shadows = renderer.receives_shadows,
        };
        entity_index += 1;
    }
    snapshot.entity_count = entity_index;
    
    // TODO: Extract light data when PointLight component exists
    // For now, allocate empty light array
    snapshot.point_lights = try allocator.alloc(
        GameStateSnapshot.PointLightData,
        0
    );
    snapshot.point_light_count = 0;
    
    return snapshot;
}

/// Helper to free a snapshot (called when overwriting old buffer)
pub fn freeSnapshot(snapshot: *GameStateSnapshot) void {
    const allocator = snapshot.allocator;
    snapshot.deinit();
    snapshot.* = GameStateSnapshot.init(allocator);
}
