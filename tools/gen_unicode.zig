//! Generator for `src/core/unicode_tables.zig`.
//!
//! Not part of the normal build. Run by hand when bumping the Unicode version:
//!
//!   zig run tools/gen_unicode.zig -- <ucd-dir> src/core/unicode_tables.zig
//!
//! `<ucd-dir>` must hold these files from https://www.unicode.org/Public/<ver>/ucd/
//! (flattened into one directory): GraphemeBreakProperty.txt, emoji-data.txt,
//! DerivedCoreProperties.txt (InCB), LineBreak.txt, EastAsianWidth.txt.
//!
//! Output: two run-length tables (`start | value << 21` per change of value,
//! binary-searched at lookup).
//!   grapheme byte = GCB (bits 0-3) | Extended_Pictographic << 4 | InCB << 5
//!   linebreak byte = reduced UAX#14 class (bits 0-3) | East-Asian-wide << 7

const std = @import("std");

const Gcb = enum(u4) { other, cr, lf, control, extend, zwj, ri, prepend, spacing_mark, l, v, t, lv, lvt };
const Incb = enum(u2) { none, consonant, linker, extend };
const Lb = enum(u4) { other, nu, id, sp, zw, bk, cr, lf, gl, wj, ba, hy, op, cl, no_before, qu };

const MAX_CP = 0x110000;

const Range = struct { lo: u32, hi: u32, value: []const u8 };

/// Parses `LO[..HI] ; value ...` lines. `field` selects which `;`-separated
/// field is the value (1 for most files; InCB lines use 2 with field 1 == "InCB").
fn parseRanges(gpa: std.mem.Allocator, text: []const u8, want_incb: bool) ![]Range {
    var out: std.ArrayList(Range) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw[0 .. std.mem.indexOfScalar(u8, raw, '#') orelse raw.len], " \t\r");
        if (line.len == 0) continue;
        var f = std.mem.splitScalar(u8, line, ';');
        const rng = std.mem.trim(u8, f.next().?, " \t");
        var val = std.mem.trim(u8, f.next() orelse continue, " \t");
        if (want_incb) {
            if (!std.mem.eql(u8, val, "InCB")) continue;
            val = std.mem.trim(u8, f.next() orelse continue, " \t");
        }
        var r = std.mem.splitSequence(u8, rng, "..");
        const lo = try std.fmt.parseInt(u32, r.next().?, 16);
        const hi = if (r.next()) |h| try std.fmt.parseInt(u32, h, 16) else lo;
        try out.append(gpa, .{ .lo = lo, .hi = hi, .value = try gpa.dupe(u8, val) });
    }
    return out.toOwnedSlice(gpa);
}

fn readFile(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, name: []const u8) ![]u8 {
    const path = try std.fs.path.join(gpa, &.{ dir, name });
    defer gpa.free(path);
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
}

fn gcbFromName(name: []const u8) !Gcb {
    if (std.mem.eql(u8, name, "Regional_Indicator")) return .ri;
    if (std.mem.eql(u8, name, "SpacingMark")) return .spacing_mark;
    const map = [_]struct { []const u8, Gcb }{
        .{ "CR", .cr },   .{ "LF", .lf },           .{ "Control", .control }, .{ "Extend", .extend },
        .{ "ZWJ", .zwj }, .{ "Prepend", .prepend }, .{ "L", .l },             .{ "V", .v },
        .{ "T", .t },     .{ "LV", .lv },           .{ "LVT", .lvt },
    };
    for (map) |m| if (std.mem.eql(u8, m[0], name)) return m[1];
    return error.UnknownGcb;
}

