const std = @import("std");
const Window = @import("window.zig").Window;
const Pipeline = @import("pipeline.zig").Pipeline;
const simple_vert align(@alignOf(u32)) = @embedFile("simple_vert").*;
const simple_frag align(@alignOf(u32)) = @embedFile("simple_frag").*;
const point_light_vert align(@alignOf(u32)) = @embedFile("point_light_vert").*;
const point_light_frag align(@alignOf(u32)) = @embedFile("point_light_frag").*;
const GraphicsContext = @import("graphics_context.zig").GraphicsContext;
const Swapchain = @import("swapchain.zig").Swapchain;
const MAX_FRAMES_IN_FLIGHT = @import("swapchain.zig").MAX_FRAMES_IN_FLIGHT;
const vk = @import("vulkan");
const ShaderLibrary = @import("shader.zig").ShaderLibrary;
const entry_point_definition = @import("shader.zig").entry_point_definition;
const Vertex = @import("mesh.zig").Vertex;
const Mesh = @import("mesh.zig").Mesh;
const Model = @import("mesh.zig").Model;
const ModelMesh = @import("mesh.zig").ModelMesh;
const Scene = @import("scene.zig").Scene;
const EnhancedScene = @import("scene_enhanced.zig").EnhancedScene;
const AssetManager = @import("assets/asset_manager.zig").AssetManager;
const SimpleRenderer = @import("renderers/simple_renderer.zig").SimpleRenderer;
const PointLightRenderer = @import("renderers/point_light_renderer.zig").PointLightRenderer;
const ParticleRenderer = @import("renderers/particle_renderer.zig").ParticleRenderer;
const Math = @import("utils/math.zig");
const Camera = @import("camera.zig").Camera;
const GameObject = @import("game_object.zig").GameObject;
const KeyboardMovementController = @import("keyboard_movement_controller.zig").KeyboardMovementController;
const FrameInfo = @import("frameinfo.zig").FrameInfo;
const Texture = @import("texture.zig").Texture;
const DescriptorSetLayout = @import("descriptors.zig").DescriptorSetLayout;
const DescriptorPool = @import("descriptors.zig").DescriptorPool;
const DescriptorSetWriter = @import("descriptors.zig").DescriptorWriter;
const Buffer = @import("buffer.zig").Buffer;
const GlobalUbo = @import("frameinfo.zig").GlobalUbo;
const RaytracingSystem = @import("systems/raytracing_system.zig").RaytracingSystem;
const GlobalUboSet = @import("ubo_set.zig").GlobalUboSet;
const RaytracingDescriptorSet = @import("raytracing_descriptor_set.zig").RaytracingDescriptorSet;
const c = @cImport({
    @cInclude("GLFW/glfw3.h");
});
const Material = @import("scene.zig").Material;
const loadFileAlloc = @import("utils/file.zig").loadFileAlloc;
const log = @import("utils/log.zig").log;
const LogLevel = @import("utils/log.zig").LogLevel;
const ComputeShaderSystem = @import("systems/compute_shader_system.zig").ComputeShaderSystem;
const RenderSystem = @import("systems/render_system.zig").RenderSystem;

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
    var current_frame: u32 = 0;
    var swapchain: Swapchain = undefined;
    var cmdbufs: []vk.CommandBuffer = undefined;
    var simple_renderer: SimpleRenderer = undefined;
    var point_light_renderer: PointLightRenderer = undefined;
    var raytracing_system: RaytracingSystem = undefined;
    var particle_renderer: ParticleRenderer = undefined;
    var compute_shader_system: ComputeShaderSystem = undefined;
    var render_system: RenderSystem = undefined;
    var last_frame_time: f64 = undefined;
    var camera: Camera = undefined;
    var viewer_object: *GameObject = undefined;
    var camera_controller: KeyboardMovementController = undefined;
    var global_UBO_buffers: ?[]Buffer = undefined;
    var frame_info: FrameInfo = FrameInfo{};

    var frame_index: u32 = 0;
    var scene: EnhancedScene = undefined;
    var asset_manager: AssetManager = undefined;
    var last_performance_report: f64 = 0.0; // Track when we last printed performance stats

    // Raytracing system field
    var global_ubo_set: GlobalUboSet = undefined;
    var raytracing_descriptor_set: RaytracingDescriptorSet = undefined;

    pub fn init(self: *App) !void {
        std.debug.print("Initializing application...\n", .{});
        self.window = try Window.init(.{ .width = 1280, .height = 720 });
        std.debug.print("Window created with title: {s}\n", .{self.window.window_props.title});

        self.allocator = std.heap.page_allocator;
        std.debug.print("Updating frame {s}\n", .{"ehho"});
        self.gc = try GraphicsContext.init(self.allocator, self.window.window_props.title, @ptrCast(self.window.window.?));
        std.log.debug("Using device: {s}", .{self.gc.deviceName()});
        swapchain = try Swapchain.init(&self.gc, self.allocator, .{ .width = self.window.window_props.width, .height = self.window.window_props.height });
        std.debug.print("Updating frame {s}\n", .{"ehho"});
        try swapchain.createRenderPass();

        try swapchain.createFramebuffers();
        try self.gc.createCommandPool();
        render_system = RenderSystem.init(&self.gc, &swapchain);

        std.debug.print("Creating command buffers\n", .{});

        // Initialize Asset Manager
        asset_manager = try AssetManager.init(self.allocator);

        // Set up ThreadPool callback to monitor running status
        asset_manager.setThreadPoolCallback(onThreadPoolRunningChanged);

        // Initialize Enhanced Scene with Asset Manager integration
        scene = EnhancedScene.init(&self.gc, self.allocator, &asset_manager);

        // Enable hot reloading for development BEFORE loading assets
        scene.enableHotReload() catch |err| {
            log(.WARN, "app", "Failed to enable hot reloading: {}", .{err});
        };

        // Register scene for hot reload callbacks and set up texture reload callback
        scene.registerForHotReloadCallbacks();
        if (scene.asset_manager.hot_reload_manager) |*hr_manager| {
            hr_manager.setTextureReloadCallback(EnhancedScene.textureReloadCallbackWrapper);
        }

        // Preload textures
        if (comptime std.debug.runtime_safety) {
            scene.startAsyncTextureLoad("textures/granitesmooth1-albedo.png") catch |err| {
                log(.WARN, "app", "Failed to start async texture preload: {}", .{err});
            };

            // Show loading stats
            const stats = scene.getLoadingStats();
            log(.DEBUG, "app", "Loading stats: active={d}, completed={d}, failed={d}", .{ stats.active_loads, stats.completed_loads, stats.failed_loads });
        }

        var mesh = Mesh.init(self.allocator);

        // --- Load texture through enhanced scene system ---
        // Pre-load the texture asynchronously (if needed)
        try scene.startAsyncTextureLoad("textures/missing.png");

        // Wait a moment for async loading then use the texture
        std.Thread.sleep(50_000_000); // 50ms

        // Update material and texture buffers after all materials/textures are added

        try mesh.vertices.appendSlice(self.allocator, &.{
            // Left Face
            Vertex{ .pos = .{ -0.5, -0.5, -0.5 }, .color = .{ 0.9, 0.9, 0.9 } },
            Vertex{ .pos = .{ -0.5, 0.5, 0.5 }, .color = .{ 0.9, 0.9, 0.9 } },
            Vertex{ .pos = .{ -0.5, -0.5, 0.5 }, .color = .{ 0.9, 0.9, 0.9 } },
            Vertex{ .pos = .{ -0.5, 0.5, -0.5 }, .color = .{ 0.9, 0.9, 0.9 } },

            // Right face (yellow)
            Vertex{ .pos = .{ 0.5, -0.5, -0.5 }, .color = .{ 0.8, 0.8, 0.1 } },
            Vertex{ .pos = .{ 0.5, 0.5, 0.5 }, .color = .{ 0.8, 0.8, 0.1 } },
            Vertex{ .pos = .{ 0.5, -0.5, 0.5 }, .color = .{ 0.8, 0.8, 0.1 } },
            Vertex{ .pos = .{ 0.5, 0.5, -0.5 }, .color = .{ 0.8, 0.8, 0.1 } },

            // Top face (orange, remember y axis points down)
            Vertex{ .pos = .{ -0.5, -0.5, -0.5 }, .color = .{ 0.9, 0.6, 0.1 } },
            Vertex{ .pos = .{ 0.5, -0.5, 0.5 }, .color = .{ 0.9, 0.6, 0.1 } },
            Vertex{ .pos = .{ -0.5, -0.5, 0.5 }, .color = .{ 0.9, 0.6, 0.1 } },
            Vertex{ .pos = .{ 0.5, -0.5, -0.5 }, .color = .{ 0.9, 0.6, 0.1 } },

            // Bottom face (red)
            Vertex{ .pos = .{ -0.5, 0.5, -0.5 }, .color = .{ 0.8, 0.1, 0.1 } },
            Vertex{ .pos = .{ 0.5, 0.5, 0.5 }, .color = .{ 0.8, 0.1, 0.1 } },
            Vertex{ .pos = .{ -0.5, 0.5, 0.5 }, .color = .{ 0.8, 0.1, 0.1 } },
            Vertex{ .pos = .{ 0.5, 0.5, -0.5 }, .color = .{ 0.8, 0.1, 0.1 } },

            // Front Face
            Vertex{ .pos = .{ -0.5, -0.5, 0.5 }, .color = .{ 0.1, 0.8, 0.1 } },
            Vertex{ .pos = .{ 0.5, 0.5, 0.5 }, .color = .{ 0.1, 0.8, 0.1 } },
            Vertex{ .pos = .{ -0.5, 0.5, 0.5 }, .color = .{ 0.1, 0.8, 0.1 } },
            Vertex{ .pos = .{ 0.5, -0.5, 0.5 }, .color = .{ 0.1, 0.8, 0.1 } },

            // Back Face
            Vertex{ .pos = .{ -0.5, -0.5, -0.5 }, .color = .{ 0.1, 0.1, 0.8 } },
            Vertex{ .pos = .{ 0.5, 0.5, -0.5 }, .color = .{ 0.1, 0.1, 0.8 } },
            Vertex{ .pos = .{ -0.5, 0.5, -0.5 }, .color = .{ 0.1, 0.1, 0.8 } },
            Vertex{ .pos = .{ 0.5, -0.5, -0.5 }, .color = .{ 0.1, 0.1, 0.8 } },
        });
        try mesh.indices.appendSlice(self.allocator, &.{ 0, 1, 2, 0, 3, 1, 4, 5, 6, 4, 7, 5, 8, 9, 10, 8, 11, 9, 12, 13, 14, 12, 15, 13, 16, 17, 18, 16, 19, 17, 20, 21, 22, 20, 23, 21 });
        try mesh.createVertexBuffers(&self.gc);
        try mesh.createIndexBuffers(&self.gc);

        // --- Load cube mesh using non-blocking enhanced scene system ---
        log(.DEBUG, "scene", "Loading cube with fallback through enhanced scene", .{});
        const cube_object = try scene.addModelWithMaterialAndTransformAsync("models/cube.obj", "textures/missing.png", Math.Vec3.init(0, -0.5, 0.5), // position
            Math.Vec3.init(0.5, 0.001, 0.5) // scale
        );
        log(.INFO, "scene", "Added cube object (fallback) with {d} meshes", .{if (cube_object.model) |m| m.meshes.items.len else 0});

        // Give async texture loading a moment to complete
        std.Thread.sleep(100_000_000); // 100ms

        // Update async textures for Vulkan descriptors (must be done on main thread)
        try scene.updateAsyncTextures(self.allocator);

        // --- User-friendly model+material+texture creation for the vase ---
        log(.DEBUG, "scene", "Loading vase model and texture", .{});
        const object = try scene.addModelWithMaterialAndTransform(
            "models/smooth_vase.obj",
            "textures/granitesmooth1-albedo.png",
            Math.Vec3.init(0, -1.5, 0.5),
            Math.Vec3.init(0.5, 0.5, 0.5),
        );
        log(.INFO, "scene", "Added object with model: {d} meshes", .{if (object.model) |m| m.meshes.items.len else 0});

        // Cube is now handled by enhanced scene system above

        // Create another textured cube with a different texture (non-blocking)
        log(.DEBUG, "scene", "Adding second cube with different texture (fallback)", .{});
        const cube2_object = try scene.addModelWithMaterialAndTransformAsync("models/cube.obj", "textures/default.png", Math.Vec3.init(1.0, -0.5, 0.5), // Different position
            Math.Vec3.init(0.3, 0.3, 0.3) // Different scale
        );
        log(.INFO, "scene", "Added second cube object (fallback) with {d} meshes", .{if (cube2_object.model) |m| m.meshes.items.len else 0});

        // Create a procedural mesh using the manual mesh (for demonstration)
        log(.DEBUG, "scene", "Adding procedural mesh as object5", .{});
        const object5 = try scene.addModelFromMesh(mesh, "procedural_mesh", null);
        log(.INFO, "scene", "Added procedural object with {d} meshes", .{if (object5.model) |m| m.meshes.items.len else 0});

        // Add another vase with a different texture (non-blocking fallback)
        log(.DEBUG, "scene", "Adding second vase with error texture (fallback)", .{});
        const vase2_object = try scene.addModelWithMaterialAndTransformAsync("models/smooth_vase.obj", "textures/deah.png", Math.Vec3.init(-1.0, -1.5, 0.5), // Different position
            Math.Vec3.init(0.3, 0.3, 0.3) // Different scale
        );
        log(.INFO, "scene", "Added second vase object (fallback) with {d} meshes", .{if (vase2_object.model) |m| m.meshes.items.len else 0});

        log(.DEBUG, "scene", "Adding point light objects", .{});
        const object3 = try scene.addObject(null, .{ .color = Math.Vec3.init(0.2, 0.5, 1.0), .intensity = 1.0 });
        object3.transform.translate(Math.Vec3.init(0.5, 0.5, 0.5));
        object3.transform.scale(Math.Vec3.init(0.5, 0.5, 0.5));

        const object4 = try scene.addObject(null, .{ .color = Math.Vec3.init(0.5, 0.2, 0.2), .intensity = 1.0 });
        object4.transform.translate(Math.Vec3.init(0, -1, 0.5));
        object4.transform.scale(Math.Vec3.init(0.05, 0, 0));

        log(.DEBUG, "renderer", "Creating command buffers", .{});
        cmdbufs = try self.gc.createCommandBuffers(
            self.allocator,
        );

        log(.DEBUG, "scene", "Adding viewer object and camera controller", .{});
        viewer_object = try scene.addEmpty();
        camera_controller = KeyboardMovementController.init();

        camera = Camera{ .fov = 75.0, .window = self.window };
        camera.updateProjectionMatrix();
        camera.setViewDirection(Math.Vec3.init(0, 0, 0), Math.Vec3.init(0, 0, 1), Math.Vec3.init(0, 1, 0));

        // --- Use new GlobalUboSet abstraction ---
        log(.DEBUG, "renderer", "Initializing GlobalUboSet", .{});
        global_ubo_set = try GlobalUboSet.init(&self.gc, self.allocator);
        frame_info.global_descriptor_set = global_ubo_set.sets[0];

        var shader_library = ShaderLibrary.init(self.gc, self.allocator);

        try shader_library.add(&.{
            &simple_frag,
            &simple_vert,
        }, &.{
            vk.ShaderStageFlags{ .fragment_bit = true },
            vk.ShaderStageFlags{ .vertex_bit = true },
        }, &.{
            entry_point_definition{},
            entry_point_definition{},
        });
        log(.DEBUG, "renderer", "Initializing simple renderer", .{});
        simple_renderer = try SimpleRenderer.init(@constCast(&self.gc), swapchain.render_pass, scene.asScene(), shader_library, self.allocator, @constCast(&camera), global_ubo_set.layout.descriptor_set_layout);

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
        log(.DEBUG, "renderer", "Initializing point light renderer", .{});
        point_light_renderer = try PointLightRenderer.init(@constCast(&self.gc), swapchain.render_pass, scene.asScene(), shader_library_point_light, self.allocator, @constCast(&camera), global_ubo_set.layout.descriptor_set_layout);

        // Use ShaderLibrary abstraction for shader loading
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

        // --- Raytracing pipeline setup ---
        // Use the same global descriptor set and layout as the renderer

        // Initialize RaytracingSystem with the created resources
        // --- Raytracing pool and layout creation (before RaytracingSystem.init) ---
        // --- Collect buffer infos for raytracing descriptors before pool/layout creation ---
        // Use abstractions for buffer and descriptor management
        var index_buffer_infos = std.ArrayList(vk.DescriptorBufferInfo){};
        var vertex_buffer_infos = std.ArrayList(vk.DescriptorBufferInfo){};
        defer index_buffer_infos.deinit(self.allocator);
        defer vertex_buffer_infos.deinit(self.allocator);
        for (scene.objects.items) |*obj| {
            if (obj.model) |mdl| {
                for (mdl.meshes.items) |model_mesh| {
                    const geometry = model_mesh.geometry;
                    if (geometry.mesh.vertex_buffer) |buf| {
                        try vertex_buffer_infos.append(self.allocator, buf.descriptor_info);
                    }
                    if (geometry.mesh.index_buffer) |buf| {
                        try index_buffer_infos.append(self.allocator, buf.descriptor_info);
                    }
                }
            }
        }
        const rt_counts = .{
            .ubo_count = global_ubo_set.buffers.len,
            .vertex_buffer_count = vertex_buffer_infos.items.len,
            .index_buffer_count = index_buffer_infos.items.len,
        };
        const rt_pool_layout = try RaytracingDescriptorSet.createPoolAndLayout(
            &self.gc,
            self.allocator,
            rt_counts.ubo_count,
            rt_counts.vertex_buffer_count,
            rt_counts.index_buffer_count,
            scene.materials.items.len,
            scene.textures.items.len,
        );

        // --- RaytracingSystem init with pool/layout ---
        raytracing_system = try RaytracingSystem.init(
            &self.gc,
            swapchain.render_pass,
            shader_library_raytracing,
            self.allocator,
            rt_pool_layout.layout,
            rt_pool_layout.pool,
            &swapchain,
            self.window.window_props.width,
            self.window.window_props.height,
        );

        log(.DEBUG, "raytracing", "Creating BLAS", .{});
        try raytracing_system.createBLAS(scene.asScene());
        log(.DEBUG, "raytracing", "Creating TLAS", .{});
        try raytracing_system.createTLAS(scene.asScene());
        log(.DEBUG, "raytracing", "Creating Shader Binding Table", .{});
        try raytracing_system.createShaderBindingTable(3);
        // --- After RaytracingSystem has valid AS and image, create descriptor set ---
        log(.DEBUG, "raytracing", "Creating raytracing descriptor set", .{});
        const as_info = try raytracing_system.getAccelerationStructureDescriptorInfo();
        const image_info = try raytracing_system.getOutputImageDescriptorInfo();
        var ubo_infos = try self.allocator.alloc(vk.DescriptorBufferInfo, global_ubo_set.buffers.len);
        defer self.allocator.free(ubo_infos);
        for (global_ubo_set.buffers, 0..) |buf, i| {
            ubo_infos[i] = buf.descriptor_info;
        }
        raytracing_descriptor_set.set = try RaytracingDescriptorSet.createDescriptorSet(
            &self.gc,
            rt_pool_layout.pool,
            rt_pool_layout.layout,
            self.allocator,
            @constCast(&as_info),
            @constCast(&image_info),
            ubo_infos,
            vertex_buffer_infos.items,
            index_buffer_infos.items,
            scene.material_buffer.?.descriptor_info,
            scene.texture_image_infos,
        );
        raytracing_descriptor_set.pool = rt_pool_layout.pool;
        raytracing_descriptor_set.layout = rt_pool_layout.layout;
        raytracing_system.descriptor_set = raytracing_descriptor_set.set;
        raytracing_system.descriptor_set_layout = raytracing_descriptor_set.layout;
        raytracing_system.descriptor_pool = raytracing_descriptor_set.pool;
        log(.INFO, "RaytracingSysem", "Raytracing system fully initialized", .{});

        // Register raytracing system with enhanced scene for texture updates
        scene.setRaytracingSystem(&raytracing_system);

        // --- Compute shader system initialization ---
        compute_shader_system = try ComputeShaderSystem.init(&self.gc, &swapchain, self.allocator);
        var particle_render_shader_library = ShaderLibrary.init(self.gc, self.allocator);
        // Read raytracing SPV files at runtime instead of @embedFile
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
        // Read raytracing SPV files at runtime instead of @embedFile
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

        particle_renderer = try ParticleRenderer.init(
            &self.gc,
            swapchain.render_pass,
            particle_render_shader_library,
            particle_comp_shader_library,
            self.allocator,
            1024,
            ubo_infos,
        );
        log(.INFO, "ComputeSystem", "Compute system fully initialized", .{});
        last_frame_time = c.glfwGetTime();
        frame_info.camera = &camera;
    }

    pub fn onUpdate(self: *App) !bool {
        // Process any pending hot reloads first
        scene.processPendingReloads();

        //std.debug.print("Updating frame {d}\n", .{current_frame});
        const current_time = c.glfwGetTime();

        // Print performance report every 10 seconds in debug builds
        if (comptime std.debug.runtime_safety) {
            if (current_time - last_performance_report >= 10.0) {
                asset_manager.printPerformanceReport();
                last_performance_report = current_time;
            }
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
        // Each compute system will dispatch its own compute shader
        particle_renderer.dispatch();
        compute_shader_system.dispatch(
            &particle_renderer.compute_pipeline,
            &struct { descriptor_set: vk.DescriptorSet }{ .descriptor_set = particle_renderer.descriptor_set },
            frame_info,
            .{ @intCast(particle_renderer.num_particles / 256), 1, 1 },
        );
        compute_shader_system.endCompute(frame_info);

        //log(.TRACE, "app", "Frame start", .{});
        try swapchain.beginFrame(frame_info);
        render_system.beginRender(frame_info);
        camera_controller.processInput(&self.window, viewer_object, dt);
        frame_info.camera.viewMatrix = viewer_object.transform.local2world;
        frame_info.camera.updateProjectionMatrix();
        var ubo = GlobalUbo{
            .view = frame_info.camera.viewMatrix,
            .projection = frame_info.camera.projectionMatrix,
            .dt = @floatCast(dt),
        };
        try point_light_renderer.update_point_lights(&frame_info, &ubo);
        global_ubo_set.update(frame_info.current_frame, &ubo);
        //try simple_renderer.render(frame_info);
        //try point_light_renderer.render(frame_info);
        //try particle_renderer.render(frame_info);
        render_system.endRender(frame_info);
        try raytracing_system.recordCommandBuffer(
            frame_info,
            &swapchain,
            3,
            global_ubo_set.buffers[frame_info.current_frame].descriptor_info,
            scene.material_buffer.?.descriptor_info,
            scene.texture_image_infos,
        );
        try swapchain.endFrame(frame_info, &current_frame);
        last_frame_time = current_time;
        //log(.TRACE, "app", "Frame end", .{});
        return self.window.isRunning();
    }

    pub fn deinit(self: *App) void {
        _ = self.gc.vkd.deviceWaitIdle(self.gc.dev) catch {}; // Ensure all GPU work is finished before destroying resources

        swapchain.waitForAllFences() catch unreachable;
        global_ubo_set.deinit();
        self.gc.destroyCommandBuffers(cmdbufs, self.allocator);
        point_light_renderer.deinit();
        simple_renderer.deinit();
        raytracing_system.deinit();
        particle_renderer.deinit();
        scene.deinit();
        asset_manager.deinit();
        swapchain.deinit();
        self.gc.deinit();

        // Clean up zstbi global state
        @import("texture.zig").deinitZstbi();

        self.window.deinit();
    }
};

// --- User-friendly helpers for model/object creation ---
// (Moved to mesh.zig and scene.zig)
