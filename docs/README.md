# ZulkanZengine Documentation

This directory contains technical documentation for the ZulkanZengine rendering system.

📑 **[Complete Documentation Index](INDEX.md)** - Quick navigation to all docs

## Core Architecture

### ECS & Scene Management ✅ IMPLEMENTED

- **[ECS System](ECS_SYSTEM.md)** *Updated: Oct 2025*
  - Entity lifecycle, component storage, and system execution
  - Components: Transform, MeshRenderer, Camera, Light
  - Systems: TransformSystem (hierarchies), RenderSystem (extraction)
  - Scene v2 with entity spawning and lifecycle management

- **[ECS Quick Reference](ECS_QUICK_REFERENCE.md)**
  - Component initialization and usage
  - Query patterns and iteration
  - System registration

### Rendering Systems ✅ IMPLEMENTED

- **[RenderGraph System](RENDER_GRAPH_SYSTEM.md)** *New: Oct 24, 2025*
  - Data-driven render pass coordination
  - Pass management: GeometryPass, LightVolumePass, PathTracingPass, ParticlePass
  - Resource registry and execution ordering
  - **[Quick Reference](RENDER_GRAPH_QUICK_REF.md)**

- **[Path Tracing Integration](PATH_TRACING_INTEGRATION.md)** *Updated: Oct 2025*
  - Real-time ray tracing pass with BVH acceleration
  - Async BVH rebuild on asset loading
  - Light and particle integration design (binding 7 & 8)
  - Toggle between RT and raster modes

- **[Lighting System](LIGHTING_SYSTEM.md)** *Updated: Oct 24, 2025*
  - Point light ECS components
  - Instanced light volume rendering (128 lights, 1 draw call)
  - Billboard visualization with SSBO-based rendering

- **[Particle System](PARTICLE_SYSTEM.md)** *New: Oct 24, 2025*
  - GPU-driven particle simulation via compute shaders
  - ParticleComputePass (physics) + ParticlePass (rendering)
  - ECS ParticleEmitter component with emission control
  - **[Quick Reference](PARTICLE_SYSTEM_QUICK_REF.md)**

- **[Unified Pipeline System](UNIFIED_PIPELINE_MIGRATION.md)** ✅ Complete
  - Centralized pipeline creation and management
  - Automatic descriptor layout extraction from shaders
  - Resource binding patterns and hot-reload integration

- **[Pipeline Caching](PIPELINE_CACHING_QUICK_REF.md)** ✅ Complete
  - Persistent Vulkan pipeline cache (~66% faster startup)
  - Automatic load/save of compiled pipelines

### Camera & Scene Systems ✅ IMPLEMENTED

- **[Camera System](CAMERA_SYSTEM.md)** *New: Oct 24, 2025*
  - Legacy Camera class and ECS Camera component
  - Perspective and orthographic projections
  - KeyboardMovementController (WASD + arrow keys)
  - **[Quick Reference](CAMERA_SYSTEM_QUICK_REF.md)**

- **[Unified Pipeline System](UNIFIED_PIPELINE_MIGRATION.md)** ✅ Complete
  - Centralized pipeline creation with shader reflection
  - Automatic descriptor layout extraction
  - Pipeline hot-reloading on shader changes
  - Persistent pipeline caching (~66% startup improvement)

### Asset & Threading Systems ✅ IMPLEMENTED

- **[Asset System](ASSET_SYSTEM.md)** *Updated: Oct 24, 2025*
  - AssetManager with async loading and priorities
  - Hot-reload integration via FileWatcher
  - Material and texture descriptor management
  - ThreadPool integration for parallel asset loading

- **[Enhanced Thread Pool](ENHANCED_THREAD_POOL.md)** ✅ Complete
  - Multi-subsystem work-stealing thread pool
  - Subsystems: hot_reload, bvh_building, ecs_update, asset_loading
  - Work item prioritization and scheduling
  - Per-thread command pools for secondary command buffers

- **[Threaded Rendering Design](THREADED_RENDERING_DESIGN.md)** *New: Oct 24, 2025*
  - Parallel ECS extraction and cache building
  - Secondary command buffer infrastructure (in GraphicsContext)
  - 3-phase implementation roadmap
  - Performance projections (60 FPS → 87 FPS on 8-core)



## System Status