fn lbFromName(name: []const u8) !Lb {
    const map = [_]struct { []const u8, Lb }{
        .{ "BK", .bk },        .{ "NL", .bk },        .{ "CR", .cr },        .{ "LF", .lf },
        .{ "SP", .sp },        .{ "ZW", .zw },        .{ "WJ", .wj },        .{ "GL", .gl },
        .{ "BA", .ba },        .{ "B2", .ba },        .{ "HY", .hy },        .{ "HH", .hy },
        .{ "OP", .op },        .{ "CL", .cl },        .{ "CP", .cl },        .{ "EX", .no_before },
        .{ "IS", .no_before }, .{ "SY", .no_before }, .{ "NS", .no_before }, .{ "CJ", .no_before },
        .{ "QU", .qu },        .{ "NU", .nu },        .{ "ID", .id },        .{ "EB", .id },
        .{ "EM", .id },        .{ "H2", .id },        .{ "H3", .id },
        // Everything below is "alphabetic-like": no break between two of them.
               .{ "AL", .other },
        .{ "HL", .other },     .{ "AI", .other },     .{ "SA", .other },     .{ "SG", .other },
        .{ "XX", .other },     .{ "CB", .other },     .{ "PR", .other },     .{ "PO", .other },
        .{ "CM", .other },     .{ "ZWJ", .other },    .{ "RI", .other },     .{ "JL", .other },
        .{ "JV", .other },     .{ "JT", .other },     .{ "BB", .other },     .{ "IN", .other },
        .{ "AK", .other },     .{ "AP", .other },     .{ "AS", .other },     .{ "VF", .other },
        .{ "VI", .other },
    };
    for (map) |m| if (std.mem.eql(u8, m[0], name)) return m[1];
    std.debug.print("unknown LineBreak class: {s}\n", .{name});
    return error.UnknownLb;
}

/// Run-length encode `flat` into `start | value << 21` words (one per change of value).
fn runs(gpa: std.mem.Allocator, flat: []const u8) ![]u32 {
    var out: std.ArrayList(u32) = .empty;
    var prev: ?u8 = null;
    for (flat, 0..) |v, cp| {
        if (prev == null or prev.? != v) {
            try out.append(gpa, @as(u32, @intCast(cp)) | @as(u32, v) << 21);
            prev = v;
        }
    }
    return out.toOwnedSlice(gpa);
}

