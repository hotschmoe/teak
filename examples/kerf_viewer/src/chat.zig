//! The OPERATOR CONSOLE's data: a bounded message log, the `**bold**` markup
//! and wrapping used to turn a message into `rich_text` lines, and the
//! scripted "Claude" that answers in demo mode (no network, no key).
//!
//! Everything here is plain data and pure functions; the app owns the timing
//! (a `Sub` tick per scripted step) and applies the one UI action a reply
//! carries (switch tab, select a part, ...). The responder is deliberately
//! tiny: it recognises a handful of intents so a designer can poke at the
//! cross-view selection without any model behind it.

const std = @import("std");
const teak = @import("teak");

pub const Role = enum { designer, kerf, tool };

pub const msg_cap = 440;
pub const log_cap = 32;

pub const Message = struct {
    role: Role = .designer,
    /// Number shown in the card header (`#03`); counts every message ever pushed.
    seq: u16 = 0,
    len: u16 = 0,
    text: [msg_cap]u8 = undefined,

    pub fn body(self: *const Message) []const u8 {
        return self.text[0..self.len];
    }
};

/// Bounded log: the oldest message is dropped when full.
pub const Log = struct {
    msgs: [log_cap]Message = undefined,
    n: u8 = 0,
    seq: u16 = 0,

    pub fn push(self: *Log, role: Role, text: []const u8) void {
        if (self.n == log_cap) {
            for (1..log_cap) |i| self.msgs[i - 1] = self.msgs[i];
            self.n -= 1;
        }
        var len = @min(text.len, msg_cap);
        // never cut a UTF-8 sequence in half
        while (len > 0 and len < text.len and (text[len] & 0xC0) == 0x80) len -= 1;
        self.seq +%= 1;
        const m = &self.msgs[self.n];
        m.role = role;
        m.seq = self.seq;
        m.len = @intCast(len);
        @memcpy(m.text[0..len], text[0..len]);
        self.n += 1;
    }

    pub fn at(self: *const Log, i: usize) *const Message {
        return &self.msgs[i];
    }

    pub fn clear(self: *Log) void {
        self.n = 0;
    }
};

// ── Markup + wrapping ─────────────────────────────────────────────

/// One display line: stripped text and its bold spans (indices into `text`).
pub const Line = struct {
    text: []const u8,
    spans: []const teak.RichTextSpan,
};

/// Strip `**bold**` markers and wrap at `cols` columns (a column is a UTF-8
/// code point; the console font is monospace). Breaks at spaces, honours
/// `\n`, and hard-splits words longer than a line. Memory comes from `a`
/// (the frame arena); the lines borrow from one stripped copy of `text`.
pub fn wrapMarkup(a: std.mem.Allocator, text: []const u8, cols: usize, bold: teak.FontSpec, bold_color: [4]f32) []const Line {
    const plain = a.alloc(u8, text.len) catch return &.{};
    const is_bold = a.alloc(bool, text.len) catch return &.{};
    var n: usize = 0;
    var on = false;
    var i: usize = 0;
    while (i < text.len) {
        if (i + 1 < text.len and text[i] == '*' and text[i + 1] == '*') {
            on = !on;
            i += 2;
            continue;
        }
        plain[n] = text[i];
        is_bold[n] = on;
        n += 1;
        i += 1;
    }
    const p = plain[0..n];

    var lines: std.ArrayList(Line) = .empty;
    var start: usize = 0;
    while (start <= p.len) {
        // the hard line ends at the next newline (or the end)
        const nl = std.mem.indexOfScalarPos(u8, p, start, '\n') orelse p.len;
        var s = start;
        while (true) {
            const end = fitLine(p, s, nl, cols);
            lines.append(a, makeLine(a, p, is_bold, s, end, bold, bold_color)) catch return lines.items;
            if (end >= nl) break;
            s = end;
            while (s < nl and p[s] == ' ') s += 1; // the break space is not drawn
            if (s >= nl) break;
        }
        if (nl >= p.len) break;
        start = nl + 1;
    }
    return lines.items;
}

