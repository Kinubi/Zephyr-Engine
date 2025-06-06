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
const SimpleRenderer = @import("renderer.zig").SimpleRenderer;
const PointLightRenderer = @import("renderer.zig").PointLightRenderer;
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
    var compute_shader_system: ComputeShaderSystem = undefined;
    var last_frame_time: f64 = undefined;
    var camera: Camera = undefined;
    var viewer_object: *GameObject = undefined;
    var camera_controller: KeyboardMovementController = undefined;
    var global_UBO_buffers: ?[]Buffer = undefined;
    var frame_info: FrameInfo = FrameInfo{};

    var frame_index: u32 = 0;
    var scene: Scene = undefined;

    // Raytracing system field
    var global_ubo_set: GlobalUboSet = undefined;
    var raytracing_descriptor_set: RaytracingDescriptorSet = undefined;

    pub fn init(self: *@This()) !void {
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

        std.debug.print("Creating command buffers\n", .{});

        scene = Scene.init(&self.gc, self.allocator);

        var mesh3 = Mesh.init(self.allocator);
        var mesh = Mesh.init(self.allocator);

        // --- Load a texture and add it to the scene ---
        const cube_texture = try Texture.initFromFile(&self.gc, "textures/missing.png", .rgba8);
        const cube_texture_id = try scene.addTexture(cube_texture);
        // --- Create a material for the cube mesh referencing the texture ---
        const cube_material = Material{
            .albedo_texture_id = @intCast(cube_texture_id),
        };
        const cube_material_id = try scene.addMaterial(cube_material);

        // --- Assign the material to the mesh ---
        mesh3.material_id = @intCast(cube_material_id);

        // Update material and texture buffers after all materials/textures are added

        try mesh.vertices.appendSlice(&.{
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
        try mesh.indices.appendSlice(&.{ 0, 1, 2, 0, 3, 1, 4, 5, 6, 4, 7, 5, 8, 9, 10, 8, 11, 9, 12, 13, 14, 12, 15, 13, 16, 17, 18, 16, 19, 17, 20, 21, 22, 20, 23, 21 });
        try mesh.createVertexBuffers(&self.gc);
        try mesh.createIndexBuffers(&self.gc);

        // --- Load cube mesh from file instead of @embedFile ---
        log(.DEBUG, "scene", "Loading cube mesh from models/cube.obj", .{});
        const cube_data = try loadFileAlloc(self.allocator, "models/cube.obj", 10 * 1024 * 1024);
        defer self.allocator.free(cube_data);
        try mesh3.loadFromObj(self.allocator, cube_data);
        try mesh3.createVertexBuffers(&self.gc);
        try mesh3.createIndexBuffers(&self.gc);
        log(.INFO, "scene", "Loaded cube mesh and created buffers", .{});

        // --- User-friendly model+material+texture creation for the vase ---
        log(.DEBUG, "scene", "Loading vase model and texture", .{});
        const object = try scene.addModelWithMaterial(
            "models/smooth_vase.obj",
            "textures/granitesmooth1-albedo.png",
        );
        log(.INFO, "scene", "Added object with model: {d} meshes", .{if (object.model) |m| m.meshes.items.len else 0});
        object.transform.translate(Math.Vec3.init(0, -1.5, 0.5));
        object.transform.scale(Math.Vec3.init(0.5, 0.5, 0.5));

        // Use new user-friendly helpers for model/object creation
        log(.DEBUG, "scene", "Adding mesh3 as object2", .{});
        const object2 = try scene.addModelFromMesh(mesh3, "mesh3", Math.Vec3.init(0, -0.5, 0.5));
        log(.INFO, "scene", "Added object2 with model: {d} meshes", .{if (object2.model) |m| m.meshes.items.len else 0});
        object2.transform.scale(Math.Vec3.init(0.5, 0.001, 0.5));

        log(.DEBUG, "scene", "Adding mesh as object5", .{});
        const object5 = try scene.addModelFromMesh(mesh, "mesh", null);
        log(.INFO, "scene", "Added object5 with model: {d} meshes", .{if (object5.model) |m| m.meshes.items.len else 0});

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
        simple_renderer = try SimpleRenderer.init(@constCast(&self.gc), swapchain.render_pass, &scene, shader_library, self.allocator, @constCast(&camera), global_ubo_set.layout.descriptor_set_layout);

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
        point_light_renderer = try PointLightRenderer.init(@constCast(&self.gc), swapchain.render_pass, &scene, shader_library_point_light, self.allocator, @constCast(&camera), global_ubo_set.layout.descriptor_set_layout);

        var shader_library_raytracing = ShaderLibrary.init(self.gc, self.allocator);
        // Read raytracing SPV files at runtime instead of @embedFile
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
        var index_buffer_infos = std.ArrayList(vk.DescriptorBufferInfo).init(self.allocator);
        var vertex_buffer_infos = std.ArrayList(vk.DescriptorBufferInfo).init(self.allocator);
        defer index_buffer_infos.deinit();
        defer vertex_buffer_infos.deinit();
        for (scene.objects.slice()) |*obj| {
            if (obj.model) |mdl| {
                for (mdl.meshes.items) |model_mesh| {
                    const geometry = model_mesh.geometry;
                    try vertex_buffer_infos.append(geometry.mesh.vertex_buffer_descriptor);
                    try index_buffer_infos.append(geometry.mesh.index_buffer_descriptor);
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
        try raytracing_system.createBLAS(&scene);
        log(.DEBUG, "raytracing", "Creating TLAS", .{});
        try raytracing_system.createTLAS(&scene, self.allocator);
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
        // --- Compute shader system initialization ---
        compute_shader_system = try ComputeShaderSystem.init(&self.gc, &swapchain, self.allocator);
        log(.INFO, "ComputeSystem", "Compute system fully initialized", .{});
        last_frame_time = c.glfwGetTime();
        frame_info.camera = &camera;
    }

    pub fn onUpdate(self: *@This()) !bool {

        //std.debug.print("Updating frame {d}\n", .{current_frame});
        const current_time = c.glfwGetTime();
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
        compute_shader_system.endCompute(frame_info);

        //log(.TRACE, "app", "Frame start", .{});
        try swapchain.beginFrame(frame_info);
        swapchain.beginSwapChainRenderPass(frame_info);
        camera_controller.processInput(&self.window, viewer_object, dt);
        frame_info.camera.viewMatrix = viewer_object.transform.local2world;
        frame_info.camera.updateProjectionMatrix();
        var ubo = GlobalUbo{
            .view = frame_info.camera.viewMatrix,
            .projection = frame_info.camera.projectionMatrix,
        };

        try point_light_renderer.update_point_lights(&frame_info, &ubo);
        global_ubo_set.update(frame_info.current_frame, &ubo);
        //try simple_renderer.render(frame_info);
        //try point_light_renderer.render(frame_info);
        swapchain.endSwapChainRenderPass(frame_info);
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

    pub fn deinit(self: @This()) void {
        _ = self.gc.vkd.deviceWaitIdle(self.gc.dev) catch {}; // Ensure all GPU work is finished before destroying resources

        swapchain.waitForAllFences() catch unreachable;
        global_ubo_set.deinit();
        self.gc.destroyCommandBuffers(cmdbufs, self.allocator);
        point_light_renderer.deinit();
        simple_renderer.deinit();
        raytracing_system.deinit();
        scene.deinit(self.gc);
        swapchain.deinit();
        self.gc.deinit();
        self.window.deinit();
    }
};

// --- User-friendly helpers for model/object creation ---
// (Moved to mesh.zig and scene.zig)
