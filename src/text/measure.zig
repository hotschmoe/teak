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

// ── Measure cache ──────────────────────────────────────────────────
//
// Layout measures every text run of every frame, and an app's labels barely
// change between frames. A direct-mapped table keyed by the full (text, font)
// returns the previous result without shaping. Entries compare the text and
// every font field (the hash only picks the slot) and are dropped wholesale when
// the face table changes. Runs longer than `max_text` bypass the cache.

//
// Native builds size the table for a 10k-run screen (2-way set associative);
// wasm keeps it small (its linear memory is the budget).
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

// All-zero (so it lives in .bss, not the wasm data section): `used` is false.
var cache: [cache_slots]Slot = std.mem.zeroes([cache_slots]Slot);
var cache_epoch: u64 = 0;

fn sameFont(a: teak.FontSpec, b: teak.FontSpec) bool {
    return a.size_px == b.size_px and a.family == b.family and a.weight == b.weight and
        a.letter_spacing == b.letter_spacing and a.snap_advance == b.snap_advance;
}

fn slotHash(text: []const u8, font: teak.FontSpec) u64 {
    const bits: u64 = @as(u64, @as(u32, @bitCast(font.size_px))) |
        (@as(u64, @as(u32, @bitCast(font.letter_spacing))) << 32);
    const tags: u64 = @as(u64, @backingInt(font.family)) | (@as(u64, @backingInt(font.weight)) << 8) |
        (@as(u64, if (font.snap_advance) |v| @intFromBool(v) + 1 else 0) << 16);
    return std.hash.Wyhash.hash(bits ^ std.math.rotl(u64, tags, 40), text);
}

/// Size of a run of `text` in `font`. The one measurement the Host's
/// measurer uses; the rasterizer places glyphs with the same advances.
pub fn measure(text: []const u8, font: teak.FontSpec) teak.TextMetrics {
    if (face_mod.epoch != cache_epoch) {
        cache = std.mem.zeroes([cache_slots]Slot);
        cache_epoch = face_mod.epoch;
    }
    // Pure-ASCII runs cost less than a cache probe: no table, no hashing.
    if (shaper_mod.asciiWidth(text, font)) |w| return metricsWith(w, font);
    if (text.len > max_text) return measureUncached(text, font);
    const h = slotHash(text, font);
    var slot = &cache[@as(usize, @intCast(h % cache_slots))];
    if (slot.used and slot.len == text.len and sameFont(slot.font, font) and std.mem.eql(u8, slot.text[0..slot.len], text)) {
        return slot.metrics;
    }
    if (!small) {
        // Second way: the neighbouring slot.
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

test "measure caches by full key: same text and font agree, different font does not collide" {
    defer face_mod.releaseFaces();
    const a = measure("hello", .{ .size_px = 14, .family = .mono });
    const b = measure("hello", .{ .size_px = 14, .family = .mono });
    try std.testing.expectEqual(a.width, b.width);
    if (a.width == 0) return; // no font on this builder
    const big = measure("hello", .{ .size_px = 28, .family = .mono });
    try std.testing.expect(big.width > a.width * 1.9);
    try std.testing.expect(measure("hello!", .{ .size_px = 14, .family = .mono }).width > a.width);
}

test "ascii fast width matches the shaper (kerning, snapping, ligature bail)" {
    defer face_mod.releaseFaces();
    const fonts = [_]teak.FontSpec{
        .{ .size_px = 13, .family = .sans },
        .{ .size_px = 11.5, .family = .mono },
        .{ .size_px = 17, .family = .sans, .letter_spacing = 0.5 },
        .{ .size_px = 12, .family = .sans, .snap_advance = true },
    };
    const texts = [_][]const u8{ "", "A", "AV To Wa", "r123c45", "office fi ffl", "The quick brown fox, 0123456789 [AVAWAY]" };
    for (fonts) |f| for (texts) |t| {
        const fast = shaper_mod.asciiWidth(t, f) orelse continue;
        var buf: [chunk]teak.ShapedGlyph = undefined;
        var total: f32 = 0;
        var pos: usize = 0;
        while (pos < t.len) {
            const r = shaper_mod.shape(t[pos..], f, &buf);
            total += r.width;
            if (r.consumed == 0) break;
            pos += r.consumed;
        }
        try std.testing.expectEqual(total, fast);
    };
}
