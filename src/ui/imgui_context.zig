const std = @import("std");
const vk = @import("vulkan");

const c = @cImport({
    @cDefine("GLFW_INCLUDE_VULKAN", "1");
    @cDefine("GLFW_INCLUDE_NONE", "1");
    @cInclude("GLFW/glfw3.h");
    @cInclude("dcimgui.h");
});

const GraphicsContext = @import("../core/graphics_context.zig").GraphicsContext;
const Swapchain = @import("../core/swapchain.zig").Swapchain;
const ImGuiVulkanBackend = @import("imgui_backend_vulkan.zig").ImGuiVulkanBackend;
const ImGuiGlfwInput = @import("imgui_glfw_input.zig").ImGuiGlfwInput;
const UnifiedPipelineSystem = @import("../rendering/unified_pipeline_system.zig").UnifiedPipelineSystem;

pub const ImGuiContext = struct {
    allocator: std.mem.Allocator,
    gc: *GraphicsContext,
    window: *c.GLFWwindow,
    vulkan_backend: ImGuiVulkanBackend,
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

        // Setup Dear ImGui style
        c.ImGui_StyleColorsDark(null);

        // Initialize our custom Vulkan backend
        const vulkan_backend = try ImGuiVulkanBackend.init(allocator, gc, swapchain, pipeline_system);

        // Initialize our lightweight GLFW input handler (cast window pointer)
        const glfw_input = ImGuiGlfwInput.init(@ptrCast(window));

        return ImGuiContext{
            .allocator = allocator,
            .gc = gc,
            .window = window,
            .vulkan_backend = vulkan_backend,
            .glfw_input = glfw_input,
        };
    }

    pub fn deinit(self: *ImGuiContext) void {
        self.vulkan_backend.deinit();
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
