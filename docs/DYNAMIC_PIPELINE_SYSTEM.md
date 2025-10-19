# Dynamic Pipeline Management System

The Dynamic Pipeline Management System provides real-time pipeline creation and hot reloading capabilities for the ZulkanZengine. This system allows developers to dynamically create and modify rendering pipelines at runtime, with automatic rebuilding when shaders change.

## Features

- **Dynamic Pipeline Creation**: Create pipelines from templates at runtime
- **Shader Hot Reload Integration**: Automatically rebuild pipelines when shaders are modified
- **Pipeline Caching**: Efficient reuse of existing pipelines (persistent cache via UnifiedPipelineSystem)
- **Thread Safety**: Safe concurrent access to pipeline resources
- **Usage Statistics**: Monitor pipeline performance and usage patterns

## Core Components

### 1. DynamicPipelineManager

The central manager for dynamic pipeline creation and lifecycle management.

```zig
const manager = try DynamicPipelineManager.init(
    allocator,
    graphics_context,
    asset_manager,
    shader_manager
);
defer manager.deinit();
```

### 2. PipelineTemplate

Defines the configuration for a pipeline that can be dynamically created.

```zig
const template = PipelineTemplate{
    .name = "my_pipeline",
    .vertex_shader = "shaders/vertex.vert",
    .fragment_shader = "shaders/fragment.frag",
    
    .vertex_bindings = &[_]PipelineBuilder.VertexInputBinding{
        PipelineBuilder.VertexInputBinding.create(0, @sizeOf(Vertex)),
    },
    
    .vertex_attributes = &[_]PipelineBuilder.VertexInputAttribute{
        PipelineBuilder.VertexInputAttribute.create(0, 0, .r32g32b32_sfloat, 0),
        PipelineBuilder.VertexInputAttribute.create(1, 0, .r32g32_sfloat, 12),
    },
    
    .descriptor_bindings = &[_]PipelineBuilder.DescriptorBinding{
        PipelineBuilder.DescriptorBinding.uniformBuffer(0, .{ .vertex_bit = true }),
        PipelineBuilder.DescriptorBinding.combinedImageSampler(1, .{ .fragment_bit = true }),
    },
    
    .depth_test_enable = true,
    .cull_mode = .{ .back_bit = true },
};
```

### 3. ShaderPipelineIntegration

Bridges the shader hot reload system with pipeline management.

```zig
const integration = try ShaderPipelineIntegration.init(
    allocator,
    &pipeline_manager,
    &shader_watcher
);
defer integration.deinit();

// Set global integration for shader reload callbacks
setGlobalIntegration(&integration);
```

## Usage Guide

### Step 1: Initialize the System

```zig
// Initialize managers
var pipeline_manager = try DynamicPipelineManager.init(
    allocator,
    graphics_context,
    asset_manager,
    shader_manager
);
defer pipeline_manager.deinit();

// Initialize shader hot reload integration
var integration = try ShaderPipelineIntegration.init(
    allocator,
    &pipeline_manager,
    &shader_watcher
);
defer integration.deinit();
setGlobalIntegration(&integration);
```

### Step 2: Register Pipeline Templates

```zig
// Define pipeline configurations
const basic_template = PipelineTemplate{
    .name = "basic_lit",
    .vertex_shader = "shaders/simple.vert",
    .fragment_shader = "shaders/simple.frag",
    // ... other configuration
};

const textured_template = PipelineTemplate{
    .name = "textured_lit", 
    .vertex_shader = "shaders/textured.vert",
    .fragment_shader = "shaders/textured.frag",
    // ... other configuration
};

// Register templates
try pipeline_manager.registerPipeline(basic_template);
try pipeline_manager.registerPipeline(textured_template);
```

### Step 3: Use Pipelines in Rendering

```zig
pub fn render(self: *Renderer, frame_info: FrameInfo, render_pass: vk.RenderPass) !void {
    // Get pipeline (will build if needed)
    const pipeline = try self.pipeline_manager.getPipeline("textured_lit", render_pass);
    const pipeline_layout = self.pipeline_manager.getPipelineLayout("textured_lit");
    
    if (pipeline == null or pipeline_layout == null) return;
    
    // Use the pipeline
    frame_info.command_buffer.cmdBindPipeline(.graphics, pipeline.?);
    
    // Bind descriptors and draw
    frame_info.command_buffer.cmdBindDescriptorSets(
        .graphics,
        pipeline_layout.?,
        0, 1,
        @ptrCast(&descriptor_set),
        0, null
    );
    
    frame_info.command_buffer.cmdDraw(3, 1, 0, 0);
}
```

### Step 4: Process Hot Reload Updates

```zig
pub fn update(self: *Renderer, render_pass: vk.RenderPass) void {
    // Process any pending pipeline rebuilds (call once per frame)
    self.pipeline_manager.processRebuildQueue(render_pass);
}
```

## Pipeline Template Configuration

### Shader Configuration
```zig
.vertex_shader = "shaders/vertex.vert",     // Required
.fragment_shader = "shaders/fragment.frag", // Required
.geometry_shader = "shaders/geometry.geom", // Optional
.tess_control_shader = "shaders/tess.tesc", // Optional
.tess_eval_shader = "shaders/tess.tese",    // Optional
```

