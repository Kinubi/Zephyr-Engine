const std = @import("std");
const vk = @import("vulkan");

pub fn mergeDescriptorBinding(allocator: std.mem.Allocator, list: *std.ArrayList(vk.DescriptorSetLayoutBinding), binding_idx: u32, dtype: vk.DescriptorType, sflags: vk.ShaderStageFlags, descriptor_count: u32) !void {
    var j: usize = 0;
    while (j < list.items.len) : (j += 1) {
        if (list.items[j].binding == binding_idx) {
            list.items[j].stage_flags = vk.ShaderStageFlags.merge(list.items[j].stage_flags, sflags);
            if (list.items[j].descriptor_count < descriptor_count) list.items[j].descriptor_count = descriptor_count;
            if (list.items[j].descriptor_type != dtype) {
                if (list.items[j].descriptor_type == .sampler and dtype == .combined_image_sampler) {
                    list.items[j].descriptor_type = .combined_image_sampler;
                } else if (list.items[j].descriptor_type == .uniform_buffer and dtype == .storage_buffer) {
                    list.items[j].descriptor_type = .storage_buffer;
                } else {
                    list.items[j].descriptor_type = dtype;
                }
            }
            return;
        }
    }

    const b = vk.DescriptorSetLayoutBinding{
        .binding = binding_idx,
        .descriptor_type = dtype,
        .descriptor_count = descriptor_count,
        .stage_flags = sflags,
        .p_immutable_samplers = null,
    };
    try list.append(allocator, b);
}
