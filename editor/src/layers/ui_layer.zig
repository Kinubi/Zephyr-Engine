const std = @import("std");
const zephyr = @import("zephyr");

const Layer = zephyr.Layer;
const Event = zephyr.Event;
const EventType = zephyr.EventType;
const FrameInfo = zephyr.FrameInfo;
const log = zephyr.log;
const ImGuiContext = @import("../ui/backend/imgui_context.zig").ImGuiContext;
const UIRenderer = @import("../ui/ui_renderer.zig").UIRenderer;
const RenderStats = @import("../ui/ui_renderer.zig").RenderStats;
const ViewportPicker = @import("../ui/viewport_picker.zig");
const PerformanceMonitor = zephyr.PerformanceMonitor;
const Swapchain = zephyr.Swapchain;
const Texture = zephyr.Texture;
const GraphicsContext = zephyr.GraphicsContext;
const vk = @import("vulkan");
const Scene = zephyr.Scene;
const Camera = zephyr.Camera;
const CameraController = zephyr.CameraController;
const c = @import("../ui/backend/imgui_c.zig").c;
const Gizmo = @import("../ui/gizmo.zig").Gizmo;
const MAX_FRAMES_IN_FLIGHT = zephyr.MAX_FRAMES_IN_FLIGHT;

/// UI overlay layer
/// Renders ImGui interface with performance stats and debug info
pub const UILayer = struct {
    base: Layer,
    imgui_context: *ImGuiContext,
    ui_renderer: *UIRenderer,
    performance_monitor: ?*PerformanceMonitor,
    swapchain: *Swapchain,
    scene: *Scene,
    camera: *Camera,
    camera_controller: *CameraController,
    show_ui: bool = true,
    show_ui_panels: bool = true, // Hide all panels except viewport when false
    current_fps: f32 = 0.0,

    // LDR tonemapped viewport texture for UI display (per-frame)
    viewport_ldr: [MAX_FRAMES_IN_FLIGHT]?Texture = [_]?Texture{null} ** MAX_FRAMES_IN_FLIGHT,
    viewport_extent: vk.Extent2D = .{ .width = 0, .height = 0 },
    viewport_imgui_id: c.ImTextureID = 0,
    viewport_sampler: vk.Sampler = .null_handle,

    pub fn init(
        imgui_context: *ImGuiContext,
        ui_renderer: *UIRenderer,
        performance_monitor: ?*PerformanceMonitor,
        swapchain: *Swapchain,
        scene: *Scene,
        camera: *Camera,
        camera_controller: *CameraController,
    ) UILayer {
        return .{
            .base = .{
                .name = "UILayer",
                .enabled = true,
                .vtable = &vtable,
            },
            .imgui_context = imgui_context,
            .ui_renderer = ui_renderer,
            .performance_monitor = performance_monitor,
            .swapchain = swapchain,
            .scene = scene,
            .camera = camera,
            .camera_controller = camera_controller,
        };
    }

    const vtable = Layer.VTable{
        .attach = attach,
        .detach = detach,
        .prepare = null, // UILayer has no main thread preparation work
        .begin = begin,
        .update = update,
        .render = render,
        .end = end,
        .event = event,
    };

    fn attach(base: *Layer) !void {
        const self: *UILayer = @fieldParentPtr("base", base);
        _ = self;
    }

    fn detach(base: *Layer) void {
        const self: *UILayer = @fieldParentPtr("base", base);
        // Destroy per-frame viewport LDR textures
        inline for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            if (self.viewport_ldr[i]) |*ldrt| {
                ldrt.deinit();
                self.viewport_ldr[i] = null;
            }
        }
        // Destroy viewport sampler if created
        if (self.viewport_sampler != .null_handle) {
            self.swapchain.gc.vkd.destroySampler(self.swapchain.gc.dev, self.viewport_sampler, null);
            self.viewport_sampler = .null_handle;
        }
    }

    fn begin(base: *Layer, frame_info: *const FrameInfo) !void {
        const self: *UILayer = @fieldParentPtr("base", base);

        // Ensure HDR and LDR viewport textures exist and match current viewport size
        _ = try ensureViewportTargets(self, frame_info);

        // Update frame_info with current HDR texture (may have been recreated during resize)
        const mutable_frame_info: *FrameInfo = @constCast(frame_info);
        mutable_frame_info.hdr_texture = self.swapchain.currentHdrTexture();

        // Configure frame_info to render to viewport-sized LDR texture (not swapchain)
        if (self.viewport_ldr[frame_info.current_frame]) |*ldr_tex| {
            mutable_frame_info.color_image = ldr_tex.image;
            mutable_frame_info.color_image_view = ldr_tex.image_view;
            mutable_frame_info.extent = self.viewport_extent;
        }

        // Expose viewport texture to UIRenderer for display
        if (self.viewport_imgui_id != 0) {
            self.ui_renderer.viewport_texture_id = self.viewport_imgui_id;
        }
    }

    fn update(base: *Layer, frame_info: *const FrameInfo) !void {
        const self: *UILayer = @fieldParentPtr("base", base);

        if (!self.show_ui) return;

        // Update FPS estimate from dt (smoothed)
        self.current_fps = if (frame_info.dt > 0.0) 1.0 / frame_info.dt else 0.0;
    }

    fn render(base: *Layer, frame_info: *const FrameInfo) !void {
        const self: *UILayer = @fieldParentPtr("base", base);

        if (!self.show_ui) return;

        // Swapchain image transitions are handled centrally in swapchain.beginFrame/endFrame.

        // Begin new ImGui frame
        self.imgui_context.newFrame();

        // Prepare render stats
        const perf_stats = if (self.performance_monitor) |pm| pm.getStats() else null;

        // Check path tracing status
        const pt_enabled = if (self.scene.render_graph) |*graph| blk: {
            break :blk if (graph.getPass("path_tracing_pass")) |pass| pass.enabled else false;
        } else false;

        const stats = RenderStats{
            .fps = self.current_fps,
            .frame_time_ms = frame_info.dt * 1000.0,
            .entity_count = self.scene.ecs_world.entityCount(),
            .draw_calls = 0, // TODO: Get from render stats
            .path_tracing_enabled = pt_enabled,
            .camera_pos = .{ self.camera_controller.position.x, self.camera_controller.position.y, self.camera_controller.position.z },
            .camera_rot = .{ self.camera_controller.rotation.x, self.camera_controller.rotation.y, self.camera_controller.rotation.z },
            .performance_stats = perf_stats,
            .scene = self.scene,
        };

        // Render UI viewport (always visible)
        self.ui_renderer.render();

        // Publish UI capture state for engine layers (base→overlays dispatch means
        // SceneLayer has already seen events this frame; still, this keeps a stable
        // per-frame signal for gating scene input like toggles and camera control).
        const io_after = c.ImGui_GetIO();
        var want_kb_after: bool = false;
        var want_mouse_after: bool = false;
        if (io_after) |i| {
            want_kb_after = i.*.WantCaptureKeyboard;
            want_mouse_after = i.*.WantCaptureMouse;
        }

        // Render UI panels (conditionally hidden with F1)
        if (self.show_ui_panels) {
            self.ui_renderer.renderPanels(stats);
        }

        // Draw overlays (gizmo) and give the gizmo a chance to consume mouse clicks
        const gizmo_consumed: bool = self.ui_renderer.renderSelectionOverlay(self.scene, self.camera);

        // Accurate CPU-based picking using per-triangle raycasts (viewport_picker)
        // Only run scene picking if the gizmo did not consume the click (i.e. a gizmo handle wasn't clicked)
        if (!gizmo_consumed) {
            const io = c.ImGui_GetIO();
            const mouse_x = io.*.MousePos.x;
            const mouse_y = io.*.MousePos.y;

            const mouse_clicked = c.ImGui_IsMouseClicked(0);

            // Check if mouse is within viewport bounds (regardless of ImGui's WantCaptureMouse)
            // This allows picking even when ImGui thinks it should capture the mouse
            if (mouse_clicked) {
                const vp_pos = self.ui_renderer.viewport_pos;
                const vp_size = self.ui_renderer.viewport_size;

                const in_viewport = vp_size[0] > 1.0 and vp_size[1] > 1.0 and
                    mouse_x >= vp_pos[0] and mouse_x <= vp_pos[0] + vp_size[0] and
                    mouse_y >= vp_pos[1] and mouse_y <= vp_pos[1] + vp_size[1];

                // Pick if click is within viewport bounds
                // We check viewport bounds instead of WantCaptureMouse because the viewport window
                // itself is an ImGui window, so ImGui always wants to capture mouse over it
                if (in_viewport) {
                    // Convert mouse position from window space to viewport space
                    const viewport_mouse_x = mouse_x - vp_pos[0];
                    const viewport_mouse_y = mouse_y - vp_pos[1];

                    if (ViewportPicker.pickScene(self.scene, self.camera, viewport_mouse_x, viewport_mouse_y, vp_size)) |res| {
                        // Single-select the hit entity
                        if (self.ui_renderer.hierarchy_panel.selected_entities.items.len > 0) {
                            self.ui_renderer.hierarchy_panel.selected_entities.clearRetainingCapacity();
                        }
                        _ = self.ui_renderer.hierarchy_panel.selected_entities.append(std.heap.page_allocator, res.entity) catch {};
                    } else {
                        // Click in viewport but no hit - clear selection
                        self.ui_renderer.hierarchy_panel.selected_entities.clearRetainingCapacity();
                    }
                }
            }
        }

        // Now render the scene hierarchy so the new selection is visible immediately
        if (self.show_ui_panels) {
            self.ui_renderer.renderHierarchy(self.scene);
        }

        // Note: Camera aspect ratio is updated in begin() via ensureViewportTargets().
        // ImGui computes the new viewport_size during this render() call, which will be
        // used in the next frame's begin() to create correctly-sized textures and update
        // the camera projection. This one-frame delay is unavoidable since we can't know
        // the viewport size until ImGui has laid out the UI.

        // Begin GPU timing for ImGui rendering
        if (self.performance_monitor) |pm| {
            try pm.beginPass("imgui", frame_info.current_frame, frame_info.command_buffer);
        }

        // Render ImGui to command buffer
        try self.imgui_context.render(frame_info.command_buffer, self.swapchain, frame_info.current_frame);

        // No transition needed - attachment_optimal supports both rendering and sampling

        // End GPU timing
        if (self.performance_monitor) |pm| {
            try pm.endPass("imgui", frame_info.current_frame, frame_info.command_buffer);
        }

        // Present transition is handled in swapchain.endFrame.
    }

    fn end(base: *Layer, frame_info: *FrameInfo) !void {
        _ = base;
        _ = frame_info;
    }

    fn event(base: *Layer, evt: *Event) void {
        const self: *UILayer = @fieldParentPtr("base", base);

        switch (evt.event_type) {
            .KeyPressed => {
                // Determine whether UI panels should consume keyboard input.
                // We prefer the engine to receive input when the viewport is focused.
                const io = c.ImGui_GetIO();
                var want_kb: bool = false;
                if (io) |i| want_kb = i.*.WantCaptureKeyboard else want_kb = false;
                // Prefer explicit console focus; fall back to ImGui's global capture flag when
                // the viewport is not focused. This avoids a 1-frame delay when focus changes.
                const panels_consumes = self.ui_renderer.console_input_active or (want_kb and !self.ui_renderer.viewport_focused);

                // Use glfw key constants from imgui_c (c.GLFW_KEY_*) for clarity
                if (evt.data.KeyPressed.key == c.GLFW_KEY_F1) {
                    self.show_ui_panels = !self.show_ui_panels;
                    // Always handle the F1 toggle (global UI toggle)
                    evt.markHandled();
                } else if (evt.data.KeyPressed.key == c.GLFW_KEY_GRAVE_ACCENT) {
                    // Toggle scripting console with ` (backtick/tilde) key
                    self.ui_renderer.show_scripting_console = !self.ui_renderer.show_scripting_console;
                    // Always handle console toggle
                    evt.markHandled();
                } else if (evt.data.KeyPressed.key == c.GLFW_KEY_F2) {
                    // Toggle performance graphs
                    self.ui_renderer.show_performance_graphs = !self.ui_renderer.show_performance_graphs;
                    if (panels_consumes) evt.markHandled();
                } else if (evt.data.KeyPressed.key == c.GLFW_KEY_G) {
                    Gizmo.setTool(Gizmo.Tool.Translate);
                    if (panels_consumes) evt.markHandled();
                } else if (evt.data.KeyPressed.key == c.GLFW_KEY_R) {
                    // Check modifiers and ImGui's KeyCtrl as a fallback so Ctrl+R
                    // triggers reverse-search even on platforms where GLFW mods
                    // may be unreliable.
                    const mods = evt.data.KeyPressed.mods;
                    var key_ctrl: bool = false;
                    if (io) |i| key_ctrl = i.*.KeyCtrl else key_ctrl = false;

                    if ((mods & c.GLFW_MOD_CONTROL) != 0 and self.ui_renderer.show_scripting_console) {
                        self.ui_renderer.reverse_search_requested = true;
                        if (panels_consumes) evt.markHandled();
                    } else if (key_ctrl and self.ui_renderer.show_scripting_console) {
                        // Some platforms/input methods may not set the GLFW mods
                        // bitmask reliably; fall back to ImGui's KeyCtrl state.
                        self.ui_renderer.reverse_search_requested = true;
                        if (panels_consumes) evt.markHandled();
                    } else {
                        Gizmo.setTool(Gizmo.Tool.Rotate);
                        if (panels_consumes) evt.markHandled();
                    }
                } else if (evt.data.KeyPressed.key == c.GLFW_KEY_S) {
                    Gizmo.setTool(Gizmo.Tool.Scale);
                    if (panels_consumes) evt.markHandled();
                } else if (evt.data.KeyPressed.key == c.GLFW_KEY_ESCAPE) {
                    Gizmo.cancelDrag();
                    if (panels_consumes) evt.markHandled();
                }

                // Forward key down to ImGui so ImGui_IsKeyPressed and InputText flags work
                if (io) |i| {
                    var maybe_key: ?c.ImGuiKey = null;
                    switch (evt.data.KeyPressed.key) {
                        c.GLFW_KEY_ENTER => maybe_key = c.ImGuiKey_Enter,
                        c.GLFW_KEY_KP_ENTER => maybe_key = c.ImGuiKey_KeypadEnter,
                        c.GLFW_KEY_UP => maybe_key = c.ImGuiKey_UpArrow,
                        c.GLFW_KEY_DOWN => maybe_key = c.ImGuiKey_DownArrow,
                        c.GLFW_KEY_LEFT => maybe_key = c.ImGuiKey_LeftArrow,
                        c.GLFW_KEY_RIGHT => maybe_key = c.ImGuiKey_RightArrow,
                        c.GLFW_KEY_TAB => maybe_key = c.ImGuiKey_Tab,
                        c.GLFW_KEY_BACKSPACE => maybe_key = c.ImGuiKey_Backspace,
                        c.GLFW_KEY_DELETE => maybe_key = c.ImGuiKey_Delete,
                        else => maybe_key = null,
                    }
                    if (maybe_key) |mk| {
                        c.ImGuiIO_AddKeyEvent(i, mk, true);
                    }
                    // If panels (e.g., console) are focused, consume all key presses
                    if (panels_consumes) evt.markHandled();
                }
            },
            .KeyReleased => {
                // Forward key up events to ImGui and consume if panels are focused
                const io = c.ImGui_GetIO();
                var want_kb: bool = false;
                if (io) |i| want_kb = i.*.WantCaptureKeyboard else want_kb = false;
                const panels_consumes = self.ui_renderer.console_input_active or (want_kb and !self.ui_renderer.viewport_focused);
                if (io) |i| {
                    var maybe_key: ?c.ImGuiKey = null;
                    switch (evt.data.KeyReleased.key) {
                        c.GLFW_KEY_ENTER => maybe_key = c.ImGuiKey_Enter,
                        c.GLFW_KEY_KP_ENTER => maybe_key = c.ImGuiKey_KeypadEnter,
                        c.GLFW_KEY_UP => maybe_key = c.ImGuiKey_UpArrow,
                        c.GLFW_KEY_DOWN => maybe_key = c.ImGuiKey_DownArrow,
                        c.GLFW_KEY_LEFT => maybe_key = c.ImGuiKey_LeftArrow,
                        c.GLFW_KEY_RIGHT => maybe_key = c.ImGuiKey_RightArrow,
                        c.GLFW_KEY_TAB => maybe_key = c.ImGuiKey_Tab,
                        c.GLFW_KEY_BACKSPACE => maybe_key = c.ImGuiKey_Backspace,
                        c.GLFW_KEY_DELETE => maybe_key = c.ImGuiKey_Delete,
                        else => maybe_key = null,
                    }
                    if (maybe_key) |mk| {
                        c.ImGuiIO_AddKeyEvent(i, mk, false);
                    }
                    if (panels_consumes) evt.markHandled();
                }
            },
            .KeyTyped => {
                // Forward character input to ImGui
                const io = c.ImGui_GetIO();
                var want_kb: bool = false;
                if (io) |i| want_kb = i.*.WantCaptureKeyboard else want_kb = false;
                const panels_consumes = self.ui_renderer.console_input_active or (want_kb and !self.ui_renderer.viewport_focused);

                // Forward Unicode codepoint to ImGui as UTF-8 characters. Only
                // mark the event handled if UI panels are the active focus so
                // typing in the viewport doesn't block engine input.

                const cp = evt.data.KeyTyped.codepoint;
                var buf: [5]u8 = undefined; // up to 4 bytes + null
                var len: usize = 0;
                if (cp <= 0x7F) {
                    buf[0] = @intCast(cp);
                    len = 1;
                } else if (cp <= 0x7FF) {
                    buf[0] = @intCast(0xC0 | ((cp >> 6) & 0x1F));
                    buf[1] = @intCast(0x80 | (cp & 0x3F));
                    len = 2;
                } else if (cp <= 0xFFFF) {
                    buf[0] = @intCast(0xE0 | ((cp >> 12) & 0x0F));
                    buf[1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
                    buf[2] = @intCast(0x80 | (cp & 0x3F));
                    len = 3;
                } else {
                    buf[0] = @intCast(0xF0 | ((cp >> 18) & 0x07));
                    buf[1] = @intCast(0x80 | ((cp >> 12) & 0x3F));
                    buf[2] = @intCast(0x80 | ((cp >> 6) & 0x3F));
                    buf[3] = @intCast(0x80 | (cp & 0x3F));
                    len = 4;
                }
                buf[len] = 0;

                if (io) |i| {
                    c.ImGuiIO_AddInputCharactersUTF8(i, buf[0..len].ptr);
                    if (panels_consumes) evt.markHandled();
                }
            },

            .MouseButtonPressed, .MouseButtonReleased, .MouseMoved, .MouseScrolled => {
                // When panels (e.g., console) are focused, consume mouse events so the
                // camera/controller doesn't activate mouselook or scroll zoom.
                const io = c.ImGui_GetIO();
                var want_mouse: bool = false;
                if (io) |i| want_mouse = i.*.WantCaptureMouse else want_mouse = false;
                const panels_consumes = want_mouse and !self.ui_renderer.viewport_focused;
                if (panels_consumes) evt.markHandled();
            },
            else => {},
        }
    }
};

