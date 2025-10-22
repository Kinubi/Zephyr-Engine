const std = @import("std");

/// ParticleComponent manages CPU-side particle state
/// The actual physics simulation happens in GPU compute shaders
/// This component handles lifecycle, spawning, and data extraction for rendering
pub const ParticleComponent = struct {
    position: [3]f32, // 3D world position
    velocity: [3]f32, // 3D velocity
    color: [4]f32,
    lifetime: f32,
    max_lifetime: f32,

    /// Initialize a particle with random properties
    pub fn init(random: std.Random) ParticleComponent {
        const angle = random.float(f32) * std.math.pi * 2.0;
        const speed = random.float(f32) * 0.5 + 0.1;

        return .{
            .position = .{
                random.float(f32) * 2.0 - 1.0, // -1 to 1
                random.float(f32) * 2.0 - 1.0,
                random.float(f32) * 2.0 - 1.0,
            },
            .velocity = .{
                @cos(angle) * speed,
                @sin(angle) * speed,
                0.0,
            },
            .color = .{
                random.float(f32),
                random.float(f32),
                random.float(f32),
                1.0,
            },
            .lifetime = 5.0,
            .max_lifetime = 5.0,
        };
    }

    /// CPU-side update: manage lifetime
    /// Note: Position, velocity, and alpha fading happen in GPU compute shader
    /// CPU only tracks lifetime for particle removal
    pub fn update(self: *ParticleComponent, dt: f32) void {
        self.lifetime -= dt;

        // Alpha fading is now handled by GPU compute shader
        // We just track lifetime here for removal
    }

    /// Check if particle is still alive
    pub fn isAlive(self: *const ParticleComponent) bool {
        return self.lifetime > 0.0;
    }

    /// Render context for particle batch extraction
    pub const RenderContext = struct {
        batch: *std.ArrayList(ParticleData),
        allocator: std.mem.Allocator,
    };

    /// GPU-friendly particle data format
    pub const ParticleData = extern struct {
        position: [2]f32,
        velocity: [2]f32,
        color: [4]f32,
    };

    /// Extract particle data for GPU rendering
    /// Called during render phase to populate batch buffer
    pub fn render(self: *const ParticleComponent, context: *RenderContext) void {
        // Only render alive particles
        if (!self.isAlive()) return;

        context.batch.append(context.allocator, .{
            .position = self.position,
            .velocity = self.velocity,
            .color = self.color,
        }) catch {};
    }
};

// Tests
test "ParticleComponent initialization" {
    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    const particle = ParticleComponent.init(random);

    try std.testing.expect(particle.lifetime == 5.0);
    try std.testing.expect(particle.max_lifetime == 5.0);
    try std.testing.expect(particle.color[3] == 1.0);
}

test "ParticleComponent lifetime update" {
    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    var particle = ParticleComponent.init(random);

    try std.testing.expect(particle.isAlive());

    particle.update(2.5);
    try std.testing.expect(particle.lifetime == 2.5);
    try std.testing.expect(particle.isAlive());

    particle.update(3.0);
    try std.testing.expect(particle.lifetime < 0.0);
    try std.testing.expect(!particle.isAlive());
}

test "ParticleComponent alpha fade" {
    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    var particle = ParticleComponent.init(random);
    particle.lifetime = 5.0;
    particle.max_lifetime = 5.0;

    particle.update(2.5);

    // After 2.5 seconds, should be at 50% lifetime -> 50% alpha
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), particle.color[3], 0.01);
}

test "ParticleComponent render extraction" {
    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    var batch: std.ArrayList(ParticleComponent.ParticleData) = .{};
    defer batch.deinit(std.testing.allocator);

    var particle = ParticleComponent.init(random);
    var ctx = ParticleComponent.RenderContext{
        .batch = &batch,
        .allocator = std.testing.allocator,
    };

    particle.render(&ctx);

    try std.testing.expectEqual(@as(usize, 1), batch.items.len);
    try std.testing.expectEqual(particle.position, batch.items[0].position);
    try std.testing.expectEqual(particle.velocity, batch.items[0].velocity);
}

test "ParticleComponent dead particles not rendered" {
    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    var batch: std.ArrayList(ParticleComponent.ParticleData) = .{};
    defer batch.deinit(std.testing.allocator);

    var particle = ParticleComponent.init(random);
    particle.lifetime = -1.0; // Dead particle

    var ctx = ParticleComponent.RenderContext{
        .batch = &batch,
        .allocator = std.testing.allocator,
    };
    particle.render(&ctx);

    try std.testing.expectEqual(@as(usize, 0), batch.items.len);
}
