const std = @import("std");
const vk = @import("vulkan");
const zephyr = @import("zephyr");

const c = @import("imgui_c.zig").c;

const GraphicsContext = zephyr.GraphicsContext;
const Swapchain = zephyr.Swapchain;
const ImGuiVulkanBackend = @import("imgui_backend_vulkan.zig").ImGuiVulkanBackend;
const texture_manager = @import("texture_manager.zig");
const ImGuiGlfwInput = @import("imgui_glfw_input.zig").ImGuiGlfwInput;
const UnifiedPipelineSystem = zephyr.UnifiedPipelineSystem;

pub const MAX_IMGUI_BUFFERS = 3; // Maximum for triple buffering

// Global ImGui context pointer (set during init)
var global_imgui_context: ?*ImGuiContext = null;

/// Free old ImGui draw data for a specific buffer index
/// Called after render thread signals buffer is ready (after semaphore wait)
/// This processes deferred cleanup - freeing data that was queued MAX_FRAMES_IN_FLIGHT ago
pub fn freeOldBufferData(buffer_idx: usize) void {
    const ctx = global_imgui_context orelse return;
    if (buffer_idx >= ctx.deferred_cleanup.len) return;
    
    // Process all deferred cleanups for this frame slot
    // These are allocations from MAX_FRAMES_IN_FLIGHT ago that are now safe to free
    var list = &ctx.deferred_cleanup[buffer_idx];
    for (list.items) |old_data| {
        ctx.freeClonedDrawData(old_data);
    }
    list.clearRetainingCapacity();
}