/// Internal helpers
fn makeExtent3D(extent2d: vk.Extent2D) vk.Extent3D {
    return .{ .width = extent2d.width, .height = extent2d.height, .depth = 1 };
}

fn findDepthHasStencil(format: vk.Format) bool {
    return switch (format) {
        .d32_sfloat_s8_uint, .d24_unorm_s8_uint => true,
        else => false,
    };
}

/// Computes desired viewport extent from ImGui viewport size (fallback to swapchain).
fn computeDesiredExtent(self: *UILayer) vk.Extent2D {
    // Use viewport size from previous frame (updated during render phase)
    // This creates textures at the actual viewport resolution, avoiding wasteful overrendering
    const vp_w = self.ui_renderer.viewport_size[0];
    const vp_h = self.ui_renderer.viewport_size[1];
    const has_valid_size = (vp_w >= 1.0 and vp_h >= 1.0);

    // Fallback to swapchain extent if viewport hasn't been rendered yet
    var width: u32 = if (has_valid_size) @intFromFloat(@floor(vp_w)) else self.swapchain.extent.width;
    var height: u32 = if (has_valid_size) @intFromFloat(@floor(vp_h)) else self.swapchain.extent.height;

    // Clamp to swapchain extent to avoid creating textures larger than the surface supports
    // This handles the case where viewport size from previous frame exceeds new swapchain extent
    width = @min(width, self.swapchain.extent.width);
    height = @min(height, self.swapchain.extent.height);

    return .{ .width = if (width == 0) 1 else width, .height = if (height == 0) 1 else height };
}

