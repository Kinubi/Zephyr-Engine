const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("../core/graphics_context.zig").GraphicsContext;
const Buffer = @import("../core/buffer.zig").Buffer;
const Scene = @import("../scene/scene.zig").Scene;
const Vertex = @import("../rendering/mesh.zig").Vertex;
const FrameInfo = @import("../rendering/frameinfo.zig").FrameInfo;
const Pipeline = @import("../core/pipeline.zig").Pipeline;
const ShaderLibrary = @import("../core/shader.zig").ShaderLibrary;
const Swapchain = @import("../core/swapchain.zig").Swapchain;
const DescriptorWriter = @import("../core/descriptors.zig").DescriptorWriter;
const DescriptorSetLayout = @import("../core/descriptors.zig").DescriptorSetLayout;
const DescriptorPool = @import("../core/descriptors.zig").DescriptorPool;
const GlobalUbo = @import("../rendering/frameinfo.zig").GlobalUbo;
const Texture = @import("../core/texture.zig").Texture;
const log = @import("../utils/log.zig").log;
const LogLevel = @import("../utils/log.zig").LogLevel;
const deinitDescriptorResources = @import("../core/descriptors.zig").deinitDescriptorResources;
const ThreadPool = @import("../threading/thread_pool.zig").ThreadPool;

// Import the new multithreaded BVH builder
const MultithreadedBvhBuilder = @import("multithreaded_bvh_builder.zig").MultithreadedBvhBuilder;
const BlasResult = @import("multithreaded_bvh_builder.zig").BlasResult;
const TlasResult = @import("multithreaded_bvh_builder.zig").TlasResult;
const GeometryData = @import("multithreaded_bvh_builder.zig").GeometryData;
const InstanceData = @import("multithreaded_bvh_builder.zig").InstanceData;
const BvhBuildResult = @import("multithreaded_bvh_builder.zig").BvhBuildResult;

fn alignForward(val: usize, alignment: usize) usize {
    return ((val + alignment - 1) / alignment) * alignment;
}

