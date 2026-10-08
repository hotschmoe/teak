//! Small, allocation-free linear algebra for the scene helpers.
//!
//! Conventions match `core/scene.zig`: right-handed world, column-major
//! `Mat4` (`m[col * 4 + row]`), clip space with z in 0..1 (WebGPU), +y up.
//! `Affine` is a 3x4 row-major affine transform (the `Item.transform` layout:
//! `a[row * 4 + col]`, last column = translation).

const std = @import("std");

pub const Vec3 = [3]f32;
pub const Mat4 = [16]f32;
/// 3x4 affine transform, row-major (three rows of `[x_axis, y_axis, z_axis, translation]`).
pub const Affine = [12]f32;

pub const identity4: Mat4 = .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
pub const identity_affine: Affine = .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0 };

pub fn add(a: Vec3, b: Vec3) Vec3 {
    return .{ a[0] + b[0], a[1] + b[1], a[2] + b[2] };
}
pub fn sub(a: Vec3, b: Vec3) Vec3 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}
pub fn scale(a: Vec3, s: f32) Vec3 {
    return .{ a[0] * s, a[1] * s, a[2] * s };
}
pub fn dot(a: Vec3, b: Vec3) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}
pub fn cross(a: Vec3, b: Vec3) Vec3 {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}
pub fn length(a: Vec3) f32 {
    return @sqrt(dot(a, a));
}
/// Unit vector; a degenerate (near-zero) input yields `fallback`.
pub fn normalizeOr(a: Vec3, fallback: Vec3) Vec3 {
    const l = length(a);
    if (!(l > 1e-20)) return fallback;
    return scale(a, 1 / l);
}
pub fn normalize(a: Vec3) Vec3 {
    return normalizeOr(a, .{ 0, 0, 1 });
}
pub fn lerp(a: Vec3, b: Vec3, t: f32) Vec3 {
    return add(a, scale(sub(b, a), t));
}
pub fn minV(a: Vec3, b: Vec3) Vec3 {
    return .{ @min(a[0], b[0]), @min(a[1], b[1]), @min(a[2], b[2]) };
}
pub fn maxV(a: Vec3, b: Vec3) Vec3 {
    return .{ @max(a[0], b[0]), @max(a[1], b[1]), @max(a[2], b[2]) };
}

/// C = A * B (column-major).
pub fn mul(a: Mat4, b: Mat4) Mat4 {
    var c: Mat4 = undefined;
    for (0..4) |col| for (0..4) |row| {
        var s: f32 = 0;
        for (0..4) |k| s += a[k * 4 + row] * b[col * 4 + k];
        c[col * 4 + row] = s;
    };
    return c;
}

/// Homogeneous transform of a point: returns `(x, y, z, w)`.
pub fn transformPoint4(m: Mat4, p: Vec3) [4]f32 {
    var r: [4]f32 = undefined;
    for (0..4) |row| r[row] = m[row] * p[0] + m[4 + row] * p[1] + m[8 + row] * p[2] + m[12 + row];
    return r;
}

/// Right-handed look-at view matrix. A `up` parallel to the view direction
/// falls back to a stable arbitrary right vector.
pub fn lookAt(eye: Vec3, target: Vec3, up: Vec3) Mat4 {
    const f = normalize(sub(target, eye));
    var s = cross(f, up);
    if (dot(s, s) < 1e-12) s = .{ 1, 0, 0 };
    s = normalize(s);
    const u = cross(s, f);
    return .{
        s[0],         u[0],         -f[0],       0,
        s[1],         u[1],         -f[1],       0,
        s[2],         u[2],         -f[2],       0,
        -dot(s, eye), -dot(u, eye), dot(f, eye), 1,
    };
}

/// Perspective projection, depth 0..1.
pub fn perspective(fovy: f32, aspect: f32, near: f32, far: f32) Mat4 {
    const f = 1.0 / @tan(fovy * 0.5);
    return .{
        f / aspect, 0, 0,                           0,
        0,          f, 0,                           0,
        0,          0, far / (near - far),          -1,
        0,          0, (far * near) / (near - far), 0,
    };
}

/// Orthographic projection from a half-height and aspect, depth 0..1.
/// `near` may be negative (geometry behind the eye plane stays visible).
pub fn orthographic(half_h: f32, aspect: f32, near: f32, far: f32) Mat4 {
    const hw = half_h * aspect;
    return .{
        1 / hw, 0,          0,                   0,
        0,      1 / half_h, 0,                   0,
        0,      0,          1 / (near - far),    0,
        0,      0,          near / (near - far), 1,
    };
}

