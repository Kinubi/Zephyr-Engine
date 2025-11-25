const std = @import("std");
const zphysics = @import("zphysics");
const World = @import("../world.zig").World;
const FrameInfo = @import("../../rendering/frameinfo.zig").FrameInfo;
const Transform = @import("../components/transform.zig").Transform;
const RigidBody = @import("../components/physics_components.zig").RigidBody;
const BoxCollider = @import("../components/physics_components.zig").BoxCollider;
const SphereCollider = @import("../components/physics_components.zig").SphereCollider;
const CapsuleCollider = @import("../components/physics_components.zig").CapsuleCollider;
const MeshCollider = @import("../components/physics_components.zig").MeshCollider;
const Scene = @import("../../scene/scene.zig").Scene;
const log = @import("../../utils/log.zig").log;
const Math = @import("../../utils/math.zig");
const EntityId = @import("../entity_registry.zig").EntityId;

pub const PhysicsSystem = struct {
    allocator: std.mem.Allocator,
    physics_system: *zphysics.PhysicsSystem,
    broad_phase_layer_interface: zphysics.BroadPhaseLayerInterface,
    object_vs_broad_phase_layer_filter: zphysics.ObjectVsBroadPhaseLayerFilter,
    object_layer_pair_filter: zphysics.ObjectLayerPairFilter,
    active_bodies: std.AutoHashMap(EntityId, zphysics.BodyId),

    pub fn init(allocator: std.mem.Allocator) !*PhysicsSystem {
        const self = try allocator.create(PhysicsSystem);
        self.allocator = allocator;

        try zphysics.init(self.allocator, .{});

        // Setup layers
        self.broad_phase_layer_interface = zphysics.BroadPhaseLayerInterface.init(BroadPhaseLayerInterfaceImpl);
        self.object_vs_broad_phase_layer_filter = zphysics.ObjectVsBroadPhaseLayerFilter.init(ObjectVsBroadPhaseLayerFilterImpl);
        self.object_layer_pair_filter = zphysics.ObjectLayerPairFilter.init(ObjectLayerPairFilterImpl);
        self.active_bodies = std.AutoHashMap(EntityId, zphysics.BodyId).init(allocator);

        // Initialize Physics System
        self.physics_system = try zphysics.PhysicsSystem.create(
            &self.broad_phase_layer_interface,
            &self.object_vs_broad_phase_layer_filter,
            &self.object_layer_pair_filter,
            .{
                .max_bodies = 1024,
                .num_body_mutexes = 0, // 0 = default
                .max_body_pairs = 1024,
                .max_contact_constraints = 1024,
            },
        );

        // Set gravity to point down (+Y) because Vulkan uses -Y up
        self.physics_system.setGravity(.{ 0.0, 9.81, 0.0 });

        log(.INFO, "physics_system", "PhysicsSystem initialized", .{});
        return self;
    }

    pub fn deinit(self: *PhysicsSystem) void {
        self.active_bodies.deinit();
        self.physics_system.destroy();

        zphysics.deinit();
        self.allocator.destroy(self);
    }

    pub fn reset(self: *PhysicsSystem) void {
        self.active_bodies.clearRetainingCapacity();

        // Destroy and recreate the physics system to clear all state
        self.physics_system.destroy();
        self.physics_system = zphysics.PhysicsSystem.create(
            &self.broad_phase_layer_interface,
            &self.object_vs_broad_phase_layer_filter,
            &self.object_layer_pair_filter,
            .{
                .max_bodies = 1024,
                .num_body_mutexes = 0,
                .max_body_pairs = 1024,
                .max_contact_constraints = 1024,
            },
        ) catch |err| {
            log(.ERR, "physics_system", "Failed to recreate physics system during reset: {}", .{err});
            @panic("Failed to reset physics system");
        };
        self.physics_system.setGravity(.{ 0.0, 9.81, 0.0 });
    }

    pub fn prepare(self: *PhysicsSystem, world: *World, dt: f32) !void {
        // log(.INFO, "physics_system", "PhysicsSystem prepare start", .{});
        const body_interface = self.physics_system.getBodyInterfaceMut();

        // 1. Sync ECS Transforms -> Physics Bodies (Kinematic/Static) & Create Bodies

        // Track seen entities to detect removals
        var seen_entities = std.AutoHashMap(EntityId, void).init(self.allocator);
        defer seen_entities.deinit();

        var query = try world.query(struct {
            entity: EntityId,
            transform: *Transform,
            body: *RigidBody,
            box: ?*BoxCollider,
            sphere: ?*SphereCollider,
            capsule: ?*CapsuleCollider,
            mesh: ?*MeshCollider,
        });
        defer query.deinit();

        while (query.next()) |data| {
            try seen_entities.put(data.entity, {});

            if (data.body.body_id == .invalid) {
                // Create Shape
                var shape_settings: *zphysics.ShapeSettings = undefined;
                var offset: [3]f32 = .{ 0, 0, 0 };

                if (data.box) |box| {
                    const box_settings = try zphysics.BoxShapeSettings.create(.{ box.half_extents[0], box.half_extents[1], box.half_extents[2] });
                    shape_settings = @ptrCast(box_settings);
                    offset = box.offset;
                } else if (data.sphere) |sphere| {
                    const sphere_settings = try zphysics.SphereShapeSettings.create(sphere.radius);
                    shape_settings = @ptrCast(sphere_settings);
                    offset = sphere.offset;
                } else if (data.capsule) |capsule| {
                    const capsule_settings = try zphysics.CapsuleShapeSettings.create(capsule.height * 0.5, capsule.radius);
                    shape_settings = @ptrCast(capsule_settings);
                    offset = capsule.offset;
                } else if (data.mesh) |mesh| {
                    // TODO: Implement mesh collider creation. This will likely involve
                    // loading mesh data from the asset manager.
                    _ = mesh;
                    log(.WARN, "physics_system", "MeshCollider not yet implemented", .{});
                    continue;
                } else {
                    continue; // No collider
                }

                // Apply offset if needed
                if (offset[0] != 0 or offset[1] != 0 or offset[2] != 0) {
                    const rotated_settings = try zphysics.DecoratedShapeSettings.createRotatedTranslated(
                        shape_settings,
                        .{ 0, 0, 0, 1 }, // Identity rotation
                        .{ offset[0], offset[1], offset[2] },
                    );
                    shape_settings.release(); // Release the child shape settings as the wrapper now holds a reference
                    shape_settings = rotated_settings.asShapeSettings();
                }
                defer shape_settings.release();

                // Create Body Settings
                const motion_type: zphysics.MotionType = switch (data.body.body_type) {
                    .Static => .static,
                    .Kinematic => .kinematic,
                    .Dynamic => .dynamic,
                };

                const object_layer: zphysics.ObjectLayer = if (data.body.body_type == .Static)
                    @intFromEnum(Layers.NonMoving)
                else
                    @intFromEnum(Layers.Moving);

                const shape = try shape_settings.createShape();
                defer shape.release();

                const body_settings = zphysics.BodyCreationSettings{
                    .position = .{ data.transform.position.x, data.transform.position.y, data.transform.position.z, 1.0 },
                    .rotation = .{ data.transform.rotation.x, data.transform.rotation.y, data.transform.rotation.z, data.transform.rotation.w },
                    .motion_type = motion_type,
                    .object_layer = object_layer,
                    .shape = shape,
                    .friction = data.body.friction,
                    .restitution = data.body.restitution,
                    .linear_damping = data.body.linear_damping,
                    .angular_damping = data.body.angular_damping,
                    .is_sensor = data.body.is_sensor,
                };

                // Create Body
                const body_id = try body_interface.createAndAddBody(body_settings, .activate);
                data.body.body_id = body_id;
                try self.active_bodies.put(data.entity, body_id);
            } else {
                // Ensure tracked
                if (!self.active_bodies.contains(data.entity)) {
                    try self.active_bodies.put(data.entity, data.body.body_id);
                }

                // Sync Kinematic
                if (data.body.body_type == .Kinematic) {
                    body_interface.setPosition(data.body.body_id, .{ data.transform.position.x, data.transform.position.y, data.transform.position.z }, .activate);
                    body_interface.setRotation(data.body.body_id, .{ data.transform.rotation.x, data.transform.rotation.y, data.transform.rotation.z, data.transform.rotation.w }, .activate);
                } else if (data.body.body_type == .Dynamic and data.transform.dirty) {
                    // Sync Dynamic if Transform changed externally (e.g. Editor Gizmo)
                    // Check if the transform is significantly different from physics state to avoid feedback loop
                    const phys_pos = body_interface.getPosition(data.body.body_id);
                    const phys_rot = body_interface.getRotation(data.body.body_id);

                    const t_pos = data.transform.position;
                    const t_rot = data.transform.rotation;

                    const dist_sq = (t_pos.x - phys_pos[0]) * (t_pos.x - phys_pos[0]) +
                        (t_pos.y - phys_pos[1]) * (t_pos.y - phys_pos[1]) +
                        (t_pos.z - phys_pos[2]) * (t_pos.z - phys_pos[2]);

                    // Dot product of quaternions: if close to 1 or -1, they are same rotation
                    const rot_dot = t_rot.x * phys_rot[0] + t_rot.y * phys_rot[1] + t_rot.z * phys_rot[2] + t_rot.w * phys_rot[3];
                    const abs_dot = if (rot_dot < 0) -rot_dot else rot_dot;

                    // Thresholds: 1mm squared = 0.000001, Rotation cos(angle) ~ 0.9999
                    if (dist_sq > 0.000001 or abs_dot < 0.9999) {
                        // Teleport body to new transform
                        body_interface.setPosition(data.body.body_id, .{ t_pos.x, t_pos.y, t_pos.z }, .activate);
                        body_interface.setRotation(data.body.body_id, .{ t_rot.x, t_rot.y, t_rot.z, t_rot.w }, .activate);

                        // Reset velocities to stop movement (optional, but usually desired when dragging)
                        body_interface.setLinearAndAngularVelocity(data.body.body_id, .{ 0, 0, 0 }, .{ 0, 0, 0 });
                        data.transform.dirty = false;
                    }
                }
            }
        }

        // Cleanup orphans
        var to_remove = std.ArrayList(EntityId){};
        defer to_remove.deinit(self.allocator);

        var it = self.active_bodies.iterator();
        while (it.next()) |entry| {
            if (!seen_entities.contains(entry.key_ptr.*)) {
                try to_remove.append(self.allocator, entry.key_ptr.*);
            }
        }

        for (to_remove.items) |entity_id| {
            if (self.active_bodies.get(entity_id)) |body_id| {
                body_interface.removeBody(body_id);
                body_interface.destroyBody(body_id);
                _ = self.active_bodies.remove(entity_id);
            }
        }

        // 2. Step Physics World
        // TODO: Implement fixed timestep loop (accumulator) for stable physics simulation
        try self.physics_system.update(dt, .{ .collision_steps = 1 });

        // 3. Sync Physics Bodies -> ECS Transforms (Dynamic)
        // Optimization: Use View(RigidBody) directly to avoid QueryIterator overhead
        // and only look up Transform for dynamic bodies.
        var rb_view = try world.view(RigidBody);
        var rb_iter = rb_view.iterator();

        while (rb_iter.next()) |entry| {
            const body = entry.component;
            if (body.body_id != .invalid and body.body_type == .Dynamic) {
                if (body_interface.isActive(body.body_id)) {
                    // Only fetch transform if we actually need to update it
                    if (world.getMut(Transform, entry.entity)) |transform| {
                        const pos = body_interface.getPosition(body.body_id);
                        const rot = body_interface.getRotation(body.body_id);

                        transform.position = .{ .x = pos[0], .y = pos[1], .z = pos[2] };
                        transform.rotation = .{ .x = rot[0], .y = rot[1], .z = rot[2], .w = rot[3] };
                        transform.dirty = true;
                    }
                }
            }
        }
    }

    pub fn update(self: *PhysicsSystem, world: *World, frame_info: *FrameInfo) !void {
        _ = self;
        _ = world;
        _ = frame_info;
        // No GPU work for physics system
    }
};

