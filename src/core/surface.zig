//! Surface decoration data shared by the style structs: per-corner radii,
//! soft drop shadows and gradients. Plain data; the render pass turns a
//! rect that uses any of them into an SDF quad (`render/sdf.zig`), while a
//! rect that uses none keeps drawing as plain solid quads, pixel for pixel
//! as before. Units are logical pixels.

const std = @import("std");

/// Corner radii, clockwise from the top left. `Radii.all(8)` for a uniform
/// radius; radii are clamped to half the shorter side when drawn.
pub const Radii = struct {
    tl: f32 = 0,
    tr: f32 = 0,
    br: f32 = 0,
    bl: f32 = 0,

    pub fn all(r: f32) Radii {
        return .{ .tl = r, .tr = r, .br = r, .bl = r };
    }

    /// Round only the top corners / only the bottom corners (tab and panel headers).
    pub fn top(r: f32) Radii {
        return .{ .tl = r, .tr = r };
    }

    pub fn bottom(r: f32) Radii {
        return .{ .br = r, .bl = r };
    }

    pub fn isZero(self: Radii) bool {
        return self.tl <= 0 and self.tr <= 0 and self.br <= 0 and self.bl <= 0;
    }

    pub fn max(self: Radii) f32 {
        return @max(@max(self.tl, self.tr), @max(self.br, self.bl));
    }
};

/// A soft (blurred) drop shadow behind a rect, CSS `box-shadow` semantics:
/// the rect grown by `spread` and moved by (`dx`, `dy`), blurred by `blur`
/// (the Gaussian's full width is about `blur`, sigma = blur / 2), drawn only
/// OUTSIDE the rect. The retro hard shadow is `OverlayStyle.shadow`.
pub const Shadow = struct {
    dx: f32 = 0,
    dy: f32 = 2,
    blur: f32 = 8,
    spread: f32 = 0,
    color: [4]f32 = .{ 0, 0, 0, 0.25 },
};

/// A two-stop gradient fill replacing the flat `bg`.
pub const Gradient = struct {
    from: [4]f32,
    to: [4]f32,
    kind: Kind = .linear,
    /// Linear only: the direction `from` -> `to` points, degrees clockwise
    /// from "up" (CSS convention): 0 bottom-to-top, 90 left-to-right, 180
    /// top-to-bottom.
    angle_deg: f32 = 180,

    pub const Kind = enum { linear, radial };

    /// Top-to-bottom linear gradient.
    pub fn vertical(from: [4]f32, to: [4]f32) Gradient {
        return .{ .from = from, .to = to };
    }

    /// Left-to-right linear gradient.
    pub fn horizontal(from: [4]f32, to: [4]f32) Gradient {
        return .{ .from = from, .to = to, .angle_deg = 90 };
    }

    /// Unit vector (screen space, y down) the gradient advances along.
    pub fn direction(self: Gradient) [2]f32 {
        const a = self.angle_deg * std.math.pi / 180.0;
        return .{ @sin(a), -@cos(a) };
    }
};

test "Radii helpers" {
    try std.testing.expect((Radii{}).isZero());
    try std.testing.expect(!Radii.top(4).isZero());
    try std.testing.expectEqual(@as(f32, 4), Radii.top(4).max());
    try std.testing.expectEqual(@as(f32, 0), Radii.top(4).bl);
    try std.testing.expectEqual(@as(f32, 9), Radii.all(9).br);
}

test "Gradient direction follows the CSS angle convention" {
    const v = Gradient.vertical(.{ 0, 0, 0, 1 }, .{ 1, 1, 1, 1 }).direction();
    try std.testing.expectApproxEqAbs(@as(f32, 0), v[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1), v[1], 1e-6); // down the screen
    const h = Gradient.horizontal(.{ 0, 0, 0, 1 }, .{ 1, 1, 1, 1 }).direction();
    try std.testing.expectApproxEqAbs(@as(f32, 1), h[0], 1e-6); // to the right
    try std.testing.expectApproxEqAbs(@as(f32, 0), h[1], 1e-6);
}
