//! Shared tessellator: Drawing IR -> triangle list in SCREEN pixels.
//!
//! The live UI viewport uploads the result to the GPU; the PNG renderer
//! (CPU raster, not shipped here) rasterizes the very same triangles on the CPU. Because both
//! consume exactly this output, `kerf_render` shows what the designer sees.
//!
//! ```zig
//! var t = tess.Tessellator.init(gpa);
//! defer t.deinit();
//! const view = tess.View.fit(drawing.bounds, 1200, 800, 24);
//! try t.build(&drawing, &font, view, tess.Palette.live(), .{ .hovered = "sill_plate" });
//! gpu.upload(std.mem.sliceAsBytes(t.verts()));   // Vert = 6 x f32, triangle list (3 verts per triangle)
//! // next frame (pan/zoom): just call t.build(...) again; buffers are reused, no allocation in steady state.
//! ```
//!
//! ## Coordinates
//! Screen pixels, origin top-left, y grows DOWN. `View` maps model inches
//! (y up) to screen: `sx = origin_x + x * ppi`, `sy = origin_y - y * ppi`.
//!
//! ## Antialiasing without MSAA ("feathered fringes")
//! With `Options.antialias` every primitive is emitted with a ~1 px wide
//! alpha ramp instead of a hard edge: a stroke is a ribbon whose cross-section
//! has vertices at offsets `-(w+.5), -(w-.5), +(w-.5), +(w+.5)` px with alphas
//! `0, 1, 1, 0` (3 vertices `0,1,0` for 1 px lines); open ends get the same
//! ramp along the line. Solid fills are inset by 0.5 px and surrounded by a 1 px
//! fringe strip whose outer vertices have alpha 0. Consumers must therefore blend with
//! straight (non-premultiplied) alpha `src-over` using the per-vertex `a`
//! (raster.zig does; on the GPU use `SRC_ALPHA, ONE_MINUS_SRC_ALPHA`).
//! Joins are mitered (limit 2.5, i.e. ~47 degrees); sharper corners split the
//! stroke and are capped; wide lines (>= 3 px) get round caps/joins, thin ones
//! get projecting square caps. Dashes use butt caps.
//!
//! ## Weights
//! Pen width px = `width_mm / 25.4 * px_per_paper_in` where
//! `px_per_paper_in = view.px_per_model_in * drawing.scale`, clamped to
//! `Options.min_line_px` (default 1). Dash/gap lengths are converted the same way;
//! dash patterns whose period is under 3 px degrade to solid lines.
//!
//! ## Draw order
//! vellum, grid, selection tint, then drawing items in IR order, then
//! hover/selection outlines (blue, >= 2 px; dashed pens are not outlined). A selected src
//! with a cut region gets the 15 % tint; one made only of fills / text / lines gets the outline instead.
//! Items whose bbox is outside the viewport are skipped. Text smaller than
//! ~2.5 px cap height is greeked into a single thin line.

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom.zig");
const ir = @import("ir.zig");
const font_mod = @import("font.zig");
const Font = font_mod.Font;
const Vec2 = geom.Vec2;

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// Straight (non-premultiplied) sRGB color, components 0..1.
pub const Color = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32 = 1,

    pub fn hex(rgb: u24) Color {
        return .{
            .r = @as(f32, @floatFromInt((rgb >> 16) & 0xff)) / 255.0,
            .g = @as(f32, @floatFromInt((rgb >> 8) & 0xff)) / 255.0,
            .b = @as(f32, @floatFromInt(rgb & 0xff)) / 255.0,
        };
    }
    pub fn withAlpha(c: Color, a: f32) Color {
        return .{ .r = c.r, .g = c.g, .b = c.b, .a = a };
    }
};

/// DESIGN.md tokens. `live()` = on-screen viewport; `white_ink()` = PNG for the LLM.
pub const Palette = struct {
    vellum: Color,
    ink: Color,
    grid: Color,
    grid2: Color,
    blue: Color,
    /// Desk behind a sheet page (`Options.page`).
    desk: Color = Color.hex(0xCFCABB),
    /// Alpha of the selected-region tint (DESIGN.md: 15 % blue).
    tint_alpha: f32 = 0.15,

    pub fn live() Palette {
        return .{
            .vellum = Color.hex(0xFBFAF5),
            .ink = Color.hex(0x1A1A1A),
            .grid = Color.hex(0xA9C1DD),
            .grid2 = Color.hex(0xD3E0EE),
            .blue = Color.hex(0x1D4E9E),
        };
    }

    /// White paper, pure black ink, no grid colors needed (use `Options.grid = false`).
    pub fn white_ink() Palette {
        return .{
            .vellum = Color.hex(0xFFFFFF),
            .ink = Color.hex(0x000000),
            .grid = Color.hex(0xA9C1DD),
            .grid2 = Color.hex(0xD3E0EE),
            .blue = Color.hex(0x1D4E9E),
        };
    }
};

/// One vertex of the output triangle list (6 f32: x, y, r, g, b, a). It is
/// teak's own canvas vertex, so the tessellator's buffer feeds a
/// `CanvasPrimitive.triangles` batch without a copy.
pub const Vert = @import("teak").CanvasPrimitive.TriVertex;

/// Growable triangle list (3 consecutive verts = 1 triangle). `clear()` keeps capacity.
pub const TriBuf = struct {
    verts: std.ArrayList(Vert) = .empty,

    pub fn deinit(self: *TriBuf, a: Allocator) void {
        self.verts.deinit(a);
    }
    pub fn clear(self: *TriBuf) void {
        self.verts.clearRetainingCapacity();
    }
    pub fn triangleCount(self: *const TriBuf) usize {
        return self.verts.items.len / 3;
    }
    pub fn slice(self: *const TriBuf) []const Vert {
        return self.verts.items;
    }
    pub fn asBytes(self: *const TriBuf) []const u8 {
        return std.mem.sliceAsBytes(self.verts.items);
    }
};

