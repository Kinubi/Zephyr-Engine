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

pub const PhysicsSystem = struct {
    allocator: std.mem.Allocator,
    gpa: std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }),
    physics_system: *zphysics.PhysicsSystem,
    broad_phase_layer_interface: zphysics.BroadPhaseLayerInterface,
    object_vs_broad_phase_layer_filter: zphysics.ObjectVsBroadPhaseLayerFilter,
    object_layer_pair_filter: zphysics.ObjectLayerPairFilter,

    pub fn init(allocator: std.mem.Allocator) !*PhysicsSystem {
        const self = try allocator.create(PhysicsSystem);
        self.allocator = allocator;
        self.gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
        const physics_allocator = self.gpa.allocator();

        try zphysics.init(physics_allocator, .{});

        // Setup layers
        self.broad_phase_layer_interface = zphysics.BroadPhaseLayerInterface.init(BroadPhaseLayerInterfaceImpl);
        self.object_vs_broad_phase_layer_filter = zphysics.ObjectVsBroadPhaseLayerFilter.init(ObjectVsBroadPhaseLayerFilterImpl);
        self.object_layer_pair_filter = zphysics.ObjectLayerPairFilter.init(ObjectLayerPairFilterImpl);

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

        log(.INFO, "physics_system", "PhysicsSystem initialized", .{});
        return self;
    }

    pub fn deinit(self: *PhysicsSystem) void {
        log(.INFO, "physics_system", "PhysicsSystem deinit start", .{});
        
        log(.INFO, "physics_system", "Destroying Jolt PhysicsSystem...", .{});
        self.physics_system.destroy();
        log(.INFO, "physics_system", "Jolt PhysicsSystem destroyed", .{});
        
        log(.INFO, "physics_system", "Deinitializing zphysics...", .{});
        zphysics.deinit();
        log(.INFO, "physics_system", "zphysics deinitialized", .{});
        
        _ = self.gpa.deinit();
        self.allocator.destroy(self);
        log(.INFO, "physics_system", "PhysicsSystem deinitialized", .{});
    }    pub fn prepare(self: *PhysicsSystem, world: *World, dt: f32) !void {
        log(.INFO, "physics_system", "PhysicsSystem prepare start", .{});
        const body_interface = self.physics_system.getBodyInterfaceMut();

        // 1. Sync ECS Transforms -> Physics Bodies (Kinematic/Static) & Create Bodies
        log(.INFO, "physics_system", "Querying entities...", .{});
        var query = try world.query(struct {
            transform: *Transform,
            body: *RigidBody,
            box: ?*BoxCollider,
            sphere: ?*SphereCollider,
        });
        defer query.deinit();
        log(.INFO, "physics_system", "Query created", .{});

        while (query.next()) |entity| {
            log(.INFO, "physics_system", "Processing entity...", .{});
            if (entity.body.body_id == .invalid) {
                // Create Shape
                var shape_settings: *zphysics.ShapeSettings = undefined;

                if (entity.box) |box| {
                    const box_settings = try zphysics.BoxShapeSettings.create(.{ box.half_extents[0], box.half_extents[1], box.half_extents[2] });
                    shape_settings = @ptrCast(box_settings);
                } else if (entity.sphere) |sphere| {
                    const sphere_settings = try zphysics.SphereShapeSettings.create(sphere.radius);
                    shape_settings = @ptrCast(sphere_settings);
                } else {
                    continue; // No collider
                }
                defer shape_settings.release();

                // Create Body Settings
                const motion_type: zphysics.MotionType = switch (entity.body.body_type) {
                    .Static => .static,
                    .Kinematic => .kinematic,
                    .Dynamic => .dynamic,
                };

                const object_layer: zphysics.ObjectLayer = if (entity.body.body_type == .Static)
                    @intFromEnum(Layers.NonMoving)
                else
                    @intFromEnum(Layers.Moving);

                const shape = try shape_settings.createShape();
                defer shape.release();

                const body_settings = zphysics.BodyCreationSettings{
                    .position = .{ entity.transform.position.x, entity.transform.position.y, entity.transform.position.z, 1.0 },
                    .rotation = .{ entity.transform.rotation.x, entity.transform.rotation.y, entity.transform.rotation.z, entity.transform.rotation.w },
                    .motion_type = motion_type,
                    .object_layer = object_layer,
                    .shape = shape,
                };

                // Create Body
                log(.INFO, "physics_system", "Creating body for entity...", .{});
                const body_id = try body_interface.createAndAddBody(body_settings, .activate);
                log(.INFO, "physics_system", "Body created: {}", .{body_id});
                entity.body.body_id = body_id;
            } else {
                // Sync Kinematic
                if (entity.body.body_type == .Kinematic) {
                    body_interface.setPosition(entity.body.body_id, .{ entity.transform.position.x, entity.transform.position.y, entity.transform.position.z }, .activate);
                    body_interface.setRotation(entity.body.body_id, .{ entity.transform.rotation.x, entity.transform.rotation.y, entity.transform.rotation.z, entity.transform.rotation.w }, .activate);
                }
            }
        }

        // 2. Step Physics World
        log(.INFO, "physics_system", "Stepping physics world...", .{});
        try self.physics_system.update(dt, .{ .collision_steps = 1 });
        log(.INFO, "physics_system", "Physics world stepped", .{});

        // 3. Sync Physics Bodies -> ECS Transforms (Dynamic)
        log(.INFO, "physics_system", "Syncing dynamic bodies...", .{});
        var dynamic_query = try world.query(struct {
            transform: *Transform,
            body: *RigidBody,
        });
        defer dynamic_query.deinit();

        while (dynamic_query.next()) |entity| {
            if (entity.body.body_id != .invalid and entity.body.body_type == .Dynamic) {
                if (body_interface.isActive(entity.body.body_id)) {
                    const pos = body_interface.getPosition(entity.body.body_id);
                    const rot = body_interface.getRotation(entity.body.body_id);

                    entity.transform.position = .{ .x = pos[0], .y = pos[1], .z = pos[2] };
                    entity.transform.rotation = .{ .x = rot[0], .y = rot[1], .z = rot[2], .w = rot[3] };
                    entity.transform.dirty = true;
                }
            }
        }
        log(.INFO, "physics_system", "PhysicsSystem prepare complete", .{});
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
