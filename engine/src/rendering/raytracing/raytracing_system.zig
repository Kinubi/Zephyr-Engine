const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("../../core/graphics_context.zig").GraphicsContext;
const Buffer = @import("../../core/buffer.zig").Buffer;
const FrameInfo = @import("../../rendering/frameinfo.zig").FrameInfo;
const log = @import("../../utils/log.zig").log;
const ThreadPoolMod = @import("../../threading/thread_pool.zig");

const RenderData = @import("../../rendering/render_data_types.zig");
const RaytracingData = RenderData.RaytracingData;
const RenderSystem = @import("../../ecs//systems/render_system.zig").RenderSystem;
const MeshRenderer = @import("../../ecs/components/mesh_renderer.zig").MeshRenderer;
const Transform = @import("../../ecs/components/transform.zig").Transform;
const World = @import("../../ecs/world.zig").World;
const AssetManager = @import("../../assets/asset_manager.zig").AssetManager;
const MAX_FRAMES_IN_FLIGHT = @import("../../core/swapchain.zig").MAX_FRAMES_IN_FLIGHT;
// Import the new multithreaded BVH builder (still in rendering/raytracing/)
const MultithreadedBvhBuilder = @import("../../rendering/raytracing/multithreaded_bvh_builder.zig").MultithreadedBvhBuilder;
const BlasResult = @import("../../rendering/raytracing/multithreaded_bvh_builder.zig").BlasResult;
const InstanceData = @import("../../rendering/raytracing/multithreaded_bvh_builder.zig").InstanceData;
const TlasWorker = @import("../../rendering/raytracing/tlas_worker.zig");
const TlasJob = TlasWorker.TlasJob;
const ThreadPool = ThreadPoolMod.ThreadPool;

fn alignForward(val: usize, alignment: usize) usize {
    return ((val + alignment - 1) / alignment) * alignment;
}

/// Per-frame resources queued for destruction
const PerFrameDestroyQueue = struct {
    blas_handles: std.ArrayList(vk.AccelerationStructureKHR),
    blas_buffers: std.ArrayList(Buffer),
    tlas_handles: std.ArrayList(vk.AccelerationStructureKHR),
    tlas_buffers: std.ArrayList(Buffer),
    tlas_instance_buffers: std.ArrayList(Buffer),

    fn init() PerFrameDestroyQueue {
        return .{
            .blas_handles = .{},
            .blas_buffers = .{},
            .tlas_handles = .{},
            .tlas_buffers = .{},
            .tlas_instance_buffers = .{},
        };
    }

    fn deinit(self: *PerFrameDestroyQueue, allocator: std.mem.Allocator) void {
        self.blas_handles.deinit(allocator);
        self.blas_buffers.deinit(allocator);
        self.tlas_handles.deinit(allocator);
        self.tlas_buffers.deinit(allocator);
        self.tlas_instance_buffers.deinit(allocator);
    }
};

// ==================== Acceleration Structure Sets ====================

/// TLAS entry for atomic swap (heap-allocated)
const TlasEntry = struct {
    acceleration_structure: vk.AccelerationStructureKHR,
    buffer: Buffer,
    instance_buffer: Buffer,
    device_address: vk.DeviceAddress,
    instance_count: u32,
    build_time_ns: u64,
    created_frame: u32,
};

/// Managed TLAS with generation tracking + atomic swap
/// Combines generation-based descriptor tracking with atomic swap for safe lifecycle
pub const ManagedTLAS = struct {
    // Atomic pointer to current TLAS (double-buffered, lock-free)
    current: std.atomic.Value(?*TlasEntry) = std.atomic.Value(?*TlasEntry).init(null),

    // Generation tracking (increments AFTER all frames bind the new TLAS)
    generation: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    // Pending bind mask: tracks which frames still need to bind the current TLAS
    // When mask reaches 0, all frames have bound, and we can increment generation
    pending_bind_mask: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),

    name: []const u8,

    /// Get current acceleration structure handle (thread-safe read)
    pub fn acceleration_structure(self: *const ManagedTLAS) vk.AccelerationStructureKHR {
        if (self.current.load(.acquire)) |entry| {
            return entry.acceleration_structure;
        }
        return vk.AccelerationStructureKHR.null_handle;
    }

    /// Get current device address (thread-safe read)
    pub fn device_address(self: *const ManagedTLAS) vk.DeviceAddress {
        if (self.current.load(.acquire)) |entry| {
            return entry.device_address;
        }
        return 0;
    }

    /// Get current instance count (thread-safe read)
    pub fn instance_count(self: *const ManagedTLAS) u32 {
        if (self.current.load(.acquire)) |entry| {
            return entry.instance_count;
        }
        return 0;
    }
};

