const std = @import("std");
const vk = @import("vulkan");
pub const zstbi = @import("zstbi");
const GraphicsContext = @import("graphics_context.zig").GraphicsContext;
const Buffer = @import("buffer.zig").Buffer;
const log = @import("../utils/log.zig").log;
const LogLevel = @import("../utils/log.zig").LogLevel;

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

    pub fn init(
        gc: *GraphicsContext,
        format: vk.Format,
        extent: vk.Extent3D,
        usage: vk.ImageUsageFlags,
        sample_count: vk.SampleCountFlags,
    ) !Texture {
        var aspect_mask = vk.ImageAspectFlags{ .color_bit = true };
        var image_layout: vk.ImageLayout = undefined;

        // Determine appropriate layout based on usage flags
        if (usage.color_attachment_bit) {
            aspect_mask = vk.ImageAspectFlags{ .color_bit = true };
            image_layout = vk.ImageLayout.color_attachment_optimal;
        } else if (usage.depth_stencil_attachment_bit) {
            aspect_mask = vk.ImageAspectFlags{ .depth_bit = true };
            image_layout = vk.ImageLayout.depth_stencil_attachment_optimal;
        } else if (usage.storage_bit) {
            aspect_mask = vk.ImageAspectFlags{ .color_bit = true };
            image_layout = vk.ImageLayout.general;
        } else {
            // Sampled-only texture (no attachment or storage usage)
            aspect_mask = vk.ImageAspectFlags{ .color_bit = true };
            image_layout = vk.ImageLayout.shader_read_only_optimal;
        }
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
                .image_layout = vk.ImageLayout.shader_read_only_optimal,
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
                .image_layout = vk.ImageLayout.shader_read_only_optimal,
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
            .shader_read_only_optimal,
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
        texture.descriptor.image_layout = .shader_read_only_optimal;

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
        // Destroy Vulkan resources in reverse order of creation
        self.gc.vkd.destroySampler(self.gc.dev, self.sampler, null);
        self.gc.vkd.destroyImageView(self.gc.dev, self.image_view, null);
        self.gc.vkd.destroyImage(self.gc.dev, self.image, null);
        self.gc.vkd.freeMemory(self.gc.dev, self.memory, null);
    }
};

// Texture struct already stores gc as a member, matching the init signature. Allocator is not stored, as not needed after construction.
