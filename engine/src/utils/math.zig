// Local math library with essential types and functions for 3D graphics.
// Provides Vec2, Vec3, Vec4, Mat3, Mat4 and common operations.
// Expandable math module designed for Vulkan engine requirements.

// Minimal math library based on mach's math.zig
// You can expand this as needed for your project.

const std = @import("std");
const simd = @import("simd.zig");

pub const Vec2 = struct {
    x: f32,
    y: f32,

    pub fn init(x: f32, y: f32) Vec2 {
        return Vec2{ .x = x, .y = y };
    }
    pub fn zero() Vec2 {
        return Vec2{ .x = 0, .y = 0 };
    }
    pub fn add(self: Vec2, other: Vec2) Vec2 {
        return Vec2{ .x = self.x + other.x, .y = self.y + other.y };
    }
    pub fn sub(self: Vec2, other: Vec2) Vec2 {
        return Vec2{ .x = self.x - other.x, .y = self.y - other.y };
    }
    pub fn scale(self: Vec2, s: f32) Vec2 {
        return Vec2{ .x = self.x * s, .y = self.y * s };
    }
    pub fn dot(self: Vec2, other: Vec2) f32 {
        return self.x * other.x + self.y * other.y;
    }
    pub fn length(self: Vec2) f32 {
        return @sqrt(self.x * self.x + self.y * self.y);
    }
    pub fn normalize(self: Vec2) Vec2 {
        const len = self.length();
        if (len == 0) return Vec2.zero();
        return self.scale(1.0 / len);
    }
};

pub const Vec3 = struct {
    x: f32,
    y: f32,
    z: f32,

    pub fn init(x: f32, y: f32, z: f32) Vec3 {
        return Vec3{ .x = x, .y = y, .z = z };
    }
    pub fn zero() Vec3 {
        return Vec3{ .x = 0, .y = 0, .z = 0 };
    }
    pub fn add(self: Vec3, other: Vec3) Vec3 {
        return Vec3{ .x = self.x + other.x, .y = self.y + other.y, .z = self.z + other.z };
    }
    pub fn sub(self: Vec3, other: Vec3) Vec3 {
        return Vec3{ .x = self.x - other.x, .y = self.y - other.y, .z = self.z - other.z };
    }
    pub fn scale(self: Vec3, s: f32) Vec3 {
        return Vec3{ .x = self.x * s, .y = self.y * s, .z = self.z * s };
    }
    pub fn dot(self: Vec3, other: Vec3) f32 {
        return self.x * other.x + self.y * other.y + self.z * other.z;
    }
    pub fn cross(self: Vec3, other: Vec3) Vec3 {
        return Vec3{
            .x = self.y * other.z - self.z * other.y,
            .y = self.z * other.x - self.x * other.z,
            .z = self.x * other.y - self.y * other.x,
        };
    }
    pub fn length(self: Vec3) f32 {
        return @sqrt(self.x * self.x + self.y * self.y + self.z * self.z);
    }
    pub fn normalize(self: Vec3) Vec3 {
        const len = self.length();
        if (len == 0) return Vec3.zero();
        return self.scale(1.0 / len);
    }
    /// Access component by index (0=x, 1=y, 2=z)
    pub fn at(self: Vec3, idx: usize) f32 {
        return switch (idx) {
            0 => self.x,
            1 => self.y,
            2 => self.z,
            else => unreachable,
        };
    }
};

pub const Vec4 = struct {
    x: f32,
    y: f32,
    z: f32,
    w: f32,

    pub fn init(x: f32, y: f32, z: f32, w: f32) Vec4 {
        return Vec4{ .x = x, .y = y, .z = z, .w = w };
    }
};

