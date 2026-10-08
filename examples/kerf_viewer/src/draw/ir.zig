//! Drawing IR (`kerf_drawing`, SPEC section 10): typed model + tolerant JSON parser.
//!
//! ```zig
//! var d = try ir.parse(allocator, json_bytes);
//! defer d.deinit();
//! for (d.items) |it| switch (it.body) { .path => ..., .fill => ..., .hatch => ..., .text => ... };
//! ```
//!
//! * Everything (strings, points, items) lives in an arena owned by the
//!   `Drawing`; `deinit()` frees all of it. Nothing aliases the input bytes.
//! * Parsing is tolerant: unknown fields are ignored, optional fields get
//!   defaults, items with an unknown `t` or without usable geometry are
//!   skipped and counted in `skipped_items` (never an error).
//! * Hard errors: invalid JSON, root is not an object, or the object has
//!   neither `kerf_drawing` nor `items` (`error.NotADrawing`).
//! * Every item gets a precomputed model-space `bbox` (arcs included; text is a
//!   conservative estimate, see `textBBox`) so renderers can cull cheaply.
//! * Pens are resolved once at parse time: `Item.pen_index` indexes
//!   `Drawing.pens` (or is `no_pen` when the name is unknown/absent, in which
//!   case `Drawing.penOf` returns `default_pen`).
//! * Units: model inches. `Pen.width_mm` / `dash_mm` are PAPER millimetres;
//!   multiply paper inches by `Drawing.scale` to get model inches.

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom.zig");
const jv = @import("jv.zig");

pub const Pt = geom.BPt;
pub const BBox = geom.BBox;

pub const no_pen: u16 = std.math.maxInt(u16);

pub const Pen = struct {
    name: []const u8 = "",
    width_mm: f64 = 0.18,
    /// Dash/gap pairs in paper mm (`[dash, gap, dash, gap...]`); empty = continuous.
    dash_mm: []const f64 = &.{},
};

/// Used when an item names a pen the drawing does not define.
pub const default_pen: Pen = .{ .name = "", .width_mm = 0.18, .dash_mm = &.{} };

pub const Layer = struct {
    name: []const u8,
    lineweight_mm: f64 = 0.18,
};

pub const HAlign = enum { left, center, right };
/// `baseline` = y is the baseline; `bottom` = y is the bottom of descenders
/// (baseline - 1/3 cap height); `middle` = y is the middle of the capitals;
/// `top` = y is the top of the capitals.
pub const VAlign = enum { baseline, bottom, middle, top };

pub const Path = struct {
    closed: bool,
    pts: []const Pt,
};

/// Solid fill. Loops are even-odd (loop 0 outer, others holes).
pub const Fill = struct {
    loops: []const []const Pt,
};

pub const Hatch = struct {
    pattern: []const u8 = "",
    scale: f64 = 1,
    angle: f64 = 0,
    /// Loop 0 outer, the rest holes.
    loops: []const []const Pt,
    /// Pre-clipped pattern segments `[x0, y0, x1, y1]` (model inches). A
    /// zero-length segment is a dot.
    lines: []const [4]f64,
};

pub const Text = struct {
    s: []const u8,
    x: f64,
    y: f64,
    /// Cap height in model inches.
    h: f64,
    /// Degrees, counter-clockwise.
    rot: f64 = 0,
    halign: HAlign = .left,
    valign: VAlign = .baseline,
};

pub const Kind = enum { path, fill, hatch, text };

pub const Body = union(Kind) {
    path: Path,
    fill: Fill,
    hatch: Hatch,
    text: Text,
};

pub const Item = struct {
    layer: []const u8 = "",
    pen: []const u8 = "",
    /// Index into `Drawing.pens`, or `no_pen`.
    pen_index: u16 = no_pen,
    /// Component / annotation id this item belongs to ("" if none).
    src: []const u8 = "",
    bbox: BBox = BBox.empty,
    body: Body,

    pub fn kind(self: Item) Kind {
        return std.meta.activeTag(self.body);
    }
};

