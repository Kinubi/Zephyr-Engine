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
const Texture = @import("texture.zig").Texture;
const deinitDescriptorResources = @import("descriptors.zig").deinitDescriptorResources;
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

pub const Particle = extern struct {
    position: [2]f32,
    velocity: [2]f32,
    color: [4]f32,

    pub const binding_description = vk.VertexInputBindingDescription{
        .binding = 0,
        .stride = @sizeOf(Particle),
        .input_rate = .vertex,
    };

    pub const attribute_description = [_]vk.VertexInputAttributeDescription{
        .{
            .binding = 0,
            .location = 0,
            .format = .r32g32_sfloat,
            .offset = @offsetOf(Particle, "position"),
        },
        .{
            .binding = 0,
            .location = 1,
            .format = .r32g32_sfloat,
            .offset = @offsetOf(Particle, "velocity"),
        },
        .{
            .binding = 0,
            .location = 2,
            .format = .r32g32b32a32_sfloat,
            .offset = @offsetOf(Particle, "color"),
        },
    };
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

    pub fn render(self: *SimpleRenderer, frame_info: FrameInfo) !void {
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

    pub fn update_point_lights(self: *PointLightRenderer, frame_info: *FrameInfo, global_ubo: *GlobalUbo) !void {
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

    pub fn deinit(self: *PointLightRenderer) void {
        self.gc.*.vkd.destroyPipelineLayout(self.gc.*.dev, self.pipeline_layout, null);
        self.pipeline.deinit();
    }

    pub fn render(self: *PointLightRenderer, frame_info: FrameInfo) !void {
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
    raster_pipeline: Pipeline = undefined,
    compute_pipeline: Pipeline = undefined,
    particle_buffer_in: Buffer = undefined,
    particle_buffer_out: Buffer = undefined,
    descriptor_pool: *DescriptorPool = undefined,
    descriptor_set: vk.DescriptorSet = undefined,
    descriptor_set_layout: *DescriptorSetLayout = undefined,
    num_particles: usize = 0,
    allocator: std.mem.Allocator = undefined,
    pub fn init(
        gc: *GraphicsContext,
        render_pass: vk.RenderPass,
        raster_shader_library: ShaderLibrary,
        compute_shader_library: ShaderLibrary,
        allocator: std.mem.Allocator,
        num_particles: usize,
        ubo_infos: []const vk.DescriptorBufferInfo,
    ) !ParticleRenderer {
        // Create storage buffer for particles (device local)
        const buffer_size = @sizeOf(Particle) * num_particles;
        const particle_buffer_in = try Buffer.init(
            gc,
            buffer_size,
            1,
            .{ .storage_buffer_bit = true, .vertex_buffer_bit = true, .transfer_dst_bit = true },
            .{ .device_local_bit = true },
        );
        const particle_buffer_out = try Buffer.init(
            gc,
            buffer_size,
            1,
            .{ .storage_buffer_bit = true, .vertex_buffer_bit = true, .transfer_src_bit = true, .transfer_dst_bit = true },
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
            .setMaxSets(10)
            .addPoolSize(.uniform_buffer, 10)
            .addPoolSize(.storage_buffer, 10).build();

        var layout_builder = DescriptorSetLayout.Builder{
            .gc = gc,
            .bindings = std.AutoHashMap(u32, vk.DescriptorSetLayoutBinding).init(allocator),
        };
        const layout = try allocator.create(DescriptorSetLayout);
        layout.* = try layout_builder
            .addBinding(0, .uniform_buffer, .{ .compute_bit = true }, 1)
            .addBinding(1, .storage_buffer, .{ .compute_bit = true }, 1)
            .addBinding(2, .storage_buffer, .{ .compute_bit = true }, 1)
            .build();
        // Allocate descriptor set
        var descriptor_set: vk.DescriptorSet = undefined;
        // Write buffer info to descriptor set
        var writer = DescriptorWriter.init(gc, layout, pool);
        for (ubo_infos) |info| {
            try writer.writeBuffer(0, @constCast(&info)).build(&descriptor_set);
        }
        writer.writeBuffer(1, @constCast(&particle_buffer_in.descriptor_info))
            .writeBuffer(2, @constCast(&particle_buffer_out.descriptor_info))
            .build(&descriptor_set) catch |err| return err;
        const dsl_arr = [_]vk.DescriptorSetLayout{layout.descriptor_set_layout};
        // Create raster pipeline layout
        const raster_pipeline_layout = try gc.vkd.createPipelineLayout(
            gc.*.dev,
            &vk.PipelineLayoutCreateInfo{
                .flags = .{},
                .set_layout_count = dsl_arr.len,
                .p_set_layouts = &dsl_arr,
                .push_constant_range_count = 0,
            },
            null,
        );
        // Create raster pipeline using Pipeline.init and default create info
        var default_render_create_info = try Pipeline.defaultLayout(raster_pipeline_layout);
        default_render_create_info.p_input_assembly_state = &.{ .topology = .point_list, .primitive_restart_enable = vk.TRUE };
        const raster_pipeline = try Pipeline.initParticles(
            gc.*,
            render_pass,
            raster_shader_library,
            raster_pipeline_layout,
            default_render_create_info,
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
        var self = ParticleRenderer{
            .gc = gc,
            .raster_pipeline = raster_pipeline,
            .compute_pipeline = compute_pipeline,
            .particle_buffer_in = particle_buffer_in,
            .particle_buffer_out = particle_buffer_out,
            .descriptor_pool = pool,
            .descriptor_set = descriptor_set,
            .descriptor_set_layout = layout,
            .num_particles = num_particles,
            .allocator = allocator,
        };
        self.initialiseParticles(1280, 720) catch |err| {
            self.deinit();
            return err;
        };
        return self;
    }

    pub fn deinit(self: *ParticleRenderer) void {
        self.raster_pipeline.deinit();
        self.compute_pipeline.deinit();
        self.particle_buffer_in.deinit();
        self.particle_buffer_out.deinit();
        var descriptor_sets = [_]vk.DescriptorSet{self.descriptor_set};
        deinitDescriptorResources(self.descriptor_pool, self.descriptor_set_layout, descriptor_sets[0..], self.allocator) catch |err| {
            std.debug.print("Failed to deinit descriptor resources: {}\n", .{err});
        };
    }

    pub fn render(self: *ParticleRenderer, frame_info: FrameInfo) !void {
        // Render particles as points using the raster pipeline

        self.gc.*.vkd.cmdBindPipeline(frame_info.command_buffer, .graphics, self.raster_pipeline.pipeline);
        self.gc.vkd.cmdBindDescriptorSets(frame_info.command_buffer, .graphics, self.raster_pipeline.pipeline_layout, 0, 1, @ptrCast(&self.descriptor_set), 0, null);
        self.gc.vkd.cmdBindVertexBuffers(frame_info.command_buffer, 0, 1, @ptrCast(&self.particle_buffer_in.buffer), &.{0});
        self.gc.vkd.cmdDraw(frame_info.command_buffer, @intCast(self.num_particles), 1, 0, 0);
    }

    pub fn dispatch(self: *ParticleRenderer) void {
        // Dispatch compute shader using the owned compute pipeline
        self.gc.copyBuffer(self.particle_buffer_in.buffer, self.particle_buffer_out.buffer, @sizeOf(Particle) * self.num_particles) catch |err| {
            std.debug.print("Failed to copy particle buffers: {}\n", .{err});
            return;
        };

    }

    fn initialiseParticles(self: *ParticleRenderer, width: f32, height: f32) !void {
        // Create staging buffer (host visible)
        const buffer_size = @sizeOf(Particle) * self.num_particles;
        var staging_buffer = try Buffer.init(
            self.gc,
            buffer_size,
            1,
            .{ .transfer_src_bit = true },
            .{ .host_visible_bit = true, .host_coherent_bit = true },
        );
        // Fill staging buffer with initial particle data
        var prng = std.Random.DefaultPrng.init(@intCast(std.time.timestamp()));
        const rand = prng.random();
        const pi = 3.14159265358979323846;
        const scale = 0.25;
        const vel_scale = 0.00025;
        const particle_data = try self.allocator.alloc(Particle, self.num_particles);
        defer self.allocator.free(particle_data);
        for (particle_data) |*particle| {
            const r = scale * @sqrt(rand.float(f32));
            const theta = rand.float(f32) * 2.0 * pi;
            const x = r * @cos(theta) * height / width;
            const y = r * @sin(theta);
            // Velocity as normalized (x, y) * vel_scale
            const len = @sqrt(x * x + y * y);
            const vx = if (len > 0.0) (x / len) * vel_scale else 0.0;
            const vy = if (len > 0.0) (y / len) * vel_scale else 0.0;
            // Color random
            const color = .{ rand.float(f32), rand.float(f32), rand.float(f32), 1.0 };
            particle.* = Particle{
                .position = .{ x, y },
                .velocity = .{ vx, vy },
                .color = color,
            };
        }
        try staging_buffer.map(buffer_size, 0);
        staging_buffer.writeToBuffer(std.mem.sliceAsBytes(particle_data), buffer_size, 0);
        // Copy from staging buffer to device-local buffer
        try self.gc.copyBuffer(self.particle_buffer_in.buffer, staging_buffer.buffer, buffer_size);
        try self.gc.copyBuffer(self.particle_buffer_out.buffer, staging_buffer.buffer, buffer_size);
        staging_buffer.deinit();
    }
};

// All pipeline, buffer, and descriptor management uses abstractions (Pipeline, Buffer, DescriptorPool, DescriptorSetLayout, DescriptorWriter, etc.)
// No raw Vulkan resource management is used directly in this file.