pub const Mat4 = struct {
    data: [16]f32,

    pub fn identity() Mat4 {
        return Mat4{ .data = [_]f32{
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1,
        } };
    }
    /// Construct a Mat4 from four Vec4 rows (mach-math compatible)
    pub fn init(row0: *const Vec4, row1: *const Vec4, row2: *const Vec4, row3: *const Vec4) Mat4 {
        return Mat4{ .data = [_]f32{
            row0.x, row0.y, row0.z, row0.w,
            row1.x, row1.y, row1.z, row1.w,
            row2.x, row2.y, row2.z, row2.w,
            row3.x, row3.y, row3.z, row3.w,
        } };
    }
    pub fn mul(self: Mat4, other: Mat4) Mat4 {
        const col0: @Vector(4, f32) = self.data[0..4].*;
        const col1: @Vector(4, f32) = self.data[4..8].*;
        const col2: @Vector(4, f32) = self.data[8..12].*;
        const col3: @Vector(4, f32) = self.data[12..16].*;

        var result: Mat4 = undefined;

        inline for (0..4) |i| {
            const b_col = other.data[i * 4 .. i * 4 + 4];

            const val0: @Vector(4, f32) = @splat(b_col[0]);
            const val1: @Vector(4, f32) = @splat(b_col[1]);
            const val2: @Vector(4, f32) = @splat(b_col[2]);
            const val3: @Vector(4, f32) = @splat(b_col[3]);

            const res = (col0 * val0) + (col1 * val1) + (col2 * val2) + (col3 * val3);
            result.data[i * 4 .. i * 4 + 4].* = res;
        }
        return result;
    }
    pub fn translation(v: Vec3) Mat4 {
        var m = Mat4.identity();
        m.data[12] = v.x;
        m.data[13] = v.y;
        m.data[14] = v.z;
        return m;
    }
    pub fn scale(v: Vec3) Mat4 {
        var m = Mat4.identity();
        m.data[0] = v.x;
        m.data[5] = v.y;
        m.data[10] = v.z;
        return m;
    }
    pub fn perspective(fovy: f32, aspect: f32, near: f32, far: f32) Mat4 {
        const f = 1.0 / @tan(fovy / 2.0);
        var m = Mat4{ .data = [_]f32{0} ** 16 };
        m.data[0] = f / aspect;
        m.data[5] = f;
        m.data[10] = (far + near) / (near - far);
        m.data[11] = -1.0;
        m.data[14] = (2.0 * far * near) / (near - far);
        return m;
    }
    pub fn lookAt(eye: Vec3, center: Vec3, up: Vec3) Mat4 {
        const f = center.sub(eye).normalize();
        const s = f.cross(up.normalize()).normalize();
        const u = s.cross(f);
        var m = Mat4.identity();
        m.data[0] = s.x;
        m.data[1] = u.x;
        m.data[2] = -f.x;
        m.data[4] = s.y;
        m.data[5] = u.y;
        m.data[6] = -f.y;
        m.data[8] = s.z;
        m.data[9] = u.z;
        m.data[10] = -f.z;
        m.data[12] = -s.dot(eye);
        m.data[13] = -u.dot(eye);
        m.data[14] = f.dot(eye);
        return m;
    }
    pub fn zero() Mat4 {
        return Mat4{ .data = [_]f32{0} ** 16 };
    }
    pub fn get(self: *Mat4, row: usize, col: usize) *f32 {
        return &self.data[row * 4 + col];
    }
    pub fn to_3x4(self: Mat4) [3][4]f32 {
        // Vulkan expects row-major [3][4] (upper 3 rows, all 4 columns)
        var out: [3][4]f32 = undefined;
        const mat = self.transpose().data;
        for (0..3) |row| {
            for (0..4) |col| {
                out[row][col] = mat[row * 4 + col];
            }
        }

        return out;
    }

    pub fn transpose(self: Mat4) Mat4 {
        var result: [16]f32 = undefined;
        for (0..4) |row| {
            for (0..4) |col| {
                result[row * 4 + col] = self.data[col * 4 + row];
            }
        }
        return Mat4{ .data = result };
    }
};

