const std = @import("std");
const zphysics = @import("zphysics");

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
    body_type: BodyType = .Dynamic,
    mass: f32 = 1.0,
    friction: f32 = 0.5,
    restitution: f32 = 0.0,
    linear_damping: f32 = 0.05,
    angular_damping: f32 = 0.05,
    is_sensor: bool = false,

    // Runtime handle to the Jolt body
    body_id: zphysics.BodyId = .invalid,
};

pub const BoxCollider = struct {
    half_extents: [3]f32 = .{ 0.5, 0.5, 0.5 },
    offset: [3]f32 = .{ 0.0, 0.0, 0.0 },
};

pub const SphereCollider = struct {
    radius: f32 = 0.5,
    offset: [3]f32 = .{ 0.0, 0.0, 0.0 },
};

pub const CapsuleCollider = struct {
    radius: f32 = 0.5,
    height: f32 = 1.0,
    offset: [3]f32 = .{ 0.0, 0.0, 0.0 },
};

pub const MeshCollider = struct {
    // Asset ID for the mesh to use as collider
    mesh_asset_id: u32 = 0,
    convex: bool = true,
};
