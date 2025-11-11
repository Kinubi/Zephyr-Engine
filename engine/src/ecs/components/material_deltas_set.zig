const std = @import("std");
const vk = @import("vulkan");

/// GPU Material struct (matches shader layout)
pub const GPUMaterial = extern struct {
    albedo_idx: u32,
    roughness_idx: u32,
    metallic_idx: u32,
    normal_idx: u32,
    emissive_idx: u32,
    occlusion_idx: u32,

    albedo_tint: [4]f32,
    roughness_factor: f32,
    metallic_factor: f32,
    normal_strength: f32,
    emissive_intensity: f32,
    emissive_color: [3]f32 align(16),
    occlusion_strength: f32,
};

/// Material change for delta updates
pub const MaterialChange = struct {
    index: u32,
    data: GPUMaterial,
};

/// Material set delta for a single material set
pub const MaterialSetDelta = struct {
    set_name: []const u8, // Owned by MaterialSystem, don't free
    changed_materials: []MaterialChange, // Owned by this component
    texture_descriptors: []vk.DescriptorImageInfo, // Owned by this component
    texture_count: u32,
    texture_array_dirty: bool,
};

/// Singleton component holding material deltas from prepare phase.
/// Similar to RenderablesSet, this is written by MaterialSystem.prepare()
/// and read by the render thread for GPU updates.
pub const MaterialDeltasSet = struct {
    allocator: std.mem.Allocator,
    deltas: []MaterialSetDelta,

    pub fn init(allocator: std.mem.Allocator) MaterialDeltasSet {
        return .{
            .allocator = allocator,
            .deltas = &.{},
        };
    }

    pub fn deinit(self: *MaterialDeltasSet) void {
        for (self.deltas) |*delta| {
            if (delta.changed_materials.len > 0) {
                self.allocator.free(delta.changed_materials);
            }
            if (delta.texture_descriptors.len > 0) {
                self.allocator.free(delta.texture_descriptors);
            }
            // set_name is owned by MaterialSystem, don't free
        }
        if (self.deltas.len > 0) {
            self.allocator.free(self.deltas);
        }
        self.* = undefined;
    }

    /// Clear deltas but keep allocator (for reuse)
    pub fn clear(self: *MaterialDeltasSet) void {
        for (self.deltas) |*delta| {
            if (delta.changed_materials.len > 0) {
                self.allocator.free(delta.changed_materials);
            }
            if (delta.texture_descriptors.len > 0) {
                self.allocator.free(delta.texture_descriptors);
            }
        }
        if (self.deltas.len > 0) {
            self.allocator.free(self.deltas);
        }
        self.deltas = &.{};
    }
};
