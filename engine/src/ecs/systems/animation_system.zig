const std = @import("std");
const World = @import("../world.zig").World;
const Transform = @import("../components/transform.zig").Transform;
const animation = @import("../components/animation.zig");
const AnimationComponent = animation.AnimationComponent;
const SkeletonComponent = animation.SkeletonComponent;
const AnimationChannel = animation.AnimationChannel;
const EntityId = @import("../entity_registry.zig").EntityId;
const Scene = @import("../../scene/scene.zig").Scene;
const log = @import("../../utils/log.zig").log;
const math = @import("../../utils/math.zig");

/// Animation system - Updates skeletal animations each frame
/// Processes AnimationComponent and SkeletonComponent to update bone transforms
pub const AnimationSystem = struct {
    allocator: std.mem.Allocator,

    // Statistics
    animated_entity_count: u32 = 0,
    last_update_time_us: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) AnimationSystem {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *AnimationSystem) void {
        _ = self;
        // No resources to free currently
    }

    /// Update all animations in the world
    pub fn update(self: *AnimationSystem, world: *World, delta_time: f32) void {
        const start_time = std.time.microTimestamp();
        var entity_count: u32 = 0;

        // Query entities with both AnimationComponent and SkeletonComponent
        const anim_view = world.view2(AnimationComponent, SkeletonComponent) catch return;

        for (anim_view.items[0], anim_view.items[1], anim_view.entities) |anim_comp, skeleton_comp, entity| {
            _ = entity;
            self.updateAnimation(anim_comp, skeleton_comp, delta_time);
            entity_count += 1;
        }

        // Also update animations without skeletons (for property animations)
        const standalone_view = world.view(AnimationComponent) catch return;
        for (standalone_view.items, standalone_view.entities) |anim_comp, entity| {
            // Skip if entity also has skeleton (already processed)
            if (world.has(SkeletonComponent, entity)) continue;

            self.updateStandaloneAnimation(world, anim_comp, entity, delta_time);
            entity_count += 1;
        }

        const end_time = std.time.microTimestamp();
        self.animated_entity_count = entity_count;
        self.last_update_time_us = if (end_time >= start_time) @intCast(end_time - start_time) else 0;
    }

    /// Update a skeletal animation
    fn updateAnimation(self: *AnimationSystem, anim: *AnimationComponent, skeleton: *SkeletonComponent, dt: f32) void {
        _ = self;

        // Update playback state
        if (anim.state.playing) {
            anim.state.current_time += dt * anim.state.speed;

            // Get current clip
            if (anim.current_clip >= 0 and anim.current_clip < @as(i8, @intCast(anim.clip_count))) {
                if (anim.clips[@intCast(anim.current_clip)]) |clip| {
                    // Handle looping
                    if (anim.state.current_time > clip.duration) {
                        if (anim.state.looping) {
                            anim.state.current_time = @mod(anim.state.current_time, clip.duration);
                        } else {
                            anim.state.current_time = clip.duration;
                            anim.state.playing = false;
                        }
                    }

                    // Sample animation and apply to skeleton
                    applyAnimationToSkeleton(&clip, skeleton, anim.state.current_time);
                }
            }
        }

        // Handle crossfade blending
        if (anim.blend_clip >= 0) {
            anim.blend_progress += dt / anim.blend_duration;
            if (anim.blend_progress >= 1.0) {
                // Blend complete
                anim.blend_clip = -1;
                anim.blend_progress = 0;
            } else if (anim.blend_state.playing) {
                // Update blend source time
                anim.blend_state.current_time += dt * anim.blend_state.speed;

                if (anim.clips[@intCast(anim.blend_clip)]) |blend_clip| {
                    if (anim.blend_state.current_time > blend_clip.duration) {
                        if (anim.blend_state.looping) {
                            anim.blend_state.current_time = @mod(anim.blend_state.current_time, blend_clip.duration);
                        } else {
                            anim.blend_state.playing = false;
                        }
                    }
                }
            }
        }

        // Update bone matrices
        skeleton.updateBoneMatrices();
    }

    /// Update an animation component without a skeleton (property animation)
    fn updateStandaloneAnimation(self: *AnimationSystem, world: *World, anim: *AnimationComponent, entity: EntityId, dt: f32) void {
        _ = self;

        if (!anim.state.playing) return;

        anim.state.current_time += dt * anim.state.speed;

        // Get current clip
        if (anim.current_clip >= 0 and anim.current_clip < @as(i8, @intCast(anim.clip_count))) {
            if (anim.clips[@intCast(anim.current_clip)]) |clip| {
                // Handle looping
                if (anim.state.current_time > clip.duration) {
                    if (anim.state.looping) {
                        anim.state.current_time = @mod(anim.state.current_time, clip.duration);
                    } else {
                        anim.state.current_time = clip.duration;
                        anim.state.playing = false;
                    }
                }

                // Apply animation to entity transform
                if (world.get(Transform, entity)) |transform| {
                    applyAnimationToTransform(&clip, transform, anim.state.current_time);
                }
            }
        }
    }
};

/// Apply animation clip channels to skeleton bones
fn applyAnimationToSkeleton(clip: *const animation.AnimationClip, skeleton: *SkeletonComponent, time: f32) void {
    for (clip.channels) |channel| {
        if (channel.bone_index >= skeleton.bone_count) continue;

        const bone = &skeleton.bones[channel.bone_index];
        const sampled = animation.sampleChannel(&channel, time);

        switch (channel.property) {
            .translation => {
                bone.local_position = math.Vec3.init(sampled[0], sampled[1], sampled[2]);
            },
            .rotation => {
                bone.local_rotation = math.Quat.init(sampled[0], sampled[1], sampled[2], sampled[3]);
            },
            .scale => {
                bone.local_scale = math.Vec3.init(sampled[0], sampled[1], sampled[2]);
            },
        }
    }

    skeleton.dirty = true;
}

/// Apply animation clip to a transform (for non-skeletal animations)
fn applyAnimationToTransform(clip: *const animation.AnimationClip, transform: *Transform, time: f32) void {
    for (clip.channels) |channel| {
        // For transform animation, bone_index 0 means the entity's transform
        if (channel.bone_index != 0) continue;

        const sampled = animation.sampleChannel(&channel, time);

        switch (channel.property) {
            .translation => {
                transform.position = math.Vec3.init(sampled[0], sampled[1], sampled[2]);
                transform.dirty = true;
            },
            .rotation => {
                transform.rotation = math.Quat.init(sampled[0], sampled[1], sampled[2], sampled[3]);
                transform.dirty = true;
            },
            .scale => {
                transform.scale = math.Vec3.init(sampled[0], sampled[1], sampled[2]);
                transform.dirty = true;
            },
        }
    }
}

/// Prepare function for parallel system execution (called before update)
pub fn prepare(world: *World, dt: f32) !void {
    const scene_ptr = world.getUserData("scene") orelse return;
    const scene: *Scene = @ptrCast(@alignCast(scene_ptr));

    if (scene.animation_system) |sys| {
        sys.update(world, dt);
    }
}

/// Update function for parallel system execution
pub fn update(world: *World, scene: *Scene) !void {
    _ = world;
    _ = scene;
    // Update is handled in prepare() with delta time
}

// ============================================================================
// Tests
// ============================================================================

test "AnimationSystem initialization" {
    const allocator = std.testing.allocator;
    var system = AnimationSystem.init(allocator);
    defer system.deinit();

    try std.testing.expectEqual(@as(u32, 0), system.animated_entity_count);
}
