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
const KeyboardMovementController = @import("../keyboard_movement_controller.zig").KeyboardMovementController;
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
    camera_controller: *KeyboardMovementController,
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
        camera_controller: *KeyboardMovementController,
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

        // Ensure viewport render targets exist and match current extent
        // Returns true if textures were just recreated (already in color_attachment_optimal)
        _ = try ensureViewportTargets(self, frame_info);

        // Update frame_info to point to the current HDR texture (in case it was recreated)
        const mutable_frame_info: *FrameInfo = @constCast(frame_info);
        const hdr_texture = self.swapchain.currentHdrTexture();
        mutable_frame_info.hdr_texture = hdr_texture;

        // DON'T clear or transition HDR here - let geometry pass handle it
        // HDR will be in color_attachment_optimal (from ensureViewportTargets or previous frame)

        // Set frame_info to use LDR viewport texture as render target
        if (self.viewport_ldr[frame_info.current_frame]) |*ldr_tex| {
            mutable_frame_info.color_image = ldr_tex.image;
            mutable_frame_info.color_image_view = ldr_tex.image_view;
            mutable_frame_info.extent = self.viewport_extent; // Use viewport extent, not swapchain extent

        }

        // Expose ImGui texture ID to UIRenderer so it can draw the viewport
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

        // Begin GPU timing for ImGui rendering
        if (self.performance_monitor) |pm| {
            try pm.beginPass("imgui", frame_info.current_frame, frame_info.command_buffer);
        }

        // Render ImGui to command buffer
        try self.imgui_context.render(frame_info.command_buffer, self.swapchain, frame_info.current_frame);

        self.swapchain.gc.transitionImageLayout(
            frame_info.command_buffer,
            frame_info.color_image,
            .shader_read_only_optimal,
            .color_attachment_optimal,
            .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        );

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
                // Use glfw key constants from imgui_c (c.GLFW_KEY_*) for clarity
                if (evt.data.KeyPressed.key == c.GLFW_KEY_F1) {
                    self.show_ui_panels = !self.show_ui_panels;
                    evt.markHandled();
                } else if (evt.data.KeyPressed.key == c.GLFW_KEY_F2) {
                    // Toggle performance graphs
                    self.ui_renderer.show_performance_graphs = !self.ui_renderer.show_performance_graphs;
                    evt.markHandled();
                } else if (evt.data.KeyPressed.key == c.GLFW_KEY_G) {
                    Gizmo.setTool(Gizmo.Tool.Translate);
                    evt.markHandled();
                } else if (evt.data.KeyPressed.key == c.GLFW_KEY_R) {
                    Gizmo.setTool(Gizmo.Tool.Rotate);
                    evt.markHandled();
                } else if (evt.data.KeyPressed.key == c.GLFW_KEY_S) {
                    Gizmo.setTool(Gizmo.Tool.Scale);
                    evt.markHandled();
                } else if (evt.data.KeyPressed.key == c.GLFW_KEY_ESCAPE) {
                    Gizmo.cancelDrag();
                    evt.markHandled();
                }
            },
            .KeyTyped => {
                // Forward Unicode codepoint to ImGui as UTF-8 characters
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
                const io = c.ImGui_GetIO();
                if (io) |i| {
                    c.ImGuiIO_AddInputCharactersUTF8(i, buf[0..len].ptr);
                    evt.markHandled();
                }
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

fn ensureViewportTargets(self: *UILayer, frame_info: *const FrameInfo) !bool {
    // Returns true if textures were recreated, false if already up to date
    // Compute desired extent from ImGui viewport size with guards and fallback to swapchain
    const vp_w_f = self.ui_renderer.viewport_size[0];
    const vp_h_f = self.ui_renderer.viewport_size[1];
    const has_valid_vp = (vp_w_f >= 1.0 and vp_h_f >= 1.0);
    const desired_w: u32 = if (has_valid_vp) @intFromFloat(@floor(vp_w_f)) else self.swapchain.extent.width;
    const desired_h: u32 = if (has_valid_vp) @intFromFloat(@floor(vp_h_f)) else self.swapchain.extent.height;
    const desired_extent: vk.Extent2D = .{ .width = if (desired_w == 0) 1 else desired_w, .height = if (desired_h == 0) 1 else desired_h };

    if (self.viewport_extent.width == desired_extent.width and self.viewport_extent.height == desired_extent.height and self.viewport_ldr[0] != null) {
        return false; // Up to date
    }

    // Destroy old LDR textures
    inline for (0..MAX_FRAMES_IN_FLIGHT) |i| {
        if (self.viewport_ldr[i]) |*ldrt| {
            ldrt.deinit();
            self.viewport_ldr[i] = null;
        }
    }

    // Destroy and recreate HDR textures in swapchain at viewport size
    for (self.swapchain.swap_images) |*swap_img| {
        swap_img.hdr_texture.deinit();
        swap_img.hdr_texture = try Texture.init(
            self.swapchain.gc,
            self.swapchain.hdr_format,
            makeExtent3D(desired_extent),
            .{
                .color_attachment_bit = true,
                .sampled_bit = true,
                .transfer_dst_bit = true,
            },
            .{ .@"1_bit" = true },
        );

        // Transition newly created HDR texture from undefined to color_attachment_optimal
        self.swapchain.gc.transitionImageLayout(
            frame_info.command_buffer,
            swap_img.hdr_texture.image,
            .undefined,
            .color_attachment_optimal,
            .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        );
    }

    // Create new per-frame LDR targets
    const gc: *GraphicsContext = self.swapchain.gc;
    const extent3d = makeExtent3D(desired_extent);
    var textures_ldr: [MAX_FRAMES_IN_FLIGHT]*Texture = undefined;
    inline for (0..MAX_FRAMES_IN_FLIGHT) |i| {
        // Create LDR tonemap destination (sampled by ImGui)
        const ldr_tex = try Texture.init(
            gc,
            // Use the swapchain's surface format for the LDR viewport texture
            self.swapchain.surface_format.format,
            extent3d,
            .{ .color_attachment_bit = true, .sampled_bit = true },
            .{ .@"1_bit" = true },
        );

        gc.transitionImageLayout(
            frame_info.command_buffer,
            ldr_tex.image,
            .undefined,
            .color_attachment_optimal,
            .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        );
        self.viewport_ldr[i] = ldr_tex;
        textures_ldr[i] = &self.viewport_ldr[i].?;
    }

    // Register per-frame LDR textures with ImGui backend and get a single texture ID
    self.viewport_imgui_id = try self.imgui_context.vulkan_backend.addPerFrameTextures(textures_ldr);

    // Record extent and publish ID to UI renderer
    self.viewport_extent = desired_extent;
    self.ui_renderer.viewport_texture_id = self.viewport_imgui_id;

    // Update camera aspect
    const aspect: f32 = @as(f32, @floatFromInt(self.viewport_extent.width)) / @as(f32, @floatFromInt(self.viewport_extent.height));
    self.camera.setPerspectiveProjection(zephyr.math.radians(self.camera.fov), aspect, self.camera.nearPlane, self.camera.farPlane);

    return true; // Textures were recreated
}
