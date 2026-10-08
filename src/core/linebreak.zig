//! UAX #14 "lite" line-break opportunities over grapheme clusters.
//!
//! Not the full UAX #14 pair table: a reduced class set (`unicode.Lb`) and the
//! rules that matter for UI text -- hard breaks (LF, CR, CRLF, VT/FF, NEL,
//! U+2028/2029), break after spaces and ZWSP, no break at NBSP / NNBSP / U+2011
//! / WORD JOINER, break after hyphen-minus and dashes when a letter follows, CJK
//! ideographs/kana/Hangul syllables breakable on both sides with the kinsoku
//! sets (no line starts with closing/small punctuation, no line ends with an
//! opening bracket), quotes glued to their neighbours, and "alphabetic" runs
//! (letters, digits, most symbols) unbreakable except at spaces. Not handled:
//! dictionary breaking (Thai/Lao/Khmer), number/currency subtleties, and the
//! Korean `keep-all` policy.
//!
//! A break *opportunity* is a byte offset where a line may end; trailing
//! spaces belong to the segment before it (they hang). Breaking is decided per
//! grapheme cluster (class of its first code point), so combining marks and
//! ZWJ sequences never separate.

const std = @import("std");
const unicode = @import("unicode.zig");
const Lb = unicode.Lb;

pub const Kind = enum {
    /// Optional break (line may wrap here).
    soft,
    /// Mandatory break directly after a hard line terminator.
    hard,
    /// End of text (no terminator before it).
    end,
};

pub const Break = struct {
    /// Byte offset of the opportunity (start of the next segment).
    end: usize,
    kind: Kind,
};

const Verdict = enum { none, soft, hard };

/// Walks the break opportunities of `text` starting at a line start `start`
/// (a grapheme boundary). Yields segments in order; the last has kind `.end`
/// (or `.hard` when the text ends in a terminator). Empty remainder yields null.
pub const Breaker = struct {
    text: []const u8,
    pos: usize,
    started: bool = false,
    finished: bool = false,
    a: Lb = .bk,
    a_wide: bool = false,
    /// Class before `a` (start-of-text counts as `.bk`).
    a2: Lb = .bk,
    /// Last class before the current position that was not a space.
    ln: Lb = .bk,

    pub fn init(text: []const u8, start: usize) Breaker {
        return .{ .text = text, .pos = start };
    }

    pub fn next(self: *Breaker) ?Break {
        while (self.pos < self.text.len) {
            const at = self.pos;
            const e = unicode.nextGrapheme(self.text, at);
            const cp = unicode.firstCodepoint(self.text[at..e]);
            const b = unicode.lineBreakClass(cp);
            const b_wide = unicode.isWide(cp);
            const v: Verdict = if (self.started) self.between(b, b_wide) else .none;
            self.a2 = self.a;
            self.a = b;
            self.a_wide = b_wide;
            if (b != .sp) self.ln = b;
            self.started = true;
            self.pos = e;
            switch (v) {
                .none => {},
                .soft => return .{ .end = at, .kind = .soft },
                .hard => return .{ .end = at, .kind = .hard },
            }
        }
        if (self.finished or !self.started) return null;
        self.finished = true;
        const hard = self.a == .bk or self.a == .cr or self.a == .lf;
        return .{ .end = self.text.len, .kind = if (hard) .hard else .end };
    }

    fn between(self: *const Breaker, b: Lb, b_wide: bool) Verdict {
        const a = self.a;
        if (a == .bk or a == .cr or a == .lf) return .hard; // LB4, LB5
        if (b == .bk or b == .cr or b == .lf) return .none; // LB6
        if (b == .sp or b == .zw) return .none; // LB7
        if (self.ln == .zw) return .soft; // LB8: ZW SP* ÷
        if (a == .wj or b == .wj) return .none; // LB11
        if (a == .gl) return .none; // LB12
        if (b == .gl and a != .sp and a != .ba and a != .hy) return .none; // LB12a
        if (b == .no_before or b == .cl) return .none; // LB13 (kinsoku: no line start)
        if (self.ln == .op) return .none; // LB14: OP SP* × (kinsoku: no line end)
        if (self.ln == .qu and b == .op) return .none; // LB15
        if (a == .sp) return .soft; // LB18
        if (a == .qu or b == .qu) return .none; // LB19
        if (b == .ba or b == .hy) return .none; // LB21
        if (a == .hy) {
            // LB20a/LB25: a word-initial hyphen or a hyphen before a digit stays put.
            if (b == .nu) return .none;
            if (self.a2 == .bk or self.a2 == .sp or self.a2 == .zw or self.a2 == .cr or self.a2 == .lf or self.a2 == .hy) return .none;
            return .soft;
        }
        if (a == .ba) return .soft;
        if (b == .op and !b_wide and (a == .other or a == .nu)) return .none; // LB30
        if ((a == .no_before or a == .cl) and !self.a_wide and (b == .other or b == .nu)) return .none; // LB29 etc
        if (a == .id or b == .id) return .soft; // LB31 (ideographs break everywhere)
        if ((a == .other or a == .nu) and (b == .other or b == .nu)) return .none;
        return .soft;
    }
};

