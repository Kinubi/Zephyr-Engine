const std = @import("std");
const vk = @import("vulkan");
const DescriptorPool = @import("../core/descriptors.zig").DescriptorPool;
const DescriptorSetLayout = @import("../core/descriptors.zig").DescriptorSetLayout;
const DescriptorWriter = @import("../core/descriptors.zig").DescriptorWriter;
const GraphicsContext = @import("../core/graphics_context.zig").GraphicsContext;
const MAX_FRAMES_IN_FLIGHT = @import("../core/swapchain.zig").MAX_FRAMES_IN_FLIGHT;

/// Descriptor set configuration for raytracing
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
        acceleration_structure: *vk.WriteDescriptorSetAccelerationStructureKHR,
        buffer: vk.DescriptorBufferInfo,
        image: vk.DescriptorImageInfo,
        buffer_array: []const vk.DescriptorBufferInfo,
        image_array: []const vk.DescriptorImageInfo,
    };
};

/// Manager for raytracing descriptor sets - handles pools, layouts, and sets
pub const RaytracingDescriptorManager = struct {
    gc: *GraphicsContext,
    allocator: std.mem.Allocator,

    // Descriptor pool and layouts per set
    pools: std.AutoHashMap(u32, *DescriptorPool),
    layouts: std.AutoHashMap(u32, *DescriptorSetLayout),

    // Descriptor sets per frame per set
    descriptor_sets: std.AutoHashMap(u32, []vk.DescriptorSet),

    // Configuration
    set_configs: []const DescriptorSetConfig,

    // Performance optimization: pre-allocated working memory
    bindings_per_set: std.AutoHashMap(u32, std.ArrayList(ResourceBinding)),
    descriptor_writer: ?*DescriptorWriter,

    pub fn init(
        gc: *GraphicsContext,
        allocator: std.mem.Allocator,
        set_configs: []const DescriptorSetConfig,
    ) !RaytracingDescriptorManager {
        var self = RaytracingDescriptorManager{
            .gc = gc,
            .allocator = allocator,
            .pools = std.AutoHashMap(u32, *DescriptorPool).init(allocator),
            .layouts = std.AutoHashMap(u32, *DescriptorSetLayout).init(allocator),
            .descriptor_sets = std.AutoHashMap(u32, []vk.DescriptorSet).init(allocator),
            .set_configs = set_configs,
            .bindings_per_set = std.AutoHashMap(u32, std.ArrayList(ResourceBinding)).init(allocator),
            .descriptor_writer = null,
        };

        // Create pools and layouts for each descriptor set
        for (set_configs) |config| {
            try self.createPoolAndLayout(config);
        }

        return self;
    }

    pub fn deinit(self: *RaytracingDescriptorManager) void {
        // Deinit performance optimization data structures
        var bindings_iter = self.bindings_per_set.iterator();
        while (bindings_iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.bindings_per_set.deinit();

        if (self.descriptor_writer) |writer| {
            writer.deinit();
            self.allocator.destroy(writer);
        }

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

    fn createPoolAndLayout(self: *RaytracingDescriptorManager, config: DescriptorSetConfig) !void {
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
            .poolSizes = std.ArrayList(vk.DescriptorPoolSize).init(self.allocator),
            .poolFlags = .{ .free_descriptor_set_bit = true },
            .maxSets = 0,
            .allocator = self.allocator,
        };
        defer pool_builder.poolSizes.deinit();

        // Make pool larger to handle multiple allocations
        const total_sets: u32 = MAX_FRAMES_IN_FLIGHT * 5; // 5x safety margin
        var type_iter = type_counts.iterator();
        while (type_iter.next()) |entry| {
            // Also multiply descriptor counts by safety margin
            _ = pool_builder.addPoolSize(entry.key_ptr.*, entry.value_ptr.* * 5);
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

    /// Update descriptor set bindings (optimized version)
    pub fn updateDescriptorSet(
        self: *RaytracingDescriptorManager,
        frame_index: u32,
        bindings: []const ResourceBinding,
    ) !void {
        // Clear existing bindings but keep allocated memory - only for sets being updated
        var sets_to_update = std.AutoHashMap(u32, void).init(self.allocator);
        defer sets_to_update.deinit();

        // First pass: collect which sets we're updating
        for (bindings) |binding| {
            try sets_to_update.put(binding.set_index, {});
        }

        // Clear only the sets we're about to update
        var sets_iter = sets_to_update.iterator();
        while (sets_iter.next()) |entry| {
            const set_index = entry.key_ptr.*;
            if (self.bindings_per_set.getPtr(set_index)) |binding_list| {
                binding_list.clearRetainingCapacity();
            }
        }

        // Group bindings by set (reusing pre-allocated hash map)
        for (bindings) |binding| {
            const result = self.bindings_per_set.getOrPut(binding.set_index) catch unreachable;
            if (!result.found_existing) {
                result.value_ptr.* = std.ArrayList(ResourceBinding).init(self.allocator);
            }
            result.value_ptr.append(binding) catch unreachable;
        }

        // Update each set
        var set_iter = self.bindings_per_set.iterator();
        while (set_iter.next()) |entry| {
            const set_index = entry.key_ptr.*;
            const set_bindings = entry.value_ptr.items;

            if (set_bindings.len == 0) continue;

            const layout = self.layouts.get(set_index) orelse continue;
            const pool = self.pools.get(set_index) orelse continue;
            const sets = self.descriptor_sets.get(set_index) orelse continue;

            if (frame_index >= sets.len) continue;

            // Create descriptor writer if not cached, or reuse existing one
            if (self.descriptor_writer == null) {
                const writer = try self.allocator.create(DescriptorWriter);
                writer.* = DescriptorWriter.init(self.gc, layout, pool, self.allocator);
                self.descriptor_writer = writer;
            }

            const writer = self.descriptor_writer.?;

            // Reset writer for new update (clear previous writes)
            writer.writes.clearRetainingCapacity();

            for (set_bindings) |binding| {
                switch (binding.resource) {
                    .acceleration_structure => |accel_info| {
                        _ = writer.writeAccelerationStructure(binding.binding, accel_info);
                    },
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
    pub fn getDescriptorSet(self: *RaytracingDescriptorManager, set_index: u32, frame_index: u32) ?vk.DescriptorSet {
        const sets = self.descriptor_sets.get(set_index) orelse return null;
        if (frame_index >= sets.len) return null;
        return sets[frame_index];
    }

    /// Get descriptor set layout for a specific set index
    pub fn getDescriptorSetLayout(self: *RaytracingDescriptorManager, set_index: u32) ?vk.DescriptorSetLayout {
        const layout = self.layouts.get(set_index) orelse return null;
        return layout.descriptor_set_layout;
    }

    /// Get all descriptor set layouts (for pipeline layout creation)
    pub fn getAllLayouts(self: *RaytracingDescriptorManager, allocator: std.mem.Allocator) ![]vk.DescriptorSetLayout {
        var layouts = try std.ArrayList(vk.DescriptorSetLayout).initCapacity(allocator, 8);

        // Sort by set index to ensure correct order
        var set_indices = try std.ArrayList(u32).initCapacity(allocator, 8);
        defer set_indices.deinit();

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

/// Pre-configured descriptor manager for raytracing
pub const RaytracingDescriptors = struct {
    manager: RaytracingDescriptorManager,

    pub fn init(
        gc: *GraphicsContext,
        allocator: std.mem.Allocator,
        vertex_buffer_count: u32,
        index_buffer_count: u32,
    ) !RaytracingDescriptors {
        // Define descriptor sets for raytracing:
        // Set 0: Raytracing resources (acceleration structure, output image, UBO, vertex/index buffers, materials, textures)
        const set_configs = [_]DescriptorSetConfig{
            .{
                .set_index = 0,
                .bindings = &[_]DescriptorSetConfig.BindingConfig{
                    // Binding 0: Top-level acceleration structure
                    .{
                        .binding = 0,
                        .descriptor_type = .acceleration_structure_khr,
                        .stage_flags = .{ .raygen_bit_khr = true },
                        .descriptor_count = 1,
                    },
                    // Binding 1: Storage image (output)
                    .{
                        .binding = 1,
                        .descriptor_type = .storage_image,
                        .stage_flags = .{ .raygen_bit_khr = true },
                        .descriptor_count = 1,
                    },
                    // Binding 2: Uniform buffer (camera data)
                    .{
                        .binding = 2,
                        .descriptor_type = .uniform_buffer,
                        .stage_flags = .{ .raygen_bit_khr = true },
                        .descriptor_count = 1,
                    },
                    // Binding 3: Vertex buffers array
                    .{
                        .binding = 3,
                        .descriptor_type = .storage_buffer,
                        .stage_flags = .{ .raygen_bit_khr = true, .closest_hit_bit_khr = true },
                        .descriptor_count = @max(vertex_buffer_count, 1),
                    },
                    // Binding 4: Index buffers array
                    .{
                        .binding = 4,
                        .descriptor_type = .storage_buffer,
                        .stage_flags = .{ .raygen_bit_khr = true, .closest_hit_bit_khr = true },
                        .descriptor_count = @max(index_buffer_count, 1),
                    },
                    // Binding 5: Material buffer
                    .{
                        .binding = 5,
                        .descriptor_type = .storage_buffer,
                        .stage_flags = .{ .closest_hit_bit_khr = true },
                        .descriptor_count = 1,
                    },
                    // Binding 6: Texture array
                    .{
                        .binding = 6,
                        .descriptor_type = .combined_image_sampler,
                        .stage_flags = .{ .closest_hit_bit_khr = true },
                        .descriptor_count = 32, // Support up to 32 textures
                    },
                },
            },
        };

        const manager = try RaytracingDescriptorManager.init(gc, allocator, &set_configs);

        return RaytracingDescriptors{
            .manager = manager,
        };
    }

    pub fn deinit(self: *RaytracingDescriptors) void {
        self.manager.deinit();
    }

    /// Update raytracing descriptor set for current frame
    pub fn updateRaytracingData(
        self: *RaytracingDescriptors,
        frame_index: u32,
        accel_info: *vk.WriteDescriptorSetAccelerationStructureKHR,
        output_image_info: vk.DescriptorImageInfo,
        ubo_info: vk.DescriptorBufferInfo,
        vertex_buffer_infos: []const vk.DescriptorBufferInfo,
        index_buffer_infos: []const vk.DescriptorBufferInfo,
        material_buffer_info: vk.DescriptorBufferInfo,
        texture_image_infos: []const vk.DescriptorImageInfo,
    ) !void {
        var bindings = std.ArrayList(ResourceBinding).init(self.manager.allocator);
        defer bindings.deinit();

        // Acceleration structure
        try bindings.append(.{
            .set_index = 0,
            .binding = 0,
            .resource = .{ .acceleration_structure = accel_info },
        });

        // Output image
        try bindings.append(.{
            .set_index = 0,
            .binding = 1,
            .resource = .{ .image = output_image_info },
        });

        // UBO
        try bindings.append(.{
            .set_index = 0,
            .binding = 2,
            .resource = .{ .buffer = ubo_info },
        });

        // Vertex buffers
        if (vertex_buffer_infos.len > 0) {
            try bindings.append(.{
                .set_index = 0,
                .binding = 3,
                .resource = .{ .buffer_array = vertex_buffer_infos },
            });
        }

        // Index buffers
        if (index_buffer_infos.len > 0) {
            try bindings.append(.{
                .set_index = 0,
                .binding = 4,
                .resource = .{ .buffer_array = index_buffer_infos },
            });
        }

        // Material buffer
        try bindings.append(.{
            .set_index = 0,
            .binding = 5,
            .resource = .{ .buffer = material_buffer_info },
        });

        // Texture array
        if (texture_image_infos.len > 0) {
            try bindings.append(.{
                .set_index = 0,
                .binding = 6,
                .resource = .{ .image_array = texture_image_infos },
            });
        }

        try self.manager.updateDescriptorSet(frame_index, bindings.items);
    }

    /// Get raytracing descriptor set for binding
    pub fn getRaytracingDescriptorSet(self: *RaytracingDescriptors, frame_index: u32) ?vk.DescriptorSet {
        return self.manager.getDescriptorSet(0, frame_index);
    }

    /// Get raytracing descriptor set layout for pipeline creation
    pub fn getRaytracingDescriptorSetLayout(self: *RaytracingDescriptors) ?vk.DescriptorSetLayout {
        return self.manager.getDescriptorSetLayout(0);
    }
};
