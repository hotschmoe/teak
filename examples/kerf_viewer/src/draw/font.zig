//! Kerf stroke font (SPEC section 15): Hershey Roman Simplex from
//! `spec/fonts/kerf-simplex.json` (`{"cap_height":21,"glyphs":{"A":{"adv":18,"strokes":[[[x,y],..],..]}}}`).
//!
//! ```zig
//! var font = try Font.initEmbedded(allocator);      // or Font.init(allocator, json_bytes)
//! defer font.deinit();
//! var out: Polylines = .{};
//! defer out.deinit(allocator);
//! try font.textStrokes(allocator, &out, "2X8 PT SILL", 0.75, x, y, 0, .left, .baseline);
//! for (0..out.count()) |i| draw(out.line(i));       // polylines in MODEL space
//! const w = font.textWidth("2X8 PT SILL", 0.75);    // model inches
//! ```
//!
//! * Glyph units are Hershey units (y up, baseline 0, cap height 21). Text of
//!   height `h` (a CAP height) scales by `h / cap_height`; advances scale the same.
//! * Unknown / non-ASCII glyphs render as `?` (a few typographic characters are
//!   mapped to ASCII look-alikes: en/em dash -> `-`, curly quotes, `x` multiply, NBSP).
//! * Text may contain `\n`; following lines step down by `line_spacing * h`
//!   (1.6, the style default). Alignment applies per line.
//! * Fully deterministic: no hash maps are iterated, output order = text order.
//! * `Font` owns an arena; `deinit()` frees it. The embedded variant needs the
//!   `spec_font_json` anonymous import declared in `apps/teak/build.zig`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom.zig");
const ir = @import("ir.zig");
const jv = @import("jv.zig");

pub const Vec2 = geom.Vec2;
pub const HAlign = ir.HAlign;
pub const VAlign = ir.VAlign;

/// Vertical distance between text lines, in text heights (style `text.line_spacing`).
pub const line_spacing: f64 = 1.6;

pub const GPt = struct { x: f32, y: f32 };

pub const Glyph = struct {
    /// Advance in glyph units.
    adv: f32,
    /// Stroke range into `Font.strokes`.
    s0: u32,
    s1: u32,
};

pub const Stroke = struct {
    /// Point range into `Font.pts`.
    p0: u32,
    p1: u32,
};

/// A set of polylines stored contiguously. `ends[i]` is the exclusive end of polyline i in `pts`.
pub const Polylines = struct {
    pts: std.ArrayList(Vec2) = .empty,
    ends: std.ArrayList(u32) = .empty,

    pub fn deinit(self: *Polylines, a: Allocator) void {
        self.pts.deinit(a);
        self.ends.deinit(a);
    }
    pub fn clear(self: *Polylines) void {
        self.pts.clearRetainingCapacity();
        self.ends.clearRetainingCapacity();
    }
    pub fn count(self: *const Polylines) usize {
        return self.ends.items.len;
    }
    pub fn line(self: *const Polylines, i: usize) []const Vec2 {
        const s: usize = if (i == 0) 0 else self.ends.items[i - 1];
        return self.pts.items[s..self.ends.items[i]];
    }
};

