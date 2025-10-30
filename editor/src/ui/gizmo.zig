const std = @import("std");
const zephyr = @import("zephyr");
const Math = zephyr.math;

const c = @import("imgui_c.zig").c;

const Camera = zephyr.Camera;
const Scene = zephyr.Scene;
const ViewportPicker = @import("viewport_picker.zig");
fn transformVec4Row(m: *Math.Mat4x4, v: Math.Vec4) Math.Vec4 {
    const x = v.x * m.get(0, 0).* + v.y * m.get(1, 0).* + v.z * m.get(2, 0).* + v.w * m.get(3, 0).*;
    const y = v.x * m.get(0, 1).* + v.y * m.get(1, 1).* + v.z * m.get(2, 1).* + v.w * m.get(3, 1).*;
    const z = v.x * m.get(0, 2).* + v.y * m.get(1, 2).* + v.z * m.get(2, 2).* + v.w * m.get(3, 2).*;
    const w = v.x * m.get(0, 3).* + v.y * m.get(1, 3).* + v.z * m.get(2, 3).* + v.w * m.get(3, 3).*;
    return Math.Vec4.init(x, y, z, w);
}

fn project(camera: *Camera, vp_pos: [2]f32, vp_size: [2]f32, point: Math.Vec3) ?[2]f32 {
    _ = vp_pos;
    _ = vp_size;

    // Use the same projection pipeline as the bbox (proper view-projection with perspective divide)
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

    // Convert NDC to window coordinates (use main window, not viewport, for proper alignment)
    const main_viewport = c.ImGui_GetMainViewport();
    const window_origin_x = main_viewport.*.Pos.x;
    const window_origin_y = main_viewport.*.Pos.y;
    const window_width = main_viewport.*.Size.x;
    const window_height = main_viewport.*.Size.y;

    if (window_width <= 0.0 or window_height <= 0.0)
        return null;

    const window_x = window_origin_x + ((ndc_x + 1.0) * 0.5) * window_width;
    const window_y = window_origin_y + ((ndc_y + 1.0) * 0.5) * window_height;

    return .{ window_x, window_y };
}

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
        initial_rot: Math.Vec3 = Math.Vec3.zero(),
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
        const io = c.ImGui_GetIO();
        const mouse = io.*.MousePos;
        const mouse_x = mouse.x;
        const mouse_y = mouse.y;
        const mouse_clicked = c.ImGui_IsMouseClicked(0);

        const ray = ViewportPicker.rayFromMouse(camera, mouse_x, mouse_y, viewport_pos, viewport_size);

        // Hover detection first so draw calls can reflect hover state (only pick visible handles based on current tool)
        const pick_hover = pickAxisOrRing(world_pos, viewport_pos, viewport_size, mouse_x, mouse_y, camera, state.tool);
        state.hovered_axis = pick_hover.axis;
        state.hovered_kind = pick_hover.kind;

        // Draw gizmo visuals based on current tool (uses state.hovered_* for highlighting)
        drawBase(draw_list, viewport_pos, viewport_size, camera, world_pos, state.hovered_axis, state.hovered_kind, state.tool);
        // Helper: get transform pointer
        const transform = scene.ecs_world.get(zephyr.Transform, selected) orelse return false;

        // Mouse button handling (left button)
        const mouse_down = io.*.MouseDown[0];

        if (!state.dragging) {
            // Hover detection: find nearest axis or ring (use screen-space metric so clicks select the visible handle)
            const pick = pickAxisOrRing(world_pos, viewport_pos, viewport_size, mouse_x, mouse_y, camera, state.tool);
            if (mouse_clicked) {
                if (pick.kind != Gizmo.PickKind.None) {
                    // Start interaction on picked axis/ring
                    state.active_axis = pick.axis;
                    state.dragging = true;
                    state.initial_pos = transform.position;
                    state.initial_rot = transform.rotation;
                    state.initial_scale = transform.scale;

                    // Initialize drag based on current tool
                    if (state.tool == .Translate) {
                        state.drag_origin = closestPointOnLine(world_pos, axisDir(state.active_axis), ray.origin, ray.dir);
                        state.drag_mouse_start = .{ mouse_x, mouse_y };
                    } else if (state.tool == .Scale) {
                        state.drag_origin = closestPointOnLine(world_pos, axisDir(state.active_axis), ray.origin, ray.dir);
                    } else if (state.tool == .Rotate) {
                        // Rotation uses plane perpendicular to the selected axis
                        const plane_normal = axisDir(state.active_axis);
                        if (projectRayToPlane(ray.origin, ray.dir, world_pos, plane_normal)) |p| {
                            state.drag_origin = Math.Vec3.normalize(Math.Vec3.sub(p, world_pos));
                        } else {
                            // Couldn't start rotate - cancel drag
                            state.dragging = false;
                            state.active_axis = .None;
                            return false;
                        }
                    }

                    // We consumed the click by starting a gizmo interaction
                    return true;
                }
            }
            // No drag started this frame
        } else {
            // Dragging active
            if (!mouse_down) {
                // End drag
                state.dragging = false;
                state.active_axis = .None;
                return true; // consumed since we were dragging
            } else {
                // Continue drag: compute delta based on tool
                if (state.tool == .Translate) {
                    // Screen-space translate: project axis to screen, use mouse pixel delta projected onto axis screen vector
                    const center_screen = project(camera, viewport_pos, viewport_size, world_pos) orelse return false;
                    const axis_world = axisDir(state.active_axis);
                    // compute a world length matching drawTranslate
                    const inv_view = &camera.inverseViewMatrix;
                    const cam_pos = Math.Vec3.init(inv_view.get(3, 0).*, inv_view.get(3, 1).*, inv_view.get(3, 2).*);
                    const dist = Math.Vec3.sub(world_pos, cam_pos).length();
                    const world_len = dist * 0.15;
                    const end_world = Math.Vec3.add(world_pos, Math.Vec3.scale(axis_world, world_len));
                    if (project(camera, viewport_pos, viewport_size, end_world)) |end_screen| {
                        const axis_dx = end_screen[0] - center_screen[0];
                        const axis_dy = end_screen[1] - center_screen[1];
                        const axis_len = @sqrt(axis_dx * axis_dx + axis_dy * axis_dy);
                        if (axis_len > 1e-6) {
                            const nm_x = axis_dx / axis_len;
                            const nm_y = axis_dy / axis_len;
                            const pdx = mouse_x - state.drag_mouse_start[0];
                            const pdy = mouse_y - state.drag_mouse_start[1];
                            const proj_pixels = pdx * nm_x + pdy * nm_y;
                            var world_move_len = (proj_pixels / axis_len) * world_len;
                            if (io.*.KeyShift) world_move_len *= 0.1; // precision modifier
                            var new_pos = Math.Vec3.add(state.initial_pos, Math.Vec3.scale(axis_world, world_move_len));
                            if (io.*.KeyCtrl) {
                                const snap: f32 = 0.5;
                                new_pos.x = @round(new_pos.x / snap) * snap;
                                new_pos.y = @round(new_pos.y / snap) * snap;
                                new_pos.z = @round(new_pos.z / snap) * snap;
                            }
                            transform.setPosition(new_pos);
                        }
                    }
                } else if (state.tool == .Rotate) {
                    // Compute signed angle delta around axis using ray-plane intersection
                    const axis_world = axisDir(state.active_axis);
                    if (projectRayToPlane(ray.origin, ray.dir, world_pos, axis_world)) |cur_p| {
                        const cur_vec = Math.Vec3.normalize(Math.Vec3.sub(cur_p, world_pos));
                        const cross = Math.Vec3.cross(state.drag_origin, cur_vec);
                        const cross_len = Math.Vec3.length(cross);
                        const dot = Math.Vec3.dot(state.drag_origin, cur_vec);
                        const angle = std.math.atan2(@as(f32, cross_len), @as(f32, dot));
                        const sign: f32 = if (Math.Vec3.dot(cross, axis_world) >= 0.0) @as(f32, 1.0) else @as(f32, -1.0);
                        var signed_angle: f32 = angle * sign;
                        if (io.*.KeyShift) signed_angle *= 0.1; // precision
                        var new_rot = state.initial_rot;
                        if (state.active_axis == .X) {
                            new_rot.x = state.initial_rot.x + signed_angle;
                        } else if (state.active_axis == .Y) {
                            new_rot.y = state.initial_rot.y + signed_angle;
                        } else if (state.active_axis == .Z) {
                            new_rot.z = state.initial_rot.z + signed_angle;
                        }
                        // Snap
                        if (io.*.KeyCtrl) {
                            const snap_deg: f32 = 15.0;
                            const snap_rad = Math.radians(snap_deg);
                            if (state.active_axis == .X) {
                                new_rot.x = @round(new_rot.x / snap_rad) * snap_rad;
                            } else if (state.active_axis == .Y) {
                                new_rot.y = @round(new_rot.y / snap_rad) * snap_rad;
                            } else if (state.active_axis == .Z) {
                                new_rot.z = @round(new_rot.z / snap_rad) * snap_rad;
                            }
                        }
                        transform.setRotation(new_rot);
                    } else {
                        // couldn't intersect plane — fallback to small mouse-delta based rotation
                        const dx = io.*.MouseDelta.x;
                        const dy = io.*.MouseDelta.y;
                        var ang_delta: f32 = (dx - dy) * 0.01;
                        if (io.*.KeyShift) ang_delta *= 0.1;
                        var new_rot = state.initial_rot;
                        if (state.active_axis == .X) {
                            new_rot.x += ang_delta;
                        } else if (state.active_axis == .Y) {
                            new_rot.y += ang_delta;
                        } else if (state.active_axis == .Z) {
                            new_rot.z += ang_delta;
                        }
                        transform.setRotation(new_rot);
                    }
                } else if (state.tool == .Scale) {
                    const new_pt = closestPointOnLine(world_pos, axisDir(state.active_axis), ray.origin, ray.dir);
                    const delta = Math.Vec3.sub(new_pt, state.drag_origin);
                    var scale_amount: f32 = 1.0 + (Math.Vec3.dot(delta, axisDir(state.active_axis)));
                    if (io.*.KeyShift) scale_amount = 1.0 + (scale_amount - 1.0) * 0.1;
                    var new_scale = state.initial_scale;
                    if (state.active_axis == .X) {
                        new_scale.x = state.initial_scale.x * scale_amount;
                    } else if (state.active_axis == .Y) {
                        new_scale.y = state.initial_scale.y * scale_amount;
                    } else if (state.active_axis == .Z) {
                        new_scale.z = state.initial_scale.z * scale_amount;
                    }
                    if (io.*.KeyCtrl) {
                        const snap: f32 = 0.1;
                        new_scale.x = @round(new_scale.x / snap) * snap;
                        new_scale.y = @round(new_scale.y / snap) * snap;
                        new_scale.z = @round(new_scale.z / snap) * snap;
                    }
                    transform.setScale(new_scale);
                }
                // While dragging we always consume the mouse
                return true;
            }
        }

        // If we reach here, we did not start or continue a drag that consumes the click
        return false;
    }

    pub fn drawTranslate(draw_list: *c.ImDrawList, viewport_pos: [2]f32, viewport_size: [2]f32, camera: *Camera, world_pos: Math.Vec3) void {
        // Project center
        const center = project(camera, viewport_pos, viewport_size, world_pos) orelse return;

        // Compute a gizmo length in world-space proportional to distance from camera
        const inv_view = &camera.inverseViewMatrix;
        const cam_pos = Math.Vec3.init(inv_view.get(3, 0).*, inv_view.get(3, 1).*, inv_view.get(3, 2).*);
        const dist = Math.Vec3.sub(world_pos, cam_pos).length();
        const world_len = dist * 0.15; // scale factor

        const axes = [_]Math.Vec3{ Math.Vec3.init(1, 0, 0), Math.Vec3.init(0, 1, 0), Math.Vec3.init(0, 0, 1) };
        const colors = [_]u32{ makeColor(255, 0, 0, 255), makeColor(0, 255, 0, 255), makeColor(0, 128, 255, 255) };

        var i: usize = 0;
        while (i < axes.len) : (i += 1) {
            const axis = axes[i];
            const end_world = Math.Vec3.add(world_pos, Math.Vec3.scale(axis, world_len));
            if (project(camera, viewport_pos, viewport_size, end_world)) |end_screen| {
                const a = .{ center[0], center[1] };
                const b = .{ end_screen[0], end_screen[1] };
                var color = colors[i];
                // Highlight if hovered on this axis
                if (state.hovered_axis == axisFromIndex(i) and state.hovered_kind == Gizmo.PickKind.Axis) {
                    color = makeColor(255, 214, 0, 255); // bright yellow for hover
                }
                c.ImDrawList_AddLine(draw_list, .{ .x = a[0], .y = a[1] }, .{ .x = b[0], .y = b[1] }, color);

                // draw a small triangular arrowhead pointing along the axis
                var dir_x = b[0] - a[0];
                var dir_y = b[1] - a[1];
                const len = @sqrt(dir_x * dir_x + dir_y * dir_y);
                if (len > 1e-6) {
                    dir_x /= len;
                    dir_y /= len;
                    const perp_x = -dir_y;
                    const perp_y = dir_x;
                    const tip_x = b[0];
                    const tip_y = b[1];
                    const size: f32 = 8.0;
                    const base_x = tip_x - dir_x * size;
                    const base_y = tip_y - dir_y * size;
                    const p1: c.ImVec2 = c.ImVec2{ .x = tip_x, .y = tip_y };
                    const p2: c.ImVec2 = c.ImVec2{ .x = base_x + perp_x * (size * 0.5), .y = base_y + perp_y * (size * 0.5) };
                    const p3: c.ImVec2 = c.ImVec2{ .x = base_x - perp_x * (size * 0.5), .y = base_y - perp_y * (size * 0.5) };
                    c.ImDrawList_AddTriangleFilled(draw_list, p1, p2, p3, color);
                    // If hovered, draw a white outline for clearer feedback
                    if (state.hovered_axis == axisFromIndex(i) and state.hovered_kind == Gizmo.PickKind.Axis) {
                        const outline_col = makeColor(255, 255, 255, 180);
                        c.ImDrawList_AddTriangle(draw_list, p1, p2, p3, outline_col);
                    }
                }
            }
        }
    }
};

