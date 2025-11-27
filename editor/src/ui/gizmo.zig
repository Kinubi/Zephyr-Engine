const std = @import("std");
const zephyr = @import("zephyr");
const Math = zephyr.math;

const c = @import("backend/imgui_c.zig").c;

const Camera = zephyr.Camera;
const Scene = zephyr.Scene;
const ViewportPicker = @import("viewport_picker.zig");
const UIMath = @import("backend/ui_math.zig");
const GizmoDraw = @import("backend/gizmo_draw.zig");
const GizmoProcess = @import("backend/gizmo_process.zig");

pub const Gizmo = struct {
    pub const Tool = enum { Translate, Rotate, Scale };
    const Axis = enum { None, X, Y, Z };
    pub const PickKind = enum { None, Axis, Ring };

    pub const State = struct {
        tool: Tool = .Translate,
        active_axis: Axis = .None,
        dragging: bool = false,
        hovered_axis: Axis = .None,
        hovered_kind: PickKind = .None,
        drag_origin: Math.Vec3 = Math.Vec3.zero(),
        drag_mouse_start: [2]f32 = .{ 0.0, 0.0 },
        initial_pos: Math.Vec3 = Math.Vec3.zero(),
        initial_rot: Math.Quat = Math.Quat.identity(),
        initial_scale: Math.Vec3 = Math.Vec3.init(1, 1, 1),
    };

    var state: State = State{};

    pub fn setTool(t: Tool) void {
        state.tool = t;
    }

    pub fn cancelDrag() void {
        state.dragging = false;
        state.active_axis = .None;
    }

    pub fn process(draw_list: *c.ImDrawList, viewport_pos: [2]f32, viewport_size: [2]f32, camera: *Camera, world_pos: Math.Vec3, scene: *Scene, selected: zephyr.Entity) bool {
        return GizmoProcess.process(&state, draw_list, viewport_pos, viewport_size, camera, world_pos, scene, selected);
    }
};

pub fn axisDir(a: Gizmo.Axis) Math.Vec3 {
    return switch (a) {
        .X => Math.Vec3.init(1, 0, 0),
        .Y => Math.Vec3.init(0, 1, 0),
        .Z => Math.Vec3.init(0, 0, 1),
        .None => Math.Vec3.zero(),
    };
}

pub fn axisFromIndex(i: usize) Gizmo.Axis {
    if (i == 0) return .X;
    if (i == 1) return .Y;
    return .Z;
}

fn axisToIndex(a: Gizmo.Axis) i32 {
    return switch (a) {
        .None => -1,
        .X => 0,
        .Y => 1,
        .Z => 2,
    };
}

// Drawing helpers live in `gizmo_draw.zig` (imported as GizmoDraw). Call those directly from drawBase.

pub fn drawBase(draw_list: *c.ImDrawList, viewport_pos: [2]f32, viewport_size: [2]f32, camera: *Camera, world_pos: Math.Vec3, hovered_axis: Gizmo.Axis, hovered_kind: Gizmo.PickKind, tool: Gizmo.Tool) void {
    // Draw only the gizmo for the current tool
    switch (tool) {
        .Translate => {
            // Draw translate arrows only — call the drawing module directly and pass numeric hover info
            const hovered_idx: i32 = axisToIndex(hovered_axis);
            const hovered_kind_u8: u8 = switch (hovered_kind) {
                .None => 0,
                .Axis => 1,
                .Ring => 2,
            };
            GizmoDraw.drawTranslate(draw_list, viewport_pos, viewport_size, camera, world_pos, hovered_idx, hovered_kind_u8);
        },
        .Rotate => {
            // Draw 3D rotation rings (circles perpendicular to each axis)
            const hovered_idx: i32 = axisToIndex(hovered_axis);
            const hovered_kind_u8: u8 = switch (hovered_kind) {
                .None => 0,
                .Axis => 1,
                .Ring => 2,
            };
            GizmoDraw.drawRotationRings(draw_list, viewport_pos, viewport_size, camera, world_pos, hovered_idx, hovered_kind_u8);
        },
        .Scale => {
            // Draw scale handles (axis lines with cubes at the end)
            const hovered_idx: i32 = axisToIndex(hovered_axis);
            const hovered_kind_u8: u8 = switch (hovered_kind) {
                .None => 0,
                .Axis => 1,
                .Ring => 2,
            };
            GizmoDraw.drawScale(draw_list, viewport_pos, viewport_size, camera, world_pos, hovered_idx, hovered_kind_u8);
        },
    }
}