/// True for the line terminators `Breaker` treats as mandatory (U+000A, 000B,
/// 000C, 000D, 0085, 2028, 2029) and for the zero-width/space classes that hang
/// off the end of a line (spaces, ZWSP). Used to trim a segment for measuring.
pub fn isTrailing(cp: u21) bool {
    return switch (unicode.lineBreakClass(cp)) {
        .sp, .zw, .bk, .cr, .lf => true,
        else => false,
    };
}

/// True when `cp` is a hard line terminator.
pub fn isTerminator(cp: u21) bool {
    return switch (unicode.lineBreakClass(cp)) {
        .bk, .cr, .lf => true,
        else => false,
    };
}

// ── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;

/// Renders `text` with `|` at soft opportunities and `!` at hard ones (the
/// terminal break at end of text is not marked).
fn mark(buf: []u8, text: []const u8) []const u8 {
    var n: usize = 0;
    var last: usize = 0;
    var it = Breaker.init(text, 0);
    while (it.next()) |br| {
        @memcpy(buf[n..][0 .. br.end - last], text[last..br.end]);
        n += br.end - last;
        last = br.end;
        if (br.end == text.len and br.kind != .hard) continue;
        buf[n] = if (br.kind == .hard) '!' else '|';
        n += 1;
    }
    return buf[0..n];
}

fn expectMarked(text: []const u8, expected: []const u8) !void {
    var buf: [512]u8 = undefined;
    const got = mark(&buf, text);
    testing.expectEqualStrings(expected, got) catch |e| {
        std.debug.print("input: {s}\n", .{text});
        return e;
    };
}

test "golden: Latin, spaces, hyphen, punctuation" {
    try expectMarked("hello world foo", "hello |world |foo");
    try expectMarked("two  spaces", "two  |spaces");
    try expectMarked("well-known fact", "well-|known |fact");
    try expectMarked("a - b", "a |- |b");
    try expectMarked("x-5 -y", "x-5 |-y");
    try expectMarked("foo.bar baz", "foo.bar |baz");
    try expectMarked("(a) b", "(a) |b");
    try expectMarked("( a)", "( a)");
    try expectMarked("\"hi\" there", "\"hi\" |there");
    try expectMarked("en\u{2013}dash x", "en\u{2013}|dash |x");
    try expectMarked("abcdefghijklmnop", "abcdefghijklmnop"); // long token: no opportunity
    try expectMarked("", "");
    try expectMarked("end ", "end ");
}

