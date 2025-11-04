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

    pub fn render(self: *ImGuiContext, command_buffer: vk.CommandBuffer, swapchain: *Swapchain, frame_index: u32) !void {
        c.ImGui_Render();
        const draw_data = c.ImGui_GetDrawData();
        try self.vulkan_backend.renderDrawData(command_buffer, @ptrCast(draw_data), swapchain, frame_index);
    }
};