| System | Documentation | Status | Last Updated |
|--------|---------------|--------|--------------|
| ECS Core | ✅ [Docs](ECS_SYSTEM.md) + [Quick Ref](ECS_QUICK_REFERENCE.md) | ✅ Complete | Oct 22, 2025 |
| Scene v2 (GameObject v2) | ⏳ Planned | ✅ Complete | Oct 22, 2025 |
| RenderGraph | ✅ [Docs](RENDER_GRAPH_SYSTEM.md) + [Quick Ref](RENDER_GRAPH_QUICK_REF.md) | ✅ Complete | Oct 24, 2025 |
| Path Tracing Pass | ✅ [Docs](PATH_TRACING_INTEGRATION.md) | ✅ Complete | Oct 22, 2025 |
| Particle System | ✅ [Docs](PARTICLE_SYSTEM.md) + [Quick Ref](PARTICLE_SYSTEM_QUICK_REF.md) | ✅ Complete | Oct 24, 2025 |
| Lighting System | ✅ [Docs](LIGHTING_SYSTEM.md) | ✅ Complete | Oct 24, 2025 |
| Camera System | ✅ [Docs](CAMERA_SYSTEM.md) + [Quick Ref](CAMERA_SYSTEM_QUICK_REF.md) | ✅ Complete | Oct 24, 2025 |
| Unified Pipeline System | ✅ [Docs](UNIFIED_PIPELINE_MIGRATION.md) | ✅ Complete | Oct 22, 2025 |
| Pipeline Caching | ✅ [Quick Ref](PIPELINE_CACHING_QUICK_REF.md) | ✅ Complete | Oct 16, 2025 |
| Asset Manager | ✅ [Docs](ASSET_SYSTEM.md) | ✅ Complete | Oct 22, 2025 |
| Thread Pool | ✅ [Docs](ENHANCED_THREAD_POOL.md) | ✅ Complete | Oct 16, 2025 |
| Hot Reload System | ⏳ In Asset Docs | ✅ Complete | Oct 22, 2025 |
| Multi-threaded BVH | ⏳ In Path Tracing Docs | ✅ Complete | Oct 22, 2025 |
| Buffer System | ⏳ Planned | ✅ Complete | Oct 24, 2025 |
| Descriptor System | ⏳ Planned | ✅ Complete | Oct 24, 2025 |
| Graphics Context | ⏳ Planned | ✅ Complete | Oct 24, 2025 |
| UI System (ImGui) | ⏳ Planned | ✅ Complete | Oct 24, 2025 |
| Secondary Command Buffers | ⏳ In Threaded Rendering | ⚠️ Infrastructure Ready | Oct 24, 2025 |

## Recent Major Changes

### October 24, 2025 - Render Pass Optimizations & Documentation Overhaul
- ✅ **Instanced Light Volume Rendering**
  - Replaced per-light push constants with SSBO + instancing
  - 128 light capacity, single draw call (95% reduction in draw calls)
  - Billboard visualization with camera-facing quads

- ✅ **Render Pass Optimizations** (5 high-impact optimizations)
  - GeometryPass: Cached pipeline layout, removed visibility checks
  - PathTracingPass: Reduced image transitions from 4 to 2 per frame
  - ParticleComputePass: Early exit when no particles active
  - LightVolumePass: Instanced rendering with SSBO

- ✅ **Documentation Overhaul** (Massive cleanup)
  - **Deleted** (12): Inaccurate asset docs, DYNAMIC_PIPELINE_SYSTEM, RENDER_PASS_VULKAN_INTEGRATION, redundant summaries
  - **Archived** (9): POC/ directory, IMPLEMENTATION_ROADMAP, ECS_INTEGRATION_GUIDE, milestone summaries
  - **Updated**: LIGHTING_SYSTEM.md for instanced LightVolumePass
  - **Created**: ASSET_SYSTEM.md, THREADED_RENDERING_DESIGN.md, ROADMAP.md
  - **Final**: 10 accurate, consolidated documentation files

### October 22, 2025 - Legacy Cleanup & Camera Controller
- ✅ **Removed Legacy Systems**
  - Deleted old Scene, GameObject, SceneBridge
  - Removed old renderers (TexturedRenderer, EcsRenderer, PointLightRenderer, etc.)
  - Cleaned up render_system to use render_data_types instead of SceneBridge
  
- ✅ **Camera Controller Implementation**
  - WASD movement, arrow key rotation
  - Direct camera manipulation for ECS scene
  - Smooth delta-time based controls

- ✅ **Path Tracing Logging Cleanup**
  - Removed verbose frame-by-frame logs
  - Kept only critical warnings and errors

### October 2025 - Path Tracing & BVH
- ✅ **PathTracingPass Implementation**
  - 7 descriptor bindings (TLAS, output, camera, vertices, indices, materials, textures)
  - Automatic BVH rebuild detection from async asset loading
  - Toggle with 'T' key, automatic geometry pass disable
  - Manual descriptor set binding for proper validation

- ✅ **Async Asset Detection**
  - Mesh asset ID tracking in RenderSystem
  - Detects when async loads complete
  - Triggers BVH rebuild automatically

