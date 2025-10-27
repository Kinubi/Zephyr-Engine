const std = @import("std");
const Allocator = std.mem.Allocator;
const Math = @import("../utils/math.zig");

const ecs = @import("../ecs.zig");
const Camera = @import("../rendering/camera.zig").Camera;

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
        mesh_id: u32,
        material_id: u32,
        // Add other render-relevant component data as needed
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
    _ = world; // TODO: Implement ECS query
    
    var snapshot = GameStateSnapshot.init(allocator);
    
    snapshot.frame_index = frame_index;
    snapshot.delta_time = delta_time;
    
    // Copy camera state
    snapshot.camera_position = camera.position;
    snapshot.camera_view_matrix = camera.getViewMatrix();
    snapshot.camera_projection_matrix = camera.getProjectionMatrix();
    snapshot.camera_view_projection_matrix = snapshot.camera_projection_matrix.mul(snapshot.camera_view_matrix);
    
    // Count entities with renderable components
    // TODO: Query for Transform + MeshRenderer (or similar components)
    // For now, use actual count from world
    const estimated_entity_count = 0; // TODO: world.query(...).count()
    snapshot.entities = try allocator.alloc(
        GameStateSnapshot.EntityRenderData,
        estimated_entity_count
    );
    
    // Extract entity data
    // TODO: Implement actual ECS query
    // var iter = world.query(&.{Transform, MeshRenderer});
    // while (iter.next()) |entry| {
    //     snapshot.entities[snapshot.entity_count] = .{
    //         .entity_id = entry.entity,
    //         .transform = entry.get(Transform).matrix,
    //         .mesh_id = entry.get(MeshRenderer).mesh_id,
    //         .material_id = entry.get(MeshRenderer).material_id,
    //     };
    //     snapshot.entity_count += 1;
    // }
    snapshot.entity_count = 0; // Placeholder
    
    // Extract light data
    // TODO: Query for PointLight component
    const estimated_light_count = 0; // TODO: world.query(...).count()
    snapshot.point_lights = try allocator.alloc(
        GameStateSnapshot.PointLightData,
        estimated_light_count
    );
    snapshot.point_light_count = 0; // Placeholder
    
    return snapshot;
}

/// Helper to free a snapshot (called when overwriting old buffer)
pub fn freeSnapshot(snapshot: *GameStateSnapshot) void {
    const allocator = snapshot.allocator;
    snapshot.deinit();
    snapshot.* = GameStateSnapshot.init(allocator);
}
