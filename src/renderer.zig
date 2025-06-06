const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("graphics_context.zig").GraphicsContext;
const Scene = @import("scene.zig").Scene;
const Pipeline = @import("pipeline.zig").Pipeline;
const ShaderLibrary = @import("shader.zig").ShaderLibrary;
const Math = @import("utils/math.zig");
const glfw = @import("mach-glfw");
const Camera = @import("camera.zig").Camera;
const FrameInfo = @import("frameinfo.zig").FrameInfo;
const GlobalUbo = @import("frameinfo.zig").GlobalUbo;
const Geometry = @import("geometry.zig").Geometry;
const ComputeShaderSystem = @import("systems/compute_shader_system.zig").ComputeShaderSystem;
const Buffer = @import("buffer.zig").Buffer;
const DescriptorPool = @import("descriptors.zig").DescriptorPool;
const DescriptorSetLayout = @import("descriptors.zig").DescriptorSetLayout;
const DescriptorWriter = @import("descriptors.zig").DescriptorWriter;
const MAX_FRAMES_IN_FLIGHT = @import("swapchain.zig").MAX_FRAMES_IN_FLIGHT;

const SimplePushConstantData = extern struct {
    transform: [16]f32 = Math.Mat4x4.identity().data,
    normal_matrix: [16]f32 = Math.Mat4x4.identity().data,
};

const PointLightPushConstant = struct {
    position: Math.Vec4 = Math.Vec4.init(0, 0, 0, 1),
    color: Math.Vec4 = Math.Vec4.init(1, 1, 1, 1),
    radius: f32 = 1.0,
};

pub const SimpleRenderer = struct {
    scene: *Scene = undefined,
    pipeline: Pipeline = undefined,
    gc: *GraphicsContext = undefined,
    pipeline_layout: vk.PipelineLayout = undefined,
    camera: *Camera = undefined,

    pub fn init(gc: *GraphicsContext, render_pass: vk.RenderPass, scene: *Scene, shader_library: ShaderLibrary, alloc: std.mem.Allocator, camera: *Camera, global_set_layout: vk.DescriptorSetLayout) !SimpleRenderer {
        const pcr = [_]vk.PushConstantRange{.{ .stage_flags = .{ .vertex_bit = true, .fragment_bit = true }, .offset = 0, .size = @sizeOf(SimplePushConstantData) }};
        const dsl = [_]vk.DescriptorSetLayout{global_set_layout};
        const layout = try gc.vkd.createPipelineLayout(
            gc.*.dev,
            &vk.PipelineLayoutCreateInfo{
                .flags = .{},
                .set_layout_count = dsl.len,
                .p_set_layouts = &dsl,
                .push_constant_range_count = 1,
                .p_push_constant_ranges = &pcr,
            },
            null,
        );
        const pipeline = try Pipeline.init(gc.*, render_pass, shader_library, layout, try Pipeline.defaultLayout(layout), alloc);
        return SimpleRenderer{ .scene = scene, .pipeline = pipeline, .gc = gc, .pipeline_layout = layout, .camera = camera };
    }

    pub fn deinit(self: *SimpleRenderer) void {
        self.gc.*.vkd.destroyPipelineLayout(self.gc.*.dev, self.pipeline_layout, null);
        self.pipeline.deinit();
    }

    pub fn render(self: *@This(), frame_info: FrameInfo) !void {
        self.gc.*.vkd.cmdBindPipeline(frame_info.command_buffer, .graphics, self.pipeline.pipeline);
        self.gc.vkd.cmdBindDescriptorSets(frame_info.command_buffer, .graphics, self.pipeline_layout, 0, 1, @ptrCast(&frame_info.global_descriptor_set), 0, null);
        for (self.scene.objects.slice()) |*object| {
            if (object.geometry == null) continue;
            const push = SimplePushConstantData{
                .transform = object.transform.local2world.data,
                .normal_matrix = object.transform.normal2world.data,
            };
            self.gc.*.vkd.cmdPushConstants(frame_info.command_buffer, self.pipeline_layout, .{ .vertex_bit = true, .fragment_bit = true }, 0, @sizeOf(SimplePushConstantData), @ptrCast(&push));
            try object.render(self.gc.*, frame_info.command_buffer);
        }
    }
};

