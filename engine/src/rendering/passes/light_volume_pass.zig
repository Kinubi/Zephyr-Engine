const std = @import("std");
const vk = @import("vulkan");
const log = @import("../../utils/log.zig").log;
const Math = @import("../../utils/math.zig");
const RenderGraph = @import("../render_graph.zig").RenderGraph;
const RenderPass = @import("../render_graph.zig").RenderPass;
const RenderPassVTable = @import("../render_graph.zig").RenderPassVTable;
const ResourceId = @import("../render_graph.zig").ResourceId;
const FrameInfo = @import("../frameinfo.zig").FrameInfo;
const GlobalUbo = @import("../frameinfo.zig").GlobalUbo;
const GraphicsContext = @import("../../core/graphics_context.zig").GraphicsContext;
const UnifiedPipelineSystem = @import("../unified_pipeline_system.zig").UnifiedPipelineSystem;
const ResourceBinder = @import("../resource_binder.zig").ResourceBinder;
const PipelineConfig = @import("../unified_pipeline_system.zig").PipelineConfig;
const PipelineId = @import("../unified_pipeline_system.zig").PipelineId;
const MAX_FRAMES_IN_FLIGHT = @import("../../core/swapchain.zig").MAX_FRAMES_IN_FLIGHT;
const DynamicRenderingHelper = @import("../../utils/dynamic_rendering.zig").DynamicRenderingHelper;
const Buffer = @import("../../core/buffer.zig").Buffer;
const BufferManager = @import("../buffer_manager.zig").BufferManager;
const ManagedBuffer = @import("../buffer_manager.zig").ManagedBuffer;
const ecs = @import("../../ecs.zig");
const GlobalUboSet = @import("../ubo_set.zig").GlobalUboSet;
const Resource = @import("../unified_pipeline_system.zig").Resource;

const World = ecs.World;
const LightSystem = ecs.LightSystem;

// TODO: SIMPLIFY RENDER PASS - Remove resource update checks
// TODO: Use named resource binding: bindStorageBuffer("LightVolumes", light_volume_buffer)

/// Light volume data for SSBO (matches shader struct)
const LightVolumeData = extern struct {
    position: [4]f32,
    color: [4]f32,
    radius: f32,
    _padding: [3]f32 = .{0} ** 3,
};

