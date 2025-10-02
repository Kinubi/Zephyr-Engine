const std = @import("std");
const vk = @import("vulkan");
const DescriptorPool = @import("../core/descriptors.zig").DescriptorPool;
const DescriptorSetLayout = @import("../core/descriptors.zig").DescriptorSetLayout;
const DescriptorWriter = @import("../core/descriptors.zig").DescriptorWriter;
const GraphicsContext = @import("../core/graphics_context.zig").GraphicsContext;

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
            .poolSizes = std.ArrayList(vk.DescriptorPoolSize){},
            .poolFlags = .{ .free_descriptor_set_bit = true },
            .maxSets = 0,
            .allocator = allocator,
        };
        const pool = try allocator.create(DescriptorPool);
        pool.* = try pool_builder
            .setMaxSets(1000)
            .addPoolSize(.storage_image, 1000)
            .addPoolSize(.acceleration_structure_khr, 1000)
            .addPoolSize(.uniform_buffer, @intCast(@max(ubo_count, 1))) // Global UBO
            .addPoolSize(.storage_buffer, @intCast(@max(vertex_buffer_count + index_buffer_count + material_count, 1))) // All storage buffers combined
            .addPoolSize(.combined_image_sampler, @intCast(@max(texture_count, 1))) // Textures
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
            .addBinding(3, .storage_buffer, .{ .raygen_bit_khr = true, .closest_hit_bit_khr = true }, @intCast(@max(vertex_buffer_count, 1))) // Ensure at least 1 for runtime array
            .addBinding(4, .storage_buffer, .{ .raygen_bit_khr = true, .closest_hit_bit_khr = true }, @intCast(@max(index_buffer_count, 1))) // Ensure at least 1 for runtime array
            .addBinding(5, .storage_buffer, .{ .closest_hit_bit_khr = true }, 1)
            .addBinding(6, .combined_image_sampler, .{ .closest_hit_bit_khr = true }, 1) // Ensure at least 1 for runtime array
            .build();
        return .{ .pool = pool, .layout = layout };
    }

    pub fn createDescriptorSet(
        gc: *GraphicsContext,
        pool: *DescriptorPool,
        layout: *DescriptorSetLayout,
        allocator: std.mem.Allocator,
        accel_info: *vk.WriteDescriptorSetAccelerationStructureKHR,
        output_image_info: *vk.DescriptorImageInfo,
        ubo_infos: []const vk.DescriptorBufferInfo,
        vertex_buffer_infos: []const vk.DescriptorBufferInfo,
        index_buffer_infos: []const vk.DescriptorBufferInfo,
        material_buffer_info: vk.DescriptorBufferInfo,
        texture_image_infos: []const vk.DescriptorImageInfo,
    ) !vk.DescriptorSet {
        var set: vk.DescriptorSet = undefined;
        var writer = DescriptorWriter.init(gc, layout, pool, allocator);
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