/// Managed geometry buffers (vertex/index arrays) with generation tracking
/// These are descriptor buffer info arrays that get updated when geometries change
pub const ManagedGeometryBuffers = struct {
    vertex_infos: std.ArrayList(vk.DescriptorBufferInfo),
    index_infos: std.ArrayList(vk.DescriptorBufferInfo),
    generation: u32 = 0, // Increments when buffers change
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) ManagedGeometryBuffers {
        return .{
            .vertex_infos = std.ArrayList(vk.DescriptorBufferInfo){},
            .index_infos = std.ArrayList(vk.DescriptorBufferInfo){},
            .generation = 0,
            .allocator = allocator,
        };
    }

    fn deinit(self: *ManagedGeometryBuffers) void {
        self.vertex_infos.deinit(self.allocator);
        self.index_infos.deinit(self.allocator);
    }

    /// Update geometry buffers from raytracing data
    /// Populates vertex_infos and index_infos arrays with buffer descriptors
    fn updateFromGeometries(self: *ManagedGeometryBuffers, rt_data: RaytracingData) !void {
        // Clear existing arrays
        self.vertex_infos.clearRetainingCapacity();
        self.index_infos.clearRetainingCapacity();

        // Reserve capacity for all geometries
        try self.vertex_infos.ensureTotalCapacity(self.allocator, rt_data.geometries.len);
        try self.index_infos.ensureTotalCapacity(self.allocator, rt_data.geometries.len);

        // Populate vertex and index buffer info arrays
        for (rt_data.geometries) |geometry| {
            const mesh = geometry.mesh_ptr;

            // Add vertex buffer info
            const vertex_info = vk.DescriptorBufferInfo{
                .buffer = mesh.vertex_buffer.?.buffer,
                .offset = 0,
                .range = mesh.vertex_buffer.?.buffer_size,
            };
            self.vertex_infos.appendAssumeCapacity(vertex_info);

            // Add index buffer info
            const index_info = vk.DescriptorBufferInfo{
                .buffer = mesh.index_buffer.?.buffer,
                .offset = 0,
                .range = mesh.index_buffer.?.buffer_size,
            };
            self.index_infos.appendAssumeCapacity(index_info);
        }

        // Increment generation to trigger descriptor rebinding
        self.generation += 1;
    }
};

/// Geometry reference for BLAS (simplified - stores buffer references)
pub const BlasHandle = struct {
    vertex_buffer: vk.Buffer,
    index_buffer: vk.Buffer,
    vertex_count: u32,
    index_count: u32,
    vertex_stride: u32,
    transform: [12]f32,
};

/// Named acceleration structure set
/// A collection of BLAS (geometries) with a TLAS (scene)
pub const AccelerationStructureSet = struct {
    allocator: std.mem.Allocator,
    name: []const u8,

    // Geometry handles for this set (BLAS references)
    blas_handles: std.ArrayList(BlasHandle),

    // TLAS for this set (scene)
    tlas: ManagedTLAS,

    // Geometry buffers (vertex/index arrays) with generation tracking
    geometry_buffers: ManagedGeometryBuffers,

    // Tracking
    dirty: bool = true, // Marks set as needing rebuild

    // Cooldown frames after TLAS rebuild (allows descriptor rebinding)
    rebuild_cooldown_frames: u32 = 0,

    fn init(allocator: std.mem.Allocator, name: []const u8) AccelerationStructureSet {
        return .{
            .allocator = allocator,
            .name = name,
            .blas_handles = std.ArrayList(BlasHandle).init(allocator),
            .tlas = .{
                .name = name,
            },
            .geometry_buffers = ManagedGeometryBuffers.init(allocator),
            .dirty = true,
        };
    }

    fn deinit(self: *AccelerationStructureSet) void {
        self.blas_handles.deinit();
        self.geometry_buffers.deinit();
    }
};

// ==========================================================================

