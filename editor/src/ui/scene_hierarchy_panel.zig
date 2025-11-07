const std = @import("std");
const zephyr = @import("zephyr");

const c = @import("backend/imgui_c.zig").c;

const ecs = zephyr.ecs;
const World = ecs.World;
const EntityId = ecs.EntityId;
const Transform = ecs.Transform;
const MeshRenderer = ecs.MeshRenderer;
const Camera = ecs.Camera;
const PointLight = ecs.PointLight;
const ParticleEmitter = ecs.ParticleEmitter;
const ScriptComponent = ecs.ScriptComponent;

const Scene = zephyr.Scene;
const Math = zephyr.math;

/// Scene Hierarchy Panel - ImGui panel showing all entities in the ECS world
pub const SceneHierarchyPanel = struct {
    selected_entities: std.ArrayList(EntityId) = std.ArrayList(EntityId){},
    show_hierarchy: bool = true,
    show_inspector: bool = true,

    // Temp buffer for text input
    temp_buffer: [256]u8 = undefined,
    // Script editor buffer (fixed capacity). When an entity with a ScriptComponent
    // is selected, we copy its script into this buffer for editing. We keep the
    // currently editing entity id so we only reload when selection changes.
    script_buffer: [4096]u8 = undefined,
    script_buffer_owner: ?EntityId = null,
    // When true, the inspector will call ImGui_SetWindowFocus() on its next render
    // to ensure keyboard input is directed to the Inspector window.
    request_inspector_focus: bool = false,
    // When true, applying the script will set it to run every frame
    script_auto_run: bool = false,

    pub fn init() SceneHierarchyPanel {
        var panel = SceneHierarchyPanel{};
        panel.selected_entities = std.ArrayList(EntityId){};
        // Zero script buffer length sentinel (not strictly required)
        panel.script_buffer[0] = 0;
        return panel;
    }

    pub fn deinit(self: *SceneHierarchyPanel) void {
        // always free selected_entities storage (ArrayList.deinit is safe
        // even if the list is empty) so we don't leak if capacity was
        // allocated earlier.
        self.selected_entities.deinit(std.heap.page_allocator);
    }

    /// Render the hierarchy panel and inspector
    pub fn render(self: *SceneHierarchyPanel, scene: *Scene) void {
        if (self.show_hierarchy) {
            self.renderHierarchy(scene);
        }

        if (self.show_inspector and self.selected_entities.items.len > 0) {
            self.renderInspector(scene);
        }
    }

    /// Render the entity hierarchy tree
    fn renderHierarchy(self: *SceneHierarchyPanel, scene: *Scene) void {
        const window_flags = c.ImGuiWindowFlags_NoCollapse;

        if (c.ImGui_Begin("Scene Hierarchy", null, window_flags)) {
            c.ImGui_Text("Scene: %s", scene.name.ptr);
            c.ImGui_Text("Entities: %d", scene.getEntityCount());
            // Debug: show current selection count and IDs to verify picking
            c.ImGui_Text("Selected Count: %d", self.selected_entities.items.len);
            var sel_idx: usize = 0;
            for (self.selected_entities.items) |eid| {
                c.ImGui_Text("  [%d] idx=%d (raw=%u)", sel_idx, eid.index(), @intFromEnum(eid));
                sel_idx += 1;
            }
            c.ImGui_Separator();

            // Iterate over all game objects
            for (scene.iterateObjects()) |*game_obj| {
                const entity = game_obj.entity_id;

                // Check if this entity is selected (multi-select support)
                var is_selected: bool = false;
                for (self.selected_entities.items) |eid| {
                    if (eid == entity) {
                        is_selected = true;
                        break;
                    }
                }

                // Build entity label with component info
                var label_buf: [128]u8 = undefined;
                const label = self.buildEntityLabel(scene.ecs_world, entity, &label_buf) catch "Entity";

                // Make it selectable
                const flags = c.ImGuiTreeNodeFlags_Leaf | c.ImGuiTreeNodeFlags_NoTreePushOnOpen;
                const selected_flag = if (is_selected) c.ImGuiTreeNodeFlags_Selected else 0;

                _ = c.ImGui_TreeNodeEx(@ptrCast(label.ptr), flags | selected_flag);

                // Accept drag-and-drop onto the entity entry (ASSET_PATH payloads)
                if (c.ImGui_BeginDragDropTarget()) {
                    const payload = c.ImGui_AcceptDragDropPayload("ASSET_PATH", 0);
                    if (payload != null) {
                        if (payload.*.Data) |data_any| {
                            const data_ptr: [*]const u8 = @ptrCast(data_any);
                            const data_size: usize = @intCast(payload.*.DataSize);

                            // Copy the dropped path into a temporary buffer
                            const path_opt = std.heap.page_allocator.alloc(u8, data_size + 1) catch null;
                            if (path_opt) |path_buf| {
                                std.mem.copyForwards(u8, path_buf[0..data_size], data_ptr[0..data_size]);
                                path_buf[data_size] = 0;
                                const path_slice = path_buf[0..data_size];

                                // Determine file type by extension and call Scene helpers accordingly
                                // Mesh extensions -> update model; Texture extensions -> update texture
                                if (std.mem.endsWith(u8, path_slice, ".obj") or std.mem.endsWith(u8, path_slice, ".gltf") or std.mem.endsWith(u8, path_slice, ".glb")) {
                                    // Update model for the entity (best-effort)
                                    scene.updateModelForEntity(entity, path_slice) catch {};
                                } else if (std.mem.endsWith(u8, path_slice, ".png") or std.mem.endsWith(u8, path_slice, ".jpg") or std.mem.endsWith(u8, path_slice, ".jpeg")) {
                                    scene.updateTextureForEntity(entity, path_slice) catch {};
                                } else if (std.mem.endsWith(u8, path_slice, ".lua") or std.mem.endsWith(u8, path_slice, ".txt") or std.mem.endsWith(u8, path_slice, ".zs")) {
                                    if (std.fs.cwd().openFile(path_slice, .{})) |file| {
                                        defer file.close();
                                        const contents = file.readToEndAlloc(scene.allocator, 64 * 1024) catch null;
                                        if (contents) |cdata| {
                                            // Register script as an asset (best-effort) so it participates in hot-reload
                                            const AssetType = zephyr.AssetType;
                                            const LoadPriority = zephyr.LoadPriority;
                                            var script_asset_id: ?zephyr.AssetId = null;
                                            script_asset_id = scene.asset_manager.loadAssetAsync(path_slice, AssetType.script, LoadPriority.high) catch null;

                                            // Replace ScriptComponent on the entity and associate asset if available
                                            _ = scene.ecs_world.remove(ScriptComponent, entity);
                                            const slice: []const u8 = cdata;
                                            if (script_asset_id) |aid| {
                                                _ = scene.ecs_world.emplace(ScriptComponent, entity, ScriptComponent.initWithAsset(slice, aid, self.script_auto_run, false)) catch {};
                                            } else {
                                                _ = scene.ecs_world.emplace(ScriptComponent, entity, ScriptComponent.init(slice, self.script_auto_run, false)) catch {};
                                            }

                                            // If this entity is currently selected, mirror into editor buffer
                                            var was_selected: bool = false;
                                            for (self.selected_entities.items) |eid| {
                                                if (eid == entity) {
                                                    was_selected = true;
                                                    break;
                                                }
                                            }
                                            if (was_selected) {
                                                const copy_len = @min(cdata.len, self.script_buffer.len - 1);
                                                std.mem.copyForwards(u8, self.script_buffer[0..copy_len], cdata[0..copy_len]);
                                                self.script_buffer[copy_len] = 0;
                                                self.script_buffer_owner = entity;
                                            }
                                        }
                                    } else |_| {
                                        // openFile failed; ignore
                                    }
                                } else {
                                    // Unknown extension - try to treat as mesh+texture (best-effort)
                                    scene.updatePropAssets(entity, path_slice, path_slice) catch {};
                                }

                                std.heap.page_allocator.free(path_buf);
                            }
                        }
                    }
                }

                // Handle selection with modifiers: Ctrl=toggle, Shift=add, none=single
                if (c.ImGui_IsItemClicked()) {
                    const io = c.ImGui_GetIO();
                    if (io.*.KeyCtrl) {
                        // toggle membership: use std.mem.indexOf for concise lookup
                        // Ensure we pass an explicit slice to match std.mem.indexOf signature
                        const needle = [_]EntityId{entity};
                        const maybe_idx = std.mem.indexOf(EntityId, self.selected_entities.items[0..self.selected_entities.items.len], needle[0..1]);
                        if (maybe_idx) |i| {
                            _ = self.selected_entities.swapRemove(i);
                        } else {
                            _ = self.selected_entities.append(std.heap.page_allocator, entity) catch {};
                        }
                    } else if (io.*.KeyShift) {
                        // add to selection
                        _ = self.selected_entities.append(std.heap.page_allocator, entity) catch {};
                    } else {
                        // single select
                        if (self.selected_entities.items.len > 0) self.selected_entities.clearRetainingCapacity();
                        _ = self.selected_entities.append(std.heap.page_allocator, entity) catch {};
                    }
                    // Request that the Inspector steals focus on next render so keyboard
                    // input targets inspector widgets (we call SetWindowFocus from inside
                    // the Inspector to avoid API differences on the c-binding).
                    self.request_inspector_focus = true;
                }

                // Context menu for entity operations
                if (c.ImGui_BeginPopupContextItem()) {
                    if (c.ImGui_MenuItem("Delete Entity")) {
                        scene.destroyObject(game_obj);
                        // remove from selection if present
                        // Find and remove the entity from the selection (if present)
                        const needle = [_]EntityId{entity};
                        const maybe_idx = std.mem.indexOf(EntityId, self.selected_entities.items[0..self.selected_entities.items.len], needle[0..1]);
                        if (maybe_idx) |i| {
                            _ = self.selected_entities.swapRemove(i);
                        }
                    }
                    c.ImGui_EndPopup();
                }
            }
        }
        c.ImGui_End();
    }

    /// Render the inspector for the selected entity
    fn renderInspector(self: *SceneHierarchyPanel, scene: *Scene) void {
        const window_flags = c.ImGuiWindowFlags_NoCollapse;

        if (c.ImGui_Begin("Inspector", null, window_flags)) {
            // If a previous interaction requested inspector focus, perform it here
            if (self.request_inspector_focus) {
                c.ImGui_SetWindowFocus();
                self.request_inspector_focus = false;
            }
            if (self.selected_entities.items.len > 0) {
                const entity = self.selected_entities.items[0];
                c.ImGui_Text("Entity Index: %d (raw=%u)", entity.index(), @intFromEnum(entity));
                c.ImGui_Separator();

                // Transform component
                if (scene.ecs_world.get(Transform, entity)) |transform| {
                    if (c.ImGui_CollapsingHeader("Transform", c.ImGuiTreeNodeFlags_DefaultOpen)) {
                        self.renderTransformInspector(scene.ecs_world, entity, transform);
                    }
                }

                // MeshRenderer component
                if (scene.ecs_world.get(MeshRenderer, entity)) |mesh_renderer| {
                    if (c.ImGui_CollapsingHeader("Mesh Renderer", c.ImGuiTreeNodeFlags_DefaultOpen)) {
                        self.renderMeshRendererInspector(mesh_renderer);

                        // Accept drag-and-drop onto the Mesh Renderer inspector area
                        if (c.ImGui_BeginDragDropTarget()) {
                            const payload = c.ImGui_AcceptDragDropPayload("ASSET_PATH", 0);
                            if (payload != null) {
                                if (payload.*.Data) |data_any| {
                                    const data_ptr: [*]const u8 = @ptrCast(data_any);
                                    const data_size: usize = @intCast(payload.*.DataSize);

                                    const path_opt = std.heap.page_allocator.alloc(u8, data_size + 1) catch null;
                                    if (path_opt) |path_buf| {
                                        std.mem.copyForwards(u8, path_buf[0..data_size], data_ptr[0..data_size]);
                                        path_buf[data_size] = 0;
                                        const path_slice = path_buf[0..data_size];

                                        // Route based on extension
                                        if (std.mem.endsWith(u8, path_slice, ".obj") or std.mem.endsWith(u8, path_slice, ".gltf") or std.mem.endsWith(u8, path_slice, ".glb")) {
                                            scene.updateModelForEntity(entity, path_slice) catch {};
                                        } else if (std.mem.endsWith(u8, path_slice, ".png") or std.mem.endsWith(u8, path_slice, ".jpg") or std.mem.endsWith(u8, path_slice, ".jpeg")) {
                                            scene.updateTextureForEntity(entity, path_slice) catch {};
                                        } else {
                                            // If unknown, try both model+texture update using same path
                                            scene.updatePropAssets(entity, path_slice, path_slice) catch {};
                                        }

                                        std.heap.page_allocator.free(path_buf);
                                    }
                                }
                            }
                        }
                    }
                }

                // Camera component
                if (scene.ecs_world.get(Camera, entity)) |camera| {
                    if (c.ImGui_CollapsingHeader("Camera", c.ImGuiTreeNodeFlags_DefaultOpen)) {
                        self.renderCameraInspector(camera);
                    }
                }

                // PointLight component
                if (scene.ecs_world.get(PointLight, entity)) |light| {
                    if (c.ImGui_CollapsingHeader("Point Light", c.ImGuiTreeNodeFlags_DefaultOpen)) {
                        self.renderPointLightInspector(scene.ecs_world, entity, light);
                    }
                }

                // ParticleEmitter component
                if (scene.ecs_world.get(ParticleEmitter, entity)) |emitter| {
                    if (c.ImGui_CollapsingHeader("Particle Emitter", c.ImGuiTreeNodeFlags_DefaultOpen)) {
                        self.renderParticleEmitterInspector(scene.ecs_world, entity, emitter);
                    }
                }

                // Script component inspector/editor
                if (scene.ecs_world.get(ScriptComponent, entity)) |sc| {
                    if (c.ImGui_CollapsingHeader("Script", c.ImGuiTreeNodeFlags_DefaultOpen)) {
                        // If we started editing a different entity, load its script into the
                        // fixed-size buffer so the user can edit it.
                        if (self.script_buffer_owner == null or self.script_buffer_owner.? != entity) {
                            // Copy up to capacity-1 bytes and NUL terminate
                            const copy_len = @min(sc.script.len, self.script_buffer.len - 1);
                            std.mem.copyForwards(u8, self.script_buffer[0..copy_len], sc.script[0..copy_len]);
                            self.script_buffer[copy_len] = 0;
                            self.script_buffer_owner = entity;
                        }

                        // Multiline text editor. Pass the buffer capacity so ImGui can edit in-place.
                        _ = c.ImGui_InputTextMultiline("##script_editor", &self.script_buffer[0], self.script_buffer.len);

                        // Accept drag-and-drop payloads from the Asset Browser (type: "ASSET_PATH")
                        if (c.ImGui_BeginDragDropTarget()) {
                            const payload = c.ImGui_AcceptDragDropPayload("ASSET_PATH", 0);
                            if (payload != null) {
                                // payload->Data is nullable anyopaque; handle safely
                                if (payload.*.Data) |data_any| {
                                    const data_ptr: [*]const u8 = @ptrCast(data_any);
                                    const data_size: usize = @intCast(payload.*.DataSize);

                                    // Copy path string into a temporary page-allocator buffer
                                    const path_opt = std.heap.page_allocator.alloc(u8, data_size + 1) catch null;
                                    if (path_opt) |path_buf| {
                                        std.mem.copyForwards(u8, path_buf[0..data_size], data_ptr[0..data_size]);
                                        path_buf[data_size] = 0;
                                        const path_slice = path_buf[0..data_size];

                                        // Try to open and read the file from the workspace
                                        if (std.fs.cwd().openFile(path_slice, .{})) |file| {
                                            defer file.close();
                                            const contents = file.readToEndAlloc(scene.allocator, 64 * 1024) catch null;
                                            if (contents) |cdata| {
                                                // Register script as an asset (best-effort) so it participates in hot-reload
                                                const AssetType = zephyr.AssetType;
                                                const LoadPriority = zephyr.LoadPriority;
                                                var script_asset_id: ?zephyr.AssetId = null;
                                                script_asset_id = scene.asset_manager.loadAssetAsync(path_slice, AssetType.script, LoadPriority.high) catch null;

                                                // Replace ScriptComponent with the file contents and honor auto-run
                                                _ = scene.ecs_world.remove(ScriptComponent, entity);
                                                const slice: []const u8 = cdata;
                                                if (script_asset_id) |aid| {
                                                    _ = scene.ecs_world.emplace(ScriptComponent, entity, ScriptComponent.initWithAsset(slice, aid, self.script_auto_run, false)) catch {};
                                                } else {
                                                    _ = scene.ecs_world.emplace(ScriptComponent, entity, ScriptComponent.init(slice, self.script_auto_run, false)) catch {};
                                                }

                                                // Mirror editor buffer so the inspector shows loaded text
                                                const copy_len = @min(cdata.len, self.script_buffer.len - 1);
                                                std.mem.copyForwards(u8, self.script_buffer[0..copy_len], cdata[0..copy_len]);
                                                self.script_buffer[copy_len] = 0;
                                                self.script_buffer_owner = entity;
                                            } else {
                                                c.ImGui_Text("Failed to read dropped file");
                                            }
                                        } else |_| {
                                            c.ImGui_Text("Dropped item is not a file: %s", path_slice.ptr);
                                        }

                                        std.heap.page_allocator.free(path_buf);
                                    } else {
                                        c.ImGui_Text("Out of memory copying payload");
                                    }
                                } else {
                                    c.ImGui_Text("Empty payload data");
                                }
                            }
                        }

                        // Auto-run checkbox controls whether Apply enables per-frame execution
                        _ = c.ImGui_Checkbox("Auto-run every frame", &self.script_auto_run);

                        c.ImGui_Spacing();
                        if (c.ImGui_Button("Apply")) {
                            // Determine current script length (up to NUL)
                            var new_len: usize = 0;
                            while (new_len < self.script_buffer.len) : (new_len += 1) {
                                if (self.script_buffer[new_len] == 0) break;
                            }

                            if (new_len > 0) {
                                // Allocate a persistent buffer from the Scene allocator to store the
                                // script; ScriptComponent stores a []const u8 so the allocator must
                                // keep the memory alive while the component exists. Allocation may
                                // fail; handle gracefully.
                                const dst_opt = scene.allocator.alloc(u8, new_len + 1) catch null;
                                if (dst_opt != null) {
                                    var dst = dst_opt.?;
                                    std.mem.copyForwards(u8, dst[0..new_len], self.script_buffer[0..new_len]);
                                    dst[new_len] = 0;
                                    // Replace component by removing and emplacing new one that
                                    // points to the newly allocated script slice.
                                    _ = scene.ecs_world.remove(ScriptComponent, entity);
                                    const slice: []const u8 = dst[0 .. new_len + 1];
                                    // Apply the script. If Auto-run is checked enable per-frame execution
                                    if (self.script_auto_run) {
                                        _ = scene.ecs_world.emplace(ScriptComponent, entity, ScriptComponent.init(slice, true, false)) catch {};
                                    } else {
                                        _ = scene.ecs_world.emplace(ScriptComponent, entity, ScriptComponent.initDefault(slice)) catch {};
                                    }
                                    // Keep our editor owner as the same entity
                                    self.script_buffer_owner = entity;
                                } else {
                                    // Allocation failed; show ephemeral message in inspector
                                    c.ImGui_Text("Failed to allocate script buffer (out of memory)");
                                }
                            }
                        }

                        c.ImGui_SameLine();
                        if (c.ImGui_Button("Run Next Update")) {
                            // Determine current buffer length
                            var run_len: usize = 0;
                            while (run_len < self.script_buffer.len) : (run_len += 1) {
                                if (self.script_buffer[run_len] == 0) break;
                            }
                            if (run_len > 0) {
                                // Make a scene-owned copy of the current editor buffer so the
                                // ScriptComponent can safely reference it.
                                const dst_opt = scene.allocator.alloc(u8, run_len + 1) catch null;
                                if (dst_opt) |dst| {
                                    std.mem.copyForwards(u8, dst[0..run_len], self.script_buffer[0..run_len]);
                                    dst[run_len] = 0;

                                    // Replace the component (remove+emplace) to mirror Apply semantics
                                    // but request a one-shot execution on the next update tick.
                                    _ = scene.ecs_world.remove(ScriptComponent, entity);
                                    const slice: []const u8 = dst[0 .. run_len + 1];
                                    // Replace component and schedule persistent per-frame execution
                                    _ = scene.ecs_world.emplace(ScriptComponent, entity, ScriptComponent.init(slice, true, false)) catch {};

                                    // Keep our editor owner as the same entity
                                    self.script_buffer_owner = entity;
                                } else {
                                    c.ImGui_Text("Failed to allocate script buffer (out of memory)");
                                }
                            }
                        }

                        c.ImGui_Spacing();
                        // Start button: enable script and optionally run every frame depending on auto-run
                        if (c.ImGui_Button("Start")) {
                            if (scene.ecs_world.get(ScriptComponent, entity)) |mut_sc| {
                                mut_sc.enabled = true;
                                mut_sc.run_on_update = self.script_auto_run;
                                mut_sc.run_once = false;
                            }
                        }
                        c.ImGui_SameLine();
                        if (c.ImGui_Button("Stop")) {
                            if (scene.ecs_world.get(ScriptComponent, entity)) |mut_sc| {
                                mut_sc.enabled = false;
                                mut_sc.run_on_update = false;
                                mut_sc.run_once = false;
                            }
                        }

                        // Show script run state in inspector for clarity
                        if (scene.ecs_world.get(ScriptComponent, entity)) |sc_state| {
                            const status_text: [*:0]const u8 = if (sc_state.enabled and sc_state.run_on_update) "Running (per-frame)" else if (sc_state.run_once) "Scheduled (one-shot)" else if (sc_state.enabled) "Enabled" else "Disabled";
                            c.ImGui_Text("Script status: %s", status_text);
                        }
                    }
                }
            }
        }
        c.ImGui_End();
    }

    /// Build a label for an entity showing its components
    fn buildEntityLabel(self: *SceneHierarchyPanel, world: *World, entity: EntityId, buf: []u8) ![:0]const u8 {
        _ = self;

        const entity_index = entity.index();
        const entity_u32: u32 = @intFromEnum(entity);
        var components = std.ArrayList(u8){};
        defer components.deinit(std.heap.page_allocator);

        // Check what components this entity has
        var has_any = false;

        if (world.has(Transform, entity)) {
            try components.appendSlice(std.heap.page_allocator, "T");
            has_any = true;
        }
        if (world.has(MeshRenderer, entity)) {
            if (has_any) try components.appendSlice(std.heap.page_allocator, ",");
            try components.appendSlice(std.heap.page_allocator, "M");
            has_any = true;
        }
        if (world.has(Camera, entity)) {
            if (has_any) try components.appendSlice(std.heap.page_allocator, ",");
            try components.appendSlice(std.heap.page_allocator, "C");
            has_any = true;
        }
        if (world.has(PointLight, entity)) {
            if (has_any) try components.appendSlice(std.heap.page_allocator, ",");
            try components.appendSlice(std.heap.page_allocator, "L");
            has_any = true;
        }
        if (world.has(ParticleEmitter, entity)) {
            if (has_any) try components.appendSlice(std.heap.page_allocator, ",");
            try components.appendSlice(std.heap.page_allocator, "P");
            has_any = true;
        }
        if (world.has(ScriptComponent, entity)) {
            if (has_any) try components.appendSlice(std.heap.page_allocator, ",");
            // Try to inspect state for a richer indicator
            if (world.get(ScriptComponent, entity)) |sc| {
                if (sc.enabled and sc.run_on_update) {
                    try components.appendSlice(std.heap.page_allocator, "S*");
                } else if (sc.run_once) {
                    try components.appendSlice(std.heap.page_allocator, "S1");
                } else if (sc.enabled) {
                    try components.appendSlice(std.heap.page_allocator, "S");
                } else {
                    try components.appendSlice(std.heap.page_allocator, "s");
                }
            } else {
                try components.appendSlice(std.heap.page_allocator, "S");
            }
            has_any = true;
        }

        const label = if (has_any)
            try std.fmt.bufPrintZ(buf, "Entity {d} (idx {d}) [{s}]", .{ entity_u32, entity_index, components.items })
        else
            try std.fmt.bufPrintZ(buf, "Entity {d} (idx {d})", .{ entity_u32, entity_index });

        return label;
    }

    /// Render Transform component inspector with editable fields
    fn renderTransformInspector(self: *SceneHierarchyPanel, world: *World, entity: EntityId, transform: *Transform) void {
        _ = self;
        _ = world;
        _ = entity;

        // Position
        var pos = [3]f32{ transform.position.x, transform.position.y, transform.position.z };
        if (c.ImGui_DragFloat3("Position", &pos)) {
            transform.setPosition(Math.Vec3.init(pos[0], pos[1], pos[2]));
        }

        // Rotation (displayed as Euler angles converted from quaternion)
        const euler = transform.rotation.toEuler();
        var rot = [3]f32{ euler.x, euler.y, euler.z };
        if (c.ImGui_DragFloat3("Rotation", &rot)) {
            transform.setRotation(Math.Vec3.init(rot[0], rot[1], rot[2]));
        }

        // Scale
        var scale = [3]f32{ transform.scale.x, transform.scale.y, transform.scale.z };
        if (c.ImGui_DragFloat3("Scale", &scale)) {
            transform.setScale(Math.Vec3.init(scale[0], scale[1], scale[2]));
        }

        // Show dirty flag
        const dirty_status: [*:0]const u8 = if (transform.dirty) "Dirty" else "Clean";
        c.ImGui_Text("Status: %s", dirty_status);
    }

    /// Render MeshRenderer component inspector
    fn renderMeshRendererInspector(self: *SceneHierarchyPanel, mesh_renderer: *const MeshRenderer) void {
        _ = self;

        if (mesh_renderer.model_asset) |model_id| {
            const model_u64: u64 = @intFromEnum(model_id);
            c.ImGui_Text("Model ID: %llu", model_u64);
        } else {
            c.ImGui_Text("Model: None");
        }

        if (mesh_renderer.texture_asset) |tex_id| {
            const texture_u64: u64 = @intFromEnum(tex_id);
            c.ImGui_Text("Texture ID: %llu", texture_u64);
        } else {
            c.ImGui_Text("Texture: None");
        }

        const enabled_str: [*:0]const u8 = if (mesh_renderer.enabled) "Yes" else "No";
        c.ImGui_Text("Enabled: %s", enabled_str);
    }

    /// Render Camera component inspector
    fn renderCameraInspector(self: *SceneHierarchyPanel, camera: *const Camera) void {
        _ = self;

        const proj_type: [*:0]const u8 = switch (camera.projection_type) {
            .perspective => "Perspective",
            .orthographic => "Orthographic",
        };
        c.ImGui_Text("Type: %s", proj_type);

        const is_primary: [*:0]const u8 = if (camera.is_primary) "Yes" else "No";
        c.ImGui_Text("Primary: %s", is_primary);

        if (camera.projection_type == .perspective) {
            c.ImGui_Text("FOV: %.2f", camera.fov);
        }
        c.ImGui_Text("Aspect: %.2f", camera.aspect_ratio);
        c.ImGui_Text("Near: %.2f", camera.near_plane);
        c.ImGui_Text("Far: %.2f", camera.far_plane);
    }

    /// Render PointLight component inspector with editable fields
    fn renderPointLightInspector(self: *SceneHierarchyPanel, world: *World, entity: EntityId, light: *PointLight) void {
        _ = self;
        _ = world;
        _ = entity;

        // Color picker
        var color = [3]f32{ light.color.x, light.color.y, light.color.z };
        if (c.ImGui_ColorEdit3("Color", &color, 0)) {
            light.color = Math.Vec3.init(color[0], color[1], color[2]);
        }

        // Intensity slider
        var intensity = light.intensity;
        if (c.ImGui_SliderFloat("Intensity", &intensity, 0.0, 10.0)) {
            light.intensity = intensity;
        }
    }

    /// Render ParticleEmitter component inspector with editable fields
    fn renderParticleEmitterInspector(self: *SceneHierarchyPanel, world: *World, entity: EntityId, emitter: *ParticleEmitter) void {
        _ = self;
        _ = world;
        _ = entity;

        // Active toggle
        var active: bool = emitter.active;
        if (c.ImGui_Checkbox("Active", &active)) {
            emitter.active = active;
        }

        // Emission rate
        var emission_rate = emitter.emission_rate;
        if (c.ImGui_SliderFloat("Emission Rate", &emission_rate, 1.0, 100.0)) {
            emitter.emission_rate = emission_rate;
        }

        // Particle lifetime
        var lifetime = emitter.particle_lifetime;
        if (c.ImGui_SliderFloat("Lifetime", &lifetime, 0.1, 10.0)) {
            emitter.particle_lifetime = lifetime;
        }

        // Color picker
        var color = [3]f32{ emitter.color.x, emitter.color.y, emitter.color.z };
        if (c.ImGui_ColorEdit3("Color", &color, 0)) {
            emitter.color = Math.Vec3.init(color[0], color[1], color[2]);
        }

        // Velocity range
        c.ImGui_Text("Velocity Min: (%.2f, %.2f, %.2f)", emitter.velocity_min.x, emitter.velocity_min.y, emitter.velocity_min.z);
        c.ImGui_Text("Velocity Max: (%.2f, %.2f, %.2f)", emitter.velocity_max.x, emitter.velocity_max.y, emitter.velocity_max.z);
    }
};
