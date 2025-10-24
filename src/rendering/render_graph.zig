const std = @import("std");
const vk = @import("vulkan");
const log = @import("../utils/log.zig").log;
const FrameInfo = @import("frameinfo.zig").FrameInfo;
const GraphicsContext = @import("../core/graphics_context.zig").GraphicsContext;

const Allocator = std.mem.Allocator;

/// Unique identifier for resources (render targets, depth buffers, etc.)
pub const ResourceId = enum(u32) {
    invalid = 0,
    _,

    pub fn fromInt(value: u32) ResourceId {
        return @enumFromInt(value);
    }

    pub fn toInt(self: ResourceId) u32 {
        return @intFromEnum(self);
    }
};

/// Types of resources managed by the render graph
pub const ResourceType = enum {
    render_target, // Color attachment
    depth_buffer, // Depth/stencil attachment
};

/// Resource handle stored in the registry
pub const Resource = struct {
    id: ResourceId,
    type: ResourceType,
    name: []const u8,
    format: vk.Format,

    // Image resources
    image: vk.Image = .null_handle,
    view: vk.ImageView = .null_handle,
    memory: vk.DeviceMemory = .null_handle,

    // Size info
    width: u32 = 0,
    height: u32 = 0,
};

/// Registry for render graph resources
pub const ResourceRegistry = struct {
    allocator: Allocator,
    resources: std.ArrayList(Resource),
    name_to_id: std.StringHashMap(ResourceId),
    next_id: u32,

    pub fn init(allocator: Allocator) ResourceRegistry {
        return ResourceRegistry{
            .allocator = allocator,
            .resources = std.ArrayList(Resource){},
            .name_to_id = std.StringHashMap(ResourceId).init(allocator),
            .next_id = 1, // 0 is invalid
        };
    }

    pub fn deinit(self: *ResourceRegistry) void {
        // Note: Resource cleanup (vkDestroyImage, etc.) should happen elsewhere
        // This just cleans up the registry data structures
        self.resources.deinit(self.allocator);
        self.name_to_id.deinit();
    }

    /// Register a new resource
    pub fn registerResource(
        self: *ResourceRegistry,
        name: []const u8,
        resource_type: ResourceType,
        format: vk.Format,
    ) !ResourceId {
        const id = ResourceId.fromInt(self.next_id);
        self.next_id += 1;

        const resource = Resource{
            .id = id,
            .type = resource_type,
            .name = name,
            .format = format,
        };

        try self.resources.append(self.allocator, resource);
        try self.name_to_id.put(name, id);

        log(.INFO, "resource_registry", "Registered {s}: {s} (format: {})", .{ @tagName(resource_type), name, format });
        return id;
    }

    /// Get resource by ID
    pub fn getResource(self: *ResourceRegistry, id: ResourceId) ?*Resource {
        for (self.resources.items) |*resource| {
            if (resource.id.toInt() == id.toInt()) {
                return resource;
            }
        }
        return null;
    }

    /// Get resource by name
    pub fn getResourceByName(self: *ResourceRegistry, name: []const u8) ?*Resource {
        if (self.name_to_id.get(name)) |id| {
            return self.getResource(id);
        }
        return null;
    }

    /// Update resource image handles (called when images are created)
    pub fn updateResourceImage(
        self: *ResourceRegistry,
        id: ResourceId,
        image: vk.Image,
        view: vk.ImageView,
        memory: vk.DeviceMemory,
        width: u32,
        height: u32,
    ) !void {
        if (self.getResource(id)) |resource| {
            resource.image = image;
            resource.view = view;
            resource.memory = memory;
            resource.width = width;
            resource.height = height;
        } else {
            return error.ResourceNotFound;
        }
    }
};

/// Virtual method table for RenderPass
pub const RenderPassVTable = struct {
    /// Setup resources and declare dependencies
    setup: *const fn (pass: *RenderPass, graph: *RenderGraph) anyerror!void,

    /// Update pass state each frame (e.g., BVH rebuilds, descriptor updates)
    update: *const fn (pass: *RenderPass, frame_info: *const FrameInfo) anyerror!void,

    /// Execute the pass (record commands)
    execute: *const fn (pass: *RenderPass, frame_info: FrameInfo) anyerror!void,

    /// Cleanup resources
    teardown: *const fn (pass: *RenderPass) void,
};

