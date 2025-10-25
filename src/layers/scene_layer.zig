const std = @import("std");
const Layer = @import("../core/layer.zig").Layer;
const Event = @import("../core/event.zig").Event;
const EventType = @import("../core/event.zig").EventType;
const FrameInfo = @import("../rendering/frameinfo.zig").FrameInfo;
const GlobalUbo = @import("../rendering/frameinfo.zig").GlobalUbo;
const Camera = @import("../rendering/camera.zig").Camera;
const SceneV2 = @import("../scene/scene_v2.zig").Scene;
const GlobalUboSet = @import("../rendering/ubo_set.zig").GlobalUboSet;
const TransformSystem = @import("../ecs.zig").TransformSystem;
const World = @import("../ecs.zig").World;
const PerformanceMonitor = @import("../rendering/performance_monitor.zig").PerformanceMonitor;
const log = @import("../utils/log.zig").log;

/// Scene management layer
/// Updates scene state, manages ECS systems, handles UBO updates
pub const SceneLayer = struct {
    base: Layer,
    camera: *Camera,
    scene: *SceneV2,
    global_ubo_set: *GlobalUboSet,
    transform_system: *TransformSystem,
    ecs_world: *World,
    performance_monitor: ?*PerformanceMonitor,

    pub fn init(
        camera: *Camera,
        scene: *SceneV2,
        global_ubo_set: *GlobalUboSet,
        transform_system: *TransformSystem,
        ecs_world: *World,
        performance_monitor: ?*PerformanceMonitor,
    ) SceneLayer {
        return .{
            .base = .{
                .name = "SceneLayer",
                .enabled = true,
                .vtable = &vtable,
            },
            .camera = camera,
            .scene = scene,
            .global_ubo_set = global_ubo_set,
            .transform_system = transform_system,
            .ecs_world = ecs_world,
            .performance_monitor = performance_monitor,
        };
    }

    const vtable = Layer.VTable{
        .attach = attach,
        .detach = detach,
        .begin = begin,
        .update = update,
        .render = render,
        .end = end,
        .event = event,
    };

    fn attach(base: *Layer) !void {
        const self: *SceneLayer = @fieldParentPtr("base", base);
        _ = self;
    }

    fn detach(base: *Layer) void {
        const self: *SceneLayer = @fieldParentPtr("base", base);
        _ = self;
    }

    fn begin(base: *Layer, frame_info: *const FrameInfo) !void {
        _ = base;
        _ = frame_info;
    }

    fn update(base: *Layer, frame_info: *const FrameInfo) !void {
        const self: *SceneLayer = @fieldParentPtr("base", base);

        // Update camera projection
        self.camera.updateProjectionMatrix();

        // Build UBO using frame_info
        var ubo = GlobalUbo{
            .view = self.camera.viewMatrix,
            .projection = self.camera.projectionMatrix,
            .dt = frame_info.dt,
        };

        // Update ECS transform hierarchies
        if (self.performance_monitor) |pm| {
            try pm.beginPass("transform_update", frame_info.current_frame, null);
        }
        try self.transform_system.update(self.ecs_world);
        if (self.performance_monitor) |pm| {
            try pm.endPass("transform_update", frame_info.current_frame, null);
        }

        // Update scene
        if (self.performance_monitor) |pm| {
            try pm.beginPass("scene_update", frame_info.current_frame, null);
        }
        try self.scene.update(frame_info.*, &ubo);
        if (self.performance_monitor) |pm| {
            try pm.endPass("scene_update", frame_info.current_frame, null);
        }

        // Update UBO set for this frame
        if (self.performance_monitor) |pm| {
            try pm.beginPass("ubo_update", frame_info.current_frame, null);
        }
        self.global_ubo_set.update(frame_info.current_frame, &ubo);
        if (self.performance_monitor) |pm| {
            try pm.endPass("ubo_update", frame_info.current_frame, null);
        }
    }

    fn render(base: *Layer, frame_info: *const FrameInfo) !void {
        const self: *SceneLayer = @fieldParentPtr("base", base);

        // Render scene
        try self.scene.render(frame_info.*);
    }

    fn end(base: *Layer, frame_info: *FrameInfo) !void {
        _ = base;
        _ = frame_info;
    }

    fn event(base: *Layer, evt: *Event) void {
        const self: *SceneLayer = @fieldParentPtr("base", base);

        switch (evt.event_type) {
            .PathTracingToggled => {
                const enabled = evt.data.PathTracingToggled.enabled;
                self.scene.setPathTracingEnabled(enabled) catch |err| {
                    log(.WARN, "scene_layer", "Failed to toggle path tracing: {}", .{err});
                };
                evt.markHandled();
            },
            else => {},
        }
    }
};
