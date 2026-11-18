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
    if (shaper_mod.asciiWidth(text, font)) |w| return w;
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

const small = @import("builtin").cpu.arch.isWasm();
const max_text = if (small) 48 else 96;
const cache_slots = if (small) 1024 else 4096;

const Slot = struct {
    used: bool,
    len: u8,
    font: teak.FontSpec,
    text: [max_text]u8,
    metrics: teak.TextMetrics,
};

// Zero initialization keeps the cache out of the wasm data section.
var cache: [cache_slots]Slot = std.mem.zeroes([cache_slots]Slot);
var cache_epoch: u64 = 0;

fn sameFont(a: teak.FontSpec, b: teak.FontSpec) bool {
    return a.size_px == b.size_px and a.family == b.family and a.weight == b.weight and
        a.letter_spacing == b.letter_spacing and a.snap_advance == b.snap_advance and a.rtl == b.rtl;
}

fn slotHash(text: []const u8, font: teak.FontSpec) u64 {
    const bits: u64 = @as(u64, @as(u32, @bitCast(font.size_px))) |
        (@as(u64, @as(u32, @bitCast(font.letter_spacing))) << 32);
    const tags: u64 = @as(u64, @backingInt(font.family)) | (@as(u64, @backingInt(font.weight)) << 8) |
        (@as(u64, if (font.snap_advance) |v| @intFromBool(v) + 1 else 0) << 16) |
        (@as(u64, @intFromBool(font.rtl)) << 24);
    return std.hash.Wyhash.hash(bits ^ std.math.rotl(u64, tags, 40), text);
}

/// Size of a run of `text` in `font`. The one measurement the Host's
/// measurer uses; the rasterizer places glyphs with the same advances.
pub fn measure(text: []const u8, font: teak.FontSpec) teak.TextMetrics {
    if (face_mod.epoch != cache_epoch) {
        cache = std.mem.zeroes([cache_slots]Slot);
        cache_epoch = face_mod.epoch;
    }
    if (text.len <= 16) {
        if (shaper_mod.asciiWidth(text, font)) |w| return metricsWith(w, font);
    }
    if (text.len > max_text) return measureUncached(text, font);
    const h = slotHash(text, font);
    var slot = &cache[@as(usize, @intCast(h % cache_slots))];
    if (slot.used and slot.len == text.len and sameFont(slot.font, font) and std.mem.eql(u8, slot.text[0..slot.len], text)) {
        return slot.metrics;
    }
    if (!small) {
        const other = &cache[@as(usize, @intCast(h % cache_slots)) ^ 1];
        if (other.used and other.len == text.len and sameFont(other.font, font) and std.mem.eql(u8, other.text[0..other.len], text)) {
            return other.metrics;
        }
        if (slot.used and (!other.used or (h >> 40) & 1 == 1)) slot = other;
    }
    const m = measureUncached(text, font);
    slot.used = true;
    slot.len = @intCast(text.len);
    slot.font = font;
    slot.metrics = m;
    @memcpy(slot.text[0..text.len], text);
    return m;
}

fn measureUncached(text: []const u8, font: teak.FontSpec) teak.TextMetrics {
    return metricsWith(width(text, font), font);
}

fn metricsWith(w: f32, font: teak.FontSpec) teak.TextMetrics {
    const resolved = face_mod.resolveFace(font.family, font.weight) orelse
        return .{ .width = 0, .height = font.size_px, .ascent = font.size_px * 0.75, .descent = font.size_px * 0.25 };
    const vm = resolved.face.vMetrics(font.size_px);
    return .{
        .width = w,
        .height = vm.ascent + vm.descent,
        .ascent = vm.ascent,
        .descent = vm.descent,
    };
}