/// Base interface for render passes
pub const RenderPass = struct {
    name: []const u8,
    enabled: bool = true,
    vtable: *const RenderPassVTable,

    // Dependencies: names of passes this pass depends on (must execute after)
    dependencies: std.ArrayList([]const u8),

    /// Call setup through vtable
    pub fn setup(self: *RenderPass, graph: *RenderGraph) !void {
        return self.vtable.setup(self, graph);
    }

    /// Call update through vtable
    pub fn update(self: *RenderPass, frame_info: *const FrameInfo) !void {
        return self.vtable.update(self, frame_info);
    }

    /// Call execute through vtable
    pub fn execute(self: *RenderPass, frame_info: FrameInfo) !void {
        return self.vtable.execute(self, frame_info);
    }

    /// Call teardown through vtable
    pub fn teardown(self: *RenderPass) void {
        self.vtable.teardown(self);
    }

    /// Check if this is a compute pass by name convention
    pub fn isComputePass(self: *const RenderPass) bool {
        return std.mem.indexOf(u8, self.name, "compute") != null;
    }
};

/// RenderGraph manages a DAG of render passes for a scene
pub const RenderGraph = struct {
    allocator: Allocator,
    graphics_context: *GraphicsContext,

    // All passes (including disabled)
    passes: std.ArrayList(*RenderPass),

    // Compiled execution order (only enabled passes, topologically sorted)
    execution_order: std.ArrayList(*RenderPass),

    // Resource registry (render targets, depth buffers, etc)
    resources: ResourceRegistry,

    // Graph state
    compiled: bool = false,

    pub fn init(allocator: Allocator, graphics_context: *GraphicsContext) RenderGraph {
        log(.INFO, "render_graph", "Creating render graph", .{});
        return RenderGraph{
            .allocator = allocator,
            .graphics_context = graphics_context,
            .passes = std.ArrayList(*RenderPass){},
            .execution_order = std.ArrayList(*RenderPass){},
            .resources = ResourceRegistry.init(allocator),
            .compiled = false,
        };
    }

    pub fn deinit(self: *RenderGraph) void {
        log(.INFO, "render_graph", "Destroying render graph ({} passes)", .{self.passes.items.len});

        // Teardown all passes
        for (self.passes.items) |pass| {
            pass.teardown();
        }

        self.passes.deinit(self.allocator);
        self.execution_order.deinit(self.allocator);
        self.resources.deinit();
    }

    /// Add a pass to the graph
    pub fn addPass(self: *RenderGraph, pass: *RenderPass) !void {
        try self.passes.append(self.allocator, pass);
        self.compiled = false; // Need to recompile
        log(.INFO, "render_graph", "Added pass: {s}", .{pass.name});
    }

    /// Compile the graph: setup passes, validate dependencies, determine execution order
    pub fn compile(self: *RenderGraph) !void {
        log(.INFO, "render_graph", "Compiling render graph with {} passes", .{self.passes.items.len});

        // Call setup on all passes to register resources
        for (self.passes.items) |pass| {
            try pass.setup(self);
        }

        // Build execution order using topological sort (only enabled passes)
        try self.buildExecutionOrder();

        self.compiled = true;
        log(.INFO, "render_graph", "Render graph compiled successfully ({} enabled passes)", .{self.execution_order.items.len});
    }

    /// Build execution order using topological sort (Kahn's algorithm)
    /// Only includes enabled passes in the execution order
    fn buildExecutionOrder(self: *RenderGraph) !void {
        self.execution_order.clearRetainingCapacity();

        // Filter to only enabled passes
        var enabled_passes = std.ArrayList(*RenderPass){};
        defer enabled_passes.deinit(self.allocator);

        for (self.passes.items) |pass| {
            if (pass.enabled) {
                try enabled_passes.append(self.allocator, pass);
            }
        }

        if (enabled_passes.items.len == 0) {
            log(.WARN, "render_graph", "No enabled passes in graph", .{});
            return;
        }

        // Build dependency graph for enabled passes only
        // Count incoming edges for each pass
        var in_degree = std.StringHashMap(usize).init(self.allocator);
        defer in_degree.deinit();

        // Initialize in-degree for all enabled passes
        for (enabled_passes.items) |pass| {
            try in_degree.put(pass.name, 0);
        }

        // Count dependencies (only from enabled passes to enabled passes)
        for (enabled_passes.items) |pass| {
            for (pass.dependencies.items) |dep_name| {
                // Only count if dependency is also enabled
                if (self.getPass(dep_name)) |dep_pass| {
                    if (dep_pass.enabled) {
                        const current = in_degree.get(pass.name) orelse 0;
                        try in_degree.put(pass.name, current + 1);
                    }
                }
            }
        }

        // Queue for passes with no dependencies
        var queue = std.ArrayList(*RenderPass){};
        defer queue.deinit(self.allocator);

        // Add all passes with in-degree 0
        for (enabled_passes.items) |pass| {
            const degree = in_degree.get(pass.name) orelse 0;
            if (degree == 0) {
                try queue.append(self.allocator, pass);
            }
        }

        // Process queue
        while (queue.items.len > 0) {
            const current = queue.orderedRemove(0);
            try self.execution_order.append(self.allocator, current);

            // For each enabled pass that depends on current
            for (enabled_passes.items) |pass| {
                if (!pass.enabled) continue;

                // Check if this pass depends on current
                var depends_on_current = false;
                for (pass.dependencies.items) |dep_name| {
                    if (std.mem.eql(u8, dep_name, current.name)) {
                        depends_on_current = true;
                        break;
                    }
                }

                if (depends_on_current) {
                    const degree = in_degree.get(pass.name) orelse 0;
                    if (degree > 0) {
                        const new_degree = degree - 1;
                        try in_degree.put(pass.name, new_degree);
                        if (new_degree == 0) {
                            try queue.append(self.allocator, pass);
                        }
                    }
                }
            }
        }

        // Check for cycles
        if (self.execution_order.items.len != enabled_passes.items.len) {
            log(.ERROR, "render_graph", "Cycle detected in render graph dependencies!", .{});
            return error.CyclicDependency;
        }

        log(.INFO, "render_graph", "Execution order built: {} passes", .{self.execution_order.items.len});
    }

    /// Update all enabled passes (call each frame before execute)
    pub fn update(self: *RenderGraph, frame_info: *const FrameInfo) !void {
        if (!self.compiled) {
            return error.GraphNotCompiled;
        }

        for (self.execution_order.items) |pass| {
            // Create update pass name with suffix
            var name_buf: [64]u8 = undefined;
            const update_name = std.fmt.bufPrint(&name_buf, "{s}_update", .{pass.name}) catch pass.name;

            if (frame_info.performance_monitor) |pm| {
                try pm.beginPass(update_name, frame_info.current_frame, frame_info.command_buffer);
            }

            try pass.update(frame_info);

            if (frame_info.performance_monitor) |pm| {
                try pm.endPass(update_name, frame_info.current_frame, frame_info.command_buffer);
            }
        }
    }

    /// Execute all enabled passes
    pub fn execute(self: *RenderGraph, frame_info: FrameInfo) !void {
        if (!self.compiled) {
            return error.GraphNotCompiled;
        }

        for (self.execution_order.items) |pass| {
            if (frame_info.performance_monitor) |pm| {
                try pm.beginPass(pass.name, frame_info.current_frame, frame_info.command_buffer);
            }
            try pass.execute(frame_info);
            if (frame_info.performance_monitor) |pm| {
                try pm.endPass(pass.name, frame_info.current_frame, frame_info.command_buffer);
            }
        }
    }

    /// Enable a pass by name (doesn't recompile - call recompile() after all state changes)
    pub fn enablePass(self: *RenderGraph, name: []const u8) void {
        for (self.passes.items) |pass| {
            if (std.mem.eql(u8, pass.name, name)) {
                if (!pass.enabled) {
                    pass.enabled = true;
                    self.compiled = false; // Mark as needing recompilation
                }
                return;
            }
        }
        log(.WARN, "render_graph", "Pass not found: {s}", .{name});
    }

    /// Disable a pass by name (doesn't recompile - call recompile() after all state changes)
    pub fn disablePass(self: *RenderGraph, name: []const u8) void {
        for (self.passes.items) |pass| {
            if (std.mem.eql(u8, pass.name, name)) {
                if (pass.enabled) {
                    pass.enabled = false;
                    self.compiled = false; // Mark as needing recompilation
                }
                return;
            }
        }
        log(.WARN, "render_graph", "Pass not found: {s}", .{name});
    }

    /// Recompile the execution order (call after changing pass enabled states)
    pub fn recompile(self: *RenderGraph) !void {
        if (!self.compiled) {
            log(.INFO, "render_graph", "Recompiling execution order", .{});
            try self.buildExecutionOrder();
            self.compiled = true;
        }
    }

    /// Get a pass by name
    pub fn getPass(self: *RenderGraph, name: []const u8) ?*RenderPass {
        for (self.passes.items) |pass| {
            if (std.mem.eql(u8, pass.name, name)) {
                return pass;
            }
        }
        return null;
    }
};
