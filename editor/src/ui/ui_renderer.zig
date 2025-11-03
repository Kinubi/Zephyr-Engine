const std = @import("std");
const zephyr = @import("zephyr");
const log = zephyr.log;

const c = @import("backend/imgui_c.zig").c;

const PerformanceMonitor = zephyr.PerformanceMonitor;
const SceneHierarchyPanel = @import("scene_hierarchy_panel.zig").SceneHierarchyPanel;
const AssetBrowserPanel = @import("asset_browser_panel.zig").AssetBrowserPanel;
const ViewportPicker = @import("viewport_picker.zig");
const Gizmo = @import("gizmo.zig").Gizmo;
const UIMath = @import("backend/ui_math.zig");
const Scene = zephyr.Scene;
const Camera = zephyr.Camera;
const Math = zephyr.math;
// Lua bindings (used by the scripting console)
const lua = zephyr.lua;

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

    // Viewport texture (offscreen render target) to display inside the Viewport window
    viewport_texture_id: ?c.ImTextureID = null,

    // Scripting console (simple, fixed-size buffer + small ring history)
    show_scripting_console: bool = false,
    scripting_input_buffer: [8192]u8 = undefined,
    scripting_history_storage: [32][256]u8 = undefined,
    scripting_history_lens: [32]usize = undefined,
    scripting_history_head: usize = 0,
    scripting_history_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator) UIRenderer {
        var renderer = UIRenderer{
            .allocator = allocator,
            .hierarchy_panel = SceneHierarchyPanel.init(),
            .asset_browser_panel = AssetBrowserPanel.init(allocator),
        };

        // Zero fixed-size console buffers
        var i: usize = 0;
        while (i < renderer.scripting_input_buffer.len) : (i += 1) {
            renderer.scripting_input_buffer[i] = 0;
        }

        var ri: usize = 0;
        while (ri < renderer.scripting_history_storage.len) : (ri += 1) {
            var cj: usize = 0;
            while (cj < renderer.scripting_history_storage[ri].len) : (cj += 1) {
                renderer.scripting_history_storage[ri][cj] = 0;
            }
        }

        var li: usize = 0;
        while (li < renderer.scripting_history_lens.len) : (li += 1) {
            renderer.scripting_history_lens[li] = 0;
        }

        // Initialize asset browser by loading initial directory
        renderer.asset_browser_panel.refreshDirectory() catch |err| {
            log(.ERROR, "ui", "Failed to initialize asset browser: {}", .{err});
        };

        return renderer;
    }

    pub fn deinit(self: *UIRenderer) void {
        self.hierarchy_panel.deinit();
        self.asset_browser_panel.deinit();
    }

    /// Render all UI windows
    pub fn render(self: *UIRenderer) void {
        // Note: Dockspace disabled - requires ImGui docking branch
        // For now, windows will be regular floating windows

        // Ensure non-viewport panels are fully opaque (no subtle transparency)
        // We'll keep the viewport window transparent (NoBackground flag) separately.
        const style = c.ImGui_GetStyle();
        if (style) |s| {
            // Force WindowBg alpha to 1.0 every frame (harmless if already 1.0)
            s.*.Colors[c.ImGuiCol_WindowBg].w = 1.0;
        }

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
        const viewport_flags = c.ImGuiWindowFlags_NoBackground |
            c.ImGuiWindowFlags_NoScrollbar |
            c.ImGuiWindowFlags_NoTitleBar;

        // Remove border from viewport window
        c.ImGui_PushStyleVar(c.ImGuiStyleVar_WindowBorderSize, 0.0);
        c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_WindowPadding, .{ .x = 0, .y = 0 });

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

        // Draw the viewport image if available
        if (self.viewport_texture_id) |tid| {
            // Guard against degenerate sizes
            if (self.viewport_size[0] >= 1.0 and self.viewport_size[1] >= 1.0) {
                const tex_ref = c.ImTextureRef{ ._TexData = null, ._TexID = tid };
                const size = c.ImVec2{ .x = self.viewport_size[0], .y = self.viewport_size[1] };
                c.ImGui_Image(tex_ref, size);
            }
        } else {
            c.ImGui_Text("3D Viewport");
        }
        c.ImGui_End();

        // Pop style variables
        c.ImGui_PopStyleVar();
        c.ImGui_PopStyleVar();
    }

    /// Render UI panels (stats, camera, performance, asset browser)
    /// Separated so it can be conditionally hidden with F1
    pub fn renderPanels(self: *UIRenderer, stats: RenderStats) void {
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
        // Clip all overlay drawing to the viewport content region so it doesn't
        // spill over into other panels when geometry projects outside the view.
        const clip_min = c.ImVec2{ .x = self.viewport_pos[0], .y = self.viewport_pos[1] };
        const clip_max = c.ImVec2{ .x = self.viewport_pos[0] + self.viewport_size[0], .y = self.viewport_pos[1] + self.viewport_size[1] };
        c.ImDrawList_PushClipRect(draw_list, clip_min, clip_max, true);
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
                const consumed = Gizmo.process(draw_list, self.viewport_pos, self.viewport_size, camera, center, scene, selected[0]);
                c.ImDrawList_PopClipRect(draw_list);
                return consumed;
            }
        }

        c.ImDrawList_PopClipRect(draw_list);
        return false;
    }

    fn drawEntityAABB(self: *UIRenderer, draw_list: *c.ImDrawList, camera: *Camera, aabb: ViewportPicker.AxisAlignedBoundingBox) void {
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
            if (UIMath.project(camera, self.viewport_size, corners[i])) |viewport_pos| {
                // Convert viewport-relative coordinates to window coordinates for ImGui drawing
                projected[i] = .{ viewport_pos[0] + self.viewport_pos[0], viewport_pos[1] + self.viewport_pos[1] };
            } else {
                return; // Skip drawing if any corner cannot be projected (behind camera or degenerate)
            }
        }

        const color: u32 = UIMath.makeColor(255, 214, 0, 220);
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

    // Projection and matrix helpers moved to `ui_math.zig` and reused here via UIMath

    // Color helper moved to `ui_math.zig` and reused via UIMath

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

    fn renderScriptingConsole(self: *UIRenderer, stats: RenderStats) void {
        const window_flags = c.ImGuiWindowFlags_None;

        if (!c.ImGui_Begin("Scripting Console", &self.show_scripting_console, window_flags)) {
            c.ImGui_End();
            return;
        }

        // Toggle instructions
        c.ImGui_Text("Lua scripting console. Runs code synchronously on the main thread when possible.");
        c.ImGui_Separator();

        // Input text multiline
        // ImGui expects a NUL-terminated char buffer; we provide a fixed-size buffer.
        // Multiline input: use minimal signature provided by c-binding
        _ = c.ImGui_InputTextMultiline("##script_input", &self.scripting_input_buffer[0], self.scripting_input_buffer.len);

        // Buttons: Run (sync) and Clear
        if (c.ImGui_Button("Run (Sync)")) {
            // Determine script length (find first NUL)
            var script_len: usize = 0;
            while (script_len < self.scripting_input_buffer.len) : (script_len += 1) {
                if (self.scripting_input_buffer[script_len] == 0) break;
            }

            if (script_len > 0) {
                // Ensure we have a Scene to execute against
                if (stats.scene) |scene_ptr| {
                    // Try to use the Scene-owned scripting system's lua state pool (synchronous)
                    const sys = &scene_ptr.scripting_system;
                    var executed: bool = false;
                    if (sys.runner.state_pool) |sp| {
                        const ls = sp.acquire();
                        // Execute using the lua binding. Use UIRenderer's allocator for temporary allocations.
                        const buf_slice = self.scripting_input_buffer[0..script_len];
                        var res = lua.ExecuteResult{ .success = false, .message = "" };
                        const exec_res = lua.executeLuaBuffer(self.allocator, ls, buf_slice, 0, @ptrCast(scene_ptr)) catch {
                            // on allocation/other error, append message and release state
                            self.appendHistory("(execute error)");
                            sp.release(ls);
                            executed = true;
                            return;
                        };
                        res = exec_res;

                        // Append result to history (copying up to slot size)
                        if (res.message.len > 0) {
                            const copy_len = @min(res.message.len, self.scripting_history_storage[0].len - 1);
                            std.mem.copyForwards(u8, self.scripting_history_storage[self.scripting_history_head][0..copy_len], res.message[0..copy_len]);
                            self.scripting_history_storage[self.scripting_history_head][copy_len] = 0;
                            self.scripting_history_lens[self.scripting_history_head] = copy_len;
                            self.scripting_history_head = (self.scripting_history_head + 1) % self.scripting_history_storage.len;
                            if (self.scripting_history_count < self.scripting_history_storage.len) self.scripting_history_count += 1;
                        } else {
                            const okmsg = "(ok)";
                            self.appendHistory(@as([]const u8, okmsg));
                        }

                        // Release leased state
                        sp.release(ls);
                        executed = true;
                    }

                    if (!executed) {
                        // Could not execute synchronously (no state pool); inform user
                        self.appendHistory("(no lua state pool - cannot run synchronously)");
                    }
                } else {
                    self.appendHistory("(no scene available)");
                }
            }
        }

        c.ImGui_SameLine();
        if (c.ImGui_Button("Clear")) {
            // NUL the input buffer
            self.scripting_input_buffer[0] = 0;
        }

        c.ImGui_Separator();

        // History pane (read-only)
        const hist_size = c.ImVec2{ .x = 0, .y = 200 };
        if (c.ImGui_BeginChild("##script_history", hist_size, 0, 0)) {
            var idx: usize = 0;
            while (idx < self.scripting_history_count) : (idx += 1) {
                const pos = (self.scripting_history_head + self.scripting_history_storage.len - self.scripting_history_count + idx) % self.scripting_history_storage.len;
                const len = self.scripting_history_lens[pos];
                if (len > 0) {
                    c.ImGui_Text("%s", &self.scripting_history_storage[pos][0]);
                }
            }
        }
        // ImGui requires EndChild() to be called after BeginChild() even if BeginChild returned false
        c.ImGui_EndChild();

        c.ImGui_End();
    }

    fn appendHistory(self: *UIRenderer, msg: []const u8) void {
        const copy_len = @min(msg.len, self.scripting_history_storage[0].len - 1);
        std.mem.copyForwards(u8, self.scripting_history_storage[self.scripting_history_head][0..copy_len], msg[0..copy_len]);
        self.scripting_history_storage[self.scripting_history_head][copy_len] = 0;
        self.scripting_history_lens[self.scripting_history_head] = copy_len;
        self.scripting_history_head = (self.scripting_history_head + 1) % self.scripting_history_storage.len;
        if (self.scripting_history_count < self.scripting_history_storage.len) self.scripting_history_count += 1;
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
