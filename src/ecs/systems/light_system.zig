const std = @import("std");
const World = @import("../world.zig").World;
const Transform = @import("../components/transform.zig").Transform;
const PointLight = @import("../components/point_light.zig").PointLight;
const Math = @import("../../utils/math.zig");
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