pub const Font = struct {
    arena: std.heap.ArenaAllocator,
    cap_height: f64,
    /// ASCII code -> glyph index, or -1.
    index: [128]i16,
    glyphs: []const Glyph,
    strokes: []const Stroke,
    pts: []const GPt,
    /// Index of the '?' glyph (always valid after `init`).
    unknown: u16,

    pub const InitError = error{ InvalidFont, OutOfMemory };

    pub fn deinit(self: *Font) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn initEmbedded(allocator: Allocator) InitError!Font {
        return init(allocator, @embedFile("kerf-simplex.json"));
    }

    pub fn init(allocator: Allocator, json_bytes: []const u8) InitError!Font {
        var tmp = std.heap.ArenaAllocator.init(allocator);
        defer tmp.deinit();
        const root = std.json.parseFromSliceLeaky(jv.Value, tmp.allocator(), json_bytes, .{}) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidFont,
        };
        const obj = jv.asObject(root) orelse return error.InvalidFont;
        const gobj = jv.getObj(obj, "glyphs") orelse return error.InvalidFont;
        const cap = jv.getNum(obj, "cap_height") orelse 21;
        if (!(cap > 0)) return error.InvalidFont;

        var f: Font = .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .cap_height = cap,
            .index = @splat(-1),
            .glyphs = &.{},
            .strokes = &.{},
            .pts = &.{},
            .unknown = 0,
        };
        errdefer f.arena.deinit();
        const a = f.arena.allocator();

        var glyphs: std.ArrayList(Glyph) = .empty;
        var strokes: std.ArrayList(Stroke) = .empty;
        var pts: std.ArrayList(GPt) = .empty;
        var it = gobj.iterator();
        while (it.next()) |e| {
            const key = e.key_ptr.*;
            if (key.len != 1 or key[0] >= 128) continue; // ASCII only
            const go = jv.asObject(e.value_ptr.*) orelse continue;
            const s0: u32 = @intCast(strokes.items.len);
            if (jv.getArr(go, "strokes")) |sa| {
                for (sa) |sv| {
                    const pa = jv.asArray(sv) orelse continue;
                    const p0: u32 = @intCast(pts.items.len);
                    for (pa) |pv| {
                        const xy = jv.asArray(pv) orelse continue;
                        if (xy.len < 2) continue;
                        const x = jv.num(xy[0]) orelse continue;
                        const y = jv.num(xy[1]) orelse continue;
                        try pts.append(a, .{ .x = @floatCast(x), .y = @floatCast(y) });
                    }
                    const p1: u32 = @intCast(pts.items.len);
                    if (p1 - p0 >= 1) try strokes.append(a, .{ .p0 = p0, .p1 = p1 });
                }
            }
            const s1: u32 = @intCast(strokes.items.len);
            f.index[key[0]] = @intCast(glyphs.items.len);
            try glyphs.append(a, .{ .adv = @floatCast(jv.getNum(go, "adv") orelse 16), .s0 = s0, .s1 = s1 });
        }
        if (f.index['?'] < 0) return error.InvalidFont;
        f.unknown = @intCast(f.index['?']);
        f.glyphs = glyphs.items;
        f.strokes = strokes.items;
        f.pts = pts.items;
        return f;
    }

    /// Glyph for a codepoint, falling back to `?`.
    pub fn glyphFor(self: *const Font, cp: u21) *const Glyph {
        const c = substitute(cp);
        if (c < 128) {
            const i = self.index[c];
            if (i >= 0) return &self.glyphs[@intCast(i)];
        }
        return &self.glyphs[self.unknown];
    }

    /// Is there a real (non-fallback) glyph for this codepoint?
    pub fn has(self: *const Font, cp: u21) bool {
        const c = substitute(cp);
        return c < 128 and self.index[c] >= 0;
    }

    /// Advance of one codepoint in model units for text height `h`.
    pub fn advance(self: *const Font, cp: u21, h: f64) f64 {
        return @as(f64, self.glyphFor(cp).adv) * h / self.cap_height;
    }

    /// Width (sum of advances) of the longest line of `text`, model units.
    pub fn textWidth(self: *const Font, text: []const u8, h: f64) f64 {
        var best: f64 = 0;
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |ln| {
            const w = self.lineWidth(ln, h);
            if (w > best) best = w;
        }
        return best;
    }

    pub fn lineWidth(self: *const Font, line: []const u8, h: f64) f64 {
        var w: f64 = 0;
        var i: usize = 0;
        while (i < line.len) {
            const d = decode(line[i..]);
            i += d.len;
            w += self.advance(d.cp, h);
        }
        return w;
    }

    /// Number of lines in `text` (>= 1).
    pub fn lineCount(text: []const u8) usize {
        return std.mem.count(u8, text, "\n") + 1;
    }

    /// Total block height of the text including descenders of the last line is not
    /// needed by callers; this is the distance baseline-first to baseline-last plus cap height.
    pub fn blockHeight(text: []const u8, h: f64) f64 {
        return h + @as(f64, @floatFromInt(lineCount(text) - 1)) * line_spacing * h;
    }

    /// Append the polylines of `text` (model space) to `out`.
    ///
    /// `(x, y)` is the anchor selected by `halign`/`valign` (for multi-line text:
    /// the first line's), `rot_deg` rotates counter-clockwise about the anchor.
    pub fn textStrokes(
        self: *const Font,
        a: Allocator,
        out: *Polylines,
        text: []const u8,
        h: f64,
        x: f64,
        y: f64,
        rot_deg: f64,
        halign: HAlign,
        valign: VAlign,
    ) Allocator.Error!void {
        const sc = h / self.cap_height;
        const rad = std.math.degreesToRadians(rot_deg);
        const cr = if (rot_deg == 0) 1.0 else @cos(rad);
        const sr = if (rot_deg == 0) 0.0 else @sin(rad);
        const vshift: f64 = switch (valign) {
            .baseline => 0,
            .bottom => 7.0 * sc,
            .middle => -h * 0.5,
            .top => -h,
        };
        var it = std.mem.splitScalar(u8, text, '\n');
        var li: usize = 0;
        while (it.next()) |ln| : (li += 1) {
            const w = self.lineWidth(ln, h);
            const x0: f64 = switch (halign) {
                .left => 0,
                .center => -w * 0.5,
                .right => -w,
            };
            const base_y = vshift - @as(f64, @floatFromInt(li)) * line_spacing * h;
            var pen_x = x0;
            var i: usize = 0;
            while (i < ln.len) {
                const d = decode(ln[i..]);
                i += d.len;
                const g = self.glyphFor(d.cp);
                var si = g.s0;
                while (si < g.s1) : (si += 1) {
                    const s = self.strokes[si];
                    var pi = s.p0;
                    if (s.p1 - s.p0 == 1) {
                        // single point stroke (dot): emit a degenerate 2-point polyline
                        const p = self.pts[pi];
                        const lx = pen_x + @as(f64, p.x) * sc;
                        const ly = base_y + @as(f64, p.y) * sc;
                        const q = Vec2{ .x = x + lx * cr - ly * sr, .y = y + lx * sr + ly * cr };
                        try out.pts.append(a, q);
                        try out.pts.append(a, q);
                        try out.ends.append(a, @intCast(out.pts.items.len));
                        continue;
                    }
                    while (pi < s.p1) : (pi += 1) {
                        const p = self.pts[pi];
                        const lx = pen_x + @as(f64, p.x) * sc;
                        const ly = base_y + @as(f64, p.y) * sc;
                        try out.pts.append(a, .{ .x = x + lx * cr - ly * sr, .y = y + lx * sr + ly * cr });
                    }
                    try out.ends.append(a, @intCast(out.pts.items.len));
                }
                pen_x += @as(f64, g.adv) * sc;
            }
        }
    }

    /// Model-space bbox of the text strokes WITHOUT allocating: the aligned
    /// advance box (width x [descender .. cap height]) rotated about the anchor.
    pub fn textBBox(self: *const Font, text: []const u8, h: f64, x: f64, y: f64, rot_deg: f64, halign: HAlign, valign: VAlign) geom.BBox {
        const sc = h / self.cap_height;
        const rad = std.math.degreesToRadians(rot_deg);
        const cr = @cos(rad);
        const sr = @sin(rad);
        const vshift: f64 = switch (valign) {
            .baseline => 0,
            .bottom => 7.0 * sc,
            .middle => -h * 0.5,
            .top => -h,
        };
        var bb = geom.BBox.empty;
        var it = std.mem.splitScalar(u8, text, '\n');
        var li: usize = 0;
        while (it.next()) |ln| : (li += 1) {
            if (ln.len == 0) continue;
            const w = self.lineWidth(ln, h);
            const x0: f64 = switch (halign) {
                .left => 0,
                .center => -w * 0.5,
                .right => -w,
            };
            const by = vshift - @as(f64, @floatFromInt(li)) * line_spacing * h;
            const corners = [4][2]f64{ .{ x0, by - 7.0 * sc }, .{ x0 + w, by - 7.0 * sc }, .{ x0 + w, by + h }, .{ x0, by + h } };
            for (corners) |c| bb.addPoint(x + c[0] * cr - c[1] * sr, y + c[0] * sr + c[1] * cr);
        }
        return bb;
    }
};

