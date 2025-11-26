const std = @import("std");
const Layer = @import("../core/layer.zig").Layer;
const Event = @import("../core/event.zig").Event;
const EventType = @import("../core/event.zig").EventType;
const FrameInfo = @import("../rendering/frameinfo.zig").FrameInfo;
const GlobalUbo = @import("../rendering/frameinfo.zig").GlobalUbo;
const Camera = @import("../rendering/camera.zig").Camera;
const Scene = @import("../scene/scene.zig").Scene;
const GlobalUboSet = @import("../rendering/ubo_set.zig").GlobalUboSet;
const CameraController = @import("../input/camera_controller.zig").CameraController;
const MAX_FRAMES_IN_FLIGHT = @import("../core/swapchain.zig").MAX_FRAMES_IN_FLIGHT;
const TransformSystem = @import("../ecs.zig").TransformSystem;
const World = @import("../ecs.zig").World;
const SystemScheduler = @import("../ecs.zig").SystemScheduler;
const PerformanceMonitor = @import("../rendering/performance_monitor.zig").PerformanceMonitor;
const log = @import("../utils/log.zig").log;
const ecs = @import("../ecs.zig");
const Math = @import("../utils/math.zig");

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
    controller: *CameraController,

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
        controller: *CameraController,
    ) SceneLayer {
        // Build parallel system scheduler if thread pool is available
        var scheduler: ?SystemScheduler = null;
        if (ecs_world.thread_pool != null) {
            scheduler = SystemScheduler.buildDefault(ecs_world.allocator, ecs_world.thread_pool) catch |err| blk: {
                log(.WARN, "scene_layer", "Failed to build system scheduler: {}, falling back to sequential", .{err});
                break :blk null;
            };

            if (scheduler) |*sched| {

                // Stage 1: Independent parallel systems
                const stage1 = &sched.stages.items[0];

                stage1.addSystem(.{
                    .name = "LightAnimationSystem",
                    .prepare_fn = ecs.prepareLightSystem,
                    .access = .{
                        .reads = &[_][]const u8{"PointLight"},
                        .writes = &[_][]const u8{"Transform"},
                    },
                }) catch |err| {
                    log(.WARN, "scene_layer", "Failed to add light animation system: {}", .{err});
                };

                stage1.addSystem(.{
                    .name = "ScriptingSystem",
                    .prepare_fn = ecs.prepareScriptingSystem,
                    .access = .{
                        .reads = &[_][]const u8{},
                        .writes = &[_][]const u8{"ScriptComponent"},
                    },
                }) catch |err| {
                    log(.WARN, "scene_layer", "Failed to add scripting system: {}", .{err});
                };

                stage1.addSystem(.{
                    .name = "PhysicsSystem",
                    .prepare_fn = ecs.preparePhysicsSystem,
                    .update_fn = ecs.updatePhysicsSystem,
                    .access = .{
                        .reads = &[_][]const u8{ "RigidBody", "BoxCollider", "SphereCollider", "CapsuleCollider", "MeshCollider" },
                        .writes = &[_][]const u8{ "Transform", "RigidBody" },
                    },
                }) catch |err| {
                    log(.WARN, "scene_layer", "Failed to add physics system: {}", .{err});
                };

                stage1.addSystem(.{
                    .name = "MaterialSystem",
                    .prepare_fn = ecs.prepareMaterialSystem,
                    .update_fn = ecs.updateMaterialSystem,
                    .access = .{
                        .reads = &[_][]const u8{ "MaterialSet", "MeshRenderer" },
                        .writes = &[_][]const u8{},
                    },
                }) catch |err| {
                    log(.WARN, "scene_layer", "Failed to add material system: {}", .{err});
                };

                // Stage 2: Systems that depend on Stage 1
                if (sched.addStage("DependentSystems")) |stage2| {
                    stage2.addSystem(.{
                        .name = "TransformSystem",
                        .prepare_fn = ecs.updateTransformSystem,
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
                        .prepare_fn = ecs.updateParticleEmittersSystem,
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

                // Stage 4: Render system updates (change detection only - no cache building)
                // Sets dirty flags when scene changes are detected
                // Actual cache building happens on render thread via rebuildCachesFromSnapshot()
                if (sched.addStage("RenderSystemUpdates")) |stage4| {
                    stage4.addSystem(.{
                        .name = "RenderSystem",
                        .prepare_fn = ecs.prepareRenderSystem,
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
            .controller = controller,
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

        // Apply camera controller (movement/rotation, FOV) once per frame
        self.controller.update(self.camera, dt);

        // Select the UBO snapshot for this prepare() frame
        const prep_idx = self.prepare_frame_index % MAX_FRAMES_IN_FLIGHT;

        // Build UBO for scene preparation (includes lights after prepareFrame)
        self.prepared_ubo[prep_idx] = GlobalUbo{
            .view = self.camera.viewMatrix,
            .projection = self.camera.projectionMatrix,
        };

        // Store GlobalUbo pointer in World so systems can access it
        try self.ecs_world.setUserData("global_ubo", @ptrCast(&self.prepared_ubo[prep_idx]));

        // Determine simulation delta time based on scene state
        const sim_dt = if (self.scene.state == .Play) dt else 0.0;

        // Update ECS systems (CPU work, no Vulkan)
        // Use parallel scheduler if available, otherwise fallback to sequential
        if (self.system_scheduler) |*scheduler| {

            // Parallel execution of all registered systems
            // Systems can now extract data to GlobalUbo via userdata
            try scheduler.executePrepare(self.ecs_world, sim_dt);
        } else {
            // Fallback: Sequential execution
            try ecs.updateTransformSystem(self.ecs_world, sim_dt);
        }

        // Prepare scene (ECS queries, particle spawning, light updates - no Vulkan)
        // NOTE: Light extraction now happens in animateLightsSystem
        // NOTE: Particle GPU updates now happen in updateParticleEmittersSystem
        try self.scene.prepareFrame(&self.prepared_ubo[prep_idx]);

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
        // Rebuild GlobalUbo from snapshot (thread-safe snapshot-based architecture)

        if (frame_info.snapshot) |snapshot| {
            // Build GlobalUbo from snapshot data (camera, lights, dt)
            self.prepared_ubo[frame_info.current_frame] = GlobalUbo{
                .view = snapshot.camera_view_matrix,
                .projection = snapshot.camera_projection_matrix,
                .ambient_color = Math.Vec4.init(1, 1, 1, 0.2),
                .point_lights = undefined,
                .num_point_lights = 0,
            };

            // Populate point lights from snapshot
            const max_lights = 16;
            const light_count = @min(snapshot.point_light_count, max_lights);
            for (0..light_count) |i| {
                const light = snapshot.point_lights[i];
                self.prepared_ubo[frame_info.current_frame].point_lights[i] = .{
                    .position = Math.Vec4.init(light.position.x, light.position.y, light.position.z, 1.0),
                    .color = Math.Vec4.init(
                        light.color.x * light.intensity,
                        light.color.y * light.intensity,
                        light.color.z * light.intensity,
                        light.intensity,
                    ),
                };
            }
            self.prepared_ubo[frame_info.current_frame].num_point_lights = @intCast(light_count);

            // Clear remaining light slots
            for (light_count..max_lights) |i| {
                self.prepared_ubo[frame_info.current_frame].point_lights[i] = .{};
            }
        }
        if (self.system_scheduler) |*scheduler| {
            // Parallel execution of all registered systems update phase
            // Systems use snapshot data from frame_info
            // Cast away const - systems need mutable access to frame_info for internal state
            try scheduler.executeUpdate(self.ecs_world, @constCast(frame_info));
        }

        // Update Vulkan resources (descriptor updates)
        if (self.performance_monitor) |pm| {
            try pm.beginPass("scene_update", frame_info.current_frame, null);
        }
        try self.scene.update(frame_info.*, &self.prepared_ubo[frame_info.current_frame]);
        if (self.performance_monitor) |pm| {
            try pm.endPass("scene_update", frame_info.current_frame, null);
        }

        // Update UBO set for this frame using prepared_ubo (with lights from snapshot!)
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

        // In Play mode, disable editor camera controller - scripts handle input
        const in_play_mode = self.scene.state == .Play;

        switch (evt.event_type) {
            // First, give camera controller a chance to consume input (only in Edit/Pause mode)
            .KeyReleased, .MouseButtonPressed, .MouseButtonReleased, .MouseMoved, .MouseScrolled => {
                if (!in_play_mode and self.controller.event(evt)) {
                    evt.markHandled();
                    return;
                }
            },
            .KeyPressed => {
                if (!in_play_mode and self.controller.event(evt)) {
                    evt.markHandled();
                    return;
                }
                // Handle scene-affecting hotkeys here by consuming events.
                // Example: toggle path tracing on 'T' (only in edit mode).
                if (!in_play_mode) {
                    const GLFW_KEY_T: i32 = 84; // using ASCII 'T' code from GLFW
                    if (evt.data.KeyPressed.key == GLFW_KEY_T) {
                        if (self.scene.render_graph != null) {
                            const pt_enabled = if (self.scene.render_graph.?.getPass("path_tracing_pass")) |pass| pass.enabled else false;
                            self.scene.setPathTracingEnabled(!pt_enabled) catch |err| {
                                log(.WARN, "scene_layer", "Failed to toggle PT: {}", .{err});
                            };
                            evt.markHandled();
                        }
                    }
                }
            },
            else => {},
        }
    }
};
