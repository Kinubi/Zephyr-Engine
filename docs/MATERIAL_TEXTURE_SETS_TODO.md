# Material and Texture Sets - TODO & Implementation Notes

**Date**: November 6, 2025  
**Status**: 🚧 IN PROGRESS  
**Branch**: `feature/buffer-manager`

---

## Current Status

### ✅ Completed (November 7, 2025)

1. **Named Sets Architecture**
   - MaterialBufferSet with HashMap storage
   - TextureSet with HashMap storage
   - MaterialBufferSet links to TextureSet
   - Both use generation tracking (generation=0 pattern)

2. **ManagedTextureArray**
   - Parallel structure to ManagedBuffer
   - descriptor_infos array + generation field
   - ResourceBinder tracks texture array changes

3. **ResourceBinder Integration**
   - `bindStorageBufferNamed()` tracks ManagedBuffer
   - `bindTextureArrayNamed()` tracks ManagedTextureArray
   - Automatic generation change detection

4. **Pass Simplification**
   - GeometryPass uses material_set instead of separate systems
   - PathTracingPass uses material_set instead of separate systems
   - Single pointer provides both materials and textures

5. **Scene Integration**
   - Creates "default" texture and material sets
   - Passes sets to render passes

6. **Material Population via spawnProp** ✅
   - Materials added to sets when entities created
   - Textures automatically added to linked texture set
   - Dirty flag system for rebuild tracking

7. **Runtime Material Assignment** ✅
   - `updateTextureForEntity()` adds materials to sets
   - Dynamic texture drag-and-drop works correctly
   - Materials properly tracked in sets

8. **Deferred Buffer Destruction** ✅
   - Buffer names duplicated when queued for destruction
   - Prevents segfaults from dangling name pointers
   - Safe cleanup across frames

9. **Texture Index 0 Reservation** ✅
   - Index 0 reserved for white dummy texture
   - All texture sets include white dummy at index 0
   - User textures start at index 1+
   - `getTextureIndexInSet()` returns correct offset

10. **Generation=0 Guard** ✅
    - Materials don't rebuild until textures ready
    - Prevents binding invalid descriptors
    - Clean startup with proper initialization order

---

## IMMEDIATE TODO: Wire Up Material Population

### Problem

```zig
// Scene creates sets
const texture_set = try texture_system.createSet("default");
const material_set = try material_system.createSet("default", texture_set);

// But sets are empty! material_set.material_ids.items.len == 0
// So rebuildMaterialSet() is never called
// Generation stays 0, descriptors are black
```

### Solution Options

#### Option 1: Automatic Discovery (RECOMMENDED)

In `MaterialSystem.updateInternal()`, auto-populate "default" set:

```zig
pub fn updateInternal(self: *MaterialSystem) !void {
    // Get or create default set
    const default_set = self.getSet("default") orelse return;
    
    // Auto-populate with all loaded materials if empty
    if (default_set.material_ids.items.len == 0) {
        self.asset_manager.materials_mutex.lock();
        defer self.asset_manager.materials_mutex.unlock();
        
        // Add all loaded materials to default set
        var iter = self.asset_manager.asset_to_material.iterator();
        while (iter.next()) |entry| {
            try default_set.material_ids.append(default_set.allocator, entry.key_ptr.*);
            
            // Also add material's textures to linked texture set
            const mat_index = entry.value_ptr.*;
            if (mat_index < self.asset_manager.loaded_materials.items.len) {
                const material = self.asset_manager.loaded_materials.items[mat_index];
                // Add albedo texture
                if (material.albedo_texture_id != 0) {
                    const albedo_id = AssetId.fromU64(material.albedo_texture_id);
                    try self.texture_system.?.addTextureToSet(
                        default_set.texture_set.name,
                        albedo_id
                    );
                }
                // Add roughness texture
                if (material.roughness_texture_id != 0) {
                    const roughness_id = AssetId.fromU64(material.roughness_texture_id);
                    try self.texture_system.?.addTextureToSet(
                        default_set.texture_set.name,
                        roughness_id
                    );
                }
            }
        }
        
        log(.INFO, "material_system", 
            "Auto-populated 'default' set with {} materials", 
            .{default_set.material_ids.items.len});
    }
    
    // Now rebuild if we have materials
    if (default_set.material_ids.items.len > 0) {
        try self.rebuildMaterialSet("default");
    }
}
```

#### Option 2: Manual Population on Entity Creation

When creating entities with materials:

```zig
// In Scene.spawnEntity() or wherever materials are assigned
const material_id = material_component.material_id;
try scene.material_system.addMaterialToSet("default", material_id);
```

#### Option 3: Explicit Scene Setup

After creating sets, explicitly load materials:

```zig
// In Scene.initRenderGraph()
const texture_set = try texture_system.createSet("default");
const material_set = try material_system.createSet("default", texture_set);

// Load specific materials
try material_system.addMaterialToSet("default", floor_material_id);
try material_system.addMaterialToSet("default", wall_material_id);
```

### Recommended Approach

Use **Option 1** for initial implementation:
- Automatically discovers all loaded materials
- Works without manual setup
- Can be optimized later with explicit control

---

## Apply Same Pattern to Other Systems

### 1. TLAS/BLAS Management (HIGH PRIORITY)

**Current State**: `RaytracingSystem` rebuilds TLAS/BLAS every frame

**Target State**: Named acceleration structure sets with generation tracking

#### Desired API

```zig
pub const AccelerationStructureSet = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    blas_list: std.ArrayList(BLASHandle),
    tlas: ManagedTLAS,
    instances: std.ArrayList(InstanceData),
    dirty: bool = true,
};

pub const ManagedTLAS = struct {
    tlas: vk.AccelerationStructureKHR,
    buffer: vk.Buffer,
    memory: vk.DeviceMemory,
    generation: u32 = 0,  // Generation tracking!
    name: []const u8,
    created_frame: u32 = 0,
};

pub const BLASHandle = struct {
    blas: vk.AccelerationStructureKHR,
    buffer: vk.Buffer,
    memory: vk.DeviceMemory,
    geometry_id: AssetId,
    generation: u32 = 0,
};
```

#### Usage Pattern

```zig
// In RaytracingSystem
const as_sets: std.StringHashMap(AccelerationStructureSet);

pub fn createSet(self: *RaytracingSystem, name: []const u8) !*AccelerationStructureSet {
    const result = try self.as_sets.getOrPut(name);
    if (result.found_existing) return result.value_ptr;
    
    result.value_ptr.* = AccelerationStructureSet.init(self.allocator, name);
    return result.value_ptr;
}

pub fn addGeometryToSet(self: *RaytracingSystem, set_name: []const u8, mesh_id: AssetId) !void {
    const set = self.getSet(set_name) orelse return error.SetNotFound;
    
    // Build BLAS for this geometry
    const blas = try self.buildBLAS(mesh_id);
    try set.blas_list.append(blas);
    set.dirty = true;
}

pub fn rebuildSet(self: *RaytracingSystem, set_name: []const u8) !void {
    const set = self.getSet(set_name) orelse return;
    if (!set.dirty) return;
    
    // Rebuild TLAS from BLAS list
    try self.buildTLAS(set);
    set.tlas.generation += 1;  // Increment generation!
    set.dirty = false;
    
    log(.INFO, "raytracing", "Rebuilt AS set '{}', TLAS generation: {}", 
        .{set_name, set.tlas.generation});
}
```

#### ResourceBinder Integration

```zig
// New binding function for acceleration structures
pub fn bindAccelerationStructureNamed(
    self: *ResourceBinder,
    pipeline_id: PipelineId,
    binding_name: []const u8,
    managed_tlas: *const ManagedTLAS,
    frame: u32,
) !void {
    // Register for generation tracking
    try self.updateAccelerationStructureByName(
        pipeline_id,
        binding_name,
        managed_tlas,
        frame
    );
    
    // Bind to descriptor
    const binding_info = self.getBindingInfo(pipeline_id, binding_name) orelse 
        return error.BindingNotFound;
    
    const accel_info = vk.WriteDescriptorSetAccelerationStructureKHR{
        .s_type = .write_descriptor_set_acceleration_structure_khr,
        .acceleration_structure_count = 1,
        .p_acceleration_structures = &[_]vk.AccelerationStructureKHR{managed_tlas.tlas},
    };
    
    // ... write descriptor set
}
```

#### In PathTracingPass

```zig
pub const PathTracingPass = struct {
    rt_set: *AccelerationStructureSet,  // Instead of rt_system
    
    fn updateDescriptors(self: *PathTracingPass) !void {
        const managed_tlas = &self.rt_set.tlas;
        
        // Generation-tracked binding!
        try self.resource_binder.bindAccelerationStructureNamed(
            self.path_tracing_pipeline,
            "tlas",
            managed_tlas,
            frame
        );
    }
};
```

### 2. UBO Management (MEDIUM PRIORITY)

**Current State**: `GlobalUboSet` manually manages per-frame UBOs

**Target State**: Use BufferManager with generation tracking

#### Desired API

