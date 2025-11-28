const std = @import("std");
const World = @import("../world.zig").World;
const EntityId = @import("../entity_registry.zig").EntityId;
const Transform = @import("../components/transform.zig").Transform;
const PointLight = @import("../components/point_light.zig").PointLight;
const Math = @import("../../utils/math.zig");
const GlobalUbo = @import("../../rendering/frameinfo.zig").GlobalUbo;
const log = @import("../../utils/log.zig").log;

/// Extracted light data for rendering
pub const ExtractedLight = struct {
    position: Math.Vec3,
    color: Math.Vec3,
    intensity: f32,
    range: f32,
    attenuation: Math.Vec3, // (constant, linear, quadratic)
};

/// Collection of extracted lights
pub const LightData = struct {
    lights: std.ArrayList(ExtractedLight),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) LightData {
        return .{
            .lights = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *LightData) void {
        self.lights.deinit(self.allocator);
    }

    pub fn clear(self: *LightData) void {
        self.lights.clearRetainingCapacity();
    }
};

/// System for extracting light data from ECS for rendering
/// Uses generation-based change detection to avoid re-extracting every frame
pub const LightSystem = struct {
    allocator: std.mem.Allocator,

    // Cache to avoid re-extracting lights every frame
    cached_light_data: ?LightData = null,
    last_light_count: usize = 0,

    // Generation-based change tracking (matches ShadowSystem pattern)
    generation: u32 = 0,
    last_position_hash: u64 = 0, // Hash of all light positions for change detection

    pub fn init(allocator: std.mem.Allocator) LightSystem {
        return .{
            .allocator = allocator,
            .cached_light_data = null,
            .last_light_count = 0,
            .generation = 0,
            .last_position_hash = 0,
        };
    }

    pub fn deinit(self: *LightSystem) void {
        if (self.cached_light_data) |*data| {
            data.deinit();
        }
    }

    /// Get current generation (for external change detection)
    pub fn getGeneration(self: *const LightSystem) u32 {
        return self.generation;
    }

    /// Get lights (uses cache if nothing changed, otherwise re-extracts)
    /// Returns a pointer to the cached data - do NOT deinit it!
    pub fn getLights(self: *LightSystem, world: *World) !*const LightData {
        // Quick check: count the lights in the ECS
        var view = try world.view(PointLight);
        const count = view.len();

        // Check if count changed (fast path)
        const count_changed = count != self.last_light_count;

        // Initialize cache if needed
        if (self.cached_light_data == null) {
            self.cached_light_data = LightData.init(self.allocator);
        }

        if (count_changed) {
            // Count changed - must re-extract
            try self.extractLightsInto(world, &self.cached_light_data.?);
            self.last_light_count = count;
            self.generation +%= 1;
        } else if (count > 0) {
            // Same count - check if positions changed using a quick hash
            const new_hash = try self.computePositionHash(world);
            if (new_hash != self.last_position_hash) {
                try self.extractLightsInto(world, &self.cached_light_data.?);
                self.last_position_hash = new_hash;
                self.generation +%= 1;
            }
        }

        return &(self.cached_light_data.?);
    }

    /// Compute a hash of all light positions for quick change detection
    fn computePositionHash(self: *LightSystem, world: *World) !u64 {
        _ = self;
        var hasher = std.hash.Wyhash.init(0);

        var view = try world.view(PointLight);
        var iter = view.iterator();
        while (iter.next()) |entry| {
            const transform = world.get(Transform, entry.entity) orelse continue;
            // Hash position components
            hasher.update(std.mem.asBytes(&transform.position.x));
            hasher.update(std.mem.asBytes(&transform.position.y));
            hasher.update(std.mem.asBytes(&transform.position.z));
            // Also hash intensity and color for visual changes
            hasher.update(std.mem.asBytes(&entry.component.intensity));
            hasher.update(std.mem.asBytes(&entry.component.color.x));
            hasher.update(std.mem.asBytes(&entry.component.color.y));
            hasher.update(std.mem.asBytes(&entry.component.color.z));
        }

        return hasher.final();
    }

    /// Extract all point lights from the ECS world into provided LightData
    fn extractLightsInto(self: *LightSystem, world: *World, light_data: *LightData) !void {
        _ = self;
        light_data.clear();

        // Get view of all entities with PointLight components
        var view = try world.view(PointLight);

        // Extract each light (also need Transform component)
        var iter = view.iterator();
        while (iter.next()) |entry| {
            const point_light = entry.component;

            // Skip if entity doesn't have Transform
            const transform = world.get(Transform, entry.entity) orelse continue;

            // Extract world position from transform
            const position = transform.position;

            try light_data.lights.append(light_data.allocator, .{
                .position = position,
                .color = point_light.color,
                .intensity = point_light.intensity,
                .range = point_light.range,
                .attenuation = Math.Vec3.init(
                    point_light.constant,
                    point_light.linear,
                    point_light.quadratic,
                ),
            });
        }
    }
};

