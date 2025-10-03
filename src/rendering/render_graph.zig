const std = @import("std");
const RenderPass = @import("render_pass.zig").RenderPass;
const RenderContext = @import("render_pass.zig").RenderContext;
const ResourceBinding = @import("render_pass.zig").ResourceBinding;
const ResourceAccess = @import("render_pass.zig").ResourceAccess;
const PassPriority = @import("render_pass.zig").PassPriority;

/// Handle to a render pass in the graph
pub const PassHandle = enum(u32) {
    invalid = 0,
    _,

    pub fn isValid(self: PassHandle) bool {
        return self != .invalid;
    }
};

/// Dependency between two render passes
const PassDependency = struct {
    from: PassHandle,
    to: PassHandle,
    resource_name: []const u8,
};

/// Resource usage tracking for automatic barriers
const ResourceUsage = struct {
    last_pass: PassHandle,
    last_access: ResourceAccess,
    current_pass: PassHandle,
    current_access: ResourceAccess,
};

/// RenderGraph manages render passes and their dependencies
pub const RenderGraph = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    passes: std.ArrayList(RenderPass),
    dependencies: std.ArrayList(PassDependency),
    resource_usage: std.HashMap([]const u8, ResourceUsage, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),
    execution_order: std.ArrayList(PassHandle),

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .passes = std.ArrayList(RenderPass){},
            .dependencies = std.ArrayList(PassDependency){},
            .resource_usage = std.HashMap([]const u8, ResourceUsage, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
            .execution_order = std.ArrayList(PassHandle){},
        };
    }

    pub fn deinit(self: *Self) void {
        // Deinitialize all passes
        for (self.passes.items) |*pass| {
            pass.deinit();
        }

        self.passes.deinit(self.allocator);
        self.dependencies.deinit(self.allocator);
        self.resource_usage.deinit();
        self.execution_order.deinit(self.allocator);
    }

    /// Add a render pass to the graph
    pub fn addPass(self: *Self, pass: RenderPass) !PassHandle {
        const handle = @as(PassHandle, @enumFromInt(@as(u32, @intCast(self.passes.items.len + 1))));
        try self.passes.append(self.allocator, pass);

        // Register resource usage for this pass
        const resources = pass.getResourceRequirements();
        for (resources) |resource| {
            const usage = ResourceUsage{
                .last_pass = .invalid,
                .last_access = .read, // Default
                .current_pass = handle,
                .current_access = resource.access,
            };

            if (self.resource_usage.get(resource.resource_name)) |existing| {
                const updated_usage = ResourceUsage{
                    .last_pass = existing.current_pass,
                    .last_access = existing.current_access,
                    .current_pass = handle,
                    .current_access = resource.access,
                };
                try self.resource_usage.put(resource.resource_name, updated_usage);
            } else {
                try self.resource_usage.put(resource.resource_name, usage);
            }
        }

        return handle;
    }

    /// Add a dependency between two passes
    pub fn addDependency(self: *Self, from: PassHandle, to: PassHandle) !void {
        // Validate handles
        if (!from.isValid() or !to.isValid()) return error.InvalidPassHandle;
        if (@intFromEnum(from) > self.passes.items.len or @intFromEnum(to) > self.passes.items.len) {
            return error.InvalidPassHandle;
        }

        const dependency = PassDependency{
            .from = from,
            .to = to,
            .resource_name = "", // Generic dependency
        };

        try self.dependencies.append(self.allocator, dependency);

        // Mark execution order as dirty
        self.execution_order.clearAndFree();
    }

    /// Add a resource-specific dependency between passes
    pub fn addResourceDependency(self: *Self, from: PassHandle, to: PassHandle, resource_name: []const u8) !void {
        if (!from.isValid() or !to.isValid()) return error.InvalidPassHandle;

        const dependency = PassDependency{
            .from = from,
            .to = to,
            .resource_name = resource_name,
        };

        try self.dependencies.append(self.allocator, dependency);
        self.execution_order.clearAndFree();
    }

    /// Build execution order using topological sort
    pub fn buildExecutionOrder(self: *Self) !void {
        if (self.execution_order.items.len > 0) return; // Already built

        const pass_count = self.passes.items.len;
        if (pass_count == 0) return;

        // Initialize arrays for topological sort
        var in_degree = try self.allocator.alloc(u32, pass_count);
        defer self.allocator.free(in_degree);
        var queue = std.ArrayList(PassHandle){};
        defer queue.deinit(self.allocator);

        // Initialize in-degrees to 0
        for (in_degree) |*degree| {
            degree.* = 0;
        }

        // Calculate in-degrees based on dependencies
        for (self.dependencies.items) |dep| {
            const to_index = @intFromEnum(dep.to) - 1;
            in_degree[to_index] += 1;
        }

        // Add all passes with no incoming edges to queue
        for (0..pass_count) |i| {
            if (in_degree[i] == 0) {
                const handle = @as(PassHandle, @enumFromInt(@as(u32, @intCast(i + 1))));
                try queue.append(self.allocator, handle);
            }
        }

        // Sort by priority within each level
        std.sort.pdq(PassHandle, queue.items, {}, comparePassPriority);

        // Process passes in topological order
        while (queue.items.len > 0) {
            const current = queue.orderedRemove(0);
            try self.execution_order.append(self.allocator, current);

            // Reduce in-degree of dependent passes
            for (self.dependencies.items) |dep| {
                if (dep.from == current) {
                    const to_index = @intFromEnum(dep.to) - 1;
                    in_degree[to_index] -= 1;

                    if (in_degree[to_index] == 0) {
                        // Insert in priority order
                        var insert_index: usize = 0;
                        while (insert_index < queue.items.len) {
                            if (comparePassPriority({}, dep.to, queue.items[insert_index])) {
                                break;
                            }
                            insert_index += 1;
                        }
                        try queue.insert(self.allocator, insert_index, dep.to);
                    }
                }
            }
        }

        // Check for cycles
        if (self.execution_order.items.len != pass_count) {
            return error.CyclicDependency;
        }
    }

    /// Compare passes by priority for sorting
    fn comparePassPriority(context: void, a: PassHandle, b: PassHandle) bool {
        _ = context;
        // Lower priority values execute first
        // This is a placeholder - would need access to passes array
        return @intFromEnum(a) < @intFromEnum(b);
    }

    /// Execute all passes in dependency order
    pub fn execute(self: *Self, context: RenderContext) !void {
        if (self.execution_order.items.len == 0) {
            try self.buildExecutionOrder();
        }

        for (self.execution_order.items) |handle| {
            const pass_index = @intFromEnum(handle) - 1;
            var pass = &self.passes.items[pass_index];

            if (pass.shouldExecute(context)) {
                try pass.execute(context);
            }
        }
    }

    /// Validate the render graph for cycles and resource conflicts
    pub fn validate(self: *Self) !bool {
        // Try to build execution order - will fail if cycles exist
        self.execution_order.clearAndFree();
        self.buildExecutionOrder() catch |err| {
            if (err == error.CyclicDependency) {
                return false;
            }
            return err;
        };

        // Validate resource usage patterns
        var resource_iterator = self.resource_usage.iterator();
        while (resource_iterator.next()) |entry| {
            const usage = entry.value_ptr.*;

            // Check for read-after-write hazards without proper dependencies
            if (usage.last_access == .write and usage.current_access == .read) {
                // Should have dependency between last_pass and current_pass
                const has_dependency = for (self.dependencies.items) |dep| {
                    if (dep.from == usage.last_pass and dep.to == usage.current_pass) {
                        break true;
                    }
                } else false;

                if (!has_dependency) {
                    std.log.warn("Missing dependency for resource '{s}' between passes {} and {}", .{
                        entry.key_ptr.*,
                        usage.last_pass,
                        usage.current_pass,
                    });
                }
            }
        }

        return true;
    }

    /// Get execution statistics
    pub fn getStats(self: *const Self) struct {
        pass_count: usize,
        dependency_count: usize,
        resource_count: usize,
    } {
        return .{
            .pass_count = self.passes.items.len,
            .dependency_count = self.dependencies.items.len,
            .resource_count = self.resource_usage.count(),
        };
    }

    /// Print debug information about the render graph
    pub fn printDebugInfo(self: *const Self) void {
        std.log.info("=== Render Graph Debug Info ===");
        std.log.info("Passes: {d}", .{self.passes.items.len});

        for (self.passes.items, 0..) |pass, i| {
            const handle = @as(PassHandle, @enumFromInt(@as(u32, @intCast(i + 1))));
            std.log.info("  Pass {}: {} (type: {s}, priority: {})", .{
                handle,
                @intFromEnum(handle),
                @tagName(pass.config.pass_type),
                @intFromEnum(pass.config.priority),
            });
        }

        std.log.info("Dependencies: {d}", .{self.dependencies.items.len});
        for (self.dependencies.items) |dep| {
            std.log.info("  {} -> {} (resource: {s})", .{ dep.from, dep.to, dep.resource_name });
        }

        std.log.info("Execution Order: {d} passes", .{self.execution_order.items.len});
        for (self.execution_order.items, 0..) |handle, i| {
            std.log.info("  {d}. Pass {}", .{ i + 1, handle });
        }
    }
};
