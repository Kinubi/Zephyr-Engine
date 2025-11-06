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

1. Add `Pass.bind()` wrapper that uses internal pipeline_id
2. ResourceBinder should auto-rebind in updateFrame() (DONE)
3. Remove all resource management from passes
4. Implement `registerShader()` and `bake()` helpers
5. Test with GeometryPass as reference implementation
