const std = @import("std");
const zphysics = @import("zphysics");
const AssetId = @import("../../assets/asset_types.zig").AssetId;

pub const BodyType = enum {
    Static,
    Kinematic,
    Dynamic,
};

pub const ShapeType = enum {
    Box,
    Sphere,
    Capsule,
    Mesh,
};

pub const RigidBody = struct {
    pub const json_name = "RigidBody";
    body_type: BodyType = .Dynamic,
    mass: f32 = 1.0,
    friction: f32 = 0.5,
    restitution: f32 = 0.0,
    linear_damping: f32 = 0.05,
    angular_damping: f32 = 0.05,
    is_sensor: bool = false,

    // Runtime handle to the Jolt body
    body_id: zphysics.BodyId = .invalid,

    pub fn jsonSerialize(self: RigidBody, serializer: anytype, writer: anytype) !void {
        _ = serializer;
        try writer.beginObject();
        try writer.objectField("body_type");
        try writer.write(@tagName(self.body_type));
        try writer.objectField("mass");
        try writer.write(self.mass);
        try writer.objectField("friction");
        try writer.write(self.friction);
        try writer.objectField("restitution");
        try writer.write(self.restitution);
        try writer.objectField("linear_damping");
        try writer.write(self.linear_damping);
        try writer.objectField("angular_damping");
        try writer.write(self.angular_damping);
        try writer.objectField("is_sensor");
        try writer.write(self.is_sensor);
        try writer.endObject();
    }

    pub fn deserialize(serializer: anytype, value: std.json.Value) !RigidBody {
        _ = serializer;
        var rb = RigidBody{};
        if (value.object.get("body_type")) |v| {
            if (std.meta.stringToEnum(BodyType, v.string)) |bt| {
                rb.body_type = bt;
            }
        }
        if (value.object.get("mass")) |v| {
            rb.mass = @floatCast(if (v == .float) v.float else @as(f64, @floatFromInt(v.integer)));
        }
        if (value.object.get("friction")) |v| {
            rb.friction = @floatCast(if (v == .float) v.float else @as(f64, @floatFromInt(v.integer)));
        }
        if (value.object.get("restitution")) |v| {
            rb.restitution = @floatCast(if (v == .float) v.float else @as(f64, @floatFromInt(v.integer)));
        }
        if (value.object.get("linear_damping")) |v| {
            rb.linear_damping = @floatCast(if (v == .float) v.float else @as(f64, @floatFromInt(v.integer)));
        }
        if (value.object.get("angular_damping")) |v| {
            rb.angular_damping = @floatCast(if (v == .float) v.float else @as(f64, @floatFromInt(v.integer)));
        }
        if (value.object.get("is_sensor")) |v| {
            rb.is_sensor = v.bool;
        }
        return rb;
    }
};

pub const BoxCollider = struct {
    pub const json_name = "BoxCollider";
    half_extents: [3]f32 = .{ 0.5, 0.5, 0.5 },
    offset: [3]f32 = .{ 0.0, 0.0, 0.0 },

    pub fn jsonSerialize(self: BoxCollider, serializer: anytype, writer: anytype) !void {
        _ = serializer;
        try writer.beginObject();
        try writer.objectField("half_extents");
        try writer.beginArray();
        try writer.write(self.half_extents[0]);
        try writer.write(self.half_extents[1]);
        try writer.write(self.half_extents[2]);
        try writer.endArray();
        try writer.objectField("offset");
        try writer.beginArray();
        try writer.write(self.offset[0]);
        try writer.write(self.offset[1]);
        try writer.write(self.offset[2]);
        try writer.endArray();
        try writer.endObject();
    }

    pub fn deserialize(serializer: anytype, value: std.json.Value) !BoxCollider {
        _ = serializer;
        var bc = BoxCollider{};
        if (value.object.get("half_extents")) |v| {
            if (v == .array and v.array.items.len == 3) {
                bc.half_extents[0] = @floatCast(if (v.array.items[0] == .float) v.array.items[0].float else @as(f64, @floatFromInt(v.array.items[0].integer)));
                bc.half_extents[1] = @floatCast(if (v.array.items[1] == .float) v.array.items[1].float else @as(f64, @floatFromInt(v.array.items[1].integer)));
                bc.half_extents[2] = @floatCast(if (v.array.items[2] == .float) v.array.items[2].float else @as(f64, @floatFromInt(v.array.items[2].integer)));
            }
        }
        if (value.object.get("offset")) |v| {
            if (v == .array and v.array.items.len == 3) {
                bc.offset[0] = @floatCast(if (v.array.items[0] == .float) v.array.items[0].float else @as(f64, @floatFromInt(v.array.items[0].integer)));
                bc.offset[1] = @floatCast(if (v.array.items[1] == .float) v.array.items[1].float else @as(f64, @floatFromInt(v.array.items[1].integer)));
                bc.offset[2] = @floatCast(if (v.array.items[2] == .float) v.array.items[2].float else @as(f64, @floatFromInt(v.array.items[2].integer)));
            }
        }
        return bc;
    }
};

