# Scene Serialization Design Document

**Status**: Draft
**Date**: November 22, 2025
**Author**: GitHub Copilot

## 1. Overview
This document outlines the design for saving and loading scenes in the Zephyr Engine. The goal is to persist the state of the ECS world, including entities, their components, and their relationships, to a human-readable format (JSON).

## 2. File Format (JSON)
We will use JSON for its readability and ease of debugging.

### Schema Example
```json
{
  "version": "1.0",
  "name": "MainLevel",
  "entities": [
    {
      "id": "550e8400-e29b-41d4-a716-446655440000",
      "name": "Player",
      "components": {
        "Transform": {
          "position": [0.0, 1.0, 0.0],
          "rotation": [0.0, 0.0, 0.0, 1.0],
          "scale": [1.0, 1.0, 1.0],
          "parent": null
        },
        "MeshRenderer": {
          "model": "assets/models/hero.obj",
          "enabled": true,
          "casts_shadows": true,
          "receives_shadows": true
        },
        "MaterialSet": {
          "set_name": "opaque",
          "shader_variant": "pbr_standard"
        },
        "AlbedoMaterial": {
          "texture": "assets/textures/hero_diffuse.png",
          "color": [1.0, 1.0, 1.0, 1.0]
        },
        "RoughnessMaterial": {
          "texture": "assets/textures/hero_roughness.png",
          "factor": 0.8
        }
      }
    },
    {
      "id": "770e8400-e29b-41d4-a716-446655441111",
      "name": "Sword",
      "components": {
        "Transform": {
          "position": [0.5, 0.0, 0.0],
          "rotation": [0.0, 0.0, 0.0, 1.0],
          "scale": [1.0, 1.0, 1.0],
          "parent": "550e8400-e29b-41d4-a716-446655440000" 
        },
        "MeshRenderer": {
          "model": "assets/models/sword.obj"
        },
        "MaterialSet": {
          "set_name": "opaque"
        },
        "MetallicMaterial": {
           "factor": 1.0
        }
      }
    }
  ]
}
```

## 3. Architecture Changes

### 3.1. Stable Entity Identification (UUIDs)
Runtime `EntityId`s (integers) are not stable across sessions. If we save an entity with ID 5, next time we run, ID 5 might be assigned to a different object.
*   **Solution**: Introduce a `UuidComponent` (or add a UUID field to the `Entity` struct if possible, but component is cleaner for ECS).
*   **Usage**: When saving, we write the UUID. When loading, we map the UUID to the new runtime `EntityId`.
*   **Parenting**: The `Transform` component currently stores `parent: ?EntityId`. During serialization, we must look up the parent's UUID. During deserialization, we must resolve the UUID back to the new runtime `EntityId`.

### 3.2. Asset References
Components currently store `AssetId` (u32). This is a runtime handle.
*   **Requirement**: `AssetManager` needs a reverse lookup: `getPath(id: AssetId) -> []const u8`.
*   **Saving**: Convert `AssetId` -> Path.
*   **Loading**: Convert Path -> `AssetId` (loading the asset if necessary).

### 3.3. Serialization System
We will create a `SceneSerializer` struct in `engine/src/scene/scene_serializer.zig`.

```zig
pub const SceneSerializer = struct {
    world: *World,
    asset_manager: *AssetManager,

    pub fn serialize(self: *SceneSerializer, path: []const u8) !void {
        // 1. Open file
        // 2. Iterate all entities with UuidComponent
        // 3. For each entity, iterate all registered component types
        // 4. Write JSON
    }

    pub fn deserialize(self: *SceneSerializer, path: []const u8) !void {
        // 1. Parse JSON
        // 2. First Pass: Create all entities and map UUID -> RuntimeID
        // 3. Second Pass: Deserialize components and resolve UUID references (parenting)
    }
};
```

## 4. Implementation Steps

### Phase 1: Foundation
1.  Add `UuidComponent` to `engine/src/ecs/components/uuid.zig`.
2.  Update `Scene.spawnProp` and other spawn methods to automatically attach a random UUID.
3.  Implement `AssetManager.getAssetPath(id)`.

### Phase 2: Component Serialization
1.  Define a `serialize` method for `Transform`, `MeshRenderer`, `PointLight`, `Name`.
2.  **Material System Serialization**:
    *   Serialize `MaterialSet` (set name, shader variant).
    *   Serialize `AlbedoMaterial` (texture path, color tint).
    *   Serialize `RoughnessMaterial` (texture path, factor).
    *   Serialize `MetallicMaterial` (texture path, factor).
    *   Serialize `NormalMaterial` (texture path, strength).
    *   Serialize `EmissiveMaterial` (texture path, color, intensity).
3.  Or, use Zig's compile-time reflection to auto-serialize structs, with custom handling for `AssetId` and `EntityId`.

### Phase 3: The Serializer
1.  Implement `SceneSerializer.save`.
2.  Implement `SceneSerializer.load`.

### Phase 4: Editor UI
1.  Add menu bar items.
2.  Connect to `SceneSerializer`.

## 5. Challenges & Solutions
*   **Circular Dependencies**: Parent-child relationships.
    *   *Solution*: Two-pass loading. Pass 1 creates entities. Pass 2 sets parents.
*   **Missing Assets**: What if a file path in the JSON doesn't exist?
    *   *Solution*: Fallback to a default "Error" mesh/texture (purple checkerboard).
*   **Version Compatibility**: What if component data structures change?
    *   *Solution*: Use default values for missing fields. For major changes, bump version number in JSON.