pub const PointLightRenderer = struct {
    scene: *Scene = undefined,
    pipeline: Pipeline = undefined,
    gc: *GraphicsContext = undefined,
    pipeline_layout: vk.PipelineLayout = undefined,
    camera: *Camera = undefined,

    pub fn init(gc: *GraphicsContext, render_pass: vk.RenderPass, scene: *Scene, shader_library: ShaderLibrary, alloc: std.mem.Allocator, camera: *Camera, global_set_layout: vk.DescriptorSetLayout) !PointLightRenderer {
        const pcr = [_]vk.PushConstantRange{.{ .stage_flags = .{ .vertex_bit = true, .fragment_bit = true }, .offset = 0, .size = @sizeOf(PointLightPushConstant) }};
        const dsl = [_]vk.DescriptorSetLayout{global_set_layout};
        const layout = try gc.*.vkd.createPipelineLayout(
            gc.*.dev,
            &vk.PipelineLayoutCreateInfo{
                .flags = .{},
                .set_layout_count = dsl.len,
                .p_set_layouts = &dsl,
                .push_constant_range_count = pcr.len,
                .p_push_constant_ranges = &pcr,
            },
            null,
        );
        const pipeline = try Pipeline.init(gc.*, render_pass, shader_library, layout, try Pipeline.defaultLayout(layout), alloc);
        return PointLightRenderer{ .scene = scene, .pipeline = pipeline, .gc = gc, .pipeline_layout = layout, .camera = camera };
    }

    pub fn update_point_lights(self: *@This(), frame_info: *FrameInfo, global_ubo: *GlobalUbo) !void {
        _ = frame_info;
        var num_lights: u32 = 0;
        for (self.scene.objects.slice()) |*object| {
            if (object.point_light == null) {
                continue;
            }

            global_ubo.point_lights[num_lights].color = Math.Vec4.init(object.point_light.?.color.x, object.point_light.?.color.y, object.point_light.?.color.z, object.point_light.?.intensity);

            global_ubo.point_lights[num_lights].position = Math.Vec4.init(
                object.transform.local2world.data[12],
                object.transform.local2world.data[13],
                object.transform.local2world.data[14],
                object.transform.local2world.data[15],
            );
            num_lights += 1;
        }

        global_ubo.num_point_lights = num_lights;
    }

    pub fn deinit(self: *@This()) void {
        self.gc.*.vkd.destroyPipelineLayout(self.gc.*.dev, self.pipeline_layout, null);
        self.pipeline.deinit();
    }

    pub fn render(self: *@This(), frame_info: FrameInfo) !void {
        self.gc.*.vkd.cmdBindPipeline(frame_info.command_buffer, .graphics, self.pipeline.pipeline);

        self.gc.vkd.cmdBindDescriptorSets(frame_info.command_buffer, .graphics, self.pipeline_layout, 0, 1, @ptrCast(&frame_info.global_descriptor_set), 0, null);
        for (self.scene.objects.slice()) |*object| {
            if (object.point_light == null) {
                continue;
            }
            const push = PointLightPushConstant{ .position = Math.Vec4.init(
                object.transform.local2world.data[12],
                object.transform.local2world.data[13],
                object.transform.local2world.data[14],
                object.transform.local2world.data[15],
            ), .color = Math.Vec4.init(object.point_light.?.color.x, object.point_light.?.color.y, object.point_light.?.color.z, object.point_light.?.intensity), .radius = object.transform.object_scale.x };

            self.gc.*.vkd.cmdPushConstants(frame_info.command_buffer, self.pipeline_layout, .{ .vertex_bit = true, .fragment_bit = true }, 0, @sizeOf(PointLightPushConstant), @ptrCast(&push));
            self.gc.vkd.cmdDraw(frame_info.command_buffer, 6, 1, 0, 0);
        }
    }
};

