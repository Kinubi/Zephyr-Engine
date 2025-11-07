# Render Pass Vision - Zero Boilerplate API

## Goal
Create render passes with minimal code - no manual resource management, no pipeline tracking, no descriptor updates.

## Ideal API

```zig
// Step 1: Create pass with minimal boilerplate
quad_pass = Pass.create(allocator, "quad_pass", graphics_context);

// Step 2: Register shaders (queued for bake)
quad_pass.registerShader("quad.vert");
quad_pass.registerShader("quad.frag");

// Step 3: Register resource bindings (queued for bake)
quad_pass.bind("GlobalUBO", ubo_buffer);
quad_pass.bind("Textures", texture_infos);

// Step 4: Bake - creates pipeline + binds all resources
quad_pass.bake();  // This does:
                   // - Create pipeline from shaders
                   // - Populate ResourceBinder via shader reflection
                   // - Bind all registered resources

// That's it! updateFrame() happens automatically
// No manual resource tracking
// No updateDescriptors() calls
// No pipeline management
```

## Key Principles

1. **Bind Once, Forget**
   - Call `bind()` once in setup
   - ResourceBinder auto-detects when buffer handles change
   - Descriptors automatically update

2. **No Pipeline IDs**
   - Pass owns exactly one pipeline
   - `bind()` doesn't need pipeline_id parameter
   - Everything is implicit from the pass context

3. **Automatic Resource Type Detection**
   - `bind()` figures out if it's a uniform buffer, storage buffer, or texture
   - Uses shader reflection to find binding location
   - No manual type specification needed

4. **Zero Resource Management**
   - Pass doesn't track dirty flags
   - Pass doesn't check for buffer changes
   - Pass just renders - infrastructure handles the rest

5. **External Resource Creation**
   - Resources created outside the pass (externally managed)
   - Pass receives resources via `bind()`, doesn't own them
   - Example: Output textures, intermediate buffers, render targets
   - Enables resource sharing between passes

## External Resource Pattern

For pass-specific resources like output textures, create them externally and bind:

```zig
// Create HDR backbuffer (managed by swapchain, viewport-sized)
var hdr_backbuffer = try ManagedTexture.create(texture_manager, "hdr_backbuffer", .{
    .format = .r16g16b16a16_sfloat,
    .extent = viewport_extent,  // Resizes with viewport
    .usage = .{ .color_attachment_bit = true, .sampled_bit = true },
});

// Create output texture that auto-resizes AND matches format with HDR backbuffer
const output_config = TextureConfig{
    .usage = .{ .storage_bit = true, .transfer_src_bit = true, .sampled_bit = true },
    .resize_source = &hdr_backbuffer,  // Link to HDR backbuffer for size/format
    .match_format = true,              // Also match source format
};
var output_texture = try ManagedTexture.create(texture_manager, "pt_output", output_config);

// RaytracingSystem builds and exposes geometry buffer arrays
// (internally builds vertex/index descriptor arrays from geometries)
rt_system.update(render_system, frame_info, geometry_changed);

// Create path tracing pass
var pt_pass = try Pass.create(allocator, "path_tracing", graphics_context);
pt_pass.registerShader("path_trace.rgen");
pt_pass.registerShader("path_trace.rmiss");
pt_pass.registerShader("path_trace.rchit");

// Bind external resources - pass doesn't create or manage any of these
pt_pass.bind("output_texture", &output_texture);        // Output image (auto-resizes)
pt_pass.bind("GlobalUBO", global_ubo);                  // Camera/scene data
pt_pass.bind("scene", rt_system.getTLAS());             // Acceleration structure
pt_pass.bind("VertexBuffers", rt_system.getVertexBuffers()); // Geometry vertex data
pt_pass.bind("IndexBuffers", rt_system.getIndexBuffers());   // Geometry index data
pt_pass.bind("MaterialBuffer", material_system.getBuffer());
pt_pass.bind("Textures", material_system.getTextureArray());

pt_pass.bake();

// Later: texture can be used by other passes or presented
tonemap_pass.bind("input_texture", &output_texture);
```

### Dynamic Resize Linking

**Problem**: HDR backbuffer resizes with viewport, PathTracingPass output must match size and format

**Solution**: ManagedTexture with resize_source reference

```zig
pub const ManagedTexture = struct {
    handle: vk.Image,
    view: vk.ImageView,
    format: vk.Format,
    extent: vk.Extent3D,
    generation: u32,  // Increments on resize or format change
    resize_source: ?*ManagedTexture,  // Optional link to another texture
    match_format: bool = false,  // If true, also match source format
    
    pub fn update(self: *ManagedTexture, texture_manager: *TextureManager) !void {
        if (self.resize_source) |source| {
            // Check if source texture has changed
            const size_changed = source.extent.width != self.extent.width or 
                                 source.extent.height != self.extent.height;
            const format_changed = self.match_format and source.format != self.format;
            
            if (size_changed or format_changed) {
                // Resize and/or update format to match source
                const new_format = if (self.match_format) source.format else self.format;
                try self.resize(texture_manager, source.extent, new_format);
                // Generation auto-increments in resize()
            }
        }
    }
    
    pub fn resize(self: *ManagedTexture, texture_manager: *TextureManager, new_extent: vk.Extent3D, new_format: vk.Format) !void {
        // Recreate texture with new size/format
        texture_manager.destroyTexture(self.handle);
        self.handle = try texture_manager.createTexture(self.config, new_extent, new_format);
        self.extent = new_extent;
        self.format = new_format;
        self.generation += 1;  // Trigger ResourceBinder rebind
    }
};
```

