//! Minimal column-major 4x4 matrix helpers (element [col * 4 + row]) for a
//! right-handed view space and WebGPU's 0..1 clip-space depth.

const std = @import("std");

pub const Mat4 = [16]f32;
pub const Vec3 = [3]f32;

pub const identity: Mat4 = .{
    1, 0, 0, 0,
    0, 1, 0, 0,
    0, 0, 1, 0,
    0, 0, 0, 1,
};

pub fn mul(a: Mat4, b: Mat4) Mat4 {
    var out: Mat4 = undefined;
    for (0..4) |c| {
        for (0..4) |r| {
            var sum: f32 = 0;
            for (0..4) |k| sum += a[k * 4 + r] * b[c * 4 + k];
            out[c * 4 + r] = sum;
        }
    }
    return out;
}

pub fn perspective(fovy: f32, aspect: f32, near: f32, far: f32) Mat4 {
    const f = 1.0 / @tan(fovy / 2.0);
    var m: Mat4 = @splat(0);
    m[0] = f / aspect;
    m[5] = f;
    m[10] = far / (near - far);
    m[11] = -1;
    m[14] = near * far / (near - far);
    return m;
}

fn sub(a: Vec3, b: Vec3) Vec3 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}

fn dot(a: Vec3, b: Vec3) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

fn cross(a: Vec3, b: Vec3) Vec3 {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

fn normalize(a: Vec3) Vec3 {
    const l = @sqrt(dot(a, a));
    return .{ a[0] / l, a[1] / l, a[2] / l };
}

pub fn lookAt(eye: Vec3, center: Vec3, up: Vec3) Mat4 {
    const f = normalize(sub(center, eye));
    const s = normalize(cross(f, up));
    const u = cross(s, f);
    return .{
        s[0],         u[0],         -f[0],       0,
        s[1],         u[1],         -f[1],       0,
        s[2],         u[2],         -f[2],       0,
        -dot(s, eye), -dot(u, eye), dot(f, eye), 1,
    };
}

pub fn rotateY(t: f32) Mat4 {
    const c = @cos(t);
    const s = @sin(t);
    return .{
        c, 0, -s, 0,
        0, 1, 0,  0,
        s, 0, c,  0,
        0, 0, 0,  1,
    };
}

pub fn rotateX(t: f32) Mat4 {
    const c = @cos(t);
    const s = @sin(t);
    return .{
        1, 0,  0, 0,
        0, c,  s, 0,
        0, -s, c, 0,
        0, 0,  0, 1,
    };
}

test "perspective maps near plane to depth 0 and far to 1" {
    const m = perspective(1.0, 1.0, 0.1, 10.0);
    const near = [4]f32{ 0, 0, -0.1, 1 };
    const far = [4]f32{ 0, 0, -10.0, 1 };
    inline for (.{ .{ near, 0.0 }, .{ far, 1.0 } }) |case| {
        var clip: [4]f32 = undefined;
        for (0..4) |r| {
            var sum: f32 = 0;
            for (0..4) |k| sum += m[k * 4 + r] * case[0][k];
            clip[r] = sum;
        }
        try std.testing.expectApproxEqAbs(@as(f32, case[1]), clip[2] / clip[3], 1e-5);
    }
}

test "lookAt puts the eye at the origin and the target on -z" {
    const v = lookAt(.{ 0, 0, 5 }, .{ 0, 0, 0 }, .{ 0, 1, 0 });
    // target (0,0,0) -> view (0,0,-5)
    try std.testing.expectApproxEqAbs(@as(f32, -5), v[14], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0), v[12], 1e-5);
}

test "mul identity" {
    const m = rotateY(0.7);
    const r = mul(identity, m);
    for (m, r) |a, b| try std.testing.expectApproxEqAbs(a, b, 1e-6);
}
