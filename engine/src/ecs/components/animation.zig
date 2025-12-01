const std = @import("std");
const math = @import("../../utils/math.zig");
const log = @import("../../utils/log.zig").log;
const EntityId = @import("../entity_registry.zig").EntityId;
const AssetId = @import("../../assets/asset_types.zig").AssetId;

/// Maximum number of bones per skeleton
pub const MAX_BONES: usize = 128;

/// Maximum number of animation clips per component
pub const MAX_ANIMATION_CLIPS: usize = 32;

/// A single bone in a skeleton hierarchy
pub const Bone = struct {
    /// Name of this bone (for debugging/GLTF mapping)
    name: [64]u8 = std.mem.zeroes([64]u8),
    name_len: u8 = 0,

    /// Parent bone index (-1 for root bones)
    parent_index: i16 = -1,

    /// Inverse bind matrix - transforms from mesh space to bone space
    inverse_bind_matrix: math.Mat4 = math.Mat4.identity(),

    /// Local transform (relative to parent)
    local_position: math.Vec3 = math.Vec3.zero(),
    local_rotation: math.Quat = math.Quat.identity(),
    local_scale: math.Vec3 = math.Vec3.init(1, 1, 1),

    /// Computed world-space transform (updated by animation system)
    world_matrix: math.Mat4 = math.Mat4.identity(),

    /// Final bone matrix for skinning: world_matrix * inverse_bind_matrix
    final_matrix: math.Mat4 = math.Mat4.identity(),

    pub fn setName(self: *Bone, name: []const u8) void {
        const copy_len = @min(name.len, 63);
        @memcpy(self.name[0..copy_len], name[0..copy_len]);
        self.name[copy_len] = 0;
        self.name_len = @intCast(copy_len);
    }

    pub fn getName(self: *const Bone) []const u8 {
        return self.name[0..self.name_len];
    }
};

/// Keyframe data for a single property
pub const Keyframe = struct {
    /// Time in seconds
    time: f32,
    /// Value at this keyframe (position, rotation, or scale depending on channel)
    value: [4]f32 = [_]f32{ 0, 0, 0, 0 },
};

/// Animation channel targeting a specific bone property
pub const AnimationChannel = struct {
    /// Target bone index
    bone_index: u16 = 0,

    /// Property being animated
    property: PropertyType = .translation,

    /// Interpolation method
    interpolation: InterpolationType = .linear,

    /// Keyframes for this channel
    keyframes: []Keyframe = &.{},

    pub const PropertyType = enum(u8) {
        translation,
        rotation,
        scale,
    };

    pub const InterpolationType = enum(u8) {
        step,
        linear,
        cubic_spline,
    };
};

/// A single animation clip (e.g., "walk", "run", "idle")
pub const AnimationClip = struct {
    /// Name of this animation clip
    name: [64]u8 = std.mem.zeroes([64]u8),
    name_len: u8 = 0,

    /// Duration in seconds
    duration: f32 = 0,

    /// Animation channels
    channels: []AnimationChannel = &.{},

    /// Asset ID if loaded from file
    asset_id: ?AssetId = null,

    pub fn setName(self: *AnimationClip, name: []const u8) void {
        const copy_len = @min(name.len, 63);
        @memcpy(self.name[0..copy_len], name[0..copy_len]);
        self.name[copy_len] = 0;
        self.name_len = @intCast(copy_len);
    }

    pub fn getName(self: *const AnimationClip) []const u8 {
        return self.name[0..self.name_len];
    }
};

