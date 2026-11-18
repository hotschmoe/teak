//! Unicode support for text entry and layout: lossy UTF-8 decoding, UAX #29
//! extended grapheme clusters (Unicode 16, including GB9c Indic conjuncts and
//! GB11 emoji ZWJ sequences), word classes for Ctrl+Arrow / double-click, and
//! property lookups (line-break class, East Asian wide) used by `linebreak.zig`.
//!
//! Pure and allocation-free: std only. Property data is generated into
//! `unicode_tables.zig` by `tools/gen_unicode.zig` (about 12 KB of run tables).
//!
//! Byte offsets everywhere. Invalid UTF-8 is tolerated: every byte that is not
//! part of a well-formed sequence is one unit decoding to U+FFFD, so segmentation
//! never fails and never reads out of bounds. Forward (`nextGrapheme`) and
//! backward (`prevGrapheme`) walks always agree on boundaries.

const std = @import("std");
const t = @import("unicode_tables.zig");

pub const Gcb = t.Gcb;
pub const Lb = t.Lb;

/// U+FFFD, what an invalid byte decodes to.
pub const replacement: u21 = 0xFFFD;

pub const Decoded = struct {
    cp: u21,
    /// Bytes consumed, 1..4. Always >= 1 so callers make progress.
    len: u3,
};

/// Decode the unit at `bytes[i]` (`i < bytes.len`). Well-formed sequences decode
/// to their code point (overlongs, surrogates and values above U+10FFFF are
/// rejected); anything else is one byte of U+FFFD.
pub fn utf8DecodeLossy(bytes: []const u8, i: usize) Decoded {
    const b0 = bytes[i];
    if (b0 < 0x80) return .{ .cp = b0, .len = 1 };
    const bad: Decoded = .{ .cp = replacement, .len = 1 };
    var need: u3 = undefined;
    var cp: u32 = undefined;
    var min: u32 = undefined;
    switch (b0) {
        0xC2...0xDF => {
            need = 2;
            cp = b0 & 0x1F;
            min = 0x80;
        },
        0xE0...0xEF => {
            need = 3;
            cp = b0 & 0x0F;
            min = 0x800;
        },
        0xF0...0xF4 => {
            need = 4;
            cp = b0 & 0x07;
            min = 0x10000;
        },
        else => return bad,
    }
    if (i + need > bytes.len) return bad;
    for (bytes[i + 1 ..][0 .. need - 1]) |b| {
        if (b & 0xC0 != 0x80) return bad;
        cp = (cp << 6) | (b & 0x3F);
    }
    if (cp < min or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF)) return bad;
    return .{ .cp = @intCast(cp), .len = need };
}

/// Start of the decode unit that ends at `i` (`0 < i <= bytes.len`), consistent
/// with forward `utf8DecodeLossy` segmentation.
pub fn utf8PrevStart(bytes: []const u8, i: usize) usize {
    std.debug.assert(i > 0 and i <= bytes.len);
    if (bytes[i - 1] & 0xC0 == 0x80) {
        var k: usize = 2;
        while (k <= 4 and k <= i) : (k += 1) {
            const s = i - k;
            if (bytes[s] & 0xC0 == 0x80) continue;
            const d = utf8DecodeLossy(bytes, s);
            if (d.len == k) return s;
            break;
        }
    }
    return i - 1;
}


inline fn gprop(cp: u21) u8 {
    return t.lookup(&t.grapheme_runs, cp);
}

inline fn lprop(cp: u21) u8 {
    return t.lookup(&t.linebreak_runs, cp);
}

/// UAX #29 Grapheme_Cluster_Break of `cp`.
pub fn graphemeBreakClass(cp: u21) Gcb {
    return @fromBackingInt(@intCast(@as(u4, @truncate(gprop(cp)))));
}

/// UAX #14 class of `cp`, reduced to the "lite" set (see `linebreak.zig`).
pub fn lineBreakClass(cp: u21) Lb {
    return @fromBackingInt(@intCast(@as(u4, @truncate(lprop(cp)))));
}

/// East_Asian_Width is W or F (occupies two cells; CJK break rules apply).
pub fn isWide(cp: u21) bool {
    return lprop(cp) & 0x80 != 0;
}