pub const View = struct {
    /// Screen pixels per model inch (zoom).
    px_per_model_in: f32,
    /// Screen position of model (0, 0).
    origin_x: f32,
    origin_y: f32,
    /// Viewport size in pixels.
    width: f32,
    height: f32,

    pub fn sx(self: View, x: f64) f32 {
        return @floatCast(@as(f64, self.origin_x) + x * @as(f64, self.px_per_model_in));
    }
    pub fn sy(self: View, y: f64) f32 {
        return @floatCast(@as(f64, self.origin_y) - y * @as(f64, self.px_per_model_in));
    }
    pub fn modelX(self: View, px: f64) f64 {
        return (px - @as(f64, self.origin_x)) / @as(f64, self.px_per_model_in);
    }
    pub fn modelY(self: View, py: f64) f64 {
        return (@as(f64, self.origin_y) - py) / @as(f64, self.px_per_model_in);
    }
    /// Model-space rectangle covered by the viewport.
    pub fn modelBounds(self: View) geom.BBox {
        return .{
            .x0 = self.modelX(0),
            .x1 = self.modelX(self.width),
            .y0 = self.modelY(self.height),
            .y1 = self.modelY(0),
        };
    }
    /// Fit model `bounds` (`[x0,y0,x1,y1]`) into a width x height viewport with a pixel margin, centered.
    pub fn fit(bounds: [4]f64, width: f32, height: f32, margin: f32) View {
        const bw = @max(bounds[2] - bounds[0], 1e-6);
        const bh = @max(bounds[3] - bounds[1], 1e-6);
        const aw = @max(@as(f64, width) - 2.0 * margin, 1.0);
        const ah = @max(@as(f64, height) - 2.0 * margin, 1.0);
        const s = @min(aw / bw, ah / bh);
        const cx = (bounds[0] + bounds[2]) * 0.5;
        const cy = (bounds[1] + bounds[3]) * 0.5;
        return .{
            .px_per_model_in = @floatCast(s),
            .origin_x = @floatCast(@as(f64, width) * 0.5 - cx * s),
            .origin_y = @floatCast(@as(f64, height) * 0.5 + cy * s),
            .width = width,
            .height = height,
        };
    }
    /// Zoom by `factor` keeping the model point under screen (px, py) fixed.
    pub fn zoomAt(self: View, px: f32, py: f32, factor: f32) View {
        var v = self;
        v.px_per_model_in = self.px_per_model_in * factor;
        v.origin_x = px - (px - self.origin_x) * factor;
        v.origin_y = py - (py - self.origin_y) * factor;
        return v;
    }
    pub fn panned(self: View, dx: f32, dy: f32) View {
        var v = self;
        v.origin_x += dx;
        v.origin_y += dy;
        return v;
    }
};

pub const Options = struct {
    /// `src` of the selected component (15 % blue tint on its cut region), or null.
    selected: ?[]const u8 = null,
    /// `src` of the hovered component (2 px blue outline), or null.
    hovered: ?[]const u8 = null,
    /// Draw the model-space grid (1/4", 1", 12", 144" tiers that fade when too dense).
    grid: bool = true,
    /// Feathered fringes (see module doc). Off = hard-edged geometry (for MSAA / tests).
    antialias: bool = true,
    /// Minimum stroke width in device pixels (DESIGN.md: 1).
    min_line_px: f32 = 1.0,
    /// Emit the vellum background rectangle.
    background: bool = true,
    /// Sheet preview: the viewport is a desk, and `drawing.bounds` is a white page with a hard offset shadow.
    page: bool = false,
};

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

const P = struct {
    x: f32,
    y: f32,
};

inline fn pAdd(a: P, b: P) P {
    return .{ .x = a.x + b.x, .y = a.y + b.y };
}
inline fn pSub(a: P, b: P) P {
    return .{ .x = a.x - b.x, .y = a.y - b.y };
}
inline fn pMul(a: P, s: f32) P {
    return .{ .x = a.x * s, .y = a.y * s };
}
inline fn pDot(a: P, b: P) f32 {
    return a.x * b.x + a.y * b.y;
}
/// Left normal (in screen numbers) of a direction.
inline fn leftN(d: P) P {
    return .{ .x = -d.y, .y = d.x };
}

const Cap = enum { auto, butt, square, round };

const Profile = struct {
    n: u8,
    off: [4]f32,
    alpha: [4]f32,
    /// Half width of the fully opaque core.
    inner: f32,
    /// Half width including the fringe.
    outer: f32,
    /// Nominal half width.
    w: f32,
};

fn makeProfile(W: f32, aa: bool) Profile {
    const w = W * 0.5;
    if (!aa) return .{ .n = 2, .off = .{ -w, w, 0, 0 }, .alpha = .{ 1, 1, 0, 0 }, .inner = w, .outer = w, .w = w };
    if (w >= 0.5) {
        const inner = w - 0.5;
        const outer = w + 0.5;
        if (inner < 0.02) return .{ .n = 3, .off = .{ -outer, 0, outer, 0 }, .alpha = .{ 0, 1, 0, 0 }, .inner = 0, .outer = outer, .w = w };
        return .{ .n = 4, .off = .{ -outer, -inner, inner, outer }, .alpha = .{ 0, 1, 1, 0 }, .inner = inner, .outer = outer, .w = w };
    }
    // sub-pixel line: tent with the same area as the ideal box
    const outer = 0.5 + w;
    return .{ .n = 3, .off = .{ -outer, 0, outer, 0 }, .alpha = .{ 0, W / outer, 0, 0 }, .inner = 0, .outer = outer, .w = w };
}

const miter_break_dot: f32 = -0.68;
const dedupe_eps: f32 = 0.02;
const round_cap_min_w: f32 = 3.0;

