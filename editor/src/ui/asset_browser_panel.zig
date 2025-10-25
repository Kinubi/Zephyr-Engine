const std = @import("std");
const c = @cImport({
    @cInclude("dcimgui.h");
});

/// Asset Browser Panel
/// Displays project assets in a file browser interface
pub const AssetBrowserPanel = struct {
    allocator: std.mem.Allocator,
    current_directory: []u8, // Owned by this struct
    assets_root: []const u8,
    directory_entries: std.ArrayList(DirectoryEntry),
    selected_asset: ?[]const u8,

    const DirectoryEntry = struct {
        name: []const u8,
        path: []const u8,
        is_directory: bool,
        extension: ?[]const u8,
    };

    pub fn init(allocator: std.mem.Allocator) AssetBrowserPanel {
        const assets_root = "assets"; // Constrain to assets directory

        return .{
            .allocator = allocator,
            .current_directory = allocator.dupe(u8, assets_root) catch unreachable,
            .assets_root = assets_root,
            .directory_entries = std.ArrayList(DirectoryEntry){},
            .selected_asset = null,
        };
    }

    pub fn deinit(self: *AssetBrowserPanel) void {
        for (self.directory_entries.items) |entry| {
            self.allocator.free(entry.name);
            self.allocator.free(entry.path);
            if (entry.extension) |ext| {
                self.allocator.free(ext);
            }
        }
        self.directory_entries.deinit(self.allocator);

        // Free owned current_directory
        self.allocator.free(self.current_directory);

        if (self.selected_asset) |asset| {
            self.allocator.free(asset);
        }
    }

    /// Refresh the directory listing
    pub fn refreshDirectory(self: *AssetBrowserPanel) !void {
        // Clear existing entries
        for (self.directory_entries.items) |entry| {
            self.allocator.free(entry.name);
            self.allocator.free(entry.path);
            if (entry.extension) |ext| {
                self.allocator.free(ext);
            }
        }
        self.directory_entries.clearRetainingCapacity();

        // Open directory
        var dir = std.fs.cwd().openDir(self.current_directory, .{ .iterate = true }) catch |err| {
            std.debug.print("Failed to open directory '{s}': {}\n", .{ self.current_directory, err });
            return;
        };
        defer dir.close();

        // Iterate through entries
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            const is_dir = entry.kind == .directory;

            // Skip hidden files and build artifacts
            if (entry.name[0] == '.' or
                std.mem.eql(u8, entry.name, "zig-out") or
                std.mem.eql(u8, entry.name, "zig-cache") or
                std.mem.eql(u8, entry.name, ".zig-cache") or
                std.mem.eql(u8, entry.name, "cache"))
            {
                continue;
            }

            // Get extension for files
            var extension: ?[]const u8 = null;
            if (!is_dir) {
                if (std.mem.lastIndexOfScalar(u8, entry.name, '.')) |dot_index| {
                    extension = try self.allocator.dupe(u8, entry.name[dot_index..]);
                }
            }

            // Create full path
            const path = try std.fs.path.join(self.allocator, &.{ self.current_directory, entry.name });

            try self.directory_entries.append(self.allocator, .{
                .name = try self.allocator.dupe(u8, entry.name),
                .path = path,
                .is_directory = is_dir,
                .extension = extension,
            });
        }

        // Sort: directories first, then files alphabetically
        std.mem.sort(DirectoryEntry, self.directory_entries.items, {}, compareEntries);
    }

    fn compareEntries(_: void, a: DirectoryEntry, b: DirectoryEntry) bool {
        // Directories come before files
        if (a.is_directory and !b.is_directory) return true;
        if (!a.is_directory and b.is_directory) return false;

        // Alphabetical order
        return std.mem.lessThan(u8, a.name, b.name);
    }

    /// Render the asset browser panel
    pub fn render(self: *AssetBrowserPanel) void {
        const window_flags = c.ImGuiWindowFlags_None;

        if (c.ImGui_Begin("Asset Browser", null, window_flags)) {
            // Toolbar with navigation
            self.renderToolbar();

            c.ImGui_Separator();

            // Current directory path
            c.ImGui_Text("Path: %s", self.current_directory.ptr);
            c.ImGui_Separator();

            // Asset grid/list view
            self.renderAssetGrid();
        }
        c.ImGui_End();
    }

    fn renderToolbar(self: *AssetBrowserPanel) void {
        // Back button
        if (c.ImGui_Button("<- Back")) {
            self.navigateUp() catch |err| {
                std.debug.print("Failed to navigate up: {}\n", .{err});
            };
        }

        c.ImGui_SameLine();

        // Home button (go to project root)
        if (c.ImGui_Button("Home")) {
            const new_dir = self.allocator.dupe(u8, self.assets_root) catch {
                std.debug.print("Failed to allocate for home navigation\n", .{});
                return;
            };
            self.allocator.free(self.current_directory);
            self.current_directory = new_dir;
            self.refreshDirectory() catch |err| {
                std.debug.print("Failed to refresh directory: {}\n", .{err});
            };
        }

        c.ImGui_SameLine();

        // Refresh button
        if (c.ImGui_Button("Refresh")) {
            self.refreshDirectory() catch |err| {
                std.debug.print("Failed to refresh directory: {}\n", .{err});
            };
        }

        c.ImGui_SameLine();
        c.ImGui_Text("| %d items", @as(c_int, @intCast(self.directory_entries.items.len)));
    }

    fn renderAssetGrid(self: *AssetBrowserPanel) void {
        // Calculate grid layout
        const window_visible_x = c.ImGui_GetWindowContentRegionMax().x;
        const icon_size: f32 = 64.0;
        const padding: f32 = 16.0;
        const cell_size = icon_size + padding;

        const columns = @max(1, @as(i32, @intFromFloat(window_visible_x / cell_size)));

        // Begin grid
        if (c.ImGui_BeginTable("AssetGrid", columns, c.ImGuiTableFlags_None)) {
            var column: i32 = 0;

            for (self.directory_entries.items) |entry| {
                if (column == 0) {
                    c.ImGui_TableNextRow();
                }
                _ = c.ImGui_TableSetColumnIndex(column);

                // Render asset item
                self.renderAssetItem(entry);

                column = @rem((column + 1), columns);
            }

            c.ImGui_EndTable();
        }
    }

    fn renderAssetItem(self: *AssetBrowserPanel, entry: DirectoryEntry) void {
        const icon_size: f32 = 64.0;

        // Create unique ID for this item
        c.ImGui_PushID(entry.path.ptr);
        defer c.ImGui_PopID();

        // Determine icon based on type
        const icon = if (entry.is_directory) "📁" else getFileIcon(entry.extension);

        // Button for the item
        const is_selected = if (self.selected_asset) |selected|
            std.mem.eql(u8, selected, entry.path)
        else
            false;

        if (is_selected) {
            const col = c.ImVec4{ .x = 0.3, .y = 0.5, .z = 0.9, .w = 0.4 };
            c.ImGui_PushStyleColorImVec4(c.ImGuiCol_Button, col);
        }

        // Create a selectable area for the icon
        _ = c.ImGui_Selectable(icon);
        const clicked = c.ImGui_IsItemClicked();

        if (is_selected) {
            c.ImGui_PopStyleColor();
        }

        if (clicked) {
            // Handle click
            if (entry.is_directory) {
                // Navigate into directory
                self.navigateInto(entry.path) catch |err| {
                    std.debug.print("Failed to navigate into directory: {}\n", .{err});
                };
            } else {
                // Select asset
                if (self.selected_asset) |old| {
                    self.allocator.free(old);
                }
                self.selected_asset = self.allocator.dupe(u8, entry.path) catch null;
                std.debug.print("Selected asset: {s}\n", .{entry.path});
            }
        }

        // Handle double-click for directories
        if (entry.is_directory and c.ImGui_IsItemHovered(c.ImGuiHoveredFlags_None) and c.ImGui_IsMouseDoubleClicked(c.ImGuiMouseButton_Left)) {
            self.navigateInto(entry.path) catch |err| {
                std.debug.print("Failed to navigate into directory: {}\n", .{err});
            };
        }

        // Asset name (wrapped text)
        const text_width = icon_size;
        c.ImGui_PushTextWrapPos(c.ImGui_GetCursorPosX() + text_width);
        c.ImGui_TextWrapped("%s", entry.name.ptr);
        c.ImGui_PopTextWrapPos();
    }

    fn getFileIcon(extension: ?[]const u8) [*:0]const u8 {
        if (extension) |ext| {
            // Model files
            if (std.mem.eql(u8, ext, ".obj") or
                std.mem.eql(u8, ext, ".gltf") or
                std.mem.eql(u8, ext, ".glb") or
                std.mem.eql(u8, ext, ".fbx"))
            {
                return "🧊"; // Cube for 3D models
            }

            // Image files
            if (std.mem.eql(u8, ext, ".png") or
                std.mem.eql(u8, ext, ".jpg") or
                std.mem.eql(u8, ext, ".jpeg") or
                std.mem.eql(u8, ext, ".bmp") or
                std.mem.eql(u8, ext, ".tga"))
            {
                return "🖼️"; // Picture frame
            }

            // Shader files
            if (std.mem.eql(u8, ext, ".vert") or
                std.mem.eql(u8, ext, ".frag") or
                std.mem.eql(u8, ext, ".comp") or
                std.mem.eql(u8, ext, ".glsl") or
                std.mem.eql(u8, ext, ".hlsl") or
                std.mem.eql(u8, ext, ".spv"))
            {
                return "⚡"; // Lightning for shaders
            }

            // Scene files
            if (std.mem.eql(u8, ext, ".scene") or std.mem.eql(u8, ext, ".json")) {
                return "🎬"; // Scene clapper
            }
        }

        return "📄"; // Generic file
    }

    fn navigateUp(self: *AssetBrowserPanel) !void {
        // Don't go above assets root
        if (std.mem.eql(u8, self.current_directory, self.assets_root)) {
            return;
        }

        // Get parent directory
        if (std.fs.path.dirname(self.current_directory)) |parent| {
            // Don't go above assets root
            if (parent.len < self.assets_root.len) {
                // Free old and set to assets root
                self.allocator.free(self.current_directory);
                self.current_directory = try self.allocator.dupe(u8, self.assets_root);
            } else {
                // Free old and set to parent
                const new_dir = try self.allocator.dupe(u8, parent);
                self.allocator.free(self.current_directory);
                self.current_directory = new_dir;
            }
            try self.refreshDirectory();
        }
    }

    fn navigateInto(self: *AssetBrowserPanel, path: []const u8) !void {
        // Create owned copy of the new path
        const new_dir = try self.allocator.dupe(u8, path);

        // Free old current_directory and assign new one
        self.allocator.free(self.current_directory);
        self.current_directory = new_dir;

        try self.refreshDirectory();
    }
};
