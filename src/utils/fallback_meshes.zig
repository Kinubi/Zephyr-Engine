const std = @import("std");
const Mesh = @import("../mesh.zig").Mesh;
const Vertex = @import("../mesh.zig").Vertex;
const Model = @import("../mesh.zig").Model;
const ModelMesh = @import("../mesh.zig").ModelMesh;
const Transform = @import("../mesh.zig").Transform;
const Geometry = @import("../geometry.zig").Geometry;
const GraphicsContext = @import("../graphics_context.zig").GraphicsContext;

/// Generate fallback meshes for when model loading fails or is slow
pub const FallbackMeshes = struct {
    /// Create a simple cube mesh as a fallback
    pub fn createCubeMesh(allocator: std.mem.Allocator) !Mesh {
        var mesh = Mesh.init(allocator);

        // Cube vertices (same as in app.zig)
        try mesh.vertices.appendSlice(allocator, &.{
            // Left Face
            Vertex{ .pos = .{ -0.5, -0.5, -0.5 }, .color = .{ 0.7, 0.7, 0.7 } },
            Vertex{ .pos = .{ -0.5, 0.5, 0.5 }, .color = .{ 0.7, 0.7, 0.7 } },
            Vertex{ .pos = .{ -0.5, -0.5, 0.5 }, .color = .{ 0.7, 0.7, 0.7 } },
            Vertex{ .pos = .{ -0.5, 0.5, -0.5 }, .color = .{ 0.7, 0.7, 0.7 } },

            // Right face
            Vertex{ .pos = .{ 0.5, -0.5, -0.5 }, .color = .{ 0.8, 0.8, 0.8 } },
            Vertex{ .pos = .{ 0.5, 0.5, 0.5 }, .color = .{ 0.8, 0.8, 0.8 } },
            Vertex{ .pos = .{ 0.5, -0.5, 0.5 }, .color = .{ 0.8, 0.8, 0.8 } },
            Vertex{ .pos = .{ 0.5, 0.5, -0.5 }, .color = .{ 0.8, 0.8, 0.8 } },

            // Top face
            Vertex{ .pos = .{ -0.5, -0.5, -0.5 }, .color = .{ 0.9, 0.9, 0.9 } },
            Vertex{ .pos = .{ 0.5, -0.5, 0.5 }, .color = .{ 0.9, 0.9, 0.9 } },
            Vertex{ .pos = .{ -0.5, -0.5, 0.5 }, .color = .{ 0.9, 0.9, 0.9 } },
            Vertex{ .pos = .{ 0.5, -0.5, -0.5 }, .color = .{ 0.9, 0.9, 0.9 } },

            // Bottom face
            Vertex{ .pos = .{ -0.5, 0.5, -0.5 }, .color = .{ 0.6, 0.6, 0.6 } },
            Vertex{ .pos = .{ 0.5, 0.5, 0.5 }, .color = .{ 0.6, 0.6, 0.6 } },
            Vertex{ .pos = .{ -0.5, 0.5, 0.5 }, .color = .{ 0.6, 0.6, 0.6 } },
            Vertex{ .pos = .{ 0.5, 0.5, -0.5 }, .color = .{ 0.6, 0.6, 0.6 } },

            // Front Face
            Vertex{ .pos = .{ -0.5, -0.5, 0.5 }, .color = .{ 0.7, 0.7, 0.7 } },
            Vertex{ .pos = .{ 0.5, 0.5, 0.5 }, .color = .{ 0.7, 0.7, 0.7 } },
            Vertex{ .pos = .{ -0.5, 0.5, 0.5 }, .color = .{ 0.7, 0.7, 0.7 } },
            Vertex{ .pos = .{ 0.5, -0.5, 0.5 }, .color = .{ 0.7, 0.7, 0.7 } },

            // Back Face
            Vertex{ .pos = .{ -0.5, -0.5, -0.5 }, .color = .{ 0.5, 0.5, 0.5 } },
            Vertex{ .pos = .{ 0.5, 0.5, -0.5 }, .color = .{ 0.5, 0.5, 0.5 } },
            Vertex{ .pos = .{ -0.5, 0.5, -0.5 }, .color = .{ 0.5, 0.5, 0.5 } },
            Vertex{ .pos = .{ 0.5, -0.5, -0.5 }, .color = .{ 0.5, 0.5, 0.5 } },
        });

        // Cube indices
        try mesh.indices.appendSlice(allocator, &.{
            0, 1, 2, 0, 3, 1, // Left face
            4, 5, 6, 4, 7, 5, // Right face
            8, 9, 10, 8, 11, 9, // Top face
            12, 13, 14, 12, 15, 13, // Bottom face
            16, 17, 18, 16, 19, 17, // Front face
            20, 21, 22, 20, 23, 21, // Back face
        });

        return mesh;
    }

    /// Create a simple cube Model as a fallback
    pub fn createCubeModel(allocator: std.mem.Allocator, gc: *GraphicsContext, name: []const u8) !Model {
        var meshes = std.ArrayList(ModelMesh){};

        // Create the cube mesh
        var cube_mesh = try createCubeMesh(allocator);
        try cube_mesh.createVertexBuffers(gc);
        try cube_mesh.createIndexBuffers(gc);

        // Create a geometry wrapper
        const geometry = Geometry{
            .name = try allocator.dupe(u8, name),
            .mesh = cube_mesh,
            .material = null,
            .blas = null,
        };

        // Create the model mesh
        const model_mesh = ModelMesh{
            .geometry = geometry,
            .local_transform = Transform{},
        };

        try meshes.append(allocator, model_mesh);

        return Model{
            .meshes = meshes,
            .allocator = allocator,
        };
    }
};
