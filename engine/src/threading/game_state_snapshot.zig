const std = @import("std");
const Math = @import("../utils/math.zig");
const ecs = @import("../ecs.zig");
const Camera = @import("../rendering/camera.zig").Camera;
const Transform = @import("../ecs/components/transform.zig").Transform;
const MeshRenderer = @import("../ecs/components/mesh_renderer.zig").MeshRenderer;
const AssetId = @import("../assets/asset_types.zig").AssetId;
const render_data_types = @import("../rendering/render_data_types.zig");

const Allocator = std.mem.Allocator;

/// Instance data delta for render system
pub const InstanceDelta = struct {
    changed_indices: []u32, // Indices of changed instances
    changed_data: []render_data_types.RasterizationData.InstanceData, // New data for changed instances
};

/// Change detection metadata from prepare phase
pub const RenderChangeFlags = struct {
    renderables_dirty: bool = false, // If true, caches need rebuild
    transform_only_change: bool = false, // If true, only TLAS needs update
    raster_descriptors_dirty: bool = false, // If true, descriptor sets need update
    raytracing_descriptors_dirty: bool = false, // If true, RT descriptor sets need update
};

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
    imgui_buffer_idx: usize, // Which buffer this data belongs to (for freeing)

    // Change detection metadata (from RenderSystem.prepare)
    render_changes: RenderChangeFlags,

    // Material system delta updates (from MaterialSystem.prepare)
    // These are copied from MaterialDeltasSet singleton component
    material_deltas: []ecs.MaterialSetDelta,

    // Instance data delta updates (from RenderSystem.prepare)
    instance_delta: ?InstanceDelta,

    // Particle system data (if needed)
    // particles: []ParticleData,

    pub const EntityRenderData = struct {
        entity_id: ecs.EntityId,
        transform: Math.Mat4x4, // World transform matrix
        model_asset: AssetId,
        material_buffer_index: ?u32, // Index into MaterialSystem's per-set material buffer
        material_set_name: []const u8, // Name of the material set (e.g. "opaque")
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
            .imgui_buffer_idx = 0,
            .render_changes = .{},
            .material_deltas = &.{},
            .instance_delta = null,
        };
    }

    pub fn deinit(self: *GameStateSnapshot) void {
        if (self.entities.len > 0) {
            self.allocator.free(self.entities);
        }
        if (self.point_lights.len > 0) {
            self.allocator.free(self.point_lights);
        }
        // Free material deltas
        for (self.material_deltas) |*delta| {
            if (delta.changed_materials.len > 0) {
                self.allocator.free(delta.changed_materials);
            }
            if (delta.texture_descriptors.len > 0) {
                self.allocator.free(delta.texture_descriptors);
            }
            // set_name is owned by MaterialSystem, don't free
        }
        if (self.material_deltas.len > 0) {
            self.allocator.free(self.material_deltas);
        }
        // Free instance delta
        if (self.instance_delta) |delta| {
            if (delta.changed_indices.len > 0) {
                self.allocator.free(delta.changed_indices);
            }
            if (delta.changed_data.len > 0) {
                self.allocator.free(delta.changed_data);
            }
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
    imgui_buffer_idx: usize, // Which buffer this ImGui data belongs to
) !GameStateSnapshot {
    // Read render change flags from RenderablesSet component
    const render_changes = blk: {
        if (world.getSingletonEntity()) |singleton_entity| {
            if (world.get(ecs.RenderablesSet, singleton_entity)) |renderables_set| {
                break :blk renderables_set.changes;
            }
        }
        break :blk RenderChangeFlags{};
    };

    var snapshot = GameStateSnapshot{
        .allocator = allocator,
        .frame_index = frame_index,
        .delta_time = delta_time,
        .imgui_draw_data = imgui_draw_data,
        .imgui_buffer_idx = imgui_buffer_idx,
        .render_changes = render_changes,
        .material_deltas = &.{}, // Will be populated below
        .camera_position = undefined,
        .camera_view_matrix = undefined,
        .camera_projection_matrix = undefined,
        .camera_view_projection_matrix = undefined,
        .entities = undefined,
        .entity_count = 0,
        .point_lights = undefined,
        .point_light_count = 0,
        .instance_delta = null,
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

    // Read extracted renderables from RenderablesSet component (NO ECS QUERIES!)
    // RenderSystem.prepare() already did all the ECS extraction work
    const singleton_entity = try world.getOrCreateSingletonEntity();
    const renderables_set = world.get(ecs.RenderablesSet, singleton_entity);
    const extracted_renderables = if (renderables_set) |rs| rs.renderables else &[_]ecs.ExtractedRenderable{};

    // Allocate and copy entity render data
    snapshot.entities = try allocator.alloc(GameStateSnapshot.EntityRenderData, extracted_renderables.len);
    for (extracted_renderables, 0..) |extracted, i| {
        snapshot.entities[i] = .{
            .entity_id = extracted.entity_id,
            .transform = extracted.transform,
            .model_asset = extracted.model_asset,
            .material_buffer_index = extracted.material_buffer_index,
            .material_set_name = extracted.material_set_name,
            .layer = extracted.layer,
            .casts_shadows = extracted.casts_shadows,
            .receives_shadows = extracted.receives_shadows,
        };
    }
    snapshot.entity_count = extracted_renderables.len;

    // Extract light data from PointLight components
    const PointLight = ecs.PointLight;
    const light_view = try world.view(PointLight);
    const light_entities = light_view.storage.entities.items;

    // Allocate array for light data (up to 16 lights)
    const max_lights = 16;
    const light_count = @min(light_entities.len, max_lights);
    snapshot.point_lights = try allocator.alloc(GameStateSnapshot.PointLightData, light_count);

    // Extract each light with Transform
    var light_index: usize = 0;
    for (light_entities) |entity| {
        if (light_index >= max_lights) break;

        const point_light = world.get(PointLight, entity) orelse continue;
        const transform = world.get(Transform, entity) orelse continue;

        snapshot.point_lights[light_index] = .{
            .position = transform.position,
            .color = point_light.color,
            .intensity = point_light.intensity,
            .radius = point_light.range,
        };
        light_index += 1;
    }
    snapshot.point_light_count = light_index;

    // Capture material deltas from MaterialDeltasSet singleton component
    // (similar to how we read RenderablesSet above)
    if (world.get(ecs.MaterialDeltasSet, singleton_entity)) |material_deltas_set| {
        // Allocate and copy deltas for thread-safe transfer
        snapshot.material_deltas = try allocator.alloc(ecs.MaterialSetDelta, material_deltas_set.deltas.len);
        for (material_deltas_set.deltas, 0..) |delta, i| {
            // Deep copy each delta
            const changed_materials = try allocator.alloc(ecs.MaterialChange, delta.changed_materials.len);
            @memcpy(changed_materials, delta.changed_materials);

            const texture_descriptors = try allocator.alloc(@import("vulkan").DescriptorImageInfo, delta.texture_descriptors.len);
            @memcpy(texture_descriptors, delta.texture_descriptors);

            snapshot.material_deltas[i] = .{
                .set_name = delta.set_name, // Borrowed from MaterialSystem, don't copy
                .changed_materials = changed_materials,
                .texture_descriptors = texture_descriptors,
                .texture_count = delta.texture_count,
                .texture_array_dirty = delta.texture_array_dirty,
            };
        }
    }

    // Capture instance deltas from InstanceDeltasSet singleton component
    if (world.get(ecs.InstanceDeltasSet, singleton_entity)) |instance_deltas_set| {
        if (instance_deltas_set.changed_indices.len > 0) {
            // Deep copy delta data for thread-safe transfer
            const indices = try allocator.alloc(u32, instance_deltas_set.changed_indices.len);
            @memcpy(indices, instance_deltas_set.changed_indices);

            const data = try allocator.alloc(@import("../rendering/render_data_types.zig").RasterizationData.InstanceData, instance_deltas_set.changed_data.len);
            @memcpy(data, instance_deltas_set.changed_data);

            snapshot.instance_delta = InstanceDelta{
                .changed_indices = indices,
                .changed_data = data,
            };
        }
    }

    return snapshot;
}

/// Helper to free a snapshot (called when overwriting old buffer)
pub fn freeSnapshot(snapshot: *GameStateSnapshot) void {
    const allocator = snapshot.allocator;
    snapshot.deinit();
    snapshot.* = GameStateSnapshot.init(allocator);
}