pub const Diagnostic = struct {
    /// "error" | "warning" | "info" (kept as the engine wrote it).
    level: []const u8 = "info",
    code: []const u8 = "",
    message: []const u8 = "",
    id: ?[]const u8 = null,
    path: ?[]const u8 = null,
    fix: ?[]const u8 = null,
};

pub const Drawing = struct {
    arena: std.heap.ArenaAllocator,
    version: []const u8 = "",
    doc: []const u8 = "",
    view: []const u8 = "",
    /// "section" | "iso" | "" (unknown)
    kind: []const u8 = "",
    /// Detail scale factor: model size / paper size (12 for 1"=1'-0"). Always > 0.
    scale: f64 = 1,
    /// Model-space bounds `[x0, y0, x1, y1]`. Computed from the items when absent.
    bounds: [4]f64 = .{ 0, 0, 0, 0 },
    pens: []const Pen = &.{},
    layers: []const Layer = &.{},
    items: []const Item = &.{},
    diagnostics: []const Diagnostic = &.{},
    /// Items that were dropped while parsing (unknown `t`, no geometry).
    skipped_items: usize = 0,

    pub fn deinit(self: *Drawing) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn penOf(self: *const Drawing, it: Item) Pen {
        if (it.pen_index != no_pen and it.pen_index < self.pens.len) return self.pens[it.pen_index];
        return default_pen;
    }

    pub fn findPen(self: *const Drawing, name: []const u8) ?u16 {
        for (self.pens, 0..) |p, i| if (std.mem.eql(u8, p.name, name)) return @intCast(i);
        return null;
    }

    pub fn boundsBox(self: *const Drawing) BBox {
        return .{ .x0 = self.bounds[0], .y0 = self.bounds[1], .x1 = self.bounds[2], .y1 = self.bounds[3] };
    }

    pub fn errorCount(self: *const Drawing) usize {
        var n: usize = 0;
        for (self.diagnostics) |d| if (std.mem.eql(u8, d.level, "error")) {
            n += 1;
        };
        return n;
    }

    /// Number of items whose `src` equals `src` (0 for "").
    pub fn countSrc(self: *const Drawing, src: []const u8) usize {
        if (src.len == 0) return 0;
        var n: usize = 0;
        for (self.items) |it| if (std.mem.eql(u8, it.src, src)) {
            n += 1;
        };
        return n;
    }

    /// Number of text items on layers/pens used for notes (any item whose src starts with "n"
    /// is not assumed; this simply counts text items). Handy for the render summary.
    pub fn textCount(self: *const Drawing) usize {
        var n: usize = 0;
        for (self.items) |it| if (it.kind() == .text) {
            n += 1;
        };
        return n;
    }
};

/// Component id of a `src` ("truss#1" -> "truss"; instance suffix `#k`, SPEC 16).
pub fn srcBase(src: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, src, '#')) |i| return src[0..i];
    return src;
}

/// Does an item's `src` belong to the wanted id? `wanted` = "truss" matches "truss" and "truss#0";
/// `wanted` = "truss#1" matches only instance 1. Empty strings never match.
pub fn srcMatches(item_src: []const u8, wanted: []const u8) bool {
    if (item_src.len == 0 or wanted.len == 0) return false;
    if (std.mem.eql(u8, item_src, wanted)) return true;
    if (std.mem.indexOfScalar(u8, wanted, '#') == null) return std.mem.eql(u8, srcBase(item_src), wanted);
    return false;
}

pub const ParseError = error{ InvalidJson, NotADrawing, OutOfMemory };

