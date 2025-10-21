// ECS Module - Entity Component System
// Phase 1: Core Foundation (Complete)
// Phase 2: Parallel Dispatch (Complete)
// Phase 3: Particle System Migration (In Progress)

pub const EntityId = @import("ecs/entity_registry.zig").EntityId;
pub const EntityRegistry = @import("ecs/entity_registry.zig").EntityRegistry;
pub const DenseSet = @import("ecs/dense_set.zig").DenseSet;
pub const View = @import("ecs/view.zig").View;
pub const World = @import("ecs/world.zig").World;

// Components
pub const ParticleComponent = @import("ecs/components/particle.zig").ParticleComponent;

test {
    @import("std").testing.refAllDecls(@This());
}
