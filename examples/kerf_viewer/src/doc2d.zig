//! The 2D half of a Kerf document: parsed drawings (SECTION / ISO sheets), a
//! pan / zoom camera per sheet, and the tessellated triangle list that the app
//! hands to a teak canvas as ONE `CanvasPrimitive.triangles` batch (with a
//! content `key`, so an unchanged frame costs nothing).
//!
//! Pure logic over `draw/` (the Kerf drawing pipeline ported from the archived
//! teak app): no teak widgets, no rendering. The app's `update` drives it from
//! canvas events and rebuilds the triangles; `view` only reads the result.
//! Selection and hover are expressed as drawing `src` ids ("jack_studs#1");
//! the app maps those to mesh parts (`partForSrc` / `srcOfPart`) so the parts
//! table, the 2D sheet and the 3D viewport share one selection.

const std = @import("std");
const Allocator = std.mem.Allocator;
const draw = @import("draw/mod.zig");
const kerf = @import("kerf_mesh.zig");

pub const ir = draw.ir;
pub const View = draw.tess.View;

pub const Kind = enum { section, iso, other };

pub const Sheet = struct {
    d: ir.Drawing,
    cam: View = .{ .px_per_model_in = 8, .origin_x = 0, .origin_y = 0, .width = 100, .height = 100 },
    /// False until the sheet has been framed (or the user moved the camera).
    fitted: bool = false,

    pub fn kind(s: *const Sheet) Kind {
        if (std.mem.eql(u8, s.d.kind, "iso")) return .iso;
        if (std.mem.eql(u8, s.d.kind, "section")) return .section;
        return .other;
    }
};

pub const min_zoom: f32 = 0.4;
pub const max_zoom: f32 = 600;
const fit_margin: f32 = 28;

