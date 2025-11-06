const std = @import("std");
const vk = @import("vulkan");
const UnifiedPipelineSystem = @import("unified_pipeline_system.zig").UnifiedPipelineSystem;
const PipelineId = @import("unified_pipeline_system.zig").PipelineId;
const Resource = @import("unified_pipeline_system.zig").Resource;
const Buffer = @import("../core/buffer.zig").Buffer;
const Texture = @import("../core/texture.zig").Texture;
const log = @import("../utils/log.zig").log;

// ============================================================================
// TODO: MAJOR REFACTOR - NAMED RESOURCE BINDING & CENTRALIZED MANAGEMENT
// ============================================================================
//
// GOAL: Simplify render passes by moving resource management here
//
// 1. NAMED RESOURCE BINDING API
//    Replace numeric binding indices with descriptive names:
//
//    Before:
//      resource_binder.bindUniformBuffer(pipeline, 0, 2, light_buffer, ...);
//
//    After:
//      resource_binder.bindBuffer("LightBuffer", light_buffer);
//      resource_binder.bindTexture("AlbedoMap", albedo_texture);
//      resource_binder.bindStorageBuffer("ParticleData", particle_buffer);
//
//    Implementation:
//    - Add StringHashMap([]const u8, BindingLocation) for name->binding lookup
//    - Cache string hashes for performance
//    - Load binding names from shader reflection or config file
//
// 2. CENTRALIZED RESOURCE MANAGEMENT
//    Move resource lifetime tracking OUT of render passes:
//    - Track texture updates/invalidation
//    - Track buffer recreation/resizing
//    - Automatically rebind resources when pipelines change
//    - Handle descriptor set invalidation
//
//    Render passes should ONLY contain rendering logic, not resource checks!
//
// 3. AUTOMATIC RESOURCE VALIDATION
//    - Warn if binding name doesn't exist in shader
//    - Error if required binding is missing before draw
//    - Track which resources are "dirty" and need rebinding
//
// ============================================================================

