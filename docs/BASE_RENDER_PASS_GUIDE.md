# BaseRenderPass — Zero Boilerplate Render Pass API

**Status**: ✅ **IMPLEMENTED** (Phase 4 Complete)  
**File**: `engine/src/rendering/passes/base_render_pass.zig`

## Overview

BaseRenderPass provides a builder pattern for creating render passes with minimal boilerplate. It handles:
- Pipeline creation and shader compilation
- Automatic shader reflection for binding discovery
- Named resource binding (no magic numbers!)
- Automatic resource rebinding when handles change
- Flexible render data extraction from RenderSystem

## Key Features

### 1. Render Data Extraction

Each pass can register a custom function to extract exactly what it needs from RenderSystem:

```zig
pub const RenderDataFn = fn (render_system: *RenderSystem, context: ?*anyopaque) RenderData;

pub const RenderData = struct {
    batches: ?[]const anyopaque = null,    // Instanced batches
    objects: ?[]const anyopaque = null,    // Individual objects  
    particles: ?[]const anyopaque = null,  // Particle systems
    lights: ?[]const anyopaque = null,     // Light data
    custom: ?*anyopaque = null,            // Pass-specific data
};
```

### 2. Automatic Rebinding

ResourceBinder automatically detects when buffer/texture handles change and rebinds descriptors. No manual dirty tracking needed!

### 3. Named Resource Binding

Use descriptive names instead of magic numbers:
```zig
try pass.bind("GlobalUBO", &global_ubo);
try pass.bind("MaterialBuffer", material_system);
try pass.bind("Textures", texture_array);
```

## Usage Examples

### Example 1: Opaque Geometry Pass

```zig
// Render data extractor: Get opaque instanced batches
fn getOpaqueGeometry(render_system: *RenderSystem, ctx: ?*anyopaque) BaseRenderPass.RenderData {
    _ = ctx;
    const batches = render_system.getOpaqueBatches();
    return .{ .batches = batches };
}

// Create and configure pass
const geometry_pass = try BaseRenderPass.create(
    allocator,
    "geometry_pass",
    graphics_context,
    pipeline_system,
    resource_binder,
    render_system,
    .{
        .color_formats = &[_]vk.Format{.r16g16b16a16_sfloat},
        .depth_format = .d32_sfloat,
        .cull_mode = .{ .back_bit = true },
        .depth_test = true,
        .depth_write = true,
        .blend_enable = false,
    },
);
defer geometry_pass.destroy();

// Register shaders
try geometry_pass.registerShader("assets/shaders/cached/simple.vert.spv");
try geometry_pass.registerShader("assets/shaders/cached/simple.frag.spv");

// Bind resources (uses named binding)
try geometry_pass.bind("GlobalUBO", &global_ubo);
try geometry_pass.bind("MaterialBuffer", material_system);
try geometry_pass.bind("Textures", texture_array);

// Register render data extractor
try geometry_pass.setRenderDataFn(getOpaqueGeometry, null);

// Bake pipeline and bind resources
try geometry_pass.bake();

// Done! RenderGraph calls execute() automatically
```

### Example 2: Transparent Pass with Context

```zig
// Context for render data extraction
const TransparentContext = struct {
    sort_by_depth: bool = true,
    max_layers: u32 = 16,
};

fn getTransparentGeometry(
    render_system: *RenderSystem,
    ctx: ?*anyopaque,
) BaseRenderPass.RenderData {
    const context: *TransparentContext = @ptrCast(@alignCast(ctx.?));
    
    var batches = render_system.getTransparentBatches();
    
    if (context.sort_by_depth) {
        // Sort back-to-front for correct alpha blending
        std.sort.block(anyopaque, batches, {}, compareDepth);
    }
    
    return .{ .batches = batches[0..@min(batches.len, context.max_layers)] };
}

var ctx = TransparentContext{ .sort_by_depth = true };

const transparent_pass = try BaseRenderPass.create(...);
try transparent_pass.registerShader("transparent.vert");
try transparent_pass.registerShader("transparent.frag");
try transparent_pass.bind("GlobalUBO", &global_ubo);
try transparent_pass.setRenderDataFn(getTransparentGeometry, &ctx);
try transparent_pass.bake();
```

### Example 3: Particle System Pass

```zig
fn getParticleData(render_system: *RenderSystem, ctx: ?*anyopaque) BaseRenderPass.RenderData {
    _ = ctx;
    const particles = render_system.getActiveParticleSystems();
    return .{ .particles = particles };
}

const particle_pass = try BaseRenderPass.create(
    allocator,
    "particle_pass",
    graphics_context,
    pipeline_system,
    resource_binder,
    render_system,
    .{
        .color_formats = &[_]vk.Format{.r16g16b16a16_sfloat},
        .depth_format = .d32_sfloat,
        .cull_mode = .{ .none = true }, // No culling for particles
        .depth_test = true,
        .depth_write = false, // Read depth but don't write
        .blend_enable = true,
        .blend_mode = .additive, // Additive blending for particles
    },
);

try particle_pass.registerShader("particles.vert");
try particle_pass.registerShader("particles.frag");
try particle_pass.bind("GlobalUBO", &global_ubo);
try particle_pass.bind("ParticleBuffer", particle_system);
try particle_pass.setRenderDataFn(getParticleData, null);
try particle_pass.bake();
```