```zig
pub const ManagedUboSet = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    buffers: [MAX_FRAMES_IN_FLIGHT]ManagedBuffer,
    data_size: usize,
    generation: u32 = 0,  // Increments when UBO structure changes
};

// In BufferManager
pub fn createUboSet(
    self: *BufferManager,
    name: []const u8,
    size: usize,
) !ManagedUboSet {
    var set = ManagedUboSet{
        .allocator = self.allocator,
        .name = try self.allocator.dupe(u8, name),
        .buffers = undefined,
        .data_size = size,
    };
    
    // Create one buffer per frame
    for (0..MAX_FRAMES_IN_FLIGHT) |i| {
        set.buffers[i] = try self.createBuffer(.{
            .name = try std.fmt.allocPrint(
                self.allocator,
                "{s}_frame{}",
                .{name, i}
            ),
            .size = size,
            .usage = .{ .uniform_buffer_bit = true },
            .strategy = .host_visible,  // UBOs are updated frequently
        }, @intCast(i));
    }
    
    return set;
}

pub fn updateUboSet(
    self: *BufferManager,
    set: *ManagedUboSet,
    frame: u32,
    data: []const u8,
) !void {
    try self.updateBuffer(&set.buffers[frame], data, frame);
}
```

#### Usage

```zig
// Replace GlobalUboSet
const camera_ubo_set = try buffer_manager.createUboSet("CameraUbo", @sizeOf(CameraData));

// Update per frame
try buffer_manager.updateUboSet(&camera_ubo_set, frame, std.mem.asBytes(&camera_data));

// Bind with generation tracking
try resource_binder.bindUniformBufferNamed(
    pipeline_id,
    "CameraUbo",
    &camera_ubo_set.buffers[frame],
    frame
);
```

---

## Relationships Between Systems

### Material and MaterialBufferSet

```
AssetManager                  MaterialSystem
    │                              │
    ├─> loaded_materials[]        ├─> HashMap<String, MaterialBufferSet>
    │   (CPU data)                │        │
    │                             │        ├─> buffer: ManagedBuffer (GPU)
    │                             │        ├─> material_ids: []AssetId
    │                             │        └─> texture_set: *TextureSet
    │                             │
    └─ Notify on changes ────────>└─ Rebuild GPU buffer

MaterialBufferSet = "A collection of materials with their GPU buffer"

1. MaterialSystem.createSet("name", texture_set) 
   → Creates empty MaterialBufferSet
   
2. MaterialSystem.addMaterialToSet("name", material_id)
   → Adds material ID to set's material_ids list
   → Adds material's textures to linked texture_set
   
3. MaterialSystem.rebuildMaterialSet("name")
   → Queries AssetManager for material data by IDs
   → Resolves texture indices via TextureSystem
   → Builds GPU buffer via BufferManager
   → Increments buffer.generation
   
4. Pass binds buffer
   → ResourceBinder detects generation change
   → Auto-rebinds descriptors
```

### Texture and TextureSet

```
AssetManager                  TextureSystem
    │                              │
    ├─> loaded_textures[]         ├─> HashMap<String, TextureSet>
    │   (CPU/GPU textures)        │        │
    │                             │        ├─> texture_ids: []AssetId
    │                             │        └─> managed_textures: ManagedTextureArray
    │                             │                 ├─> descriptor_infos[]
    └─ Notify on changes ────────>                 └─> generation

TextureSet = "A collection of texture descriptors"

1. TextureSystem.createSet("name")
   → Creates empty TextureSet
   
2. TextureSystem.addTextureToSet("name", texture_id)
   → Adds texture ID to set's texture_ids list
   
3. TextureSystem.rebuildTextureSet("name")
   → Queries AssetManager for texture descriptors by IDs
   → Builds descriptor array
   → Increments managed_textures.generation
   
4. Pass binds textures
   → ResourceBinder detects generation change
   → Auto-rebinds descriptor array
```

---

## Testing Checklist

### Material/Texture Sets

- [ ] Create multiple sets with different names
- [ ] Add materials to sets
- [ ] Verify generation increments when sets rebuild
- [ ] Verify ResourceBinder detects generation changes
- [ ] Verify different passes can use different sets
- [ ] Test hot-reload (material changes trigger rebuild)
- [ ] Test texture changes (linked set regenerates)

### TLAS/BLAS Sets (Future)

- [ ] Create acceleration structure sets
- [ ] Add geometries to sets
- [ ] Verify TLAS generation tracking
- [ ] Multiple AS sets for different scenes
- [ ] BLAS caching within sets

### UBO Sets (Future)

- [ ] Convert GlobalUboSet to ManagedUboSet
- [ ] Verify per-frame UBO management
- [ ] Test generation tracking for UBO structure changes

---

## Notes

- All "sets" follow the same pattern: HashMap + generation tracking
- ResourceBinder is the central hub for detecting changes
- Generation=0 means "not created yet" (lazy initialization)
- Each system (Material, Texture, RT, UBO) owns its GPU resources
- AssetManager stays pure CPU data

**Good night! Continue here tomorrow.**