fn emitTable(w: *std.Io.Writer, name: []const u8, table: []const u32) !void {
    try w.print("pub const {s}_runs = [_]u32{{", .{name});
    for (table, 0..) |v, i| {
        if (i % 12 == 0) try w.writeAll("\n   ");
        try w.print(" 0x{x},", .{v});
    }
    try w.writeAll("\n};\n\n");
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) {
        std.debug.print("usage: gen_unicode <ucd-dir> <out.zig>\n", .{});
        std.process.exit(2);
    }
    const dir = args[1];

    const flat_g = try gpa.alloc(u8, MAX_CP);
    @memset(flat_g, 0);
    const flat_l = try gpa.alloc(u8, MAX_CP);
    @memset(flat_l, 0);

    // ── Grapheme_Cluster_Break ──
    const gbp = try readFile(gpa, io, dir, "GraphemeBreakProperty.txt");
    for (try parseRanges(gpa, gbp, false)) |r| {
        const g = try gcbFromName(r.value);
        var c = r.lo;
        while (c <= r.hi) : (c += 1) flat_g[c] = (flat_g[c] & 0xF0) | @backingInt(g);
    }
    // ── Extended_Pictographic ──
    const emoji = try readFile(gpa, io, dir, "emoji-data.txt");
    for (try parseRanges(gpa, emoji, false)) |r| {
        if (!std.mem.eql(u8, r.value, "Extended_Pictographic")) continue;
        var c = r.lo;
        while (c <= r.hi) : (c += 1) flat_g[c] |= 0x10;
    }
    // ── InCB ──
    const dcp = try readFile(gpa, io, dir, "DerivedCoreProperties.txt");
    for (try parseRanges(gpa, dcp, true)) |r| {
        const v: u8 = if (std.mem.eql(u8, r.value, "Consonant")) 1 else if (std.mem.eql(u8, r.value, "Linker")) 2 else if (std.mem.eql(u8, r.value, "Extend")) 3 else return error.UnknownInCB;
        var c = r.lo;
        while (c <= r.hi) : (c += 1) flat_g[c] = (flat_g[c] & 0x9F) | (v << 5);
    }

    // ── Line_Break (defaults from the LineBreak.txt header, then explicit entries) ──
    const id_default = [_][2]u32{
        .{ 0x3400, 0x4DBF },   .{ 0x4E00, 0x9FFF },   .{ 0xF900, 0xFAFF },   .{ 0x20000, 0x2FFFD },
        .{ 0x30000, 0x3FFFD }, .{ 0x1F000, 0x1FAFF }, .{ 0x1FC00, 0x1FFFD },
    };
    for (id_default) |r| {
        var c = r[0];
        while (c <= r[1]) : (c += 1) flat_l[c] = @backingInt(Lb.id);
    }
    const lbt = try readFile(gpa, io, dir, "LineBreak.txt");
    for (try parseRanges(gpa, lbt, false)) |r| {
        const l = try lbFromName(r.value);
        var c = r.lo;
        while (c <= r.hi) : (c += 1) flat_l[c] = (flat_l[c] & 0x80) | @backingInt(l);
    }
    // ── East Asian Width: W / F set bit 7 ──
    const wide_default = [_][2]u32{
        .{ 0x3400, 0x4DBF }, .{ 0x4E00, 0x9FFF }, .{ 0xF900, 0xFAFF }, .{ 0x20000, 0x2FFFD }, .{ 0x30000, 0x3FFFD },
    };
    for (wide_default) |r| {
        var c = r[0];
        while (c <= r[1]) : (c += 1) flat_l[c] |= 0x80;
    }
    const eaw = try readFile(gpa, io, dir, "EastAsianWidth.txt");
    for (try parseRanges(gpa, eaw, false)) |r| {
        const wide = std.mem.eql(u8, r.value, "W") or std.mem.eql(u8, r.value, "F");
        var c = r.lo;
        while (c <= r.hi) : (c += 1) flat_l[c] = if (wide) flat_l[c] | 0x80 else flat_l[c] & 0x7F;
    }

    const pg = try runs(gpa, flat_g);
    const pl = try runs(gpa, flat_l);

    var aw: std.Io.Writer.Allocating = .init(gpa);
    const w = &aw.writer;
    try w.writeAll(
        \\//! GENERATED by tools/gen_unicode.zig -- do not edit by hand.
        \\//!
        \\//! Derived from the Unicode Character Database (GraphemeBreakProperty.txt,
        \\//! emoji-data.txt, DerivedCoreProperties.txt [InCB], LineBreak.txt,
        \\//! EastAsianWidth.txt), Unicode 16.0.0.
        \\//! Copyright (c) 1991-2024 Unicode, Inc. All rights reserved. Distributed under
        \\//! the Terms of Use in https://www.unicode.org/copyright.html (Unicode License
        \\//! v3): the data files and any derived software may be used and distributed
        \\//! provided this copyright and permission notice appear in all copies.
        \\//!
        \\//!   Each table is a run list: `start | value << 21`; value byte layout:
        \\//!   grapheme byte  = Gcb (bits 0-3) | Extended_Pictographic << 4 | Incb << 5
        \\//!   linebreak byte = Lb  (bits 0-3) | East-Asian-wide << 7
        \\
        \\pub const Gcb = enum(u4) { other, cr, lf, control, extend, zwj, ri, prepend, spacing_mark, l, v, t, lv, lvt };
        \\pub const Incb = enum(u2) { none, consonant, linker, extend };
        \\/// Reduced UAX #14 classes ("lite"): see core/linebreak.zig for the mapping rationale.
        \\pub const Lb = enum(u4) { other, nu, id, sp, zw, bk, cr, lf, gl, wj, ba, hy, op, cl, no_before, qu };
        \\
        \\/// Value byte for `cp`: binary search for the last run starting at or before it.
        \\pub fn lookup(runs: []const u32, cp: u32) u8 {
        \\    var lo: usize = 0;
        \\    var hi: usize = runs.len;
        \\    while (hi - lo > 1) {
        \\        const mid = (lo + hi) / 2;
        \\        if ((runs[mid] & 0x1FFFFF) <= cp) lo = mid else hi = mid;
        \\    }
        \\    return @intCast(runs[lo] >> 21);
        \\}
        \\
        \\
    );
    try emitTable(w, "grapheme", pg);
    try emitTable(w, "linebreak", pl);
    std.debug.print("grapheme: {d} runs ({d} bytes); linebreak: {d} runs ({d} bytes)\n", .{ pg.len, pg.len * 4, pl.len, pl.len * 4 });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[2], .data = aw.written() });
}