// --- Jolt Layer Implementation Details ---

const Layers = enum(u8) {
    NonMoving = 0,
    Moving = 1,
    len = 2,
};

const BroadPhaseLayers = enum(u8) {
    NonMoving = 0,
    Moving = 1,
    len = 2,
};

const BroadPhaseLayerInterfaceImpl = struct {
    pub fn getNumBroadPhaseLayers(_: *const zphysics.BroadPhaseLayerInterface) callconv(.c) u32 {
        return @intFromEnum(BroadPhaseLayers.len);
    }

    pub fn getBroadPhaseLayer(_: *const zphysics.BroadPhaseLayerInterface, layer: zphysics.ObjectLayer) callconv(.c) zphysics.BroadPhaseLayer {
        const object_layer = @as(Layers, @enumFromInt(layer));
        return switch (object_layer) {
            .NonMoving => @intFromEnum(BroadPhaseLayers.NonMoving),
            .Moving => @intFromEnum(BroadPhaseLayers.Moving),
            .len => unreachable,
        };
    }

    pub fn getBroadPhaseLayerName(_: *const zphysics.BroadPhaseLayerInterface, layer: zphysics.BroadPhaseLayer) callconv(.c) [*:0]const u8 {
        const bp_layer = @as(BroadPhaseLayers, @enumFromInt(layer));
        return switch (bp_layer) {
            .NonMoving => "NonMoving",
            .Moving => "Moving",
            .len => unreachable,
        };
    }
};

