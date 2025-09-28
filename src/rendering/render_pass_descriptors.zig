const std = @import("std");
const vk = @import("vulkan");
const DescriptorPool = @import("../core/descriptors.zig").DescriptorPool;
const DescriptorSetLayout = @import("../core/descriptors.zig").DescriptorSetLayout;
const DescriptorWriter = @import("../core/descriptors.zig").DescriptorWriter;
const GraphicsContext = @import("../core/graphics_context.zig").GraphicsContext;
const Buffer = @import("../core/buffer.zig").Buffer;
const MAX_FRAMES_IN_FLIGHT = @import("../core/swapchain.zig").MAX_FRAMES_IN_FLIGHT;

/// Descriptor set configuration for render passes
pub const DescriptorSetConfig = struct {
    /// Set index (0, 1, 2, etc.)
    set_index: u32,
    /// Binding configurations for this set
    bindings: []const BindingConfig,

    pub const BindingConfig = struct {
        /// Binding index within the set
        binding: u32,
        /// Type of descriptor (UBO, SSBO, combined image sampler, etc.)
        descriptor_type: vk.DescriptorType,
        /// Which shader stages use this binding
        stage_flags: vk.ShaderStageFlags,
        /// Number of descriptors in array (1 for single, N for arrays)
        descriptor_count: u32 = 1,
    };
};

/// Resource binding for a specific binding point
pub const ResourceBinding = struct {
    set_index: u32,
    binding: u32,
    resource: ResourceType,

    pub const ResourceType = union(enum) {
        buffer: vk.DescriptorBufferInfo,
        image: vk.DescriptorImageInfo,
        buffer_array: []const vk.DescriptorBufferInfo,
        image_array: []const vk.DescriptorImageInfo,
    };
};

