//! Bidi-aware geometry of one laid-out line (UAX #9 L1/L2 over `bidi.zig`).
//!
//! `text_wrap` breaks text into lines in logical order and measures prefixes
//! left to right. For a line that mixes directions the glyphs are drawn in
//! visual order instead, so everything that maps between byte offsets and x
//! (caret, hit-test, selection, drawing) goes through a `Layout` built here:
//! the line is split into directional runs (`bidi.lineRuns`), each run is
//! measured whole, and a boundary inside a right-to-left run sits at
//! `run.x + run.w - width(prefix)`.
//!
//! Pure and allocation-free for callers: all scratch lives in a `Scratch`
//! (stack). `layoutLine` returns null when the line is plain left-to-right
//! (the overwhelmingly common case: one byte scan decides), or too long for
//! the scratch; callers then use their logical code path unchanged.
//!
//! Caret convention (no extra Model state): the caret at byte `i > line start`
//! is drawn on the trailing edge of the cluster before `i`; at the line start
//! on the leading edge of the first cluster. Inside a run both agree; at a
//! direction boundary this picks one of the two visual places.

const std = @import("std");
pub const bidi = @import("bidi.zig");
const text_mod = @import("text.zig");
const unicode = @import("unicode.zig");

const FontSpec = text_mod.FontSpec;
const TextMeasurer = text_mod.TextMeasurer;

/// Longest paragraph (bytes between hard line breaks) analysed; longer ones
/// are drawn and edited in logical order.
pub const MAX_PARA = 2048;
/// Directional runs per line before falling back to logical order.
pub const MAX_RUNS = 48;

/// Stack scratch for one analysis. Not zeroed (`undefined`).
pub const Scratch = struct { buf: [96 * 1024]u8 = undefined };

/// True when `s` may contain right-to-left characters or bidi controls
/// (any UTF-8 lead byte from U+0580 up). A cheap pre-filter, not a decision.
pub fn mayBeRtl(s: []const u8) bool {
    for (s) |b| if (b >= 0xD6) return true;
    return false;
}

pub const Span = bidi.Span;

pub const RunGeo = struct {
    /// Byte range in the text (absolute).
    start: u32,
    end: u32,
    level: u8,
    /// Left edge and width, line-local px (origin shift included).
    x: f32,
    w: f32,

    pub fn rtl(self: RunGeo) bool {
        return self.level & 1 == 1;
    }
};

pub const Layout = struct {
    runs: [MAX_RUNS]RunGeo = undefined,
    n: usize = 0,
    ls: usize = 0,
    le: usize = 0,
    /// Sum of run widths.
    width: f32 = 0,
    /// The paragraph's base direction is right-to-left.
    para_rtl: bool = false,
    text: []const u8 = "",
    font: FontSpec = .{},
    m: TextMeasurer = undefined,

    pub fn items(self: *const Layout) []const RunGeo {
        return self.runs[0..self.n];
    }

    fn runFont(self: *const Layout, r: RunGeo) FontSpec {
        var f = self.font;
        f.rtl = r.rtl();
        return f;
    }

    /// x of byte boundary `i` (`r.start <= i <= r.end`) inside run `r`.
    fn xIn(self: *const Layout, r: RunGeo, i: usize) f32 {
        const wp: f32 = if (i <= r.start) 0 else if (i >= r.end) r.w else self.m.measure(self.text[r.start..i], self.runFont(r)).width;
        return if (r.rtl()) r.x + r.w - wp else r.x + wp;
    }

    /// Line-local x of the caret at byte offset `idx` (see the caret convention).
    pub fn caretX(self: *const Layout, idx: usize) f32 {
        const i = std.math.clamp(idx, self.ls, self.le);
        for (self.items()) |r| {
            if (i > self.ls and r.start < i and i <= r.end) return self.xIn(r, i);
            if (i == self.ls and r.start <= i and i < r.end) return self.xIn(r, i);
        }
        return if (self.para_rtl) self.width else 0;
    }

    /// Byte offset of the caret position nearest to line-local `x` (ties go left).
    pub fn indexAt(self: *const Layout, x: f32) usize {
        var best: usize = self.ls;
        var best_d: f32 = std.math.inf(f32);
        var best_x: f32 = 0;
        for (self.items()) |r| {
            if (r.start <= self.ls and self.ls < r.end) self.consider(r, self.ls, x, &best, &best_d, &best_x);
            var p: usize = r.start;
            while (p < r.end) {
                p = @min(unicode.nextGrapheme(self.text[0..r.end], p), r.end);
                self.consider(r, p, x, &best, &best_d, &best_x);
            }
        }
        return best;
    }

    fn consider(self: *const Layout, r: RunGeo, i: usize, x: f32, best: *usize, best_d: *f32, best_x: *f32) void {
        const cx = self.xIn(r, i);
        const d = @abs(cx - x);
        if (d < best_d.* or (d == best_d.* and cx < best_x.*)) {
            best.* = i;
            best_d.* = d;
            best_x.* = cx;
        }
    }

    /// Highlight spans of the logical selection `[lo, hi)` in visual order,
    /// touching spans merged. At most `out.len` spans (excess merged into the last).
    pub fn selection(self: *const Layout, lo: usize, hi: usize, out: []Span) []Span {
        var n: usize = 0;
        for (self.items()) |r| {
            const a = @max(lo, @as(usize, r.start));
            const b = @min(hi, @as(usize, r.end));
            if (a >= b) continue;
            const xa = self.xIn(r, a);
            const xb = self.xIn(r, b);
            const s: Span = .{ .x0 = @min(xa, xb), .x1 = @max(xa, xb) };
            if (n > 0 and @abs(out[n - 1].x1 - s.x0) < 0.5) {
                out[n - 1].x1 = s.x1;
            } else if (n < out.len) {
                out[n] = s;
                n += 1;
            } else {
                out[n - 1].x1 = @max(out[n - 1].x1, s.x1);
            }
        }
        return out[0..n];
    }
};