/// End of the line that starts at `s` and may not pass `limit`: at most
/// `cols` code points, broken at the last space inside when there is one.
fn fitLine(p: []const u8, s: usize, limit: usize, cols: usize) usize {
    var count: usize = 0;
    var j = s;
    var last_space: ?usize = null;
    while (j < limit) {
        if (count == cols) {
            return if (last_space) |sp| sp else j;
        }
        if (p[j] == ' ' and j > s) last_space = j;
        j += std.unicode.utf8ByteSequenceLength(p[j]) catch 1;
        count += 1;
    }
    return limit;
}

fn makeLine(a: std.mem.Allocator, p: []const u8, is_bold: []const bool, s: usize, e: usize, bold: teak.FontSpec, bold_color: [4]f32) Line {
    var spans: std.ArrayList(teak.RichTextSpan) = .empty;
    var k = s;
    while (k < e) {
        if (!is_bold[k]) {
            k += 1;
            continue;
        }
        const from = k;
        while (k < e and is_bold[k]) k += 1;
        spans.append(a, .{
            .start = @intCast(from - s),
            .end = @intCast(k - s),
            .color = bold_color,
            .font = bold,
            .bold = true,
        }) catch break;
    }
    return .{ .text = p[s..e], .spans = spans.items };
}

// ── The scripted responder ────────────────────────────────────────

pub const Intent = union(enum) {
    greet,
    help,
    summary,
    view_section,
    view_iso,
    view_3d,
    cut,
    fit,
    /// 1-based part id.
    select: u32,
};

/// What the responder needs to know about the open document.
pub const Context = struct {
    /// Part names in id order (`parts[0]` is id 1).
    parts: []const []const u8,
    sections: usize,
    has_iso: bool,
};

/// Classify a designer message. A mentioned part name wins over everything
/// (the longest name that appears), then the view / action keywords.
pub fn parseIntent(text: []const u8, ctx: Context) Intent {
    var buf: [msg_cap]u8 = undefined;
    const n = @min(text.len, buf.len);
    const low = std.ascii.lowerString(buf[0..n], text[0..n]);

    var best: u32 = 0;
    var best_len: usize = 0;
    for (ctx.parts, 1..) |name, id| {
        if (name.len > best_len and containsWord(low, name)) {
            best = @intCast(id);
            best_len = name.len;
        }
    }
    if (best != 0) return .{ .select = best };
    if (has(low, "iso")) return .view_iso;
    if (has(low, "section")) return .view_section;
    if (has(low, "3d") or has(low, "3-d") or has(low, "model") or has(low, "orbit")) return .view_3d;
    if (has(low, "cut")) return .cut;
    if (has(low, "fit") or has(low, "zoom") or has(low, "reset")) return .fit;
    if (has(low, "help") or has(low, "what can") or has(low, "how")) return .help;
    if (has(low, "hello") or has(low, "hi ") or std.mem.eql(u8, std.mem.trim(u8, low, " \n"), "hi")) return .greet;
    return .summary;
}

