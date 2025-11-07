const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("../core/graphics_context.zig").GraphicsContext;
const Texture = @import("../core/texture.zig").Texture;
const log = @import("../utils/log.zig").log;

pub const MAX_FRAMES_IN_FLIGHT = @import("../core/swapchain.zig").MAX_FRAMES_IN_FLIGHT;

pub const TextureConfig = struct {
    name: []const u8,
    format: vk.Format,
    extent: vk.Extent3D,
    usage: vk.ImageUsageFlags,
    samples: vk.SampleCountFlags = .{ .@"1_bit" = true },
    /// Optional link to another texture for automatic size tracking
    resize_source: ?*ManagedTexture = null,
    /// If true, also match the source texture's format (not just size)
    match_format: bool = false,
};

pub const TextureStats = struct {
    format: vk.Format,
    extent: vk.Extent3D,
    created_frame: u64,
    last_updated: u64,
};

/// Managed texture with generation tracking for automatic rebinding
pub const ManagedTexture = struct {
    texture: Texture,
    name: []const u8,
    format: vk.Format,
    extent: vk.Extent3D,
    usage: vk.ImageUsageFlags,
    samples: vk.SampleCountFlags,
    created_frame: u64,
    generation: u32, // Generation counter for tracking updates
    resize_source: ?*ManagedTexture = null,
    match_format: bool = false,
    binding_info: ?BindingInfo = null,

    pub const BindingInfo = struct {
        set: u32,
        binding: u32,
        pipeline_name: []const u8,
    };

    /// Get descriptor info for manual binding
    pub fn getDescriptorInfo(self: *const ManagedTexture) vk.DescriptorImageInfo {
        return self.texture.getDescriptorInfo();
    }

    /// Check if linked texture changed and auto-resize/format-match if needed
    pub fn update(self: *ManagedTexture, texture_manager: *TextureManager) !void {
        if (self.resize_source) |source| {
            // Check if source texture has changed
            const size_changed = source.extent.width != self.extent.width or
                source.extent.height != self.extent.height or
                source.extent.depth != self.extent.depth;
            const format_changed = self.match_format and source.format != self.format;

            if (size_changed or format_changed) {
                // Resize and/or update format to match source
                const new_format = if (self.match_format) source.format else self.format;

                try self.resize(texture_manager, source.extent, new_format);
                // Generation auto-increments in resize()
            }
        }
    }

    /// Resize texture (recreates underlying Vulkan resources)
    pub fn resize(self: *ManagedTexture, texture_manager: *TextureManager, new_extent: vk.Extent3D, new_format: vk.Format) !void {

        // Defer old texture cleanup to avoid in-flight frame issues
        try texture_manager.deferTextureCleanup(self.texture);

        // Create new texture with new size/format using initSingleTime to avoid command pool dependency
        self.texture = try Texture.initSingleTime(
            texture_manager.graphics_context,
            new_format,
            new_extent,
            self.usage,
            self.samples,
        );

        self.extent = new_extent;
        self.format = new_format;
        self.generation += 1; // Trigger ResourceBinder rebind

        // Update statistics
        if (texture_manager.all_textures.getPtr(self.name)) |stats| {
            stats.extent = new_extent;
            stats.last_updated = texture_manager.frame_counter;
        }

        log(.INFO, "texture_manager", "Texture '{s}' resized, new generation: {}", .{ self.name, self.generation });
    }
};

