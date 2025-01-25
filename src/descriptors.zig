const std = @import("std");
const GraphicsContext = @import("graphics_context.zig").GraphicsContext;
const vk = @import("vulkan");

pub const DescriptorSetLayout = struct {
    gc: *GraphicsContext,
    bindings: std.AutoHashMap(u32, vk.DescriptorSetLayoutBinding),
    descriptor_set_layout: vk.DescriptorSetLayout,

    pub fn init(gc: *GraphicsContext, bindings: std.AutoHashMap(u32, vk.DescriptorSetLayoutBinding)) DescriptorSetLayout {
        var setLayoutBindings = std.ArrayList(vk.DescriptorSetLayoutBinding).init(std.heap.page_allocator);
        defer setLayoutBindings.deinit();
        var it = bindings.valueIterator();
        while (it.next()) |kv| {
            setLayoutBindings.append(kv.*) catch unreachable;
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
        self.gc.vkd.vkDestroyDescriptorSetLayout(self.gc.dev, self.descriptorSetLayout, null);
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
        // var layouts = try allocator.alloc(vk.DescriptorSetLayout, descriptor_sets.len);

        // for (0..descriptor_sets.len) |i| {
        //     layouts[i] = descriptorSetLayout;
        // }
        std.debug.print("Allocating descriptor sets with layout: {any}\n", .{descriptorSetLayout});
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

    pub fn freeDescriptors(self: *DescriptorPool, descriptors: []vk.DescriptorSet) void {
        self.gc.vkd.freeDescriptorSets(self.gc.dev, self.descriptorPool, @as(u32, @intCast(descriptors.len)), descriptors.ptr);
    }

    pub fn resetPool(self: *DescriptorPool) void {
        self.gc.vkd.resetDescriptorPool(self.gc.dev, self.descriptorPool, 0);
    }

    pub const Builder = struct {
        gc: *GraphicsContext,
        poolSizes: std.ArrayList(vk.DescriptorPoolSize),
        poolFlags: vk.DescriptorPoolCreateFlags,
        maxSets: u32,

        pub fn addPoolSize(self: *Builder, descriptorType: vk.DescriptorType, count: u32) *Builder {
            self.poolSizes.append(vk.DescriptorPoolSize{ .type = descriptorType, .descriptor_count = count }) catch unreachable;
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
    gc: GraphicsContext = undefined,

    pub fn init(gc: GraphicsContext, setLayout: *DescriptorSetLayout, pool: *DescriptorPool) DescriptorWriter {
        return DescriptorWriter{
            .setLayout = setLayout,
            .pool = pool,
            .writes = std.ArrayList(vk.WriteDescriptorSet).init(std.heap.page_allocator),
            .gc = gc,
        };
    }

    pub fn deinit(self: *DescriptorWriter) void {
        self.writes.deinit();
    }

    pub fn writeBuffer(self: *DescriptorWriter, binding: u32, bufferInfo: *vk.DescriptorBufferInfo) *DescriptorWriter {
        const bindingDescription = self.setLayout.bindings.get(binding).?;
        const write = vk.WriteDescriptorSet{
            .descriptor_type = bindingDescription.descriptor_type,
            .dst_binding = binding,
            .p_buffer_info = @ptrCast(bufferInfo),
            .descriptor_count = 1,
            .dst_set = undefined,
            .dst_array_element = 0,
            .p_image_info = undefined,
            .p_texel_buffer_view = undefined,
        };

        self.writes.append(write) catch unreachable;
        return self;
    }

    pub fn writeImage(self: *DescriptorWriter, binding: u32, imageInfo: *vk.DescriptorImageInfo) *DescriptorWriter {
        const bindingDescription = self.setLayout.bindings.get(binding).?;

        const write = vk.WriteDescriptorSet{
            .descriptor_type = bindingDescription.descriptor_type,
            .dst_binding = binding,
            .descriptor_count = 1,
            .dst_array_element = 0,
            .dst_set = undefined,
            .p_image_info = @ptrCast(imageInfo),
            .p_texel_buffer_view = undefined,
        };

        self.writes.append(write) catch unreachable;
        return self;
    }

    pub fn build(self: *DescriptorWriter, set: *vk.DescriptorSet) !void {
        self.pool.allocateDescriptor(self.setLayout.descriptor_set_layout, set) catch unreachable;
        for (0..self.writes.items.len) |i| {
            self.writes.items[i].dst_set = set.*;
        }
        self.gc.vkd.updateDescriptorSets(self.gc.dev, @intCast(self.writes.items.len), @ptrCast(self.writes.items.ptr), 0, null);
    }
};
