const std = @import("std");
const log = @import("../utils/log.zig").log;
const math = @import("../utils/math.zig");
const animation = @import("../ecs/components/animation.zig");
const AnimationComponent = animation.AnimationComponent;
const AnimationClip = animation.AnimationClip;
const AnimationChannel = animation.AnimationChannel;
const SkeletonComponent = animation.SkeletonComponent;
const Bone = animation.Bone;
const Keyframe = animation.Keyframe;
const Mesh = @import("../rendering/mesh.zig").Mesh;
const Vertex = @import("../rendering/mesh.zig").Vertex;

/// GLTF buffer view target types
const BufferViewTarget = enum(u32) {
    array_buffer = 34962,
    element_array_buffer = 34963,
    _,
};

/// GLTF accessor component types
const ComponentType = enum(u32) {
    signed_byte = 5120,
    unsigned_byte = 5121,
    signed_short = 5122,
    unsigned_short = 5123,
    unsigned_int = 5125,
    float = 5126,
    _,
};

/// GLTF accessor types
const AccessorType = enum {
    scalar,
    vec2,
    vec3,
    vec4,
    mat2,
    mat3,
    mat4,
};

/// GLTF animation channel target path
const AnimationPath = enum {
    translation,
    rotation,
    scale,
    weights,
};

/// GLTF animation interpolation
const Interpolation = enum {
    linear,
    step,
    cubic_spline,
};

/// Result of loading a GLTF file
pub const GltfLoadResult = struct {
    meshes: std.ArrayList(Mesh),
    skeleton: ?SkeletonComponent,
    animations: std.ArrayList(AnimationClip),
    allocator: std.mem.Allocator,

    pub fn deinit(self: *GltfLoadResult) void {
        for (self.meshes.items) |*mesh| {
            mesh.vertices.deinit(self.allocator);
            mesh.indices.deinit(self.allocator);
        }
        self.meshes.deinit(self.allocator);

        for (self.animations.items) |*clip| {
            for (clip.channels) |*channel| {
                self.allocator.free(channel.keyframes);
            }
            self.allocator.free(clip.channels);
        }
        self.animations.deinit(self.allocator);
    }
};

