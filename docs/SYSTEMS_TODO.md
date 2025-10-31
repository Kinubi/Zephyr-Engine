# Systems Requiring Documentation

**Status**: October 25, 2025

This document tracks systems that are implemented but lack full documentation.

## ✅ Completed (Fully Documented Systems)

### Layer & Event System
**Status**: ✅ Implemented, ✅ Documented

**Implemented Features**:
- Layer interface with VTable pattern for polymorphism
- LayerStack for organized execution (begin/update/render/end phases)
- EventBus with event queue and category filtering
- GLFW callback integration for event generation
- Event handlers in all layers (InputLayer, SceneLayer, UILayer)
- Per-layer performance profiling (CPU time tracking)
- Runtime toggles: F1 (UI), F2 (Performance Graphs), T (Path Tracing)
- Event-driven architecture replacing direct input polling

**Documentation**:
- `docs/LAYER_EVENT_SYSTEM.md` - Full design and architecture
- `docs/LAYER_SYSTEM_QUICK_REF.md` - Quick reference guide

**Files**:
- `src/core/layer.zig` - Layer interface
- `src/core/layer_stack.zig` - Layer management
- `src/core/event.zig` - Event types
- `src/core/event_bus.zig` - Event queue and dispatching
- `src/layers/*.zig` - All layer implementations

---

## High Priority (Core Systems)

### 1. Scene System (Scene v2 + GameObject v2)
**Status**: ✅ Implemented, ⏳ Documentation Needed

**What to Document**:
- Scene v2 architecture with ECS integration
- GameObject v2 as entity wrapper
- Entity spawning and lifecycle management
- Scene serialization/deserialization
- Prefab system (if implemented)

**Files**:
- `src/scene/scene.zig`
- `src/scene/game_object_v2.zig`

### 2. Buffer System
**Status**: ✅ Implemented, ⏳ Documentation Needed

**What to Document**:
- Buffer class for GPU memory management
- Usage flags and memory properties
- Staging buffers for uploads
- UBO (Uniform Buffer Object) management
- SSBO (Shader Storage Buffer Object) patterns
- Buffer mapping and copying

**Files**:
- `src/core/buffer.zig`
- `src/rendering/ubo_set.zig`

### 3. Descriptor System
**Status**: ✅ Implemented, ⏳ Documentation Needed

**What to Document**:
- Descriptor set allocation and pooling
- Automatic layout extraction from SPIR-V
- Resource binding patterns
- Descriptor set caching
- Push constants vs descriptors

**Files**:
- `src/core/descriptors.zig`
- `src/rendering/resource_binder.zig`

### 4. Graphics Context
**Status**: ✅ Implemented, ⏳ Documentation Needed

**What to Document**:
- Vulkan device and queue management
- Command buffer allocation (primary + secondary)
- Command pool management (per-thread pools)
- Synchronization primitives (fences, semaphores)
- Memory allocation strategies
- Swapchain integration

**Files**:
- `src/core/graphics_context.zig`
- `src/core/swapchain.zig`

## Medium Priority (Supporting Systems)

### 5. UI System (ImGui)
**Status**: ✅ Implemented, ⏳ Documentation Needed

**What to Document**:
- ImGui integration with Vulkan
- Scene hierarchy panel
- Component inspector
- Performance overlays
- Custom UI widgets
- Input handling

**Files**:
- `src/ui/imgui_context.zig`
- `src/ui/imgui_backend_vulkan.zig`
- `src/ui/scene_hierarchy_panel.zig`
- `src/ui/ui_renderer.zig`

### 6. Shader System
**Status**: ✅ Implemented, ⏳ Documentation Needed (partially in Asset docs)

**What to Document**:
- GLSL/HLSL compilation to SPIR-V
- Shader reflection and metadata extraction
- Shader hot-reload mechanism
- Shader cache and validation
- Include file handling

**Files**:
- `src/assets/shader_compiler.zig`
- `src/assets/glsl_compiler.zig`
- `src/assets/shader_manager.zig`
- `src/assets/shader_hot_reload.zig`

### 7. Geometry/Mesh System
**Status**: ✅ Implemented, ⏳ Documentation Needed

**What to Document**:
- Mesh data structures (vertices, indices)
- Vertex formats (position, normal, UV, etc.)
- Mesh loading from assets
- GPU buffer management for geometry
- Instanced rendering support

**Files**:
- `src/rendering/mesh.zig`
- `src/rendering/geometry.zig`
- `src/rendering/vertex_formats.zig`

### 8. Texture System
**Status**: ✅ Implemented, ⏳ Documentation Needed (partially in Asset docs)

**What to Document**:
- Texture loading (PNG, JPG, etc.)
- Mipmap generation
- Texture sampling and filtering
- Texture arrays and atlases
- Cubemaps (if implemented)

**Files**:
- `src/core/texture.zig`

## Low Priority (Advanced Systems)

### 9. Ray Tracing System
**Status**: ✅ Implemented, ⏳ Documentation Needed (partially in Path Tracing docs)

**What to Document**:
- BLAS/TLAS building
- Async BVH construction on ThreadPool
- Shader binding table (SBT)
- Ray tracing shaders (rgen, rchit, rmiss)
- Material and texture access in RT shaders

**Files**:
- `src/systems/raytracing_system.zig`
- `src/systems/multithreaded_bvh_builder.zig`

### 10. Performance Monitor
**Status**: ✅ Implemented, ⏳ Documentation Needed

**What to Document**:
- Frame timing metrics
- GPU profiling with Vulkan queries
- Performance counters
- Statistics visualization
- Bottleneck detection

**Files**:
- `src/rendering/performance_monitor.zig`

## Documentation Template

For each system, include:

### System Overview
- Purpose and responsibilities
- Architecture diagram
- Key components

### API Reference
- Public functions and types
- Usage examples
- Common patterns

### Integration Points
- How it connects to other systems
- Dependencies
- Data flow

### Performance Characteristics
- Memory usage
- CPU/GPU overhead
- Optimization tips

### Troubleshooting
- Common issues and solutions
- Error messages explained
- Debugging tips

### Quick Reference
- One-page cheat sheet
- Code snippets
- Common patterns

## Progress Tracking

| System | Priority | Docs Started | Docs Complete | Quick Ref |
|--------|----------|--------------|---------------|-----------|
| Scene System | High | ⏳ | ⏳ | ⏳ |
| Buffer System | High | ⏳ | ⏳ | ⏳ |
| Descriptor System | High | ⏳ | ⏳ | ⏳ |
| Graphics Context | High | ⏳ | ⏳ | ⏳ |
| UI System | Medium | ⏳ | ⏳ | ⏳ |
| Shader System | Medium | Partial | ⏳ | ⏳ |
| Mesh System | Medium | ⏳ | ⏳ | ⏳ |
| Texture System | Medium | Partial | ⏳ | ⏳ |
| Ray Tracing | Low | Partial | ⏳ | ⏳ |
| Performance Monitor | Low | ⏳ | ⏳ | ⏳ |

## Next Steps

1. **Scene System** - Most visible to users, high priority
2. **Buffer + Descriptor** - Foundation for rendering, paired documentation
3. **Graphics Context** - Core infrastructure understanding
4. **UI System** - Developer tools and debugging
5. **Remaining systems** - As time permits

---

*This document will be updated as documentation is completed.*
