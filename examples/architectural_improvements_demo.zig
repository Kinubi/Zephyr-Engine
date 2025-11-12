// Example: Using the new architectural improvements in Zephyr Engine

const std = @import("std");
const zephyr = @import("zephyr");

/// Custom error handler that logs to file
fn customErrorHandler(ctx: zephyr.ErrorContext) void {
    std.log.err("[{s}] {s} at {s}:{d}", .{
        @errorName(ctx.error_code),
        ctx.message,
        ctx.file,
        ctx.line,
    });
}

/// Example texture resource
const Texture = struct {
    width: u32,
    height: u32,
    data: []u8,
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !Texture {
        const data = try allocator.alloc(u8, width * height * 4);
        return .{
            .width = width,
            .height = height,
            .data = data,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Texture) void {
        self.allocator.free(self.data);
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.log.info("=== Zephyr Engine Architectural Improvements Demo ===\n", .{});
    
    // ========== 1. Error Handling Demo ==========
    std.log.info("1. Setting up error handling...", .{});
    zephyr.setErrorHandler(customErrorHandler);
    
    // Errors now have rich context
    const result = initializeGraphics() catch |err| {
        std.log.err("Failed to initialize graphics: {}", .{err});
        return err;
    };
    _ = result;
    
    // ========== 2. Resource Management Demo ==========
    std.log.info("\n2. Demonstrating resource management...", .{});
    
    var texture_manager = zephyr.ResourceManager(Texture).init(allocator);
    defer texture_manager.deinit();
    
    // Create textures
    const tex1 = try Texture.init(allocator, 512, 512);
    const handle1 = try texture_manager.create("diffuse_map", tex1);
    std.log.info("Created texture: {}", .{handle1});
    
    const tex2 = try Texture.init(allocator, 1024, 1024);
    const handle2 = try texture_manager.create("normal_map", tex2);
    std.log.info("Created texture: {}", .{handle2});
    
    // Use resources
    if (texture_manager.get(handle1)) |texture| {
        std.log.info("Texture dimensions: {}x{}", .{ texture.width, texture.height });
    }
    
    // Reference counting
    try texture_manager.addRef(handle1);
    std.log.info("Added reference to texture", .{});
    
    texture_manager.removeRef(handle1);
    std.log.info("Removed reference to texture", .{});
    
    // Get statistics
    const stats = texture_manager.getStats();
    std.log.info("Resource stats: total={d}, active={d}, refs={d}", .{
        stats.total,
        stats.active,
        stats.total_refs,
    });
    
    // ========== 3. Configuration Management Demo ==========
    std.log.info("\n3. Demonstrating configuration management...", .{});
    
    var config = zephyr.ConfigManager.init(allocator);
    defer config.deinit();
    
    // Register graphics settings
    try config.register(
        "graphics.vsync",
        .{ .bool = true },
        "Enable vertical synchronization",
        "graphics",
        .{},
    );
    
    try config.register(
        "graphics.resolution_scale",
        .{ .float = 1.0 },
        "Resolution scale factor (0.5 - 2.0)",
        "graphics",
        .{ .validator = resolutionScaleValidator },
    );
    
    try config.register(
        "graphics.max_fps",
        .{ .int = 144 },
        "Maximum frames per second",
        "graphics",
        .{},
    );
    
    try config.register(
        "engine.version",
        .{ .string = "1.0.0" },
        "Engine version",
        "system",
        .{ .read_only = true },
    );
    
    // Use configuration
    const vsync = config.getBool("graphics.vsync", false);
    const scale = config.getFloat("graphics.resolution_scale", 1.0);
    const max_fps = config.getInt("graphics.max_fps", 60);
    
    std.log.info("Graphics settings:", .{});
    std.log.info("  VSync: {}", .{vsync});
    std.log.info("  Resolution Scale: {d:.2}", .{scale});
    std.log.info("  Max FPS: {d}", .{max_fps});
    
    // Change settings
    try config.set("graphics.vsync", .{ .bool = false });
    std.log.info("Changed VSync to false", .{});
    
    // Try to change read-only value (will fail)
    config.set("engine.version", .{ .string = "2.0.0" }) catch |err| {
        std.log.err("Cannot change read-only value: {}", .{err});
    };
    
    // Save configuration
    try config.saveToFile("engine_config.ini");
    std.log.info("Configuration saved to engine_config.ini", .{});
    
    // ========== 4. Integration Example ==========
    std.log.info("\n4. Integration example...", .{});
    
    // Use all systems together
    const GraphicsSystem = struct {
        config: *zephyr.ConfigManager,
        textures: *zephyr.ResourceManager(Texture),
        
        pub fn loadTexture(self: *@This(), name: []const u8, width: u32, height: u32) !zephyr.resource.Handle(Texture) {
            const scale = self.config.getFloat("graphics.resolution_scale", 1.0);
            const scaled_width = @as(u32, @intFromFloat(@as(f32, @floatFromInt(width)) * @as(f32, @floatCast(scale))));
            const scaled_height = @as(u32, @intFromFloat(@as(f32, @floatFromInt(height)) * @as(f32, @floatCast(scale))));
            
            const texture = try Texture.init(self.textures.allocator, scaled_width, scaled_height);
            return try self.textures.create(name, texture);
        }
    };
    
    var graphics_system = GraphicsSystem{
        .config = &config,
        .textures = &texture_manager,
    };
    
    const scaled_texture = try graphics_system.loadTexture("player_sprite", 256, 256);
    if (texture_manager.get(scaled_texture)) |texture| {
        std.log.info("Loaded scaled texture: {}x{}", .{ texture.width, texture.height });
    }
    
    std.log.info("\n=== Demo Complete ===", .{});
}

fn initializeGraphics() !void {
    // Simulate graphics initialization
    // In real code, this might fail and provide error context
    std.log.info("Graphics initialized successfully", .{});
}

fn resolutionScaleValidator(value: zephyr.ConfigValue) zephyr.config.ValidationError!void {
    if (value == .float) {
        if (value.float < 0.5 or value.float > 2.0) {
            return zephyr.config.ValidationError.OutOfRange;
        }
    }
}
