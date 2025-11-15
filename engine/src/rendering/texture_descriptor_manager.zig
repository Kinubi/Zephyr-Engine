const std = @import("std");
const vk = @import("vulkan");
const log = @import("../utils/log.zig").log;

const MAX_FRAMES_IN_FLIGHT = @import("../core/swapchain.zig").MAX_FRAMES_IN_FLIGHT;

/// Frame arena for texture descriptor allocations
/// Matches BufferManager's FrameArena pattern with ring-buffer behavior and wrap-around support
pub const DescriptorArena = struct {
    allocator: std.mem.Allocator,
    /// Large pre-allocated memory pool for descriptors
    memory: []vk.DescriptorImageInfo,
    capacity: usize,
    current_offset: usize,
    smallest_used_offset: usize, // Track oldest still-referenced allocation
    frame_index: u32,
    needs_compaction: bool,

    // Track active allocations for proper wrap-around and compaction
    active_allocations: std.ArrayList(AllocationInfo),

    pub const AllocationInfo = struct {
        offset: usize,
        size: usize,
    };

    pub fn init(allocator: std.mem.Allocator, capacity: usize, frame_index: u32) !DescriptorArena {
        const memory = try allocator.alloc(vk.DescriptorImageInfo, capacity);
        return .{
            .allocator = allocator,
            .memory = memory,
            .capacity = capacity,
            .current_offset = 0,
            .smallest_used_offset = 0,
            .frame_index = frame_index,
            .needs_compaction = false,
            .active_allocations = std.ArrayList(AllocationInfo){},
        };
    }

    pub fn deinit(self: *DescriptorArena) void {
        self.active_allocations.deinit(self.allocator);
        self.allocator.free(self.memory);
    }

    /// Allocate space for descriptors from this arena with wrap-around support
    /// Returns a slice pointing into the arena's memory
    /// Matches BufferManager's allocation pattern
    pub fn allocate(self: *DescriptorArena, count: usize) !struct { offset: usize, slice: []vk.DescriptorImageInfo } {
        // Check if allocation fits from current position
        if (self.current_offset + count > self.capacity) {
            // Would wrap - check if allocation fits from start of arena
            if (count > self.capacity) {
                // Single allocation too large for entire arena
                return error.AllocationTooLarge;
            }

            // Check if we'd collide with active allocations when wrapping
            if (self.active_allocations.items.len > 0 and count > self.smallest_used_offset) {
                // Collision detected - need compaction
                self.needs_compaction = true;
                return error.ArenaRequiresCompaction;
            }

            // Safe to wrap around to start
            const offset: usize = 0;
            self.current_offset = count;

            // Track this allocation
            try self.active_allocations.append(self.allocator, .{
                .offset = offset,
                .size = count,
            });

            return .{
                .offset = offset,
                .slice = self.memory[offset..][0..count],
            };
        }

        // Normal allocation without wrap
        const offset = self.current_offset;
        const new_offset = self.current_offset + count;
        
        // Check if we're in wrapped region and would collide with active allocations
        if (offset < self.smallest_used_offset and new_offset > self.smallest_used_offset) {
            // Collision detected - need compaction
            self.needs_compaction = true;
            return error.ArenaRequiresCompaction;
        }
        
        self.current_offset = new_offset;

        // Track this allocation
        try self.active_allocations.append(self.allocator, .{
            .offset = offset,
            .size = count,
        });

        return .{
            .offset = offset,
            .slice = self.memory[offset..][0..count],
        };
    }

    /// Free an allocation and update smallest_used_offset
    /// Called when a ManagedTextureArray is no longer referencing this offset
    pub fn freeAllocation(self: *DescriptorArena, offset: usize) void {
        // Find and remove the allocation
        const was_smallest = (offset == self.smallest_used_offset);
        var found = false;
        
        for (self.active_allocations.items, 0..) |alloc, i| {
            if (alloc.offset == offset) {
                _ = self.active_allocations.swapRemove(i);
                found = true;
                break;
            }
        }

        // Only recalculate if we removed the smallest allocation or nothing was found
        if (!found or was_smallest) {
            if (self.active_allocations.items.len == 0) {
                self.smallest_used_offset = 0;
            } else {
                // Recalculate smallest_used_offset
                self.smallest_used_offset = self.capacity;
                for (self.active_allocations.items) |alloc| {
                    if (alloc.offset < self.smallest_used_offset) {
                        self.smallest_used_offset = alloc.offset;
                    }
                }
            }
        }
    }

    /// Explicitly reset arena (clears all tracking)
    /// Used for full arena reset, not typically called during normal operation
    pub fn reset(self: *DescriptorArena) void {
        self.current_offset = 0;
        self.smallest_used_offset = 0;
        self.active_allocations.clearRetainingCapacity();
        self.needs_compaction = false;
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
        self.allocator = allocator;

        // Initialize each frame arena with its frame index
        for (&self.frame_arenas, 0..) |*arena, i| {
            arena.* = try DescriptorArena.init(allocator, DEFAULT_CAPACITY_PER_FRAME, @intCast(i));
        }

        log(.INFO, "texture_descriptor_manager", "TextureDescriptorManager initialized with {} frame arenas ({} descriptors each)", .{
            MAX_FRAMES_IN_FLIGHT,
            DEFAULT_CAPACITY_PER_FRAME,
        });

        return self;
    }

    pub fn deinit(self: *TextureDescriptorManager) void {
        for (&self.frame_arenas) |*arena| {
            arena.deinit();
        }
        self.allocator.destroy(self);
    }

    /// Begin a new frame - compact arenas if needed before allocations
    pub fn beginFrame(self: *TextureDescriptorManager, frame_index: u32) !void {
        if (frame_index >= MAX_FRAMES_IN_FLIGHT) return error.InvalidFrameIndex;
        
        const arena = &self.frame_arenas[frame_index];
        if (arena.needs_compaction) {
            try self.compactFrameArena(frame_index);
        }
    }

    /// Allocate texture descriptors from a specific frame's arena
    /// Copies the source descriptors into the arena and returns offset + slice
    /// The offset is stable and can be used to retrieve descriptors later
    /// Supports wrap-around allocation like BufferManager
    pub fn allocateFromFrame(
        self: *TextureDescriptorManager,
        frame_index: u32,
        source_descriptors: []const vk.DescriptorImageInfo,
    ) !struct { offset: usize, descriptors: []vk.DescriptorImageInfo } {
        if (frame_index >= MAX_FRAMES_IN_FLIGHT) {
            return error.InvalidFrameIndex;
        }

        const arena = &self.frame_arenas[frame_index];
        
        // Allocate with wrap-around support
        const result = try arena.allocate(source_descriptors.len);

        // Copy descriptors into arena memory
        @memcpy(result.slice, source_descriptors);

        return .{
            .offset = result.offset,
            .descriptors = result.slice,
        };
    }

    /// Free a descriptor allocation, updating the arena's smallest_used_offset
    /// Should be called when a ManagedTextureArray is being destroyed or reallocated
    pub fn freeAllocation(self: *TextureDescriptorManager, frame_index: u32, offset: usize) void {
        if (frame_index >= MAX_FRAMES_IN_FLIGHT) return;
        self.frame_arenas[frame_index].freeAllocation(offset);
    }

    /// Reset a frame's arena (for explicit reset only, not called per-frame)
    /// Normally the arena works as a ring buffer with wrap-around
    pub fn resetFrameArena(self: *TextureDescriptorManager, frame_index: u32) void {
        if (frame_index >= MAX_FRAMES_IN_FLIGHT) return;

        self.frame_arenas[frame_index].reset();
    }

    /// Compact a frame's arena by rebuilding it without gaps
    /// Called when arena reports needs_compaction after failed wrap-around
    /// Unlike BufferManager, we don't need to copy GPU data - just rebuild the allocation tracking
    pub fn compactFrameArena(self: *TextureDescriptorManager, frame_index: u32) !void {
        if (frame_index >= MAX_FRAMES_IN_FLIGHT) return error.InvalidFrameIndex;

        const arena = &self.frame_arenas[frame_index];
        
        // For descriptor arenas, compaction is simpler than BufferManager:
        // We don't need to move GPU memory, just rebuild the memory layout
        // and update the offsets in all ManagedTextureArray instances that reference this arena
        //
        // However, we CAN'T easily update the offsets in ManagedTextureArray from here
        // because we don't have references to them.
        //
        // Solution: Just reset the arena and let the next allocation rebuild naturally.
        // The old offsets become invalid, but generation tracking will trigger rebinding.
        log(.WARN, "texture_descriptor_manager", "Frame {} descriptor arena requires compaction - resetting arena (generation tracking will trigger rebinds)", .{frame_index});
        
        arena.reset();
    }

    /// Check if any arenas need compaction and perform it
    /// NOTE: Prefer using beginFrame() for per-frame compaction. This function compacts all
    /// arenas and is useful for manual compaction scenarios.
    pub fn compactArenasIfNeeded(self: *TextureDescriptorManager) !void {
        for (&self.frame_arenas, 0..) |*arena, i| {
            if (arena.needs_compaction) {
                try self.compactFrameArena(@intCast(i));
            }
        }
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