/// High-level resource binding abstraction for the unified pipeline system
///
/// This provides a convenient interface for binding common resources like
/// uniform buffers, textures, and storage buffers to pipelines.
pub const ResourceBinder = struct {
    pipeline_system: *UnifiedPipelineSystem,
    allocator: std.mem.Allocator,

    // Resource tracking
    bound_uniform_buffers: std.HashMap(BindingKey, BoundUniformBuffer, BindingKeyContext, std.hash_map.default_max_load_percentage),
    bound_textures: std.HashMap(BindingKey, BoundTexture, BindingKeyContext, std.hash_map.default_max_load_percentage),
    bound_storage_buffers: std.HashMap(BindingKey, BoundStorageBuffer, BindingKeyContext, std.hash_map.default_max_load_percentage),

    pub fn init(allocator: std.mem.Allocator, pipeline_system: *UnifiedPipelineSystem) ResourceBinder {
        return ResourceBinder{
            .pipeline_system = pipeline_system,
            .allocator = allocator,
            .bound_uniform_buffers = std.HashMap(BindingKey, BoundUniformBuffer, BindingKeyContext, std.hash_map.default_max_load_percentage).init(allocator),
            .bound_textures = std.HashMap(BindingKey, BoundTexture, BindingKeyContext, std.hash_map.default_max_load_percentage).init(allocator),
            .bound_storage_buffers = std.HashMap(BindingKey, BoundStorageBuffer, BindingKeyContext, std.hash_map.default_max_load_percentage).init(allocator),
        };
    }

    pub fn deinit(self: *ResourceBinder) void {
        self.bound_uniform_buffers.deinit();
        self.bound_textures.deinit();
        self.bound_storage_buffers.deinit();
    }

    /// Bind a uniform buffer to a pipeline
    pub fn bindUniformBuffer(
        self: *ResourceBinder,
        pipeline_id: PipelineId,
        set: u32,
        binding: u32,
        buffer: *Buffer,
        offset: vk.DeviceSize,
        range: vk.DeviceSize,
        frame_index: u32,
    ) !void {
        const resource = Resource{
            .buffer = .{
                .buffer = buffer.buffer,
                .offset = offset,
                .range = range,
            },
        };

        try self.pipeline_system.bindResource(pipeline_id, set, binding, resource, frame_index);

        // Track the binding for convenience functions
        const key = BindingKey{
            .pipeline_id = pipeline_id,
            .set = set,
            .binding = binding,
            .frame_index = frame_index,
        };

        const bound_buffer = BoundUniformBuffer{
            .buffer = buffer,
            .offset = offset,
            .range = range,
        };

        try self.bound_uniform_buffers.put(key, bound_buffer);
    }

    /// Bind a texture (image + sampler) to a pipeline
    pub fn bindTexture(
        self: *ResourceBinder,
        pipeline_id: PipelineId,
        set: u32,
        binding: u32,
        image_view: vk.ImageView,
        sampler: vk.Sampler,
        layout: vk.ImageLayout,
        frame_index: u32,
    ) !void {
        const resource = Resource{
            .image = .{
                .image_view = image_view,
                .sampler = sampler,
                .layout = layout,
            },
        };

        try self.pipeline_system.bindResource(pipeline_id, set, binding, resource, frame_index);

        // Track the binding
        const key = BindingKey{
            .pipeline_id = pipeline_id,
            .set = set,
            .binding = binding,
            .frame_index = frame_index,
        };

        const bound_texture = BoundTexture{
            .image_view = image_view,
            .sampler = sampler,
            .layout = layout,
        };

        try self.bound_textures.put(key, bound_texture);
    }

    /// Bind a storage buffer to a pipeline
    pub fn bindStorageBuffer(
        self: *ResourceBinder,
        pipeline_id: PipelineId,
        set: u32,
        binding: u32,
        buffer: *Buffer,
        offset: vk.DeviceSize,
        range: vk.DeviceSize,
        frame_index: u32,
    ) !void {
        const resource = Resource{
            .buffer = .{
                .buffer = buffer.buffer,
                .offset = offset,
                .range = range,
            },
        };

        try self.pipeline_system.bindResource(pipeline_id, set, binding, resource, frame_index);

        // Track the binding
        const key = BindingKey{
            .pipeline_id = pipeline_id,
            .set = set,
            .binding = binding,
            .frame_index = frame_index,
        };

        const bound_storage = BoundStorageBuffer{
            .buffer = buffer,
            .offset = offset,
            .range = range,
        };

        try self.bound_storage_buffers.put(key, bound_storage);
    }

    /// Convenience function to bind a full uniform buffer
    pub fn bindFullUniformBuffer(
        self: *ResourceBinder,
        pipeline_id: PipelineId,
        set: u32,
        binding: u32,
        buffer: *Buffer,
        frame_index: u32,
    ) !void {
        try self.bindUniformBuffer(pipeline_id, set, binding, buffer, 0, vk.WHOLE_SIZE, frame_index);
    }

    /// Convenience function to bind a full storage buffer
    pub fn bindFullStorageBuffer(
        self: *ResourceBinder,
        pipeline_id: PipelineId,
        set: u32,
        binding: u32,
        buffer: *Buffer,
        frame_index: u32,
    ) !void {
        try self.bindStorageBuffer(pipeline_id, set, binding, buffer, 0, vk.WHOLE_SIZE, frame_index);
    }

    /// Bind a texture with default shader-read-only layout
    pub fn bindTextureDefault(
        self: *ResourceBinder,
        pipeline_id: PipelineId,
        set: u32,
        binding: u32,
        image_view: vk.ImageView,
        sampler: vk.Sampler,
        frame_index: u32,
    ) !void {
        try self.bindTexture(pipeline_id, set, binding, image_view, sampler, .general, frame_index);
    }

    /// Update descriptor bindings for a specific pipeline and frame
    pub fn updateFrame(self: *ResourceBinder, pipeline_id: PipelineId, frame_index: u32) !void {
        try self.pipeline_system.updateDescriptorSetsForPipeline(pipeline_id, frame_index);
    }

    /// Get information about a bound uniform buffer
    pub fn getBoundUniformBuffer(self: *ResourceBinder, pipeline_id: PipelineId, set: u32, binding: u32, frame_index: u32) ?BoundUniformBuffer {
        const key = BindingKey{
            .pipeline_id = pipeline_id,
            .set = set,
            .binding = binding,
            .frame_index = frame_index,
        };

        return self.bound_uniform_buffers.get(key);
    }

    /// Get information about a bound texture
    pub fn getBoundTexture(self: *ResourceBinder, pipeline_id: PipelineId, set: u32, binding: u32, frame_index: u32) ?BoundTexture {
        const key = BindingKey{
            .pipeline_id = pipeline_id,
            .set = set,
            .binding = binding,
            .frame_index = frame_index,
        };

        return self.bound_textures.get(key);
    }

    /// Get information about a bound storage buffer
    pub fn getBoundStorageBuffer(self: *ResourceBinder, pipeline_id: PipelineId, set: u32, binding: u32, frame_index: u32) ?BoundStorageBuffer {
        const key = BindingKey{
            .pipeline_id = pipeline_id,
            .set = set,
            .binding = binding,
            .frame_index = frame_index,
        };

        return self.bound_storage_buffers.get(key);
    }

    /// Clear all bindings for a specific frame (useful for frame reset)
    pub fn clearFrame(self: *ResourceBinder, frame_index: u32) void {
        // Remove all bindings for this frame
        var uniform_iter = self.bound_uniform_buffers.iterator();
        while (uniform_iter.next()) |entry| {
            if (entry.key_ptr.frame_index == frame_index) {
                _ = self.bound_uniform_buffers.remove(entry.key_ptr.*);
            }
        }

        var texture_iter = self.bound_textures.iterator();
        while (texture_iter.next()) |entry| {
            if (entry.key_ptr.frame_index == frame_index) {
                _ = self.bound_textures.remove(entry.key_ptr.*);
            }
        }

        var storage_iter = self.bound_storage_buffers.iterator();
        while (storage_iter.next()) |entry| {
            if (entry.key_ptr.frame_index == frame_index) {
                _ = self.bound_storage_buffers.remove(entry.key_ptr.*);
            }
        }
    }

    /// Clear all bindings for a specific pipeline
    pub fn clearPipeline(self: *ResourceBinder, pipeline_id: PipelineId) void {
        var uniform_iter = self.bound_uniform_buffers.iterator();
        while (uniform_iter.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.pipeline_id.name, pipeline_id.name)) {
                _ = self.bound_uniform_buffers.remove(entry.key_ptr.*);
            }
        }

        var texture_iter = self.bound_textures.iterator();
        while (texture_iter.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.pipeline_id.name, pipeline_id.name)) {
                _ = self.bound_textures.remove(entry.key_ptr.*);
            }
        }

        var storage_iter = self.bound_storage_buffers.iterator();
        while (storage_iter.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.pipeline_id.name, pipeline_id.name)) {
                _ = self.bound_storage_buffers.remove(entry.key_ptr.*);
            }
        }
    }
};

