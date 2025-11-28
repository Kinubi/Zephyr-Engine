const std = @import("std");
const World = @import("../world.zig").World;
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
    // Static time accumulator (persists across calls)
    const State = struct {
        var time_elapsed: f32 = 0.0;
    };
    State.time_elapsed += dt;

    // Get GlobalUbo from world userdata for extraction
    const ubo_ptr = world.getUserData("global_ubo");
    const global_ubo: ?*GlobalUbo = if (ubo_ptr) |ptr| @ptrCast(@alignCast(ptr)) else null;

    // Collect up to 16 lights with stable order by entity id
    const MaxLights = 16;
    const Entry = struct {
        id: usize,
        transform: *Transform,
        light: *const PointLight,
    };
    var list: [MaxLights]Entry = undefined;
    var count: usize = 0;

    var view = try world.view(PointLight);
    var iter = view.iterator();
    while (iter.next()) |entry| {
        const transform_ptr = world.get(Transform, entry.entity) orelse continue;
        if (count < MaxLights) {
            list[count] = .{
                .id = @intFromEnum(entry.entity),
                .transform = transform_ptr,
                .light = entry.component,
            };
            count += 1;
        }
        // Update world matrix and clear dirty flag for lights (they don't go through render system)
        transform_ptr.updateWorldMatrix();
    }

    // Sort by stable entity id
    std.sort.pdq(Entry, list[0..count], {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            return a.id < b.id;
        }
    }.lessThan);

    // Write light data to UBO using current transform positions (no animation)
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const pos = list[i].transform.position;

        if (global_ubo) |ubo| {
            ubo.point_lights[i] = .{
                .position = Math.Vec4.init(pos.x, pos.y, pos.z, 1.0),
                .color = Math.Vec4.init(
                    list[i].light.color.x * list[i].light.intensity,
                    list[i].light.color.y * list[i].light.intensity,
                    list[i].light.color.z * list[i].light.intensity,
                    list[i].light.intensity,
                ),
            };
        }
    }

    if (global_ubo) |ubo| {
        ubo.num_point_lights = @intCast(count);
        // Clear remaining light slots
        var j: usize = count;
        while (j < MaxLights) : (j += 1) {
            ubo.point_lights[j] = .{};
        }
    }
}
