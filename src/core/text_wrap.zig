//! Pure text wrapping, height-for-width measurement and caret/point mapping.
//!
//! No platform, no allocation: everything is a function of `(text, font,
//! max_width, mode)` and a `TextMeasurer` (use `teak.monoMeasurer()` in tests).
//! Break opportunities come from `linebreak.zig`; overlong unbreakable tokens
//! are cut at grapheme boundaries (CSS `overflow-wrap: anywhere`) so nothing
//! overflows a line that has room for one grapheme.
//!
//! Line model (all byte offsets into `text`, always grapheme boundaries):
//!
//!   start .. end    visible content
//!   end   .. hang   trailing spaces/ZWSP that "hang": excluded from `width` and
//!                   from the fit test, but still caret positions
//!   hang  .. next   the line terminator (hard breaks only)
//!
//! Lines tile the text: `line[k].next == line[k+1].start`. Text that ends in a
//! terminator produces one extra empty line (the caret can sit after it), and
//! empty text is one empty line. Width accumulation sums per-segment measures
//! (no kerning across a break opportunity); caret/point mapping measures
//! prefixes so a caret x is exactly what the measurer reports for the text
//! before it.

const std = @import("std");
const text_mod = @import("text.zig");
const unicode = @import("unicode.zig");
const linebreak = @import("linebreak.zig");

const FontSpec = text_mod.FontSpec;
const TextMeasurer = text_mod.TextMeasurer;

/// How a text run is broken into lines. (`TextCmd.wrap` uses this type.)
pub const Wrap = enum(u8) {
    /// One line per hard break; never wraps.
    none,
    /// Break at UAX #14 opportunities; overlong tokens break at graphemes.
    word,
    /// Break at any grapheme boundary.
    char,
    /// A single line truncated with U+2026 where it does not fit.
    ellipsis,
};

pub const ELLIPSIS = "\u{2026}";

pub const Line = struct {
    start: u32,
    /// End of visible content (before hanging spaces and the terminator).
    end: u32,
    /// End of content plus hanging spaces, before the terminator.
    hang: u32,
    /// Start of the following line.
    next: u32,
    /// Width of `text[start..end]` (plus the ellipsis when `ellipsized`).
    width: f32,
    /// The line ends at a hard line terminator.
    hard_break: bool,
    /// Content was truncated; the renderer appends `ELLIPSIS` after `end`.
    ellipsized: bool = false,
};

/// Line height for `font` as the measurer reports it.
pub fn lineHeight(font: FontSpec, m: TextMeasurer) f32 {
    return m.measure(" ", font).height;
}

fn widthOf(text: []const u8, font: FontSpec, m: TextMeasurer) f32 {
    if (text.len == 0) return 0;
    return m.measure(text, font).width;
}

const Trim = struct { content: usize, hang: usize };

/// Splits the trailing terminator and spaces off `text[s..e]`.
fn trimSegment(text: []const u8, s: usize, e: usize) Trim {
    var hang = e;
    while (hang > s) {
        const p = @max(unicode.prevGrapheme(text, hang), s);
        if (!linebreak.isTerminator(unicode.firstCodepoint(text[p..hang]))) break;
        hang = p;
    }
    var c = hang;
    while (c > s) {
        const p = @max(unicode.prevGrapheme(text, c), s);
        if (!linebreak.isTrailing(unicode.firstCodepoint(text[p..c]))) break;
        c = p;
    }
    return .{ .content = c, .hang = hang };
}

/// Width of the spaces in `text[content..hang]` (zero-width ZWSP clusters count 0).
fn hangWidth(text: []const u8, content: usize, hang: usize, font: FontSpec, m: TextMeasurer) f32 {
    var w: f32 = 0;
    var p = content;
    while (p < hang) {
        const e = unicode.nextGrapheme(text, p);
        if (unicode.lineBreakClass(unicode.firstCodepoint(text[p..e])) == .sp) w += widthOf(text[p..e], font, m);
        p = e;
    }
    return w;
}