/// Incremental UAX #29 boundary decider. Feed code points in order; `step`
/// answers whether there is a boundary *before* the fed code point.
pub const GraphemeState = struct {
    prev: Gcb = .other,
    /// 0 none, 1 = ExtPict Extend* seen, 2 = ... ZWJ seen (GB11).
    pict: u2 = 0,
    ri_odd: bool = false,
    /// 0 none, 1 = Consonant [Extend|Linker]* seen, 2 = ... with a Linker (GB9c).
    conj: u2 = 0,
    started: bool = false,

    pub fn step(self: *GraphemeState, cp: u21) bool {
        const p = gprop(cp);
        const cur: Gcb = @fromBackingInt(@intCast(@as(u4, @truncate(p))));
        const ext_pict = p & 0x10 != 0;
        const incb: t.Incb = @fromBackingInt(@intCast(@as(u2, @truncate(p >> 5))));
        const prev = self.prev;
        const brk = !self.started or self.decide(prev, cur, ext_pict, incb);
        self.started = true;

        if (ext_pict) {
            self.pict = 1;
        } else if (cur == .extend and self.pict == 1) {
        } else if (cur == .zwj and self.pict == 1) {
            self.pict = 2;
        } else self.pict = 0;
        self.ri_odd = cur == .ri and brk;
        switch (incb) {
            .consonant => self.conj = 1,
            .linker => self.conj = if (self.conj != 0) 2 else 0,
            .extend => {},
            .none => self.conj = 0,
        }
        self.prev = cur;
        return brk;
    }

    fn decide(self: *const GraphemeState, prev: Gcb, cur: Gcb, ext_pict: bool, incb: t.Incb) bool {
        if (prev == .cr and cur == .lf) return false; // GB3
        if (prev == .control or prev == .cr or prev == .lf) return true; // GB4
        if (cur == .control or cur == .cr or cur == .lf) return true; // GB5
        switch (prev) { // GB6-8: Hangul syllable sequences
            .l => if (cur == .l or cur == .v or cur == .lv or cur == .lvt) return false,
            .lv, .v => if (cur == .v or cur == .t) return false,
            .lvt, .t => if (cur == .t) return false,
            else => {},
        }
        if (cur == .extend or cur == .zwj) return false; // GB9
        if (cur == .spacing_mark) return false; // GB9a
        if (prev == .prepend) return false; // GB9b
        if (incb == .consonant and self.conj == 2) return false; // GB9c
        if (self.pict == 2 and ext_pict) return false; // GB11
        if (prev == .ri and cur == .ri and self.ri_odd) return false; // GB12/13
        return true; // GB999
    }
};

/// End offset of the grapheme cluster that starts at `i` (`i < text.len`).
/// Always `> i`.
pub fn nextGrapheme(text: []const u8, i: usize) usize {
    var st: GraphemeState = .{};
    var p = i;
    while (p < text.len) {
        const d = utf8DecodeLossy(text, p);
        if (st.step(d.cp) and p != i) return p;
        p += d.len;
    }
    return p;
}

/// Start offset of the grapheme cluster that contains byte `i - 1`
/// (`0 < i <= text.len`); equals the previous boundary when `i` is one.
pub fn prevGrapheme(text: []const u8, i: usize) usize {
    std.debug.assert(i > 0 and i <= text.len);
    // Adjacent ASCII bytes other than CRLF form a context-free boundary.
    var q = utf8PrevStart(text, i);
    while (q > 0 and !(text[q] < 0x80 and text[q - 1] < 0x80 and !(text[q - 1] == '\r' and text[q] == '\n')))
        q = utf8PrevStart(text, q);
    var last = q;
    var cur = q;
    while (true) {
        const e = nextGrapheme(text, cur);
        if (e >= i) break;
        last = e;
        cur = e;
    }
    return last;
}

/// True when `i` is a grapheme boundary of `text` (0 and `text.len` always are).
pub fn isGraphemeBoundary(text: []const u8, i: usize) bool {
    if (i == 0 or i >= text.len) return i <= text.len;
    return nextGrapheme(text, prevGrapheme(text, i)) == i;
}

/// Largest grapheme boundary <= `i` (clamped to `text.len`).
pub fn snapBackward(text: []const u8, i: usize) usize {
    if (i >= text.len) return text.len;
    if (i == 0) return 0;
    const s = prevGrapheme(text, i + 1);
    return s;
}

/// Iterates grapheme clusters as byte slices.
pub const GraphemeIterator = struct {
    text: []const u8,
    pos: usize = 0,

    pub fn next(self: *GraphemeIterator) ?[]const u8 {
        if (self.pos >= self.text.len) return null;
        const e = nextGrapheme(self.text, self.pos);
        defer self.pos = e;
        return self.text[self.pos..e];
    }
};

/// First code point of a (non-empty) cluster slice.
pub fn firstCodepoint(cluster: []const u8) u21 {
    return utf8DecodeLossy(cluster, 0).cp;
}

/// Number of grapheme clusters in `text`.
pub fn graphemeCount(text: []const u8) usize {
    var it: GraphemeIterator = .{ .text = text };
    var n: usize = 0;
    while (it.next()) |_| n += 1;
    return n;
}


