//! Orbit camera, projection modes, pointer-driven navigation, picking rays.
//!
//! Pure data + pure functions (HARDLINE: the `Orbit` lives in the app's
//! `Model` and is mutated only in `update`; `camera()` is called from `view`).
//! The output is the existing `Camera` Cmd payload, so perspective vs
//! orthographic is *only* a matrix choice — no renderer change.
//!
//! Conventions: right-handed world, depth 0..1 (WebGPU). `yaw` rotates the
//! eye around the up axis (`yaw = 0` puts the eye on the +Z side of the
//! target for Y-up), `pitch` lifts it toward the up axis. Z-up is the same
//! rig rotated so `+Z` is up (`front` then looks along +Y).

const std = @import("std");
const mat = @import("mat.zig");
const scene = @import("../scene.zig");
const pointer = @import("../pointer.zig");

pub const Vec3 = mat.Vec3;
pub const Mat4 = mat.Mat4;
pub const Camera = scene.Camera;

/// World-space ray. `dir` is a unit vector when produced by `pickRay`.
pub const Ray = struct { origin: Vec3, dir: Vec3 };

/// Axis-aligned bounds, used to derive near/far and for `Orbit.frame`.
pub const Bounds = struct {
    lo: Vec3,
    hi: Vec3,

    pub fn center(self: Bounds) Vec3 {
        return mat.scale(mat.add(self.lo, self.hi), 0.5);
    }
    /// Radius of the bounding sphere around `center()`.
    pub fn radius(self: Bounds) f32 {
        return 0.5 * mat.length(mat.sub(self.hi, self.lo));
    }
};

/// Vertical field of view used by orthographic mode to define its extent
/// (`half_height = dist * tan(ortho_fov_y / 2)`), so toggling keeps the
/// apparent size at the target.
pub const ortho_fov_y: f32 = 0.7;

pub const Projection = union(enum) {
    perspective: struct { fov_y: f32 = 0.7 },
    /// Extent comes from `Orbit.dist` (see `ortho_fov_y`).
    ortho,
};

