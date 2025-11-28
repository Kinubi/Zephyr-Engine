const std = @import("std");
const vk = @import("vulkan");
pub const zstbi = @import("zstbi");
const GraphicsContext = @import("graphics_context.zig").GraphicsContext;
const Buffer = @import("buffer.zig").Buffer;
const log = @import("../utils/log.zig").log;
const LogLevel = @import("../utils/log.zig").LogLevel;

// TODO(FEATURE): ASYNC TEXTURE COMPRESSION & MIP GENERATION - MEDIUM PRIORITY
// Currently: textures loaded without mipmaps, no compression, synchronous mip gen blocks loading
// Required: Generate mipmaps on worker thread, BC7/BC5/BC4 compression, stream mips progressively
// Files: texture.zig (async mip gen), asset_loader.zig (queue jobs), texture_compressor.zig (new)
// Branch: features/texture-compression

// Global ZSTBI state management
var zstbi_initialized: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var zstbi_init_mutex: std.Thread.Mutex = .{};

/// Safely initialize zstbi once per application
pub fn ensureZstbiInit(allocator: std.mem.Allocator) void {
    if (!zstbi_initialized.load(.acquire)) {
        zstbi_init_mutex.lock();
        defer zstbi_init_mutex.unlock();

        // Double-check pattern
        if (!zstbi_initialized.load(.acquire)) {
            zstbi.init(allocator);
            zstbi_initialized.store(true, .release);
        }
    }
}

/// Safely deinitialize zstbi
pub fn deinitZstbi() void {
    zstbi_init_mutex.lock();
    defer zstbi_init_mutex.unlock();

    if (zstbi_initialized.load(.acquire)) {
        zstbi.deinit();
        zstbi_initialized.store(false, .release);
    }
}

