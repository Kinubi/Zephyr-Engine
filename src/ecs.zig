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
pub const Transform = @import("ecs/components/transform.zig").Transform;
pub const MeshRenderer = @import("ecs/components/mesh_renderer.zig").MeshRenderer;
pub const Camera = @import("ecs/components/camera.zig").Camera;

// Systems
pub const TransformSystem = @import("ecs/systems/transform_system.zig").TransformSystem;
pub const RenderSystem = @import("ecs/systems/render_system.zig").RenderSystem;

test {
    @import("std").testing.refAllDecls(@This());
}
