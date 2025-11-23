const std = @import("std");
const ecs = @import("../ecs.zig");
const Scene = @import("scene.zig").Scene;
const AssetManagerMod = @import("../assets/asset_manager.zig");
const AssetManager = AssetManagerMod.AssetManager;
const LoadPriority = AssetManagerMod.LoadPriority;
const AssetType = AssetManagerMod.AssetType;
const AssetId = @import("../assets/asset_types.zig").AssetId;
const UuidComponent = @import("../ecs/components/uuid.zig").UuidComponent;

/// Handles serialization and deserialization of Scenes to/from JSON
pub const SceneSerializer = struct {
    scene: *Scene,
    allocator: std.mem.Allocator,
    uuid_map: std.AutoHashMap(UuidComponent, ecs.EntityId),

    pub fn init(scene: *Scene) SceneSerializer {
        return .{
            .scene = scene,
            .allocator = scene.allocator,
            .uuid_map = std.AutoHashMap(UuidComponent, ecs.EntityId).init(scene.allocator),
        };
    }

    pub fn deinit(self: *SceneSerializer) void {
        self.uuid_map.deinit();
    }

    /// Helper to get UUID for an entity ID
    pub fn getEntityUuid(self: *SceneSerializer, entity: ecs.EntityId) ?UuidComponent {
        if (self.scene.ecs_world.get(UuidComponent, entity)) |ptr| {
            return ptr.*;
        }
        return null;
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

    /// Helper to get Entity ID for a UUID (used during deserialization)
    pub fn getEntityId(self: *SceneSerializer, uuid: UuidComponent) ?ecs.EntityId {
        return self.uuid_map.get(uuid);
    }

    /// Serialize the entire scene to a JSON writer
    pub fn jsonStringify(self: *SceneSerializer, writer: anytype) !void {
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
                const uuid_str = try std.fmt.allocPrint(self.allocator, "{f}", .{uuid_comp});
                defer self.allocator.free(uuid_str);
                try writer.write(uuid_str);
                
                try writer.objectField("components");
                try writer.beginObject();
                
                // Core components
                try self.serializeComponent(ecs.Name, entity, writer);
                try self.serializeComponent(ecs.Transform, entity, writer);
                try self.serializeComponent(ecs.MeshRenderer, entity, writer);
                try self.serializeComponent(ecs.Camera, entity, writer);
                try self.serializeComponent(ecs.PointLight, entity, writer);
                try self.serializeComponent(ecs.ScriptComponent, entity, writer);
                try self.serializeComponent(ecs.ParticleEmitter, entity, writer);
                try self.serializeComponent(ecs.MaterialSet, entity, writer);
                
                // Material property components
                try self.serializeComponent(ecs.AlbedoMaterial, entity, writer);
                try self.serializeComponent(ecs.RoughnessMaterial, entity, writer);
                try self.serializeComponent(ecs.MetallicMaterial, entity, writer);
                try self.serializeComponent(ecs.NormalMaterial, entity, writer);
                try self.serializeComponent(ecs.EmissiveMaterial, entity, writer);
                try self.serializeComponent(ecs.OcclusionMaterial, entity, writer);

                try writer.endObject(); // components
                
                try writer.endObject(); // entity
            }
        }
        
        try writer.endArray(); // entities
        try writer.endObject(); // scene
    }

    fn serializeComponent(self: *SceneSerializer, comptime T: type, entity: ecs.EntityId, writer: anytype) !void {
        if (self.scene.ecs_world.get(T, entity)) |component| {
            try writer.objectField(T.json_name);
            try component.jsonSerialize(self, writer);
        }
    }

    /// Deserialize a scene from a JSON value tree
    pub fn deserialize(self: *SceneSerializer, root: std.json.Value) !void {
        if (root != .object) return error.InvalidSceneFormat;
        
        // Verify scene name if present (optional)
        // if (root.object.get("name")) |name_val| { ... }

        const entities_val = root.object.get("entities") orelse return error.MissingEntitiesField;
        if (entities_val != .array) return error.InvalidEntitiesFormat;

        // Pass 1: Create all entities and register their UUIDs
        for (entities_val.array.items) |entity_val| {
            if (entity_val != .object) continue;
            
            const uuid_val = entity_val.object.get("uuid") orelse continue;
            if (uuid_val != .string) continue;
            
            const uuid = try UuidComponent.fromString(uuid_val.string);
            
            // Create entity in world
            const entity = try self.scene.ecs_world.createEntity();
            try self.scene.ecs_world.emplace(UuidComponent, entity, uuid);
            try self.scene.entities.append(self.allocator, entity);
            
            // Map UUID to EntityId for reference resolution
            try self.uuid_map.put(uuid, entity);
        }

        // Pass 2: Deserialize components
        for (entities_val.array.items) |entity_val| {
            if (entity_val != .object) continue;
            
            const uuid_val = entity_val.object.get("uuid") orelse continue;
            const uuid = try UuidComponent.fromString(uuid_val.string);
            const entity = self.uuid_map.get(uuid) orelse continue;
            
            const components_val = entity_val.object.get("components") orelse continue;
            if (components_val != .object) continue;
            
            // Core components
            try self.deserializeComponent(ecs.Name, entity, components_val);
            try self.deserializeComponent(ecs.Transform, entity, components_val);
            try self.deserializeComponent(ecs.MeshRenderer, entity, components_val);
            try self.deserializeComponent(ecs.Camera, entity, components_val);
            try self.deserializeComponent(ecs.PointLight, entity, components_val);
            try self.deserializeComponent(ecs.ScriptComponent, entity, components_val);
            try self.deserializeComponent(ecs.ParticleEmitter, entity, components_val);
            try self.deserializeComponent(ecs.MaterialSet, entity, components_val);
            
            // Material property components
            try self.deserializeComponent(ecs.AlbedoMaterial, entity, components_val);
            try self.deserializeComponent(ecs.RoughnessMaterial, entity, components_val);
            try self.deserializeComponent(ecs.MetallicMaterial, entity, components_val);
            try self.deserializeComponent(ecs.NormalMaterial, entity, components_val);
            try self.deserializeComponent(ecs.EmissiveMaterial, entity, components_val);
            try self.deserializeComponent(ecs.OcclusionMaterial, entity, components_val);
        }
    }

    fn deserializeComponent(self: *SceneSerializer, comptime T: type, entity: ecs.EntityId, components_val: std.json.Value) !void {
        if (components_val.object.get(T.json_name)) |comp_val| {
            const component = try T.deserialize(self, comp_val);
            try self.scene.ecs_world.emplace(T, entity, component);
        }
    }
    


    /// Helper to load a model asset (async)
    pub fn loadModel(self: *SceneSerializer, path: []const u8) !AssetId {
        // Use critical priority for scene load to ensure they are available ASAP
        return self.scene.asset_manager.loadAssetAsync(path, .mesh, .critical);
    }

    /// Helper to load a texture asset (async)
    pub fn loadTexture(self: *SceneSerializer, path: []const u8) !AssetId {
        // Use critical priority for scene load to ensure they are available ASAP
        return self.scene.asset_manager.loadAssetAsync(path, .texture, .critical);
    }
};
