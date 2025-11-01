# Zephyr-Engine Documentation Index

Quick navigation to all documentation. Each system has full docs (📖) and/or quick reference (⚡).

## 🎯 Quick Start

**New to Zephyr-Engine?** Start here:
1. [Development Roadmap](ROADMAP.md) - Current status and milestones
2. [ECS System](ECS_SYSTEM.md) - Core architecture
3. [Asset System](ASSET_SYSTEM.md) - Loading resources
4. [RenderGraph System](RENDER_GRAPH_SYSTEM.md) - Rendering pipeline

## 📚 Complete System Index

### Core Systems

| System | Full Docs | Quick Ref | Description |
|--------|-----------|-----------|-------------|
| **ECS** | [📖](ECS_SYSTEM.md) | [⚡](ECS_QUICK_REFERENCE.md) | Entity-component-system architecture |
| **Asset Manager** | [📖](ASSET_SYSTEM.md) | ⏳ | Async asset loading and hot-reload |
| **Thread Pool** | [📖](ENHANCED_THREAD_POOL.md) | ⏳ | Multi-subsystem work-stealing threads |
| **Threaded Rendering** | [📖](THREADED_RENDERING_DESIGN.md) | ⏳ | Parallel rendering architecture |

### Rendering Systems

| System | Full Docs | Quick Ref | Description |
|--------|-----------|-----------|-------------|
| **RenderGraph** | [📖](RENDER_GRAPH_SYSTEM.md) | [⚡](RENDER_GRAPH_QUICK_REF.md) | Render pass coordination |
| **Particle System** | [📖](PARTICLE_SYSTEM.md) | [⚡](PARTICLE_SYSTEM_QUICK_REF.md) | GPU particle simulation |
| **Lighting** | [📖](LIGHTING_SYSTEM.md) | ⏳ | Instanced light volumes |
| **Path Tracing** | [📖](PATH_TRACING_INTEGRATION.md) | ⏳ | Hardware ray tracing |
| **Unified Pipeline** | [📖](UNIFIED_PIPELINE_MIGRATION.md) | ⏳ | Pipeline creation and hot-reload |
| **Pipeline Caching** | ⏳ | [⚡](PIPELINE_CACHING_QUICK_REF.md) | Pipeline cache system |

### Camera & Scene

| System | Full Docs | Quick Ref | Description |
|--------|-----------|-----------|-------------|
| **Camera** | [📖](CAMERA_SYSTEM.md) | [⚡](CAMERA_SYSTEM_QUICK_REF.md) | Camera and movement controller |
| **Scene** | ⏳ | ⏳ | Scene v2 and GameObject v2 *(needs docs)* |

### Infrastructure (Needs Documentation)

| System | Status | Description |
|--------|--------|-------------|
| **Buffer System** | ⏳ | GPU memory and UBO management |
| **Descriptor System** | ⏳ | Descriptor sets and resource binding |
| **Graphics Context** | ⏳ | Vulkan device and command buffers |
| **UI System** | ⏳ | ImGui integration |
| **Shader System** | Partial | Shader compilation *(in Asset docs)* |
| **Texture System** | Partial | Texture loading *(in Asset docs)* |

## 🔍 By Topic

### Getting Started
- [Roadmap](ROADMAP.md) - Project status
- [ECS Quick Reference](ECS_QUICK_REFERENCE.md) - Component basics
- [Camera Quick Reference](CAMERA_SYSTEM_QUICK_REF.md) - Camera controls

### Rendering
- [RenderGraph](RENDER_GRAPH_SYSTEM.md) - Pass coordination
- [Lighting](LIGHTING_SYSTEM.md) - Light volumes
- [Particles](PARTICLE_SYSTEM.md) - GPU particles
- [Path Tracing](PATH_TRACING_INTEGRATION.md) - Ray tracing

### Asset & Performance
- [Asset System](ASSET_SYSTEM.md) - Loading and hot-reload
- [Thread Pool](ENHANCED_THREAD_POOL.md) - Parallel work
- [Pipeline Caching](PIPELINE_CACHING_QUICK_REF.md) - Startup optimization

### Development
- [Threaded Rendering Design](THREADED_RENDERING_DESIGN.md) - Future parallelization
- [Systems TODO](SYSTEMS_TODO.md) - Documentation priorities

