# Particle Renderer Migration: Old vs New Unified System

## Overview

This document shows the migration of the particle renderer from the old fragmented approach to the new unified pipeline system. The particle renderer is particularly interesting because it uses both compute and graphics pipelines.

## Architecture Comparison

### Before: Old Fragmented Approach

```zig
// Multiple separate systems to manage
const pipeline_builder = PipelineBuilder.init(graphics_context, allocator);
const descriptor_manager = RenderPassDescriptorManager.init(allocator, graphics_context);
const dynamic_pipeline = DynamicPipelineManager.init(allocator, graphics_context);

// Manual descriptor layout creation for compute pipeline
const compute_uniform_binding = vk.DescriptorSetLayoutBinding{
    .binding = 0,
    .descriptor_type = .uniform_buffer,
    .descriptor_count = 1,
    .stage_flags = .{ .compute_bit = true },
    .p_immutable_samplers = null,
};

const particle_storage_binding = vk.DescriptorSetLayoutBinding{
    .binding = 1,
    .descriptor_type = .storage_buffer,
    .descriptor_count = 1,
    .stage_flags = .{ .compute_bit = true },
    .p_immutable_samplers = null,
};

// Manual pipeline creation
const compute_pipeline = try pipeline_builder.buildComputePipeline(compute_layout);
const render_pipeline = try pipeline_builder.buildGraphicsPipeline(render_layout);

// Manual resource binding per frame
for (0..MAX_FRAMES_IN_FLIGHT) |frame_index| {
    try descriptor_manager.bindUniformBuffer(
        compute_descriptor_sets[frame_index], 
        0, 
        compute_uniform_buffers[frame_index]
    );
    try descriptor_manager.bindStorageBuffer(
        compute_descriptor_sets[frame_index], 
        1, 
        particle_buffers[frame_index]
    );
}
```

### After: New Unified System

```zig
// Single unified system
var pipeline_system = try UnifiedPipelineSystem.init(allocator, graphics_context, shader_manager);
var resource_binder = ResourceBinder.init(allocator, &pipeline_system);

// Automatic descriptor layout extraction from shaders
const compute_pipeline = try pipeline_system.createPipeline(.{
    .name = "particle_compute",
    .compute_shader = "shaders/particles.comp",
    .render_pass = vk.RenderPass.null_handle, // Compute pipelines don't use render passes
});

const render_pipeline = try pipeline_system.createPipeline(.{
    .name = "particle_render",
    .vertex_shader = "shaders/particles.vert",
    .fragment_shader = "shaders/particles.frag",
    .render_pass = render_pass,
    .topology = .point_list,
});

// Easy resource binding for all frames
for (0..MAX_FRAMES_IN_FLIGHT) |frame_index| {
    // Compute resources
    try resource_binder.bindFullUniformBuffer(compute_pipeline, 0, 0, compute_uniform_buffers[frame_index], frame_index);
    try resource_binder.bindFullStorageBuffer(compute_pipeline, 1, 0, particle_buffers[frame_index], frame_index);
    
    // Render resources
    try resource_binder.bindFullUniformBuffer(render_pipeline, 0, 0, render_uniform_buffers[frame_index], frame_index);
}
```

## Key Improvements

### 1. Unified Pipeline Management

**Before:**
- Separate systems for compute and graphics pipelines
- Manual descriptor layout management
- Complex state tracking across multiple managers

**After:**
- Single system handles both compute and graphics pipelines
- Automatic descriptor layout extraction from shaders
- Unified resource binding interface

### 2. Simplified Resource Binding

**Before:**
```zig
// Manual binding with complex descriptor set management
try descriptor_manager.bindUniformBuffer(descriptor_set, binding, buffer);
try descriptor_manager.bindStorageBuffer(descriptor_set, binding, buffer);
try descriptor_manager.updateDescriptorSet(descriptor_set);
```

**After:**
```zig
// Simple high-level resource binding
try resource_binder.bindFullUniformBuffer(pipeline_id, set, binding, buffer, frame_index);
try resource_binder.bindFullStorageBuffer(pipeline_id, set, binding, buffer, frame_index);
try resource_binder.updateFrame(frame_index);
```

### 3. Hot-Reload Integration

