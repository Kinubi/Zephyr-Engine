const std = @import("std");

// Core graphics imports
const Window = @import("window.zig").Window;
const Pipeline = @import("core/pipeline.zig").Pipeline;

const GraphicsContext = @import("core/graphics_context.zig").GraphicsContext;
const Swapchain = @import("core/swapchain.zig").Swapchain;
const MAX_FRAMES_IN_FLIGHT = @import("core/swapchain.zig").MAX_FRAMES_IN_FLIGHT;
const ShaderLibrary = @import("core/shader.zig").ShaderLibrary;
const entry_point_definition = @import("core/shader.zig").entry_point_definition;
const Texture = @import("core/texture.zig").Texture;
const DescriptorSetLayout = @import("core/descriptors.zig").DescriptorSetLayout;
const DescriptorPool = @import("core/descriptors.zig").DescriptorPool;
const DescriptorSetWriter = @import("core/descriptors.zig").DescriptorWriter;
const Buffer = @import("core/buffer.zig").Buffer;

// Rendering imports
const Vertex = @import("rendering/mesh.zig").Vertex;
const Mesh = @import("rendering/mesh.zig").Mesh;
const Model = @import("rendering/mesh.zig").Model;
const ModelMesh = @import("rendering/mesh.zig").ModelMesh;
const Camera = @import("rendering/camera.zig").Camera;
const FrameInfo = @import("rendering/frameinfo.zig").FrameInfo;
const GlobalUbo = @import("rendering/frameinfo.zig").GlobalUbo;
const GlobalUboSet = @import("rendering/ubo_set.zig").GlobalUboSet;
const RaytracingDescriptorSet = @import("rendering/raytracing_descriptor_set.zig").RaytracingDescriptorSet;

// Scene imports
const Scene = @import("scene/scene.zig").Scene;
const GameObject = @import("scene/game_object.zig").GameObject;
const Material = @import("assets/asset_manager.zig").Material;

// Asset system imports
const AssetManager = @import("assets/asset_manager.zig").AssetManager;
const ThreadPool = @import("threading/thread_pool.zig").ThreadPool;
const ShaderManager = @import("assets/shader_manager.zig").ShaderManager;
const FileWatcher = @import("utils/file_watcher.zig").FileWatcher;

// Dynamic pipeline system imports
const DynamicPipelineManager = @import("rendering/dynamic_pipeline_manager.zig").DynamicPipelineManager;
const PipelineTemplate = @import("rendering/dynamic_pipeline_manager.zig").PipelineTemplate;
const PipelineBuilder = @import("rendering/pipeline_builder.zig").PipelineBuilder;
const VertexInputBinding = @import("rendering/pipeline_builder.zig").VertexInputBinding;
const VertexInputAttribute = @import("rendering/pipeline_builder.zig").VertexInputAttribute;
const DescriptorBinding = @import("rendering/pipeline_builder.zig").DescriptorBinding;
const PushConstantRange = @import("rendering/pipeline_builder.zig").PushConstantRange;
// Shader-pipeline integration removed in favor of the unified pipeline system

// Unified pipeline system imports
const UnifiedPipelineSystem = @import("rendering/unified_pipeline_system.zig").UnifiedPipelineSystem;
const ResourceBinder = @import("rendering/resource_binder.zig").ResourceBinder;

// Renderer imports
const TexturedRenderer = @import("renderers/unified_textured_renderer.zig").UnifiedTexturedRenderer;
const PointLightRenderer = @import("renderers/point_light_renderer.zig").PointLightRenderer;
const ParticleRenderer = @import("renderers/particle_renderer.zig").ParticleRenderer;
const RaytracingRenderer = @import("renderers/unified_raytracing_renderer.zig").RaytracingRenderer;

// System imports
// RaytracingSystem is now integrated into RaytracingRenderer
const ComputeShaderSystem = @import("systems/compute_shader_system.zig").ComputeShaderSystem;
const RenderSystem = @import("systems/render_system.zig").RenderSystem;

// Render Pass System imports
const RenderPass = @import("rendering/render_pass.zig").RenderPass;
const RenderContext = @import("rendering/render_pass.zig").RenderContext;
const SceneView = @import("rendering/render_pass.zig").SceneView;
const GenericRenderer = @import("rendering/generic_renderer.zig").GenericRenderer;
const RendererType = @import("rendering/generic_renderer.zig").RendererType;
const RendererEntry = @import("rendering/generic_renderer.zig").RendererEntry;
const SceneBridge = @import("rendering/scene_bridge.zig").SceneBridge;