### Editor & UI
- [Editor UI & Scripting](EDITOR_SCRIPTING_UI.md) - Editor scripting workflow, drag & drop, inspector editor, and icons

## 📋 Quick References Only

Fast lookups without reading full docs:
- [ECS Quick Reference](ECS_QUICK_REFERENCE.md)
- [RenderGraph Quick Reference](RENDER_GRAPH_QUICK_REF.md)
- [Particle System Quick Reference](PARTICLE_SYSTEM_QUICK_REF.md)
- [Camera Quick Reference](CAMERA_SYSTEM_QUICK_REF.md)
- [Pipeline Caching Quick Reference](PIPELINE_CACHING_QUICK_REF.md)

## 🗂️ By File Location

```
docs/
├── README.md                              ← Main index (you are here)
├── INDEX.md                               ← This file
├── ROADMAP.md                             ← Development roadmap
├── SYSTEMS_TODO.md                        ← Documentation priorities
├── DOCUMENTATION_CLEANUP_SUMMARY.md       ← Recent changes
│
├── Core Systems
│   ├── ECS_SYSTEM.md
│   ├── ECS_QUICK_REFERENCE.md
│   ├── ASSET_SYSTEM.md
│   ├── ENHANCED_THREAD_POOL.md
│   └── THREADED_RENDERING_DESIGN.md
│
├── Rendering Systems
│   ├── RENDER_GRAPH_SYSTEM.md             ✨ NEW
│   ├── RENDER_GRAPH_QUICK_REF.md          ✨ NEW
│   ├── PARTICLE_SYSTEM.md                 ✨ NEW
│   ├── PARTICLE_SYSTEM_QUICK_REF.md       ✨ NEW
│   ├── LIGHTING_SYSTEM.md
│   ├── PATH_TRACING_INTEGRATION.md
│   ├── UNIFIED_PIPELINE_MIGRATION.md
│   └── PIPELINE_CACHING_QUICK_REF.md
│
├── Camera & Scene
│   ├── CAMERA_SYSTEM.md                   ✨ NEW
│   └── CAMERA_SYSTEM_QUICK_REF.md         ✨ NEW
│
└── archive/                               ← Old/outdated docs
```

## 🎓 Learning Paths

### Path 1: Rendering Engineer
1. [ECS System](ECS_SYSTEM.md) - Understand data flow
2. [RenderGraph System](RENDER_GRAPH_SYSTEM.md) - Pass architecture
3. [Unified Pipeline](UNIFIED_PIPELINE_MIGRATION.md) - Pipeline creation
4. [Path Tracing](PATH_TRACING_INTEGRATION.md) - Ray tracing
5. [Threaded Rendering](THREADED_RENDERING_DESIGN.md) - Optimization

### Path 2: Gameplay Programmer
1. [ECS Quick Reference](ECS_QUICK_REFERENCE.md) - Component usage
2. [Camera Quick Reference](CAMERA_SYSTEM_QUICK_REF.md) - Camera controls
3. [Particle Quick Reference](PARTICLE_SYSTEM_QUICK_REF.md) - Effects
4. [Asset System](ASSET_SYSTEM.md) - Resource loading

### Path 3: Engine Developer
1. [Roadmap](ROADMAP.md) - Current status
2. [ECS System](ECS_SYSTEM.md) - Core architecture
3. [Thread Pool](ENHANCED_THREAD_POOL.md) - Parallelization
4. [Asset System](ASSET_SYSTEM.md) - Resource management
5. [Systems TODO](SYSTEMS_TODO.md) - What needs work

## 📊 Documentation Status

- ✅ **11 systems** fully documented
- ⏳ **5 systems** partially documented (in other docs)
- 📋 **5 systems** need documentation

See [SYSTEMS_TODO.md](SYSTEMS_TODO.md) for detailed tracking.

## 🔗 External Resources

- [Vulkan Specification](https://www.khronos.org/vulkan/)
- [Vulkan Guide](https://github.com/KhronosGroup/Vulkan-Guide)
- [Zig Language Reference](https://ziglang.org/documentation/master/)

---

*Last Updated: October 24, 2025*
