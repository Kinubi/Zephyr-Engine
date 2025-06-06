const std = @import("std");
const vk = @import("vulkan");
const DescriptorPool = @import("descriptors.zig").DescriptorPool;
const DescriptorSetLayout = @import("descriptors.zig").DescriptorSetLayout;
const DescriptorWriter = @import("descriptors.zig").DescriptorWriter;
const GraphicsContext = @import("graphics_context.zig").GraphicsContext;

pub const RaytracingDescriptorSet = struct {
    pool: *DescriptorPool,
    layout: *DescriptorSetLayout,
    set: vk.DescriptorSet,

    pub fn deinit(self: *RaytracingDescriptorSet) void {
        _ = self;
        // Optionally deinit pool/layout/set if you own them
    }

    pub fn createPoolAndLayout(
        gc: *GraphicsContext,
        allocator: std.mem.Allocator,
        ubo_count: usize,
        vertex_buffer_count: usize,
        index_buffer_count: usize,
        material_count: usize,
        texture_count: usize,
    ) !struct {
        pool: *DescriptorPool,
        layout: *DescriptorSetLayout,
    } {
        var pool_builder = DescriptorPool.Builder{
            .gc = gc,
            .poolSizes = std.ArrayList(vk.DescriptorPoolSize).init(allocator),
            .poolFlags = .{ .free_descriptor_set_bit = true },
            .maxSets = 0,
        };
        const pool = try allocator.create(DescriptorPool);
        pool.* = try pool_builder
            .setMaxSets(1000)
            .addPoolSize(.storage_image, 1000)
            .addPoolSize(.acceleration_structure_khr, 1000)
            .addPoolSize(.uniform_buffer, @intCast(ubo_count))
            .addPoolSize(.storage_buffer, @intCast(vertex_buffer_count + index_buffer_count))
            .addPoolSize(.storage_buffer, @intCast(material_count))
            .addPoolSize(.combined_image_sampler, @intCast(texture_count))
            .build();

        var layout_builder = DescriptorSetLayout.Builder{
            .gc = gc,
            .bindings = std.AutoHashMap(u32, vk.DescriptorSetLayoutBinding).init(allocator),
        };
        const layout = try allocator.create(DescriptorSetLayout);
        layout.* = try layout_builder
            .addBinding(0, .acceleration_structure_khr, .{ .raygen_bit_khr = true }, 1)
            .addBinding(1, .storage_image, .{ .raygen_bit_khr = true }, 1)
            .addBinding(2, .uniform_buffer, .{ .raygen_bit_khr = true }, 1)
            .addBinding(3, .storage_buffer, .{ .raygen_bit_khr = true, .closest_hit_bit_khr = true }, @intCast(vertex_buffer_count))
            .addBinding(4, .storage_buffer, .{ .raygen_bit_khr = true, .closest_hit_bit_khr = true }, @intCast(index_buffer_count))
            .addBinding(5, .storage_buffer, .{ .closest_hit_bit_khr = true }, 1)
            .addBinding(6, .combined_image_sampler, .{ .closest_hit_bit_khr = true }, @intCast(texture_count))
            .build();
        return .{ .pool = pool, .layout = layout };
    }

    pub fn createDescriptorSet(
        gc: *GraphicsContext,
        pool: *DescriptorPool,
        layout: *DescriptorSetLayout,
        accel_info: *vk.WriteDescriptorSetAccelerationStructureKHR,
        output_image_info: *vk.DescriptorImageInfo,
        ubo_infos: []const vk.DescriptorBufferInfo,
        vertex_buffer_infos: []const vk.DescriptorBufferInfo,
        index_buffer_infos: []const vk.DescriptorBufferInfo,
        material_buffer_info: vk.DescriptorBufferInfo,
        texture_image_infos: []const vk.DescriptorImageInfo,
    ) !vk.DescriptorSet {
        var set: vk.DescriptorSet = undefined;
        var writer = DescriptorWriter.init(gc, layout, pool);
        try writer.writeAccelerationStructure(0, accel_info)
            .writeImage(1, output_image_info)
            .build(&set);
        for (ubo_infos) |info| {
            try writer.writeBuffer(2, @constCast(&info)).build(&set);
        }
        if (vertex_buffer_infos.len > 0) {
            try writer.writeBuffers(3, vertex_buffer_infos).build(&set);
        }
        if (index_buffer_infos.len > 0) {
            try writer.writeBuffers(4, index_buffer_infos).build(&set);
        }
        // Bind material buffer (SSBO or UBO)
        try writer.writeBuffer(5, @constCast(&material_buffer_info)).build(&set);
        // Bind texture array (array of combined image samplers)
        if (texture_image_infos.len > 0) {
            try writer.writeImages(6, texture_image_infos).build(&set);
        }
        return set;
    }
};
