//! Fixed-column monospace tables, as pure helpers.
//!
//! A monospace font makes columns free: pad every cell to its column's
//! character width and the cells line up with no pixel widths, no fixed-width
//! groups and no per-frame measurement. This module is the string half
//! (`fitCell`: truncate with an ellipsis, pad by alignment) plus a small row
//! emitter that turns a `Table` + cell strings into one horizontal group of
//! `text` cmds per row. Header and body rows share the same `Table`, so they
//! cannot drift apart.
//!
//! Like everything on the view side it allocates only from the per-frame
//! arena (`cb.arena`): the padded strings live until the next `reset`. No
//! state, no callbacks (HARDLINE §1/§3); layout, hit-test and render see
//! ordinary groups and text.
//!
//! "Width" is counted in UTF-8 code points, one column each. That is right
//! for a monospace face with single-width glyphs (Latin, box drawing, the
//! ellipsis); wide CJK / combining sequences are out of scope.

const std = @import("std");
const text_mod = @import("text.zig");
const Allocator = std.mem.Allocator;

/// The default truncation marker: one column in IBM Plex Mono and most
/// monospace faces. (Under `monoMeasurer`, which counts bytes, it measures 3.)
pub const ELLIPSIS = "\u{2026}";

pub const CellAlign = enum { left, right, center };

pub const Column = struct {
    /// Header text; empty = blank header cell.
    title: []const u8 = "",
    /// Content width in characters (excluding the inter-column gutter).
    chars: u16,
    cell_align: CellAlign = .left,
};

/// How one emitted row looks. Use a different `RowStyle` per row kind
/// (header, body, selected, added/removed in a diff).
pub const RowStyle = struct {
    font: text_mod.FontSpec = .{ .family = .mono },
    color: [4]f32 = .{ 0.92, 0.92, 0.94, 1.0 },
    /// Row background (selection highlight, header band); null = none.
    bg: ?[4]f32 = null,
    /// Color of a 1px rule drawn under the row; null = no rule.
    rule: ?[4]f32 = null,
    pad_x: f32 = 4,
    pad_y: f32 = 2,
    /// Fixed outer row height; 0 = the text height plus padding.
    height: f32 = 0,
};

pub const Table = struct {
    columns: []const Column,
    /// Blank characters between columns.
    gutter: u8 = 1,
    /// Appended when a cell is cut; pass "" or "~" to taste.
    ellipsis: []const u8 = ELLIPSIS,

    /// Characters in one full row (cells plus gutters).
    pub fn totalChars(self: Table) usize {
        var n: usize = 0;
        for (self.columns, 0..) |c, i| {
            n += c.chars;
            if (i + 1 < self.columns.len) n += self.gutter;
        }
        return n;
    }

    /// Emit the header row: each column's `title` in `style`.
    pub fn header(self: Table, cb: anytype, style: RowStyle) void {
        self.emitRow(cb, null, style);
    }

    /// Emit one body row. `cells[i]` goes in column `i`; missing cells are
    /// blank, extra cells are ignored.
    pub fn row(self: Table, cb: anytype, cells: []const []const u8, style: RowStyle) void {
        self.emitRow(cb, cells, style);
    }

    fn emitRow(self: Table, cb: anytype, cells: ?[]const []const u8, style: RowStyle) void {
        const arena = cb.arena.allocator();
        cb.pushGroup(.{
            .direction = .horizontal,
            .padding = 0,
            .pad_x = style.pad_x,
            .pad_y = style.pad_y,
            .gap = 0,
            .height = style.height,
            .bg = style.bg,
        });
        for (self.columns, 0..) |col, i| {
            const raw: []const u8 = if (cells) |cs| (if (i < cs.len) cs[i] else "") else col.title;
            const gutter: usize = if (i + 1 < self.columns.len) self.gutter else 0;
            const cell = fitCell(arena, raw, col.chars, col.cell_align, self.ellipsis, gutter) catch unreachable;
            cb.textStyled(cell, style.font, style.color);
        }
        cb.popGroup();
        if (style.rule) |c| cb.dividerStyled(.{ .thickness = 1, .color = c });
    }
};

/// Number of columns `s` occupies: one per UTF-8 code point (an invalid
/// byte counts as one).
pub fn columns(s: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (n += 1) i += seqLen(s, i);
    return n;
}

/// Byte length of the first `cols` columns of `s` (all of it if shorter).
pub fn prefixBytes(s: []const u8, cols: usize) usize {
    var i: usize = 0;
    var n: usize = 0;
    while (i < s.len and n < cols) : (n += 1) i += seqLen(s, i);
    return i;
}

fn seqLen(s: []const u8, i: usize) usize {
    const n = std.unicode.utf8ByteSequenceLength(s[i]) catch return 1;
    return @min(@as(usize, n), s.len - i);
}