fn has(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

/// `needle` (case-insensitive) as a whole identifier: not glued to letters,
/// digits or `_` on either side.
fn containsWord(low: []const u8, name: []const u8) bool {
    var buf: [64]u8 = undefined;
    if (name.len > buf.len) return false;
    const nl = std.ascii.lowerString(buf[0..name.len], name);
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, low, from, nl)) |at| {
        const before_ok = at == 0 or !isIdent(low[at - 1]);
        const after = at + nl.len;
        const after_ok = after >= low.len or !isIdent(low[after]);
        if (before_ok and after_ok) return true;
        from = at + 1;
    }
    return false;
}

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// The tool line shown first (`▸ VIEW  SECTION A  ✓`).
pub fn toolLine(buf: []u8, intent: Intent, part_name: []const u8) []const u8 {
    return switch (intent) {
        .greet, .help => std.fmt.bufPrint(buf, "\u{25B8} HELP  \u{2713}", .{}) catch "",
        .summary => std.fmt.bufPrint(buf, "\u{25B8} INSPECT  SUMMARY  \u{2713}", .{}) catch "",
        .view_section => std.fmt.bufPrint(buf, "\u{25B8} VIEW  SECTION  \u{2713}", .{}) catch "",
        .view_iso => std.fmt.bufPrint(buf, "\u{25B8} VIEW  ISO  \u{2713}", .{}) catch "",
        .view_3d => std.fmt.bufPrint(buf, "\u{25B8} VIEW  3D  \u{2713}", .{}) catch "",
        .cut => std.fmt.bufPrint(buf, "\u{25B8} CUT  3D SECTION  \u{2713}", .{}) catch "",
        .fit => std.fmt.bufPrint(buf, "\u{25B8} FIT  \u{2713}", .{}) catch "",
        .select => std.fmt.bufPrint(buf, "\u{25B8} SELECT  {s}  \u{2713}", .{part_name}) catch "",
    };
}

/// The final answer for `intent` (markup: `**bold**`).
pub fn replyText(buf: []u8, intent: Intent, ctx: Context, detail: []const u8) []const u8 {
    return (switch (intent) {
        .greet => std.fmt.bufPrint(buf, "DEMO MODE: I am a script, not a model. Ask me to show the **section**, the **iso** or the **3D** view, to **cut** the model, or to select a part by name.", .{}),
        .help => std.fmt.bufPrint(buf, "Try: **show the section**, **iso view**, **3d**, **cut**, **fit**, or name a part, for example **{s}**. Hover and click work in every view and share one selection.", .{if (ctx.parts.len > 0) ctx.parts[0] else "beam"}),
        .summary => std.fmt.bufPrint(buf, "**{d} parts**, **{d} section{s}**{s}. {s}", .{
            ctx.parts.len,
            ctx.sections,
            if (ctx.sections == 1) "" else "s",
            if (ctx.has_iso) " and an iso view" else ", no iso view",
            detail,
        }),
        .view_section => std.fmt.bufPrint(buf, "Showing the **section**. Pan with the left button, zoom with the wheel, **FIT** reframes it.", .{}),
        .view_iso => if (ctx.has_iso)
            std.fmt.bufPrint(buf, "Showing the **iso** drawing. Hover a member to outline it and find its row in the parts table.", .{})
        else
            std.fmt.bufPrint(buf, "This document has no iso drawing. Showing the **3D** model with the iso preset instead.", .{}),
        .view_3d => std.fmt.bufPrint(buf, "Showing the **3D** model. Drag to orbit, middle-drag or Shift-drag to pan, wheel to zoom.", .{}),
        .cut => std.fmt.bufPrint(buf, "Cut on, **Y** axis, halfway. Slide the offset, **FLIP** keeps the other side. Caps are manila.", .{}),
        .fit => std.fmt.bufPrint(buf, "Framed the whole view.", .{}),
        .select => std.fmt.bufPrint(buf, "Selected **{s}**. {s}", .{ detail, "It is highlighted in the table, the sheet and the 3D view." }),
    }) catch buf[0..0];
}

// ── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;
const test_bold: teak.FontSpec = .{ .size_px = 13, .family = .mono, .weight = .bold };

test "log: push, truncation on a code point boundary, oldest dropped when full" {
    var log: Log = .{};
    log.push(.designer, "hello");
    try testing.expectEqualStrings("hello", log.at(0).body());
    try testing.expectEqual(@as(u16, 1), log.at(0).seq);
    var big: [msg_cap + 10]u8 = undefined;
    @memset(&big, 'a');
    big[msg_cap - 1] = 0xC3; // a 2-byte sequence straddling the cap
    big[msg_cap] = 0xA9;
    log.push(.kerf, &big);
    try testing.expectEqual(@as(u16, msg_cap - 1), log.at(1).len);
    for (0..log_cap + 3) |_| log.push(.tool, "x");
    try testing.expectEqual(@as(u8, log_cap), log.n);
    try testing.expect(log.at(0).seq > 5);
}