fn axisDir(a: Gizmo.Axis) Math.Vec3 {
    return switch (a) {
        .X => Math.Vec3.init(1, 0, 0),
        .Y => Math.Vec3.init(0, 1, 0),
        .Z => Math.Vec3.init(0, 0, 1),
        .None => Math.Vec3.zero(),
    };
}

fn axisFromIndex(i: usize) Gizmo.Axis {
    if (i == 0) return .X;
    if (i == 1) return .Y;
    return .Z;
}

fn drawRotationRings(draw_list: *c.ImDrawList, viewport_pos: [2]f32, viewport_size: [2]f32, camera: *Camera, world_pos: Math.Vec3, hovered_axis: Gizmo.Axis, hovered_kind: Gizmo.PickKind) void {
    // Compute world-space radius for the rings
    const inv_view = &camera.inverseViewMatrix;
    const cam_pos = Math.Vec3.init(inv_view.get(3, 0).*, inv_view.get(3, 1).*, inv_view.get(3, 2).*);
    const dist = Math.Vec3.sub(world_pos, cam_pos).length();
    const world_radius = dist * 0.12; // Ring size in world space

    const num_segments: u32 = 64;
    const angle_step = (2.0 * std.math.pi) / @as(f32, @floatFromInt(num_segments));

    // Draw X-axis ring (circle in YZ plane)
    {
        var col: u32 = makeColor(255, 0, 0, 180);
        if (hovered_kind == Gizmo.PickKind.Ring and hovered_axis == .X) {
            col = makeColor(255, 214, 0, 255);
        }

        var prev_screen: ?[2]f32 = null;
        var i: u32 = 0;
        while (i <= num_segments) : (i += 1) {
            const angle = @as(f32, @floatFromInt(i)) * angle_step;
            const y = @cos(angle) * world_radius;
            const z = @sin(angle) * world_radius;
            const world_point = Math.Vec3.init(world_pos.x, world_pos.y + y, world_pos.z + z);

            if (project(camera, viewport_pos, viewport_size, world_point)) |screen| {
                if (prev_screen) |prev| {
                    c.ImDrawList_AddLine(draw_list, .{ .x = prev[0], .y = prev[1] }, .{ .x = screen[0], .y = screen[1] }, col);
                }
                prev_screen = screen;
            } else {
                prev_screen = null;
            }
        }
    }

    // Draw Y-axis ring (circle in XZ plane)
    {
        var col: u32 = makeColor(0, 255, 0, 180);
        if (hovered_kind == Gizmo.PickKind.Ring and hovered_axis == .Y) {
            col = makeColor(255, 214, 0, 255);
        }

        var prev_screen: ?[2]f32 = null;
        var i: u32 = 0;
        while (i <= num_segments) : (i += 1) {
            const angle = @as(f32, @floatFromInt(i)) * angle_step;
            const x = @cos(angle) * world_radius;
            const z = @sin(angle) * world_radius;
            const world_point = Math.Vec3.init(world_pos.x + x, world_pos.y, world_pos.z + z);

            if (project(camera, viewport_pos, viewport_size, world_point)) |screen| {
                if (prev_screen) |prev| {
                    c.ImDrawList_AddLine(draw_list, .{ .x = prev[0], .y = prev[1] }, .{ .x = screen[0], .y = screen[1] }, col);
                }
                prev_screen = screen;
            } else {
                prev_screen = null;
            }
        }
    }

    // Draw Z-axis ring (circle in XY plane)
    {
        var col: u32 = makeColor(0, 128, 255, 180);
        if (hovered_kind == Gizmo.PickKind.Ring and hovered_axis == .Z) {
            col = makeColor(255, 214, 0, 255);
        }

        var prev_screen: ?[2]f32 = null;
        var i: u32 = 0;
        while (i <= num_segments) : (i += 1) {
            const angle = @as(f32, @floatFromInt(i)) * angle_step;
            const x = @cos(angle) * world_radius;
            const y = @sin(angle) * world_radius;
            const world_point = Math.Vec3.init(world_pos.x + x, world_pos.y + y, world_pos.z);

            if (project(camera, viewport_pos, viewport_size, world_point)) |screen| {
                if (prev_screen) |prev| {
                    c.ImDrawList_AddLine(draw_list, .{ .x = prev[0], .y = prev[1] }, .{ .x = screen[0], .y = screen[1] }, col);
                }
                prev_screen = screen;
            } else {
                prev_screen = null;
            }
        }
    }
}

