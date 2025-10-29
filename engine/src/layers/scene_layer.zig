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

    // Phase 2.1: Cached UBO from prepare() to update()
    // Main thread populates this in prepare(), render thread uses it in update()
    prepared_ubo: GlobalUbo = undefined,

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
        .prepare = prepare,
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

    fn prepare(base: *Layer, dt: f32) !void {
        const self: *SceneLayer = @fieldParentPtr("base", base);

        // PHASE 2.1: MAIN THREAD - Game logic, ECS queries (NO Vulkan work)
        // Note: No performance monitoring here - this runs on main thread without frame context

        // Update camera projection
        self.camera.updateProjectionMatrix();

        // Build UBO for scene preparation (includes lights after prepareFrame)
        self.prepared_ubo = GlobalUbo{
            .view = self.camera.viewMatrix,
            .projection = self.camera.projectionMatrix,
            .dt = dt,
        };

        // Update ECS transform hierarchies (CPU work, no Vulkan)
        try self.transform_system.update(self.ecs_world);

        // Prepare scene (ECS queries, particle spawning, light updates - no Vulkan)
        // This updates prepared_ubo with light data
        try self.scene.prepareFrame(&self.prepared_ubo, dt);
    }

    fn begin(base: *Layer, frame_info: *const FrameInfo) !void {
        _ = base;
        _ = frame_info;
    }

    fn update(base: *Layer, frame_info: *const FrameInfo) !void {
        const self: *SceneLayer = @fieldParentPtr("base", base);

        // PHASE 2.1: RENDER THREAD - Vulkan descriptor updates (NO ECS queries!)
        // Main thread already did:
        // - transform_system.update() (in prepare)
        // - scene.prepareFrame() (in prepare) - populated lights in prepared_ubo
        //
        // Here we do Vulkan descriptor updates

        // Use the UBO prepared on main thread (includes light data)
        // Just update the view/projection in case camera moved (though it should be captured in snapshot)
        self.prepared_ubo.view = self.camera.viewMatrix;
        self.prepared_ubo.projection = self.camera.projectionMatrix;
        self.prepared_ubo.dt = frame_info.dt;

        // Update Vulkan resources (descriptor updates)
        if (self.performance_monitor) |pm| {
            try pm.beginPass("scene_update", frame_info.current_frame, null);
        }
        try self.scene.update(frame_info.*, &self.prepared_ubo);
        if (self.performance_monitor) |pm| {
            try pm.endPass("scene_update", frame_info.current_frame, null);
        }

        // Update UBO set for this frame using prepared_ubo (with lights!)
        if (self.performance_monitor) |pm| {
            try pm.beginPass("ubo_update", frame_info.current_frame, null);
        }
        self.global_ubo_set.update(frame_info.current_frame, &self.prepared_ubo);
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
