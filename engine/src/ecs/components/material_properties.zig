const std = @import("std");
const AssetId = @import("../../assets/asset_types.zig").AssetId;

/// Albedo (base color) material component
/// Defines the diffuse color of a surface
pub const AlbedoMaterial = struct {
    pub const json_name = "AlbedoMaterial";
    /// Albedo texture asset
    texture_id: AssetId,

    /// Color tint multiplied with texture (RGBA)
    /// Can be used for vertex colors or to tint the texture
    color_tint: [4]f32 = [_]f32{ 1.0, 1.0, 1.0, 1.0 },

    /// Create with texture only (white tint)
    pub fn init(texture: AssetId) AlbedoMaterial {
        return .{
            .texture_id = texture,
            .color_tint = [_]f32{ 1.0, 1.0, 1.0, 1.0 },
        };
    }

    /// Create with texture and color tint
    pub fn initWithTint(texture: AssetId, tint: [4]f32) AlbedoMaterial {
        return .{
            .texture_id = texture,
            .color_tint = tint,
        };
    }

    /// Create with solid color (no texture)
    pub fn initColor(color: [4]f32) AlbedoMaterial {
        return .{
            .texture_id = AssetId.invalid,
            .color_tint = color,
        };
    }

    /// Serialize AlbedoMaterial component
    pub fn jsonSerialize(self: AlbedoMaterial, serializer: anytype, writer: anytype) !void {
        try writer.beginObject();
        
        if (self.texture_id.isValid()) {
            if (serializer.getAssetPath(self.texture_id)) |path| {
                try writer.objectField("texture");
                try writer.write(path);
            }
        }
        
        try writer.objectField("color");
        try writer.write(self.color_tint);
        
        try writer.endObject();
    }

    /// Deserialize AlbedoMaterial component
    pub fn deserialize(serializer: anytype, value: std.json.Value) !AlbedoMaterial {
        var mat = AlbedoMaterial.initColor([_]f32{1, 1, 1, 1});
        
        if (value.object.get("texture")) |path_val| {
            if (path_val == .string) {
                if (serializer.loadTexture(path_val.string) catch null) |id| {
                    mat.texture_id = id;
                }
            }
        }
        
        if (value.object.get("color")) |val| {
            const parsed = try std.json.parseFromValue([4]f32, serializer.allocator, val, .{});
            mat.color_tint = parsed.value;
            parsed.deinit();
        }
        
        return mat;
    }
};

/// Roughness material component
/// Defines how rough/smooth a surface is (0 = smooth mirror, 1 = rough diffuse)
pub const RoughnessMaterial = struct {
    pub const json_name = "RoughnessMaterial";
    /// Roughness texture asset (R channel used)
    texture_id: AssetId,

    /// Roughness factor (multiplied with texture)
    /// 0.0 = perfectly smooth (mirror), 1.0 = fully rough (diffuse)
    factor: f32 = 0.5,

    /// Create with texture and default factor
    pub fn init(texture: AssetId) RoughnessMaterial {
        return .{
            .texture_id = texture,
            .factor = 0.5,
        };
    }

    /// Create with texture and custom factor
    pub fn initWithFactor(texture: AssetId, factor: f32) RoughnessMaterial {
        return .{
            .texture_id = texture,
            .factor = factor,
        };
    }

    /// Create with constant roughness (no texture)
    pub fn initConstant(factor: f32) RoughnessMaterial {
        return .{
            .texture_id = AssetId.invalid,
            .factor = factor,
        };
    }

    /// Serialize RoughnessMaterial component
    pub fn jsonSerialize(self: RoughnessMaterial, serializer: anytype, writer: anytype) !void {
        try writer.beginObject();
        
        if (self.texture_id.isValid()) {
            if (serializer.getAssetPath(self.texture_id)) |path| {
                try writer.objectField("texture");
                try writer.write(path);
            }
        }
        
        try writer.objectField("factor");
        try writer.write(self.factor);
        
        try writer.endObject();
    }

    /// Deserialize RoughnessMaterial component
    pub fn deserialize(serializer: anytype, value: std.json.Value) !RoughnessMaterial {
        var mat = RoughnessMaterial.initConstant(0.5);
        
        if (value.object.get("texture")) |path_val| {
            if (path_val == .string) {
                if (serializer.loadTexture(path_val.string) catch null) |id| {
                    mat.texture_id = id;
                }
            }
        }
        
        if (value.object.get("factor")) |val| {
            if (val == .float) mat.factor = @floatCast(val.float);
        }
        
        return mat;
    }
};

