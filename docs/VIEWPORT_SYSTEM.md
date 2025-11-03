# Viewport System Documentation

## Overview

The viewport system manages the 3D scene rendering within the editor's UI. It implements a modern HDR rendering pipeline with tone mapping, viewport-relative coordinate systems for mouse picking and gizmos, and dynamic resizing.

**Last Updated**: November 3, 2025

---

## Architecture

### Components

1. **UILayer** (`editor/src/layers/ui_layer.zig`)
   - Manages viewport render targets (HDR and LDR textures)
   - Handles viewport resizing and texture recreation
   - Coordinates with ImGui for UI integration

2. **UIRenderer** (`editor/src/ui/ui_renderer.zig`)
   - Renders the viewport window within ImGui
   - Displays the LDR-tonemapped scene texture
   - Manages viewport position and size

3. **Swapchain** (`engine/src/core/swapchain.zig`)
   - Provides HDR back buffers per swap image
   - Manages per-frame resources

4. **ViewportPicker** (`editor/src/ui/viewport_picker.zig`)
   - Implements CPU-based raycasting for entity selection
   - Uses viewport-relative coordinates

---

## HDR Rendering Pipeline

### Flow

```
Geometry Pass → HDR Buffer → Tonemap Pass → LDR Viewport Texture → ImGui Display → Swapchain
```

### Texture Formats

- **HDR Buffer**: `VK_FORMAT_R16G16B16A16_SFLOAT`
  - Per swap image (one per frame in flight)
  - Size matches viewport dimensions (not swapchain)
  - Usage: `COLOR_ATTACHMENT_BIT | SAMPLED_BIT | TRANSFER_DST_BIT`

- **LDR Viewport Texture**: Swapchain surface format (e.g., `VK_FORMAT_B8G8R8A8_SRGB`)
  - Per frame in flight (typically 2-3 textures)
  - Size matches viewport dimensions
  - Usage: `COLOR_ATTACHMENT_BIT | SAMPLED_BIT`

- **Swapchain Images**: HDR10 format (`VK_FORMAT_A2B10G10R10_UNORM_PACK32`)
  - Usage: `COLOR_ATTACHMENT_BIT | SAMPLED_BIT`
  - Color space: `VK_COLOR_SPACE_HDR10_ST2084_EXT`

### Image Layout Transitions

#### Frame Begin (ui_layer.zig::begin)
```zig
// HDR: color_attachment_optimal (from ensureViewportTargets or previous frame)
// LDR: color_attachment_optimal (recreated or transitioned)
```

#### After Geometry Pass
```zig
// HDR: stays in color_attachment_optimal
```

#### Tonemap Pass
```zig
// HDR: color_attachment_optimal → shader_read_only_optimal (before descriptor bind)
// Renders HDR → LDR
// LDR: color_attachment_optimal → shader_read_only_optimal (after rendering)
```

#### ImGui Rendering
```zig
// LDR: shader_read_only_optimal (sampled by ImGui)
// Swapchain: undefined → color_attachment_optimal
```

#### Frame End
```zig
// Swapchain: color_attachment_optimal → present_src_khr
```

---

## Viewport Coordinate System

### Problem Solved

Previously, all coordinate systems used window-space coordinates, causing issues when the viewport is resized or positioned within the editor UI.

### Solution: Viewport-Relative Coordinates

All viewport operations now use coordinates relative to the viewport's top-left corner `(0, 0)`.

#### Coordinate Conversion

**Window to Viewport:**
```zig
const viewport_x = window_x - viewport_pos[0];
const viewport_y = window_y - viewport_pos[1];
```

**Viewport to Window (for ImGui drawing):**
```zig
const window_x = viewport_x + viewport_pos[0];
const window_y = viewport_y + viewport_pos[1];
```

#### Affected Systems

1. **Mouse Picking** (`ui_layer.zig`, `viewport_picker.zig`)
   - Converts window mouse coordinates to viewport-relative
   - Passes to raycast system

2. **Projection** (`ui_math.zig::project`)
   - Returns viewport-relative coordinates
   - Projects 3D world positions to 2D viewport space