pub const ParticleRenderer = struct {
    gc: *GraphicsContext = undefined,
    compute_system: *ComputeShaderSystem = undefined,
    raster_pipeline: Pipeline = undefined,
    compute_pipeline: Pipeline = undefined,
    particle_buffer: Buffer = undefined,
    descriptor_set: vk.DescriptorSet = undefined,
    descriptor_set_layout: vk.DescriptorSetLayout = undefined,
    num_particles: usize = 0,

    pub fn init(
        gc: *GraphicsContext,
        compute_system: *ComputeShaderSystem,
        render_pass: vk.RenderPass,
        raster_shader_library: ShaderLibrary,
        compute_shader_library: ShaderLibrary,
        allocator: std.mem.Allocator,
        num_particles: usize,
        descriptor_pool: *DescriptorPool,
    ) !ParticleRenderer {
        // Create storage buffer for particles
        const particle_buffer = try Buffer.init(
            gc,
            @sizeOf(Math.Vec4) * num_particles,
            1,
            .{ .storage_buffer_bit = true },
            .{ .device_local_bit = true },
        );
        var pool_builder = DescriptorPool.Builder{
            .gc = gc,
            .poolSizes = std.ArrayList(vk.DescriptorPoolSize).init(allocator),
            .poolFlags = .{},
            .maxSets = 0,
        };
        const pool = try allocator.create(DescriptorPool);
        pool.* = try pool_builder
            .setMaxSets(@intCast(MAX_FRAMES_IN_FLIGHT))
            .addPoolSize(.storage_buffer, @intCast(MAX_FRAMES_IN_FLIGHT)).build();

        var layout_builder = DescriptorSetLayout.Builder{
            .gc = gc,
            .bindings = std.AutoHashMap(u32, vk.DescriptorSetLayoutBinding).init(allocator),
        };
        const layout = try allocator.create(DescriptorSetLayout);
        layout.* = try layout_builder
            .addBinding(0, .storage_buffer, .{ .vertex_bit = true, .fragment_bit = true }, 1)
            .build();
        // Allocate descriptor set
        var descriptor_set = try descriptor_pool.allocate(&layout);
        // Write buffer info to descriptor set
        var buffer_info = vk.DescriptorBufferInfo{
            .buffer = particle_buffer.buffer,
            .offset = 0,
            .range = @sizeOf(Math.Vec4) * num_particles,
        };
        DescriptorWriter.init(gc, &layout, descriptor_pool)
            .writeBuffer(0, &buffer_info)
            .build(&descriptor_set) catch |err| return err;
        const pcr = [_]vk.PushConstantRange{.{ .stage_flags = .{ .vertex_bit = true }, .offset = 0, .size = 0 }};
        const dsl_arr = [_]vk.DescriptorSetLayout{layout.descriptor_set_layout};
        // Create raster pipeline layout
        const raster_pipeline_layout = try gc.vkd.createPipelineLayout(
            gc.*.dev,
            &vk.PipelineLayoutCreateInfo{
                .flags = .{},
                .set_layout_count = dsl_arr.len,
                .p_set_layouts = &dsl_arr,
                .push_constant_range_count = pcr.len,
                .p_push_constant_ranges = &pcr,
            },
            null,
        );
        // Create raster pipeline using Pipeline.init and default create info
        const raster_pipeline = try Pipeline.init(
            gc.*,
            render_pass,
            raster_shader_library,
            raster_pipeline_layout,
            Pipeline.defaultLayout(raster_pipeline_layout, render_pass),
            allocator,
        );
        // Create compute pipeline layout
        const compute_pipeline_layout = try gc.vkd.createPipelineLayout(
            gc.*.dev,
            &vk.PipelineLayoutCreateInfo{
                .flags = .{},
                .set_layout_count = dsl_arr.len,
                .p_set_layouts = &dsl_arr,
                .push_constant_range_count = 0,
                .p_push_constant_ranges = null,
            },
            null,
        );
        // Create compute pipeline using Pipeline.initCompute and default create info
        const compute_pipeline = try Pipeline.initCompute(
            gc.*,
            .null_handle, // render_pass unused for compute
            compute_shader_library,
            compute_pipeline_layout,
            Pipeline.defaultComputeLayout(compute_pipeline_layout),
        );
        return ParticleRenderer{
            .gc = gc,
            .compute_system = compute_system,
            .raster_pipeline = raster_pipeline,
            .compute_pipeline = compute_pipeline,
            .particle_buffer = particle_buffer,
            .descriptor_set = descriptor_set,
            .descriptor_set_layout = layout,
            .num_particles = num_particles,
        };
    }

    pub fn deinit(self: *ParticleRenderer) void {
        self.raster_pipeline.deinit();
        self.compute_pipeline.deinit();
        self.particle_buffer.deinit();
        self.descriptor_set_layout.deinit();
    }

    pub fn render(self: *ParticleRenderer, frame_info: FrameInfo) !void {
        // Render particles as points using the raster pipeline
        self.gc.*.vkd.cmdBindPipeline(frame_info.command_buffer, .graphics, self.raster_pipeline.pipeline);
        self.gc.vkd.cmdBindDescriptorSets(frame_info.command_buffer, .graphics, self.raster_pipeline.pipeline_layout, 0, 1, @ptrCast(&self.descriptor_set), 0, null);
        self.gc.vkd.cmdDraw(frame_info.command_buffer, @intCast(self.num_particles), 1, 0, 0);
    }

    pub fn dispatch(self: *ParticleRenderer, frame_info: FrameInfo, group_count_x: u32, group_count_y: u32, group_count_z: u32) void {
        // Dispatch compute shader using the owned compute pipeline
        self.gc.*.vkd.cmdBindPipeline(frame_info.compute_buffer, .compute, self.compute_pipeline.pipeline);
        self.gc.vkd.cmdBindDescriptorSets(frame_info.compute_buffer, .compute, self.compute_pipeline.pipeline_layout, 0, 1, @ptrCast(&self.descriptor_set), 0, null);
        self.gc.vkd.cmdDispatch(frame_info.compute_buffer, group_count_x, group_count_y, group_count_z);
    }
};
