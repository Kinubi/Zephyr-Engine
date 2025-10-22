# RenderGraph vs GenericRenderer Architecture

**Date**: 21 October 2025  
**Status**: Design Complete → Implementation Starting

---

## Why Replace GenericRenderer?

### Problems with GenericRenderer

```zig
// GenericRenderer is GLOBAL - one instance processes everything
var forward_renderer: GenericRenderer = undefined;

// All scenes rendered the same way
try forward_renderer.addRenderer("textured", .raster, &textured_renderer, ...);
try forward_renderer.addRenderer("ecs_renderer", .raster, &ecs_renderer, ...);
try forward_renderer.addRenderer("point_light", .lighting, &point_light_renderer, ...);

// No per-scene control - dungeon and forest both get RT shadows (or neither)
try forward_renderer.render(frame_info);
```

**Limitations:**
- ❌ One rendering pipeline for all scenes
- ❌ Can't customize per scene (RT shadows in dungeon, shadow maps in forest)
- ❌ Hard-coded execution order
- ❌ No explicit resource dependencies
- ❌ Difficult to add/remove passes dynamically

---

## RenderGraph Solution

### Per-Scene Rendering Pipeline

```zig
// Each scene owns its own render graph
pub const Scene = struct {
    ecs_world: *World,
    render_graph: RenderGraph,  // Scene-specific pipeline!
};

// Dungeon scene - wants RT shadows, SSAO, bloom
var dungeon = Scene.init(...);
try dungeon.render_graph.addPass(DepthPrepass.create(...));
try dungeon.render_graph.addPass(GeometryPass.create(&dungeon));
try dungeon.render_graph.addPass(ShadowPass.create(&dungeon, .Raytraced));  // RT!
try dungeon.render_graph.addPass(LightingPass.create(&dungeon));
try dungeon.render_graph.addPass(SSAOPass.create(...));
try dungeon.render_graph.addPass(PostProcessPass.create(...));

// Forest scene - wants shadow maps, no SSAO, different post-processing
var forest = Scene.init(...);
try forest.render_graph.addPass(GeometryPass.create(&forest));
try forest.render_graph.addPass(ShadowPass.create(&forest, .ShadowMaps));  // Shadow maps!
try forest.render_graph.addPass(LightingPass.create(&forest));
try forest.render_graph.addPass(PostProcessPass.create(...));

// Execute per-scene
try dungeon.render_graph.execute(frame_info);  // RT shadows
try forest.render_graph.execute(frame_info);   // Shadow maps
```

**Benefits:**
- ✅ Each scene defines its own pipeline
- ✅ Easy to add/remove passes per scene
- ✅ Explicit resource dependencies
- ✅ Automatic pass ordering
- ✅ Industry standard approach

---

## Architecture Comparison

### Old: GenericRenderer (Global)

```
┌─────────────────────────────────────┐
│      GenericRenderer (Global)       │
│  ┌─────────────────────────────┐   │
│  │   TexturedRenderer          │   │
│  │   EcsRenderer               │   │
│  │   PointLightRenderer        │   │
│  │   ParticleRenderer          │   │
│  │   RaytracingRenderer        │   │
│  └─────────────────────────────┘   │
│                                     │
│  Hard-coded execution order:        │
│  1. Raster renderers                │
│  2. Lighting renderers              │
│  3. Compute renderers               │
│  4. Raytracing renderers            │
│  5. Post-process renderers          │
└─────────────────────────────────────┘
         ↓
    All Scenes
  (same pipeline)
```

### New: RenderGraph (Per-Scene)

```
┌──────────────────────────┐     ┌──────────────────────────┐
│   Scene: Dungeon         │     │   Scene: Forest          │
│  ┌────────────────────┐  │     │  ┌────────────────────┐  │
│  │   RenderGraph      │  │     │  │   RenderGraph      │  │
│  │                    │  │     │  │                    │  │
│  │ 1. DepthPrepass    │  │     │  │ 1. GeometryPass    │  │
│  │ 2. GeometryPass    │  │     │  │ 2. ShadowPass      │  │
│  │ 3. ShadowPass (RT) │  │     │  │    (Shadow Maps)   │  │
│  │ 4. LightingPass    │  │     │  │ 3. LightingPass    │  │
│  │ 5. SSAOPass        │  │     │  │ 4. TransparencyPass│  │
│  │ 6. TransparencyPass│  │     │  │ 5. PostProcessPass │  │
│  │ 7. PostProcessPass │  │     │  │                    │  │
│  └────────────────────┘  │     │  └────────────────────┘  │
└──────────────────────────┘     └──────────────────────────┘
         ↓                                ↓
    RT Shadows                       Shadow Maps
      SSAO                              No SSAO
      Bloom                         Different Bloom
```

