# ZulkanZengine Development Roadmap

**Last Updated**: October 24, 2025  
**Branch**: features/threaded-rendering

## Current Status: Phase 3 - Performance Optimization

### ✅ Phase 1: Core Foundation (COMPLETE)

**Status**: 🟢 **Production Ready**

#### ECS Foundation
- ✅ EntityRegistry with generational IDs
- ✅ DenseSet component storage (cache-friendly)
- ✅ World management with parallel queries
- ✅ Components: Transform, MeshRenderer, Camera, PointLight, ParticleComponent
- ✅ Systems: TransformSystem (hierarchies), RenderSystem (extraction), LightSystem
- ✅ Scene v2 with GameObject v2 wrapper
- ✅ 62 tests passing

#### Asset Management
- ✅ AssetManager with ThreadPool integration
- ✅ Async loading with priorities (critical/high/normal/low)
- ✅ Hot-reload via FileWatcher and HotReloadManager
- ✅ Material and texture descriptor management
- ✅ Fallback asset system

#### Rendering Pipeline
- ✅ UnifiedPipelineSystem (shader reflection, automatic descriptors)
- ✅ Pipeline caching (~66% faster startup)
- ✅ RenderGraph architecture
- ✅ Dynamic rendering (Vulkan 1.3)
- ✅ Shader hot-reload integration

#### Thread Pool
- ✅ Multi-subsystem work-stealing pool
- ✅ Subsystems: hot_reload, bvh_building, ecs_update, asset_loading
- ✅ Priority-based scheduling
- ✅ Per-thread command pools for GPU work

---

### ✅ Phase 2: Advanced Rendering (COMPLETE)

**Status**: 🟢 **Production Ready**

#### Path Tracing
- ✅ Ray tracing pass with TLAS/BLAS
- ✅ Async BVH building on ThreadPool
- ✅ Automatic geometry detection and rebuild
- ✅ Light integration (binding 7)
- ✅ Toggle with 'T' key

#### Render Passes
- ✅ GeometryPass (rasterization)
- ✅ LightVolumePass (instanced rendering, 128 lights, 1 draw call)
- ✅ PathTracingPass (ray tracing)
- ✅ ParticlePass (rendering)
- ✅ ParticleComputePass (GPU simulation)

#### Camera System
- ✅ Keyboard movement controller (WASD)
- ✅ Arrow key rotation
- ✅ Delta-time based smooth controls
- ✅ Direct ECS camera manipulation

---

### 🔄 Phase 3: Performance Optimization (IN PROGRESS)

**Status**: 🟡 **Active Development** - October 24, 2025

#### Render Pass Optimizations ✅ COMPLETE
- ✅ **LightVolumePass**: Instanced rendering (N draw calls → 1 draw call)
  - SSBO-based light data (128 light capacity)
  - Billboard rendering with gl_InstanceIndex
  - 95% reduction in draw calls
  
- ✅ **GeometryPass**: Pipeline layout caching
  - Eliminates per-frame hashmap lookup
  - Removed runtime visibility checks (moved to TODO for culling system)
  
- ✅ **PathTracingPass**: Image transition optimization
  - Reduced from 4 to 2 transitions per frame (50% reduction)
  - Output texture stays in GENERAL layout
  
- ✅ **ParticleComputePass**: Early exit optimization
  - Skips barriers and buffer copy when no particles active
  - Zero GPU work for empty particle systems

#### Threaded Rendering 🚧 IN DESIGN

**Design Document**: `THREADED_RENDERING_DESIGN.md`

**Phase 3.1: Parallel ECS Extraction** ⏳ Not Started
- Parallel queries for Transform + MeshRenderer
- Chunk-based work distribution
- Lock-free result collection
- Target: 3x speedup on 8-core CPU

**Phase 3.2: Cache Building** ⏳ Not Started
- Parallel cache construction (pipeline layout, vertex buffers)
- Frustum culling during cache build
- Target: 2x speedup for cache operations

**Phase 3.3: Secondary Command Buffers** ⏳ Optional
- ⚠️ Infrastructure ready in GraphicsContext (thread pools, command pools)
- ⚠️ Needs enhancement for dynamic rendering inheritance
- Decision gate: Only if >500 draw calls per frame
- Target: 2x speedup in command recording

**Performance Projections**:
- Current: 60 FPS (16.7ms/frame)
- After Phase 3.1+3.2: 74 FPS (13.5ms)
- After Phase 3.3: 87 FPS (11.5ms) [if applicable]

---

### 📋 Phase 4: Advanced Features (PLANNED)

**Status**: ⚪ **Not Started**

#### Rendering Enhancements
- [ ] Frustum culling (CPU-side)
- [ ] Occlusion culling (GPU-side)
- [ ] Distance-based LOD system
- [ ] Shadow mapping (for rasterization path)
- [ ] Volumetric light scattering
- [ ] Post-processing pipeline (bloom, tonemapping, FXAA)

#### ECS Enhancements
- [ ] Multi-component queries (Transform + MeshRenderer + Custom)
- [ ] Event system for component changes
- [ ] Archetype storage (SoA optimization)
- [ ] Prefab system for entity templates
- [ ] Entity serialization/deserialization

