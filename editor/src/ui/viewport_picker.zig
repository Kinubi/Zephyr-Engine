const std = @import("std");
const zephyr = @import("zephyr");
const Math = zephyr.math;

const Camera = zephyr.Camera;
const Scene = zephyr.Scene;
const MeshRenderer = zephyr.MeshRenderer;
const AssetManager = zephyr.AssetManager;
const Model = zephyr.Model;
const Mesh = zephyr.Mesh;

pub const PickResult = struct {
    entity: zephyr.Entity,
    distance: f32,
    pos: Math.Vec3,
};

fn transformPoint(m: *Math.Mat4x4, p: Math.Vec3) Math.Vec3 {
    // row-major multiplication: out = m * vec4(p,1)
    const x = m.get(0, 0).* * p.x + m.get(0, 1).* * p.y + m.get(0, 2).* * p.z + m.get(0, 3).* * 1.0;
    const y = m.get(1, 0).* * p.x + m.get(1, 1).* * p.y + m.get(1, 2).* * p.z + m.get(1, 3).* * 1.0;
    const z = m.get(2, 0).* * p.x + m.get(2, 1).* * p.y + m.get(2, 2).* * p.z + m.get(2, 3).* * 1.0;
    return Math.Vec3.init(x, y, z);
}

fn transformDirection(m: *Math.Mat4x4, d: Math.Vec3) Math.Vec3 {
    // multiply by matrix ignoring translation: out = m * vec4(d,0)
    const x = m.get(0, 0).* * d.x + m.get(0, 1).* * d.y + m.get(0, 2).* * d.z;
    const y = m.get(1, 0).* * d.x + m.get(1, 1).* * d.y + m.get(1, 2).* * d.z;
    const z = m.get(2, 0).* * d.x + m.get(2, 1).* * d.y + m.get(2, 2).* * d.z;
    return Math.Vec3.init(x, y, z);
}

const Ray = struct { origin: Math.Vec3, dir: Math.Vec3 };

