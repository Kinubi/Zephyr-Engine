# ZulkanZengine

A modern, high-performance game engine built in Zig with Vulkan, featuring an Entity Component System (ECS), path tracing, and advanced asset management.

## Architecture Overview

ZulkanZengine features a modern architecture consisting of three main pillars:

### 🧩 **Entity Component System (ECS)** ✅ IMPLEMENTED
- **Data-Oriented Design**: Components stored in packed arrays for optimal cache performance
- **Flexible Queries**: Efficient iteration over entities with specific component combinations  
- **System Architecture**: Modular systems (Transform, RenderSystem, etc.)
- **Hierarchical Transforms**: Parent-child relationships with world matrix propagation
- **Performance**: Scales to thousands of entities with minimal overhead

### 🗂️ **Asset Manager** ✅ IMPLEMENTED
- **Async Loading**: Background asset streaming with thread pool
- **Hot Reloading**: Real-time shader and asset updates without engine restart
- **Dependency Tracking**: Automatic loading and cleanup based on usage
- **Material System**: PBR materials with texture management
- **Memory Management**: Efficient caching and reference counting

### 🎨 **Unified Renderer** ✅ IMPLEMENTED
- **Path Tracing**: Hardware-accelerated ray tracing with BVH acceleration
- **Deferred Rendering**: Multi-pass rendering with G-buffer
- **Lighting Volume Pass**: Efficient point light rendering
- **RenderGraph**: Data-driven render pass management
- **Dynamic Pipeline System**: Automatic pipeline creation and caching
- **Multi-threaded BVH Building**: Asynchronous acceleration structure updates

## Current Features

### Rendering
- ✅ **Vulkan Backend**: Modern graphics API with validation layers
- ✅ **Path Tracing Pass**: Real-time ray tracing with toggle support (T key)
- ✅ **Deferred Rendering**: G-buffer with geometry and lighting passes
- ✅ **Lighting Volume Pass**: Efficient point light rendering
- ✅ **Ray Tracing System**: Hardware RT with BLAS/TLAS acceleration structures
- ✅ **Shader Hot Reload**: Real-time shader recompilation and update
- ✅ **Mesh Rendering**: OBJ model loading with materials

### ECS System
- ✅ **Core ECS**: EntityManager, World, ComponentStorage
- ✅ **Components**: Transform, MeshRenderer, Camera, Light
- ✅ **Systems**: TransformSystem (hierarchies), RenderSystem (extraction)
- ✅ **Scene Management**: Scene v2 with entity spawning and lifecycle
- ✅ **Async Asset Integration**: Automatic BVH rebuild on asset load

### Asset Pipeline
- ✅ **Asset Manager**: Centralized resource management
- ✅ **Thread Pool**: Multi-threaded asset loading with subsystems
- ✅ **File Watcher**: Automatic hot reload detection
- ✅ **Material System**: PBR materials with metallic/roughness
- ✅ **Texture Management**: Descriptor set updates and pooling
- ✅ **Scheduled Loading**: Frame-based asset streaming

### Controls
- ✅ **Camera Controller**: WASD movement, arrow key rotation
- ✅ **Path Tracing Toggle**: 'T' key switches RT/raster modes
- ✅ **Smooth Movement**: Delta-time based controls

## Removed/Deprecated
- ❌ Old Scene System (replaced with ECS Scene v2)
- ❌ GameObject/Transform classes (replaced with ECS components)
- ❌ Scene Bridge (replaced with RenderData types)
- ❌ Individual Renderers (replaced with unified RenderGraph)

## Getting Started

### Prerequisites

1. **Install the Vulkan SDK**: Download from https://vulkan.lunarg.com/sdk/home
2. **Zig 0.15.1+**: Ensure you have the latest Zig version
3. **Git**: For cloning the repository

### Setup

```sh
# Clone the repository
git clone <repository-url>
cd ZulkanZengine

# Ensure glslc is on your PATH (for shader compilation)
# On macOS, add to ~/.zprofile:
export PATH=$PATH:$HOME/VulkanSDK/1.3.xxx.0/macOS/bin/

# On Linux, add to ~/.bashrc or ~/.profile:
export PATH=$PATH:$HOME/VulkanSDK/1.3.xxx.0/x86_64/bin/
```

### Build and Run

```sh
# Build and run the engine
zig build run

# Build in release mode for performance testing
zig build run -Doptimize=ReleaseFast

# Run with validation layers (debug mode)
zig build run -Ddebug=true
```