/// Destroys existing LDR viewport textures.
fn destroyOldViewportTextures(self: *UILayer) void {
    inline for (0..MAX_FRAMES_IN_FLIGHT) |i| {
        if (self.viewport_ldr[i]) |*ldr_tex| {
            ldr_tex.deinit();
            self.viewport_ldr[i] = null;
        }
    }
}

/// Recreates HDR textures for all swap images at the given extent.
fn recreateHDRTextures(self: *UILayer, frame_info: *const FrameInfo, extent: vk.Extent2D) !void {
    const extent3d = makeExtent3D(extent);
    const color_barrier = vk.ImageSubresourceRange{
        .aspect_mask = .{ .color_bit = true },
        .base_mip_level = 0,
        .level_count = 1,
        .base_array_layer = 0,
        .layer_count = 1,
    };

    for (self.swapchain.swap_images) |*swap_img| {
        swap_img.hdr_texture.deinit();
        swap_img.hdr_texture = try Texture.init(
            self.swapchain.gc,
            self.swapchain.hdr_format,
            extent3d,
            .{ .color_attachment_bit = true, .sampled_bit = true, .transfer_dst_bit = true },
            .{ .@"1_bit" = true },
        );

        // New texture starts undefined, transition to color_attachment_optimal
        self.swapchain.gc.transitionImageLayout(
            frame_info.command_buffer,
            swap_img.hdr_texture.image,
            .undefined,
            .general, // Unified layout - stays in GENERAL forever
            color_barrier,
        );
    }
}

