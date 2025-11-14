const std = @import("std");
const vk = @import("vulkan");
const log = @import("../utils/log.zig").log;

const MAX_FRAMES_IN_FLIGHT = @import("../core/swapchain.zig").MAX_FRAMES_IN_FLIGHT;

/// Frame arena for texture descriptor allocations
/// Each frame has its own arena that cycles, just like BufferManager's frame arenas
pub const DescriptorArena = struct {
    allocator: std.mem.Allocator,
    /// Large pre-allocated memory pool for descriptors
    memory: []vk.DescriptorImageInfo,
    capacity: usize,
    current_offset: usize,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !DescriptorArena {
        const memory = try allocator.alloc(vk.DescriptorImageInfo, capacity);
        return .{
            .allocator = allocator,
            .memory = memory,
            .capacity = capacity,
            .current_offset = 0,
        };
    }

    pub fn deinit(self: *DescriptorArena) void {
        self.allocator.free(self.memory);
    }

    /// Allocate space for descriptors from this arena
    /// Returns a slice pointing into the arena's memory
    pub fn allocate(self: *DescriptorArena, count: usize) ![]vk.DescriptorImageInfo {
        if (self.current_offset + count > self.capacity) {
            return error.ArenaFull;
        }

        const start = self.current_offset;
        self.current_offset += count;

        return self.memory[start..][0..count];
    }

    /// Reset the arena for the next frame cycle
    /// Unlike BufferManager which tracks allocations, we just reset the offset
    /// since descriptor data gets copied in and doesn't need lifecycle tracking
    pub fn reset(self: *DescriptorArena) void {
        self.current_offset = 0;
    }
};

/// Texture Descriptor Manager - manages per-frame texture descriptor arrays
/// Mirrors BufferManager's design for consistent lifecycle management
pub const TextureDescriptorManager = struct {
    allocator: std.mem.Allocator,
    /// Per-frame arenas (one per frame-in-flight)
    frame_arenas: [MAX_FRAMES_IN_FLIGHT]DescriptorArena,

    /// Default capacity: 1024 descriptors per frame (4 textures × 256 materials = worst case)
    const DEFAULT_CAPACITY_PER_FRAME: usize = 1024;

    pub fn init(allocator: std.mem.Allocator) !*TextureDescriptorManager {
        const self = try allocator.create(TextureDescriptorManager);

        for (&self.frame_arenas) |*arena| {
            arena.* = try DescriptorArena.init(allocator, DEFAULT_CAPACITY_PER_FRAME);
        }

        log(.INFO, "texture_descriptor_manager", "TextureDescriptorManager initialized with {} frame arenas ({} descriptors each)", .{
            MAX_FRAMES_IN_FLIGHT,
            DEFAULT_CAPACITY_PER_FRAME,
        });

        self.* = .{
            .allocator = allocator,
            .frame_arenas = self.frame_arenas,
        };

        return self;
    }

    pub fn deinit(self: *TextureDescriptorManager) void {
        for (&self.frame_arenas) |*arena| {
            arena.deinit();
        }
        self.allocator.destroy(self);
    }

    /// Allocate texture descriptors from a specific frame's arena
    /// Copies the source descriptors into the arena and returns offset + slice
    /// The offset is stable across arena resets (like material buffer offsets)
    pub fn allocateFromFrame(
        self: *TextureDescriptorManager,
        frame_index: u32,
        source_descriptors: []const vk.DescriptorImageInfo,
    ) !struct { offset: usize, descriptors: []vk.DescriptorImageInfo } {
        if (frame_index >= MAX_FRAMES_IN_FLIGHT) {
            return error.InvalidFrameIndex;
        }

        const arena = &self.frame_arenas[frame_index];
        const offset = arena.current_offset; // Save offset before allocation
        const dest = try arena.allocate(source_descriptors.len);

        // Copy descriptors into arena memory
        @memcpy(dest, source_descriptors);

        return .{
            .offset = offset,
            .descriptors = dest,
        };
    }

    /// Reset a frame's arena (for explicit reset only, not called per-frame)
    /// Normally the arena works as a ring buffer - keeps allocating until full,
    /// then old allocations get naturally overwritten on wrap-around
    /// This is the same pattern as BufferManager's frame arenas
    pub fn resetFrameArena(self: *TextureDescriptorManager, frame_index: u32) void {
        if (frame_index >= MAX_FRAMES_IN_FLIGHT) return;

        self.frame_arenas[frame_index].reset();
    }

    /// Get descriptors from arena using offset (for binding after arena reset)
    /// This resolves the stable offset back to a slice pointer
    pub fn getDescriptorsAtOffset(
        self: *TextureDescriptorManager,
        frame_index: u32,
        offset: usize,
        count: usize,
    ) []vk.DescriptorImageInfo {
        if (frame_index >= MAX_FRAMES_IN_FLIGHT) {
            return &[_]vk.DescriptorImageInfo{};
        }

        const arena = &self.frame_arenas[frame_index];
        if (offset + count > arena.capacity) {
            return &[_]vk.DescriptorImageInfo{};
        }

        return arena.memory[offset..][0..count];
    }

    /// Get current usage stats for a frame's arena
    pub fn getArenaUsage(self: *TextureDescriptorManager, frame_index: u32) struct { used: usize, capacity: usize } {
        if (frame_index >= MAX_FRAMES_IN_FLIGHT) {
            return .{ .used = 0, .capacity = 0 };
        }

        const arena = &self.frame_arenas[frame_index];
        return .{
            .used = arena.current_offset,
            .capacity = arena.capacity,
        };
    }
};