## Project Structure

```
ZulkanZengine/
├── src/
│   ├── ecs/                      # Entity Component System ✅
│   │   ├── world.zig            # ECS World and EntityManager
│   │   ├── components/          # Transform, MeshRenderer, Camera, Light
│   │   └── systems/             # TransformSystem, RenderSystem
│   ├── scene/                   # Scene Management ✅
│   │   ├── scene_v2.zig         # ECS-based scene system
│   │   └── game_object_v2.zig   # Entity wrapper
│   ├── assets/                  # Asset Management ✅
│   │   ├── asset_manager.zig    # Central asset coordination
│   │   ├── shader_hot_reload.zig # Real-time shader updates
│   │   └── glsl_compiler.zig    # GLSL/HLSL compilation
│   ├── rendering/               # Rendering Systems ✅
│   │   ├── render_graph.zig     # Data-driven render passes
│   │   ├── passes/              # PathTracingPass, GeometryPass, etc.
│   │   ├── unified_pipeline_system.zig # Pipeline management
│   │   └── render_data_types.zig # Shared rendering structures
│   ├── systems/                 # Engine Systems ✅
│   │   ├── raytracing_system.zig # RT acceleration structures
│   │   └── multithreaded_bvh_builder.zig # Async BVH building
│   ├── threading/               # Concurrency ✅
│   │   └── thread_pool.zig      # Work-stealing thread pool
│   ├── core/                    # Vulkan Core ✅
│   │   ├── graphics_context.zig
│   │   ├── pipeline.zig
│   │   ├── swapchain.zig
│   │   └── descriptors.zig
│   └── utils/                   # Utilities
│       ├── math.zig
│       └── log.zig
├── shaders/                     # HLSL/GLSL Shaders
│   ├── RayTracingTriangle.*     # Path tracing shaders
│   ├── simple.*, textured.*     # Rasterization shaders
│   └── cached/                  # Compiled SPIR-V cache
├── docs/                        # Documentation
│   ├── PATH_TRACING_INTEGRATION.md
│   ├── ECS_SYSTEM.md
│   └── ASSET_SYSTEM_ARCHITECTURE.md
├── POC/                         # Design Documents
└── models/, textures/           # Assets
```

## Documentation

### Implementation Docs
- **[Path Tracing Integration](docs/PATH_TRACING_INTEGRATION.md)**: Light and particle integration design
- **[ECS System](docs/ECS_SYSTEM.md)**: Entity Component System architecture
- **[Asset System Architecture](docs/ASSET_SYSTEM_ARCHITECTURE.md)**: Asset management design
- **[Unified Pipeline System](docs/UNIFIED_PIPELINE_MIGRATION.md)**: Pipeline management
- **[RenderGraph Integration](docs/RENDER_PASS_VULKAN_INTEGRATION.md)**: Pass-based rendering

### Design Docs (POC)
- **[ECS Design](POC/ECS_DESIGN.md)**: Original ECS architecture proposal
- **[Asset Integration](POC/ASSET_ECS_INTEGRATION.md)**: Asset-ECS integration design
- **[Implementation Roadmap](POC/IMPLEMENTATION_ROADMAP.md)**: Development timeline

## Development Status

✅ **Phase 1 Complete**: Core ECS, Asset Manager, RenderSystem
✅ **Phase 2 Complete**: Path Tracing, Multi-threaded BVH, Hot Reload
🔄 **Phase 3 In Progress**: Light/Particle integration with path tracer

### Recent Achievements
- ✅ Path tracing pass with automatic BVH rebuilds
- ✅ Async asset loading detection and RT updates
- ✅ Cleaned up legacy scene system (removed old renderers)
- ✅ Keyboard camera controller for ECS scene
- ✅ Shader hot reload system working
- ✅ Material and texture descriptor management

### Next Steps
- 🔄 Integrate lighting volume data into path tracer (binding 7)
- 🔄 Integrate particle system into path tracer (binding 8)
- 🔄 Animation system components
- 🔄 Physics integration
- 🔄 Scene serialization

## Performance

Current performance characteristics:
- **ECS Queries**: Sub-microsecond for typical component iterations
- **Transform Hierarchies**: Efficient parent-child propagation
- **BVH Building**: Multi-threaded BLAS/TLAS construction
- **Asset Loading**: Background streaming with priority
- **Path Tracing**: Real-time RT at 1080p on RTX hardware
- **Hot Reload**: <100ms shader recompilation and update