/// Key for tracking resource bindings
const BindingKey = struct {
    pipeline_id: PipelineId,
    set: u32,
    binding: u32,
    frame_index: u32,
};

/// Bound uniform buffer information
pub const BoundUniformBuffer = struct {
    buffer: *Buffer,
    offset: vk.DeviceSize,
    range: vk.DeviceSize,
};

/// Bound texture information
pub const BoundTexture = struct {
    image_view: vk.ImageView,
    sampler: vk.Sampler,
    layout: vk.ImageLayout,
};

/// Bound storage buffer information
pub const BoundStorageBuffer = struct {
    buffer: *Buffer,
    offset: vk.DeviceSize,
    range: vk.DeviceSize,
};

/// Context for BindingKey HashMap
const BindingKeyContext = struct {
    pub fn hash(self: @This(), key: BindingKey) u64 {
        _ = self;
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&key.pipeline_id.hash));
        hasher.update(std.mem.asBytes(&key.set));
        hasher.update(std.mem.asBytes(&key.binding));
        hasher.update(std.mem.asBytes(&key.frame_index));
        return hasher.final();
    }

    pub fn eql(self: @This(), a: BindingKey, b: BindingKey) bool {
        _ = self;
        return std.mem.eql(u8, a.pipeline_id.name, b.pipeline_id.name) and
            a.set == b.set and
            a.binding == b.binding and
            a.frame_index == b.frame_index;
    }
};
