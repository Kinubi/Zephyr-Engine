const std = @import("std");

pub const MaterialSet = struct {
    set_name: []const u8 = "opaque", // Name of the material set this entity belongs to
    shader_variant: []const u8 = "pbr_standard",
    material_buffer_index: u32 = 0,
    casts_shadows: bool = true,
    receives_shadows: bool = true,
    alpha_cutoff: f32 = 0.5,

    pub fn initOpaque() MaterialSet {
        return .{ .set_name = "opaque", .shader_variant = "pbr_standard" };
    }

    pub fn initTransparent() MaterialSet {
        return .{ .set_name = "transparent", .shader_variant = "pbr_standard", .casts_shadows = false };
    }

    pub fn initUnlit() MaterialSet {
        return .{ .set_name = "opaque", .shader_variant = "unlit", .casts_shadows = false, .receives_shadows = false };
    }

    pub fn initMasked(alpha_cutoff: f32) MaterialSet {
        return .{ .set_name = "masked", .shader_variant = "pbr_standard", .alpha_cutoff = alpha_cutoff };
    }

    /// Serialize MaterialSet component
    pub fn serialize(self: MaterialSet, serializer: anytype, writer: anytype) !void {
        _ = serializer;
        try writer.beginObject();
        
        try writer.objectField("set_name");
        try writer.write(self.set_name);
        
        try writer.objectField("shader_variant");
        try writer.write(self.shader_variant);
        
        try writer.objectField("casts_shadows");
        try writer.write(self.casts_shadows);
        
        try writer.objectField("receives_shadows");
        try writer.write(self.receives_shadows);
        
        try writer.objectField("alpha_cutoff");
        try writer.write(self.alpha_cutoff);
        
        try writer.endObject();
    }
};
