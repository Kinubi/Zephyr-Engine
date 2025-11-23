const std = @import("std");

pub const MaterialSet = struct {
    pub const json_name = "MaterialSet";
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
    pub fn jsonSerialize(self: MaterialSet, serializer: anytype, writer: anytype) !void {
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

    /// Deserialize MaterialSet component
    pub fn deserialize(serializer: anytype, value: std.json.Value) !MaterialSet {
        _ = serializer;
        var ms = MaterialSet.initOpaque();
        
        if (value.object.get("set_name")) |val| {
            if (val == .string) {
                if (std.mem.eql(u8, val.string, "opaque")) {
                    ms.set_name = "opaque";
                } else if (std.mem.eql(u8, val.string, "transparent")) {
                    ms.set_name = "transparent";
                } else if (std.mem.eql(u8, val.string, "masked")) {
                    ms.set_name = "masked";
                } else {
                    std.log.warn("Unknown material set name: {s}. Defaulting to 'opaque'.", .{val.string});
                    ms.set_name = "opaque";
                }
            }
        }
        
        if (value.object.get("shader_variant")) |val| {
            if (val == .string) {
                if (std.mem.eql(u8, val.string, "pbr_standard")) {
                    ms.shader_variant = "pbr_standard";
                } else if (std.mem.eql(u8, val.string, "unlit")) {
                    ms.shader_variant = "unlit";
                } else {
                    std.log.warn("Unknown shader variant: {s}. Defaulting to 'pbr_standard'.", .{val.string});
                    ms.shader_variant = "pbr_standard";
                }
            }
        }
        
        if (value.object.get("casts_shadows")) |val| {
            if (val == .bool) ms.casts_shadows = val.bool;
        }
        
        if (value.object.get("receives_shadows")) |val| {
            if (val == .bool) ms.receives_shadows = val.bool;
        }
        
        if (value.object.get("alpha_cutoff")) |val| {
            if (val == .float) ms.alpha_cutoff = @floatCast(val.float);
        }
        
        return ms;
    }
};