fn drawScale(draw_list: *c.ImDrawList, viewport_pos: [2]f32, viewport_size: [2]f32, camera: *Camera, world_pos: Math.Vec3, hovered_axis: Gizmo.Axis, hovered_kind: Gizmo.PickKind) void {
    // Project center
    const center = project(camera, viewport_pos, viewport_size, world_pos) orelse return;

    // Compute a gizmo length in world-space proportional to distance from camera
    const inv_view = &camera.inverseViewMatrix;
    const cam_pos = Math.Vec3.init(inv_view.get(3, 0).*, inv_view.get(3, 1).*, inv_view.get(3, 2).*);
    const dist = Math.Vec3.sub(world_pos, cam_pos).length();
    const world_len = dist * 0.15;

    const axes = [_]Math.Vec3{ Math.Vec3.init(1, 0, 0), Math.Vec3.init(0, 1, 0), Math.Vec3.init(0, 0, 1) };
    const colors = [_]u32{ makeColor(255, 0, 0, 255), makeColor(0, 255, 0, 255), makeColor(0, 128, 255, 255) };

    var i: usize = 0;
    while (i < axes.len) : (i += 1) {
        const axis = axes[i];
        const end_world = Math.Vec3.add(world_pos, Math.Vec3.scale(axis, world_len));
        if (project(camera, viewport_pos, viewport_size, end_world)) |end_screen| {
            const a = .{ center[0], center[1] };
            const b = .{ end_screen[0], end_screen[1] };
            var color = colors[i];

            // Highlight if hovered on this axis
            if (hovered_axis == axisFromIndex(i) and hovered_kind == Gizmo.PickKind.Axis) {
                color = makeColor(255, 214, 0, 255);
            }

            // Draw line
            c.ImDrawList_AddLine(draw_list, .{ .x = a[0], .y = a[1] }, .{ .x = b[0], .y = b[1] }, color);

            // Draw cube at the end instead of arrowhead
            const cube_size: f32 = 8.0;
            const min_x = b[0] - cube_size * 0.5;
            const min_y = b[1] - cube_size * 0.5;
            const max_x = b[0] + cube_size * 0.5;
            const max_y = b[1] + cube_size * 0.5;
            c.ImDrawList_AddRectFilled(draw_list, .{ .x = min_x, .y = min_y }, .{ .x = max_x, .y = max_y }, color);

            // If hovered, draw outline
            if (hovered_axis == axisFromIndex(i) and hovered_kind == Gizmo.PickKind.Axis) {
                const outline_col = makeColor(255, 255, 255, 180);
                c.ImDrawList_AddRect(draw_list, .{ .x = min_x, .y = min_y }, .{ .x = max_x, .y = max_y }, outline_col);
            }
        }
    }
}