pub const SphereCollider = struct {
    pub const json_name = "SphereCollider";
    radius: f32 = 0.5,
    offset: [3]f32 = .{ 0.0, 0.0, 0.0 },

    pub fn jsonSerialize(self: SphereCollider, serializer: anytype, writer: anytype) !void {
        _ = serializer;
        try writer.beginObject();
        try writer.objectField("radius");
        try writer.write(self.radius);
        try writer.objectField("offset");
        try writer.beginArray();
        try writer.write(self.offset[0]);
        try writer.write(self.offset[1]);
        try writer.write(self.offset[2]);
        try writer.endArray();
        try writer.endObject();
    }

    pub fn deserialize(serializer: anytype, value: std.json.Value) !SphereCollider {
        _ = serializer;
        var sc = SphereCollider{};
        if (value.object.get("radius")) |v| {
            sc.radius = @floatCast(if (v == .float) v.float else @as(f64, @floatFromInt(v.integer)));
        }
        if (value.object.get("offset")) |v| {
            if (v == .array and v.array.items.len == 3) {
                sc.offset[0] = @floatCast(if (v.array.items[0] == .float) v.array.items[0].float else @as(f64, @floatFromInt(v.array.items[0].integer)));
                sc.offset[1] = @floatCast(if (v.array.items[1] == .float) v.array.items[1].float else @as(f64, @floatFromInt(v.array.items[1].integer)));
                sc.offset[2] = @floatCast(if (v.array.items[2] == .float) v.array.items[2].float else @as(f64, @floatFromInt(v.array.items[2].integer)));
            }
        }
        return sc;
    }
};

pub const CapsuleCollider = struct {
    pub const json_name = "CapsuleCollider";
    radius: f32 = 0.5,
    height: f32 = 1.0,
    offset: [3]f32 = .{ 0.0, 0.0, 0.0 },

    pub fn jsonSerialize(self: CapsuleCollider, serializer: anytype, writer: anytype) !void {
        _ = serializer;
        try writer.beginObject();
        try writer.objectField("radius");
        try writer.write(self.radius);
        try writer.objectField("height");
        try writer.write(self.height);
        try writer.objectField("offset");
        try writer.beginArray();
        try writer.write(self.offset[0]);
        try writer.write(self.offset[1]);
        try writer.write(self.offset[2]);
        try writer.endArray();
        try writer.endObject();
    }

    pub fn deserialize(serializer: anytype, value: std.json.Value) !CapsuleCollider {
        _ = serializer;
        var cc = CapsuleCollider{};
        if (value.object.get("radius")) |v| {
            cc.radius = @floatCast(if (v == .float) v.float else @as(f64, @floatFromInt(v.integer)));
        }
        if (value.object.get("height")) |v| {
            cc.height = @floatCast(if (v == .float) v.float else @as(f64, @floatFromInt(v.integer)));
        }
        if (value.object.get("offset")) |v| {
            if (v == .array and v.array.items.len == 3) {
                cc.offset[0] = @floatCast(if (v.array.items[0] == .float) v.array.items[0].float else @as(f64, @floatFromInt(v.array.items[0].integer)));
                cc.offset[1] = @floatCast(if (v.array.items[1] == .float) v.array.items[1].float else @as(f64, @floatFromInt(v.array.items[1].integer)));
                cc.offset[2] = @floatCast(if (v.array.items[2] == .float) v.array.items[2].float else @as(f64, @floatFromInt(v.array.items[2].integer)));
            }
        }
        return cc;
    }
};

pub const MeshCollider = struct {
    pub const json_name = "MeshCollider";
    // Asset ID for the mesh to use as collider
    mesh_asset_id: AssetId = .invalid,
    convex: bool = true,

    pub fn jsonSerialize(self: MeshCollider, serializer: anytype, writer: anytype) !void {
        try writer.beginObject();
        try writer.objectField("convex");
        try writer.write(self.convex);

        if (serializer.getAssetPath(self.mesh_asset_id)) |path| {
            try writer.objectField("mesh_path");
            try writer.write(path);
        }
        try writer.endObject();
    }

    pub fn deserialize(serializer: anytype, value: std.json.Value) !MeshCollider {
        var mc = MeshCollider{};
        if (value.object.get("convex")) |v| {
            mc.convex = v.bool;
        }
        if (value.object.get("mesh_path")) |v| {
            if (v == .string) {
                // Try to load or get asset ID
                // For now, we assume it's already loaded or we can get ID
                // But SceneSerializer.loadModel is async.
                // For physics, we might need it immediately?
                // Or we just store the ID and let the system handle it.
                // SceneSerializer.loadModel returns !AssetId
                if (serializer.loadModel(v.string)) |id| {
                    mc.mesh_asset_id = id;
                } else |_| {
                    // Failed to load, maybe log?
                }
            }
        }
        return mc;
    }
};