pub const ImGuiContext = struct {
    allocator: std.mem.Allocator,
    gc: *GraphicsContext,
    window: *c.GLFWwindow,
    vulkan_backend: *ImGuiVulkanBackend,
    glfw_input: ImGuiGlfwInput,

    // Multi-buffered cloned draw data for render thread (2-3 buffers)
    cloned_draw_data: []?*c.ImDrawData,
    buffer_count: u32,
    
    // Deferred cleanup: old draw data queued for deletion after MAX_FRAMES_IN_FLIGHT
    deferred_cleanup: [MAX_IMGUI_BUFFERS]std.ArrayList(*c.ImDrawData),
    current_cleanup_frame: usize = 0,

    pub fn init(allocator: std.mem.Allocator, gc: *GraphicsContext, window: *c.GLFWwindow, swapchain: *Swapchain, pipeline_system: *UnifiedPipelineSystem) !ImGuiContext {
        // Read buffer count from CVAR to match render thread
        const buffer_count: u32 = blk: {
            if (zephyr.cvar.getGlobal()) |registry| {
                if (registry.getAsStringAlloc("r_snapshot_buffers", allocator)) |value| {
                    defer allocator.free(value);
                    if (std.fmt.parseInt(u32, value, 10)) |parsed| {
                        break :blk @min(@max(parsed, 2), MAX_IMGUI_BUFFERS);
                    } else |_| {}
                }
            }
            break :blk 3; // Default to triple buffering
        };

        // Allocate draw data buffer array
        const cloned_draw_data = try allocator.alloc(?*c.ImDrawData, buffer_count);
        for (cloned_draw_data) |*slot| {
            slot.* = null;
        }
        
        // Initialize deferred cleanup lists (using empty struct literal)
        const deferred_cleanup: [MAX_IMGUI_BUFFERS]std.ArrayList(*c.ImDrawData) = [_]std.ArrayList(*c.ImDrawData){std.ArrayList(*c.ImDrawData){}} ** MAX_IMGUI_BUFFERS;

        // Initialize ImGui context
        if (c.ImGui_CreateContext(null) == null) {
            allocator.free(cloned_draw_data);
            return error.ImGuiCreateContextFailure;
        }

        const io = c.ImGui_GetIO();
        io.*.ConfigFlags |= c.ImGuiConfigFlags_NavEnableKeyboard;
        // Note: Docking may not be available in all ImGui builds
        io.*.ConfigFlags |= c.ImGuiConfigFlags_DockingEnable;
        // Only allow moving windows from their title bar to avoid dragging panels from content areas
        //io.*.ConfigWindowsMoveFromTitleBarOnly = true;
        // // Require holding SHIFT to start docking/undocking, avoids accidental drags from content
        //io.*.ConfigDockingWithShift = true;

        // Setup Dear ImGui style
        c.ImGui_StyleColorsDark(null);

        // Allocate the Vulkan backend on the heap so its pointer is stable
        // and can be safely published to the global texture manager.
        const backend_ptr = try allocator.create(ImGuiVulkanBackend);
        var should_destroy_backend: bool = true;
        defer if (should_destroy_backend) allocator.destroy(backend_ptr);

        backend_ptr.* = try ImGuiVulkanBackend.init(allocator, gc, swapchain, pipeline_system);

        // Initialize our lightweight GLFW input handler (cast window pointer)
        const glfw_input = ImGuiGlfwInput.init(@ptrCast(window));

        // Initialize the global texture manager now that we have a stable
        // backend pointer. If this fails, the deferred destroy above will
        // clean up the heap allocation.
        try texture_manager.initGlobal(allocator, backend_ptr);

        // Ownership transferred; don't destroy on error path.
        should_destroy_backend = false;

        const ctx = ImGuiContext{
            .allocator = allocator,
            .gc = gc,
            .window = window,
            .vulkan_backend = backend_ptr,
            .glfw_input = glfw_input,
            .cloned_draw_data = cloned_draw_data,
            .buffer_count = buffer_count,
            .deferred_cleanup = deferred_cleanup,
        };

        // Note: global_imgui_context will be set after ctx is at its stable location
        // (see setGlobalContext method)

        return ctx;
    }

    /// Set the global context pointer (call after init when context is at stable address)
    pub fn setGlobalContext(self: *ImGuiContext) void {
        global_imgui_context = self;
    }

    pub fn deinit(self: *ImGuiContext) void {
        // Clear global pointer
        global_imgui_context = null;

        // Clean up any remaining deferred draw data
        for (&self.deferred_cleanup) |*list| {
            for (list.items) |draw_data| {
                self.freeClonedDrawData(draw_data);
            }
            list.deinit(self.allocator);
        }

        // Clean up cloned draw data
        for (0..self.buffer_count) |i| {
            if (self.cloned_draw_data[i]) |draw_data| {
                self.freeClonedDrawData(draw_data);
            }
        }
        self.allocator.free(self.cloned_draw_data);

        // Tear down UI texture manager first (it may reference the backend),
        // then destroy the backend and ImGui context.
        texture_manager.deinitGlobal(self.allocator);

        self.vulkan_backend.deinit();
        self.allocator.destroy(self.vulkan_backend);

        c.ImGui_DestroyContext(null);
    }

    pub fn newFrame(self: *ImGuiContext) void {
        // Use our optimized input handler instead of cImGui_ImplGlfw_NewFrame
        self.glfw_input.newFrame();
        c.ImGui_NewFrame();
    }

    /// MAIN THREAD: Finalize ImGui frame and clone draw data for render thread
    /// Returns pointer to cloned draw data that should be stored in snapshot
    /// Uses main_thread_write_idx from render_thread.zig to stay synchronized
    pub fn endFrame(self: *ImGuiContext, write_idx: usize) !?*anyopaque {
        // Finalize ImGui frame to generate draw data
        c.ImGui_EndFrame();
        c.ImGui_Render();

        const src_draw_data = c.ImGui_GetDrawData() orelse return null;

        // Queue old cloned data for deferred cleanup (after MAX_FRAMES_IN_FLIGHT)
        // This ensures render thread has finished using it before we free it
        if (self.cloned_draw_data[write_idx]) |old_data| {
            try self.deferred_cleanup[write_idx].append(self.allocator, old_data);
        }

        // Deep clone the draw data into the slot matching snapshot buffer index
        const cloned = self.cloneDrawData(src_draw_data) catch return null;
        self.cloned_draw_data[write_idx] = cloned;

        return @ptrCast(cloned);
    }

    /// RENDER THREAD: Render using pre-cloned draw data from snapshot
    pub fn renderFromSnapshot(self: *ImGuiContext, draw_data_ptr: ?*anyopaque, command_buffer: vk.CommandBuffer, swapchain: *Swapchain, frame_index: u32) !void {
        if (draw_data_ptr) |ptr| {
            const draw_data: *c.ImDrawData = @ptrCast(@alignCast(ptr));
            try self.vulkan_backend.renderDrawData(command_buffer, draw_data, swapchain, frame_index);
        }
    }

    /// Deep clone ImDrawData structure
    fn cloneDrawData(self: *ImGuiContext, src: *c.ImDrawData) !*c.ImDrawData {
        const cloned = try self.allocator.create(c.ImDrawData);
        errdefer self.allocator.destroy(cloned);

        cloned.* = src.*;

        // Clone command lists (ImVector structure)
        if (src.CmdListsCount > 0 and src.CmdLists.Size > 0) {
            const count: usize = @intCast(src.CmdListsCount);
            const cmd_lists = try self.allocator.alloc([*c]c.ImDrawList, count);
            errdefer self.allocator.free(cmd_lists);

            var cloned_count: usize = 0;
            errdefer {
                // Free any command lists that were successfully cloned before the error
                for (0..cloned_count) |i| {
                    self.freeClonedDrawList(cmd_lists[i]);
                }
            }

            for (0..count) |i| {
                // Access ImVector data directly
                cmd_lists[i] = try self.cloneDrawList(src.CmdLists.Data[i]);
                cloned_count += 1;
            }

            // Store the cloned array in the ImVector structure
            cloned.CmdLists.Data = cmd_lists.ptr;
            cloned.CmdLists.Size = @intCast(count);
            cloned.CmdLists.Capacity = @intCast(count);
        }

        return cloned;
    }

    /// Clone a single ImDrawList
    fn cloneDrawList(self: *ImGuiContext, src: *c.ImDrawList) !*c.ImDrawList {
        const cloned = try self.allocator.create(c.ImDrawList);
        errdefer self.allocator.destroy(cloned);

        cloned.* = src.*;

        // Clone vertex buffer
        if (src.VtxBuffer.Size > 0) {
            const vtx_data = src.VtxBuffer.Data[0..@intCast(src.VtxBuffer.Size)];
            const vtx_clone = try self.allocator.alloc(c.ImDrawVert, vtx_data.len);
            errdefer self.allocator.free(vtx_clone);

            @memcpy(vtx_clone, vtx_data);
            cloned.VtxBuffer.Data = vtx_clone.ptr;
            cloned.VtxBuffer.Size = @intCast(vtx_clone.len);
            cloned.VtxBuffer.Capacity = @intCast(vtx_clone.len);
        }

        // Clone index buffer
        if (src.IdxBuffer.Size > 0) {
            const idx_data = src.IdxBuffer.Data[0..@intCast(src.IdxBuffer.Size)];
            const idx_clone = try self.allocator.alloc(c.ImDrawIdx, idx_data.len);
            errdefer {
                self.allocator.free(idx_clone);
                // Free vertex buffer if it was allocated
                if (src.VtxBuffer.Size > 0) {
                    const vtx_buf = cloned.VtxBuffer.Data[0..@intCast(cloned.VtxBuffer.Size)];
                    self.allocator.free(vtx_buf);
                }
            }

            @memcpy(idx_clone, idx_data);
            cloned.IdxBuffer.Data = idx_clone.ptr;
            cloned.IdxBuffer.Size = @intCast(idx_clone.len);
            cloned.IdxBuffer.Capacity = @intCast(idx_clone.len);
        }

        // Clone command buffer
        if (src.CmdBuffer.Size > 0) {
            const cmd_data = src.CmdBuffer.Data[0..@intCast(src.CmdBuffer.Size)];
            const cmd_clone = try self.allocator.alloc(c.ImDrawCmd, cmd_data.len);
            errdefer {
                self.allocator.free(cmd_clone);
                // Free index buffer if it was allocated
                if (src.IdxBuffer.Size > 0) {
                    const idx_buf = cloned.IdxBuffer.Data[0..@intCast(cloned.IdxBuffer.Size)];
                    self.allocator.free(idx_buf);
                }
                // Free vertex buffer if it was allocated
                if (src.VtxBuffer.Size > 0) {
                    const vtx_buf = cloned.VtxBuffer.Data[0..@intCast(cloned.VtxBuffer.Size)];
                    self.allocator.free(vtx_buf);
                }
            }

            @memcpy(cmd_clone, cmd_data);
            cloned.CmdBuffer.Data = cmd_clone.ptr;
            cloned.CmdBuffer.Size = @intCast(cmd_clone.len);
            cloned.CmdBuffer.Capacity = @intCast(cmd_clone.len);
        }

        return cloned;
    }

    /// Free cloned draw data
    fn freeClonedDrawData(self: *ImGuiContext, draw_data: *c.ImDrawData) void {
        // Free command lists
        if (draw_data.CmdListsCount > 0 and draw_data.CmdLists.Size > 0) {
            const count: usize = @intCast(draw_data.CmdListsCount);
            const cmd_lists = draw_data.CmdLists.Data[0..count];
            for (cmd_lists) |cmd_list| {
                self.freeClonedDrawList(cmd_list);
            }
            // Free the array we allocated
            self.allocator.free(cmd_lists);
        }

        self.allocator.destroy(draw_data);
    }

    /// Free cloned draw list
    fn freeClonedDrawList(self: *ImGuiContext, draw_list: *c.ImDrawList) void {
        if (draw_list.VtxBuffer.Size > 0) {
            const vtx_data = draw_list.VtxBuffer.Data[0..@intCast(draw_list.VtxBuffer.Size)];
            self.allocator.free(vtx_data);
        }

        if (draw_list.IdxBuffer.Size > 0) {
            const idx_data = draw_list.IdxBuffer.Data[0..@intCast(draw_list.IdxBuffer.Size)];
            self.allocator.free(idx_data);
        }

        if (draw_list.CmdBuffer.Size > 0) {
            const cmd_data = draw_list.CmdBuffer.Data[0..@intCast(draw_list.CmdBuffer.Size)];
            self.allocator.free(cmd_data);
        }

        self.allocator.destroy(draw_list);
    }
};