fn emptyLine(at: usize) Line {
    return .{ .start = @intCast(at), .end = @intCast(at), .hang = @intCast(at), .next = @intCast(at), .width = 0, .hard_break = false };
}

/// The unwrapped hard line starting at `start`.
fn hardLine(text: []const u8, start: usize, font: FontSpec, m: TextMeasurer) Line {
    var br = linebreak.Breaker.init(text, start);
    while (br.next()) |b| {
        if (b.kind == .soft) continue;
        // The terminator (if any) is at the end of the last segment.
        const tr = trimSegment(text, start, b.end);
        return .{
            .start = @intCast(start),
            .end = @intCast(tr.content),
            .hang = @intCast(tr.hang),
            .next = @intCast(b.end),
            .width = widthOf(text[start..tr.content], font, m),
            .hard_break = b.kind == .hard,
        };
    }
    return emptyLine(start);
}

/// Greedy line from `start` cutting at grapheme boundaries only; stops at a
/// hard terminator. `stop` bounds the scan (a segment end for overlong tokens).
fn charLine(text: []const u8, start: usize, stop: usize, font: FontSpec, max_w: f32, m: TextMeasurer) Line {
    var p = start;
    var acc: f32 = 0;
    while (p < stop) {
        const e = unicode.nextGrapheme(text, p);
        if (linebreak.isTerminator(unicode.firstCodepoint(text[p..e]))) {
            return .{
                .start = @intCast(start),
                .end = @intCast(p),
                .hang = @intCast(p),
                .next = @intCast(e),
                .width = widthOf(text[start..p], font, m),
                .hard_break = true,
            };
        }
        const cw = widthOf(text[p..e], font, m);
        if (p > start and acc + cw > max_w) break;
        acc += cw;
        p = e;
    }
    return .{
        .start = @intCast(start),
        .end = @intCast(p),
        .hang = @intCast(p),
        .next = @intCast(p),
        .width = widthOf(text[start..p], font, m),
        .hard_break = false,
    };
}

/// Next line of `text[start..]` for a maximum width (`start` must be a line
/// start: 0 or a previous `Line.next`). O(line length) measurer calls.
/// `.ellipsis` behaves like `.none` here; truncation is applied by `LineIter`
/// (it needs to know whether this is the last visible line).
pub fn nextLine(text: []const u8, start: usize, font: FontSpec, max_w: f32, mode: Wrap, m: TextMeasurer) Line {
    if (start >= text.len) return emptyLine(text.len);
    switch (mode) {
        .none, .ellipsis => return hardLine(text, start, font, m),
        .char => return charLine(text, start, text.len, font, max_w, m),
        .word => {},
    }
    var br = linebreak.Breaker.init(text, start);
    var line: Line = emptyLine(start);
    var any = false;
    var acc: f32 = 0; // full width of accepted segments, trailing spaces included
    var seg_start = start;
    while (br.next()) |b| {
        const tr = trimSegment(text, seg_start, b.end);
        const tw = widthOf(text[seg_start..tr.content], font, m);
        if (any and acc + tw > max_w) {
            line.next = @intCast(seg_start);
            line.hard_break = false;
            return line;
        }
        if (!any and tw > max_w) {
            // Unbreakable token wider than the line: cut it at graphemes.
            var cut = charLine(text, start, tr.content, font, max_w, m);
            if (cut.end == tr.content) {
                // The last piece of the token: its trailing spaces hang here
                // instead of becoming a blank line of their own.
                cut.hang = @intCast(tr.hang);
                cut.next = @intCast(b.end);
                cut.hard_break = b.kind == .hard;
            }
            return cut;
        }
        any = true;
        line.end = @intCast(tr.content);
        line.hang = @intCast(tr.hang);
        line.width = acc + tw;
        if (b.kind != .soft) {
            line.next = @intCast(b.end);
            line.hard_break = b.kind == .hard;
            return line;
        }
        acc += tw + hangWidth(text, tr.content, tr.hang, font, m);
        seg_start = b.end;
    }
    return line;
}

