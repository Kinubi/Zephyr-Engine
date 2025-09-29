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
        texture_index: u32,
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
    materials: []const MaterialData,
    textures: []const *const Texture,

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
        transform: [12]f32, // 3x4 transform matrix
        instance_id: u32,
        mask: u8 = 0xFF,
        geometry_index: u32,
        material_index: u32,
    };

    /// Raytracing geometry description
    pub const RTGeometry = struct {
        vertex_buffer: vk.Buffer,
        vertex_offset: u64 = 0,
        vertex_stride: u32,
        vertex_count: u32,
        index_buffer: ?vk.Buffer = null,
        index_offset: u64 = 0,
        index_count: u32 = 0,
        blas: ?vk.AccelerationStructureKHR = null,
    };

    instances: []const RTInstance,
    geometries: []const RTGeometry,
    materials: []const RasterizationData.MaterialData, // Reuse material structure

    /// Check if TLAS needs rebuilding
    pub fn needsTLASRebuild(self: *const RaytracingData) bool {
        _ = self;
        // TODO: Track instance changes
        return false;
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
