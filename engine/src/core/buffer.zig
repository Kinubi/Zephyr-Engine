const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("graphics_context.zig").GraphicsContext;
const log = @import("../utils/log.zig").log;
const LogLevel = @import("../utils/log.zig").LogLevel;

pub const Buffer = struct {
    gc: *GraphicsContext,
    instance_size: vk.DeviceSize,
    instance_count: u32,
    usage_flags: vk.BufferUsageFlags,
    memory_property_flags: vk.MemoryPropertyFlags,
    alignment_size: vk.DeviceSize,
    buffer_size: vk.DeviceSize,
    buffer: vk.Buffer = undefined,
    memory: vk.DeviceMemory = undefined,
    mapped: ?*anyopaque = null,
    descriptor_info: vk.DescriptorBufferInfo = undefined,

    pub fn init(gc: *GraphicsContext, instance_size: vk.DeviceSize, instance_count: u32, usage_flags: vk.BufferUsageFlags, memory_property_flags: vk.MemoryPropertyFlags) !Buffer {
        const lcm = (gc.props.limits.min_uniform_buffer_offset_alignment * gc.props.limits.non_coherent_atom_size) / std.math.gcd(gc.props.limits.min_uniform_buffer_offset_alignment, gc.props.limits.non_coherent_atom_size);

        const alignment_size: vk.DeviceSize = Buffer.getAlignment(instance_size, lcm);
        const buffer_size = instance_count * alignment_size;
        var self = Buffer{ .gc = gc, .instance_size = instance_size, .instance_count = instance_count, .usage_flags = usage_flags, .memory_property_flags = memory_property_flags, .alignment_size = alignment_size, .buffer_size = buffer_size, .mapped = null };
        try gc.createBuffer(self.buffer_size, usage_flags, memory_property_flags, @constCast(&self.buffer), @constCast(&self.memory));
        self.descriptor_info = .{ .buffer = self.buffer, .offset = 0, .range = vk.WHOLE_SIZE };

        return self;
    }

    pub fn deinit(self: *Buffer) void {
        if (self.mapped != null) self.unmap();
        self.gc.vkd.destroyBuffer(self.gc.dev, self.buffer, null);
        self.gc.vkd.freeMemory(self.gc.dev, self.memory, null);
    }

    pub fn getAlignment(instance_size: vk.DeviceSize, min_offset_alignment: vk.DeviceSize) vk.DeviceSize {
        if (min_offset_alignment > 0) {
            return (instance_size + min_offset_alignment - 1) & ~(min_offset_alignment - 1);
        }
        return instance_size;
    }

    pub fn map(self: *Buffer, size: vk.DeviceSize, offset: vk.DeviceSize) !void {
        self.mapped = try self.gc.vkd.mapMemory(self.gc.dev, self.memory, offset, size, .{});
    }

    pub fn unmap(self: *Buffer) void {
        if (self.mapped) |mapped| {
            _ = mapped;
            self.gc.vkd.unmapMemory(self.gc.dev, self.memory);
            self.mapped = null;
        }
    }

    pub fn writeToBuffer(self: *Buffer, data: []const u8, size: vk.DeviceSize, offset: vk.DeviceSize) void {
        if (size == vk.WHOLE_SIZE) {
            std.mem.copyForwards(u8, @as([*]u8, @ptrCast(self.mapped.?))[0..self.buffer_size], data);
        } else {
            std.mem.copyForwards(u8, @as([*]u8, @ptrCast(self.mapped.?))[offset .. offset + size], data);
        }
    }

    pub fn flush(self: *Buffer, size: vk.DeviceSize, offset: vk.DeviceSize) !void {
        const mapped_range = vk.MappedMemoryRange{
            .p_next = null,
            .memory = self.memory,
            .offset = offset,
            .size = size,
        };
        return try self.gc.vkd.flushMappedMemoryRanges(self.gc.dev, 1, @ptrCast(@constCast(&mapped_range)));
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

    pub fn getdescriptorInfo(self: Buffer) vk.DescriptorBufferInfo {
        return self.descriptor_info;
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

    pub fn fromVkBuffer(gc: *GraphicsContext, buffer: vk.Buffer, memory: vk.DeviceMemory, descriptor_info: vk.DescriptorBufferInfo, buffer_size: vk.DeviceSize) Buffer {
        return Buffer{
            .gc = gc,
            .instance_size = 0,
            .instance_count = 0,
            .usage_flags = .{},
            .memory_property_flags = .{},
            .alignment_size = 0,
            .buffer_size = buffer_size,
            .buffer = buffer,
            .memory = memory,
            .mapped = null,
            .descriptor_info = descriptor_info,
        };
    }
};

// Buffer struct already stores gc as a member, matching the init signature. Allocator is not stored, as not needed after construction.
