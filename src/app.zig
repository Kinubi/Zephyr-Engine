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

// Dynamic pipeline system imports
const DynamicPipelineManager = @import("rendering/dynamic_pipeline_manager.zig").DynamicPipelineManager;
const PipelineTemplate = @import("rendering/dynamic_pipeline_manager.zig").PipelineTemplate;
const PipelineBuilder = @import("rendering/pipeline_builder.zig").PipelineBuilder;
const VertexInputBinding = @import("rendering/pipeline_builder.zig").VertexInputBinding;
const VertexInputAttribute = @import("rendering/pipeline_builder.zig").VertexInputAttribute;
const DescriptorBinding = @import("rendering/pipeline_builder.zig").DescriptorBinding;
const PushConstantRange = @import("rendering/pipeline_builder.zig").PushConstantRange;
const ShaderPipelineIntegration = @import("rendering/shader_pipeline_integration.zig").ShaderPipelineIntegration;
const setGlobalIntegration = @import("rendering/shader_pipeline_integration.zig").setGlobalIntegration;

// Unified pipeline system imports
const UnifiedPipelineSystem = @import("rendering/unified_pipeline_system.zig").UnifiedPipelineSystem;
const ResourceBinder = @import("rendering/resource_binder.zig").ResourceBinder;

// Renderer imports
const SimpleRenderer = @import("renderers/simple_renderer.zig").SimpleRenderer;
const TexturedRenderer = @import("renderers/textured_renderer.zig").TexturedRenderer;
const PointLightRenderer = @import("renderers/point_light_renderer.zig").PointLightRenderer;
const ParticleRenderer = @import("renderers/particle_renderer.zig").ParticleRenderer;
const RaytracingRenderer = @import("renderers/raytracing_renderer.zig").RaytracingRenderer;

// System imports
// RaytracingSystem is now integrated into RaytracingRenderer
const ComputeShaderSystem = @import("systems/compute_shader_system.zig").ComputeShaderSystem;
const RenderSystem = @import("systems/render_system.zig").RenderSystem;