pub const Tessellator = struct {
    gpa: Allocator,
    buf: TriBuf = .{},

    // per-build context
    view: View = undefined,
    pal: Palette = Palette.live(),
    opt: Options = .{},
    font: *const Font = undefined,
    drawing: *const ir.Drawing = undefined,
    ppp: f32 = 1, // px per paper inch
    ppi: f32 = 1, // px per model inch
    cull: geom.BBox = geom.BBox.empty,

    // scratch (reused between builds)
    sp: std.ArrayList(P) = .empty,
    sd: std.ArrayList(P) = .empty,
    sp2: std.ArrayList(P) = .empty,
    sd2: std.ArrayList(P) = .empty,
    dash: std.ArrayList(P) = .empty,
    flat: std.ArrayList(Vec2) = .empty,
    scr: std.ArrayList(Vec2) = .empty,
    loop_ends: std.ArrayList(u32) = .empty,
    ring_in: std.ArrayList(Vec2) = .empty,
    ring_out: std.ArrayList(Vec2) = .empty,
    holes: std.ArrayList([]const Vec2) = .empty,
    tris: geom.TriList = .empty,
    polys: font_mod.Polylines = .{},
    tp: std.ArrayList(P) = .empty,

    pub fn init(gpa: Allocator) Tessellator {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Tessellator) void {
        const a = self.gpa;
        self.buf.deinit(a);
        self.sp.deinit(a);
        self.sd.deinit(a);
        self.sp2.deinit(a);
        self.sd2.deinit(a);
        self.dash.deinit(a);
        self.flat.deinit(a);
        self.scr.deinit(a);
        self.loop_ends.deinit(a);
        self.ring_in.deinit(a);
        self.ring_out.deinit(a);
        self.holes.deinit(a);
        self.tris.deinit(a);
        self.polys.deinit(a);
        self.tp.deinit(a);
    }

    /// The triangle list produced by the last `build`.
    pub fn verts(self: *const Tessellator) []const Vert {
        return self.buf.slice();
    }

    /// Tessellate `d` for `view`. Previous output is discarded; capacity is reused.
    pub fn build(self: *Tessellator, d: *const ir.Drawing, font: *const Font, view: View, pal: Palette, opt: Options) Allocator.Error!void {
        self.buf.clear();
        self.view = view;
        self.pal = pal;
        self.opt = opt;
        self.font = font;
        self.drawing = d;
        self.ppi = view.px_per_model_in;
        self.ppp = view.px_per_model_in * @as(f32, @floatCast(d.scale));
        self.cull = view.modelBounds();

        if (opt.page) {
            try self.rect(0, 0, view.width, view.height, pal.desk, 1);
            const x0 = view.sx(d.bounds[0]);
            const x1 = view.sx(d.bounds[2]);
            const y0 = view.sy(d.bounds[3]);
            const y1 = view.sy(d.bounds[1]);
            try self.rect(x0 + 4, y0 + 4, x1 + 4, y1 + 4, pal.ink, 1);
            try self.rect(x0, y0, x1, y1, Color.hex(0xFFFFFF), 1);
        } else if (opt.background) try self.rect(0, 0, view.width, view.height, pal.vellum, 1);
        if (opt.grid) try self.drawGrid();

        // Selection tint goes under the linework.
        var sel_has_region = false;
        if (opt.selected) |s| {
            if (s.len > 0) sel_has_region = try self.drawTint(s);
        }

        for (d.items) |it| try self.drawItem(it);

        if (opt.hovered) |h| {
            if (h.len > 0) try self.drawOutline(h);
        }
        if (opt.selected) |s| {
            if (s.len > 0 and !sel_has_region) try self.drawOutline(s);
        }
    }

    // ---- low-level emit ---------------------------------------------------

    fn tri(self: *Tessellator, a: Vert, b: Vert, c: Vert) Allocator.Error!void {
        try self.buf.verts.ensureUnusedCapacity(self.gpa, 3);
        self.buf.verts.appendSliceAssumeCapacity(&.{ a, b, c });
    }

    fn quad(self: *Tessellator, a: Vert, b: Vert, c: Vert, d: Vert) Allocator.Error!void {
        try self.buf.verts.ensureUnusedCapacity(self.gpa, 6);
        self.buf.verts.appendSliceAssumeCapacity(&.{ a, b, c, a, c, d });
    }

    /// Axis aligned rectangle with constant alpha (no fringe).
    fn rect(self: *Tessellator, x0: f32, y0: f32, x1: f32, y1: f32, c: Color, alpha: f32) Allocator.Error!void {
        const a = c.a * alpha;
        try self.quad(mk(x0, y0, c, a), mk(x1, y0, c, a), mk(x1, y1, c, a), mk(x0, y1, c, a));
    }

    // ---- grid -------------------------------------------------------------

    fn drawGrid(self: *Tessellator) Allocator.Error!void {
        const v = self.view;
        const bb = self.cull;
        const tiers = [_]f64{ 0.25, 1.0, 12.0, 144.0 };
        var alphas: [4]f32 = undefined;
        for (tiers, 0..) |t, i| {
            const spx: f32 = @floatCast(t * @as(f64, self.ppi));
            alphas[i] = gridFade(spx);
        }
        var ti: usize = tiers.len;
        while (ti > 0) {
            ti -= 1;
            const a = alphas[ti];
            if (a < 0.03) continue;
            const t = tiers[ti];
            const col = if (ti == 0) self.pal.grid2 else self.pal.grid;
            const skip_ratio: i64 = if (ti + 1 < tiers.len and alphas[ti + 1] >= 0.03) @intFromFloat(@round(tiers[ti + 1] / t)) else 0;

            const ix0: i64 = @intFromFloat(@ceil(bb.x0 / t));
            const ix1: i64 = @intFromFloat(@floor(bb.x1 / t));
            if (ix1 - ix0 < 1500) {
                var i = ix0;
                while (i <= ix1) : (i += 1) {
                    if (skip_ratio != 0 and @mod(i, skip_ratio) == 0) continue;
                    const px = @floor(v.sx(@as(f64, @floatFromInt(i)) * t));
                    try self.rect(px, 0, px + 1, v.height, col, a);
                }
            }
            const iy0: i64 = @intFromFloat(@ceil(bb.y0 / t));
            const iy1: i64 = @intFromFloat(@floor(bb.y1 / t));
            if (iy1 - iy0 < 1500) {
                var i = iy0;
                while (i <= iy1) : (i += 1) {
                    if (skip_ratio != 0 and @mod(i, skip_ratio) == 0) continue;
                    const py = @floor(v.sy(@as(f64, @floatFromInt(i)) * t));
                    try self.rect(0, py, v.width, py + 1, col, a);
                }
            }
        }
    }

    // ---- generic helpers --------------------------------------------------

    fn penPx(self: *const Tessellator, it: ir.Item) f32 {
        const pen = self.drawing.penOf(it);
        const w: f32 = @floatCast(pen.width_mm / 25.4 * @as(f64, self.ppp));
        return @max(w, self.opt.min_line_px);
    }

    fn visible(self: *const Tessellator, it: ir.Item, pad_px: f32) bool {
        const pad: f64 = @as(f64, pad_px) / @as(f64, self.ppi);
        return it.bbox.grow(pad).intersects(self.cull);
    }

    fn toP(self: *const Tessellator, x: f64, y: f64) P {
        return .{ .x = self.view.sx(x), .y = self.view.sy(y) };
    }

    /// Flatten a model-space bulge path into `self.sp`-style screen points (appended to `out`).
    fn pathToScreen(self: *Tessellator, out: *std.ArrayList(P), pts: []const ir.Pt, closed: bool) Allocator.Error!void {
        out.clearRetainingCapacity();
        var has_arc = false;
        for (pts) |p| {
            if (@abs(p.b) > 1e-9) {
                has_arc = true;
                break;
            }
        }
        if (!has_arc) {
            try out.ensureTotalCapacity(self.gpa, pts.len + 1);
            for (pts) |p| out.appendAssumeCapacity(self.toP(p.x, p.y));
            if (closed) out.appendAssumeCapacity(out.items[0]); // stroke wants explicit closure removed later
            return;
        }
        self.flat.clearRetainingCapacity();
        const tol_model: f64 = 0.15 / @as(f64, self.ppi);
        try geom.appendFlattened(&self.flat, self.gpa, pts, closed, tol_model);
        try out.ensureTotalCapacity(self.gpa, self.flat.items.len + 1);
        for (self.flat.items) |q| out.appendAssumeCapacity(self.toP(q.x, q.y));
        if (closed) out.appendAssumeCapacity(out.items[0]);
    }

    // ---- items ------------------------------------------------------------

    fn drawItem(self: *Tessellator, it: ir.Item) Allocator.Error!void {
        const ink = self.pal.ink;
        switch (it.body) {
            .path => |p| {
                const W = self.penPx(it);
                if (!self.visible(it, W)) return;
                try self.pathToScreen(&self.tp, p.pts, p.closed);
                const pen = self.drawing.penOf(it);
                // pathToScreen appends the closing point for closed paths; strokeP wants it raw.
                const pts = self.tp.items;
                var closed = p.closed;
                var slice: []const P = pts;
                if (closed) slice = pts[0 .. pts.len - 1];
                if (slice.len < 2) return;
                if (slice.len == 2) closed = false;
                try self.strokeStyled(slice, closed, W, pen.dash_mm, ink);
            },
            .fill => |f| {
                if (!self.visible(it, 2)) return;
                self.beginLoops();
                for (f.loops, 0..) |l, i| try self.addLoop(l, i == 0);
                try self.fillPrepared(ink);
            },
            .hatch => |h| {
                if (!self.visible(it, 2)) return;
                try self.drawHatchLines(it, h);
            },
            .text => |t| {
                if (!self.textVisible(t)) return;
                try self.drawText(t, self.penPx(it), ink, 1.0);
            },
        }
    }

    fn drawHatchLines(self: *Tessellator, it: ir.Item, h: ir.Hatch) Allocator.Error!void {
        const W = self.penPx(it);
        const prof = makeProfile(W, self.opt.antialias);
        const ink = self.pal.ink;
        const v = self.view;
        const pad: f32 = W + 2;
        for (h.lines) |ln| {
            const a = self.toP(ln[0], ln[1]);
            const b = self.toP(ln[2], ln[3]);
            // viewport cull (screen space)
            if ((a.x < -pad and b.x < -pad) or (a.y < -pad and b.y < -pad) or
                (a.x > v.width + pad and b.x > v.width + pad) or
                (a.y > v.height + pad and b.y > v.height + pad)) continue;
            const dx = b.x - a.x;
            const dy = b.y - a.y;
            const l2 = dx * dx + dy * dy;
            if (l2 < dedupe_eps * dedupe_eps) {
                try self.dot(a, prof, ink);
                continue;
            }
            const inv = 1.0 / @sqrt(l2);
            const d: P = .{ .x = dx * inv, .y = dy * inv };
            const pts = [2]P{ a, b };
            const dirs = [1]P{d};
            try self.emitRun(&pts, &dirs, false, .butt, .butt, prof, ink);
        }
    }

    fn textVisible(self: *const Tessellator, t: ir.Text) bool {
        const bb = self.font.textBBox(t.s, t.h, t.x, t.y, t.rot, t.halign, t.valign);
        const pad: f64 = 2.0 / @as(f64, self.ppi);
        return bb.grow(pad).intersects(self.cull);
    }

    fn drawText(self: *Tessellator, t: ir.Text, W_in: f32, col: Color, alpha: f32) Allocator.Error!void {
        const h_px = @as(f32, @floatCast(t.h)) * self.ppi;
        var c = col;
        c.a *= alpha;
        if (h_px < 2.5) {
            // greek: one thin line at mid cap height
            const w = self.font.textWidth(t.s, t.h);
            const x0: f64 = switch (t.halign) {
                .left => 0,
                .center => -w * 0.5,
                .right => -w,
            };
            const ym: f64 = switch (t.valign) {
                .baseline => t.h * 0.5,
                .bottom => t.h * 0.5 + t.h * 7.0 / 21.0,
                .middle => 0,
                .top => -t.h * 0.5,
            };
            const rad = std.math.degreesToRadians(t.rot);
            const cr = @cos(rad);
            const sr = @sin(rad);
            const p0 = self.toP(t.x + x0 * cr - ym * sr, t.y + x0 * sr + ym * cr);
            const p1 = self.toP(t.x + (x0 + w) * cr - ym * sr, t.y + (x0 + w) * sr + ym * cr);
            c.a *= 0.55;
            const pts = [2]P{ p0, p1 };
            try self.strokeP(&pts, false, @max(W_in, @max(1.0, h_px * 0.5)), .butt, c);
            return;
        }
        self.polys.clear();
        try self.font.textStrokes(self.gpa, &self.polys, t.s, t.h, t.x, t.y, t.rot, t.halign, t.valign);
        var i: usize = 0;
        while (i < self.polys.count()) : (i += 1) {
            const line = self.polys.line(i);
            self.tp.clearRetainingCapacity();
            try self.tp.ensureTotalCapacity(self.gpa, line.len);
            // radial decimation: drop vertices closer than 0.7 px to the previous kept one (keeps last)
            var last: P = undefined;
            for (line, 0..) |q, k| {
                const p = self.toP(q.x, q.y);
                if (k > 0 and k + 1 < line.len) {
                    const dx = p.x - last.x;
                    const dy = p.y - last.y;
                    if (dx * dx + dy * dy < 0.49) continue;
                }
                self.tp.appendAssumeCapacity(p);
                last = p;
            }
            try self.strokeP(self.tp.items, false, W_in, .auto, c);
        }
    }

    // ---- selection / hover ------------------------------------------------

    /// Tint the cut region of `src`. Region sources, in order: hatch loops (loop 0 outer, rest holes);
    /// else closed cut/profile paths plus loops formed by chaining its open cut/profile paths end to end
    /// (the engines emit cut outlines as open chains); else nothing. Returns true if a region was tinted.
    fn drawTint(self: *Tessellator, src: []const u8) Allocator.Error!bool {
        const tint = self.pal.blue.withAlpha(self.pal.tint_alpha);
        var drew = false;
        for (self.drawing.items) |it| {
            if (!ir.srcMatches(it.src, src)) continue;
            switch (it.body) {
                .hatch => |h| {
                    if (h.loops.len == 0) continue;
                    drew = true;
                    if (!self.visible(it, 2)) continue;
                    self.beginLoops();
                    for (h.loops, 0..) |l, i| try self.addLoop(l, i == 0);
                    try self.fillPrepared(tint);
                },
                else => {},
            }
        }
        if (drew) return true;

        // closed cut paths + chained open cut paths
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const ar = arena.allocator();
        var open: std.ArrayList([]const ir.Pt) = .empty;
        for (self.drawing.items) |it| {
            if (!ir.srcMatches(it.src, src)) continue;
            if (it.body != .path) continue;
            const name = self.drawing.penOf(it).name;
            if (!(std.mem.eql(u8, name, "cut") or std.mem.eql(u8, name, "profile") or name.len == 0)) continue;
            const p = it.body.path;
            if (p.closed) {
                if (p.pts.len < 3) continue;
                drew = true;
                if (!self.visible(it, 2)) continue;
                self.beginLoops();
                try self.addLoop(p.pts, true);
                try self.fillPrepared(tint);
            } else {
                try open.append(ar, p.pts);
            }
        }
        if (open.items.len > 0) {
            const loops = try chainLoops(ar, open.items);
            for (loops) |l| {
                drew = true;
                var bb = geom.bboxOfPath(l, true);
                bb = bb.grow(2.0 / @as(f64, self.ppi));
                if (!bb.intersects(self.cull)) continue;
                self.beginLoops();
                try self.addLoop(l, true);
                try self.fillPrepared(tint);
            }
        }
        return drew;
    }

    /// Blue outline of every item with this src (paths, fill outlines, text).
    fn drawOutline(self: *Tessellator, src: []const u8) Allocator.Error!void {
        const blue = self.pal.blue;
        for (self.drawing.items) |it| {
            if (!ir.srcMatches(it.src, src)) continue;
            switch (it.body) {
                .path => |p| {
                    if (self.drawing.penOf(it).dash_mm.len >= 2) continue; // hidden/dashed linework is not outlined
                    const W = @max(2.0, self.penPx(it) + 1.0);
                    if (!self.visible(it, W)) continue;
                    try self.pathToScreen(&self.tp, p.pts, p.closed);
                    var slice: []const P = self.tp.items;
                    var closed = p.closed;
                    if (closed) slice = slice[0 .. slice.len - 1];
                    if (slice.len < 2) continue;
                    if (slice.len == 2) closed = false;
                    try self.strokeP(slice, closed, W, .auto, blue);
                },
                .fill => |f| {
                    if (!self.visible(it, 4)) continue;
                    for (f.loops) |l| {
                        try self.pathToScreen(&self.tp, l, true);
                        const slice = self.tp.items[0 .. self.tp.items.len - 1];
                        if (slice.len < 3) continue;
                        try self.strokeP(slice, true, 2.0, .auto, blue);
                    }
                },
                .text => |t| {
                    if (!self.textVisible(t)) continue;
                    try self.drawText(t, @max(1.5, self.penPx(it) + 0.5), blue, 1.0);
                },
                .hatch => {},
            }
        }
    }

    // ---- stroking ---------------------------------------------------------

    fn strokeStyled(self: *Tessellator, pts: []const P, closed: bool, W: f32, dash_mm: []const f64, col: Color) Allocator.Error!void {
        if (dash_mm.len >= 2) {
            var pat: [16]f32 = undefined;
            const n = @min(dash_mm.len, pat.len);
            var period: f32 = 0;
            for (0..n) |i| {
                pat[i] = @floatCast(dash_mm[i] / 25.4 * @as(f64, self.ppp));
                if (!(pat[i] > 0)) pat[i] = 0.01;
                period += pat[i];
            }
            if (n >= 2 and period >= 3.0) {
                // dash pattern with an odd count repeats (AutoCAD semantic) — keep simple: even count only
                const m = n & ~@as(usize, 1);
                try self.strokeDashed(pts, closed, W, pat[0..m], col);
                return;
            }
        }
        try self.strokeP(pts, closed, W, .auto, col);
    }

    fn strokeDashed(self: *Tessellator, pts_in: []const P, closed: bool, W: f32, pat: []const f32, col: Color) Allocator.Error!void {
        const n = pts_in.len;
        if (n < 2) return;
        const nseg = if (closed) n else n - 1;
        var idx: usize = 0;
        var rem: f32 = pat[0];
        var on = true;
        self.dash.clearRetainingCapacity();
        try self.dash.append(self.gpa, pts_in[0]);
        var s: usize = 0;
        while (s < nseg) : (s += 1) {
            const a = pts_in[s];
            const b = pts_in[(s + 1) % n];
            const dx = b.x - a.x;
            const dy = b.y - a.y;
            const L = @sqrt(dx * dx + dy * dy);
            if (L < 1e-6) continue;
            const ux = dx / L;
            const uy = dy / L;
            var pos: f32 = 0;
            while (true) {
                const left = L - pos;
                if (rem > left) {
                    rem -= left;
                    if (on) try self.dash.append(self.gpa, b);
                    break;
                }
                pos += rem;
                const q: P = .{ .x = a.x + ux * pos, .y = a.y + uy * pos };
                if (on) {
                    try self.dash.append(self.gpa, q);
                    try self.strokeP(self.dash.items, false, W, .butt, col);
                    self.dash.clearRetainingCapacity();
                } else {
                    self.dash.clearRetainingCapacity();
                    try self.dash.append(self.gpa, q);
                }
                on = !on;
                idx = (idx + 1) % pat.len;
                rem = pat[idx];
                if (pos >= L - 1e-4) {
                    // dash boundary exactly at the vertex: next segment continues
                    if (on and self.dash.items.len == 0) try self.dash.append(self.gpa, q);
                    break;
                }
            }
        }
        if (on and self.dash.items.len >= 2) try self.strokeP(self.dash.items, false, W, .butt, col);
    }

    fn dot(self: *Tessellator, p: P, prof: Profile, col: Color) Allocator.Error!void {
        // small octagon fan; fringe ring when antialiased
        const steps = 8;
        const r_in = if (self.opt.antialias) prof.inner else prof.w;
        const r_out = prof.outer;
        const peak: f32 = if (self.opt.antialias and prof.n == 3 and prof.inner == 0) prof.alpha[1] else 1;
        const center = mk(p.x, p.y, col, col.a * peak);
        var prev_in: Vert = undefined;
        var prev_out: Vert = undefined;
        var j: usize = 0;
        while (j <= steps) : (j += 1) {
            const th = 2.0 * std.math.pi * @as(f32, @floatFromInt(j)) / steps;
            const cx = @cos(th);
            const sy = @sin(th);
            const vin = mk(p.x + cx * r_in, p.y + sy * r_in, col, col.a * peak);
            const vout = mk(p.x + cx * r_out, p.y + sy * r_out, col, 0);
            if (j > 0) {
                if (r_in > 0.02) try self.tri(center, prev_in, vin);
                if (self.opt.antialias) try self.quad(prev_in, vin, vout, prev_out);
            }
            prev_in = vin;
            prev_out = vout;
        }
    }

    /// Stroke a polyline given in screen px. See module doc for join/cap rules.
    fn strokeP(self: *Tessellator, pts_in: []const P, closed_in: bool, W: f32, cap_in: Cap, col: Color) Allocator.Error!void {
        const prof = makeProfile(W, self.opt.antialias);
        // dedupe
        self.sp.clearRetainingCapacity();
        try self.sp.ensureTotalCapacity(self.gpa, pts_in.len);
        for (pts_in) |p| {
            if (self.sp.items.len > 0) {
                const l = self.sp.items[self.sp.items.len - 1];
                if (@abs(p.x - l.x) < dedupe_eps and @abs(p.y - l.y) < dedupe_eps) continue;
            }
            self.sp.appendAssumeCapacity(p);
        }
        var closed = closed_in;
        if (closed and self.sp.items.len > 1) {
            const f = self.sp.items[0];
            const l = self.sp.items[self.sp.items.len - 1];
            if (@abs(f.x - l.x) < dedupe_eps and @abs(f.y - l.y) < dedupe_eps) _ = self.sp.pop();
        }
        const n = self.sp.items.len;
        if (n == 0) return;
        if (n == 1) return self.dot(self.sp.items[0], prof, col);
        if (n == 2) closed = false;
        const pts = self.sp.items;

        const nseg = if (closed) n else n - 1;
        try self.sd.resize(self.gpa, nseg);
        const dirs = self.sd.items;
        for (0..nseg) |i| {
            const a = pts[i];
            const b = pts[(i + 1) % n];
            const dx = b.x - a.x;
            const dy = b.y - a.y;
            const inv = 1.0 / @sqrt(dx * dx + dy * dy);
            dirs[i] = .{ .x = dx * inv, .y = dy * inv };
        }

        const cap: Cap = if (cap_in == .auto) (if (prof.w >= round_cap_min_w * 0.5) .round else .square) else cap_in;
        const joint_cap: Cap = if (prof.w >= round_cap_min_w * 0.5) .round else .square;

        // find breaks
        var first_break: ?usize = null;
        var any_break = false;
        if (closed) {
            for (0..n) |i| {
                const dp = dirs[(i + n - 1) % n];
                if (pDot(dp, dirs[i]) < miter_break_dot) {
                    if (first_break == null) first_break = i;
                    any_break = true;
                }
            }
        } else {
            for (1..n - 1) |i| {
                if (pDot(dirs[i - 1], dirs[i]) < miter_break_dot) {
                    any_break = true;
                    break;
                }
            }
        }

        if (!any_break) {
            return self.emitRun(pts, dirs, closed, cap, cap, prof, col);
        }

        // Rotate closed loops so they start at a break, then treat as open.
        var cp: []const P = pts;
        var cd: []const P = dirs;
        var ccap0 = cap;
        var ccap1 = cap;
        if (closed) {
            const b0 = first_break.?;
            self.sp2.clearRetainingCapacity();
            self.sd2.clearRetainingCapacity();
            try self.sp2.ensureTotalCapacity(self.gpa, n + 1);
            try self.sd2.ensureTotalCapacity(self.gpa, n);
            for (0..n) |k| {
                self.sp2.appendAssumeCapacity(pts[(b0 + k) % n]);
                self.sd2.appendAssumeCapacity(dirs[(b0 + k) % n]);
            }
            self.sp2.appendAssumeCapacity(pts[b0]);
            cp = self.sp2.items;
            cd = self.sd2.items;
            ccap0 = joint_cap;
            ccap1 = joint_cap;
        }
        // split at breaks
        const m = cp.len;
        var start: usize = 0;
        var i: usize = 1;
        while (i < m - 1) : (i += 1) {
            if (pDot(cd[i - 1], cd[i]) < miter_break_dot) {
                try self.emitRun(cp[start .. i + 1], cd[start..i], false, if (start == 0) ccap0 else joint_cap, joint_cap, prof, col);
                start = i;
            }
        }
        try self.emitRun(cp[start..m], cd[start .. m - 1], false, if (start == 0) ccap0 else joint_cap, ccap1, prof, col);
    }

    inline fn row(comptime N: usize, p: P, m: P, ra: f32, prof: *const Profile, col: Color) [N]Vert {
        var r: [N]Vert = undefined;
        inline for (0..N) |k| {
            r[k] = mk(p.x + m.x * prof.off[k], p.y + m.y * prof.off[k], col, col.a * prof.alpha[k] * ra);
        }
        return r;
    }

    inline fn rowQuads(self: *Tessellator, comptime N: usize, a: *const [N]Vert, b: *const [N]Vert) void {
        // capacity is reserved by emitRun
        const dst = self.buf.verts.addManyAsSliceAssumeCapacity(6 * (N - 1));
        inline for (0..N - 1) |k| {
            dst[k * 6 + 0] = a[k];
            dst[k * 6 + 1] = a[k + 1];
            dst[k * 6 + 2] = b[k + 1];
            dst[k * 6 + 3] = a[k];
            dst[k * 6 + 4] = b[k + 1];
            dst[k * 6 + 5] = b[k];
        }
    }

    fn capFan(self: *Tessellator, p: P, nrm: P, out_dir: P, prof: Profile, col: Color) Allocator.Error!void {
        const steps = 8;
        const aa = self.opt.antialias;
        const ri = if (aa) prof.inner else prof.w;
        const ro = prof.outer;
        const center = mk(p.x, p.y, col, col.a);
        var prev_in: Vert = undefined;
        var prev_out: Vert = undefined;
        var j: usize = 0;
        while (j <= steps) : (j += 1) {
            const th = std.math.pi * @as(f32, @floatFromInt(j)) / steps;
            const c = @cos(th);
            const s = @sin(th);
            const dv = pAdd(pMul(nrm, c), pMul(out_dir, s));
            const vin = mk(p.x + dv.x * ri, p.y + dv.y * ri, col, col.a);
            const vout = mk(p.x + dv.x * ro, p.y + dv.y * ro, col, 0);
            if (j > 0) {
                try self.tri(center, prev_in, vin);
                if (aa) try self.quad(prev_in, vin, vout, prev_out);
            }
            prev_in = vin;
            prev_out = vout;
        }
    }

    /// Emit one mitered ribbon run. `dirs[i]` is the unit direction of segment i
    /// (pts[i] -> pts[(i+1)%n]); for open runs `dirs.len == pts.len - 1`.
    fn emitRun(self: *Tessellator, pts: []const P, dirs: []const P, closed: bool, cap0: Cap, cap1: Cap, prof: Profile, col: Color) Allocator.Error!void {
        return switch (prof.n) {
            2 => self.emitRunN(2, pts, dirs, closed, cap0, cap1, prof, col),
            3 => self.emitRunN(3, pts, dirs, closed, cap0, cap1, prof, col),
            else => self.emitRunN(4, pts, dirs, closed, cap0, cap1, prof, col),
        };
    }

    fn emitRunN(self: *Tessellator, comptime N: usize, pts: []const P, dirs: []const P, closed: bool, cap0: Cap, cap1: Cap, prof: Profile, col: Color) Allocator.Error!void {
        const n = pts.len;
        // End ramps (feathered line ends) only for lines >= 2 px; thinner lines get hard ends,
        // which is invisible at 1 px and saves 1/3 of the geometry of text and hatch strokes.
        const aa = self.opt.antialias and prof.w >= 1.0;
        var prev: [N]Vert = undefined;
        var cur: [N]Vert = undefined;
        try self.buf.verts.ensureUnusedCapacity(self.gpa, (n + 4) * 18 + 400); // rows + round-cap fans

        if (closed) {
            // vertex i sits between dirs[i-1] and dirs[i]
            var i: usize = 0;
            while (i <= n) : (i += 1) {
                const k = i % n;
                const dp = dirs[(k + n - 1) % n];
                const dn = dirs[k];
                cur = row(N, pts[k], miterVec(dp, dn), 1, &prof, col);
                if (i > 0) self.rowQuads(N, &prev, &cur);
                prev = cur;
            }
            return;
        }

        // start cap
        {
            const d = dirs[0];
            const nm = leftN(d);
            const p = pts[0];
            switch (cap0) {
                .butt, .auto => if (aa) {
                    prev = row(N, pSub(p, pMul(d, 0.5)), nm, 0, &prof, col);
                    cur = row(N, pAdd(p, pMul(d, 0.5)), nm, 1, &prof, col);
                    self.rowQuads(N, &prev, &cur);
                    prev = cur;
                } else {
                    prev = row(N, p, nm, 1, &prof, col);
                },
                .square => if (aa) {
                    prev = row(N, pSub(p, pMul(d, prof.w + 0.5)), nm, 0, &prof, col);
                    cur = row(N, pSub(p, pMul(d, prof.w - 0.5)), nm, 1, &prof, col);
                    self.rowQuads(N, &prev, &cur);
                    prev = cur;
                } else {
                    prev = row(N, pSub(p, pMul(d, prof.w)), nm, 1, &prof, col);
                },
                .round => {
                    prev = row(N, p, nm, 1, &prof, col);
                    try self.capFan(p, nm, pMul(d, -1), prof, col);
                },
            }
        }
        // interior vertices
        var i: usize = 1;
        while (i + 1 < n) : (i += 1) {
            cur = row(N, pts[i], miterVec(dirs[i - 1], dirs[i]), 1, &prof, col);
            self.rowQuads(N, &prev, &cur);
            prev = cur;
        }
        // end cap
        {
            const d = dirs[n - 2];
            const nm = leftN(d);
            const p = pts[n - 1];
            switch (cap1) {
                .butt, .auto => if (aa) {
                    cur = row(N, pSub(p, pMul(d, 0.5)), nm, 1, &prof, col);
                    self.rowQuads(N, &prev, &cur);
                    prev = cur;
                    cur = row(N, pAdd(p, pMul(d, 0.5)), nm, 0, &prof, col);
                    self.rowQuads(N, &prev, &cur);
                } else {
                    cur = row(N, p, nm, 1, &prof, col);
                    self.rowQuads(N, &prev, &cur);
                },
                .square => if (aa) {
                    cur = row(N, pAdd(p, pMul(d, prof.w - 0.5)), nm, 1, &prof, col);
                    self.rowQuads(N, &prev, &cur);
                    prev = cur;
                    cur = row(N, pAdd(p, pMul(d, prof.w + 0.5)), nm, 0, &prof, col);
                    self.rowQuads(N, &prev, &cur);
                } else {
                    cur = row(N, pAdd(p, pMul(d, prof.w)), nm, 1, &prof, col);
                    self.rowQuads(N, &prev, &cur);
                },
                .round => {
                    cur = row(N, p, nm, 1, &prof, col);
                    self.rowQuads(N, &prev, &cur);
                    try self.capFan(p, nm, d, prof, col);
                },
            }
        }
    }

    // ---- solid fills ------------------------------------------------------

    fn beginLoops(self: *Tessellator) void {
        self.scr.clearRetainingCapacity();
        self.loop_ends.clearRetainingCapacity();
    }

    /// Flatten a model-space loop to screen px (f64) and append it as the next loop.
    fn addLoop(self: *Tessellator, pts: []const ir.Pt, is_outer: bool) Allocator.Error!void {
        _ = is_outer;
        self.flat.clearRetainingCapacity();
        const tol_model: f64 = 0.15 / @as(f64, self.ppi);
        try geom.appendFlattened(&self.flat, self.gpa, pts, true, tol_model);
        const start = self.scr.items.len;
        try self.scr.ensureUnusedCapacity(self.gpa, self.flat.items.len);
        for (self.flat.items) |q| {
            const sxv: f64 = self.view.sx(q.x);
            const syv: f64 = self.view.sy(q.y);
            if (self.scr.items.len > start) {
                const l = self.scr.items[self.scr.items.len - 1];
                if (@abs(l.x - sxv) < dedupe_eps and @abs(l.y - syv) < dedupe_eps) continue;
            }
            self.scr.appendAssumeCapacity(.{ .x = sxv, .y = syv });
        }
        // drop closing duplicate
        if (self.scr.items.len - start > 1) {
            const f = self.scr.items[start];
            const l = self.scr.items[self.scr.items.len - 1];
            if (@abs(l.x - f.x) < dedupe_eps and @abs(l.y - f.y) < dedupe_eps) _ = self.scr.pop();
        }
        try self.loop_ends.append(self.gpa, @intCast(self.scr.items.len));
    }

    fn loopRange(self: *const Tessellator, i: usize) struct { s: usize, e: usize } {
        const s: usize = if (i == 0) 0 else self.loop_ends.items[i - 1];
        return .{ .s = s, .e = self.loop_ends.items[i] };
    }

    /// Fill the loops accumulated by beginLoops/addLoop (loop 0 outer, rest holes).
    fn fillPrepared(self: *Tessellator, col: Color) Allocator.Error!void {
        const nl = self.loop_ends.items.len;
        if (nl == 0) return;
        const aa = self.opt.antialias;

        // orientation: outer positive area, holes negative (in screen numbers)
        var valid = true;
        for (0..nl) |i| {
            const r = self.loopRange(i);
            const l = self.scr.items[r.s..r.e];
            if (l.len < 3) {
                if (i == 0) valid = false;
                continue;
            }
            const area = geom.polygonArea(l);
            if ((i == 0 and area < 0) or (i > 0 and area > 0)) std.mem.reverse(Vec2, self.scr.items[r.s..r.e]);
        }
        if (!valid) return;

        // inset decision on the outer loop
        const r0 = self.loopRange(0);
        var bb = geom.BBox.empty;
        for (self.scr.items[r0.s..r0.e]) |q| bb.addPoint(q.x, q.y);
        const inset: f64 = if (aa and @min(bb.width(), bb.height()) > 4.0) 0.5 else 0.0;
        const out_dist: f64 = if (aa) (if (inset > 0) 0.5 else 1.0) else 0.0;

        // rings
        self.ring_in.clearRetainingCapacity();
        self.ring_out.clearRetainingCapacity();
        try self.ring_in.ensureTotalCapacity(self.gpa, self.scr.items.len);
        try self.ring_out.ensureTotalCapacity(self.gpa, self.scr.items.len);
        for (0..nl) |li| {
            const r = self.loopRange(li);
            const l = self.scr.items[r.s..r.e];
            const m = l.len;
            for (l, 0..) |v, i| {
                const pp = l[(i + m - 1) % m];
                const nn = l[(i + 1) % m];
                // outward = right of travel for positive-area loops in these numbers: (dy, -dx)... derive by orientation
                const d0 = unit2(v.x - pp.x, v.y - pp.y);
                const d1 = unit2(nn.x - v.x, nn.y - v.y);
                const n0 = Vec2{ .x = d0.y, .y = -d0.x };
                const n1 = Vec2{ .x = d1.y, .y = -d1.x };
                var mv = Vec2{ .x = n0.x + n1.x, .y = n0.y + n1.y };
                const k = 1.0 + (n0.x * n1.x + n0.y * n1.y);
                if (k < 0.16) {
                    mv = n1;
                } else {
                    mv = .{ .x = mv.x / k, .y = mv.y / k };
                    const ml = @sqrt(mv.x * mv.x + mv.y * mv.y);
                    if (ml > 2.5) mv = .{ .x = mv.x * 2.5 / ml, .y = mv.y * 2.5 / ml };
                }
                // For a positive-area loop in screen numbers (y down) the interior is on the LEFT of travel
                // in the numeric frame, so numeric-right = outside. Holes (negative) have fill on the left too.
                // => outward = numeric-right in both cases?  Interior(left) = +(-dy,dx); right = (dy,-dx).
                self.ring_in.appendAssumeCapacity(.{ .x = v.x - mv.x * inset, .y = v.y - mv.y * inset });
                self.ring_out.appendAssumeCapacity(.{ .x = v.x + mv.x * out_dist, .y = v.y + mv.y * out_dist });
            }
        }

        // interior triangles
        self.tris.clearRetainingCapacity();
        const in0 = self.ring_in.items[r0.s..r0.e];
        if (nl == 1 and isConvex(in0)) {
            var i: usize = 1;
            while (i + 1 < in0.len) : (i += 1) {
                try self.tris.appendSlice(self.gpa, &.{ in0[0], in0[i], in0[i + 1] });
            }
        } else {
            self.holes.clearRetainingCapacity();
            for (1..nl) |li| {
                const r = self.loopRange(li);
                if (r.e - r.s < 3) continue;
                try self.holes.append(self.gpa, self.ring_in.items[r.s..r.e]);
            }
            try geom.triangulate(self.gpa, in0, self.holes.items, &self.tris);
        }
        try self.buf.verts.ensureUnusedCapacity(self.gpa, self.tris.items.len);
        for (self.tris.items) |q| self.buf.verts.appendAssumeCapacity(mk(@floatCast(q.x), @floatCast(q.y), col, col.a));

        // fringe
        if (aa) {
            for (0..nl) |li| {
                const r = self.loopRange(li);
                const m = r.e - r.s;
                if (m < 3) continue;
                var i: usize = 0;
                while (i < m) : (i += 1) {
                    const j = (i + 1) % m;
                    const a0 = self.ring_in.items[r.s + i];
                    const a1 = self.ring_in.items[r.s + j];
                    const b0 = self.ring_out.items[r.s + i];
                    const b1 = self.ring_out.items[r.s + j];
                    try self.quad(
                        mk(@floatCast(a0.x), @floatCast(a0.y), col, col.a),
                        mk(@floatCast(a1.x), @floatCast(a1.y), col, col.a),
                        mk(@floatCast(b1.x), @floatCast(b1.y), col, 0),
                        mk(@floatCast(b0.x), @floatCast(b0.y), col, 0),
                    );
                }
            }
        }
    }
};

