const std = @import("std");
const zephyr = @import("zephyr");
const Math = zephyr.math;

const c = @import("imgui_c.zig").c;
const ViewportPicker = @import("../viewport_picker.zig");
const UIMath = @import("ui_math.zig");

const GizmoModule = @import("../gizmo.zig");
const Gizmo = GizmoModule.Gizmo;

pub fn process(state: *Gizmo.State, draw_list: *c.ImDrawList, viewport_pos: [2]f32, viewport_size: [2]f32, camera: *zephyr.Camera, world_pos: Math.Vec3, scene: *zephyr.Scene, selected: zephyr.Entity) bool {
    const io = c.ImGui_GetIO();
    const mouse = io.*.MousePos;
    const window_mouse_x = mouse.x;
    const window_mouse_y = mouse.y;

    // Convert window coordinates to viewport-relative coordinates
    const mouse_x = window_mouse_x - viewport_pos[0];
    const mouse_y = window_mouse_y - viewport_pos[1];
    const mouse_clicked = c.ImGui_IsMouseClicked(0);

    const ray = ViewportPicker.rayFromMouse(camera, mouse_x, mouse_y, viewport_size);

    // Hover detection first so draw calls can reflect hover state (only pick visible handles based on current tool)
    const pick_hover = GizmoModule.pickAxisOrRing(world_pos, viewport_size, mouse_x, mouse_y, camera, state.*.tool);
    state.*.hovered_axis = pick_hover.axis;
    state.*.hovered_kind = pick_hover.kind;

    // Draw gizmo visuals based on current tool (uses state.hovered_* for highlighting)
    GizmoModule.drawBase(draw_list, viewport_pos, viewport_size, camera, world_pos, state.*.hovered_axis, state.*.hovered_kind, state.*.tool);
    // Helper: get transform pointer
    const transform = scene.ecs_world.get(zephyr.Transform, selected) orelse return false;

    // Mouse button handling (left button)
    const mouse_down = io.*.MouseDown[0];

    if (!state.*.dragging) {
        // Hover detection: find nearest axis or ring (use screen-space metric so clicks select the visible handle)
        const pick = GizmoModule.pickAxisOrRing(world_pos, viewport_size, mouse_x, mouse_y, camera, state.*.tool);
        if (mouse_clicked) {
            if (pick.kind != Gizmo.PickKind.None) {
                // Start interaction on picked axis/ring
                state.*.active_axis = pick.axis;
                state.*.dragging = true;
                state.*.initial_pos = transform.position;
                // Transform.rotation is a quaternion now; store Euler angles for gizmo state
                state.*.initial_rot = transform.rotation.toEuler();
                state.*.initial_scale = transform.scale;

                // Initialize drag based on current tool
                if (state.*.tool == .Translate) {
                    state.*.drag_origin = UIMath.closestPointOnLine(world_pos, GizmoModule.axisDir(state.*.active_axis), ray.origin, ray.dir);
                    state.*.drag_mouse_start = .{ mouse_x, mouse_y };
                } else if (state.*.tool == .Scale) {
                    state.*.drag_origin = UIMath.closestPointOnLine(world_pos, GizmoModule.axisDir(state.*.active_axis), ray.origin, ray.dir);
                } else if (state.*.tool == .Rotate) {
                    // Rotation uses plane perpendicular to the selected axis
                    const plane_normal = GizmoModule.axisDir(state.*.active_axis);
                    if (UIMath.projectRayToPlane(ray.origin, ray.dir, world_pos, plane_normal)) |p| {
                        state.*.drag_origin = Math.Vec3.normalize(Math.Vec3.sub(p, world_pos));
                    } else {
                        // Couldn't start rotate - cancel drag
                        state.*.dragging = false;
                        state.*.active_axis = .None;
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
            state.*.dragging = false;
            state.*.active_axis = .None;
            return true; // consumed since we were dragging
        } else {
            // Continue drag: compute delta based on tool
            if (state.*.tool == .Translate) {
                // Screen-space translate: project axis to screen, use mouse pixel delta projected onto axis screen vector
                const center_screen = UIMath.project(camera, viewport_size, world_pos) orelse return false;
                const axis_world = GizmoModule.axisDir(state.*.active_axis);
                // compute a world length matching drawTranslate
                const inv_view = &camera.inverseViewMatrix;
                const cam_pos = Math.Vec3.init(inv_view.get(3, 0).*, inv_view.get(3, 1).*, inv_view.get(3, 2).*);
                const dist = Math.Vec3.sub(world_pos, cam_pos).length();
                const world_len = dist * 0.15;
                const end_world = Math.Vec3.add(world_pos, Math.Vec3.scale(axis_world, world_len));
                if (UIMath.project(camera, viewport_size, end_world)) |end_screen| {
                    const axis_dx = end_screen[0] - center_screen[0];
                    const axis_dy = end_screen[1] - center_screen[1];
                    const axis_len = @sqrt(axis_dx * axis_dx + axis_dy * axis_dy);
                    if (axis_len > 1e-6) {
                        const nm_x = axis_dx / axis_len;
                        const nm_y = axis_dy / axis_len;
                        const pdx = mouse_x - state.*.drag_mouse_start[0];
                        const pdy = mouse_y - state.*.drag_mouse_start[1];
                        const proj_pixels = pdx * nm_x + pdy * nm_y;
                        var world_move_len = (proj_pixels / axis_len) * world_len;
                        if (io.*.KeyShift) world_move_len *= 0.1; // precision modifier
                        var new_pos = Math.Vec3.add(state.*.initial_pos, Math.Vec3.scale(axis_world, world_move_len));
                        if (io.*.KeyCtrl) {
                            const snap: f32 = 0.5;
                            new_pos.x = @round(new_pos.x / snap) * snap;
                            new_pos.y = @round(new_pos.y / snap) * snap;
                            new_pos.z = @round(new_pos.z / snap) * snap;
                        }
                        transform.setPosition(new_pos);
                    }
                }
            } else if (state.*.tool == .Rotate) {
                // Compute signed angle delta around axis using ray-plane intersection
                const axis_world = GizmoModule.axisDir(state.*.active_axis);
                if (UIMath.projectRayToPlane(ray.origin, ray.dir, world_pos, axis_world)) |cur_p| {
                    const cur_vec = Math.Vec3.normalize(Math.Vec3.sub(cur_p, world_pos));
                    const cross = Math.Vec3.cross(state.*.drag_origin, cur_vec);
                    const cross_len = Math.Vec3.length(cross);
                    const dot = Math.Vec3.dot(state.*.drag_origin, cur_vec);
                    const angle = std.math.atan2(@as(f32, cross_len), @as(f32, dot));
                    // Sign is negative of the dot product with axis to match expected rotation direction
                    const sign: f32 = if (Math.Vec3.dot(cross, axis_world) >= 0.0) @as(f32, -1.0) else @as(f32, 1.0);
                    var signed_angle: f32 = angle * sign;
                    if (io.*.KeyShift) signed_angle *= 0.1; // precision
                    var new_rot = state.*.initial_rot;
                    if (state.*.active_axis == .X) {
                        new_rot.x = state.*.initial_rot.x + signed_angle;
                    } else if (state.*.active_axis == .Y) {
                        new_rot.y = state.*.initial_rot.y + signed_angle;
                    } else if (state.*.active_axis == .Z) {
                        new_rot.z = state.*.initial_rot.z + signed_angle;
                    }
                    // Snap
                    if (io.*.KeyCtrl) {
                        const snap_deg: f32 = 15.0;
                        const snap_rad = Math.radians(snap_deg);
                        if (state.*.active_axis == .X) {
                            new_rot.x = @round(new_rot.x / snap_rad) * snap_rad;
                        } else if (state.*.active_axis == .Y) {
                            new_rot.y = @round(new_rot.y / snap_rad) * snap_rad;
                        } else if (state.*.active_axis == .Z) {
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
                    var new_rot = state.*.initial_rot;
                    if (state.*.active_axis == .X) {
                        new_rot.x += ang_delta;
                    } else if (state.*.active_axis == .Y) {
                        new_rot.y += ang_delta;
                    } else if (state.*.active_axis == .Z) {
                        new_rot.z += ang_delta;
                    }
                    transform.setRotation(new_rot);
                }
            } else if (state.*.tool == .Scale) {
                const new_pt = UIMath.closestPointOnLine(world_pos, GizmoModule.axisDir(state.*.active_axis), ray.origin, ray.dir);
                const delta = Math.Vec3.sub(new_pt, state.*.drag_origin);
                var scale_amount: f32 = 1.0 + (Math.Vec3.dot(delta, GizmoModule.axisDir(state.*.active_axis)));
                if (io.*.KeyShift) scale_amount = 1.0 + (scale_amount - 1.0) * 0.1;
                var new_scale = state.*.initial_scale;
                if (state.*.active_axis == .X) {
                    new_scale.x = state.*.initial_scale.x * scale_amount;
                } else if (state.*.active_axis == .Y) {
                    new_scale.y = state.*.initial_scale.y * scale_amount;
                } else if (state.*.active_axis == .Z) {
                    new_scale.z = state.*.initial_scale.z * scale_amount;
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