### Recent TODO Completions
- ✅ Pipeline hashing and caching implementation
- ✅ Vulkan pipeline cache disk serialization
- ✅ PipelineBuilder cache integration

### October 16, 2025 - Pipeline Caching
- ✅ **Pipeline Caching System**
  - Automatic cache load/save
  - ~66% faster pipeline creation with cache
  - Disk serialization to `cache/unified_pipeline_cache.bin`

## Quick Start

### 📍 Project Roadmap
**Start here**: [Development Roadmap](ROADMAP.md) - Current status, completed milestones, performance metrics

### For New Developers

1. **Architecture Overview**: [Development Roadmap](ROADMAP.md)
2. **ECS Basics**: [ECS System](ECS_SYSTEM.md) + [ECS Quick Reference](ECS_QUICK_REFERENCE.md)
3. **Asset Loading**: [Asset System](ASSET_SYSTEM.md)
4. **Rendering**: [Path Tracing Integration](PATH_TRACING_INTEGRATION.md)

### For Rendering Work

1. **RenderGraph**: [Render Graph System](RENDER_GRAPH_SYSTEM.md) + [Quick Ref](RENDER_GRAPH_QUICK_REF.md)
2. **Pipeline System**: [Unified Pipeline Migration](UNIFIED_PIPELINE_MIGRATION.md)
3. **Caching**: [Pipeline Caching](PIPELINE_CACHING_QUICK_REF.md)
4. **Lighting**: [Lighting System](LIGHTING_SYSTEM.md)
5. **Particles**: [Particle System](PARTICLE_SYSTEM.md) + [Quick Ref](PARTICLE_SYSTEM_QUICK_REF.md)
6. **Ray Tracing**: [Path Tracing Integration](PATH_TRACING_INTEGRATION.md)
7. **Camera**: [Camera System](CAMERA_SYSTEM.md) + [Quick Ref](CAMERA_SYSTEM_QUICK_REF.md)
8. **Threading**: [Threaded Rendering Design](THREADED_RENDERING_DESIGN.md)

### For Asset/Threading Work

1. **Asset System**: [Asset System](ASSET_SYSTEM.md)
2. **Threading**: [Enhanced Thread Pool](ENHANCED_THREAD_POOL.md)
3. **Hot Reload**: Integrated in AssetManager and ShaderManager

## Contributing

When adding new documentation:

## Documentation Style Guide

- Use clear, descriptive titles
- Include code examples for all major features
- Provide migration guides when changing existing APIs
- Mark implementation status (✅ Complete, 🔄 In Progress, ⏳ Planned)
- Update "Last Updated" dates when making significant changes
- Include troubleshooting sections for complex systems
- Cross-reference related documents

## File Organization

```
docs/
├── README.md                              ← You are here (index of all systems)
├── ROADMAP.md                             ← Development roadmap and milestones
│
├── Core Systems
│   ├── ECS_SYSTEM.md                      ← ECS architecture and implementation
│   ├── ECS_QUICK_REFERENCE.md             ← Quick reference for ECS usage
│   ├── ASSET_SYSTEM.md                    ← Asset loading and management
│   ├── ENHANCED_THREAD_POOL.md            ← Multi-subsystem thread pool
│   └── THREADED_RENDERING_DESIGN.md       ← Parallel rendering architecture
│
├── Rendering Systems
│   ├── RENDER_GRAPH_SYSTEM.md             ← Render pass coordination
│   ├── RENDER_GRAPH_QUICK_REF.md          ← RenderGraph quick reference
│   ├── UNIFIED_PIPELINE_MIGRATION.md      ← Pipeline creation and hot-reload
│   ├── PIPELINE_CACHING_QUICK_REF.md      ← Pipeline cache quick reference
│   ├── PATH_TRACING_INTEGRATION.md        ← Ray tracing integration
│   ├── LIGHTING_SYSTEM.md                 ← Light volumes and instanced rendering
│   ├── PARTICLE_SYSTEM.md                 ← GPU particle simulation
│   └── PARTICLE_SYSTEM_QUICK_REF.md       ← Particle system quick reference
│
├── Camera & Scene
│   ├── CAMERA_SYSTEM.md                   ← Camera and movement controller
│   └── CAMERA_SYSTEM_QUICK_REF.md         ← Camera quick reference
│
└── archive/                               ← Archived/outdated documentation
```

## External Resources

- [Vulkan Specification](https://www.khronos.org/vulkan/)
- [Vulkan Guide](https://github.com/KhronosGroup/Vulkan-Guide)
- [Zig Language Reference](https://ziglang.org/documentation/master/)

---

*For questions or clarifications, please refer to the source code or create an issue in the repository.*
