const std = @import("std");
const builtin = @import("builtin");

comptime {
    const target = builtin.target;
    if (target.cpu.arch != .x86 and target.cpu.arch != .x86_64) {
        @compileError("ZulkanZengine ECS requires an x86/x86_64 target with AVX2 support");
    }
    if (!target.cpu.features.isEnabled(@intFromEnum(std.Target.x86.Feature.avx2))) {
        @compileError("ZulkanZengine ECS requires AVX2-capable CPUs");
    }
}

pub const lanes_f32 = 8;
pub const lanes_u32 = 8;

pub const F32x8 = @Vector(lanes_f32, f32);
pub const U32x8 = @Vector(lanes_u32, u32);

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
    std.mem.copy(u32, slice[0..lanes_u32], tmp[0..]);
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
