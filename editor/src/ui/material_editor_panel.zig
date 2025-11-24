const std = @import("std");
const zephyr = @import("zephyr");
const c = @import("backend/imgui_c.zig").c;

const ecs = zephyr.ecs;
const EntityId = ecs.EntityId;
const Scene = zephyr.Scene;
const AssetManager = zephyr.AssetManager;
const AssetId = zephyr.AssetId;

// Material components
const AlbedoMaterial = ecs.AlbedoMaterial;
const MaterialSet = ecs.MaterialSet;
const RoughnessMaterial = ecs.RoughnessMaterial;
const MetallicMaterial = ecs.MetallicMaterial;
const NormalMaterial = ecs.NormalMaterial;
const EmissiveMaterial = ecs.EmissiveMaterial;
const OcclusionMaterial = ecs.OcclusionMaterial;

pub const MaterialEditorPanel = struct {
    show_window: bool = true,
    selected_entity: ?EntityId = null,

    pub fn init() MaterialEditorPanel {
        return .{};
    }

    pub fn render(self: *MaterialEditorPanel, scene: *Scene, selected_entity: ?EntityId) void {
        if (!self.show_window) return;

        self.selected_entity = selected_entity;

        if (c.ImGui_Begin("Material Editor", &self.show_window, 0)) {
            if (self.selected_entity) |entity| {
                self.renderMaterialProperties(scene, entity);
            } else {
                c.ImGui_Text("No entity selected.");
            }
        }
        c.ImGui_End();
    }

    fn renderMaterialProperties(self: *MaterialEditorPanel, scene: *Scene, entity: EntityId) void {
        _ = self;
        c.ImGui_Text("Entity ID: %d", @intFromEnum(entity));
        c.ImGui_Separator();

        // Material Set
        if (scene.ecs_world.get(MaterialSet, entity)) |mat_set| {
            if (c.ImGui_CollapsingHeader("Material Set", c.ImGuiTreeNodeFlags_DefaultOpen)) {
                c.ImGui_Text("Set Name: %s", mat_set.set_name.ptr);
                c.ImGui_Text("Shader Variant: %s", mat_set.shader_variant.ptr);

                var casts_shadows = mat_set.casts_shadows;
                if (c.ImGui_Checkbox("Casts Shadows", &casts_shadows)) {
                    mat_set.casts_shadows = casts_shadows;
                }
            }
        } else {
            if (c.ImGui_Button("Add Material Set")) {
                _ = scene.ecs_world.emplace(MaterialSet, entity, MaterialSet.initOpaque()) catch {};
            }
        }

        // Albedo Material
        if (scene.ecs_world.get(AlbedoMaterial, entity)) |albedo| {
            if (c.ImGui_CollapsingHeader("Albedo", c.ImGuiTreeNodeFlags_DefaultOpen)) {
                var color = albedo.color_tint;
                if (c.ImGui_ColorEdit4("Tint", &color[0], 0)) {
                    albedo.color_tint = color;
                }

                var tex_id = albedo.texture_id;
                if (renderTextureSlot(scene, "Texture:", &tex_id)) {
                    albedo.texture_id = tex_id;
                }
            }
        } else {
            if (c.ImGui_Button("Add Albedo Material")) {
                _ = scene.ecs_world.emplace(AlbedoMaterial, entity, AlbedoMaterial.initColor(.{ 1, 1, 1, 1 })) catch {};
            }
        }

        // Normal Material
        if (scene.ecs_world.get(NormalMaterial, entity)) |normal| {
            if (c.ImGui_CollapsingHeader("Normal", c.ImGuiTreeNodeFlags_DefaultOpen)) {
                var strength = normal.strength;
                if (c.ImGui_DragFloat("Strength", &strength)) {
                    normal.strength = strength;
                }

                var tex_id = normal.texture_id;
                if (renderTextureSlot(scene, "Texture:", &tex_id)) {
                    normal.texture_id = tex_id;
                }
            }
        } else {
            if (c.ImGui_Button("Add Normal Material")) {
                _ = scene.ecs_world.emplace(NormalMaterial, entity, NormalMaterial.initWithStrength(AssetId.invalid, 1.0)) catch {};
            }
        }

        // Roughness Material
        if (scene.ecs_world.get(RoughnessMaterial, entity)) |roughness| {
            if (c.ImGui_CollapsingHeader("Roughness", c.ImGuiTreeNodeFlags_DefaultOpen)) {
                var factor = roughness.factor;
                if (c.ImGui_DragFloat("Factor", &factor)) {
                    roughness.factor = factor;
                }

                var tex_id = roughness.texture_id;
                if (renderTextureSlot(scene, "Texture:", &tex_id)) {
                    roughness.texture_id = tex_id;
                }
            }
        } else {
            if (c.ImGui_Button("Add Roughness Material")) {
                _ = scene.ecs_world.emplace(RoughnessMaterial, entity, RoughnessMaterial.initConstant(0.5)) catch {};
            }
        }

        // Metallic Material
        if (scene.ecs_world.get(MetallicMaterial, entity)) |metallic| {
            if (c.ImGui_CollapsingHeader("Metallic", c.ImGuiTreeNodeFlags_DefaultOpen)) {
                var factor = metallic.factor;
                if (c.ImGui_DragFloat("Factor", &factor)) {
                    metallic.factor = factor;
                }

                var tex_id = metallic.texture_id;
                if (renderTextureSlot(scene, "Texture:", &tex_id)) {
                    metallic.texture_id = tex_id;
                }
            }
        } else {
            if (c.ImGui_Button("Add Metallic Material")) {
                _ = scene.ecs_world.emplace(MetallicMaterial, entity, MetallicMaterial.initConstant(0.0)) catch {};
            }
        }

        // Emissive Material
        if (scene.ecs_world.get(EmissiveMaterial, entity)) |emissive| {
            if (c.ImGui_CollapsingHeader("Emissive", c.ImGuiTreeNodeFlags_DefaultOpen)) {
                var color = emissive.color;
                if (c.ImGui_ColorEdit3("Color", &color[0], 0)) {
                    emissive.color = color;
                }

                var intensity = emissive.intensity;
                if (c.ImGui_DragFloat("Intensity", &intensity)) {
                    emissive.intensity = intensity;
                }

                var tex_id = emissive.texture_id;
                if (renderTextureSlot(scene, "Texture:", &tex_id)) {
                    emissive.texture_id = tex_id;
                }
            }
        } else {
            if (c.ImGui_Button("Add Emissive Material")) {
                _ = scene.ecs_world.emplace(EmissiveMaterial, entity, EmissiveMaterial.initColor(.{ 0, 0, 0 }, 1.0)) catch {};
            }
        }

        // Occlusion Material
        if (scene.ecs_world.get(OcclusionMaterial, entity)) |occlusion| {
            if (c.ImGui_CollapsingHeader("Occlusion", c.ImGuiTreeNodeFlags_DefaultOpen)) {
                var strength = occlusion.strength;
                if (c.ImGui_DragFloat("Strength", &strength)) {
                    occlusion.strength = strength;
                }

                var tex_id = occlusion.texture_id;
                if (renderTextureSlot(scene, "Texture:", &tex_id)) {
                    occlusion.texture_id = tex_id;
                }
            }
        } else {
            if (c.ImGui_Button("Add Occlusion Material")) {
                _ = scene.ecs_world.emplace(OcclusionMaterial, entity, OcclusionMaterial.init(AssetId.invalid)) catch {};
            }
        }
    }

    fn renderTextureSlot(scene: *Scene, label: [:0]const u8, texture_id: *AssetId) bool {
        var changed = false;
        c.ImGui_Text("%s", label.ptr);
        if (texture_id.isValid()) {
            if (scene.asset_manager.getAssetPath(texture_id.*)) |path| {
                c.ImGui_Text("%s", path.ptr);
            } else {
                c.ImGui_Text("ID: %d", @intFromEnum(texture_id.*));
            }
        } else {
            c.ImGui_Text("None");
        }

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

                        const asset_id = scene.asset_manager.loadAssetAsync(path_slice, zephyr.AssetType.texture, zephyr.LoadPriority.high) catch null;

                        if (asset_id) |aid| {
                            texture_id.* = aid;
                            changed = true;
                        }

                        std.heap.page_allocator.free(path_buf);
                    }
                }
            }
            c.ImGui_EndDragDropTarget();
        }
        return changed;
    }
};
