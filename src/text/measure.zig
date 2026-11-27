//! Text measurement over the shaper: `width == sum(advances)`, so layout, the
//! caret and the rasterizer share one source of advances.

const std = @import("std");
const teak = @import("teak");
const assert = teak.assert;
const face_mod = @import("face.zig");
const shaper_mod = @import("shaper.zig");
const text_state = @import("text_state.zig");

const TextState = text_state.TextState;

/// Glyphs shaped per chunk; longer runs loop (kerning across the seam is
/// handled by the shaper, which looks ahead before finalising an advance).
const chunk = 256;

/// Width of `text` in `font`, in px.
pub fn width(state: *TextState, text: []const u8, font: teak.FontSpec) f32 {
    if (shaper_mod.asciiWidth(state, text, font)) |w| return w;
    var buf: [chunk]teak.ShapedGlyph = undefined;
    var total: f32 = 0;
    var pos: usize = 0;
    for (0..text.len) |_| {
        if (pos >= text.len) break;
        const r = shaper_mod.shape(state, text[pos..], font, &buf);
        assert(r.consumed <= text.len - pos);
        total += r.width;
        if (r.consumed == 0) break;
        pos += r.consumed;
    }
    assert(pos <= text.len);
    return total;
}

const small = @import("builtin").cpu.arch.isWasm();
const max_text = if (small) 48 else 96;

pub const Slot = struct {
    used: bool,
    len: u8,
    font: teak.FontSpec,
    text: [max_text]u8,
    metrics: teak.TextMetrics,
};

pub const Cache = struct {
    slots: []Slot,
    evicted: u64 = 0,
    bypassed: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, slot_count: u32) error{OutOfMemory}!Cache {
        assert(std.math.isPowerOfTwo(slot_count));
        assert(slot_count >= 2);
        const slots = try allocator.alloc(Slot, slot_count);
        @memset(std.mem.sliceAsBytes(slots), 0);
        return .{ .slots = slots };
    }

    pub fn deinit(self: *Cache, allocator: std.mem.Allocator) void {
        assert(self.slots.len >= 2);
        allocator.free(self.slots);
        self.slots = &.{};
        assert(self.slots.len == 0);
    }

    pub fn reset(self: *Cache) void {
        assert(self.slots.len >= 2);
        @memset(std.mem.sliceAsBytes(self.slots), 0);
        assert(!self.slots[0].used);
    }
};

fn same_font(a: teak.FontSpec, b: teak.FontSpec) bool {
    return a.size_px == b.size_px and a.family == b.family and a.weight == b.weight and
        a.letter_spacing == b.letter_spacing and a.snap_advance == b.snap_advance and
        a.rtl == b.rtl;
}

fn same_run(slot: *const Slot, text: []const u8, font: teak.FontSpec) bool {
    assert(slot.len <= max_text);
    assert(text.len <= max_text);
    return slot.used and slot.len == text.len and same_font(slot.font, font) and
        std.mem.eql(u8, slot.text[0..slot.len], text);
}

fn slot_hash(text: []const u8, font: teak.FontSpec) u64 {
    assert(text.len <= max_text);
    const bits: u64 = @as(u64, @as(u32, @bitCast(font.size_px))) |
        (@as(u64, @as(u32, @bitCast(font.letter_spacing))) << 32);
    const snap: u64 = if (font.snap_advance) |v| @as(u64, @intFromBool(v)) + 1 else 0;
    const tags: u64 = @as(u64, @backingInt(font.family)) |
        (@as(u64, @backingInt(font.weight)) << 8) | (snap << 16) |
        (@as(u64, @intFromBool(font.rtl)) << 24);
    return std.hash.Wyhash.hash(bits ^ std.math.rotl(u64, tags, 40), text);
}

/// Size of a run of `text` in `font`. The one measurement the Host's
/// measurer uses; the rasterizer places glyphs with the same advances.
pub fn measure(state: *TextState, text: []const u8, font: teak.FontSpec) teak.TextMetrics {
    const cache = &state.measure;
    assert(cache.slots.len >= 2 and std.math.isPowerOfTwo(cache.slots.len));
    if (text.len <= 16) {
        if (shaper_mod.asciiWidth(state, text, font)) |w| return metrics_with(state, w, font);
    }
    if (text.len > max_text) {
        cache.bypassed += 1;
        return metrics_with(state, width(state, text, font), font);
    }
    const h = slot_hash(text, font);
    const index: usize = @intCast(h & (cache.slots.len - 1));
    assert(index < cache.slots.len);
    var slot = &cache.slots[index];
    if (same_run(slot, text, font)) return slot.metrics;
    if (!small) {
        assert(index ^ 1 < cache.slots.len);
        const other = &cache.slots[index ^ 1];
        if (same_run(other, text, font)) return other.metrics;
        if (slot.used and (!other.used or (h >> 40) & 1 == 1)) slot = other;
    }
    const m = metrics_with(state, width(state, text, font), font);
    if (slot.used) cache.evicted += 1;
    slot.used = true;
    slot.len = @intCast(text.len);
    slot.font = font;
    slot.metrics = m;
    @memcpy(slot.text[0..text.len], text);
    assert(same_run(slot, text, font));
    return m;
}

fn metrics_with(state: *TextState, w: f32, font: teak.FontSpec) teak.TextMetrics {
    const size = font.size_px;
    const resolved = face_mod.resolveFace(state, font.family, font.weight) orelse
        return .{ .width = 0, .height = size, .ascent = size * 0.75, .descent = size * 0.25 };
    assert(resolved.id <= face_mod.fallback_face_id);
    assert(face_mod.faceById(state, resolved.id) == resolved.face);
    const vm = resolved.face.vMetrics(font.size_px);
    return .{
        .width = w,
        .height = vm.ascent + vm.descent,
        .ascent = vm.ascent,
        .descent = vm.descent,
    };
}
