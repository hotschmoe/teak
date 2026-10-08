//! HarfBuzz shaper tests (only compiled with `-Dharfbuzz=true`). They use Noto
//! Naskh Arabic, Noto Sans Devanagari / Hebrew / Latin (SIL OFL), which are NOT
//! in the repo: set `TEAK_TEST_FONTS` to a directory holding
//! `NotoNaskhArabic-Regular.ttf`, `NotoSansDevanagari-Regular.ttf`,
//! `NotoSansHebrew-Regular.ttf`, `NotoSans-Regular.ttf` (default
//! `$HOME/.cache/teak-test-fonts`). A test skips when a font is missing.

const std = @import("std");
const teak = @import("teak");
const face = @import("face.zig");
const shaper = @import("shaper.zig");
const hb_shaper = @import("hb_shaper.zig");
const raster = @import("raster.zig");
const measure_mod = @import("measure.zig");

const alloc = std.testing.allocator;

fn loadFont(name: []const u8) ![]u8 {
    var path_buf: [1024]u8 = undefined;
    const path = if (std.c.getenv("TEAK_TEST_FONTS")) |d|
        try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ std.mem.span(d), name })
    else if (std.c.getenv("HOME")) |h|
        try std.fmt.bufPrint(&path_buf, "{s}/.cache/teak-test-fonts/{s}", .{ std.mem.span(h), name })
    else
        return error.SkipZigTest;
    return face.readAbsolute(alloc, path) catch error.SkipZigTest;
}

const Fonts = struct {
    latin: []u8,
    arabic: []u8,
    deva: []u8,
    hebrew: []u8,

    fn load() !Fonts {
        const latin = try loadFont("NotoSans-Regular.ttf");
        errdefer alloc.free(latin);
        const arabic = try loadFont("NotoNaskhArabic-Regular.ttf");
        errdefer alloc.free(arabic);
        const deva = try loadFont("NotoSansDevanagari-Regular.ttf");
        errdefer alloc.free(deva);
        const hebrew = try loadFont("NotoSansHebrew-Regular.ttf");
        errdefer alloc.free(hebrew);
        // sans = Latin, serif = Arabic, mono = Devanagari; Hebrew rides on bold-sans.
        try face.registerFace(.sans, .regular, latin);
        try face.registerFace(.serif, .regular, arabic);
        try face.registerFace(.mono, .regular, deva);
        try face.registerFace(.sans, .bold, hebrew);
        return .{ .latin = latin, .arabic = arabic, .deva = deva, .hebrew = hebrew };
    }

    fn deinit(self: Fonts) void {
        face.releaseFaces();
        hb_shaper.deinit();
        alloc.free(self.latin);
        alloc.free(self.arabic);
        alloc.free(self.deva);
        alloc.free(self.hebrew);
    }
};

const spec: teak.FontSpec = .{ .size_px = 40, .family = .sans, .weight = .regular, .snap_advance = false };

fn sumAdvance(g: []const teak.ShapedGlyph) f32 {
    var s: f32 = 0;
    for (g) |x| s += x.advance;
    return s;
}

test "Latin text still uses the built-in shaper (no behaviour change)" {
    const f = try Fonts.load();
    defer f.deinit();
    try std.testing.expect(!hb_shaper.needsShaping("Hello, world fi"));
    var a: [32]teak.ShapedGlyph = undefined;
    var b: [32]teak.ShapedGlyph = undefined;
    const ra = shaper.shape("Hello AV", spec, &a);
    const rb = shaper.shapeSimple("Hello AV", spec, &b);
    try std.testing.expectEqual(rb.count, ra.count);
    try std.testing.expectEqual(rb.width, ra.width);
}

