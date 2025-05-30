// This file is a copy of mach's math module for local use.
// Add your math types, functions, and constants here as needed.
// You can expand this as your project requires.

// Example: re-export everything from mach's math module (to be replaced with actual code)
// pub usingnamespace @import("mach").math;

// TODO: Copy the relevant code from mach's math module here.

// Minimal math library based on mach's math.zig
// You can expand this as needed for your project.

const std = @import("std");

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
        var result: [16]f32 = undefined;
        for (0..4) |row| {
            for (0..4) |col| {
                var sum: f32 = 0;
                for (0..4) |i| {
                    sum += self.data[row * 4 + i] * other.data[i * 4 + col];
                }
                result[row * 4 + col] = sum;
            }
        }
        return Mat4{ .data = result };
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