fn paraBounds(text: []const u8, at: usize) struct { s: usize, e: usize } {
    const a = @min(at, text.len);
    const s = if (std.mem.lastIndexOfScalar(u8, text[0..a], '\n')) |k| k + 1 else 0;
    const e = if (std.mem.indexOfScalarPos(u8, text, a, '\n')) |k| k else text.len;
    return .{ .s = s, .e = e };
}

/// Direction-aware layout of the line `[ls, le)` of `text`, or null when the
/// plain left-to-right path applies. `wrap_w` (infinity for none) right-aligns
/// lines of a right-to-left paragraph.
pub fn layoutLine(text: []const u8, ls: usize, le: usize, font: FontSpec, m: TextMeasurer, wrap_w: f32, scratch: *Scratch) ?Layout {
    if (le <= ls or le > text.len) return null;
    const pb = paraBounds(text, ls);
    if (pb.e - pb.s > MAX_PARA or !mayBeRtl(text[pb.s..pb.e])) return null;
    var fba = std.heap.FixedBufferAllocator.init(&scratch.buf);
    const gpa = fba.allocator();
    const an = bidi.analyze(gpa, text[pb.s..pb.e], .auto) catch return null;
    if (an.isPlainLtr()) return null;
    const runs = bidi.lineRuns(gpa, an, ls - pb.s, le - pb.s) catch return null;
    if (runs.len == 0 or runs.len > MAX_RUNS) return null;
    var lay: Layout = .{ .ls = ls, .le = le, .para_rtl = an.para_level & 1 == 1, .text = text, .font = font, .m = m };
    var x: f32 = 0;
    for (runs, 0..) |r, k| {
        var g: RunGeo = .{ .start = @intCast(pb.s + r.start), .end = @intCast(pb.s + r.end), .level = r.level, .x = 0, .w = 0 };
        g.w = m.measure(text[g.start..g.end], lay.runFont(g)).width;
        g.x = x;
        x += g.w;
        lay.runs[k] = g;
    }
    lay.n = runs.len;
    lay.width = x;
    if (lay.para_rtl and std.math.isFinite(wrap_w) and wrap_w > x) {
        const shift = wrap_w - x;
        for (lay.runs[0..lay.n]) |*r| r.x += shift;
    }
    return lay;
}

