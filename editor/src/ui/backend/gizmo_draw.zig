const std = @import("std");
const zephyr = @import("zephyr");
const Math = zephyr.math;

const c = @import("imgui_c.zig").c;
const UIMath = @import("ui_math.zig");

fn hoveredIndexEquals(hovered: i32, idx: usize) bool {
    return switch (idx) {
        0 => hovered == 0,
        1 => hovered == 1,
        else => hovered == 2,
    };
}

pub fn drawTranslate(draw_list: *c.ImDrawList, viewport_pos: [2]f32, viewport_size: [2]f32, camera: *zephyr.Camera, world_pos: Math.Vec3, hovered_axis_index: i32, hovered_kind: u8) void {
    // Project center (returns viewport-relative coordinates)
    const center_vp = UIMath.project(camera, viewport_size, world_pos) orelse return;
    // Convert to window coordinates for ImGui drawing
    const center = .{ center_vp[0] + viewport_pos[0], center_vp[1] + viewport_pos[1] };

    // Compute a gizmo length in world-space proportional to distance from camera
    const inv_view = &camera.inverseViewMatrix;
    const cam_pos = Math.Vec3.init(inv_view.get(3, 0).*, inv_view.get(3, 1).*, inv_view.get(3, 2).*);
    const dist = Math.Vec3.sub(world_pos, cam_pos).length();
    const world_len = dist * 0.15; // scale factor

    const axes = [_]Math.Vec3{ Math.Vec3.init(1, 0, 0), Math.Vec3.init(0, 1, 0), Math.Vec3.init(0, 0, 1) };
    const colors = [_]u32{ UIMath.makeColor(255, 0, 0, 255), UIMath.makeColor(0, 255, 0, 255), UIMath.makeColor(0, 128, 255, 255) };

    var i: usize = 0;
    while (i < axes.len) : (i += 1) {
        const axis = axes[i];
        const end_world = Math.Vec3.add(world_pos, Math.Vec3.scale(axis, world_len));
        if (UIMath.project(camera, viewport_size, end_world)) |end_vp| {
            // Convert to window coordinates for ImGui drawing
            const end_screen = .{ end_vp[0] + viewport_pos[0], end_vp[1] + viewport_pos[1] };
            const a = .{ center[0], center[1] };
            const b = .{ end_screen[0], end_screen[1] };
            var color = colors[i];
            // Highlight if hovered on this axis
            if (hovered_axis_index >= 0 and hoveredIndexEquals(hovered_axis_index, i) and hovered_kind == 1) { // 1 == Axis
                color = UIMath.makeColor(255, 214, 0, 255); // bright yellow for hover
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
                if (hovered_axis_index >= 0 and hoveredIndexEquals(hovered_axis_index, i) and hovered_kind == 1) {
                    const outline_col = UIMath.makeColor(255, 255, 255, 180);
                    c.ImDrawList_AddTriangle(draw_list, p1, p2, p3, outline_col);
                }
            }
        }
    }
}

