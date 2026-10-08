//! Hit testing in MODEL space for hover / select / note dragging.
//!
//! ```zig
//! const tol = 4.0 / view.px_per_model_in;               // 4 screen px in model inches
//! if (pick.pick(&drawing, &font, mx, my, tol)) |src| ...  // topmost src under the cursor
//! const bb = pick.bboxOfSrc(&drawing, &font, "sill_plate");
//! const o = pick.textOrigin(&drawing, "n_roof");          // where to start a note drag
//! ```
//!
//! Priority (first match wins):
//!  1. text items (exact rotated advance box, `tol` expanded), topmost first;
//!  2. solid fills (rebar dots, arrowheads, steel): inside (even-odd, arcs exact) or within `tol` of the outline;
//!  3. linework (paths, open or closed, incl. leaders and dimension lines): the NEAREST
//!     within `tol`, ties go to the item drawn later (topmost);
//!  4. interiors of closed `cut`/`profile`/unnamed-pen paths and of hatch regions (even-odd
//!     with holes): the smallest enclosing region wins (nested components pick the inner one),
//!     ties go to the item drawn later.
//! `bboxOfSrc` / `textOrigin` accept a component id ("truss" also matches "truss#0", "truss#1")
//! or an exact instance ("truss#1"). `pick` returns the item's full `src` (use `ir.srcBase`).
//! Items without a `src` are never hit. Hatch pattern lines themselves are not pickable.
//! Everything works on arcs analytically (no allocation).

const std = @import("std");
const geom = @import("geom.zig");
const ir = @import("ir.zig");
const Font = @import("font.zig").Font;

pub const Vec2 = geom.Vec2;
pub const BBox = geom.BBox;

pub const HitKind = enum { text, fill, line, region };

pub const Hit = struct {
    src: []const u8,
    kind: HitKind,
    /// Index into `drawing.items`.
    item: usize,
    /// Distance from the cursor (0 for text/region/fill hits that contain it).
    dist: f64,
};

/// Is (px, py) inside the (rotated, aligned) advance box of a text item, grown by `tol`?
pub fn textContains(font: *const Font, t: ir.Text, px: f64, py: f64, tol: f64) bool {
    const rad = std.math.degreesToRadians(t.rot);
    const cr = @cos(rad);
    const sr = @sin(rad);
    const dx = px - t.x;
    const dy = py - t.y;
    // into text-local frame (rotate by -rot)
    const lx = dx * cr + dy * sr;
    const ly = -dx * sr + dy * cr;
    const sc = t.h / font.cap_height;
    const vshift: f64 = switch (t.valign) {
        .baseline => 0,
        .bottom => 7.0 * sc,
        .middle => -t.h * 0.5,
        .top => -t.h,
    };
    var it = std.mem.splitScalar(u8, t.s, '\n');
    var li: usize = 0;
    while (it.next()) |ln| : (li += 1) {
        if (ln.len == 0) continue;
        const w = font.lineWidth(ln, t.h);
        const x0: f64 = switch (t.halign) {
            .left => 0,
            .center => -w * 0.5,
            .right => -w,
        };
        const by = vshift - @as(f64, @floatFromInt(li)) * @import("font.zig").line_spacing * t.h;
        if (lx >= x0 - tol and lx <= x0 + w + tol and ly >= by - 7.0 * sc - tol and ly <= by + t.h + tol) return true;
    }
    return false;
}

fn isRegionPen(d: *const ir.Drawing, it: ir.Item) bool {
    const name = d.penOf(it).name;
    return name.len == 0 or std.mem.eql(u8, name, "cut") or std.mem.eql(u8, name, "profile");
}