---

## RenderGraph Design

### Core Concept: Graph of Passes

```zig
pub const RenderGraph = struct {
    allocator: Allocator,
    scene: *Scene,
    
    // Passes in execution order (after compilation)
    passes: std.ArrayList(*RenderPass),
    
    // Resource registry (render targets, depth buffers, etc)
    resources: ResourceRegistry,
    
    /// Add a pass to the graph
    pub fn addPass(self: *RenderGraph, pass: *RenderPass) !void {
        try self.passes.append(self.allocator, pass);
    }
    
    /// Compile: Build execution order, validate dependencies
    pub fn compile(self: *RenderGraph) !void {
        // TODO: Topological sort based on resource dependencies
        // For now: execute in order added
        log(.INFO, "render_graph", "Compiled graph with {} passes", .{self.passes.items.len});
    }
    
    /// Execute all passes
    pub fn execute(self: *RenderGraph, frame_info: FrameInfo) !void {
        for (self.passes.items) |pass| {
            if (!pass.enabled) continue;
            
            log(.TRACE, "render_graph", "Executing pass: {s}", .{pass.name});
            try pass.execute(frame_info);
        }
    }
    
    pub fn deinit(self: *RenderGraph) void {
        for (self.passes.items) |pass| {
            pass.vtable.teardown(pass);
        }
        self.passes.deinit(self.allocator);
        self.resources.deinit();
    }
};
```

### RenderPass Interface

```zig
pub const RenderPass = struct {
    name: []const u8,
    enabled: bool = true,
    
    // Virtual method table
    vtable: *const VTable,
    
    pub const VTable = struct {
        /// Setup resources, declare dependencies
        setup: *const fn(*RenderPass, *RenderGraph) anyerror!void,
        
        /// Execute the pass
        execute: *const fn(*RenderPass, FrameInfo) anyerror!void,
        
        /// Cleanup
        teardown: *const fn(*RenderPass) void,
    };
};
```

---

## Dynamic Rendering (VK_KHR_dynamic_rendering)

### Why Dynamic Rendering?

**Modern Vulkan (1.3+ core)** replaces the legacy `VkRenderPass`/`VkFramebuffer` model with **dynamic rendering**:

**Old Way (VkRenderPass):**
- Create `VkRenderPass` object upfront (defines attachments, subpasses, dependencies)
- Create `VkFramebuffer` objects (binds image views to render pass)
- Must match pipeline's render pass compatibility
- Inflexible: changing attachments requires new objects
- More boilerplate: multiple creation steps

**New Way (vkCmdBeginRendering):**
- No `VkRenderPass` or `VkFramebuffer` objects needed
- Define attachments inline at rendering time
- Pipeline specifies formats but no render pass dependency
- Flexible: change attachments per frame dynamically
- Less boilerplate: one command to start rendering

### Benefits for RenderGraph

✅ **Per-Pass Flexibility**: Each pass specifies its own attachments inline  
✅ **Simpler State Management**: No render pass compatibility checks  
✅ **Dynamic Reconfiguration**: Change rendering without recreating objects  
✅ **Cleaner Code**: Fewer Vulkan objects to track  
✅ **Modern Best Practice**: Industry standard for Vulkan 1.3+  
✅ **Better for Hot-Reload**: Easier to rebuild pipelines without render passes  

### API Comparison

#### Old: VkRenderPass + VkFramebuffer