test "Arabic: letters join into contextual forms, glyphs come out right-to-left" {
    const f = try Fonts.load();
    defer f.deinit();
    const word = "\u{0628}\u{0633}\u{0645}"; // beh seen meem
    var out: [16]teak.ShapedGlyph = undefined;
    const arab = teak.FontSpec{ .size_px = 40, .family = .serif, .snap_advance = false };
    const r = shaper.shape(word, arab, &out);
    // Noto Naskh builds beh from a body glyph plus a separate dot mark: 4 glyphs.
    try std.testing.expect(r.count >= 3);
    try std.testing.expectEqual(word.len, r.consumed);
    // Visual order: the last letter (meem, cluster 4) is leftmost, beh (cluster 0) rightmost.
    try std.testing.expectEqual(@as(u32, 4), out[0].cluster);
    try std.testing.expectEqual(@as(u32, 0), out[r.count - 1].cluster);
    // Contextual forms: the glyphs are not the nominal (isolated) cmap glyphs.
    const ar_face = face.faceById(out[0].face).?;
    var seen_glyph: u16 = 0;
    var beh_body: u16 = 0;
    for (out[0..r.count]) |g| {
        if (g.cluster == 2) seen_glyph = g.glyph;
        if (g.cluster == 0 and g.advance > 0) beh_body = g.glyph;
    }
    try std.testing.expect(seen_glyph != 0 and seen_glyph != ar_face.glyphIndex(0x0633)); // medial seen
    try std.testing.expect(beh_body != 0 and beh_body != ar_face.glyphIndex(0x0628)); // initial beh
    // The built-in shaper keeps the nominal glyphs, so the two disagree.
    var simple: [16]teak.ShapedGlyph = undefined;
    const rs = shaper.shapeSimple(word, arab, &simple);
    try std.testing.expectEqual(@as(usize, 3), rs.count);
    try std.testing.expect(simple[0].glyph == ar_face.glyphIndex(0x0628));
    // width == sum(advance), and measure agrees.
    try std.testing.expectApproxEqAbs(r.width, sumAdvance(out[0..r.count]), 0.001);
    try std.testing.expectApproxEqAbs(r.width, measure_mod.width(word, arab), 0.001);
    // Joined text is tighter than the nominal isolated forms.
    try std.testing.expect(r.width < rs.width);
}

/// Device-pixel bounding box (top, bottom; y down, baseline = 0) of a shaped glyph.
fn inkRows(rast: *raster.StbttRasterizer, g: teak.ShapedGlyph, size: f32) !struct { top: i32, bottom: i32 } {
    const bmp = rast.rasterizeGlyph(g.face, g.glyph, size, 0) orelse return error.NoBitmap;
    const top = @as(i32, @intFromFloat(@round(g.y))) + bmp.bearing_y;
    return .{ .top = top, .bottom = top + @as(i32, @intCast(bmp.height)) };
}

test "Arabic: a vowel mark is attached above its base (pixels)" {
    const f = try Fonts.load();
    defer f.deinit();
    const text = "\u{0628}\u{064E}"; // beh + fatha
    var out: [8]teak.ShapedGlyph = undefined;
    const size: f32 = 48;
    const r = shaper.shape(text, .{ .size_px = size, .family = .serif, .snap_advance = false }, &out);
    var rast = try raster.StbttRasterizer.init(alloc);
    defer rast.deinit();
    var base_top: i32 = std.math.maxInt(i32);
    var base_bottom: i32 = std.math.minInt(i32);
    var marks: usize = 0;
    var above: usize = 0;
    for (out[0..r.count]) |g| {
        const rows = try inkRows(&rast, g, size);
        if (g.advance > 0) {
            base_top = @min(base_top, rows.top);
            base_bottom = @max(base_bottom, rows.bottom);
        }
    }
    for (out[0..r.count]) |g| {
        if (g.advance != 0) continue;
        marks += 1;
        const rows = try inkRows(&rast, g, size);
        // The fatha sits above the beh body: its ink ends no lower than the body starts.
        if (rows.bottom <= base_top + 2) above += 1;
    }
    try std.testing.expect(marks >= 1);
    try std.testing.expect(above >= 1);
    try std.testing.expect(base_bottom > base_top);
}

