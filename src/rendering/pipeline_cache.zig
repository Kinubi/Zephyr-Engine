const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("../core/graphics_context.zig").GraphicsContext;
const PipelineBuilder = @import("pipeline_builder.zig").PipelineBuilder;
const log = @import("../utils/log.zig").log;

/// Pipeline cache entry for storing built pipelines
const PipelineCacheEntry = struct {
    pipeline: vk.Pipeline,
    pipeline_layout: vk.PipelineLayout,
    descriptor_set_layout: ?vk.DescriptorSetLayout,
    hash: u64,
    usage_count: u32 = 0,
    last_used_frame: u32 = 0,
};

/// Pipeline configuration hash for caching
const PipelineConfig = struct {
    shaders: []const []const u8, // Shader names/paths for hashing
    vertex_format: u64, // Hash of vertex input layout
    render_state: u64, // Hash of rasterization/blend/depth state
    descriptor_layout: u64, // Hash of descriptor bindings
    render_pass_hash: u64, // Hash of render pass compatibility

    pub fn hash(self: PipelineConfig) u64 {
        var hasher = std.hash.Wyhash.init(0);

        // Hash shader names
        for (self.shaders) |shader_name| {
            hasher.update(shader_name);
        }

        // Hash other components
        hasher.update(std.mem.asBytes(&self.vertex_format));
        hasher.update(std.mem.asBytes(&self.render_state));
        hasher.update(std.mem.asBytes(&self.descriptor_layout));
        hasher.update(std.mem.asBytes(&self.render_pass_hash));

        return hasher.final();
    }
};