**Before:**
- Manual pipeline recreation on shader changes
- Complex resource rebinding logic
- Error-prone state management

**After:**
```zig
// Automatic hot-reload with callback system
try pipeline_system.registerPipelineReloadCallback(.{
    .context = &reload_context,
    .onPipelineReloaded = PipelineReloadContext.onPipelineReloaded,
});

// Callback automatically re-binds resources
fn onPipelineReloaded(context: *anyopaque, pipeline_id: PipelineId) void {
    const self: *PipelineReloadContext = @ptrCast(@alignCast(context));
    self.renderer.setupResources() catch |err| {
        log(.ERROR, "Failed to re-setup resources: {}", .{err});
    };
}
```

## Usage Examples

### 1. Particle Simulation Update

**Old Way:**
```zig
// Manual pipeline binding and resource management
vkd.cmdBindPipeline(command_buffer, .compute, compute_pipeline);
vkd.cmdBindDescriptorSets(
    command_buffer, .compute, compute_pipeline_layout,
    0, 1, &descriptor_sets[frame_index], 0, null
);

// Manual barrier management
const barrier = vk.MemoryBarrier{
    .src_access_mask = .{ .shader_write_bit = true },
    .dst_access_mask = .{ .vertex_attribute_read_bit = true },
};
vkd.cmdPipelineBarrier(command_buffer, .{ .compute_shader_bit = true }, 
                      .{ .vertex_input_bit = true }, .{}, 1, &barrier, 0, null, 0, null);

vkd.cmdDispatch(command_buffer, workgroups, 1, 1);
```

**New Way:**
```zig
// Unified system handles all the complexity
try particle_renderer.updateParticles(command_buffer, delta_time, emitter_position, frame_index);

// Internal implementation:
// - Updates uniform buffers
// - Binds pipeline automatically
// - Handles memory barriers
// - Dispatches compute workgroups
```

### 2. Particle Rendering

**Old Way:**
```zig
// Manual pipeline and resource binding
vkd.cmdBindPipeline(command_buffer, .graphics, render_pipeline);
vkd.cmdBindDescriptorSets(
    command_buffer, .graphics, render_pipeline_layout,
    0, 1, &render_descriptor_sets[frame_index], 0, null
);

const vertex_buffers = [_]vk.Buffer{particle_vertex_buffer};
const offsets = [_]vk.DeviceSize{0};
vkd.cmdBindVertexBuffers(command_buffer, 0, 1, &vertex_buffers, &offsets);
vkd.cmdDraw(command_buffer, 1, particle_count, 0, 0);
```

**New Way:**
```zig
// High-level rendering interface
try particle_renderer.renderParticles(command_buffer, camera, frame_index);

// Internal implementation:
// - Updates render uniforms with camera data
// - Binds render pipeline automatically
// - Binds vertex buffers
// - Issues draw commands
```

## Performance Benefits

### Memory Management
- **Unified Descriptor Pools**: Single system manages all descriptor pools efficiently
- **Automatic Pool Resizing**: Pools grow as needed without manual intervention
- **Per-Frame Resource Tracking**: Efficient cleanup and reuse of per-frame resources

### CPU Performance
- **Batched Updates**: Single `updateFrame()` call updates all descriptor sets
- **Reduced State Changes**: Unified system minimizes redundant state changes
- **Hot-Reload Optimization**: Only affected pipelines are recreated

### Developer Experience
- **Type Safety**: Compile-time verification of resource bindings
- **Error Handling**: Comprehensive error reporting with context
- **Debug Information**: Detailed logging for troubleshooting

## Migration Steps

### 1. Replace Pipeline Creation
```zig
// Remove old pipeline builders
// const pipeline_builder = PipelineBuilder.init(...);

// Add unified system
var pipeline_system = try UnifiedPipelineSystem.init(allocator, graphics_context, shader_manager);
var resource_binder = ResourceBinder.init(allocator, &pipeline_system);
```

### 2. Update Pipeline Configuration
```zig
// Replace manual pipeline creation
const compute_pipeline = try pipeline_system.createPipeline(.{
    .name = "particle_compute",
    .compute_shader = "shaders/particles.comp",
    .render_pass = vk.RenderPass.null_handle,
});
```

