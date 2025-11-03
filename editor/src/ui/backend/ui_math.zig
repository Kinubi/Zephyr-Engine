const std = @import("std");
const zephyr = @import("zephyr");
const Math = zephyr.math;

const c = @import("imgui_c.zig").c;

pub fn transformVec4Row(m: *Math.Mat4x4, v: Math.Vec4) Math.Vec4 {
    const x = v.x * m.get(0, 0).* + v.y * m.get(1, 0).* + v.z * m.get(2, 0).* + v.w * m.get(3, 0).*;
    const y = v.x * m.get(0, 1).* + v.y * m.get(1, 1).* + v.z * m.get(2, 1).* + v.w * m.get(3, 1).*;
    const z = v.x * m.get(0, 2).* + v.y * m.get(1, 2).* + v.z * m.get(2, 2).* + v.w * m.get(3, 2).*;
    const w = v.x * m.get(0, 3).* + v.y * m.get(1, 3).* + v.z * m.get(2, 3).* + v.w * m.get(3, 3).*;
    return Math.Vec4.init(x, y, z, w);
}

pub fn project(camera: *zephyr.Camera, vp_size: [2]f32, point: Math.Vec3) ?[2]f32 {
    const point4 = Math.Vec4.init(point.x, point.y, point.z, 1.0);

    // Transform to view space
    const view4 = transformVec4Row(&camera.viewMatrix, point4);
    if (view4.z <= 0.0) return null;

    // Transform to clip space
    const clip4 = transformVec4Row(&camera.projectionMatrix, view4);
    if (@abs(clip4.w) < 1e-6) return null;

    // Perspective divide to get NDC coordinates
    const inv_w = 1.0 / clip4.w;
    const ndc_x = clip4.x * inv_w;
    const ndc_y = clip4.y * inv_w;
    const ndc_z = clip4.z * inv_w;

    // Check if point is within NDC bounds
    if (ndc_x < -1.0 or ndc_x > 1.0 or ndc_y < -1.0 or ndc_y > 1.0 or ndc_z < 0.0 or ndc_z > 1.0)
        return null;

    // Convert NDC to viewport-relative coordinates
    if (vp_size[0] <= 0.0 or vp_size[1] <= 0.0)
        return null;

    const viewport_x = ((ndc_x + 1.0) * 0.5) * vp_size[0];
    const viewport_y = ((ndc_y + 1.0) * 0.5) * vp_size[1];

    return .{ viewport_x, viewport_y };
}

pub fn closestPointOnLine(line_origin: Math.Vec3, line_dir: Math.Vec3, ray_orig: Math.Vec3, ray_dir: Math.Vec3) Math.Vec3 {
    const u = line_dir;
    const v = ray_dir;
    const w0 = Math.Vec3.sub(line_origin, ray_orig);
    const aa = Math.Vec3.dot(u, u);
    const bb = Math.Vec3.dot(u, v);
    const cc = Math.Vec3.dot(v, v);
    const dd = Math.Vec3.dot(u, w0);
    const ee = Math.Vec3.dot(v, w0);
    const denom = aa * cc - bb * bb;
    var s: f32 = 0.0;
    if (denom == 0.0) {
        s = 0.0;
    } else {
        s = (bb * ee - cc * dd) / denom;
    }
    return Math.Vec3.add(line_origin, Math.Vec3.scale(u, s));
}

pub fn projectRayToPlane(ray_orig: Math.Vec3, ray_dir: Math.Vec3, plane_point: Math.Vec3, plane_normal: Math.Vec3) ?Math.Vec3 {
    const denom = Math.Vec3.dot(ray_dir, plane_normal);
    if (@abs(denom) < 1e-6) return null;
    const t = Math.Vec3.dot(Math.Vec3.sub(plane_point, ray_orig), plane_normal) / denom;
    if (t < 0.0) return null;
    return Math.Vec3.add(ray_orig, Math.Vec3.scale(ray_dir, t));
}

pub fn distancePointToSegment(px: f32, py: f32, ax: f32, ay: f32, bx: f32, by: f32) f32 {
    const vx = bx - ax;
    const vy = by - ay;
    const wx = px - ax;
    const wy = py - ay;
    const vv = vx * vx + vy * vy;
    if (vv == 0.0) return @sqrt((px - ax) * (px - ax) + (py - ay) * (py - ay));
    var t = (wx * vx + wy * vy) / vv;
    if (t < 0.0) {
        t = 0.0;
    } else if (t > 1.0) {
        t = 1.0;
    }
    const cx = ax + vx * t;
    const cy = ay + vy * t;
    return @sqrt((px - cx) * (px - cx) + (py - cy) * (py - cy));
}

pub fn makeColor(r: u8, g: u8, b: u8, a: u8) u32 {
    return (@as(u32, a) << 24) | (@as(u32, b) << 16) | (@as(u32, g) << 8) | @as(u32, r);
}
