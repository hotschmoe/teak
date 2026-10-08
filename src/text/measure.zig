//! Text measurement over the shaper: `width == sum(advances)`, so layout, the
//! caret and the rasterizer share one source of advances.

const std = @import("std");
const teak = @import("teak");
const face_mod = @import("face.zig");
const shaper_mod = @import("shaper.zig");

/// Glyphs shaped per chunk; longer runs loop (kerning across the seam is
/// handled by the shaper, which looks ahead before finalising an advance).
const chunk = 256;

/// Width of `text` in `font`, in px.
pub fn width(text: []const u8, font: teak.FontSpec) f32 {
    var buf: [chunk]teak.ShapedGlyph = undefined;
    var total: f32 = 0;
    var pos: usize = 0;
    while (pos < text.len) {
        const r = shaper_mod.shape(text[pos..], font, &buf);
        total += r.width;
        if (r.consumed == 0) break;
        pos += r.consumed;
    }
    return total;
}

/// Size of a run of `text` in `font`. The one measurement the Host's
/// measurer uses; the rasterizer places glyphs with the same advances.
pub fn measure(text: []const u8, font: teak.FontSpec) teak.TextMetrics {
    const resolved = face_mod.resolveFace(font.family, font.weight) orelse
        return .{ .width = 0, .height = font.size_px, .ascent = font.size_px * 0.75, .descent = font.size_px * 0.25 };
    const vm = resolved.face.vMetrics(font.size_px);
    return .{
        .width = width(text, font),
        .height = vm.ascent + vm.descent,
        .ascent = vm.ascent,
        .descent = vm.descent,
    };
}