pub fn rayFromMouse(camera: *Camera, mouse_x: f32, mouse_y: f32, vp_pos: [2]f32, vp_size: [2]f32) Ray {
    // Guard against degenerate viewport size
    if (vp_size[0] < 1.0 or vp_size[1] < 1.0) {
        // Return a ray pointing forward if viewport is too small
        // Extract camera position from inverse view matrix
        const inv_view = &camera.inverseViewMatrix;
        const origin = Math.Vec3.init(inv_view.get(3, 0).*, inv_view.get(3, 1).*, inv_view.get(3, 2).*);
        return Ray{ .origin = origin, .dir = Math.Vec3.init(0, 0, -1) };
    }

    // NDC coords in [-1,1]
    // Mouse coordinates: (0,0) at top-left, increases right and down
    // NDC: (-1,-1) at bottom-left, (1,1) at top-right (standard)
    const u = (mouse_x - vp_pos[0]) / vp_size[0];
    const v = (mouse_y - vp_pos[1]) / vp_size[1];
    const ndc_x = u * 2.0 - 1.0; // [0,1] -> [-1,1]
    const ndc_y = 1.0 - v * 2.0; // [0,1] -> [1,-1] (flip Y since mouse Y increases down)

    const mouse_vp_x = mouse_x - vp_pos[0];
    const mouse_vp_y = mouse_y - vp_pos[1];
    std.debug.print("[PICKER] Mouse global: ({d:.1}, {d:.1}), VP pos: ({d:.1}, {d:.1}), Mouse in VP: ({d:.1}, {d:.1}), VP size: ({d:.1}, {d:.1})\n", .{ mouse_x, mouse_y, vp_pos[0], vp_pos[1], mouse_vp_x, mouse_vp_y, vp_size[0], vp_size[1] });
    std.debug.print("[PICKER] u={d:.3}, v={d:.3}, NDC: ({d:.3}, {d:.3})\n", .{ u, v, ndc_x, ndc_y });

    const fovy = Math.radians(camera.fov);
    const tanHalf = @tan(fovy * 0.5);

    // Use viewport's actual aspect ratio, not camera's stored aspect ratio
    // This ensures picking works correctly even if viewport is resized
    const aspect = vp_size[0] / vp_size[1];

    // Ray in camera/view space
    // Camera space: X right, Y up, Z forward (into screen, +Z)
    var dir_cam = Math.Vec3.init(ndc_x * aspect * tanHalf, ndc_y * tanHalf, 1.0);
    dir_cam = dir_cam.normalize();

    // Convert to world space using inverse view matrix
    const inv_view = &camera.inverseViewMatrix;

    // Extract camera position from inverse view matrix
    // Translation is stored at row 3, columns 0-2 (see camera.zig line 99-101)
    const origin = Math.Vec3.init(inv_view.get(3, 0).*, inv_view.get(3, 1).*, inv_view.get(3, 2).*);

    var world_dir = transformDirection(inv_view, dir_cam);
    world_dir = world_dir.normalize();

    return Ray{ .origin = origin, .dir = world_dir };
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
    // Calculate NDC for logging
    const u = (mouse_x - vp_pos[0]) / vp_size[0];
    const v = (mouse_y - vp_pos[1]) / vp_size[1];
    const ndc_x = u * 2.0 - 1.0;
    const ndc_y = 1.0 - v * 2.0;

    const ray = rayFromMouse(camera, mouse_x, mouse_y, vp_pos, vp_size);
    const orig = ray.origin;
    const dir = ray.dir;

    std.debug.print("[PICKER] NDC: ({d:.2}, {d:.2}), Camera pos: ({d:.2}, {d:.2}, {d:.2}), Ray dir: ({d:.2}, {d:.2}, {d:.2})\n", .{ ndc_x, ndc_y, orig.x, orig.y, orig.z, dir.x, dir.y, dir.z });

    var best_t: f32 = 1e30;
    var best_entity: ?zephyr.Entity = null;
    var best_pos: Math.Vec3 = Math.Vec3.zero();

    var object_count: usize = 0;
    var tested_count: usize = 0;

    // Iterate scene objects
    for (scene.iterateObjects()) |*game_obj| {
        object_count += 1;
        const eid = game_obj.entity_id;

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
        var tri_count: usize = 0;
        var hit_count: usize = 0;

        // For each mesh in the model
        for (model.meshes.items) |model_mesh| {
            const mesh = model_mesh.geometry.mesh;
            mesh_count += 1;

            // Iterate triangles (assume indices are triangle list)
            const idx_len = mesh.indices.items.len;
            var i: usize = 0;
            while (i + 2 < idx_len) : (i += 3) {
                tri_count += 1;
                const ia = @as(usize, mesh.indices.items[i]);
                const ib = @as(usize, mesh.indices.items[i + 1]);
                const ic = @as(usize, mesh.indices.items[i + 2]);

                const pa = transformPoint(world_mat, Math.Vec3.init(mesh.vertices.items[ia].pos[0], mesh.vertices.items[ia].pos[1], mesh.vertices.items[ia].pos[2]));
                const pb = transformPoint(world_mat, Math.Vec3.init(mesh.vertices.items[ib].pos[0], mesh.vertices.items[ib].pos[1], mesh.vertices.items[ib].pos[2]));
                const pc = transformPoint(world_mat, Math.Vec3.init(mesh.vertices.items[ic].pos[0], mesh.vertices.items[ic].pos[1], mesh.vertices.items[ic].pos[2]));

                if (intersectTriangle(orig, dir, pa, pb, pc)) |t| {
                    hit_count += 1;
                    if (t < best_t) {
                        best_t = t;
                        best_entity = eid;
                        best_pos = Math.Vec3.add(orig, Math.Vec3.scale(dir, t));
                    }
                }
            }
        }

        if (tested_count == 1) {
            // Log first object's details for debugging
            std.debug.print("[PICKER] Entity {}: {} meshes, {} triangles, {} hits\n", .{ eid, mesh_count, tri_count, hit_count });
        }
    }

    std.debug.print("[PICKER] Tested {}/{} objects with valid meshes\n", .{ tested_count, object_count });

    if (best_entity) |e| {
        std.debug.print("[PICKER] Found hit: entity={}, distance={d:.2}\n", .{ e, best_t });
        return PickResult{ .entity = e, .distance = best_t, .pos = best_pos };
    }
    std.debug.print("[PICKER] No hit found\n", .{});
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