/// Truncates the hard line at `line` so that content plus `ELLIPSIS` fits in
/// `max_w`, at a grapheme boundary; trailing spaces before the ellipsis are dropped.
fn ellipsize(text: []const u8, line: Line, font: FontSpec, max_w: f32, m: TextMeasurer) Line {
    const hl = hardLine(text, line.start, font, m);
    const ew = widthOf(ELLIPSIS, font, m);
    var p: usize = hl.start;
    var acc: f32 = 0;
    while (p < hl.end) {
        const e = unicode.nextGrapheme(text, p);
        const cw = widthOf(text[p..e], font, m);
        if (acc + cw + ew > max_w) break;
        acc += cw;
        p = e;
    }
    while (p > hl.start) {
        const q = unicode.prevGrapheme(text, p);
        if (!linebreak.isTrailing(unicode.firstCodepoint(text[q..p]))) break;
        p = q;
    }
    var out = line;
    out.end = @intCast(p);
    out.hang = @intCast(p);
    out.width = widthOf(text[hl.start..p], font, m) + ew;
    out.ellipsized = true;
    return out;
}

/// Iterates the visible lines of a text: honours `max_lines` (0 = unlimited)
/// and ellipsizes the last visible line when text remains (or, for
/// `.ellipsis`, when the line is too wide). `.ellipsis` shows exactly one line.
pub const LineIter = struct {
    text: []const u8,
    font: FontSpec,
    max_w: f32,
    mode: Wrap,
    max_lines: u32,
    m: TextMeasurer,
    pos: u32 = 0,
    index: u32 = 0,
    done: bool = false,

    pub fn init(text: []const u8, font: FontSpec, max_w: f32, mode: Wrap, max_lines: u32, m: TextMeasurer) LineIter {
        return .{
            .text = text,
            .font = font,
            .max_w = max_w,
            .mode = mode,
            .max_lines = if (mode == .ellipsis) 1 else max_lines,
            .m = m,
        };
    }

    pub fn next(self: *LineIter) ?Line {
        if (self.done) return null;
        if (self.max_lines != 0 and self.index >= self.max_lines) return null;
        var line = nextLine(self.text, self.pos, self.font, self.max_w, self.mode, self.m);
        const last_visible = self.max_lines != 0 and self.index + 1 == self.max_lines;
        if (last_visible and (line.next < self.text.len or (self.mode == .ellipsis and line.width > self.max_w))) {
            // Text remains after this line (or the unwrapped line overflows).
            if (self.mode == .word or self.mode == .char) {
                if (line.next < self.text.len) line = ellipsize(self.text, line, self.font, self.max_w, self.m);
            } else line = ellipsize(self.text, line, self.font, self.max_w, self.m);
        }
        self.index += 1;
        self.pos = line.next;
        if (line.next >= self.text.len and !line.hard_break) self.done = true;
        return line;
    }
};

pub const Measured = struct { w: f32, h: f32, lines: u32 };

/// Height-for-width: the widest visible line, `lines * line_height`.
/// Non-increasing in `max_w` for `lines` (greedy wrapping is monotone).
pub fn measureWrapped(text: []const u8, font: FontSpec, max_w: f32, mode: Wrap, max_lines: u32, m: TextMeasurer) Measured {
    var it = LineIter.init(text, font, max_w, mode, max_lines, m);
    var w: f32 = 0;
    var n: u32 = 0;
    while (it.next()) |l| {
        w = @max(w, l.width);
        n += 1;
    }
    return .{ .w = w, .h = @as(f32, @floatFromInt(n)) * lineHeight(font, m), .lines = n };
}

/// Width of the widest unbreakable segment (the narrowest width that does not
/// force a mid-token cut is this; layout uses it as the shrink floor).
pub fn minContent(text: []const u8, font: FontSpec, m: TextMeasurer) f32 {
    var br = linebreak.Breaker.init(text, 0);
    var best: f32 = 0;
    var seg_start: usize = 0;
    while (br.next()) |b| {
        const tr = trimSegment(text, seg_start, b.end);
        best = @max(best, widthOf(text[seg_start..tr.content], font, m));
        seg_start = b.end;
    }
    return best;
}