const Decoded = struct { cp: u21, len: usize };

/// Decode one UTF-8 codepoint; invalid bytes decode as U+FFFD with length 1.
fn decode(s: []const u8) Decoded {
    const c = s[0];
    if (c < 0x80) return .{ .cp = c, .len = 1 };
    const n = std.unicode.utf8ByteSequenceLength(c) catch return .{ .cp = 0xFFFD, .len = 1 };
    if (n > s.len) return .{ .cp = 0xFFFD, .len = 1 };
    const cp = std.unicode.utf8Decode(s[0..n]) catch return .{ .cp = 0xFFFD, .len = 1 };
    return .{ .cp = cp, .len = n };
}

fn substitute(cp: u21) u21 {
    return switch (cp) {
        0x2013, 0x2014, 0x2212 => '-',
        0x2018, 0x2019 => '\'',
        0x201C, 0x201D, 0x2033 => '"',
        0x2032 => '\'',
        0x00D7 => 'x',
        0x00A0, '\t' => ' ',
        else => cp,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn testFont() !Font {
    return Font.initEmbedded(testing.allocator);
}

test "font loads: 95 glyphs, cap height 21, A has 3 strokes" {
    var f = try testFont();
    defer f.deinit();
    try testing.expectEqual(@as(f64, 21), f.cap_height);
    try testing.expectEqual(@as(usize, 95), f.glyphs.len);
    const g = f.glyphFor('A');
    try testing.expectEqual(@as(f32, 18), g.adv);
    try testing.expectEqual(@as(u32, 3), g.s1 - g.s0);
    // space has no strokes but an advance
    const sp = f.glyphFor(' ');
    try testing.expectEqual(@as(u32, 0), sp.s1 - sp.s0);
    try testing.expectEqual(@as(f32, 16), sp.adv);
}

test "unknown glyphs fall back to '?'" {
    var f = try testFont();
    defer f.deinit();
    try testing.expect(f.glyphFor(0x4E2D) == f.glyphFor('?'));
    try testing.expect(f.glyphFor(0x1F600) == f.glyphFor('?'));
    try testing.expect(f.glyphFor(0x2014) == f.glyphFor('-'));
    try testing.expect(!f.has(0x4E2D));
    try testing.expect(f.has('Q'));
    // invalid UTF-8 byte
    try testing.expectApproxEqAbs(f.textWidth("\xff", 21), f.textWidth("?", 21), 1e-9);
}

test "textWidth scales with height and sums advances" {
    var f = try testFont();
    defer f.deinit();
    // at h = cap_height one unit == one glyph unit
    try testing.expectApproxEqAbs(@as(f64, 18 + 21), f.textWidth("AB", 21), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, (18 + 21) * 0.5), f.textWidth("AB", 10.5), 1e-9);
    try testing.expectEqual(@as(f64, 0), f.textWidth("", 5));
    // multiline: widest line wins
    try testing.expectApproxEqAbs(f.textWidth("ABC", 3), f.textWidth("A\nABC\nAB", 3), 1e-12);
}

test "textStrokes: 'A' at h=21 reproduces the glyph exactly" {
    var f = try testFont();
    defer f.deinit();
    var out: Polylines = .{};
    defer out.deinit(testing.allocator);
    try f.textStrokes(testing.allocator, &out, "A", 21, 100, 50, 0, .left, .baseline);
    try testing.expectEqual(@as(usize, 3), out.count());
    const l0 = out.line(0);
    try testing.expectEqual(@as(usize, 2), l0.len);
    try testing.expectEqual(@as(f64, 109), l0[0].x);
    try testing.expectEqual(@as(f64, 71), l0[0].y);
    try testing.expectEqual(@as(f64, 101), l0[1].x);
    try testing.expectEqual(@as(f64, 50), l0[1].y);
}

test "textStrokes: y-up, cap height maps to h" {
    var f = try testFont();
    defer f.deinit();
    var out: Polylines = .{};
    defer out.deinit(testing.allocator);
    try f.textStrokes(testing.allocator, &out, "H", 2.0, 0, 0, 0, .left, .baseline);
    var maxy: f64 = -1e9;
    var miny: f64 = 1e9;
    for (out.pts.items) |p| {
        maxy = @max(maxy, p.y);
        miny = @min(miny, p.y);
    }
    try testing.expectApproxEqAbs(@as(f64, 2.0), maxy, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.0), miny, 1e-9);
}