pub const Quat = struct {
    x: f32,
    y: f32,
    z: f32,
    w: f32,

    pub fn init(x: f32, y: f32, z: f32, w: f32) Quat {
        return Quat{ .x = x, .y = y, .z = z, .w = w };
    }
    /// Create a quaternion from Euler angles (in radians)
    pub fn fromEuler(x: f32, y: f32, z: f32) Quat {
        const cx = @cos(x * 0.5);
        const sx = @sin(x * 0.5);
        const cy = @cos(y * 0.5);
        const sy = @sin(y * 0.5);
        const cz = @cos(z * 0.5);
        const sz = @sin(z * 0.5);
        return Quat{
            .w = cx * cy * cz + sx * sy * sz,
            .x = sx * cy * cz - cx * sy * sz,
            .y = cx * sy * cz + sx * cy * sz,
            .z = cx * cy * sz - sx * sy * cz,
        };
    }

    pub fn identity() Quat {
        return Quat{ .x = 0, .y = 0, .z = 0, .w = 1 };
    }

    pub fn length(self: Quat) f32 {
        return @sqrt(self.x * self.x + self.y * self.y + self.z * self.z + self.w * self.w);
    }

    pub fn normalize(self: Quat) Quat {
        const len = self.length();
        if (len == 0) return Quat.identity();
        const inv = 1.0 / len;
        return Quat{ .x = self.x * inv, .y = self.y * inv, .z = self.z * inv, .w = self.w * inv };
    }

    /// Dot product of two quaternions
    pub fn dot(self: Quat, other: Quat) f32 {
        return self.x * other.x + self.y * other.y + self.z * other.z + self.w * other.w;
    }

    /// Check if two quaternions represent the same rotation
    /// Quaternions q and -q represent the same rotation, so we check the absolute dot product
    pub fn isRotationEqual(self: Quat, other: Quat, epsilon: f32) bool {
        const d = @abs(self.dot(other));
        return d > (1.0 - epsilon);
    }

    pub fn conjugate(self: Quat) Quat {
        return Quat{ .x = -self.x, .y = -self.y, .z = -self.z, .w = self.w };
    }

    pub fn mul(self: Quat, other: Quat) Quat {
        // Quaternion multiplication: self * other
        return Quat{
            .w = self.w * other.w - self.x * other.x - self.y * other.y - self.z * other.z,
            .x = self.w * other.x + self.x * other.w + self.y * other.z - self.z * other.y,
            .y = self.w * other.y - self.x * other.z + self.y * other.w + self.z * other.x,
            .z = self.w * other.z + self.x * other.y - self.y * other.x + self.z * other.w,
        };
    }

    pub fn rotateVec(self: Quat, v: Vec3) Vec3 {
        // Rotate vector v by quaternion q: v' = q * v * q_conj
        const q = self;
        const qv = Quat{ .x = v.x, .y = v.y, .z = v.z, .w = 0 };
        const res = q.mul(qv).mul(q.conjugate());
        return Vec3.init(res.x, res.y, res.z);
    }

    pub fn toMat4(self: Quat) Mat4 {
        const q = self.normalize();
        const x = q.x;
        const y = q.y;
        const z = q.z;
        const w = q.w;

        const xx = x * x;
        const yy = y * y;
        const zz = z * z;
        const xy = x * y;
        const xz = x * z;
        const yz = y * z;
        const wx = w * x;
        const wy = w * y;
        const wz = w * z;

        // Build rotation matrix in column-major order
        var m: [16]f32 = [_]f32{0} ** 16;
        // column 0
        m[0] = 1.0 - 2.0 * (yy + zz);
        m[1] = 2.0 * (xy + wz);
        m[2] = 2.0 * (xz - wy);
        m[3] = 0.0;
        // column 1
        m[4] = 2.0 * (xy - wz);
        m[5] = 1.0 - 2.0 * (xx + zz);
        m[6] = 2.0 * (yz + wx);
        m[7] = 0.0;
        // column 2
        m[8] = 2.0 * (xz + wy);
        m[9] = 2.0 * (yz - wx);
        m[10] = 1.0 - 2.0 * (xx + yy);
        m[11] = 0.0;
        // column 3
        m[12] = 0.0;
        m[13] = 0.0;
        m[14] = 0.0;
        m[15] = 1.0;

        return Mat4{ .data = m };
    }

    /// Convert quaternion to Euler angles (x=pitch, y=yaw, z=roll) in radians.
    /// Uses the same Tait-Bryan X-Y-Z ordering as Quat.fromEuler.
    /// Direct conversion without matrix construction for better performance.
    pub fn toEuler(self: Quat) Vec3 {
        // Direct quaternion-to-Euler conversion using Tait-Bryan X-Y-Z convention
        // This avoids constructing the full 4x4 rotation matrix
        const qx = self.x;
        const qy = self.y;
        const qz = self.z;
        const qw = self.w;

        // Calculate matrix elements directly from quaternion components
        const r00 = 1.0 - 2.0 * (qy * qy + qz * qz);
        const r10 = 2.0 * (qx * qy + qw * qz);
        const r20 = 2.0 * (qx * qz - qw * qy);
        const r21 = 2.0 * (qy * qz + qw * qx);
        const r22 = 1.0 - 2.0 * (qx * qx + qy * qy);

        const sy = -r20;
        var x: f32 = 0;
        var y: f32 = 0;
        var z: f32 = 0;
        const EPS = 1e-6;
        const sy_abs = if (sy < 0.0) -sy else sy;
        if (sy_abs < 1.0 - EPS) {
            x = std.math.atan2(r21, r22);
            y = std.math.asin(sy);
            z = std.math.atan2(r10, r00);
        } else {
            // Gimbal lock case
            x = 0.0;
            y = if (sy > 0.0) PI / 2.0 else -PI / 2.0;
            // For gimbal lock, calculate roll differently
            const r01 = 2.0 * (qx * qy - qw * qz);
            const r11 = 1.0 - 2.0 * (qx * qx + qz * qz);
            z = std.math.atan2(-r01, r11);
        }
        return Vec3.init(x, y, z);
    }
};