test "wrapMarkup: strips markers, wraps at spaces, bold spans are relative" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const lines = wrapMarkup(arena.allocator(), "one **two three** four five", 10, test_bold, .{ 0, 0, 0, 1 });
    try testing.expectEqual(@as(usize, 3), lines.len);
    try testing.expectEqualStrings("one two", lines[0].text);
    try testing.expectEqual(@as(usize, 1), lines[0].spans.len);
    try testing.expectEqual(@as(u32, 4), lines[0].spans[0].start);
    try testing.expectEqual(@as(u32, 7), lines[0].spans[0].end);
    try testing.expectEqualStrings("three four", lines[1].text);
    try testing.expectEqual(@as(u32, 0), lines[1].spans[0].start);
    try testing.expectEqual(@as(u32, 5), lines[1].spans[0].end);
    try testing.expectEqualStrings("five", lines[2].text);
    try testing.expectEqual(@as(usize, 0), lines[2].spans.len);
}

test "wrapMarkup: newlines, blank lines, long words, empty input" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const l1 = wrapMarkup(a, "a\n\nb", 20, test_bold, .{ 0, 0, 0, 1 });
    try testing.expectEqual(@as(usize, 3), l1.len);
    try testing.expectEqualStrings("", l1[1].text);
    const l2 = wrapMarkup(a, "abcdefghij", 4, test_bold, .{ 0, 0, 0, 1 });
    try testing.expectEqual(@as(usize, 3), l2.len);
    try testing.expectEqualStrings("abcd", l2[0].text);
    try testing.expectEqualStrings("ij", l2[2].text);
    const l3 = wrapMarkup(a, "", 20, test_bold, .{ 0, 0, 0, 1 });
    try testing.expectEqual(@as(usize, 1), l3.len);
    // an unterminated marker bolds to the end
    const l4 = wrapMarkup(a, "x **y", 20, test_bold, .{ 0, 0, 0, 1 });
    try testing.expectEqualStrings("x y", l4[0].text);
    try testing.expectEqual(@as(u32, 2), l4[0].spans[0].start);
}

test "parseIntent: part names win; whole words only; keywords; default" {
    const ctx: Context = .{ .parts = &.{ "beam", "studs", "jack_studs" }, .sections = 1, .has_iso = true };
    try testing.expectEqual(Intent{ .select = 1 }, parseIntent("where is the Beam?", ctx));
    try testing.expectEqual(Intent{ .select = 3 }, parseIntent("select jack_studs", ctx)); // longest, not "studs"
    try testing.expect(parseIntent("beamlike", ctx) == .summary); // glued: not a mention
    try testing.expect(parseIntent("show me the iso", ctx) == .view_iso);
    try testing.expect(parseIntent("section please", ctx) == .view_section);
    try testing.expect(parseIntent("orbit it", ctx) == .view_3d);
    try testing.expect(parseIntent("cut it", ctx) == .cut);
    try testing.expect(parseIntent("help", ctx) == .help);
    try testing.expect(parseIntent("hi", ctx) == .greet);
    try testing.expect(parseIntent("what is this", ctx) == .summary);
}

test "reply text and tool lines fit the message cap" {
    var buf: [msg_cap]u8 = undefined;
    const ctx: Context = .{ .parts = &.{ "beam", "strap" }, .sections = 2, .has_iso = false };
    for ([_]Intent{ .greet, .help, .summary, .view_section, .view_iso, .view_3d, .cut, .fit, .{ .select = 2 } }) |it| {
        const t = replyText(&buf, it, ctx, "strap");
        try testing.expect(t.len > 10 and t.len < msg_cap);
        var tb: [96]u8 = undefined;
        try testing.expect(toolLine(&tb, it, "strap").len > 4);
    }
}