/// Target of a visual Left / Right arrow from byte `cursor` over the line
/// `[ls, le)`, or null when the line is plain LTR or no caret position lies
/// further that way (the caller then moves to the neighbouring line /
/// logically). Stateless: positions are ordered by visual slot under the caret
/// convention, so repeated presses always make progress.
pub fn arrowTarget(text: []const u8, ls: usize, le: usize, cursor: usize, arrow: bidi.Arrow, scratch: *Scratch) ?usize {
    if (le <= ls or le > text.len) return null;
    const pb = paraBounds(text, ls);
    if (pb.e - pb.s > MAX_PARA or !mayBeRtl(text[pb.s..pb.e])) return null;
    var fba = std.heap.FixedBufferAllocator.init(&scratch.buf);
    const gpa = fba.allocator();
    const an = bidi.analyze(gpa, text[pb.s..pb.e], .auto) catch return null;
    if (an.isPlainLtr()) return null;
    const ptext = text[pb.s..pb.e];
    const slots_buf = gpa.alloc(u32, MAX_PARA + 1) catch return null;
    const slots = bidi.boundarySlots(gpa, ptext, an, ls - pb.s, le - pb.s, slots_buf) catch return null;
    // Boundary byte offsets, aligned with `slots`.
    var cur_slot: ?u32 = null;
    var p = ls;
    var k: usize = 0;
    const idx = std.math.clamp(cursor, ls, le);
    while (k < slots.len) : (k += 1) {
        const at = if (k + 1 < slots.len) p else le;
        if (at == idx) cur_slot = slots[k];
        if (k + 1 < slots.len) p = @min(unicode.nextGrapheme(text[0..le], p), le);
    }
    const cs = cur_slot orelse return null;
    // Nearest position strictly beyond `cs` in the arrow's direction.
    var best: ?usize = null;
    var best_slot: u32 = 0;
    p = ls;
    k = 0;
    while (k < slots.len) : (k += 1) {
        const at = if (k + 1 < slots.len) p else le;
        const sl = slots[k];
        const beyond = if (arrow == .right) sl > cs else sl < cs;
        if (beyond) {
            const nearer = best == null or (if (arrow == .right) sl < best_slot else sl > best_slot);
            if (nearer) {
                best = at;
                best_slot = sl;
            }
        }
        if (k + 1 < slots.len) p = @min(unicode.nextGrapheme(text[0..le], p), le);
    }
    return best;
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

/// 10 px per code point, fixed (test measurer).
fn fixedMeasure(_: *anyopaque, s: []const u8, _: FontSpec) text_mod.TextMetrics {
    var n: usize = 0;
    var p: usize = 0;
    while (p < s.len) : (n += 1) p += unicode.utf8DecodeLossy(s, p).len;
    return .{ .width = @floatFromInt(n * 10), .height = 16, .ascent = 12, .descent = 4 };
}

fn tm() TextMeasurer {
    return .{ .ctx = undefined, .measure_fn = &fixedMeasure };
}

const S = "ab \u{5d0}\u{5d1}\u{5d2} cd"; // a b _ [alef bet gimel] _ c d  (cps 0..8)

test "layoutLine: plain LTR returns null" {
    var sc: Scratch = .{};
    try testing.expect(layoutLine("hello world", 0, 11, .{}, tm(), std.math.inf(f32), &sc) == null);
}

test "layoutLine: mixed line has LTR, RTL, LTR runs in visual order" {
    var sc: Scratch = .{};
    const lay = layoutLine(S, 0, S.len, .{}, tm(), std.math.inf(f32), &sc).?;
    try testing.expectEqual(@as(usize, 3), lay.n);
    try testing.expectEqual(@as(u8, 0), lay.runs[0].level);
    try testing.expectEqual(@as(u8, 1), lay.runs[1].level);
    try testing.expectEqual(@as(f32, 30), lay.runs[1].x); // after "ab "
    try testing.expectEqual(@as(f32, 30), lay.runs[1].w);
    try testing.expectEqual(@as(f32, 90), lay.width);
}

test "caret and hit-test round-trip on a mixed line" {
    var sc: Scratch = .{};
    const lay = layoutLine(S, 0, S.len, .{}, tm(), std.math.inf(f32), &sc).?;
    // Logical start of the Hebrew run (byte 3) is drawn at ITS visual left
    // (trailing edge of the space before it); inside the run x decreases as the
    // logical index grows.
    const alef_end = 3 + 2; // after alef
    const bet_end = 3 + 4;
    try testing.expect(lay.caretX(alef_end) > lay.caretX(bet_end));
    try testing.expectEqual(@as(f32, 20), lay.caretX(2)); // between b and space
    // Every grapheme boundary maps back to itself.
    var p: usize = 0;
    while (p <= S.len) {
        const x = lay.caretX(p);
        const back = lay.indexAt(x);
        try testing.expectApproxEqAbs(x, lay.caretX(back), 0.001);
        if (p == S.len) break;
        p = unicode.nextGrapheme(S, p);
    }
}

test "selection across a direction boundary yields visually ordered spans" {
    var sc: Scratch = .{};
    const lay = layoutLine(S, 0, S.len, .{}, tm(), std.math.inf(f32), &sc).?;
    var out: [8]Span = undefined;
    // Select "b _ alef": logical [1, 3+2).
    const sp = lay.selection(1, 5, &out);
    try testing.expect(sp.len >= 1);
    for (sp) |s| try testing.expect(s.x1 > s.x0);
    // The whole line selects as one span.
    const all = lay.selection(0, S.len, &out);
    try testing.expectEqual(@as(usize, 1), all.len);
    try testing.expectEqual(@as(f32, 90), all[0].x1 - all[0].x0);
}

test "RTL paragraph right-aligns when a wrap width is given" {
    var sc: Scratch = .{};
    const h = "\u{5d0}\u{5d1}\u{5d2}";
    const lay = layoutLine(h, 0, h.len, .{}, tm(), 100, &sc).?;
    try testing.expect(lay.para_rtl);
    try testing.expectEqual(@as(f32, 70), lay.runs[0].x);
}

test "arrowTarget: visual right from the end of LTR text enters the RTL run" {
    var sc: Scratch = .{};
    const t = "ab \u{5d0}\u{5d1}";
    // Right arrow from idx 3 (after "ab ") steps into the RTL run, not to byte 5.
    const r1 = arrowTarget(t, 0, t.len, 3, .right, &sc).?;
    try testing.expect(r1 > 3);
    // Visiting with repeated Right from 0 reaches every slot and then stops.
    var i: usize = 0;
    var cur: usize = 0;
    while (i < 20) : (i += 1) {
        cur = arrowTarget(t, 0, t.len, cur, .right, &sc) orelse break;
    }
    try testing.expect(i < 20);
}