// Utility imports
const Math = @import("utils/math.zig");
const log = @import("utils/log.zig").log;
const LogLevel = @import("utils/log.zig").LogLevel;
const loadFileAlloc = @import("utils/file.zig").loadFileAlloc;

// Input controller
const KeyboardMovementController = @import("keyboard_movement_controller.zig").KeyboardMovementController;

// Vulkan bindings and external C libraries
const vk = @import("vulkan");
const c = @cImport({
    @cInclude("GLFW/glfw3.h");
});

// Embedded shaders
const simple_vert align(@alignOf(u32)) = @embedFile("simple_vert").*;
const simple_frag align(@alignOf(u32)) = @embedFile("simple_frag").*;
const textured_vert align(@alignOf(u32)) = @embedFile("textured_vert").*;
const textured_frag align(@alignOf(u32)) = @embedFile("textured_frag").*;
const point_light_vert align(@alignOf(u32)) = @embedFile("point_light_vert").*;
const point_light_frag align(@alignOf(u32)) = @embedFile("point_light_frag").*;

// Callback function for ThreadPool running status changes
fn onThreadPoolRunningChanged(running: bool) void {
    if (running) {
        log(.INFO, "app", "ThreadPool is now running", .{});
    } else {
        log(.WARN, "app", "ThreadPool has stopped running - no more async operations possible", .{});
    }
}