test "alignment: center and right shift by half/full width; valign shifts y" {
    var f = try testFont();
    defer f.deinit();
    const h = 1.5;
    const w = f.textWidth("HELLO", h);
    var l: Polylines = .{};
    defer l.deinit(testing.allocator);
    var c: Polylines = .{};
    defer c.deinit(testing.allocator);
    var r: Polylines = .{};
    defer r.deinit(testing.allocator);
    try f.textStrokes(testing.allocator, &l, "HELLO", h, 10, 0, 0, .left, .baseline);
    try f.textStrokes(testing.allocator, &c, "HELLO", h, 10, 0, 0, .center, .baseline);
    try f.textStrokes(testing.allocator, &r, "HELLO", h, 10, 0, 0, .right, .baseline);
    try testing.expectApproxEqAbs(l.pts.items[0].x - w * 0.5, c.pts.items[0].x, 1e-9);
    try testing.expectApproxEqAbs(l.pts.items[0].x - w, r.pts.items[0].x, 1e-9);

    var m: Polylines = .{};
    defer m.deinit(testing.allocator);
    var t: Polylines = .{};
    defer t.deinit(testing.allocator);
    try f.textStrokes(testing.allocator, &m, "HELLO", h, 10, 0, 0, .left, .middle);
    try f.textStrokes(testing.allocator, &t, "HELLO", h, 10, 0, 0, .left, .top);
    try testing.expectApproxEqAbs(l.pts.items[0].y - h * 0.5, m.pts.items[0].y, 1e-9);
    try testing.expectApproxEqAbs(l.pts.items[0].y - h, t.pts.items[0].y, 1e-9);
}