test "Devanagari: the i-matra reorders before its consonant, conjuncts ligate" {
    const f = try Fonts.load();
    defer f.deinit();
    const dev = teak.FontSpec{ .size_px = 40, .family = .mono, .snap_advance = false };
    var out: [16]teak.ShapedGlyph = undefined;
    const ki = "\u{0915}\u{093F}"; // ka + vowel sign i
    const r = shaper.shape(ki, dev, &out);
    try std.testing.expectEqual(@as(usize, 2), r.count);
    const dv = face.faceById(out[0].face).?;
    // Logical order is ka, i; visual order puts the matra glyph first.
    try std.testing.expect(out[1].glyph == dv.glyphIndex(0x0915));
    try std.testing.expect(out[0].glyph != dv.glyphIndex(0x0915));
    try std.testing.expect(out[0].x < out[1].x);
    // Pixels: both glyphs have ink, the matra's ink sits left of the consonant's stem.
    var rast = try raster.StbttRasterizer.init(alloc);
    defer rast.deinit();
    const b0 = rast.rasterizeGlyph(out[0].face, out[0].glyph, 40, 0) orelse return error.NoBitmap;
    const b1 = rast.rasterizeGlyph(out[1].face, out[1].glyph, 40, 0) orelse return error.NoBitmap;
    try std.testing.expect(b0.width > 0 and b1.width > 0);

    // A conjunct (ka + virama + ssa) shapes to fewer glyphs than code points.
    const kssa = "\u{0915}\u{094D}\u{0937}";
    const r2 = shaper.shape(kssa, dev, &out);
    try std.testing.expect(r2.count < 3);
    // The built-in shaper cannot do either.
    var simple: [16]teak.ShapedGlyph = undefined;
    const rs = shaper.shapeSimple(kssa, dev, &simple);
    try std.testing.expectEqual(@as(usize, 3), rs.count);
}

test "Hebrew run: visual order and per-script face on one line" {
    const f = try Fonts.load();
    defer f.deinit();
    const line = "ab \u{05E9}\u{05DC}\u{05D5}\u{05DD} cd"; // ab SHLOM cd
    var out: [32]teak.ShapedGlyph = undefined;
    const r = shaper.shape(line, spec, &out);
    try std.testing.expectEqual(line.len, r.consumed);
    // Latin glyphs use the primary face, Hebrew the bold-sans slot (the only face
    // with Hebrew coverage here).
    const sans_id = face.faceId(.sans, .regular);
    const heb_id = face.faceId(.sans, .bold);
    var heb_clusters: [4]u32 = undefined;
    var nheb: usize = 0;
    for (out[0..r.count]) |g| {
        const is_letter = g.cluster >= 3 and g.cluster < 11; // the four 2-byte Hebrew letters
        if (is_letter) {
            try std.testing.expectEqual(heb_id, g.face);
            heb_clusters[nheb] = g.cluster;
            nheb += 1;
        } else if (g.cluster < 2 or g.cluster >= 12) try std.testing.expectEqual(sans_id, g.face);
    }
    try std.testing.expectEqual(@as(usize, 4), nheb);
    // Right-to-left: clusters strictly decrease across the Hebrew word.
    try std.testing.expect(heb_clusters[0] > heb_clusters[1] and heb_clusters[1] > heb_clusters[2] and heb_clusters[2] > heb_clusters[3]);
    // Pen positions never go backwards.
    for (out[1..r.count], 0..) |g, i| try std.testing.expect(g.x >= out[i].x - 0.001);
}

test "a run longer than the output buffer is resumable" {
    const f = try Fonts.load();
    defer f.deinit();
    const unit = "\u{0628}\u{0633}\u{0645} ";
    const text = unit ++ unit ++ unit ++ unit ++ unit ++ unit ++ unit ++ unit;
    var small: [5]teak.ShapedGlyph = undefined;
    var pos: usize = 0;
    var guard: usize = 0;
    while (pos < text.len and guard < 64) : (guard += 1) {
        const r = shaper.shape(text[pos..], .{ .size_px = 30, .family = .serif, .snap_advance = false }, &small);
        try std.testing.expect(r.consumed > 0);
        pos += r.consumed;
    }
    try std.testing.expectEqual(text.len, pos);
}