/// Conservative (never too small) model-space bbox of a text item, rotation
/// included. The exact bbox needs the font; see `pick.textBBox`.
pub fn textBBox(t: Text) BBox {
    var maxline: usize = 0;
    var cur: usize = 0;
    var lines: usize = 1;
    for (t.s) |c| {
        if (c == '\n') {
            lines += 1;
            cur = 0;
        } else {
            cur += 1;
            if (cur > maxline) maxline = cur;
        }
    }
    const h = @abs(t.h);
    const r = (@as(f64, @floatFromInt(maxline)) * 1.3 + 1.0) * h + @as(f64, @floatFromInt(lines)) * 1.7 * h;
    return .{ .x0 = t.x - r, .y0 = t.y - r, .x1 = t.x + r, .y1 = t.y + r };
}

fn parsePts(arena: Allocator, v: jv.Value) !?[]const Pt {
    const arr = jv.asArray(v) orelse return null;
    var list: std.ArrayList(Pt) = .empty;
    try list.ensureTotalCapacity(arena, arr.len);
    for (arr) |pv| {
        const pa = jv.asArray(pv) orelse continue;
        if (pa.len < 2) continue;
        const x = jv.num(pa[0]) orelse continue;
        const y = jv.num(pa[1]) orelse continue;
        const b = if (pa.len > 2) (jv.num(pa[2]) orelse 0) else 0;
        list.appendAssumeCapacity(.{ .x = x, .y = y, .b = b });
    }
    return list.items;
}

fn parseLoops(arena: Allocator, v: ?jv.Value) ![]const []const Pt {
    const lv = v orelse return &.{};
    const arr = jv.asArray(lv) orelse return &.{};
    var list: std.ArrayList([]const Pt) = .empty;
    for (arr) |l| {
        const pts = (try parsePts(arena, l)) orelse continue;
        if (pts.len < 2) continue;
        try list.append(arena, pts);
    }
    return list.items;
}

fn parseHAlign(s: ?[]const u8) HAlign {
    const t = s orelse return .left;
    if (std.ascii.eqlIgnoreCase(t, "center") or std.ascii.eqlIgnoreCase(t, "centre") or std.ascii.eqlIgnoreCase(t, "middle")) return .center;
    if (std.ascii.eqlIgnoreCase(t, "right")) return .right;
    return .left;
}

fn parseVAlign(s: ?[]const u8) VAlign {
    const t = s orelse return .baseline;
    if (std.ascii.eqlIgnoreCase(t, "middle") or std.ascii.eqlIgnoreCase(t, "center")) return .middle;
    if (std.ascii.eqlIgnoreCase(t, "top")) return .top;
    if (std.ascii.eqlIgnoreCase(t, "bottom")) return .bottom;
    return .baseline;
}