/// Enhanced Raytracing system with multithreaded BVH building
pub const RaytracingSystem = struct {
    gc: *GraphicsContext, // Use 'gc' for consistency with Swapchain
    pipeline: Pipeline = undefined,
    pipeline_layout: vk.PipelineLayout = undefined,
    output_texture: Texture = undefined,

    // Legacy single AS support (for compatibility)
    blas: vk.AccelerationStructureKHR = undefined,
    tlas: vk.AccelerationStructureKHR = undefined,
    tlas_buffer: Buffer = undefined,
    tlas_buffer_initialized: bool = false,
    tlas_instance_buffer: Buffer = undefined,
    tlas_instance_buffer_initialized: bool = false,

    // New multithreaded BVH system
    bvh_builder: *MultithreadedBvhBuilder = undefined,
    completed_blas_list: std.ArrayList(BlasResult) = undefined,
    completed_tlas: ?TlasResult = null,
    bvh_build_in_progress: bool = false,
    bvh_rebuild_pending: bool = false,

    shader_binding_table: vk.Buffer = undefined,
    shader_binding_table_memory: vk.DeviceMemory = undefined,
    current_frame_index: usize = 0,
    frame_count: usize = 0,
    descriptor_set: vk.DescriptorSet = undefined,
    descriptor_set_layout: *DescriptorSetLayout = undefined, // pointer, not value
    descriptor_pool: *DescriptorPool = undefined,
    width: u32 = 1280,
    height: u32 = 720,

    // Legacy BLAS arrays (for compatibility)
    blas_handles: std.ArrayList(vk.AccelerationStructureKHR) = undefined,
    blas_buffers: std.ArrayList(Buffer) = undefined,
    allocator: std.mem.Allocator = undefined,

    // Texture update tracking
    descriptors_need_update: bool = false,

    /// Enhanced init with multithreaded BVH support
    pub fn init(
        gc: *GraphicsContext,
        render_pass: vk.RenderPass,
        shader_library: ShaderLibrary,
        allocator: std.mem.Allocator,
        descriptor_set_layout: *DescriptorSetLayout,
        descriptor_pool: *DescriptorPool,
        swapchain: *Swapchain,
        width: u32,
        height: u32,
        thread_pool: *ThreadPool,
    ) !RaytracingSystem {
        const dsl = [_]vk.DescriptorSetLayout{descriptor_set_layout.descriptor_set_layout};
        const layout = try gc.*.vkd.createPipelineLayout(
            gc.*.dev,
            &vk.PipelineLayoutCreateInfo{
                .flags = .{},
                .set_layout_count = dsl.len,
                .p_set_layouts = &dsl,
                .push_constant_range_count = 0,
                .p_push_constant_ranges = null,
            },
            null,
        );
        const pipeline = try Pipeline.initRaytracing(gc.*, render_pass, shader_library, layout, Pipeline.defaultRaytracingLayout(layout), allocator);

        // Create output image using Texture abstraction
        std.debug.print("Swapchain surface format: {}\n", .{swapchain.surface_format.format});
        var output_format = swapchain.surface_format.format;
        if (output_format == vk.Format.a2r10g10b10_unorm_pack32) {
            output_format = vk.Format.a2b10g10r10_unorm_pack32;
        }
        const output_texture = try Texture.init(
            gc,
            output_format,
            .{ .width = width, .height = height, .depth = 1 },
            vk.ImageUsageFlags{
                .storage_bit = true,
                .transfer_src_bit = true,
                .transfer_dst_bit = true,
                .sampled_bit = true,
            },
            vk.SampleCountFlags{ .@"1_bit" = true },
        );

        // Initialize multithreaded BVH builder (heap allocated)
        const bvh_builder = try allocator.create(MultithreadedBvhBuilder);
        bvh_builder.* = try MultithreadedBvhBuilder.init(gc, thread_pool, allocator);

        return RaytracingSystem{
            .gc = gc,
            .pipeline = pipeline,
            .pipeline_layout = layout,
            .output_texture = output_texture,
            .bvh_builder = bvh_builder,
            .completed_blas_list = std.ArrayList(BlasResult){},
            .completed_tlas = null,
            .bvh_build_in_progress = false,
            .bvh_rebuild_pending = false,
            .descriptor_set_layout = descriptor_set_layout,
            .descriptor_pool = descriptor_pool,
            .width = width,
            .height = height,
            .blas_handles = try std.ArrayList(vk.AccelerationStructureKHR).initCapacity(allocator, 8),
            .blas_buffers = try std.ArrayList(Buffer).initCapacity(allocator, 8),
            .allocator = allocator,
            .descriptors_need_update = false,
            .tlas_buffer_initialized = false,
            .tlas_instance_buffer_initialized = false,
            .current_frame_index = 0,
            .frame_count = 0,
            .blas = vk.AccelerationStructureKHR.null_handle,
            .tlas = vk.AccelerationStructureKHR.null_handle,
            .tlas_buffer = undefined,
            .tlas_instance_buffer = undefined,
            .shader_binding_table = vk.Buffer.null_handle,
            .shader_binding_table_memory = vk.DeviceMemory.null_handle,
            .descriptor_set = vk.DescriptorSet.null_handle,
        };
    }

    /// Create BLAS asynchronously using pre-computed raytracing data from SceneView
    pub fn createBlasAsyncFromRtData(self: *RaytracingSystem, rt_data: @import("../rendering/scene_view.zig").RaytracingData, completion_callback: ?*const fn (*anyopaque, []const BlasResult, ?TlasResult) void, callback_context: ?*anyopaque) !void {
        if (self.bvh_build_in_progress) {
            log(.WARN, "RaytracingSystem", "BVH build in progress - superseding with new build for {} geometries", .{rt_data.geometries.len});
            // Reset progress flag to allow new build to supersede
            self.bvh_build_in_progress = false;
        }

        self.bvh_build_in_progress = true;
        log(.INFO, "RaytracingSystem", "Starting async BLAS creation for {} geometries using pre-computed RT data with mesh pointers", .{rt_data.geometries.len});

        try self.bvh_builder.buildRtDataBvhAsync(rt_data, completion_callback, callback_context);
    }

    /// Create BLAS asynchronously using the multithreaded builder (legacy)
    pub fn createBlasAsync(self: *RaytracingSystem, scene: *Scene, completion_callback: ?*const fn (*anyopaque, []const BlasResult, ?TlasResult) void, callback_context: ?*anyopaque) !void {
        if (self.bvh_build_in_progress) {
            log(.WARN, "RaytracingSystem", "BVH build in progress - superseding with new build for {} objects (legacy)", .{scene.objects.items.len});
            // Reset progress flag to allow new build to supersede
            self.bvh_build_in_progress = false;
        }

        self.bvh_build_in_progress = true;
        log(.INFO, "RaytracingSystem", "Starting async BLAS creation for {} objects (legacy)", .{scene.objects.items.len});

        try self.bvh_builder.buildSceneBvhAsync(scene, completion_callback, callback_context);
    }

    /// Create TLAS asynchronously using pre-computed raytracing data from SceneView
    pub fn createTlasAsyncFromRtData(self: *RaytracingSystem, rt_data: @import("../rendering/scene_view.zig").RaytracingData, completion_callback: ?*const fn (*anyopaque, BvhBuildResult) void, callback_context: ?*anyopaque) !void {
        // Wait for BLAS to complete first
        // if (!self.bvh_builder.isWorkComplete()) {
        //     log(.WARN, "RaytracingSystem", "BLAS builds still in progress, cannot create TLAS yet", .{});
        //     return error.BlasNotReady;
        // }

        // Get completed BLAS results
        const blas_results = try self.bvh_builder.getCompletedBlas(self.allocator);
        defer self.allocator.free(blas_results);

        if (blas_results.len == 0) {
            log(.WARN, "RaytracingSystem", "No BLAS results available for TLAS creation", .{});
            return error.NoBlasResults;
        }

        log(.DEBUG, "RaytracingSystem", "Creating TLAS instances from {} BLAS results and {} RT instances", .{ blas_results.len, rt_data.instances.len });

        // Create instance data from RT data and BLAS results
        var instances = std.ArrayList(InstanceData){};
        defer instances.deinit(self.allocator);

        // Match RT instances to BLAS results by geometry_id
        for (rt_data.instances, 0..) |rt_instance, rt_index| {
            // Find the corresponding BLAS result for this RT instance by geometry_id
            var found_blas: ?BlasResult = null;
            for (blas_results) |blas_result| {
                // Match by geometry_id (which corresponds to the RT geometry index)
                if (blas_result.geometry_id == rt_index) {
                    found_blas = blas_result;
                    break;
                }
            }

            if (found_blas) |blas_result| {
                const clamped_material_id = @min(rt_instance.material_index, 255); // Clamp to 8 bits for safety
                log(.DEBUG, "RaytracingSystem", "RT instance {}: material_id={} -> clamped={}, blas_geometry_id={}", .{ rt_index, rt_instance.material_index, clamped_material_id, blas_result.geometry_id });

                // Convert [12]f32 to [3][4]f32 matrix format
                const transform_matrix: [3][4]f32 = .{
                    .{ rt_instance.transform[0], rt_instance.transform[1], rt_instance.transform[2], rt_instance.transform[3] },
                    .{ rt_instance.transform[4], rt_instance.transform[5], rt_instance.transform[6], rt_instance.transform[7] },
                    .{ rt_instance.transform[8], rt_instance.transform[9], rt_instance.transform[10], rt_instance.transform[11] },
                };

                const instance_data = InstanceData{
                    .blas_address = blas_result.device_address,
                    .transform = transform_matrix,
                    .custom_index = clamped_material_id,
                    .mask = 0xFF,
                    .sbt_offset = 0,
                    .flags = 0,
                };

                try instances.append(self.allocator, instance_data);
            } else {
                log(.WARN, "RaytracingSystem", "No BLAS found for RT instance {} (geometry_id={})", .{ rt_index, rt_index });
            }
        }

        log(.DEBUG, "RaytracingSystem", "RT data analysis: {} total instances, {} BLAS results, {} instances created", .{ rt_data.instances.len, blas_results.len, instances.items.len });

        if (instances.items.len == 0) {
            log(.ERROR, "RaytracingSystem", "No instances created for TLAS from RT data! Check if RT instances match BLAS count", .{});
            return error.NoInstances;
        }

        log(.INFO, "RaytracingSystem", "Creating TLAS with {} instances from RT data", .{instances.items.len});
        _ = try self.bvh_builder.buildTlasAsync(instances.items, .high, completion_callback, callback_context);
    }

    /// Create TLAS asynchronously after BLAS completion
    pub fn createTlasAsync(self: *RaytracingSystem, scene: *Scene, completion_callback: ?*const fn (*anyopaque, BvhBuildResult) void, callback_context: ?*anyopaque) !void {
        // Wait for BLAS to complete first
        if (!self.bvh_builder.isWorkComplete()) {
            log(.WARN, "RaytracingSystem", "BLAS builds still in progress, cannot create TLAS yet", .{});
            return error.BlasNotReady;
        }

        // Get completed BLAS results
        const blas_results = try self.bvh_builder.getCompletedBlas(self.allocator);
        defer self.allocator.free(blas_results);

        if (blas_results.len == 0) {
            log(.WARN, "RaytracingSystem", "No BLAS results available for TLAS creation", .{});
            return error.NoBlasResults;
        }

        log(.DEBUG, "RaytracingSystem", "Creating TLAS instances from {} BLAS results and {} scene objects", .{ blas_results.len, scene.objects.items.len });

        // Create instance data from scene and BLAS results
        var instances = std.ArrayList(InstanceData){};
        defer instances.deinit(self.allocator);

        var blas_index: usize = 0;
        var objects_with_model: u32 = 0;
        for (scene.objects.items) |*object| {
            // Check for both direct model pointers and asset-based models
            const has_model = (object.model != null) or (object.has_model and object.model_asset != null);

            if (has_model) {
                objects_with_model += 1;

                if (object.model) |model| {
                    // Handle direct model pointers (legacy path)
                    for (model.meshes.items) |*model_mesh| {
                        if (blas_index >= blas_results.len) break;

                        const blas_result = blas_results[blas_index];
                        const clamped_material_id = @min(model_mesh.geometry.mesh.material_id, 255); // Clamp to 8 bits for safety
                        log(.DEBUG, "RaytracingSystem", "Legacy object material_id: {} -> clamped: {}", .{ model_mesh.geometry.mesh.material_id, clamped_material_id });

                        const instance_data = InstanceData{
                            .blas_address = blas_result.device_address,
                            .transform = object.transform.local2world.to_3x4(),
                            .custom_index = clamped_material_id,
                            .mask = 0xFF,
                            .sbt_offset = 0,
                            .flags = 0,
                        };

                        try instances.append(self.allocator, instance_data);
                        blas_index += 1;
                    }
                } else if (object.model_asset) |model_asset_id| {
                    // Handle asset-based models (new path)
                    const resolved_asset_id = scene.asset_manager.getAssetIdForRendering(model_asset_id);

                    // Get the model from asset manager to count meshes
                    if (scene.asset_manager.getModel(resolved_asset_id)) |model| {
                        if (model.meshes.items.len > 0) {
                            for (model.meshes.items) |*model_mesh| {
                                if (blas_index >= blas_results.len) break;

                                const blas_result = blas_results[blas_index];
                                const clamped_material_id = @min(model_mesh.geometry.mesh.material_id, 255); // Clamp to 8 bits for safety
                                log(.DEBUG, "RaytracingSystem", "Object material_id: {} -> clamped: {}", .{ model_mesh.geometry.mesh.material_id, clamped_material_id });

                                const instance_data = InstanceData{
                                    .blas_address = blas_result.device_address,
                                    .transform = object.transform.local2world.to_3x4(),
                                    .custom_index = clamped_material_id,
                                    .mask = 0xFF,
                                    .sbt_offset = 0,
                                    .flags = 0,
                                };

                                try instances.append(self.allocator, instance_data);
                                blas_index += 1;
                            }
                        }
                    } else {
                        log(.WARN, "RaytracingSystem", "Asset-based object has unresolved model asset: {}", .{model_asset_id});
                    }
                }
            }
        }

        log(.DEBUG, "RaytracingSystem", "Scene analysis: {} total objects, {} with models, {} instances created", .{ scene.objects.items.len, objects_with_model, instances.items.len });

        if (instances.items.len == 0) {
            log(.ERROR, "RaytracingSystem", "No instances created for TLAS! Check if scene objects have valid models with meshes", .{});
            return error.NoInstances;
        }

        log(.INFO, "RaytracingSystem", "Creating TLAS with {} instances", .{instances.items.len});
        _ = try self.bvh_builder.buildTlasAsync(instances.items, .high, completion_callback, callback_context);
    }

    /// Check if BVH build is complete and update internal state
    pub fn updateBvhBuildStatus(self: *RaytracingSystem) !bool {
        if (!self.bvh_build_in_progress) return true;

        if (self.bvh_builder.isWorkComplete()) {
            // Update our internal state with completed results
            const blas_results = try self.bvh_builder.getCompletedBlas(self.allocator);

            // Update legacy arrays for compatibility
            self.blas_handles.clearRetainingCapacity();
            self.blas_buffers.clearRetainingCapacity();

            for (blas_results) |blas_result| {
                try self.blas_handles.append(self.allocator, blas_result.acceleration_structure);
                try self.blas_buffers.append(self.allocator, blas_result.buffer);
            }

            // Check if we should trigger TLAS creation now that BLAS is complete
            const blas_count = blas_results.len;
            self.allocator.free(blas_results);

            // Update TLAS if available
            if (self.bvh_builder.getCompletedTlas()) |tlas_result| {
                self.tlas = tlas_result.acceleration_structure;
                self.tlas_buffer = tlas_result.buffer;
                self.tlas_instance_buffer = tlas_result.instance_buffer;
                self.tlas_buffer_initialized = true;
                self.tlas_instance_buffer_initialized = true;
                self.completed_tlas = tlas_result;

                // Mark descriptors as needing update since we have a new TLAS
                self.descriptors_need_update = true;

                log(.INFO, "RaytracingSystem", "TLAS completed and ready for rendering!", .{});
            } else if (blas_count > 0) {
                // BLAS is complete but no TLAS yet - we need a scene reference to build TLAS
                // This will be handled by the scene view update mechanism
                log(.INFO, "RaytracingSystem", "BLAS completed ({}), waiting for TLAS creation trigger from scene", .{blas_count});
            }

            self.bvh_build_in_progress = false;

            // Check if there's a pending rebuild request
            if (self.bvh_rebuild_pending) {
                log(.INFO, "RaytracingSystem", "BVH build completed, but rebuild is pending due to scene changes during build", .{});
                self.bvh_rebuild_pending = false;
                // The next frame's updateBvhFromSceneView call will detect the changes and trigger a new rebuild
            }

            // Print performance metrics
            const metrics = self.bvh_builder.getPerformanceMetrics();
            log(.INFO, "RaytracingSystem", "BVH build completed: {} BLAS built in {d:.2}ms (avg: {d:.2}ms per BLAS)", .{
                metrics.total_blas_built,
                @as(f64, @floatFromInt(metrics.total_build_time_ns)) / 1_000_000.0,
                @as(f64, @floatFromInt(metrics.average_build_time_ns)) / 1_000_000.0,
            });

            return true;
        }

        return false;
    }

    /// Check if BVH needs updating using SceneView with simplified TLAS triggering logic
    pub fn updateBvhFromSceneView(self: *RaytracingSystem, scene_view: *@import("../rendering/render_pass.zig").SceneView, resources_updated: bool) !bool {
        // Check if there's a pending rebuild that can now be started (build completed)
        if (self.bvh_rebuild_pending and !self.bvh_build_in_progress) {
            log(.INFO, "raytracing", "🔄 Starting pending BVH rebuild after previous build completed", .{});
            self.bvh_rebuild_pending = false;
            // Force a rebuild by calling this function recursively with the current scene state
            return try self.updateBvhFromSceneView(scene_view, true); // Force resources_updated=true
        }

        // Get SceneBridge from SceneView to access BVH change tracking
        const scene_bridge = @as(*@import("../rendering/scene_bridge.zig").SceneBridge, @ptrCast(@alignCast(scene_view.scene_ptr)));

        // Check if BVH rebuild is needed using SceneBridge's intelligent tracking
        if (scene_bridge.checkBvhRebuildNeeded(resources_updated)) {
            // Get current raytracing data (will be rebuilt if cache is dirty)
            const rebuild_rt_data = scene_view.getRaytracingData();
            log(.DEBUG, "raytracing", "SceneBridge detected BVH changes: {} instances, {} geometries", .{ rebuild_rt_data.instances.len, rebuild_rt_data.geometries.len });

            // Debug the condition evaluation
            self.blas_handles.clearRetainingCapacity();
            self.blas_buffers.clearRetainingCapacity();

            log(.DEBUG, "raytracing", "🔍 Condition check: bvh_build_in_progress={}, !bvh_build_in_progress={}, instances.len={}, has_instances={}, should_rebuild={}", .{ self.bvh_build_in_progress, !self.bvh_build_in_progress, rebuild_rt_data.instances.len, rebuild_rt_data.instances.len > 0, !self.bvh_build_in_progress and rebuild_rt_data.instances.len > 0 });

            // Check if we can start rebuild immediately or need to queue it

            log(.INFO, "raytracing", "🔄 BVH rebuild needed - starting rebuild", .{});
            self.bvh_build_in_progress = true;

            // Clear existing results to prevent accumulation from previous rebuilds
            self.bvh_builder.clearResults();
            log(.INFO, "raytracing", "Starting BVH rebuild for {} geometries and {} instances", .{ rebuild_rt_data.geometries.len, rebuild_rt_data.instances.len });
            self.completed_tlas = null;
            self.bvh_rebuild_pending = false; // Clear any pending flag since we're starting now

            // Use the new RT data-based BVH building to ensure consistency with BLAS callback
            self.createBlasAsyncFromRtData(rebuild_rt_data, blasCompletionCallback, self) catch |err| {
                log(.ERROR, "raytracing", "Failed to start BVH rebuild from RT data: {}", .{err});
                return false;
            };
            log(.INFO, "raytracing", "Started BVH rebuild for {} geometries using RT data", .{rebuild_rt_data.geometries.len});
        }

        // Get current raytracing data for checks (BLAS building creates raytracing cache)
        const rt_data = scene_view.getRaytracingData();

        // Simple TLAS creation check: BLAS count matches geometry count AND no TLAS exists
        const blas_count = self.blas_handles.items.len;
        const geometry_count = rt_data.geometries.len;
        const has_tlas = self.completed_tlas != null;
        const counts_match = blas_count == geometry_count;
        const has_blas = blas_count > 0;
        const should_create_tlas = counts_match and !has_tlas and has_blas;

        //log(.DEBUG, "raytracing", "🔍 TLAS creation check: blas_count={}, geometry_count={}, counts_match={}, has_tlas={}, has_blas={}, should_create_tlas={}", .{ blas_count, geometry_count, counts_match, has_tlas, has_blas, should_create_tlas });

        if (should_create_tlas) {
            log(.INFO, "raytracing", "🚀 BLAS complete ({} BLAS for {} geometries), creating TLAS...", .{ self.blas_handles.items.len, rt_data.geometries.len });

            // Use RT data-based TLAS creation for consistency with callback
            self.createTlasAsyncFromRtData(rt_data, tlasCompletionCallback, self) catch |err| {
                log(.ERROR, "raytracing", "Failed to start TLAS creation from RT data: {}", .{err});
            };
            return true; // TLAS creation started
        }

        return false; // No rebuild needed or already in progress
    }

    /// BLAS completion callback - called when BLAS builds finish
    fn blasCompletionCallback(context: *anyopaque, blas_results: []const BlasResult, tlas_result: ?TlasResult) void {
        const self = @as(*RaytracingSystem, @ptrCast(@alignCast(context)));

        log(.INFO, "raytracing", "🎯 BLAS callback: {} BLAS builds completed", .{blas_results.len});

        // Update legacy arrays for compatibility with existing conditional logic

        for (blas_results) |blas_result| {
            self.blas_handles.append(self.allocator, blas_result.acceleration_structure) catch |err| {
                log(.ERROR, "raytracing", "Failed to append BLAS handle: {}", .{err});
            };
            self.blas_buffers.append(self.allocator, blas_result.buffer) catch |err| {
                log(.ERROR, "raytracing", "Failed to append BLAS buffer: {}", .{err});
            };
        }

        // Update TLAS if provided
        if (tlas_result) |tlas| {
            log(.INFO, "raytracing", "BLAS callback also received TLAS result with {} instances", .{tlas.instance_count});
            self.tlas = tlas.acceleration_structure;
            self.tlas_buffer = tlas.buffer;
            self.tlas_instance_buffer = tlas.instance_buffer;
            self.tlas_buffer_initialized = true;
            self.tlas_instance_buffer_initialized = true;
            self.completed_tlas = tlas;
            self.descriptors_need_update = true;
        }

        // Mark BVH build as no longer in progress
        self.bvh_build_in_progress = false;

        log(.INFO, "raytracing", "✅ BLAS callback completed - {} BLAS ready, TLAS: {}", .{ blas_results.len, tlas_result != null });
    }

    /// TLAS completion callback - called when TLAS build finishes
    fn tlasCompletionCallback(context: *anyopaque, result: @import("multithreaded_bvh_builder.zig").BvhBuildResult) void {
        const self = @as(*RaytracingSystem, @ptrCast(@alignCast(context)));

        switch (result) {
            .build_tlas => |tlas_result| {
                log(.INFO, "raytracing", "🎯 TLAS callback: Build completed with {} instances in {d:.2}ms", .{
                    tlas_result.instance_count,
                    @as(f64, @floatFromInt(tlas_result.build_time_ns)) / 1_000_000.0,
                });

                // Update raytracing system state with completed TLAS
                self.tlas = tlas_result.acceleration_structure;
                self.tlas_buffer = tlas_result.buffer;
                self.tlas_instance_buffer = tlas_result.instance_buffer;
                self.tlas_buffer_initialized = true;
                self.tlas_instance_buffer_initialized = true;
                self.completed_tlas = tlas_result;
                self.bvh_build_in_progress = false;

                // Mark descriptors as needing update since we have a new TLAS
                self.descriptors_need_update = true;

                log(.INFO, "raytracing", "✅ TLAS ready for rendering! Descriptors marked for update", .{});

                // Check if there was a pending rebuild and trigger it
                if (self.bvh_rebuild_pending) {
                    log(.INFO, "raytracing", "🔄 TLAS completed - pending rebuild detected, will trigger on next frame", .{});
                }
            },
            else => {
                log(.WARN, "raytracing", "TLAS callback received unexpected result type", .{});
            },
        }
    }

    /// Legacy createBLAS method for compatibility
    pub fn createBLAS(self: *RaytracingSystem, scene: *Scene) !void {
        self.blas_handles.clearRetainingCapacity();
        self.blas_buffers.clearRetainingCapacity();
        var mesh_count: usize = 0;
        log(.INFO, "RaytracingSystem", "Scene has {} objects", .{scene.objects.items.len});
        for (scene.objects.items, 0..) |*object, obj_idx| {
            if (object.model) |model| {
                log(.INFO, "RaytracingSystem", "Object {} has model with {} meshes", .{ obj_idx, model.meshes.items.len });
                for (model.meshes.items) |*model_mesh| {
                    const geometry = model_mesh.geometry;
                    mesh_count += 1;
                    const vertex_buffer = geometry.mesh.vertex_buffer;
                    const index_buffer = geometry.mesh.index_buffer;
                    const vertex_count = geometry.mesh.vertices.items.len;
                    const index_count = geometry.mesh.indices.items.len;
                    const vertex_size = @sizeOf(Vertex);
                    var vertex_address_info = vk.BufferDeviceAddressInfo{
                        .s_type = vk.StructureType.buffer_device_address_info,
                        .buffer = vertex_buffer.?.buffer,
                    };
                    var index_address_info = vk.BufferDeviceAddressInfo{
                        .s_type = vk.StructureType.buffer_device_address_info,
                        .buffer = index_buffer.?.buffer,
                    };
                    const vertex_device_address = self.gc.vkd.getBufferDeviceAddress(self.gc.dev, &vertex_address_info);
                    const index_device_address = self.gc.vkd.getBufferDeviceAddress(self.gc.dev, &index_address_info);
                    var geometry_vk = vk.AccelerationStructureGeometryKHR{
                        .s_type = vk.StructureType.acceleration_structure_geometry_khr,
                        .geometry_type = vk.GeometryTypeKHR.triangles_khr,
                        .geometry = .{
                            .triangles = vk.AccelerationStructureGeometryTrianglesDataKHR{
                                .s_type = vk.StructureType.acceleration_structure_geometry_triangles_data_khr,
                                .vertex_format = vk.Format.r32g32b32_sfloat,
                                .vertex_data = .{ .device_address = vertex_device_address },
                                .vertex_stride = vertex_size,
                                .max_vertex = @intCast(vertex_count),
                                .index_type = vk.IndexType.uint32,
                                .index_data = .{ .device_address = index_device_address },
                                .transform_data = .{ .device_address = 0 },
                            },
                        },
                        .flags = vk.GeometryFlagsKHR{ .opaque_bit_khr = true },
                    };
                    log(.INFO, "RaytracingSystem", "BLAS mesh {}: index_count = {}, primitive_count = {}", .{ mesh_count, index_count, index_count / 3 });
                    log(.INFO, "RaytracingSystem", "Creating BLAS for mesh {}: vertex_count = {}, index_count = {}, primitive_count = {}, vertex_buffer = {x}, index_buffer = {x}", .{ mesh_count, vertex_count, index_count, index_count / 3, vertex_buffer.?.buffer, index_buffer.?.buffer });
                    var range_info = vk.AccelerationStructureBuildRangeInfoKHR{
                        .primitive_count = @intCast(index_count / 3),
                        .primitive_offset = 0,
                        .first_vertex = 0,
                        .transform_offset = 0,
                    };
                    var build_info = vk.AccelerationStructureBuildGeometryInfoKHR{
                        .s_type = vk.StructureType.acceleration_structure_build_geometry_info_khr,
                        .type = vk.AccelerationStructureTypeKHR.bottom_level_khr,
                        .flags = vk.BuildAccelerationStructureFlagsKHR{ .prefer_fast_build_bit_khr = true },
                        .mode = vk.BuildAccelerationStructureModeKHR.build_khr,
                        .geometry_count = 1,
                        .p_geometries = @ptrCast(&geometry_vk),
                        .scratch_data = .{ .device_address = 0 },
                    };
                    var size_info = vk.AccelerationStructureBuildSizesInfoKHR{
                        .s_type = vk.StructureType.acceleration_structure_build_sizes_info_khr,
                        .build_scratch_size = 0,
                        .acceleration_structure_size = 0,
                        .update_scratch_size = 0,
                    };
                    var primitive_count: u32 = @intCast(index_count / 3);
                    self.gc.vkd.getAccelerationStructureBuildSizesKHR(self.gc.*.dev, vk.AccelerationStructureBuildTypeKHR.device_khr, &build_info, @ptrCast(&primitive_count), &size_info);
                    const blas_buffer = try Buffer.init(
                        self.gc,
                        size_info.acceleration_structure_size,
                        1,
                        .{ .acceleration_structure_storage_bit_khr = true, .shader_device_address_bit = true },
                        .{ .device_local_bit = true },
                    );
                    var as_create_info = vk.AccelerationStructureCreateInfoKHR{
                        .s_type = vk.StructureType.acceleration_structure_create_info_khr,
                        .buffer = blas_buffer.buffer,
                        .size = size_info.acceleration_structure_size,
                        .type = vk.AccelerationStructureTypeKHR.bottom_level_khr,
                        .device_address = 0,
                        .offset = 0,
                    };
                    const blas = try self.gc.vkd.createAccelerationStructureKHR(self.gc.dev, &as_create_info, null);
                    // Allocate scratch buffer
                    var scratch_buffer = try Buffer.init(
                        self.gc,
                        size_info.build_scratch_size,
                        1,
                        .{ .storage_buffer_bit = true, .shader_device_address_bit = true },
                        .{ .device_local_bit = true },
                    );
                    var scratch_address_info = vk.BufferDeviceAddressInfo{
                        .s_type = vk.StructureType.buffer_device_address_info,
                        .buffer = scratch_buffer.buffer,
                    };
                    const scratch_device_address = self.gc.vkd.getBufferDeviceAddress(self.gc.dev, &scratch_address_info);
                    build_info.scratch_data.device_address = scratch_device_address;
                    build_info.dst_acceleration_structure = blas;
                    // Record build command
                    var threaded_command_pool = try self.gc.beginSingleTimeCommands();
                    const p_range_info = &range_info;
                    self.gc.vkd.cmdBuildAccelerationStructuresKHR(threaded_command_pool.commandBuffer, 1, @ptrCast(&build_info), @ptrCast(&p_range_info));
                    // BLAS build command
                    try self.gc.endSingleTimeCommands(&threaded_command_pool);
                    scratch_buffer.deinit();
                    try self.blas_handles.append(self.allocator, blas);
                    try self.blas_buffers.append(self.allocator, blas_buffer);
                    // Optionally deinit scratch_buffer here
                }
            }
        }
        if (mesh_count == 0) {
            log(.WARN, "RaytracingSystem", "No meshes found in scene, skipping BLAS creation.", .{});
            return;
        }
        log(.INFO, "RaytracingSystem", "Created {d} BLASes for all meshes in scene", .{mesh_count});
    }

    /// Create TLAS for all mesh instances in the scene
    pub fn createTLAS(self: *RaytracingSystem, scene: *Scene) !void {
        var instances = try std.ArrayList(vk.AccelerationStructureInstanceKHR).initCapacity(self.allocator, self.blas_handles.items.len);
        var mesh_index: u32 = 0;
        log(.INFO, "RaytracingSystem", "Creating TLAS for Scene with {} objects", .{scene.objects.items.len});
        for (scene.objects.items) |*object| {
            if (object.model) |model| {
                for (model.meshes.items) |mesh| {
                    log(.INFO, "RaytracingSystem", "Processing model with {} meshes and texture_id {}", .{ model.meshes.items.len, mesh.geometry.mesh.*.material_id });
                    var blas_addr_info = vk.AccelerationStructureDeviceAddressInfoKHR{
                        .s_type = vk.StructureType.acceleration_structure_device_address_info_khr,
                        .acceleration_structure = self.blas_handles.items[mesh_index],
                    };
                    const blas_device_address = self.gc.vkd.getAccelerationStructureDeviceAddressKHR(self.gc.dev, &blas_addr_info);
                    try instances.append(self.allocator, vk.AccelerationStructureInstanceKHR{
                        .transform = .{ .matrix = object.transform.local2world.to_3x4() },
                        .instance_custom_index_and_mask = .{ .instance_custom_index = @intCast(mesh.geometry.mesh.*.material_id), .mask = 0xFF },
                        .instance_shader_binding_table_record_offset_and_flags = .{ .instance_shader_binding_table_record_offset = 0, .flags = 0 },
                        .acceleration_structure_reference = blas_device_address,
                    });
                    mesh_index += 1;
                }
            }
        }
        if (instances.items.len == 0) {
            log(.WARN, "RaytracingSystem", "No mesh instances found in scene, skipping TLAS creation.", .{});
            return;
        }
        // --- TLAS instance buffer setup ---
        // Create instance buffer
        var instance_buffer = try Buffer.init(
            self.gc,
            @sizeOf(vk.AccelerationStructureInstanceKHR) * instances.items.len,
            1,
            .{
                .shader_device_address_bit = true,
                .transfer_dst_bit = true,
                .acceleration_structure_build_input_read_only_bit_khr = true,
            },
            .{ .host_visible_bit = true, .host_coherent_bit = true },
        );
        try instance_buffer.map(@sizeOf(vk.AccelerationStructureInstanceKHR) * instances.items.len, 0);
        instance_buffer.writeToBuffer(std.mem.sliceAsBytes(instances.items), @sizeOf(vk.AccelerationStructureInstanceKHR) * instances.items.len, 0);
        // --- DEBUG: Print TLAS instance buffer contents before upload ---
        log(.INFO, "RaytracingSystem", "TLAS instance buffer contents ({} instances):", .{instances.items.len});
        for (instances.items, 0..) |inst, i| {
            log(.DEBUG, "RaytracingSystem", "  Instance {}: custom_index = {}, mask = {}, sbt_offset = {}, flags = {}, blas_addr = 0x{x}", .{ i, inst.instance_custom_index_and_mask.instance_custom_index, inst.instance_custom_index_and_mask.mask, inst.instance_shader_binding_table_record_offset_and_flags.instance_shader_binding_table_record_offset, inst.instance_shader_binding_table_record_offset_and_flags.flags, inst.acceleration_structure_reference });
        }
        // --- TLAS BUILD SIZES SETUP ---
        // Get device address for TLAS geometry
        var instance_addr_info = vk.BufferDeviceAddressInfo{
            .s_type = vk.StructureType.buffer_device_address_info,
            .buffer = instance_buffer.buffer,
        };
        const instance_device_address = self.gc.vkd.getBufferDeviceAddress(self.gc.dev, &instance_addr_info);

        // Fill TLAS geometry with instance buffer address
        var tlas_geometry = vk.AccelerationStructureGeometryKHR{
            .s_type = vk.StructureType.acceleration_structure_geometry_khr,
            .geometry_type = vk.GeometryTypeKHR.instances_khr,
            .geometry = .{
                .instances = vk.AccelerationStructureGeometryInstancesDataKHR{
                    .s_type = vk.StructureType.acceleration_structure_geometry_instances_data_khr,
                    .array_of_pointers = .false,
                    .data = .{ .device_address = instance_device_address },
                },
            },
            .flags = vk.GeometryFlagsKHR{ .opaque_bit_khr = true },
        };
        var tlas_range_info = vk.AccelerationStructureBuildRangeInfoKHR{
            .primitive_count = @intCast(instances.items.len), // Number of instances
            .primitive_offset = 0,
            .first_vertex = 0,
            .transform_offset = 0,
        };
        var tlas_build_info = vk.AccelerationStructureBuildGeometryInfoKHR{
            .s_type = vk.StructureType.acceleration_structure_build_geometry_info_khr,
            .type = vk.AccelerationStructureTypeKHR.top_level_khr,
            .flags = vk.BuildAccelerationStructureFlagsKHR{ .prefer_fast_trace_bit_khr = true },
            .mode = vk.BuildAccelerationStructureModeKHR.build_khr,
            .geometry_count = 1,
            .p_geometries = @ptrCast(&tlas_geometry),
            .scratch_data = .{ .device_address = 0 }, // Will set below
        };
        var tlas_size_info = vk.AccelerationStructureBuildSizesInfoKHR{
            .s_type = vk.StructureType.acceleration_structure_build_sizes_info_khr,
            .build_scratch_size = 0,
            .acceleration_structure_size = 0,
            .update_scratch_size = 0,
        };
        var tlas_primitive_count: u32 = @intCast(instances.items.len);
        self.gc.vkd.getAccelerationStructureBuildSizesKHR(self.gc.*.dev, vk.AccelerationStructureBuildTypeKHR.device_khr, &tlas_build_info, @ptrCast(&tlas_primitive_count), &tlas_size_info);

        // 2. Create TLAS buffer
        self.tlas_buffer = try Buffer.init(
            self.gc,
            tlas_size_info.acceleration_structure_size,
            1,
            .{ .acceleration_structure_storage_bit_khr = true, .shader_device_address_bit = true },
            .{ .device_local_bit = true },
        );
        // 3. Create acceleration structure
        var tlas_create_info = vk.AccelerationStructureCreateInfoKHR{
            .s_type = vk.StructureType.acceleration_structure_create_info_khr,
            .buffer = self.tlas_buffer.buffer,
            .size = tlas_size_info.acceleration_structure_size,
            .type = vk.AccelerationStructureTypeKHR.top_level_khr,
            .device_address = 0,
            .offset = 0,
        };
        const tlas = try self.gc.vkd.createAccelerationStructureKHR(self.gc.dev, &tlas_create_info, null);
        self.tlas = tlas;
        // 4. Allocate scratch buffer
        var tlas_scratch_buffer = try Buffer.init(
            self.gc,
            tlas_size_info.build_scratch_size,
            1,
            .{ .storage_buffer_bit = true, .shader_device_address_bit = true },
            .{ .device_local_bit = true },
        );
        var tlas_scratch_addr_info = vk.BufferDeviceAddressInfo{
            .s_type = vk.StructureType.buffer_device_address_info,
            .buffer = tlas_scratch_buffer.buffer,
        };
        const tlas_scratch_device_address = self.gc.vkd.getBufferDeviceAddress(self.gc.dev, &tlas_scratch_addr_info);
        tlas_build_info.scratch_data.device_address = tlas_scratch_device_address;
        tlas_build_info.dst_acceleration_structure = tlas;
        // 5. Record build command
        var threaded_command_pool = try self.gc.beginSingleTimeCommands();
        const tlas_p_range_info = &tlas_range_info;
        self.gc.vkd.cmdBuildAccelerationStructuresKHR(threaded_command_pool.commandBuffer, 1, @ptrCast(&tlas_build_info), @ptrCast(&tlas_p_range_info));
        // TLAS build command
        try self.gc.endSingleTimeCommands(&threaded_command_pool);
        tlas_scratch_buffer.deinit();
        log(.INFO, "RaytracingSystem", "TLAS created with number of instances: {}", .{instances.items.len});
        // Store instance buffer for later deinit
        self.tlas_instance_buffer = instance_buffer;
        self.tlas_instance_buffer_initialized = true;
        return;
    }

    /// Create the shader binding table for ray tracing (multi-mesh/instance)
    pub fn createShaderBindingTable(self: *RaytracingSystem, group_count: u32) !void {
        const gc = self.gc;
        // Query pipeline properties for SBT sizes
        var rt_props = vk.PhysicalDeviceRayTracingPipelinePropertiesKHR{
            .s_type = vk.StructureType.physical_device_ray_tracing_pipeline_properties_khr,
            .p_next = null,
            .shader_group_handle_size = 0,
            .max_ray_recursion_depth = 0,
            .max_shader_group_stride = 0,
            .shader_group_base_alignment = 0,
            .shader_group_handle_capture_replay_size = 0,
            .max_ray_dispatch_invocation_count = 0,
            .shader_group_handle_alignment = 0,
            .max_ray_hit_attribute_size = 0,
        };
        var props2 = vk.PhysicalDeviceProperties2{
            .s_type = vk.StructureType.physical_device_properties_2,
            .p_next = &rt_props,
            .properties = self.gc.props,
        };
        gc.vki.getPhysicalDeviceProperties2(gc.pdev, &props2);
        const handle_size = rt_props.shader_group_handle_size;
        const base_alignment = rt_props.shader_group_base_alignment;
        const sbt_stride = alignForward(handle_size, base_alignment);
        const sbt_size = sbt_stride * group_count;

        // 1. Query shader group handles
        const handles = try self.allocator.alloc(u8, handle_size * group_count);
        defer self.allocator.free(handles);
        try gc.vkd.getRayTracingShaderGroupHandlesKHR(gc.dev, self.pipeline.pipeline, 0, group_count, handle_size * group_count, handles.ptr);

        // 2. Allocate device-local SBT buffer
        var device_sbt_buffer = try Buffer.init(
            gc,
            sbt_size,
            1,
            .{ .shader_binding_table_bit_khr = true, .shader_device_address_bit = true, .transfer_dst_bit = true },
            .{ .device_local_bit = true },
        );

        // 3. Allocate host-visible upload buffer
        var upload_buffer = try Buffer.init(
            gc,
            sbt_size,
            1,
            .{ .transfer_src_bit = true },
            .{ .host_visible_bit = true, .host_coherent_bit = true },
        );
        try upload_buffer.map(sbt_size, 0);

        // 4. Write handles into upload buffer at aligned offsets, zeroing padding
        var dst = @as([*]u8, @ptrCast(upload_buffer.mapped.?));
        for (0..group_count) |i| {
            const src_offset = i * handle_size;
            const dst_offset = i * sbt_stride;
            std.mem.copyForwards(u8, dst[dst_offset..][0..handle_size], handles[src_offset..][0..handle_size]);
            // Zero padding if any
            if (sbt_stride > handle_size) {
                for (dst[dst_offset + handle_size .. dst_offset + sbt_stride]) |*b| b.* = 0;
            }
        }
        // No need to flush due to host_coherent

        // 5. Copy from upload to device-local SBT buffer
        try gc.copyBuffer(device_sbt_buffer.buffer, upload_buffer.buffer, sbt_size);

        // 6. Clean up upload buffer
        upload_buffer.deinit();

        // 7. Store device-local SBT buffer (take ownership, don't deinit)
        self.shader_binding_table = device_sbt_buffer.buffer;
        self.shader_binding_table_memory = device_sbt_buffer.memory;
        device_sbt_buffer.buffer = undefined;
        device_sbt_buffer.memory = undefined;
    }

    /// Record the ray tracing command buffer for a frame (multi-mesh/instance)
    pub fn recordCommandBuffer(self: *RaytracingSystem, frame_info: FrameInfo, swapchain: *Swapchain, group_count: u32, global_ubo_buffer_info: vk.DescriptorBufferInfo, material_buffer_info: vk.DescriptorBufferInfo, texture_image_infos: []const vk.DescriptorImageInfo) !void {
        const gc = self.gc;
        _ = group_count;
        const swapchain_changed = swapchain.extent.width != self.width or swapchain.extent.height != self.height;

        if (swapchain_changed or self.descriptors_need_update) {
            // Only recreate output texture if swapchain changed
            if (swapchain_changed) {
                self.width = swapchain.extent.width;
                self.height = swapchain.extent.height;
                const output_texture = try Texture.init(
                    gc,
                    swapchain.surface_format.format,
                    .{ .width = self.width, .height = self.height, .depth = 1 },
                    vk.ImageUsageFlags{
                        .storage_bit = true,
                        .transfer_src_bit = true,
                        .transfer_dst_bit = true,
                        .sampled_bit = true,
                    },
                    vk.SampleCountFlags{ .@"1_bit" = true },
                );
                self.output_texture = output_texture;
            }

            // Always update descriptors when needed
            try self.descriptor_pool.resetPool();
            const output_image_info = self.output_texture.getDescriptorInfo();
            var set_writer = DescriptorWriter.init(gc, self.descriptor_set_layout, self.descriptor_pool, self.allocator);
            const dummy_as_info = try self.getAccelerationStructureDescriptorInfo();
            log(.DEBUG, "raytracing", "Updating descriptors with TLAS handle: {}", .{self.tlas});
            _ = set_writer.writeAccelerationStructure(0, @constCast(&dummy_as_info))
                .writeImage(1, @constCast(&output_image_info))
                .writeBuffer(2, @constCast(&global_ubo_buffer_info))
                .writeBuffer(5, @constCast(&material_buffer_info)) // Material buffer is binding 5
                .writeImages(6, texture_image_infos); // Textures are binding 6
            try set_writer.build(&self.descriptor_set);

            // Clear the update flag
            self.descriptors_need_update = false;

            log(.DEBUG, "raytracing", "Updated raytracing descriptors (swapchain_changed: {}, texture_update: {})", .{ swapchain_changed, !swapchain_changed });
        }

        // --- existing code for binding pipeline, descriptor sets, SBT, etc...

        gc.vkd.cmdBindPipeline(frame_info.command_buffer, vk.PipelineBindPoint.ray_tracing_khr, self.pipeline.pipeline);
        gc.vkd.cmdBindDescriptorSets(frame_info.command_buffer, vk.PipelineBindPoint.ray_tracing_khr, self.pipeline_layout, 0, 1, @ptrCast(&self.descriptor_set), 0, null);

        // SBT region setup
        var rt_props = vk.PhysicalDeviceRayTracingPipelinePropertiesKHR{
            .s_type = vk.StructureType.physical_device_ray_tracing_pipeline_properties_khr,
            .p_next = null,
            .shader_group_handle_size = 0,
            .max_ray_recursion_depth = 0,
            .max_shader_group_stride = 0,
            .shader_group_base_alignment = 0,
            .shader_group_handle_capture_replay_size = 0,
            .max_ray_dispatch_invocation_count = 0,
            .shader_group_handle_alignment = 0,
            .max_ray_hit_attribute_size = 0,
        };
        var props2 = vk.PhysicalDeviceProperties2{
            .s_type = vk.StructureType.physical_device_properties_2,
            .p_next = &rt_props,
            .properties = gc.props,
        };
        gc.vki.getPhysicalDeviceProperties2(gc.pdev, &props2);
        const handle_size = rt_props.shader_group_handle_size;
        const base_alignment = rt_props.shader_group_base_alignment;
        // Use Zig's std.math.alignForwardPow2 for power-of-two alignment, or implement alignForward manually

        const sbt_stride = alignForward(handle_size, base_alignment);
        const sbt_addr_info = vk.BufferDeviceAddressInfo{
            .s_type = vk.StructureType.buffer_device_address_info,
            .buffer = self.shader_binding_table,
        };
        const sbt_addr = gc.vkd.getBufferDeviceAddress(gc.dev, &sbt_addr_info);
        var raygen_region = vk.StridedDeviceAddressRegionKHR{
            .device_address = sbt_addr,
            .stride = sbt_stride,
            .size = sbt_stride,
        };
        var miss_region = vk.StridedDeviceAddressRegionKHR{
            .device_address = sbt_addr + sbt_stride,
            .stride = sbt_stride,
            .size = sbt_stride,
        };
        var hit_region = vk.StridedDeviceAddressRegionKHR{
            .device_address = sbt_addr + sbt_stride * 2,
            .stride = sbt_stride,
            .size = sbt_stride,
        };
        var callable_region = vk.StridedDeviceAddressRegionKHR{
            .device_address = 0,
            .stride = 0,
            .size = 0,
        };
        gc.vkd.cmdTraceRaysKHR(frame_info.command_buffer, &raygen_region, &miss_region, &hit_region, &callable_region, self.width, self.height, 1);

        // --- Image layout transitions before ray tracing ---

        // 2. Transition output image to TRANSFER_SRC for copy
        self.output_texture.transitionImageLayout(
            frame_info.command_buffer,
            vk.ImageLayout.general,
            vk.ImageLayout.transfer_src_optimal,
            .{
                .aspect_mask = vk.ImageAspectFlags{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        ) catch |err| return err;

        // 3. Transition swapchain image to TRANSFER_DST for copy
        gc.transitionImageLayout(
            frame_info.command_buffer,
            swapchain.swap_images[swapchain.image_index].image,
            vk.ImageLayout.present_src_khr,
            vk.ImageLayout.transfer_dst_optimal,
            .{
                .aspect_mask = vk.ImageAspectFlags{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        );

        const copy_info: vk.ImageCopy = vk.ImageCopy{
            .src_subresource = .{ .aspect_mask = vk.ImageAspectFlags{ .color_bit = true }, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 },
            .src_offset = vk.Offset3D{ .x = 0, .y = 0, .z = 0 },
            .dst_subresource = .{ .aspect_mask = vk.ImageAspectFlags{ .color_bit = true }, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 },
            .extent = vk.Extent3D{ .width = swapchain.extent.width, .height = swapchain.extent.height, .depth = 1 },
            .dst_offset = vk.Offset3D{ .x = 0, .y = 0, .z = 0 },
        };
        gc.vkd.cmdCopyImage(frame_info.command_buffer, self.output_texture.image, vk.ImageLayout.transfer_src_optimal, swapchain.swap_images[swapchain.image_index].image, vk.ImageLayout.transfer_dst_optimal, 1, @ptrCast(&copy_info));

        // --- Image layout transitions after copy ---
        // 4. Transition output image back to GENERAL
        self.output_texture.transitionImageLayout(
            frame_info.command_buffer,
            vk.ImageLayout.transfer_src_optimal,
            vk.ImageLayout.general,
            .{
                .aspect_mask = vk.ImageAspectFlags{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        ) catch |err| return err;
        // 5. Transition swapchain image to PRESENT_SRC for presentation
        gc.transitionImageLayout(
            frame_info.command_buffer,
            swapchain.swap_images[swapchain.image_index].image,
            vk.ImageLayout.transfer_dst_optimal,
            vk.ImageLayout.present_src_khr,
            .{
                .aspect_mask = vk.ImageAspectFlags{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        );

        return;
    }

    pub fn deinit(self: *RaytracingSystem) void {
        // Wait for all GPU operations to complete before cleanup
        self.gc.vkd.deviceWaitIdle(self.gc.dev) catch |err| {
            log(.WARN, "RaytracingSystem", "Failed to wait for device idle during deinit: {}", .{err});
        };

        // Deinit multithreaded BVH builder first (heap allocated)
        self.bvh_builder.deinit();
        self.allocator.destroy(self.bvh_builder);
        self.completed_blas_list.deinit(self.allocator);

        if (self.tlas_instance_buffer_initialized) self.tlas_instance_buffer.deinit();
        // Deinit all BLAS buffers and destroy BLAS acceleration structures
        for (self.blas_buffers.items, self.blas_handles.items) |*buf, blas| {
            buf.deinit();
            if (blas != .null_handle) self.gc.vkd.destroyAccelerationStructureKHR(self.gc.dev, blas, null);
        }
        self.blas_buffers.deinit(self.allocator);
        self.blas_handles.deinit(self.allocator);
        // Destroy TLAS acceleration structure and deinit TLAS buffer
        if (self.tlas != .null_handle) self.gc.vkd.destroyAccelerationStructureKHR(self.gc.dev, self.tlas, null);
        self.tlas_buffer.deinit();
        // Destroy shader binding table buffer and free its memory
        if (self.shader_binding_table != .null_handle) self.gc.vkd.destroyBuffer(self.gc.dev, self.shader_binding_table, null);
        if (self.shader_binding_table_memory != .null_handle) self.gc.vkd.freeMemory(self.gc.dev, self.shader_binding_table_memory, null);
        // Destroy output image/texture
        self.output_texture.deinit();
        // Clean up descriptor sets, pool, and layout
        deinitDescriptorResources(self.descriptor_pool, self.descriptor_set_layout, @ptrCast(&self.descriptor_set), null) catch |err| {
            log(.ERROR, "RaytracingSystem", "Failed to deinit descriptor resources: {}", .{err});
        };
        // Destroy pipeline and associated resources
        self.pipeline.deinit();
    }

    pub fn getAccelerationStructureDescriptorInfo(self: *RaytracingSystem) !vk.WriteDescriptorSetAccelerationStructureKHR {
        // Assumes self.tlas is a valid VkAccelerationStructureKHR handle
        return vk.WriteDescriptorSetAccelerationStructureKHR{
            .s_type = vk.StructureType.write_descriptor_set_acceleration_structure_khr,
            .p_next = null,
            .acceleration_structure_count = 1,
            .p_acceleration_structures = @ptrCast(&self.tlas),
        };
    }

    pub fn getOutputImageDescriptorInfo(self: *RaytracingSystem) !vk.DescriptorImageInfo {
        // Assumes self.output_texture is valid
        return self.output_texture.getDescriptorInfo();
    }

    /// Request texture descriptor update on next frame
    pub fn requestTextureDescriptorUpdate(self: *RaytracingSystem) void {
        //log(.DEBUG, "raytracing", "Raytracing texture descriptor update requested", .{});
        self.descriptors_need_update = true;
    }
};
