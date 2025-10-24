# RenderGraph Quick Reference

**Updated**: October 24, 2025  
**Features**: DAG compilation with topological sorting

## Creating a RenderGraph

```zig
var render_graph = RenderGraph.init(allocator, graphics_context);
defer render_graph.deinit();
```

## Adding Passes

```zig
var geometry_pass = try GeometryPass.init(allocator, graphics_context, pipeline_system);
try render_graph.addPass(&geometry_pass.base);

var light_volume_pass = try LightVolumePass.init(allocator, graphics_context);
try render_graph.addPass(&light_volume_pass.base);

var path_tracing_pass = try PathTracingPass.init(allocator, graphics_context);
try render_graph.addPass(&path_tracing_pass.base);
```

## Compiling and Executing

```zig
// Compile once after all passes added
// - Calls setup() on all passes
// - Builds DAG from dependencies
// - Topologically sorts enabled passes
try render_graph.compile();

// Execute each frame (uses compiled execution order)
try render_graph.execute(frame_info);
```

## Pass Control (with DAG Recompilation)

```zig
// Enable/disable passes at runtime
// Note: These mark the graph as needing recompilation but don't rebuild yet
render_graph.enablePass("path_tracing_pass");
render_graph.disablePass("geometry_pass");
render_graph.disablePass("particle_pass");

// Recompile DAG after all state changes (efficient - single rebuild)
try render_graph.recompile();

// Example: Toggle between raster and path tracing
if (enable_path_tracing) {
    graph.disablePass("geometry_pass");
    graph.disablePass("particle_pass");
    graph.disablePass("light_volume_pass");
    graph.enablePass("path_tracing_pass");
    try graph.recompile(); // Rebuild execution order once
}
```

## Available Passes

| Pass              | Type     | Purpose                          |
|-------------------|----------|----------------------------------|
| GeometryPass      | Graphics | Rasterize meshes                 |
| LightVolumePass   | Graphics | Instanced light rendering        |
| PathTracingPass   | RayTrace | Hardware ray tracing             |
| ParticleCompute   | Compute  | GPU particle simulation          |
| ParticlePass      | Graphics | Render particles                 |

## Custom Pass Template

```zig
pub const MyPass = struct {
    base: RenderPass,
    allocator: Allocator,
    // ... your fields
    
    const vtable = RenderPassVTable{
        .setup = setup,
        .update = update,
        .execute = execute,
        .teardown = teardown,
    };
    
    pub fn init(allocator: Allocator, ctx: *GraphicsContext) !*MyPass {
        const pass = try allocator.create(MyPass);
        pass.* = .{
            .base = .{
                .name = "my_pass",
                .enabled = true,
                .vtable = &vtable,
                .dependencies = std.ArrayList([]const u8){}, // Initialize empty
            },
            .allocator = allocator,
        };
        return pass;
    }
    
    fn setup(base: *RenderPass, graph: *RenderGraph) !void {
        const self = @fieldParentPtr(MyPass, "base", base);
        
        // Optional: Declare dependencies on other passes
        // try base.dependencies.append("geometry_pass");
        // try base.dependencies.append("particle_compute_pass");
        
        // Register resources, allocate buffers, etc.
    }
    
    fn update(base: *RenderPass, delta_time: f32) !void {
        const self = @fieldParentPtr(MyPass, "base", base);
        // Update per-frame state (or no-op if not needed)
    }
    
    fn execute(base: *RenderPass, frame_info: FrameInfo) !void {
        const self = @fieldParentPtr(MyPass, "base", base);
        // Record commands
    }
    
    fn teardown(base: *RenderPass) void {
        const self = @fieldParentPtr(MyPass, "base", base);
        // Cleanup
    }
};
```

## Resource Management

```zig
// In pass setup()
const resource_id = try graph.resources.registerResource(
    "my_render_target",
    .render_target,
    .r8g8b8a8_unorm,
);

// Later, update with actual image
try graph.resources.updateResourceImage(
    resource_id,
    image,
    view,
    memory,
    width,
    height,
);

// Retrieve by name
if (graph.resources.getResourceByName("my_render_target")) |resource| {
    const view = resource.view;
}
```

## Pass Execution Order

Passes execute in the order they're added (for now):

```zig
try render_graph.addPass(&geometry_pass.base);      // Executes 1st
try render_graph.addPass(&light_volume_pass.base);  // Executes 2nd
try render_graph.addPass(&path_tracing_pass.base);  // Executes 3rd
```

## Common Patterns

### Toggle Between RT and Raster

```zig
if (rt_enabled) {
    render_graph.enablePass("PathTracingPass");
    render_graph.disablePass("GeometryPass");
} else {
    render_graph.disablePass("PathTracingPass");
    render_graph.enablePass("GeometryPass");
}
```

### Conditional Pass Execution

```zig
// Pass checks internally
fn execute(base: *RenderPass, frame_info: FrameInfo) !void {
    const self = @fieldParentPtr(MyPass, "base", base);
    
    if (self.item_count == 0) {
        return; // Early exit, no work to do
    }
    
    // ... normal execution
}
```

## See Also

- [RenderGraph System](RENDER_GRAPH_SYSTEM.md) - Full documentation
- [Lighting System](LIGHTING_SYSTEM.md) - LightVolumePass details
- [Path Tracing Integration](PATH_TRACING_INTEGRATION.md) - PathTracingPass details