3. **Gizmos** (`gizmo.zig`, `gizmo_process.zig`, `gizmo_draw.zig`)
   - Receives viewport position parameter
   - Converts viewport-relative to window for ImGui drawing

4. **Bounding Boxes** (`ui_renderer.zig::drawEntityAABB`)
   - Projects to viewport-relative coordinates
   - Adds viewport offset before drawing

---

## Viewport Resizing

### Dynamic Texture Recreation

The viewport automatically resizes when the ImGui viewport window changes size.

#### Process (`ensureViewportTargets`)

1. **Check if resize needed**
   - Compare current extent with desired extent
   - Early exit if already correct size

2. **Destroy old resources**
   - Destroy per-frame LDR textures
   - Destroy HDR textures in all swap images

3. **Create new HDR textures**
   - One per swap image (e.g., 2-3 textures)
   - Size matches viewport dimensions
   - Transition: `undefined → color_attachment_optimal`

4. **Create new LDR textures**
   - One per frame in flight
   - Registered with ImGui for per-frame display
   - Transition: `undefined → color_attachment_optimal`

5. **Update camera aspect ratio**
   - Recalculate projection matrix
   - Maintains correct perspective

#### Fallback Behavior

If viewport size is invalid (< 1.0), falls back to swapchain extent.

---

## ImGui Integration

### Viewport Window

Located in `ui_renderer.zig::render()`:

```zig
const viewport_flags = c.ImGuiWindowFlags_NoBackground | 
    c.ImGuiWindowFlags_NoScrollbar | 
    c.ImGuiWindowFlags_NoTitleBar;

c.ImGui_PushStyleVar(c.ImGuiStyleVar_WindowBorderSize, 0.0);
c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_WindowPadding, .{ .x = 0, .y = 0 });

_ = c.ImGui_Begin("Viewport", null, viewport_flags);
// ... render viewport image ...
c.ImGui_End();

c.ImGui_PopStyleVar();
c.ImGui_PopStyleVar();
```

**Features:**
- No background (transparent overlay)
- No scrollbar
- No title bar
- No border
- No padding (content fills entire window)

### Texture Display

```zig
if (self.viewport_texture_id) |tid| {
    if (self.viewport_size[0] >= 1.0 and self.viewport_size[1] >= 1.0) {
        const tex_ref = c.ImTextureRef{ ._TexData = null, ._TexID = tid };
        const size = c.ImVec2{ .x = self.viewport_size[0], .y = self.viewport_size[1] };
        c.ImGui_Image(tex_ref, size);
    }
}
```

### Position & Size Tracking

Content region (excludes title bar) is used for accurate mouse picking:

```zig
const win_pos = c.ImGui_GetWindowPos();
const content_region_min = c.ImGui_GetWindowContentRegionMin();
const content_region_max = c.ImGui_GetWindowContentRegionMax();

self.viewport_pos = .{ 
    win_pos.x + content_region_min.x, 
    win_pos.y + content_region_min.y 
};
self.viewport_size = .{ 
    content_region_max.x - content_region_min.x, 
    content_region_max.y - content_region_min.y 
};
```

---

## Overlays

### Gizmos

Transform gizmos (translate, rotate, scale) are rendered as ImGui overlays on the viewport.

**Files:**
- `gizmo.zig` - Main gizmo interface
- `gizmo_process.zig` - Interaction logic (drag, hover)
- `gizmo_draw.zig` - Rendering (arrows, rings, cubes)

**Coordinate Handling:**
```zig
// Mouse input converted to viewport-relative
const mouse_x = window_mouse_x - viewport_pos[0];
const mouse_y = window_mouse_y - viewport_pos[1];

// Projection returns viewport-relative
const center_vp = UIMath.project(camera, viewport_size, world_pos);

// Convert to window for ImGui drawing
const center = .{ center_vp[0] + viewport_pos[0], center_vp[1] + viewport_pos[1] };
```

### Bounding Boxes

Selection bounding boxes are rendered using `ImDrawList`:

```zig
if (UIMath.project(camera, self.viewport_size, corners[i])) |viewport_pos| {
    // Convert viewport-relative to window coordinates for ImGui
    projected[i] = .{ 
        viewport_pos[0] + self.viewport_pos[0], 
        viewport_pos[1] + self.viewport_pos[1] 
    };
}
```

**Clipping:**
Overlays are clipped to viewport bounds to prevent spilling into other panels:

```zig
const clip_min = c.ImVec2{ .x = self.viewport_pos[0], .y = self.viewport_pos[1] };
const clip_max = c.ImVec2{ 
    .x = self.viewport_pos[0] + self.viewport_size[0], 
    .y = self.viewport_pos[1] + self.viewport_size[1] 
};
c.ImDrawList_PushClipRect(draw_list, clip_min, clip_max, true);
// ... draw overlays ...
c.ImDrawList_PopClipRect(draw_list);
```

---

## UI Panel Visibility

### F1 Toggle

Pressing F1 hides all UI panels but keeps the viewport visible.

**Implementation:**
```zig
// UILayer
show_ui: bool = true,           // Hide everything when false
show_ui_panels: bool = true,    // Hide panels when false (F1 toggle)

// F1 handler
if (evt.data.KeyPressed.key == c.GLFW_KEY_F1) {
    self.show_ui_panels = !self.show_ui_panels;
}
```

**Conditional Rendering:**
```zig
// Viewport always rendered (when show_ui is true)
self.ui_renderer.render();

// Panels only rendered when show_ui_panels is true
if (self.show_ui_panels) {
    self.ui_renderer.renderPanels(stats);
    self.ui_renderer.renderHierarchy(self.scene);
}
```

---

## Best Practices

### 1. Always Use Viewport-Relative Coordinates

When working with viewport positions:
- Convert window coordinates to viewport-relative for logic
- Convert viewport-relative to window for ImGui drawing

### 2. Handle Viewport Resize

Always check if textures need recreation when viewport size changes:
```zig
const recreated = try ensureViewportTargets(self, frame_info);
```

### 3. Proper Layout Transitions

Follow the documented transition sequence:
- HDR: color_attachment → shader_read_only (before tonemap read)
- LDR: color_attachment → shader_read_only (after tonemap write)

### 4. Camera Aspect Ratio

Update camera projection when viewport resizes:
```zig
const aspect = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));
camera.setPerspectiveProjection(fov, aspect, near, far);
```

### 5. Clipping Overlays

Always clip overlays to viewport bounds to prevent rendering outside viewport area.

---

## Common Issues & Solutions

### Issue: Gizmos/BBoxes Appear in Wrong Position

**Cause**: Using window coordinates instead of viewport-relative coordinates.

**Solution**: Ensure `UIMath.project()` returns viewport-relative coordinates, then add viewport offset before ImGui drawing.

### Issue: Mouse Picking Inaccurate

**Cause**: Not converting window mouse coordinates to viewport-relative.

**Solution**: Subtract viewport position from mouse coordinates before raycasting.

### Issue: Validation Errors on Resize

**Cause**: Image layout mismatch during texture recreation.

**Solution**: Ensure proper transition sequences and check that newly created textures start in correct layout.

### Issue: HDR Texture Wrong Size

**Cause**: HDR textures sized to swapchain instead of viewport.

**Solution**: Destroy and recreate HDR textures when viewport resizes in `ensureViewportTargets()`.

---

## Future Improvements

- [ ] Multi-viewport support
- [ ] Viewport screenshot/capture
- [ ] Viewport render settings panel
- [ ] Custom viewport shading modes (wireframe, normals, etc.)
- [ ] Viewport grid overlay
- [ ] Viewport camera settings (FOV, near/far planes)

---

## Related Documentation

- [Layer System](LAYER_EVENT_SYSTEM.md)
- [Editor Architecture](ENGINE_EDITOR_SEPARATION.md)
- [Render Graph](RENDER_GRAPH_SYSTEM.md)
- [HDR & Path Tracing](PATH_TRACING_INTEGRATION.md)
