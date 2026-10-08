//! Face-table tests for the native text backend, against the real IBM Plex
//! Mono files (registered through anonymous build imports, so no system font
//! is needed). IBM Plex Mono is monospaced at 600 units per 1000 em, which
//! makes the expected widths exact.

const std = @import("std");
const teak = @import("teak");
const text = @import("teak-text");

const regular = @embedFile("plex-regular");
const medium = @embedFile("plex-medium");
const bold = @embedFile("plex-bold");

fn registerAll() !void {
    try text.registerFace(.mono, .regular, regular);
    try text.registerFace(.mono, .medium, medium);
    try text.registerFace(.mono, .bold, bold);
}

fn inkTotal(rast: *text.StbttRasterizer, weight: teak.FontWeight) !u64 {
    const r = text.face.resolveFace(.mono, weight) orelse return error.NoFace;
    var sum: u64 = 0;
    for ("MMMM") |ch| {
        const bmp = rast.rasterizeGlyph(r.id, r.face.glyphIndex(ch), 24, 0) orelse return error.RasterizeFailed;
        for (bmp.pixels) |p| sum += p;
    }
    return sum;
}

test "every weight advances 0.6 em per character, whatever the glyph" {
    defer text.releaseFaces();
    try registerAll();
    for ([_]teak.FontWeight{ .regular, .medium, .bold }) |w| {
        for ([_][]const u8{ "iiiiiiiiii", "WWWWWWWWWW", "0123456789" }) |run| {
            const m = text.measure(run, .{ .size_px = 20, .family = .mono, .weight = w });
            try std.testing.expectApproxEqAbs(@as(f32, 10 * 0.6 * 20), m.width, 0.01);
        }
    }
}

test "letter spacing adds to every character, the last included" {
    defer text.releaseFaces();
    try registerAll();
    const plain = text.measure("abcd", .{ .size_px = 20, .family = .mono, .snap_advance = false }).width;
    const spaced = text.measure("abcd", .{ .size_px = 20, .family = .mono, .letter_spacing = 1.5, .snap_advance = false }).width;
    try std.testing.expectApproxEqAbs(plain + 6, spaced, 0.001);
}

test "bold paints more ink than regular (the rasterizer picks the face by weight)" {
    defer text.releaseFaces();
    try registerAll();
    var rast = try text.StbttRasterizer.init(std.testing.allocator);
    defer rast.deinit();
    const r = try inkTotal(&rast, .regular);
    const m = try inkTotal(&rast, .medium);
    const b = try inkTotal(&rast, .bold);
    try std.testing.expect(r > 0);
    try std.testing.expect(m > r);
    try std.testing.expect(b > m);
}

test "a weight that is not registered takes the nearest one, the lighter on a tie" {
    defer text.releaseFaces();
    try text.registerFace(.mono, .regular, regular);
    try text.registerFace(.mono, .bold, bold);
    try std.testing.expectEqual(text.faceFor(.mono, .regular), text.faceFor(.mono, .medium));
    try std.testing.expect(text.faceFor(.mono, .bold) != text.faceFor(.mono, .regular));

    text.releaseFaces();
    try text.registerFace(.mono, .bold, bold);
    try std.testing.expectEqual(text.faceFor(.mono, .bold), text.faceFor(.mono, .regular));
}

test "garbage bytes are rejected" {
    defer text.releaseFaces();
    try std.testing.expectError(error.FontInitFailed, text.registerFace(.mono, .regular, "not a font"));
}

// ── Shaper tests (tests/fonts: OFL subsets, see tests/fonts/README.md) ──

const mono_sub = @embedFile("test-font-IBMPlexMonoSub-Regular");
const prop = @embedFile("test-font-QuicksandSub-Regular");
const prop_nolig = @embedFile("test-font-QuicksandSub-NoLig");

fn sumAdvances(gs: []const teak.ShapedGlyph) f32 {
    var s: f32 = 0;
    for (gs) |g| s += g.advance;
    return s;
}

test "kerning: AV is narrower than A + V" {
    defer text.releaseFaces();
    try text.registerFace(.sans, .regular, prop);
    const f: teak.FontSpec = .{ .size_px = 40, .family = .sans };
    const av = text.measure("AV", f).width;
    const apart = text.measure("A", f).width + text.measure("V", f).width;
    try std.testing.expect(av < apart - 0.5);
    // Kerning lives in the first glyph's advance and x stays a running pen.
    var out: [8]teak.ShapedGlyph = undefined;
    const r = text.SimpleShaper.shape("AV", f, &out);
    try std.testing.expectEqual(@as(usize, 2), r.count);
    try std.testing.expectApproxEqAbs(out[0].advance, out[1].x, 1e-4);
    try std.testing.expectApproxEqAbs(sumAdvances(out[0..r.count]), r.width, 1e-4);
}

