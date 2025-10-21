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
            log(.DEBUG, "resource_registry", "Updated resource image: {s} ({}x{})", .{ resource.name, width, height });
        } else {
            return error.ResourceNotFound;
        }
    }
};

/// Virtual method table for RenderPass
pub const RenderPassVTable = struct {
    /// Setup resources and declare dependencies
    setup: *const fn (pass: *RenderPass, graph: *RenderGraph) anyerror!void,

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

    /// Call setup through vtable
    pub fn setup(self: *RenderPass, graph: *RenderGraph) !void {
        return self.vtable.setup(self, graph);
    }

    /// Call execute through vtable
    pub fn execute(self: *RenderPass, frame_info: FrameInfo) !void {
        return self.vtable.execute(self, frame_info);
    }

    /// Call teardown through vtable
    pub fn teardown(self: *RenderPass) void {
        self.vtable.teardown(self);
    }
};

/// RenderGraph manages a DAG of render passes for a scene
pub const RenderGraph = struct {
    allocator: Allocator,
    graphics_context: *GraphicsContext,

    // Passes in execution order (after compilation)
    passes: std.ArrayList(*RenderPass),

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
            .resources = ResourceRegistry.init(allocator),
            .compiled = false,
        };
    }

    pub fn deinit(self: *RenderGraph) void {
        log(.INFO, "render_graph", "Destroying render graph ({} passes)", .{self.passes.items.len});

        // Teardown all passes
        for (self.passes.items) |pass| {
            log(.DEBUG, "render_graph", "Tearing down pass: {s}", .{pass.name});
            pass.teardown();
        }

        self.passes.deinit(self.allocator);
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
            log(.DEBUG, "render_graph", "Setting up pass: {s}", .{pass.name});
            try pass.setup(self);
        }

        // TODO: Topological sort based on resource dependencies
        // For now: execute in order added (GeometryPass -> LightingPass)

        self.compiled = true;
        log(.INFO, "render_graph", "Render graph compiled successfully", .{});
    }

    /// Execute all enabled passes
    pub fn execute(self: *RenderGraph, frame_info: FrameInfo) !void {
        if (!self.compiled) {
            return error.GraphNotCompiled;
        }

        for (self.passes.items) |pass| {
            if (!pass.enabled) {
                log(.TRACE, "render_graph", "Skipping disabled pass: {s}", .{pass.name});
                continue;
            }

            try pass.execute(frame_info);
        }
    }

    /// Enable a pass by name
    pub fn enablePass(self: *RenderGraph, name: []const u8) void {
        for (self.passes.items) |pass| {
            if (std.mem.eql(u8, pass.name, name)) {
                pass.enabled = true;
                log(.INFO, "render_graph", "Enabled pass: {s}", .{name});
                return;
            }
        }
        log(.WARN, "render_graph", "Pass not found: {s}", .{name});
    }

    /// Disable a pass by name
    pub fn disablePass(self: *RenderGraph, name: []const u8) void {
        for (self.passes.items) |pass| {
            if (std.mem.eql(u8, pass.name, name)) {
                pass.enabled = false;
                log(.INFO, "render_graph", "Disabled pass: {s}", .{name});
                return;
            }
        }
        log(.WARN, "render_graph", "Pass not found: {s}", .{name});
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
