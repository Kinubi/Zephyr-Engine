const std = @import("std");
const builtin = @import("builtin");

comptime {
    const target = builtin.target;
    if (target.cpu.arch != .x86 and target.cpu.arch != .x86_64) {
        @compileError("Zephyr-Engine ECS requires an x86/x86_64 target with AVX2 support");
    }
    if (!target.cpu.features.isEnabled(@intFromEnum(std.Target.x86.Feature.avx2))) {
        @compileError("Zephyr-Engine ECS requires AVX2-capable CPUs");
    }
}

pub const lanes_f32 = 8;
pub const lanes_u32 = 8;

pub const F32x8 = @Vector(lanes_f32, f32);
pub const U32x8 = @Vector(lanes_u32, u32);

pub const Vec3x8 = struct {
    x: F32x8,
    y: F32x8,
    z: F32x8,
};

pub const Vec4x8 = struct {
    x: F32x8,
    y: F32x8,
    z: F32x8,
    w: F32x8,
};

pub inline fn splatF32(value: f32) F32x8 {
    return @splat(value);
}

pub inline fn splatU32(value: u32) U32x8 {
    return @splat(value);
}

pub inline fn loadU32(slice: []const u32) U32x8 {
    std.debug.assert(slice.len >= lanes_u32);
    const chunk: [lanes_u32]u32 = slice[0..lanes_u32].*;
    return @bitCast(chunk);
}

pub inline fn storeU32(slice: []u32, vec: U32x8) void {
    std.debug.assert(slice.len >= lanes_u32);
    const tmp: [lanes_u32]u32 = @bitCast(vec);
    std.mem.copyForwards(u32, slice[0..lanes_u32], tmp[0..]);
}

pub inline fn fillU32(slice: []u32, value: u32) void {
    const simd_chunk = splatU32(value);
    var i: usize = 0;
    while (i + lanes_u32 <= slice.len) : (i += lanes_u32) {
        storeU32(slice[i .. i + lanes_u32], simd_chunk);
    }
    while (i < slice.len) : (i += 1) {
        slice[i] = value;
    }
}

pub inline fn bitmaskEqualU32(slice: []const u32, target: u32) u32 {
    var mask: u32 = 0;
    var offset: u32 = 0;
    const target_vec = splatU32(target);
    var i: usize = 0;
    while (i + lanes_u32 <= slice.len) : (i += lanes_u32) {
        const chunk = loadU32(slice[i .. i + lanes_u32]);
        const cmp = chunk == target_vec;
        const sub_mask = std.simd.bitMask(cmp);
        mask |= @as(u32, sub_mask) << offset;
        offset += lanes_u32;
    }
    while (i < slice.len) : (i += 1) {
        if (slice[i] == target) {
            mask |= (@as(u32, 1) << offset);
        }
        offset += 1;
    }
    return mask;
}

pub inline fn firstMatchIndex(mask: u32) ?usize {
    if (mask == 0) return null;
    return @ctz(mask);
}

pub inline fn packRow(row: [4]f32) F32x8 {
    return F32x8{
        row[0], row[1], row[2], row[3],
        row[0], row[1], row[2], row[3],
    };
}

pub inline fn packColumns(col_a: [4]f32, col_b: [4]f32) F32x8 {
    return F32x8{
        col_a[0], col_a[1], col_a[2], col_a[3],
        col_b[0], col_b[1], col_b[2], col_b[3],
    };
}

fn reduce4(vec: @Vector(4, f32)) f32 {
    const arr: [4]f32 = @bitCast(vec);
    return arr[0] + arr[1] + arr[2] + arr[3];
}

pub inline fn dot4x2(row: [4]f32, cols: F32x8) [2]f32 {
    const row_vec = packRow(row);
    const mul = row_vec * cols;
    const lo_mask = @Vector(4, i32){ 0, 1, 2, 3 };
    const hi_mask = @Vector(4, i32){ 4, 5, 6, 7 };
    const lo = @shuffle(f32, mul, undefined, lo_mask);
    const hi = @shuffle(f32, mul, undefined, hi_mask);
    return .{ reduce4(lo), reduce4(hi) };
}

pub inline fn buildColumnPair(matrix: []const f32, col_a: usize, col_b: usize) F32x8 {
    std.debug.assert(matrix.len >= 16);
    const col0 = [_]f32{
        matrix[0 * 4 + col_a],
        matrix[1 * 4 + col_a],
        matrix[2 * 4 + col_a],
        matrix[3 * 4 + col_a],
    };
    const col1 = [_]f32{
        matrix[0 * 4 + col_b],
        matrix[1 * 4 + col_b],
        matrix[2 * 4 + col_b],
        matrix[3 * 4 + col_b],
    };
    return packColumns(col0, col1);
}

