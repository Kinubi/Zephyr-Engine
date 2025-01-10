const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("graphics_context.zig").GraphicsContext;

pub const Buffer = struct {
    gc: *GraphicsContext,
    instance_size: vk.DeviceSize,
    instance_count: u32,
    usage_flags: vk.BufferUsageFlags,
    memory_property_flags: vk.MemoryPropertyFlags,
    alignment_size: vk.DeviceSize,
    buffer_size: vk.DeviceSize,
    buffer: vk.Buffer = undefined,
    memory: vk.DeviceMemory,
    mapped: ?*u8,

    pub fn init(
        gc: *GraphicsContext,
        instance_size: vk.DeviceSize,
        instance_count: u32,
        usage_flags: vk.BufferUsageFlags,
        memory_property_flags: vk.MemoryPropertyFlags,
        min_offset_alignment: vk.DeviceSize,
    ) Buffer {
        const self = Buffer{ .gc = gc, .instance_size = instance_size, .instance_count = instance_count, .usage_flags = usage_flags, .memory_property_flags = memory_property_flags, .alignment_size = Buffer.getAlignment(instance_size, min_offset_alignment), .buffer_size = instance_count };
        gc.dev.createBuffer(self.buffer_size, usage_flags, memory_property_flags, &self.buffer, &self.memory);
        return self;
    }

    pub fn deinit(self: *Buffer) void {
        self.unmap();
        vk.DestroyBuffer(self.gc.dev, self.buffer, null);
        vk.FreeMemory(self.gc.dev, self.memory, null);
    }

    pub fn getAlignment(instance_size: vk.DeviceSize, min_offset_alignment: vk.DeviceSize) vk.DeviceSize {
        if (min_offset_alignment > 0) {
            return (instance_size + min_offset_alignment - 1) & ~(min_offset_alignment - 1);
        }
        return instance_size;
    }

    pub fn map(self: *Buffer, size: vk.DeviceSize, offset: vk.DeviceSize) vk.Result {
        return vk.MapMemory(self.gc.dev, self.memory, offset, size, 0, &self.mapped);
    }

    pub fn unmap(self: *Buffer) void {
        if (self.mapped) |mapped| {
            vk.UnmapMemory(self.gc.dev, self.memory);
            mapped = null;
        }
    }

    pub fn writeToBuffer(self: *Buffer, data: []const u8, size: vk.DeviceSize, offset: vk.DeviceSize) void {
        if (size == vk.WHOLE_SIZE) {
            std.mem.copy(u8, self.mapped[0..self.buffer_size], data);
        } else {
            std.mem.copy(u8, self.mapped[offset .. offset + size], data);
        }
    }

    pub fn flush(self: *Buffer, size: vk.DeviceSize, offset: vk.DeviceSize) vk.Result {
        var mapped_range = vk.MappedMemoryRange{
            .sType = vk.STRUCTURE_TYPE_MAPPED_MEMORY_RANGE,
            .pNext = null,
            .memory = self.memory,
            .offset = offset,
            .size = size,
        };
        return vk.FlushMappedMemoryRanges(self.gc.dev, 1, &mapped_range);
    }

    pub fn invalidate(self: *Buffer, size: vk.DeviceSize, offset: vk.DeviceSize) vk.Result {
        var mapped_range = vk.MappedMemoryRange{
            .sType = vk.STRUCTURE_TYPE_MAPPED_MEMORY_RANGE,
            .pNext = null,
            .memory = self.memory,
            .offset = offset,
            .size = size,
        };
        return vk.InvalidateMappedMemoryRanges(self.gc.dev, 1, &mapped_range);
    }

    pub fn descriptorInfo(self: *Buffer, size: vk.DeviceSize, offset: vk.DeviceSize) vk.DescriptorBufferInfo {
        return vk.DescriptorBufferInfo{
            .buffer = self.buffer,
            .offset = offset,
            .range = size,
        };
    }

    pub fn writeToIndex(self: *Buffer, data: []const u8, index: usize) void {
        self.writeToBuffer(data, self.instance_size, index * self.alignment_size);
    }

    pub fn flushIndex(self: *Buffer, index: usize) vk.Result {
        return self.flush(self.alignment_size, index * self.alignment_size);
    }

    pub fn descriptorInfoForIndex(self: *Buffer, index: usize) vk.DescriptorBufferInfo {
        return self.descriptorInfo(self.alignment_size, index * self.alignment_size);
    }

    pub fn invalidateIndex(self: *Buffer, index: usize) vk.Result {
        return self.invalidate(self.alignment_size, index * self.alignment_size);
    }
};