pub const Docs2D = struct {
    gpa: Allocator,
    font: draw.font.Font,
    tess: draw.tess.Tessellator,
    sheets: std.ArrayList(Sheet) = .empty,
    /// Canvas size in logical px (from its `layout` event).
    w: f32 = 0,
    h: f32 = 0,
    /// Content revision of the triangle list (the canvas frame-diff key).
    key: u64 = 1,
    /// Inputs of the last tessellation; identical inputs skip the rebuild.
    sig: ?Sig = null,
    /// Bumped whenever the sheet list changes.
    sheets_rev: u32 = 0,

    const Sig = struct {
        sheet: usize,
        cam: View,
        selected: [64]u8,
        selected_len: u8,
        hovered: [64]u8,
        hovered_len: u8,
        grid: bool,
        sheets_rev: u32,
    };

    pub fn create(gpa: Allocator) !*Docs2D {
        const self = try gpa.create(Docs2D);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .font = try draw.font.Font.initEmbedded(gpa),
            .tess = draw.tess.Tessellator.init(gpa),
        };
        return self;
    }

    pub fn destroy(self: *Docs2D) void {
        self.clear();
        self.sheets.deinit(self.gpa);
        self.tess.deinit();
        self.font.deinit();
        self.gpa.destroy(self);
    }

    pub fn clear(self: *Docs2D) void {
        for (self.sheets.items) |*s| s.d.deinit();
        self.sheets.clearRetainingCapacity();
        self.sheets_rev +%= 1;
        self.sig = null;
    }

    /// Parse `json` as a Kerf drawing and add it; a sheet with the same view
    /// name (A, B, ...) is replaced. Returns its index.
    pub fn add(self: *Docs2D, json: []const u8) !usize {
        var d = try ir.parse(self.gpa, json);
        errdefer d.deinit();
        self.sheets_rev +%= 1;
        self.sig = null;
        for (self.sheets.items, 0..) |*s, i| {
            if (std.mem.eql(u8, s.d.view, d.view)) {
                s.d.deinit();
                s.* = .{ .d = d };
                return i;
            }
        }
        try self.sheets.append(self.gpa, .{ .d = d });
        std.mem.sort(Sheet, self.sheets.items, {}, lessByView);
        for (self.sheets.items, 0..) |*s, i| {
            if (std.mem.eql(u8, s.d.view, d.view)) return i;
        }
        unreachable;
    }

    fn lessByView(_: void, a: Sheet, b: Sheet) bool {
        return std.mem.lessThan(u8, a.d.view, b.d.view);
    }

    pub fn count(self: *const Docs2D, kind: Kind) usize {
        var n: usize = 0;
        for (self.sheets.items) |s| n += @intFromBool(s.kind() == kind);
        return n;
    }

    /// Sheet index of the `n`-th sheet of `kind`.
    pub fn nth(self: *const Docs2D, kind: Kind, n: usize) ?usize {
        var seen: usize = 0;
        for (self.sheets.items, 0..) |s, i| {
            if (s.kind() != kind) continue;
            if (seen == n) return i;
            seen += 1;
        }
        return null;
    }

    pub fn sheet(self: *Docs2D, idx: usize) ?*Sheet {
        return if (idx < self.sheets.items.len) &self.sheets.items[idx] else null;
    }

    pub fn fit(self: *Docs2D, idx: usize) void {
        const s = self.sheet(idx) orelse return;
        if (self.w <= 0 or self.h <= 0) return;
        s.cam = View.fit(self.extent(s), self.w, self.h, fit_margin);
        s.fitted = true;
    }

    /// The drawing's `bounds` grown to include every text run (callout text
    /// often runs past the geometry the engine bounded).
    pub fn extent(self: *const Docs2D, s: *const Sheet) [4]f64 {
        var bb = s.d.boundsBox();
        for (s.d.items) |it| switch (it.body) {
            .text => |t| bb.merge(self.font.textBBox(t.s, t.h, t.x, t.y, t.rot, t.halign, t.valign)),
            else => {},
        };
        return .{ bb.x0, bb.y0, bb.x1, bb.y1 };
    }

    /// Size the canvas; unfitted sheets (and every sheet whose camera the user
    /// never touched) are re-framed so a resize keeps the drawing centred.
    pub fn resize(self: *Docs2D, w: f32, h: f32) void {
        if (w == self.w and h == self.h) return;
        self.w = w;
        self.h = h;
        for (self.sheets.items, 0..) |*s, i| {
            if (!s.fitted) self.fit(i);
            s.cam.width = w;
            s.cam.height = h;
        }
    }

    pub fn zoomAt(self: *Docs2D, idx: usize, x: f32, y: f32, factor: f32) void {
        const s = self.sheet(idx) orelse return;
        const target = std.math.clamp(s.cam.px_per_model_in * factor, min_zoom, max_zoom);
        s.cam = s.cam.zoomAt(x, y, target / s.cam.px_per_model_in);
        s.fitted = true;
    }

    pub fn zoomStep(self: *Docs2D, idx: usize, factor: f32) void {
        self.zoomAt(idx, self.w * 0.5, self.h * 0.5, factor);
    }

    pub fn pan(self: *Docs2D, idx: usize, dx: f32, dy: f32) void {
        const s = self.sheet(idx) orelse return;
        s.cam = s.cam.panned(dx, dy);
        s.fitted = true;
    }

    /// `src` of the topmost thing under canvas-local `(x, y)` (4 px tolerance).
    pub fn pickSrc(self: *Docs2D, idx: usize, x: f32, y: f32) ?[]const u8 {
        const s = self.sheet(idx) orelse return null;
        const tol = 4.0 / @as(f64, s.cam.px_per_model_in);
        return draw.pick.pick(&s.d, &self.font, s.cam.modelX(x), s.cam.modelY(y), tol);
    }

    /// Does any item of the sheet belong to this exact `src`?
    pub fn hasExactSrc(self: *Docs2D, idx: usize, src: []const u8) bool {
        const s = self.sheet(idx) orelse return false;
        for (s.d.items) |it| if (std.mem.eql(u8, it.src, src)) return true;
        return false;
    }

    /// Does the sheet draw anything for this component (base id or instance)?
    pub fn hasSrc(self: *Docs2D, idx: usize, src: []const u8) bool {
        const s = self.sheet(idx) orelse return false;
        for (s.d.items) |it| if (ir.srcMatches(it.src, src)) return true;
        return false;
    }

    /// Rebuild the triangle list for sheet `idx` with `selected` / `hovered`
    /// highlighted. A no-op when nothing changed since the last build.
    pub fn retess(self: *Docs2D, idx: usize, selected: []const u8, hovered: []const u8, grid: bool) void {
        const s = self.sheet(idx) orelse {
            self.tess.buf.clear();
            self.sig = null;
            self.key +%= 1;
            return;
        };
        if (self.w <= 0 or self.h <= 0) return;
        s.cam.width = self.w;
        s.cam.height = self.h;
        var sig: Sig = .{
            .sheet = idx,
            .cam = s.cam,
            .selected = undefined,
            .selected_len = @intCast(@min(selected.len, 64)),
            .hovered = undefined,
            .hovered_len = @intCast(@min(hovered.len, 64)),
            .grid = grid,
            .sheets_rev = self.sheets_rev,
        };
        @memcpy(sig.selected[0..sig.selected_len], selected[0..sig.selected_len]);
        @memcpy(sig.hovered[0..sig.hovered_len], hovered[0..sig.hovered_len]);
        if (self.sig) |old| {
            if (sigEql(old, sig)) return;
        }
        self.sig = sig;
        self.tess.build(&s.d, &self.font, s.cam, draw.tess.Palette.live(), .{
            .selected = if (selected.len > 0) selected else null,
            .hovered = if (hovered.len > 0) hovered else null,
            .grid = grid,
        }) catch {
            self.tess.buf.clear(); // OOM: draw nothing rather than stale triangles
        };
        self.key +%= 1;
    }

    fn sigEql(a: Sig, b: Sig) bool {
        return a.sheet == b.sheet and std.meta.eql(a.cam, b.cam) and a.grid == b.grid and
            a.sheets_rev == b.sheets_rev and
            std.mem.eql(u8, a.selected[0..a.selected_len], b.selected[0..b.selected_len]) and
            std.mem.eql(u8, a.hovered[0..a.hovered_len], b.hovered[0..b.hovered_len]);
    }

    pub fn verts(self: *const Docs2D) []const draw.tess.Vert {
        return self.tess.verts();
    }
};

