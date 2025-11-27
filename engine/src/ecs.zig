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
pub const Skybox = @import("ecs/components/skybox.zig").Skybox;
pub const ParticleEmitter = @import("ecs/components/particle_emitter.zig").ParticleEmitter;
pub const Name = @import("ecs/components/name.zig").Name;
pub const UuidComponent = @import("ecs/components/uuid.zig").UuidComponent;

// Physics Components
pub const RigidBody = @import("ecs/components/physics_components.zig").RigidBody;
pub const BoxCollider = @import("ecs/components/physics_components.zig").BoxCollider;
pub const SphereCollider = @import("ecs/components/physics_components.zig").SphereCollider;
pub const CapsuleCollider = @import("ecs/components/physics_components.zig").CapsuleCollider;
pub const MeshCollider = @import("ecs/components/physics_components.zig").MeshCollider;

// Material Components
pub const MaterialSet = @import("ecs/components/material_set.zig").MaterialSet;
pub const RenderablesSet = @import("ecs/components/renderables_set.zig").RenderablesSet;
pub const ExtractedRenderable = @import("ecs/components/renderables_set.zig").ExtractedRenderable;
pub const MaterialDeltasSet = @import("ecs/components/material_deltas_set.zig").MaterialDeltasSet;
pub const MaterialSetDelta = @import("ecs/components/material_deltas_set.zig").MaterialSetDelta;
pub const GPUMaterial = @import("ecs/components/material_deltas_set.zig").GPUMaterial;
pub const MaterialChange = @import("ecs/components/material_deltas_set.zig").MaterialChange;
pub const InstanceDeltasSet = @import("ecs/components/instance_deltas_set.zig").InstanceDeltasSet;
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
pub const ParticleBuffers = @import("ecs/systems/particle_system.zig").ParticleBuffers;
pub const ParticleGPUResources = @import("ecs/systems/particle_system.zig").ParticleGPUResources;
pub const ScriptingSystem = @import("ecs/systems/scripting_system.zig").ScriptingSystem;
pub const PhysicsSystem = @import("ecs/systems/physics_system.zig").PhysicsSystem;
pub const SkyboxSystem = @import("ecs/systems/skybox_system.zig").SkyboxSystem;
pub const SkyboxGPUData = @import("ecs/systems/skybox_system.zig").SkyboxGPUData;

// System functions for parallel execution
pub const updateTransformSystem = @import("ecs/systems/transform_system.zig").update;
pub const prepareLightSystem = @import("ecs/systems/light_system.zig").prepare;
pub const updateParticleEmittersSystem = @import("ecs/systems/particle_system.zig").update;
pub const prepareScriptingSystem = @import("ecs/systems/scripting_system.zig").prepare;
pub const preparePhysicsSystem = @import("ecs/systems/physics_system.zig").prepare;
pub const updatePhysicsSystem = @import("ecs/systems/physics_system.zig").update;
pub const prepareRenderSystem = @import("ecs/systems/render_system.zig").prepare;
pub const updateRenderSystem = @import("ecs/systems/render_system.zig").update;
pub const prepareMaterialSystem = @import("ecs/systems/material_system.zig").prepare;
pub const updateMaterialSystem = @import("ecs/systems/material_system.zig").update;
pub const prepareSkyboxSystem = @import("ecs/systems/skybox_system.zig").prepare;
pub const updateSkyboxSystem = @import("ecs/systems/skybox_system.zig").update;

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
    _ = @import("ecs/query_test.zig");
}

test {
    @import("std").testing.refAllDecls(@This());
}