```zig
// 1. Create VkRenderPass (once)
var render_pass_info = vk.RenderPassCreateInfo{
    .attachmentCount = 2,
    .pAttachments = &attachments,  // color, depth
    .subpassCount = 1,
    .pSubpasses = &subpass,
    .dependencyCount = 1,
    .pDependencies = &dependency,
};
var render_pass: vk.RenderPass = undefined;
try vkd.createRenderPass(device, &render_pass_info, null, &render_pass);

// 2. Create VkFramebuffer (per swapchain image)
var framebuffer_info = vk.FramebufferCreateInfo{
    .renderPass = render_pass,
    .attachmentCount = 2,
    .pAttachments = &image_views,  // color_view, depth_view
    .width = extent.width,
    .height = extent.height,
    .layers = 1,
};
var framebuffer: vk.Framebuffer = undefined;
try vkd.createFramebuffer(device, &framebuffer_info, null, &framebuffer);

// 3. Begin render pass
var begin_info = vk.RenderPassBeginInfo{
    .renderPass = render_pass,
    .framebuffer = framebuffer,
    .renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = extent },
    .clearValueCount = 2,
    .pClearValues = &clear_values,
};
vkd.cmdBeginRenderPass(cmd, &begin_info, .@"inline");

// 4. Draw commands...

// 5. End render pass
vkd.cmdEndRenderPass(cmd);
```

#### New: vkCmdBeginRendering (Dynamic Rendering)

```zig
// 1. Setup color attachment info (inline)
var color_attachment = vk.RenderingAttachmentInfo{
    .imageView = swapchain_image_view,
    .imageLayout = .color_attachment_optimal,
    .loadOp = .clear,
    .storeOp = .store,
    .clearValue = .{ .color = .{ .float32 = .{ 0.0, 0.0, 0.0, 1.0 } } },
};

// 2. Setup depth attachment info (inline)
var depth_attachment = vk.RenderingAttachmentInfo{
    .imageView = depth_image_view,
    .imageLayout = .depth_stencil_attachment_optimal,
    .loadOp = .clear,
    .storeOp = .dont_care,
    .clearValue = .{ .depthStencil = .{ .depth = 1.0, .stencil = 0 } },
};

// 3. Begin rendering (one command)
var rendering_info = vk.RenderingInfo{
    .renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = extent },
    .layerCount = 1,
    .colorAttachmentCount = 1,
    .pColorAttachments = &color_attachment,
    .pDepthAttachment = &depth_attachment,
};
vkd.cmdBeginRendering(cmd, &rendering_info);

// 4. Draw commands...

// 5. End rendering
vkd.cmdEndRendering(cmd);
```

**Key Differences:**
- No separate `VkRenderPass`/`VkFramebuffer` creation
- Attachments specified inline in `VkRenderingInfo`
- Simpler: 3 structs vs 5+ objects
- Flexible: can change attachments per frame

### Pipeline Creation Changes

#### Old: Pipeline Needs Render Pass

```zig
var pipeline_info = vk.GraphicsPipelineCreateInfo{
    // ... vertex input, shaders, etc ...
    .renderPass = render_pass,  // ❌ REQUIRED
    .subpass = 0,
};
try vkd.createGraphicsPipelines(device, cache, 1, &pipeline_info, null, &pipeline);
```

#### New: Pipeline Specifies Formats

```zig
// 1. Define color/depth formats
var rendering_info = vk.PipelineRenderingCreateInfo{
    .colorAttachmentCount = 1,
    .pColorAttachmentFormats = &[_]vk.Format{.r16g16b16a16_sfloat},  // RGBA16F
    .depthAttachmentFormat = .d32_sfloat,
};

// 2. Chain into pipeline creation
var pipeline_info = vk.GraphicsPipelineCreateInfo{
    .pNext = &rendering_info,  // ✅ Specify formats instead of render pass
    // ... vertex input, shaders, etc ...
    .renderPass = .null_handle,  // ❌ NO LONGER NEEDED
    .subpass = 0,
};
try vkd.createGraphicsPipelines(device, cache, 1, &pipeline_info, null, &pipeline);
```

**Key Changes:**
- Pipeline specifies attachment formats via `VkPipelineRenderingCreateInfo`
- No `renderPass` dependency
- Pipelines can be used with any compatible attachments (matching formats)

### RenderGraph Integration

Each **RenderPass** uses dynamic rendering in its `execute()` method:

```zig
fn executeImpl(base: *RenderPass, frame_info: FrameInfo) !void {
    const self = @fieldParentPtr(GeometryPass, "base", base);
    const cmd = frame_info.command_buffer;
    
    // 1. Define attachments inline (from ResourceRegistry)
    var color_target = self.graph.resources.getRenderTarget(self.color_target);
    var depth_buffer = self.graph.resources.getDepthBuffer(self.depth_buffer);
    
    var color_attachment = vk.RenderingAttachmentInfo{
        .imageView = color_target.view,
        .imageLayout = .color_attachment_optimal,
        .loadOp = .clear,
        .storeOp = .store,
        .clearValue = .{ .color = .{ .float32 = .{ 0.01, 0.01, 0.01, 1.0 } } },
    };
    
    var depth_attachment = vk.RenderingAttachmentInfo{
        .imageView = depth_buffer.view,
        .imageLayout = .depth_stencil_attachment_optimal,
        .loadOp = .clear,
        .storeOp = .dont_care,
        .clearValue = .{ .depthStencil = .{ .depth = 1.0, .stencil = 0 } },
    };
    
    // 2. Begin rendering
    var rendering_info = vk.RenderingInfo{
        .renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = frame_info.extent },
        .layerCount = 1,
        .colorAttachmentCount = 1,
        .pColorAttachments = &color_attachment,
        .pDepthAttachment = &depth_attachment,
    };
    vkd.cmdBeginRendering(cmd, &rendering_info);
    
    // 3. Draw all entities
    var render_system = RenderSystem{ .allocator = self.scene.allocator };
    var render_data = try render_system.extractRenderData(self.scene.ecs_world);
    defer render_data.deinit();
    
    for (render_data.renderables.items) |renderable| {
        // ... bind pipeline, descriptors, draw ...
    }
    
    // 4. End rendering
    vkd.cmdEndRendering(cmd);
    
    log(.TRACE, "geometry_pass", "Rendered {} entities", .{render_data.renderables.items.len});
}
```

### Migration Checklist

✅ **Enable Extension** (already done in graphics_context.zig):
```zig
const required_extensions = [_][*:0]const u8{
    vk.extensions.khr_swapchain.name,
    vk.extensions.khr_dynamic_rendering.name,  // ✅ Add this
};
```

✅ **Enable Feature** (already done):
```zig
var dynamic_rendering_feature = vk.PhysicalDeviceDynamicRenderingFeatures{
    .dynamicRendering = vk.TRUE,
};
var device_features = vk.PhysicalDeviceFeatures2{
    .pNext = &dynamic_rendering_feature,
};
```

🔄 **Update Pipeline Creation** (UnifiedPipelineSystem):
- Add `VkPipelineRenderingCreateInfo` to pipeline creation
- Remove render pass dependency
- Specify color/depth formats

🔄 **Update RenderPasses** (GeometryPass, LightingPass, etc.):
- Replace `vkCmdBeginRenderPass` with `vkCmdBeginRendering`
- Define attachments inline (no framebuffer)
- Replace `vkCmdEndRenderPass` with `vkCmdEndRendering`

🔄 **Remove Legacy Objects**:
- Delete `VkRenderPass` creation from swapchain/renderers
- Delete `VkFramebuffer` creation/tracking
- Remove render pass compatibility checks

### Example Pass Implementations

#### GeometryPass (Opaque Objects)

```zig
// Outputs: color + depth
var color_attachment = vk.RenderingAttachmentInfo{
    .imageView = color_target_view,
    .imageLayout = .color_attachment_optimal,
    .loadOp = .clear,  // Clear to background
    .storeOp = .store, // Save for lighting pass
    .clearValue = .{ .color = .{ .float32 = .{ 0.01, 0.01, 0.01, 1.0 } } },
};

var depth_attachment = vk.RenderingAttachmentInfo{
    .imageView = depth_buffer_view,
    .imageLayout = .depth_stencil_attachment_optimal,
    .loadOp = .clear,  // Clear to 1.0
    .storeOp = .store, // Save for depth testing in later passes
    .clearValue = .{ .depthStencil = .{ .depth = 1.0, .stencil = 0 } },
};

vkd.cmdBeginRendering(cmd, &.{
    .renderArea = full_viewport,
    .layerCount = 1,
    .colorAttachmentCount = 1,
    .pColorAttachments = &color_attachment,
    .pDepthAttachment = &depth_attachment,
});
// Draw opaque meshes...
vkd.cmdEndRendering(cmd);
```