/// Skeleton component containing bone hierarchy
pub const SkeletonComponent = struct {
    pub const json_name = "Skeleton";

    /// All bones in this skeleton
    bones: [MAX_BONES]Bone = [_]Bone{.{}} ** MAX_BONES,
    bone_count: u16 = 0,

    /// Current pose bone matrices for GPU skinning (final_matrix values)
    /// Updated by updateBoneMatrices() and used by render system
    pose_palette: [MAX_BONES]math.Mat4 = [_]math.Mat4{math.Mat4.identity()} ** MAX_BONES,

    /// Root bone indices (skeletons can have multiple roots)
    root_bones: [16]u16 = [_]u16{0} ** 16,
    root_bone_count: u8 = 0,

    /// Whether bone matrices need to be recalculated
    dirty: bool = true,

    /// Add a bone to the skeleton
    pub fn addBone(self: *SkeletonComponent, bone: Bone) !u16 {
        if (self.bone_count >= MAX_BONES) {
            return error.TooManyBones;
        }
        const idx = self.bone_count;
        self.bones[idx] = bone;
        self.bone_count += 1;

        // Track root bones
        if (bone.parent_index < 0 and self.root_bone_count < 16) {
            self.root_bones[self.root_bone_count] = idx;
            self.root_bone_count += 1;
        }

        self.dirty = true;
        return idx;
    }

    /// Find a bone by name
    pub fn findBone(self: *const SkeletonComponent, name: []const u8) ?u16 {
        for (self.bones[0..self.bone_count], 0..) |bone, i| {
            if (std.mem.eql(u8, bone.getName(), name)) {
                return @intCast(i);
            }
        }
        return null;
    }

    /// Update all bone world matrices recursively
    pub fn updateBoneMatrices(self: *SkeletonComponent) void {
        // Process bones in order (parents before children)
        for (0..self.bone_count) |i| {
            const bone = &self.bones[i];

            // Build local transform matrix
            const translation = math.Mat4.translation(bone.local_position);
            const rotation = bone.local_rotation.toMat4();
            const scale = math.Mat4.scale(bone.local_scale);
            const local_matrix = translation.mul(rotation).mul(scale);

            // Combine with parent
            if (bone.parent_index >= 0) {
                const parent_idx: usize = @intCast(bone.parent_index);
                bone.world_matrix = self.bones[parent_idx].world_matrix.mul(local_matrix);
            } else {
                bone.world_matrix = local_matrix;
            }

            // Compute final skinning matrix
            bone.final_matrix = bone.world_matrix.mul(bone.inverse_bind_matrix);

            // Update pose palette for GPU
            self.pose_palette[i] = bone.final_matrix;
        }

        self.dirty = false;
    }

    /// Get bone matrices for GPU upload (array of final matrices)
    pub fn getBoneMatrices(self: *const SkeletonComponent, out_matrices: []math.Mat4) void {
        const count = @min(self.bone_count, out_matrices.len);
        for (0..count) |i| {
            out_matrices[i] = self.bones[i].final_matrix;
        }
    }

    /// Serialize SkeletonComponent
    pub fn jsonSerialize(self: SkeletonComponent, serializer: anytype, writer: anytype) !void {
        _ = serializer;
        try writer.beginObject();

        try writer.objectField("bone_count");
        try writer.write(self.bone_count);

        // Only serialize bone names and hierarchy for now
        // Full bone data would be loaded from GLTF asset
        try writer.objectField("bones");
        try writer.beginArray();
        for (self.bones[0..self.bone_count]) |bone| {
            try writer.beginObject();
            try writer.objectField("name");
            try writer.write(bone.getName());
            try writer.objectField("parent");
            try writer.write(bone.parent_index);
            try writer.endObject();
        }
        try writer.endArray();

        try writer.endObject();
    }

    /// Deserialize SkeletonComponent
    pub fn deserialize(serializer: anytype, value: std.json.Value) !SkeletonComponent {
        _ = serializer;
        var skeleton = SkeletonComponent{};

        if (value.object.get("bones")) |bones_val| {
            if (bones_val == .array) {
                for (bones_val.array.items) |bone_val| {
                    if (bone_val == .object) {
                        var bone = Bone{};

                        if (bone_val.object.get("name")) |name_val| {
                            if (name_val == .string) {
                                bone.setName(name_val.string);
                            }
                        }

                        if (bone_val.object.get("parent")) |parent_val| {
                            if (parent_val == .integer) {
                                bone.parent_index = @intCast(parent_val.integer);
                            }
                        }

                        _ = skeleton.addBone(bone) catch continue;
                    }
                }
            }
        }

        return skeleton;
    }
};

