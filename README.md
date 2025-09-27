# ZulkanZengine

A modern, high-performance game engine built in Zig with Vulkan, featuring an Entity Component System (ECS) and advanced asset management.

## Architecture Overview

ZulkanZengine is being enhanced with a modern architecture consisting of three main pillars:

### 🧩 **Entity Component System (ECS)**
- **Data-Oriented Design**: Components stored in packed arrays for optimal cache performance
- **Flexible Queries**: Efficient iteration over entities with specific component combinations  
- **System Architecture**: Modular systems for transforms, rendering, animation, and physics
- **Performance**: Scales to thousands of entities with minimal overhead

### 🗂️ **Asset Manager** 
- **Dependency Tracking**: Automatic loading and cleanup based on entity usage
- **Hot Reloading**: Real-time asset updates without engine restart
- **Async Loading**: Background asset streaming with priority management
- **Memory Management**: LRU caching and reference counting for optimal memory usage

### 🎨 **Unified Renderer**
- **Multi-Pass Rendering**: Deferred and forward rendering with automatic selection
- **Batching & Culling**: Automatic optimization based on material and spatial locality  
- **Ray Tracing**: Hardware-accelerated ray tracing for lighting and reflections
- **Compute Shaders**: GPU-based particle systems and post-processing effects

## Current Features

- ✅ **Vulkan Backend**: Modern graphics API with validation layers
- ✅ **Mesh Rendering**: OBJ model loading with PBR materials
- ✅ **Lighting System**: Point lights with shadow mapping
- ✅ **Ray Tracing**: Hardware ray tracing for enhanced visuals
- ✅ **Particle Systems**: GPU-based particle rendering
- ✅ **Asset Pipeline**: Texture and material management

## Planned Features (ECS Integration)

- 🔄 **Component System**: Transform, MeshRenderer, Camera, Light, Animation components
- 🔄 **Scene Management**: Hierarchical transforms and scene serialization
- 🔄 **Animation System**: Skeletal animation and blend trees
- 🔄 **Physics Integration**: Component-based physics bodies and collision
- 🔄 **Audio System**: 3D positional audio components
- 🔄 **Scripting**: Hot-reloadable game logic components

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
├── POC/                    # Design documents and proposals
│   ├── ECS_DESIGN.md      # Entity Component System architecture
│   ├── ASSET_ECS_INTEGRATION.md  # Asset Manager + ECS integration
│   └── ENHANCED_SCENE_SYSTEM.md  # Overall system design
├── src/                    # Source code
│   ├── ecs/               # Entity Component System (planned)
│   ├── assets/            # Asset Manager (planned) 
│   ├── renderers/         # Rendering systems
│   ├── systems/           # Core engine systems
│   └── utils/             # Utility functions
├── shaders/               # HLSL shaders for ray tracing and rasterization
├── models/                # 3D model assets
├── textures/              # Texture assets
└── build.zig              # Zig build configuration
```

## Documentation

- **[ECS Design](POC/ECS_DESIGN.md)**: Comprehensive Entity Component System architecture
- **[Asset Integration](POC/ASSET_ECS_INTEGRATION.md)**: How assets work with ECS entities  
- **[Enhanced Scene System](POC/ENHANCED_SCENE_SYSTEM.md)**: Overall engine architecture
- **[Implementation Roadmap](POC/IMPLEMENTATION_ROADMAP.md)**: Development phases and timeline

## Development Status

The engine is currently transitioning from a traditional object-oriented architecture to a modern ECS-based system. See the [Implementation Roadmap](POC/IMPLEMENTATION_ROADMAP.md) for detailed progress.

### Current Phase: ECS Foundation
- [ ] Core ECS implementation (EntityManager, World, ComponentStorage)
- [ ] Basic components (Transform, MeshRenderer, Camera)
- [ ] System architecture and registration
- [ ] Asset Manager integration with ECS

## Contributing

This is an active development project. The architecture documentation in the `POC/` folder describes the target system we're building towards.

## Performance Goals

- **10,000+ entities** with transform hierarchies at 60 FPS
- **Sub-millisecond** component queries and system updates
- **Automatic batching** for render calls with same material
- **Hot asset reloading** with minimal frame time impact
- **Memory efficiency** through packed component storage