#### LightingPass (Point Lights)

```zig
// Inputs: depth buffer (read-only)
// Outputs: color (additive blending)
var color_attachment = vk.RenderingAttachmentInfo{
    .imageView = color_target_view,
    .imageLayout = .color_attachment_optimal,
    .loadOp = .load,   // Keep existing color from GeometryPass
    .storeOp = .store, // Save accumulated lighting
    .clearValue = undefined, // Not used (loadOp = load)
};

var depth_attachment = vk.RenderingAttachmentInfo{
    .imageView = depth_buffer_view,
    .imageLayout = .depth_stencil_read_only_optimal, // Read-only!
    .loadOp = .load,      // Keep existing depth
    .storeOp = .dont_care, // Don't modify depth
    .clearValue = undefined,
};

vkd.cmdBeginRendering(cmd, &.{
    .renderArea = full_viewport,
    .layerCount = 1,
    .colorAttachmentCount = 1,
    .pColorAttachments = &color_attachment,
    .pDepthAttachment = &depth_attachment,
});
// Draw light volumes with additive blending...
vkd.cmdEndRendering(cmd);
```

#### TransparencyPass (Alpha Blended Objects)

```zig
// Inputs: depth buffer (read-only for testing)
// Outputs: color (alpha blending)
var color_attachment = vk.RenderingAttachmentInfo{
    .imageView = color_target_view,
    .imageLayout = .color_attachment_optimal,
    .loadOp = .load,   // Keep existing scene
    .storeOp = .store, // Save blended result
    .clearValue = undefined,
};

var depth_attachment = vk.RenderingAttachmentInfo{
    .imageView = depth_buffer_view,
    .imageLayout = .depth_stencil_read_only_optimal, // Test but don't write
    .loadOp = .load,
    .storeOp = .dont_care,
    .clearValue = undefined,
};

vkd.cmdBeginRendering(cmd, &.{
    .renderArea = full_viewport,
    .layerCount = 1,
    .colorAttachmentCount = 1,
    .pColorAttachments = &color_attachment,
    .pDepthAttachment = &depth_attachment,
});
// Draw transparent meshes back-to-front...
vkd.cmdEndRendering(cmd);
```

---

### Example: GeometryPass

```zig
pub const GeometryPass = struct {
    base: RenderPass,
    scene: *Scene,
    pipeline_system: *UnifiedPipelineSystem,
    
    // Resources this pass uses
    color_target: ResourceId,
    depth_buffer: ResourceId,
    
    pub fn create(allocator: Allocator, scene: *Scene, pipeline: *UnifiedPipelineSystem) !*GeometryPass {
        const pass = try allocator.create(GeometryPass);
        pass.* = GeometryPass{
            .base = RenderPass{
                .name = "GeometryPass",
                .enabled = true,
                .vtable = &vtable,
            },
            .scene = scene,
            .pipeline_system = pipeline,
            .color_target = undefined,  // Set during setup
            .depth_buffer = undefined,
        };
        return pass;
    }
    
    const vtable = RenderPass.VTable{
        .setup = setupImpl,
        .execute = executeImpl,
        .teardown = teardownImpl,
    };
    
    fn setupImpl(base: *RenderPass, graph: *RenderGraph) !void {
        const self = @fieldParentPtr(GeometryPass, "base", base);
        
        // Register resources we need
        self.color_target = try graph.resources.createRenderTarget("color", .RGBA16F);
        self.depth_buffer = try graph.resources.getOrCreateDepthBuffer("depth");
        
        log(.INFO, "geometry_pass", "Setup complete", .{});
    }
    
    fn executeImpl(base: *RenderPass, frame_info: FrameInfo) !void {
        const self = @fieldParentPtr(GeometryPass, "base", base);
        
        // Extract renderables from ECS
        var render_system = RenderSystem{ .allocator = self.scene.allocator };
        var render_data = try render_system.extractRenderData(self.scene.ecs_world);
        defer render_data.deinit();
        
        if (render_data.renderables.items.len == 0) return;
        
        // Render each entity (similar to EcsRenderer)
        for (render_data.renderables.items) |renderable| {
            // ... draw logic using pipeline_system ...
        }
        
        log(.TRACE, "geometry_pass", "Rendered {} entities", .{render_data.renderables.items.len});
    }
    
    fn teardownImpl(base: *RenderPass) void {
        const self = @fieldParentPtr(GeometryPass, "base", base);
        self.scene.allocator.destroy(self);
    }
};
```

