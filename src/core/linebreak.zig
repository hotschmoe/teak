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
