const std = @import("std");
const zephyr = @import("zephyr");
const Math = zephyr.math;
const c = @import("imgui_c.zig").c;

const Camera = zephyr.Camera;
const Scene = zephyr.Scene;
const MeshRenderer = zephyr.MeshRenderer;
const AssetManager = zephyr.AssetManager;
const Model = zephyr.Model;
const MeshModule = zephyr.Mesh;
const Mesh = MeshModule.Mesh;

pub const PickResult = struct {
    entity: zephyr.Entity,
    distance: f32,
    pos: Math.Vec3,
};

fn transformPoint(m: *Math.Mat4x4, p: Math.Vec3) Math.Vec3 {
    // Matrix stores translation in the last row; treat input as row-vector * matrix
    const x = p.x * m.get(0, 0).* + p.y * m.get(1, 0).* + p.z * m.get(2, 0).* + m.get(3, 0).*;
    const y = p.x * m.get(0, 1).* + p.y * m.get(1, 1).* + p.z * m.get(2, 1).* + m.get(3, 1).*;
    const z = p.x * m.get(0, 2).* + p.y * m.get(1, 2).* + p.z * m.get(2, 2).* + m.get(3, 2).*;
    return Math.Vec3.init(x, y, z);
}

fn transformDirection(m: *Math.Mat4x4, d: Math.Vec3) Math.Vec3 {
    // Same layout as transformPoint but without the translation term
    const x = d.x * m.get(0, 0).* + d.y * m.get(1, 0).* + d.z * m.get(2, 0).*;
    const y = d.x * m.get(0, 1).* + d.y * m.get(1, 1).* + d.z * m.get(2, 1).*;
    const z = d.x * m.get(0, 2).* + d.y * m.get(1, 2).* + d.z * m.get(2, 2).*;
    return Math.Vec3.init(x, y, z);
}

pub const Ray = struct { origin: Math.Vec3, dir: Math.Vec3 };

pub const AxisAlignedBoundingBox = struct {
    min: Math.Vec3,
    max: Math.Vec3,
};

fn computeMeshAABB(mesh: *Mesh) AxisAlignedBoundingBox {
    if (mesh.getOrComputeLocalBounds()) |bounds| {
        return AxisAlignedBoundingBox{ .min = bounds.min, .max = bounds.max };
    }

    // Fallback for unexpected empty meshes
    return AxisAlignedBoundingBox{
        .min = Math.Vec3.zero(),
        .max = Math.Vec3.zero(),
    };
}

fn transformAABB(world_mat: *Math.Mat4x4, local: AxisAlignedBoundingBox) AxisAlignedBoundingBox {
    // Transform the 8 corners to capture the world-space extents
    const min = local.min;
    const max = local.max;
    const corners = [_]Math.Vec3{
        Math.Vec3.init(min.x, min.y, min.z),
        Math.Vec3.init(min.x, min.y, max.z),
        Math.Vec3.init(min.x, max.y, min.z),
        Math.Vec3.init(min.x, max.y, max.z),
        Math.Vec3.init(max.x, min.y, min.z),
        Math.Vec3.init(max.x, min.y, max.z),
        Math.Vec3.init(max.x, max.y, min.z),
        Math.Vec3.init(max.x, max.y, max.z),
    };

    var world_min = Math.Vec3.init(std.math.inf(f32), std.math.inf(f32), std.math.inf(f32));
    var world_max = Math.Vec3.init(-std.math.inf(f32), -std.math.inf(f32), -std.math.inf(f32));

    for (corners) |corner| {
        const world_corner = transformPoint(world_mat, corner);
        if (world_corner.x < world_min.x) world_min.x = world_corner.x;
        if (world_corner.y < world_min.y) world_min.y = world_corner.y;
        if (world_corner.z < world_min.z) world_min.z = world_corner.z;
        if (world_corner.x > world_max.x) world_max.x = world_corner.x;
        if (world_corner.y > world_max.y) world_max.y = world_corner.y;
        if (world_corner.z > world_max.z) world_max.z = world_corner.z;
    }

    const padding: f32 = 0.01;
    world_min.x -= padding;
    world_min.y -= padding;
    world_min.z -= padding;
    world_max.x += padding;
    world_max.y += padding;
    world_max.z += padding;

    return AxisAlignedBoundingBox{ .min = world_min, .max = world_max };
}

