const std = @import("std");
const PipelineBuilder = @import("pipeline_builder.zig").PipelineBuilder;
const PipelineBuilders = @import("pipeline_builder.zig").PipelineBuilders;
const PipelineCache = @import("pipeline_cache.zig").PipelineCache;
const RenderPass = @import("render_pass.zig").RenderPass;
const RenderContext = @import("render_pass.zig").RenderContext;
const PassConfig = @import("render_pass.zig").PassConfig;
const PassType = @import("render_pass.zig").PassType;
const PassPriority = @import("render_pass.zig").PassPriority;

/// Example geometry pass using the pipeline builder
pub const ModernGeometryPass = struct {
    const Self = @This();

    name: []const u8,
    pipeline_builder: *PipelineBuilder = undefined,
    pipeline_cache: *PipelineCache,

    pub fn init(self: *Self, graphics_context: anytype, pipeline_cache: *PipelineCache, vertex_shader: anytype, fragment_shader: anytype) !void {
        _ = graphics_context;
        self.pipeline_cache = pipeline_cache;

        // This would normally get the builder from a factory or create it
        // For demo purposes, we'll show the configuration
        std.log.info("ModernGeometryPass: Initialized with pipeline builder", .{});
        std.log.info("  - Vertex Shader: {any}", .{vertex_shader});
        std.log.info("  - Fragment Shader: {any}", .{fragment_shader});
        std.log.info("  - Pipeline cache ready for dynamic creation", .{});
    }

    pub fn execute(self: *Self, context: RenderContext) !void {
        std.log.info("ModernGeometryPass: Executing frame {d}", .{context.frame_index});

        // Get rasterization data
        const raster_data = context.scene_view.getRasterizationData();
        std.log.info("  - Processing {d} objects with modern pipeline", .{raster_data.objects.len});

        // Example: Pipeline would be retrieved from cache based on current state
        std.log.info("  - Pipeline retrieved from cache (hit ratio: {d:.1}%)", .{self.pipeline_cache.getStatistics().hit_ratio * 100.0});

        // Render objects with pipeline
        for (raster_data.getVisibleObjects()) |obj| {
            std.log.info("    Rendering object with material {d}, texture {d}", .{ obj.material_index, obj.texture_index });
        }
    }

    pub fn deinit(self: *Self) void {
        _ = self;
        std.log.info("ModernGeometryPass: Deinitialized", .{});
    }
};

/// Example compute pass using pipeline builder
pub const ModernComputePass = struct {
    const Self = @This();

    name: []const u8,
    pipeline_cache: *PipelineCache,

    pub fn init(self: *Self, graphics_context: anytype, pipeline_cache: *PipelineCache, compute_shader: anytype) !void {
        _ = graphics_context;
        _ = compute_shader;
        self.pipeline_cache = pipeline_cache;
        std.log.info("ModernComputePass: Initialized with pipeline builder", .{});
    }

    pub fn execute(self: *Self, context: RenderContext) !void {
        std.log.info("ModernComputePass: Executing frame {d} with pipeline cache hit rate: {d:.1}%", .{ context.frame_index, self.pipeline_cache.getHitRate() * 100.0 });

        const compute_data = context.scene_view.getComputeData();
        std.log.info("  - Processing {d} particle systems", .{compute_data.particle_systems.len});

        for (compute_data.getActiveParticleSystems()) |system| {
            std.log.info("    Updating {d} particles", .{system.particle_count});
        }
    }

    pub fn deinit(self: *Self) void {
        _ = self;
        std.log.info("ModernComputePass: Deinitialized", .{});
    }
};

/// Demonstrate pipeline builder integration with render passes
pub fn demonstratePipelineBuilderIntegration(allocator: std.mem.Allocator) !void {
    std.log.info("Pipeline Builder Integration Demo");

    // Demonstrate allocator usage for dynamic data
    const buffer = try allocator.alloc(u8, 1024);
    defer allocator.free(buffer);

    std.log.info("Allocated {d} bytes for pipeline data", .{buffer.len});

    // Show how different passes can use the builder
    // This would be called during pass initialization
    std.log.info("Pipeline building demo complete - see pipeline_builder.zig for actual implementation");
}

/// Test the pipeline builder system
pub fn testPipelineBuilder() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try demonstratePipelineBuilderIntegration(allocator);
}
