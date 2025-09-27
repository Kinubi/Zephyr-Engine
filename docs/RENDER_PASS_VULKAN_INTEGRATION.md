# Render Pass Architecture - Vulkan Integration Guide

## Overview

The ZulkanZengine render pass system provides a modular, trait-based architecture for managing Vulkan render passes. This document explains where to store Vulkan render passes and begin/end functions.

## Architecture Components

### 1. RenderPass Trait (`src/rendering/render_pass.zig`)
The main trait interface that all render passes implement.

### 2. VulkanRenderPassResources (`src/rendering/render_pass.zig`)
Helper struct for managing Vulkan render pass objects, framebuffers, and attachments.

### 3. Concrete Pass Implementations (`src/rendering/passes/`)
Specific render pass implementations like ForwardPass, ShadowPass, etc.

## Where to Store Vulkan Render Passes

### ✅ Recommended: Individual Pass Implementations

```zig
pub const ForwardPass = struct {
    // Store Vulkan render pass resources here
    vk_resources: VulkanRenderPassResources,
    
    // Pass-specific renderers
    simple_renderer: SimpleRenderer,
    point_light_renderer: PointLightRenderer,
    
    pub fn init(self: *ForwardPass, graphics_context: *GraphicsContext) !void {
        // Initialize Vulkan render pass
        self.vk_resources = try VulkanRenderPassResources.init(...);
        
        // Initialize renderers with the render pass
        self.simple_renderer = try SimpleRenderer.init(
            graphics_context,
            self.vk_resources.render_pass, // Pass the Vulkan render pass
            ...
        );
    }
    
    pub fn execute(self: *ForwardPass, context: RenderContext) !void {
        // Begin Vulkan render pass
        self.vk_resources.beginRenderPass(context, 0);
        
        // Render geometry
        try self.simple_renderer.render(context.frame_info.*);
        
        // End Vulkan render pass  
        self.vk_resources.endRenderPass(context);
    }
    
    pub fn getVulkanRenderPass(self: *ForwardPass) ?vk.RenderPass {
        return self.vk_resources.render_pass;
    }
};
```

### ❌ Not Recommended: Global Render Pass Storage

Don't store render passes in a central manager - each pass should own its resources.

## Begin/End Function Locations

### 1. RenderContext Helper Methods
Basic begin/end functions are provided in `RenderContext`:

```zig
pub const RenderContext = struct {
    // ... fields ...
    
    /// Begin a Vulkan render pass
    pub fn beginVulkanRenderPass(
        self: *const RenderContext,
        render_pass: vk.RenderPass,
        framebuffer: vk.Framebuffer,
        clear_values: []const vk.ClearValue
    ) void {
        // Handles cmdBeginRenderPass, viewport, scissor setup
    }
    
    /// End the current Vulkan render pass
    pub fn endVulkanRenderPass(self: *const RenderContext) void {
        self.graphics_context.vkd.cmdEndRenderPass(self.command_buffer);
    }
};
```

### 2. VulkanRenderPassResources Helper Methods
Convenience methods for passes that manage their own render passes:

```zig
pub const VulkanRenderPassResources = struct {
    // ... fields ...
    
    /// Begin this render pass
    pub fn beginRenderPass(
        self: *const VulkanRenderPassResources, 
        context: RenderContext, 
        framebuffer_index: u32
    ) void {
        context.beginVulkanRenderPass(
            self.render_pass, 
            self.framebuffers[framebuffer_index], 
            self.clear_values
        );
    }
    
    /// End this render pass
    pub fn endRenderPass(
        self: *const VulkanRenderPassResources, 
        context: RenderContext
    ) void {
        context.endVulkanRenderPass();
    }
};
```

### 3. Optional Pass-Specific Begin/End (VTable)
For custom setup/cleanup logic:

```zig
pub const ForwardPass = struct {
    // ... fields ...
    
    /// Called before execute() - optional
    pub fn beginPass(self: *ForwardPass, context: RenderContext) !void {
        // Bind global descriptor sets
        // Set up dynamic state
        // Configure pass-specific settings
    }
    
    /// Called after execute() - optional  
    pub fn endPass(self: *ForwardPass, context: RenderContext) !void {
        // Generate mipmaps
        // Transition resource layouts
        // Cleanup pass-specific state
    }
};
```

## Usage Pattern

### 1. Create Pass Implementation
```zig
var forward_pass = try ForwardPass.create(allocator);
var render_pass = forward_pass.asRenderPass();
```

### 2. Add to Render Graph
```zig
var render_graph = RenderGraph.init(allocator);
try render_graph.addPass(&render_pass);
```

### 3. Execute (Handled by RenderGraph)
```zig
// RenderGraph calls this sequence automatically:
try render_pass.beginPass(context);     // Optional setup
try render_pass.execute(context);       // Main rendering
try render_pass.endPass(context);       // Optional cleanup
```

## Key Benefits

1. **Encapsulation**: Each pass owns its Vulkan resources
2. **Flexibility**: Passes can be compute, raytracing, or rasterization
3. **Modularity**: Easy to add/remove/reorder passes
4. **Type Safety**: Compile-time dispatch with runtime flexibility
5. **Resource Management**: Automatic cleanup and dependency tracking

## Migration from Current System

To migrate existing renderers:

1. Wrap renderers in pass implementations
2. Move render pass creation to pass `init()`
3. Use `VulkanRenderPassResources` for complex setups
4. Replace direct `cmdBeginRenderPass` with `beginRenderPass()`
5. Add passes to `RenderGraph` instead of manual sequencing

This architecture provides a clean separation between Vulkan render pass management and rendering logic while maintaining high performance and flexibility.