/// Full hit record, or null.
pub fn pickHit(d: *const ir.Drawing, font: *const Font, x: f64, y: f64, tol: f64) ?Hit {
    const items = d.items;

    // 1. text
    var i: usize = items.len;
    while (i > 0) {
        i -= 1;
        const it = items[i];
        if (it.src.len == 0 or it.body != .text) continue;
        if (!it.bbox.grow(tol).contains(x, y)) continue;
        if (textContains(font, it.body.text, x, y, tol)) return .{ .src = it.src, .kind = .text, .item = i, .dist = 0 };
    }

    // 2. fills
    i = items.len;
    while (i > 0) {
        i -= 1;
        const it = items[i];
        if (it.src.len == 0 or it.body != .fill) continue;
        if (!it.bbox.grow(tol).contains(x, y)) continue;
        const loops = it.body.fill.loops;
        var inside = false;
        for (loops) |l| if (geom.pointInLoop(l, x, y)) {
            inside = !inside;
        };
        if (inside) return .{ .src = it.src, .kind = .fill, .item = i, .dist = 0 };
        var best = std.math.inf(f64);
        for (loops) |l| best = @min(best, geom.distToPath(x, y, l, true));
        if (best <= tol) return .{ .src = it.src, .kind = .fill, .item = i, .dist = best };
    }

    // 3. linework: nearest path within tol, ties -> topmost
    var best_i: ?usize = null;
    var best_d: f64 = std.math.inf(f64);
    i = items.len;
    while (i > 0) {
        i -= 1;
        const it = items[i];
        if (it.src.len == 0 or it.body != .path) continue;
        if (!it.bbox.grow(tol).contains(x, y)) continue;
        const p = it.body.path;
        const dist = geom.distToPath(x, y, p.pts, p.closed);
        if (dist <= tol and dist < best_d - 1e-12) {
            best_d = dist;
            best_i = i;
        }
    }
    if (best_i) |bi| return .{ .src = items[bi].src, .kind = .line, .item = bi, .dist = best_d };

    // 4. interiors: smallest enclosing region
    var reg_i: ?usize = null;
    var reg_area: f64 = std.math.inf(f64);
    i = items.len;
    while (i > 0) {
        i -= 1;
        const it = items[i];
        if (it.src.len == 0) continue;
        if (!it.bbox.contains(x, y)) continue;
        switch (it.body) {
            .path => |p| {
                if (!p.closed or !isRegionPen(d, it) or p.pts.len < 3) continue;
                if (!geom.pointInLoop(p.pts, x, y)) continue;
                const a = @abs(geom.loopArea(p.pts));
                if (a < reg_area - 1e-9) {
                    reg_area = a;
                    reg_i = i;
                }
            },
            .hatch => |h| {
                if (h.loops.len == 0) continue;
                if (!geom.pointInLoopsEvenOdd(h.loops, x, y)) continue;
                var a: f64 = @abs(geom.loopArea(h.loops[0]));
                for (h.loops[1..]) |hole| a -= @abs(geom.loopArea(hole));
                if (a < reg_area - 1e-9) {
                    reg_area = a;
                    reg_i = i;
                }
            },
            else => {},
        }
    }
    if (reg_i) |ri| return .{ .src = items[ri].src, .kind = .region, .item = ri, .dist = 0 };
    return null;
}

/// `src` of the topmost thing under (x, y) within `tol` model inches, or null.
pub fn pick(d: *const ir.Drawing, font: *const Font, x: f64, y: f64, tol: f64) ?[]const u8 {
    return if (pickHit(d, font, x, y, tol)) |h| h.src else null;
}

/// Model-space bounding box of every item belonging to `src` (null if none).
/// Text uses the exact aligned/rotated advance box (via the font).
pub fn bboxOfSrc(d: *const ir.Drawing, font: *const Font, src: []const u8) ?BBox {
    if (src.len == 0) return null;
    var bb = BBox.empty;
    for (d.items) |it| {
        if (!ir.srcMatches(it.src, src)) continue;
        switch (it.body) {
            .text => |t| bb.merge(font.textBBox(t.s, t.h, t.x, t.y, t.rot, t.halign, t.valign)),
            .hatch => |h| {
                // loops only (lines lie inside them)
                if (h.loops.len > 0) {
                    for (h.loops) |l| bb.merge(geom.bboxOfPath(l, true));
                } else bb.merge(it.bbox);
            },
            else => bb.merge(it.bbox),
        }
    }
    return if (bb.isEmpty()) null else bb;
}

