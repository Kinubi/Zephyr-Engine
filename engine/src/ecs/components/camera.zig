const std = @import("std");
const math = @import("../../utils/math.zig");

/// Camera component for ECS entities
/// Works with Transform component for positioning and orientation
/// Supports perspective and orthographic projections
pub const Camera = struct {
    /// Camera projection type
    pub const ProjectionType = enum {
        perspective,
        orthographic,
    };

    /// Projection settings
    projection_type: ProjectionType = .perspective,

    // Perspective settings
    fov: f32 = 50.0, // Field of view in degrees
    near_plane: f32 = 0.1,
    far_plane: f32 = 100.0,
    aspect_ratio: f32 = 16.0 / 9.0,

    // Orthographic settings
    ortho_left: f32 = -10.0,
    ortho_right: f32 = 10.0,
    ortho_bottom: f32 = -10.0,
    ortho_top: f32 = 10.0,

    /// Whether this is the primary/active camera
    is_primary: bool = false,

    /// Cached projection matrix (updated when projection settings change)
    projection_matrix: math.Mat4x4 = math.Mat4x4.identity(),

    /// Dirty flag for projection matrix
    projection_dirty: bool = true,

    // ========================================================================
    // Initialization
    // ========================================================================

    /// Create a perspective camera with default settings
    pub fn init() Camera {
        return .{
            .projection_type = .perspective,
            .fov = 50.0,
            .near_plane = 0.1,
            .far_plane = 100.0,
            .aspect_ratio = 16.0 / 9.0,
            .is_primary = false,
            .projection_matrix = math.Mat4x4.identity(),
            .projection_dirty = true,
        };
    }

    /// Create a perspective camera with custom FOV
    pub fn initPerspective(fov: f32, aspect_ratio: f32, near: f32, far: f32) Camera {
        return .{
            .projection_type = .perspective,
            .fov = fov,
            .near_plane = near,
            .far_plane = far,
            .aspect_ratio = aspect_ratio,
            .is_primary = false,
            .projection_matrix = math.Mat4x4.identity(),
            .projection_dirty = true,
        };
    }

    /// Create an orthographic camera
    pub fn initOrthographic(left: f32, right: f32, bottom: f32, top: f32, near: f32, far: f32) Camera {
        return .{
            .projection_type = .orthographic,
            .ortho_left = left,
            .ortho_right = right,
            .ortho_bottom = bottom,
            .ortho_top = top,
            .near_plane = near,
            .far_plane = far,
            .is_primary = false,
            .projection_matrix = math.Mat4x4.identity(),
            .projection_dirty = true,
        };
    }

    // ========================================================================
    // Projection Settings
    // ========================================================================

    /// Set perspective projection parameters
    pub fn setPerspective(self: *Camera, fov: f32, aspect_ratio: f32, near: f32, far: f32) void {
        self.projection_type = .perspective;
        self.fov = fov;
        self.aspect_ratio = aspect_ratio;
        self.near_plane = near;
        self.far_plane = far;
        self.projection_dirty = true;
    }

    /// Set orthographic projection parameters
    pub fn setOrthographic(self: *Camera, left: f32, right: f32, bottom: f32, top: f32, near: f32, far: f32) void {
        self.projection_type = .orthographic;
        self.ortho_left = left;
        self.ortho_right = right;
        self.ortho_bottom = bottom;
        self.ortho_top = top;
        self.near_plane = near;
        self.far_plane = far;
        self.projection_dirty = true;
    }

    /// Serialize Camera component
    pub fn serialize(self: Camera, serializer: anytype, writer: anytype) !void {
        _ = serializer;
        try writer.beginObject();
        
        try writer.objectField("projection_type");
        switch (self.projection_type) {
            .perspective => try writer.write("perspective"),
            .orthographic => try writer.write("orthographic"),
        }
        
        try writer.objectField("is_primary");
        try writer.write(self.is_primary);
        
        try writer.objectField("near_plane");
        try writer.write(self.near_plane);
        
        try writer.objectField("far_plane");
        try writer.write(self.far_plane);
        
        if (self.projection_type == .perspective) {
            try writer.objectField("fov");
            try writer.write(self.fov);
            
            try writer.objectField("aspect_ratio");
            try writer.write(self.aspect_ratio);
        } else {
            try writer.objectField("ortho_left");
            try writer.write(self.ortho_left);
            
            try writer.objectField("ortho_right");
            try writer.write(self.ortho_right);
            
            try writer.objectField("ortho_bottom");
            try writer.write(self.ortho_bottom);
            
            try writer.objectField("ortho_top");
            try writer.write(self.ortho_top);
        }
        
        try writer.endObject();
    }

    /// Deserialize Camera component
    pub fn deserialize(serializer: anytype, value: std.json.Value) !Camera {
        _ = serializer;
        var cam = Camera.init();
        
        if (value.object.get("projection_type")) |val| {
            if (val == .string) {
                if (std.mem.eql(u8, val.string, "perspective")) cam.projection_type = .perspective;
                if (std.mem.eql(u8, val.string, "orthographic")) cam.projection_type = .orthographic;
            }
        }
        
        if (value.object.get("is_primary")) |val| {
            if (val == .bool) cam.is_primary = val.bool;
        }
        
        if (value.object.get("near_plane")) |val| {
            if (val == .float) cam.near_plane = @floatCast(val.float);
        }
        
        if (value.object.get("far_plane")) |val| {
            if (val == .float) cam.far_plane = @floatCast(val.float);
        }
        
        if (value.object.get("fov")) |val| {
            if (val == .float) cam.fov = @floatCast(val.float);
        }
        
        if (value.object.get("aspect_ratio")) |val| {
            if (val == .float) cam.aspect_ratio = @floatCast(val.float);
        }
        
        if (value.object.get("ortho_left")) |val| {
            if (val == .float) cam.ortho_left = @floatCast(val.float);
        }
        
        if (value.object.get("ortho_right")) |val| {
            if (val == .float) cam.ortho_right = @floatCast(val.float);
        }
        
        if (value.object.get("ortho_bottom")) |val| {
            if (val == .float) cam.ortho_bottom = @floatCast(val.float);
        }
        
        if (value.object.get("ortho_top")) |val| {
            if (val == .float) cam.ortho_top = @floatCast(val.float);
        }
        
        cam.projection_dirty = true;
        return cam;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Camera: default init creates perspective" {
    const camera = Camera.init();

    try std.testing.expectEqual(Camera.ProjectionType.perspective, camera.projection_type);
    try std.testing.expectEqual(@as(f32, 50.0), camera.fov);
    try std.testing.expectEqual(@as(f32, 0.1), camera.near_plane);
    try std.testing.expectEqual(@as(f32, 100.0), camera.far_plane);
    try std.testing.expect(!camera.is_primary);
    try std.testing.expect(camera.projection_dirty);
}

test "Camera: perspective init with custom params" {
    const camera = Camera.initPerspective(60.0, 16.0 / 9.0, 0.01, 500.0);

    try std.testing.expectEqual(@as(f32, 60.0), camera.fov);
    try std.testing.expectEqual(@as(f32, 0.01), camera.near_plane);
    try std.testing.expectEqual(@as(f32, 500.0), camera.far_plane);
    try std.testing.expectEqual(@as(f32, 16.0 / 9.0), camera.aspect_ratio);
}

test "Camera: orthographic init" {
    const camera = Camera.initOrthographic(-10, 10, -5, 5, 0.1, 100);

    try std.testing.expectEqual(Camera.ProjectionType.orthographic, camera.projection_type);
    try std.testing.expectEqual(@as(f32, -10), camera.ortho_left);
    try std.testing.expectEqual(@as(f32, 10), camera.ortho_right);
    try std.testing.expectEqual(@as(f32, -5), camera.ortho_bottom);
    try std.testing.expectEqual(@as(f32, 5), camera.ortho_top);
}

test "Camera: setPerspective marks dirty" {
    var camera = Camera.init();
    camera.projection_dirty = false;

    camera.setPerspective(90.0, 1.0, 0.5, 200.0);

    try std.testing.expect(camera.projection_dirty);
    try std.testing.expectEqual(@as(f32, 90.0), camera.fov);
    try std.testing.expectEqual(@as(f32, 1.0), camera.aspect_ratio);
}

test "Camera: setOrthographic marks dirty and changes type" {
    var camera = Camera.initPerspective(60.0, 16.0 / 9.0, 0.1, 100);
    camera.projection_dirty = false;

    camera.setOrthographic(-5, 5, -5, 5, 0.1, 50);

    try std.testing.expect(camera.projection_dirty);
    try std.testing.expectEqual(Camera.ProjectionType.orthographic, camera.projection_type);
}

test "Camera: setFov marks dirty" {
    var camera = Camera.init();
    camera.projection_dirty = false;

    camera.setFov(75.0);

    try std.testing.expect(camera.projection_dirty);
    try std.testing.expectEqual(@as(f32, 75.0), camera.fov);
}

test "Camera: setAspectRatio marks dirty" {
    var camera = Camera.init();
    camera.projection_dirty = false;

    camera.setAspectRatio(21.0 / 9.0);

    try std.testing.expect(camera.projection_dirty);
    try std.testing.expectApproxEqAbs(@as(f32, 21.0 / 9.0), camera.aspect_ratio, 0.0001);
}

test "Camera: getProjectionMatrix updates when dirty" {
    var camera = Camera.initPerspective(90.0, 1.0, 1.0, 10.0);

    try std.testing.expect(camera.projection_dirty);

    const proj = camera.getProjectionMatrix();

    try std.testing.expect(!camera.projection_dirty);

    // Verify projection matrix has been calculated (not identity)
    // For a 90 degree FOV with aspect 1.0, [0,0] should be 1.0 / tan(45 deg) = 1.0
    // So check element that should NOT be 1.0 - like [3,2] which should be negative
    try std.testing.expect(proj.data[14] != 0.0); // [3,2] in row-major = index 14
}

test "Camera: setPrimary flag" {
    var camera = Camera.init();
    try std.testing.expect(!camera.is_primary);

    camera.setPrimary(true);
    try std.testing.expect(camera.is_primary);

    camera.setPrimary(false);
    try std.testing.expect(!camera.is_primary);
}

test "Camera: render extracts primary camera" {
    var camera = Camera.init();
    camera.setPrimary(true);
    _ = camera.getProjectionMatrix(); // Ensure projection is calculated

    var context = Camera.RenderContext{};

    camera.render(&context);

    try std.testing.expect(context.primary_camera != null);
    try std.testing.expectEqual(&camera, context.primary_camera.?);
}

test "Camera: render ignores non-primary camera" {
    const camera = Camera.init(); // is_primary = false

    var context = Camera.RenderContext{};

    camera.render(&context);

    try std.testing.expect(context.primary_camera == null);
}

test "Camera: update method clears dirty flag" {
    var camera = Camera.init();
    try std.testing.expect(camera.projection_dirty);

    camera.update(0.016);

    try std.testing.expect(!camera.projection_dirty);
}