fn ptEq(a: ir.Pt, b: ir.Pt) bool {
    return @abs(a.x - b.x) < 2e-3 and @abs(a.y - b.y) < 2e-3;
}

/// Reverse a bulge path (vertex k = p[n-k], bulge of segment k = -bulge of the original segment n-1-k).
fn reversedPath(ar: Allocator, p: []const ir.Pt) Allocator.Error![]ir.Pt {
    const n = p.len;
    const out = try ar.alloc(ir.Pt, n);
    for (0..n) |k| {
        const src_i = n - 1 - k;
        out[k] = .{ .x = p[src_i].x, .y = p[src_i].y, .b = if (src_i >= 1) -p[src_i - 1].b else 0 };
    }
    return out;
}

/// Greedily chain open paths (matching end points within 0.002 in) into closed loops.
/// Chains that do not close are closed with a straight chord when they have >= 3 vertices and a real
/// area (a U-shaped wood outline whose bottom edge is shared with a neighbour), else dropped.
/// Allocations come from `ar` (an arena).
pub fn chainLoops(ar: Allocator, paths: []const []const ir.Pt) Allocator.Error![]const []const ir.Pt {
    const used = try ar.alloc(bool, paths.len);
    @memset(used, false);
    var loops: std.ArrayList([]const ir.Pt) = .empty;
    for (paths, 0..) |first, fi| {
        if (used[fi] or first.len < 2) continue;
        used[fi] = true;
        var chain: std.ArrayList(ir.Pt) = .empty;
        try chain.appendSlice(ar, first);
        var guard: usize = 0;
        while (guard < paths.len + 1) : (guard += 1) {
            if (chain.items.len >= 3 and ptEq(chain.items[0], chain.items[chain.items.len - 1])) break;
            const end = chain.items[chain.items.len - 1];
            var progressed = false;
            for (paths, 0..) |cand, ci| {
                if (used[ci] or cand.len < 2) continue;
                var piece: ?[]const ir.Pt = null;
                if (ptEq(cand[0], end)) {
                    piece = cand;
                } else if (ptEq(cand[cand.len - 1], end)) {
                    piece = try reversedPath(ar, cand);
                }
                if (piece) |pc| {
                    used[ci] = true;
                    // the join vertex keeps the new piece's first bulge
                    chain.items[chain.items.len - 1].b = pc[0].b;
                    try chain.appendSlice(ar, pc[1..]);
                    progressed = true;
                    break;
                }
            }
            if (!progressed) break;
        }
        if (chain.items.len >= 4 and ptEq(chain.items[0], chain.items[chain.items.len - 1])) {
            _ = chain.pop(); // drop the duplicated closing vertex; its bulge is the closing segment's
            try loops.append(ar, chain.items);
        } else if (chain.items.len >= 3) {
            chain.items[chain.items.len - 1].b = 0;
            if (@abs(geom.loopArea(chain.items)) > 1e-4) try loops.append(ar, chain.items);
        }
    }
    return loops.items;
}

