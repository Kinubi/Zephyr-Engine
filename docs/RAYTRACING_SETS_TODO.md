# Raytracing Acceleration Structure Sets - Implementation Plan

**Date**: November 22, 2025  
**Status**: ✅ COMPLETE  
**Branch**: `master`

---

## Goal

Refactor RaytracingSystem to use **named acceleration structure sets** with generation tracking, matching the Material/Texture sets pattern.

---

## Current Architecture (Implemented)

```zig
// Named AS sets (like MaterialBufferSet/TextureSet)
pub const AccelerationStructureSet = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    
    // BLAS list for this set (geometries)
    blas_handles: std.ArrayList(BlasHandle),
    
    // TLAS for this set (scene)
    tlas: ManagedTLAS,
    
    // Geometry buffers (vertex/index arrays) with generation tracking
    geometry_buffers: ManagedGeometryBuffers,
    
    // Tracking
    dirty: bool = true,
    rebuild_cooldown_frames: u32 = 0,
};
```

**Status:**
- ✅ Named sets implemented
- ✅ Generation tracking for TLAS and geometry buffers
- ✅ Integration with PathTracingPass
- ✅ Automatic descriptor rebinding via ResourceBinder

---

## Previous Architecture (Deprecated)
    
    // TLAS for this set (scene)
    managed_tlas: ManagedTLAS,
    
    // Tracking
    dirty: bool = true,
    last_geometry_generation: u32 = 0,
};

// Managed TLAS with generation tracking (like ManagedBuffer/ManagedTextureArray)
pub const ManagedTLAS = struct {
    acceleration_structure: vk.AccelerationStructureKHR,
    buffer: vk.Buffer,
    instance_buffer: vk.Buffer,
    device_address: vk.DeviceAddress,
    instance_count: u32,
    
    // Generation tracking!
    generation: u32 = 0,  // Increments when TLAS rebuilt
    name: []const u8,
    created_frame: u32 = 0,
};

// BLAS handle (geometry)
pub const BlasHandle = struct {
    acceleration_structure: vk.AccelerationStructureKHR,
    buffer: vk.Buffer,
    geometry_hash: u64,  // For deduplication
    generation: u32 = 0,
};
```

### Usage Pattern

```zig
// In Scene.init() - create AS set
const as_set = try rt_system.createSet("default");

// In Scene.spawnProp() - add geometry to set
try rt_system.addGeometryToSet("default", model_id);

// In RaytracingSystem.update() - rebuild if dirty
if (as_set.dirty) {
    try rt_system.rebuildSet("default", frame_info);
    as_set.managed_tlas.generation += 1;  // Increment!
    as_set.dirty = false;
}

// In PathTracingPass - bind with generation tracking
try resource_binder.bindAccelerationStructureNamed(
    pipeline_id,
    "tlas",
    &as_set.managed_tlas,
    frame
);

// ResourceBinder auto-detects generation change and rebinds!
```

---

## Implementation Steps

### Phase 1: Core Structures ✅ (Plan)

1. Create `AccelerationStructureSet` struct
2. Create `ManagedTLAS` struct with generation tracking
3. Create `BlasHandle` struct
4. Add `as_sets: StringHashMap(AccelerationStructureSet)` to RaytracingSystem

### Phase 2: Set Management API

```zig
// Create or get a named AS set
pub fn createSet(self: *RaytracingSystem, name: []const u8) !*AccelerationStructureSet;

// Get a set by name
pub fn getSet(self: *RaytracingSystem, name: []const u8) ?*AccelerationStructureSet;

// Add geometry to a set (builds BLAS if needed)
pub fn addGeometryToSet(
    self: *RaytracingSystem,
    set_name: []const u8,
    geometry_hash: u64,
    geometry_data: GeometryData,
) !void;

// Rebuild a set's TLAS from its BLAS list
pub fn rebuildSet(
    self: *RaytracingSystem,
    set_name: []const u8,
    frame_info: *const FrameInfo,
) !void;