pub fn prepare(world: *World, dt: f32) !void {
    _ = dt;

    // Get GlobalUbo from world userdata for extraction
    const ubo_ptr = world.getUserData("global_ubo");
    const global_ubo: ?*GlobalUbo = if (ubo_ptr) |ptr| @ptrCast(@alignCast(ptr)) else null;
    if (global_ubo == null) return;

    // Static cache to avoid re-querying/sorting every frame
    const MaxLights = 16;
    const CachedEntry = struct {
        id: usize,
        entity: EntityId,
    };
    const State = struct {
        var cached_entities: [MaxLights]CachedEntry = undefined;
        var cached_count: usize = 0;
        var last_generation: u32 = 0;
    };

    // Quick check: get light count via view len
    var view = try world.view(PointLight);
    const new_count = view.len();

    // Check if we need to rebuild cache (count changed or first run)
    const count_changed = new_count != State.cached_count;
    var needs_rebuild = count_changed;

    // If count same, check generation from world (if available)
    if (!needs_rebuild) {
        // Check if any transforms are dirty - quick scan
        var iter = view.iterator();
        while (iter.next()) |entry| {
            const transform_ptr = world.get(Transform, entry.entity) orelse continue;
            if (transform_ptr.dirty) {
                needs_rebuild = true;
                break;
            }
        }
    }

    var count: usize = 0;

    if (needs_rebuild) {
        // Rebuild sorted entity list
        var iter = view.iterator();
        while (iter.next()) |entry| {
            const transform_ptr = world.get(Transform, entry.entity) orelse continue;
            if (count < MaxLights) {
                State.cached_entities[count] = .{
                    .id = @intFromEnum(entry.entity),
                    .entity = entry.entity,
                };
                count += 1;
            }
            transform_ptr.updateWorldMatrix();
        }
        State.cached_count = count;

        // Sort by stable entity id
        std.sort.pdq(CachedEntry, State.cached_entities[0..count], {}, struct {
            fn lessThan(_: void, a: CachedEntry, b: CachedEntry) bool {
                return a.id < b.id;
            }
        }.lessThan);
    } else {
        // Use cached count, just update world matrices
        count = State.cached_count;
        var iter = view.iterator();
        while (iter.next()) |_| {}
    }

    // Write light data to UBO using cached entity order
    const ubo = global_ubo.?;
    for (0..count) |i| {
        const entity = State.cached_entities[i].entity;
        const transform_ptr = world.get(Transform, entity) orelse continue;
        const light = world.get(PointLight, entity) orelse continue;
        const pos = transform_ptr.position;

        ubo.point_lights[i] = .{
            .position = Math.Vec4.init(pos.x, pos.y, pos.z, 1.0),
            .color = Math.Vec4.init(
                light.color.x * light.intensity,
                light.color.y * light.intensity,
                light.color.z * light.intensity,
                light.intensity,
            ),
        };
    }

    ubo.num_point_lights = @intCast(count);
    // Clear remaining light slots
    for (count..MaxLights) |j| {
        ubo.point_lights[j] = .{};
    }
}