pub const Orbit = struct {
    target: Vec3 = .{ 0, 0, 0 },
    yaw: f32 = -0.62,
    /// Clamped to +-`max_pitch` so the rig never flips at the poles.
    pitch: f32 = 0.5,
    /// Perspective: eye distance. Ortho: half-height = dist * tan(fov/2).
    dist: f32 = 10,
    up: enum { y, z } = .y,
    projection: Projection = .{ .perspective = .{} },
    /// Explicit clip range; null derives it from `bounds` (or from `dist`).
    near_far: ?[2]f32 = null,

    pub const max_pitch: f32 = std.math.pi / 2.0 - 0.01;

    pub const Preset = enum { front, back, left, right, top, bottom, iso };

    pub fn setPreset(self: *Orbit, p: Preset) void {
        const hp = std.math.pi / 2.0;
        const yp: [2]f32 = switch (p) {
            .front => .{ 0, 0 },
            .back => .{ std.math.pi, 0 },
            .left => .{ -hp, 0 },
            .right => .{ hp, 0 },
            .top => .{ 0, max_pitch },
            .bottom => .{ 0, -max_pitch },
            .iso => .{ -0.62, 0.5 },
        };
        self.yaw = yp[0];
        self.pitch = yp[1];
    }

    /// Map a vector expressed in the Y-up rig frame into world space.
    fn toWorld(self: Orbit, v: Vec3) Vec3 {
        return switch (self.up) {
            .y => v,
            .z => .{ v[0], -v[2], v[1] },
        };
    }

    pub fn upVector(self: Orbit) Vec3 {
        return self.toWorld(.{ 0, 1, 0 });
    }

    pub fn eye(self: Orbit) Vec3 {
        const cp = @cos(self.pitch);
        const off = self.toWorld(.{ self.dist * cp * @sin(self.yaw), self.dist * @sin(self.pitch), self.dist * cp * @cos(self.yaw) });
        return mat.add(self.target, off);
    }

    /// Orthonormal view basis in world space.
    pub const Basis = struct { forward: Vec3, right: Vec3, up: Vec3 };

    pub fn basis(self: Orbit) Basis {
        const f = mat.normalize(mat.sub(self.target, self.eye()));
        const r = mat.normalizeOr(mat.cross(f, self.upVector()), .{ 1, 0, 0 });
        return .{ .forward = f, .right = r, .up = mat.cross(r, f) };
    }

    fn fovY(self: Orbit) f32 {
        return switch (self.projection) {
            .perspective => |p| p.fov_y,
            .ortho => ortho_fov_y,
        };
    }

    /// Half the visible height, in world units, on the plane through `target`.
    pub fn halfHeight(self: Orbit) f32 {
        return self.dist * @tan(self.fovY() * 0.5);
    }

    /// Switch perspective <-> ortho, keeping the apparent size at the target.
    pub fn toggleProjection(self: *Orbit) void {
        switch (self.projection) {
            .perspective => |p| {
                self.dist = self.dist * @tan(p.fov_y * 0.5) / @tan(ortho_fov_y * 0.5);
                self.projection = .ortho;
            },
            .ortho => self.projection = .{ .perspective = .{ .fov_y = ortho_fov_y } },
        }
    }

    /// Center on `lo..hi` and pick a distance so the bounding sphere fits the
    /// viewport (any aspect), in the current projection mode.
    pub fn frame(self: *Orbit, lo: Vec3, hi: Vec3, aspect: f32) void {
        const b = Bounds{ .lo = lo, .hi = hi };
        const r = @max(b.radius(), 1e-3);
        const a = if (aspect > 1e-3) aspect else 1;
        self.target = b.center();
        const fit_half = @tan(self.fovY() * 0.5) * @min(1, a); // tan of the narrower half-angle
        self.dist = switch (self.projection) {
            .perspective => r / @sin(std.math.atan(fit_half)),
            .ortho => r / fit_half,
        };
    }

    /// Input policy for `onEvent`.
    pub const Bindings = struct {
        orbit: pointer.Button = .left,
        pan: pointer.Button = .middle,
        /// Orbit-button drag with Shift pans instead of orbiting.
        pan_with_shift: bool = true,
        zoom_to_cursor: bool = true,
        orbit_speed: f32 = 0.008,
        /// Zoom factor per 100 px of wheel delta.
        zoom_step: f32 = 1.12,
        min_dist: f32 = 1e-3,
        max_dist: f32 = 1e7,
    };

    /// The whole navigation policy as one pure function. Feed it the
    /// `CanvasEvent`s `canvasMsg` forwarded (call from `update`). Returns true
    /// when the camera changed. Needs no drag state: `move` events carry
    /// deltas and the held buttons.
    pub fn onEvent(self: *Orbit, ev: pointer.CanvasEvent, b: Bindings) bool {
        switch (ev.kind) {
            .move => {
                if (ev.dx == 0 and ev.dy == 0) return false;
                const orbit_held = buttonHeld(ev.buttons, b.orbit);
                const pan_held = buttonHeld(ev.buttons, b.pan) or (orbit_held and b.pan_with_shift and ev.mods.shift);
                if (pan_held) {
                    self.panPx(ev.dx, ev.dy, ev.h);
                    return true;
                }
                if (orbit_held) {
                    self.rotate(ev.dx * b.orbit_speed, ev.dy * b.orbit_speed);
                    return true;
                }
                return false;
            },
            .wheel => {
                if (ev.dy == 0) return false;
                const notches = std.math.clamp(ev.dy / 100.0, -4, 4);
                const f = std.math.pow(f32, b.zoom_step, notches);
                if (b.zoom_to_cursor and ev.w > 0 and ev.h > 0) {
                    self.zoomAt(f, 2 * ev.x / ev.w - 1, 1 - 2 * ev.y / ev.h, ev.w / ev.h, b);
                } else {
                    self.dist = std.math.clamp(self.dist * f, b.min_dist, b.max_dist);
                }
                return true;
            },
            else => return false,
        }
    }

    /// Rotate by yaw/pitch deltas in radians (pitch is clamped).
    pub fn rotate(self: *Orbit, d_yaw: f32, d_pitch: f32) void {
        self.yaw -= d_yaw;
        self.pitch = std.math.clamp(self.pitch + d_pitch, -max_pitch, max_pitch);
        const tau = 2 * std.math.pi;
        if (self.yaw > std.math.pi) self.yaw -= tau else if (self.yaw < -std.math.pi) self.yaw += tau;
    }

    /// Pan by a screen delta in px: the point on the target plane under the
    /// cursor follows the cursor.
    pub fn panPx(self: *Orbit, dx_px: f32, dy_px: f32, viewport_h: f32) void {
        const k = 2 * self.halfHeight() / @max(viewport_h, 1);
        const bs = self.basis();
        self.target = mat.add(self.target, mat.add(mat.scale(bs.right, -dx_px * k), mat.scale(bs.up, dy_px * k)));
    }

    /// Scale `dist` by `factor` keeping the world point under NDC (nx, ny) on
    /// the target plane fixed on screen. Perspective dollies along the cursor
    /// ray; ortho rescales the extent. Both reduce to the same target shift.
    pub fn zoomAt(self: *Orbit, factor: f32, nx: f32, ny: f32, aspect: f32, b: Bindings) void {
        const new_dist = std.math.clamp(self.dist * factor, b.min_dist, b.max_dist);
        const f = new_dist / self.dist;
        const hh = self.halfHeight();
        const bs = self.basis();
        const off = mat.add(mat.scale(bs.right, nx * aspect * hh), mat.scale(bs.up, ny * hh));
        self.target = mat.add(self.target, mat.scale(off, 1 - f));
        self.dist = new_dist;
    }

    /// View-projection for a `w x h` logical-px viewport, as the `Camera` Cmd
    /// payload. Near/far come from `near_far`, else from `bounds` (sphere
    /// around its center) so the line depth bias stays meaningful at any
    /// scale, else from `dist`.
    pub fn camera(self: Orbit, w: f32, h: f32, bounds: ?Bounds) Camera {
        const e = self.eye();
        const aspect = if (h > 0 and w > 0) w / h else 1;
        const view = mat.lookAt(e, self.target, self.upVector());

        var near: f32 = undefined;
        var far: f32 = undefined;
        const persp = self.projection == .perspective;
        if (self.near_far) |nf| {
            near = nf[0];
            far = nf[1];
        } else if (bounds) |bd| {
            const d = mat.length(mat.sub(bd.center(), e));
            const r = bd.radius() * 1.01;
            far = @max(d + r, 1e-3);
            near = if (persp) @max(d - r, far * 1e-3) else d - r;
        } else if (persp) {
            near = @max(self.dist * 0.01, 1e-4);
            far = self.dist * 100;
        } else {
            near = -self.dist * 100;
            far = self.dist * 100;
        }
        const proj = switch (self.projection) {
            .perspective => |p| mat.perspective(p.fov_y, aspect, near, far),
            .ortho => mat.orthographic(self.halfHeight(), aspect, near, far),
        };
        return .{ .view_proj = mat.mul(proj, view), .eye = e };
    }
};