#### Asset System Enhancements
- [ ] GLTF/GLB model support
- [ ] Compressed texture formats (BC7, ASTC)
- [ ] Streaming for large assets (mip levels, LODs)
- [ ] Asset bundles/packaging
- [ ] Reference counting and automatic unloading
- [ ] Memory budget management

#### Advanced Ray Tracing
- [ ] Multiple bounces (currently 1 bounce)
- [ ] Importance sampling for lights
- [ ] Temporal accumulation for denoising
- [ ] Adaptive sampling
- [ ] Russian roulette path termination

---

## Recent Milestones

### October 24, 2025
- ✅ Render pass optimizations (5 high-impact improvements)
- ✅ Instanced light volume rendering
- ✅ Documentation overhaul (19 files deleted/archived, 2 created)
- ✅ Threaded rendering design document (60 pages)

### October 22, 2025
- ✅ Legacy cleanup (Scene, GameObject, SceneBridge, GenericRenderer removed)
- ✅ Camera controller implementation
- ✅ Path tracing logging cleanup
- ✅ RenderSystem refactor to use render_data_types

### October 21, 2025
- ✅ Phase 2 ECS foundation complete (62 tests)
- ✅ All core components implemented
- ✅ TransformSystem and RenderSystem operational

### October 16, 2025
- ✅ Pipeline caching system (~66% startup improvement)
- ✅ ThreadPool multi-subsystem support

---

## Performance Metrics

### Current Performance (Baseline)
- **Frame Time**: ~16.7ms (60 FPS)
- **CPU Time**: ~12ms
  - ECS Extraction: 4.5ms
  - Cache Building: 2ms
  - Command Recording: 3ms
  - Other: 2.5ms
- **GPU Time**: ~8ms

### Target Performance (After Phase 3)
- **Frame Time**: ~11.5ms (87 FPS)
- **CPU Time**: ~7ms (-42% from baseline)
  - ECS Extraction: 1.5ms (3x faster)
  - Cache Building: 1ms (2x faster)
  - Command Recording: 1.5ms (2x faster)
  - Other: 3ms
- **GPU Time**: ~8ms (unchanged)

### Scalability
| CPU Cores | Current FPS | Target FPS | Improvement |
|-----------|-------------|------------|-------------|
| 4 cores   | 60 FPS      | 72 FPS     | +12 FPS     |
| 8 cores   | 60 FPS      | 87 FPS     | +27 FPS     |
| 16 cores  | 60 FPS      | 90 FPS     | +30 FPS     |

---

## Technical Debt

### High Priority
- [ ] Frustum culling (currently all objects rendered)
- [ ] Memory profiling and leak detection
- [ ] GPU memory budget tracking
- [ ] Error handling standardization

### Medium Priority
- [ ] Cross-platform file watching (currently Linux-only)
- [ ] More comprehensive unit tests
- [ ] Shader validation in CI/CD
- [ ] Performance regression tests

### Low Priority
- [ ] Code documentation (inline comments)
- [ ] API documentation generation
- [ ] Example scenes and tutorials
- [ ] Editor/tooling integration

---

## System Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                        Application                          │
├─────────────────────────────────────────────────────────────┤
│                         ECS World                           │
│  (Entities, Components, Systems, Scene v2)                  │
├─────────────────────────────────────────────────────────────┤
│                       RenderGraph                           │
│  ┌──────────────┐ ┌──────────────┐ ┌──────────────┐        │
│  │ GeometryPass │ │LightVolumePass│ │PathTracingPass│       │
│  └──────────────┘ └──────────────┘ └──────────────┘        │
├─────────────────────────────────────────────────────────────┤
│              UnifiedPipelineSystem                          │
│  (Shader Reflection, Pipeline Caching, Hot-Reload)         │
├─────────────────────────────────────────────────────────────┤
│                    Asset Manager                            │
│  (Async Loading, Hot-Reload, Materials, Textures)          │
├─────────────────────────────────────────────────────────────┤
│                    ThreadPool                               │
│  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐          │
│  │ hot_reload  │ │bvh_building │ │asset_loading│          │
│  └─────────────┘ └─────────────┘ └─────────────┘          │
├─────────────────────────────────────────────────────────────┤
│                  Graphics Context                           │
│  (Vulkan, Command Buffers, Secondary Buffers)              │
└─────────────────────────────────────────────────────────────┘
```

---

## Documentation Status

### Current Documentation (10 files)
1. ✅ `README.md` - Main index
2. ✅ `ASSET_SYSTEM.md` - Asset management API
3. ✅ `ECS_SYSTEM.md` - ECS architecture
4. ✅ `ECS_QUICK_REFERENCE.md` - Component patterns
5. ✅ `ENHANCED_THREAD_POOL.md` - Threading system
6. ✅ `LIGHTING_SYSTEM.md` - Light volume rendering
7. ✅ `PATH_TRACING_INTEGRATION.md` - Ray tracing
8. ✅ `PIPELINE_CACHING_QUICK_REF.md` - Pipeline caching
9. ✅ `UNIFIED_PIPELINE_MIGRATION.md` - Pipeline system
10. ✅ `THREADED_RENDERING_DESIGN.md` - Threading roadmap

### Archived Documentation (9 files)
- Historical milestones and migration guides preserved in `docs/archive/`

---

**For Questions or Contributions**: See individual system documentation files for detailed API references and usage patterns.
