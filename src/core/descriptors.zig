const std = @import("std");
const GraphicsContext = @import("graphics_context.zig").GraphicsContext;
const vk = @import("vulkan");
const log = @import("../utils/log.zig").log;

pub const DescriptorSetLayout = struct {
    gc: *GraphicsContext,
    bindings: std.AutoHashMap(u32, vk.DescriptorSetLayoutBinding),
    descriptor_set_layout: vk.DescriptorSetLayout,

    pub fn init(gc: *GraphicsContext, bindings: std.AutoHashMap(u32, vk.DescriptorSetLayoutBinding)) DescriptorSetLayout {
        var setLayoutBindings = std.ArrayList(vk.DescriptorSetLayoutBinding){};
        defer setLayoutBindings.deinit(std.heap.page_allocator);
        var it = bindings.valueIterator();
        while (it.next()) |kv| {
            setLayoutBindings.append(std.heap.page_allocator, kv.*) catch unreachable;
        }

        var descriptorSetLayoutInfo = vk.DescriptorSetLayoutCreateInfo{
            .flags = .{},
            .binding_count = @as(u32, @intCast(setLayoutBindings.items.len)),
            .p_bindings = setLayoutBindings.items.ptr,
        };

        var descriptor_set_layout: vk.DescriptorSetLayout = undefined;

        descriptor_set_layout = gc.vkd.createDescriptorSetLayout(gc.dev, &descriptorSetLayoutInfo, null) catch unreachable;

        const self = DescriptorSetLayout{ .gc = gc, .bindings = bindings, .descriptor_set_layout = descriptor_set_layout };

        return self;
    }

    pub fn deinit(self: *DescriptorSetLayout) void {
        self.gc.vkd.destroyDescriptorSetLayout(self.gc.dev, self.descriptor_set_layout, null);
    }

    pub const Builder = struct {
        gc: *GraphicsContext,
        bindings: std.AutoHashMap(u32, vk.DescriptorSetLayoutBinding),
        allocator: std.mem.Allocator = std.heap.page_allocator,

        pub fn addBinding(self: *Builder, binding: u32, descriptorType: vk.DescriptorType, stageFlags: vk.ShaderStageFlags, count: u32) *Builder {
            const layoutBinding = vk.DescriptorSetLayoutBinding{
                .binding = binding,
                .descriptor_type = descriptorType,
                .descriptor_count = count,
                .stage_flags = stageFlags,
                .p_immutable_samplers = null,
            };

            self.bindings.put(binding, layoutBinding) catch unreachable;
            return self;
        }

        pub fn build(self: *Builder) !DescriptorSetLayout {
            return DescriptorSetLayout.init(self.gc, self.bindings);
        }
    };
};

pub const DescriptorPool = struct {
    gc: *GraphicsContext,
    descriptorPool: vk.DescriptorPool,

    pub fn init(gc: *GraphicsContext, maxSets: u32, poolFlags: vk.DescriptorPoolCreateFlags, poolSizes: []const vk.DescriptorPoolSize) DescriptorPool {
        var descriptorPoolInfo = vk.DescriptorPoolCreateInfo{
            .pool_size_count = @as(u32, @intCast(poolSizes.len)),
            .p_pool_sizes = poolSizes.ptr,
            .max_sets = maxSets,
            .flags = poolFlags,
        };

        var descriptor_pool: vk.DescriptorPool = undefined;

        descriptor_pool = gc.vkd.createDescriptorPool(gc.dev, &descriptorPoolInfo, null) catch unreachable;
        const self = DescriptorPool{ .gc = gc, .descriptorPool = descriptor_pool };

        return self;
    }

    pub fn deinit(self: *DescriptorPool) void {
        self.gc.vkd.destroyDescriptorPool(self.gc.dev, self.descriptorPool, null);
    }

    pub fn allocateDescriptor(self: *DescriptorPool, descriptorSetLayout: vk.DescriptorSetLayout, descriptor_set: *vk.DescriptorSet) !void {
        const layouts = [_]vk.DescriptorSetLayout{descriptorSetLayout};
        var allocInfo = vk.DescriptorSetAllocateInfo{
            .descriptor_pool = self.descriptorPool,
            .p_set_layouts = &layouts,
            .descriptor_set_count = layouts.len,
        };

        self.gc.vkd.allocateDescriptorSets(self.gc.dev, &allocInfo, @ptrCast(descriptor_set)) catch |err| {
            std.debug.print("Failed to allocate descriptor set: {any}\n", .{err});
            return err;
        };
    }

    pub fn freeDescriptors(self: *DescriptorPool, descriptors: []vk.DescriptorSet) !void {
        try self.gc.vkd.freeDescriptorSets(self.gc.dev, self.descriptorPool, @as(u32, @intCast(descriptors.len)), descriptors.ptr);
    }

    pub fn resetPool(self: *DescriptorPool) !void {
        try self.gc.vkd.resetDescriptorPool(self.gc.dev, self.descriptorPool, .{});
    }

    pub const Builder = struct {
        gc: *GraphicsContext,
        poolSizes: std.ArrayList(vk.DescriptorPoolSize),
        poolFlags: vk.DescriptorPoolCreateFlags,
        maxSets: u32,
        allocator: std.mem.Allocator,

        pub fn addPoolSize(self: *Builder, descriptorType: vk.DescriptorType, count: u32) *Builder {
            self.poolSizes.append(self.allocator, vk.DescriptorPoolSize{ .type = descriptorType, .descriptor_count = count }) catch unreachable;
            return self;
        }

        pub fn setPoolFlags(self: *Builder, flags: vk.DescriptorPoolCreateFlags) *Builder {
            self.poolFlags = flags;
            return self;
        }

        pub fn setMaxSets(self: *Builder, count: u32) *Builder {
            self.maxSets = count;
            return self;
        }

        pub fn build(self: *Builder) !DescriptorPool {
            return DescriptorPool.init(self.gc, self.maxSets, self.poolFlags, self.poolSizes.items);
        }
    };
};