// Render Pass System imports
const RenderPass = @import("rendering/render_pass.zig").RenderPass;
const RenderContext = @import("rendering/render_pass.zig").RenderContext;
const SceneView = @import("rendering/render_pass.zig").SceneView;
const RenderPassManager = @import("rendering/render_pass_manager.zig").RenderPassManager;
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
    descriptor_dirty_flags: [MAX_FRAMES_IN_FLIGHT]bool = [_]bool{false} ** MAX_FRAMES_IN_FLIGHT,
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
    // NOTE: Shader-pipeline integration disabled - unified pipeline system handles hot reload now
    // var shader_pipeline_integration: ShaderPipelineIntegration = undefined;

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
    var last_performance_report: f64 = 0.0; // Track when we last printed performance stats    // Scheduled asset loading system
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

        // Start the thread pool with initial workers
        try thread_pool.start(8); // Start with 4 workers

        // Initialize Asset Manager on heap for stable pointer address
        asset_manager = try AssetManager.init(self.allocator, &self.gc, thread_pool);

        // Initialize Shader Manager for hot reload and compilation
        shader_manager = try ShaderManager.init(self.allocator, asset_manager, thread_pool);
        try shader_manager.addShaderDirectory("shaders");
        try shader_manager.addShaderDirectory("shaders/cached");
        try shader_manager.start();
        log(.INFO, "app", "Shader hot reload system initialized", .{});

        // Initialize Unified Pipeline System
        unified_pipeline_system = try UnifiedPipelineSystem.init(self.allocator, &self.gc, &shader_manager);
        resource_binder = ResourceBinder.init(self.allocator, &unified_pipeline_system);
        @import("rendering/unified_pipeline_system.zig").setGlobalUnifiedPipelineSystem(&unified_pipeline_system);
        log(.INFO, "app", "Unified pipeline system initialized", .{});

        // Initialize Dynamic Pipeline Manager
        dynamic_pipeline_manager = try DynamicPipelineManager.init(self.allocator, &self.gc, asset_manager, &shader_manager);
        log(.INFO, "app", "Dynamic pipeline manager initialized", .{});

        // NOTE: Shader-pipeline integration disabled - unified pipeline system handles hot reload now
        // shader_pipeline_integration = try ShaderPipelineIntegration.init(self.allocator, &dynamic_pipeline_manager, &shader_manager.hot_reload);
        // setGlobalIntegration(&shader_pipeline_integration);
        // log(.INFO, "app", "Shader-pipeline integration initialized", .{});

        // Initialize Scene with Asset Manager integration
        scene = Scene.init(&self.gc, self.allocator, asset_manager);

        // Enhanced Scene registers for asset completion callbacks during its init

        // Enable hot reloading for development BEFORE loading assets
        scene.enableHotReload() catch |err| {
            log(.WARN, "app", "Failed to enable hot reloading: {}", .{err});
        };

        // --- Load cube mesh using asset-based enhanced scene system ---
        const cube_object = try scene.addModelAssetAsync("models/cube.obj", "textures/missing.png", Math.Vec3.init(0, 0.5, 0.5), // position
            Math.Vec3.init(0, 0, 0), // rotation
            Math.Vec3.init(0.5, 0.5, 0.5)); // scale
        log(.INFO, "scene", "Added cube object (asset-based) with asset IDs: model={}, material={}, texture={}", .{ cube_object.model_asset orelse @as(@TypeOf(cube_object.model_asset.?), @enumFromInt(0)), cube_object.material_asset orelse @as(@TypeOf(cube_object.material_asset.?), @enumFromInt(0)), cube_object.texture_asset orelse @as(@TypeOf(cube_object.texture_asset.?), @enumFromInt(0)) });

        // Create another textured cube with a different texture (asset-based)
        const cube2_object = try scene.addModelAssetAsync("models/cube.obj", "textures/default.png", Math.Vec3.init(0.7, -0.5, 0.5), // position
            Math.Vec3.init(0, 0, 0), // rotation
            Math.Vec3.init(0.5, 0.5, 0.5)); // scale
        log(.INFO, "scene", "Added second cube object (asset-based) with asset IDs: model={}, material={}, texture={}", .{ cube2_object.model_asset orelse @as(@TypeOf(cube2_object.model_asset.?), @enumFromInt(0)), cube2_object.material_asset orelse @as(@TypeOf(cube2_object.material_asset.?), @enumFromInt(0)), cube2_object.texture_asset orelse @as(@TypeOf(cube2_object.texture_asset.?), @enumFromInt(0)) });

        // Add another vase with a different texture (asset-based)
        const vase1_object = try scene.addModelAssetAsync("models/smooth_vase.obj", "textures/error.png", Math.Vec3.init(-0.7, -0.5, 0.5), // position
            Math.Vec3.init(0, 0, 0), // rotation
            Math.Vec3.init(0.5, 0.5, 0.5)); // scale
        log(.INFO, "scene", "Added first vase object (asset-based) with asset IDs: model={}, material={}, texture={}", .{ vase1_object.model_asset orelse @as(@TypeOf(vase1_object.model_asset.?), @enumFromInt(0)), vase1_object.material_asset orelse @as(@TypeOf(vase1_object.material_asset.?), @enumFromInt(0)), vase1_object.texture_asset orelse @as(@TypeOf(vase1_object.texture_asset.?), @enumFromInt(0)) });

        // // Add another vase with a different texture (asset-based)
        // const vase2_object = try scene.addModelAssetAsync("models/flat_vase.obj", "textures/granitesmooth1-albedo.png", Math.Vec3.init(-1.4, -0.5, 0.5), // position
        //     Math.Vec3.init(0, 0, 0), // rotation
        //     Math.Vec3.init(0.5, 0.5, 0.5)); // scale
        // log(.INFO, "scene", "Added second vase object (asset-based) with asset IDs: model={}, material={}, texture={}", .{ vase2_object.model_asset orelse @as(@TypeOf(vase2_object.model_asset.?), @enumFromInt(0)), vase2_object.material_asset orelse @as(@TypeOf(vase2_object.material_asset.?), @enumFromInt(0)), vase2_object.texture_asset orelse @as(@TypeOf(vase2_object.texture_asset.?), @enumFromInt(0)) });

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

        var shader_library = ShaderLibrary.init(self.gc, self.allocator);

        try shader_library.add(&.{
            &textured_frag,
            &textured_vert,
        }, &.{
            vk.ShaderStageFlags{ .fragment_bit = true },
            vk.ShaderStageFlags{ .vertex_bit = true },
        }, &.{
            entry_point_definition{},
            entry_point_definition{},
        });
        _ = try scene.updateSyncResources(self.allocator);
        textured_renderer = try TexturedRenderer.init(@constCast(&self.gc), swapchain.render_pass, shader_library, self.allocator, global_ubo_set.layout.descriptor_set_layout, &dynamic_pipeline_manager);
        for (0..MAX_FRAMES_IN_FLIGHT) |FF_index| {
            try textured_renderer.updateMaterialData(@intCast(FF_index), scene.asset_manager.material_buffer.?.descriptor_info, scene.asset_manager.getTextureDescriptorArray());
        }

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

        // Use ShaderLibrary abstraction for shader loading - heap allocate for proper lifetime
        var shader_library_raytracing = ShaderLibrary.init(self.gc, self.allocator);
        const rgen_code = try std.fs.cwd().readFileAlloc(self.allocator, "shaders/RayTracingTriangle.rgen.hlsl.spv", 10 * 1024 * 1024);
        const rmiss_code = try std.fs.cwd().readFileAlloc(self.allocator, "shaders/RayTracingTriangle.rmiss.hlsl.spv", 10 * 1024 * 1024);
        const rchit_code = try std.fs.cwd().readFileAlloc(self.allocator, "shaders/RayTracingTriangle.rchit.hlsl.spv", 10 * 1024 * 1024);
        try shader_library_raytracing.add(
            &.{ rgen_code, rmiss_code, rchit_code },
            &.{
                vk.ShaderStageFlags{ .raygen_bit_khr = true },
                vk.ShaderStageFlags{ .miss_bit_khr = true },
                vk.ShaderStageFlags{ .closest_hit_bit_khr = true },
            },
            &.{
                entry_point_definition{ .name = "main" },
                entry_point_definition{ .name = "main" },
                entry_point_definition{ .name = "main" },
            },
        );

        // Initialize raytracing renderer with the correct shader library
        raytracing_renderer = try RaytracingRenderer.init(@constCast(&self.gc), self.allocator, swapchain.render_pass, shader_library_raytracing, &swapchain, thread_pool);

        // --- Raytracing pipeline setup ---
        // Use the same global descriptor set and layout as the renderer

        // Create scene bridge for render pass system and raytracing
        scene_bridge = SceneBridge.init(&scene, self.allocator);

        // Raytracing system is now integrated into the raytracing renderer
        _ = try raytracing_renderer.rt_system.updateBvhFromSceneView(@constCast(&scene_bridge.createSceneView()), true);

        // Note: TLAS creation will be handled in the update loop once BLAS is complete
        // SBT will be created by raytracing renderer when pipeline is ready

        // --- Initialize Unified Particle Renderer ---
        particle_renderer = try ParticleRenderer.init(
            self.allocator,
            &self.gc,
            &shader_manager,
            &unified_pipeline_system,
            swapchain.render_pass,
            1024, // max particles
        );

        // Register for hot reload after renderer is in final memory location
        try particle_renderer.registerHotReload();

        // Initialize particles with random data
        try particle_renderer.initializeParticles();

        log(.INFO, "app", "Unified particle renderer initialized", .{});

        // --- Compute shader system initialization ---
        compute_shader_system = try ComputeShaderSystem.init(&self.gc, &swapchain, self.allocator);

        // Keep old particle renderer for compatibility (TODO: remove when fully migrated)
        var particle_render_shader_library = ShaderLibrary.init(self.gc, self.allocator);
        // Read particle SPV files at runtime instead of @embedFile
        const prvert = try std.fs.cwd().readFileAlloc(self.allocator, "shaders/cached/particles.vert.spv", 10 * 1024 * 1024);
        const prfrag = try std.fs.cwd().readFileAlloc(self.allocator, "shaders/cached/particles.frag.spv", 10 * 1024 * 1024);

        try particle_render_shader_library.add(
            &.{ prvert, prfrag },
            &.{
                vk.ShaderStageFlags{ .vertex_bit = true },
                vk.ShaderStageFlags{ .fragment_bit = true },
            },
            &.{
                entry_point_definition{},
                entry_point_definition{},
            },
        );

        var particle_comp_shader_library = ShaderLibrary.init(self.gc, self.allocator);
        const prcomp = try std.fs.cwd().readFileAlloc(self.allocator, "shaders/cached/particles.comp.spv", 10 * 1024 * 1024);

        try particle_comp_shader_library.add(
            &.{prcomp},
            &.{
                vk.ShaderStageFlags{ .compute_bit = true },
            },
            &.{
                entry_point_definition{},
            },
        );

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
        last_frame_time = c.glfwGetTime();
        self.fps_last_time = last_frame_time; // Initialize FPS tracking
        frame_info.camera = &camera;
        // // Legacy initialization removed - descriptors updated via updateFromSceneView during rendering
        // raytracing_renderer.updateFromSceneView(0, ubo_infos[0], scene.asset_manager.material_buffer.?.descriptor_info, scene.asset_manager.getTextureDescriptorArray(), &scene_view.getRaytracingData()) catch |err| {
        //     log(.ERROR, "raytracing", "Failed to update raytracing renderer descriptors from SceneView: {}", .{err});
        // };
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

        // Check for and update any newly loaded async resources (textures, models, materials)
        // Note: Asset completion is handled automatically by the asset manager's worker thread
        var resources_updated = try scene.updateAsyncResources(self.allocator);
        // // Update BVH build status to detect completion and reset progress flag
        // _ = raytracing_system.updateBvhBuildStatus() catch |err| {
        //     log(.ERROR, "raytracing", "Failed to update BVH build status: {}", .{err});
        // };

        // Use SceneView-based BVH change detection and automatic rebuilding
        _ = raytracing_renderer.rt_system.updateBvhFromSceneView(&scene_view, resources_updated) catch |err| {
            log(.ERROR, "raytracing", "Failed to update BVH from SceneView: {}", .{err});
        };
        // Update textured renderer with any new material/texture data if resources changed
        if (resources_updated) {
            // Instead of deviceWaitIdle, just mark all frames as needing updates
            for (&self.descriptor_dirty_flags) |*flag| {
                flag.* = true;
            }

            // Clear the global flag since we've handled it
            resources_updated = false;
        }

        // Before rendering each frame, check if descriptors need updating
        if (self.descriptor_dirty_flags[(current_frame + 1) % MAX_FRAMES_IN_FLIGHT]) {
            log(.DEBUG, "app", "Updating descriptors for frame {d}", .{(current_frame + 1) % MAX_FRAMES_IN_FLIGHT});
            // Update descriptors for the next frame (prepare resources ahead of time)
            try textured_renderer.updateMaterialData(
                (current_frame + 1) % MAX_FRAMES_IN_FLIGHT,
                scene.asset_manager.material_buffer.?.descriptor_info,
                scene.asset_manager.getTextureDescriptorArray(),
            );

            // Note: raytracing_renderer descriptors are updated in updateFromSceneView() during rendering
            // No need to call updateMaterialData() here as it would be redundant

            // Mark this frame as updated
            self.descriptor_dirty_flags[(current_frame + 1) % MAX_FRAMES_IN_FLIGHT] = false;
            log(.DEBUG, "app", "The descriptor flags are: {any}, resources_updates: {any}", .{ self.descriptor_dirty_flags, resources_updated });

            // Mark raytracing renderer materials as dirty for all frames
            raytracing_renderer.markMaterialsDirty();
        }

        if (raytracing_renderer.rt_system.tlas_dirty) {
            // Update raytracing renderer's TLAS reference only when AS changes
            // Note: updateTLAS automatically marks all frames as dirty
            raytracing_renderer.updateTLAS(raytracing_renderer.rt_system.tlas);
            raytracing_renderer.rt_system.tlas_dirty = false; // Reset dirty flag after update
        }

        // Check if descriptors need updating (separate from TLAS dirty flag)
        const descriptors_need_update = raytracing_renderer.rt_system.descriptors_need_update;
        if (descriptors_need_update) {
            raytracing_renderer.markAllFramesDirty(); // Mark all frames as needing descriptor updates
        }

        // Create/update raytracing acceleration structure descriptors when TLAS is ready

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
        try particle_renderer.updateParticles(
            frame_info.compute_buffer,
            frame_info.current_frame,
            frame_info.dt,
            .{ .x = 0.0, .y = 0.0, .z = 0.0 }, // Default emitter position at center
        );

        // // Keep old particle renderer for compatibility (TODO: remove)
        // particle_renderer.dispatch();
        // compute_shader_system.dispatch(
        //     &particle_renderer.compute_pipeline,
        //     &struct { descriptor_set: vk.DescriptorSet }{ .descriptor_set = particle_renderer.descriptor_set },
        //     frame_info,
        //     .{ @intCast(particle_renderer.num_particles / 256), 1, 1 },
        // );

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

        // Update raytracing descriptors if TLAS is ready (before raytracing execution)
        if (raytracing_renderer.rt_system.completed_tlas != null) {
            const rt_data = scene_view.getRaytracingData();
            const ubo_buffer_info = global_ubo_set.*.buffers[frame_info.current_frame].descriptor_info;
            const material_buffer_info = scene.asset_manager.material_buffer.?.descriptor_info;

            try raytracing_renderer.updateFromSceneView(
                frame_info.current_frame,
                ubo_buffer_info,
                material_buffer_info,
                scene.asset_manager.getTextureDescriptorArray(),
                rt_data,
                raytracing_renderer.rt_system,
            );
        }

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

        // Descriptor set 0: Global uniforms
        const textured_descriptor_set_0 = [_]DescriptorBinding{
            DescriptorBinding{
                .binding = 0,
                .descriptor_type = .uniform_buffer,
                .descriptor_count = 1,
                .stage_flags = .{ .vertex_bit = true, .fragment_bit = true },
            },
        };

        // Descriptor set 1: Material buffer and textures
        const textured_descriptor_set_1 = [_]DescriptorBinding{
            DescriptorBinding{
                .binding = 0,
                .descriptor_type = .storage_buffer,
                .descriptor_count = 1,
                .stage_flags = .{ .fragment_bit = true },
            },
            DescriptorBinding{
                .binding = 1,
                .descriptor_type = .combined_image_sampler,
                .descriptor_count = 16,
                .stage_flags = .{ .fragment_bit = true },
            },
        };

        // Combine sets into array
        const textured_descriptor_sets = [_][]const DescriptorBinding{
            &textured_descriptor_set_0,
            &textured_descriptor_set_1,
        };

        const textured_vertex_bindings = [_]VertexInputBinding{
            VertexInputBinding{
                .binding = 0,
                .stride = @sizeOf(Vertex),
                .input_rate = .vertex,
            },
        };

        const textured_vertex_attributes = [_]VertexInputAttribute{
            VertexInputAttribute{
                .location = 0,
                .binding = 0,
                .format = .r32g32b32_sfloat,
                .offset = @offsetOf(Vertex, "pos"),
            },
            VertexInputAttribute{
                .location = 1,
                .binding = 0,
                .format = .r32g32b32_sfloat,
                .offset = @offsetOf(Vertex, "color"),
            },
            VertexInputAttribute{
                .location = 2,
                .binding = 0,
                .format = .r32g32b32_sfloat,
                .offset = @offsetOf(Vertex, "normal"),
            },
            VertexInputAttribute{
                .location = 3,
                .binding = 0,
                .format = .r32g32_sfloat,
                .offset = @offsetOf(Vertex, "uv"),
            },
        };

        const textured_push_constants = [_]PushConstantRange{
            PushConstantRange{
                .stage_flags = .{ .vertex_bit = true, .fragment_bit = true },
                .offset = 0,
                .size = @sizeOf(@import("renderers/textured_renderer.zig").TexturedPushConstantData),
            },
        };

        // Textured renderer pipeline template
        const textured_template = PipelineTemplate{
            .name = "textured_renderer",
            .vertex_shader = "shaders/textured.vert",
            .fragment_shader = "shaders/textured.frag",

            .vertex_bindings = &textured_vertex_bindings,
            .vertex_attributes = &textured_vertex_attributes,
            .descriptor_sets = &textured_descriptor_sets,
            .push_constant_ranges = &textured_push_constants,

            .depth_test_enable = true,
            .depth_write_enable = true,
            .cull_mode = .{ .back_bit = true },
            .front_face = .counter_clockwise,
        };

        try dynamic_pipeline_manager.registerPipeline(textured_template);

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

        log(.INFO, "app", "Registered pipeline templates: textured_renderer, point_light_renderer, particle_renderer", .{});
    }

    pub fn deinit(self: *App) void {
        _ = self.gc.vkd.deviceWaitIdle(self.gc.dev) catch {}; // Ensure all GPU work is finished before destroying resources

        swapchain.waitForAllFences() catch unreachable;

        // Clean up scheduled assets list
        scheduled_assets.deinit(self.allocator);

        global_ubo_set.deinit();

        // Cleanup generic renderer
        forward_renderer.deinit();

        // Shutdown thread pool first to prevent threading conflicts
        thread_pool.deinit();
        self.allocator.destroy(thread_pool);

        self.gc.destroyCommandBuffers(cmdbufs, self.allocator);

        // Clean up unified systems
        particle_renderer.deinit();
        resource_binder.deinit();
        unified_pipeline_system.deinit();

        point_light_renderer.deinit();
        textured_renderer.deinit();
        raytracing_renderer.deinit(); // This handles the integrated raytracing system cleanup

        // Cleanup heap-allocated shader library

        //particle_renderer.deinit();
        scene.deinit();

        // Clean up dynamic pipeline system
        // NOTE: Shader-pipeline integration disabled - unified pipeline system handles hot reload now
        // shader_pipeline_integration.deinit();
        dynamic_pipeline_manager.deinit();

        shader_manager.deinit();
        asset_manager.deinit();
        swapchain.deinit();
        self.gc.deinit();

        // Clean up zstbi global state
        @import("core/texture.zig").deinitZstbi();

        self.window.deinit();
    }
};

// --- User-friendly helpers for model/object creation ---
// (Moved to mesh.zig and scene.zig)
