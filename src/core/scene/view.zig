//! The data a `viewport3d` Cmd carries besides the camera: placed mesh
//! instances (`Item`) and scene-level options (grid, gizmo, section cut,
//! material, highlight colour). Plain data — no handles, no callbacks
//! (HARDLINE §3); `Item.mesh` is a resource key like `ImageCmd.handle`, and
//! the item slice lives in the frame arena. See docs/features/scene.md §3.2.

const std = @import("std");
const mat = @import("mat.zig");

pub const identity_3x4: [12]f32 = mat.identity_affine;

pub const ItemFlags = packed struct(u8) {
    /// Cheap visibility toggle (layers); skipped by draw and pick.
    hidden: bool = false,
    /// Flat colour, no Lambert shading.
    unlit: bool = false,
    /// Skip this item's feature edges.
    no_edges: bool = false,
    /// Skipped by CPU picking (`scene.pick` callers map this to `Item.no_pick`).
    no_pick: bool = false,
    /// Blend toward `View.highlight_color`.
    highlight: bool = false,
    /// No cap fill for this item under a section cut (open shells would
    /// streak under stencil parity); its cut outline is still drawn.
    no_cap: bool = false,
    _pad: u2 = 0,
};

/// One placed instance of a mesh resource.
pub const Item = struct {
    /// Resource key (`MeshResource.key`); remapped to a Gpu handle on staging.
    mesh: u32,
    /// Rows of a 3x4 affine matrix: `[x_axis, y_axis, z_axis, translation]` per row.
    transform: [12]f32 = identity_3x4,
    /// Multiplied into the vertex colour (alpha ignored).
    tint: [4]f32 = .{ 1, 1, 1, 1 },
    /// App-chosen id echoed by picking; 0 = none.
    id: u32 = 0,
    flags: ItemFlags = .{},
    /// Section-cap fill for this item; alpha 0 uses `Cut.cap_color`.
    cap_color: [4]f32 = .{ 0, 0, 0, 0 },
};

pub const Material = enum(u8) { lambert, flat };

pub const GridPlane = enum { xz, xy, yz };

pub const Grid = struct {
    plane: GridPlane = .xz,
    offset: f32 = 0,
    spacing: f32 = 12,
    major_every: u32 = 5,
    minor: [4]f32 = .{ 0.83, 0.88, 0.93, 1 },
    major: [4]f32 = .{ 0.66, 0.76, 0.87, 1 },
    axis_a: [4]f32 = .{ 0.78, 0.2, 0.2, 1 },
    axis_b: [4]f32 = .{ 0.2, 0.4, 0.8, 1 },
    /// Distance at which lines fade out; 0 derives it from the camera distance.
    fade_dist: f32 = 0,
};

pub const Corner = enum { top_left, top_right, bottom_left, bottom_right };

/// Axis triad in a corner sub-viewport.
pub const Gizmo = struct {
    corner: Corner = .bottom_left,
    size_px: f32 = 72,
    margin_px: f32 = 8,
    /// X, Y, Z axis colours.
    colors: [3][4]f32 = .{ .{ 0.78, 0.16, 0.16, 1 }, .{ 0.18, 0.55, 0.22, 1 }, .{ 0.12, 0.31, 0.62, 1 } },
};

/// Section cut: keep the half-space where `dot(n, p) + d <= 0`.
pub const Cut = struct {
    /// `n.xyz` (unit), `d`.
    plane: [4]f32,
    cap_color: [4]f32 = .{ 0.91, 0.85, 0.65, 1 },
    cap: bool = true,
    /// Cap boundary line width in logical px; 0 = off.
    outline_px: f32 = 1.5,
    outline_color: [4]f32 = .{ 0.1, 0.1, 0.1, 1 },
};

pub const View = struct {
    /// Arena slice owned by the frame. Empty = legacy single-mesh `scene3d`.
    items: []const Item = &.{},
    grid: ?Grid = null,
    gizmo: ?Gizmo = null,
    cut: ?Cut = null,
    material: Material = .lambert,
    highlight_color: [4]f32 = .{ 0.114, 0.306, 0.62, 1 },
    /// How strongly `highlight` items blend toward `highlight_color`.
    highlight_mix: f32 = 0.6,

    /// Content equality for the frame diff (items compared by value, not address).
    pub fn eql(a: View, b: View) bool {
        if (a.items.len != b.items.len) return false;
        for (a.items, b.items) |x, y| if (!std.meta.eql(x, y)) return false;
        return std.meta.eql(a.grid, b.grid) and std.meta.eql(a.gizmo, b.gizmo) and
            std.meta.eql(a.cut, b.cut) and a.material == b.material and
            std.meta.eql(a.highlight_color, b.highlight_color) and a.highlight_mix == b.highlight_mix;
    }
};

test "Item layout defaults: identity transform, white tint, no flags" {
    const it = Item{ .mesh = 3 };
    try std.testing.expectEqual(@as(f32, 1), it.transform[0]);
    try std.testing.expectEqual(@as(f32, 0), it.transform[3]);
    try std.testing.expectEqual(@as(f32, 1), it.transform[10]);
    try std.testing.expectEqual(@as(u8, 0), @as(u8, @bitCast(it.flags)));
}

test "View.eql compares item content, not slice identity" {
    const a_items = [_]Item{ .{ .mesh = 1, .id = 5 }, .{ .mesh = 2 } };
    const b_items = [_]Item{ .{ .mesh = 1, .id = 5 }, .{ .mesh = 2 } };
    const a = View{ .items = &a_items };
    var b = View{ .items = &b_items };
    try std.testing.expect(a.eql(b));
    var c_items = b_items;
    c_items[1].flags.highlight = true;
    b.items = &c_items;
    try std.testing.expect(!a.eql(b));
    try std.testing.expect(!(View{}).eql(View{ .grid = .{} }));
    try std.testing.expect((View{ .cut = .{ .plane = .{ 0, 1, 0, 0 } } }).eql(.{ .cut = .{ .plane = .{ 0, 1, 0, 0 } } }));
    try std.testing.expect(!(View{}).eql(View{ .material = .flat }));
}
