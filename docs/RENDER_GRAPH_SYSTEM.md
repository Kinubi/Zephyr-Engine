# RenderGraph System

**Last Updated**: October 24, 2025  
**Status**: ✅ Complete

## Overview

The RenderGraph system provides a flexible, data-driven framework for managing render passes and their dependencies. It coordinates multiple rendering techniques (rasterization, ray tracing, compute shaders) through a unified execution model.

## Architecture

```
┌──────────────────────────────────────────────────┐
│             RenderGraph                          │
│  (Central coordinator for all render passes)    │
└──────────────────────────────────────────────────┘
                      │
        ┌─────────────┼─────────────────┐
        ▼             ▼                 ▼
┌──────────────┐ ┌──────────────┐ ┌──────────────┐
│  Resource    │ │  Pass        │ │  Execution   │
│  Registry    │ │  Management  │ │  Order       │
│              │ │              │ │              │
│ • Images     │ │ • Setup      │ │ • Compile    │
│ • Buffers    │ │ • Execute    │ │ • Enable     │
│ • Formats    │ │ • Teardown   │ │ • Disable    │
└──────────────┘ └──────────────┘ └──────────────┘
```

## Core Components

### RenderGraph

Central coordinator that manages:
- **Pass Registration**: Add and organize render passes
- **Resource Management**: Track render targets, depth buffers
- **Execution Order**: Compile and execute passes in dependency order
- **Dynamic Control**: Enable/disable passes at runtime

```zig
pub const RenderGraph = struct {
    allocator: Allocator,
    graphics_context: *GraphicsContext,
    passes: std.ArrayList(*RenderPass),
    resources: ResourceRegistry,
    compiled: bool = false,
};
```

### RenderPass

Base interface for all render passes using vtable pattern:

```zig
pub const RenderPass = struct {
    name: []const u8,
    enabled: bool = true,
    vtable: *const RenderPassVTable,
    
    pub fn setup(self: *RenderPass, graph: *RenderGraph) !void;
    pub fn update(self: *RenderPass, delta_time: f32) !void;
    pub fn execute(self: *RenderPass, frame_info: FrameInfo) !void;
    pub fn teardown(self: *RenderPass) void;
};

pub const RenderPassVTable = struct {
    setup: *const fn (pass: *RenderPass, graph: *RenderGraph) anyerror!void,
    update: *const fn (pass: *RenderPass, delta_time: f32) anyerror!void,
    execute: *const fn (pass: *RenderPass, frame_info: FrameInfo) anyerror!void,
    teardown: *const fn (pass: *RenderPass) void,
};
```

**VTable Functions**:
- `setup()` - Register resources and declare dependencies (called once during compile)
- `update()` - Update pass state each frame (e.g., BVH rebuilds, descriptor updates)
- `execute()` - Record commands to command buffer
- `teardown()` - Cleanup resources on shutdown

### ResourceRegistry

Manages render graph resources (images, buffers, etc.):

```zig
pub const ResourceRegistry = struct {
    resources: std.ArrayList(Resource),
    name_to_id: std.StringHashMap(ResourceId),
    
    pub fn registerResource(name: []const u8, type: ResourceType, format: vk.Format) !ResourceId;
    pub fn getResource(id: ResourceId) ?*Resource;
    pub fn getResourceByName(name: []const u8) ?*Resource;
    pub fn updateResourceImage(id: ResourceId, image: vk.Image, ...) !void;
};

pub const Resource = struct {
    id: ResourceId,
    type: ResourceType,  // render_target, depth_buffer
    name: []const u8,
    format: vk.Format,
    image: vk.Image,
    view: vk.ImageView,
    memory: vk.DeviceMemory,
    width: u32,
    height: u32,
};
```

## DAG Compilation

The RenderGraph automatically builds a Directed Acyclic Graph (DAG) from pass dependencies and determines optimal execution order.

### Dependency Declaration

Passes declare dependencies during `setup()`:

```zig
// In pass setup()
fn setup(base: *RenderPass, graph: *RenderGraph) !void {
    const self = @fieldParentPtr(MyPass, "base", base);
    
    // Declare resource dependencies
    // This pass READS from color_buffer (written by previous pass)
    try graph.declareDependency(self.base.name, "GeometryPass", "color_buffer");
    
    // This pass WRITES to output_texture
    try graph.declareOutput(self.base.name, "output_texture");
}
```

### Compilation Process

```
1. Add Passes
   └─> Passes added in arbitrary order

2. compile()
   ├─> Call setup() on all passes
   │   └─> Passes declare resource dependencies
   │
   ├─> Build dependency graph
   │   ├─> Node per pass
   │   └─> Edge = data dependency
   │
   ├─> Topological sort
   │   └─> Determines execution order
   │
   ├─> Validate DAG
   │   ├─> Check for cycles
   │   ├─> Check for missing dependencies
   │   └─> Verify resource compatibility
   │
   └─> Set compiled = true
```

### Current Implementation Status

**Current**: Simple sequential execution (order passes are added)
```zig
// Execute passes in order added
for (self.passes.items) |pass| {
    if (pass.enabled) {
        try pass.execute(frame_info);
    }
}
```

**Planned**: Dependency-based execution order
```zig
// Execute passes in topologically sorted order
for (self.sorted_passes.items) |pass| {
    if (pass.enabled) {
        try pass.execute(frame_info);
    }
}
```

### Dependency Examples

```
GeometryPass
  └─> writes: color_buffer, depth_buffer

LightVolumePass
  ├─> reads: depth_buffer
  └─> writes: color_buffer (blend)

PathTracingPass
  └─> writes: output_texture (alternative to GeometryPass)

ParticleComputePass
  └─> writes: particle_buffer

ParticlePass
  ├─> reads: particle_buffer, depth_buffer
  └─> writes: color_buffer (blend)
```

### Resource Aliasing

Future optimization: Reuse memory for transient resources

```zig
// Example: depth_buffer only needed during geometry + lighting
// Can be aliased with another resource after lighting complete
try graph.aliasResource("depth_buffer", "temporary_buffer");
```

### Parallel Execution (Future)

DAG enables parallel pass execution on independent branches:

```
        GeometryPass
             │
      ┌──────┴──────┐
      │             │
ShadowPass    ParticleComputePass
      │             │
      └──────┬──────┘
             │
       LightingPass
```

**Benefit**: ShadowPass and ParticleComputePass can execute in parallel (no data dependencies)

## Render Passes

### 1. GeometryPass

Rasterizes mesh geometry to G-buffer or screen.

**Features**:
- Per-object material binding
- Instanced rendering support
- Layer-based sorting (background → foreground)
- Push constant optimization (cached pipeline layout)

**Pipeline**: Graphics (vertex + fragment shaders)
- Vertex: `simple.vert`, `textured.vert`
- Fragment: `simple.frag`, `textured.frag`

**Output**: Color + depth attachments

```zig
pub const GeometryPass = struct {
    base: RenderPass,
    graphics_context: *GraphicsContext,
    pipeline_system: *UnifiedPipelineSystem,
    
    // Optimization: cached pipeline layout
    cached_pipeline_layout: ?vk.PipelineLayout = null,
};
```

### 2. LightVolumePass

Renders point light volumes using instanced rendering.

**Features**:
- **Instanced Rendering**: 128 lights → 1 draw call (95% reduction)
- **SSBO Storage**: Light data in structured buffer
- **Billboard Visualization**: Camera-facing quads
- **Additive Blending**: Light accumulation

**Pipeline**: Graphics (vertex + fragment shaders)
- Shaders: `point_light.vert`, `point_light.frag`

**Optimization**: Replaced per-light push constants with SSBO + gl_InstanceIndex

