# Pipeline/Descriptor Set Unification Migration Guide

## Overview

The new unified pipeline system replaces the fragmented approach of having separate systems for pipeline management, descriptor set management, and resource binding. This document shows how to migrate from the old system to the new unified approach.

## Key Benefits

1. **Automatic Descriptor Layout Extraction**: Descriptor layouts are automatically extracted from shader reflection data
2. **Unified Resource Binding**: Single API for binding all types of resources
3. **Hot-Reload Integration**: Automatic pipeline recreation when shaders change
4. **Frame-based Resource Management**: Proper handling of per-frame resources
5. **Type-Safe Resource Binding**: Compile-time safety for resource types

## Architecture Overview

```
┌─────────────────────────┐
│   Application Layer     │
├─────────────────────────┤
│    ResourceBinder       │  ← High-level resource binding API
├─────────────────────────┤
│ UnifiedPipelineSystem   │  ← Core pipeline + descriptor management
├─────────────────────────┤
│     ShaderManager       │  ← Shader compilation + hot-reload
├─────────────────────────┤
│    Vulkan Core APIs     │
└─────────────────────────┘
```

## Migration Examples

### Before: Old Fragmented Approach

```zig
// Old approach - multiple systems to manage
const pipeline_builder = PipelineBuilder.init(graphics_context, allocator);
const descriptor_manager = RenderPassDescriptorManager.init(allocator, graphics_context);
const dynamic_pipeline = DynamicPipelineManager.init(allocator, graphics_context);

// Manual descriptor layout creation
const uniform_binding = vk.DescriptorSetLayoutBinding{
    .binding = 0,
    .descriptor_type = .uniform_buffer,
    .descriptor_count = 1,
    .stage_flags = .{ .vertex_bit = true, .fragment_bit = true },
    .p_immutable_samplers = null,
};

// Manual pipeline creation
pipeline_builder.addVertexShader(vertex_module);
pipeline_builder.addFragmentShader(fragment_module);
pipeline_builder.withDescriptorSetLayout(descriptor_layout);
const pipeline = try pipeline_builder.buildGraphicsPipeline();

// Manual resource binding
try descriptor_manager.bindUniformBuffer(descriptor_set, 0, uniform_buffer);
```

### After: New Unified Approach

```zig
// New approach - single unified system
var unified_system = try UnifiedPipelineSystem.init(allocator, graphics_context, shader_manager);
var resource_binder = ResourceBinder.init(allocator, &unified_system);

// Automatic descriptor layout extraction from shaders
const pipeline_config = UnifiedPipelineSystem.PipelineConfig{
    .name = "textured_object",
    .vertex_shader = "shaders/textured.vert",
    .fragment_shader = "shaders/textured.frag",
    .render_pass = render_pass,
    .vertex_input_bindings = &[_]VertexInputBinding{
        .{ .binding = 0, .stride = @sizeOf(Vertex), .input_rate = .vertex },
    },
    .vertex_input_attributes = &[_]VertexInputAttribute{
        .{ .location = 0, .binding = 0, .format = .r32g32b32_sfloat, .offset = @offsetOf(Vertex, "pos") },
        .{ .location = 1, .binding = 0, .format = .r32g32_sfloat, .offset = @offsetOf(Vertex, "tex_coord") },
    },
};

const pipeline_id = try unified_system.createPipeline(pipeline_config);

// Easy resource binding
try resource_binder.bindFullUniformBuffer(pipeline_id, 0, 0, uniform_buffer, frame_index);
try resource_binder.bindTextureDefault(pipeline_id, 0, 1, texture_view, sampler, frame_index);
```

## Usage Patterns

### 1. Basic Pipeline Creation and Binding

```zig
// Initialize systems
var unified_system = try UnifiedPipelineSystem.init(allocator, graphics_context, shader_manager);
defer unified_system.deinit();

var resource_binder = ResourceBinder.init(allocator, &unified_system);
defer resource_binder.deinit();

// Create pipeline with automatic descriptor layout extraction
const pipeline_id = try unified_system.createPipeline(.{
    .name = "simple_render",
    .vertex_shader = "shaders/simple.vert",
    .fragment_shader = "shaders/simple.frag",
    .render_pass = main_render_pass,
});

// Bind resources for this frame
try resource_binder.bindFullUniformBuffer(pipeline_id, 0, 0, mvp_buffer, current_frame);
try resource_binder.bindTextureDefault(pipeline_id, 0, 1, diffuse_texture, linear_sampler, current_frame);

// Update descriptor sets
try resource_binder.updateFrame(current_frame);

// Render
try unified_system.bindPipeline(command_buffer, pipeline_id);
// ... draw commands ...
```

### 2. Per-Frame Resource Management

```zig
// For each frame in flight
for (0..MAX_FRAMES_IN_FLIGHT) |frame_index| {
    // Bind frame-specific resources
    try resource_binder.bindFullUniformBuffer(
        pipeline_id,
        0, 0, // set 0, binding 0
        per_frame_uniform_buffers[frame_index],
        @intCast(frame_index)
    );
    
    // Bind shared resources
    try resource_binder.bindTextureDefault(
        pipeline_id,
        0, 1, // set 0, binding 1
        shared_texture,
        shared_sampler,
        @intCast(frame_index)
    );
}

// Update all frames
for (0..MAX_FRAMES_IN_FLIGHT) |frame_index| {
    try resource_binder.updateFrame(@intCast(frame_index));
}
```