pub const TextOrigin = struct {
    x: f64,
    y: f64,
    halign: ir.HAlign,
    valign: ir.VAlign,
    h: f64,
    rot: f64,
};

/// Anchor of the first (top-most, then left-most) text line of `src`: the point a
/// note drag moves (the note's `place`). Null when `src` has no text.
pub fn textOrigin(d: *const ir.Drawing, src: []const u8) ?TextOrigin {
    if (src.len == 0) return null;
    var best: ?ir.Text = null;
    for (d.items) |it| {
        if (it.body != .text or !ir.srcMatches(it.src, src)) continue;
        const t = it.body.text;
        if (best) |b| {
            if (t.y > b.y + 1e-9 or (@abs(t.y - b.y) <= 1e-9 and t.x < b.x)) best = t;
        } else best = t;
    }
    const b = best orelse return null;
    return .{ .x = b.x, .y = b.y, .halign = b.halign, .valign = b.valign, .h = b.h, .rot = b.rot };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const pick_json =
    \\{ "kerf_drawing": "0.1", "scale": 12, "bounds": [0,0,40,20],
    \\  "pens": { "cut": {"width_mm": 0.5}, "beyond": {"width_mm": 0.18}, "anno": {"width_mm": 0.18}, "hatch": {"width_mm": 0.09} },
    \\  "items": [
    \\    { "t": "path", "pen": "cut", "src": "big", "closed": true, "pts": [[0,0],[20,0],[20,10],[0,10]] },
    \\    { "t": "hatch", "pen": "hatch", "src": "big", "pattern": "ANSI31", "loops": [[[0,0],[20,0],[20,10],[0,10]], [[8,3],[12,3],[12,7],[8,7]]], "lines": [[0,0,1,1]] },
    \\    { "t": "path", "pen": "cut", "src": "inner", "closed": true, "pts": [[8,3],[12,3],[12,7],[8,7]] },
    \\    { "t": "path", "pen": "cut", "src": "arcy", "closed": true, "pts": [[25,0,1],[35,0],[35,1]] },
    \\    { "t": "fill", "src": "dot", "loops": [[[15,5,1],[16,5,1]]] },
    \\    { "t": "path", "pen": "anno", "src": "n1", "pts": [[20,15],[30,15]] },
    \\    { "t": "path", "pen": "beyond", "pts": [[0,18],[5,18]] },
    \\    { "t": "text", "pen": "anno", "src": "n1", "s": "NOTE TEXT", "x": 30.5, "y": 14.5, "h": 1.125, "align": "left" },
    \\    { "t": "text", "pen": "anno", "src": "n1", "s": "SECOND", "x": 30.5, "y": 12.0, "h": 1.125 },
    \\    { "t": "text", "pen": "anno", "src": "rot", "s": "VERT", "x": 38, "y": 2, "h": 1, "rot": 90 }
    \\  ] }
;

test "pick: interior, nesting (smallest region), outside, no src" {
    var d = try ir.parse(testing.allocator, pick_json);
    defer d.deinit();
    var font = try Font.initEmbedded(testing.allocator);
    defer font.deinit();
    // inside big only
    try testing.expectEqualStrings("big", pick(&d, &font, 4, 5, 0.1).?);
    // inside inner (nested) => inner (smaller region); the hatch hole excludes big's hatch there
    try testing.expectEqualStrings("inner", pick(&d, &font, 10, 5, 0.1).?);
    // outside everything
    try testing.expect(pick(&d, &font, 22, 18, 0.1) == null);
    // item without src (beyond path at y=18) is never a hit
    try testing.expect(pick(&d, &font, 2, 18, 0.2) == null);
}

test "pick: edge within tolerance beats interior; nearest edge wins" {
    var d = try ir.parse(testing.allocator, pick_json);
    defer d.deinit();
    var font = try Font.initEmbedded(testing.allocator);
    defer font.deinit();
    // 0.05 outside big's right edge
    try testing.expectEqualStrings("big", pick(&d, &font, 20.05, 5, 0.1).?);
    try testing.expect(pick(&d, &font, 20.5, 5, 0.1) == null);
    // near inner's left edge but inside big: edge distance 0.04 -> inner (line pass beats region pass)
    const h = pickHit(&d, &font, 8.04, 5, 0.1).?;
    try testing.expectEqualStrings("inner", h.src);
    try testing.expectEqual(HitKind.line, h.kind);
    try testing.expect(h.dist < 0.05);
    // leader line
    try testing.expectEqualStrings("n1", pick(&d, &font, 25, 15.03, 0.1).?);
}

test "pick: fills and arcs" {
    var d = try ir.parse(testing.allocator, pick_json);
    defer d.deinit();
    var font = try Font.initEmbedded(testing.allocator);
    defer font.deinit();
    // the dot is a circle centered (15.5,5) r 0.5 inside big
    const h = pickHit(&d, &font, 15.5, 5, 0.05).?;
    try testing.expectEqualStrings("dot", h.src);
    try testing.expectEqual(HitKind.fill, h.kind);
    try testing.expectEqualStrings("dot", pick(&d, &font, 16.03, 5, 0.1).?); // just outside, within tol
    // arc-bulge region: (25,0)->(35,0) bulge 1 (below chord), closing (35,1)->(25,0)
    try testing.expectEqualStrings("arcy", pick(&d, &font, 30, -3, 0.01).?); // inside the semicircle (center (30,0) r5)
    try testing.expect(pick(&d, &font, 30, -6, 0.01) == null);
}

test "pick: text wins over regions; rotated text; second line" {
    var d = try ir.parse(testing.allocator, pick_json);
    defer d.deinit();
    var font = try Font.initEmbedded(testing.allocator);
    defer font.deinit();
    const h = pickHit(&d, &font, 32, 15, 0.05).?;
    try testing.expectEqualStrings("n1", h.src);
    try testing.expectEqual(HitKind.text, h.kind);
    try testing.expectEqualStrings("n1", pick(&d, &font, 32, 12.5, 0.05).?); // second line
    try testing.expect(pick(&d, &font, 32, 17, 0.05) == null);
    // vertical text: rot 90 => runs upward from (38,2)
    try testing.expectEqualStrings("rot", pick(&d, &font, 37.7, 4, 0.05).?);
    try testing.expect(pick(&d, &font, 40.5, 2.2, 0.05) == null);
}

test "bboxOfSrc and textOrigin" {
    var d = try ir.parse(testing.allocator, pick_json);
    defer d.deinit();
    var font = try Font.initEmbedded(testing.allocator);
    defer font.deinit();
    const b = bboxOfSrc(&d, &font, "big").?;
    try testing.expectEqual(@as(f64, 0), b.x0);
    try testing.expectEqual(@as(f64, 20), b.x1);
    const a = bboxOfSrc(&d, &font, "arcy").?;
    try testing.expectApproxEqAbs(@as(f64, -5), a.y0, 1e-9);
    const n = bboxOfSrc(&d, &font, "n1").?;
    try testing.expect(n.x1 > 36 and n.y1 > 15.4 and n.y0 < 12);
    try testing.expect(bboxOfSrc(&d, &font, "zzz") == null);
    try testing.expect(bboxOfSrc(&d, &font, "") == null);
    const o = textOrigin(&d, "n1").?;
    try testing.expectEqual(@as(f64, 30.5), o.x);
    try testing.expectEqual(@as(f64, 14.5), o.y); // top line, not the second
    try testing.expect(textOrigin(&d, "big") == null);
    try testing.expectEqual(@as(f64, 90), textOrigin(&d, "rot").?.rot);
}

test "pick on empty drawing" {
    var d = try ir.parse(testing.allocator, "{\"kerf_drawing\":\"0.1\"}");
    defer d.deinit();
    var font = try Font.initEmbedded(testing.allocator);
    defer font.deinit();
    try testing.expect(pick(&d, &font, 0, 0, 1) == null);
}
