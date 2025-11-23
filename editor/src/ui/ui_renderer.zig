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
const cvar = zephyr.cvar;

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

    // When true the ImGui Viewport window is focused this frame.
    // Used by layers to decide whether UI should capture keyboard/mouse input
    // (we prefer the engine to receive input when the viewport is focused).
    viewport_focused: bool = false,

    // Save/Load Scene state
    show_save_scene_popup: bool = false,
    show_load_scene_popup: bool = false,
    scene_filename_buffer: [256]u8 = std.mem.zeroes([256]u8),

    // Scripting console (simple, fixed-size buffer + small ring history)
    show_scripting_console: bool = false,
    // True when the scripting console input text box is the active item this frame
    // (used by UILayer to decide whether to consume keyboard events immediately
    // even before ImGui's WantCaptureKeyboard reflects the new focus state).
    console_input_active: bool = false,
    scripting_input_buffer: [8192]u8 = undefined,
    scripting_history_storage: [32][256]u8 = undefined,
    scripting_history_lens: [32]usize = undefined,
    scripting_history_head: usize = 0,
    scripting_history_count: usize = 0,
    scripting_history_nav_pos: ?usize = null,
    // Reverse search (Ctrl+R) state
    reverse_search_requested: bool = false,
    reverse_search_query: [256]u8 = undefined,
    reverse_search_query_len: usize = 0,
    reverse_search_last_found: ?usize = null,
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
    // When true, we will focus the console input on the next frame before drawing it
    focus_console_input_next_frame: bool = false,

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

        // Load persistent console history from disk (optional). Each line is a past command.
        // On failure we log a warning but continue. Uses renderer.allocator for temporary reads.
        const history_path = "cache/console_history.txt";
        const fs = std.fs;
        const cwd = fs.cwd();
        var history_file: ?std.fs.File = null;
        const open_res = cwd.openFile(history_path, .{});
        if (open_res) |hf| {
            history_file = hf;
        } else |err| {
            // Could not open history file; not fatal, just warn
            log(.WARN, "ui", "Failed to open console history: {}", .{err});
        }

        if (history_file) |hf| {
            defer hf.close();
            var data: ?[]u8 = null;
            const read_res = hf.readToEndAlloc(renderer.allocator, 4096);
            if (read_res) |buf| {
                data = buf;
            } else |err| {
                log(.WARN, "ui", "Failed to read console history: {}", .{err});
            }

            if (data) |buf| {
                // Split into lines and append each non-empty line
                var start: usize = 0;
                var bi: usize = 0;
                while (bi <= buf.len) : (bi += 1) {
                    if (bi == buf.len or buf[bi] == '\n') {
                        var line = buf[start..bi];
                        // Trim trailing CR if present
                        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
                        if (line.len > 0) renderer.appendHistory(line);
                        start = bi + 1;
                    }
                }
                // Free the allocated buffer
                renderer.allocator.free(buf);
            }
        }

        return renderer;
    }

    pub fn deinit(self: *UIRenderer) void {
        self.hierarchy_panel.deinit();
        self.asset_browser_panel.deinit();
        // Persist console history to disk (overwrite). Non-fatal on failure.
        const fs = std.fs;
        const cwd = fs.cwd();
        const history_path = "cache/console_history.txt";
        const f_res = cwd.createFile(history_path, .{});
        if (f_res) |f| {
            defer f.close();
            const buf_len = self.scripting_history_storage.len;
            const start_pos = (self.scripting_history_head + buf_len - self.scripting_history_count) % buf_len;
            var idx: usize = 0;
            while (idx < self.scripting_history_count) : (idx += 1) {
                const pos = (start_pos + idx) % buf_len;
                const len = self.scripting_history_lens[pos];
                if (len > 0) {
                    const slice = self.scripting_history_storage[pos][0..len];
                    _ = f.writeAll(slice) catch |err| {
                        log(.WARN, "ui", "Failed to write history: {}", .{err});
                    };
                }
                _ = f.writeAll("\n") catch |err| {
                    log(.WARN, "ui", "Failed to write history newline: {}", .{err});
                };
            }
        } else |err| {
            log(.WARN, "ui", "Failed to create console history file: {}", .{err});
        }
    }

    /// Render all UI windows
    pub fn render(self: *UIRenderer, scene: *Scene) void {
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
            c.ImGuiWindowFlags_NoBackground;

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
            c.ImGuiWindowFlags_NoScrollbar;
        c.ImGui_PushStyleVar(c.ImGuiStyleVar_WindowBorderSize, 0.0);
        c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_WindowPadding, .{ .x = 0, .y = 0 });

        _ = c.ImGui_Begin("Viewport", null, viewport_flags);

        // Track whether the viewport window is focused. When the viewport is
        // focused we prefer the engine to receive input (so camera controls
        // / scene interactions work), and UI panels should not claim keyboard
        // focus. This flag is used by UILayer.event and InputLayer.
        // ImGui_IsWindowFocused returns a bool; set the viewport_focused flag
        // directly so other layers can decide whether UI should capture input.
        self.viewport_focused = c.ImGui_IsWindowFocused(0);

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

        // Main Menu Bar
        if (c.ImGui_BeginMainMenuBar()) {
            if (c.ImGui_BeginMenu("File")) {
                if (c.ImGui_MenuItem("Save Scene...")) {
                    const default_name = "scene.json";
                    @memcpy(self.scene_filename_buffer[0..default_name.len], default_name);
                    self.scene_filename_buffer[default_name.len] = 0;
                    self.show_save_scene_popup = true;
                }
                if (c.ImGui_MenuItem("Load Scene...")) {
                    self.scene_filename_buffer[0] = 0;
                    self.show_load_scene_popup = true;
                }
                c.ImGui_EndMenu();
            }
            c.ImGui_EndMainMenuBar();
        }

        // Save Scene Popup
        if (self.show_save_scene_popup) {
            c.ImGui_OpenPopup("Save Scene", 0);
            self.show_save_scene_popup = false;
        }
        if (c.ImGui_BeginPopupModal("Save Scene", null, c.ImGuiWindowFlags_AlwaysAutoResize)) {
            c.ImGui_Text("Enter filename:");
            _ = c.ImGui_InputText("##filename", &self.scene_filename_buffer[0], self.scene_filename_buffer.len, 0);
            
            if (c.ImGui_Button("Save")) {
                const len = std.mem.indexOfScalar(u8, &self.scene_filename_buffer, 0) orelse self.scene_filename_buffer.len;
                const filename = self.scene_filename_buffer[0..len];
                scene.save(filename) catch |err| {
                    log(.ERROR, "ui", "Failed to save scene: {}", .{err});
                };
                c.ImGui_CloseCurrentPopup();
            }
            c.ImGui_SameLine();
            if (c.ImGui_Button("Cancel")) {
                c.ImGui_CloseCurrentPopup();
            }
            c.ImGui_EndPopup();
        }

        // Load Scene Popup
        if (self.show_load_scene_popup) {
            c.ImGui_OpenPopup("Load Scene", 0);
            self.show_load_scene_popup = false;
        }
        if (c.ImGui_BeginPopupModal("Load Scene", null, c.ImGuiWindowFlags_AlwaysAutoResize)) {
            c.ImGui_Text("Enter filename:");
            _ = c.ImGui_InputText("##filename", &self.scene_filename_buffer[0], self.scene_filename_buffer.len, 0);
            
            if (c.ImGui_Button("Load")) {
                const len = std.mem.indexOfScalar(u8, &self.scene_filename_buffer, 0) orelse self.scene_filename_buffer.len;
                const filename = self.scene_filename_buffer[0..len];
                scene.load(filename) catch |err| {
                    log(.ERROR, "ui", "Failed to load scene: {}", .{err});
                };
                c.ImGui_CloseCurrentPopup();
            }
            c.ImGui_SameLine();
            if (c.ImGui_Button("Cancel")) {
                c.ImGui_CloseCurrentPopup();
            }
            c.ImGui_EndPopup();
        }
    }

    /// Render UI panels (stats, camera, performance, asset browser)
    /// Separated so it can be conditionally hidden with F1
    pub fn renderPanels(self: *UIRenderer, stats: RenderStats) void {
        // Reset per-frame input focus hints; specific panels can set them while rendering
        self.console_input_active = false;
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
                    ts_slice = std.fmt.bufPrint(&ts_buf, "{d}ms", .{e.timestamp}) catch "";
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
        // If requested from a previous frame action (like history nav), focus input now
        if (self.focus_console_input_next_frame) {
            c.ImGui_SetKeyboardFocusHere();
            self.focus_console_input_next_frame = false;
        }
        const input_returned = c.ImGui_InputText("##console_input", input_buf_ptr, self.scripting_input_buffer.len, c.ImGuiInputTextFlags_EnterReturnsTrue);
        // After InputText, track whether the console input currently owns keyboard focus
        self.console_input_active = c.ImGui_IsItemActive();
        const enter_pressed = self.console_input_active and (c.ImGui_IsKeyPressed(c.ImGuiKey_Enter) or c.ImGui_IsKeyPressed(c.ImGuiKey_KeypadEnter));
        // ImGui_InputText returns true on any text change as well as on Enter when
        // ImGuiInputTextFlags_EnterReturnsTrue is set. We must avoid treating
        // history navigation (which programmatically changes the buffer) as a
        // submission. Only consider input_returned a submission when Enter was
        // actually pressed this frame.
        const input_submitted = enter_pressed or (input_returned and (c.ImGui_IsKeyPressed(c.ImGuiKey_Enter) or c.ImGui_IsKeyPressed(c.ImGuiKey_KeypadEnter)));

        // If a reverse-search was requested (Ctrl+R from UILayer), process it
        if (self.reverse_search_requested) {
            // Copy current input into a temporary query buffer
            var cur_len: usize = 0;
            while (cur_len < self.scripting_input_buffer.len) : (cur_len += 1) {
                if (self.scripting_input_buffer[cur_len] == 0) break;
            }
            // If the query changed since last time, reset last_found so we start
            // searching from the most recent entry. Otherwise continue searching
            // earlier entries.
            var query_changed = true;
            if (cur_len == self.reverse_search_query_len) {
                if (cur_len == 0) {
                    query_changed = false;
                } else {
                    if (std.mem.eql(u8, self.reverse_search_query[0..cur_len], self.scripting_input_buffer[0..cur_len])) {
                        query_changed = false;
                    }
                }
            }
            if (query_changed) {
                // copy new query
                const copy_len = @min(cur_len, self.reverse_search_query.len);
                std.mem.copyForwards(u8, self.reverse_search_query[0..copy_len], self.scripting_input_buffer[0..copy_len]);
                if (copy_len < self.reverse_search_query.len) self.reverse_search_query[copy_len] = 0;
                self.reverse_search_query_len = copy_len;
                self.reverse_search_last_found = null;
            }

            // Only search if we have a non-empty query and there are history entries
            if (self.reverse_search_query_len > 0 and self.scripting_history_count > 0) {
                const buf_len = self.scripting_history_storage.len;
                var start_pos: usize = 0;
                if (self.reverse_search_last_found) |lf| {
                    start_pos = (lf + buf_len - 1) % buf_len;
                } else {
                    start_pos = (self.scripting_history_head + buf_len - 1) % buf_len;
                }

                var checked: usize = 0;
                var found: ?usize = null;
                var pos = start_pos;
                while (checked < self.scripting_history_count) : (checked += 1) {
                    const len = self.scripting_history_lens[pos];
                    if (len > 0) {
                        const entry = self.scripting_history_storage[pos][0..len];
                        if (asciiContainsIgnoreCase(entry, self.reverse_search_query[0..self.reverse_search_query_len])) {
                            found = pos;
                            break;
                        }
                    }
                    pos = if (pos == 0) buf_len - 1 else pos - 1;
                }

                if (found) |fpos| {
                    self.reverse_search_last_found = fpos;
                    self.scripting_history_nav_pos = fpos;
                    // Load history entry into input buffer
                    const len = self.scripting_history_lens[fpos];
                    std.mem.copyForwards(u8, self.scripting_input_buffer[0..len], self.scripting_history_storage[fpos][0..len]);
                    if (len < self.scripting_input_buffer.len) self.scripting_input_buffer[len] = 0;
                    // Ensure the input keeps focus on next frame
                    self.focus_console_input_next_frame = true;
                }
            }

            // Clear the request; subsequent Ctrl+R presses will set it again
            self.reverse_search_requested = false;
        }

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
                        // Request focusing the input at the beginning of next frame
                        self.focus_console_input_next_frame = true;
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
                        self.focus_console_input_next_frame = true;
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

                // Execute via Lua if available. Special-case a small runtime
                // test command `test_input_capture` which verifies whether
                // the console currently has focus and whether ImGui wants
                // to capture keyboard input. This helps validate that the
                // UI is correctly consuming keyboard events when the
                // console is active.
                if (std.mem.eql(u8, cmd, "test_input_capture")) {
                    const io = c.ImGui_GetIO();
                    var want_cap = false;
                    if (io) |io_ptr| want_cap = io_ptr.*.WantCaptureKeyboard;
                    log(.INFO, "console", "test_input_capture: console_input_active={s} want_capture_keyboard={s}", .{
                        if (self.console_input_active) "true" else "false",
                        if (want_cap) "true" else "false",
                    });
                } else {
                    // Try to handle common console commands locally (avoid spawning Lua when not necessary)
                    var handled: bool = false;
                    // Trim leading spaces
                    var sstart: usize = 0;
                    while (sstart < cmd.len and (cmd[sstart] == ' ' or cmd[sstart] == '\t')) sstart += 1;
                    var send: usize = cmd.len;
                    while (send > sstart and (cmd[send - 1] == ' ' or cmd[send - 1] == '\t')) send -= 1;
                    const trimmed = cmd[sstart..send];
                    // Extract first token
                    var t_end: usize = 0;
                    while (t_end < trimmed.len and trimmed[t_end] != ' ') t_end += 1;
                    const verb = trimmed[0..t_end];
                    // helpers to get remainder
                    const remainder = if (t_end < trimmed.len) trimmed[t_end + 1 .. trimmed.len] else trimmed[0..0];

                    // Compare verbs
                    if (std.mem.eql(u8, verb, "get")) {
                        handled = true; // Mark as handled to prevent Lua execution
                        const name = remainder;
                        if (name.len > 0) {
                            if (cvar.getGlobal()) |rp| {
                                const reg: *cvar.CVarRegistry = @ptrCast(rp);
                                if (reg.getAsStringAlloc(name, std.heap.page_allocator)) |v| {
                                    const vptr: [*]const u8 = @ptrCast(v);
                                    log(.INFO, "console", "{s} = {s}", .{ name, vptr[0..v.len] });
                                    std.heap.page_allocator.free(v);
                                } else {
                                    log(.WARN, "console", "CVar not found: {s}", .{name});
                                }
                            } else {
                                log(.ERROR, "console", "CVar system not initialized", .{});
                            }
                        } else {
                            log(.ERROR, "console", "Usage: get <cvar_name>", .{});
                        }
                    } else if (std.mem.eql(u8, verb, "set")) {
                        handled = true; // Mark as handled
                        // set <name> <value...>
                        var space: usize = 0;
                        var i: usize = 0;
                        while (i < remainder.len) {
                            if (remainder[i] == ' ') {
                                space = i;
                                break;
                            }
                            i += 1;
                        }
                        if (space > 0) {
                            const name = remainder[0..space];
                            const val = remainder[space + 1 .. remainder.len];
                            if (cvar.getGlobal()) |rp| {
                                const reg: *cvar.CVarRegistry = @ptrCast(rp);
                                reg.setFromString(name, val) catch |err| {
                                    log(.ERROR, "console", "Failed to set CVar {s}: {}", .{ name, err });
                                };
                                log(.INFO, "console", "Set {s} = {s}", .{ name, val });
                            } else {
                                log(.ERROR, "console", "CVar system not initialized", .{});
                            }
                        } else {
                            log(.ERROR, "console", "Usage: set <cvar_name> <value>", .{});
                        }
                    } else if (std.mem.eql(u8, verb, "toggle")) {
                        handled = true; // Mark as handled
                        const name = remainder;
                        if (name.len > 0) {
                            if (cvar.getGlobal()) |rp| {
                                const reg: *cvar.CVarRegistry = @ptrCast(rp);
                                if (reg.getAsStringAlloc(name, std.heap.page_allocator)) |v| {
                                    var newv: []const u8 = "true";
                                    if (std.mem.eql(u8, v, "true")) newv = "false";
                                    std.heap.page_allocator.free(v);
                                    _ = reg.setFromString(name, newv) catch {};
                                    log(.INFO, "console", "Toggled {s} -> {s}", .{ name, newv });
                                } else {
                                    log(.WARN, "console", "CVar not found: {s}", .{name});
                                }
                            } else {
                                log(.ERROR, "console", "CVar system not initialized", .{});
                            }
                        } else {
                            log(.ERROR, "console", "Usage: toggle <cvar_name>", .{});
                        }
                    } else if (std.mem.eql(u8, verb, "reset")) {
                        handled = true; // Mark as handled
                        const name = remainder;
                        if (name.len > 0) {
                            if (cvar.getGlobal()) |rp| {
                                const reg: *cvar.CVarRegistry = @ptrCast(rp);
                                const ok = reg.reset(name) catch false;
                                if (ok) {
                                    log(.INFO, "console", "Reset {s}", .{name});
                                } else {
                                    log(.WARN, "console", "CVar not found: {s}", .{name});
                                }
                            } else {
                                log(.ERROR, "console", "CVar system not initialized", .{});
                            }
                        } else {
                            log(.ERROR, "console", "Usage: reset <cvar_name>", .{});
                        }
                    } else if (std.mem.eql(u8, verb, "list")) {
                        handled = true; // Mark as handled
                        const filter = remainder;
                        if (cvar.getGlobal()) |rp| {
                            const reg: *cvar.CVarRegistry = @ptrCast(rp);
                            const list = reg.listAllAlloc(std.heap.page_allocator) catch null;
                            if (list) |lst| {
                                var idx: usize = 0;
                                while (idx < lst.len) : (idx += 1) {
                                    const s = lst[idx];
                                    if (filter.len == 0 or std.mem.indexOf(u8, s, filter) != null) {
                                        const sptr: [*]const u8 = @ptrCast(s.ptr);
                                        log(.INFO, "console", "{s}", .{sptr[0..s.len]});
                                    }
                                }
                                std.heap.page_allocator.free(lst);
                            }
                        } else {
                            log(.ERROR, "console", "CVar system not initialized", .{});
                        }
                    } else if (std.mem.eql(u8, verb, "help")) {
                        const name = remainder;
                        if (name.len > 0) {
                            if (cvar.getGlobal()) |rp| {
                                const reg: *cvar.CVarRegistry = @ptrCast(rp);
                                if (reg.getDescriptionAlloc(name, std.heap.page_allocator)) |d| {
                                    const dptr: [*]const u8 = @ptrCast(d.ptr);
                                    log(.INFO, "console", "{s}: {s}", .{ name, dptr[0..d.len] });
                                    std.heap.page_allocator.free(d);
                                } else {
                                    log(.INFO, "console", "No help available for {s}", .{name});
                                }
                                handled = true;
                            }
                        } else {
                            // Show general help
                            log(.INFO, "console", "=== Console Commands ===", .{});
                            log(.INFO, "console", "  get <cvar>           - Get CVar value", .{});
                            log(.INFO, "console", "  set <cvar> <value>   - Set CVar value", .{});
                            log(.INFO, "console", "  toggle <cvar>        - Toggle boolean CVar", .{});
                            log(.INFO, "console", "  list [pattern]       - List all CVars (optional filter)", .{});
                            log(.INFO, "console", "  help <cvar>          - Show CVar description", .{});
                            log(.INFO, "console", "", .{});
                            log(.INFO, "console", "Memory Tracking CVars:", .{});
                            log(.INFO, "console", "  r_trackMemory        - Enable GPU memory tracking (requires restart)", .{});
                            log(.INFO, "console", "  r_logMemoryAllocs    - Log individual allocations", .{});
                            handled = true;
                        }
                    } else if (std.mem.eql(u8, verb, "archive")) {
                        handled = true; // Mark as handled
                        // archive <name> <0|1|true|false>
                        var space: usize = 0;
                        var i: usize = 0;
                        while (i < remainder.len) {
                            if (remainder[i] == ' ') {
                                space = i;
                                break;
                            }
                            i += 1;
                        }
                        if (space > 0) {
                            const name = remainder[0..space];
                            const val = remainder[space + 1 .. remainder.len];
                            var archive_bool: bool = false;
                            if (std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "true")) archive_bool = true;
                            if (cvar.getGlobal()) |rp| {
                                const reg: *cvar.CVarRegistry = @ptrCast(rp);
                                const ok = reg.setArchived(name, archive_bool) catch false;
                                if (ok) {
                                    log(.INFO, "console", "Archived {s} = {s}", .{ name, if (archive_bool) "true" else "false" });
                                } else {
                                    log(.WARN, "console", "CVar not found: {s}", .{name});
                                }
                            } else {
                                log(.ERROR, "console", "CVar system not initialized", .{});
                            }
                        } else {
                            log(.ERROR, "console", "Usage: archive <cvar_name> <0|1|true|false>", .{});
                        }
                    }

                    if (!handled) {
                        // Fallback to executing as Lua
                        if (stats.scene) |scene_ptr| {
                            const sys = &scene_ptr.scripting_system;
                            if (sys.runner.state_pool) |sp| {
                                const ls = sp.acquire();
                                defer sp.release(ls);
                                if (lua.executeLuaBuffer(self.allocator, ls, cmd, 0, @ptrCast(scene_ptr))) |exec_res| {
                                    defer {
                                        // Free the message if it was allocated
                                        if (exec_res.message.len > 0) {
                                            self.allocator.free(exec_res.message);
                                        }
                                    }
                                    if (exec_res.message.len > 0) log(.INFO, "console", "{s}", .{exec_res.message});
                                } else |err| {
                                    log(.ERROR, "console", "Lua execution error: {}", .{err});
                                }
                            } else {
                                log(.WARN, "console", "(no lua state pool - cannot run synchronously)", .{});
                            }
                        } else {
                            log(.WARN, "console", "(no scene available)", .{});
                        }
                    }
                }

                // Clear input buffer after running
                self.scripting_input_buffer[0] = 0;
                // Keep focus on the input after submitting (behave like Up/Down navigation)
                self.focus_console_input_next_frame = true;
            }
        }

        c.ImGui_End();
    }

    fn appendHistory(self: *UIRenderer, msg: []const u8) void {
        // Skip consecutive duplicate entries (avoid flooding history with the same command)
        if (self.scripting_history_count > 0) {
            const last_index = (self.scripting_history_head + self.scripting_history_storage.len - 1) % self.scripting_history_storage.len;
            const last_len = self.scripting_history_lens[last_index];
            if (last_len == msg.len) {
                if (std.mem.eql(u8, self.scripting_history_storage[last_index][0..last_len], msg)) return;
            }
        }

        const copy_len = @min(msg.len, self.scripting_history_storage[0].len - 1);
        std.mem.copyForwards(u8, self.scripting_history_storage[self.scripting_history_head][0..copy_len], msg[0..copy_len]);
        self.scripting_history_storage[self.scripting_history_head][copy_len] = 0;
        self.scripting_history_lens[self.scripting_history_head] = copy_len;
        self.scripting_history_head = (self.scripting_history_head + 1) % self.scripting_history_storage.len;
        if (self.scripting_history_count < self.scripting_history_storage.len) self.scripting_history_count += 1;

        // Persisting the full history is done on deinit to avoid dealing with
        // platform-specific append flags here. See deinit() for the writeback.
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
            if (al != bl) {
                ok = false;
                break;
            }
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
