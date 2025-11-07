// ECS Module - Entity Component System
// Phase 1: Core Foundation (Complete)
// Phase 2: Parallel Dispatch (Complete)
// Phase 3: Components & Systems (In Progress)

pub const EntityId = @import("ecs/entity_registry.zig").EntityId;
pub const EntityRegistry = @import("ecs/entity_registry.zig").EntityRegistry;
pub const DenseSet = @import("ecs/dense_set.zig").DenseSet;
pub const View = @import("ecs/view.zig").View;
pub const World = @import("ecs/world.zig").World;

// Components
pub const ParticleComponent = @import("ecs/components/particle.zig").ParticleComponent;
pub const ScriptComponent = @import("ecs/components/script.zig").ScriptComponent;
pub const Transform = @import("ecs/components/transform.zig").Transform;
pub const MeshRenderer = @import("ecs/components/mesh_renderer.zig").MeshRenderer;
pub const Camera = @import("ecs/components/camera.zig").Camera;
pub const PointLight = @import("ecs/components/point_light.zig").PointLight;
pub const ParticleEmitter = @import("ecs/components/particle_emitter.zig").ParticleEmitter;
pub const Name = @import("ecs/components/name.zig").Name;

// Material Components
pub const MaterialSet = @import("ecs/components/material_set.zig").MaterialSet;
const material_props = @import("ecs/components/material_properties.zig");
pub const AlbedoMaterial = material_props.AlbedoMaterial;
pub const RoughnessMaterial = material_props.RoughnessMaterial;
pub const MetallicMaterial = material_props.MetallicMaterial;
pub const NormalMaterial = material_props.NormalMaterial;
pub const EmissiveMaterial = material_props.EmissiveMaterial;
pub const OcclusionMaterial = material_props.OcclusionMaterial;

// Systems
pub const TransformSystem = @import("ecs/systems/transform_system.zig").TransformSystem;
pub const RenderSystem = @import("ecs/systems/render_system.zig").RenderSystem;
pub const LightSystem = @import("ecs/systems/light_system.zig").LightSystem;
pub const ParticleSystem = @import("ecs/systems/particle_system.zig").ParticleSystem;
pub const ScriptingSystem = @import("ecs/systems/scripting_system.zig").ScriptingSystem;

// System functions for parallel execution
pub const updateTransformSystem = @import("ecs/systems/transform_system.zig").update;
pub const updateLightSystem = @import("ecs/systems/light_system.zig").update;
pub const updateParticleEmittersSystem = @import("ecs/systems/particle_system.zig").update;
pub const updateScriptingSystem = @import("ecs/systems/scripting_system.zig").update;
pub const updateRenderSystem = @import("ecs/systems/render_system.zig").update;
pub const updateMaterialSystem = @import("ecs/systems/material_system.zig").update;

// Parallel System Execution
pub const SystemScheduler = @import("ecs/system_scheduler.zig").SystemScheduler;
pub const SystemStage = @import("ecs/system_scheduler.zig").SystemStage;
pub const SystemDef = @import("ecs/system_scheduler.zig").SystemDef;
pub const ComponentAccess = @import("ecs/system_scheduler.zig").ComponentAccess;

// Workflow demonstrations
test {
    _ = @import("ecs/workflow_demo.zig");
}

test {
    @import("std").testing.refAllDecls(@This());
}
