# ZulkanZengine Documentation

This directory contains technical documentation for the ZulkanZengine rendering system.

## Core Architecture

### ECS & Scene Management ✅ IMPLEMENTED

- **[ECS System](ECS_SYSTEM.md)** *Updated: Oct 2025*
  - Entity lifecycle, component storage, and system execution
  - Components: Transform, MeshRenderer, Camera, Light
  - Systems: TransformSystem (hierarchies), RenderSystem (extraction)
  - Scene v2 with entity spawning and lifecycle management

- **[ECS Integration Guide](ECS_INTEGRATION_GUIDE.md)**
  - Adding new components and systems
  - Query patterns and best practices
  - Performance optimization

- **[Transform Component Summary](TRANSFORM_COMPONENT_SUMMARY.md)**
  - Hierarchical transform system
  - World matrix propagation
  - Parent-child relationships

### Rendering Systems ✅ IMPLEMENTED

- **[Path Tracing Integration](PATH_TRACING_INTEGRATION.md)** *Updated: Oct 2025*
  - Real-time ray tracing pass with BVH acceleration
  - Async BVH rebuild on asset loading
  - Light and particle integration design (binding 7 & 8)
  - Toggle between RT and raster modes

- **[Unified Pipeline System](UNIFIED_PIPELINE_MIGRATION.md)** ✅ Complete
  - Centralized pipeline creation and management
  - Automatic descriptor layout extraction from shaders
  - Resource binding patterns and hot-reload integration

- **[Pipeline Caching](PIPELINE_CACHING.md)** ✅ Complete
  - Persistent Vulkan pipeline cache (~66% faster startup)
  - Automatic load/save of compiled pipelines
  - **Quick Ref**: [Pipeline Caching Quick Reference](PIPELINE_CACHING_QUICK_REF.md)

- **[Render Pass Vulkan Integration](RENDER_PASS_VULKAN_INTEGRATION.md)**
  - RenderGraph system with data-driven passes
  - Pass coordination: GeometryPass, LightingVolumePass, PathTracingPass
  - Swapchain integration and presentation

- **[Dynamic Pipeline System](DYNAMIC_PIPELINE_SYSTEM.md)**
  - Real-time pipeline creation and hot reloading
  - Shader change detection and automatic rebuilds

### Asset & Threading Systems ✅ IMPLEMENTED

- **[Asset System Architecture](ASSET_SYSTEM_ARCHITECTURE.md)**
  - AssetManager with thread pool integration
  - Hot reload system for shaders and assets
  - Material and texture management
  - **Quick Refs**: 
    - [Asset System Documentation](ASSET_SYSTEM_DOCUMENTATION.md)
    - [Asset System Quick Reference](ASSET_SYSTEM_QUICK_REFERENCE.md)

- **[Enhanced Thread Pool](ENHANCED_THREAD_POOL.md)**
  - Multi-subsystem work-stealing thread pool
  - Subsystems: hot_reload, bvh_building, asset_loading
  - Work item prioritization and scheduling
  - **Quick Ref**: [Thread Pool Summary](ENHANCED_THREAD_POOL_SUMMARY.md)

- **[Lighting System](LIGHTING_SYSTEM.md)**
  - Point light management
  - Lighting volume pass integration

## System Status

| System | Status | Last Updated |
|--------|--------|--------------|
| ECS Core | ✅ Complete | Oct 22, 2025 |
| Scene v2 | ✅ Complete | Oct 22, 2025 |
| Path Tracing Pass | ✅ Complete | Oct 22, 2025 |
| RenderGraph | ✅ Complete | Oct 22, 2025 |
| Asset Manager | ✅ Complete | Oct 22, 2025 |
| Hot Reload System | ✅ Complete | Oct 22, 2025 |
| Thread Pool | ✅ Complete | Oct 16, 2025 |
| Pipeline Caching | ✅ Complete | Oct 16, 2025 |
| Multi-threaded BVH | ✅ Complete | Oct 22, 2025 |
| Camera Controller | ✅ Complete | Oct 22, 2025 |

## Recent Major Changes

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

### For New Developers

1. **ECS Basics**: Start with [ECS System](ECS_SYSTEM.md) to understand entity-component architecture
2. **Scene Setup**: Read [ECS Integration Guide](ECS_INTEGRATION_GUIDE.md) for adding entities
3. **Rendering**: Check [Path Tracing Integration](PATH_TRACING_INTEGRATION.md) for RT rendering
4. **Assets**: See [Asset System Quick Reference](ASSET_SYSTEM_QUICK_REFERENCE.md) for loading models

### For Rendering Work

1. **Pipeline System**: [Unified Pipeline Migration](UNIFIED_PIPELINE_MIGRATION.md)
2. **Caching**: [Pipeline Caching Quick Reference](PIPELINE_CACHING_QUICK_REF.md)
3. **Passes**: [Render Pass Vulkan Integration](RENDER_PASS_VULKAN_INTEGRATION.md)
4. **RT**: [Path Tracing Integration](PATH_TRACING_INTEGRATION.md)

### For Asset/Threading Work

1. **Asset System**: [Asset System Architecture](ASSET_SYSTEM_ARCHITECTURE.md)
2. **Threading**: [Enhanced Thread Pool Summary](ENHANCED_THREAD_POOL_SUMMARY.md)
3. **Hot Reload**: Check shader_hot_reload.zig implementation

## Contributing

When adding new systems or features:

1. **Create Documentation**: Add a new `.md` file in this directory
2. **Update This Index**: Add your document to the appropriate section above
3. **Cross-Reference**: Link to related documents using relative paths
4. **Include Examples**: Show practical usage with code snippets
5. **Document Status**: Mark completion status and update dates

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
├── README.md                              ← You are here
├── PIPELINE_CACHING.md                    ← New: Persistent cache system (detailed)
├── PIPELINE_CACHING_QUICK_REF.md          ← New: Quick reference card
├── UNIFIED_PIPELINE_MIGRATION.md          ← Pipeline system guide
├── DYNAMIC_PIPELINE_SYSTEM.md             ← Dynamic pipelines
├── RENDER_PASS_VULKAN_INTEGRATION.md      ← Swapchain render-pass guidance
├── PARTICLE_RENDERER_MIGRATION.md         ← Particle system
├── ENHANCED_THREAD_POOL.md                ← Threading details
├── ENHANCED_THREAD_POOL_SUMMARY.md        ← Threading quick ref
└── ENHANCED_ASSET_MANAGEMENT.md           ← Asset loading
```

## External Resources

- [Vulkan Specification](https://www.khronos.org/vulkan/)
- [Vulkan Guide](https://github.com/KhronosGroup/Vulkan-Guide)
- [Zig Language Reference](https://ziglang.org/documentation/master/)

---

*For questions or clarifications, please refer to the source code or create an issue in the repository.*