/// Pipeline cache for storing and reusing pipelines
pub const PipelineCache = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    graphics_context: *GraphicsContext,
    cache: std.AutoHashMap(u64, PipelineCacheEntry),
    vulkan_cache: vk.PipelineCache,
    current_frame: u32 = 0,

    // Statistics
    cache_hits: u32 = 0,
    cache_misses: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, graphics_context: *GraphicsContext) !Self {
        return try initWithCache(allocator, graphics_context, "cache/pipeline_cache.bin");
    }

    /// Initialize pipeline cache and optionally load from disk
    pub fn initWithCache(allocator: std.mem.Allocator, graphics_context: *GraphicsContext, cache_path: []const u8) !Self {
        // Try to load existing cache data
        var cache_data: ?[]u8 = null;
        defer if (cache_data) |data| allocator.free(data);

        // Attempt to load cache from disk
        if (std.fs.cwd().openFile(cache_path, .{})) |file| {
            defer file.close();
            cache_data = file.readToEndAlloc(allocator, 100 * 1024 * 1024) catch |err| blk: { // 100MB max
                log(.WARN, "pipeline_cache", "Failed to read cache file: {}", .{err});
                break :blk null;
            };
            
            if (cache_data) |data| {
                log(.INFO, "pipeline_cache", "✅ Loaded pipeline cache from disk ({} bytes)", .{data.len});
            }
        } else |err| {
            if (err != error.FileNotFound) {
                log(.WARN, "pipeline_cache", "Failed to open cache file: {}", .{err});
            } else {
                log(.INFO, "pipeline_cache", "No existing pipeline cache found, creating new cache", .{});
            }
        }

        // Create Vulkan pipeline cache with loaded data
        const cache_create_info = vk.PipelineCacheCreateInfo{
            .initial_data_size = if (cache_data) |data| data.len else 0,
            .p_initial_data = if (cache_data) |data| data.ptr else null,
        };

        const vulkan_cache = try graphics_context.vkd.createPipelineCache(graphics_context.dev, &cache_create_info, null);

        return Self{
            .allocator = allocator,
            .graphics_context = graphics_context,
            .cache = std.AutoHashMap(u64, PipelineCacheEntry).init(allocator),
            .vulkan_cache = vulkan_cache,
        };
    }

    pub fn deinit(self: *Self) void {
        // Save cache to disk before cleanup
        self.saveToDisk("cache/pipeline_cache.bin") catch |err| {
            log(.WARN, "pipeline_cache", "Failed to save pipeline cache: {}", .{err});
        };

        // Destroy all cached pipelines
        var iterator = self.cache.iterator();
        while (iterator.next()) |entry| {
            self.graphics_context.vkd.destroyPipeline(self.graphics_context.dev, entry.value_ptr.pipeline, null);
            self.graphics_context.vkd.destroyPipelineLayout(self.graphics_context.dev, entry.value_ptr.pipeline_layout, null);
            if (entry.value_ptr.descriptor_set_layout) |layout| {
                self.graphics_context.vkd.destroyDescriptorSetLayout(self.graphics_context.dev, layout, null);
            }
        }

        self.cache.deinit();
        self.graphics_context.vkd.destroyPipelineCache(self.graphics_context.dev, self.vulkan_cache, null);
    }

    /// Get or create a pipeline using the builder
    pub fn getOrCreatePipeline(self: *Self, builder: *PipelineBuilder, config_hash: u64) !PipelineCacheEntry {
        self.current_frame += 1;

        if (self.cache.getPtr(config_hash)) |entry| {
            // Cache hit
            self.cache_hits += 1;
            entry.usage_count += 1;
            entry.last_used_frame = self.current_frame;
            
            log(.DEBUG, "pipeline_cache", "✅ Cache HIT for pipeline hash: 0x{X} (usage: {})", .{ config_hash, entry.usage_count });
            
            return entry.*;
        }

        // Cache miss - build new pipeline
        self.cache_misses += 1;
        
        log(.INFO, "pipeline_cache", "⚙️  Cache MISS - building new pipeline (hash: 0x{X})", .{config_hash});

        // Build descriptor set layout
        const descriptor_set_layout = if (builder.descriptor_bindings.items.len > 0)
            try builder.buildDescriptorSetLayout()
        else
            null;

        // Build pipeline layout
        const layouts = if (descriptor_set_layout) |layout| [_]vk.DescriptorSetLayout{layout} else [_]vk.DescriptorSetLayout{};
        const pipeline_layout = try builder.buildPipelineLayout(layouts[0..]);

        // Build pipeline based on type
        const pipeline = switch (builder.pipeline_type) {
            .graphics => try builder.buildGraphicsPipeline(pipeline_layout),
            .compute => try builder.buildComputePipeline(pipeline_layout),
            .raytracing => try builder.buildRaytracingPipeline(pipeline_layout),
        };

        // Cache the pipeline
        const entry = PipelineCacheEntry{
            .pipeline = pipeline,
            .pipeline_layout = pipeline_layout,
            .descriptor_set_layout = descriptor_set_layout,
            .hash = config_hash,
            .usage_count = 1,
            .last_used_frame = self.current_frame,
        };

        try self.cache.put(config_hash, entry);
        
        log(.INFO, "pipeline_cache", "✅ Pipeline cached (hash: 0x{X}, type: {s})", .{ 
            config_hash, 
            @tagName(builder.pipeline_type) 
        });
        
        return entry;
    }

    /// Create a configuration hash from builder state
    pub fn createConfigHash(self: *Self, builder: *PipelineBuilder) !u64 {

        // Collect shader names/paths for hashing
        var shader_names = std.ArrayList([]const u8).init(self.allocator);
        defer shader_names.deinit();

        for (builder.shader_stages.items) |stage| {
            // Use shader module handle as identifier
            const handle_str = try std.fmt.allocPrint(self.allocator, "{x}", .{@intFromPtr(stage.shader.module.handle)});
            defer self.allocator.free(handle_str);
            try shader_names.append(handle_str);
        }

        // Hash vertex format
        var vertex_hasher = std.hash.Wyhash.init(1);
        for (builder.vertex_bindings.items) |binding| {
            vertex_hasher.update(std.mem.asBytes(&binding));
        }
        for (builder.vertex_attributes.items) |attribute| {
            vertex_hasher.update(std.mem.asBytes(&attribute));
        }
        const vertex_format_hash = vertex_hasher.final();

        // Hash render state
        var state_hasher = std.hash.Wyhash.init(2);
        state_hasher.update(std.mem.asBytes(&builder.rasterization_state));
        state_hasher.update(std.mem.asBytes(&builder.multisample_state));
        state_hasher.update(std.mem.asBytes(&builder.depth_stencil_state));
        for (builder.color_blend_attachments.items) |attachment| {
            state_hasher.update(std.mem.asBytes(&attachment));
        }
        const render_state_hash = state_hasher.final();

        // Hash descriptor layout
        var desc_hasher = std.hash.Wyhash.init(3);
        for (builder.descriptor_bindings.items) |binding| {
            desc_hasher.update(std.mem.asBytes(&binding));
        }
        for (builder.push_constant_ranges.items) |range| {
            desc_hasher.update(std.mem.asBytes(&range));
        }
        const descriptor_layout_hash = desc_hasher.final();

        // Hash render pass compatibility
        const render_pass_hash = if (builder.render_pass) |rp|
            @intFromPtr(rp.handle)
        else
            0;

        const config = PipelineConfig{
            .shaders = shader_names.items,
            .vertex_format = vertex_format_hash,
            .render_state = render_state_hash,
            .descriptor_layout = descriptor_layout_hash,
            .render_pass_hash = render_pass_hash,
        };

        return config.hash();
    }

    /// Garbage collect unused pipelines
    pub fn garbageCollect(self: *Self, max_unused_frames: u32) !void {
        var to_remove = std.ArrayList(u64).init(self.allocator);
        defer to_remove.deinit();

        var iterator = self.cache.iterator();
        while (iterator.next()) |entry| {
            const frames_unused = self.current_frame - entry.value_ptr.last_used_frame;
            if (frames_unused > max_unused_frames) {
                try to_remove.append(entry.key_ptr.*);
            }
        }

        for (to_remove.items) |hash| {
            if (self.cache.fetchRemove(hash)) |entry| {
                self.graphics_context.vkd.destroyPipeline(self.graphics_context.dev, entry.value.pipeline, null);
                self.graphics_context.vkd.destroyPipelineLayout(self.graphics_context.dev, entry.value.pipeline_layout, null);
                if (entry.value.descriptor_set_layout) |layout| {
                    self.graphics_context.vkd.destroyDescriptorSetLayout(self.graphics_context.dev, layout, null);
                }
            }
        }
    }

    /// Save cache data to disk for faster startup
    pub fn saveToDisk(self: *Self, path: []const u8) !void {
        // Ensure cache directory exists
        const cache_dir = std.fs.path.dirname(path) orelse ".";
        std.fs.cwd().makePath(cache_dir) catch |err| {
            if (err != error.PathAlreadyExists) {
                log(.ERROR, "pipeline_cache", "Failed to create cache directory: {}", .{err});
                return err;
            }
        };

        var cache_size: usize = undefined;
        _ = try self.graphics_context.vkd.getPipelineCacheData(self.graphics_context.dev, self.vulkan_cache, &cache_size, null);

        if (cache_size > 0) {
            const cache_data = try self.allocator.alloc(u8, cache_size);
            defer self.allocator.free(cache_data);

            _ = try self.graphics_context.vkd.getPipelineCacheData(self.graphics_context.dev, self.vulkan_cache, &cache_size, cache_data.ptr);

            const file = try std.fs.cwd().createFile(path, .{});
            defer file.close();

            try file.writeAll(cache_data);
            
            log(.INFO, "pipeline_cache", "💾 Saved pipeline cache to disk: {} bytes at {s}", .{ cache_size, path });
        } else {
            log(.DEBUG, "pipeline_cache", "No cache data to save", .{});
        }
    }

    /// Load cache data from disk
    pub fn loadFromDisk(self: *Self, path: []const u8) !void {
        const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                log(.INFO, "pipeline_cache", "No cache file found at {s}", .{path});
                return; // No cache file exists yet
            },
            else => {
                log(.WARN, "pipeline_cache", "Failed to open cache file: {}", .{err});
                return err;
            },
        };
        defer file.close();

        const cache_data = try file.readToEndAlloc(self.allocator, std.math.maxInt(usize));
        defer self.allocator.free(cache_data);

        // Destroy old cache and create new one with data
        self.graphics_context.vkd.destroyPipelineCache(self.graphics_context.dev, self.vulkan_cache, null);

        const cache_create_info = vk.PipelineCacheCreateInfo{
            .initial_data_size = cache_data.len,
            .p_initial_data = cache_data.ptr,
        };

        self.vulkan_cache = try self.graphics_context.vkd.createPipelineCache(self.graphics_context.dev, &cache_create_info, null);
        
        log(.INFO, "pipeline_cache", "📂 Loaded pipeline cache from disk: {} bytes", .{cache_data.len});
    }

    /// Get cache statistics
    pub fn getStatistics(self: *const Self) struct {
        total_pipelines: usize,
        cache_hits: u32,
        cache_misses: u32,
        hit_ratio: f32,
    } {
        const total_requests = self.cache_hits + self.cache_misses;
        const hit_ratio = if (total_requests > 0) @as(f32, @floatFromInt(self.cache_hits)) / @as(f32, @floatFromInt(total_requests)) else 0.0;

        return .{
            .total_pipelines = self.cache.count(),
            .cache_hits = self.cache_hits,
            .cache_misses = self.cache_misses,
            .hit_ratio = hit_ratio,
        };
    }

    /// Print debug information
    pub fn printDebugInfo(self: *const Self) void {
        const stats = self.getStatistics();
        log(.DEBUG, "pipeline_cache", "=== Pipeline Cache Debug Info ===", .{});
        log(.DEBUG, "pipeline_cache", "Total Pipelines: {d}", .{stats.total_pipelines});
        log(.DEBUG, "pipeline_cache", "Cache Hits: {d}", .{stats.cache_hits});
        log(.DEBUG, "pipeline_cache", "Cache Misses: {d}", .{stats.cache_misses});
        log(.DEBUG, "pipeline_cache", "Hit Ratio: {d:.2}%", .{stats.hit_ratio * 100.0});

        log(.DEBUG, "pipeline_cache", "Pipeline Details:", .{});
        var iterator = self.cache.iterator();
        while (iterator.next()) |entry| {
            const pipeline_entry = entry.value_ptr.*;
            log(.DEBUG, "pipeline_cache", "  Hash: 0x{X}, Usage: {d}, Last Frame: {d}", .{
                pipeline_entry.hash,
                pipeline_entry.usage_count,
                pipeline_entry.last_used_frame,
            });
        }
    }
};