// Mark set dirty (triggers rebuild)
pub fn markSetDirty(self: *RaytracingSystem, set_name: []const u8) void;
```

### Phase 3: Migration from Current System

**Keep Existing:**
- `MultithreadedBvhBuilder` (BLAS/TLAS building logic)
- `TlasWorker` (async TLAS building)
- Per-frame destruction queues

**Migrate:**
- Move BLAS registry from builder into `AccelerationStructureSet.blas_list`
- Replace `TlasRegistry.current` with `AccelerationStructureSet.managed_tlas`
- Add generation increment when TLAS completes

**Update Callers:**
- Scene: Create "default" AS set during init
- Scene.spawnProp: Add geometry to default set
- PathTracingPass: Bind via ResourceBinder with generation tracking

### Phase 4: ResourceBinder Integration

```zig
// New binding function for acceleration structures
pub fn bindAccelerationStructureNamed(
    self: *ResourceBinder,
    pipeline_id: PipelineId,
    binding_name: []const u8,
    managed_tlas: *const ManagedTLAS,
    frame: u32,
) !void {
    // Track for generation changes
    const key = BindingKey{ .pipeline_id = pipeline_id, .name = binding_name };
    try self.tracked_as.put(key, .{
        .managed_tlas = managed_tlas,
        .last_generation = managed_tlas.generation,
    });
    
    // Bind to descriptor
    const binding_info = self.getBindingInfo(pipeline_id, binding_name) orelse 
        return error.BindingNotFound;
    
    const accel_info = vk.WriteDescriptorSetAccelerationStructureKHR{
        .s_type = .write_descriptor_set_acceleration_structure_khr,
        .acceleration_structure_count = 1,
        .p_acceleration_structures = &[_]vk.AccelerationStructureKHR{managed_tlas.acceleration_structure},
    };
    
    // Write descriptor set for this frame
    // ...
}

// In updateFrame() - check AS generation changes
for (self.tracked_as.values()) |*tracked| {
    if (tracked.managed_tlas.generation != tracked.last_generation) {
        // Rebind for ALL frames
        for (0..MAX_FRAMES_IN_FLIGHT) |f| {
            try self.bindAccelerationStructureNamed(
                tracked.pipeline_id,
                tracked.binding_name,
                tracked.managed_tlas,
                @intCast(f)
            );
        }
        tracked.last_generation = tracked.managed_tlas.generation;
    }
}
```

---

## Migration Path

### Step 1: Add Structures (Non-Breaking)

Add new structures to `raytracing_system.zig` without removing old code:
- `AccelerationStructureSet`
- `ManagedTLAS`
- `BlasHandle`
- `as_sets: HashMap`

### Step 2: Implement Set Management

Add new API functions that work alongside existing system:
- `createSet()`
- `getSet()`
- `addGeometryToSet()`
- `rebuildSet()`

### Step 3: Migrate Callers

Update callers one by one:
1. Scene.init() - create default AS set
2. Scene.spawnProp() - add geometries to set
3. PathTracingPass - use ResourceBinder binding
4. RaytracingSystem.update() - check set dirty flags

### Step 4: Remove Old System

Once all callers migrated:
- Remove `TlasRegistry.current`
- Remove `getTlas()` / `isTlasValid()`
- Clean up unused code

---

## Benefits

1. **Generation Tracking**: Pass automatically detects TLAS changes
2. **Named Sets**: Multiple AS sets for different scenes/levels
3. **Automatic Rebinding**: ResourceBinder handles descriptor updates
4. **Consistent Pattern**: Same architecture as Material/Texture systems
5. **BLAS Organization**: Clear ownership of BLAS within sets
6. **Dirty Flag Optimization**: Only rebuild when needed

---

## Testing Plan

1. Create "default" AS set during scene init
2. Add all geometries to default set
3. Verify TLAS generation increments after rebuild
4. Verify PathTracingPass detects generation changes
5. Test multiple AS sets with different geometries
6. Performance: Measure rebuild frequency
7. Stress test: Many geometry additions

---

## Next Steps

1. ✅ Create this plan document
2. ⏳ Implement core structures in `raytracing_system.zig`
3. ⏳ Add set management API
4. ⏳ Migrate Scene to use sets
5. ⏳ Add ResourceBinder AS tracking
6. ⏳ Update PathTracingPass to use ResourceBinder
7. ⏳ Remove old TlasRegistry system
8. ⏳ Testing and validation

---

## Notes

- Keep async TLAS building (don't break existing performance)
- Maintain per-frame destruction queues (frame safety)
- Generation=0 pattern: Don't bind until first TLAS built
- Each set can have independent rebuild cooldowns