### Example 4: Shadow Map Pass (Per-Light)

```zig
// Context: Which light to render shadows for
const ShadowContext = struct {
    light_index: u32,
};

fn getShadowCasters(render_system: *RenderSystem, ctx: ?*anyopaque) BaseRenderPass.RenderData {
    const context: *ShadowContext = @ptrCast(@alignCast(ctx.?));
    
    // Get objects visible from this light's perspective
    const batches = render_system.getBatchesVisibleFromLight(context.light_index);
    
    return .{ .batches = batches };
}

var shadow_ctx = ShadowContext{ .light_index = 0 };

const shadow_pass = try BaseRenderPass.create(
    allocator,
    "shadow_map_pass",
    graphics_context,
    pipeline_system,
    resource_binder,
    render_system,
    .{
        .color_formats = &[_]vk.Format{}, // No color attachment
        .depth_format = .d32_sfloat,
        .cull_mode = .{ .front_bit = true }, // Front-face culling for shadow acne reduction
        .depth_test = true,
        .depth_write = true,
        .blend_enable = false,
    },
);

try shadow_pass.registerShader("shadow.vert");
try shadow_pass.registerShader("shadow.frag");
try shadow_pass.bind("LightUBO", &light_ubo);
try shadow_pass.setRenderDataFn(getShadowCasters, &shadow_ctx);
try shadow_pass.bake();

// Update light index each frame for multiple shadow maps
shadow_ctx.light_index = 1; // Second light
```

### Example 5: Post-Process Pass (No Render Data)

```zig
// Post-process passes don't need render data - they just draw a fullscreen quad
const tonemap_pass = try BaseRenderPass.create(
    allocator,
    "tonemap_pass",
    graphics_context,
    pipeline_system,
    resource_binder,
    render_system,
    .{
        .color_formats = &[_]vk.Format{.b8g8r8a8_srgb},
        .depth_format = null, // No depth testing
        .cull_mode = .{ .none = true },
        .depth_test = false,
        .depth_write = false,
        .blend_enable = false,
    },
);

try tonemap_pass.registerShader("tonemap.vert");
try tonemap_pass.registerShader("tonemap.frag");
try tonemap_pass.bind("HDRTexture", &hdr_texture);
try tonemap_pass.bind("TonemapParams", &tonemap_params);
// No render data extractor needed
try tonemap_pass.bake();
```

## Architecture

### Builder Pattern Flow

```
Create → Register Shaders → Bind Resources → Set RenderDataFn → Bake → Execute
  ↓           ↓                    ↓                 ↓             ↓        ↓
alloc      queue            queue             set fn        compile    render
            paths           bindings                         pipeline
```

### Bake Process

When you call `bake()`:

1. **Create Pipeline**: Compiles shaders and creates Vulkan pipeline
2. **Shader Reflection**: Extracts binding names from SPIR-V automatically
3. **Bind Resources**: Binds all registered resources using named binding
4. **Finalize**: Pass is ready to execute

### Execute Flow

Each frame when RenderGraph calls `execute()`:

1. **Update Resources**: `updateFrame()` checks if any buffer/texture handles changed
2. **Auto-Rebind**: If handles changed, automatically rebind descriptors
3. **Extract Render Data**: Call registered `RenderDataFn` to get data from RenderSystem
4. **Bind Pipeline**: Bind pipeline with descriptor sets
5. **Render**: Draw using extracted render data

## Benefits

### Zero Boilerplate

Before (Custom RenderPass):
```zig
// 200+ lines of setup, update, execute, teardown
// Manual pipeline creation
// Manual shader loading
// Manual descriptor binding
// Manual dirty tracking
// Manual resource cleanup
```

After (BaseRenderPass):
```zig
// 10-20 lines total
const pass = try BaseRenderPass.create(...);
try pass.registerShader("my.vert");
try pass.registerShader("my.frag");
try pass.bind("GlobalUBO", &ubo);
try pass.setRenderDataFn(myDataExtractor, null);
try pass.bake();
// Done!
```

### Automatic Resource Management

- **No Manual Dirty Tracking**: ResourceBinder detects buffer handle changes automatically
- **No Manual Rebinding**: Descriptors rebind only when handles actually change
- **No Memory Leaks**: BufferManager handles cleanup with ring-buffer safety
- **No Validation Errors**: Named binding prevents set/binding mismatches

### Flexible Data Extraction

- **Per-Pass Logic**: Each pass gets exactly the data it needs
- **Context Support**: Pass custom context to extractor functions
- **Type-Safe**: Strongly typed render data structure
- **No Coupling**: RenderSystem doesn't need to know about individual passes