---

## Migration Path

### Step 1: Keep Both (Parallel Development)

```zig
// app.zig - During transition
var forward_renderer: GenericRenderer = undefined;  // Old
var render_graph: ?RenderGraph = null;              // New

// Use flag to switch
const use_render_graph = true;

if (use_render_graph) {
    try render_graph.?.execute(frame_info);
} else {
    try forward_renderer.render(frame_info);
}
```

### Step 2: Implement Basic RenderGraph

- Create `render_graph.zig`
- Create `GeometryPass` (replaces EcsRenderer)
- Create `LightingPass` (replaces PointLightRenderer)
- Test that objects render correctly

### Step 3: Remove GenericRenderer

- Delete `generic_renderer.zig`
- Delete individual renderers (TexturedRenderer, EcsRenderer, etc.)
- Keep particle renderer (moves to compute pass)
- Keep raytracing renderer (moves to RT pass)

### Step 4: Add Advanced Passes

- DepthPrepass
- ShadowPass (multiple techniques)
- SSAOPass
- TransparencyPass
- PostProcessPass

---

## Benefits Summary

### For Scene System
- ✅ Each scene defines its own rendering pipeline
- ✅ Easy to switch techniques (RT vs shadow maps)
- ✅ Can test different pipelines without code changes

### For Performance
- ✅ Only execute needed passes
- ✅ Explicit resource dependencies (better GPU sync)
- ✅ Easier to optimize (profiling per-pass)

### For Development
- ✅ Industry standard (familiar to game devs)
- ✅ Modular (easy to add new passes)
- ✅ Testable (test individual passes)
- ✅ Debuggable (visualize graph execution)

### For Features
- ✅ Per-scene quality settings
- ✅ Dynamic pipeline reconfiguration
- ✅ Editor integration (visual graph editor)
- ✅ Hot-reload of individual passes

---

## Implementation Timeline

**This Session:**
1. Create basic RenderGraph infrastructure
2. Create GeometryPass (replaces EcsRenderer logic)
3. Create LightingPass (replaces PointLightRenderer logic)
4. Update app.zig to use RenderGraph
5. Remove GenericRenderer usage
6. Verify rendering works

**Next Session:**
1. Add DepthPrepass
2. Add ShadowPass with RT + shadow maps
3. Add TransparencyPass
4. Add PostProcessPass
5. Resource management system

**Future:**
1. Automatic pass ordering (topological sort)
2. RenderGraph serialization (save/load pipelines)
3. Visual graph editor in ImGui
4. Performance profiling per-pass

---

## Technical Notes

### Resource Management

Resources (render targets, depth buffers) are tracked by the graph:

```zig
pub const ResourceRegistry = struct {
    render_targets: std.StringHashMap(RenderTarget),
    depth_buffers: std.StringHashMap(DepthBuffer),
    
    pub fn createRenderTarget(self: *ResourceRegistry, name: []const u8, format: vk.Format) !ResourceId;
    pub fn getOrCreateDepthBuffer(self: *ResourceRegistry, name: []const u8) !ResourceId;
    pub fn getResource(self: *ResourceRegistry, id: ResourceId) Resource;
};
```

### Pass Dependencies

Future enhancement - passes declare dependencies:

```zig
// LightingPass depends on GeometryPass color output
const lighting_pass = try LightingPass.create(...);
lighting_pass.addInputDependency(geometry_pass.color_target);

// Graph automatically orders passes based on dependencies
try render_graph.compile();  // Topological sort
```

### Multi-Scene Rendering

Can execute multiple scene graphs per frame:

```zig
// Main world
try main_world_scene.render_graph.execute(frame_info);

// Picture-in-picture minimap
try minimap_scene.render_graph.execute(minimap_frame_info);

// UI overlay
try ui_scene.render_graph.execute(ui_frame_info);
```

---

**This design gives us the flexibility to have completely different rendering pipelines per scene while maintaining clean, modular code!** 🚀