**Workflow**:
1. Viewport resizes → HDR backbuffer recreated via `hdr_backbuffer.resize(new_extent, new_format)`
2. Next frame: `output_texture.update()` checks `resize_source` (HDR backbuffer)
3. Detects size OR format mismatch → calls `output_texture.resize()` to match
4. Generation increments → ResourceBinder auto-rebinds on all frames
5. PathTracingPass renders at correct size/format (no manual intervention)

**Use Cases**:
- **Size only**: Intermediate buffers that keep own format but match viewport size
- **Size + Format**: Output textures that must exactly match HDR backbuffer
- **Independent**: Textures with fixed size/format (no resize_source)

### Benefits
- **Resource Ownership**: Clear who owns what (render graph owns render targets)
- **Resource Sharing**: Same texture used by multiple passes
- **Automatic Resize**: Linked textures resize together, no manual tracking
- **Format Propagation**: HDR format changes auto-propagate to linked textures
- **Generation Tracking**: ResourceBinder auto-rebinds when size changes
- **Flexibility**: Easy to swap implementations (different output formats)
- **Testability**: Can inject mock resources for testing
- **Lifecycle Control**: Application controls when resources are created/destroyed

### Current Path Tracing Issue
Currently `PathTracingPass` creates its own `output_texture` internally and builds vertex/index buffer arrays:
```zig
// CURRENT (tight coupling, manual resize/format handling, duplicate geometry logic):
var output_format = swapchain_format;
if (output_format == vk.Format.a2r10g10b10_unorm_pack32) {
    output_format = vk.Format.a2b10g10r10_unorm_pack32;
} else if (output_format == vk.Format.r16g16b16a16_sfloat) {
    output_format = vk.Format.r16g16b16a16_sfloat;
}
const output_texture = try Texture.init(graphics_context, output_format, extent, ...);
pass.output_texture = output_texture;

// Build vertex/index buffer arrays per-frame (duplicate of what RT system has)
per_frame: [MAX_FRAMES_IN_FLIGHT]PerFrameDescriptorData = undefined;
fn updateFromGeometries(frame_data, rt_data) {
    // Manually iterate geometries and build descriptor arrays
    for (rt_data.geometries) |geometry| {
        vertex_infos.append(...);
        index_infos.append(...);
    }
}
// On resize: must manually recreate output_texture to match new HDR size/format

// DESIRED (external creation, auto-resize + format, shared geometry buffers):
var output_texture = try ManagedTexture.create(texture_manager, "pt_output", .{
    .usage = .{ .storage_bit = true, .transfer_src_bit = true, .sampled_bit = true },
    .resize_source = &hdr_backbuffer,  // Auto-matches HDR size AND format
    .match_format = true,              // Propagate format changes
});

// RaytracingSystem exposes geometry buffer arrays (built once, shared)
const vertex_buffers = rt_system.getVertexBuffers(); // ManagedBufferArray
const index_buffers = rt_system.getIndexBuffers();   // ManagedBufferArray

pt_pass.bind("output_texture", &output_texture);
pt_pass.bind("VertexBuffers", &vertex_buffers);  // No manual array building!
pt_pass.bind("IndexBuffers", &index_buffers);    // No manual array building!
// On resize/format change: hdr_backbuffer changes, output_texture auto-follows
// On geometry change: rt_system rebuilds arrays, generation increments, auto-rebinds
```

This change enables:
- Automatic format propagation (HDR format changes → output texture follows)
- Automatic resize propagation (viewport → HDR → output texture)
- No manual format conversion logic in pass code
- **No duplicate geometry buffer array building** - RaytracingSystem owns this
- **Generation tracking for geometry changes** - auto-rebind when buffers change
- Sharing output texture with other passes (e.g., tonemap, UI overlay)
- Testing with different texture configurations
- Render graph control over resource lifecycle
- Generation-based rebinding (no manual descriptor updates)


   - Pass doesn't track dirty flags
   - Pass doesn't check for buffer changes
   - Pass just renders - infrastructure handles the rest

## Behind the Scenes

### MaterialSystem
- Creates buffers via BufferManager with name "MaterialBuffer"
- Updates buffer data when materials change
- Doesn't bind anything - just manages data

### BufferManager
- Creates and updates buffers
- Tracks buffer lifecycle (creation, destruction)
- Doesn't bind - just provides buffers

### ResourceBinder
- Tracks bindings by (pipeline_id, binding_name, frame_index)
- In `updateFrame()`: checks if buffer handles changed, rebinds automatically
- Detects changes by comparing VkBuffer handles
- Only writes descriptors if something changed