## Integration with Existing Systems

### MaterialSystem Integration

```zig
// MaterialSystem provides buffer, BaseRenderPass binds it
try pass.bind("MaterialBuffer", material_system);

// ResourceBinder automatically rebinds if MaterialSystem recreates buffer
// (e.g., after hot-reload)
```

### TextureSystem Integration

```zig
// TextureSystem provides descriptor array
const texture_array = texture_system.getDescriptorArray();
try pass.bind("Textures", texture_array);

// Automatically rebinds if descriptor array changes
```

### RenderSystem Integration

```zig
// Each pass extracts its own data
fn getOpaqueGeometry(rs: *RenderSystem, ctx: ?*anyopaque) RenderData {
    return .{ .batches = rs.getOpaqueBatches() };
}

fn getTransparentGeometry(rs: *RenderSystem, ctx: ?*anyopaque) RenderData {
    return .{ .batches = rs.getTransparentBatches() };
}

fn getParticles(rs: *RenderSystem, ctx: ?*anyopaque) RenderData {
    return .{ .particles = rs.getActiveParticleSystems() };
}
```

## When to Use BaseRenderPass

**Use BaseRenderPass when:**
- ✅ Creating simple render passes with standard rendering
- ✅ You need automatic resource management
- ✅ You want named binding without boilerplate
- ✅ Your pass fits the standard pipeline model

**Use Custom RenderPass when:**
- ❌ You need complex multi-pass rendering (e.g., deferred shading)
- ❌ You need dynamic pipeline switching
- ❌ You need custom descriptor update logic
- ❌ Your pass has unusual requirements (compute, ray tracing, etc.)

## Future Enhancements

### Planned Features

1. **Draw Callback System**: Allow custom drawing logic without subclassing
   ```zig
   try pass.setDrawFn(myCustomDrawLogic);
   ```

2. **Multi-Pass Support**: Chain multiple sub-passes
   ```zig
   try pass.addSubPass("depth_prepass");
   try pass.addSubPass("geometry_pass");
   ```

3. **Compute Pass Support**: Extend to compute shaders
   ```zig
   const compute_pass = try BaseComputePass.create(...);
   ```

4. **Ray Tracing Support**: Add RT pipeline creation
   ```zig
   const rt_pass = try BaseRayTracingPass.create(...);
   ```

## Performance Considerations

### Automatic Rebinding Overhead

- **Minimal**: Only checks buffer handles (pointer comparison)
- **Conditional**: Only writes descriptors if handles actually changed
- **Amortized**: Cost spread across all passes using ResourceBinder

### Render Data Extraction

- **Per-Frame**: Extractor called once per frame per pass
- **Lightweight**: Just returns pointers to existing data
- **No Allocation**: Data owned by RenderSystem, not copied

### Pipeline Creation

- **One-Time**: Happens during `bake()`, not per-frame
- **Cached**: UnifiedPipelineSystem caches compiled pipelines
- **Fast Reload**: Hot-reload recompiles only changed shaders

## Testing

Example test demonstrating the API:

```zig
test "BaseRenderPass: basic usage" {
    const allocator = std.testing.allocator;
    
    // Mock systems
    var gc = try MockGraphicsContext.init(allocator);
    defer gc.deinit();
    var pipeline_sys = try UnifiedPipelineSystem.init(allocator, &gc);
    defer pipeline_sys.deinit();
    var resource_binder = try ResourceBinder.init(allocator);
    defer resource_binder.deinit();
    var render_system = try RenderSystem.init(allocator);
    defer render_system.deinit();
    
    // Create pass
    const pass = try BaseRenderPass.create(
        allocator,
        "test_pass",
        &gc,
        &pipeline_sys,
        &resource_binder,
        &render_system,
        .{
            .color_formats = &[_]vk.Format{.r8g8b8a8_unorm},
            .depth_format = null,
        },
    );
    defer pass.destroy();
    
    // Configure
    try pass.registerShader("test.vert");
    try pass.registerShader("test.frag");
    
    var mock_buffer = MockBuffer{};
    try pass.bind("TestBuffer", &mock_buffer);
    
    fn testExtractor(rs: *RenderSystem, ctx: ?*anyopaque) BaseRenderPass.RenderData {
        _ = rs;
        _ = ctx;
        return .{};
    }
    try pass.setRenderDataFn(testExtractor, null);
    
    // Bake
    try pass.bake();
    
    // Execute
    const frame_info = FrameInfo{ /* ... */ };
    try pass.base.execute(frame_info);
    
    // Success!
}
```

## See Also

- [BUFFER_MANAGER_SYSTEM.md](BUFFER_MANAGER_SYSTEM.md) - Buffer lifecycle management
- [RENDER_PASS_VISION.md](RENDER_PASS_VISION.md) - Original vision document
- [RESOURCE_BINDER.md](RESOURCE_BINDER.md) - Named binding system
- [RENDER_GRAPH_SYSTEM.md](RENDER_GRAPH_SYSTEM.md) - Pass orchestration