// Math constants
pub const PI = 3.14159265358979323846;
pub const TAU = 6.28318530717958647692;
pub const DEG2RAD = PI / 180.0;
pub const RAD2DEG = 180.0 / PI;

pub fn radians(deg: f32) f32 {
    return deg * DEG2RAD;
}
pub fn degrees(rad: f32) f32 {
    return rad * RAD2DEG;
}

pub fn clamp(val: f32, min: f32, max: f32) f32 {
    if (val < min) return min;
    if (val > max) return max;
    return val;
}

pub fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

// Mat2 and Mat3 definitions
pub const Mat2 = struct {
    data: [4]f32,
    pub fn identity() Mat2 {
        return Mat2{ .data = [_]f32{ 1, 0, 0, 1 } };
    }
};

pub const Mat3 = struct {
    data: [9]f32,
    pub fn identity() Mat3 {
        return Mat3{ .data = [_]f32{
            1, 0, 0,
            0, 1, 0,
            0, 0, 1,
        } };
    }
};

// Type aliases for compatibility with mach-math
pub const Mat4x4 = Mat4;
pub const Mat3x3 = Mat3;
pub const Mat2x2 = Mat2;

// ============================================================================
// Frustum Culling
// ============================================================================

/// A plane in 3D space represented as ax + by + cz + d = 0
/// Normal is (a, b, c), normalized. d is distance from origin.
pub const Plane = struct {
    normal: Vec3,
    d: f32,

    /// Distance from point to plane (positive = in front, negative = behind)
    pub fn distanceToPoint(self: Plane, point: Vec3) f32 {
        return Vec3.dot(self.normal, point) + self.d;
    }
};

/// Axis-Aligned Bounding Box
pub const AABB = struct {
    min: Vec3,
    max: Vec3,

    /// Get the center of the AABB
    pub fn center(self: AABB) Vec3 {
        return Vec3.init(
            (self.min.x + self.max.x) * 0.5,
            (self.min.y + self.max.y) * 0.5,
            (self.min.z + self.max.z) * 0.5,
        );
    }

    /// Get the half-extents (half-size) of the AABB
    pub fn extents(self: AABB) Vec3 {
        return Vec3.init(
            (self.max.x - self.min.x) * 0.5,
            (self.max.y - self.min.y) * 0.5,
            (self.max.z - self.min.z) * 0.5,
        );
    }

    /// Transform an AABB by a 4x4 matrix, returning a new world-space AABB
    /// Uses the separating axis theorem approach for tight bounds
    pub fn transform(self: AABB, mat: Mat4) AABB {
        // Extract translation from matrix (column 3)
        const translation = Vec3.init(mat.data[12], mat.data[13], mat.data[14]);

        // Start with translation
        var new_min = translation;
        var new_max = translation;

        // For each axis, compute contribution from rotation/scale
        // Matrix is column-major: col0 = [0,1,2,3], col1 = [4,5,6,7], col2 = [8,9,10,11]
        inline for (0..3) |i| {
            inline for (0..3) |j| {
                const e = mat.data[j * 4 + i]; // mat[row i, col j]
                const a = e * self.min.at(j);
                const b = e * self.max.at(j);

                const min_ptr = switch (i) {
                    0 => &new_min.x,
                    1 => &new_min.y,
                    2 => &new_min.z,
                    else => unreachable,
                };
                const max_ptr = switch (i) {
                    0 => &new_max.x,
                    1 => &new_max.y,
                    2 => &new_max.z,
                    else => unreachable,
                };

                if (a < b) {
                    min_ptr.* += a;
                    max_ptr.* += b;
                } else {
                    min_ptr.* += b;
                    max_ptr.* += a;
                }
            }
        }

        return AABB{ .min = new_min, .max = new_max };
    }
};

