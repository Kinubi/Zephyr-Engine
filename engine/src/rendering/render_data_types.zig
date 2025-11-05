const std = @import("std");
const vk = @import("vulkan");
const Mesh = @import("mesh.zig").Mesh;
const AssetId = @import("../assets/asset_types.zig").AssetId;

/// Shared data structure definitions for rendering systems
/// These types are used by render_system, raytracing_system, and rendering passes
/// Rasterization-specific scene data
pub const RasterizationData = struct {
    /// TODO(FEATURE): ADD SORTING KEY FOR STATE-CHANGE MINIMIZATION - MEDIUM PRIORITY
    /// Currently: RenderableObject has no sorting key, objects drawn in ECS iteration order
    /// Required: Add sort_key: u64 = (pipeline_id << 48 | material_id << 32 | mesh_id)
    /// Usage: Sort objects before draw loop in geometry_pass.zig
    /// Benefits: Reduce pipeline/descriptor binding overhead, better GPU cache coherency
    /// Branch: features/draw-call-sorting
    pub const RenderableObject = struct {
        pub const MeshHandle = struct {
            mesh_ptr: *const Mesh,

            pub fn getMesh(self: MeshHandle) *const Mesh {
                return self.mesh_ptr;
            }
        };

        transform: [16]f32,
        mesh_handle: MeshHandle,
        material_index: u32,
        visible: bool = true,
    };

    pub const MaterialData = struct {
        base_color: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
        metallic: f32 = 0.0,
        roughness: f32 = 1.0,
        emissive: f32 = 0.0,
        texture_index: u32 = 0,
    };

    objects: []const RenderableObject,

    pub fn getVisibleObjects(self: *const RasterizationData) []const RenderableObject {
        return self.objects;
    }
};

/// Raytracing-specific scene data
pub const RaytracingData = struct {
    pub const RTInstance = struct {
        transform: [3][4]f32,
        instance_id: u32,
        mask: u8 = 0xFF,
        geometry_index: u32,
        material_index: u32,
    };

    pub const RTGeometry = struct {
        mesh_ptr: *Mesh,
        // TODO(FEATURE): MOVE BLAS OWNERSHIP HERE - HIGH PRIORITY
        // Currently: blas field is optional and populated from global registry
        // Problem: Global registry causes redundant rebuilds when mesh_ptr changes
        // Solution: BLAS should be owned by Mesh (via mesh_ptr), not stored here or in registry
        // After refactor: Remove this field, access via mesh_ptr.getBlas()
        // Related: See geometry.zig, multithreaded_bvh_builder.zig TODOs
        // Branch: features/blas-ownership
        blas: ?vk.AccelerationStructureKHR = null,
        model_asset: AssetId, // Track which asset this geometry came from

        /// Get stable geometry_id from asset ID (lower 16 bits to fit in 256-slot registry)
        pub fn getGeometryId(self: RTGeometry) u32 {
            return @truncate(@intFromEnum(self.model_asset) & 0xFFFF);
        }
    };

    pub const BvhChangeTracker = struct {
        last_object_count: usize = 0,
        last_geometry_count: usize = 0,
        last_instance_count: usize = 0,
        resources_updated: bool = false,
        force_rebuild: bool = false,

        pub fn needsRebuild(
            self: *BvhChangeTracker,
            current_objects: usize,
            current_geometries: usize,
            current_instances: usize,
            resources_changed: bool,
        ) bool {
            const needs_rebuild = self.force_rebuild or
                (current_objects != self.last_object_count) or
                (current_geometries != self.last_geometry_count) or
                (current_instances != self.last_instance_count) or
                resources_changed;

            if (needs_rebuild) {
                self.last_object_count = current_objects;
                self.last_geometry_count = current_geometries;
                self.last_instance_count = current_instances;
                self.resources_updated = resources_changed;
                self.force_rebuild = false;
            }

            return needs_rebuild;
        }

        pub fn forceRebuild(self: *BvhChangeTracker) void {
            self.force_rebuild = true;
        }
    };

    instances: []const RTInstance,
    geometries: []const RTGeometry,
    materials: []const RasterizationData.MaterialData,
    change_tracker: BvhChangeTracker = .{},

    pub fn needsTLASRebuild(self: *RaytracingData, resources_updated: bool) bool {
        return self.change_tracker.needsRebuild(self.instances.len, self.geometries.len, self.instances.len, resources_updated);
    }

    pub fn forceRebuild(self: *RaytracingData) void {
        self.change_tracker.forceRebuild();
    }
};

/// Compute-specific scene data
pub const ComputeData = struct {
    pub const ParticleSystem = struct {
        position_buffer: vk.Buffer,
        velocity_buffer: vk.Buffer,
        particle_count: u32,
        max_particles: u32,
        emit_rate: f32,
        lifetime: f32,
    };

    pub const ComputeTask = struct {
        dispatch_x: u32,
        dispatch_y: u32 = 1,
        dispatch_z: u32 = 1,
        pipeline: vk.Pipeline,
        descriptor_set: vk.DescriptorSet,
    };

    particle_systems: []const ParticleSystem,
    compute_tasks: []const ComputeTask,

    pub fn getActiveParticleSystems(self: *const ComputeData) []const ParticleSystem {
        return self.particle_systems;
    }
};
