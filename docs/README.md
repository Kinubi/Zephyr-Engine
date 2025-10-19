# ZulkanZengine Documentation

This directory contains technical documentation for the ZulkanZengine rendering system.

## Pipeline & Rendering Systems

### Core Systems

- **[Pipeline Caching](PIPELINE_CACHING.md)** ✅ *Updated: Oct 2025*
  - Persistent Vulkan pipeline cache for faster startup times
  - Automatic load/save of compiled pipelines
  - ~66% improvement in pipeline creation on subsequent launches
  - Fully integrated with UnifiedPipelineSystem
  - **Quick Start**: See [Pipeline Caching Quick Reference](PIPELINE_CACHING_QUICK_REF.md)

- **[Unified Pipeline Migration Guide](UNIFIED_PIPELINE_MIGRATION.md)** 
  - Migration from fragmented pipeline/descriptor systems to unified approach
  - Automatic descriptor layout extraction from shaders
  - Hot-reload integration
  - Resource binding patterns and best practices

- **[Dynamic Pipeline System](DYNAMIC_PIPELINE_SYSTEM.md)**
  - Real-time pipeline creation and hot reloading
  - Template-based pipeline configuration
  - Shader change detection and automatic rebuilds
  - Integration with GenericRenderer

### Specialized Systems

- **[Render Pass Vulkan Integration](RENDER_PASS_VULKAN_INTEGRATION.md)**
  - Current swapchain-driven render pass flow
  - How renderers coordinate begin/end with the swapchain
  - Guidance for adding bespoke off-screen passes

- **[Particle Renderer Migration](PARTICLE_RENDERER_MIGRATION.md)**
  - Unified particle system using compute and render pipelines
  - Migration from old particle system
  - GPU-based particle simulation

## Threading & Asset Systems

- **[Enhanced Thread Pool](ENHANCED_THREAD_POOL.md)**
  - Multi-subsystem thread pool architecture
  - Work item prioritization and scheduling
  - Hot reload, BVH building, and asset loading integration
  
- **[Enhanced Thread Pool Summary](ENHANCED_THREAD_POOL_SUMMARY.md)**
  - Quick reference for thread pool usage
  - Subsystem configuration
  - Performance considerations

- **[Enhanced Asset Management](ENHANCED_ASSET_MANAGEMENT.md)**
  - Asynchronous asset loading system
  - Thread pool integration
  - GPU resource management

## Gameplay & ECS

- **[ECS System](ECS_SYSTEM.md)** ✅ *Updated: Oct 2025*
  - Entity lifecycle, component storage, and scheduler overview
  - Job-based system execution and multithreaded guard sharing
  - Stage metrics, renderer extraction flow, and extension points

## System Status

| System | Status | Last Updated |
|--------|--------|--------------|
| Pipeline Caching | ✅ Complete | Oct 16, 2025 |
| Unified Pipeline System | ✅ Complete | - |
| Dynamic Pipelines | ✅ Complete | - |
| Enhanced Thread Pool | ✅ Complete | - |
| Enhanced Asset Management | ✅ Complete | - |
| Particle Renderer | ✅ Complete | - |
| Render Pass Integration Notes | ✅ Complete | Oct 19, 2025 |
| ECS System | ✅ Complete | Oct 19, 2025 |

## Quick Start

### For New Developers

1. Start with **[Unified Pipeline Migration Guide](UNIFIED_PIPELINE_MIGRATION.md)** to understand the core pipeline system
2. Read **[Pipeline Caching Quick Reference](PIPELINE_CACHING_QUICK_REF.md)** for instant performance boost
3. Check **[Dynamic Pipeline System](DYNAMIC_PIPELINE_SYSTEM.md)** for hot-reload capabilities

### For Existing Developers

If you're updating old code:
1. See **[Unified Pipeline Migration Guide](UNIFIED_PIPELINE_MIGRATION.md)** for migration patterns
2. Review **[Enhanced Thread Pool Summary](ENHANCED_THREAD_POOL_SUMMARY.md)** for threading changes
3. Check **[Enhanced Asset Management](ENHANCED_ASSET_MANAGEMENT.md)** for asset system updates

## Recent Changes

### October 16, 2025
- ✅ **Pipeline Caching System** - Implemented persistent Vulkan pipeline cache
  - Automatic cache load on startup
  - Automatic cache save on shutdown
  - ~66% faster pipeline creation with cache
  - Disk serialization to `cache/unified_pipeline_cache.bin`
  - Full integration with UnifiedPipelineSystem and PipelineBuilder

### Recent TODO Completions
- ✅ Pipeline hashing and caching implementation
- ✅ Vulkan pipeline cache disk serialization
- ✅ PipelineBuilder cache integration

### Active TODOs (18 remaining)
See main repository for current TODO list. Major categories:
- Particle system improvements (emission, buffer management)
- Per-object uniform buffer management
- Raytracing pipeline completion
- Frustum culling implementation
- Scene data extraction improvements

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