pub const DescriptorWriter = struct {
    setLayout: *DescriptorSetLayout,
    pool: *DescriptorPool,
    writes: std.ArrayList(vk.WriteDescriptorSet),
    gc: *GraphicsContext,
    allocator: std.mem.Allocator,
    // Storage for buffer and image infos to avoid pointer aliasing
    buffer_infos: std.ArrayList(vk.DescriptorBufferInfo),
    image_infos: std.ArrayList(vk.DescriptorImageInfo),

    pub fn init(gc: *GraphicsContext, setLayout: *DescriptorSetLayout, pool: *DescriptorPool, allocator: std.mem.Allocator) DescriptorWriter {
        return DescriptorWriter{
            .setLayout = setLayout,
            .pool = pool,
            .writes = std.ArrayList(vk.WriteDescriptorSet){},
            .buffer_infos = std.ArrayList(vk.DescriptorBufferInfo){},
            .image_infos = std.ArrayList(vk.DescriptorImageInfo){},
            .gc = gc,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *DescriptorWriter) void {
        self.writes.deinit(self.allocator);
        self.buffer_infos.deinit(self.allocator);
        self.image_infos.deinit(self.allocator);
    }

    pub fn writeBuffer(self: *DescriptorWriter, binding: u32, bufferInfo: *vk.DescriptorBufferInfo) *DescriptorWriter {
        log(.DEBUG, "descriptor_writer", "Writing buffer to binding {}: buffer handle=0x{X}, offset={}, range={}", .{ binding, @intFromEnum(bufferInfo.buffer), bufferInfo.offset, bufferInfo.range });
        const bindingDescription = self.setLayout.bindings.get(binding).?;

        // Store a copy of the buffer info to avoid pointer aliasing issues
        self.buffer_infos.append(self.allocator, bufferInfo.*) catch unreachable;
        const stored_buffer_info = &self.buffer_infos.items[self.buffer_infos.items.len - 1];

        const write = vk.WriteDescriptorSet{
            .descriptor_type = bindingDescription.descriptor_type,
            .dst_binding = binding,
            .p_buffer_info = @ptrCast(stored_buffer_info),
            .descriptor_count = 1,
            .dst_set = undefined,
            .dst_array_element = 0,
            .p_image_info = undefined,
            .p_texel_buffer_view = undefined,
        };
        self.writes.append(self.allocator, write) catch unreachable;

        // DEBUG: Log what we just stored in the writes array
        const stored_write = &self.writes.items[self.writes.items.len - 1];
        std.log.info("[writeBuffer-STORED] binding={}, type={}, buffer=0x{X}", .{ stored_write.dst_binding, stored_write.descriptor_type, @intFromEnum(stored_write.p_buffer_info[0].buffer) });

        return self;
    }

    pub fn writeImage(self: *DescriptorWriter, binding: u32, imageInfo: *vk.DescriptorImageInfo) *DescriptorWriter {
        const bindingDescription = self.setLayout.bindings.get(binding).?;

        // Store a copy of the image info to avoid pointer aliasing issues
        self.image_infos.append(self.allocator, imageInfo.*) catch unreachable;
        const stored_image_info = &self.image_infos.items[self.image_infos.items.len - 1];

        const write = vk.WriteDescriptorSet{
            .descriptor_type = bindingDescription.descriptor_type,
            .dst_binding = binding,
            .descriptor_count = 1,
            .dst_array_element = 0,
            .dst_set = undefined,
            .p_image_info = @ptrCast(stored_image_info),
            .p_texel_buffer_view = undefined,
            .p_buffer_info = undefined,
        };

        self.writes.append(self.allocator, write) catch unreachable;
        return self;
    }

    pub fn writeAccelerationStructure(self: *DescriptorWriter, binding: u32, accel_info: *vk.WriteDescriptorSetAccelerationStructureKHR) *DescriptorWriter {
        const bindingDescription = self.setLayout.bindings.get(binding).?;
        const write = vk.WriteDescriptorSet{
            .p_next = @ptrCast(accel_info),
            .dst_set = undefined,
            .dst_binding = binding,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = bindingDescription.descriptor_type,
            .p_image_info = undefined,
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        };
        self.writes.append(self.allocator, write) catch unreachable;
        return self;
    }

    pub fn writeBuffers(self: *DescriptorWriter, binding: u32, bufferInfos: []const vk.DescriptorBufferInfo) *DescriptorWriter {
        const bindingDescription = self.setLayout.bindings.get(binding).?;
        const write = vk.WriteDescriptorSet{
            .descriptor_type = bindingDescription.descriptor_type,
            .dst_binding = binding,
            .p_buffer_info = @ptrCast(bufferInfos.ptr),
            .descriptor_count = @as(u32, @intCast(bufferInfos.len)),
            .dst_set = undefined,
            .dst_array_element = 0,
            .p_image_info = undefined,
            .p_texel_buffer_view = undefined,
        };
        self.writes.append(self.allocator, write) catch unreachable;
        return self;
    }

    /// Write an array of sampled images (textures) to the descriptor set at the given binding.
    pub fn writeImages(self: *DescriptorWriter, binding: u32, image_infos: []const vk.DescriptorImageInfo) *DescriptorWriter {
        const bindingDescription = self.setLayout.bindings.get(binding).?;
        const write = vk.WriteDescriptorSet{
            .descriptor_type = bindingDescription.descriptor_type,
            .dst_binding = binding,
            .descriptor_count = @as(u32, @intCast(image_infos.len)),
            .dst_array_element = 0,
            .dst_set = undefined,
            .p_image_info = image_infos.ptr,
            .p_texel_buffer_view = undefined,
            .p_buffer_info = undefined,
        };
        self.writes.append(self.allocator, write) catch unreachable;
        return self;
    }

    pub fn build(self: *DescriptorWriter, set: *vk.DescriptorSet) !void {
        self.pool.allocateDescriptor(self.setLayout.descriptor_set_layout, set) catch unreachable;
        log(.DEBUG, "descriptor_set", "Allocated descriptor set: {}, with write count: {d}\n", .{ set.*, self.writes.items.len });
        for (0..self.writes.items.len) |i| {
            self.writes.items[i].dst_set = set.*;
        }

        // DEBUG: Log exactly what we're about to submit to Vulkan
        for (self.writes.items, 0..) |write, i| {
            if (write.descriptor_type == .uniform_buffer or write.descriptor_type == .storage_buffer) {
                std.log.info("[vkUpdateDescriptorSets] Write[{}]: binding={}, type={}, buffer=0x{X}", .{ i, write.dst_binding, write.descriptor_type, @intFromEnum(write.p_buffer_info[0].buffer) });
            }
        }

        self.gc.vkd.updateDescriptorSets(self.gc.dev, @intCast(self.writes.items.len), @ptrCast(self.writes.items.ptr), 0, null);
    }

    /// Update an existing descriptor set without allocating a new one
    pub fn update(self: *DescriptorWriter, set: vk.DescriptorSet) void {
        for (0..self.writes.items.len) |i| {
            self.writes.items[i].dst_set = set;
        }

        // DEBUG: Log exactly what we're about to submit to Vulkan (update path)
        for (self.writes.items, 0..) |write, i| {
            if (write.descriptor_type == .uniform_buffer or write.descriptor_type == .storage_buffer) {
                std.log.info("[vkUpdateDescriptorSets-UPDATE] Write[{}]: binding={}, type={}, buffer=0x{X}", .{ i, write.dst_binding, write.descriptor_type, @intFromEnum(write.p_buffer_info[0].buffer) });
            }
        }

        self.gc.vkd.updateDescriptorSets(self.gc.dev, @intCast(self.writes.items.len), @ptrCast(self.writes.items.ptr), 0, null);
    }
};

pub fn deinitDescriptorResources(
    pool: ?*DescriptorPool,
    layout: ?*DescriptorSetLayout,
    sets: ?[]vk.DescriptorSet,
    allocator: ?std.mem.Allocator,
) !void {
    // Free descriptor sets if provided
    if (pool) |p| {
        if (sets) |s| {
            try p.freeDescriptors(s);
        }
        p.deinit();
        if (allocator) |a| a.destroy(p);
    }
    // Destroy layout
    if (layout) |l| {
        l.deinit();
        if (allocator) |a| a.destroy(l);
    }
}

// DescriptorSetLayout, DescriptorPool, and DescriptorWriter structs already store gc as a member, matching their init signatures. Allocator is not stored, as not needed after construction.
