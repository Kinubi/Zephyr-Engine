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
        self.lights.clearRetainingCapacity(self.allocator);
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
        var count: usize = 0;
        var iter = view.iterator();
        while (iter.next()) |_| {
            count += 1;
        }

        // Check if we need to re-extract
        const count_changed = count != self.last_light_count;
        if (count_changed or self.lights_dirty or self.cached_light_data == null) {

            // Re-extract lights
            if (self.cached_light_data) |*old_data| {
                old_data.deinit();
            }

            self.cached_light_data = try self.extractLights(world);
            self.last_light_count = count;
            //self.lights_dirty = false;
        }

        return &(self.cached_light_data.?);
    }

    /// Extract all point lights from the ECS world (internal, use getLights instead)
    fn extractLights(self: *LightSystem, world: *World) !LightData {
        var light_data = LightData.init(self.allocator);
        errdefer light_data.deinit();

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

        return light_data;
    }

    /// Mark lights as dirty to force re-extraction next frame
    /// Call this when lights are added/removed/modified programmatically
    pub fn markDirty(self: *LightSystem) void {
        self.lights_dirty = true;
    }
};

/// Standalone system function for animating lights (for SystemScheduler)
/// This animates point lights in a circle pattern
pub fn animateLightsSystem(world: *World, dt: f32) !void {
    // Static time accumulator (persists across calls)
    const State = struct {
        var time_elapsed: f32 = 0.0;
    };
    State.time_elapsed += dt;

    // Get GlobalUbo from world userdata for extraction

    const ubo_ptr = world.getUserData("global_ubo");
    const global_ubo: ?*GlobalUbo = if (ubo_ptr) |ptr| @ptrCast(@alignCast(ptr)) else null;

    var view = try world.view(PointLight);
    var iter = view.iterator();
    var light_index: usize = 0;

    while (iter.next()) |entry| : (light_index += 1) {
        const point_light = entry.component;
        const transform_ptr = world.get(Transform, entry.entity) orelse continue;

        // Animate position in a circle
        const radius: f32 = 1.5;
        const height: f32 = 0.5;
        const speed: f32 = 1.0;
        const angle_offset: f32 = @as(f32, @floatFromInt(light_index)) * (2.0 * std.math.pi / 3.0);

        const angle = State.time_elapsed * speed + angle_offset;
        const x = @cos(angle) * radius;
        const z = @sin(angle) * radius;

        // Update transform position using setter to mark dirty flag
        transform_ptr.setPosition(Math.Vec3.init(x, height, z));

        // Extract to GlobalUbo if available
        if (global_ubo) |ubo| {
            if (light_index < 16) {
                ubo.point_lights[light_index] = .{
                    .position = Math.Vec4.init(x, height, z, 1.0),
                    .color = Math.Vec4.init(
                        point_light.color.x * point_light.intensity,
                        point_light.color.y * point_light.intensity,
                        point_light.color.z * point_light.intensity,
                        point_light.intensity,
                    ),
                };
            }
        }
    }

    // Finalize GlobalUbo light data
    if (global_ubo) |ubo| {
        ubo.num_point_lights = @intCast(@min(light_index, 16));

        // Clear remaining light slots
        for (light_index..16) |i| {
            ubo.point_lights[i] = .{};
        }
    }
}