fn rayIntersectsAABB(origin: Math.Vec3, dir: Math.Vec3, aabb: AxisAlignedBoundingBox) ?f32 {
    const EPS: f32 = 1e-6;
    var t_min: f32 = -std.math.inf(f32);
    var t_max: f32 = std.math.inf(f32);

    const orig_components = [_]f32{ origin.x, origin.y, origin.z };
    const dir_components = [_]f32{ dir.x, dir.y, dir.z };
    const min_components = [_]f32{ aabb.min.x, aabb.min.y, aabb.min.z };
    const max_components = [_]f32{ aabb.max.x, aabb.max.y, aabb.max.z };

    for (orig_components, dir_components, min_components, max_components) |orig, direction, min_val, max_val| {
        if (@abs(direction) < EPS) {
            if (orig < min_val or orig > max_val) return null;
        } else {
            const inv_dir = 1.0 / direction;
            var t1 = (min_val - orig) * inv_dir;
            var t2 = (max_val - orig) * inv_dir;
            if (t1 > t2) {
                const tmp = t1;
                t1 = t2;
                t2 = tmp;
            }
            if (t1 > t_min) t_min = t1;
            if (t2 < t_max) t_max = t2;
            if (t_min > t_max) return null;
        }
    }

    if (t_max < 0.0) return null;
    return if (t_min > 0.0) t_min else t_max;
}

pub fn rayFromMouse(camera: *Camera, mouse_x: f32, mouse_y: f32, vp_pos: [2]f32, vp_size: [2]f32) Ray {
    // Guard against degenerate viewport size
    if (vp_size[0] < 1.0 or vp_size[1] < 1.0) {
        // Return a ray pointing forward if viewport is too small
        // Extract camera position from inverse view matrix
        const inv_view = &camera.inverseViewMatrix;
        const origin = Math.Vec3.init(inv_view.get(3, 0).*, inv_view.get(3, 1).*, inv_view.get(3, 2).*);
        return Ray{ .origin = origin, .dir = Math.Vec3.init(0, 0, -1) };
    }

    _ = vp_pos;

    const main_viewport = c.ImGui_GetMainViewport();
    const window_origin_x = main_viewport.*.Pos.x;
    const window_origin_y = main_viewport.*.Pos.y;
    const window_width = main_viewport.*.Size.x;
    const window_height = main_viewport.*.Size.y;

    if (window_width <= 0.0 or window_height <= 0.0) {
        const inv_view = &camera.inverseViewMatrix;
        const origin = Math.Vec3.init(inv_view.get(3, 0).*, inv_view.get(3, 1).*, inv_view.get(3, 2).*);
        return Ray{ .origin = origin, .dir = Math.Vec3.init(0, 0, -1) };
    }

    // Convert mouse position (ImGui space) into clip space coordinates
    const window_u = (mouse_x - window_origin_x) / window_width;
    const window_v = (mouse_y - window_origin_y) / window_height;
    const ndc_x = window_u * 2.0 - 1.0;
    const ndc_y = window_v * 2.0 - 1.0;

    const fovy = Math.radians(camera.fov);
    const tanHalf = @tan(fovy * 0.5);

    const aspect = window_width / window_height;

    // Perspective ray: point through the camera frustum
    const dir_cam = Math.Vec3.init(ndc_x * aspect * tanHalf, ndc_y * tanHalf, 1.0);

    // Convert to world space using inverse view matrix
    const inv_view = &camera.inverseViewMatrix;

    // Camera position in world space
    const camera_pos = Math.Vec3.init(inv_view.get(3, 0).*, inv_view.get(3, 1).*, inv_view.get(3, 2).*);

    var world_dir = transformDirection(inv_view, dir_cam);
    world_dir = world_dir.normalize();
    var origin = camera_pos;

    const origin_epsilon: f32 = 1e-3;
    origin = Math.Vec3.add(origin, Math.Vec3.scale(world_dir, origin_epsilon));
    return Ray{ .origin = origin, .dir = world_dir };
}

pub fn computeEntityWorldAABB(scene: *Scene, entity: zephyr.Entity) ?AxisAlignedBoundingBox {
    if (entity == zephyr.Entity.invalid) return null;

    const mr = scene.ecs_world.get(MeshRenderer, entity) orelse return null;
    if (!mr.hasValidAssets()) return null;

    const model_ptr = scene.asset_manager.getLoadedModelConst(mr.model_asset.?) orelse return null;
    const model = model_ptr.*;

    const transform = scene.ecs_world.get(zephyr.Transform, entity) orelse return null;
    const world_mat = &transform.world_matrix;

    var combined_min = Math.Vec3.init(std.math.inf(f32), std.math.inf(f32), std.math.inf(f32));
    var combined_max = Math.Vec3.init(-std.math.inf(f32), -std.math.inf(f32), -std.math.inf(f32));
    var found_mesh: bool = false;

    for (model.meshes.items) |model_mesh| {
        const mesh = model_mesh.geometry.mesh;
        const local_aabb = computeMeshAABB(mesh);
        const world_aabb = transformAABB(world_mat, local_aabb);
        if (world_aabb.min.x < combined_min.x) combined_min.x = world_aabb.min.x;
        if (world_aabb.min.y < combined_min.y) combined_min.y = world_aabb.min.y;
        if (world_aabb.min.z < combined_min.z) combined_min.z = world_aabb.min.z;
        if (world_aabb.max.x > combined_max.x) combined_max.x = world_aabb.max.x;
        if (world_aabb.max.y > combined_max.y) combined_max.y = world_aabb.max.y;
        if (world_aabb.max.z > combined_max.z) combined_max.z = world_aabb.max.z;
        found_mesh = true;
    }

    if (!found_mesh) return null;
    return AxisAlignedBoundingBox{ .min = combined_min, .max = combined_max };
}