fn buttonHeld(held: pointer.Buttons, b: pointer.Button) bool {
    return switch (b) {
        .none => false,
        .left => held.left,
        .middle => held.middle,
        .right => held.right,
    };
}

fn isPerspective(cam: Camera) bool {
    return cam.view_proj[11] != 0;
}

/// World-space right and up vectors of the camera (the first two rows of the
/// view rotation, recovered from `view_proj`: they are the projection's x / y
/// scale times the unit rotation rows, so normalising them is exact for
/// perspective and orthographic cameras alike).
pub fn viewAxes(cam: Camera) struct { right: Vec3, up: Vec3 } {
    const m = cam.view_proj;
    return .{
        .right = mat.normalizeOr(.{ m[0], m[4], m[8] }, .{ 1, 0, 0 }),
        .up = mat.normalizeOr(.{ m[1], m[5], m[9] }, .{ 0, 1, 0 }),
    };
}

/// Unit-direction ray through viewport-local logical px `(x, y)` of a
/// `w x h` viewport (y down). Perspective rays start at the eye; ortho rays
/// start on the near plane. Returns a ray along -Z if the matrix is singular.
pub fn pickRay(cam: Camera, w: f32, h: f32, x: f32, y: f32) Ray {
    const nx = 2 * x / @max(w, 1e-6) - 1;
    const ny = 1 - 2 * y / @max(h, 1e-6);
    const inv = mat.invert(cam.view_proj) orelse return .{ .origin = cam.eye, .dir = .{ 0, 0, -1 } };
    const near_p = unproject(inv, nx, ny, 0);
    const far_p = unproject(inv, nx, ny, 1);
    const dir = mat.normalize(mat.sub(far_p, near_p));
    return .{ .origin = if (isPerspective(cam)) cam.eye else near_p, .dir = dir };
}

