const std = @import("std");
const vk = @import("vulkan");
const Buffer = @import("../core/buffer.zig").Buffer;
const Texture = @import("../core/texture.zig").Texture;
const Mesh = @import("mesh.zig").Mesh;

pub const Geometry = struct {
    name: []const u8,
    mesh: *Mesh,
    material: ?*Material = null,

    // TODO(FEATURE): MOVE BLAS OWNERSHIP TO MESH/GEOMETRY - HIGH PRIORITY
    // Currently BLAS stored in global registry (multithreaded_bvh_builder.zig)
    // This causes redundant rebuilds when the same mesh is used multiple times.
    //
    // Required changes:
    // 1. Replace ?*anyopaque with actual BLAS type (vk.AccelerationStructureKHR + Buffer)
    // 2. Add reference counting for shared meshes (multiple Geometry can share same Mesh)
    // 3. Build BLAS once when mesh is loaded, store here
    // 4. Refactor multithreaded_bvh_builder.zig to lookup BLAS from mesh, not registry
    // 5. Add BLAS lifecycle management (build on load, destroy with mesh)
    //
    // Benefits: No redundant BLAS rebuilds, clearer ownership, easier caching
    // Complexity: HIGH - requires raytracing system refactor + reference counting
    // Branch: features/blas-ownership (coordinate with raytracing system changes)
    blas: ?*anyopaque = null, // Replace with actual BLAS type if available
    // Optional: bounding box, etc.
    // ...

    pub fn deinit(self: *Geometry, allocator: std.mem.Allocator) void {
        self.mesh.deinit(allocator);
        allocator.destroy(self.mesh);

        if (self.material) |mat| mat.deinit(allocator);
        // Note: BLAS (raytracing acceleration structure) managed by raytracing system
    }
};

pub const Material = struct {
    name: []const u8,
    base_color_texture: ?*Texture = null,
    normal_texture: ?*Texture = null,
    metallic_roughness_texture: ?*Texture = null,
    // ...other PBR properties

    pub fn deinit(self: *Material, allocator: std.mem.Allocator) void {
        if (self.base_color_texture) |tex| tex.deinit(allocator);
        if (self.normal_texture) |tex| tex.deinit(allocator);
        if (self.metallic_roughness_texture) |tex| tex.deinit(allocator);
    }
};