pub const TextureManager = struct {
    allocator: std.mem.Allocator,
    graphics_context: *GraphicsContext,

    // Ring buffers for frame-safe cleanup
    deferred_textures: [MAX_FRAMES_IN_FLIGHT]std.ArrayList(Texture),
    current_frame: u32 = 0,
    frame_counter: u64 = 0,

    // Global registry for debugging
    all_textures: std.StringHashMap(TextureStats),

    // Registry of all managed textures for automatic updates
    managed_textures: std.ArrayList(*ManagedTexture),

    /// Initialize TextureManager
    pub fn init(
        allocator: std.mem.Allocator,
        graphics_context: *GraphicsContext,
    ) !TextureManager {
        var deferred_textures: [MAX_FRAMES_IN_FLIGHT]std.ArrayList(Texture) = undefined;
        inline for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            deferred_textures[i] = std.ArrayList(Texture){};
        }

        const self = TextureManager{
            .allocator = allocator,
            .graphics_context = graphics_context,
            .deferred_textures = deferred_textures,
            .all_textures = std.StringHashMap(TextureStats).init(allocator),
            .managed_textures = std.ArrayList(*ManagedTexture){},
        };

        log(.INFO, "texture_manager", "TextureManager initialized", .{});
        return self;
    }

    pub fn deinit(self: *TextureManager) void {
        // Clean up all deferred textures
        for (&self.deferred_textures) |*slot| {
            self.cleanupRingSlot(slot);
            slot.deinit(self.allocator);
        }

        self.managed_textures.deinit(self.allocator);
        self.all_textures.deinit();
        log(.INFO, "texture_manager", "TextureManager deinitialized", .{});
    }

    /// Create managed texture with specified config
    /// Note: Returns a pointer to the managed texture which must be stored by the caller.
    /// The texture is automatically registered for resize updates.
    pub fn createTexture(
        self: *TextureManager,
        config: TextureConfig,
    ) !*ManagedTexture {
        // Duplicate the name for ownership
        const owned_name = try self.allocator.dupe(u8, config.name);
        errdefer self.allocator.free(owned_name);

        // Create the texture using initSingleTime to avoid command pool dependency
        const texture = try Texture.initSingleTime(
            self.graphics_context,
            config.format,
            config.extent,
            config.usage,
            config.samples,
        );

        // Allocate the managed texture on the heap so we can track it
        const managed = try self.allocator.create(ManagedTexture);
        errdefer self.allocator.destroy(managed);

        managed.* = ManagedTexture{
            .texture = texture,
            .name = owned_name,
            .format = config.format,
            .extent = config.extent,
            .usage = config.usage,
            .samples = config.samples,
            .created_frame = self.frame_counter,
            .generation = 1, // Start at generation 1
            .resize_source = config.resize_source,
            .match_format = config.match_format,
        };

        // Add to statistics
        try self.all_textures.put(owned_name, TextureStats{
            .format = config.format,
            .extent = config.extent,
            .created_frame = self.frame_counter,
            .last_updated = self.frame_counter,
        });

        // Automatically register for resize updates
        try self.registerTexture(managed);

        log(.INFO, "texture_manager", "Created and registered texture '{s}' ({}x{}x{}, format: {})", .{
            config.name,
            config.extent.width,
            config.extent.height,
            config.extent.depth,
            config.format,
        });

        return managed;
    }

    /// Register a managed texture for automatic updates
    pub fn registerTexture(self: *TextureManager, managed: *ManagedTexture) !void {
        try self.managed_textures.append(self.allocator, managed);
    }

    /// Unregister a managed texture (call before destroying)
    /// Safe to call even if texture was never registered
    pub fn unregisterTexture(self: *TextureManager, managed: *ManagedTexture) void {
        // Find and remove the texture from the registry
        // Safe to call even if texture wasn't registered - just won't find it
        var i: usize = 0;
        while (i < self.managed_textures.items.len) {
            if (self.managed_textures.items[i] == managed) {
                _ = self.managed_textures.swapRemove(i);
                return;
            }
            i += 1;
        }
        // Texture not found in registry - this is OK for manually-managed textures
    }

    /// Destroy a managed texture (defers actual cleanup)
    pub fn destroyTexture(self: *TextureManager, managed: *ManagedTexture) void {
        log(.INFO, "texture_manager", "Destroying texture '{s}'", .{managed.name});

        // Unregister from update list
        self.unregisterTexture(managed);

        // Defer texture cleanup to avoid in-flight frame issues
        self.deferTextureCleanup(managed.texture) catch |err| {
            log(.ERROR, "texture_manager", "Failed to defer texture cleanup: {}", .{err});
        };

        // Remove from statistics
        _ = self.all_textures.remove(managed.name);

        // Free the name
        self.allocator.free(managed.name);

        // Free the managed texture itself
        self.allocator.destroy(managed);
    }

    /// Begin a new frame (flush old deferred textures)
    pub fn beginFrame(self: *TextureManager, frame_index: u32) void {
        self.current_frame = frame_index;
        self.frame_counter += 1;

        // Clean up deferred textures from MAX_FRAMES_IN_FLIGHT ago
        self.cleanupRingSlot(&self.deferred_textures[frame_index]);
    }

    /// Update all managed textures (check resize sources, auto-resize if needed)
    /// Called from RenderLayer.update() each frame
    pub fn updateTextures(self: *TextureManager) !void {
        // Iterate through all registered managed textures and update them
        for (self.managed_textures.items) |managed_tex| {
            try managed_tex.update(self);
        }
    }

    /// Defer texture cleanup to frame-safe ring buffer
    fn deferTextureCleanup(self: *TextureManager, texture: Texture) !void {
        try self.deferred_textures[self.current_frame].append(self.allocator, texture);
    }

    /// Clean up all textures in a ring slot
    fn cleanupRingSlot(_: *TextureManager, slot: *std.ArrayList(Texture)) void {
        for (slot.items) |*texture| {
            texture.deinit();
        }
        slot.clearRetainingCapacity();
    }

    /// Get statistics for a texture
    pub fn getStats(self: *TextureManager, name: []const u8) ?TextureStats {
        return self.all_textures.get(name);
    }

    /// Debug: Print all managed textures
    pub fn debugPrint(self: *TextureManager) void {
        log(.DEBUG, "texture_manager", "=== TextureManager State ===", .{});
        log(.DEBUG, "texture_manager", "Frame: {}", .{self.frame_counter});
        log(.DEBUG, "texture_manager", "Active textures: {}", .{self.all_textures.count()});

        var iter = self.all_textures.iterator();
        while (iter.next()) |entry| {
            const stats = entry.value_ptr.*;
            log(.DEBUG, "texture_manager", "  '{s}': {}x{}x{}, format: {}, frame: {}", .{
                entry.key_ptr.*,
                stats.extent.width,
                stats.extent.height,
                stats.extent.depth,
                stats.format,
                stats.created_frame,
            });
        }
    }
};