/// Parse a `kerf_drawing` JSON document. See the module comment for the
/// tolerance rules. The returned drawing owns its memory.
pub fn parse(allocator: Allocator, json_bytes: []const u8) ParseError!Drawing {
    var tmp = std.heap.ArenaAllocator.init(allocator);
    defer tmp.deinit();
    const root = std.json.parseFromSliceLeaky(jv.Value, tmp.allocator(), json_bytes, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    const obj = jv.asObject(root) orelse return error.NotADrawing;
    if (obj.get("kerf_drawing") == null and obj.get("items") == null) return error.NotADrawing;

    var d: Drawing = .{ .arena = std.heap.ArenaAllocator.init(allocator) };
    errdefer d.arena.deinit();
    const a = d.arena.allocator();

    d.version = try a.dupe(u8, jv.getStr(obj, "kerf_drawing") orelse "");
    d.doc = try a.dupe(u8, jv.getStr(obj, "doc") orelse "");
    d.view = try a.dupe(u8, jv.getStr(obj, "view") orelse "");
    d.kind = try a.dupe(u8, jv.getStr(obj, "kind") orelse "");
    const sc = jv.getNum(obj, "scale") orelse 1;
    d.scale = if (sc > 0 and std.math.isFinite(sc)) sc else 1;

    // pens (object; iteration order of std.json objects is insertion order = file order)
    if (jv.getObj(obj, "pens")) |po| {
        var pens: std.ArrayList(Pen) = .empty;
        var it = po.iterator();
        while (it.next()) |e| {
            const pobj = jv.asObject(e.value_ptr.*) orelse continue;
            var dashes: std.ArrayList(f64) = .empty;
            if (jv.getArr(pobj, "dash_mm")) |da| {
                for (da) |dv| if (jv.num(dv)) |x| try dashes.append(a, x);
            }
            // a dash list must have at least a dash and a gap, else treat as solid
            const dl: []const f64 = if (dashes.items.len >= 2) dashes.items else &.{};
            try pens.append(a, .{
                .name = try a.dupe(u8, e.key_ptr.*),
                .width_mm = jv.getNum(pobj, "width_mm") orelse 0.18,
                .dash_mm = dl,
            });
        }
        d.pens = pens.items;
    }

    if (jv.getArr(obj, "layers")) |la| {
        var layers: std.ArrayList(Layer) = .empty;
        for (la) |lv| {
            if (jv.asObject(lv)) |lo| {
                try layers.append(a, .{
                    .name = try a.dupe(u8, jv.getStr(lo, "name") orelse ""),
                    .lineweight_mm = jv.getNum(lo, "lineweight_mm") orelse 0.18,
                });
            } else if (jv.str(lv)) |s| {
                try layers.append(a, .{ .name = try a.dupe(u8, s) });
            }
        }
        d.layers = layers.items;
    }

    var items: std.ArrayList(Item) = .empty;
    var skipped: usize = 0;
    if (jv.getArr(obj, "items")) |ia| {
        try items.ensureTotalCapacity(a, ia.len);
        for (ia) |iv| {
            const io = jv.asObject(iv) orelse {
                skipped += 1;
                continue;
            };
            const t = jv.getStr(io, "t") orelse {
                skipped += 1;
                continue;
            };
            var item: Item = .{ .body = undefined };
            item.layer = try a.dupe(u8, jv.getStr(io, "layer") orelse "");
            item.pen = try a.dupe(u8, jv.getStr(io, "pen") orelse "");
            item.src = try a.dupe(u8, jv.getStr(io, "src") orelse "");
            if (item.pen.len > 0) item.pen_index = d.findPen(item.pen) orelse no_pen;

            if (std.mem.eql(u8, t, "path")) {
                const pts = (if (io.get("pts")) |pv| try parsePts(a, pv) else null) orelse {
                    skipped += 1;
                    continue;
                };
                if (pts.len < 2) {
                    skipped += 1;
                    continue;
                }
                const closed = jv.getBool(io, "closed") orelse false;
                item.body = .{ .path = .{ .closed = closed, .pts = pts } };
                item.bbox = geom.bboxOfPath(pts, closed);
            } else if (std.mem.eql(u8, t, "fill")) {
                const loops = try parseLoops(a, io.get("loops"));
                if (loops.len == 0) {
                    skipped += 1;
                    continue;
                }
                item.body = .{ .fill = .{ .loops = loops } };
                for (loops) |l| item.bbox.merge(geom.bboxOfPath(l, true));
            } else if (std.mem.eql(u8, t, "hatch")) {
                const loops = try parseLoops(a, io.get("loops"));
                var lines: std.ArrayList([4]f64) = .empty;
                if (jv.getArr(io, "lines")) |la| {
                    try lines.ensureTotalCapacity(a, la.len);
                    for (la) |lv| {
                        const q = jv.asArray(lv) orelse continue;
                        if (q.len < 4) continue;
                        const x0 = jv.num(q[0]) orelse continue;
                        const y0 = jv.num(q[1]) orelse continue;
                        const x1 = jv.num(q[2]) orelse continue;
                        const y1 = jv.num(q[3]) orelse continue;
                        lines.appendAssumeCapacity(.{ x0, y0, x1, y1 });
                    }
                }
                if (loops.len == 0 and lines.items.len == 0) {
                    skipped += 1;
                    continue;
                }
                item.body = .{ .hatch = .{
                    .pattern = try a.dupe(u8, jv.getStr(io, "pattern") orelse ""),
                    .scale = jv.getNum(io, "scale") orelse 1,
                    .angle = jv.getNum(io, "angle") orelse 0,
                    .loops = loops,
                    .lines = lines.items,
                } };
                for (loops) |l| item.bbox.merge(geom.bboxOfPath(l, true));
                for (lines.items) |ln| {
                    item.bbox.addPoint(ln[0], ln[1]);
                    item.bbox.addPoint(ln[2], ln[3]);
                }
            } else if (std.mem.eql(u8, t, "text")) {
                const s = jv.getStr(io, "s") orelse {
                    skipped += 1;
                    continue;
                };
                const h = jv.getNum(io, "h") orelse 0.75;
                const tx: Text = .{
                    .s = try a.dupe(u8, s),
                    .x = jv.getNum(io, "x") orelse 0,
                    .y = jv.getNum(io, "y") orelse 0,
                    .h = if (h > 0) h else 0.75,
                    .rot = jv.getNum(io, "rot") orelse 0,
                    .halign = parseHAlign(jv.getStr(io, "align")),
                    .valign = parseVAlign(jv.getStr(io, "valign")),
                };
                item.body = .{ .text = tx };
                item.bbox = textBBox(tx);
            } else {
                skipped += 1;
                continue;
            }
            items.appendAssumeCapacity(item);
        }
    }
    d.items = items.items;
    d.skipped_items = skipped;

    if (jv.getArr(obj, "diagnostics")) |da| {
        var diags: std.ArrayList(Diagnostic) = .empty;
        for (da) |dv| {
            const dobj = jv.asObject(dv) orelse continue;
            try diags.append(a, .{
                .level = try a.dupe(u8, jv.getStr(dobj, "level") orelse jv.getStr(dobj, "severity") orelse "info"),
                .code = try a.dupe(u8, jv.getStr(dobj, "code") orelse ""),
                .message = try a.dupe(u8, jv.getStr(dobj, "message") orelse ""),
                .id = if (jv.getStr(dobj, "id")) |s| try a.dupe(u8, s) else null,
                .path = if (jv.getStr(dobj, "path")) |s| try a.dupe(u8, s) else null,
                .fix = if (jv.getStr(dobj, "fix")) |s| try a.dupe(u8, s) else null,
            });
        }
        d.diagnostics = diags.items;
    }

    // bounds
    var have_bounds = false;
    if (jv.getArr(obj, "bounds")) |ba| {
        if (ba.len >= 4) {
            var b: [4]f64 = undefined;
            var ok = true;
            for (0..4) |i| {
                if (jv.num(ba[i])) |x| b[i] = x else ok = false;
            }
            if (ok and b[2] >= b[0] and b[3] >= b[1]) {
                d.bounds = b;
                have_bounds = true;
            }
        }
    }
    if (!have_bounds) {
        var bb = BBox.empty;
        for (d.items) |it| {
            // text boxes are over-estimates; for bounds use the anchor point only
            if (it.body == .text) bb.addPoint(it.body.text.x, it.body.text.y) else bb.merge(it.bbox);
        }
        if (bb.isEmpty()) bb = .{ .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 1 };
        d.bounds = .{ bb.x0, bb.y0, bb.x1, bb.y1 };
    }
    return d;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

pub const tiny_json =
    \\{ "kerf_drawing": "0.1", "doc": "t", "view": "A", "kind": "section", "scale": 12,
    \\  "bounds": [0, 0, 10, 8],
    \\  "pens": { "cut": {"width_mm": 0.5, "dash_mm": null}, "hidden": {"width_mm": 0.18, "dash_mm": [2, 1]},
    \\            "anno": {"width_mm": 0.18}, "hatch": {"width_mm": 0.09} },
    \\  "layers": [ {"name": "S-DETL-CUT", "lineweight_mm": 0.5} ],
    \\  "items": [
    \\    { "t": "path", "layer": "S-DETL-CUT", "pen": "cut", "src": "sill", "closed": true,
    \\      "pts": [[1,1,0],[5,1,0.5],[5,3],[1,3,0]] },
    \\    { "t": "path", "pen": "hidden", "src": "sill", "pts": [[0,0],[1,1]], "future_field": 7 },
    \\    { "t": "fill", "src": "r1", "loops": [[[6,6,1],[7,6,1]]] },
    \\    { "t": "hatch", "pen": "hatch", "src": "sill", "pattern": "ANSI31", "scale": 0.75, "angle": 0,
    \\      "loops": [[[1,1],[5,1],[5,3],[1,3]]], "lines": [[1,1,2,2],[2,1,3,2],[3,3,3,3]] },
    \\    { "t": "text", "layer": "S-ANNO-NOTE", "pen": "anno", "src": "n1", "s": "2X8 PT SILL",
    \\      "x": 6, "y": 2, "h": 0.75, "rot": 0, "align": "center", "valign": "middle" },
    \\    { "t": "mystery", "x": 1 },
    \\    { "t": "path", "pts": [[0,0]] }
    \\  ],
    \\  "diagnostics": [ {"level": "warning", "code": "W_FLOATING", "id": "x", "message": "m"} ]
    \\}
;

test "parse tiny drawing" {
    var d = try parse(testing.allocator, tiny_json);
    defer d.deinit();
    try testing.expectEqualStrings("0.1", d.version);
    try testing.expectEqualStrings("t", d.doc);
    try testing.expectEqual(@as(f64, 12), d.scale);
    try testing.expectEqual(@as(usize, 4), d.pens.len);
    try testing.expectEqual(@as(usize, 5), d.items.len);
    try testing.expectEqual(@as(usize, 2), d.skipped_items);
    try testing.expectEqual(@as(usize, 1), d.diagnostics.len);
    try testing.expectEqualStrings("W_FLOATING", d.diagnostics[0].code);
    try testing.expectEqual(@as(usize, 1), d.layers.len);

    const p0 = d.items[0];
    try testing.expectEqual(Kind.path, p0.kind());
    try testing.expect(p0.body.path.closed);
    try testing.expectEqual(@as(usize, 4), p0.body.path.pts.len);
    try testing.expectEqual(@as(f64, 0.5), p0.body.path.pts[1].b);
    try testing.expectEqual(@as(f64, 0), p0.body.path.pts[2].b);
    try testing.expectEqualStrings("sill", p0.src);
    try testing.expectEqual(@as(f64, 0.5), d.penOf(p0).width_mm);
    try testing.expectEqual(@as(usize, 0), d.penOf(p0).dash_mm.len);
    // arc bulge extends the bbox below/above the straight chord
    try testing.expect(p0.bbox.x1 > 5.0);

    try testing.expectEqual(@as(usize, 2), d.penOf(d.items[1]).dash_mm.len);
    try testing.expect(!d.items[1].body.path.closed);

    try testing.expectEqual(Kind.fill, d.items[2].kind());
    try testing.expectEqual(@as(usize, 1), d.items[2].body.fill.loops.len);
    try testing.expectEqual(no_pen, d.items[2].pen_index);
    try testing.expectEqual(default_pen.width_mm, d.penOf(d.items[2]).width_mm);

    const h = d.items[3].body.hatch;
    try testing.expectEqualStrings("ANSI31", h.pattern);
    try testing.expectEqual(@as(usize, 3), h.lines.len);
    try testing.expectEqual(@as(f64, 0.75), h.scale);

    const t = d.items[4].body.text;
    try testing.expectEqualStrings("2X8 PT SILL", t.s);
    try testing.expectEqual(HAlign.center, t.halign);
    try testing.expectEqual(VAlign.middle, t.valign);
    try testing.expectEqual(@as(f64, 0.75), t.h);
    try testing.expectEqual(@as(f64, 10), d.bounds[2]);
    try testing.expectEqual(@as(usize, 3), d.countSrc("sill")); // path, hidden path, hatch
}

test "parse: bounds computed when absent, scale defaults" {
    const j =
        \\{ "kerf_drawing": "0.1", "items": [
        \\ { "t": "path", "pen": "x", "pts": [[2,3],[8,9]] } ] }
    ;
    var d = try parse(testing.allocator, j);
    defer d.deinit();
    try testing.expectEqual(@as(f64, 1), d.scale);
    try testing.expectEqual(@as(f64, 2), d.bounds[0]);
    try testing.expectEqual(@as(f64, 9), d.bounds[3]);
}

test "parse: empty drawing and tolerant garbage" {
    var d = try parse(testing.allocator, "{\"kerf_drawing\":\"0.1\"}");
    defer d.deinit();
    try testing.expectEqual(@as(usize, 0), d.items.len);
    try testing.expectEqual(@as(f64, 1), d.bounds[2]);

    var d2 = try parse(testing.allocator,
        \\{"kerf_drawing":"0.1","scale":-3,"items":[1,"x",{"t":5},{"t":"text"},{"t":"fill","loops":"no"}],"pens":{"a":7,"b":{"dash_mm":[1]}}}
    );
    defer d2.deinit();
    try testing.expectEqual(@as(usize, 0), d2.items.len);
    try testing.expectEqual(@as(usize, 5), d2.skipped_items);
    try testing.expectEqual(@as(f64, 1), d2.scale);
    try testing.expectEqual(@as(usize, 1), d2.pens.len);
    try testing.expectEqual(@as(usize, 0), d2.pens[0].dash_mm.len);
}

test "parse: errors" {
    try testing.expectError(error.InvalidJson, parse(testing.allocator, "{not json"));
    try testing.expectError(error.NotADrawing, parse(testing.allocator, "[1,2]"));
    try testing.expectError(error.NotADrawing, parse(testing.allocator, "{\"foo\":1}"));
}

test "parse: no leaks across many items" {
    // testing.allocator reports leaks; build a big-ish doc programmatically
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try buf.appendSlice(testing.allocator, "{\"kerf_drawing\":\"0.1\",\"items\":[");
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        if (i > 0) try buf.append(testing.allocator, ',');
        try buf.print(testing.allocator, "{{\"t\":\"path\",\"src\":\"s{d}\",\"pts\":[[0,{d}],[1,{d}]]}}", .{ i, i, i });
    }
    try buf.appendSlice(testing.allocator, "]}");
    var d = try parse(testing.allocator, buf.items);
    defer d.deinit();
    try testing.expectEqual(@as(usize, 200), d.items.len);
}

test "textBBox grows with length" {
    const a = textBBox(.{ .s = "AB", .x = 0, .y = 0, .h = 1 });
    const b = textBBox(.{ .s = "ABCDEFGH", .x = 0, .y = 0, .h = 1 });
    try testing.expect(b.x1 > a.x1);
}

test "srcBase / srcMatches handle instance suffixes" {
    try testing.expectEqualStrings("truss", srcBase("truss#1"));
    try testing.expectEqualStrings("cmu", srcBase("cmu"));
    try testing.expect(srcMatches("truss#0", "truss"));
    try testing.expect(srcMatches("truss", "truss"));
    try testing.expect(srcMatches("truss#1", "truss#1"));
    try testing.expect(!srcMatches("truss#0", "truss#1"));
    try testing.expect(!srcMatches("truss2", "truss"));
    try testing.expect(!srcMatches("", ""));
    try testing.expect(!srcMatches("a", ""));
}