fn unproject(inv: Mat4, nx: f32, ny: f32, z: f32) Vec3 {
    var r: [4]f32 = undefined;
    for (0..4) |row| r[row] = inv[row] * nx + inv[4 + row] * ny + inv[8 + row] * z + inv[12 + row];
    return .{ r[0] / r[3], r[1] / r[3], r[2] / r[3] };
}

/// Project a world point to viewport px plus NDC depth (0 near .. 1 far).
/// Null when the point is behind the eye (perspective) or not finite.
pub fn project(cam: Camera, w: f32, h: f32, p: Vec3) ?Vec3 {
    const c = mat.transformPoint4(cam.view_proj, p);
    if (!(c[3] > 1e-9)) return null;
    const nx = c[0] / c[3];
    const ny = c[1] / c[3];
    return .{ (nx * 0.5 + 0.5) * w, (0.5 - ny * 0.5) * h, c[2] / c[3] };
}

/// Inverse of `project`: world point at viewport px `(x, y)` and NDC depth `z`.
pub fn unprojectPx(cam: Camera, w: f32, h: f32, x: f32, y: f32, z: f32) ?Vec3 {
    const inv = mat.invert(cam.view_proj) orelse return null;
    return unproject(inv, 2 * x / w - 1, 1 - 2 * y / h, z);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const approx = testing.expectApproxEqAbs;

fn expectVec(want: Vec3, got: Vec3, tol: f32) !void {
    for (0..3) |i| try approx(want[i], got[i], tol);
}

test "project/unproject round trip, both projections and up axes" {
    var o = Orbit{ .target = .{ 1, 2, 3 }, .dist = 20 };
    for ([_]bool{ false, true }) |ortho| {
        for ([_]@TypeOf(o.up){ .y, .z }) |up| {
            o.up = up;
            o.projection = if (ortho) .ortho else .{ .perspective = .{} };
            const cam = o.camera(800, 600, null);
            const pts = [_]Vec3{ .{ 1, 2, 3 }, .{ 4, -1, 2 }, .{ -3, 5, 8 } };
            for (pts) |p| {
                const s = project(cam, 800, 600, p).?;
                const back = unprojectPx(cam, 800, 600, s[0], s[1], s[2]).?;
                try expectVec(p, back, 2e-3);
            }
        }
    }
}

test "viewAxes matches the orbit basis (persp and ortho)" {
    var o = Orbit{ .yaw = 0.9, .pitch = 0.3, .dist = 9 };
    for ([_]bool{ false, true }) |ortho| {
        o.projection = if (ortho) .ortho else .{ .perspective = .{} };
        const bs = o.basis();
        const ax = viewAxes(o.camera(640, 480, null));
        try expectVec(bs.right, ax.right, 1e-4);
        try expectVec(bs.up, ax.up, 1e-4);
    }
}

test "target projects to the viewport center" {
    var o = Orbit{ .target = .{ 5, 6, 7 }, .dist = 12 };
    const cam = o.camera(640, 480, null);
    const s = project(cam, 640, 480, o.target).?;
    try approx(@as(f32, 320), s[0], 1e-2);
    try approx(@as(f32, 240), s[1], 1e-2);
    try testing.expect(s[2] > 0 and s[2] < 1);
    o.projection = .ortho;
    const s2 = project(o.camera(640, 480, null), 640, 480, o.target).?;
    try approx(@as(f32, 320), s2[0], 1e-2);
    try approx(@as(f32, 240), s2[1], 1e-2);
}

test "project is null behind the eye (perspective) only" {
    var o = Orbit{ .dist = 10 };
    const behind = mat.add(o.eye(), mat.scale(mat.sub(o.eye(), o.target), 0.5));
    try testing.expect(project(o.camera(100, 100, null), 100, 100, behind) == null);
    o.projection = .ortho;
    try testing.expect(project(o.camera(100, 100, null), 100, 100, behind) != null);
}

test "pickRay hits known points: perspective and ortho" {
    var o = Orbit{ .target = .{ 0, 1, 0 }, .dist = 15 };
    for ([_]bool{ false, true }) |ortho| {
        o.projection = if (ortho) .ortho else .{ .perspective = .{} };
        const cam = o.camera(800, 600, null);
        // Center ray passes through the target and is parallel to forward.
        const c = pickRay(cam, 800, 600, 400, 300);
        const bs = o.basis();
        try expectVec(bs.forward, c.dir, 1e-4);
        const to_t = mat.sub(o.target, c.origin);
        try expectVec(.{ 0, 0, 0 }, mat.cross(to_t, c.dir), 2e-3);
        // A ray through the pixel of an arbitrary point passes through it.
        const p = Vec3{ 2, -1, 3 };
        const s = project(cam, 800, 600, p).?;
        const r = pickRay(cam, 800, 600, s[0], s[1]);
        try expectVec(.{ 0, 0, 0 }, mat.cross(mat.sub(p, r.origin), r.dir), 3e-3);
        try testing.expect(mat.dot(mat.sub(p, r.origin), r.dir) > 0);
        if (ortho) {
            // ortho rays are parallel
            const r2 = pickRay(cam, 800, 600, 10, 10);
            try expectVec(r.dir, r2.dir, 1e-4);
        } else {
            try expectVec(cam.eye, r.origin, 1e-6);
        }
    }
}

test "ortho extent equals dist*tan(fov/2) and toggle preserves target size" {
    var o = Orbit{ .dist = 10, .target = .{ 0, 0, 0 } };
    const half = o.halfHeight();
    // Persp: a point at the target plane at +half height lands on the top edge.
    var cam = o.camera(100, 100, null);
    const up = o.basis().up;
    const s = project(cam, 100, 100, mat.scale(up, half)).?;
    try approx(@as(f32, 0), s[1], 1e-2);
    o.toggleProjection();
    try testing.expect(o.projection == .ortho);
    try approx(half, o.halfHeight(), 1e-4);
    cam = o.camera(100, 100, null);
    const s2 = project(cam, 100, 100, mat.scale(up, half)).?;
    try approx(@as(f32, 0), s2[1], 1e-2);
    o.toggleProjection();
    try testing.expect(o.projection == .perspective);
    try approx(half, o.halfHeight(), 1e-4);
}

test "toggle from a non-default fov keeps the apparent size" {
    var o = Orbit{ .dist = 10, .projection = .{ .perspective = .{ .fov_y = 1.0 } } };
    const half = o.halfHeight();
    o.toggleProjection();
    try approx(half, o.halfHeight(), 1e-4);
}

test "pitch clamps at the poles and the view never flips" {
    var o = Orbit{};
    o.rotate(0, 1000);
    try approx(Orbit.max_pitch, o.pitch, 1e-6);
    o.rotate(0, -1000);
    try approx(-Orbit.max_pitch, o.pitch, 1e-6);
    // At the pole the basis stays finite and orthonormal; screen-up tracks yaw.
    for ([_]f32{ 0.3, 1.2, -2.0 }) |yaw| {
        o.yaw = yaw;
        o.pitch = Orbit.max_pitch;
        const bs = o.basis();
        try approx(@as(f32, 1), mat.length(bs.right), 1e-4);
        try approx(@as(f32, 1), mat.length(bs.up), 1e-4);
        try approx(@as(f32, 0), mat.dot(bs.right, bs.up), 1e-4);
        const cam = o.camera(100, 100, null);
        for (cam.view_proj) |v| try testing.expect(std.math.isFinite(v));
    }
    // Continuous across an over-the-top drag: right vector keeps its sign.
    o = .{ .yaw = 0.4, .pitch = Orbit.max_pitch - 0.001 };
    const before = o.basis().right;
    o.rotate(0, 0.5);
    const after = o.basis().right;
    try testing.expect(mat.dot(before, after) > 0.99);
}

test "presets look from the expected side (y-up and z-up)" {
    var o = Orbit{ .dist = 10 };
    o.setPreset(.front);
    try expectVec(.{ 0, 0, 10 }, o.eye(), 1e-4);
    o.setPreset(.right);
    try expectVec(.{ 10, 0, 0 }, o.eye(), 1e-4);
    o.setPreset(.left);
    try expectVec(.{ -10, 0, 0 }, o.eye(), 1e-4);
    o.setPreset(.back);
    try expectVec(.{ 0, 0, -10 }, o.eye(), 1e-3);
    o.setPreset(.top);
    try testing.expect(o.eye()[1] > 9.99);
    o.setPreset(.bottom);
    try testing.expect(o.eye()[1] < -9.99);
    o.setPreset(.iso);
    try testing.expect(o.eye()[1] > 0);

    o.up = .z;
    o.setPreset(.front); // looks along +Y from -Y, Z up
    try expectVec(.{ 0, -10, 0 }, o.eye(), 1e-4);
    o.setPreset(.top);
    try testing.expect(o.eye()[2] > 9.99);
    o.setPreset(.right);
    try expectVec(.{ 10, 0, 0 }, o.eye(), 1e-4);
    // World +Z projects above the target on screen.
    o.setPreset(.iso);
    const cam = o.camera(100, 100, null);
    const s = project(cam, 100, 100, mat.add(o.target, .{ 0, 0, 1 })).?;
    try testing.expect(s[1] < 50);
}

test "zoom-to-cursor keeps the point under the cursor fixed" {
    const b = Orbit.Bindings{};
    for ([_]bool{ false, true }) |ortho| {
        var o = Orbit{ .target = .{ 1, 2, 3 }, .dist = 14, .yaw = 0.8, .pitch = 0.4 };
        if (ortho) o.projection = .ortho;
        const w: f32 = 900;
        const h: f32 = 500;
        const px: f32 = 700;
        const py: f32 = 120;
        // The point on the target plane under the cursor, before zooming.
        const cam0 = o.camera(w, h, null);
        const ray = pickRay(cam0, w, h, px, py);
        const bs = o.basis();
        const t = mat.dot(mat.sub(o.target, ray.origin), bs.forward) / mat.dot(ray.dir, bs.forward);
        const p = mat.add(ray.origin, mat.scale(ray.dir, t));
        const ev = pointer.CanvasEvent{ .id = 1, .kind = .wheel, .x = px, .y = py, .dy = -100, .w = w, .h = h };
        try testing.expect(o.onEvent(ev, b));
        try testing.expect(o.dist < 14); // zoomed in
        const s = project(o.camera(w, h, null), w, h, p).?;
        try approx(px, s[0], 0.05);
        try approx(py, s[1], 0.05);
        // And zooming out again also keeps it fixed.
        var ev2 = ev;
        ev2.dy = 250;
        try testing.expect(o.onEvent(ev2, b));
        const s2 = project(o.camera(w, h, null), w, h, p).?;
        try approx(px, s2[0], 0.05);
        try approx(py, s2[1], 0.05);
    }
}

test "zoom without zoom_to_cursor leaves the target; clamps dist" {
    var o = Orbit{ .dist = 10 };
    const ev = pointer.CanvasEvent{ .id = 1, .kind = .wheel, .x = 10, .y = 10, .dy = 100, .w = 100, .h = 100 };
    try testing.expect(o.onEvent(ev, .{ .zoom_to_cursor = false }));
    try approx(@as(f32, 11.2), o.dist, 1e-3);
    try expectVec(.{ 0, 0, 0 }, o.target, 0);
    o.dist = 1;
    var ev2 = ev;
    ev2.dy = -400;
    _ = o.onEvent(ev2, .{ .min_dist = 0.9, .zoom_to_cursor = false });
    try approx(@as(f32, 0.9), o.dist, 1e-6);
}

test "orbit drag rotates, shift-drag and middle-drag pan" {
    var o = Orbit{};
    const yaw0 = o.yaw;
    const pitch0 = o.pitch;
    var ev = pointer.CanvasEvent{ .id = 1, .kind = .move, .dx = 20, .dy = 10, .buttons = .{ .left = true }, .w = 800, .h = 600 };
    try testing.expect(o.onEvent(ev, .{}));
    try testing.expect(o.yaw < yaw0);
    try testing.expect(o.pitch > pitch0);
    try expectVec(.{ 0, 0, 0 }, o.target, 0);

    // Shift + left pans: the target-plane point under the cursor follows it.
    ev.mods.shift = true;
    const cam0 = o.camera(800, 600, null);
    const anchor = o.target;
    const s0 = project(cam0, 800, 600, anchor).?;
    try testing.expect(o.onEvent(ev, .{}));
    const s1 = project(o.camera(800, 600, null), 800, 600, anchor).?;
    try approx(s0[0] + 20, s1[0], 0.05);
    try approx(s0[1] + 10, s1[1], 0.05);

    // Middle button pans too; no buttons / unbound button does nothing.
    ev.mods.shift = false;
    ev.buttons = .{ .middle = true };
    try testing.expect(o.onEvent(ev, .{}));
    ev.buttons = .{};
    try testing.expect(!o.onEvent(ev, .{}));
    ev.buttons = .{ .right = true };
    try testing.expect(!o.onEvent(ev, .{}));
    ev.kind = .down;
    try testing.expect(!o.onEvent(ev, .{}));
}

test "frame fits bounds in view for wide and tall viewports, both projections" {
    const lo = Vec3{ -5, 0, -2 };
    const hi = Vec3{ 15, 4, 6 };
    for ([_]bool{ false, true }) |ortho| {
        for ([_]f32{ 2.0, 0.5, 1.0 }) |aspect| {
            var o = Orbit{ .yaw = 0.7, .pitch = 0.3 };
            if (ortho) o.projection = .ortho;
            o.frame(lo, hi, aspect);
            const w: f32 = 400 * aspect;
            const h: f32 = 400;
            const cam = o.camera(w, h, .{ .lo = lo, .hi = hi });
            for (0..8) |i| {
                const c = Vec3{
                    if (i & 1 == 0) lo[0] else hi[0],
                    if (i & 2 == 0) lo[1] else hi[1],
                    if (i & 4 == 0) lo[2] else hi[2],
                };
                const s = project(cam, w, h, c).?;
                try testing.expect(s[0] >= -0.5 and s[0] <= w + 0.5);
                try testing.expect(s[1] >= -0.5 and s[1] <= h + 0.5);
                try testing.expect(s[2] > 0 and s[2] < 1);
            }
        }
    }
}

test "near/far derive from bounds and honor explicit near_far" {
    var o = Orbit{ .dist = 100, .target = .{ 0, 0, 0 } };
    const bd = Bounds{ .lo = .{ -1, -1, -1 }, .hi = .{ 1, 1, 1 } };
    const cam = o.camera(100, 100, bd);
    // Target depth sits just inside (0,1) and a point at the sphere's far edge is < 1.
    const far_pt = mat.sub(o.target, mat.scale(o.basis().forward, -1.5));
    const sd = project(cam, 100, 100, far_pt).?;
    try testing.expect(sd[2] > 0 and sd[2] < 1);
    // A tight near/far range clips (null projection depth > 1) a point beyond it.
    o.near_far = .{ 90, 105 };
    const cam2 = o.camera(100, 100, bd);
    const beyond = mat.add(o.target, mat.scale(o.basis().forward, 20));
    try testing.expect(project(cam2, 100, 100, beyond).?[2] > 1);
    // Ortho with bounds allows geometry in front of the target.
    o.near_far = null;
    o.projection = .ortho;
    const cam3 = o.camera(100, 100, bd);
    const s = project(cam3, 100, 100, o.target).?;
    try testing.expect(s[2] > 0 and s[2] < 1);
}