fn drawBase(draw_list: *c.ImDrawList, viewport_pos: [2]f32, viewport_size: [2]f32, camera: *Camera, world_pos: Math.Vec3, hovered_axis: Gizmo.Axis, hovered_kind: Gizmo.PickKind, tool: Gizmo.Tool) void {
    // Draw only the gizmo for the current tool
    switch (tool) {
        .Translate => {
            // Draw translate arrows only
            Gizmo.drawTranslate(draw_list, viewport_pos, viewport_size, camera, world_pos);
        },
        .Rotate => {
            // Draw 3D rotation rings (circles perpendicular to each axis)
            drawRotationRings(draw_list, viewport_pos, viewport_size, camera, world_pos, hovered_axis, hovered_kind);
        },
        .Scale => {
            // Draw scale handles (axis lines with cubes at the end)
            drawScale(draw_list, viewport_pos, viewport_size, camera, world_pos, hovered_axis, hovered_kind);
        },
    }
}

// Return closest point on infinite line defined by (line_origin, line_dir) to ray (ray_orig, ray_dir)
fn closestPointOnLine(line_origin: Math.Vec3, line_dir: Math.Vec3, ray_orig: Math.Vec3, ray_dir: Math.Vec3) Math.Vec3 {
    // Solve for parameters s (line) and t (ray) minimizing |(line_origin + s*line_dir) - (ray_orig + t*ray_dir)|
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

fn projectRayToPlane(ray_orig: Math.Vec3, ray_dir: Math.Vec3, plane_point: Math.Vec3, plane_normal: Math.Vec3) ?Math.Vec3 {
    const denom = Math.Vec3.dot(ray_dir, plane_normal);
    if (@abs(denom) < 1e-6) return null;
    const t = Math.Vec3.dot(Math.Vec3.sub(plane_point, ray_orig), plane_normal) / denom;
    if (t < 0.0) return null;
    return Math.Vec3.add(ray_orig, Math.Vec3.scale(ray_dir, t));
}

fn distancePointToSegment(px: f32, py: f32, ax: f32, ay: f32, bx: f32, by: f32) f32 {
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

fn pickAxisOrRing(center: Math.Vec3, vp_pos: [2]f32, vp_size: [2]f32, mouse_x: f32, mouse_y: f32, camera: *Camera, tool: Gizmo.Tool) struct {
    kind: Gizmo.PickKind,
    axis: Gizmo.Axis,
} {
    // Project center
    const center_screen = project(camera, vp_pos, vp_size, center) orelse return .{ .kind = Gizmo.PickKind.None, .axis = .None };

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
            if (project(camera, vp_pos, vp_size, end_world)) |end_screen| {
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
                        const d1 = distancePointToSegment(mouse_x, mouse_y, t1x, t1y, t2x, t2y);
                        const d2 = distancePointToSegment(mouse_x, mouse_y, t2x, t2y, t3x, t3y);
                        const d3 = distancePointToSegment(mouse_x, mouse_y, t3x, t3y, t1x, t1y);
                        d = if (d1 < d2) if (d1 < d3) d1 else d3 else if (d2 < d3) d2 else d3;
                    }
                } else {
                    d = distancePointToSegment(mouse_x, mouse_y, ax, ay, bx, by);
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
        // Pick 3D rotation rings by projecting ring segments and checking screen-space distance
        const world_radius = dist * 0.12;
        const num_segments: u32 = 32; // Fewer segments for picking (performance)
        const angle_step = (2.0 * std.math.pi) / @as(f32, @floatFromInt(num_segments));
        const pick_threshold: f32 = 12.0;

        var best_ring_axis: Gizmo.Axis = .None;
        var best_ring_dist: f32 = 1e9;

        // Check X-axis ring (YZ plane)
        {
            var i: u32 = 0;
            while (i < num_segments) : (i += 1) {
                const angle = @as(f32, @floatFromInt(i)) * angle_step;
                const y = @cos(angle) * world_radius;
                const z = @sin(angle) * world_radius;
                const world_point = Math.Vec3.init(center.x, center.y + y, center.z + z);

                if (project(camera, vp_pos, vp_size, world_point)) |screen| {
                    const dx = mouse_x - screen[0];
                    const dy = mouse_y - screen[1];
                    const d = @sqrt(dx * dx + dy * dy);
                    if (d < best_ring_dist) {
                        best_ring_dist = d;
                        best_ring_axis = .X;
                    }
                }
            }
        }

        // Check Y-axis ring (XZ plane)
        {
            var i: u32 = 0;
            while (i < num_segments) : (i += 1) {
                const angle = @as(f32, @floatFromInt(i)) * angle_step;
                const x = @cos(angle) * world_radius;
                const z = @sin(angle) * world_radius;
                const world_point = Math.Vec3.init(center.x + x, center.y, center.z + z);

                if (project(camera, vp_pos, vp_size, world_point)) |screen| {
                    const dx = mouse_x - screen[0];
                    const dy = mouse_y - screen[1];
                    const d = @sqrt(dx * dx + dy * dy);
                    if (d < best_ring_dist) {
                        best_ring_dist = d;
                        best_ring_axis = .Y;
                    }
                }
            }
        }

        // Check Z-axis ring (XY plane)
        {
            var i: u32 = 0;
            while (i < num_segments) : (i += 1) {
                const angle = @as(f32, @floatFromInt(i)) * angle_step;
                const x = @cos(angle) * world_radius;
                const y = @sin(angle) * world_radius;
                const world_point = Math.Vec3.init(center.x + x, center.y + y, center.z);

                if (project(camera, vp_pos, vp_size, world_point)) |screen| {
                    const dx = mouse_x - screen[0];
                    const dy = mouse_y - screen[1];
                    const d = @sqrt(dx * dx + dy * dy);
                    if (d < best_ring_dist) {
                        best_ring_dist = d;
                        best_ring_axis = .Z;
                    }
                }
            }
        }

        if (best_ring_dist <= pick_threshold and best_ring_axis != .None) {
            return .{ .kind = Gizmo.PickKind.Ring, .axis = best_ring_axis };
        }
    }

    return .{ .kind = Gizmo.PickKind.None, .axis = .None };
}

fn makeColor(r: u8, g: u8, b: u8, a: u8) u32 {
    return (@as(u32, a) << 24) | (@as(u32, b) << 16) | (@as(u32, g) << 8) | @as(u32, r);
}
