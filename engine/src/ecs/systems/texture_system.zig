const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("../../core/graphics_context.zig").GraphicsContext;
const Texture = @import("../../core/texture.zig").Texture;
const ResourceBinder = @import("../../rendering/resource_binder.zig").ResourceBinder;
const World = @import("../world.zig").World;
const Scene = @import("../../scene/scene.zig").Scene;
const log = @import("../../utils/log.zig").log;

pub const MAX_FRAMES_IN_FLIGHT = @import("../../core/swapchain.zig").MAX_FRAMES_IN_FLIGHT;

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
    pub fn update(self: *ManagedTexture, texture_manager: *TextureSystem) !void {
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
    pub fn resize(self: *ManagedTexture, texture_manager: *TextureSystem, new_extent: vk.Extent3D, new_format: vk.Format) !void {
        log(.INFO, "texture_manager", "Resizing texture '{s}' from {}x{}x{} to {}x{}x{}", .{
            self.name,
            self.extent.width,
            self.extent.height,
            self.extent.depth,
            new_extent.width,
            new_extent.height,
            new_extent.depth,
        });

        // Defer old texture cleanup to avoid in-flight frame issues
        try texture_manager.deferTextureCleanup(self.texture);

        // Create new texture with new size/format
        self.texture = try Texture.init(
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
    }
};

pub const TextureSystem = struct {
    allocator: std.mem.Allocator,
    graphics_context: *GraphicsContext,

    // Ring buffers for frame-safe cleanup
    deferred_textures: [MAX_FRAMES_IN_FLIGHT]std.ArrayList(Texture),
    current_frame: u32 = 0,
    frame_counter: u64 = 0,

    // Global registry for debugging
    all_textures: std.StringHashMap(TextureStats),

    /// Initialize TextureSystem
    pub fn init(
        allocator: std.mem.Allocator,
        graphics_context: *GraphicsContext,
    ) !TextureSystem {
        var self = TextureSystem{
            .allocator = allocator,
            .graphics_context = graphics_context,
            .deferred_textures = undefined,
            .all_textures = std.StringHashMap(TextureStats).init(allocator),
        };

        // Initialize ring buffer arrays
        inline for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            self.deferred_textures[i] = std.ArrayList(Texture).init(allocator);
        }

        log(.INFO, "texture_system", "TextureSystem initialized", .{});
        return self;
    }

    pub fn deinit(self: *TextureSystem) void {
        // Clean up all deferred textures
        for (&self.deferred_textures) |*slot| {
            self.cleanupRingSlot(slot);
            slot.deinit();
        }

        self.all_textures.deinit();
        log(.INFO, "texture_system", "TextureSystem deinitialized", .{});
    }

    /// Create managed texture with specified config
    pub fn createTexture(
        self: *TextureSystem,
        config: TextureConfig,
    ) !ManagedTexture {
        // Duplicate the name for ownership
        const owned_name = try self.allocator.dupe(u8, config.name);
        errdefer self.allocator.free(owned_name);

        // Create the texture
        const texture = try Texture.init(
            self.graphics_context,
            config.format,
            config.extent,
            config.usage,
            config.samples,
        );

        const managed = ManagedTexture{
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

        log(.INFO, "texture_manager", "Created texture '{s}' ({}x{}x{}, format: {})", .{
            config.name,
            config.extent.width,
            config.extent.height,
            config.extent.depth,
            config.format,
        });

        return managed;
    }

    /// Destroy a managed texture (defers actual cleanup)
    pub fn destroyTexture(self: *TextureSystem, managed: *ManagedTexture) void {
        log(.INFO, "texture_manager", "Destroying texture '{s}'", .{managed.name});

        // Defer texture cleanup to avoid in-flight frame issues
        self.deferTextureCleanup(managed.texture) catch |err| {
            log(.ERROR, "texture_manager", "Failed to defer texture cleanup: {}", .{err});
        };

        // Remove from statistics
        _ = self.all_textures.remove(managed.name);

        // Free the name
        self.allocator.free(managed.name);
    }

    /// Begin a new frame (flush old deferred textures)
    pub fn beginFrame(self: *TextureSystem, frame_index: u32) void {
        self.current_frame = frame_index;
        self.frame_counter += 1;

        // Clean up deferred textures from MAX_FRAMES_IN_FLIGHT ago
        self.cleanupRingSlot(&self.deferred_textures[frame_index]);
    }

    /// Update all managed textures (check resize sources, auto-resize if needed)
    /// Called from SystemScheduler or manually each frame
    pub fn updateTextures(self: *TextureSystem) !void {
        // In the future, we'll track ManagedTexture instances and update them
        // For now, this is a placeholder for the SystemScheduler integration
        _ = self;
    }

    /// Defer texture cleanup to frame-safe ring buffer
    fn deferTextureCleanup(self: *TextureSystem, texture: Texture) !void {
        try self.deferred_textures[self.current_frame].append(texture);
    }

    /// Clean up all textures in a ring slot
    fn cleanupRingSlot(_: *TextureSystem, slot: *std.ArrayList(Texture)) void {
        for (slot.items) |*texture| {
            texture.deinit();
        }
        slot.clearRetainingCapacity();
    }

    /// Get statistics for a texture
    pub fn getStats(self: *TextureSystem, name: []const u8) ?TextureStats {
        return self.all_textures.get(name);
    }

    /// Debug: Print all managed textures
    pub fn debugPrint(self: *TextureSystem) void {
        log(.DEBUG, "texture_manager", "=== TextureSystem State ===", .{});
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

/// Free update function for SystemScheduler compatibility
/// Runs texture resize checks and updates via the Scene-owned TextureSystem instance.
pub fn update(world: *World, dt: f32) !void {
    _ = dt;

    // Get the scene from world userdata
    const scene_ptr = world.getUserData("scene") orelse return;
    const scene: *Scene = @ptrCast(@alignCast(scene_ptr));

    // Get texture system from scene
    if (scene.texture_system) |texture_system| {
        try texture_system.updateTextures();
    }
}