/// Min-content width for a wrap mode: the narrowest width layout may shrink
/// the text to. `.word` = widest unbreakable segment, `.char` = widest
/// grapheme, `.ellipsis` = the ellipsis glyph, `.none` = never shrinks.
pub fn minContentFor(text: []const u8, font: FontSpec, mode: Wrap, m: TextMeasurer) f32 {
    switch (mode) {
        .none => return maxContent(text, font, m),
        .word => return minContent(text, font, m),
        .ellipsis => return widthOf(ELLIPSIS, font, m),
        .char => {
            var best: f32 = 0;
            var p: usize = 0;
            while (p < text.len) {
                const e = unicode.nextGrapheme(text, p);
                best = @max(best, widthOf(text[p..e], font, m));
                p = e;
            }
            return best;
        },
    }
}

/// Unwrapped width of the longest hard line.
pub fn maxContent(text: []const u8, font: FontSpec, m: TextMeasurer) f32 {
    var best: f32 = 0;
    var pos: usize = 0;
    while (true) {
        const l = nextLine(text, pos, font, std.math.inf(f32), .none, m);
        best = @max(best, l.width);
        if (l.next >= text.len and !l.hard_break) break;
        pos = l.next;
    }
    return best;
}

pub const Caret = struct { x: f32, y: f32, line: u32 };

/// Caret position (relative to the text origin) of byte offset `index`, which
/// should be a grapheme boundary; other values are clamped to the text. At a
/// soft wrap the caret sits at the start of the following line. Offsets past
/// the visible lines (`max_lines`) or past the content of an ellipsized line
/// clamp to the visible end.
pub fn caretPos(text: []const u8, index: usize, font: FontSpec, max_w: f32, mode: Wrap, max_lines: u32, m: TextMeasurer) Caret {
    const idx = @min(index, text.len);
    var it = LineIter.init(text, font, max_w, mode, max_lines, m);
    var cur = it.next().?;
    var li: u32 = 0;
    while (true) {
        const nxt = it.next();
        if (idx < cur.next or nxt == null) break;
        cur = nxt.?;
        li += 1;
    }
    const limit: usize = if (cur.ellipsized) cur.end else cur.hang;
    const at = std.math.clamp(idx, cur.start, @max(limit, cur.start));
    return .{
        .x = widthOf(text[cur.start..at], font, m),
        .y = @as(f32, @floatFromInt(li)) * lineHeight(font, m),
        .line = li,
    };
}

/// Byte offset of the grapheme boundary nearest to the point `(x, y)` in the
/// same coordinates as `caretPos`; `y` picks the line (clamped), `x` the
/// boundary on it (ties go left). Inverse of `caretPos` at every boundary.
pub fn indexAt(text: []const u8, x: f32, y: f32, font: FontSpec, max_w: f32, mode: Wrap, max_lines: u32, m: TextMeasurer) usize {
    const lh = lineHeight(font, m);
    const want: u32 = if (y <= 0 or lh <= 0) 0 else @intFromFloat(@min(y / lh, 1.0e9));
    var it = LineIter.init(text, font, max_w, mode, max_lines, m);
    var cur = it.next().?;
    var li: u32 = 0;
    var is_last = false;
    while (li < want) {
        const nxt = it.next() orelse {
            is_last = true;
            break;
        };
        cur = nxt;
        li += 1;
    }
    if (!is_last) is_last = blk: {
        // Peek: is there another visible line after `cur`?
        var probe = it;
        break :blk probe.next() == null;
    };
    // Candidate boundaries: start .. limit. At a soft wrap the line's visible
    // end is the next line's start; leave that index to the next line.
    var limit: usize = if (cur.ellipsized) cur.end else cur.hang;
    if (!is_last and !cur.hard_break and !cur.ellipsized and limit == cur.next and limit > cur.start) {
        limit = unicode.prevGrapheme(text, limit);
    }
    var best: usize = cur.start;
    var best_d: f32 = @abs(x);
    var p: usize = cur.start;
    while (p < limit) {
        const e = unicode.nextGrapheme(text, p);
        if (e > limit) break;
        const bx = widthOf(text[cur.start..e], font, m);
        const d = @abs(x - bx);
        if (d < best_d) {
            best_d = d;
            best = e;
        }
        if (bx >= x) break;
        p = e;
    }
    return best;
}

// ── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;

fn mono() TextMeasurer {
    return text_mod.monoMeasurer();
}

const F: FontSpec = .{};

fn lineText(text: []const u8, l: Line) []const u8 {
    return text[l.start..l.end];
}

fn expectLines(text: []const u8, max_w: f32, mode: Wrap, max_lines: u32, expected: []const []const u8) !void {
    var it = LineIter.init(text, F, max_w, mode, max_lines, mono());
    var i: usize = 0;
    while (it.next()) |l| : (i += 1) {
        if (i >= expected.len) {
            std.debug.print("extra line {d}: '{s}'\n", .{ i, lineText(text, l) });
            return error.TestExpectedEqual;
        }
        try testing.expectEqualStrings(expected[i], lineText(text, l));
        if (l.ellipsized) try testing.expect(l.width <= max_w);
    }
    try testing.expectEqual(expected.len, i);
}

test "word wrap: greedy, trailing spaces hang" {
    // 10 px per byte: width 80 = 8 chars.
    try expectLines("hello world foo", 80, .word, 0, &.{ "hello", "world", "foo" });
    try expectLines("hello world foo", 110, .word, 0, &.{ "hello world", "foo" });
    try expectLines("ab cd ef", 1000, .word, 0, &.{"ab cd ef"});
    try expectLines("a b c d", 30, .word, 0, &.{ "a b", "c d" });
    var it = LineIter.init("hello world", F, 80, .word, 0, mono());
    const l0 = it.next().?;
    try testing.expectEqual(@as(u32, 5), l0.end);
    try testing.expectEqual(@as(u32, 6), l0.hang);
    try testing.expectEqual(@as(u32, 6), l0.next);
    try testing.expectEqual(@as(f32, 50), l0.width); // trailing space excluded
}

test "word wrap: hard breaks, empty lines, trailing newline" {
    try expectLines("", 100, .word, 0, &.{""});
    try expectLines("a\nb", 100, .word, 0, &.{ "a", "b" });
    try expectLines("a\n\nb", 100, .word, 0, &.{ "a", "", "b" });
    try expectLines("a\n", 100, .word, 0, &.{ "a", "" });
    try expectLines("a\r\nb", 100, .word, 0, &.{ "a", "b" });
    try expectLines("\n", 100, .none, 0, &.{ "", "" });
}

test "word wrap: hyphen, NBSP, CJK kinsoku" {
    try expectLines("well-known fact", 70, .word, 0, &.{ "well-", "known", "fact" });
    try expectLines("aa\u{00A0}bb cc", 70, .word, 0, &.{ "aa\u{00A0}bb", "cc" }); // NBSP is 2 bytes: 60 px, unbreakable
    // 3 bytes per CJK char = 30 px; width 65 fits two ideographs.
    try expectLines("日本語です。", 65, .word, 0, &.{ "日本", "語で", "す。" });
    // 。 cannot start a line: it travels with the preceding char.
    try expectLines("日本語。", 125, .word, 0, &.{"日本語。"});
    try expectLines("日本語。", 95, .word, 0, &.{ "日本", "語。" });
    try expectLines("日本語。", 65, .word, 0, &.{ "日本", "語。" });
    try expectLines("日「本」", 95, .word, 0, &.{ "日", "「本」" });
}