/// Animation playback state
pub const AnimationState = struct {
    /// Current playback time in seconds
    current_time: f32 = 0,

    /// Playback speed multiplier (1.0 = normal, 0.5 = half speed, 2.0 = double speed)
    speed: f32 = 1.0,

    /// Whether the animation is currently playing
    playing: bool = false,

    /// Whether to loop the animation
    looping: bool = true,

    /// Blend weight when blending with other animations (0-1)
    weight: f32 = 1.0,

    /// Reset playback state
    pub fn reset(self: *AnimationState) void {
        self.current_time = 0;
        self.playing = false;
    }
};

/// Animation component for playing animations on an entity
pub const AnimationComponent = struct {
    pub const json_name = "Animation";

    /// Available animation clips
    clips: [MAX_ANIMATION_CLIPS]?AnimationClip = [_]?AnimationClip{null} ** MAX_ANIMATION_CLIPS,
    clip_count: u8 = 0,

    /// Index of currently active clip (-1 for none)
    current_clip: i8 = -1,

    /// Playback state for current animation
    state: AnimationState = .{},

    /// Queue of clips to blend/crossfade
    blend_clip: i8 = -1,
    blend_state: AnimationState = .{},
    blend_duration: f32 = 0.3,
    blend_progress: f32 = 0,

    /// Initialize with no animations
    pub fn init() AnimationComponent {
        return .{};
    }

    /// Add an animation clip
    pub fn addClip(self: *AnimationComponent, clip: AnimationClip) !u8 {
        if (self.clip_count >= MAX_ANIMATION_CLIPS) {
            return error.TooManyClips;
        }
        const idx = self.clip_count;
        self.clips[idx] = clip;
        self.clip_count += 1;
        return idx;
    }

    /// Find a clip by name
    pub fn findClip(self: *const AnimationComponent, name: []const u8) ?u8 {
        for (0..self.clip_count) |i| {
            if (self.clips[i]) |clip| {
                if (std.mem.eql(u8, clip.getName(), name)) {
                    return @intCast(i);
                }
            }
        }
        return null;
    }

    /// Play an animation by index
    pub fn play(self: *AnimationComponent, clip_index: u8) void {
        if (clip_index >= self.clip_count) return;

        self.current_clip = @intCast(clip_index);
        self.state.current_time = 0;
        self.state.playing = true;
    }

    /// Play an animation by name
    pub fn playByName(self: *AnimationComponent, name: []const u8) void {
        if (self.findClip(name)) |idx| {
            self.play(idx);
        }
    }

    /// Crossfade to a new animation
    pub fn crossfadeTo(self: *AnimationComponent, clip_index: u8, duration: f32) void {
        if (clip_index >= self.clip_count) return;
        if (self.current_clip == @as(i8, @intCast(clip_index))) return;

        // Move current to blend slot
        if (self.current_clip >= 0) {
            self.blend_clip = self.current_clip;
            self.blend_state = self.state;
        }

        // Start new clip
        self.current_clip = @intCast(clip_index);
        self.state.current_time = 0;
        self.state.playing = true;

        // Set blend parameters
        self.blend_duration = duration;
        self.blend_progress = 0;
    }

    /// Stop the current animation
    pub fn stop(self: *AnimationComponent) void {
        self.state.playing = false;
    }

    /// Pause the current animation
    pub fn pause(self: *AnimationComponent) void {
        self.state.playing = false;
    }

    /// Resume a paused animation
    pub fn unpause(self: *AnimationComponent) void {
        self.state.playing = true;
    }

    /// Get the current clip (if any)
    pub fn getCurrentClip(self: *const AnimationComponent) ?*const AnimationClip {
        if (self.current_clip < 0) return null;
        return if (self.clips[@intCast(self.current_clip)]) |*clip| clip else null;
    }

    /// Serialize AnimationComponent
    pub fn jsonSerialize(self: AnimationComponent, serializer: anytype, writer: anytype) !void {
        _ = serializer;
        try writer.beginObject();

        try writer.objectField("clip_count");
        try writer.write(self.clip_count);

        try writer.objectField("current_clip");
        try writer.write(self.current_clip);

        try writer.objectField("playing");
        try writer.write(self.state.playing);

        try writer.objectField("looping");
        try writer.write(self.state.looping);

        try writer.objectField("speed");
        try writer.write(self.state.speed);

        try writer.objectField("clips");
        try writer.beginArray();
        for (0..self.clip_count) |i| {
            if (self.clips[i]) |clip| {
                try writer.beginObject();
                try writer.objectField("name");
                try writer.write(clip.getName());
                try writer.objectField("duration");
                try writer.write(clip.duration);
                try writer.endObject();
            }
        }
        try writer.endArray();

        try writer.endObject();
    }

    /// Deserialize AnimationComponent
    pub fn deserialize(serializer: anytype, value: std.json.Value) !AnimationComponent {
        _ = serializer;
        var anim = AnimationComponent.init();

        if (value.object.get("current_clip")) |clip_val| {
            if (clip_val == .integer) {
                anim.current_clip = @intCast(clip_val.integer);
            }
        }

        if (value.object.get("playing")) |playing_val| {
            if (playing_val == .bool) {
                anim.state.playing = playing_val.bool;
            }
        }

        if (value.object.get("looping")) |looping_val| {
            if (looping_val == .bool) {
                anim.state.looping = looping_val.bool;
            }
        }

        if (value.object.get("speed")) |speed_val| {
            switch (speed_val) {
                .float => anim.state.speed = @floatCast(speed_val.float),
                .integer => anim.state.speed = @floatFromInt(speed_val.integer),
                else => {},
            }
        }

        // Note: Full clip data would be loaded from GLTF asset
        // This just restores the playback state

        return anim;
    }
};

