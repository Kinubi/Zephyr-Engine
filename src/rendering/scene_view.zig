const std = @import("std");
const vk = @import("vulkan");
const GameObject = @import("../scene/game_object.zig").GameObject;
const Mesh = @import("mesh.zig").Mesh;
const Texture = @import("../core/texture.zig").Texture;

/// Rasterization-specific scene data
pub const RasterizationData = struct {
    /// Mesh handle for efficient referencing without copying
    /// Renderable objects with meshes and materials
    pub const RenderableObject = struct {
        /// Mesh handle for efficient referencing without copying
        pub const MeshHandle = struct {
            mesh_ptr: *const Mesh,

            pub fn getMesh(self: MeshHandle) *const Mesh {
                return self.mesh_ptr;
            }
        };

        transform: [16]f32, // 4x4 matrix
        mesh_handle: MeshHandle,
        material_index: u32,
        visible: bool = true,
    };

    /// Material data for GPU upload
    pub const MaterialData = struct {
        base_color: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
        metallic: f32 = 0.0,
        roughness: f32 = 1.0,
        emissive: f32 = 0.0,
        texture_index: u32 = 0,
    };

    objects: []const RenderableObject,
    // materials: []const MaterialData,
    // textures: []const *const Texture,

    /// Get objects that should be rendered this frame
    pub fn getVisibleObjects(self: *const RasterizationData) []const RenderableObject {
        // TODO: Implement frustum culling
        return self.objects;
    }
};

/// Raytracing-specific scene data
pub const RaytracingData = struct {
    /// Geometry instance for raytracing
    pub const RTInstance = struct {
        transform: [3][4]f32, // 3x4 transform matrix
        instance_id: u32,
        mask: u8 = 0xFF,
        geometry_index: u32,
        material_index: u32,
    };

    /// Raytracing geometry description
    pub const RTGeometry = struct {
        mesh_ptr: *@import("mesh.zig").Mesh,
        blas: ?vk.AccelerationStructureKHR = null,
    };

    /// BVH change tracking information
    pub const BvhChangeTracker = struct {
        last_object_count: usize = 0,
        last_geometry_count: usize = 0,
        last_instance_count: usize = 0,
        resources_updated: bool = false,
        force_rebuild: bool = false,

        /// Check if BVH needs to be rebuilt
        pub fn needsRebuild(self: *BvhChangeTracker, current_objects: usize, current_geometries: usize, current_instances: usize, resources_changed: bool) bool {
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

        /// Force a BVH rebuild on next check
        pub fn forceRebuild(self: *BvhChangeTracker) void {
            self.force_rebuild = true;
        }
    };

    instances: []const RTInstance,
    geometries: []const RTGeometry,
    materials: []const RasterizationData.MaterialData, // Reuse material structure

    // BVH change tracking (mutable for tracking state changes)
    change_tracker: BvhChangeTracker = .{},

    /// Check if TLAS needs rebuilding based on scene changes
    pub fn needsTLASRebuild(self: *RaytracingData, resources_updated: bool) bool {
        return self.change_tracker.needsRebuild(self.instances.len, self.geometries.len, self.instances.len, resources_updated);
    }

    /// Force a TLAS rebuild on next check
    pub fn forceRebuild(self: *RaytracingData) void {
        self.change_tracker.forceRebuild();
    }
};

/// Compute-specific scene data
pub const ComputeData = struct {
    /// Particle system data
    pub const ParticleSystem = struct {
        position_buffer: vk.Buffer,
        velocity_buffer: vk.Buffer,
        particle_count: u32,
        max_particles: u32,
        emit_rate: f32,
        lifetime: f32,
    };

    /// Compute task description
    pub const ComputeTask = struct {
        dispatch_x: u32,
        dispatch_y: u32 = 1,
        dispatch_z: u32 = 1,
        pipeline: vk.Pipeline,
        descriptor_set: vk.DescriptorSet,
    };

    particle_systems: []const ParticleSystem,
    compute_tasks: []const ComputeTask,

    /// Get active particle systems that need updating
    pub fn getActiveParticleSystems(self: *const ComputeData) []const ParticleSystem {
        return self.particle_systems; // TODO: Filter active systems
    }
};