test "ligatures: fi/fl rewrite when the face has them, not otherwise" {
    defer text.releaseFaces();
    var out: [8]teak.ShapedGlyph = undefined;
    const f: teak.FontSpec = .{ .size_px = 20, .family = .sans };

    try text.registerFace(.sans, .regular, prop);
    const lig = text.SimpleShaper.shape("fi", f, &out);
    try std.testing.expectEqual(@as(usize, 1), lig.count);
    try std.testing.expectEqual(@as(usize, 2), lig.consumed);
    const fl = text.SimpleShaper.shape("afl", f, &out);
    try std.testing.expectEqual(@as(usize, 2), fl.count);
    // ffi has no glyph in the subset: ff falls back to f + fi.
    const ffi = text.SimpleShaper.shape("ffi", f, &out);
    try std.testing.expectEqual(@as(usize, 2), ffi.count);
    try std.testing.expectEqual(@as(u32, 1), out[1].cluster);
    // letter_spacing disables ligatures.
    var spaced = f;
    spaced.letter_spacing = 1;
    try std.testing.expectEqual(@as(usize, 2), text.SimpleShaper.shape("fi", spaced, &out).count);

    text.releaseFaces();
    try text.registerFace(.sans, .regular, prop_nolig);
    try std.testing.expectEqual(@as(usize, 2), text.SimpleShaper.shape("fi", f, &out).count);
}

test "monospace never ligates and snap makes every advance integral" {
    defer text.releaseFaces();
    try text.registerFace(.mono, .regular, mono_sub);
    var out: [64]teak.ShapedGlyph = undefined;
    var f: teak.FontSpec = .{ .size_px = 13, .family = .mono, .snap_advance = true };
    const r = text.SimpleShaper.shape("fi fl ffi the quick", f, &out);
    try std.testing.expectEqual(@as(usize, 19), r.count);
    for (out[0..r.count]) |g| try std.testing.expectEqual(@round(g.advance), g.advance);
    f.snap_advance = false;
    _ = text.SimpleShaper.shape("i", f, &out);
    try std.testing.expectApproxEqAbs(@as(f32, 7.8), out[0].advance, 0.01);
}

test "measure equals the sum of shaped advances, across chunk seams" {
    defer text.releaseFaces();
    try text.registerFace(.sans, .regular, prop);
    const f: teak.FontSpec = .{ .size_px = 15, .family = .sans };
    const run = comptime blk: {
        var s: []const u8 = "";
        for (0..40) |_| s = s ++ "AVATAR fi To Wa ";
        break :blk s; // 640 glyphs: three chunks
    };
    var out: [1024]teak.ShapedGlyph = undefined;
    const r = text.SimpleShaper.shape(run, f, &out);
    try std.testing.expectEqual(run.len, r.consumed);
    try std.testing.expectApproxEqAbs(sumAdvances(out[0..r.count]), r.width, 1e-2);
    // Chunked measure agrees with the single pass (kerning across the seam kept).
    try std.testing.expectApproxEqAbs(r.width, text.measure(run, f).width, 0.05);
}

test "buffer full resumes on a cluster boundary" {
    defer text.releaseFaces();
    try text.registerFace(.sans, .regular, prop);
    const f: teak.FontSpec = .{ .size_px = 20, .family = .sans };
    var small: [3]teak.ShapedGlyph = undefined;
    const r = text.SimpleShaper.shape("héllo", f, &small);
    try std.testing.expectEqual(@as(usize, 3), r.count);
    try std.testing.expect(r.consumed < "héllo".len);
}

test "invalid UTF-8 never reads out of bounds (10k random strings)" {
    defer text.releaseFaces();
    try text.registerFace(.sans, .regular, prop);
    var prng = std.Random.DefaultPrng.init(0xf00d);
    const rnd = prng.random();
    var buf: [64]u8 = undefined;
    var out: [16]teak.ShapedGlyph = undefined;
    const f: teak.FontSpec = .{ .size_px = 14, .family = .sans };
    var iter: usize = 0;
    while (iter < 10_000) : (iter += 1) {
        const n = rnd.uintLessThan(usize, buf.len + 1);
        rnd.bytes(buf[0..n]);
        // Bias toward UTF-8 lead/continuation bytes and truncated tails.
        if (n > 0 and iter % 3 == 0) buf[n - 1] = 0xE2;
        var pos: usize = 0;
        while (pos < n) {
            const r = text.SimpleShaper.shape(buf[pos..n], f, &out);
            try std.testing.expect(r.consumed > 0 and r.consumed <= n - pos);
            for (out[0..r.count]) |g| try std.testing.expect(g.cluster < n - pos);
            pos += r.consumed;
        }
        _ = text.measure(buf[0..n], f);
    }
}