inline fn mk(x: f32, y: f32, c: Color, a: f32) Vert {
    return .{ .x = x, .y = y, .r = c.r, .g = c.g, .b = c.b, .a = a };
}

fn unit2(dx: f64, dy: f64) Vec2 {
    const l = @sqrt(dx * dx + dy * dy);
    if (l < 1e-12) return .{ .x = 1, .y = 0 };
    return .{ .x = dx / l, .y = dy / l };
}

fn isConvex(l: []const Vec2) bool {
    if (l.len < 3) return false;
    var sign: f64 = 0;
    for (l, 0..) |p, i| {
        const q = l[(i + 1) % l.len];
        const r = l[(i + 2) % l.len];
        const c = (q.x - p.x) * (r.y - q.y) - (q.y - p.y) * (r.x - q.x);
        if (c == 0) continue;
        if (sign == 0) sign = c else if ((sign > 0) != (c > 0)) return false;
    }
    return sign != 0;
}

/// Offset vector for a vertex between unit directions d0 (in) and d1 (out): the
/// bisector of the two left normals scaled so that the perpendicular width is preserved.
inline fn miterVec(d0: P, d1: P) P {
    const n0 = leftN(d0);
    const n1 = leftN(d1);
    const k = 1.0 + pDot(n0, n1);
    if (k < 0.16) return n1;
    const s = 1.0 / k;
    return .{ .x = (n0.x + n1.x) * s, .y = (n0.y + n1.y) * s };
}

fn gridFade(spx: f32) f32 {
    const lo: f32 = 5.0;
    const hi: f32 = 12.0;
    if (spx <= lo) return 0;
    if (spx >= hi) return 1;
    const t = (spx - lo) / (hi - lo);
    return t * t * (3 - 2 * t);
}