/// Enhanced Raytracing system with multithreaded BVH building
pub const RaytracingSystem = struct {
    gc: *GraphicsContext, // Use 'gc' for consistency with Swapchain

    // NEW: Named acceleration structure sets (like MaterialBufferSet/TextureSet)
    as_sets: std.StringHashMap(AccelerationStructureSet),

    // Multithreaded BVH system
    bvh_builder: *MultithreadedBvhBuilder = undefined,
    bvh_build_in_progress: bool = false,
    force_rebuild: bool = false, // Force rebuild on next update (overrides all checks)
    next_tlas_job_id: u64 = 1,

    // Shader Binding Table (for raytracing)
    shader_binding_table: vk.Buffer = undefined,
    shader_binding_table_memory: vk.DeviceMemory = undefined,

    // Per-frame destruction queues for deferred resource cleanup
    // Flow: When spawning TLAS worker, we queue old TLAS/BLAS for destruction in per_frame_destroy[current_frame]
    // These are destroyed MAX_FRAMES_IN_FLIGHT frames later (after GPU finishes using them)
    // This ensures GPU synchronization without blocking or orphaning
    per_frame_destroy: [MAX_FRAMES_IN_FLIGHT]PerFrameDestroyQueue = undefined,

    allocator: std.mem.Allocator = undefined,

    /// Cooldown frames after a TLAS pickup to allow all frames-in-flight to
    /// rebind their descriptor sets before spawning another TLAS build.
    /// NOTE: This will move into AccelerationStructureSet (per-set cooldown)
    tlas_rebuild_cooldown_frames: u32 = 0,
    last_cooldown_decrement_frame: u32 = 0, // Track which frame last decremented cooldown
    last_tlas_pickup_frame: u32 = std.math.maxInt(u32), // Track which frame last picked up a TLAS (to prevent multiple pickups per frame)

    /// Enhanced init with multithreaded BVH support
    pub fn init(
        gc: *GraphicsContext,
        allocator: std.mem.Allocator,
        thread_pool: *ThreadPool,
    ) !RaytracingSystem {
        // RaytracingSystem now focuses only on BVH building and management
        // Rendering/descriptor management is handled by RaytracingRenderer

        // Initialize BVH builder
        const bvh_builder = try allocator.create(MultithreadedBvhBuilder);
        bvh_builder.* = try MultithreadedBvhBuilder.init(gc, thread_pool, allocator);

        // Initialize per-frame destruction queues
        var per_frame_destroy: [MAX_FRAMES_IN_FLIGHT]PerFrameDestroyQueue = undefined;
        for (&per_frame_destroy) |*queue| {
            queue.* = PerFrameDestroyQueue.init();
        }

        return RaytracingSystem{
            .gc = gc,
            .as_sets = std.StringHashMap(AccelerationStructureSet).init(allocator),
            .bvh_builder = bvh_builder,
            .bvh_build_in_progress = false,
            .per_frame_destroy = per_frame_destroy,
            .allocator = allocator,
            .shader_binding_table = vk.Buffer.null_handle,
            .shader_binding_table_memory = vk.DeviceMemory.null_handle,
        };
    }

    // ========================================================================
    // Acceleration Structure Set Management API
    // ========================================================================

    /// Create or get an acceleration structure set by name
    pub fn createSet(self: *RaytracingSystem, name: []const u8) !*AccelerationStructureSet {
        // Check if set already exists
        if (self.as_sets.getPtr(name)) |existing_set| {
            return existing_set;
        }

        // Create new set
        const set_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(set_name);

        const set = AccelerationStructureSet{
            .allocator = self.allocator,
            .name = set_name,
            .tlas = .{
                .name = set_name, // ManagedTLAS needs a name

            },
            .blas_handles = std.ArrayList(BlasHandle){},
            .geometry_buffers = ManagedGeometryBuffers.init(self.allocator),
            .dirty = true, // New sets are dirty
            .rebuild_cooldown_frames = 0,
        };

        try self.as_sets.put(set_name, set);

        log(.INFO, "RaytracingSystem", "Created acceleration structure set '{s}'", .{name});
        return self.as_sets.getPtr(set_name).?;
    }

    /// Get an acceleration structure set by name (returns null if not found)
    pub fn getSet(self: *RaytracingSystem, name: []const u8) ?*AccelerationStructureSet {
        return self.as_sets.getPtr(name);
    }

    /// Add geometry to an acceleration structure set
    pub fn addGeometryToSet(
        self: *RaytracingSystem,
        set_name: []const u8,
        vertex_buffer: vk.Buffer,
        index_buffer: vk.Buffer,
        vertex_count: u32,
        index_count: u32,
        vertex_stride: u32,
        transform: [12]f32,
    ) !void {
        const set = try self.createSet(set_name);

        const blas_handle = BlasHandle{
            .vertex_buffer = vertex_buffer,
            .index_buffer = index_buffer,
            .vertex_count = vertex_count,
            .index_count = index_count,
            .vertex_stride = vertex_stride,
            .transform = transform,
        };

        try set.blas_handles.append(blas_handle);
        set.dirty = true;

        log(.DEBUG, "RaytracingSystem", "Added geometry to set '{s}' (vertices: {}, indices: {})", .{ set_name, vertex_count, index_count });
    }

    /// Mark a set as dirty (needs rebuild)
    pub fn markSetDirty(self: *RaytracingSystem, set_name: []const u8) void {
        if (self.getSet(set_name)) |set| {
            set.dirty = true;
            log(.DEBUG, "RaytracingSystem", "Marked set '{s}' as dirty", .{set_name});
        }
    }

    /// Rebuild an acceleration structure set (builds TLAS from BLAS handles)
    pub fn rebuildSet(self: *RaytracingSystem, set_name: []const u8) !void {
        const set = self.getSet(set_name) orelse {
            log(.WARN, "RaytracingSystem", "Cannot rebuild set '{s}': not found", .{set_name});
            return;
        };

        if (!set.dirty) {
            log(.DEBUG, "RaytracingSystem", "Set '{s}' is not dirty, skipping rebuild", .{set_name});
            return;
        }

        if (set.rebuild_cooldown_frames > 0) {
            log(.DEBUG, "RaytracingSystem", "Set '{s}' is in cooldown ({} frames remaining)", .{ set_name, set.rebuild_cooldown_frames });
            return;
        }

        if (set.blas_handles.items.len == 0) {
            log(.WARN, "RaytracingSystem", "Cannot rebuild set '{s}': no geometries", .{set_name});
            return;
        }

        log(.INFO, "RaytracingSystem", "Rebuilding acceleration structure set '{s}' ({} geometries)", .{ set_name, set.blas_handles.items.len });

        // TODO: Spawn worker to build TLAS from BLAS handles
        // For now, mark as not dirty and increment generation
        set.dirty = false;
        set.tlas.generation += 1;
        set.rebuild_cooldown_frames = 2; // Wait 2 frames before allowing rebuild

        log(.INFO, "RaytracingSystem", "Set '{s}' rebuilt (generation: {})", .{ set_name, set.tlas.generation });
    }

    /// ECS-driven update: Query MeshRenderer components and build acceleration structure sets from them
    /// This follows the ECS philosophy: systems query components, not explicit API calls
    pub fn updateFromECS(self: *RaytracingSystem, world: *World, asset_manager: *AssetManager) !void {

        // Query all entities with MeshRenderer components
        var mesh_view = try world.view(MeshRenderer);
        var iter = mesh_view.iterator();

        // Scan all entities and extract geometry for BLAS
        while (iter.next()) |entry| {
            const mesh_renderer = entry.component;

            // Get transform for this entity (default to identity if missing)
            const transform = world.get(Transform, entry.entity) orelse continue;

            // Skip if not renderable
            if (!mesh_renderer.hasValidAssets()) continue;

            // Get model asset
            const model_id = mesh_renderer.model_asset orelse continue;

            // Get mesh data from asset manager
            if (asset_manager.getMeshByAssetId(model_id)) |mesh_data| {
                // Extract transform matrix (convert to [12]f32 for BLAS)
                const mat = transform.getTransformMatrix();
                const transform_array = [12]f32{
                    mat.m[0][0], mat.m[0][1], mat.m[0][2], mat.m[0][3],
                    mat.m[1][0], mat.m[1][1], mat.m[1][2], mat.m[1][3],
                    mat.m[2][0], mat.m[2][1], mat.m[2][2], mat.m[2][3],
                };

                // Add geometry to "default" set (or could use mesh_renderer.layer for set name)
                const set_name = "default"; // TODO: Could derive from layer or other component data

                try self.addGeometryToSet(
                    set_name,
                    mesh_data.vertex_buffer,
                    mesh_data.index_buffer,
                    mesh_data.vertex_count,
                    mesh_data.index_count,
                    mesh_data.vertex_stride,
                    transform_array,
                );
            }
        }

        // Now update all sets (rebuild dirty ones)
        try self.updateAccelerationStructureSets();
    }

    /// Update all acceleration structure sets (call once per frame)
    pub fn updateAccelerationStructureSets(self: *RaytracingSystem) !void {
        var iter = self.as_sets.iterator();
        while (iter.next()) |entry| {
            const set = entry.value_ptr;

            // Decrement cooldown
            if (set.rebuild_cooldown_frames > 0) {
                set.rebuild_cooldown_frames -= 1;
            }

            // Rebuild dirty sets
            if (set.dirty and set.rebuild_cooldown_frames == 0) {
                try self.rebuildSet(set.name);
            }
        }
    }

    // ========================================================================
    // Legacy API (to be removed after migration)
    // ========================================================================

    /// Update the Shader Binding Table when the pipeline changes
    pub fn updateShaderBindingTable(self: *RaytracingSystem, pipeline: vk.Pipeline) !void {
        if (pipeline == vk.Pipeline.null_handle) {
            log(.WARN, "RaytracingSystem", "Cannot update SBT: pipeline is null", .{});
            return;
        }

        // Get shader group handles from the pipeline
        const group_count: u32 = 3; // raygen, miss, closest hit

        // Query raytracing pipeline properties - validate each field access
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

        // Use existing graphics context properties
        var props2 = vk.PhysicalDeviceProperties2{
            .s_type = vk.StructureType.physical_device_properties_2,
            .p_next = &rt_props,
            .properties = self.gc.props,
        };

        // Safely query properties
        self.gc.vki.getPhysicalDeviceProperties2(self.gc.pdev, &props2);

        const handle_size = rt_props.shader_group_handle_size;
        const base_alignment = rt_props.shader_group_base_alignment;

        // Use the same stride calculation as the renderer
        const sbt_stride = alignForward(handle_size, base_alignment);

        var group_handles = try self.allocator.alloc(u8, group_count * handle_size);
        defer self.allocator.free(group_handles);

        try self.gc.*.vkd.getRayTracingShaderGroupHandlesKHR(
            self.gc.*.dev,
            pipeline,
            0,
            group_count,
            @intCast(group_handles.len),
            group_handles.ptr,
        );

        // Create shader binding table buffer with enough space for all regions
        // We need space for: raygen (1) + miss (1) + hit (1) = 3 entries minimum
        // The renderer accesses at offsets: 0, stride, stride*2
        // So we need at least 3 * stride bytes total
        const min_entries = 3;
        const actual_entries = @max(group_count, min_entries);
        const sbt_size = actual_entries * sbt_stride;

        // Clean up existing SBT if it exists
        if (self.shader_binding_table != vk.Buffer.null_handle) {
            // Untrack existing SBT memory
            if (self.gc.*.memory_tracker) |tracker| {
                tracker.untrackAllocation("raytracing_sbt");
            }
            self.gc.*.vkd.destroyBuffer(self.gc.*.dev, self.shader_binding_table, null);
            self.gc.*.vkd.freeMemory(self.gc.*.dev, self.shader_binding_table_memory, null);
        }

        // Create new SBT buffer
        const sbt_buffer_info = vk.BufferCreateInfo{
            .size = sbt_size,
            .usage = vk.BufferUsageFlags{
                .shader_binding_table_bit_khr = true,
                .shader_device_address_bit = true,
            },
            .sharing_mode = .exclusive,
            .queue_family_index_count = 0,
            .p_queue_family_indices = null,
            .flags = .{},
        };

        self.shader_binding_table = try self.gc.*.vkd.createBuffer(self.gc.*.dev, &sbt_buffer_info, null);

        const memory_requirements = self.gc.*.vkd.getBufferMemoryRequirements(self.gc.*.dev, self.shader_binding_table);
        const memory_type_index = try self.gc.*.findMemoryTypeIndex(memory_requirements.memory_type_bits, vk.MemoryPropertyFlags{
            .host_visible_bit = true,
            .host_coherent_bit = true,
        });

        // Add device address flag for SBT memory allocation
        const alloc_flags = vk.MemoryAllocateFlagsInfo{
            .s_type = vk.StructureType.memory_allocate_flags_info,
            .p_next = null,
            .flags = vk.MemoryAllocateFlags{
                .device_address_bit = true,
            },
            .device_mask = 0,
        };

        const alloc_info = vk.MemoryAllocateInfo{
            .s_type = vk.StructureType.memory_allocate_info,
            .p_next = &alloc_flags,
            .allocation_size = memory_requirements.size,
            .memory_type_index = memory_type_index,
        };

        self.shader_binding_table_memory = try self.gc.*.vkd.allocateMemory(self.gc.*.dev, &alloc_info, null);
        try self.gc.*.vkd.bindBufferMemory(self.gc.*.dev, self.shader_binding_table, self.shader_binding_table_memory, 0);

        // Track shader binding table memory allocation
        if (self.gc.*.memory_tracker) |tracker| {
            tracker.trackAllocation("raytracing_sbt", memory_requirements.size, .buffer) catch |err| {
                std.log.warn("Failed to track SBT allocation: {}", .{err});
            };
        }

        // Map memory and copy shader handles
        const mapped_memory = try self.gc.*.vkd.mapMemory(self.gc.*.dev, self.shader_binding_table_memory, 0, sbt_size, .{});
        defer self.gc.*.vkd.unmapMemory(self.gc.*.dev, self.shader_binding_table_memory);

        const sbt_data: [*]u8 = @ptrCast(mapped_memory);

        // Zero out the entire buffer first
        @memset(sbt_data[0..sbt_size], 0);

        // Copy handles with proper alignment using consistent stride
        for (0..group_count) |i| {
            const src_offset = i * handle_size;
            const dst_offset = i * sbt_stride;

            if (dst_offset + handle_size <= sbt_size) {
                @memcpy(sbt_data[dst_offset .. dst_offset + handle_size], group_handles[src_offset .. src_offset + handle_size]);
            }
        }
    }

    /// Update BVH state using data from RenderSystem (for modern ECS-based rendering)
    pub fn update(
        self: *RaytracingSystem,
        render_system: *RenderSystem,
        frame_info: *const FrameInfo,
        geo_changed: bool,
    ) !bool {
        const frame_index = frame_info.current_frame;

        // Track if we completed a TLAS in THIS update() call to prevent immediate respawn
        var completed_tlas_this_call = false;

        // FIRST: Check if TLAS worker has completed and pick up the result
        // Only pick up once per frame to prevent rapid successive rebuilds
        if (self.bvh_build_in_progress and self.last_tlas_pickup_frame != frame_index) {
            if (self.bvh_builder.tryPickupCompletedTlas()) |tlas_result| {
                self.last_tlas_pickup_frame = frame_index; // Mark this frame as having picked up a TLAS
                completed_tlas_this_call = true; // Mark completion in THIS call

                // TLAS build completed successfully!
                const default_set = try self.createSet("default");

                // Create new TLAS entry (heap allocated for atomic pointer)
                const new_entry = try self.allocator.create(TlasEntry);
                new_entry.* = .{
                    .acceleration_structure = tlas_result.acceleration_structure,
                    .buffer = tlas_result.buffer,
                    .instance_buffer = tlas_result.instance_buffer,
                    .device_address = tlas_result.device_address,
                    .instance_count = tlas_result.instance_count,
                    .build_time_ns = tlas_result.build_time_ns,
                    .created_frame = frame_index,
                };

                // Atomic swap: get old TLAS, store new TLAS (lock-free, safe)
                const old_entry = default_set.tlas.current.swap(new_entry, .acq_rel);

                // Queue old TLAS for destruction (if it existed)
                if (old_entry) |old| {
                    // Queue acceleration structure handle
                    self.per_frame_destroy[frame_index].tlas_handles.append(self.allocator, old.acceleration_structure) catch |err| {
                        log(.ERROR, "raytracing", "Failed to queue old TLAS handle: {}", .{err});
                        self.gc.vkd.destroyAccelerationStructureKHR(self.gc.dev, old.acceleration_structure, null);
                    };

                    // Queue buffers
                    self.per_frame_destroy[frame_index].tlas_buffers.append(self.allocator, old.buffer) catch |err| {
                        log(.ERROR, "raytracing", "Failed to queue old TLAS buffer: {}", .{err});
                        var immediate = old.buffer;
                        immediate.deinit();
                    };

                    self.per_frame_destroy[frame_index].tlas_instance_buffers.append(self.allocator, old.instance_buffer) catch |err| {
                        log(.ERROR, "raytracing", "Failed to queue old TLAS instance buffer: {}", .{err});
                        var immediate = old.instance_buffer;
                        immediate.deinit();
                    };

                    // Free the old entry struct itself
                    self.allocator.destroy(old);
                }

                // Update geometry buffers (vertex/index arrays) with current raytracing data
                const rt_data = try render_system.getRaytracingData();
                defer {
                    self.allocator.free(rt_data.instances);
                    self.allocator.free(rt_data.geometries);
                    self.allocator.free(rt_data.materials);
                }
                try default_set.geometry_buffers.updateFromGeometries(rt_data);

                // Mark build as no longer in progress
                self.bvh_build_in_progress = false;

                // Check if force rebuild was requested while this build was in progress
                if (self.force_rebuild) {
                    // Skip cooldown to allow immediate rebuild
                    self.tlas_rebuild_cooldown_frames = 0;
                } else {
                    // Start cooldown to prevent rapid rebuilds that cause flashing
                    // Use longer cooldown than MAX_FRAMES_IN_FLIGHT to batch updates
                    self.tlas_rebuild_cooldown_frames = MAX_FRAMES_IN_FLIGHT * 3; // 9 frames ~= 150ms at 60fps
                }

                // CRITICAL: Set pending bind mask BEFORE incrementing generation
                // This prevents race where frames see generation change before mask is set
                // Use .release ordering to ensure mask write is visible before generation increment
                default_set.tlas.pending_bind_mask.store(0b111, .release);

                // Increment generation atomically (for descriptor tracking)
                // Resource binder will see this change and bind each frame,
                // clearing mask bits as it goes. It reverts last_generation
                // until all frames have bound (mask == 0).
                // Use .acq_rel to establish happens-before relationship with mask store
                _ = default_set.tlas.generation.fetchAdd(1, .acq_rel);

                return true;
            }
        }

        // Pick up any old BLAS that were replaced in the registry and need deferred destruction
        const old_blas_list = self.bvh_builder.takeOldBlasForDestruction(self.allocator) catch |err| blk: {
            log(.ERROR, "raytracing", "Failed to take old BLAS for destruction: {}", .{err});
            break :blk &[_]BlasResult{};
        };
        defer self.allocator.free(old_blas_list);

        // Queue them for per-frame destruction
        for (old_blas_list) |old_blas| {
            self.per_frame_destroy[frame_index].blas_handles.append(self.allocator, old_blas.acceleration_structure) catch |err| {
                log(.ERROR, "raytracing", "Failed to queue old BLAS handle for destruction: {}", .{err});
                self.gc.vkd.destroyAccelerationStructureKHR(self.gc.dev, old_blas.acceleration_structure, null);
                if (self.gc.memory_tracker) |tracker| {
                    var name_buf: [64]u8 = undefined;
                    const blas_name = std.fmt.bufPrint(&name_buf, "blas_{d}", .{@intFromEnum(old_blas.acceleration_structure)}) catch "blas_unknown";
                    tracker.untrackAllocation(blas_name);
                }
                var immediate = old_blas.buffer;
                immediate.deinit();
                continue;
            };

            self.per_frame_destroy[frame_index].blas_buffers.append(self.allocator, old_blas.buffer) catch |err| {
                log(.ERROR, "raytracing", "Failed to queue old BLAS buffer for destruction: {}", .{err});
                self.gc.vkd.destroyAccelerationStructureKHR(self.gc.dev, old_blas.acceleration_structure, null);
                if (self.gc.memory_tracker) |tracker| {
                    var name_buf: [64]u8 = undefined;
                    const blas_name = std.fmt.bufPrint(&name_buf, "blas_{d}", .{@intFromEnum(old_blas.acceleration_structure)}) catch "blas_unknown";
                    tracker.untrackAllocation(blas_name);
                }
                var immediate = old_blas.buffer;
                immediate.deinit();
                if (self.per_frame_destroy[frame_index].blas_handles.items.len > 0) {
                    self.per_frame_destroy[frame_index].blas_handles.items.len -= 1;
                }
                continue;
            };
        }

        // Check if we need to spawn a TLAS worker for either transform-only or geometry changes
        // Only rebuild if:
        // 1. Geometry actually changed (geo_changed = true from descriptors dirty)
        // 2. OR mesh transforms changed (transform_only AND renderables_dirty)
        // Don't rebuild just because renderables_dirty is true - that could be raster-only changes
        const mesh_transforms_changed = render_system.transform_only_change and render_system.renderables_dirty;
        const rebuild_needed = geo_changed or mesh_transforms_changed;

        // Decrement cooldown if active (but only once per frame!)
        if (self.tlas_rebuild_cooldown_frames > 0 and self.last_cooldown_decrement_frame != frame_index) {
            self.tlas_rebuild_cooldown_frames -= 1;
            self.last_cooldown_decrement_frame = frame_index;
        }

        // Force rebuild overrides everything (except in-progress builds)
        const wants_rebuild = self.force_rebuild or rebuild_needed;
        const can_spawn_new_build = self.tlas_rebuild_cooldown_frames == 0 and !self.bvh_build_in_progress and !completed_tlas_this_call;

        if (wants_rebuild and can_spawn_new_build) {
            // Clear force flag when we actually start the build
            if (self.force_rebuild) {
                self.force_rebuild = false;
            }

            // Clear renderables_dirty flag so we don't rebuild again next frame
            // This flag gets set by RenderSystem.checkForChanges() and needs to be cleared
            // immediately when we consume it (spawn TLAS build)
            render_system.renderables_dirty = false;
            render_system.transform_only_change = false;

            // Get current raytracing data
            const rt_data = try render_system.getRaytracingData();
            defer {
                self.allocator.free(rt_data.instances);
                self.allocator.free(rt_data.geometries);
                self.allocator.free(rt_data.materials);
            }

            // Create TlasJob and spawn TLAS worker
            // When it completes, registry will handle the swap automatically
            try self.spawnTlasWorker(rt_data);

            return false;
        }

        return false; // No rebuild needed or already in progress
    }

    /// Spawn TLAS worker as a ThreadPool job - event-driven approach
    fn spawnTlasWorker(self: *RaytracingSystem, rt_data: RenderData.RaytracingData) !void {
        // Extract stable geometry IDs from rt_data using asset IDs
        const required_geom_ids = try self.allocator.alloc(u32, rt_data.geometries.len);
        for (rt_data.geometries, 0..) |geom, i| {
            required_geom_ids[i] = geom.getGeometryId();
        }

        // Copy geometries for BLAS spawning
        const geometries_copy = try self.allocator.alloc(RenderData.RaytracingData.RTGeometry, rt_data.geometries.len);
        for (rt_data.geometries, 0..) |geom, i| {
            geometries_copy[i] = geom;
        }

        // Copy instances for the job
        const instances_copy = try self.allocator.alloc(InstanceData, rt_data.instances.len);
        for (rt_data.instances, 0..) |inst, i| {
            instances_copy[i] = InstanceData{
                .blas_address = 0, // Will be filled by TLAS worker from buffer
                .transform = inst.transform,
                .custom_index = inst.material_index,
                .mask = inst.mask,
                .sbt_offset = 0,
                .flags = 0,
            };
        }

        // Create atomic BLAS buffer: one slot per geometry
        // BLAS workers will fill their slots atomically
        const blas_buffer = try self.allocator.alloc(std.atomic.Value(?*BlasResult), rt_data.geometries.len);
        for (blas_buffer) |*slot| {
            slot.* = std.atomic.Value(?*BlasResult).init(null);
        }

        // Create TlasJob
        const job = try self.allocator.create(TlasJob);
        job.* = TlasJob{
            .job_id = @atomicRmw(u64, &self.next_tlas_job_id, .Add, 1, .monotonic),
            .blas_buffer = blas_buffer,
            .filled_count = std.atomic.Value(u32).init(0),
            .expected_count = @intCast(rt_data.geometries.len),
            .required_geometry_ids = required_geom_ids,
            .geometries = geometries_copy,
            .instances = instances_copy,
            .allocator = self.allocator,
            .builder = self.bvh_builder,
            .completion_sem = .{},
        };

        // Spawn TLAS worker asynchronously via ThreadPool
        // Create work item for TLAS building
        const work_id = job.job_id;
        const thread_pool = ThreadPoolMod;

        // Use createBvhBuildingWork for TLAS with job as work_data
        const work_item = thread_pool.createBvhBuildingWork(
            work_id,
            .tlas,
            @ptrCast(job),
            .full_rebuild,
            .high, // TLAS builds are high priority
            TlasWorker.tlasWorkerMain,
            @ptrCast(job), // Pass job as context
        );
        // Mark build as in progress
        self.bvh_build_in_progress = true;

        // Submit to thread pool
        // Note: Job cleanup will happen when system picks up completed_tlas
        // or in deinit if still pending
        try self.bvh_builder.thread_pool.submitWork(work_item);
    }

    /// Get the current TLAS handle for rendering
    /// Returns null if no TLAS has been built yet
    /// This is safe to call from any thread and stable for the entire frame
    pub fn getTlas(self: *const RaytracingSystem) ?vk.AccelerationStructureKHR {
        if (self.getSet("default")) |set| {
            if (set.tlas.generation.load(.acquire) > 0) {
                return set.tlas.acceleration_structure();
            }
        }
        return null;
    }

    /// Check if TLAS is valid/available
    pub fn isTlasValid(self: *const RaytracingSystem) bool {
        if (self.getSet("default")) |set| {
            return set.tlas.generation.load(.acquire) > 0;
        }
        return false;
    }

    /// Get ManagedTLAS for a specific set (returns null if not found or not created yet)
    /// This provides generation tracking for descriptor rebinding
    pub fn getManagedTLAS(self: *RaytracingSystem, set_name: []const u8) ?*ManagedTLAS {
        if (self.getSet(set_name)) |set| {
            // Only return if TLAS has been created (generation > 0)
            if (set.tlas.generation.load(.acquire) > 0) {
                return &set.tlas;
            }
        }
        return null;
    }

    /// Get ManagedTLAS for the default set
    pub fn getDefaultManagedTLAS(self: *RaytracingSystem) ?*ManagedTLAS {
        return self.getManagedTLAS("default");
    }

    pub fn deinit(self: *RaytracingSystem) void {
        // Wait for all GPU operations to complete before cleanup
        self.gc.vkd.deviceWaitIdle(self.gc.dev) catch |err| {
            log(.WARN, "raytracing", "Failed to wait for device idle during deinit: {}", .{err});
        };

        // Clean up acceleration structure sets
        var iter = self.as_sets.iterator();
        while (iter.next()) |entry| {
            const set = entry.value_ptr;

            // Destroy TLAS if created (atomically take ownership)
            if (set.tlas.current.swap(null, .acquire)) |entry_ptr| {
                self.gc.vkd.destroyAccelerationStructureKHR(self.gc.dev, entry_ptr.acceleration_structure, null);
                if (self.gc.memory_tracker) |tracker| {
                    var name_buf: [128]u8 = undefined;
                    const tlas_name = std.fmt.bufPrint(&name_buf, "tlas_{s}", .{set.name}) catch "tlas_unknown";
                    tracker.untrackAllocation(tlas_name);
                }
                var buf = entry_ptr.buffer;
                buf.deinit();
                var inst_buf = entry_ptr.instance_buffer;
                inst_buf.deinit();
                self.allocator.destroy(entry_ptr);
            }

            // Free BLAS handles
            set.blas_handles.deinit(self.allocator);

            // Free geometry buffers
            set.geometry_buffers.deinit();

            // Free set name
            self.allocator.free(set.name);
        }
        self.as_sets.deinit();

        // Flush all per-frame destruction queues (old resources queued for deferred destruction)
        log(.INFO, "raytracing", "Deinit: flushing per-frame destruction queues", .{});
        for (&self.per_frame_destroy) |*queue| {
            self.flushDestroyQueue(queue);
        }

        // Deinit multithreaded BVH builder (heap allocated)
        self.bvh_builder.deinit();
        self.allocator.destroy(self.bvh_builder);

        // Free the per-frame queue allocations
        for (&self.per_frame_destroy) |*queue| {
            queue.deinit(self.allocator);
        }

        // Destroy shader binding table buffer and free its memory
        if (self.shader_binding_table != .null_handle) {
            // Untrack SBT memory before destroying
            if (self.gc.memory_tracker) |tracker| {
                tracker.untrackAllocation("raytracing_sbt");
            }
            self.gc.vkd.destroyBuffer(self.gc.dev, self.shader_binding_table, null);
        }
        if (self.shader_binding_table_memory != .null_handle) self.gc.vkd.freeMemory(self.gc.dev, self.shader_binding_table_memory, null);
    }

    /// Flush a destruction queue, destroying all queued resources
    /// Called after GPU has finished using resources for a particular frame
    fn flushDestroyQueue(self: *RaytracingSystem, queue: *PerFrameDestroyQueue) void {
        // Destroy BLAS acceleration structures and their backing buffers
        // Process handles and buffers together to match tracking
        for (queue.blas_handles.items, queue.blas_buffers.items) |handle, *buf| {
            self.gc.vkd.destroyAccelerationStructureKHR(self.gc.dev, handle, null);
            // Untrack BLAS memory using unique handle-based name
            if (self.gc.memory_tracker) |tracker| {
                var name_buf: [64]u8 = undefined;
                const blas_name = std.fmt.bufPrint(&name_buf, "blas_{d}", .{@intFromEnum(handle)}) catch "blas_unknown";
                tracker.untrackAllocation(blas_name);
            }
            buf.deinit();
        }
        queue.blas_handles.clearRetainingCapacity();
        queue.blas_buffers.clearRetainingCapacity();

        // Destroy TLAS acceleration structures and their backing buffers
        // Process handles and buffers together to match tracking
        for (queue.tlas_handles.items, queue.tlas_buffers.items) |handle, *buf| {
            self.gc.vkd.destroyAccelerationStructureKHR(self.gc.dev, handle, null);
            // Untrack TLAS memory using unique handle-based name
            if (self.gc.memory_tracker) |tracker| {
                var name_buf: [64]u8 = undefined;
                const tlas_name = std.fmt.bufPrint(&name_buf, "tlas_{d}", .{@intFromEnum(handle)}) catch "tlas_unknown";
                tracker.untrackAllocation(tlas_name);
            }
            buf.deinit();
        }
        queue.tlas_handles.clearRetainingCapacity();
        queue.tlas_buffers.clearRetainingCapacity();

        for (queue.tlas_instance_buffers.items) |*buf| {
            buf.deinit();
        }
        queue.tlas_instance_buffers.clearRetainingCapacity();
    }

    /// Flush deferred resources for a specific frame
    /// Call this AFTER waiting for that frame's fence to ensure GPU is done
    pub fn flushDeferredFrame(self: *RaytracingSystem, frame_index: u32) void {
        self.flushDestroyQueue(&self.per_frame_destroy[frame_index]);
    }

    /// Force a rebuild on the next update, overriding all checks
    /// Call this when enabling PT to ensure fresh BVH
    pub fn forceRebuild(self: *RaytracingSystem) void {
        self.force_rebuild = true;
    }

    /// Flush ALL pending destruction queues immediately
    /// Use this when disabling the RT pass to clean up before re-enabling
    pub fn flushAllPendingDestruction(self: *RaytracingSystem) void {
        log(.INFO, "raytracing", "Flushing ALL pending destruction queues", .{});
        for (&self.per_frame_destroy, 0..) |*queue, i| {
            const blas_count = queue.blas_handles.items.len;
            const tlas_count = queue.tlas_handles.items.len;
            if (blas_count > 0 or tlas_count > 0) {
                log(.INFO, "raytracing", "  Frame {}: {} BLAS, {} TLAS", .{ i, blas_count, tlas_count });
            }
            self.flushDestroyQueue(queue);
        }
    }
};
