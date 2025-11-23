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
        var result = Mat4.zero();
        var i: usize = 0;
        while (i < 4) : (i += 1) {
            var j: usize = 0;
            while (j < 4) : (j += 1) {
                var sum: f32 = 0.0;
                var k: usize = 0;
                while (k < 4) : (k += 1) {
                    // Column-major: data[col * 4 + row]
                    // C[row=j, col=i] = sum(A[row=j, col=k] * B[row=k, col=i])
                    // A index: k * 4 + j
                    // B index: i * 4 + k
                    sum += self.data[k * 4 + j] * other.data[i * 4 + k];
                }
                result.data[i * 4 + j] = sum;
            }
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