```zig
pub const LightVolumePass = struct {
    base: RenderPass,
    graphics_context: *GraphicsContext,
    
    // SSBO with all light data (128 capacity)
    light_buffer: vk.Buffer,
    light_count: u32,
};
```

### 3. PathTracingPass

Hardware ray tracing with BVH acceleration.

**Features**:
- **TLAS/BLAS**: Top-level and bottom-level acceleration structures
- **Async BVH Building**: Runs on ThreadPool (bvh_building subsystem)
- **7 Descriptor Bindings**: TLAS, output, camera, vertices, indices, materials, textures
- **Toggle Mode**: Switch between RT and raster with 'T' key

**Pipeline**: Ray tracing (rgen, rchit, rmiss shaders)
- Shaders: `RayTracingTriangle.rgen`, `.rchit`, `.rmiss` (HLSL)

**Optimization**: Reduced image transitions from 4 → 2 per frame (50%)

```zig
pub const PathTracingPass = struct {
    base: RenderPass,
    graphics_context: *GraphicsContext,
    
    // Acceleration structure
    tlas: vk.AccelerationStructureKHR,
    blas_list: std.ArrayList(vk.AccelerationStructureKHR),
    
    // Output
    output_image: vk.Image,
    output_view: vk.ImageView,
    
    // Shader binding table
    sbt_buffer: vk.Buffer,
};
```

### 4. ParticleComputePass

GPU-driven particle simulation using compute shaders.

**Features**:
- **Compute Shader**: Physics updates on GPU
- **Position/Velocity Integration**: Euler integration
- **Early Exit Optimization**: Skip work when no particles active

**Pipeline**: Compute shader
- Shader: `particles.comp`

**Optimization**: Avoids barriers and buffer copies when particle count = 0

```zig
pub const ParticleComputePass = struct {
    base: RenderPass,
    graphics_context: *GraphicsContext,
    
    // Particle data SSBOs
    position_buffer: vk.Buffer,
    velocity_buffer: vk.Buffer,
    particle_count: u32,
};
```

### 5. ParticlePass

Renders GPU-simulated particles as billboards.

**Features**:
- Billboard geometry (camera-facing quads)
- Alpha blending for soft particles
- Instanced rendering (1 draw call per emitter)

**Pipeline**: Graphics (vertex + fragment shaders)
- Shaders: `particles.vert`, `particles.frag`

```zig
pub const ParticlePass = struct {
    base: RenderPass,
    graphics_context: *GraphicsContext,
    pipeline_system: *UnifiedPipelineSystem,
};
```

### 6. LightingPass (Deprecated)

⚠️ **Note**: Being replaced by LightVolumePass. Legacy deferred lighting implementation.

## Usage

### Basic Setup

```zig
// 1. Create render graph
var render_graph = RenderGraph.init(allocator, graphics_context);
defer render_graph.deinit();

// 2. Create and add passes
var geometry_pass = try GeometryPass.init(allocator, graphics_context, pipeline_system);
try render_graph.addPass(&geometry_pass.base);

var light_volume_pass = try LightVolumePass.init(allocator, graphics_context);
try render_graph.addPass(&light_volume_pass.base);

var path_tracing_pass = try PathTracingPass.init(allocator, graphics_context);
try render_graph.addPass(&path_tracing_pass.base);

// 3. Compile graph
try render_graph.compile();

// 4. Execute each frame
while (running) {
    const frame_info = ...; // Camera, delta time, frame index
    try render_graph.execute(frame_info);
}
```

### Dynamic Pass Control

```zig
// ✅ CORRECT: Control passes through RenderGraph
if (input.keyPressed(.T)) {
    if (rt_enabled) {
        render_graph.disablePass("PathTracingPass");
        render_graph.enablePass("GeometryPass");
        rt_enabled = false;
    } else {
        render_graph.enablePass("PathTracingPass");
        render_graph.disablePass("GeometryPass");
        rt_enabled = true;
    }
}

// ❌ INCORRECT: Don't manipulate pass.enabled directly
// This bypasses the graph's management and can cause issues
var pass = render_graph.getPass("PathTracingPass");
pass.?.enabled = false;  // DON'T DO THIS!
```