/// Manager for render pass descriptor sets - handles pools, layouts, and sets
pub const RenderPassDescriptorManager = struct {
    gc: *GraphicsContext,
    allocator: std.mem.Allocator,

    // Descriptor pool and layouts per set
    pools: std.AutoHashMap(u32, *DescriptorPool),
    layouts: std.AutoHashMap(u32, *DescriptorSetLayout),

    // Descriptor sets per frame per set
    descriptor_sets: std.AutoHashMap(u32, []vk.DescriptorSet),

    // Configuration
    set_configs: []const DescriptorSetConfig,

    pub fn init(
        gc: *GraphicsContext,
        allocator: std.mem.Allocator,
        set_configs: []const DescriptorSetConfig,
    ) !RenderPassDescriptorManager {
        var self = RenderPassDescriptorManager{
            .gc = gc,
            .allocator = allocator,
            .pools = std.AutoHashMap(u32, *DescriptorPool).init(allocator),
            .layouts = std.AutoHashMap(u32, *DescriptorSetLayout).init(allocator),
            .descriptor_sets = std.AutoHashMap(u32, []vk.DescriptorSet).init(allocator),
            .set_configs = set_configs,
        };

        // Create pools and layouts for each descriptor set
        for (set_configs) |config| {
            try self.createPoolAndLayout(config);
        }

        return self;
    }

    pub fn deinit(self: *RenderPassDescriptorManager) void {
        // Deinit descriptor sets
        var set_iter = self.descriptor_sets.iterator();
        while (set_iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.descriptor_sets.deinit();

        // Deinit pools
        var pool_iter = self.pools.iterator();
        while (pool_iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.pools.deinit();

        // Deinit layouts
        var layout_iter = self.layouts.iterator();
        while (layout_iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.layouts.deinit();
    }

    fn createPoolAndLayout(self: *RenderPassDescriptorManager, config: DescriptorSetConfig) !void {
        // Count descriptor types for pool sizing
        var type_counts = std.AutoHashMap(vk.DescriptorType, u32).init(self.allocator);
        defer type_counts.deinit();

        for (config.bindings) |binding| {
            const current_count = type_counts.get(binding.descriptor_type) orelse 0;
            try type_counts.put(binding.descriptor_type, current_count + binding.descriptor_count * MAX_FRAMES_IN_FLIGHT);
        }

        // Create descriptor pool
        var pool_builder = DescriptorPool.Builder{
            .gc = self.gc,
            .poolSizes = std.ArrayList(vk.DescriptorPoolSize){},
            .poolFlags = .{ .free_descriptor_set_bit = true },
            .maxSets = 0,
            .allocator = self.allocator,
        };
        defer pool_builder.poolSizes.deinit(self.allocator);

        // Make pool much larger to handle multiple allocations
        // Each frame needs sets, plus we may have temporary allocations
        const total_sets: u32 = MAX_FRAMES_IN_FLIGHT * 10; // 10x safety margin
        var type_iter = type_counts.iterator();
        while (type_iter.next()) |entry| {
            // Also multiply descriptor counts by safety margin
            _ = pool_builder.addPoolSize(entry.key_ptr.*, entry.value_ptr.* * 10);
        }

        const pool = try self.allocator.create(DescriptorPool);
        pool.* = try pool_builder.setMaxSets(total_sets).build();
        try self.pools.put(config.set_index, pool);

        // Create descriptor set layout
        var layout_builder = DescriptorSetLayout.Builder{
            .gc = self.gc,
            .bindings = std.AutoHashMap(u32, vk.DescriptorSetLayoutBinding).init(self.allocator),
        };

        for (config.bindings) |binding| {
            _ = layout_builder.addBinding(binding.binding, binding.descriptor_type, binding.stage_flags, binding.descriptor_count);
        }

        const layout = try self.allocator.create(DescriptorSetLayout);
        layout.* = try layout_builder.build();
        try self.layouts.put(config.set_index, layout);

        // Allocate descriptor sets for all frames
        const sets = try self.allocator.alloc(vk.DescriptorSet, MAX_FRAMES_IN_FLIGHT);
        for (sets) |*set| {
            try pool.allocateDescriptor(layout.descriptor_set_layout, set);
        }
        try self.descriptor_sets.put(config.set_index, sets);
    }

    /// Update descriptor set bindings
    pub fn updateDescriptorSet(
        self: *RenderPassDescriptorManager,
        frame_index: u32,
        bindings: []const ResourceBinding,
    ) !void {
        // Group bindings by set
        var bindings_per_set = std.AutoHashMap(u32, std.ArrayList(ResourceBinding)).init(self.allocator);
        defer {
            var iter = bindings_per_set.iterator();
            while (iter.next()) |entry| {
                entry.value_ptr.deinit(self.allocator);
            }
            bindings_per_set.deinit();
        }

        for (bindings) |binding| {
            if (!bindings_per_set.contains(binding.set_index)) {
                const new_list = try std.ArrayList(ResourceBinding).initCapacity(self.allocator, 8);
                try bindings_per_set.put(binding.set_index, new_list);
            }
            try bindings_per_set.getPtr(binding.set_index).?.append(self.allocator, binding);
        }

        // Update each set
        var set_iter = bindings_per_set.iterator();
        while (set_iter.next()) |entry| {
            const set_index = entry.key_ptr.*;
            const set_bindings = entry.value_ptr.items;

            const layout = self.layouts.get(set_index) orelse continue;
            const pool = self.pools.get(set_index) orelse continue;
            const sets = self.descriptor_sets.get(set_index) orelse continue;

            if (frame_index >= sets.len) continue;

            var writer = DescriptorWriter.init(self.gc, layout, pool, self.allocator);
            defer writer.deinit();

            for (set_bindings) |binding| {
                switch (binding.resource) {
                    .buffer => |buffer_info| {
                        _ = writer.writeBuffer(binding.binding, @constCast(&buffer_info));
                    },
                    .image => |image_info| {
                        _ = writer.writeImage(binding.binding, @constCast(&image_info));
                    },
                    .buffer_array => |buffer_infos| {
                        _ = writer.writeBuffers(binding.binding, buffer_infos);
                    },
                    .image_array => |image_infos| {
                        _ = writer.writeImages(binding.binding, image_infos);
                    },
                }
            }

            // Use pre-allocated descriptor set and just update it
            writer.update(sets[frame_index]);
        }
    }

    /// Get descriptor set for a specific set index and frame
    pub fn getDescriptorSet(self: *RenderPassDescriptorManager, set_index: u32, frame_index: u32) ?vk.DescriptorSet {
        const sets = self.descriptor_sets.get(set_index) orelse return null;
        if (frame_index >= sets.len) return null;
        return sets[frame_index];
    }

    /// Get descriptor set layout for a specific set index
    pub fn getDescriptorSetLayout(self: *RenderPassDescriptorManager, set_index: u32) ?vk.DescriptorSetLayout {
        const layout = self.layouts.get(set_index) orelse return null;
        return layout.descriptor_set_layout;
    }

    /// Get all descriptor set layouts (for pipeline layout creation)
    pub fn getAllLayouts(self: *RenderPassDescriptorManager, allocator: std.mem.Allocator) ![]vk.DescriptorSetLayout {
        var layouts = try std.ArrayList(vk.DescriptorSetLayout).initCapacity(allocator, 8);

        // Sort by set index to ensure correct order
        var set_indices = try std.ArrayList(u32).initCapacity(allocator, 8);
        defer set_indices.deinit(allocator);

        var iter = self.layouts.iterator();
        while (iter.next()) |entry| {
            try set_indices.append(entry.key_ptr.*);
        }

        std.mem.sort(u32, set_indices.items, {}, std.sort.asc(u32));

        for (set_indices.items) |set_index| {
            if (self.layouts.get(set_index)) |layout| {
                try layouts.append(layout.descriptor_set_layout);
            }
        }

        return layouts.toOwnedSlice();
    }
};

/// Pre-configured descriptor manager for forward rendering pass
pub const ForwardRenderPassDescriptors = struct {
    manager: RenderPassDescriptorManager,

    pub fn init(gc: *GraphicsContext, allocator: std.mem.Allocator) !ForwardRenderPassDescriptors {
        // Define descriptor sets for forward rendering:
        // Set 0: Global data (view, projection, lights)
        // Set 1: Material data (material buffer, textures)
        const set_configs = [_]DescriptorSetConfig{
            // Set 0: Global UBO (already handled by GlobalUboSet)
            // We'll skip this and let the existing system handle it

            // Set 1: Material and texture data
            .{
                .set_index = 1,
                .bindings = &[_]DescriptorSetConfig.BindingConfig{
                    .{
                        .binding = 0,
                        .descriptor_type = .storage_buffer,
                        .stage_flags = .{ .vertex_bit = true, .fragment_bit = true },
                        .descriptor_count = 1,
                    },
                    .{
                        .binding = 1,
                        .descriptor_type = .combined_image_sampler,
                        .stage_flags = .{ .fragment_bit = true },
                        .descriptor_count = 32, // Support up to 32 textures
                    },
                },
            },
        };

        const manager = try RenderPassDescriptorManager.init(gc, allocator, &set_configs);

        return ForwardRenderPassDescriptors{
            .manager = manager,
        };
    }

    pub fn deinit(self: *ForwardRenderPassDescriptors) void {
        self.manager.deinit();
    }

    /// Update material buffer and textures for current frame
    pub fn updateMaterialData(
        self: *ForwardRenderPassDescriptors,
        frame_index: u32,
        material_buffer_info: vk.DescriptorBufferInfo,
        texture_image_infos: []const vk.DescriptorImageInfo,
    ) !void {
        const bindings = [_]ResourceBinding{
            .{
                .set_index = 1,
                .binding = 0,
                .resource = .{ .buffer = material_buffer_info },
            },
            .{
                .set_index = 1,
                .binding = 1,
                .resource = .{ .image_array = texture_image_infos },
            },
        };

        try self.manager.updateDescriptorSet(frame_index, &bindings);
    }

    /// Get material descriptor set for binding
    pub fn getMaterialDescriptorSet(self: *ForwardRenderPassDescriptors, frame_index: u32) ?vk.DescriptorSet {
        return self.manager.getDescriptorSet(1, frame_index);
    }

    /// Get material descriptor set layout for pipeline creation
    pub fn getMaterialDescriptorSetLayout(self: *ForwardRenderPassDescriptors) ?vk.DescriptorSetLayout {
        return self.manager.getDescriptorSetLayout(1);
    }
};
