const std = @import("std");
const RenderPass = @import("render_pass.zig").RenderPass;
const RenderGraph = @import("render_graph.zig").RenderGraph;
const RenderContext = @import("render_pass.zig").RenderContext;
const PassConfig = @import("render_pass.zig").PassConfig;
const PassType = @import("render_pass.zig").PassType;
const PassPriority = @import("render_pass.zig").PassPriority;
const ResourceBinding = @import("render_pass.zig").ResourceBinding;
const ResourceAccess = @import("render_pass.zig").ResourceAccess;
const ResourceTracker = @import("resource_tracker.zig").ResourceTracker;
const SceneView = @import("render_pass.zig").SceneView;
const log = @import("../utils/log.zig").log;

/// Example geometry pass implementation
pub const GeometryPass = struct {
    const Self = @This();

    name: []const u8,

    pub fn init(self: *Self, graphics_context: anytype) !void {
        _ = self;
        _ = graphics_context;
        log(.INFO, "render_pass_demo", "GeometryPass: Initialized", .{});
    }

    pub fn execute(self: *Self, context: RenderContext) !void {
        _ = self;
        log(.INFO, "render_pass_demo", "GeometryPass: Executing frame {d}", .{context.frame_index});

        // Get rasterization data from scene
        const raster_data = context.scene_view.getRasterizationData();
        log(.INFO, "render_pass_demo", "GeometryPass: Processing {d} objects", .{raster_data.objects.len});
    }

    pub fn deinit(self: *Self) void {
        _ = self;
        log(.INFO, "render_pass_demo", "GeometryPass: Deinitialized", .{});
    }

    pub fn getResourceRequirements(self: *Self) []const ResourceBinding {
        _ = self;
        const bindings = [_]ResourceBinding{
            .{ .resource_name = "color_buffer", .access = .write, .stage = .{ .color_attachment_output_bit = true } },
            .{ .resource_name = "depth_buffer", .access = .write, .stage = .{ .early_fragment_tests_bit = true } },
        };
        return &bindings;
    }
};

/// Example lighting pass implementation
pub const LightingPass = struct {
    const Self = @This();

    name: []const u8,

    pub fn init(self: *Self, graphics_context: anytype) !void {
        _ = self;
        _ = graphics_context;
        log(.INFO, "render_pass_demo", "LightingPass: Initialized", .{});
    }

    pub fn execute(self: *Self, context: RenderContext) !void {
        _ = self;
        log(.INFO, "render_pass_demo", "LightingPass: Executing frame {d}", .{context.frame_index});

        // Access geometry buffer from previous pass
        const raster_data = context.scene_view.getRasterizationData();
        log(.INFO, "render_pass_demo", "LightingPass: Using {d} materials", .{raster_data.materials.len});
    }

    pub fn deinit(self: *Self) void {
        _ = self;
        log(.INFO, "render_pass_demo", "LightingPass: Deinitialized", .{});
    }

    pub fn getResourceRequirements(self: *Self) []const ResourceBinding {
        _ = self;
        const bindings = [_]ResourceBinding{
            .{ .resource_name = "color_buffer", .access = .read, .stage = .{ .fragment_shader_bit = true } },
            .{ .resource_name = "depth_buffer", .access = .read, .stage = .{ .fragment_shader_bit = true } },
            .{ .resource_name = "final_color", .access = .write, .stage = .{ .color_attachment_output_bit = true } },
        };
        return &bindings;
    }
};

/// Example post-processing pass
pub const PostProcessPass = struct {
    const Self = @This();

    name: []const u8,

    pub fn init(self: *Self, graphics_context: anytype) !void {
        _ = self;
        _ = graphics_context;
        log(.INFO, "render_pass_demo", "PostProcessPass: Initialized", .{});
    }

    pub fn execute(self: *Self, context: RenderContext) !void {
        _ = self;
        log(.INFO, "render_pass_demo", "PostProcessPass: Executing frame {d}", .{context.frame_index});
    }

    pub fn deinit(self: *Self) void {
        _ = self;
        log(.INFO, "render_pass_demo", "PostProcessPass: Deinitialized", .{});
    }

    pub fn getResourceRequirements(self: *Self) []const ResourceBinding {
        _ = self;
        const bindings = [_]ResourceBinding{
            .{ .resource_name = "final_color", .access = .read, .stage = .{ .fragment_shader_bit = true } },
            .{ .resource_name = "swapchain", .access = .write, .stage = .{ .color_attachment_output_bit = true } },
        };
        return &bindings;
    }
};

/// Demonstrate the Week 1 render pass architecture
pub fn demonstrateRenderPassArchitecture(allocator: std.mem.Allocator) !void {
    log(.INFO, "render_pass_demo", "=== Week 1: Render Pass Architecture Demo ===", .{});

    // Initialize render graph
    var render_graph = RenderGraph.init(allocator);
    defer render_graph.deinit();

    // Create pass implementations
    var geometry_pass = GeometryPass{ .name = "GeometryPass" };
    var lighting_pass = LightingPass{ .name = "LightingPass" };
    var post_process_pass = PostProcessPass{ .name = "PostProcessPass" };

    // Create render pass configs
    const geometry_config = PassConfig{
        .name = "geometry",
        .pass_type = .rasterization,
        .priority = .geometry,
        .resource_bindings = geometry_pass.getResourceRequirements(),
    };

    const lighting_config = PassConfig{
        .name = "lighting",
        .pass_type = .rasterization,
        .priority = .lighting,
        .resource_bindings = lighting_pass.getResourceRequirements(),
    };

    const post_process_config = PassConfig{
        .name = "post_process",
        .pass_type = .rasterization,
        .priority = .post_process,
        .resource_bindings = post_process_pass.getResourceRequirements(),
    };

    // Add passes to render graph
    const geometry_handle = try render_graph.addPass(RenderPass.create(GeometryPass, &geometry_pass, geometry_config));
    const lighting_handle = try render_graph.addPass(RenderPass.create(LightingPass, &lighting_pass, lighting_config));
    const post_process_handle = try render_graph.addPass(RenderPass.create(PostProcessPass, &post_process_pass, post_process_config));

    // Set up dependencies
    try render_graph.addResourceDependency(geometry_handle, lighting_handle, "color_buffer");
    try render_graph.addResourceDependency(lighting_handle, post_process_handle, "final_color");

    // Validate the graph
    const is_valid = try render_graph.validate();
    log(.INFO, "render_pass_demo", "Render graph validation: {}", .{is_valid});

    // Print debug information
    render_graph.printDebugInfo();

    // Build execution order
    try render_graph.buildExecutionOrder();

    // Simulate frame execution (without actual Vulkan context)
    log(.INFO, "render_pass_demo", "\n=== Simulating Frame Execution ===", .{});
    // Note: This would normally require a proper RenderContext with Vulkan objects
    // For now, we'll just demonstrate the structure

    log(.INFO, "render_pass_demo", "Week 1 implementation complete!", .{});
    log(.INFO, "render_pass_demo", "✅ RenderPass trait/interface system with VTable", .{});
    log(.INFO, "render_pass_demo", "✅ RenderGraph with dependency tracking and topological sorting", .{});
    log(.INFO, "render_pass_demo", "✅ SceneView abstraction for pass-specific data extraction", .{});
    log(.INFO, "render_pass_demo", "✅ ResourceTracker for automatic GPU resource management", .{});
}

/// Test the render pass architecture
pub fn testRenderPassArchitecture() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try demonstrateRenderPassArchitecture(allocator);
}