const ObjectVsBroadPhaseLayerFilterImpl = struct {
    pub fn shouldCollide(_: *const zphysics.ObjectVsBroadPhaseLayerFilter, layer1: zphysics.ObjectLayer, layer2: zphysics.BroadPhaseLayer) callconv(.c) bool {
        const object_layer = @as(Layers, @enumFromInt(layer1));
        const bp_layer = @as(BroadPhaseLayers, @enumFromInt(layer2));

        return switch (object_layer) {
            .NonMoving => bp_layer == .Moving,
            .Moving => true,
            .len => unreachable,
        };
    }
};

const ObjectLayerPairFilterImpl = struct {
    pub fn shouldCollide(_: *const zphysics.ObjectLayerPairFilter, layer1: zphysics.ObjectLayer, layer2: zphysics.ObjectLayer) callconv(.c) bool {
        const object_layer1 = @as(Layers, @enumFromInt(layer1));
        const object_layer2 = @as(Layers, @enumFromInt(layer2));

        return switch (object_layer1) {
            .NonMoving => object_layer2 == .Moving,
            .Moving => true,
            .len => unreachable,
        };
    }
};

// --- System Scheduler Wrappers ---

pub fn prepare(world: *World, dt: f32) !void {
    const scene_ptr = world.getUserData("scene") orelse return;
    const scene: *Scene = @ptrCast(@alignCast(scene_ptr));

    if (scene.physics_system) |physics_system| {
        try physics_system.prepare(world, dt);
    }
}

pub fn update(world: *World, frame_info: *FrameInfo) !void {
    const scene_ptr = world.getUserData("scene") orelse return;
    const scene: *Scene = @ptrCast(@alignCast(scene_ptr));

    if (scene.physics_system) |physics_system| {
        try physics_system.update(world, frame_info);
    }
}