**Why use RenderGraph methods?**
- Proper state management and logging
- Future DAG recompilation on topology changes
- Thread-safe updates in multi-threaded rendering

### Custom Pass Implementation

```zig
pub const MyCustomPass = struct {
    base: RenderPass,
    // ... custom fields
    
    const vtable = RenderPassVTable{
        .setup = setup,
        .update = update,
        .execute = execute,
        .teardown = teardown,
    };
    
    pub fn init(allocator: Allocator, context: *GraphicsContext) !*MyCustomPass {
        const pass = try allocator.create(MyCustomPass);
        pass.* = .{
            .base = .{
                .name = "MyCustomPass",
                .enabled = true,
                .vtable = &vtable,
            },
            // ... initialize fields
        };
        return pass;
    }
    
    fn setup(base: *RenderPass, graph: *RenderGraph) !void {
        const self = @fieldParentPtr(MyCustomPass, "base", base);
        // Register resources, declare dependencies
    }
    
    fn update(base: *RenderPass, delta_time: f32) !void {
        const self = @fieldParentPtr(MyCustomPass, "base", base);
        // Update state each frame (e.g., rebuild structures, update descriptors)
        // This is called before execute() each frame
    }
    
    fn execute(base: *RenderPass, frame_info: FrameInfo) !void {
        const self = @fieldParentPtr(MyCustomPass, "base", base);
        // Record commands to command buffer
    }
    
    fn teardown(base: *RenderPass) void {
        const self = @fieldParentPtr(MyCustomPass, "base", base);
        // Cleanup resources
    }
};
```

**Note**: All passes must implement `update()`, even if it's a no-op:

```zig
fn update(base: *RenderPass, delta_time: f32) !void {
    _ = base;
    _ = delta_time;
    // No per-frame updates needed for this pass
}
```
                .name = "MyCustomPass",
                .enabled = true,
                .vtable = &vtable,
            },
            // ... initialize fields
        };
        return pass;
    }
    
    fn setup(base: *RenderPass, graph: *RenderGraph) !void {
        const self = @fieldParentPtr(MyCustomPass, "base", base);
        // Register resources, dependencies
    }
    
    fn execute(base: *RenderPass, frame_info: FrameInfo) !void {
        const self = @fieldParentPtr(MyCustomPass, "base", base);
        // Record commands
    }
    
    fn teardown(base: *RenderPass) void {
        const self = @fieldParentPtr(MyCustomPass, "base", base);
        // Cleanup resources
    }
};
```

## Pass Execution Flow

```
1. RenderGraph.compile()
   ├─> Build dependency DAG from pass resource declarations
   ├─> Topological sort for execution order
   ├─> GeometryPass.setup()
   ├─> LightVolumePass.setup()
   └─> PathTracingPass.setup()
   
2. RenderGraph.update(delta_time)      [Each frame]
   ├─> GeometryPass.update(dt)         [if enabled]
   ├─> LightVolumePass.update(dt)      [if enabled]
   └─> PathTracingPass.update(dt)      [if enabled]
       └─> BVH rebuilds, descriptor updates
   
3. RenderGraph.execute(frame_info)     [Each frame]
   ├─> GeometryPass.execute()          [if enabled]
   │   ├─> Begin rendering
   │   ├─> Bind pipeline + descriptors
   │   ├─> Draw meshes
   │   └─> End rendering
   │
   ├─> LightVolumePass.execute()       [if enabled]
   │   ├─> Update light SSBO
   │   ├─> Begin rendering
   │   ├─> Draw instanced (1 draw call)
   │   └─> End rendering
   │
   └─> PathTracingPass.execute()       [if enabled]
       ├─> Bind ray tracing pipeline
       ├─> Trace rays
       └─> Image transition

