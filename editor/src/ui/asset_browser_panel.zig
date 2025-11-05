const std = @import("std");
const zephyr = @import("zephyr");
const log = zephyr.log;
const c = @import("backend/imgui_c.zig").c;
const texture_manager = @import("backend/texture_manager.zig");

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
            log(.ERROR, "AssetBrowser", "Failed to open directory '{s}': {}", .{ self.current_directory, err });
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
                log(.ERROR, "AssetBrowser", "Failed to navigate up: {}", .{err});
            };
        }

        c.ImGui_SameLine();

        // Home button (go to project root)
        if (c.ImGui_Button("Home")) {
            const new_dir = self.allocator.dupe(u8, self.assets_root) catch {
                log(.ERROR, "AssetBrowser", "Failed to allocate for home navigation", .{});
                return;
            };
            self.allocator.free(self.current_directory);
            self.current_directory = new_dir;
            self.refreshDirectory() catch |err| {
                log(.ERROR, "AssetBrowser", "Failed to refresh directory: {}", .{err});
            };
        }

        c.ImGui_SameLine();

        // Refresh button
        if (c.ImGui_Button("Refresh")) {
            self.refreshDirectory() catch |err| {
                log(.ERROR, "AssetBrowser", "Failed to refresh directory: {}", .{err});
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

            // Defer directory navigation to avoid mutating `directory_entries` while
            // iterating it. `navigateInto()` calls `refreshDirectory()` which clears
            // and repopulates the entries list; doing that during iteration causes
            // use-after-free and crashes (observed when opening `assets/scripts`).
            var pending_navigation: ?[]u8 = null;

            for (self.directory_entries.items) |entry| {
                if (column == 0) {
                    c.ImGui_TableNextRow();
                }
                _ = c.ImGui_TableSetColumnIndex(column);

                // Render asset item and allow it to set pending navigation
                self.renderAssetItem(entry, &pending_navigation);

                column = @rem((column + 1), columns);
            }

            c.ImGui_EndTable();

            // Perform deferred navigation (safe to mutate now)
            if (pending_navigation) |p| {
                self.navigateInto(p) catch |err| {
                    log(.ERROR, "AssetBrowser", "Failed to navigate into directory: {}", .{err});
                };
                self.allocator.free(p);
            }
        }
    }

    fn renderAssetItem(self: *AssetBrowserPanel, entry: DirectoryEntry, pending_navigation: *?[]u8) void {

        // Create unique ID for this item
        c.ImGui_PushID(entry.path.ptr);
        defer c.ImGui_PopID();

        const icon_size: f32 = 64.0;

        // First: Try per-type icon files under assets/icons/ (e.g. assets/icons/folder.png or assets/icons/png.png)
        if (texture_manager.getGlobal()) |tm| {
            if (tryLoadIconForEntry(self, tm, entry)) |icon_id| {
                const tex_ref = c.ImTextureRef{ ._TexData = null, ._TexID = icon_id };
                const button_clicked = c.ImGui_ImageButton(entry.name.ptr, tex_ref, .{ .x = icon_size, .y = icon_size });
                if (button_clicked) {
                    if (entry.is_directory) {
                        // Navigate into directory on single click
                        if (pending_navigation.* == null) {
                            pending_navigation.* = self.allocator.dupe(u8, entry.path) catch null;
                        }
                    } else {
                        // Select asset file
                        if (self.selected_asset) |old| {
                            self.allocator.free(old);
                        }
                        self.selected_asset = self.allocator.dupe(u8, entry.path) catch null;
                    }
                }
                if (c.ImGui_BeginDragDropSource(0)) {
                    _ = c.ImGui_SetDragDropPayload("ASSET_PATH", entry.path.ptr, entry.path.len, 0);
                    c.ImGui_Text("%s", entry.path.ptr);
                    c.ImGui_EndDragDropSource();
                }
                c.ImGui_TextWrapped("%s", entry.name.ptr);
                return;
            }
        }

        // Fallback to text icon (emoji/ASCII)
        const icon = if (entry.is_directory) "📁" else getFileIcon(entry.extension);

        // Button for the item: show icon and name together in the selectable
        // label so the click target includes both and the icon is visible.
        const is_selected = if (self.selected_asset) |selected|
            std.mem.eql(u8, selected, entry.path)
        else
            false;

        if (is_selected) {
            const col = c.ImVec4{ .x = 0.3, .y = 0.5, .z = 0.9, .w = 0.4 };
            c.ImGui_PushStyleColorImVec4(c.ImGuiCol_Button, col);
        }

        // Build a temporary NUL-terminated label: "<icon> <name>" and use it as
        // the selectable label. This ensures the icon and name render together.
        const icon_len = std.mem.len(icon);
        const combined_opt = self.allocator.alloc(u8, icon_len + 1 + entry.name.len + 1) catch null;
        if (combined_opt) |combined_buf| {
            std.mem.copyForwards(u8, combined_buf[0..icon_len], icon[0..icon_len]);
            combined_buf[icon_len] = ' ';
            std.mem.copyForwards(u8, combined_buf[icon_len + 1 .. icon_len + 1 + entry.name.len], entry.name);
            combined_buf[icon_len + 1 + entry.name.len] = 0;

            _ = c.ImGui_Selectable(combined_buf.ptr);
        } else {
            // Allocation failed; fall back to showing only the icon as selectable
            _ = c.ImGui_Selectable(icon);
        }
        const clicked = c.ImGui_IsItemClicked();

        if (is_selected) {
            c.ImGui_PopStyleColor();
        }

        if (clicked) {
            // Handle click
            if (entry.is_directory) {
                // Defer navigation: duplicate the path so it survives refreshDirectory()
                if (pending_navigation.* == null) {
                    pending_navigation.* = self.allocator.dupe(u8, entry.path) catch null;
                    if (pending_navigation.* == null) {
                        log(.ERROR, "AssetBrowser", "Failed to allocate pending navigation path", .{});
                    }
                }
            } else {
                // Select asset
                if (self.selected_asset) |old| {
                    self.allocator.free(old);
                }
                self.selected_asset = self.allocator.dupe(u8, entry.path) catch null;
            }
        }

        // Allow dragging this asset as a payload (path string)
        if (c.ImGui_BeginDragDropSource(0)) {
            // ImGui copies payload data, pass pointer and size
            _ = c.ImGui_SetDragDropPayload("ASSET_PATH", entry.path.ptr, entry.path.len, 0);
            c.ImGui_Text("%s", entry.path.ptr);
            c.ImGui_EndDragDropSource();
        }

        // Handle double-click for directories
        if (entry.is_directory and c.ImGui_IsItemHovered(c.ImGuiHoveredFlags_None) and c.ImGui_IsMouseDoubleClicked(c.ImGuiMouseButton_Left)) {
            if (pending_navigation.* == null) {
                pending_navigation.* = self.allocator.dupe(u8, entry.path) catch null;
                if (pending_navigation.* == null) {
                    log(.ERROR, "AssetBrowser", "Failed to allocate pending navigation path", .{});
                }
            }
        }

        // We rendered the name as part of the selectable label above. Free the
        // combined buffer if it was allocated.
        if (combined_opt) |buf| {
            self.allocator.free(buf);
        }
    }

    fn isImageFile(extension: ?[]const u8) bool {
        if (extension) |ext| {
            return std.mem.eql(u8, ext, ".png") or
                std.mem.eql(u8, ext, ".jpg") or
                std.mem.eql(u8, ext, ".jpeg") or
                std.mem.eql(u8, ext, ".bmp") or
                std.mem.eql(u8, ext, ".tga");
        }
        return false;
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
            if (isImageFile(extension)) {
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

    fn isModelFile(extension: ?[]const u8) bool {
        if (extension) |ext| {
            return std.mem.eql(u8, ext, ".obj") or
                std.mem.eql(u8, ext, ".gltf") or
                std.mem.eql(u8, ext, ".glb") or
                std.mem.eql(u8, ext, ".fbx");
        }
        return false;
    }

    fn isShaderFile(extension: ?[]const u8) bool {
        if (extension) |ext| {
            return std.mem.eql(u8, ext, ".vert") or
                std.mem.eql(u8, ext, ".frag") or
                std.mem.eql(u8, ext, ".comp") or
                std.mem.eql(u8, ext, ".glsl") or
                std.mem.eql(u8, ext, ".hlsl") or
                std.mem.eql(u8, ext, ".spv");
        }
        return false;
    }

    fn getDefaultIconID(tm: *texture_manager.TextureManager, name: []const u8, color: [4]u8) ?c.ImTextureID {
        if (tm.getTextureID(name)) |id| return id;
        return tm.createColoredIcon(name, 32, color) catch null;
    }

    /// Map file extensions to icon filenames
    /// Returns the icon filename (without path) for a given extension
    fn getIconNameForExtension(ext: []const u8) ?[]const u8 {
        // Shader files -> shader.png
        if (std.mem.eql(u8, ext, ".vert") or
            std.mem.eql(u8, ext, ".frag") or
            std.mem.eql(u8, ext, ".comp") or
            std.mem.eql(u8, ext, ".glsl") or
            std.mem.eql(u8, ext, ".hlsl") or
            std.mem.eql(u8, ext, ".spv"))
        {
            return "shader";
        }

        // Script files -> script.png
        if (std.mem.eql(u8, ext, ".lua") or
            std.mem.eql(u8, ext, ".js") or
            std.mem.eql(u8, ext, ".py"))
        {
            return "script";
        }

        // Direct mapping for extensions that match icon names
        if (std.mem.eql(u8, ext, ".png")) return "png";
        if (std.mem.eql(u8, ext, ".obj")) return "obj";

        // No specific icon
        return null;
    }

    fn tryLoadIconForEntry(self: *AssetBrowserPanel, mgr: *texture_manager.TextureManager, entry: DirectoryEntry) ?c.ImTextureID {
        const cwd = std.fs.cwd();

        // Try to load icon file from assets/icons/
        if (entry.is_directory) {
            const folder_path = "assets/icons/folder.png";
            // Try to load the icon file; if it exists, use it
            if (cwd.access(folder_path, .{})) {
                const tex_id = mgr.loadTexture(folder_path) catch |err| {
                    log(.WARN, "AssetBrowser", "Failed to load folder icon: {}", .{err});
                    return getDefaultIconID(mgr, "icon_folder", .{ 100, 149, 237, 255 });
                };
                return tex_id;
            } else |_| {
                return getDefaultIconID(mgr, "icon_folder", .{ 100, 149, 237, 255 });
            }
        }

        // Extension-specific icon file
        if (entry.extension) |ext| {

            // Try mapped icon name first (e.g., .vert -> shader.png)
            if (getIconNameForExtension(ext)) |icon_name| {
                const icon_path = std.fmt.allocPrint(self.allocator, "assets/icons/{s}.png", .{icon_name}) catch null;
                if (icon_path) |p| {
                    defer self.allocator.free(p);
                    if (cwd.access(p, .{})) {
                        const tex_id = mgr.loadTexture(p) catch |load_err| {
                            log(.WARN, "AssetBrowser", "Failed to load mapped icon {s}: {}", .{ p, load_err });
                            return null;
                        };
                        return tex_id;
                    } else |_| {
                        // mapped icon not found
                    }
                }
            }

            // Try direct extension match (e.g., .png -> png.png)
            if (ext.len > 0 and ext[0] == '.') {
                const ext_no_dot = ext[1..];
                const icon_path = std.fmt.allocPrint(self.allocator, "assets/icons/{s}.png", .{ext_no_dot}) catch null;
                if (icon_path) |p| {
                    defer self.allocator.free(p);
                    if (cwd.access(p, .{})) {
                        const tex_id = mgr.loadTexture(p) catch |load_err| {
                            log(.WARN, "AssetBrowser", "Failed to load extension icon {s}: {}", .{ p, load_err });
                            return null;
                        };
                        return tex_id;
                    } else |_| {
                        // direct extension icon not found
                    }
                }
            }

            // Grouped fallbacks with generated icons - DISABLED FOR TESTING
            // skipping generated icon fallback for entry
            // if (isImageFile(ext)) return getDefaultIconID(mgr, "icon_image", .{ 200, 120, 0, 255 });
            // if (isModelFile(ext)) return getDefaultIconID(mgr, "icon_model", .{ 120, 200, 120, 255 });
            // if (isShaderFile(ext)) return getDefaultIconID(mgr, "icon_shader", .{ 220, 220, 50, 255 });
        }

        // skipping default file icon for entry
        // return getDefaultIconID(mgr, "icon_file", .{ 160, 160, 160, 255 });
        return null; // Return null instead of generated icon
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
