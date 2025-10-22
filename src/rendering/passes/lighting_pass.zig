const std = @import("std");
const vk = @import("vulkan");
const log = @import("../../utils/log.zig").log;
const Math = @import("../../utils/math.zig");

const RenderGraph = @import("../render_graph.zig").RenderGraph;
const RenderPass = @import("../render_graph.zig").RenderPass;
const RenderPassVTable = @import("../render_graph.zig").RenderPassVTable;
const ResourceId = @import("../render_graph.zig").ResourceId;
const FrameInfo = @import("../frameinfo.zig").FrameInfo;
const GraphicsContext = @import("../../core/graphics_context.zig").GraphicsContext;
const UnifiedPipelineSystem = @import("../unified_pipeline_system.zig").UnifiedPipelineSystem;
const PipelineConfig = @import("../unified_pipeline_system.zig").PipelineConfig;
const PipelineId = @import("../unified_pipeline_system.zig").PipelineId;
const Resource = @import("../unified_pipeline_system.zig").Resource;
const MAX_FRAMES_IN_FLIGHT = @import("../../core/swapchain.zig").MAX_FRAMES_IN_FLIGHT;

// ECS imports for lights
const ecs = @import("../../ecs.zig");
const World = ecs.World;
const LightSystem = ecs.LightSystem;

const MAX_LIGHTS = 16;

/// Shader-compatible point light structure
pub const ShaderPointLight = extern struct {
    position: [4]f32 = [4]f32{ 0, 0, 0, 1 },
    color: [4]f32 = [4]f32{ 1, 1, 1, 1 },
    // x: constant, y: linear, z: quadratic, w: range
    attenuation: [4]f32 = [4]f32{ 1.0, 0.09, 0.032, 10.0 },
};