// Return closest point on infinite line defined by (line_origin, line_dir) to ray (ray_orig, ray_dir)
// Math helpers are provided by `ui_math.zig` (imported as GizmoMath).
// Call those functions directly from callers to avoid duplicating wrappers here.

pub fn pickAxisOrRing(center: Math.Vec3, vp_size: [2]f32, mouse_x: f32, mouse_y: f32, camera: *Camera, tool: Gizmo.Tool) struct {
    kind: Gizmo.PickKind,
    axis: Gizmo.Axis,
} {
    // Project center
    const center_screen = UIMath.project(camera, vp_size, center) orelse return .{ .kind = Gizmo.PickKind.None, .axis = .None };

    // Determine a world-space gizmo length scaled by camera distance (match drawTranslate)
    const inv_view = &camera.inverseViewMatrix;
    const cam_pos = Math.Vec3.init(inv_view.get(3, 0).*, inv_view.get(3, 1).*, inv_view.get(3, 2).*);
    const dist = Math.Vec3.sub(center, cam_pos).length();
    const world_len = dist * 0.15;

    const axes = [_]Math.Vec3{ Math.Vec3.init(1, 0, 0), Math.Vec3.init(0, 1, 0), Math.Vec3.init(0, 0, 1) };

    // Only pick axes if in Translate or Scale mode
    if (tool == .Translate or tool == .Scale) {
        var best_axis: Gizmo.Axis = .None;
        var best_dist: f32 = 1e9;

        var i: usize = 0;
        while (i < axes.len) : (i += 1) {
            const axis = axes[i];
            const end_world = Math.Vec3.add(center, Math.Vec3.scale(axis, world_len));
            if (UIMath.project(camera, vp_size, end_world)) |end_screen| {
                const ax = center_screen[0];
                const ay = center_screen[1];
                const bx = end_screen[0];
                const by = end_screen[1];
                // compute arrowhead triangle in screen space (match drawTranslate)
                const axis_dx = bx - ax;
                const axis_dy = by - ay;
                const axis_len = @sqrt(axis_dx * axis_dx + axis_dy * axis_dy);
                var d: f32 = 1e9;
                if (axis_len > 1e-6) {
                    const dir_x = axis_dx / axis_len;
                    const dir_y = axis_dy / axis_len;
                    const perp_x = -dir_y;
                    const perp_y = dir_x;
                    const tip_x = bx;
                    const tip_y = by;
                    const size: f32 = 8.0;
                    const base_x = tip_x - dir_x * size;
                    const base_y = tip_y - dir_y * size;
                    // triangle points
                    const t1x = tip_x;
                    const t1y = tip_y;
                    const t2x = base_x + perp_x * (size * 0.5);
                    const t2y = base_y + perp_y * (size * 0.5);
                    const t3x = base_x - perp_x * (size * 0.5);
                    const t3y = base_y - perp_y * (size * 0.5);
                    // point-in-triangle test (barycentric)
                    const v0x = t3x - t1x;
                    const v0y = t3y - t1y;
                    const v1x = t2x - t1x;
                    const v1y = t2y - t1y;
                    const v2x = mouse_x - t1x;
                    const v2y = mouse_y - t1y;
                    const dot00 = v0x * v0x + v0y * v0y;
                    const dot01 = v0x * v1x + v0y * v1y;
                    const dot02 = v0x * v2x + v0y * v2y;
                    const dot11 = v1x * v1x + v1y * v1y;
                    const dot12 = v1x * v2x + v1y * v2y;
                    const invDenom = 1.0 / (@max(1e-6, dot00 * dot11 - dot01 * dot01));
                    const u = (dot11 * dot02 - dot01 * dot12) * invDenom;
                    const v_ = (dot00 * dot12 - dot01 * dot02) * invDenom;
                    if (u >= 0.0 and v_ >= 0.0 and (u + v_ <= 1.0)) {
                        d = 0.0;
                    } else {
                        // distance to triangle edges
                        const d1 = UIMath.distancePointToSegment(mouse_x, mouse_y, t1x, t1y, t2x, t2y);
                        const d2 = UIMath.distancePointToSegment(mouse_x, mouse_y, t2x, t2y, t3x, t3y);
                        const d3 = UIMath.distancePointToSegment(mouse_x, mouse_y, t3x, t3y, t1x, t1y);
                        d = if (d1 < d2) if (d1 < d3) d1 else d3 else if (d2 < d3) d2 else d3;
                    }
                } else {
                    d = UIMath.distancePointToSegment(mouse_x, mouse_y, ax, ay, bx, by);
                }
                if (d < best_dist) {
                    best_dist = d;
                    best_axis = axisFromIndex(i);
                }
            }
        }

        // Pixel threshold for click distance
        const pick_threshold: f32 = 18.0;
        if (best_dist <= pick_threshold) return .{ .kind = Gizmo.PickKind.Axis, .axis = best_axis };
    }

    // Rotation ring pick: only in Rotate mode
    if (tool == .Rotate) {
        // Pick 3D rotation rings by projecting ring segments and checking screen-space distance to segments
        const world_radius = dist * 0.12;
        const num_segments: u32 = 32;
        const angle_step = (2.0 * std.math.pi) / @as(f32, @floatFromInt(num_segments));
        const pick_threshold: f32 = 10.0;

        var best_ring_axis: Gizmo.Axis = .None;
        var best_ring_dist: f32 = 1e9;

        // Check X-axis ring (YZ plane) - check distance to line segments
        {
            var prev_screen: ?[2]f32 = null;
            var i: u32 = 0;
            while (i <= num_segments) : (i += 1) {
                const angle = @as(f32, @floatFromInt(i % num_segments)) * angle_step;
                const y = @cos(angle) * world_radius;
                const z = @sin(angle) * world_radius;
                const world_point = Math.Vec3.init(center.x, center.y + y, center.z + z);

                if (UIMath.project(camera, vp_size, world_point)) |screen| {
                    if (prev_screen) |prev| {
                        const d = UIMath.distancePointToSegment(mouse_x, mouse_y, prev[0], prev[1], screen[0], screen[1]);
                        if (d < best_ring_dist) {
                            best_ring_dist = d;
                            best_ring_axis = .X;
                        }
                    }
                    prev_screen = screen;
                }
            }
        }

        // Check Y-axis ring (XZ plane)
        {
            var prev_screen: ?[2]f32 = null;
            var i: u32 = 0;
            while (i <= num_segments) : (i += 1) {
                const angle = @as(f32, @floatFromInt(i % num_segments)) * angle_step;
                const x = @cos(angle) * world_radius;
                const z = @sin(angle) * world_radius;
                const world_point = Math.Vec3.init(center.x + x, center.y, center.z + z);

                if (UIMath.project(camera, vp_size, world_point)) |screen| {
                    if (prev_screen) |prev| {
                        const d = UIMath.distancePointToSegment(mouse_x, mouse_y, prev[0], prev[1], screen[0], screen[1]);
                        if (d < best_ring_dist) {
                            best_ring_dist = d;
                            best_ring_axis = .Y;
                        }
                    }
                    prev_screen = screen;
                }
            }
        }

        // Check Z-axis ring (XY plane)
        {
            var prev_screen: ?[2]f32 = null;
            var i: u32 = 0;
            while (i <= num_segments) : (i += 1) {
                const angle = @as(f32, @floatFromInt(i % num_segments)) * angle_step;
                const x = @cos(angle) * world_radius;
                const y = @sin(angle) * world_radius;
                const world_point = Math.Vec3.init(center.x + x, center.y + y, center.z);

                if (UIMath.project(camera, vp_size, world_point)) |screen| {
                    if (prev_screen) |prev| {
                        const d = UIMath.distancePointToSegment(mouse_x, mouse_y, prev[0], prev[1], screen[0], screen[1]);
                        if (d < best_ring_dist) {
                            best_ring_dist = d;
                            best_ring_axis = .Z;
                        }
                    }
                    prev_screen = screen;
                }
            }
        }

        if (best_ring_dist <= pick_threshold and best_ring_axis != .None) {
            return .{ .kind = Gizmo.PickKind.Ring, .axis = best_ring_axis };
        }
    }

    return .{ .kind = Gizmo.PickKind.None, .axis = .None };
}

// Color helper lives in `ui_math.zig` and callers should call GizmoMath.makeColor directly.
