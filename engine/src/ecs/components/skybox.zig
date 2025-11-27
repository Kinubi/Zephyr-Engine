const std = @import("std");
const Math = @import("../../utils/math.zig");

/// Skybox component for ECS entities
/// Represents an environment skybox using either a cubemap or equirectangular HDRI
/// Only one skybox should be active in a scene at a time
pub const Skybox = struct {
    pub const json_name = "Skybox";

    /// Source type for the skybox
    pub const SourceType = enum {
        /// 6-face cubemap (right, left, top, bottom, front, back)
        cubemap,
        /// Single equirectangular HDRI image
        equirectangular,
        /// Procedural sky (no texture needed)
        procedural,
    };

    /// The type of skybox source
    source_type: SourceType = .equirectangular,

    /// Path to the HDRI/cubemap texture(s)
    /// For equirectangular: single path like "assets/textures/skybox.hdr"
    /// For cubemap: base path, faces loaded as path_right.png, path_left.png, etc.
    texture_path: [256]u8 = std.mem.zeroes([256]u8),
    texture_path_len: u16 = 0,

    /// Rotation of the skybox around Y axis (in radians)
    rotation: f32 = 0.0,

    /// Exposure/brightness multiplier
    exposure: f32 = 1.0,

    /// Tint color (multiplied with skybox color)
    tint: Math.Vec3 = Math.Vec3.init(1.0, 1.0, 1.0),

    /// Whether this skybox is active/enabled
    is_active: bool = true,

    /// Whether the texture path has been confirmed (user pressed Enter)
    /// Texture only loads when this is true
    path_confirmed: bool = false,

    /// Blur level for reflections (0 = sharp, 1 = fully blurred)
    /// Used when generating IBL reflection maps
    blur_level: f32 = 0.0,

    // Procedural sky settings
    /// Sun direction for procedural sky (normalized)
    sun_direction: Math.Vec3 = Math.Vec3.init(0.0, 1.0, 0.0),

    /// Ground color for procedural sky
    ground_color: Math.Vec3 = Math.Vec3.init(0.3, 0.25, 0.2),

    /// Horizon color for procedural sky
    horizon_color: Math.Vec3 = Math.Vec3.init(0.7, 0.8, 0.9),

    /// Zenith color for procedural sky
    zenith_color: Math.Vec3 = Math.Vec3.init(0.2, 0.4, 0.8),

    // ========================================================================
    // Initialization
    // ========================================================================

    /// Create a default skybox
    pub fn init() Skybox {
        return .{};
    }

    /// Create an equirectangular HDRI skybox
    pub fn initEquirectangular(path: []const u8) Skybox {
        var skybox = Skybox{
            .source_type = .equirectangular,
        };
        skybox.setTexturePath(path);
        return skybox;
    }

    /// Create a cubemap skybox
    pub fn initCubemap(base_path: []const u8) Skybox {
        var skybox = Skybox{
            .source_type = .cubemap,
        };
        skybox.setTexturePath(base_path);
        return skybox;
    }

    /// Create a procedural sky
    pub fn initProcedural() Skybox {
        return Skybox{
            .source_type = .procedural,
            .is_active = true,
        };
    }

    // ========================================================================
    // Utility Methods
    // ========================================================================

    /// Set the texture path (does not trigger load - user must confirm with Enter)
    pub fn setTexturePath(self: *Skybox, path: []const u8) void {
        const len = @min(path.len, self.texture_path.len);
        @memcpy(self.texture_path[0..len], path[0..len]);
        self.texture_path_len = @intCast(len);
        // Reset confirmation when path changes
        self.path_confirmed = false;
    }

    /// Confirm the texture path (triggers actual load)
    pub fn confirmTexturePath(self: *Skybox) void {
        self.path_confirmed = true;
    }

    /// Get the texture path as a slice
    pub fn getTexturePath(self: *const Skybox) []const u8 {
        return self.texture_path[0..self.texture_path_len];
    }

    /// Set sun direction from angles (for procedural sky)
    pub fn setSunFromAngles(self: *Skybox, azimuth: f32, elevation: f32) void {
        const cos_elev = @cos(elevation);
        self.sun_direction = Math.Vec3.init(
            @cos(azimuth) * cos_elev,
            @sin(elevation),
            @sin(azimuth) * cos_elev,
        ).normalize();
    }

    // ========================================================================
    // Serialization
    // ========================================================================

    /// Serialize Skybox component
    pub fn jsonSerialize(self: Skybox, serializer: anytype, writer: anytype) !void {
        _ = serializer;
        try writer.beginObject();

        try writer.objectField("source_type");
        try writer.write(@tagName(self.source_type));

        try writer.objectField("texture_path");
        try writer.write(self.getTexturePath());

        try writer.objectField("rotation");
        try writer.write(self.rotation);

        try writer.objectField("exposure");
        try writer.write(self.exposure);

        try writer.objectField("tint");
        try writer.write(self.tint);

        try writer.objectField("is_active");
        try writer.write(self.is_active);

        try writer.objectField("path_confirmed");
        try writer.write(self.path_confirmed);

        // Procedural sky settings
        if (self.source_type == .procedural) {
            try writer.objectField("sun_direction");
            try writer.write(self.sun_direction);

            try writer.objectField("ground_color");
            try writer.write(self.ground_color);

            try writer.objectField("horizon_color");
            try writer.write(self.horizon_color);

            try writer.objectField("zenith_color");
            try writer.write(self.zenith_color);
        }

        try writer.endObject();
    }

    /// Deserialize Skybox component
    pub fn deserialize(serializer: anytype, value: std.json.Value) !Skybox {
        var skybox = Skybox.init();

        if (value != .object) return skybox;

        // Source type
        if (value.object.get("source_type")) |v| {
            if (v == .string) {
                if (std.mem.eql(u8, v.string, "cubemap")) {
                    skybox.source_type = .cubemap;
                } else if (std.mem.eql(u8, v.string, "procedural")) {
                    skybox.source_type = .procedural;
                } else {
                    skybox.source_type = .equirectangular;
                }
            }
        }

        // Texture path
        if (value.object.get("texture_path")) |v| {
            if (v == .string) {
                skybox.setTexturePath(v.string);
            }
        }

        // Rotation
        if (value.object.get("rotation")) |v| {
            skybox.rotation = switch (v) {
                .float => @floatCast(v.float),
                .integer => @floatFromInt(v.integer),
                else => skybox.rotation,
            };
        }

        // Exposure
        if (value.object.get("exposure")) |v| {
            skybox.exposure = switch (v) {
                .float => @floatCast(v.float),
                .integer => @floatFromInt(v.integer),
                else => skybox.exposure,
            };
        }

        // Tint
        if (value.object.get("tint")) |v| {
            const parsed = try std.json.parseFromValue(Math.Vec3, serializer.allocator, v, .{});
            skybox.tint = parsed.value;
            parsed.deinit();
        }

        // Is active
        if (value.object.get("is_active")) |v| {
            if (v == .bool) {
                skybox.is_active = v.bool;
            }
        }

        // Path confirmed (texture loads immediately if true)
        if (value.object.get("path_confirmed")) |v| {
            if (v == .bool) {
                skybox.path_confirmed = v.bool;
            }
        }

        // Procedural sky settings
        if (value.object.get("sun_direction")) |v| {
            const parsed = try std.json.parseFromValue(Math.Vec3, serializer.allocator, v, .{});
            skybox.sun_direction = parsed.value;
            parsed.deinit();
        }
        if (value.object.get("ground_color")) |v| {
            const parsed = try std.json.parseFromValue(Math.Vec3, serializer.allocator, v, .{});
            skybox.ground_color = parsed.value;
            parsed.deinit();
        }
        if (value.object.get("horizon_color")) |v| {
            const parsed = try std.json.parseFromValue(Math.Vec3, serializer.allocator, v, .{});
            skybox.horizon_color = parsed.value;
            parsed.deinit();
        }
        if (value.object.get("zenith_color")) |v| {
            const parsed = try std.json.parseFromValue(Math.Vec3, serializer.allocator, v, .{});
            skybox.zenith_color = parsed.value;
            parsed.deinit();
        }

        return skybox;
    }
};
