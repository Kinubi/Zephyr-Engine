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
        const raw_id = id.toInt();
        if (raw_id == 0 or raw_id > self.resources.items.len) return null;
        return &self.resources.items[raw_id - 1];
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

    /// PHASE 2.1: Prepare CPU-side data (MAIN THREAD)
    /// Called before snapshot capture to do ECS queries, sorting, culling
    /// Optional - passes without CPU work can leave this null
    prepareExecute: ?*const fn (pass: *RenderPass, frame_info: *const FrameInfo) anyerror!void = null,

    /// Update pass state each frame (RENDER THREAD)
    /// For Vulkan descriptor updates, pipeline state changes
    update: *const fn (pass: *RenderPass, frame_info: *const FrameInfo) anyerror!void,

    /// Execute the pass (RENDER THREAD)
    /// Record Vulkan draw commands ONLY - no ECS queries here
    execute: *const fn (pass: *RenderPass, frame_info: FrameInfo) anyerror!void,

    /// Cleanup resources
    teardown: *const fn (pass: *RenderPass) void,

    /// Check if pass has become valid (for recovery after initial setup failure)
    /// Called each frame for passes where setup_succeeded == false
    checkValidity: *const fn (pass: *RenderPass) bool,

    /// Reset pass state (optional)
    reset: ?*const fn (pass: *RenderPass) void = null,
};