pub const Texture = struct {
    image: vk.Image,
    image_view: vk.ImageView,
    memory: vk.DeviceMemory,
    sampler: vk.Sampler,
    mip_levels: u32,
    extent: vk.Extent3D,
    format: vk.Format,
    descriptor: vk.DescriptorImageInfo,
    gc: *GraphicsContext,
    memory_size: u64 = 0, // Track memory size for proper untracking

    // Cube texture support - optional fields for 6-face cube maps
    is_cube: bool = false,
    /// Individual face views for rendering to cube faces (order: +X, -X, +Y, -Y, +Z, -Z)
    /// Only valid when is_cube = true
    face_views: ?[6]vk.ImageView = null,

    // Cube array texture support for multi-light shadow mapping with multiview
    /// Number of cubes in a cube array (0 = not a cube array)
    cube_count: u32 = 0,
    /// Face array views for multiview rendering - each view covers the same face across all cubes
    /// face_array_views[face] covers layers [face, face+6, face+12, ...] for all cubes
    /// Used with VK_KHR_multiview to render all lights simultaneously
    face_array_views: ?[6]vk.ImageView = null,

    pub fn init(
        gc: *GraphicsContext,
        format: vk.Format,
        extent: vk.Extent3D,
        usage: vk.ImageUsageFlags,
        sample_count: vk.SampleCountFlags,
    ) !Texture {
        var aspect_mask = vk.ImageAspectFlags{ .color_bit = true };
        var image_layout: vk.ImageLayout = undefined;

        // Helper to detect if a depth format has a stencil component
        const formatHasStencil = switch (format) {
            .d32_sfloat_s8_uint, .d24_unorm_s8_uint, .d16_unorm_s8_uint => true,
            else => false,
        };

        // With VK_KHR_synchronization2 + unified image layouts, use GENERAL everywhere
        // This is just as efficient as specialized layouts and eliminates transitions
        if (usage.depth_stencil_attachment_bit) {
            aspect_mask = if (formatHasStencil)
                (vk.ImageAspectFlags{ .depth_bit = true, .stencil_bit = true })
            else
                (vk.ImageAspectFlags{ .depth_bit = true });
        } else {
            aspect_mask = vk.ImageAspectFlags{ .color_bit = true };
        }
        image_layout = vk.ImageLayout.general;
        const image_info = vk.ImageCreateInfo{
            .s_type = vk.StructureType.image_create_info,
            .image_type = .@"2d",
            .format = format,
            .extent = extent,
            .mip_levels = 1,
            .array_layers = 1,
            .samples = sample_count,
            .tiling = vk.ImageTiling.optimal,
            .usage = usage,
            .initial_layout = vk.ImageLayout.undefined,
            .sharing_mode = vk.SharingMode.exclusive,
            .flags = .{},
            .p_next = null,
            .queue_family_index_count = 0,
            .p_queue_family_indices = null,
        };
        var image: vk.Image = undefined;
        var memory: vk.DeviceMemory = undefined;
        try gc.createImageWithInfo(image_info, vk.MemoryPropertyFlags{ .device_local_bit = true }, &image, &memory);

        // Query memory size for tracking
        const mem_reqs = gc.vkd.getImageMemoryRequirements(gc.dev, image);
        const memory_size = mem_reqs.size;

        var view_info = vk.ImageViewCreateInfo{
            .s_type = vk.StructureType.image_view_create_info,
            .view_type = vk.ImageViewType.@"2d",
            .format = format,
            .subresource_range = .{
                .aspect_mask = aspect_mask,
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .image = image,
            .components = .{
                .r = vk.ComponentSwizzle.identity,
                .g = vk.ComponentSwizzle.identity,
                .b = vk.ComponentSwizzle.identity,
                .a = vk.ComponentSwizzle.identity,
            },
            .flags = .{},
            .p_next = null,
        };

        // Zig Vulkan bindings: createImageView returns the image view directly (not via out param)
        const image_view = gc.vkd.createImageView(gc.dev, &view_info, null) catch return error.FailedToCreateImageView;
        try gc.transitionImageLayoutSingleTime(
            image,
            vk.ImageLayout.undefined,
            image_layout,
            .{
                .aspect_mask = aspect_mask,
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        );
        // Sampler
        var sampler_info = vk.SamplerCreateInfo{
            .s_type = vk.StructureType.sampler_create_info,
            .mag_filter = vk.Filter.linear,
            .min_filter = vk.Filter.linear,
            .mipmap_mode = vk.SamplerMipmapMode.linear,
            .address_mode_u = vk.SamplerAddressMode.clamp_to_border,
            .address_mode_v = vk.SamplerAddressMode.clamp_to_border,
            .address_mode_w = vk.SamplerAddressMode.clamp_to_border,
            .mip_lod_bias = 0.0,
            .max_anisotropy = 1.0,
            .min_lod = 0.0,
            .max_lod = 1.0,
            .border_color = vk.BorderColor.float_opaque_black,
            .flags = .{},
            .p_next = null,
            .unnormalized_coordinates = .false,
            .compare_enable = .false,
            .compare_op = vk.CompareOp.always,
            .anisotropy_enable = .false,
        };
        const sampler = gc.vkd.createSampler(gc.dev, &sampler_info, null) catch return error.FailedToCreateSampler;
        return Texture{
            .image = image,
            .image_view = image_view,
            .memory = memory,
            .sampler = sampler,
            .mip_levels = 1,
            .extent = extent,
            .format = format,
            .descriptor = vk.DescriptorImageInfo{
                .sampler = sampler,
                .image_view = image_view,
                .image_layout = image_layout,
            },
            .gc = gc,
            .memory_size = memory_size,
        };
    }

    /// Create a texture and transition initial layout using a dedicated single-time command buffer,
    /// regardless of the calling thread. Useful during early startup when secondary buffers are unsafe.
    pub fn initSingleTime(
        gc: *GraphicsContext,
        format: vk.Format,
        extent: vk.Extent3D,
        usage: vk.ImageUsageFlags,
        sample_count: vk.SampleCountFlags,
    ) !Texture {
        var aspect_mask = vk.ImageAspectFlags{ .color_bit = true };
        var image_layout: vk.ImageLayout = undefined;

        const formatHasStencil = switch (format) {
            .d32_sfloat_s8_uint, .d24_unorm_s8_uint, .d16_unorm_s8_uint => true,
            else => false,
        };

        // With VK_KHR_synchronization2 + unified image layouts, use GENERAL everywhere
        // This is just as efficient as specialized layouts and eliminates transitions
        if (usage.depth_stencil_attachment_bit) {
            aspect_mask = if (formatHasStencil)
                (vk.ImageAspectFlags{ .depth_bit = true, .stencil_bit = true })
            else
                (vk.ImageAspectFlags{ .depth_bit = true });
        } else {
            aspect_mask = vk.ImageAspectFlags{ .color_bit = true };
        }
        image_layout = vk.ImageLayout.general;

        const image_info = vk.ImageCreateInfo{
            .s_type = vk.StructureType.image_create_info,
            .image_type = .@"2d",
            .format = format,
            .extent = extent,
            .mip_levels = 1,
            .array_layers = 1,
            .samples = sample_count,
            .tiling = vk.ImageTiling.optimal,
            .usage = usage,
            .initial_layout = vk.ImageLayout.undefined,
            .sharing_mode = vk.SharingMode.exclusive,
            .flags = .{},
            .p_next = null,
            .queue_family_index_count = 0,
            .p_queue_family_indices = null,
        };

        var image: vk.Image = undefined;
        var memory: vk.DeviceMemory = undefined;
        try gc.createImageWithInfo(image_info, vk.MemoryPropertyFlags{ .device_local_bit = true }, &image, &memory);

        // Query memory size for tracking
        const mem_reqs = gc.vkd.getImageMemoryRequirements(gc.dev, image);
        const memory_size = mem_reqs.size;

        var view_info = vk.ImageViewCreateInfo{
            .s_type = vk.StructureType.image_view_create_info,
            .view_type = vk.ImageViewType.@"2d",
            .format = format,
            .subresource_range = .{
                .aspect_mask = aspect_mask,
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .image = image,
            .components = .{
                .r = vk.ComponentSwizzle.identity,
                .g = vk.ComponentSwizzle.identity,
                .b = vk.ComponentSwizzle.identity,
                .a = vk.ComponentSwizzle.identity,
            },
            .flags = .{},
            .p_next = null,
        };

        const image_view = gc.vkd.createImageView(gc.dev, &view_info, null) catch return error.FailedToCreateImageView;

        // Perform initial layout transition using a temporary command pool/buffer.
        // This avoids relying on gc.command_pool which may not be created yet during early startup.
        const temp_pool = try gc.vkd.createCommandPool(gc.dev, &vk.CommandPoolCreateInfo{
            .flags = .{ .reset_command_buffer_bit = true, .transient_bit = true },
            .queue_family_index = gc.graphics_queue.family,
        }, null);
        defer gc.vkd.destroyCommandPool(gc.dev, temp_pool, null);

        var alloc_info = vk.CommandBufferAllocateInfo{
            .s_type = vk.StructureType.command_buffer_allocate_info,
            .command_pool = temp_pool,
            .level = .primary,
            .command_buffer_count = 1,
        };
        var cmd: vk.CommandBuffer = undefined;
        try gc.vkd.allocateCommandBuffers(gc.dev, &alloc_info, @ptrCast(&cmd));
        defer gc.vkd.freeCommandBuffers(gc.dev, temp_pool, 1, @ptrCast(&cmd));

        var begin_info = vk.CommandBufferBeginInfo{
            .s_type = vk.StructureType.command_buffer_begin_info,
            .flags = .{ .one_time_submit_bit = true },
            .p_inheritance_info = null,
        };
        try gc.vkd.beginCommandBuffer(cmd, &begin_info);

        gc.transitionImageLayout(
            cmd,
            image,
            vk.ImageLayout.undefined,
            image_layout,
            .{
                .aspect_mask = aspect_mask,
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        );

        try gc.vkd.endCommandBuffer(cmd);

        var submit_info = vk.SubmitInfo{
            .s_type = vk.StructureType.submit_info,
            .wait_semaphore_count = 0,
            .p_wait_semaphores = null,
            .p_wait_dst_stage_mask = null,
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast(&cmd),
            .signal_semaphore_count = 0,
            .p_signal_semaphores = null,
        };

        // Synchronize queue access as required by Vulkan spec
        gc.queue_mutex.lock();
        defer gc.queue_mutex.unlock();
        try gc.vkd.queueSubmit(gc.graphics_queue.handle, 1, @ptrCast(&submit_info), .null_handle);
        try gc.vkd.queueWaitIdle(gc.graphics_queue.handle);

        // Sampler
        var sampler_info = vk.SamplerCreateInfo{
            .s_type = vk.StructureType.sampler_create_info,
            .mag_filter = vk.Filter.linear,
            .min_filter = vk.Filter.linear,
            .mipmap_mode = vk.SamplerMipmapMode.linear,
            .address_mode_u = vk.SamplerAddressMode.clamp_to_border,
            .address_mode_v = vk.SamplerAddressMode.clamp_to_border,
            .address_mode_w = vk.SamplerAddressMode.clamp_to_border,
            .mip_lod_bias = 0.0,
            .max_anisotropy = 1.0,
            .min_lod = 0.0,
            .max_lod = 1.0,
            .border_color = vk.BorderColor.float_opaque_black,
            .flags = .{},
            .p_next = null,
            .unnormalized_coordinates = .false,
            .compare_enable = .false,
            .compare_op = vk.CompareOp.always,
            .anisotropy_enable = .false,
        };
        const sampler = gc.vkd.createSampler(gc.dev, &sampler_info, null) catch return error.FailedToCreateSampler;

        return Texture{
            .image = image,
            .image_view = image_view,
            .memory = memory,
            .sampler = sampler,
            .mip_levels = 1,
            .extent = extent,
            .format = format,
            .descriptor = vk.DescriptorImageInfo{
                .sampler = sampler,
                .image_view = image_view,
                .image_layout = image_layout,
            },
            .gc = gc,
            .memory_size = memory_size,
        };
    }

    pub const ImageFormat = enum {
        rgba8,
        rgb8,
        gray8,
    };

    pub fn initFromFile(
        gc: *GraphicsContext,
        allocator: std.mem.Allocator,
        filepath: []const u8,
        image_format: ImageFormat,
    ) !Texture {
        // Convert filepath to null-terminated string for zstbi
        const filepath_z = try std.mem.concatWithSentinel(allocator, u8, @ptrCast(&filepath), 0);
        defer allocator.free(filepath_z);

        // Ensure zstbi is initialized (thread-safe, once per application)
        ensureZstbiInit(allocator);

        var image = try zstbi.Image.loadFromFile(filepath_z, switch (image_format) {
            .rgba8 => 4,
            .rgb8 => 3,
            .gray8 => 1,
        });
        defer image.deinit();

        const mip_levels: u32 = std.math.log2_int(u32, @max(image.width, image.height)) + 1;
        const extent = vk.Extent3D{
            .width = image.width,
            .height = image.height,
            .depth = 1,
        };
        const vk_format = switch (image_format) {
            .rgba8 => vk.Format.r8g8b8a8_srgb,
            .rgb8 => vk.Format.r8g8b8_srgb,
            .gray8 => vk.Format.r8_srgb,
        };
        // 1. Create staging buffer and upload pixels using Buffer abstraction
        const pixel_count = image.width * image.height * image.num_components;
        const buffer_size = pixel_count * image.bytes_per_component;
        const on_main_thread = std.Thread.getCurrentId() == gc.main_thread_id;
        var staging_buffer = try Buffer.init(
            gc,
            buffer_size,
            1,
            .{ .transfer_src_bit = true },
            .{ .host_visible_bit = true, .host_coherent_bit = true },
        );
        var staging_cleanup_needed = true;
        defer {
            if (staging_cleanup_needed) staging_buffer.deinit();
        }

        try staging_buffer.map(buffer_size, 0);
        staging_buffer.writeToBuffer(image.data, buffer_size, 0);
        staging_buffer.unmap();

        // 2. Create image
        const image_info = vk.ImageCreateInfo{
            .s_type = vk.StructureType.image_create_info,
            .image_type = vk.ImageType.@"2d",
            .format = vk_format,
            .extent = extent,
            .mip_levels = mip_levels,
            .array_layers = 1,
            .samples = vk.SampleCountFlags{ .@"1_bit" = true },
            .tiling = vk.ImageTiling.optimal,
            .usage = vk.ImageUsageFlags{
                .transfer_src_bit = true,
                .transfer_dst_bit = true,
                .sampled_bit = true,
            },
            .initial_layout = vk.ImageLayout.undefined,
            .sharing_mode = vk.SharingMode.exclusive,
            .flags = .{},
            .p_next = null,
            .queue_family_index_count = 0,
            .p_queue_family_indices = null,
        };
        var image_handle: vk.Image = undefined;
        var memory: vk.DeviceMemory = undefined;
        try gc.createImageWithInfo(image_info, vk.MemoryPropertyFlags{ .device_local_bit = true }, &image_handle, &memory);
        // 3. Transition image to TRANSFER_DST_OPTIMAL
        try gc.transitionImageLayoutSingleTime(
            image_handle,
            vk.ImageLayout.undefined,
            vk.ImageLayout.transfer_dst_optimal,
            .{
                .aspect_mask = vk.ImageAspectFlags{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = mip_levels,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        );

        // 4. Copy buffer to image
        try gc.copyBufferToImageSingleTime(
            staging_buffer,
            image_handle,
            image.width,
            image.height,
        );
        staging_cleanup_needed = on_main_thread;
        if (!on_main_thread) {
            staging_buffer.buffer = vk.Buffer.null_handle;
            staging_buffer.memory = vk.DeviceMemory.null_handle;
            staging_buffer.descriptor_info.buffer = vk.Buffer.null_handle;
        }

        // 5. Generate mipmaps
        try gc.generateMipmapsSingleTime(
            image_handle,
            image.width,
            image.height,
            mip_levels,
        );

        // 6. Transition image to SHADER_READ_ONLY_OPTIMAL
        // (Handled by generateMipmapsSingleTime for all mips)
        // Create image view
        var view_info = vk.ImageViewCreateInfo{
            .s_type = vk.StructureType.image_view_create_info,
            .view_type = vk.ImageViewType.@"2d",
            .format = vk_format,
            .subresource_range = .{
                .aspect_mask = vk.ImageAspectFlags{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = mip_levels,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .image = image_handle,
            .components = .{
                .r = vk.ComponentSwizzle.identity,
                .g = vk.ComponentSwizzle.identity,
                .b = vk.ComponentSwizzle.identity,
                .a = vk.ComponentSwizzle.identity,
            },
            .flags = .{},
            .p_next = null,
        };

        // Zig Vulkan bindings: createImageView returns the image view directly (not via out param)
        const image_view = gc.vkd.createImageView(gc.dev, &view_info, null) catch return error.FailedToCreateImageView;
        // Create sampler
        var sampler_info = vk.SamplerCreateInfo{
            .s_type = vk.StructureType.sampler_create_info,
            .mag_filter = vk.Filter.linear,
            .min_filter = vk.Filter.linear,
            .mipmap_mode = vk.SamplerMipmapMode.linear,
            .address_mode_u = vk.SamplerAddressMode.repeat,
            .address_mode_v = vk.SamplerAddressMode.repeat,
            .address_mode_w = vk.SamplerAddressMode.repeat,
            .mip_lod_bias = 0.0,
            .max_anisotropy = 16.0,
            .min_lod = 0.0,
            .max_lod = @floatFromInt(mip_levels),
            .border_color = vk.BorderColor.int_opaque_black,
            .flags = .{},
            .p_next = null,
            .unnormalized_coordinates = .false,
            .compare_enable = .false,
            .compare_op = vk.CompareOp.always,
            .anisotropy_enable = .false,
        };
        const sampler = gc.vkd.createSampler(gc.dev, &sampler_info, null) catch return error.FailedToCreateSampler;
        return Texture{
            .image = image_handle,
            .image_view = image_view,
            .memory = memory,
            .sampler = sampler,
            .mip_levels = mip_levels,
            .extent = extent,
            .format = vk_format,
            .descriptor = vk.DescriptorImageInfo{
                .sampler = sampler,
                .image_view = image_view,
                .image_layout = vk.ImageLayout.general,
            },
            .gc = gc,
        };
    }

    /// Load an HDR environment map from file (equirectangular format)
    /// Returns a texture with R32G32B32A32_SFLOAT format
    /// Uses ONLY synchronous single-time commands to ensure texture is ready immediately
    pub fn initHdrFromFile(
        gc: *GraphicsContext,
        allocator: std.mem.Allocator,
        filepath: []const u8,
    ) !Texture {
        // Convert filepath to null-terminated string for zstbi
        const filepath_z = try std.mem.concatWithSentinel(allocator, u8, @ptrCast(&filepath), 0);
        defer allocator.free(filepath_z);

        // Ensure zstbi is initialized (thread-safe, once per application)
        ensureZstbiInit(allocator);

        // Check if it's actually HDR
        if (!zstbi.isHdr(filepath_z)) {
            log(.WARN, "texture", "File is not HDR format: {s}, loading as LDR", .{filepath});
            return initFromFile(gc, allocator, filepath, .rgba8);
        }

        // Load HDR image (zstbi auto-detects and loads as float)
        var image = try zstbi.Image.loadFromFile(filepath_z, 4); // Force 4 components (RGBA)
        defer image.deinit();

        if (!image.is_hdr) {
            log(.WARN, "texture", "Expected HDR but got LDR: {s}", .{filepath});
        }

        log(.INFO, "texture", "HDR image: {}x{}, {} components, {} bytes/component, is_hdr={}", .{
            image.width, image.height, image.num_components, image.bytes_per_component, image.is_hdr,
        });

        const mip_levels: u32 = 1; // HDR env maps typically don't need mipmaps for skybox
        const extent = vk.Extent3D{
            .width = image.width,
            .height = image.height,
            .depth = 1,
        };

        // Choose format based on actual bytes per component from zstbi
        // zstbi returns HDR as 16-bit half floats (2 bytes) or 32-bit floats (4 bytes)
        const vk_format = if (image.bytes_per_component == 4)
            vk.Format.r32g32b32a32_sfloat
        else
            vk.Format.r16g16b16a16_sfloat;

        // Calculate buffer size using actual bytes per component from image
        const buffer_size = image.width * image.height * image.num_components * image.bytes_per_component;

        // Create staging buffer
        var staging_buffer = try Buffer.init(
            gc,
            buffer_size,
            1,
            .{ .transfer_src_bit = true },
            .{ .host_visible_bit = true, .host_coherent_bit = true },
        );
        defer staging_buffer.deinit();

        try staging_buffer.map(buffer_size, 0);
        staging_buffer.writeToBuffer(image.data, buffer_size, 0);
        staging_buffer.unmap();

        // Create image
        const image_info = vk.ImageCreateInfo{
            .s_type = vk.StructureType.image_create_info,
            .image_type = vk.ImageType.@"2d",
            .format = vk_format,
            .extent = extent,
            .mip_levels = mip_levels,
            .array_layers = 1,
            .samples = vk.SampleCountFlags{ .@"1_bit" = true },
            .tiling = vk.ImageTiling.optimal,
            .usage = vk.ImageUsageFlags{
                .transfer_dst_bit = true,
                .sampled_bit = true,
            },
            .initial_layout = vk.ImageLayout.undefined,
            .sharing_mode = vk.SharingMode.exclusive,
            .flags = .{},
            .p_next = null,
            .queue_family_index_count = 0,
            .p_queue_family_indices = null,
        };

        var image_handle: vk.Image = undefined;
        var memory: vk.DeviceMemory = undefined;
        try gc.createImageWithInfo(image_info, vk.MemoryPropertyFlags{ .device_local_bit = true }, &image_handle, &memory);

        // Use synchronous single-time commands for all operations
        // This ensures the texture is fully ready before returning, regardless of calling thread

        // 1. Transition to transfer dst
        const transition1_cmd = try gc.beginSingleTimeCommands();
        gc.transitionImageLayout(
            transition1_cmd,
            image_handle,
            vk.ImageLayout.undefined,
            vk.ImageLayout.transfer_dst_optimal,
            .{
                .aspect_mask = vk.ImageAspectFlags{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = mip_levels,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        );
        try gc.endSingleTimeCommands(transition1_cmd);

        // 2. Copy buffer to image
        const copy_cmd = try gc.beginSingleTimeCommands();
        const region = vk.BufferImageCopy{
            .buffer_offset = 0,
            .buffer_row_length = 0,
            .buffer_image_height = 0,
            .image_subresource = .{
                .aspect_mask = vk.ImageAspectFlags{ .color_bit = true },
                .mip_level = 0,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .image_offset = .{ .x = 0, .y = 0, .z = 0 },
            .image_extent = .{ .width = image.width, .height = image.height, .depth = 1 },
        };
        gc.vkd.cmdCopyBufferToImage(
            copy_cmd,
            staging_buffer.buffer,
            image_handle,
            vk.ImageLayout.transfer_dst_optimal,
            1,
            @ptrCast(&region),
        );
        try gc.endSingleTimeCommands(copy_cmd);

        // 3. Transition to general layout (we use GENERAL everywhere for synchronization2)
        const transition2_cmd = try gc.beginSingleTimeCommands();
        gc.transitionImageLayout(
            transition2_cmd,
            image_handle,
            vk.ImageLayout.transfer_dst_optimal,
            vk.ImageLayout.general,
            .{
                .aspect_mask = vk.ImageAspectFlags{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = mip_levels,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        );
        try gc.endSingleTimeCommands(transition2_cmd);

        // Create image view
        const view_info = vk.ImageViewCreateInfo{
            .s_type = vk.StructureType.image_view_create_info,
            .view_type = vk.ImageViewType.@"2d",
            .format = vk_format,
            .subresource_range = .{
                .aspect_mask = vk.ImageAspectFlags{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = mip_levels,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .image = image_handle,
            .components = .{
                .r = vk.ComponentSwizzle.identity,
                .g = vk.ComponentSwizzle.identity,
                .b = vk.ComponentSwizzle.identity,
                .a = vk.ComponentSwizzle.identity,
            },
            .flags = .{},
            .p_next = null,
        };

        const image_view = gc.vkd.createImageView(gc.dev, &view_info, null) catch return error.FailedToCreateImageView;

        // Create sampler with clamp-to-edge for env maps
        // Enable anisotropic filtering for sharper quality
        const sampler_info = vk.SamplerCreateInfo{
            .s_type = vk.StructureType.sampler_create_info,
            .mag_filter = vk.Filter.linear,
            .min_filter = vk.Filter.linear,
            .mipmap_mode = vk.SamplerMipmapMode.linear,
            .address_mode_u = vk.SamplerAddressMode.clamp_to_edge,
            .address_mode_v = vk.SamplerAddressMode.clamp_to_edge,
            .address_mode_w = vk.SamplerAddressMode.clamp_to_edge,
            .mip_lod_bias = 0.0,
            .max_anisotropy = 16.0,
            .min_lod = 0.0,
            .max_lod = @floatFromInt(mip_levels),
            .border_color = vk.BorderColor.float_opaque_black,
            .flags = .{},
            .p_next = null,
            .unnormalized_coordinates = .false,
            .compare_enable = .false,
            .compare_op = vk.CompareOp.always,
            .anisotropy_enable = .true,
        };

        const sampler = gc.vkd.createSampler(gc.dev, &sampler_info, null) catch return error.FailedToCreateSampler;

        log(.INFO, "texture", "Loaded HDR environment map: {s} ({}x{})", .{ filepath, image.width, image.height });

        return Texture{
            .image = image_handle,
            .image_view = image_view,
            .memory = memory,
            .sampler = sampler,
            .mip_levels = mip_levels,
            .extent = extent,
            .format = vk_format,
            .descriptor = vk.DescriptorImageInfo{
                .sampler = sampler,
                .image_view = image_view,
                .image_layout = vk.ImageLayout.general,
            },
            .gc = gc,
        };
    }

    pub fn initFromMemory(
        gc: *GraphicsContext,
        allocator: std.mem.Allocator,
        img_data: []const u8,
        image_format: ImageFormat,
    ) !Texture {
        // // Convert filepath to null-terminated string for zstbi
        // const filepath_z = try std.mem.concatWithSentinel(allocator, u8, @ptrCast(&filepath), 0);
        // defer allocator.free(filepath_z);

        // Ensure zstbi is initialized (thread-safe, once per application)
        ensureZstbiInit(allocator);

        var image = try zstbi.Image.loadFromMemory(img_data, switch (image_format) {
            .rgba8 => 4,
            .rgb8 => 3,
            .gray8 => 1,
        });
        defer image.deinit();

        const mip_levels: u32 = std.math.log2_int(u32, @max(image.width, image.height)) + 1;
        const extent = vk.Extent3D{
            .width = image.width,
            .height = image.height,
            .depth = 1,
        };
        const vk_format = switch (image_format) {
            .rgba8 => vk.Format.r8g8b8a8_srgb,
            .rgb8 => vk.Format.r8g8b8_srgb,
            .gray8 => vk.Format.r8_srgb,
        };
        // 1. Create staging buffer and upload pixels using Buffer abstraction
        const pixel_count = image.width * image.height * image.num_components;
        const buffer_size = pixel_count * image.bytes_per_component;
        const on_main_thread = std.Thread.getCurrentId() == gc.main_thread_id;
        var staging_buffer = try Buffer.init(
            gc,
            buffer_size,
            1,
            .{ .transfer_src_bit = true },
            .{ .host_visible_bit = true, .host_coherent_bit = true },
        );
        var staging_cleanup_needed = true;
        defer {
            if (staging_cleanup_needed) staging_buffer.deinit();
        }

        try staging_buffer.map(buffer_size, 0);
        staging_buffer.writeToBuffer(image.data, buffer_size, 0);
        staging_buffer.unmap();

        // 2. Create image
        const image_info = vk.ImageCreateInfo{
            .s_type = vk.StructureType.image_create_info,
            .image_type = vk.ImageType.@"2d",
            .format = vk_format,
            .extent = extent,
            .mip_levels = mip_levels,
            .array_layers = 1,
            .samples = vk.SampleCountFlags{ .@"1_bit" = true },
            .tiling = vk.ImageTiling.optimal,
            .usage = vk.ImageUsageFlags{
                .transfer_src_bit = true,
                .transfer_dst_bit = true,
                .sampled_bit = true,
            },
            .initial_layout = vk.ImageLayout.undefined,
            .sharing_mode = vk.SharingMode.exclusive,
            .flags = .{},
            .p_next = null,
            .queue_family_index_count = 0,
            .p_queue_family_indices = null,
        };
        var image_handle: vk.Image = undefined;
        var memory: vk.DeviceMemory = undefined;
        try gc.createImageWithInfo(image_info, vk.MemoryPropertyFlags{ .device_local_bit = true }, &image_handle, &memory);
        // 3. Transition image to TRANSFER_DST_OPTIMAL
        try gc.transitionImageLayoutSingleTime(
            image_handle,
            vk.ImageLayout.undefined,
            vk.ImageLayout.transfer_dst_optimal,
            .{
                .aspect_mask = vk.ImageAspectFlags{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = mip_levels,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        );

        // 4. Copy buffer to image
        try gc.copyBufferToImageSingleTime(
            staging_buffer,
            image_handle,
            image.width,
            image.height,
        );
        staging_cleanup_needed = on_main_thread;
        if (!on_main_thread) {
            staging_buffer.buffer = vk.Buffer.null_handle;
            staging_buffer.memory = vk.DeviceMemory.null_handle;
            staging_buffer.descriptor_info.buffer = vk.Buffer.null_handle;
        }

        // 5. Generate mipmaps
        try gc.generateMipmapsSingleTime(
            image_handle,
            image.width,
            image.height,
            mip_levels,
        );

        // 6. Transition image to SHADER_READ_ONLY_OPTIMAL
        // (Handled by generateMipmapsSingleTime for all mips)
        // Create image view
        var view_info = vk.ImageViewCreateInfo{
            .s_type = vk.StructureType.image_view_create_info,
            .view_type = vk.ImageViewType.@"2d",
            .format = vk_format,
            .subresource_range = .{
                .aspect_mask = vk.ImageAspectFlags{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = mip_levels,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .image = image_handle,
            .components = .{
                .r = vk.ComponentSwizzle.identity,
                .g = vk.ComponentSwizzle.identity,
                .b = vk.ComponentSwizzle.identity,
                .a = vk.ComponentSwizzle.identity,
            },
            .flags = .{},
            .p_next = null,
        };

        // Zig Vulkan bindings: createImageView returns the image view directly (not via out param)
        const image_view = gc.vkd.createImageView(gc.dev, &view_info, null) catch return error.FailedToCreateImageView;
        // Create sampler
        var sampler_info = vk.SamplerCreateInfo{
            .s_type = vk.StructureType.sampler_create_info,
            .mag_filter = vk.Filter.linear,
            .min_filter = vk.Filter.linear,
            .mipmap_mode = vk.SamplerMipmapMode.linear,
            .address_mode_u = vk.SamplerAddressMode.repeat,
            .address_mode_v = vk.SamplerAddressMode.repeat,
            .address_mode_w = vk.SamplerAddressMode.repeat,
            .mip_lod_bias = 0.0,
            .max_anisotropy = 16.0,
            .min_lod = 0.0,
            .max_lod = @floatFromInt(mip_levels),
            .border_color = vk.BorderColor.int_opaque_black,
            .flags = .{},
            .p_next = null,
            .unnormalized_coordinates = .false,
            .compare_enable = .false,
            .compare_op = vk.CompareOp.always,
            .anisotropy_enable = .false,
        };
        const sampler = gc.vkd.createSampler(gc.dev, &sampler_info, null) catch return error.FailedToCreateSampler;
        return Texture{
            .image = image_handle,
            .image_view = image_view,
            .memory = memory,
            .sampler = sampler,
            .mip_levels = mip_levels,
            .extent = extent,
            .format = vk_format,
            .descriptor = vk.DescriptorImageInfo{
                .sampler = sampler,
                .image_view = image_view,
                .image_layout = vk.ImageLayout.general,
            },
            .gc = gc,
        };
    }

    pub fn transitionImageLayout(
        self: *Texture,
        cmd_buf: vk.CommandBuffer,
        old_layout: vk.ImageLayout,
        new_layout: vk.ImageLayout,
        subresource_range: vk.ImageSubresourceRange,
    ) !void {
        self.gc.transitionImageLayout(
            cmd_buf,
            self.image,
            old_layout,
            new_layout,
            subresource_range,
        );
        // Update descriptor's image_layout after transition
        self.descriptor.image_layout = new_layout;
    }

    pub fn getDescriptorInfo(self: *Texture) vk.DescriptorImageInfo {
        return self.descriptor;
    }

    /// Load texture from raw pixel data using ONLY single-time commands (synchronous)
    /// Suitable for UI textures that need immediate availability (e.g., ImGui)
    /// Transitions: undefined -> transfer_dst -> shader_read_only
    pub fn loadFromMemorySingle(
        gc: *GraphicsContext,
        pixels: []const u8,
        width: u32,
        height: u32,
        format: vk.Format,
    ) !Texture {
        const extent = vk.Extent3D{
            .width = width,
            .height = height,
            .depth = 1,
        };

        // Create the texture image
        var texture = try Texture.init(
            gc,
            format,
            extent,
            .{ .transfer_dst_bit = true, .sampled_bit = true },
            .{ .@"1_bit" = true },
        );
        errdefer texture.deinit();

        // Transition from undefined to transfer_dst_optimal
        const transition1_cmd = try gc.beginSingleTimeCommands();
        gc.transitionImageLayout(
            transition1_cmd,
            texture.image,
            .undefined,
            .transfer_dst_optimal,
            .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        );
        try gc.endSingleTimeCommands(transition1_cmd);

        // Upload pixel data via staging buffer
        const buffer_size = pixels.len;
        var staging_buffer = try Buffer.init(
            gc,
            buffer_size,
            1,
            .{ .transfer_src_bit = true },
            .{ .host_visible_bit = true, .host_coherent_bit = true },
        );
        defer staging_buffer.deinit();

        try staging_buffer.map(buffer_size, 0);
        staging_buffer.writeToBuffer(pixels, buffer_size, 0);
        staging_buffer.unmap();

        // Copy buffer to image
        const copy_cmd = try gc.beginSingleTimeCommands();
        const region = vk.BufferImageCopy{
            .buffer_offset = 0,
            .buffer_row_length = 0,
            .buffer_image_height = 0,
            .image_subresource = .{
                .aspect_mask = .{ .color_bit = true },
                .mip_level = 0,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .image_offset = .{ .x = 0, .y = 0, .z = 0 },
            .image_extent = .{ .width = width, .height = height, .depth = 1 },
        };
        gc.vkd.cmdCopyBufferToImage(
            copy_cmd,
            staging_buffer.buffer,
            texture.image,
            .transfer_dst_optimal,
            1,
            @ptrCast(&region),
        );
        try gc.endSingleTimeCommands(copy_cmd);

        // Transition to shader_read_only_optimal
        const transition2_cmd = try gc.beginSingleTimeCommands();
        gc.transitionImageLayout(
            transition2_cmd,
            texture.image,
            .transfer_dst_optimal,
            .general,
            .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        );
        try gc.endSingleTimeCommands(transition2_cmd);

        // Update descriptor layout
        texture.descriptor.image_layout = .general;

        return texture;
    }

    /// Load texture from file using ONLY single-time commands (synchronous)
    /// Suitable for UI textures that need immediate availability (e.g., ImGui)
    /// Automatically decodes image to RGBA8 format
    pub fn loadFromFileSingle(
        gc: *GraphicsContext,
        allocator: std.mem.Allocator,
        filepath: []const u8,
    ) !Texture {
        // Ensure zstbi is initialized
        ensureZstbiInit(allocator);

        // Load and decode image file
        const file_data = try std.fs.cwd().readFileAlloc(allocator, filepath, 10 * 1024 * 1024); // 10MB max
        defer allocator.free(file_data);

        var image = try zstbi.Image.loadFromMemory(file_data, 4); // 4 channels = RGBA
        defer image.deinit();

        const pixel_data = image.data[0 .. image.width * image.height * 4];

        return loadFromMemorySingle(
            gc,
            pixel_data,
            image.width,
            image.height,
            .r8g8b8a8_srgb,
        );
    }

    pub fn deinit(self: *Texture) void {
        // Untrack memory before destroying using image handle as unique identifier
        if (self.gc.memory_tracker) |tracker| {
            if (self.memory_size > 0) {
                var buf: [32]u8 = undefined;
                const key = std.fmt.bufPrint(&buf, "texture_{x}", .{@intFromEnum(self.image)}) catch "texture_unknown";
                tracker.untrackAllocation(key);
            }
        }

        // Destroy face views if this is a cube texture
        if (self.face_views) |views| {
            for (views) |view| {
                self.gc.vkd.destroyImageView(self.gc.dev, view, null);
            }
        }

        // Destroy face array views if this is a cube array texture (for multiview)
        if (self.face_array_views) |views| {
            for (views) |view| {
                self.gc.vkd.destroyImageView(self.gc.dev, view, null);
            }
        }

        // Destroy Vulkan resources in reverse order of creation
        self.gc.vkd.destroySampler(self.gc.dev, self.sampler, null);
        self.gc.vkd.destroyImageView(self.gc.dev, self.image_view, null);
        self.gc.vkd.destroyImage(self.gc.dev, self.image, null);
        self.gc.vkd.freeMemory(self.gc.dev, self.memory, null);
    }

    /// Get a specific face view for rendering (only valid for cube textures)
    pub fn getFaceView(self: *const Texture, face: u32) ?vk.ImageView {
        if (self.face_views) |views| {
            return views[face];
        }
        return null;
    }

    /// Get a face array view for multiview rendering (only valid for cube array textures)
    /// Returns a 2D_ARRAY view covering the same face across all cubes
    pub fn getFaceArrayView(self: *const Texture, face: u32) ?vk.ImageView {
        if (self.face_array_views) |views| {
            return views[face];
        }
        return null;
    }

    /// Initialize a cube depth texture for shadow mapping
    /// Creates a 6-layer cube-compatible image with depth format
    pub fn initCubeDepth(
        gc: *GraphicsContext,
        size: u32,
        format: vk.Format,
        compare_enable: bool,
        compare_op: vk.CompareOp,
    ) !Texture {
        const extent = vk.Extent3D{ .width = size, .height = size, .depth = 1 };

        // Create cube-compatible image with 6 array layers
        const image_info = vk.ImageCreateInfo{
            .s_type = vk.StructureType.image_create_info,
            .image_type = .@"2d",
            .format = format,
            .extent = extent,
            .mip_levels = 1,
            .array_layers = 6,
            .samples = .{ .@"1_bit" = true },
            .tiling = vk.ImageTiling.optimal,
            .usage = .{ .depth_stencil_attachment_bit = true, .sampled_bit = true },
            .initial_layout = vk.ImageLayout.undefined,
            .sharing_mode = vk.SharingMode.exclusive,
            .flags = .{ .cube_compatible_bit = true },
            .p_next = null,
            .queue_family_index_count = 0,
            .p_queue_family_indices = null,
        };

        var image: vk.Image = undefined;
        var memory: vk.DeviceMemory = undefined;
        try gc.createImageWithInfo(image_info, vk.MemoryPropertyFlags{ .device_local_bit = true }, &image, &memory);

        // Query memory size for tracking
        const mem_reqs = gc.vkd.getImageMemoryRequirements(gc.dev, image);
        const memory_size = mem_reqs.size;

        const aspect_mask = vk.ImageAspectFlags{ .depth_bit = true };

        // Create cube image view for sampling (all 6 layers as cube)
        const cube_view_info = vk.ImageViewCreateInfo{
            .s_type = vk.StructureType.image_view_create_info,
            .view_type = .cube,
            .format = format,
            .subresource_range = .{
                .aspect_mask = aspect_mask,
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 6,
            },
            .image = image,
            .components = .{
                .r = vk.ComponentSwizzle.identity,
                .g = vk.ComponentSwizzle.identity,
                .b = vk.ComponentSwizzle.identity,
                .a = vk.ComponentSwizzle.identity,
            },
            .flags = .{},
            .p_next = null,
        };
        const cube_view = gc.vkd.createImageView(gc.dev, &cube_view_info, null) catch return error.FailedToCreateImageView;

        // Create individual face views for rendering
        var face_views: [6]vk.ImageView = undefined;
        for (0..6) |i| {
            const face_view_info = vk.ImageViewCreateInfo{
                .s_type = vk.StructureType.image_view_create_info,
                .view_type = .@"2d",
                .format = format,
                .subresource_range = .{
                    .aspect_mask = aspect_mask,
                    .base_mip_level = 0,
                    .level_count = 1,
                    .base_array_layer = @intCast(i),
                    .layer_count = 1,
                },
                .image = image,
                .components = .{
                    .r = vk.ComponentSwizzle.identity,
                    .g = vk.ComponentSwizzle.identity,
                    .b = vk.ComponentSwizzle.identity,
                    .a = vk.ComponentSwizzle.identity,
                },
                .flags = .{},
                .p_next = null,
            };
            face_views[i] = gc.vkd.createImageView(gc.dev, &face_view_info, null) catch return error.FailedToCreateImageView;
        }

        // Transition all layers to general layout
        const cmd = try gc.beginSingleTimeCommands();
        gc.transitionImageLayout(
            cmd,
            image,
            vk.ImageLayout.undefined,
            vk.ImageLayout.general,
            .{
                .aspect_mask = aspect_mask,
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 6,
            },
        );
        try gc.endSingleTimeCommands(cmd);

        // Create comparison sampler for shadow mapping
        // Using less_or_equal: returns 1.0 if reference <= stored (fragment is lit)
        const sampler_info = vk.SamplerCreateInfo{
            .s_type = vk.StructureType.sampler_create_info,
            .mag_filter = vk.Filter.linear,
            .min_filter = vk.Filter.linear,
            .mipmap_mode = vk.SamplerMipmapMode.nearest,
            .address_mode_u = vk.SamplerAddressMode.clamp_to_edge,
            .address_mode_v = vk.SamplerAddressMode.clamp_to_edge,
            .address_mode_w = vk.SamplerAddressMode.clamp_to_edge,
            .mip_lod_bias = 0.0,
            .max_anisotropy = 1.0,
            .min_lod = 0.0,
            .max_lod = 1.0,
            .border_color = vk.BorderColor.float_opaque_white,
            .flags = .{},
            .p_next = null,
            .unnormalized_coordinates = .false,
            .compare_enable = if (compare_enable) .true else .false,
            .compare_op = compare_op, // Fragment lit if its depth <= stored depth
            .anisotropy_enable = .false,
        };
        const sampler = gc.vkd.createSampler(gc.dev, &sampler_info, null) catch return error.FailedToCreateSampler;

        log(.INFO, "texture", "Created cube depth texture {}x{} (6 layers)", .{ size, size });

        return Texture{
            .image = image,
            .image_view = cube_view, // Main view is the cube view for sampling
            .memory = memory,
            .sampler = sampler,
            .mip_levels = 1,
            .extent = extent,
            .format = format,
            .descriptor = vk.DescriptorImageInfo{
                .sampler = sampler,
                .image_view = cube_view,
                .image_layout = vk.ImageLayout.general,
            },
            .gc = gc,
            .memory_size = memory_size,
            .is_cube = true,
            .face_views = face_views,
        };
    }

    /// Initialize a cube depth array texture for multi-light shadow mapping with VK_KHR_multiview
    /// Creates cube_count cubes (cube_count * 6 layers) for rendering all lights simultaneously
    ///
    /// Memory layout: [light0_face0, light0_face1, ..., light0_face5, light1_face0, ..., lightN_face5]
    ///
    /// Creates two types of views:
    /// - Main view: CUBE_ARRAY for sampling in shaders (samplerCubeArray)
    /// - Face array views[6]: Each is a 2D_ARRAY covering the same face across ALL cubes
    ///   For multiview rendering: face_array_views[face] renders to layers [face, face+6, face+12, ...]
    pub fn initCubeDepthArray(
        gc: *GraphicsContext,
        size: u32,
        cube_count: u32,
        format: vk.Format,
        compare_enable: bool,
        compare_op: vk.CompareOp,
    ) !Texture {
        if (cube_count == 0) return error.InvalidCubeCount;

        const extent = vk.Extent3D{ .width = size, .height = size, .depth = 1 };
        const total_layers: u32 = cube_count * 6;

        // Create 2D array image with cube_count * 6 array layers (face-major layout)
        // Layout: [face0_light0..N, face1_light0..N, ...] for efficient multiview rendering
        const image_info = vk.ImageCreateInfo{
            .s_type = vk.StructureType.image_create_info,
            .image_type = .@"2d",
            .format = format,
            .extent = extent,
            .mip_levels = 1,
            .array_layers = total_layers,
            .samples = .{ .@"1_bit" = true },
            .tiling = vk.ImageTiling.optimal,
            .usage = .{ .depth_stencil_attachment_bit = true, .sampled_bit = true },
            .initial_layout = vk.ImageLayout.undefined,
            .sharing_mode = vk.SharingMode.exclusive,
            .flags = .{}, // No cube_compatible_bit - using 2D array with manual cube math
            .p_next = null,
            .queue_family_index_count = 0,
            .p_queue_family_indices = null,
        };

        var image: vk.Image = undefined;
        var memory: vk.DeviceMemory = undefined;
        try gc.createImageWithInfo(image_info, vk.MemoryPropertyFlags{ .device_local_bit = true }, &image, &memory);

        // Query memory size for tracking
        const mem_reqs = gc.vkd.getImageMemoryRequirements(gc.dev, image);
        const memory_size = mem_reqs.size;

        const aspect_mask = vk.ImageAspectFlags{ .depth_bit = true };

        // Create 2D_ARRAY image view for sampling (all layers as 2D array)
        // Layout: [face0_light0..N, face1_light0..N, ...] - face-major for multiview
        // Shader manually computes layer = face * num_lights + light_idx
        const array_view_info = vk.ImageViewCreateInfo{
            .s_type = vk.StructureType.image_view_create_info,
            .view_type = .@"2d_array",
            .format = format,
            .subresource_range = .{
                .aspect_mask = aspect_mask,
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = total_layers,
            },
            .image = image,
            .components = .{
                .r = vk.ComponentSwizzle.identity,
                .g = vk.ComponentSwizzle.identity,
                .b = vk.ComponentSwizzle.identity,
                .a = vk.ComponentSwizzle.identity,
            },
            .flags = .{},
            .p_next = null,
        };
        const array_view = gc.vkd.createImageView(gc.dev, &array_view_info, null) catch return error.FailedToCreateImageView;

        // Create face array views for multiview rendering
        // Each face view is a 2D_ARRAY covering layers [face * cube_count, (face+1) * cube_count - 1]
        // These are used with VK_KHR_multiview to render all lights in one draw call per face
        var face_array_views: [6]vk.ImageView = undefined;
        for (0..6) |face_idx| {
            // Layout: [face0_light0..N, face1_light0..N, ...]
            // So face_array_views[face] covers layers [face * cube_count, face * cube_count + cube_count - 1]
            //
            // Alternative approach: Use contiguous layout [face0_all_lights, face1_all_lights, ...]
            // Layer layout: [light0_f0, light1_f0, ..., lightN_f0, light0_f1, light1_f1, ...]
            //
            // For now, create a 2D_ARRAY view for each face starting at layer face_idx * cube_count
            // This requires changing the memory layout!
            //
            // Updated layout: [face0_light0, face0_light1, ..., face0_lightN, face1_light0, ...]
            // So face_array_views[face] covers layers [face * cube_count, face * cube_count + cube_count - 1]
            const base_layer: u32 = @as(u32, @intCast(face_idx)) * cube_count;

            const face_array_view_info = vk.ImageViewCreateInfo{
                .s_type = vk.StructureType.image_view_create_info,
                .view_type = .@"2d_array",
                .format = format,
                .subresource_range = .{
                    .aspect_mask = aspect_mask,
                    .base_mip_level = 0,
                    .level_count = 1,
                    .base_array_layer = base_layer,
                    .layer_count = cube_count,
                },
                .image = image,
                .components = .{
                    .r = vk.ComponentSwizzle.identity,
                    .g = vk.ComponentSwizzle.identity,
                    .b = vk.ComponentSwizzle.identity,
                    .a = vk.ComponentSwizzle.identity,
                },
                .flags = .{},
                .p_next = null,
            };
            face_array_views[face_idx] = gc.vkd.createImageView(gc.dev, &face_array_view_info, null) catch return error.FailedToCreateImageView;
        }

        // Transition all layers to general layout
        const cmd = try gc.beginSingleTimeCommands();
        gc.transitionImageLayout(
            cmd,
            image,
            vk.ImageLayout.undefined,
            vk.ImageLayout.general,
            .{
                .aspect_mask = aspect_mask,
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = total_layers,
            },
        );
        try gc.endSingleTimeCommands(cmd);

        // Create comparison sampler for shadow mapping
        const sampler_info = vk.SamplerCreateInfo{
            .s_type = vk.StructureType.sampler_create_info,
            .mag_filter = vk.Filter.linear,
            .min_filter = vk.Filter.linear,
            .mipmap_mode = vk.SamplerMipmapMode.nearest,
            .address_mode_u = vk.SamplerAddressMode.clamp_to_edge,
            .address_mode_v = vk.SamplerAddressMode.clamp_to_edge,
            .address_mode_w = vk.SamplerAddressMode.clamp_to_edge,
            .mip_lod_bias = 0.0,
            .max_anisotropy = 1.0,
            .min_lod = 0.0,
            .max_lod = 1.0,
            .border_color = vk.BorderColor.float_opaque_white,
            .flags = .{},
            .p_next = null,
            .unnormalized_coordinates = .false,
            .compare_enable = if (compare_enable) .true else .false,
            .compare_op = compare_op,
            .anisotropy_enable = .false,
        };
        const sampler = gc.vkd.createSampler(gc.dev, &sampler_info, null) catch return error.FailedToCreateSampler;

        log(.INFO, "texture", "Created cube depth array texture {}x{} ({} cubes, {} total layers)", .{
            size,
            size,
            cube_count,
            total_layers,
        });
        log(.INFO, "texture", "  Layout: [face0_light0..N, face1_light0..N, ...] for multiview", .{});

        return Texture{
            .image = image,
            .image_view = array_view, // Main view is 2D_ARRAY for sampling with sampler2DArrayShadow
            .memory = memory,
            .sampler = sampler,
            .mip_levels = 1,
            .extent = extent,
            .format = format,
            .descriptor = vk.DescriptorImageInfo{
                .sampler = sampler,
                .image_view = array_view,
                .image_layout = vk.ImageLayout.general,
            },
            .gc = gc,
            .memory_size = memory_size,
            .is_cube = true,
            .cube_count = cube_count,
            .face_views = null, // Not used for cube arrays
            .face_array_views = face_array_views,
        };
    }
};

// Texture struct already stores gc as a member, matching the init signature. Allocator is not stored, as not needed after construction.
