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

    /// Set field of view (perspective only)
    pub fn setFov(self: *Camera, fov: f32) void {
        self.fov = fov;
        self.projection_dirty = true;
    }

    /// Set aspect ratio (perspective only)
    pub fn setAspectRatio(self: *Camera, aspect_ratio: f32) void {
        self.aspect_ratio = aspect_ratio;
        self.projection_dirty = true;
    }

    /// Set near/far planes
    pub fn setClipPlanes(self: *Camera, near: f32, far: f32) void {
        self.near_plane = near;
        self.far_plane = far;
        self.projection_dirty = true;
    }

    /// Mark this camera as the primary/active camera
    pub fn setPrimary(self: *Camera, is_primary: bool) void {
        self.is_primary = is_primary;
    }

    // ========================================================================
    // Matrix Calculations
    // ========================================================================

    /// Update projection matrix if dirty
    /// Called automatically by getProjectionMatrix()
    fn updateProjectionMatrix(self: *Camera) void {
        if (!self.projection_dirty) {
            return;
        }

        switch (self.projection_type) {
            .perspective => {
                const fov_rad = math.radians(self.fov);
                const tan_half_fov = @tan(fov_rad / 2.0);

                self.projection_matrix = math.Mat4x4.zero();
                self.projection_matrix.get(0, 0).* = 1.0 / (self.aspect_ratio * tan_half_fov);
                self.projection_matrix.get(1, 1).* = 1.0 / tan_half_fov;
                self.projection_matrix.get(2, 2).* = self.far_plane / (self.far_plane - self.near_plane);
                self.projection_matrix.get(2, 3).* = 1.0;
                self.projection_matrix.get(3, 2).* = -(self.far_plane * self.near_plane) / (self.far_plane - self.near_plane);
            },
            .orthographic => {
                self.projection_matrix = math.Mat4x4.identity();
                self.projection_matrix.get(0, 0).* = 2.0 / (self.ortho_right - self.ortho_left);
                self.projection_matrix.get(1, 1).* = 2.0 / (self.ortho_bottom - self.ortho_top);
                self.projection_matrix.get(2, 2).* = 1.0 / (self.far_plane - self.near_plane);
                self.projection_matrix.get(3, 0).* = -(self.ortho_right + self.ortho_left) / (self.ortho_right - self.ortho_left);
                self.projection_matrix.get(3, 1).* = -(self.ortho_bottom + self.ortho_top) / (self.ortho_bottom - self.ortho_top);
                self.projection_matrix.get(3, 2).* = -self.near_plane / (self.far_plane - self.near_plane);
            },
        }

        self.projection_dirty = false;
    }

    /// Get the projection matrix (updates if dirty)
    pub fn getProjectionMatrix(self: *Camera) math.Mat4x4 {
        self.updateProjectionMatrix();
        return self.projection_matrix;
    }

    /// Build view matrix from Transform component's world matrix
    /// Transform's world matrix is the camera's model matrix (position/rotation in world)
    /// View matrix is the inverse of model matrix
    pub fn getViewMatrix(camera_world_matrix: math.Mat4x4) math.Mat4x4 {
        // For now, return identity - will be computed by CameraSystem using Transform
        // This is a static helper for the system to use
        _ = camera_world_matrix;
        return math.Mat4x4.identity();
    }

    // ========================================================================
    // ECS Integration
    // ========================================================================

    /// ECS update method - updates projection matrix if needed
    pub fn update(self: *Camera, dt: f32) void {
        _ = dt;
        self.updateProjectionMatrix();
    }

    /// Render extraction context for CameraSystem
    pub const RenderContext = struct {
        /// Output: the primary camera (if found)
        primary_camera: ?*const Camera = null,
        /// Output: projection matrix of primary camera
        projection_matrix: math.Mat4x4 = math.Mat4x4.identity(),
        /// Output: view matrix from Transform + Camera
        view_matrix: math.Mat4x4 = math.Mat4x4.identity(),
    };

    /// ECS render method - extracts camera data to context
    /// The first primary camera found will be used
    pub fn render(self: *const Camera, context: *RenderContext) void {
        // If this is the primary camera and we haven't found one yet
        if (self.is_primary and context.primary_camera == null) {
            context.primary_camera = self;
            context.projection_matrix = self.projection_matrix;
            // Note: view_matrix will be filled by CameraSystem using Transform
        }
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
