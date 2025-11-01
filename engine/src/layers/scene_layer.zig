const std = @import("std");
const Layer = @import("../core/layer.zig").Layer;
const Event = @import("../core/event.zig").Event;
const EventType = @import("../core/event.zig").EventType;
const FrameInfo = @import("../rendering/frameinfo.zig").FrameInfo;
const GlobalUbo = @import("../rendering/frameinfo.zig").GlobalUbo;
const Camera = @import("../rendering/camera.zig").Camera;
const Scene = @import("../scene/scene.zig").Scene;
const GlobalUboSet = @import("../rendering/ubo_set.zig").GlobalUboSet;
const MAX_FRAMES_IN_FLIGHT = @import("../core/swapchain.zig").MAX_FRAMES_IN_FLIGHT;
const TransformSystem = @import("../ecs.zig").TransformSystem;
const World = @import("../ecs.zig").World;
const SystemScheduler = @import("../ecs.zig").SystemScheduler;
const PerformanceMonitor = @import("../rendering/performance_monitor.zig").PerformanceMonitor;
const log = @import("../utils/log.zig").log;
const ecs = @import("../ecs.zig");

/// Scene management layer
/// Updates scene state, manages ECS systems, handles UBO updates
pub const SceneLayer = struct {
    base: Layer,
    camera: *Camera,
    scene: *Scene,
    global_ubo_set: *GlobalUboSet,
    transform_system: *TransformSystem,
    ecs_world: *World,
    performance_monitor: ?*PerformanceMonitor,
    system_scheduler: ?SystemScheduler,

    // Phase 2.1: Double-buffered UBO snapshots per frame-in-flight
    // Main thread populates prepared_ubo[prepare_idx] in prepare()
    // Render thread uses prepared_ubo[current_frame] in update()
    prepared_ubo: [MAX_FRAMES_IN_FLIGHT]GlobalUbo = [_]GlobalUbo{.{}} ** MAX_FRAMES_IN_FLIGHT,
    prepare_frame_index: usize = 0,

    pub fn init(
        camera: *Camera,
        scene: *Scene,
        global_ubo_set: *GlobalUboSet,
        transform_system: *TransformSystem,
        ecs_world: *World,
        performance_monitor: ?*PerformanceMonitor,
    ) SceneLayer {
        // Build parallel system scheduler if thread pool is available
        var scheduler: ?SystemScheduler = null;
        if (ecs_world.thread_pool != null) {
            scheduler = SystemScheduler.buildDefault(ecs_world.allocator, ecs_world.thread_pool) catch |err| blk: {
                log(.WARN, "scene_layer", "Failed to build system scheduler: {}, falling back to sequential", .{err});
                break :blk null;
            };

            if (scheduler) |*sched| {

                // Stage 1: Light animation (modifies light transforms)
                const stage1 = &sched.stages.items[0];

                stage1.addSystem(.{
                    .name = "LightAnimationSystem",
                    .update_fn = ecs.updateLightSystem,
                    .access = .{
                        .reads = &[_][]const u8{"PointLight"},
                        .writes = &[_][]const u8{"Transform"},
                    },
                }) catch |err| {
                    log(.WARN, "scene_layer", "Failed to add light animation system: {}", .{err});
                };

                // Add ScriptingSystem into the SAME stage as LightAnimation to test parallelism
                stage1.addSystem(.{
                    .name = "ScriptingSystem",
                    .update_fn = ecs.updateScriptingSystem,
                    .access = .{
                        .reads = &[_][]const u8{},
                        .writes = &[_][]const u8{"ScriptComponent"},
                    },
                }) catch |err| {
                    log(.WARN, "scene_layer", "Failed to add scripting system: {}", .{err});
                };

                // Stage 2: Transform updates (processes all transforms including animated lights)
                if (sched.addStage("TransformUpdates")) |stage3| {
                    stage3.addSystem(.{
                        .name = "TransformSystem",
                        .update_fn = ecs.updateTransformSystem,
                        .access = .{
                            .reads = &[_][]const u8{},
                            .writes = &[_][]const u8{"Transform"},
                        },
                    }) catch |err| {
                        log(.WARN, "scene_layer", "Failed to add transform system: {}", .{err});
                    };
                } else |err| {
                    log(.WARN, "scene_layer", "Failed to add stage 2: {}", .{err});
                }

                // Stage 3: Particle emitter updates (reads transforms)
                if (sched.addStage("ParticleEmitterUpdates")) |stage4| {
                    stage4.addSystem(.{
                        .name = "ParticleEmitterSystem",
                        .update_fn = ecs.updateParticleEmittersSystem,
                        .access = .{
                            .reads = &[_][]const u8{ "ParticleEmitter", "Transform" },
                            .writes = &[_][]const u8{},
                        },
                    }) catch |err| {
                        log(.WARN, "scene_layer", "Failed to add particle emitter system: {}", .{err});
                    };
                } else |err| {
                    log(.WARN, "scene_layer", "Failed to add stage 3: {}", .{err});
                }

                // Stage 4: Render system updates (extract render data, build caches)
                if (sched.addStage("RenderSystemUpdates")) |stage5| {
                    stage5.addSystem(.{
                        .name = "RenderSystem",
                        .update_fn = ecs.updateRenderSystem,
                        .access = .{
                            .reads = &[_][]const u8{ "MeshRenderer", "Transform", "Camera" },
                            .writes = &[_][]const u8{"Transform"}, // clears dirty flags
                        },
                    }) catch |err| {
                        log(.WARN, "scene_layer", "Failed to add render system: {}", .{err});
                    };
                } else |err| {
                    log(.WARN, "scene_layer", "Failed to add stage 4: {}", .{err});
                }
            }
        }

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
            .system_scheduler = scheduler,
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
        if (self.system_scheduler) |*sched| {
            sched.deinit();
        }
    }

    fn prepare(base: *Layer, dt: f32) !void {
        const self: *SceneLayer = @fieldParentPtr("base", base);

        // PHASE 2.1: MAIN THREAD - Game logic, ECS queries (NO Vulkan work)
        // Note: No performance monitoring here - this runs on main thread without frame context

        // Update camera projection
        self.camera.updateProjectionMatrix();

        // Select the UBO snapshot for this prepare() frame
        const prep_idx = self.prepare_frame_index % MAX_FRAMES_IN_FLIGHT;

        // Build UBO for scene preparation (includes lights after prepareFrame)
        self.prepared_ubo[prep_idx] = GlobalUbo{
            .view = self.camera.viewMatrix,
            .projection = self.camera.projectionMatrix,
            .dt = dt,
        };

        // Store GlobalUbo pointer in World so systems can access it
        try self.ecs_world.setUserData("global_ubo", @ptrCast(&self.prepared_ubo[prep_idx]));

        // Update ECS systems (CPU work, no Vulkan)
        // Use parallel scheduler if available, otherwise fallback to sequential
        if (self.system_scheduler) |*scheduler| {
            // Parallel execution of all registered systems
            // Systems can now extract data to GlobalUbo via userdata
            try scheduler.execute(self.ecs_world, dt);
        } else {
            // Fallback: Sequential execution
            try ecs.updateTransformSystem(self.ecs_world, dt);
        }

        // Prepare scene (ECS queries, particle spawning, light updates - no Vulkan)
        // NOTE: Light extraction now happens in animateLightsSystem
        // NOTE: Particle GPU updates now happen in updateParticleEmittersSystem
        try self.scene.prepareFrame(&self.prepared_ubo[prep_idx], dt);

        // Advance prepare frame index for next main-thread prepare()
        self.prepare_frame_index = (prep_idx + 1) % MAX_FRAMES_IN_FLIGHT;
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

        // Use the UBO prepared on main thread (immutable snapshot for this frame).
        // Avoid mutating prepared_ubo here to prevent data races with prepare() on main thread.

        // Update Vulkan resources (descriptor updates)
        if (self.performance_monitor) |pm| {
            try pm.beginPass("scene_update", frame_info.current_frame, null);
        }
        try self.scene.update(frame_info.*, &self.prepared_ubo[frame_info.current_frame]);
        if (self.performance_monitor) |pm| {
            try pm.endPass("scene_update", frame_info.current_frame, null);
        }

        // Update UBO set for this frame using prepared_ubo (with lights!)
        if (self.performance_monitor) |pm| {
            try pm.beginPass("ubo_update", frame_info.current_frame, null);
        }
        self.global_ubo_set.update(frame_info.current_frame, &self.prepared_ubo[frame_info.current_frame]);
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
        const self: *SceneLayer = @fieldParentPtr("base", base);
        _ = frame_info;

        // PHASE 2.1: Apply pending path tracing toggles AFTER endFrame() when GPU is idle
        // This is safe because:
        // 1. GPU has finished all work (frame submission completed)
        // 2. No fences are in-flight (they've all been waited on)
        // 3. Render graph recompile can happen without fence conflicts
        _ = self.scene.applyPendingPathTracingToggle() catch |err| {
            log(.ERROR, "scene_layer", "Failed to apply PT toggle: {}", .{err});
        };
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
