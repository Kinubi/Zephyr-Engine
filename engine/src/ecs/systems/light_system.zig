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
pub const LightSystem = struct {
    allocator: std.mem.Allocator,

    // Cache to avoid re-extracting lights every frame
    cached_light_data: ?LightData = null,
    last_light_count: usize = 0,
    lights_dirty: bool = true,

    pub fn init(allocator: std.mem.Allocator) LightSystem {
        return .{
            .allocator = allocator,
            .cached_light_data = null,
            .last_light_count = 0,
            .lights_dirty = true,
        };
    }

    pub fn deinit(self: *LightSystem) void {
        if (self.cached_light_data) |*data| {
            data.deinit();
        }
    }

    /// Get lights (uses cache if nothing changed, otherwise re-extracts)
    /// Returns a pointer to the cached data - do NOT deinit it!
    pub fn getLights(self: *LightSystem, world: *World) !*const LightData {
        // Quick check: count the lights in the ECS
        var view = try world.view(PointLight);
        const count = view.len();

        // Check if we need to re-extract
        const count_changed = count != self.last_light_count;
        if (count_changed or self.lights_dirty or self.cached_light_data == null) {

            // Initialize cache if needed
            if (self.cached_light_data == null) {
                self.cached_light_data = LightData.init(self.allocator);
            }

            // Re-extract lights into existing cache
            try self.extractLightsInto(world, &self.cached_light_data.?);
            self.last_light_count = count;
            //self.lights_dirty = false;
        }

        return &(self.cached_light_data.?);
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

    /// Mark lights as dirty to force re-extraction next frame
    /// Call this when lights are added/removed/modified programmatically
    pub fn markDirty(self: *LightSystem) void {
        self.lights_dirty = true;
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
    }

    // Sort by stable entity id
    std.sort.pdq(Entry, list[0..count], {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            return a.id < b.id;
        }
    }.lessThan);

    // Animate and write to UBO in sorted order with even angular spacing
    const radius: f32 = 1.5;
    const height: f32 = 0.5;
    const speed: f32 = 1.0;
    const two_pi: f32 = 2.0 * std.math.pi;

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const phase = if (count > 0) (@as(f32, @floatFromInt(i)) * (two_pi / @as(f32, @floatFromInt(count)))) else 0.0;
        const angle = State.time_elapsed * speed + phase;
        const x = @cos(angle) * radius;
        const z = @sin(angle) * radius;

        // Update transform position and UBO
        list[i].transform.setPosition(Math.Vec3.init(x, height, z));

        if (global_ubo) |ubo| {
            ubo.point_lights[i] = .{
                .position = Math.Vec4.init(x, height, z, 1.0),
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