/// Base interface for render passes
pub const RenderPass = struct {
    name: []const u8,
    enabled: bool = true,
    setup_succeeded: bool = false, // Track if setup completed successfully
    just_recovered: bool = false, // Track if this pass just recovered (to auto-enable it)
    vtable: *const RenderPassVTable,

    // Dependencies: names of passes this pass depends on (must execute after)
    dependencies: std.ArrayList([]const u8),

    /// Call setup through vtable
    pub fn setup(self: *RenderPass, graph: *RenderGraph) !void {
        return self.vtable.setup(self, graph);
    }

    /// Call prepareExecute through vtable (MAIN THREAD - ECS queries, sorting)
    pub fn prepareExecute(self: *RenderPass, frame_info: *const FrameInfo) !void {
        if (self.vtable.prepareExecute) |prepare| {
            return prepare(self, frame_info);
        }
    }

    /// Call update through vtable (RENDER THREAD - Vulkan descriptor updates)
    pub fn update(self: *RenderPass, frame_info: *const FrameInfo) !void {
        return self.vtable.update(self, frame_info);
    }

    /// Call execute through vtable (RENDER THREAD - Vulkan draw commands)
    pub fn execute(self: *RenderPass, frame_info: FrameInfo) !void {
        return self.vtable.execute(self, frame_info);
    }

    /// Call teardown through vtable
    pub fn teardown(self: *RenderPass) void {
        self.vtable.teardown(self);
    }

    /// Check if pass has become valid (recovery detection)
    pub fn checkValidity(self: *RenderPass) bool {
        return self.vtable.checkValidity(self);
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
        // Handle setup errors gracefully - disable pass if setup fails
        var i: usize = 0;
        while (i < self.passes.items.len) {
            const pass = self.passes.items[i];
            log(.INFO, "render_graph", "Setting up pass: {s}", .{pass.name});
            pass.setup(self) catch |err| {
                log(.WARN, "render_graph", "Pass {s} setup failed with error: {}. Disabling pass.", .{ pass.name, err });
                pass.enabled = false;
                pass.setup_succeeded = false;
                i += 1;
                continue;
            };
            pass.setup_succeeded = true;
            log(.INFO, "render_graph", "Pass {s} setup complete", .{pass.name});
            i += 1;
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

        log(.INFO, "render_graph", "Building execution order from {} total passes", .{self.passes.items.len});
        for (self.passes.items) |pass| {
            if (pass.enabled and pass.setup_succeeded) {
                log(.INFO, "render_graph", "  Including enabled pass: {s}", .{pass.name});
                try enabled_passes.append(self.allocator, pass);
            } else if (!pass.setup_succeeded) {
                log(.INFO, "render_graph", "  Skipping pass (setup failed): {s}", .{pass.name});
            } else {
                log(.INFO, "render_graph", "  Skipping disabled pass: {s}", .{pass.name});
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

    /// PHASE 2.1: Prepare CPU-side data for all passes (MAIN THREAD)
    /// Called before snapshot capture to do ECS queries, sorting, culling
    /// Passes without prepareExecute() are safely skipped
    pub fn prepareExecute(self: *RenderGraph, frame_info: *const FrameInfo) !void {
        if (!self.compiled) {
            return error.GraphNotCompiled;
        }

        for (self.execution_order.items) |pass| {
            // Skip passes that don't have CPU preparation work
            if (pass.vtable.prepareExecute == null) {
                continue;
            }

            // Optional performance monitoring
            if (frame_info.performance_monitor) |pm| {
                var name_buf: [64]u8 = undefined;
                const prep_name = std.fmt.bufPrint(&name_buf, "{s}_prepare", .{pass.name}) catch pass.name;
                try pm.beginPass(prep_name, frame_info.current_frame, frame_info.command_buffer);

                try pass.prepareExecute(frame_info);

                try pm.endPass(prep_name, frame_info.current_frame, frame_info.command_buffer);
            } else {
                try pass.prepareExecute(frame_info);
            }
        }
    }

    /// Update all enabled passes (RENDER THREAD - Vulkan descriptor updates)
    /// Call each frame before execute
    pub fn update(self: *RenderGraph, frame_info: *const FrameInfo) !void {
        if (!self.compiled) {
            return error.GraphNotCompiled;
        }

        // Check if any previously failed passes have recovered
        for (self.passes.items) |pass| {
            if (!pass.setup_succeeded) {
                if (pass.checkValidity()) {
                    log(.INFO, "render_graph", "Pass {s} recovered successfully", .{pass.name});
                    pass.setup_succeeded = true;
                    pass.just_recovered = true; // Mark for auto-enabling after recompilation
                    // Note: Don't set enabled = true here! The pass will be enabled
                    // after recompilation. Just mark for recompilation.
                    self.compiled = false; // Mark for recompilation at end of render
                }
            }
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
        // If graph needs recompilation (e.g., after pass recovery), do it before execution

        for (self.execution_order.items) |pass| {
            if (frame_info.performance_monitor) |pm| {
                try pm.beginPass(pass.name, frame_info.current_frame, frame_info.command_buffer);
            }
            try pass.execute(frame_info);
            if (frame_info.performance_monitor) |pm| {
                try pm.endPass(pass.name, frame_info.current_frame, frame_info.command_buffer);
            }
        }

        if (!self.compiled) {
            // Enable only passes that just recovered (not all disabled passes)
            for (self.passes.items) |pass| {
                if (pass.just_recovered) {
                    log(.INFO, "render_graph", "Enabling recovered pass: {s}", .{pass.name});
                    pass.enabled = true;
                    pass.just_recovered = false; // Clear flag after enabling
                }
            }

            try self.buildExecutionOrder();
            self.compiled = true;
        }
    }

    /// Enable a pass by name (doesn't recompile - call recompile() after all state changes)
    /// Only enables if setup previously succeeded
    pub fn enablePass(self: *RenderGraph, name: []const u8) void {
        for (self.passes.items) |pass| {
            if (std.mem.eql(u8, pass.name, name)) {
                if (!pass.setup_succeeded) {
                    log(.WARN, "render_graph", "Cannot enable pass {s} - setup failed", .{name});
                    return;
                }
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

    /// Retry setup for passes that previously failed
    /// Useful after shader hot-reload or asset changes
    pub fn retryFailedPasses(self: *RenderGraph) !void {
        log(.INFO, "render_graph", "Retrying setup for failed passes", .{});

        var any_recovered = false;
        for (self.passes.items) |pass| {
            if (!pass.setup_succeeded) {
                log(.INFO, "render_graph", "Retrying setup for: {s}", .{pass.name});
                pass.setup(self) catch |err| {
                    log(.WARN, "render_graph", "Pass {s} setup still fails: {}", .{ pass.name, err });
                    continue;
                };
                // Setup succeeded this time!
                pass.setup_succeeded = true;
                pass.enabled = true;
                any_recovered = true;
                log(.INFO, "render_graph", "Pass {s} setup now succeeded!", .{pass.name});
            }
        }

        if (any_recovered) {
            // Rebuild execution order to include recovered passes
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

    /// Reset all passes
    pub fn reset(self: *RenderGraph) void {
        for (self.passes.items) |pass| {
            if (pass.vtable.reset) |reset_fn| {
                reset_fn(pass);
            }
        }
        log(.INFO, "render_graph", "Reset all passes", .{});
    }
};
