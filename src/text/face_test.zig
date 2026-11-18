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







const mono_sub = @embedFile("test-font-IBMPlexMonoSub-Regular");
const prop = @embedFile("test-font-QuicksandSub-Regular");
const prop_nolig = @embedFile("test-font-QuicksandSub-NoLig");

fn sumAdvances(gs: []const teak.ShapedGlyph) f32 {
    var s: f32 = 0;
    for (gs) |g| s += g.advance;
    return s;
}









const marks = @embedFile("test-font-IBMPlexMonoMarks");




const accents = @embedFile("test-font-IBMPlexMonoAccents");

