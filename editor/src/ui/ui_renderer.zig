const std = @import("std");
const zephyr = @import("zephyr");

const c = @import("imgui_c.zig").c;

const PerformanceMonitor = zephyr.PerformanceMonitor;
const SceneHierarchyPanel = @import("scene_hierarchy_panel.zig").SceneHierarchyPanel;
const AssetBrowserPanel = @import("asset_browser_panel.zig").AssetBrowserPanel;
const ViewportPicker = @import("viewport_picker.zig");
const Gizmo = @import("gizmo.zig").Gizmo;
const Scene = zephyr.Scene;
const Camera = zephyr.Camera;
const Math = zephyr.math;

/// UI Renderer - manages all ImGui UI rendering
/// Keeps UI code separate from main app logic
pub const UIRenderer = struct {
    allocator: std.mem.Allocator,
    show_demo_window: bool = false, // Disabled by default - very expensive!
    show_stats_window: bool = true,
    show_camera_window: bool = true,
    show_performance_graphs: bool = true,
    show_asset_browser: bool = true,

    // Scene hierarchy panel
    hierarchy_panel: SceneHierarchyPanel,

    // Last viewport position/size (filled every frame when Viewport window is created)
    viewport_pos: [2]f32 = .{ 0.0, 0.0 },
    viewport_size: [2]f32 = .{ 0.0, 0.0 },

    // Asset browser panel
    asset_browser_panel: AssetBrowserPanel,

    // Cached draw list for the viewport window (used for overlays)
    viewport_draw_list: ?*c.ImDrawList = null,

    pub fn init(allocator: std.mem.Allocator) UIRenderer {
        var renderer = UIRenderer{
            .allocator = allocator,
            .hierarchy_panel = SceneHierarchyPanel.init(),
            .asset_browser_panel = AssetBrowserPanel.init(allocator),
        };

        // Initialize asset browser by loading initial directory
        renderer.asset_browser_panel.refreshDirectory() catch |err| {
            std.debug.print("Failed to initialize asset browser: {}\n", .{err});
        };

        return renderer;
    }

    pub fn deinit(self: *UIRenderer) void {
        self.hierarchy_panel.deinit();
        self.asset_browser_panel.deinit();
    }

    /// Render all UI windows
    pub fn render(self: *UIRenderer, stats: RenderStats) void {
        // Note: Dockspace disabled - requires ImGui docking branch
        // For now, windows will be regular floating windows

        const viewport = c.ImGui_GetMainViewport();
        c.ImGui_SetNextWindowPos(viewport.*.Pos, c.ImGuiCond_Always);
        c.ImGui_SetNextWindowSize(viewport.*.Size, c.ImGuiCond_Always);
        c.ImGui_SetNextWindowViewport(viewport.*.ID);

        const window_flags = c.ImGuiWindowFlags_NoDocking |
            c.ImGuiWindowFlags_NoTitleBar | c.ImGuiWindowFlags_NoCollapse |
            c.ImGuiWindowFlags_NoResize | c.ImGuiWindowFlags_NoMove |
            c.ImGuiWindowFlags_NoBringToFrontOnFocus | c.ImGuiWindowFlags_NoNavFocus |
            c.ImGuiWindowFlags_NoBackground; // Transparent background for dockspace host

        c.ImGui_PushStyleVar(c.ImGuiStyleVar_WindowRounding, 0.0);
        c.ImGui_PushStyleVar(c.ImGuiStyleVar_WindowBorderSize, 0.0);
        c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_WindowPadding, .{ .x = 0, .y = 0 });

        _ = c.ImGui_Begin("DockSpace", null, window_flags);
        c.ImGui_PopStyleVar();
        c.ImGui_PopStyleVar();
        c.ImGui_PopStyleVar();

        // DockSpace
        const dockspace_id = c.ImGui_GetID("MyDockSpace");
        _ = c.ImGui_DockSpace(dockspace_id);

        c.ImGui_End();

        self.viewport_draw_list = null;

        // Transparent viewport window in the center
        const viewport_flags = c.ImGuiWindowFlags_NoBackground | c.ImGuiWindowFlags_NoScrollbar;
        _ = c.ImGui_Begin("Viewport", null, viewport_flags);
        // Record viewport position/size so other layers (picking, overlays) can use it
        // IMPORTANT: Use content region (excludes title bar) for accurate mouse picking
        const win_pos = c.ImGui_GetWindowPos();
        const content_region_min = c.ImGui_GetWindowContentRegionMin();
        const content_region_max = c.ImGui_GetWindowContentRegionMax();

        // Calculate actual content region position and size
        // Content region min/max are relative to window position
        self.viewport_pos = .{ win_pos.x + content_region_min.x, win_pos.y + content_region_min.y };
        self.viewport_size = .{ content_region_max.x - content_region_min.x, content_region_max.y - content_region_min.y };
        self.viewport_draw_list = c.ImGui_GetWindowDrawList();

        c.ImGui_Text("3D Viewport");
        c.ImGui_End();

        if (self.show_stats_window) {
            self.renderStatsWindow(stats);
        }

        if (self.show_camera_window) {
            self.renderCameraWindow(stats.camera_pos, stats.camera_rot);
        }

        if (self.show_performance_graphs) {
            self.renderPerformanceGraphs(stats);
        }

        if (self.show_asset_browser) {
            self.asset_browser_panel.render();
        }

        // NOTE: scene hierarchy is rendered by the caller after any picking logic
    }

    /// Render only the scene hierarchy (used by caller to render after picking)
    pub fn renderHierarchy(self: *UIRenderer, scene: *Scene) void {
        self.hierarchy_panel.render(scene);
    }

    pub fn renderSelectionOverlay(self: *UIRenderer, scene: *Scene, camera: *Camera) bool {
        if (self.viewport_draw_list == null) return false;
        const selected = self.hierarchy_panel.selected_entities.items;
        if (selected.len == 0) return false;
        if (self.viewport_size[0] < 1.0 or self.viewport_size[1] < 1.0) return false;

        const draw_list = self.viewport_draw_list.?;
        var sel_count: usize = 0;
        var last_aabb: ?ViewportPicker.AxisAlignedBoundingBox = null;
        for (selected) |entity| {
            if (ViewportPicker.computeEntityWorldAABB(scene, entity)) |aabb| {
                drawEntityAABB(self, draw_list, camera, aabb);
                sel_count += 1;
                last_aabb = aabb;
            }
        }

        // If a single entity is selected, draw and handle gizmo interaction at its center
        if (sel_count == 1) {
            if (last_aabb) |aabb| {
                const center = Math.Vec3.init((aabb.min.x + aabb.max.x) * 0.5, (aabb.min.y + aabb.max.y) * 0.5, (aabb.min.z + aabb.max.z) * 0.5);
                // Pass the scene and aabb center so the gizmo can perform interactive transforms
                return Gizmo.process(draw_list, self.viewport_pos, self.viewport_size, camera, center, scene, selected[0]);
            }
        }

        return false;
    }

    fn drawEntityAABB(self: *UIRenderer, draw_list: *c.ImDrawList, camera: *Camera, aabb: ViewportPicker.AxisAlignedBoundingBox) void {
        _ = self;
        const min = aabb.min;
        const max = aabb.max;
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

        var projected: [8][2]f32 = undefined;
        var i: usize = 0;
        while (i < corners.len) : (i += 1) {
            if (projectPointToViewport(camera, corners[i])) |screen_pos| {
                projected[i] = screen_pos;
            } else {
                return; // Skip drawing if any corner cannot be projected (behind camera or degenerate)
            }
        }

        const color: u32 = makeColor(255, 214, 0, 220);
        const edges = [_][2]usize{
            .{ 0, 1 }, .{ 0, 2 }, .{ 0, 4 },
            .{ 1, 3 }, .{ 1, 5 }, .{ 2, 3 },
            .{ 2, 6 }, .{ 3, 7 }, .{ 4, 5 },
            .{ 4, 6 }, .{ 5, 7 }, .{ 6, 7 },
        };

        for (edges) |edge| {
            const a = projected[edge[0]];
            const b = projected[edge[1]];
            c.ImDrawList_AddLine(draw_list, .{ .x = a[0], .y = a[1] }, .{ .x = b[0], .y = b[1] }, color);
        }
    }

    fn projectPointToViewport(camera: *Camera, point: Math.Vec3) ?[2]f32 {
        const point4 = Math.Vec4.init(point.x, point.y, point.z, 1.0);
        const view4 = transformVec4Row(&camera.viewMatrix, point4);
        if (view4.z <= 0.0) return null;

        const clip4 = transformVec4Row(&camera.projectionMatrix, view4);
        if (@abs(clip4.w) < 1e-6) return null;

        const inv_w = 1.0 / clip4.w;
        const ndc_x = clip4.x * inv_w;
        const ndc_y = clip4.y * inv_w;
        const ndc_z = clip4.z * inv_w;

        if (ndc_x < -1.0 or ndc_x > 1.0 or ndc_y < -1.0 or ndc_y > 1.0 or ndc_z < 0.0 or ndc_z > 1.0)
            return null;

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

    fn transformVec4Row(m: *Math.Mat4x4, v: Math.Vec4) Math.Vec4 {
        const x = v.x * m.get(0, 0).* + v.y * m.get(1, 0).* + v.z * m.get(2, 0).* + v.w * m.get(3, 0).*;
        const y = v.x * m.get(0, 1).* + v.y * m.get(1, 1).* + v.z * m.get(2, 1).* + v.w * m.get(3, 1).*;
        const z = v.x * m.get(0, 2).* + v.y * m.get(1, 2).* + v.z * m.get(2, 2).* + v.w * m.get(3, 2).*;
        const w = v.x * m.get(0, 3).* + v.y * m.get(1, 3).* + v.z * m.get(2, 3).* + v.w * m.get(3, 3).*;
        return Math.Vec4.init(x, y, z, w);
    }

    fn makeColor(r: u8, g: u8, b: u8, a: u8) u32 {
        return (@as(u32, a) << 24) | (@as(u32, b) << 16) | (@as(u32, g) << 8) | @as(u32, r);
    }

    fn renderStatsWindow(self: *UIRenderer, stats: RenderStats) void {
        _ = self;

        const window_flags = c.ImGuiWindowFlags_NoCollapse;

        if (c.ImGui_Begin("Render Stats", null, window_flags)) {
            // FPS breakdown with timing
            if (stats.performance_stats) |perf| {
                // Calculate FPS from times
                const total_frame_ms = stats.frame_time_ms;
                const total_fps = if (total_frame_ms > 0) 1000.0 / total_frame_ms else 0.0;

                const cpu_fps = if (perf.cpu_time_ms > 0) 1000.0 / perf.cpu_time_ms else 0.0;
                const gpu_fps = if (perf.gpu_time_ms > 0) 1000.0 / perf.gpu_time_ms else 0.0;

                c.ImGui_Text("CPU logic: %.1f fps (%.2f ms)", total_fps, total_frame_ms);
                c.ImGui_Text("CPU render: %.1f fps (%.2f ms)", cpu_fps, perf.cpu_time_ms);
                c.ImGui_Text("GPU render: %.1f fps (%.2f ms)", gpu_fps, perf.gpu_time_ms);
            } else {
                c.ImGui_Text("FPS: %.1f", stats.fps);
                c.ImGui_Text("Frame Time: %.2f ms", stats.frame_time_ms);
            }
            c.ImGui_Separator();

            c.ImGui_Text("Entities: %d", stats.entity_count);
            c.ImGui_Text("Draw Calls: %d", stats.draw_calls);
            c.ImGui_Separator();

            const pt_status: [*:0]const u8 = if (stats.path_tracing_enabled) "Enabled" else "Disabled";
            c.ImGui_Text("Path Tracing: %s", pt_status);
            c.ImGui_Text("Sample Count: %d", stats.sample_count);

            // Performance breakdown if available
            if (stats.performance_stats) |perf| {
                c.ImGui_Separator();
                c.ImGui_Text("Performance (rolling avg):");

                // Calculate pass sums
                var cpu_sum: f32 = 0.0;
                var gpu_sum: f32 = 0.0;
                for (perf.pass_timings) |pass_timing| {
                    if (pass_timing.name_len > 0) {
                        cpu_sum += pass_timing.getCpuTimeMs();
                        gpu_sum += pass_timing.getGpuTimeMs(perf.timestamp_period);
                    }
                }

                c.ImGui_Text("Pass breakdown:");
                c.ImGui_Text("  CPU sum: %.2f ms | GPU sum: %.2f ms", cpu_sum, gpu_sum);
                for (perf.pass_timings) |pass_timing| {
                    if (pass_timing.name_len == 0) continue;
                    const cpu_ms = pass_timing.getCpuTimeMs();
                    const gpu_ms = pass_timing.getGpuTimeMs(perf.timestamp_period);
                    const name = pass_timing.getName();
                    c.ImGui_Text("  %s: CPU %.2f ms | GPU %.2f ms", name.ptr, cpu_ms, gpu_ms);
                }

                const cpu_overhead = perf.cpu_time_ms - cpu_sum;
                const gpu_overhead = perf.gpu_time_ms - gpu_sum;
                c.ImGui_Text("Overhead: CPU %.2f ms | GPU %.2f ms", cpu_overhead, gpu_overhead);
            }
        }
        c.ImGui_End();
    }

    fn renderCameraWindow(self: *UIRenderer, pos: [3]f32, rot: [3]f32) void {
        _ = self;

        const window_flags = c.ImGuiWindowFlags_NoCollapse;

        if (c.ImGui_Begin("Camera", null, window_flags)) {
            c.ImGui_Text("Position:");
            c.ImGui_Text("  X: %.2f", pos[0]);
            c.ImGui_Text("  Y: %.2f", pos[1]);
            c.ImGui_Text("  Z: %.2f", pos[2]);
            c.ImGui_Separator();

            c.ImGui_Text("Rotation:");
            c.ImGui_Text("  Yaw:   %.2f", rot[0]);
            c.ImGui_Text("  Pitch: %.2f", rot[1]);
            c.ImGui_Text("  Roll:  %.2f", rot[2]);
        }
        c.ImGui_End();
    }

    fn renderPerformanceGraphs(self: *UIRenderer, stats: RenderStats) void {
        _ = self;

        if (stats.performance_stats) |perf| {
            const window_flags = c.ImGuiWindowFlags_NoCollapse;

            if (c.ImGui_Begin("Performance Graphs", null, window_flags)) {
                // Show last 2000 frames (about 1.4 seconds at 1400fps)
                const visible_frames: c_int = 2000;
                const graph_width: f32 = 800.0;
                const graph_height: f32 = 120.0;

                // CPU Frame Time Graph
                c.ImGui_Text("CPU Frame Time");
                c.ImGui_Text("Min: %.2f ms | Max: %.2f ms | Avg: %.2f ms", perf.cpu_min_ms, perf.cpu_max_ms, perf.cpu_avg_ms);

                // Show most recent N frames, scrolling right as new data comes in
                // Offset determines where to start reading from the circular buffer
                const history_size: usize = perf.cpu_frame_history.len;
                const write_pos: usize = perf.history_offset;

                // Start reading from (write_pos - visible_frames) to show the most recent data
                // This creates a scrolling effect where new frames appear on the right
                const frames_to_show: usize = @min(visible_frames, history_size);
                const start_pos: usize = if (write_pos >= frames_to_show)
                    write_pos - frames_to_show
                else
                    history_size - (frames_to_show - write_pos);

                c.ImGui_PlotLinesEx("##cpu", perf.cpu_frame_history.ptr, @intCast(frames_to_show), @intCast(start_pos), null, 0.0, perf.cpu_max_ms * 1.1, // Add 10% headroom
                    .{ .x = graph_width, .y = graph_height }, @sizeOf(f32));

                c.ImGui_Spacing();
                c.ImGui_Separator();
                c.ImGui_Spacing();

                // GPU Frame Time Graph
                c.ImGui_Text("GPU Frame Time");
                c.ImGui_Text("Min: %.2f ms | Max: %.2f ms | Avg: %.2f ms", perf.gpu_min_ms, perf.gpu_max_ms, perf.gpu_avg_ms);

                c.ImGui_PlotLinesEx("##gpu", perf.gpu_frame_history.ptr, @intCast(frames_to_show), @intCast(start_pos), null, 0.0, perf.gpu_max_ms * 1.1, // Add 10% headroom
                    .{ .x = graph_width, .y = graph_height }, @sizeOf(f32));
            }
            c.ImGui_End();
        }
    }
};

/// Stats passed from main application to UI
pub const RenderStats = struct {
    fps: f32 = 0.0,
    frame_time_ms: f32 = 0.0,
    entity_count: u32 = 0,
    draw_calls: u32 = 0,
    path_tracing_enabled: bool = false,
    sample_count: u32 = 0,
    camera_pos: [3]f32 = .{ 0, 0, 0 },
    camera_rot: [3]f32 = .{ 0, 0, 0 },

    // Performance monitoring
    performance_stats: ?PerformanceMonitor.PerformanceStats = null,

    // Scene reference for hierarchy panel
    scene: ?*Scene = null,
};