### Vertex Input
```zig
.vertex_bindings = &[_]PipelineBuilder.VertexInputBinding{
    PipelineBuilder.VertexInputBinding.create(0, @sizeOf(Vertex)),
    PipelineBuilder.VertexInputBinding.create(1, @sizeOf(InstanceData)).instanceRate(),
},

.vertex_attributes = &[_]PipelineBuilder.VertexInputAttribute{
    PipelineBuilder.VertexInputAttribute.create(0, 0, .r32g32b32_sfloat, @offsetOf(Vertex, "position")),
    PipelineBuilder.VertexInputAttribute.create(1, 0, .r32g32b32_sfloat, @offsetOf(Vertex, "normal")),
    PipelineBuilder.VertexInputAttribute.create(2, 1, .r32g32b32a32_sfloat, @offsetOf(InstanceData, "transform")),
},
```

### Descriptor Sets
```zig
.descriptor_bindings = &[_]PipelineBuilder.DescriptorBinding{
    PipelineBuilder.DescriptorBinding.uniformBuffer(0, .{ .vertex_bit = true, .fragment_bit = true }),
    PipelineBuilder.DescriptorBinding.combinedImageSampler(1, .{ .fragment_bit = true }),
    PipelineBuilder.DescriptorBinding.storageBuffer(2, .{ .compute_bit = true }),
    PipelineBuilder.DescriptorBinding.accelerationStructure(3, .{ .raygen_bit_khr = true }),
},
```

### Push Constants
```zig
.push_constant_ranges = &[_]PipelineBuilder.PushConstantRange{
    PipelineBuilder.PushConstantRange{
        .stage_flags = .{ .vertex_bit = true, .fragment_bit = true },
        .offset = 0,
        .size = @sizeOf(PushConstants),
    },
},
```

### Render State
```zig
.primitive_topology = .triangle_list,
.polygon_mode = .fill,              // .fill, .line, .point
.cull_mode = .{ .back_bit = true }, // .none, .front, .back, .front_and_back
.front_face = .counter_clockwise,
.depth_test_enable = true,
.depth_write_enable = true,
.depth_compare_op = .less,
.blend_enable = false,
```

### Dynamic State
```zig
.dynamic_states = &[_]vk.DynamicState{
    .viewport,
    .scissor,
    .line_width,
    .depth_bias,
},
```

## Hot Reload Workflow

1. **Shader Change Detection**: The shader hot reload system detects file changes
2. **Pipeline Identification**: The integration finds all pipelines using the changed shader
3. **Rebuild Marking**: Affected pipelines are marked for rebuild and queued
4. **Rebuild Processing**: During the next frame, `processRebuildQueue()` rebuilds pipelines
5. **Automatic Usage**: Next `getPipeline()` call returns the updated pipeline

## Performance Considerations

- **Pipeline Caching**: Pipelines are cached and reused until shaders change
  - **Disk Persistence**: UnifiedPipelineSystem provides persistent Vulkan pipeline cache for faster subsequent launches
  - **See**: `docs/PIPELINE_CACHING.md` for details on cache management
- **Lazy Building**: Pipelines are only built when first requested
- **Batch Rebuilding**: Multiple shader changes are batched into a single rebuild pass
- **Thread Safety**: All operations are thread-safe with minimal locking

## Statistics and Monitoring

```zig
const stats = pipeline_manager.getStatistics();
log(.INFO, "pipeline_stats", 
    "Pipelines: {}/{} active, {} pending rebuilds, {} total usage",
    .{stats.active_pipelines, stats.total_pipelines, stats.pending_rebuilds, stats.total_usage}
);
```

## Integration with GenericRenderer

The dynamic pipeline system works seamlessly with the GenericRenderer:

```zig
pub const MyRenderer = struct {
    pipeline_manager: *DynamicPipelineManager,
    
    pub fn render(self: *Self, frame_info: FrameInfo, scene_data: *anyopaque) !void {
        const render_pass = frame_info.render_pass; // Get from frame info
        
        // Process hot reload updates
        self.pipeline_manager.processRebuildQueue(render_pass);
        
        // Use dynamic pipelines for rendering
        const pipeline = try self.pipeline_manager.getPipeline("my_pipeline", render_pass);
        // ... render with pipeline
    }
};

// Register with GenericRenderer
try generic_renderer.addRenderer("my_renderer", .raster, &my_renderer, MyRenderer);
```

## Example: Complete Renderer

See `dynamic_renderer_example.zig` for a complete example renderer that demonstrates:
- Multiple pipeline templates (basic, textured, wireframe)
- Dynamic pipeline selection based on render mode
- Proper integration with hot reload system
- Statistics monitoring

This system provides the foundation for flexible, maintainable rendering pipelines with excellent developer experience through hot reloading capabilities.

## See Also

- `docs/PIPELINE_CACHING.md` - Persistent pipeline cache for faster startups
- `docs/UNIFIED_PIPELINE_MIGRATION.md` - UnifiedPipelineSystem migration guide
- `src/rendering/unified_pipeline_system.zig` - Core pipeline management
- `src/rendering/pipeline_builder.zig` - Pipeline creation utilities