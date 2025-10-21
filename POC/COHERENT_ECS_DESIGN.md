# Coherent ECS Architecture for ZulkanZengine

**Date**: October 21, 2025  
**Status**: Design Specification  
**Based On**: SIMPLE_ECS_v2.md + Current ZulkanZengine Architecture

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Design Principles](#design-principles)
3. [Architecture Overview](#architecture-overview)
4. [Core Components](#core-components)
5. [Component Contract](#component-contract)
6. [Integration with Existing Systems](#integration-with-existing-systems)
7. [Detailed API Reference](#detailed-api-reference)
8. [Implementation Phases](#implementation-phases)
9. [Examples & Usage Patterns](#examples--usage-patterns)
10. [Performance Considerations](#performance-considerations)
11. [Migration Guide](#migration-guide)

---

## Executive Summary

This document defines a **coherent ECS architecture** that cleanly integrates with ZulkanZengine's existing:
- **Unified Pipeline System** (UnifiedPipelineSystem, ResourceBinder)
- **Asset Management** (AssetManager, ShaderManager)
- **Thread Pool** (ThreadPool with subsystem-based scheduling)
- **Scene Bridge** (SceneBridge for renderer data extraction)

### Key Design Goals

1. **Components own their logic**: Each component type provides `update()` and `render()` methods
2. **No central scheduler**: Dispatch is explicit via `World.updateComponents()` and `World.renderComponents()`
3. **EnTT-style views**: Ergonomic iteration with `view.each()` and `view.each_parallel()`
4. **ThreadPool integration**: Parallel dispatch uses existing ThreadPool infrastructure
5. **Clean separation**: ECS manages gameplay/simulation data; renderers consume extracted data

### What This Fixes

**Current Problems:**
- `particle_system.zig` acts as a "stage" that bridges ECS → Renderer, mixing concerns
- Components are just data with no behavior
- No clear pattern for where update/render logic lives
- Confusing lifecycle (who calls what, when?)

**New Approach:**
- Components are **self-contained** with update/render methods
- ECS World provides **explicit dispatch**: `world.updateComponents(Velocity, dt)` 
- Renderers **extract** data from ECS components during render phase
- Clear ownership: ECS owns game state, Renderers own GPU resources

---

## Entities vs Components: Core Concept

**Entities** are just **IDs** (handles) - they have no data themselves. Think of them as "things that exist in your game world."

**Components** are **data + behavior** that you attach to entities. Think of them as "properties that entities can have."

### The Pattern:

```zig
// 1. Create an entity (just an ID - no data)
const player = world.createEntity();  // player = EntityId(12345)

// 2. Attach components TO that entity
try world.emplace(Position, player, .{ .x = 10, .y = 20 });
try world.emplace(Velocity, player, .{ .x = 1, .y = 0 });
try world.emplace(Health, player, .{ .value = 100 });

// 3. Later, query components BY entity
const pos = world.get(Position, player);  // Get Position for entity 12345
const vel = world.get(Velocity, player);  // Get Velocity for entity 12345
```

### Storage Layout:

```
Entity Registry (just IDs):
  EntityId(1) -> valid (generation=0)
  EntityId(2) -> valid (generation=0)
  EntityId(3) -> valid (generation=1)

Position Storage (DenseSet<Position>):
  EntityId(1) -> Position{ x=10, y=20 }
  EntityId(2) -> Position{ x=5, y=15 }

Velocity Storage (DenseSet<Velocity>):
  EntityId(1) -> Velocity{ x=1, y=0 }
  // EntityId(2) has no Velocity!

Health Storage (DenseSet<Health>):
  EntityId(3) -> Health{ value=50 }
```

**Key Insight**: Entities are like **database row IDs**, components are like **columns** - but in ECS, not every entity needs every component (sparse data).

---

## Design Principles

### 1. **Components Are Behavior + Data**

Each component type is a plain struct with:
- Data fields (position, velocity, color, etc.)
- `update(self: *T, dt: f32)` method for simulation
- `render(self: *const T, context: RenderContext)` method for rendering

```zig
pub const ParticleComponent = struct {
    position: [2]f32,
    velocity: [2]f32,
    color: [4]f32,
    
    pub fn update(self: *ParticleComponent, dt: f32) void {
        self.position[0] += self.velocity[0] * dt;
        self.position[1] += self.velocity[1] * dt;
    }
    
    pub fn render(self: *const ParticleComponent, context: RenderContext) void {
        // Queue this particle's data for GPU upload
        context.particle_batch.append(self.*) catch {};
    }
};
```

### 2. **Explicit Dispatch, No Hidden Scheduler**

The ECS World does NOT automatically call update/render. Instead:

```zig
// In your game loop:
try world.updateComponents(ParticleComponent, dt);  // Calls update() on all particles
try world.renderComponents(ParticleComponent, render_ctx);  // Calls render() on all particles
```

This makes the execution flow **crystal clear** and **debuggable**.

### 3. **View-Based Iteration (EnTT Style)**

Access components through type-safe views:

```zig
const view = try world.view(ParticleComponent);

// Serial iteration
view.each(struct {
    fn call(entity: EntityId, particle: *ParticleComponent) void {
        particle.update(0.016);
    }
}.call);

// Parallel iteration (uses ThreadPool)
try view.each_parallel(64, struct {  // chunk_size = 64
    fn call(entities: []EntityId, particles: []ParticleComponent, dt: f32) void {
        for (particles) |*p| p.update(dt);
    }
}.call, dt);
```

### 4. **ThreadPool Integration**

Parallel dispatch creates chunk jobs submitted to the existing ThreadPool:

```zig
// Internal implementation of each_parallel:
pub fn each_parallel(
    self: *View(T),
    chunk_size: usize,
    callback: fn([]EntityId, []T, f32) void,
    dt: f32,
) !void {
    const total = self.storage.len();
    const num_chunks = (total + chunk_size - 1) / chunk_size;
    
    for (0..num_chunks) |i| {
        const start = i * chunk_size;
        const end = @min(start + chunk_size, total);
        
        const job = try self.allocator.create(ChunkJob(T));
        job.* = .{
            .entities = self.entities[start..end],
            .components = self.components[start..end],
            .callback = callback,
            .dt = dt,
        };
        
        const work = WorkItem{
            .data = .{ .custom = .{
                .user_data = @ptrCast(job),
                .work_fn = chunk_worker,
            }},
        };
        
        try thread_pool.submitWork(work);
    }
    
    // Wait for all chunks to complete
    try thread_pool.waitForIdle();
}
```

### 5. **Renderer Integration via Extraction**

Renderers don't directly access ECS components. Instead:

1. **Simulation Phase**: `world.updateComponents()` runs game logic
2. **Extraction Phase**: Components populate render-friendly buffers
3. **Render Phase**: Renderers consume pre-extracted data

```zig
// Example: ParticleRenderer extracts data during render()
pub fn render(self: *const ParticleComponent, context: RenderContext) void {
    // Extract to flat array for GPU upload
    const batch = &context.particle_batch;
    try batch.append(.{
        .position = self.position,
        .velocity = self.velocity,
        .color = self.color,
    });
}

// Later, ParticleRenderer uploads the batch to GPU:
pub fn flushParticleBatch(renderer: *ParticleRenderer, batch: []Particle) !void {
    try renderer.uploadParticleData(batch);
}
```

---

## Architecture Overview

### High-Level Structure

```
┌─────────────────────────────────────────────────────────────┐
│                        Application                           │
│  ┌───────────────────────────────────────────────────────┐  │
│  │                    Game Loop                          │  │
│  │  1. world.updateComponents(Velocity, dt)             │  │
│  │  2. world.updateComponents(Transform, dt)            │  │
│  │  3. world.renderComponents(ParticleComponent, ctx)   │  │
│  │  4. renderer.flushParticleBatch(ctx.particle_batch)  │  │
│  │  5. renderer.render(frame_info)                      │  │
│  └───────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
        ┌───────────────────────────────────────┐
        │           ECS World                    │
        │  ┌─────────────────────────────────┐  │
        │  │  Entity Registry                │  │
        │  │  - create() → EntityId          │  │
        │  │  - destroy(EntityId)            │  │
        │  └─────────────────────────────────┘  │
        │  ┌─────────────────────────────────┐  │
        │  │  Component Storages             │  │
        │  │  - DenseSet<Velocity>           │  │
        │  │  - DenseSet<Transform>          │  │
        │  │  - DenseSet<ParticleComponent>  │  │
        │  └─────────────────────────────────┘  │
        │  ┌─────────────────────────────────┐  │
        │  │  View Factory                   │  │
        │  │  - view(T) → View<T>            │  │
        │  └─────────────────────────────────┘  │
        └───────────────────────────────────────┘
                            │
                            ▼
        ┌───────────────────────────────────────┐
        │         ThreadPool                     │
        │  Parallel chunk jobs for:              │
        │  - Component update()                  │
        │  - Component render()                  │
        └───────────────────────────────────────┘
                            │
                            ▼
        ┌───────────────────────────────────────┐
        │      Renderers (Existing)              │
        │  - ParticleRenderer                    │
        │  - TexturedRenderer                    │
        │  - PointLightRenderer                  │
        │  Consume extracted render data         │
        └───────────────────────────────────────┘
```

### Data Flow

```
┌──────────────┐    ┌──────────────┐    ┌──────────────┐
│   Entities   │───▶│  Components  │───▶│  Renderers   │
│  (Handles)   │    │ (Simulation) │    │  (GPU Work)  │
└──────────────┘    └──────────────┘    └──────────────┘
       │                    │                    │
       │                    │                    │
       ▼                    ▼                    ▼
  create/destroy       update/render       upload/draw
  (World)              (Component)         (Renderer)
```

### Particle System Data Flow (GPU Compute)

```
┌────────────────────────────────────────────────────────────────┐
│                        Frame N                                  │
│                                                                  │
│  1. ECS Update (CPU - Parallel)                                │
│     ┌─────────────────────────────────────────┐                │
│     │ ParticleComponent.update(dt)            │                │
│     │ - Decrease lifetime                     │                │
│     │ - Mark dead particles                   │                │
│     │ - Spawn new particles (if needed)       │                │
│     └─────────────────────────────────────────┘                │
│                        ↓                                        │
│  2. ECS Extraction (CPU - Serial)                              │
│     ┌─────────────────────────────────────────┐                │
│     │ ParticleComponent.render(context)       │                │
│     │ - Append to particle_batch              │                │
│     │ - Filter out dead particles             │                │
│     └─────────────────────────────────────────┘                │
│                        ↓                                        │
│  3. GPU Upload (Transfer)                                      │
│     ┌─────────────────────────────────────────┐                │
│     │ particle_renderer.uploadAndSimulate()   │                │
│     │ - Upload batch to GPU buffers           │                │
│     │ - Update compute uniforms (dt, gravity) │                │
│     └─────────────────────────────────────────┘                │
│                        ↓                                        │
│  4. GPU Compute (Physics Simulation)                           │
│     ┌─────────────────────────────────────────┐                │
│     │ shaders/particles.comp                  │                │
│     │ - Read from particle_buffer_in          │                │
│     │ - Apply velocity, gravity, collisions   │                │
│     │ - Write to particle_buffer_out          │                │
│     └─────────────────────────────────────────┘                │
│                        ↓                                        │
│  5. Copy Back (for next frame)                                 │
│     ┌─────────────────────────────────────────┐                │
│     │ cmdCopyBuffer(out → in)                 │                │
│     └─────────────────────────────────────────┘                │
│                        ↓                                        │
│  6. GPU Render (Draw Pass)                                     │
│     ┌─────────────────────────────────────────┐                │
│     │ particle_renderer.render()              │                │
│     │ - Bind particle_buffer_in as VBO        │                │
│     │ - Draw particles as GL_POINTS           │                │
│     └─────────────────────────────────────────┘                │
│                                                                  │
└────────────────────────────────────────────────────────────────┘

Key:
CPU Work:   ECS update/extraction (Steps 1-2)
Transfer:   CPU → GPU data upload (Step 3)
GPU Work:   Compute simulation (Step 4) + Rendering (Step 6)
```

**Why This Hybrid Approach?**
- **CPU (ECS)**: Manages spawning, lifetime, high-level logic
- **GPU (Compute)**: Handles expensive physics (1000s of particles)
- **Best of Both**: Flexible spawning + fast simulation

---

## Core Components

### 1. **EntityId**

Opaque handle to an entity. Internally uses generational indices:

```zig
pub const EntityId = enum(u32) {
    invalid = 0,
    _,
    
    pub fn generation(self: EntityId) u16 {
        return @intCast((@intFromEnum(self) >> 16) & 0xFFFF);
    }
    
    pub fn index(self: EntityId) u16 {
        return @intCast(@intFromEnum(self) & 0xFFFF);
    }
};
```

### 2. **DenseSet(T)** - Component Storage

Sparse set optimized for cache-friendly iteration:

```zig
pub fn DenseSet(comptime T: type) type {
    return struct {
        const Self = @This();
        
        // Dense arrays (contiguous)
        entities: std.ArrayList(EntityId),
        components: std.ArrayList(T),
        
        // Sparse mapping (entity → dense index)
        sparse: std.AutoHashMap(EntityId, u32),
        
        allocator: std.mem.Allocator,
        
        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .entities = std.ArrayList(EntityId).init(allocator),
                .components = std.ArrayList(T).init(allocator),
                .sparse = std.AutoHashMap(EntityId, u32).init(allocator),
                .allocator = allocator,
            };
        }
        
        pub fn emplace(self: *Self, entity: EntityId, value: T) !void {
            const dense_idx: u32 = @intCast(self.components.items.len);
            try self.entities.append(entity);
            try self.components.append(value);
            try self.sparse.put(entity, dense_idx);
        }
        
        pub fn get(self: *Self, entity: EntityId) ?*T {
            const idx = self.sparse.get(entity) orelse return null;
            return &self.components.items[idx];
        }
        
        pub fn remove(self: *Self, entity: EntityId) bool {
            const idx = self.sparse.get(entity) orelse return false;
            
            // Swap-remove to maintain dense packing
            const last_idx = self.components.items.len - 1;
            if (idx != last_idx) {
                self.components.items[idx] = self.components.items[last_idx];
                self.entities.items[idx] = self.entities.items[last_idx];
                // Update sparse index for swapped entity
                try self.sparse.put(self.entities.items[idx], idx);
            }
            
            _ = self.components.pop();
            _ = self.entities.pop();
            _ = self.sparse.remove(entity);
            
            return true;
        }
        
        pub fn len(self: *const Self) usize {
            return self.components.items.len;
        }
    };
}
```

### 3. **World** - ECS Registry

Central registry managing entities and component storages:

```zig
pub const World = struct {
    allocator: std.mem.Allocator,
    thread_pool: *ThreadPool,
    
    // Entity management
    entity_registry: EntityRegistry,
    
    // Component storages (type-erased)
    storages: std.StringHashMap(*anyopaque),
    storage_metadata: std.StringHashMap(StorageMetadata),
    
    pub fn init(allocator: std.mem.Allocator, thread_pool: *ThreadPool) !World {
        return .{
            .allocator = allocator,
            .thread_pool = thread_pool,
            .entity_registry = EntityRegistry.init(allocator),
            .storages = std.StringHashMap(*anyopaque).init(allocator),
            .storage_metadata = std.StringHashMap(StorageMetadata).init(allocator),
        };
    }
    
    pub fn deinit(self: *World) void {
        // Deinitialize all storages
        var it = self.storages.iterator();
        while (it.next()) |entry| {
            const metadata = self.storage_metadata.get(entry.key_ptr.*).?;
            metadata.deinit_fn(entry.value_ptr.*);
        }
        
        self.storages.deinit();
        self.storage_metadata.deinit();
        self.entity_registry.deinit();
    }
    
    // Create a new entity
    pub fn createEntity(self: *World) EntityId {
        return self.entity_registry.create();
    }
    
    // Destroy an entity and remove all its components
    pub fn destroyEntity(self: *World, entity: EntityId) void {
        // Remove from all storages
        var it = self.storages.iterator();
        while (it.next()) |entry| {
            const metadata = self.storage_metadata.get(entry.key_ptr.*).?;
            metadata.remove_fn(entry.value_ptr.*, entity);
        }
        
        self.entity_registry.destroy(entity);
    }
    
    // Register a component type (call once per type)
    pub fn registerComponent(self: *World, comptime T: type) !void {
        const type_name = @typeName(T);
        
        if (self.storages.contains(type_name)) return; // Already registered
        
        const storage = try self.allocator.create(DenseSet(T));
        storage.* = DenseSet(T).init(self.allocator);
        
        try self.storages.put(type_name, storage);
        try self.storage_metadata.put(type_name, StorageMetadata{
            .deinit_fn = struct {
                fn call(ptr: *anyopaque) void {
                    const s: *DenseSet(T) = @ptrCast(@alignCast(ptr));
                    s.deinit();
                }
            }.call,
            .remove_fn = struct {
                fn call(ptr: *anyopaque, entity: EntityId) void {
                    const s: *DenseSet(T) = @ptrCast(@alignCast(ptr));
                    _ = s.remove(entity);
                }
            }.call,
        });
    }
    
    // Add a component to an entity
    pub fn emplace(self: *World, comptime T: type, entity: EntityId, value: T) !void {
        const type_name = @typeName(T);
        const storage_ptr = self.storages.get(type_name) orelse return error.ComponentNotRegistered;
        const storage: *DenseSet(T) = @ptrCast(@alignCast(storage_ptr));
        try storage.emplace(entity, value);
    }
    
    // Get a component from an entity
    pub fn get(self: *World, comptime T: type, entity: EntityId) ?*T {
        const type_name = @typeName(T);
        const storage_ptr = self.storages.get(type_name) orelse return null;
        const storage: *DenseSet(T) = @ptrCast(@alignCast(storage_ptr));
        return storage.get(entity);
    }
    
    // Remove a component from an entity
    pub fn remove(self: *World, comptime T: type, entity: EntityId) bool {
        const type_name = @typeName(T);
        const storage_ptr = self.storages.get(type_name) orelse return false;
        const storage: *DenseSet(T) = @ptrCast(@alignCast(storage_ptr));
        return storage.remove(entity);
    }
    
    // Get a view for iterating components
    pub fn view(self: *World, comptime T: type) !View(T) {
        const type_name = @typeName(T);
        const storage_ptr = self.storages.get(type_name) orelse return error.ComponentNotRegistered;
        const storage: *DenseSet(T) = @ptrCast(@alignCast(storage_ptr));
        
        return View(T){
            .storage = storage,
            .thread_pool = self.thread_pool,
            .allocator = self.allocator,
        };
    }
    
    // Dispatch update() on all components of type T
    pub fn update(self: *World, comptime T: type, dt: f32) !void {
        comptime {
            if (!@hasDecl(T, "update")) {
                @compileError(@typeName(T) ++ " must implement update(self: *T, dt: f32)");
            }
        }
        
        var v = try self.view(T);
        try v.each_parallel(256, struct {
            fn call(entities: []EntityId, components: []T, delta: f32) void {
                _ = entities;
                for (components) |*comp| {
                    comp.update(delta);
                }
            }
        }.call, dt);
    }
    
    // Dispatch render() on all components of type T
    pub fn render(self: *World, comptime T: type, context: anytype) !void {
        comptime {
            if (!@hasDecl(T, "render")) {
                @compileError(@typeName(T) ++ " must implement render(self: *const T, context: anytype)");
            }
        }
        
        const v = try self.view(T);
        v.each(struct {
            ctx: @TypeOf(context),
            
            fn call(entity: EntityId, comp: *T) void {
                _ = entity;
                comp.render(this.ctx);
            }
        }{ .ctx = context }.call);
    }
};

const StorageMetadata = struct {
    deinit_fn: *const fn(*anyopaque) void,
    remove_fn: *const fn(*anyopaque, EntityId) void,
};
```

### 4. **View(T)** - Component Iteration

Type-safe view for iterating over components:

```zig
pub fn View(comptime T: type) type {
    return struct {
        const Self = @This();
        
        storage: *DenseSet(T),
        thread_pool: *ThreadPool,
        allocator: std.mem.Allocator,
        
        // Serial iteration with callback
        pub fn each(self: *Self, callback: fn(EntityId, *T) void) void {
            for (self.storage.entities.items, self.storage.components.items) |entity, *comp| {
                callback(entity, comp);
            }
        }
        
        // Parallel iteration with chunk-based dispatch
        pub fn each_parallel(
            self: *Self,
            chunk_size: usize,
            callback: fn([]EntityId, []T, f32) void,
            dt: f32,
        ) !void {
            const total = self.storage.len();
            if (total == 0) return;
            
            const num_chunks = (total + chunk_size - 1) / chunk_size;
            
            // Track completion
            var completion = std.atomic.Value(usize).init(num_chunks);
            
            for (0..num_chunks) |i| {
                const start = i * chunk_size;
                const end = @min(start + chunk_size, total);
                
                const job = try self.allocator.create(ChunkJob(T));
                job.* = .{
                    .entities = self.storage.entities.items[start..end],
                    .components = self.storage.components.items[start..end],
                    .callback = callback,
                    .dt = dt,
                    .completion = &completion,
                };
                
                const work = ThreadPool.createCustomWork(
                    0,  // task_id
                    @ptrCast(job),
                    @sizeOf(ChunkJob(T)),
                    .normal,  // priority
                    chunk_worker_trampoline(T),
                    @ptrCast(self.thread_pool),
                );
                
                try self.thread_pool.submitWork(work);
            }
            
            // Wait for all chunks to complete
            while (completion.load(.acquire) > 0) {
                std.Thread.yield() catch {};
            }
        }
        
        // Forward iteration (for-loop style)
        pub fn iterator(self: *Self) Iterator {
            return .{
                .entities = self.storage.entities.items,
                .components = self.storage.components.items,
                .index = 0,
            };
        }
        
        const Iterator = struct {
            entities: []EntityId,
            components: []T,
            index: usize,
            
            pub fn next(self: *Iterator) ?struct { entity: EntityId, component: *T } {
                if (self.index >= self.entities.len) return null;
                defer self.index += 1;
                return .{
                    .entity = self.entities[self.index],
                    .component = &self.components[self.index],
                };
            }
        };
    };
}

fn ChunkJob(comptime T: type) type {
    return struct {
        entities: []EntityId,
        components: []T,
        callback: fn([]EntityId, []T, f32) void,
        dt: f32,
        completion: *std.atomic.Value(usize),
    };
}

fn chunk_worker_trampoline(comptime T: type) *const fn(*anyopaque, ThreadPool.WorkItem) void {
    return struct {
        fn call(context: *anyopaque, work: ThreadPool.WorkItem) void {
            _ = context;
            const job: *ChunkJob(T) = @ptrCast(@alignCast(work.data.custom.user_data));
            
            // Execute the callback
            job.callback(job.entities, job.components, job.dt);
            
            // Signal completion
            _ = job.completion.fetchSub(1, .release);
        }
    }.call;
}
```

---

## Component Contract

Every component type MUST implement:

```zig
pub const ComponentInterface = struct {
    // Required methods:
    
    /// Update component state (simulation/gameplay logic)
    /// Called by: world.updateComponents(T, dt)
    /// Threading: May be called from worker threads in parallel
    /// Mutability: Allowed to mutate self
    pub fn update(self: *T, dt: f32) void;
    
    /// Extract/queue render data for this component
    /// Called by: world.renderComponents(T, context)
    /// Threading: Called from main thread (serial)
    /// Mutability: Should NOT mutate self (use *const T)
    pub fn render(self: *const T, context: RenderContext) void;
};
```

### Example: ParticleComponent

**NOTE:** The current ParticleRenderer uses **GPU compute shaders** for simulation. The ECS component pattern adapts to this by:
1. CPU-side components hold initial/spawning data
2. `render()` extracts data for GPU upload
3. ParticleRenderer runs compute shaders for simulation
4. Results stay on GPU for rendering

```zig
const RenderContext = struct {
    particle_batch: *std.ArrayList(vertex_formats.Particle),
};

pub const ParticleComponent = struct {
    position: [2]f32,
    velocity: [2]f32,
    color: [4]f32,
    lifetime: f32,
    
    pub fn init(pos: [2]f32, vel: [2]f32, color: [4]f32) ParticleComponent {
        return .{
            .position = pos,
            .velocity = vel,
            .color = color,
            .lifetime = 5.0,
        };
    }
    
    /// Update particle state (CPU-side)
    /// NOTE: For GPU-simulated particles, this just updates lifetime/spawning logic.
    /// The actual physics simulation happens in GPU compute shaders.
    pub fn update(self: *ParticleComponent, dt: f32) void {
        // Update lifetime for CPU-side culling
        self.lifetime -= dt;
        
        // For GPU-simulated particles, position/velocity updates happen in shaders
        // This method is primarily for spawning new particles, managing lifetime, etc.
    }
    
    /// Extract render data for GPU upload
    pub fn render(self: *const ParticleComponent, context: RenderContext) void {
        if (self.lifetime <= 0.0) return; // Don't upload dead particles
        
        // Add to batch for GPU upload
        // ParticleRenderer will upload this to GPU buffers
        // Compute shaders will then simulate physics
        context.particle_batch.append(.{
            .position = self.position,
            .velocity = self.velocity,
            .color = self.color,
        }) catch {};
    }
};
```

---

## Integration with Existing Systems

### 1. **UnifiedPipelineSystem & ParticleRenderer Integration**

The ECS does NOT directly interact with pipelines. Instead:

1. Components extract data during `render()`
2. Renderers consume extracted data and use UnifiedPipelineSystem
3. For particles: **GPU compute shaders handle simulation**

#### Current ParticleRenderer Architecture

The existing `ParticleRenderer` uses a dual-pipeline approach:
- **Compute Pipeline**: `shaders/particles.comp` - physics simulation on GPU
- **Graphics Pipeline**: `shaders/particles.vert/frag` - rendering particles as points

```zig
// Current ParticleRenderer structure (from src/renderers/particle_renderer.zig):
pub const ParticleRenderer = struct {
    compute_pipeline: PipelineId,    // For physics simulation
    render_pipeline: PipelineId,     // For drawing
    
    particle_buffers: [MAX_FRAMES_IN_FLIGHT]ParticleBuffers,
    // ^ Each frame has input/output buffers for ping-pong updates
    
    compute_uniform_buffers: [MAX_FRAMES_IN_FLIGHT]Buffer,
    // ^ Stores dt, gravity, spawn rate, etc.
    
    // Existing methods:
    pub fn update(frame_info, scene_bridge) !void;  // Compute pass
    pub fn render(frame_info, scene_bridge) !void;  // Draw pass
};
```

#### ECS Integration Pattern

ParticleRenderer already fits the GenericRenderer interface (`update` + `render`), so we adapt it to consume ECS data:

```zig
// MODIFIED: ParticleRenderer.update() extracts ECS data itself
pub fn update(self: *ParticleRenderer, frame_info: *const FrameInfo, scene_bridge: *SceneBridge) !bool {
    if (frame_info.compute_buffer == vk.CommandBuffer.null_handle) return false;
    
    // 1. Extract particles from ECS World (if available)
    const ecs_world = scene_bridge.getEcsWorld() orelse return false;
    
    self.particle_batch.clearRetainingCapacity();
    const ctx = RenderContext{ .particle_batch = &self.particle_batch };
    try ecs_world.render(ParticleComponent, ctx);
    
    if (self.particle_batch.items.len == 0) return false;
    
    self.particle_count = @intCast(self.particle_batch.items.len);
    
    // 2. Upload extracted particle data to GPU buffers
    try self.uploadParticleData(self.particle_batch.items);
    
    // 3. Update compute uniforms
    const compute_ubo = ComputeUniformBuffer{
        .delta_time = frame_info.dt,
        .particle_count = self.particle_count,
        .max_particles = self.max_particles,
        .gravity = .{ 0.0, -9.81, 0.0, 0.0 },
        .spawn_rate = 100.0,
    };
    self.compute_uniform_buffers[frame_info.current_frame].writeToBuffer(
        std.mem.asBytes(&compute_ubo),
        @sizeOf(ComputeUniformBuffer),
        0
    );
    
    // 4. Bind compute pipeline and dispatch shader
    const command_buffer = frame_info.compute_buffer;
    try self.pipeline_system.bindPipeline(command_buffer, self.compute_pipeline);
    try self.pipeline_system.updateDescriptorSetsForPipeline(
        self.compute_pipeline,
        frame_info.current_frame
    );
    
    const workgroups = (self.particle_count + 255) / 256;
    self.graphics_context.vkd.cmdDispatch(command_buffer, workgroups, 1, 1);
    
    // 5. Memory barrier: compute → vertex read
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
    
    // 6. Copy output → input for next frame (ping-pong)
    const buffer_size = @sizeOf(vertex_formats.Particle) * self.particle_count;
    const copy_region = vk.BufferCopy{ .src_offset = 0, .dst_offset = 0, .size = buffer_size };
    self.graphics_context.vkd.cmdCopyBuffer(
        command_buffer,
        self.particle_buffers[frame_info.current_frame].particle_buffer_out.buffer,
        self.particle_buffers[frame_info.current_frame].particle_buffer_in.buffer,
        1, @ptrCast(&copy_region)
    );
    
    return false;
}

// UNCHANGED: render() stays the same
pub fn render(self: *ParticleRenderer, frame_info: FrameInfo, scene_bridge: *SceneBridge) !void {
    if (self.particle_count == 0) return;
    
    try self.pipeline_system.bindPipeline(frame_info.command_buffer, self.render_pipeline);
    
    const vertex_buffers = [_]vk.Buffer{
        self.particle_buffers[frame_info.current_frame].particle_buffer_in.buffer
    };
    const offsets = [_]vk.DeviceSize{0};
    self.graphics_context.vkd.cmdBindVertexBuffers(
        frame_info.command_buffer, 0, 1, &vertex_buffers, &offsets
    );
    
    self.graphics_context.vkd.cmdDraw(frame_info.command_buffer, self.particle_count, 1, 0, 0);
}
```

#### SceneBridge Extension

```zig
// Add to SceneBridge for ECS World access
pub const SceneBridge = struct {
    // Existing fields...
    ecs_world: ?*ecs.World,  // Optional reference to ECS world
    
    pub fn setEcsWorld(self: *SceneBridge, world: *ecs.World) void {
        self.ecs_world = world;
    }
    
    pub fn getEcsWorld(self: *const SceneBridge) ?*ecs.World {
        return self.ecs_world;
    }
};
```

#### App.update() - Clean Integration

```zig
pub fn update(self: *App) !bool {
    const current_time = c.glfwGetTime();
    const dt = @as(f32, @floatCast(current_time - last_frame_time));
    
    frame_info.dt = dt;
    frame_info.current_frame = current_frame;
    
    // 1. Update ECS (parallel on CPU)
    try ecs_world.update(ParticleComponent, dt);
    
    // 2. Compute phase (renderers extract their own data)
    compute_shader_system.beginCompute(frame_info);
    try forward_renderer.update(&frame_info, &scene_bridge);
    // ^ ParticleRenderer.update() extracts particles from ECS internally
    compute_shader_system.endCompute(frame_info);
    
    // 3. Render phase
    try swapchain.beginFrame(frame_info);
    swapchain.beginSwapChainRenderPass(frame_info);
    
    try forward_renderer.render(frame_info, &scene_bridge);
    
    swapchain.endSwapChainRenderPass(frame_info);
    try swapchain.endFrame(frame_info, &current_frame);
    
    last_frame_time = current_time;
    return self.window.isRunning();
}
```

**Key Benefits:**
- ✅ **ECS manages spawning/lifetime**: High-level particle logic on CPU
- ✅ **GPU handles physics**: Compute shaders for performance
- ✅ **Clean separation**: ECS doesn't know about Vulkan, Renderer doesn't know about ECS internals
- ✅ **Renderer-driven extraction**: Each renderer extracts only what it needs
- ✅ **No global extraction step**: Keeps App.update() simple and clear

### 2. **AssetManager**

Components can reference assets via `AssetId`:

```zig
pub const MeshComponent = struct {
    mesh_id: AssetId,
    material_id: AssetId,
    transform: Transform,
    
    pub fn update(self: *MeshComponent, dt: f32) void {
        _ = dt;
        // No-op for static meshes
    }
    
    pub fn render(self: *const MeshComponent, context: RenderContext) void {
        // Extract render data
        context.mesh_batch.append(.{
            .mesh_id = self.mesh_id,
            .material_id = self.material_id,
            .transform = self.transform,
        }) catch {};
    }
};

// Later, in MeshRenderer:
pub fn flushEcsBatch(self: *MeshRenderer, batch: []const MeshRenderData, asset_manager: *AssetManager) !void {
    for (batch) |data| {
        const mesh = asset_manager.getMesh(data.mesh_id) orelse continue;
        const material = asset_manager.getMaterial(data.material_id) orelse continue;
        
        // Bind material, draw mesh (existing renderer code)
        try self.drawMesh(mesh, material, data.transform);
    }
}
```

### 3. **ThreadPool**

The ECS uses the existing ThreadPool for parallel dispatch:

```zig
// In World.updateComponents():
pub fn updateComponents(self: *World, comptime T: type, dt: f32) !void {
    var v = try self.view(T);
    
    // each_parallel() internally uses:
    // - thread_pool.submitWork() for each chunk
    // - Atomic completion counter for synchronization
    // - No new subsystem needed - uses existing .ecs_update subsystem
    
    try v.each_parallel(256, struct {
        fn call(entities: []EntityId, components: []T, delta: f32) void {
            _ = entities;
            for (components) |*comp| {
                comp.update(delta);
            }
        }
    }.call, dt);
}
```

### 4. **SceneBridge**

SceneBridge provides access to the ECS World for renderers:

```zig
pub const SceneBridge = struct {
    // Existing fields...
    
    // ECS World reference (set once at startup)
    ecs_world: ?*ecs.World,
    
    pub fn setEcsWorld(self: *SceneBridge, world: *ecs.World) void {
        self.ecs_world = world;
    }
    
    pub fn getEcsWorld(self: *const SceneBridge) ?*ecs.World {
        return self.ecs_world;
    }
};

// Example: MeshRenderer extracts its own data
pub fn update(self: *MeshRenderer, frame_info: FrameInfo, scene_bridge: *SceneBridge) !void {
    const ecs_world = scene_bridge.getEcsWorld() orelse return;
    
    // Extract mesh data (only what MeshRenderer needs)
    self.mesh_batch.clearRetainingCapacity();
    const ctx = RenderContext{ 
        .mesh_batch = &self.mesh_batch,
        .world = ecs_world,  // For cross-component queries (e.g., Transform)
    };
    try ecs_world.render(MeshComponent, ctx);
    
    // Proceed with rendering...
}
```

---

## Detailed API Reference

### World API

```zig
pub const World = struct {
    // Initialization
    pub fn init(allocator: std.mem.Allocator, thread_pool: *ThreadPool) !World;
    pub fn deinit(self: *World) void;
    
    // Entity management
    pub fn createEntity(self: *World) EntityId;
    pub fn destroyEntity(self: *World, entity: EntityId) void;
    pub fn isValid(self: *const World, entity: EntityId) bool;
    
    // Component registration
    pub fn registerComponent(self: *World, comptime T: type) !void;
    
    // Component operations
    pub fn emplace(self: *World, comptime T: type, entity: EntityId, value: T) !void;
    pub fn get(self: *World, comptime T: type, entity: EntityId) ?*T;
    pub fn remove(self: *World, comptime T: type, entity: EntityId) bool;
    pub fn has(self: *const World, comptime T: type, entity: EntityId) bool;
    
    // View access
    pub fn view(self: *World, comptime T: type) !View(T);
    
    // Batch dispatch (convenience)
    pub fn update(self: *World, comptime T: type, dt: f32) !void;
    pub fn render(self: *World, comptime T: type, context: anytype) !void;
};
```

### View API

```zig
pub fn View(comptime T: type) type {
    return struct {
        // Serial iteration
        pub fn each(self: *Self, callback: fn(EntityId, *T) void) void;
        
        // Parallel iteration (chunked)
        pub fn each_parallel(
            self: *Self,
            chunk_size: usize,
            callback: fn([]EntityId, []T, f32) void,
            dt: f32,
        ) !void;
        
        // Forward iteration
        pub fn iterator(self: *Self) Iterator;
        
        // Direct access
        pub fn get(self: *Self, entity: EntityId) ?*T;
        pub fn len(self: *const Self) usize;
    };
}
```

---

## Implementation Phases

### Phase 1: Core ECS Foundation ✅ COMPLETE

**Files Created:**
- ✅ `src/ecs/entity_registry.zig` - Entity ID management with generational indices
- ✅ `src/ecs/dense_set.zig` - Sparse-set component storage
- ✅ `src/ecs/world.zig` - Central registry with type-erased storages
- ✅ `src/ecs/view.zig` - Component iteration (serial only)
- ✅ `src/ecs.zig` - Public module interface

**Test Results:**
- ✅ 17 tests passing
- ✅ No memory leaks
- ✅ Can create/destroy entities
- ✅ Can register component types
- ✅ Can emplace/get/remove components
- ✅ Serial iteration works
- ✅ `world.update()` and `world.render()` dispatch working

**Usage Example:**
```zig
const ecs = @import("ecs.zig");

var world = ecs.World.init(allocator);
defer world.deinit();

try world.registerComponent(Position);

const e1 = try world.createEntity();
try world.emplace(Position, e1, .{ .x = 10, .y = 20 });

const pos = world.get(Position, e1).?;
// pos.x == 10
```

### Phase 2: Parallel Dispatch (IN PROGRESS)

**Goal:** Add parallel component iteration using ThreadPool

**Files to Update:**
- `src/ecs/view.zig` - Add `each_parallel()` with chunking
- `src/ecs/world.zig` - Update `update()` to use parallel dispatch
- Integration with existing `ThreadPool` from `src/threading/thread_pool.zig`

**Implementation Plan:**
1. Add `each_parallel()` to View that:
   - Splits components into chunks
   - Submits chunk jobs to ThreadPool
   - Uses atomic counter for completion tracking
2. Update `World.update()` to use `each_parallel()` instead of serial iteration
3. Add tests for parallel execution and correctness

**Acceptance Criteria:**
- ✅ Parallel iteration splits into configurable chunks
- ✅ ThreadPool integration works (submits jobs correctly)
- ✅ Atomic completion tracking prevents race conditions
- ✅ Parallel update uses multiple CPU cores
- ✅ Results match serial execution (correctness)

**Test:**
```zig
test "parallel component update" {
    const thread_pool = try ThreadPool.init(allocator, .{ .num_threads = 4 });
    defer thread_pool.deinit();
    
    var world = try World.init(allocator, &thread_pool);
    defer world.deinit();
    
    try world.registerComponent(Counter);
    
    // Create 1000 entities
    for (0..1000) |_| {
        const e = try world.createEntity();
        try world.emplace(Counter, e, .{ .value = 0 });
    }
    
    // Update in parallel (should use all 4 threads)
    try world.update(Counter, 0.016);
    
    // Verify all updated correctly
    var v = try world.view(Counter);
    var iter = v.iterator();
    while (iter.next()) |item| {
        try testing.expectEqual(@as(i32, 1), item.component.value);
    }
}
```

### Phase 3: Particle System Migration (Week 3)

**Files to Update:**
- `src/ecs/components/particle.zig` - NEW: ParticleComponent with update/render
- `src/app.zig` - Create ECS world, seed particles, dispatch updates
- `src/renderers/particle_renderer.zig` - Add `flushEcsBatch()`

**Acceptance Criteria:**
- Particles live as ECS components
- Update runs in parallel
- Render extracts to batch buffer
- Existing ParticleRenderer consumes batch

**Test:**
- Run app, verify particles animate
- Profile: parallel update should use multiple cores

### Phase 4: Additional Components (Week 4+)

**Files to Create:**
- `src/ecs/components/transform.zig`
- `src/ecs/components/velocity.zig`
- `src/ecs/components/mesh.zig`
- `src/ecs/components/light.zig`

**Gradual Migration:**
- Move one subsystem at a time
- Keep old code working during transition
- Compare performance before/after

---

## Examples & Usage Patterns

### Example 1: Particle System (GPU Compute Shader Integration)

**Current Architecture:** ParticleRenderer uses compute shaders for simulation. Here's how ECS integrates:

```zig
// 1. Define component (CPU-side particle state)
pub const ParticleComponent = struct {
    position: [2]f32,
    velocity: [2]f32,
    color: [4]f32,
    lifetime: f32,
    
    /// CPU-side update: manage spawning, lifetime, etc.
    /// Physics simulation happens in GPU compute shaders
    pub fn update(self: *ParticleComponent, dt: f32) void {
        self.lifetime -= dt;
        // No position/velocity update here - that's done by compute shader
    }
    
    /// Extract data for GPU upload
    pub fn render(self: *const ParticleComponent, context: RenderContext) void {
        if (self.lifetime <= 0.0) return;
        
        context.particle_batch.append(.{
            .position = self.position,
            .velocity = self.velocity,
            .color = self.color,
        }) catch {};
    }
};

// 2. In App.init():
try ecs_world.registerComponent(ParticleComponent);

// Spawn initial particles
for (0..1024) |i| {
    const e = ecs_world.createEntity();
    try ecs_world.emplace(ParticleComponent, e, ParticleComponent{
        .position = .{ random(), random() },
        .velocity = .{ random(), random() },
        .color = .{ 1, 1, 1, 1 },
        .lifetime = 5.0,
    });
}

// 3. In App.update():

// 3a. Update CPU-side state (lifetime tracking, spawning)
try ecs_world.update(ParticleComponent, dt);

// 3b. Compute phase (ParticleRenderer extracts its own data)
compute_shader_system.beginCompute(frame_info);
try forward_renderer.update(&frame_info, &scene_bridge);
// ^ Inside ParticleRenderer.update():
//   - Gets ECS world from scene_bridge
//   - Calls world.render(ParticleComponent, ctx) to extract particles
//   - Uploads to GPU and dispatches compute shader
compute_shader_system.endCompute(frame_info);

// 3c. Render phase (draw particles)
swapchain.beginSwapChainRenderPass(frame_info);
try forward_renderer.render(frame_info, &scene_bridge);
swapchain.endSwapChainRenderPass(frame_info);
```

**Key Points:**
- **ECS components**: Hold spawning data, lifetime, initial conditions
- **CPU update**: Manages high-level particle lifecycle (spawn/despawn)
- **GPU compute**: Performs actual physics simulation (position, velocity, collisions)
- **Renderer**: Orchestrates GPU upload, compute dispatch, and rendering

### Example 2: Transform Hierarchy

```zig
pub const Transform = struct {
    position: math.Vec3,
    rotation: math.Vec3,
    scale: math.Vec3,
    parent: ?EntityId,
    cached_world_matrix: math.Mat4,
    dirty: bool,
    
    pub fn update(self: *Transform, dt: f32) void {
        _ = dt;
        if (self.dirty) {
            self.recalculateMatrix();
            self.dirty = false;
        }
    }
    
    pub fn render(self: *const Transform, context: RenderContext) void {
        // Transforms themselves don't render, but child components use them
        _ = self;
        _ = context;
    }
    
    fn recalculateMatrix(self: *Transform) void {
        // Build local matrix from position/rotation/scale
        self.cached_world_matrix = math.Mat4.compose(
            self.position,
            self.rotation,
            self.scale,
        );
    }
};
```

### Example 3: Mesh Rendering

```zig
pub const MeshComponent = struct {
    mesh_id: AssetId,
    material_id: AssetId,
    entity: EntityId,  // To query Transform
    
    pub fn update(self: *MeshComponent, dt: f32) void {
        _ = self;
        _ = dt;
        // Static meshes don't update
    }
    
    pub fn render(self: *const MeshComponent, context: RenderContext) void {
        // Get transform from entity
        const transform = context.world.get(Transform, self.entity) orelse return;
        
        context.mesh_batch.append(.{
            .mesh_id = self.mesh_id,
            .material_id = self.material_id,
            .world_matrix = transform.cached_world_matrix,
        }) catch {};
    }
};
```

---

## Performance Considerations

### 1. **Chunk Size Tuning**

```zig
// Small chunks: More parallelism, higher overhead
try view.each_parallel(32, callback, dt);  // Good for heavy per-component work

// Large chunks: Less overhead, less parallelism
try view.each_parallel(256, callback, dt);  // Good for light per-component work

// Rule of thumb: chunk_size ≈ total_count / (num_threads * 4)
const recommended_chunk = world.view(T).len() / (thread_pool.worker_count * 4);
```

### 2. **Cache Locality**

DenseSet ensures components are contiguous in memory:

```
┌──────────────────────────────────────┐
│ Component 0 | Component 1 | ... | N  │  ← Cache-friendly iteration
└──────────────────────────────────────┘
```

### 3. **Avoid Locking in update()**

```zig
// BAD: Global mutex in update()
pub fn update(self: *Component, dt: f32) void {
    global_mutex.lock();
    defer global_mutex.unlock();
    // ...
}

// GOOD: No synchronization needed
pub fn update(self: *Component, dt: f32) void {
    self.value += dt;  // Only touches self
}

// GOOD: Use atomic for shared counters
pub fn update(self: *Component, dt: f32) void {
    _ = global_counter.fetchAdd(1, .monotonic);
}
```

### 4. **Batch Extraction**

```zig
// Preallocate batches to avoid repeated allocations
pub const RenderContext = struct {
    particle_batch: *std.ArrayList(Particle),
    mesh_batch: *std.ArrayList(MeshData),
    
    pub fn init(allocator: std.mem.Allocator) !RenderContext {
        var ctx: RenderContext = undefined;
        ctx.particle_batch = try allocator.create(std.ArrayList(Particle));
        ctx.particle_batch.* = std.ArrayList(Particle).init(allocator);
        try ctx.particle_batch.ensureTotalCapacity(1024);  // Preallocate
        
        // ...
        return ctx;
    }
};
```

---

## Migration Guide

### Step 1: Create ECS World (Don't Break Existing Code)

```zig
// In App.zig:
pub const App = struct {
    // Existing fields...
    scene: Scene,  // Keep this
    particle_renderer: ParticleRenderer,
    
    // NEW: Add ECS world
    ecs_world: ecs.World,
    
    pub fn init(self: *App) !void {
        // Existing init...
        
        // NEW: Initialize ECS (doesn't affect existing systems)
        self.ecs_world = try ecs.World.init(self.allocator, thread_pool);
        
        // Existing code continues...
    }
};
```

### Step 2: Register Components (Gradually)

```zig
// In App.init(), after ecs_world creation:
try self.ecs_world.registerComponent(ParticleComponent);
// ... register more as you migrate them
```

### Step 3: Dual-Mode Operation (Keep Old Code Working)

```zig
// In App.onUpdate():
pub fn onUpdate(self: *App) !bool {
    // NEW: ECS particles (run in parallel)
    if (USE_ECS_PARTICLES) {
        // 1. Update CPU-side state (lifetime tracking, spawning)
        try self.ecs_world.update(ParticleComponent, dt);
        
        // 2. Compute phase (ParticleRenderer extracts from ECS internally)
        compute_shader_system.beginCompute(frame_info);
        _ = try forward_renderer.update(&frame_info, &scene_bridge);
        compute_shader_system.endCompute(frame_info);
    }
    
    // OLD: Existing particle system (fallback for testing)
    if (USE_OLD_PARTICLES) {
        compute_shader_system.beginCompute(frame_info);
        _ = try particle_renderer.update(&frame_info, &scene_bridge);
        compute_shader_system.endCompute(frame_info);
    }
    
    // Render phase
    swapchain.beginSwapChainRenderPass(frame_info);
    
    if (USE_ECS_PARTICLES) {
        try forward_renderer.render(frame_info, &scene_bridge);
    }
    
    if (USE_OLD_PARTICLES) {
        try particle_renderer.render(frame_info, &scene_bridge);
    }
    
    swapchain.endSwapChainRenderPass(frame_info);
    
    // ...
}
```

### Step 4: Performance Comparison

```zig
const start = std.time.nanoTimestamp();

// Run ECS version
try self.ecs_world.updateComponents(ParticleComponent, dt);

const end = std.time.nanoTimestamp();
log(.INFO, "ecs", "Particle update: {}μs", .{(end - start) / 1000});
```

### Step 5: Delete Old Code (Once Validated)

1. Remove `src/ecs/particle_system.zig` (the "stage" pattern)
2. Remove `src/ecs/bootstrap.zig` (no scheduler needed)
3. Simplify `particle_renderer.zig` (remove `syncFromEcs`, just keep `flushEcsBatch`)

---

## Summary

This ECS design provides:

✅ **Clear component ownership**: Components have update/render methods  
✅ **Explicit dispatch**: No hidden scheduler, you call `world.updateComponents()`  
✅ **EnTT-style views**: Ergonomic iteration patterns  
✅ **ThreadPool integration**: Parallel updates using existing infrastructure  
✅ **Renderer separation**: ECS handles simulation, renderers handle GPU  
✅ **Incremental migration**: Can run alongside existing code  

The architecture is **coherent**, **understandable**, and **integrates cleanly** with your existing systems.

Next step: Start with **Phase 1** (Core ECS Foundation) and get basic component storage + iteration working.
