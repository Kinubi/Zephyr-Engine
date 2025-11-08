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

pub const ImGuiContext = struct {
    allocator: std.mem.Allocator,
    gc: *GraphicsContext,
    window: *c.GLFWwindow,
    vulkan_backend: *ImGuiVulkanBackend,
    glfw_input: ImGuiGlfwInput,

    // Double-buffered cloned draw data for render thread
    cloned_draw_data: [2]?*c.ImDrawData = [_]?*c.ImDrawData{null} ** 2,
    current_write_buffer: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    pub fn init(allocator: std.mem.Allocator, gc: *GraphicsContext, window: *c.GLFWwindow, swapchain: *Swapchain, pipeline_system: *UnifiedPipelineSystem) !ImGuiContext {
        // Initialize ImGui context
        if (c.ImGui_CreateContext(null) == null) {
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

        const ctx = ImGuiContext{
            .allocator = allocator,
            .gc = gc,
            .window = window,
            .vulkan_backend = backend_ptr,
            .glfw_input = glfw_input,
        };

        // Initialize the global texture manager now that we have a stable
        // backend pointer. If this fails, the deferred destroy above will
        // clean up the heap allocation.
        try texture_manager.initGlobal(allocator, backend_ptr);

        // Ownership transferred; don't destroy on error path.
        should_destroy_backend = false;

        return ctx;
    }

    pub fn deinit(self: *ImGuiContext) void {
        // Clean up cloned draw data
        inline for (0..2) |i| {
            if (self.cloned_draw_data[i]) |draw_data| {
                self.freeClonedDrawData(draw_data);
            }
        }

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
    pub fn endFrame(self: *ImGuiContext) ?*anyopaque {
        // Finalize ImGui frame to generate draw data
        c.ImGui_EndFrame();
        c.ImGui_Render();

        const src_draw_data = c.ImGui_GetDrawData() orelse return null;

        // Determine which buffer to write to (flip-flop)
        const write_idx = self.current_write_buffer.load(.monotonic);
        const next_idx = 1 - write_idx;

        // Free old cloned data in the buffer we're about to overwrite
        if (self.cloned_draw_data[next_idx]) |old_data| {
            self.freeClonedDrawData(old_data);
            self.cloned_draw_data[next_idx] = null;
        }

        // Deep clone the draw data
        const cloned = self.cloneDrawData(src_draw_data) catch return null;
        self.cloned_draw_data[next_idx] = cloned;

        // Atomically flip to the new buffer
        self.current_write_buffer.store(next_idx, .release);

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
