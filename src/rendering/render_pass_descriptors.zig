const std = @import("std");
const vk = @import("vulkan");
const DescriptorPool = @import("../core/descriptors.zig").DescriptorPool;
const DescriptorSetLayout = @import("../core/descriptors.zig").DescriptorSetLayout;
const DescriptorWriter = @import("../core/descriptors.zig").DescriptorWriter;
const GraphicsContext = @import("../core/graphics_context.zig").GraphicsContext;
const Buffer = @import("../core/buffer.zig").Buffer;
const MAX_FRAMES_IN_FLIGHT = @import("../core/swapchain.zig").MAX_FRAMES_IN_FLIGHT;
const log = @import("../utils/log.zig").log;

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
        acceleration_structure: *vk.WriteDescriptorSetAccelerationStructureKHR,
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
    descriptor_sets: *std.AutoHashMap(u32, []vk.DescriptorSet),

    // Configuration
    set_configs: []const DescriptorSetConfig,

    // Performance optimization: pre-allocated working memory
    bindings_per_set: std.AutoHashMap(u32, std.ArrayList(ResourceBinding)),
    descriptor_writer: ?*DescriptorWriter,

    pub fn init(
        gc: *GraphicsContext,
        allocator: std.mem.Allocator,
        set_configs: []const DescriptorSetConfig,
    ) !RenderPassDescriptorManager {
        const descriptor_sets = allocator.create(std.AutoHashMap(u32, []vk.DescriptorSet)) catch return error.OutOfMemory;
        descriptor_sets.* = std.AutoHashMap(u32, []vk.DescriptorSet).init(allocator);
        var self = RenderPassDescriptorManager{
            .gc = gc,
            .allocator = allocator,
            .pools = std.AutoHashMap(u32, *DescriptorPool).init(allocator),
            .layouts = std.AutoHashMap(u32, *DescriptorSetLayout).init(allocator),
            .descriptor_sets = descriptor_sets,
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

    pub fn deinit(self: *RenderPassDescriptorManager) void {
        // Deinit performance optimization data structures
        var bindings_iter = self.bindings_per_set.iterator();
        while (bindings_iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
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

    /// Update descriptor set bindings (optimized version)
    pub fn updateDescriptorSet(
        self: *RenderPassDescriptorManager,
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
                result.value_ptr.* = std.ArrayList(ResourceBinding){};
            }
            result.value_ptr.append(self.allocator, binding) catch unreachable;
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

            // Skip pool reset - just use the existing allocated descriptor sets
            // Pool reset causes validation errors when descriptors are still in use by command buffers

            var writer = DescriptorWriter.init(self.gc, layout, pool, self.allocator);

            for (set_bindings) |binding| {
                // Clear writes and update each binding individually to avoid validation errors

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
                    .acceleration_structure => |accel_info| {
                        _ = writer.writeAccelerationStructure(binding.binding, accel_info);
                    },
                }
            }

            // Use pre-allocated descriptor set and just update it
            writer.update(sets[frame_index]);

            // Clean up writer to prevent memory issues
            writer.deinit();
        }
    }

    /// Get descriptor set for a specific set index and frame
    pub fn getDescriptorSet(self: *RenderPassDescriptorManager, set_index: u32, frame_index: u32) ?vk.DescriptorSet {
        const sets = self.descriptor_sets.get(set_index) orelse return null;
        if (frame_index >= sets.len) return null;
        return sets[frame_index];
    }

    /// Get descriptor set layout for a specific set index
    pub fn getDescriptorSetLayout(self: *const RenderPassDescriptorManager, set_index: u32) ?vk.DescriptorSetLayout {
        const layout = self.layouts.get(set_index) orelse return null;
        return layout.descriptor_set_layout;
    }

    /// Get all descriptor set layouts (for pipeline layout creation)
    pub fn getAllLayouts(self: *RenderPassDescriptorManager, allocator: std.mem.Allocator) ![]vk.DescriptorSetLayout {
        var layouts = try std.ArrayList(vk.DescriptorSetLayout){};

        // Sort by set index to ensure correct order
        var set_indices = try std.ArrayList(u32){};
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

    /// Recreate a specific descriptor set with new configuration (for dynamic resizing)
    pub fn recreateDescriptorSet(
        self: *RenderPassDescriptorManager,
        set_index: u32,
        new_config: DescriptorSetConfig,
    ) !void {
        // Wait for device idle before destroying resources
        try self.gc.vkd.deviceWaitIdle(self.gc.dev);

        // Clean up old resources for this set
        if (self.pools.get(set_index)) |old_pool| {
            old_pool.deinit();
            self.allocator.destroy(old_pool);
            _ = self.pools.remove(set_index);
        }

        if (self.layouts.get(set_index)) |old_layout| {
            old_layout.deinit();
            self.allocator.destroy(old_layout);
            _ = self.layouts.remove(set_index);
        }

        if (self.descriptor_sets.get(set_index)) |old_sets| {
            self.allocator.free(old_sets);
            _ = self.descriptor_sets.remove(set_index);
        }

        // IMPORTANT: Clear cached descriptor writer since layout has changed
        if (self.descriptor_writer) |writer| {
            writer.deinit();
            self.allocator.destroy(writer);
            self.descriptor_writer = null;
        }

        // Recreate with new configuration
        try self.createPoolAndLayout(new_config);
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

/// Pre-configured descriptor manager for raytracing rendering pass
pub const RayTracingRenderPassDescriptors = struct {
    manager: *RenderPassDescriptorManager,
    // Store configs on heap so they persist
    configs: []DescriptorSetConfig,
    bindings: []DescriptorSetConfig.BindingConfig,

    pub fn init(
        gc: *GraphicsContext,
        allocator: std.mem.Allocator,
        vertex_buffer_count: u32,
        index_buffer_count: u32,
    ) !RayTracingRenderPassDescriptors {
        // Define descriptor sets for raytracing:
        // Set 0: Raytracing resources (acceleration structure, output image, UBO, vertex/index buffers, materials, textures)

        // Allocate binding configs on heap so they persist
        const bindings_data = [_]DescriptorSetConfig.BindingConfig{
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
                .descriptor_count = 1, // Start with 1, grow dynamically
            },
        };

        const bindings = try allocator.dupe(DescriptorSetConfig.BindingConfig, &bindings_data);

        const set_configs_data = [_]DescriptorSetConfig{
            .{
                .set_index = 0,
                .bindings = bindings,
            },
        };

        // Allocate configs on heap so they persist
        const configs = try allocator.dupe(DescriptorSetConfig, &set_configs_data);
        const manager = try allocator.create(RenderPassDescriptorManager);
        manager.* = try RenderPassDescriptorManager.init(gc, allocator, configs);
        //

        return RayTracingRenderPassDescriptors{
            .manager = manager,
            .configs = configs,
            .bindings = bindings,
        };
    }

    pub fn deinit(self: *RayTracingRenderPassDescriptors) void {
        self.manager.allocator.free(self.bindings);
        self.manager.allocator.free(self.configs);
        self.manager.deinit();
    }

    /// Update raytracing descriptor set for current frame
    pub fn updateRaytracingData(
        self: *RayTracingRenderPassDescriptors,
        frame_index: u32,
        accel_info: *vk.WriteDescriptorSetAccelerationStructureKHR,
        output_image_info: vk.DescriptorImageInfo,
        ubo_info: vk.DescriptorBufferInfo,
        vertex_buffer_infos: []const vk.DescriptorBufferInfo,
        index_buffer_infos: []const vk.DescriptorBufferInfo,
        material_buffer_info: vk.DescriptorBufferInfo,
        texture_image_infos: []const vk.DescriptorImageInfo,
    ) !void {
        var bindings = std.ArrayList(ResourceBinding){};
        defer bindings.deinit(self.manager.allocator);

        // Acceleration structure
        try bindings.append(self.manager.allocator, .{
            .set_index = 0,
            .binding = 0,
            .resource = .{ .acceleration_structure = accel_info },
        });

        // Output image
        try bindings.append(self.manager.allocator, .{
            .set_index = 0,
            .binding = 1,
            .resource = .{ .image = output_image_info },
        });

        // UBO
        try bindings.append(self.manager.allocator, .{
            .set_index = 0,
            .binding = 2,
            .resource = .{ .buffer = ubo_info },
        });

        // Vertex buffers
        if (vertex_buffer_infos.len > 0) {
            try bindings.append(self.manager.allocator, .{
                .set_index = 0,
                .binding = 3,
                .resource = .{ .buffer_array = vertex_buffer_infos },
            });
        }

        // Index buffers
        if (index_buffer_infos.len > 0) {
            try bindings.append(self.manager.allocator, .{
                .set_index = 0,
                .binding = 4,
                .resource = .{ .buffer_array = index_buffer_infos },
            });
        }

        // Material buffer
        // Material buffer
        try bindings.append(self.manager.allocator, .{
            .set_index = 0,
            .binding = 5,
            .resource = .{ .buffer = material_buffer_info },
        });

        // Texture array
        if (texture_image_infos.len > 0) {
            try bindings.append(self.manager.allocator, .{
                .set_index = 0,
                .binding = 6,
                .resource = .{ .image_array = texture_image_infos },
            });
        }
        // Log bindings for debugging
        // Debug logs removed to reduce spam
        try self.manager.updateDescriptorSet(frame_index, bindings.items);
    }

    /// Get raytracing descriptor set for binding
    pub fn getRaytracingDescriptorSet(self: *RayTracingRenderPassDescriptors, frame_index: u32) ?vk.DescriptorSet {
        return self.manager.getDescriptorSet(0, frame_index);
    }

    /// Get raytracing descriptor set layout for pipeline creation
    pub fn getRaytracingDescriptorSetLayout(self: *const RayTracingRenderPassDescriptors) ?vk.DescriptorSetLayout {
        return self.manager.getDescriptorSetLayout(0);
    }

    /// Get descriptor set for a specific frame (alias for consistency)
    pub fn getDescSet(self: *RayTracingRenderPassDescriptors, frame_index: u32) ?vk.DescriptorSet {
        return self.getRaytracingDescriptorSet(frame_index);
    }

    /// Get descriptor set layout (alias for consistency)
    pub fn getDescSetLayout(self: *const RayTracingRenderPassDescriptors) ?vk.DescriptorSetLayout {
        return self.getRaytracingDescriptorSetLayout();
    }

    /// Update material buffer and texture descriptors only
    pub fn updateMatData(
        self: *RayTracingRenderPassDescriptors,
        frame_index: u32,
        material_buffer_info: vk.DescriptorBufferInfo,
        texture_image_infos: []const vk.DescriptorImageInfo,
    ) !void {
        var bindings = std.ArrayList(ResourceBinding){};
        defer bindings.deinit(self.manager.allocator);

        // Material buffer
        try bindings.append(self.manager.allocator, .{
            .set_index = 0,
            .binding = 5,
            .resource = .{ .buffer = material_buffer_info },
        });

        // Texture array
        if (texture_image_infos.len > 0) {
            try bindings.append(self.manager.allocator, .{
                .set_index = 0,
                .binding = 6,
                .resource = .{ .image_array = texture_image_infos },
            });
        }

        try self.manager.updateDescriptorSet(frame_index, bindings.items);
    }

    /// Update acceleration structure and geometry data only
    pub fn updateASData(
        self: *RayTracingRenderPassDescriptors,
        frame_index: u32,
        accel_info: *vk.WriteDescriptorSetAccelerationStructureKHR,
        vertex_buffer_infos: []const vk.DescriptorBufferInfo,
        index_buffer_infos: []const vk.DescriptorBufferInfo,
    ) !void {
        var bindings = try std.ArrayList(ResourceBinding){};
        defer bindings.deinit(self.manager.allocator);

        // Acceleration structure
        try bindings.append(.{
            .set_index = 0,
            .binding = 0,
            .resource = .{ .acceleration_structure = accel_info },
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

        try self.manager.updateDescriptorSet(frame_index, bindings.items);
    }

    /// Check if descriptor layout needs to be recreated due to buffer count changes
    pub fn needsResize(
        self: *const RayTracingRenderPassDescriptors,
        new_vertex_buffer_count: u32,
        new_index_buffer_count: u32,
        new_texture_count: u32,
    ) bool {

        // If no configs exist yet, we need to resize to create initial config
        if (self.configs.len == 0) {
            return true;
        }

        // Get current configuration
        for (self.configs) |config| {
            if (config.set_index == 0) {
                // Check if bindings is valid before accessing
                if (config.bindings.len == 0) {
                    return true;
                }
                for (config.bindings) |binding| {
                    switch (binding.binding) {
                        3 => { // Vertex buffers
                            if (new_vertex_buffer_count > binding.descriptor_count) {
                                return true;
                            }
                        },
                        4 => { // Index buffers
                            if (new_index_buffer_count > binding.descriptor_count) {
                                return true;
                            }
                            if (new_index_buffer_count > binding.descriptor_count) {
                                return true;
                            }
                        },
                        6 => { // Textures
                            if (new_texture_count > binding.descriptor_count) {
                                return true;
                            }
                        },
                        else => {},
                    }
                }
                break;
            }
        }
        return false;
    }

    /// Get current buffer counts for debugging
    pub fn getCurrentBufferCounts(self: *const RayTracingRenderPassDescriptors) struct { vertex_count: u32, index_count: u32 } {
        var vertex_count: u32 = 0;
        var index_count: u32 = 0;

        for (self.configs) |config| {
            if (config.set_index == 0) {
                for (config.bindings) |binding| {
                    switch (binding.binding) {
                        3 => vertex_count = binding.descriptor_count,
                        4 => index_count = binding.descriptor_count,
                        else => {},
                    }
                }
                break;
            }
        }

        return .{ .vertex_count = vertex_count, .index_count = index_count };
    }

    /// Update from scene view raytracing data
    pub fn updateFromSceneViewData(
        self: *RayTracingRenderPassDescriptors,
        frame_index: u32,
        accel_info: *vk.WriteDescriptorSetAccelerationStructureKHR,
        output_image_info: vk.DescriptorImageInfo,
        ubo_info: vk.DescriptorBufferInfo,
        material_buffer_info: vk.DescriptorBufferInfo,
        texture_image_infos: []const vk.DescriptorImageInfo,
        rt_data: anytype, // SceneView.RaytracingData
    ) !void {
        // Extract vertex and index buffer infos from raytracing data
        var vertex_buffer_infos = std.ArrayList(vk.DescriptorBufferInfo){};
        defer vertex_buffer_infos.deinit(self.manager.allocator);
        try vertex_buffer_infos.ensureTotalCapacity(self.manager.allocator, rt_data.geometries.len);

        var index_buffer_infos = std.ArrayList(vk.DescriptorBufferInfo){};
        defer index_buffer_infos.deinit(self.manager.allocator);
        try index_buffer_infos.ensureTotalCapacity(self.manager.allocator, rt_data.geometries.len);

        // Convert raytracing data geometries to descriptor buffer infos
        for (rt_data.geometries) |geometry| {
            const mesh = geometry.mesh_ptr;

            // Add vertex buffer info
            if (mesh.vertex_buffer) |vertex_buf| {
                vertex_buffer_infos.appendAssumeCapacity(vk.DescriptorBufferInfo{
                    .buffer = vertex_buf.buffer,
                    .offset = 0,
                    .range = vertex_buf.instance_size * vertex_buf.instance_count,
                });
            }

            // Add index buffer info
            if (mesh.index_buffer) |index_buf| {
                index_buffer_infos.appendAssumeCapacity(vk.DescriptorBufferInfo{
                    .buffer = index_buf.buffer,
                    .offset = 0,
                    .range = index_buf.instance_size * index_buf.instance_count,
                });
            }
        }

        // Update all raytracing data
        try self.updateRaytracingData(
            frame_index,
            accel_info,
            output_image_info,
            ubo_info,
            vertex_buffer_infos.items,
            index_buffer_infos.items,
            material_buffer_info,
            texture_image_infos,
        );
    }
};
