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



/// Device-pixel bounding box (top, bottom; y down, baseline = 0) of a shaped glyph.
fn inkRows(rast: *raster.StbttRasterizer, g: teak.ShapedGlyph, size: f32) !struct { top: i32, bottom: i32 } {
    const bmp = rast.rasterizeGlyph(g.face, g.glyph, size, 0) orelse return error.NoBitmap;
    const top = @as(i32, @intFromFloat(@round(g.y))) + bmp.bearing_y;
    return .{ .top = top, .bottom = top + @as(i32, @intCast(bmp.height)) };
}