/// LightVolumePass renders emissive spheres/billboards at light positions
/// This makes lights visible and provides visual feedback for debugging
pub const LightVolumePass = struct {
    base: RenderPass,
    allocator: std.mem.Allocator,

    // Rendering context
    graphics_context: *GraphicsContext,
    pipeline_system: *UnifiedPipelineSystem,
    resource_binder: ResourceBinder,
    buffer_manager: *BufferManager,
    ecs_world: *World,
    global_ubo_set: *GlobalUboSet,

    // Swapchain formats
    swapchain_color_format: vk.Format,
    swapchain_depth_format: vk.Format,

    // Pipeline
    light_volume_pipeline: PipelineId = undefined,
    cached_pipeline_handle: vk.Pipeline = .null_handle,

    // Light extraction system
    light_system: LightSystem,

    // SSBO for instanced light data (per frame to avoid synchronization issues)
    light_volume_buffers: [MAX_FRAMES_IN_FLIGHT]*ManagedBuffer,
    max_lights: u32,

    pub fn create(
        allocator: std.mem.Allocator,
        graphics_context: *GraphicsContext,
        pipeline_system: *UnifiedPipelineSystem,
        buffer_manager: *BufferManager,
        ecs_world: *World,
        global_ubo_set: *GlobalUboSet,
        swapchain_color_format: vk.Format,
        swapchain_depth_format: vk.Format,
    ) !*LightVolumePass {
        const pass = try allocator.create(LightVolumePass);

        // Create SSBO for light data (per frame in flight) using BufferManager
        const max_lights: u32 = 128; // Support up to 128 lights
        var light_volume_buffers: [MAX_FRAMES_IN_FLIGHT]*ManagedBuffer = undefined;

        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            const buffer_name = try std.fmt.allocPrint(allocator, "light_volumes_{d}", .{i});
            defer allocator.free(buffer_name);

            light_volume_buffers[i] = try buffer_manager.createBuffer(
                .{
                    .name = buffer_name,
                    .size = @sizeOf(LightVolumeData) * max_lights,
                    .strategy = .host_visible,
                    .usage = .{ .storage_buffer_bit = true },
                },
                0, // frame_index
            );

            // Map the buffer for host writes
            try light_volume_buffers[i].buffer.map(vk.WHOLE_SIZE, 0);
        }

        pass.* = LightVolumePass{
            .base = RenderPass{
                .name = "light_volume_pass",
                .enabled = true,
                .vtable = &vtable,
                .dependencies = std.ArrayList([]const u8){},
            },
            .allocator = allocator,
            .graphics_context = graphics_context,
            .pipeline_system = pipeline_system,
            .resource_binder = ResourceBinder.init(allocator, pipeline_system),
            .buffer_manager = buffer_manager,
            .ecs_world = ecs_world,
            .global_ubo_set = global_ubo_set,
            .swapchain_color_format = swapchain_color_format,
            .swapchain_depth_format = swapchain_depth_format,
            .light_system = LightSystem.init(allocator),
            .light_volume_buffers = light_volume_buffers,
            .max_lights = max_lights,
        };

        log(.INFO, "light_volume_pass", "Created LightVolumePass", .{});
        return pass;
    }

    const vtable = RenderPassVTable{
        .setup = setupImpl,
        .update = updateImpl,
        .execute = executeImpl,
        .teardown = teardownImpl,
        .checkValidity = checkValidityImpl,
        .reset = reset,
    };

    fn checkValidityImpl(base: *RenderPass) bool {
        const self: *LightVolumePass = @fieldParentPtr("base", base);

        // Check if pipeline now exists (hot-reload succeeded)
        if (!self.pipeline_system.pipelines.contains(self.light_volume_pipeline)) {
            return false;
        }

        // Pipeline exists! Complete the setup that was skipped during initial failure
        const pipeline_entry = self.pipeline_system.pipelines.get(self.light_volume_pipeline) orelse return false;
        self.cached_pipeline_handle = pipeline_entry.vulkan_pipeline;

        // Bind resources after recovery
        self.bindResources() catch |err| {
            log(.WARN, "light_volume_pass", "Failed to bind resources during recovery: {}", .{err});
            return false;
        };

        self.pipeline_system.markPipelineResourcesDirty(self.light_volume_pipeline);

        log(.INFO, "light_volume_pass", "Recovery setup complete", .{});
        return true;
    }

    fn updateImpl(base: *RenderPass, frame_info: *const FrameInfo) !void {
        const self: *LightVolumePass = @fieldParentPtr("base", base);

        try self.resource_binder.updateFrame(self.light_volume_pipeline, frame_info.current_frame);
    }

    fn setupImpl(base: *RenderPass, graph: *RenderGraph) !void {
        const self: *LightVolumePass = @fieldParentPtr("base", base);
        _ = graph;

        // Create billboard light rendering pipeline
        const color_formats = [_]vk.Format{self.swapchain_color_format};
        const pipeline_config = PipelineConfig{
            .name = "light_volume_pass",
            .vertex_shader = "assets/shaders/point_light.vert",
            .fragment_shader = "assets/shaders/point_light.frag",
            .render_pass = .null_handle, // Dynamic rendering
            .vertex_input_bindings = null, // No vertex input for billboards
            .vertex_input_attributes = null,
            .push_constant_ranges = null, // No push constants - using SSBO now
            .topology = .triangle_list,
            .polygon_mode = .fill,
            .cull_mode = .{ .back_bit = true },
            .front_face = .counter_clockwise,
            .dynamic_rendering_color_formats = &color_formats,
            .dynamic_rendering_depth_format = self.swapchain_depth_format,
            .depth_stencil_state = .{
                .depth_test_enable = true, // Test against depth buffer
                .depth_write_enable = false, // Don't write to depth (transparent)
                .depth_compare_op = .less,
            },
            .color_blend_attachment = .{
                .blend_enable = true,
                .src_color_blend_factor = .src_alpha,
                .dst_color_blend_factor = .one, // Additive for glow effect
                .color_blend_op = .add,
                .src_alpha_blend_factor = .one,
                .dst_alpha_blend_factor = .zero,
                .alpha_blend_op = .add,
                .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
            },
        };

        const result = try self.pipeline_system.createPipeline(pipeline_config);
        self.light_volume_pipeline = result.id;

        if (!result.success) {
            log(.WARN, "light_volume_pass", "Pipeline creation failed. Pass will be disabled.", .{});
            return error.PipelineCreationFailed;
        }

        const pipeline_entry = self.pipeline_system.pipelines.get(self.light_volume_pipeline) orelse return error.PipelineNotFound;
        self.cached_pipeline_handle = pipeline_entry.vulkan_pipeline;

        // Populate ResourceBinder with shader reflection data
        if (try self.pipeline_system.getPipelineReflection(self.light_volume_pipeline)) |reflection| {
            var mut_reflection = reflection;
            try self.resource_binder.populateFromReflection(mut_reflection);
            mut_reflection.deinit(self.allocator);
        }

        // Bind resources once - ResourceBinder tracks generation changes automatically
        try self.bindResources();

        self.pipeline_system.markPipelineResourcesDirty(self.light_volume_pipeline);

        log(.INFO, "light_volume_pass", "Setup complete", .{});
    }

    fn bindResources(self: *LightVolumePass) !void {
        // Bind global UBO for all frames (generation tracked automatically)
        try self.resource_binder.bindUniformBufferNamed(
            self.light_volume_pipeline,
            "GlobalUbo",
            self.global_ubo_set.frame_buffers,
        );

        // Bind light volume SSBO for all frames (generation tracked automatically)
        // Shader variable name is "lightVolumes" (lowercase 'l')
        try self.resource_binder.bindStorageBufferArrayNamed(
            self.light_volume_pipeline,
            "LightVolumeBuffer",
            self.light_volume_buffers,
        );
    }

    fn executeImpl(base: *RenderPass, frame_info: FrameInfo) !void {
        const self: *LightVolumePass = @fieldParentPtr("base", base);
        const cmd = frame_info.command_buffer;
        const frame_index = frame_info.current_frame;

        // Get cached lights (light system handles caching internally)
        const light_data = try self.light_system.getLights(self.ecs_world);

        if (light_data.lights.items.len == 0) {
            return; // No lights to render
        }

        // Update SSBO with light data for this frame
        const light_count = @min(light_data.lights.items.len, self.max_lights);
        var light_volumes = try self.allocator.alloc(LightVolumeData, light_count);
        defer self.allocator.free(light_volumes);

        for (light_data.lights.items[0..light_count], 0..) |light, i| {
            light_volumes[i] = LightVolumeData{
                .position = [4]f32{ light.position.x, light.position.y, light.position.z, 1.0 },
                .color = [4]f32{
                    light.color.x * light.intensity,
                    light.color.y * light.intensity,
                    light.color.z * light.intensity,
                    1.0,
                },
                .radius = @max(0.1, light.intensity * 0.2),
            };
        }

        // Write to SSBO (ManagedBuffer)
        const buffer_size = @sizeOf(LightVolumeData) * light_count;
        const light_bytes = std.mem.sliceAsBytes(light_volumes);
        self.light_volume_buffers[frame_index].buffer.writeToBuffer(light_bytes, buffer_size, 0);

        // Setup dynamic rendering with load operations (don't clear, render on top of geometry)
        const helper = DynamicRenderingHelper.initLoad(
            frame_info.hdr_texture.?.image_view,
            frame_info.depth_image_view,
            frame_info.extent,
        );

        helper.begin(self.graphics_context, cmd);
        defer helper.end(self.graphics_context, cmd);

        // Check for pipeline hot-reload
        const pipeline_entry = self.pipeline_system.pipelines.get(self.light_volume_pipeline) orelse return error.PipelineNotFound;
        const pipeline_rebuilt = pipeline_entry.vulkan_pipeline != self.cached_pipeline_handle;

        if (pipeline_rebuilt) {
            log(.INFO, "light_volume_pass", "Pipeline hot-reloaded, rebinding resources", .{});
            self.cached_pipeline_handle = pipeline_entry.vulkan_pipeline;
            self.resource_binder.clearPipeline(self.light_volume_pipeline);

            // Rebind resources after hot reload
            try self.bindResources();
            self.pipeline_system.markPipelineResourcesDirty(self.light_volume_pipeline);
        }

        try self.pipeline_system.bindPipelineWithDescriptorSets(cmd, self.light_volume_pipeline, frame_info.current_frame);

        // Instanced draw - single draw call for all lights
        // 6 vertices per billboard, light_count instances
        self.graphics_context.vkd.cmdDraw(cmd, 6, @intCast(light_count), 0, 0);
    }

    fn teardownImpl(base: *RenderPass) void {
        const self: *LightVolumePass = @fieldParentPtr("base", base);
        log(.INFO, "light_volume_pass", "Tearing down", .{});

        // Clean up SSBO buffers (ManagedBuffers destroyed by BufferManager)
        for (self.light_volume_buffers) |buffer| {
            self.buffer_manager.destroyBuffer(buffer) catch |err| {
                log(.ERROR, "light_volume_pass", "Failed to destroy buffer: {}", .{err});
            };
        }

        self.light_system.deinit();
        self.allocator.destroy(self);
    }

    /// Reset pass state and release resources
    /// Called when the render graph is reset (e.g. scene change)
    /// Clears resource bindings and destroys pipeline to prevent dangling references
    fn reset(ctx: *RenderPass) void {
        const self: *LightVolumePass = @fieldParentPtr("base", ctx);
        self.resource_binder.clear();
        
        if (self.cached_pipeline_handle != .null_handle) {
            self.pipeline_system.destroyPipeline(self.light_volume_pipeline);
            self.cached_pipeline_handle = .null_handle;
        }
        
        log(.INFO, "light_volume_pass", "Reset resources", .{});
    }
};
