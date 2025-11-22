const std = @import("std");
const ecs = @import("../ecs.zig");
const Scene = @import("scene.zig").Scene;
const AssetManager = @import("../assets/asset_manager.zig").AssetManager;
const AssetId = @import("../assets/asset_types.zig").AssetId;
const UuidComponent = @import("../ecs/components/uuid.zig").UuidComponent;

/// Handles serialization and deserialization of Scenes to/from JSON
pub const SceneSerializer = struct {
    scene: *Scene,
    allocator: std.mem.Allocator,

    pub fn init(scene: *Scene) SceneSerializer {
        return .{
            .scene = scene,
            .allocator = scene.allocator,
        };
    }

    /// Helper to get UUID for an entity ID
    pub fn getEntityUuid(self: *SceneSerializer, entity: ecs.EntityId) ?UuidComponent {
        return self.scene.ecs_world.get(UuidComponent, entity);
    }

    /// Helper to get Asset Path for an Asset ID
    pub fn getAssetPath(self: *SceneSerializer, asset_id: AssetId) ?[]const u8 {
        return self.scene.asset_manager.getAssetPath(asset_id);
    }

    /// Helper to get Asset ID for a path (loading if needed? or just lookup?)
    /// For serialization we just need path lookup. Deserialization needs path->ID.
    pub fn getAssetId(self: *SceneSerializer, path: []const u8) ?AssetId {
        return self.scene.asset_manager.getAssetId(path);
    }

    /// Serialize the entire scene to a JSON writer
    pub fn serialize(self: *SceneSerializer, writer: anytype) !void {
        try writer.beginObject();
        
        try writer.objectField("name");
        try writer.write(self.scene.name);
        
        try writer.objectField("entities");
        try writer.beginArray();
        
        for (self.scene.entities.items) |entity| {
            // Only serialize entities with a UUID component
            if (self.scene.ecs_world.get(UuidComponent, entity)) |uuid_comp| {
                try writer.beginObject();
                
                try writer.objectField("uuid");
                const uuid_str = try std.fmt.allocPrint(self.allocator, "{}", .{uuid_comp});
                defer self.allocator.free(uuid_str);
                try writer.write(uuid_str);
                
                try writer.objectField("components");
                try writer.beginObject();
                
                // Core components
                try self.serializeComponent(ecs.Name, "Name", entity, writer);
                try self.serializeComponent(ecs.Transform, "Transform", entity, writer);
                try self.serializeComponent(ecs.MeshRenderer, "MeshRenderer", entity, writer);
                try self.serializeComponent(ecs.Camera, "Camera", entity, writer);
                try self.serializeComponent(ecs.PointLight, "PointLight", entity, writer);
                try self.serializeComponent(ecs.ScriptComponent, "ScriptComponent", entity, writer);
                try self.serializeComponent(ecs.ParticleEmitter, "ParticleEmitter", entity, writer);
                try self.serializeComponent(ecs.MaterialSet, "MaterialSet", entity, writer);
                
                // Material property components
                try self.serializeComponent(ecs.AlbedoMaterial, "AlbedoMaterial", entity, writer);
                try self.serializeComponent(ecs.RoughnessMaterial, "RoughnessMaterial", entity, writer);
                try self.serializeComponent(ecs.MetallicMaterial, "MetallicMaterial", entity, writer);
                try self.serializeComponent(ecs.NormalMaterial, "NormalMaterial", entity, writer);
                try self.serializeComponent(ecs.EmissiveMaterial, "EmissiveMaterial", entity, writer);
                try self.serializeComponent(ecs.OcclusionMaterial, "OcclusionMaterial", entity, writer);

                try writer.endObject(); // components
                
                try writer.endObject(); // entity
            }
        }
        
        try writer.endArray(); // entities
        try writer.endObject(); // scene
    }

    fn serializeComponent(self: *SceneSerializer, comptime T: type, name: []const u8, entity: ecs.EntityId, writer: anytype) !void {
        if (self.scene.ecs_world.get(T, entity)) |component| {
            try writer.objectField(name);
            try component.serialize(self, writer);
        }
    }
};