// ============================================================================
// Animation Interpolation Helpers
// ============================================================================

/// Linear interpolation between two Vec3 values
pub fn lerpVec3(a: math.Vec3, b: math.Vec3, t: f32) math.Vec3 {
    return math.Vec3.init(
        math.lerp(a.x, b.x, t),
        math.lerp(a.y, b.y, t),
        math.lerp(a.z, b.z, t),
    );
}

/// Spherical linear interpolation between two quaternions
pub fn slerpQuat(a: math.Quat, b: math.Quat, t: f32) math.Quat {
    var qa = a;
    var qb = b;

    // Compute dot product (cosine of angle between quaternions)
    var dot = qa.dot(qb);

    // If the dot product is negative, negate one quaternion to take the shorter path
    if (dot < 0) {
        qb = math.Quat.init(-qb.x, -qb.y, -qb.z, -qb.w);
        dot = -dot;
    }

    // If quaternions are very close, use linear interpolation
    if (dot > 0.9995) {
        const result = math.Quat.init(
            math.lerp(qa.x, qb.x, t),
            math.lerp(qa.y, qb.y, t),
            math.lerp(qa.z, qb.z, t),
            math.lerp(qa.w, qb.w, t),
        );
        return result.normalize();
    }

    // Standard slerp
    const theta_0 = std.math.acos(dot);
    const theta = theta_0 * t;
    const sin_theta = @sin(theta);
    const sin_theta_0 = @sin(theta_0);

    const s0 = @cos(theta) - dot * sin_theta / sin_theta_0;
    const s1 = sin_theta / sin_theta_0;

    return math.Quat.init(
        s0 * qa.x + s1 * qb.x,
        s0 * qa.y + s1 * qb.y,
        s0 * qa.z + s1 * qb.z,
        s0 * qa.w + s1 * qb.w,
    ).normalize();
}