test "word wrap: long token breaks at graphemes, ZWSP breaks" {
    try expectLines("abcdefghij", 40, .word, 0, &.{ "abcd", "efgh", "ij" });
    try expectLines("xx abcdefghij", 40, .word, 0, &.{ "xx", "abcd", "efgh", "ij" });
    // A combining sequence is never split: 'é' (e + U+0301) is 3 bytes = 30 px.
    try expectLines("e\u{0301}e\u{0301}e\u{0301}", 40, .word, 0, &.{ "e\u{0301}", "e\u{0301}", "e\u{0301}" });
    // Narrower than one grapheme: one grapheme per line, no infinite loop.
    try expectLines("abc", 5, .word, 0, &.{ "a", "b", "c" });
    try expectLines("abc", 0, .word, 0, &.{ "a", "b", "c" });
    try expectLines("one\u{200B}two\u{200B}three", 60, .word, 0, &.{ "one\u{200B}two", "three" });
}

test "overlong token's trailing spaces hang instead of forming a blank line" {
    var it = LineIter.init("abcdefgh  x", F, 50, .word, 0, mono());
    var n: usize = 0;
    while (it.next()) |l| : (n += 1) try testing.expect(l.end > l.start);
    try testing.expectEqual(@as(usize, 3), n); // abcde / fgh / x
}

test "char wrap and none" {
    try expectLines("hello world", 50, .char, 0, &.{ "hello", " worl", "d" });
    try expectLines("ab\ncd", 100, .char, 0, &.{ "ab", "cd" });
    try expectLines("hello world", 10, .none, 0, &.{"hello world"});
    try expectLines("a\nb", 10, .none, 0, &.{ "a", "b" });
}

test "ellipsis and max_lines" {
    try expectLines("hello world", 1000, .ellipsis, 0, &.{"hello world"});
    // 8 chars of room = 5 chars + ellipsis (3 bytes = 30 px).
    try expectLines("hello world", 80, .ellipsis, 0, &.{"hello"});
    try expectLines("hello world", 80, .ellipsis, 5, &.{"hello"});
    try expectLines("hi there world", 100, .ellipsis, 0, &.{"hi ther"}); // 7 + ellipsis = 100
    try expectLines("ab cd\nef", 1000, .ellipsis, 0, &.{"ab cd"}); // text remains after the newline
    try expectLines("one two three four", 80, .word, 2, &.{ "one two", "three" }); // exactly fits, ellipsis needs room
    try expectLines("one two three four five", 80, .word, 2, &.{ "one two", "three" });
    var it = LineIter.init("alpha beta gamma delta", F, 100, .word, 2, mono());
    _ = it.next().?;
    const l2 = it.next().?;
    try testing.expect(l2.ellipsized);
    try testing.expect(l2.width <= 100);
    try testing.expectEqual(@as(?Line, null), it.next());
    // Trailing space before the ellipsis is dropped.
    try expectLines("ab cdefgh", 50, .ellipsis, 0, &.{"ab"}); // "ab " + ... would be 60
    // Fits entirely: no ellipsis.
    var it2 = LineIter.init("abc", F, 100, .word, 1, mono());
    try testing.expect(!it2.next().?.ellipsized);
}

test "measureWrapped basics" {
    const r = measureWrapped("hello world foo", F, 80, .word, 0, mono());
    try testing.expectEqual(@as(u32, 3), r.lines);
    try testing.expectEqual(@as(f32, 60), r.h);
    try testing.expectEqual(@as(f32, 50), r.w);
    try testing.expectEqual(@as(u32, 1), measureWrapped("", F, 80, .word, 0, mono()).lines);
    try testing.expectEqual(@as(u32, 2), measureWrapped("a\n", F, 80, .word, 0, mono()).lines);
    try testing.expectEqual(@as(u32, 2), measureWrapped("hello world foo", F, 80, .word, 2, mono()).lines);
    try testing.expectEqual(@as(u32, 1), measureWrapped("hello world foo", F, 80, .ellipsis, 0, mono()).lines);
}