/// Metallic material component
/// Defines how metallic a surface is (0 = dielectric, 1 = metal)
pub const MetallicMaterial = struct {
    pub const json_name = "MetallicMaterial";
    /// Metallic texture asset (R channel used)
    texture_id: AssetId,

    /// Metallic factor (multiplied with texture)
    /// 0.0 = non-metal (dielectric), 1.0 = pure metal
    factor: f32 = 0.0,

    /// Create with texture and default factor
    pub fn init(texture: AssetId) MetallicMaterial {
        return .{
            .texture_id = texture,
            .factor = 0.0,
        };
    }

    /// Create with texture and custom factor
    pub fn initWithFactor(texture: AssetId, factor: f32) MetallicMaterial {
        return .{
            .texture_id = texture,
            .factor = factor,
        };
    }

    /// Create with constant metallic (no texture)
    pub fn initConstant(factor: f32) MetallicMaterial {
        return .{
            .texture_id = AssetId.invalid,
            .factor = factor,
        };
    }

    /// Serialize MetallicMaterial component
    pub fn jsonSerialize(self: MetallicMaterial, serializer: anytype, writer: anytype) !void {
        try writer.beginObject();
        
        if (self.texture_id.isValid()) {
            if (serializer.getAssetPath(self.texture_id)) |path| {
                try writer.objectField("texture");
                try writer.write(path);
            }
        }
        
        try writer.objectField("factor");
        try writer.write(self.factor);
        
        try writer.endObject();
    }

    /// Deserialize MetallicMaterial component
    pub fn deserialize(serializer: anytype, value: std.json.Value) !MetallicMaterial {
        var mat = MetallicMaterial.initConstant(0.0);
        
        if (value.object.get("texture")) |path_val| {
            if (path_val == .string) {
                if (serializer.loadTexture(path_val.string) catch null) |id| {
                    mat.texture_id = id;
                }
            }
        }
        
        if (value.object.get("factor")) |val| {
            if (val == .float) mat.factor = @floatCast(val.float);
        }
        
        return mat;
    }
};

/// Normal map material component
/// Defines surface normal perturbation for detail
pub const NormalMaterial = struct {
    pub const json_name = "NormalMaterial";
    /// Normal map texture asset (RGB channels in tangent space)
    texture_id: AssetId,

    /// Normal strength (how much the normal map affects the surface)
    /// 0.0 = no effect, 1.0 = full effect, >1.0 = exaggerated
    strength: f32 = 1.0,

    /// Create with texture and default strength
    pub fn init(texture: AssetId) NormalMaterial {
        return .{
            .texture_id = texture,
            .strength = 1.0,
        };
    }

    /// Create with texture and custom strength
    pub fn initWithStrength(texture: AssetId, strength: f32) NormalMaterial {
        return .{
            .texture_id = texture,
            .strength = strength,
        };
    }

    /// Serialize NormalMaterial component
    pub fn jsonSerialize(self: NormalMaterial, serializer: anytype, writer: anytype) !void {
        try writer.beginObject();
        
        if (self.texture_id.isValid()) {
            if (serializer.getAssetPath(self.texture_id)) |path| {
                try writer.objectField("texture");
                try writer.write(path);
            }
        }
        
        try writer.objectField("strength");
        try writer.write(self.strength);
        
        try writer.endObject();
    }

    /// Deserialize NormalMaterial component
    pub fn deserialize(serializer: anytype, value: std.json.Value) !NormalMaterial {
        var mat = NormalMaterial.initWithStrength(AssetId.invalid, 1.0);
        
        if (value.object.get("texture")) |path_val| {
            if (path_val == .string) {
                if (serializer.loadTexture(path_val.string) catch null) |id| {
                    mat.texture_id = id;
                }
            }
        }
        
        if (value.object.get("strength")) |val| {
            if (val == .float) mat.strength = @floatCast(val.float);
        }
        
        return mat;
    }
};