// ============================================================================
// Transform System SIMD Helpers
// ============================================================================

/// Load 8 f32 values from a slice (for loading Vec3/Vec4 components)
pub inline fn loadF32x8(slice: []const f32) F32x8 {
    std.debug.assert(slice.len >= lanes_f32);
    const chunk: [lanes_f32]f32 = slice[0..lanes_f32].*;
    return @bitCast(chunk);
}

/// Store 8 f32 values to a slice
pub inline fn storeF32x8(slice: []f32, vec: F32x8) void {
    std.debug.assert(slice.len >= lanes_f32);
    const tmp: [lanes_f32]f32 = @bitCast(vec);
    std.mem.copyForwards(f32, slice[0..lanes_f32], tmp[0..]);
}

/// Batch build TRS matrices for 8 transforms
/// Input: positions, scales (8 of each component x, y, z)
/// Output: 8 matrices stored sequentially in output buffer
/// NOTE: This version handles Translation and Scale only (no rotation yet)
pub fn batchBuildTRSMatrices(
    pos_x: F32x8,
    pos_y: F32x8,
    pos_z: F32x8,
    scale_x: F32x8,
    scale_y: F32x8,
    scale_z: F32x8,
    output: []f32, // Must be at least 128 floats (8 matrices * 16 floats)
) void {
    std.debug.assert(output.len >= 128);

    // Build 8 TRS matrices in parallel using proper SIMD operations
    // We'll construct matrices in SoA (Structure of Arrays) format, then transpose to AoS
    // Matrix layout (row-major in memory, since Vulkan expects row-major [3][4]):
    // Each matrix is 16 floats: [m0 m1 m2 m3 m4 m5 m6 m7 m8 m9 m10 m11 m12 m13 m14 m15]

    const zero: F32x8 = @splat(0.0);
    const one: F32x8 = @splat(1.0);

    // Build matrix rows as SIMD vectors (8 matrices worth of each row element)
    // For simple TRS (no rotation), the matrix structure is:
    // [sx  0   0   px]
    // [0   sy  0   py]
    // [0   0   sz  pz]
    // [0   0   0   1 ]

    // We need to transpose from SoA (8 values per matrix element) to AoS (16 elements per matrix)
    // Transpose and store: convert from 16 vectors of 8 elements to 8 matrices of 16 elements
    // For each matrix element position, we have a vector of 8 values (one per matrix)
    comptime var elem: usize = 0;
    inline while (elem < 16) : (elem += 1) {
        const vec = switch (elem) {
            0 => scale_x, // m0: scale_x for all 8 matrices
            1 => zero, // m1: 0
            2 => zero, // m2: 0
            3 => zero, // m3: 0
            4 => zero, // m4: 0
            5 => scale_y, // m5: scale_y for all 8 matrices
            6 => zero, // m6: 0
            7 => zero, // m7: 0
            8 => zero, // m8: 0
            9 => zero, // m9: 0
            10 => scale_z, // m10: scale_z for all 8 matrices
            11 => zero, // m11: 0
            12 => pos_x, // m12: pos_x for all 8 matrices
            13 => pos_y, // m13: pos_y for all 8 matrices
            14 => pos_z, // m14: pos_z for all 8 matrices
            15 => one, // m15: 1
            else => unreachable,
        };
        const arr: [8]f32 = @bitCast(vec);

        // Write this element to all 8 matrices
        comptime var mat: usize = 0;
        inline while (mat < 8) : (mat += 1) {
            output[mat * 16 + elem] = arr[mat];
        }
    }
}

/// Check if 8 boolean flags are all false (returns true if all false)
pub inline fn allFalse(flags: [8]bool) bool {
    return @as(u8, @bitCast(flags)) == 0;
}

// ============================================================================
// General SIMD Math Helpers (Vec3/Vec4 batched ops)
// ============================================================================

/// Load 8 Vec3 values from three separate SoA slices (x[], y[], z[])
pub inline fn loadVec3x8(xs: []const f32, ys: []const f32, zs: []const f32) Vec3x8 {
    std.debug.assert(xs.len >= lanes_f32 and ys.len >= lanes_f32 and zs.len >= lanes_f32);
    const cx: [lanes_f32]f32 = xs[0..lanes_f32].*;
    const cy: [lanes_f32]f32 = ys[0..lanes_f32].*;
    const cz: [lanes_f32]f32 = zs[0..lanes_f32].*;
    return Vec3x8{ .x = @bitCast(cx), .y = @bitCast(cy), .z = @bitCast(cz) };
}