### 3. Migrate Resource Binding
```zig
// Replace manual descriptor management
try resource_binder.bindFullUniformBuffer(pipeline_id, set, binding, buffer, frame_index);
try resource_binder.bindFullStorageBuffer(pipeline_id, set, binding, buffer, frame_index);
```

### 4. Add Hot-Reload Support
```zig
// Add pipeline reload callbacks
try pipeline_system.registerPipelineReloadCallback(.{
    .context = &reload_context,
    .onPipelineReloaded = YourRenderer.onPipelineReloaded,
});
```

### 5. Update Render Loop
```zig
// Replace manual pipeline binding
try pipeline_system.bindPipeline(command_buffer, pipeline_id);

// Replace manual descriptor updates
try resource_binder.updateFrame(frame_index);
```

## Compute Pipeline Specifics

### Workgroup Dispatch
```zig
// Old way: Manual workgroup calculation
const workgroup_size = 64;
const workgroups = (particle_count + workgroup_size - 1) / workgroup_size;
vkd.cmdDispatch(command_buffer, workgroups, 1, 1);

// New way: Can be abstracted further
pub fn dispatchCompute(self: *UnifiedPipelineSystem, command_buffer: vk.CommandBuffer, 
                      pipeline_id: PipelineId, x: u32, y: u32, z: u32) void {
    self.graphics_context.vkd.cmdDispatch(command_buffer, x, y, z);
}
```

### Memory Barriers
```zig
// The unified system can provide helpers for common barrier patterns
pub fn insertComputeToVertexBarrier(self: *UnifiedPipelineSystem, command_buffer: vk.CommandBuffer) void {
    const barrier = vk.MemoryBarrier{
        .src_access_mask = .{ .shader_write_bit = true },
        .dst_access_mask = .{ .vertex_attribute_read_bit = true },
    };
    
    self.graphics_context.vkd.cmdPipelineBarrier(
        command_buffer,
        .{ .compute_shader_bit = true },
        .{ .vertex_input_bit = true },
        .{}, 1, @ptrCast(&barrier), 0, null, 0, null
    );
}
```

## Testing and Validation

### Debug Features
```zig
// The unified system provides debug information
if (builtin.mode == .Debug) {
    const bound_resources = resource_binder.getBoundUniformBuffer(pipeline_id, set, binding, frame_index);
    if (bound_resources == null) {
        log(.WARN, "Missing resource binding: pipeline={s}, set={}, binding={}", 
            .{pipeline_id.name, set, binding});
    }
}
```

### Performance Monitoring
```zig
// Track pipeline usage statistics
pub fn getPipelineStats(self: *UnifiedPipelineSystem, pipeline_id: PipelineId) PipelineStats {
    return PipelineStats{
        .bind_count = self.getPipelineBindCount(pipeline_id),
        .resource_updates = self.getResourceUpdateCount(pipeline_id),
        .hot_reload_count = self.getHotReloadCount(pipeline_id),
    };
}
```

## 2025-10-21 Progress Log: ECS-Driven Particle Uploads

- Introduced `src/ecs/particle_system.zig`, seeding ECS entities with the legacy random distribution and providing a `Stage` helper that copies component data into a scratch buffer before calling `ParticleRenderer.syncFromEcs`.
- Expanded `src/ecs/bootstrap.zig` with a configurable bootstrap that owns the particle stage, exposes helpers to attach the runtime renderer, mark the stage dirty, tick it each frame, and release resources during shutdown.
- Extended `src/app.zig` to pass a shared `PARTICLE_MAX` constant into both the renderer and ECS bootstrap, attach the renderer to the ECS stage immediately after creation, invoke the new tick signature every frame (including the initial zero-delta prime), and tear the stage down during `App.deinit`.
- Updated `src/renderers/particle_renderer.zig` with `syncFromEcs` and `uploadParticleData` so ECS-driven particle snapshots upload through a single staging buffer pass, reusing descriptor dirtying to ensure compute bindings refresh automatically.
- Verified the migration step with `zig build`, confirming the project compiles after wiring ECS particle data into the renderer.

This migration demonstrates how the unified system simplifies particle rendering while providing better performance, maintainability, and developer experience.