### 3. Hot-Reload Integration

```zig
// Register for pipeline reload notifications
const ReloadContext = struct {
    renderer: *MyRenderer,
    
    fn onPipelineReloaded(context: *anyopaque, pipeline_id: PipelineId) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.renderer.rebindResources(pipeline_id);
    }
};

var reload_context = ReloadContext{ .renderer = my_renderer };
try unified_system.registerPipelineReloadCallback(.{
    .context = &reload_context,
    .onPipelineReloaded = ReloadContext.onPipelineReloaded,
});

// When shaders change, pipelines are automatically recreated
// and the callback is invoked to rebind resources
```

### 4. Multiple Descriptor Sets

```zig
// Pipeline with multiple descriptor sets
const pipeline_id = try unified_system.createPipeline(.{
    .name = "multi_set_pipeline",
    .vertex_shader = "shaders/multi_set.vert",
    .fragment_shader = "shaders/multi_set.frag",
    .render_pass = render_pass,
});

// Set 0: Per-frame data
try resource_binder.bindFullUniformBuffer(pipeline_id, 0, 0, frame_ubo, frame_index);

// Set 1: Per-material data
try resource_binder.bindFullUniformBuffer(pipeline_id, 1, 0, material_ubo, frame_index);
try resource_binder.bindTextureDefault(pipeline_id, 1, 1, diffuse_texture, sampler, frame_index);
try resource_binder.bindTextureDefault(pipeline_id, 1, 2, normal_texture, sampler, frame_index);

// Set 2: Per-object data
try resource_binder.bindFullUniformBuffer(pipeline_id, 2, 0, object_ubo, frame_index);
```

## Error Handling

```zig
// Pipeline creation can fail
const pipeline_id = unified_system.createPipeline(config) catch |err| switch (err) {
    error.ShaderCompilationFailed => {
        log(.ERROR, "Failed to compile shaders for pipeline: {s}", .{config.name});
        return err;
    },
    error.IncompatibleDescriptorLayouts => {
        log(.ERROR, "Descriptor layouts don't match between shader stages", .{});
        return err;
    },
    else => return err,
};

// Resource binding can fail
resource_binder.bindFullUniformBuffer(pipeline_id, 0, 0, buffer, frame_index) catch |err| switch (err) {
    error.PipelineNotFound => {
        log(.ERROR, "Pipeline not found: {}", .{pipeline_id});
        return err;
    },
    error.InvalidBinding => {
        log(.ERROR, "Invalid binding: set=0, binding=0", .{});
        return err;
    },
    else => return err,
};
```

## Performance Considerations

### Resource Binding Optimization

```zig
// Batch resource updates per frame instead of individual updates
const frame_resources = [_]struct {
    pipeline_id: PipelineId,
    set: u32,
    binding: u32,
    buffer: *Buffer,
}{
    .{ .pipeline_id = main_pipeline, .set = 0, .binding = 0, .buffer = mvp_buffer },
    .{ .pipeline_id = main_pipeline, .set = 0, .binding = 1, .buffer = light_buffer },
    .{ .pipeline_id = shadow_pipeline, .set = 0, .binding = 0, .buffer = shadow_mvp_buffer },
};

// Bind all resources for the frame
for (frame_resources) |resource| {
    try resource_binder.bindFullUniformBuffer(
        resource.pipeline_id,
        resource.set,
        resource.binding,
        resource.buffer,
        frame_index
    );
}

// Single update call for all resources
try resource_binder.updateFrame(frame_index);
```

### Descriptor Pool Management

```zig
// The unified system automatically manages descriptor pools
// based on usage patterns. No manual pool management required.

// However, you can hint at expected usage for better pool sizing:
const pipeline_config = UnifiedPipelineSystem.PipelineConfig{
    .name = "high_frequency_pipeline",
    .vertex_shader = "shaders/instanced.vert",
    .fragment_shader = "shaders/instanced.frag",
    .render_pass = render_pass,
    // This pipeline will be used frequently with many descriptor sets
    .expected_descriptor_set_count = 1000,
};
```

## Migration Checklist

- [ ] Replace PipelineBuilder usage with UnifiedPipelineSystem.createPipeline()
- [ ] Replace manual descriptor layout creation with automatic extraction
- [ ] Replace RenderPassDescriptorManager with ResourceBinder
- [ ] Update resource binding calls to use ResourceBinder methods
- [ ] Add hot-reload callbacks for dynamic pipelines
- [ ] Update frame management to use per-frame resource binding
- [ ] Remove manual descriptor pool management
- [ ] Update error handling for new error types

## Common Migration Issues

### Issue: Missing Descriptor Bindings
**Problem**: Shader expects bindings that aren't being set.
**Solution**: Use the ResourceBinder.getBound* methods to verify bindings are correct.

### Issue: Frame Synchronization
**Problem**: Resources bound to wrong frame indices.
**Solution**: Ensure frame_index parameter matches the current frame in flight.

### Issue: Hot-Reload Crashes
**Problem**: Resources become invalid after shader reload.
**Solution**: Implement proper pipeline reload callbacks to rebind resources.

### Issue: Performance Degradation
**Problem**: Too many individual resource updates.
**Solution**: Batch resource binding calls and use single updateFrame() call.