/// Recreates LDR textures (one per frame in flight) at the given extent.
/// Uses the swapchain's surface format. Transitions to color_attachment_optimal.
/// Returns an array of texture pointers for ImGui registration.
fn recreateLDRTextures(self: *UILayer, frame_info: *const FrameInfo, extent: vk.Extent2D) ![MAX_FRAMES_IN_FLIGHT]*Texture {
    const extent3d = makeExtent3D(extent);
    const color_barrier = vk.ImageSubresourceRange{
        .aspect_mask = .{ .color_bit = true },
        .base_mip_level = 0,
        .level_count = 1,
        .base_array_layer = 0,
        .layer_count = 1,
    };

    var textures_ldr: [MAX_FRAMES_IN_FLIGHT]*Texture = undefined;

    inline for (0..MAX_FRAMES_IN_FLIGHT) |i| {
        const ldr_tex = try Texture.init(
            self.swapchain.gc,
            self.swapchain.surface_format.format,
            extent3d,
            .{ .color_attachment_bit = true, .sampled_bit = true },
            .{ .@"1_bit" = true },
        );

        self.swapchain.gc.transitionImageLayout(
            frame_info.command_buffer,
            ldr_tex.image,
            .undefined,
            .general, // Unified layout - stays in GENERAL forever
            color_barrier,
        );

        self.viewport_ldr[i] = ldr_tex;
        textures_ldr[i] = &self.viewport_ldr[i].?;
    }

    return textures_ldr;
}