/// General 4x4 inverse (cofactor expansion); null when singular.
pub fn invert(m: Mat4) ?Mat4 {
    var inv: Mat4 = undefined;
    inv[0] = m[5] * m[10] * m[15] - m[5] * m[11] * m[14] - m[9] * m[6] * m[15] + m[9] * m[7] * m[14] + m[13] * m[6] * m[11] - m[13] * m[7] * m[10];
    inv[4] = -m[4] * m[10] * m[15] + m[4] * m[11] * m[14] + m[8] * m[6] * m[15] - m[8] * m[7] * m[14] - m[12] * m[6] * m[11] + m[12] * m[7] * m[10];
    inv[8] = m[4] * m[9] * m[15] - m[4] * m[11] * m[13] - m[8] * m[5] * m[15] + m[8] * m[7] * m[13] + m[12] * m[5] * m[11] - m[12] * m[7] * m[9];
    inv[12] = -m[4] * m[9] * m[14] + m[4] * m[10] * m[13] + m[8] * m[5] * m[14] - m[8] * m[6] * m[13] - m[12] * m[5] * m[10] + m[12] * m[6] * m[9];
    inv[1] = -m[1] * m[10] * m[15] + m[1] * m[11] * m[14] + m[9] * m[2] * m[15] - m[9] * m[3] * m[14] - m[13] * m[2] * m[11] + m[13] * m[3] * m[10];
    inv[5] = m[0] * m[10] * m[15] - m[0] * m[11] * m[14] - m[8] * m[2] * m[15] + m[8] * m[3] * m[14] + m[12] * m[2] * m[11] - m[12] * m[3] * m[10];
    inv[9] = -m[0] * m[9] * m[15] + m[0] * m[11] * m[13] + m[8] * m[1] * m[15] - m[8] * m[3] * m[13] - m[12] * m[1] * m[11] + m[12] * m[3] * m[9];
    inv[13] = m[0] * m[9] * m[14] - m[0] * m[10] * m[13] - m[8] * m[1] * m[14] + m[8] * m[2] * m[13] + m[12] * m[1] * m[10] - m[12] * m[2] * m[9];
    inv[2] = m[1] * m[6] * m[15] - m[1] * m[7] * m[14] - m[5] * m[2] * m[15] + m[5] * m[3] * m[14] + m[13] * m[2] * m[7] - m[13] * m[3] * m[6];
    inv[6] = -m[0] * m[6] * m[15] + m[0] * m[7] * m[14] + m[4] * m[2] * m[15] - m[4] * m[3] * m[14] - m[12] * m[2] * m[7] + m[12] * m[3] * m[6];
    inv[10] = m[0] * m[5] * m[15] - m[0] * m[7] * m[13] - m[4] * m[1] * m[15] + m[4] * m[3] * m[13] + m[12] * m[1] * m[7] - m[12] * m[3] * m[5];
    inv[14] = -m[0] * m[5] * m[14] + m[0] * m[6] * m[13] + m[4] * m[1] * m[14] - m[4] * m[2] * m[13] - m[12] * m[1] * m[6] + m[12] * m[2] * m[5];
    inv[3] = -m[1] * m[6] * m[11] + m[1] * m[7] * m[10] + m[5] * m[2] * m[11] - m[5] * m[3] * m[10] - m[9] * m[2] * m[7] + m[9] * m[3] * m[6];
    inv[7] = m[0] * m[6] * m[11] - m[0] * m[7] * m[10] - m[4] * m[2] * m[11] + m[4] * m[3] * m[10] + m[8] * m[2] * m[7] - m[8] * m[3] * m[6];
    inv[11] = -m[0] * m[5] * m[11] + m[0] * m[7] * m[9] + m[4] * m[1] * m[11] - m[4] * m[3] * m[9] - m[8] * m[1] * m[7] + m[8] * m[3] * m[5];
    inv[15] = m[0] * m[5] * m[10] - m[0] * m[6] * m[9] - m[4] * m[1] * m[10] + m[4] * m[2] * m[9] + m[8] * m[1] * m[6] - m[8] * m[2] * m[5];
    const det = m[0] * inv[0] + m[1] * inv[4] + m[2] * inv[8] + m[3] * inv[12];
    if (!(@abs(det) > 1e-30)) return null;
    const r = 1 / det;
    for (&inv) |*v| v.* *= r;
    return inv;
}

