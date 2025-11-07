const AssetId = @import("../../assets/asset_types.zig").AssetId;

/// Albedo (base color) material component
/// Defines the diffuse color of a surface
pub const AlbedoMaterial = struct {
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
};

/// Roughness material component
/// Defines how rough/smooth a surface is (0 = smooth mirror, 1 = rough diffuse)
pub const RoughnessMaterial = struct {
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
};

/// Metallic material component
/// Defines how metallic a surface is (0 = dielectric, 1 = metal)
pub const MetallicMaterial = struct {
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
};

/// Normal map material component
/// Defines surface normal perturbation for detail
pub const NormalMaterial = struct {
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
};

/// Emissive material component
/// Defines self-illumination (glow)
pub const EmissiveMaterial = struct {
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
};

/// Occlusion material component (optional)
/// Defines ambient occlusion baked into texture
pub const OcclusionMaterial = struct {
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
};
