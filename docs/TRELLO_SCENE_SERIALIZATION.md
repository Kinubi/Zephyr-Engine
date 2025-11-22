# Trello Board: Scene Serialization

**Goal**: Implement Save/Load functionality for Scenes to enable persistent world building.

## 📋 Backlog (To Do)

### 1. Architecture & Data Design
- [ ] **Define Scene File Format (JSON)**
    - [ ] Design JSON schema for `.scene` files.
    - [ ] Decide on handling Entity IDs (runtime vs persistent UUIDs).
    - [ ] Decide on handling Asset IDs (paths vs UUIDs).
- [ ] **Create `SceneSerializer` Struct**
    - [ ] Define `serialize(scene: *Scene, writer: anytype) !void`.
    - [ ] Define `deserialize(scene: *Scene, reader: anytype) !void`.

### 2. Component Serialization
- [ ] **Implement `Serialize` Interface for Components**
    - [ ] Create a mixin or interface for components to define `jsonSerialize` and `jsonDeserialize`.
- [ ] **Implement `Transform` Serialization**
    - [ ] Serialize Position (Vec3), Rotation (Quat), Scale (Vec3).
    - [ ] Handle Parent-Child relationships (store parent's persistent ID).
- [ ] **Implement `MeshRenderer` Serialization**
    - [ ] Serialize `model_asset` (convert AssetId -> File Path).
    - [ ] Serialize `texture_asset` (convert AssetId -> File Path).
    - [ ] Serialize flags (enabled, casts_shadows, etc.).
- [ ] **Implement `PointLight` Serialization**
    - [ ] Serialize color, intensity, radius.
- [ ] **Implement `Name` Serialization**
    - [ ] Serialize entity name string.

### 3. Scene System Integration
- [ ] **Implement `Scene.save(path: []const u8)`**
    - [ ] Iterate all entities.
    - [ ] Collect all components.
    - [ ] Write to JSON file.
- [ ] **Implement `Scene.load(path: []const u8)`**
    - [ ] Clear current scene (destroy all entities).
    - [ ] Parse JSON.
    - [ ] Re-create entities and components.
    - [ ] Re-link parent-child hierarchies (2-pass loading).
    - [ ] Request assets from AssetManager.

### 4. Editor Integration
- [ ] **Add "Save Scene" Menu Item**
    - [ ] Add to File menu in MainMenuBar.
    - [ ] Open file dialog (if possible) or save to fixed path for now.
- [ ] **Add "Load Scene" Menu Item**
    - [ ] Add to File menu.
    - [ ] Trigger scene reload.
- [ ] **Add "Save" Shortcut (Ctrl+S)**
    - [ ] Handle input event in Editor layer.

### 5. Asset Management Updates
- [ ] **Asset Path Lookup**
    - [ ] Ensure `AssetManager` can return the file path for a given `AssetId` (needed for saving).
    - [ ] Ensure `AssetManager` can return an `AssetId` for a given file path (needed for loading).

## 🏃 In Progress
*   (Empty - Drag items here when starting)

## ✅ Done
*   (Empty)

---

## 📝 Notes
*   **JSON Library**: Use Zig's standard `std.json`.
*   **UUIDs**: We likely need to add a `UuidComponent` to every entity to ensure stable references (parenting) across save/load cycles, as runtime `EntityId`s will change.
*   **Asset Paths**: We must store relative paths (e.g., `assets/models/cube.obj`) not absolute paths.