### RaytracingSystem
- Builds BLAS/TLAS from scene geometry
- **Builds vertex/index buffer descriptor arrays internally**
- Exposes ManagedBufferArray for vertex/index buffers
- Generation increments when geometry changes
- Eliminates duplicate array building in passes

### ManagedBufferArray (New)
Similar to ManagedTextureArray, but for buffer descriptor arrays:
```zig
pub const ManagedBufferArray = struct {
    descriptor_infos: []vk.DescriptorBufferInfo,  // Array of buffer descriptors
    generation: u32,  // Increments when array rebuilt
    
    pub fn update(self: *ManagedBufferArray, new_infos: []vk.DescriptorBufferInfo) void {
        // Rebuild array
        self.descriptor_infos = new_infos;
        self.generation += 1;  // Trigger ResourceBinder rebind
    }
};
```

Used by RaytracingSystem:
```zig
// RaytracingSystem internally builds these from geometries
vertex_buffer_array: ManagedBufferArray,
index_buffer_array: ManagedBufferArray,

pub fn getVertexBuffers(self: *RaytracingSystem) *ManagedBufferArray {
    return &self.vertex_buffer_array;
}

pub fn getIndexBuffers(self: *RaytracingSystem) *ManagedBufferArray {
    return &self.index_buffer_array;
}
```

### Pass (GeometryPass, QuadPass, etc.)
- **Setup**: 
  - `registerShader()` - queues shaders for bake
  - `bind()` - queues resource bindings for bake
  - `bake()` - creates pipeline + binds all registered resources
- **Update**: Calls `updateFrame()` - that's it!
- **Execute**: Renders using bound resources
- No resource management logic

### Bake Process
When `pass.bake()` is called:
1. Create pipeline from registered shaders (via UnifiedPipelineSystem)
2. Extract shader reflection data (bindings, sets, types)
3. Populate ResourceBinder with binding locations
4. Bind all registered resources from `bind()` calls
5. Mark pass as ready to render

## Current Status

✅ BufferManager: Creates/updates buffers with frame-safe cleanup
✅ MaterialSystem: Manages material data, creates buffers via BufferManager
✅ ResourceBinder: Auto-rebinds changed buffers in updateFrame()
⏳ Pass API: Still requires manual bindResources() call - needs cleanup
⏳ Simplified bind() wrapper without pipeline_id

## Next Steps

1. **Add Pass.bind() wrapper** - Uses internal pipeline_id, cleaner API
2. **External resource creation** - Move output texture creation out of PathTracingPass
3. **TextureManager integration** - Managed textures with generation tracking (like BufferManager)
4. **Remove manual resource management** - Clean up passes to just render
5. **Implement registerShader() and bake()** - Complete the zero-boilerplate API
6. **Test with PathTracingPass** - Reference implementation showing external resources

### Phase 9: External Resource Pattern with Dynamic Resize (In Progress)

**Goal**: Move resource creation outside passes, enable resource sharing, auto-resize linked textures

1. ✅ Create TextureManager (similar to BufferManager)
   - ManagedTexture with generation tracking
   - Named texture creation and lookup
   - Automatic cleanup with ring buffer
   - **resize_source pointer** for linked resize behavior
   - **update()** method checks resize_source and resizes if needed
   - **resize()** method recreates texture and increments generation
   - **Implementation**: `engine/src/rendering/texture_manager.zig`

2. ⏳ Migrate HDR backbuffer to ManagedTexture
   - Swapchain creates HDR backbuffer via TextureManager
   - On viewport resize: `hdr_backbuffer.resize(new_extent)`
   - Generation increments → ResourceBinder auto-rebinds
   - Named "hdr_backbuffer" for easy lookup

3. ⏳ Refactor PathTracingPass
   - Remove internal output_texture creation
   - Accept output texture via bind()
   - Application creates with `resize_source = &hdr_backbuffer`
   - Pass just calls `output_texture.update()` each frame
   - Auto-resizes when HDR backbuffer changes
   - **Remove vertex/index buffer array building** - get from RaytracingSystem instead

4. ⏳ RaytracingSystem exposes geometry buffer arrays
   - Build vertex_buffer_descriptors and index_buffer_descriptors internally
   - Expose as ManagedBufferArray (similar to ManagedTextureArray)
   - Generation increments when geometry changes
   - PathTracingPass binds via: `pt_pass.bind("VertexBuffers", rt_system.getVertexBuffers())`
   - PathTracingPass binds via: `pt_pass.bind("IndexBuffers", rt_system.getIndexBuffers())`
   - Eliminates duplicate PerFrameDescriptorData in pass

5. ⏳ Update other passes for external resources
   - TonemapPass: accepts input/output textures (both ManagedTexture)
   - GeometryPass: accepts render targets
   - Enable resource sharing between passes

5. ⏳ Implement Pass.bind() wrapper
   - Hides pipeline_id from API
   - Type detection via shader reflection
   - Queue bindings for bake()

**Validation**: 
- PathTracingPass uses externally created output texture
- Output texture auto-resizes when viewport/HDR backbuffer resizes
- Generation tracking triggers automatic descriptor rebinding
- No manual resize tracking in pass code

