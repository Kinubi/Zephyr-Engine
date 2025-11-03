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
    scripting_history_nav_pos: ?usize = null,
    // Console log viewer filters
    log_filter_trace: bool = false,
    log_filter_debug: bool = true,
    log_filter_info: bool = true,
    log_filter_warn: bool = true,
    log_filter_error: bool = true,
    // Search/filter text for logs (case-insensitive ASCII search)
    log_search_buffer: [256]u8 = undefined,
    // Auto-scroll logs to bottom when new entries arrive
    log_auto_scroll: bool = true,

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

        // Zero log search buffer
        var sbi: usize = 0;
        while (sbi < renderer.log_search_buffer.len) : (sbi += 1) renderer.log_search_buffer[sbi] = 0;

        // Initialize asset browser by loading initial directory
        renderer.asset_browser_panel.refreshDirectory() catch |err| {
            log(.ERROR, "ui", "Failed to initialize asset browser: {}", .{err});
        };

        // Initialize in-memory log buffer used by the editor console
        // This is optional and low-cost; safe to call multiple times.
        zephyr.initLogRingBuffer();

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

        // Borderless, transparent 3D viewport window
        const viewport_flags = c.ImGuiWindowFlags_NoBackground |
            c.ImGuiWindowFlags_NoScrollbar |
            c.ImGuiWindowFlags_NoTitleBar;

        c.ImGui_PushStyleVar(c.ImGuiStyleVar_WindowBorderSize, 0.0);
        c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_WindowPadding, .{ .x = 0, .y = 0 });

        _ = c.ImGui_Begin("Viewport", null, viewport_flags);

        // Capture viewport position/size for mouse picking and overlays
        // Use content region (excludes decorations) for accurate coordinate mapping
        const win_pos = c.ImGui_GetWindowPos();
        const content_region_min = c.ImGui_GetWindowContentRegionMin();
        const content_region_max = c.ImGui_GetWindowContentRegionMax();

        self.viewport_pos = .{ win_pos.x + content_region_min.x, win_pos.y + content_region_min.y };
        self.viewport_size = .{ content_region_max.x - content_region_min.x, content_region_max.y - content_region_min.y };
        self.viewport_draw_list = c.ImGui_GetWindowDrawList();

        // Display LDR-tonemapped scene texture
        if (self.viewport_texture_id) |tid| {
            if (self.viewport_size[0] >= 1.0 and self.viewport_size[1] >= 1.0) {
                const tex_ref = c.ImTextureRef{ ._TexData = null, ._TexID = tid };
                const size = c.ImVec2{ .x = self.viewport_size[0], .y = self.viewport_size[1] };
                c.ImGui_Image(tex_ref, size);
            }
        } else {
            c.ImGui_Text("3D Viewport");
        }

        c.ImGui_End();
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

        // Scripting console is a panel and should be rendered with other panels
        if (self.show_scripting_console) {
            self.renderScriptingConsole(stats);
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

    // Brief instructions
    c.ImGui_Text("Developer console — logs above, enter commands below.");
        c.ImGui_Separator();

        // --- Console: engine logs viewer (large area) ---
        // Log level filters and clear button (inline controls)
    // Search box for filtering logs (case-insensitive ASCII substring)
    c.ImGui_Text("Search:");
    c.ImGui_SameLine();
    _ = c.ImGui_InputText("##console_search", &self.log_search_buffer[0], self.log_search_buffer.len, 0);
    c.ImGui_SameLine();
        _ = c.ImGui_Checkbox("Trace", &self.log_filter_trace);
        c.ImGui_SameLine();
        _ = c.ImGui_Checkbox("Debug", &self.log_filter_debug);
        c.ImGui_SameLine();
        _ = c.ImGui_Checkbox("Info", &self.log_filter_info);
        c.ImGui_SameLine();
        _ = c.ImGui_Checkbox("Warn", &self.log_filter_warn);
        c.ImGui_SameLine();
        _ = c.ImGui_Checkbox("Error", &self.log_filter_error);
        c.ImGui_SameLine();
        if (c.ImGui_Button("Clear Logs")) {
            zephyr.clearLogs();
        }

        // Big logs child area (where the 'blank space' in your sketch appears)
        const logs_child_size = c.ImVec2{ .x = 0, .y = 300 };
        if (c.ImGui_BeginChild("##console_logs", logs_child_size, 0, 0)) {
            // Fetch recent logs (up to a reasonable cap)
            var entries: [256]zephyr.LogOut = undefined;
            const n = zephyr.fetchLogs(entries[0..]);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const e = entries[i];
                // Filter by selected levels
                const show = switch (e.level) {
                    .TRACE => self.log_filter_trace,
                    .DEBUG => self.log_filter_debug,
                    .INFO => self.log_filter_info,
                    .WARN => self.log_filter_warn,
                    .ERROR => self.log_filter_error,
                };
                if (!show) continue;

                // Choose color per level
                const col = switch (e.level) {
                    .TRACE => c.ImVec4{ .x = 0.6, .y = 0.6, .z = 0.6, .w = 1.0 },
                    .DEBUG => c.ImVec4{ .x = 0.0, .y = 0.8, .z = 0.8, .w = 1.0 },
                    .INFO => c.ImVec4{ .x = 1.0, .y = 1.0, .z = 1.0, .w = 1.0 },
                    .WARN => c.ImVec4{ .x = 1.0, .y = 0.9, .z = 0.0, .w = 1.0 },
                    .ERROR => c.ImVec4{ .x = 1.0, .y = 0.2, .z = 0.2, .w = 1.0 },
                };

                // Basic search filtering (case-insensitive ASCII) using search buffer
                var search_len: usize = 0;
                while (search_len < self.log_search_buffer.len) : (search_len += 1) {
                    if (self.log_search_buffer[search_len] == 0) break;
                }
                if (search_len > 0) {
                    const search_slice = self.log_search_buffer[0..search_len];
                    // Helper function declared at file scope: asciiContainsIgnoreCase

                    const sec_slice = e.section[0..e.section_len];
                    const msg_slice = e.message[0..e.message_len];
                    if (!asciiContainsIgnoreCase(sec_slice, search_slice) and !asciiContainsIgnoreCase(msg_slice, search_slice)) continue;
                }

                // Print: [SECTION] message (timestamp available in e.timestamp)
                var ts_buf: [64]u8 = undefined;
                var ts_slice: []const u8 = "";
                if (zephyr.time_format.formatTimestampBuf(&ts_buf, e.timestamp)) |ts| {
                    ts_slice = ts;
                } else |_| {
                    // Fallback to raw milliseconds if formatting fails
                    ts_slice = std.fmt.bufPrint(&ts_buf, "{d}ms", .{ e.timestamp }) catch "";
                }
                // Ensure NUL-termination
                if (ts_slice.len < ts_buf.len) ts_buf[ts_slice.len] = 0 else ts_buf[ts_buf.len - 1] = 0;

                // Use the ImGui_TextColored shortcut which pushes the text color, prints, then pops.
                // Signature: void ImGui_TextColored(ImVec4 col, const char* fmt, ...)
                c.ImGui_TextColored(col, "[%s] [%s] %s", &ts_buf[0], &e.section[0], &e.message[0]);
            }
            // Auto-scroll to bottom when enabled
            if (self.log_auto_scroll) {
                c.ImGui_SetScrollHereY(1.0);
            }
        }
        c.ImGui_EndChild();

        // Input area (single-line) at the bottom
        c.ImGui_Separator();
        // Single-line input occupying most of the row
        const input_buf_ptr = &self.scripting_input_buffer[0];
        // Input field: Enter returns true. Also accept raw Enter/KeypadEnter presses as a fallback.
        const input_returned = c.ImGui_InputText("##console_input", input_buf_ptr, self.scripting_input_buffer.len, c.ImGuiInputTextFlags_EnterReturnsTrue);
        const enter_pressed = c.ImGui_IsItemActive() and (c.ImGui_IsKeyPressed(c.ImGuiKey_Enter) or c.ImGui_IsKeyPressed(c.ImGuiKey_KeypadEnter));
        const input_submitted = input_returned or enter_pressed;

        // Handle Up/Down navigation when the input is active
        if (c.ImGui_IsItemActive()) {
            // Up arrow
            if (c.ImGui_IsKeyPressed(c.ImGuiKey_UpArrow)) {
                if (self.scripting_history_count > 0) {
                    const buf_len = self.scripting_history_storage.len;
                    const start_pos = (self.scripting_history_head + buf_len - self.scripting_history_count) % buf_len;
                    const end_pos = (self.scripting_history_head + buf_len - 1) % buf_len;
                    if (self.scripting_history_nav_pos) |pos| {
                        const new_pos: usize = if (pos == start_pos) end_pos else (pos + buf_len - 1) % buf_len;
                        self.scripting_history_nav_pos = new_pos;
                    } else {
                        self.scripting_history_nav_pos = end_pos;
                    }
                    // Load history entry into input buffer
                    if (self.scripting_history_nav_pos) |p| {
                        const len = self.scripting_history_lens[p];
                        std.mem.copyForwards(u8, self.scripting_input_buffer[0..len], self.scripting_history_storage[p][0..len]);
                        if (len < self.scripting_input_buffer.len) self.scripting_input_buffer[len] = 0;
                    }
                }
            }

            // Down arrow
            if (c.ImGui_IsKeyPressed(c.ImGuiKey_DownArrow)) {
                if (self.scripting_history_nav_pos) |pos| {
                    const buf_len = self.scripting_history_storage.len;
                    const end_pos = (self.scripting_history_head + buf_len - 1) % buf_len;
                    if (pos == end_pos) {
                        // Clear navigation and input
                        self.scripting_history_nav_pos = null;
                        self.scripting_input_buffer[0] = 0;
                    } else {
                        const new_pos = (pos + 1) % buf_len;
                        self.scripting_history_nav_pos = new_pos;
                        const len = self.scripting_history_lens[new_pos];
                        std.mem.copyForwards(u8, self.scripting_input_buffer[0..len], self.scripting_history_storage[new_pos][0..len]);
                        if (len < self.scripting_input_buffer.len) self.scripting_input_buffer[len] = 0;
                    }
                }
            }
        }

        var did_submit: bool = false;
        if (input_submitted) did_submit = true;
        c.ImGui_SameLine();
        if (c.ImGui_Button("Run")) did_submit = true;
        c.ImGui_SameLine();
        if (c.ImGui_Button("Clear")) {
            self.scripting_input_buffer[0] = 0;
            self.scripting_history_nav_pos = null;
        }

        if (did_submit) {
            // Determine input length
            var script_len: usize = 0;
            while (script_len < self.scripting_input_buffer.len) : (script_len += 1) {
                if (self.scripting_input_buffer[script_len] == 0) break;
            }
            if (script_len > 0) {
                const cmd = self.scripting_input_buffer[0..script_len];
                // Append to history and reset nav
                self.appendHistory(cmd);
                self.scripting_history_nav_pos = null;

                // Also log the command into the engine logs so it appears in the logs area
                zephyr.log(.INFO, "console", "{s}", .{cmd});

                // Execute via Lua if available
                if (stats.scene) |scene_ptr| {
                    const sys = &scene_ptr.scripting_system;
                    if (sys.runner.state_pool) |sp| {
                        const ls = sp.acquire();
                        const exec_res = lua.executeLuaBuffer(self.allocator, ls, cmd, 0, @ptrCast(scene_ptr)) catch {
                            self.appendHistory("(execute error)");
                            sp.release(ls);
                            return;
                        };
                        if (exec_res.message.len > 0) {
                            self.appendHistory(exec_res.message);
                        }
                        sp.release(ls);
                    } else {
                        self.appendHistory("(no lua state pool - cannot run synchronously)");
                    }
                } else {
                    self.appendHistory("(no scene available)");
                }

                // Clear input buffer after running
                self.scripting_input_buffer[0] = 0;
            }
        }

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

// File-scope helper: ASCII-only case-insensitive substring search.
fn asciiContainsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        var ok = true;
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            const a = hay[i + j];
            const b = needle[j];
            const al = if (a >= 'A' and a <= 'Z') a + 32 else a;
            const bl = if (b >= 'A' and b <= 'Z') b + 32 else b;
            if (al != bl) { ok = false; break; }
        }
        if (ok) return true;
    }
    return false;
}

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