/// GLTF Loader - Parses GLTF/GLB files and extracts meshes, skeletons, and animations
pub const GltfLoader = struct {
    allocator: std.mem.Allocator,

    // Parsed GLTF data
    json_data: ?std.json.Parsed(std.json.Value) = null,
    binary_chunk: ?[]const u8 = null,

    // Buffers loaded from file
    buffers: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator) GltfLoader {
        return .{
            .allocator = allocator,
            .buffers = std.ArrayList([]const u8){},
        };
    }

    pub fn deinit(self: *GltfLoader) void {
        if (self.json_data) |*json| {
            json.deinit();
        }

        for (self.buffers.items) |buffer| {
            self.allocator.free(buffer);
        }
        self.buffers.deinit(self.allocator);
    }

    /// Load a GLTF or GLB file
    pub fn load(self: *GltfLoader, file_path: []const u8) !GltfLoadResult {
        // Read file
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();

        const file_size = try file.getEndPos();
        const data = try self.allocator.alloc(u8, file_size);
        defer self.allocator.free(data);

        _ = try file.readAll(data);

        // Detect format
        if (data.len >= 4 and std.mem.eql(u8, data[0..4], "glTF")) {
            return self.parseGlb(data, file_path);
        } else {
            return self.parseGltf(data, file_path);
        }
    }

    /// Parse GLB (binary GLTF) format
    fn parseGlb(self: *GltfLoader, data: []const u8, file_path: []const u8) !GltfLoadResult {
        _ = file_path;

        if (data.len < 12) return error.InvalidGlb;

        // GLB header: magic (4) + version (4) + length (4)
        const version = std.mem.readInt(u32, data[4..8], .little);
        if (version != 2) {
            log(.ERROR, "gltf_loader", "Unsupported GLB version: {}", .{version});
            return error.UnsupportedVersion;
        }

        // Parse chunks
        var offset: usize = 12;

        // JSON chunk
        if (offset + 8 > data.len) return error.InvalidGlb;
        const json_length = std.mem.readInt(u32, data[offset..][0..4], .little);
        const json_type = std.mem.readInt(u32, data[offset + 4 ..][0..4], .little);
        offset += 8;

        if (json_type != 0x4E4F534A) return error.InvalidGlb; // "JSON"
        if (offset + json_length > data.len) return error.InvalidGlb;

        const json_data = data[offset .. offset + json_length];
        offset += json_length;

        // Binary chunk (optional)
        if (offset + 8 <= data.len) {
            const bin_length = std.mem.readInt(u32, data[offset..][0..4], .little);
            const bin_type = std.mem.readInt(u32, data[offset + 4 ..][0..4], .little);
            offset += 8;

            if (bin_type == 0x004E4942) { // "BIN\0"
                if (offset + bin_length <= data.len) {
                    const bin_copy = try self.allocator.dupe(u8, data[offset .. offset + bin_length]);
                    self.binary_chunk = bin_copy;
                    try self.buffers.append(self.allocator, bin_copy);
                }
            }
        }

        // Parse JSON
        self.json_data = try std.json.parseFromSlice(std.json.Value, self.allocator, json_data, .{});

        return self.extractData();
    }

    /// Parse GLTF (JSON) format
    fn parseGltf(self: *GltfLoader, data: []const u8, file_path: []const u8) !GltfLoadResult {
        // Parse JSON
        self.json_data = try std.json.parseFromSlice(std.json.Value, self.allocator, data, .{});

        const root = self.json_data.?.value;

        // Load external buffers
        if (root.object.get("buffers")) |buffers_val| {
            if (buffers_val == .array) {
                // Get directory of GLTF file
                const dir_end = std.mem.lastIndexOf(u8, file_path, "/") orelse 0;
                const base_dir = if (dir_end > 0) file_path[0..dir_end] else ".";

                for (buffers_val.array.items) |buffer_val| {
                    if (buffer_val == .object) {
                        if (buffer_val.object.get("uri")) |uri_val| {
                            if (uri_val == .string) {
                                const uri = uri_val.string;

                                // Handle data URIs
                                if (std.mem.startsWith(u8, uri, "data:")) {
                                    // TODO: Decode base64 data URI
                                    log(.WARN, "gltf_loader", "Data URIs not yet supported", .{});
                                    continue;
                                }

                                // Load external file
                                var path_buf: [512]u8 = undefined;
                                const full_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ base_dir, uri });

                                const buf_file = std.fs.cwd().openFile(full_path, .{}) catch |err| {
                                    log(.ERROR, "gltf_loader", "Failed to load buffer: {s} - {}", .{ full_path, err });
                                    continue;
                                };
                                defer buf_file.close();

                                const buf_size = try buf_file.getEndPos();
                                const buf_data = try self.allocator.alloc(u8, buf_size);
                                _ = try buf_file.readAll(buf_data);
                                try self.buffers.append(self.allocator, buf_data);
                            }
                        }
                    }
                }
            }
        }

        return self.extractData();
    }

    /// Extract meshes, skeleton, and animations from parsed GLTF
    fn extractData(self: *GltfLoader) !GltfLoadResult {
        var result = GltfLoadResult{
            .meshes = std.ArrayList(Mesh){},
            .skeleton = null,
            .animations = std.ArrayList(AnimationClip){},
            .allocator = self.allocator,
        };

        const root = self.json_data.?.value;

        // Extract skeleton from skins
        if (root.object.get("skins")) |skins_val| {
            if (skins_val == .array and skins_val.array.items.len > 0) {
                result.skeleton = try self.extractSkeleton(&root, skins_val.array.items[0]);
            }
        }

        // Extract meshes
        if (root.object.get("meshes")) |meshes_val| {
            if (meshes_val == .array) {
                for (meshes_val.array.items) |mesh_val| {
                    if (try self.extractMesh(&root, mesh_val)) |mesh| {
                        try result.meshes.append(self.allocator, mesh);
                    }
                }
            }
        }

        // Extract animations
        if (root.object.get("animations")) |anims_val| {
            if (anims_val == .array) {
                for (anims_val.array.items) |anim_val| {
                    if (try self.extractAnimation(&root, anim_val, result.skeleton)) |clip| {
                        try result.animations.append(self.allocator, clip);
                    }
                }
            }
        }

        log(.INFO, "gltf_loader", "Loaded {} meshes, {} animations", .{ result.meshes.items.len, result.animations.items.len });

        return result;
    }

    /// Extract skeleton from a GLTF skin
    fn extractSkeleton(self: *GltfLoader, root: *const std.json.Value, skin: std.json.Value) !SkeletonComponent {
        var skeleton = SkeletonComponent{};

        if (skin != .object) return skeleton;

        // Get joint indices
        const joints = skin.object.get("joints") orelse return skeleton;
        if (joints != .array) return skeleton;

        // Get inverse bind matrices accessor
        const ibm_accessor_idx = if (skin.object.get("inverseBindMatrices")) |ibm| blk: {
            if (ibm == .integer) break :blk @as(usize, @intCast(ibm.integer));
            break :blk null;
        } else null;

        // Get nodes array
        const nodes = root.object.get("nodes") orelse return skeleton;
        if (nodes != .array) return skeleton;

        // Process each joint
        for (joints.array.items, 0..) |joint_idx_val, bone_idx| {
            if (joint_idx_val != .integer) continue;
            const joint_idx: usize = @intCast(joint_idx_val.integer);

            if (joint_idx >= nodes.array.items.len) continue;
            const node = nodes.array.items[joint_idx];
            if (node != .object) continue;

            var bone = Bone{};

            // Get bone name
            if (node.object.get("name")) |name_val| {
                if (name_val == .string) {
                    bone.setName(name_val.string);
                }
            }

            // Get local transform
            if (node.object.get("translation")) |t| {
                if (t == .array and t.array.items.len >= 3) {
                    bone.local_position = math.Vec3.init(
                        getFloatValue(t.array.items[0]),
                        getFloatValue(t.array.items[1]),
                        getFloatValue(t.array.items[2]),
                    );
                }
            }

            if (node.object.get("rotation")) |r| {
                if (r == .array and r.array.items.len >= 4) {
                    bone.local_rotation = math.Quat.init(
                        getFloatValue(r.array.items[0]),
                        getFloatValue(r.array.items[1]),
                        getFloatValue(r.array.items[2]),
                        getFloatValue(r.array.items[3]),
                    );
                }
            }

            if (node.object.get("scale")) |s| {
                if (s == .array and s.array.items.len >= 3) {
                    bone.local_scale = math.Vec3.init(
                        getFloatValue(s.array.items[0]),
                        getFloatValue(s.array.items[1]),
                        getFloatValue(s.array.items[2]),
                    );
                }
            }

            // Find parent bone index
            bone.parent_index = -1;
            if (node.object.get("children")) |children| {
                _ = children;
                // Parent is found by checking which node has this joint as a child
                // This is a simplified approach - full implementation would build a proper hierarchy
            }

            // Get inverse bind matrix
            if (ibm_accessor_idx) |accessor_idx| {
                if (self.readMat4FromAccessor(root, accessor_idx, bone_idx)) |mat| {
                    bone.inverse_bind_matrix = mat;
                }
            }

            _ = skeleton.addBone(bone) catch continue;
        }

        // Build parent hierarchy from node children
        for (joints.array.items, 0..) |joint_idx_val, bone_idx| {
            if (joint_idx_val != .integer) continue;
            const joint_idx: usize = @intCast(joint_idx_val.integer);

            if (joint_idx >= nodes.array.items.len) continue;
            const node = nodes.array.items[joint_idx];
            if (node != .object) continue;

            if (node.object.get("children")) |children| {
                if (children == .array) {
                    for (children.array.items) |child_idx_val| {
                        if (child_idx_val != .integer) continue;
                        const child_node_idx: usize = @intCast(child_idx_val.integer);

                        // Find which bone corresponds to this child node
                        for (joints.array.items, 0..) |j2, child_bone_idx| {
                            if (j2 == .integer and @as(usize, @intCast(j2.integer)) == child_node_idx) {
                                if (child_bone_idx < skeleton.bone_count) {
                                    skeleton.bones[child_bone_idx].parent_index = @intCast(bone_idx);
                                }
                                break;
                            }
                        }
                    }
                }
            }
        }

        log(.INFO, "gltf_loader", "Loaded skeleton with {} bones", .{skeleton.bone_count});

        return skeleton;
    }

    /// Extract a mesh from GLTF
    fn extractMesh(self: *GltfLoader, root: *const std.json.Value, mesh_val: std.json.Value) !?Mesh {
        if (mesh_val != .object) return null;

        const primitives = mesh_val.object.get("primitives") orelse return null;
        if (primitives != .array or primitives.array.items.len == 0) return null;

        // Only handle first primitive for now
        const primitive = primitives.array.items[0];
        if (primitive != .object) return null;

        var mesh = Mesh.init(self.allocator);

        // Get accessors
        const accessors = root.object.get("accessors") orelse return null;
        if (accessors != .array) return null;

        // Get attributes
        const attributes = primitive.object.get("attributes") orelse return null;
        if (attributes != .object) return null;

        // Read positions
        const pos_accessor_idx = if (attributes.object.get("POSITION")) |p| blk: {
            if (p == .integer) break :blk @as(usize, @intCast(p.integer));
            break :blk null;
        } else null;

        // Read normals
        const normal_accessor_idx = if (attributes.object.get("NORMAL")) |n| blk: {
            if (n == .integer) break :blk @as(usize, @intCast(n.integer));
            break :blk null;
        } else null;

        // Read UVs
        const uv_accessor_idx = if (attributes.object.get("TEXCOORD_0")) |u| blk: {
            if (u == .integer) break :blk @as(usize, @intCast(u.integer));
            break :blk null;
        } else null;

        // Read indices
        const indices_accessor_idx = if (primitive.object.get("indices")) |i| blk: {
            if (i == .integer) break :blk @as(usize, @intCast(i.integer));
            break :blk null;
        } else null;

        // Get vertex count from position accessor
        var vertex_count: usize = 0;
        if (pos_accessor_idx) |idx| {
            if (idx < accessors.array.items.len) {
                const accessor = accessors.array.items[idx];
                if (accessor == .object) {
                    if (accessor.object.get("count")) |count| {
                        if (count == .integer) {
                            vertex_count = @intCast(count.integer);
                        }
                    }
                }
            }
        }

        // Read vertex data
        for (0..vertex_count) |i| {
            var vertex = Vertex{
                .pos = .{ 0, 0, 0 },
                .color = .{ 1, 1, 1 },
                .normal = .{ 0, 1, 0 },
                .uv = .{ 0, 0 },
            };

            if (pos_accessor_idx) |idx| {
                if (self.readVec3FromAccessor(root, idx, i)) |pos| {
                    vertex.pos = .{ pos.x, pos.y, pos.z };
                }
            }

            if (normal_accessor_idx) |idx| {
                if (self.readVec3FromAccessor(root, idx, i)) |normal| {
                    vertex.normal = .{ normal.x, normal.y, normal.z };
                }
            }

            if (uv_accessor_idx) |idx| {
                if (self.readVec2FromAccessor(root, idx, i)) |uv| {
                    vertex.uv = .{ uv[0], uv[1] };
                }
            }

            try mesh.vertices.append(self.allocator, vertex);
        }

        // Read indices
        if (indices_accessor_idx) |idx| {
            if (idx < accessors.array.items.len) {
                const accessor = accessors.array.items[idx];
                if (accessor == .object) {
                    if (accessor.object.get("count")) |count| {
                        if (count == .integer) {
                            const index_count: usize = @intCast(count.integer);
                            for (0..index_count) |i| {
                                if (self.readIndexFromAccessor(root, idx, i)) |index| {
                                    try mesh.indices.append(self.allocator, index);
                                }
                            }
                        }
                    }
                }
            }
        }

        if (mesh.vertices.items.len == 0) {
            return null;
        }

        log(.INFO, "gltf_loader", "Loaded mesh with {} vertices, {} indices", .{ mesh.vertices.items.len, mesh.indices.items.len });

        return mesh;
    }

    /// Extract an animation clip from GLTF
    fn extractAnimation(self: *GltfLoader, root: *const std.json.Value, anim_val: std.json.Value, skeleton: ?SkeletonComponent) !?AnimationClip {
        if (anim_val != .object) return null;

        var clip = AnimationClip{};

        // Get animation name
        if (anim_val.object.get("name")) |name_val| {
            if (name_val == .string) {
                clip.setName(name_val.string);
            }
        }

        // Get channels and samplers
        const channels_val = anim_val.object.get("channels") orelse return null;
        const samplers_val = anim_val.object.get("samplers") orelse return null;
        if (channels_val != .array or samplers_val != .array) return null;

        var channel_list = std.ArrayList(AnimationChannel){};

        for (channels_val.array.items) |channel_val| {
            if (channel_val != .object) continue;

            const sampler_idx_val = channel_val.object.get("sampler") orelse continue;
            if (sampler_idx_val != .integer) continue;
            const sampler_idx: usize = @intCast(sampler_idx_val.integer);

            if (sampler_idx >= samplers_val.array.items.len) continue;
            const sampler = samplers_val.array.items[sampler_idx];
            if (sampler != .object) continue;

            // Get target
            const target = channel_val.object.get("target") orelse continue;
            if (target != .object) continue;

            var anim_channel = AnimationChannel{};

            // Get target node
            if (target.object.get("node")) |node_val| {
                if (node_val == .integer) {
                    // Convert node index to bone index
                    if (skeleton) |skel| {
                        _ = skel;
                        // For now, use node index directly as bone index
                        // Full implementation would map via skeleton joints
                        anim_channel.bone_index = @intCast(node_val.integer);
                    }
                }
            }

            // Get target path
            if (target.object.get("path")) |path_val| {
                if (path_val == .string) {
                    if (std.mem.eql(u8, path_val.string, "translation")) {
                        anim_channel.property = .translation;
                    } else if (std.mem.eql(u8, path_val.string, "rotation")) {
                        anim_channel.property = .rotation;
                    } else if (std.mem.eql(u8, path_val.string, "scale")) {
                        anim_channel.property = .scale;
                    } else {
                        continue; // Skip unsupported paths (e.g., weights)
                    }
                }
            }

            // Get interpolation
            if (sampler.object.get("interpolation")) |interp_val| {
                if (interp_val == .string) {
                    if (std.mem.eql(u8, interp_val.string, "STEP")) {
                        anim_channel.interpolation = .step;
                    } else if (std.mem.eql(u8, interp_val.string, "CUBICSPLINE")) {
                        anim_channel.interpolation = .cubic_spline;
                    } else {
                        anim_channel.interpolation = .linear;
                    }
                }
            }

            // Get input (time) accessor
            const input_accessor_idx = if (sampler.object.get("input")) |i| blk: {
                if (i == .integer) break :blk @as(usize, @intCast(i.integer));
                break :blk null;
            } else null;

            // Get output (value) accessor
            const output_accessor_idx = if (sampler.object.get("output")) |o| blk: {
                if (o == .integer) break :blk @as(usize, @intCast(o.integer));
                break :blk null;
            } else null;

            if (input_accessor_idx == null or output_accessor_idx == null) continue;

            // Read keyframes
            const accessors = root.object.get("accessors") orelse continue;
            if (accessors != .array) continue;

            if (input_accessor_idx.? >= accessors.array.items.len) continue;
            const input_accessor = accessors.array.items[input_accessor_idx.?];
            if (input_accessor != .object) continue;

            const keyframe_count_val = input_accessor.object.get("count") orelse continue;
            if (keyframe_count_val != .integer) continue;
            const keyframe_count: usize = @intCast(keyframe_count_val.integer);

            var keyframes = try self.allocator.alloc(Keyframe, keyframe_count);

            for (0..keyframe_count) |i| {
                var kf = Keyframe{ .time = 0 };

                // Read time
                if (self.readFloatFromAccessor(root, input_accessor_idx.?, i)) |time| {
                    kf.time = time;
                    if (time > clip.duration) {
                        clip.duration = time;
                    }
                }

                // Read value based on property type
                switch (anim_channel.property) {
                    .translation, .scale => {
                        if (self.readVec3FromAccessor(root, output_accessor_idx.?, i)) |v| {
                            kf.value = .{ v.x, v.y, v.z, 1.0 };
                        }
                    },
                    .rotation => {
                        if (self.readVec4FromAccessor(root, output_accessor_idx.?, i)) |v| {
                            kf.value = v;
                        }
                    },
                }

                keyframes[i] = kf;
            }

            anim_channel.keyframes = keyframes;
            try channel_list.append(self.allocator, anim_channel);
        }

        if (channel_list.items.len == 0) {
            return null;
        }

        clip.channels = try channel_list.toOwnedSlice(self.allocator);

        log(.INFO, "gltf_loader", "Loaded animation '{s}' with {} channels, duration: {d:.2}s", .{
            clip.getName(),
            clip.channels.len,
            clip.duration,
        });

        return clip;
    }

    // ============================================================================
    // Accessor reading helpers
    // ============================================================================

    fn getAccessorData(self: *GltfLoader, root: *const std.json.Value, accessor_idx: usize) ?struct { data: []const u8, stride: usize, offset: usize } {
        const accessors = root.object.get("accessors") orelse return null;
        if (accessors != .array or accessor_idx >= accessors.array.items.len) return null;

        const accessor = accessors.array.items[accessor_idx];
        if (accessor != .object) return null;

        const buffer_view_idx_val = accessor.object.get("bufferView") orelse return null;
        if (buffer_view_idx_val != .integer) return null;
        const buffer_view_idx: usize = @intCast(buffer_view_idx_val.integer);

        const buffer_views = root.object.get("bufferViews") orelse return null;
        if (buffer_views != .array or buffer_view_idx >= buffer_views.array.items.len) return null;

        const buffer_view = buffer_views.array.items[buffer_view_idx];
        if (buffer_view != .object) return null;

        const buffer_idx_val = buffer_view.object.get("buffer") orelse return null;
        if (buffer_idx_val != .integer) return null;
        const buffer_idx: usize = @intCast(buffer_idx_val.integer);

        if (buffer_idx >= self.buffers.items.len) return null;

        const byte_offset: usize = if (buffer_view.object.get("byteOffset")) |bo| blk: {
            if (bo == .integer) break :blk @intCast(bo.integer);
            break :blk 0;
        } else 0;

        const accessor_offset: usize = if (accessor.object.get("byteOffset")) |ao| blk: {
            if (ao == .integer) break :blk @intCast(ao.integer);
            break :blk 0;
        } else 0;

        const byte_stride: usize = if (buffer_view.object.get("byteStride")) |bs| blk: {
            if (bs == .integer) break :blk @intCast(bs.integer);
            break :blk 0;
        } else 0;

        return .{
            .data = self.buffers.items[buffer_idx],
            .stride = byte_stride,
            .offset = byte_offset + accessor_offset,
        };
    }

    fn readFloatFromAccessor(self: *GltfLoader, root: *const std.json.Value, accessor_idx: usize, element_idx: usize) ?f32 {
        const info = self.getAccessorData(root, accessor_idx) orelse return null;
        const element_size: usize = 4; // float
        const stride = if (info.stride > 0) info.stride else element_size;
        const offset = info.offset + element_idx * stride;

        if (offset + element_size > info.data.len) return null;
        return @bitCast(info.data[offset..][0..4].*);
    }

    fn readVec2FromAccessor(self: *GltfLoader, root: *const std.json.Value, accessor_idx: usize, element_idx: usize) ?[2]f32 {
        const info = self.getAccessorData(root, accessor_idx) orelse return null;
        const element_size: usize = 8; // 2 floats
        const stride = if (info.stride > 0) info.stride else element_size;
        const offset = info.offset + element_idx * stride;

        if (offset + element_size > info.data.len) return null;

        return .{
            @bitCast(info.data[offset..][0..4].*),
            @bitCast(info.data[offset + 4 ..][0..4].*),
        };
    }

    fn readVec3FromAccessor(self: *GltfLoader, root: *const std.json.Value, accessor_idx: usize, element_idx: usize) ?math.Vec3 {
        const info = self.getAccessorData(root, accessor_idx) orelse return null;
        const element_size: usize = 12; // 3 floats
        const stride = if (info.stride > 0) info.stride else element_size;
        const offset = info.offset + element_idx * stride;

        if (offset + element_size > info.data.len) return null;

        return math.Vec3.init(
            @bitCast(info.data[offset..][0..4].*),
            @bitCast(info.data[offset + 4 ..][0..4].*),
            @bitCast(info.data[offset + 8 ..][0..4].*),
        );
    }

    fn readVec4FromAccessor(self: *GltfLoader, root: *const std.json.Value, accessor_idx: usize, element_idx: usize) ?[4]f32 {
        const info = self.getAccessorData(root, accessor_idx) orelse return null;
        const element_size: usize = 16; // 4 floats
        const stride = if (info.stride > 0) info.stride else element_size;
        const offset = info.offset + element_idx * stride;

        if (offset + element_size > info.data.len) return null;

        return .{
            @bitCast(info.data[offset..][0..4].*),
            @bitCast(info.data[offset + 4 ..][0..4].*),
            @bitCast(info.data[offset + 8 ..][0..4].*),
            @bitCast(info.data[offset + 12 ..][0..4].*),
        };
    }

    fn readMat4FromAccessor(self: *GltfLoader, root: *const std.json.Value, accessor_idx: usize, element_idx: usize) ?math.Mat4 {
        const info = self.getAccessorData(root, accessor_idx) orelse return null;
        const element_size: usize = 64; // 16 floats
        const stride = if (info.stride > 0) info.stride else element_size;
        const offset = info.offset + element_idx * stride;

        if (offset + element_size > info.data.len) return null;

        var mat: [16]f32 = undefined;
        for (0..16) |i| {
            const float_offset = offset + i * 4;
            mat[i] = @bitCast(info.data[float_offset..][0..4].*);
        }

        return math.Mat4{ .data = mat };
    }

    fn readIndexFromAccessor(self: *GltfLoader, root: *const std.json.Value, accessor_idx: usize, element_idx: usize) ?u32 {
        const accessors = root.object.get("accessors") orelse return null;
        if (accessors != .array or accessor_idx >= accessors.array.items.len) return null;

        const accessor = accessors.array.items[accessor_idx];
        if (accessor != .object) return null;

        // Get component type
        const component_type_val = accessor.object.get("componentType") orelse return null;
        if (component_type_val != .integer) return null;
        const component_type: u32 = @intCast(component_type_val.integer);

        const info = self.getAccessorData(root, accessor_idx) orelse return null;

        const element_size: usize = switch (component_type) {
            5121 => 1, // unsigned byte
            5123 => 2, // unsigned short
            5125 => 4, // unsigned int
            else => return null,
        };

        const stride = if (info.stride > 0) info.stride else element_size;
        const offset = info.offset + element_idx * stride;

        if (offset + element_size > info.data.len) return null;

        return switch (component_type) {
            5121 => info.data[offset],
            5123 => std.mem.readInt(u16, info.data[offset..][0..2], .little),
            5125 => std.mem.readInt(u32, info.data[offset..][0..4], .little),
            else => null,
        };
    }
};

fn getFloatValue(val: std.json.Value) f32 {
    return switch (val) {
        .float => @floatCast(val.float),
        .integer => @floatFromInt(val.integer),
        else => 0,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "GltfLoader initialization" {
    const allocator = std.testing.allocator;
    var loader = GltfLoader.init(allocator);
    defer loader.deinit();
}