/// View frustum with 6 planes for culling
/// Planes face inward (positive half-space is inside frustum)
pub const Frustum = struct {
    planes: [6]Plane, // left, right, bottom, top, near, far

    /// Extract frustum planes from a view-projection matrix
    /// Uses Gribb/Hartmann method for plane extraction
    pub fn fromViewProjection(vp: Mat4) Frustum {
        var frustum: Frustum = undefined;

        // Row extraction from column-major matrix:
        // row0 = [data[0], data[4], data[8], data[12]]
        // row1 = [data[1], data[5], data[9], data[13]]
        // row2 = [data[2], data[6], data[10], data[14]]
        // row3 = [data[3], data[7], data[11], data[15]]

        const row0 = Vec4.init(vp.data[0], vp.data[4], vp.data[8], vp.data[12]);
        const row1 = Vec4.init(vp.data[1], vp.data[5], vp.data[9], vp.data[13]);
        const row2 = Vec4.init(vp.data[2], vp.data[6], vp.data[10], vp.data[14]);
        const row3 = Vec4.init(vp.data[3], vp.data[7], vp.data[11], vp.data[15]);

        // Left: row3 + row0
        frustum.planes[0] = normalizePlane(
            row3.x + row0.x,
            row3.y + row0.y,
            row3.z + row0.z,
            row3.w + row0.w,
        );

        // Right: row3 - row0
        frustum.planes[1] = normalizePlane(
            row3.x - row0.x,
            row3.y - row0.y,
            row3.z - row0.z,
            row3.w - row0.w,
        );

        // Bottom: row3 + row1
        frustum.planes[2] = normalizePlane(
            row3.x + row1.x,
            row3.y + row1.y,
            row3.z + row1.z,
            row3.w + row1.w,
        );

        // Top: row3 - row1
        frustum.planes[3] = normalizePlane(
            row3.x - row1.x,
            row3.y - row1.y,
            row3.z - row1.z,
            row3.w - row1.w,
        );

        // Near: row2 (for Vulkan [0,1] depth range, clip.z >= 0)
        frustum.planes[4] = normalizePlane(
            row2.x,
            row2.y,
            row2.z,
            row2.w,
        );

        // Far: row3 - row2
        frustum.planes[5] = normalizePlane(
            row3.x - row2.x,
            row3.y - row2.y,
            row3.z - row2.z,
            row3.w - row2.w,
        );

        return frustum;
    }

    /// Check if the frustum is valid (not from an identity/degenerate matrix)
    pub fn isValid(self: Frustum) bool {
        // A valid frustum should have reasonable plane normals
        // If all planes have tiny normals, it's probably from an identity matrix
        var valid_planes: usize = 0;
        for (self.planes) |plane| {
            const len_sq = plane.normal.x * plane.normal.x +
                plane.normal.y * plane.normal.y +
                plane.normal.z * plane.normal.z;
            if (len_sq > 0.5) { // Should be ~1.0 for normalized planes
                valid_planes += 1;
            }
        }
        if (valid_planes < 4) return false;

        // Additional check: A real perspective frustum has near/far planes with
        // different distances. If near.d and far.d are too similar (like both ~1),
        // it's probably from an identity or degenerate matrix.
        const near_d = @abs(self.planes[4].d);
        const far_d = @abs(self.planes[5].d);

        // For a real camera, far is typically much larger than near
        // Identity matrix gives near.d=1, far.d=1 which is invalid
        if (far_d < 2.0 and near_d < 2.0) {
            // Both planes very close to origin - likely identity matrix
            return false;
        }

        return true;
    }

    /// Test if an AABB is visible (intersects or is inside the frustum)
    /// Returns true if the AABB should be rendered
    pub fn testAABB(self: Frustum, aabb: AABB) bool {
        for (self.planes) |plane| {
            // Find the positive vertex (furthest along plane normal)
            const p = Vec3.init(
                if (plane.normal.x >= 0) aabb.max.x else aabb.min.x,
                if (plane.normal.y >= 0) aabb.max.y else aabb.min.y,
                if (plane.normal.z >= 0) aabb.max.z else aabb.min.z,
            );

            // If positive vertex is behind the plane, AABB is fully outside
            if (plane.distanceToPoint(p) < 0) {
                return false;
            }
        }

        return true;
    }

    /// Test if a sphere is visible
    pub fn testSphere(self: Frustum, center: Vec3, radius: f32) bool {
        for (self.planes) |plane| {
            if (plane.distanceToPoint(center) < -radius) {
                return false;
            }
        }
        return true;
    }
};

fn normalizePlane(a: f32, b: f32, c: f32, d: f32) Plane {
    const len = @sqrt(a * a + b * b + c * c);
    if (len == 0) {
        return Plane{ .normal = Vec3.init(0, 1, 0), .d = 0 };
    }
    const inv_len = 1.0 / len;
    return Plane{
        .normal = Vec3.init(a * inv_len, b * inv_len, c * inv_len),
        .d = d * inv_len,
    };
}