test "golden: NBSP, WJ and U+2011 never break" {
    try expectMarked("a\u{00A0}b c", "a\u{00A0}b |c");
    try expectMarked("1\u{202F}000 x", "1\u{202F}000 |x");
    try expectMarked("non\u{2011}break x", "non\u{2011}break |x");
    try expectMarked("a\u{2060}b", "a\u{2060}b");
    try expectMarked("a \u{00A0}b", "a |\u{00A0}b"); // break before NBSP after a space is fine
}

test "golden: ZWSP" {
    try expectMarked("a\u{200B}b", "a\u{200B}|b");
    try expectMarked("a\u{200B} b", "a\u{200B} |b");
    try expectMarked("a\u{200B}", "a\u{200B}");
}

test "golden: hard breaks" {
    try expectMarked("a\nb", "a\n!b");
    try expectMarked("a\r\nb", "a\r\n!b");
    try expectMarked("a\rb", "a\r!b");
    try expectMarked("a\n", "a\n!");
    try expectMarked("a\u{2028}b c", "a\u{2028}!b |c");
    try expectMarked("\n\n", "\n!\n!");
}

test "golden: CJK with kinsoku" {
    try expectMarked("日本語です", "日|本|語|で|す");
    try expectMarked("日本。語", "日|本。|語"); // no line starts with 。
    try expectMarked("日本、語", "日|本、|語");
    try expectMarked("日「本」語", "日|「本」|語"); // no line ends with 「 or starts with 」
    try expectMarked("（日本）語", "（日|本）|語");
    try expectMarked("abc日本", "abc|日|本");
    try expectMarked("日本abc def", "日|本|abc |def");
    try expectMarked("あっ。", "あっ。"); // small kana and 。 cannot start a line
    try expectMarked("ー日", "ー|日");
    try expectMarked("日 。", "日 。"); // closing punctuation never starts a line, even after a space
}

test "golden: grapheme clusters are never split" {
    try expectMarked("e\u{0301}e\u{0301} x", "e\u{0301}e\u{0301} |x");
    try expectMarked("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}日", "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}|日");
    try expectMarked("日\u{0301}本", "日\u{0301}|本");
}

test "Breaker from a mid-text start and kinds" {
    var it = Breaker.init("ab cd\nef", 3);
    const b1 = it.next().?;
    try testing.expectEqual(@as(usize, 6), b1.end);
    try testing.expectEqual(Kind.hard, b1.kind);
    const b2 = it.next().?;
    try testing.expectEqual(@as(usize, 8), b2.end);
    try testing.expectEqual(Kind.end, b2.kind);
    try testing.expectEqual(@as(?Break, null), it.next());
    var empty = Breaker.init("abc", 3);
    try testing.expectEqual(@as(?Break, null), empty.next());
}

test "Breaker fuzz: offsets increase, land on grapheme boundaries, end at len" {
    var prng = std.Random.DefaultPrng.init(0xB4EA);
    const rnd = prng.random();
    const pieces = [_][]const u8{ "a", "b", " ", "-", "\n", "日", "。", "「", "\u{00A0}", "\u{200B}", "e\u{0301}", "\xFF", "1", "." };
    var buf: [128]u8 = undefined;
    var iter: usize = 0;
    while (iter < 2000) : (iter += 1) {
        var n: usize = 0;
        const count = rnd.uintLessThan(usize, 20);
        for (0..count) |_| {
            const p = pieces[rnd.uintLessThan(usize, pieces.len)];
            @memcpy(buf[n..][0..p.len], p);
            n += p.len;
        }
        const s = buf[0..n];
        var it = Breaker.init(s, 0);
        var last: usize = 0;
        var saw_end = false;
        while (it.next()) |br| {
            try testing.expect(br.end > last or (br.end == 0 and false));
            try testing.expect(unicode.isGraphemeBoundary(s, br.end));
            last = br.end;
            if (br.end == s.len) saw_end = true;
        }
        try testing.expect(saw_end == (s.len > 0));
    }
}