/// Store 8 Vec3 values into three separate SoA slices
pub inline fn storeVec3x8(xs: []f32, ys: []f32, zs: []f32, x: F32x8, y: F32x8, z: F32x8) void {
    std.debug.assert(xs.len >= lanes_f32 and ys.len >= lanes_f32 and zs.len >= lanes_f32);
    const tx: [lanes_f32]f32 = @bitCast(x);
    const ty: [lanes_f32]f32 = @bitCast(y);
    const tz: [lanes_f32]f32 = @bitCast(z);
    std.mem.copyForwards(f32, xs[0..lanes_f32], tx[0..]);
    std.mem.copyForwards(f32, ys[0..lanes_f32], ty[0..]);
    std.mem.copyForwards(f32, zs[0..lanes_f32], tz[0..]);
}

/// Dot product per-lane for 3D vectors
pub inline fn dot3x8(ax: F32x8, ay: F32x8, az: F32x8, bx: F32x8, by: F32x8, bz: F32x8) F32x8 {
    return (ax * bx) + (ay * by) + (az * bz);
}

/// Cross product per-lane for 3D vectors
pub inline fn cross3x8(ax: F32x8, ay: F32x8, az: F32x8, bx: F32x8, by: F32x8, bz: F32x8) Vec3x8 {
    const cx = (ay * bz) - (az * by);
    const cy = (az * bx) - (ax * bz);
    const cz = (ax * by) - (ay * bx);
    return Vec3x8{ .x = cx, .y = cy, .z = cz };
}

/// Length per-lane for 3D vectors
pub inline fn length3x8(ax: F32x8, ay: F32x8, az: F32x8) F32x8 {
    const d = dot3x8(ax, ay, az, ax, ay, az);
    // safe sqrt of each lane
    return @sqrt(d);
}

/// Normalize per-lane for 3D vectors. Uses small epsilon to avoid div-by-zero.
pub inline fn normalize3x8(ax: F32x8, ay: F32x8, az: F32x8) Vec3x8 {
    const eps = splatF32(1e-8);
    const len_sq = dot3x8(ax, ay, az, ax, ay, az);
    const len = @sqrt(len_sq + eps);
    const inv_len = splatF32(1.0) / len;
    return Vec3x8{ .x = ax * inv_len, .y = ay * inv_len, .z = az * inv_len };
}

/// Compare each lane `vec >= scalar` and return a bitmask (lane0 in LSB)
pub inline fn cmp_ge_mask(vec: F32x8, scalar: f32) u32 {
    const cmp = vec >= splatF32(scalar);
    return @as(u32, std.simd.bitMask(cmp));
}

/// Convert a 8-bit mask into indices written into `out`. Returns number of indices written.
pub inline fn maskToIndices(mask: u32, out: []usize) usize {
    var count: usize = 0;
    var m: u32 = mask;
    while (m != 0) : (m = m & (m - 1)) {
        const tz = @ctz(m);
        if (count < out.len) out[count] = @as(usize, tz);
        count += 1;
    }
    return count;
}

/// Multiply 8 matrices (SoA columns) by 8 Vec4s (SoA vectors). Columns are provided per-component as F32x8.
/// Column layout: col0x, col0y, col0z, col0w represent the first column across 8 matrices, etc.
pub inline fn mulMat4Vec4SoA(
    col0x: F32x8,
    col0y: F32x8,
    col0z: F32x8,
    col0w: F32x8,
    col1x: F32x8,
    col1y: F32x8,
    col1z: F32x8,
    col1w: F32x8,
    col2x: F32x8,
    col2y: F32x8,
    col2z: F32x8,
    col2w: F32x8,
    col3x: F32x8,
    col3y: F32x8,
    col3z: F32x8,
    col3w: F32x8,
    vx: F32x8,
    vy: F32x8,
    vz: F32x8,
    vw: F32x8,
) Vec4x8 {
    const rx = (col0x * vx) + (col1x * vy) + (col2x * vz) + (col3x * vw);
    const ry = (col0y * vx) + (col1y * vy) + (col2y * vz) + (col3y * vw);
    const rz = (col0z * vx) + (col1z * vy) + (col2z * vz) + (col3z * vw);
    const rw = (col0w * vx) + (col1w * vy) + (col2w * vz) + (col3w * vw);
    return Vec4x8{ .x = rx, .y = ry, .z = rz, .w = rw };
}