/// Emissive material component
/// Defines self-illumination (glow)
pub const EmissiveMaterial = struct {
    pub const json_name = "EmissiveMaterial";
    /// Emissive texture asset (RGB channels)
    texture_id: AssetId,

    /// Emissive color (multiplied with texture)
    color: [3]f32 = [_]f32{ 1.0, 1.0, 1.0 },

    /// Emissive intensity multiplier
    /// 0.0 = no emission, 1.0 = standard, >1.0 = HDR glow
    intensity: f32 = 1.0,

    /// Create with texture and default parameters
    pub fn init(texture: AssetId) EmissiveMaterial {
        return .{
            .texture_id = texture,
            .color = [_]f32{ 1.0, 1.0, 1.0 },
            .intensity = 1.0,
        };
    }

    /// Create with texture, color, and intensity
    pub fn initFull(texture: AssetId, color: [3]f32, intensity: f32) EmissiveMaterial {
        return .{
            .texture_id = texture,
            .color = color,
            .intensity = intensity,
        };
    }

    /// Create with solid color (no texture)
    pub fn initColor(color: [3]f32, intensity: f32) EmissiveMaterial {
        return .{
            .texture_id = AssetId.invalid,
            .color = color,
            .intensity = intensity,
        };
    }

    /// Serialize EmissiveMaterial component
    pub fn jsonSerialize(self: EmissiveMaterial, serializer: anytype, writer: anytype) !void {
        try writer.beginObject();
        
        if (self.texture_id.isValid()) {
            if (serializer.getAssetPath(self.texture_id)) |path| {
                try writer.objectField("texture");
                try writer.write(path);
            }
        }
        
        try writer.objectField("color");
        try writer.write(self.color);
        
        try writer.objectField("intensity");
        try writer.write(self.intensity);
        
        try writer.endObject();
    }

    /// Deserialize EmissiveMaterial component
    pub fn deserialize(serializer: anytype, value: std.json.Value) !EmissiveMaterial {
        var mat = EmissiveMaterial.initColor([_]f32{0, 0, 0}, 1.0);
        
        if (value.object.get("texture")) |path_val| {
            if (path_val == .string) {
                if (serializer.loadTexture(path_val.string) catch null) |id| {
                    mat.texture_id = id;
                }
            }
        }
        
        if (value.object.get("color")) |val| {
            const parsed = try std.json.parseFromValue([3]f32, serializer.allocator, val, .{});
            mat.color = parsed.value;
            parsed.deinit();
        }
        
        if (value.object.get("intensity")) |val| {
            if (val == .float) mat.intensity = @floatCast(val.float);
        }
        
        return mat;
    }
};

/// Occlusion material component (optional)
/// Defines ambient occlusion baked into texture
pub const OcclusionMaterial = struct {
    pub const json_name = "OcclusionMaterial";
    /// Occlusion texture asset (R channel used)
    texture_id: AssetId,

    /// Occlusion strength
    /// 0.0 = no occlusion, 1.0 = full occlusion
    strength: f32 = 1.0,

    pub fn init(texture: AssetId) OcclusionMaterial {
        return .{
            .texture_id = texture,
            .strength = 1.0,
        };
    }

    /// Serialize OcclusionMaterial component
    pub fn jsonSerialize(self: OcclusionMaterial, serializer: anytype, writer: anytype) !void {
        try writer.beginObject();
        
        if (self.texture_id.isValid()) {
            if (serializer.getAssetPath(self.texture_id)) |path| {
                try writer.objectField("texture");
                try writer.write(path);
            }
        }
        
        try writer.objectField("strength");
        try writer.write(self.strength);
        
        try writer.endObject();
    }

    /// Deserialize OcclusionMaterial component
    pub fn deserialize(serializer: anytype, value: std.json.Value) !OcclusionMaterial {
        var mat = OcclusionMaterial.init(AssetId.invalid);
        
        if (value.object.get("texture")) |path_val| {
            if (path_val == .string) {
                if (serializer.loadTexture(path_val.string) catch null) |id| {
                    mat.texture_id = id;
                }
            }
        }
        
        if (value.object.get("strength")) |val| {
            if (val == .float) mat.strength = @floatCast(val.float);
        }
        
        return mat;
    }
};