/// Sample an animation channel at a specific time
pub fn sampleChannel(channel: *const AnimationChannel, time: f32) [4]f32 {
    if (channel.keyframes.len == 0) {
        return [_]f32{ 0, 0, 0, 1 };
    }

    // Find surrounding keyframes
    var prev_idx: usize = 0;
    var next_idx: usize = 0;

    for (channel.keyframes, 0..) |kf, i| {
        if (kf.time <= time) {
            prev_idx = i;
        }
        if (kf.time >= time and next_idx == 0) {
            next_idx = i;
            break;
        }
    }

    // Handle edge cases
    if (next_idx == 0) next_idx = channel.keyframes.len - 1;
    if (prev_idx >= channel.keyframes.len) prev_idx = channel.keyframes.len - 1;

    const prev_kf = channel.keyframes[prev_idx];
    const next_kf = channel.keyframes[next_idx];

    // If same keyframe or step interpolation, return value directly
    if (prev_idx == next_idx or channel.interpolation == .step) {
        return prev_kf.value;
    }

    // Calculate interpolation factor
    const dt = next_kf.time - prev_kf.time;
    const t = if (dt > 0) (time - prev_kf.time) / dt else 0;

    // Interpolate based on property type
    switch (channel.property) {
        .rotation => {
            // Use slerp for rotation
            const qa = math.Quat.init(prev_kf.value[0], prev_kf.value[1], prev_kf.value[2], prev_kf.value[3]);
            const qb = math.Quat.init(next_kf.value[0], next_kf.value[1], next_kf.value[2], next_kf.value[3]);
            const result = slerpQuat(qa, qb, t);
            return [_]f32{ result.x, result.y, result.z, result.w };
        },
        .translation, .scale => {
            // Use lerp for position and scale
            return [_]f32{
                math.lerp(prev_kf.value[0], next_kf.value[0], t),
                math.lerp(prev_kf.value[1], next_kf.value[1], t),
                math.lerp(prev_kf.value[2], next_kf.value[2], t),
                1.0,
            };
        },
    }
}

// ============================================================================
// Tests
// ============================================================================

test "Bone name operations" {
    var bone = Bone{};
    bone.setName("test_bone");
    try std.testing.expectEqualStrings("test_bone", bone.getName());
}

test "Skeleton add bones" {
    var skeleton = SkeletonComponent{};

    var root = Bone{};
    root.setName("root");
    const root_idx = try skeleton.addBone(root);
    try std.testing.expectEqual(@as(u16, 0), root_idx);

    var child = Bone{};
    child.setName("child");
    child.parent_index = @intCast(root_idx);
    const child_idx = try skeleton.addBone(child);
    try std.testing.expectEqual(@as(u16, 1), child_idx);

    try std.testing.expectEqual(@as(u16, 2), skeleton.bone_count);
    try std.testing.expectEqual(@as(u8, 1), skeleton.root_bone_count);
}

test "AnimationComponent play" {
    var anim = AnimationComponent.init();

    var clip = AnimationClip{};
    clip.setName("walk");
    clip.duration = 1.0;
    _ = try anim.addClip(clip);

    anim.play(0);
    try std.testing.expect(anim.state.playing);
    try std.testing.expectEqual(@as(i8, 0), anim.current_clip);
}

test "slerp quaternion" {
    const q1 = math.Quat.identity();
    const q2 = math.Quat.fromAxisAngle(math.Vec3.init(0, 1, 0), std.math.pi / 2.0);

    const mid = slerpQuat(q1, q2, 0.5);
    try std.testing.expect(@abs(mid.length() - 1.0) < 0.001);
}