/// LightingPass applies deferred lighting using point lights from ECS
/// Inputs: G-buffer (positions, normals, albedo, etc.)
/// Output: Final lit image
pub const LightingPass = struct {
    base: RenderPass,
    allocator: std.mem.Allocator,

    // Rendering context
    graphics_context: *GraphicsContext,
    pipeline_system: *UnifiedPipelineSystem,
    ecs_world: *World,

    // Swapchain format
    swapchain_color_format: vk.Format,

    // Resources (from G-buffer)
    gbuffer_position: ResourceId = .invalid,
    gbuffer_normal: ResourceId = .invalid,
    gbuffer_albedo: ResourceId = .invalid,
    depth_buffer: ResourceId = .invalid,
    output_color: ResourceId = .invalid,

    // Pipeline
    lighting_pipeline: PipelineId = undefined,
    cached_pipeline_handle: vk.Pipeline = .null_handle,

    // Light extraction system
    light_system: LightSystem,

    // Light buffer (per-frame)
    light_buffers: [MAX_FRAMES_IN_FLIGHT]?vk.Buffer = [_]?vk.Buffer{null} ** MAX_FRAMES_IN_FLIGHT,
    light_memories: [MAX_FRAMES_IN_FLIGHT]?vk.DeviceMemory = [_]?vk.DeviceMemory{null} ** MAX_FRAMES_IN_FLIGHT,

    pub fn create(
        allocator: std.mem.Allocator,
        graphics_context: *GraphicsContext,
        pipeline_system: *UnifiedPipelineSystem,
        ecs_world: *World,
        swapchain_color_format: vk.Format,
    ) !*LightingPass {
        const pass = try allocator.create(LightingPass);
        pass.* = LightingPass{
            .base = RenderPass{
                .vtable = &vtable,
            },
            .allocator = allocator,
            .graphics_context = graphics_context,
            .pipeline_system = pipeline_system,
            .ecs_world = ecs_world,
            .swapchain_color_format = swapchain_color_format,
            .light_system = LightSystem.init(allocator),
        };

        log(.INFO, "lighting_pass", "Created LightingPass", .{});
        return pass;
    }

    const vtable = RenderPassVTable{
        .setup = setupImpl,
        .execute = executeImpl,
        .teardown = teardownImpl,
    };

    fn setupImpl(base: *RenderPass, graph: *RenderGraph) !void {
        const self: *LightingPass = @fieldParentPtr("base", base);

        // TODO: Register G-buffer inputs (when we have a proper G-buffer system)
        // For now, we'll skip resource registration
        _ = graph;

        // Create fullscreen lighting pipeline
        // TODO: Create proper lighting shaders
        // For now, we'll create a placeholder pipeline
        const color_formats = [_]vk.Format{self.swapchain_color_format};
        const pipeline_config = PipelineConfig{
            .name = "lighting_pass",
            .vertex_shader = "shaders/simple.vert", // TODO: fullscreen.vert
            .fragment_shader = "shaders/simple.frag", // TODO: deferred_lighting.frag
            .render_pass = .null_handle,
            .vertex_input_bindings = &[_]vk.VertexInputBindingDescription{},
            .vertex_input_attributes = &[_]vk.VertexInputAttributeDescription{},
            .push_constant_ranges = &[_]vk.PushConstantRange{},
            .topology = .triangle_list,
            .polygon_mode = .fill,
            .cull_mode = .{ .back_bit = true },
            .front_face = .counter_clockwise,
            .dynamic_rendering_color_formats = &color_formats,
            .dynamic_rendering_depth_format = null, // No depth test for fullscreen
        };

        self.lighting_pipeline = try self.pipeline_system.createPipeline(pipeline_config);
        const pipeline_entry = self.pipeline_system.pipelines.get(self.lighting_pipeline) orelse return error.PipelineNotFound;
        self.cached_pipeline_handle = pipeline_entry.vulkan_pipeline;

        // Create light buffers (one per frame in flight)
        try self.createLightBuffers();

        log(.INFO, "lighting_pass", "Setup complete", .{});
    }

    fn createLightBuffers(self: *LightingPass) !void {
        const buffer_size = @sizeOf(ShaderPointLight) * MAX_LIGHTS;

        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            const buffer_info = vk.BufferCreateInfo{
                .s_type = .buffer_create_info,
                .p_next = null,
                .flags = .{},
                .size = buffer_size,
                .usage = .{ .uniform_buffer_bit = true },
                .sharing_mode = .exclusive,
                .queue_family_index_count = 0,
                .p_queue_family_indices = null,
            };

            const buffer = try self.graphics_context.vkd.createBuffer(
                self.graphics_context.dev,
                &buffer_info,
                null,
            );
            errdefer self.graphics_context.vkd.destroyBuffer(self.graphics_context.dev, buffer, null);

            const mem_reqs = self.graphics_context.vkd.getBufferMemoryRequirements(
                self.graphics_context.dev,
                buffer,
            );

            const mem_type_index = try self.graphics_context.findMemoryType(
                mem_reqs.memory_type_bits,
                .{ .host_visible_bit = true, .host_coherent_bit = true },
            );

            const alloc_info = vk.MemoryAllocateInfo{
                .s_type = .memory_allocate_info,
                .p_next = null,
                .allocation_size = mem_reqs.size,
                .memory_type_index = mem_type_index,
            };

            const memory = try self.graphics_context.vkd.allocateMemory(
                self.graphics_context.dev,
                &alloc_info,
                null,
            );
            errdefer self.graphics_context.vkd.freeMemory(self.graphics_context.dev, memory, null);

            try self.graphics_context.vkd.bindBufferMemory(
                self.graphics_context.dev,
                buffer,
                memory,
                0,
            );

            self.light_buffers[i] = buffer;
            self.light_memories[i] = memory;
        }

        log(.INFO, "lighting_pass", "Created {} light buffers", .{MAX_FRAMES_IN_FLIGHT});
    }

    fn executeImpl(base: *RenderPass, frame_info: FrameInfo) !void {
        const self: *LightingPass = @fieldParentPtr("base", base);
        const cmd = frame_info.command_buffer;
        const frame_index = frame_info.current_frame;

        // Extract lights from ECS
        var light_data = try self.light_system.extractLights(self.ecs_world);
        defer light_data.deinit();

        // Update light buffer for this frame
        try self.updateLightBuffer(frame_index, &light_data);

        // Check for pipeline hot-reload
        const pipeline_entry = self.pipeline_system.pipelines.get(self.lighting_pipeline) orelse return error.PipelineNotFound;
        const pipeline_rebuilt = pipeline_entry.vulkan_pipeline != self.cached_pipeline_handle;

        if (pipeline_rebuilt) {
            log(.INFO, "lighting_pass", "Pipeline hot-reloaded", .{});
            self.cached_pipeline_handle = pipeline_entry.vulkan_pipeline;
            self.pipeline_system.markPipelineResourcesDirty(self.lighting_pipeline);
        }

        // For now, just log the number of lights
        // Full implementation will apply lighting in a fullscreen pass
        if (light_data.lights.items.len > 0) {
            log(.DEBUG, "lighting_pass", "Rendering with {} point lights", .{light_data.lights.items.len});
        }

        // TODO: Fullscreen quad rendering with deferred lighting
        // This will be implemented when we have proper G-buffer support

        // TODO: Draw light sources as emissive spheres
        // - For each light in light_data.lights:
        //   * Render a sphere mesh at light.position with radius based on light.intensity
        //   * Use additive blending for emission
        //   * Shader should output light.color * light.intensity (unlit, pure emission)
        //   * This provides visual feedback for light positions and makes them visible in ray tracing
        // - Could use instanced rendering for performance with many lights
        // - Consider billboard spheres or actual sphere geometry

        _ = cmd;
    }

    fn updateLightBuffer(self: *LightingPass, frame_index: u32, light_data: *LightSystem.LightData) !void {
        _ = self.light_buffers[frame_index] orelse return error.BufferNotCreated;
        const memory = self.light_memories[frame_index] orelse return error.MemoryNotAllocated;

        // Map buffer memory
        const data = try self.graphics_context.vkd.mapMemory(
            self.graphics_context.dev,
            memory,
            0,
            @sizeOf(ShaderPointLight) * MAX_LIGHTS,
            .{},
        );
        defer self.graphics_context.vkd.unmapMemory(self.graphics_context.dev, memory);

        // Convert extracted lights to shader format
        const shader_lights: [*]ShaderPointLight = @ptrCast(@alignCast(data));
        const num_lights = @min(light_data.lights.items.len, MAX_LIGHTS);

        for (0..num_lights) |i| {
            const light = light_data.lights.items[i];
            shader_lights[i] = ShaderPointLight{
                .position = [4]f32{ light.position.x, light.position.y, light.position.z, 1.0 },
                .color = [4]f32{
                    light.color.x * light.intensity,
                    light.color.y * light.intensity,
                    light.color.z * light.intensity,
                    1.0,
                },
                .attenuation = [4]f32{
                    light.attenuation.x,
                    light.attenuation.y,
                    light.attenuation.z,
                    light.range,
                },
            };
        }

        // Clear remaining lights
        for (num_lights..MAX_LIGHTS) |i| {
            shader_lights[i] = ShaderPointLight{};
        }
    }

    fn teardownImpl(base: *RenderPass) void {
        const self: *LightingPass = @fieldParentPtr("base", base);
        log(.INFO, "lighting_pass", "Tearing down", .{});

        // Destroy light buffers
        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            if (self.light_buffers[i]) |buffer| {
                self.graphics_context.vkd.destroyBuffer(self.graphics_context.dev, buffer, null);
            }
            if (self.light_memories[i]) |memory| {
                self.graphics_context.vkd.freeMemory(self.graphics_context.dev, memory, null);
            }
        }

        self.light_system.deinit();
        self.allocator.destroy(self);
    }
};
