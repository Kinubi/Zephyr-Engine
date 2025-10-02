const std = @import("std");
const vk = @import("vulkan");
const Buffer = @import("../core/buffer.zig").Buffer;
const DescriptorPool = @import("../core/descriptors.zig").DescriptorPool;
const DescriptorSetLayout = @import("../core/descriptors.zig").DescriptorSetLayout;
const DescriptorWriter = @import("../core/descriptors.zig").DescriptorWriter;
const GlobalUbo = @import("frameinfo.zig").GlobalUbo;
const MAX_FRAMES_IN_FLIGHT = @import("../core/swapchain.zig").MAX_FRAMES_IN_FLIGHT;
const GraphicsContext = @import("../core/graphics_context.zig").GraphicsContext;
const deinitDescriptorResources = @import("../core/descriptors.zig").deinitDescriptorResources;
const log = @import("../utils/log.zig").log;

pub const GlobalUboSet = struct {
    pool: *DescriptorPool,
    layout: *DescriptorSetLayout,
    sets: []vk.DescriptorSet,
    buffers: []Buffer,
    allocator: std.mem.Allocator,

    /// Create pool and layout for the global UBO set, matching RaytracingDescriptorSet style
    pub fn createPoolAndLayout(
        gc: *GraphicsContext,
        allocator: std.mem.Allocator,
        frame_count: usize,
    ) !struct {
        pool: *DescriptorPool,
        layout: *DescriptorSetLayout,
    } {
        var pool_builder = DescriptorPool.Builder{
            .gc = gc,
            .poolSizes = std.ArrayList(vk.DescriptorPoolSize){},
            .poolFlags = .{ .free_descriptor_set_bit = true },
            .maxSets = 0,
            .allocator = allocator,
        };
        const pool = try allocator.create(DescriptorPool);
        pool.* = try pool_builder
            .setMaxSets(@intCast(frame_count))
            .addPoolSize(.uniform_buffer, @intCast(frame_count)).build();

        var layout_builder = DescriptorSetLayout.Builder{
            .gc = gc,
            .bindings = std.AutoHashMap(u32, vk.DescriptorSetLayoutBinding).init(allocator),
        };
        const layout = try allocator.create(DescriptorSetLayout);
        layout.* = try layout_builder
            .addBinding(0, .uniform_buffer, .{ .vertex_bit = true, .fragment_bit = true }, 1)
            .build();
        return .{ .pool = pool, .layout = layout };
    }

    /// Allocate and write descriptor sets for the global UBOs
    pub fn createDescriptorSets(
        gc: *GraphicsContext,
        pool: *DescriptorPool,
        layout: *DescriptorSetLayout,
        allocator: std.mem.Allocator,
        buffers: []Buffer,
    ) ![]vk.DescriptorSet {
        var sets = try allocator.alloc(vk.DescriptorSet, buffers.len);
        var writer = DescriptorWriter.init(gc, layout, pool, allocator);
        for (buffers, 0..) |buf, i| {
            const bufferInfo = buf.descriptor_info;
            try writer.writeBuffer(0, @constCast(&bufferInfo)).build(&sets[i]);
        }
        return sets;
    }

    /// New init: create buffers, then pool/layout, then sets, matching RaytracingDescriptorSet style
    pub fn init(gc: *GraphicsContext, allocator: std.mem.Allocator) !GlobalUboSet {
        var buffers = try allocator.alloc(Buffer, MAX_FRAMES_IN_FLIGHT);
        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            buffers[i] = try Buffer.init(
                gc,
                @sizeOf(GlobalUbo),
                1,
                .{ .uniform_buffer_bit = true },
                .{ .host_visible_bit = true, .host_coherent_bit = true },
            );
            try buffers[i].map(vk.WHOLE_SIZE, 0);
            // Debug log removed to reduce spam
        }
        const pool_layout = try GlobalUboSet.createPoolAndLayout(gc, allocator, MAX_FRAMES_IN_FLIGHT);
        const sets = try GlobalUboSet.createDescriptorSets(gc, pool_layout.pool, pool_layout.layout, allocator, buffers);
        return GlobalUboSet{
            .pool = pool_layout.pool,
            .layout = pool_layout.layout,
            .sets = sets,
            .buffers = buffers,
            .allocator = allocator,
        };
    }

    pub fn update(self: *GlobalUboSet, frame: usize, ubo: *GlobalUbo) void {
        self.buffers[frame].writeToBuffer(std.mem.asBytes(ubo), vk.WHOLE_SIZE, 0);
        self.buffers[frame].flush(vk.WHOLE_SIZE, 0) catch {};
    }

    pub fn deinit(self: *GlobalUboSet) void {
        for (self.buffers) |*buf| buf.deinit();
        deinitDescriptorResources(self.pool, self.layout, self.sets, self.allocator) catch |err| {
            std.debug.print("Error deinitializing GlobalUboSet: {}\n", .{err});
        };
    }
};