/// Apply an affine transform to a point.
pub fn affinePoint(a: Affine, p: Vec3) Vec3 {
    return .{
        a[0] * p[0] + a[1] * p[1] + a[2] * p[2] + a[3],
        a[4] * p[0] + a[5] * p[1] + a[6] * p[2] + a[7],
        a[8] * p[0] + a[9] * p[1] + a[10] * p[2] + a[11],
    };
}

/// Apply only the linear part (directions, not translated).
pub fn affineDir(a: Affine, d: Vec3) Vec3 {
    return .{
        a[0] * d[0] + a[1] * d[1] + a[2] * d[2],
        a[4] * d[0] + a[5] * d[1] + a[6] * d[2],
        a[8] * d[0] + a[9] * d[1] + a[10] * d[2],
    };
}

/// Inverse of an affine transform; null when the linear part is singular.
pub fn affineInverse(a: Affine) ?Affine {
    const c0 = Vec3{ a[0], a[4], a[8] };
    const c1 = Vec3{ a[1], a[5], a[9] };
    const c2 = Vec3{ a[2], a[6], a[10] };
    const r0 = cross(c1, c2);
    const r1 = cross(c2, c0);
    const r2 = cross(c0, c1);
    const det = dot(c0, r0);
    if (!(@abs(det) > 1e-30)) return null;
    const k = 1 / det;
    // inverse linear part has rows r0, r1, r2 (scaled by 1/det)
    var out: Affine = undefined;
    const rows = [3]Vec3{ scale(r0, k), scale(r1, k), scale(r2, k) };
    const t = Vec3{ a[3], a[7], a[11] };
    for (rows, 0..) |row, i| {
        out[i * 4 + 0] = row[0];
        out[i * 4 + 1] = row[1];
        out[i * 4 + 2] = row[2];
        out[i * 4 + 3] = -dot(row, t);
    }
    return out;
}

/// Build an affine from a translation (identity rotation).
pub fn translation(t: Vec3) Affine {
    return .{ 1, 0, 0, t[0], 0, 1, 0, t[1], 0, 0, 1, t[2] };
}

const expectApproxEqAbs = std.testing.expectApproxEqAbs;

test "mul identity and invert round trip" {
    const p = perspective(0.7, 1.5, 0.5, 100);
    const v = lookAt(.{ 3, 4, 5 }, .{ 0, 0, 0 }, .{ 0, 1, 0 });
    const m = mul(p, v);
    const inv = invert(m).?;
    const id = mul(inv, m);
    for (0..16) |i| try expectApproxEqAbs(identity4[i], id[i], 2e-4);
    try std.testing.expect(invert(@as(Mat4, @splat(0))) == null);
}

test "affine inverse undoes transform" {
    const a: Affine = .{ 0, -2, 0, 5, 2, 0, 0, -1, 0, 0, 3, 7 };
    const inv = affineInverse(a).?;
    const p = Vec3{ 1.5, -2, 0.25 };
    const q = affinePoint(inv, affinePoint(a, p));
    for (0..3) |i| try expectApproxEqAbs(p[i], q[i], 1e-5);
    try std.testing.expect(affineInverse(.{ 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0 }) == null);
}

test "orthographic maps the box to the clip cube" {
    const m = orthographic(2, 2, -1, 3);
    const lo = transformPoint4(m, .{ -4, -2, 1 }); // eye space z=+1 is behind view dir; near=-1 -> z=-near
    try expectApproxEqAbs(@as(f32, -1), lo[0], 1e-6);
    try expectApproxEqAbs(@as(f32, -1), lo[1], 1e-6);
    // eye-space z = -near -> depth 0, z = -far -> depth 1
    try expectApproxEqAbs(@as(f32, 0), transformPoint4(m, .{ 0, 0, 1 })[2], 1e-6);
    try expectApproxEqAbs(@as(f32, 1), transformPoint4(m, .{ 0, 0, -3 })[2], 1e-6);
}

test "lookAt degenerate up does not produce NaN" {
    const v = lookAt(.{ 0, 5, 0 }, .{ 0, 0, 0 }, .{ 0, 1, 0 });
    for (v) |x| try std.testing.expect(!std.math.isNan(x));
}