/// 1-based part id for a drawing `src` ("beam", "studs#1"), 0 when it names
/// no part (notes, dimensions, titles). A bare id with several instances maps
/// to the first; "#k" picks the part whose `instance` is `k`.
pub fn partForSrc(parts: []const kerf.Part, src: []const u8) u32 {
    const base = ir.srcBase(src);
    const inst: ?u32 = if (std.mem.indexOfScalar(u8, src, '#')) |i|
        std.fmt.parseInt(u32, src[i + 1 ..], 10) catch null
    else
        null;
    for (parts) |p| {
        if (!std.mem.eql(u8, p.src, base)) continue;
        if (inst == null or inst.? == p.instance) return p.index + 1;
    }
    return 0;
}

/// The `src` to hand the tessellator for a part: the exact "src#k" when the
/// sheet draws that instance by itself, else the bare component id (which
/// matches every instance). Written into `buf`; empty when the sheet does not
/// draw the part at all.
pub fn srcOfPart(docs: *Docs2D, idx: usize, p: kerf.Part, buf: []u8) []const u8 {
    const exact = std.fmt.bufPrint(buf, "{s}#{d}", .{ p.src, p.instance }) catch return "";
    if (docs.hasExactSrc(idx, exact)) return exact;
    if (docs.hasSrc(idx, p.src)) {
        const n = @min(p.src.len, buf.len);
        @memcpy(buf[0..n], p.src[0..n]);
        return buf[0..n];
    }
    return "";
}

const testing = std.testing;
const flush_a = @embedFile("fixtures/flush-psl-2x6.A.json");
const flush_b = @embedFile("fixtures/flush-psl-2x6.B.json");