/// Updates camera projection for the current viewport aspect ratio.
fn updateCameraAspect(self: *UILayer) void {
    const aspect = @as(f32, @floatFromInt(self.viewport_extent.width)) /
        @as(f32, @floatFromInt(self.viewport_extent.height));
    // Update camera's stored aspect ratio so controller doesn't overwrite with old value
    self.camera.aspectRatio = aspect;
    self.camera.setPerspectiveProjection(zephyr.math.radians(self.camera.fov), aspect, self.camera.nearPlane, self.camera.farPlane);
}

/// Ensures HDR and LDR viewport textures exist and match the current viewport size.
/// Recreates all textures if viewport size has changed.
/// Returns true if textures were recreated, false if already up to date.
fn ensureViewportTargets(self: *UILayer, frame_info: *const FrameInfo) !bool {
    const desired_extent = computeDesiredExtent(self);

    // Early exit if textures already match desired size
    if (self.viewport_extent.width == desired_extent.width and
        self.viewport_extent.height == desired_extent.height and
        self.viewport_ldr[0] != null)
    {
        return false;
    }

    // Clean up old textures
    destroyOldViewportTextures(self);

    // Recreate HDR textures (one per swap image)
    try recreateHDRTextures(self, frame_info, desired_extent);

    // Create new LDR textures (one per frame in flight)
    const ldr_texture_array = try recreateLDRTextures(self, frame_info, desired_extent);

    // Register LDR textures with ImGui
    self.viewport_imgui_id = try self.imgui_context.vulkan_backend.addPerFrameTextures(ldr_texture_array);
    self.viewport_extent = desired_extent;
    self.ui_renderer.viewport_texture_id = self.viewport_imgui_id;

    // Update camera projection for new aspect ratio
    updateCameraAspect(self);

    return true;
}