pub fn drawRotationRings(draw_list: *c.ImDrawList, viewport_pos: [2]f32, viewport_size: [2]f32, camera: *zephyr.Camera, world_pos: Math.Vec3, hovered_axis_index: i32, hovered_kind: u8) void {
    // Compute world-space radius for the rings
    const inv_view = &camera.inverseViewMatrix;
    const cam_pos = Math.Vec3.init(inv_view.get(3, 0).*, inv_view.get(3, 1).*, inv_view.get(3, 2).*);
    const dist = Math.Vec3.sub(world_pos, cam_pos).length();
    const world_radius = dist * 0.12; // Ring size in world space

    const num_segments: u32 = 64;
    const angle_step = (2.0 * std.math.pi) / @as(f32, @floatFromInt(num_segments));

    // Draw X-axis ring (circle in YZ plane)
    {
        var col: u32 = UIMath.makeColor(255, 0, 0, 180);
        if (hovered_kind == 2 and hovered_axis_index == 0) { // 2 == Ring, axis enum mapping
            col = UIMath.makeColor(255, 214, 0, 255);
        }

        var prev_screen: ?[2]f32 = null;
        var i: u32 = 0;
        while (i <= num_segments) : (i += 1) {
            const angle = @as(f32, @floatFromInt(i)) * angle_step;
            const y = @cos(angle) * world_radius;
            const z = @sin(angle) * world_radius;
            const world_point = Math.Vec3.init(world_pos.x, world_pos.y + y, world_pos.z + z);

            if (UIMath.project(camera, viewport_size, world_point)) |screen_vp| {
                // Convert to window coordinates for ImGui drawing
                const screen = .{ screen_vp[0] + viewport_pos[0], screen_vp[1] + viewport_pos[1] };
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
        var col: u32 = UIMath.makeColor(0, 255, 0, 180);
        if (hovered_kind == 2 and hovered_axis_index == 1) {
            col = UIMath.makeColor(255, 214, 0, 255);
        }

        var prev_screen: ?[2]f32 = null;
        var i: u32 = 0;
        while (i <= num_segments) : (i += 1) {
            const angle = @as(f32, @floatFromInt(i)) * angle_step;
            const x = @cos(angle) * world_radius;
            const z = @sin(angle) * world_radius;
            const world_point = Math.Vec3.init(world_pos.x + x, world_pos.y, world_pos.z + z);

            if (UIMath.project(camera, viewport_size, world_point)) |screen_vp| {
                // Convert to window coordinates for ImGui drawing
                const screen = .{ screen_vp[0] + viewport_pos[0], screen_vp[1] + viewport_pos[1] };
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
        var col: u32 = UIMath.makeColor(0, 128, 255, 180);
        if (hovered_kind == 2 and hovered_axis_index == 2) {
            col = UIMath.makeColor(255, 214, 0, 255);
        }

        var prev_screen: ?[2]f32 = null;
        var i: u32 = 0;
        while (i <= num_segments) : (i += 1) {
            const angle = @as(f32, @floatFromInt(i)) * angle_step;
            const x = @cos(angle) * world_radius;
            const y = @sin(angle) * world_radius;
            const world_point = Math.Vec3.init(world_pos.x + x, world_pos.y + y, world_pos.z);

            if (UIMath.project(camera, viewport_size, world_point)) |screen_vp| {
                // Convert to window coordinates for ImGui drawing
                const screen = .{ screen_vp[0] + viewport_pos[0], screen_vp[1] + viewport_pos[1] };
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

pub fn drawScale(draw_list: *c.ImDrawList, viewport_pos: [2]f32, viewport_size: [2]f32, camera: *zephyr.Camera, world_pos: Math.Vec3, hovered_axis_index: i32, hovered_kind: u8) void {
    // Project center (returns viewport-relative coordinates)
    const center_vp = UIMath.project(camera, viewport_size, world_pos) orelse return;
    // Convert to window coordinates for ImGui drawing
    const center = .{ center_vp[0] + viewport_pos[0], center_vp[1] + viewport_pos[1] };

    // Compute a gizmo length in world-space proportional to distance from camera
    const inv_view = &camera.inverseViewMatrix;
    const cam_pos = Math.Vec3.init(inv_view.get(3, 0).*, inv_view.get(3, 1).*, inv_view.get(3, 2).*);
    const dist = Math.Vec3.sub(world_pos, cam_pos).length();
    const world_len = dist * 0.15;

    const axes = [_]Math.Vec3{ Math.Vec3.init(1, 0, 0), Math.Vec3.init(0, 1, 0), Math.Vec3.init(0, 0, 1) };
    const colors = [_]u32{ UIMath.makeColor(255, 0, 0, 255), UIMath.makeColor(0, 255, 0, 255), UIMath.makeColor(0, 128, 255, 255) };

    var i: usize = 0;
    while (i < axes.len) : (i += 1) {
        const axis = axes[i];
        const end_world = Math.Vec3.add(world_pos, Math.Vec3.scale(axis, world_len));
        if (UIMath.project(camera, viewport_size, end_world)) |end_vp| {
            // Convert to window coordinates for ImGui drawing
            const end_screen = .{ end_vp[0] + viewport_pos[0], end_vp[1] + viewport_pos[1] };
            const a = .{ center[0], center[1] };
            const b = .{ end_screen[0], end_screen[1] };
            var color = colors[i];

            // Highlight if hovered on this axis
            if (hovered_axis_index >= 0 and hoveredIndexEquals(hovered_axis_index, i) and hovered_kind == 1) {
                color = UIMath.makeColor(255, 214, 0, 255);
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
            if (hovered_axis_index >= 0 and hoveredIndexEquals(hovered_axis_index, i) and hovered_kind == 1) {
                const outline_col = UIMath.makeColor(255, 255, 255, 180);
                c.ImDrawList_AddRect(draw_list, .{ .x = min_x, .y = min_y }, .{ .x = max_x, .y = max_y }, outline_col);
            }
        }
    }
}

// Use shared color helper from ui_math.zig to avoid duplicates
// (GizmoMath is imported above)