fn intersectTriangle(orig: Math.Vec3, dir: Math.Vec3, v0: Math.Vec3, v1: Math.Vec3, v2: Math.Vec3) ?f32 {
    const EPS: f32 = 1e-6;
    const edge1 = Math.Vec3.sub(v1, v0);
    const edge2 = Math.Vec3.sub(v2, v0);
    const pvec = Math.Vec3.cross(dir, edge2);
    const det = Math.Vec3.dot(edge1, pvec);
    if (det > -EPS and det < EPS) return null; // Parallel
    const inv_det = 1.0 / det;
    const tvec = Math.Vec3.sub(orig, v0);
    const u = inv_det * Math.Vec3.dot(tvec, pvec);
    if (u < 0.0 or u > 1.0) return null;
    const qvec = Math.Vec3.cross(tvec, edge1);
    const v = inv_det * Math.Vec3.dot(dir, qvec);
    if (v < 0.0 or u + v > 1.0) return null;
    const t = inv_det * Math.Vec3.dot(edge2, qvec);
    if (t > EPS) return t;
    return null;
}

pub fn pickScene(scene: *Scene, camera: *Camera, mouse_x: f32, mouse_y: f32, vp_pos: [2]f32, vp_size: [2]f32) ?PickResult {
    const ray = rayFromMouse(camera, mouse_x, mouse_y, vp_pos, vp_size);
    const orig = ray.origin;
    const dir = ray.dir;

    var best_t: f32 = 1e30;
    var best_entity: ?zephyr.Entity = null;
    var best_pos: Math.Vec3 = Math.Vec3.zero();

    var object_count: usize = 0;
    var tested_count: usize = 0;

    // Iterate scene objects
    for (scene.iterateObjects()) |*game_obj| {
        object_count += 1;
        const eid = game_obj.entity_id;
        if (eid == zephyr.Entity.invalid) continue;

        // Skip if no MeshRenderer
        const mr = scene.ecs_world.get(MeshRenderer, eid) orelse continue;
        if (!mr.hasValidAssets()) continue;

        // Get loaded model (const safe access)
        const model_ptr = scene.asset_manager.getLoadedModelConst(mr.model_asset.?) orelse continue;
        const model = model_ptr.*;

        // Get transform for object
        const transform = scene.ecs_world.get(zephyr.Transform, eid) orelse continue;
        const world_mat = &transform.world_matrix;

        tested_count += 1;

        var mesh_count: usize = 0;

        // For each mesh in the model
        for (model.meshes.items) |model_mesh| {
            const mesh = model_mesh.geometry.mesh;
            mesh_count += 1;

            const local_aabb = computeMeshAABB(mesh);
            const world_aabb = transformAABB(world_mat, local_aabb);
            const aabb_hit = rayIntersectsAABB(orig, dir, world_aabb);

            if (aabb_hit == null) {
                continue;
            }
            if (aabb_hit) |t| {
                if (t < best_t) {
                    best_t = t;
                    best_entity = eid;
                    best_pos = Math.Vec3.add(orig, Math.Vec3.scale(dir, t));
                }
            }
        }
    }

    if (best_entity) |e| {
        return PickResult{ .entity = e, .distance = best_t, .pos = best_pos };
    }

    return null;
}

test "Moller-Trumbore basic intersection" {
    const orig = Math.Vec3.init(0, 0, 0);
    const dir = Math.Vec3.init(0, 0, -1);
    const v0 = Math.Vec3.init(-1, -1, -5);
    const v1 = Math.Vec3.init(1, -1, -5);
    const v2 = Math.Vec3.init(0, 1, -5);
    const t = intersectTriangle(orig, dir, v0, v1, v2) orelse unreachable;
    try std.testing.expect(t > 4.9 and t < 5.1);
}