test "minContent and maxContent" {
    try testing.expectEqual(@as(f32, 50), minContent("hello w", F, mono()));
    try testing.expectEqual(@as(f32, 50), minContent("a well-known b", F, mono())); // "well-" = 50, "known" = 50
    try testing.expectEqual(@as(f32, 60), minContent("aa\u{00A0}bb", F, mono())); // 6 bytes
    try testing.expectEqual(@as(f32, 0), minContent("", F, mono()));
    try testing.expectEqual(@as(f32, 80), maxContent("ab\nabcdefgh \nxy", F, mono()));
    try testing.expectEqual(@as(f32, 0), maxContent("", F, mono()));
}

const samples = [_][]const u8{
    "",
    "hello world foo bar baz",
    "a\n\nb c\n",
    "well-known and non\u{2011}breaking, with 日本語の文章。「引用」です。",
    "supercalifragilisticexpialidocious word",
    "e\u{0301}e\u{0301} \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} x\u{200B}y  z",
    "tabs\tand   spaces   here",
    "bad \xFF\xFE bytes \xE2\x82 end",
    "שלום עולם مرحبا",
};

test "measureWrapped is monotone in width (lines non-increasing, height consistent)" {
    for (samples) |s| {
        for ([_]Wrap{ .word, .char, .none }) |mode| {
            for ([_]u32{ 0, 2 }) |ml| {
                var prev: u32 = std.math.maxInt(u32);
                var w: f32 = 0;
                while (w <= 600) : (w += 5) {
                    const r = measureWrapped(s, F, w, mode, ml, mono());
                    testing.expect(r.lines <= prev) catch |e| {
                        std.debug.print("non-monotone: '{s}' mode {s} max_lines {d} w {d}: {d} > {d}\n", .{ s, @tagName(mode), ml, w, r.lines, prev });
                        return e;
                    };
                    try testing.expectEqual(@as(f32, @floatFromInt(r.lines)) * 20, r.h);
                    prev = r.lines;
                }
            }
        }
    }
}

test "lines tile the text and respect the width" {
    for (samples) |s| {
        for ([_]Wrap{ .word, .char }) |mode| {
            var w: f32 = 10;
            while (w <= 300) : (w += 15) {
                var it = LineIter.init(s, F, w, mode, 0, mono());
                var pos: u32 = 0;
                while (it.next()) |l| {
                    try testing.expectEqual(pos, l.start);
                    try testing.expect(l.start <= l.end and l.end <= l.hang and l.hang <= l.next and l.next <= s.len);
                    try testing.expect(unicode.isGraphemeBoundary(s, l.end) and unicode.isGraphemeBoundary(s, l.next));
                    // Too wide only when a single grapheme (or an unbreakable CJK-punctuation cluster pair).
                    if (l.width > w) {
                        const first_end = unicode.nextGrapheme(s, l.start);
                        const second_end = if (first_end < l.end) unicode.nextGrapheme(s, first_end) else first_end;
                        try testing.expect(l.end == first_end or l.end == second_end);
                    }
                    pos = l.next;
                }
                try testing.expectEqual(@as(u32, @intCast(s.len)), pos);
            }
        }
    }
}

test "indexAt(caretPos(i)) == i for every grapheme boundary" {
    for (samples) |s| {
        for ([_]Wrap{ .word, .char, .none }) |mode| {
            var w: f32 = 20;
            while (w <= 300) : (w += 20) {
                var i: usize = 0;
                while (true) {
                    const c = caretPos(s, i, F, w, mode, 0, mono());
                    const back = indexAt(s, c.x, c.y, F, w, mode, 0, mono());
                    testing.expectEqual(i, back) catch |e| {
                        std.debug.print("round trip: '{s}' mode {s} w {d} i {d} -> ({d},{d}) -> {d}\n", .{ s, @tagName(mode), w, i, c.x, c.y, back });
                        return e;
                    };
                    if (i >= s.len) break;
                    i = unicode.nextGrapheme(s, i);
                }
            }
        }
    }
}

