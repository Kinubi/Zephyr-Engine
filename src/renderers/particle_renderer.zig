// ParticleRenderer moved from renderer.zig
const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("../core/graphics_context.zig").GraphicsContext;
const Pipeline = @import("../core/pipeline.zig").Pipeline;
const ShaderLibrary = @import("../core/shader.zig").ShaderLibrary;
const Math = @import("../utils/math.zig");
const FrameInfo = @import("../rendering/frameinfo.zig").FrameInfo;
const Buffer = @import("../core/buffer.zig").Buffer;
const DescriptorPool = @import("../core/descriptors.zig").DescriptorPool;
const DescriptorSetLayout = @import("../core/descriptors.zig").DescriptorSetLayout;
const DescriptorWriter = @import("../core/descriptors.zig").DescriptorWriter;
const RenderSystem = @import("../systems/render_system.zig").RenderSystem;
const deinitDescriptorResources = @import("../core/descriptors.zig").deinitDescriptorResources;
const log = @import("../utils/log.zig").log;

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
        .{ .binding = 0, .location = 0, .format = .r32g32_sfloat, .offset = @offsetOf(Particle, "position") },
        .{ .binding = 0, .location = 1, .format = .r32g32_sfloat, .offset = @offsetOf(Particle, "velocity") },
        .{ .binding = 0, .location = 2, .format = .r32g32b32a32_sfloat, .offset = @offsetOf(Particle, "color") },
    };
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
            .poolSizes = std.ArrayList(vk.DescriptorPoolSize){},
            .poolFlags = .{ .free_descriptor_set_bit = true },
            .maxSets = 0,
            .allocator = allocator,
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
        var writer = DescriptorWriter.init(gc, layout, pool, allocator);
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
        default_render_create_info.p_input_assembly_state = &.{ .topology = .point_list, .primitive_restart_enable = .false };
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
        log(.DEBUG, "particle_renderer", "Deinitializing ParticleRenderer: raster_pipeline handle={x}, compute_pipeline handle={x}", .{ self.raster_pipeline.pipeline, self.compute_pipeline.pipeline });
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
        self.gc.*.vkd.cmdBindPipeline(frame_info.command_buffer, .graphics, self.raster_pipeline.pipeline);
        self.gc.vkd.cmdBindDescriptorSets(frame_info.command_buffer, .graphics, self.raster_pipeline.pipeline_layout, 0, 1, @ptrCast(&self.descriptor_set), 0, null);
        self.gc.vkd.cmdBindVertexBuffers(frame_info.command_buffer, 0, 1, @ptrCast(&self.particle_buffer_in.buffer), &.{0});
        self.gc.vkd.cmdDraw(frame_info.command_buffer, @intCast(self.num_particles), 1, 0, 0);
    }
    pub fn dispatch(self: *ParticleRenderer) void {
        self.gc.copyBuffer(self.particle_buffer_in.buffer, self.particle_buffer_out.buffer, @sizeOf(Particle) * self.num_particles) catch |err| {
            std.debug.print("Failed to copy particle buffers: {}\n", .{err});
            return;
        };
    }
    fn initialiseParticles(self: *ParticleRenderer, width: f32, height: f32) !void {
        const buffer_size = @sizeOf(Particle) * self.num_particles;
        var staging_buffer = try Buffer.init(
            self.gc,
            buffer_size,
            1,
            .{ .transfer_src_bit = true },
            .{ .host_visible_bit = true, .host_coherent_bit = true },
        );
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
            const len = @sqrt(x * x + y * y);
            const vx = if (len > 0.0) (x / len) * vel_scale else 0.0;
            const vy = if (len > 0.0) (y / len) * vel_scale else 0.0;
            const color = .{ rand.float(f32), rand.float(f32), rand.float(f32), 1.0 };
            particle.* = Particle{
                .position = .{ x, y },
                .velocity = .{ vx, vy },
                .color = color,
            };
        }
        try staging_buffer.map(buffer_size, 0);
        staging_buffer.writeToBuffer(std.mem.sliceAsBytes(particle_data), buffer_size, 0);
        try self.gc.copyBuffer(self.particle_buffer_in.buffer, staging_buffer.buffer, buffer_size);
        try self.gc.copyBuffer(self.particle_buffer_out.buffer, staging_buffer.buffer, buffer_size);
        staging_buffer.deinit();
    }
};
