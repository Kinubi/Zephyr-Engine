const std = @import("std");
const vk = @import("vulkan");
const UnifiedPipelineSystem = @import("unified_pipeline_system.zig").UnifiedPipelineSystem;
const PipelineId = @import("unified_pipeline_system.zig").PipelineId;
const Resource = @import("unified_pipeline_system.zig").Resource;
const Buffer = @import("../core/buffer.zig").Buffer;
const Texture = @import("../core/texture.zig").Texture;
const ShaderReflection = @import("../assets/shader_compiler.zig").ShaderReflection;
const ManagedBuffer = @import("buffer_manager.zig").ManagedBuffer;
const ManagedTexture = @import("texture_manager.zig").ManagedTexture;
const ManagedTextureArray = @import("../ecs/systems/material_system.zig").ManagedTextureArray;
const ManagedTLAS = @import("../rendering/raytracing/raytracing_system.zig").ManagedTLAS;
const log = @import("../utils/log.zig").log;

const MAX_FRAMES_IN_FLIGHT = @import("../core/swapchain.zig").MAX_FRAMES_IN_FLIGHT;

// ============================================================================
// RESOURCE BINDING SYSTEM - GENERATION-BASED AUTOMATIC REBINDING
// ============================================================================
//
// STATUS: ✅ IMPLEMENTED (November 2025)
//
// FEATURES:
// 1. ✅ NAMED RESOURCE BINDING API
//    - bindUniformBufferNamed() / bindStorageBufferNamed() for buffers
//    - bindTextureNamed() / bindTextureArrayNamed() for textures
//    - bindAccelerationStructureNamed() for ray tracing
//    - Names resolved from shader reflection
//
// 2. ✅ GENERATION-BASED TRACKING
//    - Each resource (buffer, texture, TLAS) has a generation counter
//    - Generation increments when resource handle changes (recreation)
//    - updateFrame() automatically rebinds when generation changes
//    - Avoids unnecessary descriptor updates (data-only changes don't increment)
//
// 3. ✅ AUTOMATIC RESOURCE VALIDATION
//    - Warning if binding name doesn't exist in shader
//    - Validation errors caught at bind time
//    - Per-frame generation tracking
//
// FUTURE ENHANCEMENTS:
// - Automatic validation of required bindings before draw
// - Descriptor set pooling and caching
// - Multi-threaded descriptor allocation
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
    bound_acceleration_structures: std.HashMap(BindingKey, BoundAccelerationStructure, BindingKeyContext, std.hash_map.default_max_load_percentage),

    // Phase 2: Named binding registry
    binding_registry: std.StringHashMap(BindingLocation),

    // Named resource tracking (for generation-based change detection)
    tracked_resources: std.ArrayList(BoundResource),

    /// Named binding location information
    pub const BindingLocation = struct {
        set: u32,
        binding: u32,
        binding_type: BindingType,
    };

    /// Binding types for validation
    pub const BindingType = enum {
        uniform_buffer,
        storage_buffer,
        sampled_image,
        storage_image,
        combined_image_sampler,
        acceleration_structure,
    };

    pub fn init(allocator: std.mem.Allocator, pipeline_system: *UnifiedPipelineSystem) ResourceBinder {
        return ResourceBinder{
            .pipeline_system = pipeline_system,
            .allocator = allocator,
            .bound_uniform_buffers = std.HashMap(BindingKey, BoundUniformBuffer, BindingKeyContext, std.hash_map.default_max_load_percentage).init(allocator),
            .bound_textures = std.HashMap(BindingKey, BoundTexture, BindingKeyContext, std.hash_map.default_max_load_percentage).init(allocator),
            .bound_storage_buffers = std.HashMap(BindingKey, BoundStorageBuffer, BindingKeyContext, std.hash_map.default_max_load_percentage).init(allocator),
            .bound_acceleration_structures = std.HashMap(BindingKey, BoundAccelerationStructure, BindingKeyContext, std.hash_map.default_max_load_percentage).init(allocator),
            .binding_registry = std.StringHashMap(BindingLocation).init(allocator),
            .tracked_resources = .{},
        };
    }

    pub fn deinit(self: *ResourceBinder) void {
        // Clean up binding registry names
        var iterator = self.binding_registry.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.binding_registry.deinit();

        // Clean up tracked resource names
        for (self.tracked_resources.items) |res| {
            self.allocator.free(res.name);
        }
        self.tracked_resources.deinit(self.allocator);

        self.bound_uniform_buffers.deinit();
        self.bound_textures.deinit();
        self.bound_storage_buffers.deinit();
    }

    /// Register a named binding location (manual or from shader reflection)
    pub fn registerBinding(
        self: *ResourceBinder,
        name: []const u8,
        location: BindingLocation,
    ) !void {
        // Check if binding already exists
        if (self.binding_registry.get(name)) |existing_location| {
            // If location matches exactly, it's a duplicate from multiple shader stages (vertex + fragment)
            if (existing_location.set == location.set and
                existing_location.binding == location.binding and
                existing_location.binding_type == location.binding_type)
            {
                // Silently skip duplicate - this is expected for bindings used in multiple shader stages
                return;
            }

            // Different location for same name - this is a warning-worthy situation
            log(.WARN, "resource_binder", "Binding name '{s}' already registered with different location (old: set:{} binding:{} type:{}, new: set:{} binding:{} type:{})", .{ name, existing_location.set, existing_location.binding, existing_location.binding_type, location.set, location.binding, location.binding_type });
            return error.DuplicateBindingName;
        }

        // New binding - allocate and register
        const owned_name = try self.allocator.dupe(u8, name);
        try self.binding_registry.put(owned_name, location);
    }

    /// Look up a binding location by name
    pub fn lookupBinding(self: *ResourceBinder, name: []const u8) ?BindingLocation {
        return self.binding_registry.get(name);
    }

    /// Clear all registered bindings (e.g., when pipeline changes)
    pub fn clearBindingRegistry(self: *ResourceBinder) void {
        var iterator = self.binding_registry.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.binding_registry.clearAndFree();
    }

    /// Populate binding registry from shader reflection data
    /// This is called by UnifiedPipelineSystem when creating pipelines
    pub fn populateFromReflection(
        self: *ResourceBinder,
        reflection: ShaderReflection,
    ) !void {

        // Register uniform buffers
        for (reflection.uniform_buffers.items) |ub| {
            const location = BindingLocation{
                .set = ub.set,
                .binding = ub.binding,
                .binding_type = .uniform_buffer,
            };
            try self.registerBinding(ub.name, location);
        }

        // Register storage buffers
        for (reflection.storage_buffers.items) |sb| {
            const location = BindingLocation{
                .set = sb.set,
                .binding = sb.binding,
                .binding_type = .storage_buffer,
            };
            try self.registerBinding(sb.name, location);
        }

        // Register textures
        for (reflection.textures.items) |tex| {
            const location = BindingLocation{
                .set = tex.set,
                .binding = tex.binding,
                .binding_type = .combined_image_sampler,
            };
            try self.registerBinding(tex.name, location);
        }

        // Register storage images
        for (reflection.storage_images.items) |img| {
            const location = BindingLocation{
                .set = img.set,
                .binding = img.binding,
                .binding_type = .storage_image,
            };
            try self.registerBinding(img.name, location);
        }

        // Register samplers
        for (reflection.samplers.items) |samp| {
            const location = BindingLocation{
                .set = samp.set,
                .binding = samp.binding,
                .binding_type = .sampled_image,
            };
            try self.registerBinding(samp.name, location);
        }

        for (reflection.acceleration_structures.items) |as| {
            const location = BindingLocation{
                .set = as.set,
                .binding = as.binding,
                .binding_type = .acceleration_structure,
            };
            try self.registerBinding(as.name, location);
        }
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

    // ============================================================================
    // PHASE 2: NAMED BINDING API
    // ============================================================================
    //
    // AUTOMATIC SHADER REFLECTION:
    // - Binding names are automatically extracted from shader reflection via SPIRV-Cross
    // - The names come directly from the variable names declared in shaders (GLSL/HLSL)
    // - UnifiedPipelineSystem calls populateFromReflection() when creating pipelines
    // - This ensures binding names match exactly what's declared in shader code
    //
    // SHADER NAMING CONVENTIONS (for shader authors):
    // - Use descriptive names that indicate the buffer's purpose in shaders:
    //   * layout(binding = 0) uniform CameraUBO { ... } cameraUBO;
    //   * layout(binding = 1) buffer MaterialBuffer { ... } materialBuffer;
    //   * layout(binding = 2) uniform sampler2D albedoTexture;
    // - Use camelCase or PascalCase for consistency with code style
    // - Avoid generic names like "buffer0", "texture1" - be descriptive!
    // - Array resources use array syntax: uniform sampler2D textures[16];
    //
    // USAGE IN CODE:
    // - Use the exact name from shader: bindUniformBufferNamed("CameraUBO", ...)
    // - Names are case-sensitive and must match shader declarations exactly
    // - Check spirv_reflection_debug.json for available binding names
    //
    // ============================================================================

    /// Bind a uniform buffer by name
    /// Takes a ManagedBuffer, binds for all frames, and tracks generation changes
    pub fn bindUniformBufferNamed(
        self: *ResourceBinder,
        pipeline_id: PipelineId,
        binding_name: []const u8,
        frame_buffers: [MAX_FRAMES_IN_FLIGHT]*const ManagedBuffer,
    ) !void {
        const location = self.lookupBinding(binding_name) orelse {
            log(.ERROR, "resource_binder", "Unknown binding name: '{s}'", .{binding_name});
            return error.UnknownBinding;
        };

        if (location.binding_type != .uniform_buffer) {
            log(.ERROR, "resource_binder", "Binding '{s}' is not a uniform buffer (type: {})", .{ binding_name, location.binding_type });
            return error.BindingTypeMismatch;
        }

        // Register the first frame's buffer for generation tracking (all frames share same generation)
        // We only track one buffer since they all have the same generation tracking behavior
        try self.registerBufferByName(binding_name, pipeline_id, frame_buffers[0]);

        // Bind each frame buffer to its corresponding frame
        for (frame_buffers, 0..) |managed_buffer, frame_idx| {
            if (managed_buffer.generation == 0) {
                // Buffer not created yet - skip initial bind, updateFrame will bind it later
                continue;
            }

            // Bind the Vulkan buffer handle for this specific frame
            const frame_index = @as(u32, @intCast(frame_idx));
            try self.bindUniformBuffer(
                pipeline_id,
                location.set,
                location.binding,
                @constCast(&managed_buffer.buffer),
                0, // offset
                managed_buffer.size, // use buffer's actual size
                frame_index,
            );
        }
    }

    /// Bind a managed storage buffer by name for all frames
    /// Automatically registers the buffer for generation-based tracking
    pub fn bindStorageBufferNamed(
        self: *ResourceBinder,
        pipeline_id: PipelineId,
        binding_name: []const u8,
        managed_buffer: *const ManagedBuffer,
    ) !void {
        const location = self.lookupBinding(binding_name) orelse {
            log(.ERROR, "resource_binder", "Unknown binding name: '{s}'", .{binding_name});
            return error.UnknownBinding;
        };

        if (location.binding_type != .storage_buffer) {
            log(.ERROR, "resource_binder", "Binding '{s}' is not a storage buffer (type: {})", .{ binding_name, location.binding_type });
            return error.BindingTypeMismatch;
        }

        // Register for generation tracking (once)
        try self.registerBufferByName(binding_name, pipeline_id, managed_buffer);

        if (managed_buffer.generation == 0) {
            // Buffer not created yet - skip initial bind, updateFrame will bind it later
            return;
        }

        // Bind the Vulkan buffer handle for all frames using buffer's size
        for (0..MAX_FRAMES_IN_FLIGHT) |frame_idx| {
            const frame_index = @as(u32, @intCast(frame_idx));
            try self.bindStorageBuffer(
                pipeline_id,
                location.set,
                location.binding,
                @constCast(&managed_buffer.buffer),
                0, // offset
                managed_buffer.size, // use buffer's actual size
                frame_index,
            );
        }
    }

    /// Bind a texture by name
    pub fn bindTextureNamed(
        self: *ResourceBinder,
        pipeline_id: PipelineId,
        binding_name: []const u8,
        image_view: vk.ImageView,
        sampler: vk.Sampler,
        layout: vk.ImageLayout,
        frame_index: u32,
    ) !void {
        const location = self.lookupBinding(binding_name) orelse {
            log(.ERROR, "resource_binder", "Unknown binding name: '{s}'", .{binding_name});
            return error.UnknownBinding;
        };

        if (location.binding_type != .combined_image_sampler and location.binding_type != .sampled_image) {
            log(.ERROR, "resource_binder", "Binding '{s}' is not a texture (type: {})", .{ binding_name, location.binding_type });
            return error.BindingTypeMismatch;
        }

        try self.bindTexture(pipeline_id, location.set, location.binding, image_view, sampler, layout, frame_index);
    }

    /// Bind a managed texture by name for all frames
    /// Automatically registers the texture for generation-based tracking
    pub fn bindManagedTextureNamed(
        self: *ResourceBinder,
        pipeline_id: PipelineId,
        binding_name: []const u8,
        managed_texture: *const ManagedTexture,
    ) !void {
        const location = self.lookupBinding(binding_name) orelse {
            log(.ERROR, "resource_binder", "Unknown binding name: '{s}'", .{binding_name});
            return error.UnknownBinding;
        };

        if (location.binding_type != .combined_image_sampler and location.binding_type != .sampled_image and location.binding_type != .storage_image) {
            log(.ERROR, "resource_binder", "Binding '{s}' is not a texture (type: {})", .{ binding_name, location.binding_type });
            return error.BindingTypeMismatch;
        }

        // Register for generation tracking (once)
        try self.registerTextureByName(binding_name, pipeline_id, managed_texture);

        if (managed_texture.generation == 0) {
            // Texture not created yet - skip initial bind, updateFrame will bind it later
            return;
        }

        // Get descriptor info from managed texture (need to cast away const for getDescriptorInfo)
        const descriptor_info = @constCast(&managed_texture.texture).getDescriptorInfo();

        // Bind the texture for all frames
        for (0..MAX_FRAMES_IN_FLIGHT) |frame_idx| {
            const frame_index = @as(u32, @intCast(frame_idx));
            try self.bindTexture(
                pipeline_id,
                location.set,
                location.binding,
                descriptor_info.image_view,
                descriptor_info.sampler,
                descriptor_info.image_layout,
                frame_index,
            );
        }
    }

    /// Bind an acceleration structure (TLAS) by name for all frames
    /// Automatically registers the TLAS for generation-based tracking
    pub fn bindAccelerationStructureNamed(
        self: *ResourceBinder,
        pipeline_id: PipelineId,
        binding_name: []const u8,
        managed_tlas: *const ManagedTLAS,
    ) !void {
        const location = self.lookupBinding(binding_name) orelse {
            log(.ERROR, "resource_binder", "Unknown binding name: '{s}'", .{binding_name});
            return error.UnknownBinding;
        };

        // Note: There's no specific acceleration_structure type in BindingType yet
        // Acceleration structures are typically storage images or special descriptors
        // We'll skip type validation for now since it's a special case

        // Register for generation tracking
        try self.registerAccelerationStructureByName(binding_name, pipeline_id, managed_tlas);

        if (managed_tlas.generation == 0) {
            // TLAS not created yet - skip initial bind, updateFrame will bind it later
            return;
        }

        // Bind the acceleration structure for all frames
        for (0..MAX_FRAMES_IN_FLIGHT) |frame_idx| {
            const frame_index = @as(u32, @intCast(frame_idx));

            const resource = Resource{
                .acceleration_structure = managed_tlas.acceleration_structure,
            };

            try self.pipeline_system.bindResource(
                pipeline_id,
                location.set,
                location.binding,
                resource,
                frame_index,
            );
        }
    }

    /// Convenience function to bind a full uniform buffer by name
    pub fn bindFullUniformBufferNamed(
        self: *ResourceBinder,
        pipeline_id: PipelineId,
        binding_name: []const u8,
        buffer: *Buffer,
        frame_index: u32,
    ) !void {
        try self.bindUniformBufferNamed(pipeline_id, binding_name, buffer, 0, vk.WHOLE_SIZE, frame_index);
    }

    /// Convenience function to bind a full storage buffer by name
    pub fn bindFullStorageBufferNamed(
        self: *ResourceBinder,
        pipeline_id: PipelineId,
        binding_name: []const u8,
        buffer: *Buffer,
        frame_index: u32,
    ) !void {
        try self.bindStorageBufferNamed(pipeline_id, binding_name, buffer, 0, vk.WHOLE_SIZE, frame_index);
    }

    /// Bind a texture array by name (for descriptor arrays like uniform sampler2D textures[N])
    /// Bind a managed texture array with automatic generation tracking
    /// Registers the ManagedTextureArray for tracking and binds for all frames
    pub fn bindTextureArrayNamed(
        self: *ResourceBinder,
        pipeline_id: PipelineId,
        binding_name: []const u8,
        managed_textures: *const ManagedTextureArray,
    ) !void {
        const location = self.lookupBinding(binding_name) orelse {
            log(.ERROR, "resource_binder", "Unknown binding name: '{s}'", .{binding_name});
            return error.UnknownBinding;
        };

        if (location.binding_type != .combined_image_sampler and location.binding_type != .sampled_image) {
            log(.ERROR, "resource_binder", "Binding '{s}' is not a texture (type: {})", .{ binding_name, location.binding_type });
            return error.BindingTypeMismatch;
        }

        // Always register for generation tracking
        try self.updateTextureArrayByName(binding_name, pipeline_id, managed_textures);

        // Don't bind if generation is 0 (not created yet) or if descriptor array is empty - updateFrame will bind it later
        if (managed_textures.generation == 0 or managed_textures.descriptor_infos.len == 0) {
            return;
        }

        // Bind for all frames
        for (0..MAX_FRAMES_IN_FLIGHT) |frame_idx| {
            const frame_index = @as(u32, @intCast(frame_idx));

            const resource = Resource{
                .image_array = managed_textures.descriptor_infos,
            };

            try self.pipeline_system.bindResource(pipeline_id, location.set, location.binding, resource, frame_index);
        }
    }

    /// Bind a buffer array (e.g., vertex/index buffers for ray tracing)
    /// Takes descriptor buffer infos and a generation counter for change tracking
    pub fn bindBufferArrayNamed(
        self: *ResourceBinder,
        pipeline_id: PipelineId,
        binding_name: []const u8,
        buffer_infos: []const vk.DescriptorBufferInfo,
        buffer_infos_arraylist: *const std.ArrayList(vk.DescriptorBufferInfo),
        generation_ptr: *const u32,
    ) !void {
        const location = self.lookupBinding(binding_name) orelse {
            log(.ERROR, "resource_binder", "Unknown binding name: '{s}'", .{binding_name});
            return error.UnknownBinding;
        };

        if (location.binding_type != .storage_buffer) {
            log(.ERROR, "resource_binder", "Binding '{s}' is not a storage buffer (type: {})", .{ binding_name, location.binding_type });
            return error.BindingTypeMismatch;
        }

        // Check if already tracked, update if found
        for (self.tracked_resources.items) |*res| {
            if (res.pipeline_id.hash == pipeline_id.hash and
                std.mem.eql(u8, res.name, binding_name))
            {
                // Update the pointers (in case arraylist moved)
                res.resource = .{
                    .buffer_array = .{
                        .buffer_infos_ptr = buffer_infos_arraylist,
                        .generation_ptr = generation_ptr,
                    },
                };
                // Don't update last_generation - let updateFrame detect the change

                log(.INFO, "resource_binder", "Updated tracked buffer array '{s}', {} buffers", .{ binding_name, buffer_infos.len });

                // Bind immediately if we have data
                if (buffer_infos.len > 0) {
                    for (0..MAX_FRAMES_IN_FLIGHT) |frame_idx| {
                        const frame_index = @as(u32, @intCast(frame_idx));
                        const resource = Resource{ .buffer_array = buffer_infos };
                        try self.pipeline_system.bindResource(pipeline_id, location.set, location.binding, resource, frame_index);
                    }
                }
                return;
            }
        }

        // Not found, add new tracked resource
        const name_copy = try self.allocator.dupe(u8, binding_name);
        log(.INFO, "resource_binder", "Registered buffer array '{s}' for tracking, {} buffers", .{ binding_name, buffer_infos.len });

        try self.tracked_resources.append(self.allocator, BoundResource{
            .name = name_copy,
            .set = location.set,
            .binding = location.binding,
            .pipeline_id = pipeline_id,
            .resource = .{
                .buffer_array = .{
                    .buffer_infos_ptr = buffer_infos_arraylist,
                    .generation_ptr = generation_ptr,
                },
            },
            .last_generation = 0, // Will be updated on first updateFrame call
        });

        // Bind immediately only if we have data
        if (buffer_infos.len == 0) {
            return;
        }

        // Bind for all frames
        for (0..MAX_FRAMES_IN_FLIGHT) |frame_idx| {
            const frame_index = @as(u32, @intCast(frame_idx));

            const resource = Resource{
                .buffer_array = buffer_infos,
            };

            try self.pipeline_system.bindResource(pipeline_id, location.set, location.binding, resource, frame_index);
        }
    }

    // ============================================================================
    // GENERATION-BASED MANAGED BUFFER TRACKING
    // ============================================================================
    //
    // Systems register their ManagedBuffers by name. ResourceBinder tracks the
    // generation and automatically rebinds when the buffer changes.
    //
    // Usage:
    //   // In MaterialSystem, just register the buffer reference
    //   resource_binder.registerBufferByName("MaterialBuffer", pipeline_id, &managed_buffer);
    //
    //   // In updateFrame, ResourceBinder checks generation and rebinds if changed
    //   resource_binder.updateFrame(pipeline_id, frame_index);
    //
    // ============================================================================

    /// Register or update a managed buffer for automatic generation tracking
    /// The buffer will be rebound automatically in updateFrame() if its generation changes
    pub fn registerBufferByName(
        self: *ResourceBinder,
        binding_name: []const u8,
        pipeline_id: PipelineId,
        managed_buffer: *const ManagedBuffer,
    ) !void {
        // Look up the binding location
        const location = self.lookupBinding(binding_name) orelse {
            log(.ERROR, "resource_binder", "Cannot track buffer '{s}': binding not found", .{binding_name});
            return error.UnknownBinding;
        };

        // Check if we're already tracking this resource
        for (self.tracked_resources.items) |*res| {
            if (std.mem.eql(u8, res.name, binding_name) and
                res.pipeline_id.hash == pipeline_id.hash)
            {
                // Update existing resource
                res.resource = .{ .managed_buffer = managed_buffer };
                res.set = location.set;
                res.binding = location.binding;
                // Don't update last_generation - that happens in updateFrame
                return;
            }
        }

        // Register new tracked resource
        const owned_name = try self.allocator.dupe(u8, binding_name);
        try self.tracked_resources.append(self.allocator, BoundResource{
            .name = owned_name,
            .set = location.set,
            .binding = location.binding,
            .pipeline_id = pipeline_id,
            .resource = .{ .managed_buffer = managed_buffer },
            .last_generation = 0, // Will bind on first updateFrame
        });
    }

    /// Register a managed texture for automatic generation-based tracking
    pub fn registerTextureByName(
        self: *ResourceBinder,
        binding_name: []const u8,
        pipeline_id: PipelineId,
        managed_texture: *const ManagedTexture,
    ) !void {
        // Look up the binding location
        const location = self.lookupBinding(binding_name) orelse {
            log(.ERROR, "resource_binder", "Cannot track texture '{s}': binding not found", .{binding_name});
            return error.UnknownBinding;
        };

        // Check if we're already tracking this resource
        for (self.tracked_resources.items) |*res| {
            if (std.mem.eql(u8, res.name, binding_name) and
                res.pipeline_id.hash == pipeline_id.hash)
            {
                // Update existing resource
                res.resource = .{ .managed_texture = managed_texture };
                res.set = location.set;
                res.binding = location.binding;
                // Don't update last_generation - that happens in updateFrame
                return;
            }
        }

        // Register new tracked resource
        const owned_name = try self.allocator.dupe(u8, binding_name);
        try self.tracked_resources.append(self.allocator, BoundResource{
            .name = owned_name,
            .set = location.set,
            .binding = location.binding,
            .pipeline_id = pipeline_id,
            .resource = .{ .managed_texture = managed_texture },
            .last_generation = 0, // Will bind on first updateFrame
        });

        log(.INFO, "resource_binder", "Registered tracked texture '{s}': gen={}", .{
            binding_name,
            managed_texture.generation,
        });
    }

    /// Register a managed texture array for automatic generation tracking
    fn updateTextureArrayByName(
        self: *ResourceBinder,
        binding_name: []const u8,
        pipeline_id: PipelineId,
        managed_textures: *const ManagedTextureArray,
    ) !void {
        // Look up the binding location
        const location = self.lookupBinding(binding_name) orelse {
            log(.ERROR, "resource_binder", "Cannot track texture array '{s}': binding not found", .{binding_name});
            return error.UnknownBinding;
        };

        // Check if we're already tracking this resource
        for (self.tracked_resources.items) |*res| {
            if (std.mem.eql(u8, res.name, binding_name) and
                res.pipeline_id.hash == pipeline_id.hash)
            {
                // Update existing resource - use offset to generation field
                res.resource = .{ .texture_array = .{
                    .ptr = @ptrCast(@constCast(managed_textures)),
                    .generation_offset = @offsetOf(ManagedTextureArray, "generation"),
                } };
                res.set = location.set;
                res.binding = location.binding;
                return;
            }
        }

        // Register new tracked resource
        const owned_name = try self.allocator.dupe(u8, binding_name);
        try self.tracked_resources.append(self.allocator, BoundResource{
            .name = owned_name,
            .set = location.set,
            .binding = location.binding,
            .pipeline_id = pipeline_id,
            .resource = .{ .texture_array = .{
                .ptr = @ptrCast(@constCast(managed_textures)),
                .generation_offset = @offsetOf(ManagedTextureArray, "generation"),
            } },
            .last_generation = 0, // Will bind on first updateFrame
        });

        log(.INFO, "resource_binder", "Registered tracked texture array '{s}': gen={}", .{
            binding_name,
            managed_textures.generation,
        });
    }

    /// Register a managed TLAS (acceleration structure) for automatic generation tracking
    fn registerAccelerationStructureByName(
        self: *ResourceBinder,
        binding_name: []const u8,
        pipeline_id: PipelineId,
        managed_tlas: *const ManagedTLAS,
    ) !void {
        // Look up the binding location
        const location = self.lookupBinding(binding_name) orelse {
            log(.ERROR, "resource_binder", "Cannot track acceleration structure '{s}': binding not found", .{binding_name});
            return error.UnknownBinding;
        };

        // Check if we're already tracking this resource
        for (self.tracked_resources.items) |*res| {
            if (std.mem.eql(u8, res.name, binding_name) and
                res.pipeline_id.hash == pipeline_id.hash)
            {
                // Update existing resource
                res.resource = .{ .acceleration_structure = .{
                    .ptr = @ptrCast(@constCast(managed_tlas)),
                    .generation_offset = @offsetOf(ManagedTLAS, "generation"),
                } };
                res.set = location.set;
                res.binding = location.binding;
                return;
            }
        }

        // Register new tracked resource
        const owned_name = try self.allocator.dupe(u8, binding_name);
        try self.tracked_resources.append(self.allocator, BoundResource{
            .name = owned_name,
            .set = location.set,
            .binding = location.binding,
            .pipeline_id = pipeline_id,
            .resource = .{ .acceleration_structure = .{
                .ptr = @ptrCast(@constCast(managed_tlas)),
                .generation_offset = @offsetOf(ManagedTLAS, "generation"),
            } },
            .last_generation = 0, // Will bind on first updateFrame
        });

        log(.INFO, "resource_binder", "Registered tracked acceleration structure '{s}': gen={}", .{
            binding_name,
            managed_tlas.generation,
        });
    }

    /// Update descriptor bindings for a specific pipeline and frame
    /// Automatically rebinds any buffers whose VkBuffer handle has changed
    /// AND checks tracked managed buffers for generation changes
    pub fn updateFrame(self: *ResourceBinder, pipeline_id: PipelineId, frame_index: u32) !void {
        // Check all bound storage buffers for this pipeline/frame to see if their handles changed
        var storage_iter = self.bound_storage_buffers.iterator();
        while (storage_iter.next()) |entry| {
            const key = entry.key_ptr.*;
            if (key.pipeline_id.hash != pipeline_id.hash or key.frame_index != frame_index) continue;

            const bound = entry.value_ptr.*;
            const current_handle = bound.buffer.buffer;

            // Check if buffer handle changed (buffer was recreated)
            // If so, rebind it automatically
            const resource = Resource{
                .buffer = .{
                    .buffer = current_handle,
                    .offset = bound.offset,
                    .range = bound.range,
                },
            };

            try self.pipeline_system.bindResource(pipeline_id, key.set, key.binding, resource, frame_index);
        }

        // Check uniform buffers too
        var uniform_iter = self.bound_uniform_buffers.iterator();
        while (uniform_iter.next()) |entry| {
            const key = entry.key_ptr.*;
            if (key.pipeline_id.hash != pipeline_id.hash or key.frame_index != frame_index) continue;

            const bound = entry.value_ptr.*;
            const current_handle = bound.buffer.buffer;

            const resource = Resource{
                .buffer = .{
                    .buffer = current_handle,
                    .offset = bound.offset,
                    .range = bound.range,
                },
            };

            try self.pipeline_system.bindResource(pipeline_id, key.set, key.binding, resource, frame_index);
        }

        // Check tracked resources for generation changes
        for (self.tracked_resources.items) |*res| {
            // Only process resources for this pipeline
            if (res.pipeline_id.hash != pipeline_id.hash) continue;

            // Get current generation
            const current_gen = res.getCurrentGeneration();

            // Skip if generation is 0 (resource not created yet)
            if (current_gen == 0) continue;

            // Check if generation changed
            if (current_gen == res.last_generation) continue;

            // Rebind based on resource type
            switch (res.resource) {
                .managed_buffer => |managed_buffer| {
                    // Look up binding type
                    const location = self.lookupBinding(res.name) orelse {
                        log(.ERROR, "resource_binder", "Tracked resource '{s}' has no registered binding location", .{res.name});
                        continue;
                    };

                    // Rebind for ALL frames
                    for (0..MAX_FRAMES_IN_FLIGHT) |frame_idx| {
                        const bind_frame = @as(u32, @intCast(frame_idx));

                        switch (location.binding_type) {
                            .storage_buffer => {
                                try self.bindStorageBuffer(
                                    res.pipeline_id,
                                    res.set,
                                    res.binding,
                                    @constCast(&managed_buffer.buffer),
                                    0,
                                    vk.WHOLE_SIZE,
                                    bind_frame,
                                );
                            },
                            .uniform_buffer => {
                                try self.bindUniformBuffer(
                                    res.pipeline_id,
                                    res.set,
                                    res.binding,
                                    @constCast(&managed_buffer.buffer),
                                    0,
                                    vk.WHOLE_SIZE,
                                    bind_frame,
                                );
                            },
                            else => {
                                log(.WARN, "resource_binder", "Tracked resource '{s}' has unsupported binding type: {}", .{ res.name, location.binding_type });
                            },
                        }
                    }
                },
                .managed_texture => |managed_texture| {
                    // Get descriptor info from managed texture (need to cast away const for getDescriptorInfo)
                    const descriptor_info = @constCast(&managed_texture.texture).getDescriptorInfo();

                    // Rebind for ALL frames
                    for (0..MAX_FRAMES_IN_FLIGHT) |frame_idx| {
                        const bind_frame = @as(u32, @intCast(frame_idx));

                        try self.bindTexture(
                            res.pipeline_id,
                            res.set,
                            res.binding,
                            descriptor_info.image_view,
                            descriptor_info.sampler,
                            descriptor_info.image_layout,
                            bind_frame,
                        );
                    }

                    log(.INFO, "resource_binder", "Rebound managed texture '{s}' for all frames (generation {} -> {})", .{
                        res.name,
                        res.last_generation,
                        current_gen,
                    });
                },
                .texture_array => |arr| {
                    // Cast back to ManagedTextureArray to access descriptor_infos

                    const managed_textures: *const ManagedTextureArray = @ptrCast(@alignCast(arr.ptr));

                    // Don't rebind if descriptor array is empty
                    if (managed_textures.descriptor_infos.len == 0) {
                        continue;
                    }

                    // Rebind the texture array for ALL frames
                    for (0..MAX_FRAMES_IN_FLIGHT) |frame_idx| {
                        const bind_frame = @as(u32, @intCast(frame_idx));

                        const resource = Resource{
                            .image_array = managed_textures.descriptor_infos,
                        };

                        try self.pipeline_system.bindResource(
                            res.pipeline_id,
                            res.set,
                            res.binding,
                            resource,
                            bind_frame,
                        );
                    }

                    log(.INFO, "resource_binder", "Rebound texture array '{s}' for all frames (generation {} -> {}, {} textures)", .{
                        res.name,
                        res.last_generation,
                        current_gen,
                        managed_textures.descriptor_infos.len,
                    });
                },
                .acceleration_structure => |as| {
                    // Cast back to ManagedTLAS to access acceleration_structure handle
                    const managed_tlas: *const ManagedTLAS = @ptrCast(@alignCast(as.ptr));

                    // Don't rebind if TLAS not created yet
                    if (managed_tlas.acceleration_structure == vk.AccelerationStructureKHR.null_handle) {
                        continue;
                    }

                    // Rebind the acceleration structure for ALL frames
                    for (0..MAX_FRAMES_IN_FLIGHT) |frame_idx| {
                        const bind_frame = @as(u32, @intCast(frame_idx));

                        const resource = Resource{
                            .acceleration_structure = managed_tlas.acceleration_structure,
                        };

                        try self.pipeline_system.bindResource(
                            res.pipeline_id,
                            res.set,
                            res.binding,
                            resource,
                            bind_frame,
                        );
                    }
                },
                .buffer_array => |arr| {
                    // Get buffer infos directly from the ArrayList pointer
                    const buffer_infos = arr.buffer_infos_ptr.items;

                    // Don't rebind if buffer array is empty
                    if (buffer_infos.len == 0) {
                        continue;
                    }

                    log(.INFO, "resource_binder", "Rebinding buffer array '{s}' with {} buffers (generation changed)", .{ res.name, buffer_infos.len });

                    // Rebind the buffer array for ALL frames
                    for (0..MAX_FRAMES_IN_FLIGHT) |frame_idx| {
                        const bind_frame = @as(u32, @intCast(frame_idx));

                        const resource = Resource{
                            .buffer_array = buffer_infos,
                        };

                        try self.pipeline_system.bindResource(
                            res.pipeline_id,
                            res.set,
                            res.binding,
                            resource,
                            bind_frame,
                        );
                    }
                },
                .texture => {
                    // TODO: Implement single texture rebinding
                    log(.WARN, "resource_binder", "Single texture rebinding not yet implemented for '{s}'", .{res.name});
                },
            }

            // Update the last bound generation
            res.last_generation = current_gen;
        }

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

/// Bound acceleration structure information
pub const BoundAccelerationStructure = struct {
    acceleration_structure: vk.AccelerationStructureKHR,
};

/// Unified resource tracking for generation-based change detection
const BoundResource = struct {
    name: []const u8, // Owned by ResourceBinder
    set: u32,
    binding: u32,
    pipeline_id: PipelineId,
    resource: ResourceVariant,
    last_generation: u32,

    const ResourceVariant = union(enum) {
        managed_buffer: *const ManagedBuffer,
        managed_texture: *const ManagedTexture,
        texture: TextureResource,
        texture_array: TextureArrayResource,
        acceleration_structure: AccelerationStructureResource,
        buffer_array: BufferArrayResource,
    };

    const TextureResource = struct {
        ptr: *anyopaque, // Points to texture object with generation field
        generation_offset: usize, // Offset to u32 generation field
    };

    const TextureArrayResource = struct {
        ptr: *anyopaque,
        generation_offset: usize,
    };

    const AccelerationStructureResource = struct {
        ptr: *anyopaque, // Points to ManagedTLAS
        generation_offset: usize, // Offset to u32 generation field
    };

    const BufferArrayResource = struct {
        buffer_infos_ptr: *const std.ArrayList(vk.DescriptorBufferInfo),
        generation_ptr: *const u32,
    };

    /// Get current generation of the resource
    fn getCurrentGeneration(self: *const BoundResource) u32 {
        return switch (self.resource) {
            .managed_buffer => |buf| buf.generation,
            .managed_texture => |tex| tex.generation,
            .texture => |tex| blk: {
                const gen_ptr: *u32 = @ptrFromInt(@intFromPtr(tex.ptr) + tex.generation_offset);
                break :blk gen_ptr.*;
            },
            .texture_array => |arr| blk: {
                const gen_ptr: *u32 = @ptrFromInt(@intFromPtr(arr.ptr) + arr.generation_offset);
                break :blk gen_ptr.*;
            },
            .acceleration_structure => |as| blk: {
                const gen_ptr: *u32 = @ptrFromInt(@intFromPtr(as.ptr) + as.generation_offset);
                break :blk gen_ptr.*;
            },
            .buffer_array => |arr| blk: {
                break :blk arr.generation_ptr.*;
            },
        };
    }
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