test "caretPos / indexAt: concrete positions" {
    const s = "hello world";
    // width 80: "hello " / "world"
    const c0 = caretPos(s, 3, F, 80, .word, 0, mono());
    try testing.expectEqual(@as(f32, 30), c0.x);
    try testing.expectEqual(@as(u32, 0), c0.line);
    const c1 = caretPos(s, 6, F, 80, .word, 0, mono()); // wrap point -> start of line 2
    try testing.expectEqual(@as(f32, 0), c1.x);
    try testing.expectEqual(@as(f32, 20), c1.y);
    const c2 = caretPos(s, 11, F, 80, .word, 0, mono());
    try testing.expectEqual(@as(f32, 50), c2.x);
    try testing.expectEqual(@as(u32, 1), c2.line);
    // Click right of line 1's text lands before the hanging space, left of 'w' lands at 6.
    try testing.expectEqual(@as(usize, 5), indexAt(s, 999, 5, F, 80, .word, 0, mono()));
    try testing.expectEqual(@as(usize, 6), indexAt(s, 2, 25, F, 80, .word, 0, mono()));
    try testing.expectEqual(@as(usize, 11), indexAt(s, 999, 999, F, 80, .word, 0, mono()));
    try testing.expectEqual(@as(usize, 0), indexAt(s, -5, -5, F, 80, .word, 0, mono()));
    // Nearest boundary: x=14 is closer to 10 than to 20; x=16 to 20.
    try testing.expectEqual(@as(usize, 1), indexAt(s, 14, 0, F, 80, .word, 0, mono()));
    try testing.expectEqual(@as(usize, 2), indexAt(s, 16, 0, F, 80, .word, 0, mono()));
    // Out-of-range index clamps.
    try testing.expectEqual(@as(f32, 50), caretPos(s, 999, F, 80, .word, 0, mono()).x);
    // Ellipsized line: caret clamps to the visible end.
    const e = caretPos(s, 9, F, 80, .ellipsis, 0, mono());
    try testing.expectEqual(@as(f32, 50), e.x);
}

test "RTL, invalid UTF-8 and mixed text never crash or escape the text" {
    var prng = std.Random.DefaultPrng.init(0x7E57);
    const rnd = prng.random();
    const pieces = [_][]const u8{ "שלום", " ", "مرحبا", "abc", "\xFF", "\xE2\x82", "日本", "。", "\n", "e\u{0301}", "\u{1F600}", "-" };
    var buf: [200]u8 = undefined;
    var iter: usize = 0;
    while (iter < 300) : (iter += 1) {
        var n: usize = 0;
        for (0..rnd.uintLessThan(usize, 14)) |_| {
            const p = pieces[rnd.uintLessThan(usize, pieces.len)];
            @memcpy(buf[n..][0..p.len], p);
            n += p.len;
        }
        const s = buf[0..n];
        const mode: Wrap = @fromBackingInt(@intCast(rnd.uintLessThan(u8, 4)));
        const w: f32 = @floatFromInt(rnd.uintLessThan(u32, 200));
        const r = measureWrapped(s, F, w, mode, rnd.uintLessThan(u32, 3), mono());
        try testing.expect(r.lines >= 1);
        var i: usize = 0;
        while (true) {
            const c = caretPos(s, i, F, w, mode, 0, mono());
            const back = indexAt(s, c.x, c.y, F, w, mode, 0, mono());
            try testing.expect(back <= s.len and unicode.isGraphemeBoundary(s, back));
            if (mode != .ellipsis) try testing.expectEqual(i, back);
            if (i >= s.len) break;
            i = unicode.nextGrapheme(s, i);
        }
    }
}

test "minContentFor per mode" {
    try testing.expectEqual(@as(f32, 50), minContentFor("hello world", F, .word, mono()));
    try testing.expectEqual(@as(f32, 10), minContentFor("hello world", F, .char, mono()));
    try testing.expectEqual(@as(f32, 30), minContentFor("hello world", F, .ellipsis, mono()));
    try testing.expectEqual(@as(f32, 110), minContentFor("hello world", F, .none, mono()));
    try testing.expectEqual(@as(f32, 30), minContentFor("e\u{0301}", F, .char, mono())); // one cluster
}