pub const App = struct {
    window: Window = undefined,

    gc: GraphicsContext = undefined,
    allocator: std.mem.Allocator = undefined,

    // Initialize to true so descriptors are updated on first frames
    descriptor_dirty_flags: [MAX_FRAMES_IN_FLIGHT]bool = [_]bool{true} ** MAX_FRAMES_IN_FLIGHT,
    as_dirty_flags: [MAX_FRAMES_IN_FLIGHT]bool = [_]bool{false} ** MAX_FRAMES_IN_FLIGHT,

    // FPS tracking variables (instance variables)
    fps_frame_count: u32 = 0,
    fps_last_time: f64 = 0.0,
    current_fps: f32 = 0.0,

    var current_frame: u32 = 0;
    var swapchain: Swapchain = undefined;
    var cmdbufs: []vk.CommandBuffer = undefined;

    // Individual renderers (still needed for initialization)
    var textured_renderer: TexturedRenderer = undefined;
    var point_light_renderer: PointLightRenderer = undefined;
    var raytracing_renderer: RaytracingRenderer = undefined;
    //var particle_renderer: ParticleRenderer = undefined;
    var particle_renderer: ParticleRenderer = undefined;

    // Generic forward renderer that orchestrates rasterization renderers
    var forward_renderer: GenericRenderer = undefined;

    // Raytracing render pass (separate from forward renderer)
    var rt_render_pass: GenericRenderer = undefined;

    var compute_shader_system: ComputeShaderSystem = undefined;
    var render_system: RenderSystem = undefined;
    var shader_manager: ShaderManager = undefined;
    var dynamic_pipeline_manager: DynamicPipelineManager = undefined;
    // NOTE: Shader-pipeline integration removed - unified pipeline system handles hot reload now

    // Unified pipeline system
    var unified_pipeline_system: UnifiedPipelineSystem = undefined;
    var resource_binder: ResourceBinder = undefined;

    var last_frame_time: f64 = undefined;
    var camera: Camera = undefined;
    var viewer_object: *GameObject = undefined;
    var camera_controller: KeyboardMovementController = undefined;
    var global_UBO_buffers: ?[]Buffer = undefined;
    var frame_info: FrameInfo = FrameInfo{};

    var frame_index: u32 = 0;
    var frame_counter: u64 = 0; // Global frame counter for scheduling
    var scene: Scene = undefined;
    var thread_pool: *ThreadPool = undefined;
    var asset_manager: *AssetManager = undefined;
    var file_watcher: *FileWatcher = undefined;
    // Application-owned FileWatcher for hot-reload; created early so it can be
    // deinitialized after other systems that depend on it have been deinitialized.

    var last_performance_report: f64 = 0.0; // Track when we last printed performance stats
    // Scheduled asset loading system
    const ScheduledAsset = struct {
        frame: u64,
        model_path: []const u8,
        texture_path: []const u8,
        position: Math.Vec3,
        rotation: Math.Vec3,
        scale: Math.Vec3,
        loaded: bool = false,
    };
    var scheduled_assets: std.ArrayList(ScheduledAsset) = undefined;

    // Raytracing system field
    var global_ubo_set: *GlobalUboSet = undefined;

    // Scene bridge and view for rendering
    var scene_bridge: SceneBridge = undefined;
    var scene_view: SceneView = undefined;
    // Generic renderer system is now the default rendering path

    pub fn init(self: *App) !void {
        log(.INFO, "app", "Initializing ZulkanZengine...", .{});
        self.window = try Window.init(.{ .width = 1280, .height = 720 });

        self.allocator = std.heap.page_allocator;

        // Initialize scheduled assets system
        scheduled_assets = std.ArrayList(ScheduledAsset){};

        self.gc = try GraphicsContext.init(self.allocator, self.window.window_props.title, @ptrCast(self.window.window.?));
        log(.INFO, "app", "Using device: {s}", .{self.gc.deviceName()});
        swapchain = try Swapchain.init(&self.gc, self.allocator, .{ .width = self.window.window_props.width, .height = self.window.window_props.height });
        try swapchain.createRenderPass();

        try swapchain.createFramebuffers();
        try self.gc.createCommandPool();
        render_system = RenderSystem.init(&self.gc, &swapchain);

        // Initialize Thread Pool with dynamic scaling
        thread_pool = try self.allocator.create(ThreadPool);
        thread_pool.* = try ThreadPool.init(self.allocator, 16); // Max 16 workers

        // Register subsystems with thread pool

        try thread_pool.registerSubsystem(.{
            .name = "hot_reload",
            .min_workers = 1,
            .max_workers = 2,
            .priority = .low,
            .work_item_type = .hot_reload,
        });

        try thread_pool.registerSubsystem(.{
            .name = "bvh_building",
            .min_workers = 1,
            .max_workers = 4,
            .priority = .critical,
            .work_item_type = .bvh_building,
        });

        try thread_pool.registerSubsystem(.{
            .name = "custom_work",
            .min_workers = 1,
            .max_workers = 2,
            .priority = .low,
            .work_item_type = .custom,
        });

        // Start the thread pool with initial workers
        try thread_pool.start(8); // Start with 4 workers

        // Initialize Asset Manager on heap for stable pointer address
        asset_manager = try AssetManager.init(self.allocator, &self.gc, thread_pool);

        // Create application-owned FileWatcher and hand it to hot-reload systems
        file_watcher = try self.allocator.create(FileWatcher);
        file_watcher.* = FileWatcher.init(self.allocator, thread_pool);
        try file_watcher.start();

        // Initialize Shader Manager for hot reload and compilation
        shader_manager = try ShaderManager.init(self.allocator, thread_pool, file_watcher);
        try shader_manager.addShaderDirectory("shaders");
        // Don't watch shaders/cached - we don't want to recompile cache files
        try shader_manager.start();
        log(.INFO, "app", "Shader hot reload system initialized", .{});

        // Initialize Unified Pipeline System
        unified_pipeline_system = try UnifiedPipelineSystem.init(self.allocator, &self.gc, &shader_manager);
        resource_binder = ResourceBinder.init(self.allocator, &unified_pipeline_system);

        // Connect pipeline system to shader manager for hot reload
        shader_manager.setPipelineSystem(&unified_pipeline_system);

        log(.INFO, "app", "Unified pipeline system initialized", .{});

        // Initialize Dynamic Pipeline Manager
        dynamic_pipeline_manager = try DynamicPipelineManager.init(self.allocator, &self.gc, asset_manager, &shader_manager);
        log(.INFO, "app", "Dynamic pipeline manager initialized", .{});

        // Shader-pipeline integration intentionally removed. Unified pipeline system is active.

        // Initialize Scene with Asset Manager integration
        scene = Scene.init(&self.gc, self.allocator, asset_manager);

        // Enhanced Scene registers for asset completion callbacks during its init

        scene.enableHotReload(file_watcher) catch |err| {
            log(.WARN, "app", "Failed to enable hot reloading: {}", .{err});
        };

        // --- Load cube mesh using asset-based enhanced scene system ---
        const cube_object = try scene.addModelAssetAsync("models/cube.obj", "textures/missing.png", Math.Vec3.init(0, 0.5, 0.5), // position
            Math.Vec3.init(0, 0, 0), // rotation
            Math.Vec3.init(0.5, 0.5, 0.5)); // scale
        log(.INFO, "app", "Added cube object (asset-based) with asset IDs: model={}, material={}, texture={}", .{ cube_object.model_asset orelse @as(@TypeOf(cube_object.model_asset.?), @enumFromInt(0)), cube_object.material_asset orelse @as(@TypeOf(cube_object.material_asset.?), @enumFromInt(0)), cube_object.texture_asset orelse @as(@TypeOf(cube_object.texture_asset.?), @enumFromInt(0)) });

        // Create another textured cube with a different texture (asset-based)
        const cube2_object = try scene.addModelAssetAsync("models/cube.obj", "textures/default.png", Math.Vec3.init(0.7, -0.5, 0.5), // position
            Math.Vec3.init(0, 0, 0), // rotation
            Math.Vec3.init(0.5, 0.5, 0.5)); // scale
        log(.INFO, "app", "Added second cube object (asset-based) with asset IDs: model={}, material={}, texture={}", .{ cube2_object.model_asset orelse @as(@TypeOf(cube2_object.model_asset.?), @enumFromInt(0)), cube2_object.material_asset orelse @as(@TypeOf(cube2_object.material_asset.?), @enumFromInt(0)), cube2_object.texture_asset orelse @as(@TypeOf(cube2_object.texture_asset.?), @enumFromInt(0)) });

        // Add another vase with a different texture (asset-based)
        const vase1_object = try scene.addModelAssetAsync("models/smooth_vase.obj", "textures/error.png", Math.Vec3.init(-0.7, -0.5, 0.5), // position
            Math.Vec3.init(0, 0, 0), // rotation
            Math.Vec3.init(0.5, 0.5, 0.5)); // scale
        log(.INFO, "app", "Added first vase object (asset-based) with asset IDs: model={}, material={}, texture={}", .{ vase1_object.model_asset orelse @as(@TypeOf(vase1_object.model_asset.?), @enumFromInt(0)), vase1_object.material_asset orelse @as(@TypeOf(vase1_object.material_asset.?), @enumFromInt(0)), vase1_object.texture_asset orelse @as(@TypeOf(vase1_object.texture_asset.?), @enumFromInt(0)) });

        // Schedule the flat vase to be loaded at frame 1000
        try scheduled_assets.append(self.allocator, ScheduledAsset{
            .frame = 50000,
            .model_path = "models/flat_vase.obj",
            .texture_path = "textures/granitesmooth1-albedo.png",
            .position = Math.Vec3.init(-1.4, -0.5, 0.5),
            .rotation = Math.Vec3.init(0, 0, 0),
            .scale = Math.Vec3.init(0.5, 0.5, 0.5),
        });
        log(.INFO, "app", "Scheduled flat vase to be loaded at frame 1000", .{});

        // Give async texture loading a moment to complete
        std.Thread.sleep(100_000_000); // 100ms

        // log(.DEBUG, "scene", "Adding point light objects", .{});
        // const object3 = try scene.addObject(null, .{ .color = Math.Vec3.init(0.2, 0.5, 1.0), .intensity = 1.0 });
        // object3.transform.translate(Math.Vec3.init(0.5, 0.5, 0.5));
        // object3.transform.scale(Math.Vec3.init(0.5, 0.5, 0.5));

        // const object4 = try scene.addObject(null, .{ .color = Math.Vec3.init(0.5, 0.2, 0.2), .intensity = 1.0 });
        // object4.transform.translate(Math.Vec3.init(0, -1, 0.5));
        // object4.transform.scale(Math.Vec3.init(0.05, 0, 0));

        // const object6 = try scene.addObject(null, .{ .color = Math.Vec3.init(0.5, 0.2, 0.2), .intensity = 1.0 });
        // object6.transform.translate(Math.Vec3.init(0, -1, 0.5));
        // object6.transform.scale(Math.Vec3.init(0.05, 0, 0));

        cmdbufs = try self.gc.createCommandBuffers(
            self.allocator,
        );

        viewer_object = try scene.addEmpty();
        camera_controller = KeyboardMovementController.init();

        camera = Camera{ .fov = 75.0, .window = self.window };
        camera.updateProjectionMatrix();
        camera.setViewDirection(Math.Vec3.init(0, 0, 0), Math.Vec3.init(0, 0, 1), Math.Vec3.init(0, 1, 0));

        // --- Use new GlobalUboSet abstraction ---
        global_ubo_set = self.allocator.create(GlobalUboSet) catch unreachable;
        global_ubo_set.* = try GlobalUboSet.init(&self.gc, self.allocator);
        frame_info.global_descriptor_set = global_ubo_set.sets[0];

        // Register pipeline templates for dynamic pipeline system
        try self.registerPipelineTemplates();
        log(.INFO, "app", "Pipeline templates registered", .{});

        _ = try scene.updateSyncResources(self.allocator);

        // Initialize unified textured renderer with shared pipeline system
        textured_renderer = try TexturedRenderer.init(
            self.allocator,
            @constCast(&self.gc),
            &shader_manager,
            &unified_pipeline_system,
            swapchain.render_pass,
        );

        // Material data is now managed by the asset_manager and bound via UnifiedPipelineSystem
        // No need for separate updateMaterialData calls

        var shader_library_point_light = ShaderLibrary.init(self.gc, self.allocator);

        try shader_library_point_light.add(&.{
            &point_light_frag,
            &point_light_vert,
        }, &.{
            vk.ShaderStageFlags{ .fragment_bit = true },
            vk.ShaderStageFlags{ .vertex_bit = true },
        }, &.{
            entry_point_definition{},
            entry_point_definition{},
        });
        point_light_renderer = try PointLightRenderer.init(@constCast(&self.gc), swapchain.render_pass, scene.asScene(), shader_library_point_light, self.allocator, @constCast(&camera), global_ubo_set.layout.descriptor_set_layout, &dynamic_pipeline_manager);

        // Initialize unified raytracing renderer through the shared pipeline system
        raytracing_renderer = try RaytracingRenderer.init(
            self.allocator,
            @constCast(&self.gc),
            &unified_pipeline_system,
            &swapchain,
            thread_pool,
            global_ubo_set,
        );

        // --- Raytracing pipeline setup ---
        // Use the same global descriptor set and layout as the renderer

        // Create scene bridge for render pass system and raytracing
        scene_bridge = SceneBridge.init(&scene, self.allocator);

        // Note: TLAS creation will be handled in the update loop once BLAS is complete
        // SBT will be created by raytracing renderer when pipeline is ready

        log(.INFO, "app", "Creating unified particle renderer...", .{});
        particle_renderer = try ParticleRenderer.init(
            self.allocator,
            &self.gc,
            &shader_manager,
            &unified_pipeline_system,
            swapchain.render_pass,
            1024, // max particles
        );

        // Initialize particles with random data
        try particle_renderer.initializeParticles();

        log(.INFO, "app", "Unified particle renderer initialized", .{});

        // --- Compute shader system initialization ---
        compute_shader_system = try ComputeShaderSystem.init(&self.gc, &swapchain, self.allocator);

        // // Create UBO infos for old particle renderer
        // var ubo_infos = try self.allocator.alloc(vk.DescriptorBufferInfo, global_ubo_set.buffers.len);
        // defer self.allocator.free(ubo_infos);
        // for (global_ubo_set.buffers, 0..) |buf, i| {
        //     ubo_infos[i] = buf.descriptor_info;
        // }

        // particle_renderer = try ParticleRenderer.init(
        //     &self.gc,
        //     swapchain.render_pass,
        //     particle_render_shader_library,
        //     particle_comp_shader_library,
        //     self.allocator,
        //     1024,
        //     ubo_infos,
        // );
        log(.INFO, "ComputeSystem", "Compute system fully initialized", .{});

        // Initialize Generic Forward Renderer (rasterization only)
        forward_renderer = GenericRenderer.init(self.allocator);

        // Set the scene bridge for renderers that need scene data
        forward_renderer.setSceneBridge(&scene_bridge);

        // Set the swapchain for renderers that need it
        forward_renderer.setSwapchain(&swapchain);

        // Add rasterization renderers to the forward renderer
        try forward_renderer.addRenderer("textured", RendererType.raster, &textured_renderer, TexturedRenderer);
        try forward_renderer.addRenderer("point_light", RendererType.lighting, &point_light_renderer, PointLightRenderer);

        // Initialize Raytracing Render Pass (separate from forward renderer)
        rt_render_pass = GenericRenderer.init(self.allocator);

        // Set the scene bridge and swapchain for raytracing
        rt_render_pass.setSceneBridge(&scene_bridge);
        rt_render_pass.setSwapchain(&swapchain);

        // Add raytracing renderer to its own render pass
        try rt_render_pass.addRenderer("raytracing", RendererType.raytracing, &raytracing_renderer, RaytracingRenderer);

        // Future renderers can be added here:
        // try forward_renderer.addRenderer("particle", RendererType.compute, &particle_renderer, ParticleRenderer);
        // try forward_renderer.addRenderer("shadow", RendererType.raster, &shadow_renderer, ShadowRenderer);

        // Initialize scene view using the existing SceneBridge
        scene_view = scene_bridge.createSceneView();
        log(.INFO, "app", "Render pass manager system initialized", .{});

        // Prime scene bridge state before entering the main loop so first-frame descriptors are valid
        _ = scene_bridge.updateAsyncResources() catch |err| {
            log(.WARN, "app", "Initial async resource update failed: {}", .{err});
        };
        var init_frame_info = frame_info;
        init_frame_info.current_frame = current_frame;
        try forward_renderer.update(&init_frame_info);
        try rt_render_pass.update(&init_frame_info);

        last_frame_time = c.glfwGetTime();
        self.fps_last_time = last_frame_time; // Initialize FPS tracking
        frame_info.camera = &camera;
        // // Legacy initialization removed - descriptors updated via updateFromSceneView during rendering
    }

    pub fn onUpdate(self: *App) !bool {
        // Process deferred pipeline destroys for hot reload safety
        unified_pipeline_system.processDeferredDestroys();

        // Increment frame counter for scheduling
        frame_counter += 1;

        // Check for scheduled asset loads
        for (scheduled_assets.items) |*scheduled_asset| {
            if (!scheduled_asset.loaded and frame_counter >= scheduled_asset.frame) {
                log(.INFO, "app", "Loading scheduled asset at frame {}: {s}", .{ frame_counter, scheduled_asset.model_path });

                const loaded_object = try scene.addModelAssetAsync(scheduled_asset.model_path, scheduled_asset.texture_path, scheduled_asset.position, scheduled_asset.rotation, scheduled_asset.scale);

                log(.INFO, "app", "Successfully queued scheduled asset for loading with IDs: model={}, material={}, texture={}", .{ loaded_object.model_asset orelse @as(@TypeOf(loaded_object.model_asset.?), @enumFromInt(0)), loaded_object.material_asset orelse @as(@TypeOf(loaded_object.material_asset.?), @enumFromInt(0)), loaded_object.texture_asset orelse @as(@TypeOf(loaded_object.texture_asset.?), @enumFromInt(0)) });

                log(.INFO, "app", "Note: Asset loading is asynchronous - the actual model and texture will appear once background loading completes", .{});

                scheduled_asset.loaded = true;
            }
        }

        // Process any pending hot reloads first
        dynamic_pipeline_manager.processRebuildQueue(swapchain.render_pass);

        _ = try scene_bridge.updateAsyncResources();

        var next_frame_info = frame_info;
        next_frame_info.current_frame = (current_frame + 1) % MAX_FRAMES_IN_FLIGHT;
        try forward_renderer.update(&next_frame_info);

        try rt_render_pass.update(&frame_info);

        //std.debug.print("Updating frame {d}\n", .{current_frame});
        const current_time = c.glfwGetTime();

        // Print performance report every 10 seconds in debug builds
        if (comptime std.debug.runtime_safety) {
            if (current_time - last_performance_report >= 10.0) {
                asset_manager.printPerformanceReport();
                last_performance_report = current_time;
            }
        }

        // Update FPS in title bar every second
        self.fps_frame_count += 1;
        if (current_time - self.fps_last_time >= 1.0) {
            self.current_fps = @as(f32, @floatFromInt(self.fps_frame_count)) / @as(f32, @floatCast(current_time - self.fps_last_time));

            // Create title with FPS - use a stack buffer for the string
            var title_buffer: [256:0]u8 = undefined;
            const title_slice = std.fmt.bufPrintZ(title_buffer[0..], "ZulkanZengine - FPS: {d:.1}", .{self.current_fps}) catch |err| blk: {
                log(.WARN, "app", "Failed to format title: {}", .{err});
                break :blk std.fmt.bufPrintZ(title_buffer[0..], "ZulkanZengine", .{}) catch "ZulkanZengine";
            };

            self.window.setTitle(title_slice.ptr);

            self.fps_frame_count = 0;
            self.fps_last_time = current_time;
        }
        const dt = current_time - last_frame_time;
        const cmdbuf = cmdbufs[current_frame];
        const computebuf = compute_shader_system.compute_bufs[current_frame];
        frame_info.command_buffer = cmdbuf;
        frame_info.compute_buffer = computebuf;
        frame_info.dt = @floatCast(dt);
        frame_info.current_frame = current_frame;

        var width: c_int = 0;
        var height: c_int = 0;
        c.glfwGetWindowSize(@ptrCast(self.window.window.?), &width, &height);
        frame_info.extent = .{ .width = @as(u32, @intCast(width)), .height = @as(u32, @intCast(height)) };

        compute_shader_system.beginCompute(frame_info);

        // Update and render particles using the unified system
        _ = try particle_renderer.update(&frame_info, &scene_bridge);

        compute_shader_system.endCompute(frame_info);

        //log(.TRACE, "app", "Frame start", .{});
        try swapchain.beginFrame(frame_info);

        // NOW begin the rasterization render pass
        render_system.beginRender(frame_info);
        camera_controller.processInput(&self.window, viewer_object, dt);
        frame_info.camera.viewMatrix = viewer_object.transform.local2world;
        frame_info.camera.updateProjectionMatrix();
        var ubo = GlobalUbo{
            .view = frame_info.camera.viewMatrix,
            .projection = frame_info.camera.projectionMatrix,
            .dt = @floatCast(dt),
        };
        // try point_light_renderer.update_point_lights(&frame_info, &ubo);
        global_ubo_set.*.update(frame_info.current_frame, &ubo);

        // Render particles using unified system
        try particle_renderer.renderParticles(frame_info.command_buffer, &camera, frame_info.current_frame);

        // Execute rasterization renderers through the forward renderer
        try forward_renderer.render(frame_info);

        render_system.endRender(frame_info);

        // Execute raytracing render pass BEFORE any render pass begins (raytracing must be outside render passes)
        //try rt_render_pass.render(frame_info);

        try swapchain.endFrame(frame_info, &current_frame);
        last_frame_time = current_time;

        //log(.TRACE, "app", "Frame end", .{});

        return self.window.isRunning();
    }

    /// Register pipeline templates for the dynamic pipeline system
    fn registerPipelineTemplates(self: *App) !void {
        _ = self; // Method for future expansion, currently uses global dynamic_pipeline_manager

        // NOTE: Textured renderer now uses UnifiedPipelineSystem and creates its own pipeline
        // No need to register textured_template with DynamicPipelineManager anymore

        // Static arrays for point light renderer
        const point_light_vertex_bindings = [_]VertexInputBinding{
            // Point light renderer uses no vertex input (draws fullscreen quad procedurally)
        };

        const point_light_vertex_attributes = [_]VertexInputAttribute{
            // No vertex attributes needed
        };

        const point_light_descriptor_bindings = [_]DescriptorBinding{
            DescriptorBinding{
                .binding = 0,
                .descriptor_type = .uniform_buffer,
                .descriptor_count = 1,
                .stage_flags = .{ .vertex_bit = true, .fragment_bit = true },
            },
        };

        const point_light_push_constants = [_]PushConstantRange{
            PushConstantRange{
                .stage_flags = .{ .vertex_bit = true, .fragment_bit = true },
                .offset = 0,
                .size = @sizeOf(@import("renderers/point_light_renderer.zig").PointLightPushConstant),
            },
        };

        // Point light renderer pipeline template
        const point_light_template = PipelineTemplate{
            .name = "point_light_renderer",
            .vertex_shader = "shaders/point_light.vert",
            .fragment_shader = "shaders/point_light.frag",

            .vertex_bindings = &point_light_vertex_bindings,
            .vertex_attributes = &point_light_vertex_attributes,
            .descriptor_bindings = &point_light_descriptor_bindings,
            .push_constant_ranges = &point_light_push_constants,

            .primitive_topology = .triangle_list,
            .depth_test_enable = false, // Point lights are additive
            .depth_write_enable = false,
            .blend_enable = true, // Enable blending for light accumulation
            .cull_mode = .{ .back_bit = true },
        };

        try dynamic_pipeline_manager.registerPipeline(point_light_template);

        // Particle renderer pipeline templates (for unified system reference)
        // Note: The unified particle renderer creates its own pipelines automatically
        // These templates are here for documentation and potential fallback use

        const particle_vertex_bindings = [_]VertexInputBinding{
            VertexInputBinding{
                .binding = 0,
                .stride = @sizeOf(@import("renderers/particle_renderer.zig").Particle),
                .input_rate = .instance,
            },
        };

        const particle_vertex_attributes = [_]VertexInputAttribute{
            VertexInputAttribute{
                .location = 0,
                .binding = 0,
                .format = .r32g32b32_sfloat,
                .offset = 0, // position
            },
            VertexInputAttribute{
                .location = 1,
                .binding = 0,
                .format = .r32g32b32_sfloat,
                .offset = 12, // velocity
            },
            VertexInputAttribute{
                .location = 2,
                .binding = 0,
                .format = .r32g32b32a32_sfloat,
                .offset = 24, // color
            },
            VertexInputAttribute{
                .location = 3,
                .binding = 0,
                .format = .r32_sfloat,
                .offset = 40, // life
            },
        };

        const particle_descriptor_set_0 = [_]DescriptorBinding{
            DescriptorBinding{
                .binding = 0,
                .descriptor_type = .uniform_buffer,
                .descriptor_count = 1,
                .stage_flags = .{ .vertex_bit = true, .fragment_bit = true },
            },
        };

        const particle_descriptor_sets = [_][]const DescriptorBinding{
            &particle_descriptor_set_0,
        };

        // Particle render pipeline template
        const particle_render_template = PipelineTemplate{
            .name = "particle_renderer",
            .vertex_shader = "shaders/particles.vert",
            .fragment_shader = "shaders/particles.frag",

            .vertex_bindings = &particle_vertex_bindings,
            .vertex_attributes = &particle_vertex_attributes,
            .descriptor_sets = &particle_descriptor_sets,
            .push_constant_ranges = &[_]PushConstantRange{},

            .primitive_topology = .point_list,
            .depth_test_enable = true,
            .depth_write_enable = false, // Particles don't write to depth
            .blend_enable = true, // Enable blending for particle effects
            .cull_mode = .{}, // No culling for point sprites
        };

        try dynamic_pipeline_manager.registerPipeline(particle_render_template);

        log(.INFO, "app", "Registered pipeline templates with DynamicPipelineManager: point_light_renderer, particle_renderer", .{});
        log(.INFO, "app", "NOTE: textured_renderer now uses UnifiedPipelineSystem and manages its own pipeline", .{});
    }

    pub fn deinit(self: *App) void {
        _ = self.gc.vkd.deviceWaitIdle(self.gc.dev) catch {}; // Ensure all GPU work is finished before destroying resources

        swapchain.waitForAllFences() catch unreachable;

        // Clean up scheduled assets list
        scheduled_assets.deinit(self.allocator);

        global_ubo_set.deinit();

        // Cleanup generic renderer
        forward_renderer.deinit();
        rt_render_pass.deinit();

        self.gc.destroyCommandBuffers(cmdbufs, self.allocator);

        // Clean up unified systems
        particle_renderer.deinit();
        resource_binder.deinit();
        unified_pipeline_system.deinit();

        // Cleanup heap-allocated shader library

        //particle_renderer.deinit();
        scene.deinit();

        // Clean up dynamic pipeline system
        dynamic_pipeline_manager.deinit();

        shader_manager.deinit();
        asset_manager.deinit();
        file_watcher.deinit();
        // Shutdown thread pool last to prevent threading conflicts
        thread_pool.deinit();
        self.allocator.destroy(thread_pool);
        swapchain.deinit();
        self.gc.deinit();

        // Clean up zstbi global state
        @import("core/texture.zig").deinitZstbi();

        self.window.deinit();
    }
};

// --- User-friendly helpers for model/object creation ---
// (Moved to mesh.zig and scene.zig)