/// `text` forced to exactly `width` columns, plus `trailing` blank columns,
/// in a fresh allocation: padded by `al` when short, cut and ended with
/// `ellipsis` when long (never splitting a multi-byte character). If
/// `ellipsis` itself is wider than `width` it is cut to fit.
pub fn fitCell(
    alloc: Allocator,
    s: []const u8,
    width: usize,
    al: CellAlign,
    ellipsis: []const u8,
    trailing: usize,
) Allocator.Error![]u8 {
    const have = columns(s);
    if (have <= width) {
        const pad = width - have;
        const lead: usize = switch (al) {
            .left => 0,
            .right => pad,
            .center => pad / 2,
        };
        const out = try alloc.alloc(u8, lead + s.len + (pad - lead) + trailing);
        @memset(out[0..lead], ' ');
        @memcpy(out[lead..][0..s.len], s);
        @memset(out[lead + s.len ..], ' ');
        return out;
    }

    const ell_cols = @min(columns(ellipsis), width);
    const ell_bytes = prefixBytes(ellipsis, ell_cols);
    const keep_bytes = prefixBytes(s, width - ell_cols);
    const out = try alloc.alloc(u8, keep_bytes + ell_bytes + trailing);
    @memcpy(out[0..keep_bytes], s[0..keep_bytes]);
    @memcpy(out[keep_bytes..][0..ell_bytes], ellipsis[0..ell_bytes]);
    @memset(out[keep_bytes + ell_bytes ..], ' ');
    return out;
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

fn expectFit(expected: []const u8, s: []const u8, width: usize, al: CellAlign) !void {
    const got = try fitCell(testing.allocator, s, width, al, "~", 0);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

test "fitCell pads by alignment" {
    try expectFit("ab   ", "ab", 5, .left);
    try expectFit("   ab", "ab", 5, .right);
    try expectFit(" ab  ", "ab", 5, .center);
    try expectFit("abcde", "abcde", 5, .left);
    try expectFit("", "", 0, .left);
    try expectFit("   ", "", 3, .right);
}

test "fitCell truncates with an ellipsis to exactly the width" {
    try expectFit("abcd~", "abcdefgh", 5, .left);
    try expectFit("abcd~", "abcdefgh", 5, .right); // a cut cell fills the column
    try expectFit("~", "abc", 1, .left);
    try expectFit("", "abc", 0, .left);
}

test "fitCell: multi-byte characters count as one column and are never split" {
    const got = try fitCell(testing.allocator, "h\u{e9}llo w\u{f6}rld", 6, .left, "\u{2026}", 0);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("h\u{e9}llo\u{2026}", got);
    try testing.expectEqual(@as(usize, 6), columns(got));

    try expectFit("\u{e9}   ", "\u{e9}", 4, .left);
    // A truncated or invalid trailing sequence is one column, not a crash.
    try testing.expectEqual(@as(usize, 2), columns("a\xe2"));
}

test "fitCell: an ellipsis wider than the cell is cut to fit" {
    const got = try fitCell(testing.allocator, "abcdef", 2, .left, "...", 0);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("..", got);
}

test "fitCell appends trailing gutter blanks" {
    const got = try fitCell(testing.allocator, "ab", 3, .left, "~", 2);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("ab   ", got);
}

test "Table.totalChars counts cells and gutters" {
    const t: Table = .{ .columns = &.{ .{ .chars = 10 }, .{ .chars = 4 }, .{ .chars = 6 } }, .gutter = 2 };
    try testing.expectEqual(@as(usize, 10 + 2 + 4 + 2 + 6), t.totalChars());
}

const cmd = @import("cmd.zig");
const layout = @import("../layout/engine.zig");
const snapshot = @import("snapshot.zig");

test "golden: header + rows line up; long cells truncate; rule + bg emit" {
    const Msg = union(enum) { a };
    var cb = cmd.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    const parts: Table = .{
        .columns = &.{
            .{ .title = "PART", .chars = 8 },
            .{ .title = "QTY", .chars = 3, .cell_align = .right },
        },
        .ellipsis = "~",
    };
    const head: RowStyle = .{ .rule = .{ 0, 0, 0, 1 }, .bg = .{ 0.9, 0.9, 0.9, 1 } };
    const body: RowStyle = .{};

    cb.pushGroup(.{ .padding = 0, .gap = 0, .align_cross = .stretch });
    parts.header(&cb, head);
    parts.row(&cb, &.{ "bolt", "4" }, body);
    parts.row(&cb, &.{ "washer-flange", "12" }, body);
    parts.row(&cb, &.{"nut"}, body); // missing cell -> blank
    cb.popGroup();

    var rects: [32]layout.Rect = undefined;
    const n = cb.cmds.items.len;
    layout.LayoutEngine.doLayout(rects[0..n], cb.cmds.items, 300, 200, text_mod.monoMeasurer());
    // 8 + gutter 1 + 3 = 12 chars; each cell is its own text cmd (col 0 includes the gutter).
    try snapshot.expectSnapshot(cb.cmds.items, rects[0..n], .{},
        \\group (0,0,300,200) vertical
        \\  group (0,0,300,24) horizontal bg
        \\    text (4,2,90,20) "PART     "
        \\    text (94,2,30,20) "QTY"
        \\  divider (0,24,300,1)
        \\  group (0,25,300,24) horizontal
        \\    text (4,27,90,20) "bolt     "
        \\    text (94,27,30,20) "  4"
        \\  group (0,49,300,24) horizontal
        \\    text (4,51,90,20) "washer-~ "
        \\    text (94,51,30,20) " 12"
        \\  group (0,73,300,24) horizontal
        \\    text (4,75,90,20) "nut      "
        \\    text (94,75,30,20) "   "
        \\
    );
}