pub const WordClass = enum { space, word, punct, han };

fn isHan(cp: u21) bool {
    return (cp >= 0x4E00 and cp <= 0x9FFF) or (cp >= 0x3400 and cp <= 0x4DBF) or
        (cp >= 0xF900 and cp <= 0xFAFF) or (cp >= 0x20000 and cp <= 0x3FFFD) or cp == 0x3005 or cp == 0x3007;
}

/// Class used for word motion: whitespace / word (letters, digits, `_`, every
/// non-ASCII letter or symbol, emoji) / punctuation / Han (one ideograph per
/// word). Non-ASCII punctuation is approximated from the line-break classes.
pub fn wordClass(cp: u21) WordClass {
    if (cp < 0x80) {
        return switch (cp) {
            'a'...'z', 'A'...'Z', '0'...'9', '_' => .word,
            0...' ', 0x7F => .space,
            else => .punct,
        };
    }
    switch (cp) {
        0x85, 0xA0, 0x1680, 0x2000...0x200B, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 => return .space,
        else => {},
    }
    if (isHan(cp)) return .han;
    // Kana and half-width kana are letters even though some are NS/CJ in UAX #14.
    if ((cp >= 0x3040 and cp <= 0x30FF) or (cp >= 0x31F0 and cp <= 0x31FF) or (cp >= 0xFF66 and cp <= 0xFF9F)) return .word;
    return switch (lineBreakClass(cp)) {
        .op, .cl, .no_before, .qu, .hy => .punct,
        .ba => if (cp >= 0x2010 and cp <= 0x2027) .punct else .word,
        else => .word,
    };
}

fn clusterClass(text: []const u8, start: usize, end: usize) WordClass {
    return wordClass(firstCodepoint(text[start..end]));
}

/// Offset after the next word: skips whitespace, then one run of a single
/// class (a Han ideograph is a run of one). `text.len` at the end.
pub fn nextWordBoundary(text: []const u8, i: usize) usize {
    var p = i;
    while (p < text.len) {
        const e = nextGrapheme(text, p);
        if (clusterClass(text, p, e) != .space) break;
        p = e;
    }
    if (p >= text.len) return text.len;
    var e = nextGrapheme(text, p);
    const cls = clusterClass(text, p, e);
    if (cls == .han) return e;
    p = e;
    while (p < text.len) {
        e = nextGrapheme(text, p);
        if (clusterClass(text, p, e) != cls) break;
        p = e;
    }
    return p;
}

/// Offset of the start of the previous word (mirror of `nextWordBoundary`).
pub fn prevWordBoundary(text: []const u8, i: usize) usize {
    var p = @min(i, text.len);
    while (p > 0) {
        const s = prevGrapheme(text, p);
        if (clusterClass(text, s, p) != .space) break;
        p = s;
    }
    if (p == 0) return 0;
    var s = prevGrapheme(text, p);
    const cls = clusterClass(text, s, p);
    if (cls == .han) return s;
    p = s;
    while (p > 0) {
        s = prevGrapheme(text, p);
        if (clusterClass(text, s, p) != cls) break;
        p = s;
    }
    return p;
}

pub const Span = struct { start: usize, end: usize };

/// The run of same-class clusters containing the grapheme at `i` (double-click
/// selection). `i >= text.len` selects the run before the end. Empty text gives
/// an empty span.
pub fn wordRangeAt(text: []const u8, i: usize) Span {
    if (text.len == 0) return .{ .start = 0, .end = 0 };
    const at = @min(snapBackward(text, i), prevGrapheme(text, text.len));
    const e0 = nextGrapheme(text, at);
    const cls = clusterClass(text, at, e0);
    if (cls == .han) return .{ .start = at, .end = e0 };
    var s = at;
    while (s > 0) {
        const ps = prevGrapheme(text, s);
        if (clusterClass(text, ps, s) != cls) break;
        s = ps;
    }
    var e = e0;
    while (e < text.len) {
        const ne = nextGrapheme(text, e);
        if (clusterClass(text, e, ne) != cls) break;
        e = ne;
    }
    return .{ .start = s, .end = e };
}


const testing = std.testing;
const conformance_excerpt = @embedFile("testdata/GraphemeBreakTest_excerpt.txt");

fn utf8Lossy(bytes: []const u8, out: []u21) usize {
    var i: usize = 0;
    var n: usize = 0;
    while (i < bytes.len) : (n += 1) {
        const d = utf8DecodeLossy(bytes, i);
        out[n] = d.cp;
        i += d.len;
    }
    return n;
}




fn parseHexCps(tok: []const u8) u21 {
    return @intCast(std.fmt.parseInt(u32, tok, 16) catch unreachable);
}




