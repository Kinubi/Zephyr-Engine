# Render Pass Integration Guide

## Current Architecture

The legacy `render_pass.zig` module and VTable-based pass framework have been retired. The engine now records work directly against the swapchain render pass while `GenericRenderer` orchestrates rasterization, lighting, compute, and ray-tracing renderers. This document explains the streamlined path for working with Vulkan render passes today.

## Swapchain-Owned Render Pass

- `Swapchain.createRenderPass()` builds the default Vulkan render pass used for the main framebuffer.
- During a frame, the app drives rendering with the following sequence:
  1. `try swapchain.beginFrame(frame_info);`
  2. Record compute or ray-tracing work that runs outside of raster passes.
  3. `swapchain.beginSwapChainRenderPass(frame_info);`
  4. Invoke `forward_renderer.render(frame_info);`
  5. `swapchain.endSwapChainRenderPass(frame_info);`
  6. `try swapchain.endFrame(frame_info, &current_frame);`
- Renderers access scene data through `SceneBridge` and manage their own Vulkan state via the unified pipeline system.

## Adding Additional Render Passes

If a feature requires a bespoke Vulkan render pass (e.g., G-buffer generation or post-processing):

1. Create the pass with `graphics_context.vkd.createRenderPass` and manage the accompanying framebuffers/resources inside the owning system or renderer.
2. Record commands manually using `cmdBeginRenderPass` / `cmdEndRenderPass` on the appropriate command buffer.
3. Ensure the pass executes outside the swapchain pass or on off-screen targets, then composite results during the main swapchain render pass.

This targeted ownership keeps render pass logic close to the renderer that needs it without reintroducing the old framework.

## Compute and Ray-Tracing Work

- Compute workloads (`ComputeShaderSystem`) issue commands on dedicated compute command buffers and do not require a render pass.
- The ray-tracing renderer records TLAS/BLAS updates and ray-tracing dispatches before the swapchain pass begins.

## Migration Notes

- References to `RenderPass`, `RenderContext`, and `VulkanRenderPassResources` are historical and no longer present in the codebase.
- Documentation or guides that relied on the old abstractions should now reference the swapchain flow outlined above.
- When authoring new documentation, prefer describing renderer-specific ownership patterns rather than a central render-pass trait.

This updated approach keeps the engine simpler while still allowing advanced passes when required.