4. RenderGraph.deinit()
   ├─> GeometryPass.teardown()
   ├─> LightVolumePass.teardown()
   └─> PathTracingPass.teardown()
```

## Performance Characteristics

### Pass Overhead

| Pass              | Draw Calls | CPU Time | GPU Time | Notes                          |
|-------------------|------------|----------|----------|--------------------------------|
| GeometryPass      | N objects  | ~0.5ms   | ~2.0ms   | Cached pipeline layout         |
| LightVolumePass   | 1          | ~0.1ms   | ~0.3ms   | Instanced rendering            |
| PathTracingPass   | 0          | ~0.8ms   | ~5.0ms   | BVH traversal dominates        |
| ParticleCompute   | 0          | ~0.05ms  | ~0.2ms   | Early exit when empty          |
| ParticlePass      | M emitters | ~0.2ms   | ~0.5ms   | Billboards, alpha blend        |

### Optimization Impact

- **LightVolumePass Instancing**: 95% reduction in draw calls (N → 1)
- **PathTracingPass Transitions**: 50% reduction (4 → 2 per frame)
- **GeometryPass Layout Cache**: Eliminates hashmap lookup per frame
- **ParticleComputePass Early Exit**: Zero GPU work when no particles

## Integration Points

### With ECS

```zig
// RenderSystem extracts data from ECS World
const render_data = try render_system.extractRenderData(world, camera_entity);

// GeometryPass consumes render data
try geometry_pass.execute(frame_info); // Uses render_data internally
```

### With Asset System

```zig
// Passes reference assets by ID
const material = asset_manager.getMaterial(mesh_renderer.material_id);
const texture = asset_manager.getTexture(material.diffuse_texture);

// Hot-reload triggers pipeline rebuild
asset_manager.onShaderReloaded(shader_id, |pipeline_id| {
    pipeline_system.rebuildPipeline(pipeline_id);
});
```

### With Threading

```zig
// PathTracingPass submits BVH work to ThreadPool
thread_pool.submitWork(.bvh_building, .{
    .priority = .high,
    .func = buildBVH,
    .data = geometry_data,
});

// Async completion detected in execute()
if (bvh_builder.isComplete()) {
    tlas = bvh_builder.getTLAS();
}
```

## Troubleshooting

### Pass Not Executing

**Symptoms**: Pass appears in graph but doesn't render

**Solutions**:
1. Check `pass.enabled` flag
2. Verify `render_graph.compile()` was called
3. Ensure dependencies are satisfied
4. Check validation layers for Vulkan errors

### Resource Not Found

**Symptoms**: `error.ResourceNotFound` in setup()

**Solutions**:
1. Verify resource was registered in setup()
2. Check resource name spelling
3. Ensure setup() runs before execute()

### Performance Degradation

**Symptoms**: Frame time increases after adding pass

**Solutions**:
1. Profile with PerformanceMonitor
2. Check draw call count (should be minimized)
3. Verify early exit paths are working
4. Review image transition count

## Future Enhancements

### Planned

- **Automatic Dependency Sorting**: Topological sort based on resource dependencies
- **Resource Aliasing**: Reuse memory for transient resources
- **Async Compute**: Overlap compute and graphics work
- **Multi-queue Execution**: Parallel pass execution on different queues

### Under Consideration

- **Frame Graph**: Compile-time resource lifetime analysis
- **GPU-Driven Culling**: Occlusion culling compute pass
- **Clustered Rendering**: Light clustering for forward+ rendering
- **Temporal Passes**: TAA, motion blur, history buffers

## References

- **Implementation**: `src/rendering/render_graph.zig`
- **Passes**: `src/rendering/passes/*.zig`
- **Related Docs**: 
  - [Lighting System](LIGHTING_SYSTEM.md)
  - [Path Tracing Integration](PATH_TRACING_INTEGRATION.md)
  - [Unified Pipeline System](UNIFIED_PIPELINE_MIGRATION.md)

---

*Last Updated: October 24, 2025*