test "invalid bytes become one replacement unit each" {
    defer text.releaseFaces();
    try text.registerFace(.mono, .regular, mono_sub);
    var out: [8]teak.ShapedGlyph = undefined;
    const f: teak.FontSpec = .{ .size_px = 10, .family = .mono };
    const r = text.SimpleShaper.shape("a\xff\xfeb\xe2\x82", f, &out);
    try std.testing.expectEqual(@as(usize, 6), r.count); // a, bad, bad, b, bad, bad
    try std.testing.expectEqual(@as(usize, 6), r.consumed);
}

test "unmapped full-width code points advance one em" {
    defer text.releaseFaces();
    try text.registerFace(.mono, .regular, mono_sub);
    const f: teak.FontSpec = .{ .size_px = 20, .family = .mono, .snap_advance = false };
    try std.testing.expectApproxEqAbs(@as(f32, 20), text.measure("\u{6F22}", f).width, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 12), text.measure("a", f).width, 0.001);
    // An unmapped narrow code point keeps the face's missing-glyph advance.
    try std.testing.expect(text.measure("\u{00E9}", f).width < 19);
}

const marks = @embedFile("test-font-IBMPlexMonoMarks");

test "combining mark: zero advance, so cafe + U+0301 measures like café" {
    defer text.releaseFaces();
    try text.registerFace(.mono, .regular, marks);
    const f: teak.FontSpec = .{ .size_px = 20, .family = .mono, .snap_advance = false };
    const decomposed = text.measure("cafe\u{301}", f).width;
    const composed = text.measure("caf\u{e9}", f).width;
    try std.testing.expectApproxEqAbs(composed, decomposed, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 48), decomposed, 0.001); // 4 x 0.6 em
    // The accent glyph sits centred over the e (glyph 3), not after it.
    var out: [8]teak.ShapedGlyph = undefined;
    const r = text.SimpleShaper.shape("cafe\u{301}", f, &out);
    try std.testing.expectEqual(@as(usize, 5), r.count);
    try std.testing.expectEqual(@as(f32, 0), out[4].advance);
    const e = out[3];
    const rf = text.face.resolveFace(.mono, .regular).?;
    const ink_mid = out[4].x + rf.face.inkCenterUnits(out[4].glyph) * rf.face.scaleForEm(20);
    try std.testing.expectApproxEqAbs(e.x + e.advance * 0.5, ink_mid, 0.01);
    // A mark with no base, or one the face lacks, adds no width and no box.
    try std.testing.expectApproxEqAbs(@as(f32, 12), text.measure("\u{301}a", f).width, 0.001);
    // A mark the face lacks: drawn from a fallback face when one has it (system
    // fonts differ per machine), always at zero advance; dropped otherwise.
    const lacking = text.SimpleShaper.shape("a\u{300}", f, &out);
    try std.testing.expect(lacking.count == 1 or lacking.count == 2);
    if (lacking.count == 2) try std.testing.expectEqual(@as(f32, 0), out[1].advance);
}

test "combining mark pixels: the accent is drawn over the e, not beside it" {
    defer text.releaseFaces();
    try text.registerFace(.mono, .regular, marks);
    const f: teak.FontSpec = .{ .size_px = 40, .family = .mono, .snap_advance = false };
    var out: [4]teak.ShapedGlyph = undefined;
    const r = text.SimpleShaper.shape("e\u{301}", f, &out);
    try std.testing.expectEqual(@as(usize, 2), r.count);
    var rast = try text.StbttRasterizer.init(std.testing.allocator);
    defer rast.deinit();
    const base = rast.rasterizeGlyph(out[0].face, out[0].glyph, 40, 0).?;
    const bx0: f32 = out[0].x + @as(f32, @floatFromInt(base.bearing_x));
    const bx1 = bx0 + @as(f32, @floatFromInt(base.width));
    const base_top = base.bearing_y;
    const acc = rast.rasterizeGlyph(out[1].face, out[1].glyph, 40, 0).?;
    const ax0: f32 = out[1].x + @as(f32, @floatFromInt(acc.bearing_x));
    const ax1 = ax0 + @as(f32, @floatFromInt(acc.width));
    // Horizontally inside the e's ink span, vertically above its top.
    try std.testing.expect(ax0 >= bx0 - 1 and ax1 <= bx1 + 1);
    try std.testing.expect(acc.bearing_y + @as(i32, @intCast(acc.height)) <= base_top + 2);
}
