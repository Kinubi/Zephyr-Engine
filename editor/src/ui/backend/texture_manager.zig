const std = @import("std");
const c = @import("imgui_c.zig").c;
const ImGuiVulkanBackend = @import("imgui_backend_vulkan.zig").ImGuiVulkanBackend;
const zephyr = @import("zephyr");
const Texture = zephyr.TextureMod.Texture;
const zstbi = zephyr.TextureMod.zstbi;
const log = zephyr.log;

/// Global texture manager for ImGui UI textures
/// Handles loading, caching, and lifetime management of UI textures/icons
pub const TextureManager = struct {
    allocator: std.mem.Allocator,
    backend: *ImGuiVulkanBackend,
    textures: std.StringHashMap(*Texture),
    texture_ids: std.StringHashMap(c.ImTextureID),

    pub fn init(allocator: std.mem.Allocator, backend: *ImGuiVulkanBackend) TextureManager {
        return .{
            .allocator = allocator,
            .backend = backend,
            .textures = std.StringHashMap(*Texture).init(allocator),
            .texture_ids = std.StringHashMap(c.ImTextureID).init(allocator),
        };
    }

    /// Preload common icons on the main thread to avoid secondary command buffer issues
    /// This should be called during initialization before rendering starts
    pub fn preloadIcons(self: *TextureManager) !void {

        // List of icons to preload
        const icons_to_preload = [_][]const u8{
            "assets/icons/folder.png",
            // Add more common icons here as needed
        };

        for (icons_to_preload) |path| {
            // Try to load, but don't fail if icon doesn't exist
            _ = self.loadTexture(path) catch |err| {
                log(.WARN, "TextureManager", "Failed to preload icon {s}: {}", .{ path, err });
                continue;
            };
        }
    }

    pub fn deinit(self: *TextureManager) void {
        var iter = self.textures.iterator();
        while (iter.next()) |entry| {
            self.backend.removeTexture(entry.value_ptr.*);
        }
        self.textures.deinit();
        self.texture_ids.deinit();
    }

    /// Load a texture from file and return its ImGui texture ID
    /// Uses synchronous single-time commands to ensure immediate availability
    pub fn loadTexture(self: *TextureManager, path: []const u8) !c.ImTextureID {
        // Check if already loaded
        if (self.texture_ids.get(path)) |id| {
            return id;
        }

        // Load texture using Texture.loadFromFileSingle (handles all decoding and upload)
        const texture = try self.allocator.create(Texture);
        errdefer self.allocator.destroy(texture);

        texture.* = try Texture.loadFromFileSingle(
            self.backend.gc,
            self.allocator,
            path,
        );

        // Get texture ID from backend
        const texture_id = try self.backend.addTexture(texture);

        // Cache it
        const path_owned = try self.allocator.dupe(u8, path);
        try self.textures.put(path_owned, texture);
        try self.texture_ids.put(path_owned, texture_id);

        return texture_id;
    }

    /// Create a simple colored icon texture
    pub fn createColoredIcon(self: *TextureManager, name: []const u8, size: u32, color: [4]u8) !c.ImTextureID {
        // Check if already exists
        if (self.texture_ids.get(name)) |id| {
            return id;
        }

        // Create solid color image
        const pixel_count = size * size * 4;
        const pixels = try self.allocator.alloc(u8, pixel_count);
        defer self.allocator.free(pixels);

        var i: usize = 0;
        while (i < size * size) : (i += 1) {
            pixels[i * 4 + 0] = color[0]; // R
            pixels[i * 4 + 1] = color[1]; // G
            pixels[i * 4 + 2] = color[2]; // B
            pixels[i * 4 + 3] = color[3]; // A
        }

        // Use backend's synchronous upload function (like font upload)
        const texture = try self.backend.createTextureFromPixels(pixels, size, size);
        const texture_id = try self.backend.addTexture(texture);

        // Cache it
        const name_owned = try self.allocator.dupe(u8, name);
        try self.textures.put(name_owned, texture);
        try self.texture_ids.put(name_owned, texture_id);

        return texture_id;
    }

    /// Get a texture ID by name (returns null if not loaded)
    pub fn getTextureID(self: *TextureManager, name: []const u8) ?c.ImTextureID {
        return self.texture_ids.get(name);
    }
};

/// Global texture manager instance
var g_texture_manager: ?*TextureManager = null;

/// Initialize the global texture manager
pub fn initGlobal(allocator: std.mem.Allocator, backend: *ImGuiVulkanBackend) !void {
    if (g_texture_manager != null) return error.AlreadyInitialized;

    const manager = try allocator.create(TextureManager);
    manager.* = TextureManager.init(allocator, backend);
    g_texture_manager = manager;
}

/// Shutdown the global texture manager
pub fn deinitGlobal(allocator: std.mem.Allocator) void {
    if (g_texture_manager) |manager| {
        manager.deinit();
        allocator.destroy(manager);
        g_texture_manager = null;
    }
}

/// Get the global texture manager
pub fn getGlobal() ?*TextureManager {
    return g_texture_manager;
}