test "rotation 90 degrees maps text direction to +y (CCW)" {
    var f = try testFont();
    defer f.deinit();
    var a: Polylines = .{};
    defer a.deinit(testing.allocator);
    var b: Polylines = .{};
    defer b.deinit(testing.allocator);
    try f.textStrokes(testing.allocator, &a, "II", 1, 0, 0, 0, .left, .baseline);
    try f.textStrokes(testing.allocator, &b, "II", 1, 0, 0, 90, .left, .baseline);
    try testing.expectEqual(a.pts.items.len, b.pts.items.len);
    for (a.pts.items, b.pts.items) |p, q| {
        try testing.expectApproxEqAbs(-p.y, q.x, 1e-9);
        try testing.expectApproxEqAbs(p.x, q.y, 1e-9);
    }
}

test "multi-line steps down by line_spacing * h" {
    var f = try testFont();
    defer f.deinit();
    var o1: Polylines = .{};
    defer o1.deinit(testing.allocator);
    var o2: Polylines = .{};
    defer o2.deinit(testing.allocator);
    try f.textStrokes(testing.allocator, &o1, "I", 2, 0, 0, 0, .left, .baseline);
    try f.textStrokes(testing.allocator, &o2, "I\nI", 2, 0, 0, 0, .left, .baseline);
    try testing.expectEqual(o1.count() * 2, o2.count());
    const n = o1.pts.items.len;
    try testing.expectApproxEqAbs(o1.pts.items[0].y - 1.6 * 2, o2.pts.items[n].y, 1e-9);
    try testing.expectEqual(@as(usize, 2), Font.lineCount("a\nb"));
    try testing.expectApproxEqAbs(@as(f64, 2 + 3.2), Font.blockHeight("a\nb", 2), 1e-12);
}

test "deterministic: same input same output" {
    var f = try testFont();
    defer f.deinit();
    var a: Polylines = .{};
    defer a.deinit(testing.allocator);
    var b: Polylines = .{};
    defer b.deinit(testing.allocator);
    const s = "2X8 PT SILL PLATE W/ 5/8\" DIA. ANCHOR BOLTS @ 48\" O.C.";
    try f.textStrokes(testing.allocator, &a, s, 0.75, 3, 4, 17, .center, .middle);
    try f.textStrokes(testing.allocator, &b, s, 0.75, 3, 4, 17, .center, .middle);
    try testing.expectEqualSlices(Vec2, a.pts.items, b.pts.items);
    try testing.expectEqualSlices(u32, a.ends.items, b.ends.items);
    try testing.expect(a.count() > 40);
}

test "textBBox contains all stroke points" {
    var f = try testFont();
    defer f.deinit();
    var o: Polylines = .{};
    defer o.deinit(testing.allocator);
    const s = "SECTION A-A";
    try f.textStrokes(testing.allocator, &o, s, 1, 5, 6, 30, .center, .middle);
    const bb = f.textBBox(s, 1, 5, 6, 30, .center, .middle).grow(1e-9);
    for (o.pts.items) |p| try testing.expect(bb.contains(p.x, p.y));
}

test "all printable ASCII produce finite strokes" {
    var f = try testFont();
    defer f.deinit();
    var o: Polylines = .{};
    defer o.deinit(testing.allocator);
    var c: u8 = 32;
    while (c < 127) : (c += 1) {
        o.clear();
        const s = [1]u8{c};
        try f.textStrokes(testing.allocator, &o, &s, 1, 0, 0, 0, .left, .baseline);
        for (o.pts.items) |p| try testing.expect(std.math.isFinite(p.x) and std.math.isFinite(p.y));
        if (c != ' ') try testing.expect(o.count() >= 1);
    }
}

test "init rejects garbage" {
    try testing.expectError(error.InvalidFont, Font.init(testing.allocator, "nope"));
    try testing.expectError(error.InvalidFont, Font.init(testing.allocator, "{\"glyphs\":{}}"));
}
