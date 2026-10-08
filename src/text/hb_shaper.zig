//! HarfBuzz shaper (optional; `-Dharfbuzz=true`, docs/features/harfbuzz.md).
//!
//! Same contract as `shaper.zig`'s `shape`: UTF-8 -> positioned glyph ids with
//! byte-offset clusters, `sum(advance) == width`, resumable through `consumed`.
//! It is chosen by `shaper.shape` only for text containing complex scripts
//! (Hebrew, Arabic, Indic, Thai, Khmer, ...: `needsShaping`); Latin / CJK keep
//! the built-in shaper, so default behaviour and metrics do not change.
//!
//! * Faces: HarfBuzz reads the OpenType tables straight from the bytes the face
//!   table already holds (read-only blob, no copy); outlines are still rasterized
//!   by stb from the same glyph ids. One hb face/font per face-table slot, rebuilt
//!   when `face.epoch` changes.
//! * Face choice is by coverage: a run uses the primary face while it has the
//!   glyphs, else the first registered face that does. That is how one line can
//!   mix Latin, Hebrew, Arabic and Devanagari faces.
//! * Marks and contextual forms: GSUB/GPOS/GDEF run in HarfBuzz; `x_offset`
//!   folds into `ShapedGlyph.x`, `y_offset` into `ShapedGlyph.y`.
//! * Direction: a stand-in until UAX#9 bidi lands. Each run takes the direction
//!   of its script (Hebrew/Arabic RTL) and glyphs of an RTL run come out in
//!   visual order; consecutive RTL runs are emitted in reverse so
//!   "Arabic Hebrew" reads right to left. Mixed-direction nesting beyond that
//!   (numbers inside RTL, brackets) is NOT handled.
//! * Advances are fractional (no pixel snapping): snapping would break mark
//!   attachment.

const std = @import("std");
const teak = @import("teak");
const face_mod = @import("face.zig");
const shaper = @import("shaper.zig");

const ShapedGlyph = teak.ShapedGlyph;
const ShapeResult = teak.ShapeResult;
const FontSpec = teak.FontSpec;
const Font = face_mod.Font;

// ── HarfBuzz C API (the few entry points we use) ──────────────────────

const hb = struct {
    const Blob = opaque {};
    const Face = opaque {};
    const HFont = opaque {};
    const Buffer = opaque {};
    const GlyphInfo = extern struct { codepoint: u32, mask: u32, cluster: u32, v1: u32, v2: u32 };
    const GlyphPosition = extern struct { x_advance: i32, y_advance: i32, x_offset: i32, y_offset: i32, v: u32 };
    const MEMORY_MODE_READONLY: c_int = 1;
    const DIRECTION_RTL: c_int = 5;

    extern fn hb_blob_create(data: [*]const u8, length: c_uint, mode: c_int, user_data: ?*anyopaque, destroy: ?*const anyopaque) *Blob;
    extern fn hb_blob_destroy(b: *Blob) void;
    extern fn hb_face_create(b: *Blob, index: c_uint) *Face;
    extern fn hb_face_destroy(f: *Face) void;
    extern fn hb_face_get_upem(f: *Face) c_uint;
    extern fn hb_font_create(f: *Face) *HFont;
    extern fn hb_font_destroy(f: *HFont) void;
    extern fn hb_font_set_scale(f: *HFont, x: c_int, y: c_int) void;
    extern fn hb_buffer_create() *Buffer;
    extern fn hb_buffer_destroy(b: *Buffer) void;
    extern fn hb_buffer_clear_contents(b: *Buffer) void;
    extern fn hb_buffer_add_utf8(b: *Buffer, text: [*]const u8, text_length: c_int, item_offset: c_uint, item_length: c_int) void;
    extern fn hb_buffer_guess_segment_properties(b: *Buffer) void;
    extern fn hb_buffer_get_direction(b: *Buffer) c_int;
    extern fn hb_buffer_set_direction(b: *Buffer, d: c_int) void;
    extern fn hb_shape(f: *HFont, b: *Buffer, features: ?*const anyopaque, num_features: c_uint) void;
    extern fn hb_buffer_get_length(b: *Buffer) c_uint;
    extern fn hb_buffer_get_glyph_infos(b: *Buffer, length: ?*c_uint) [*]GlyphInfo;
    extern fn hb_buffer_get_glyph_positions(b: *Buffer, length: ?*c_uint) [*]GlyphPosition;
};

// ── Per-face hb objects ───────────────────────────────────────────────

const max_faces = face_mod.fallback_face_id + 1;

const Slot = struct {
    blob: *hb.Blob,
    face: *hb.Face,
    font: *hb.HFont,
};

var slots: [max_faces]?Slot = @splat(null);
var slots_epoch: u64 = 0;
var buffer: ?*hb.Buffer = null;

fn dropSlots() void {
    for (&slots) |*s| {
        if (s.*) |v| {
            hb.hb_font_destroy(v.font);
            hb.hb_face_destroy(v.face);
            hb.hb_blob_destroy(v.blob);
            s.* = null;
        }
    }
}

fn slotFor(id: u16, f: *const Font) ?*const Slot {
    if (slots_epoch != face_mod.epoch) {
        dropSlots();
        slots_epoch = face_mod.epoch;
    }
    if (id >= max_faces) return null;
    if (slots[id] == null) {
        const blob = hb.hb_blob_create(f.data.ptr, @intCast(f.data.len), hb.MEMORY_MODE_READONLY, null, null);
        const face = hb.hb_face_create(blob, 0);
        const font = hb.hb_font_create(face);
        const upem: c_int = @intCast(hb.hb_face_get_upem(face));
        hb.hb_font_set_scale(font, upem, upem);
        slots[id] = .{ .blob = blob, .face = face, .font = font };
    }
    return &slots[id].?;
}

/// Free every hb object (tests, shutdown). The next shape rebuilds them.
pub fn deinit() void {
    dropSlots();
    if (buffer) |b| hb.hb_buffer_destroy(b);
    buffer = null;
}

// ── Script classification ─────────────────────────────────────────────

/// True when `cp` belongs to a script that needs more than cmap + kerning.
fn isComplex(cp: u21) bool {
    return (cp >= 0x0590 and cp <= 0x109F) or // Hebrew .. Myanmar (Arabic, Syriac, Indic, Thai, Lao, Tibetan)
        (cp >= 0x1780 and cp <= 0x18AF) or // Khmer, Mongolian
        (cp >= 0x1B00 and cp <= 0x1CFF) or // Balinese .. Vedic
        (cp >= 0xFB1D and cp <= 0xFDFF) or // Hebrew / Arabic presentation forms A
        (cp >= 0xFE70 and cp <= 0xFEFF); // Arabic presentation forms B
}

/// True when any code point of `text` needs HarfBuzz.
pub fn needsShaping(text: []const u8) bool {
    var i: usize = 0;
    while (i < text.len) {
        // ASCII and 2-byte Latin / Greek / Cyrillic (< U+0590) cannot be complex.
        if (text[i] < 0xD6) {
            i += 1;
            continue;
        }
        const d = shaper.decode(text, i);
        if (isComplex(d.cp)) return true;
        i += d.len;
    }
    return false;
}

/// Characters that take whichever face / direction surrounds them.
fn isNeutral(cp: u21) bool {
    return cp <= 0x40 or (cp >= 0x5B and cp <= 0x60) or (cp >= 0x7B and cp <= 0xBF) or
        (cp >= 0x2000 and cp <= 0x206F) or cp == 0x00D7 or cp == 0x00F7;
}

/// First registered face (the primary, then its family, then any) that has a
/// glyph for `cp`; null when none does.
fn coveringFace(primary_id: u16, cp: u21) ?u16 {
    if (face_mod.faceById(primary_id)) |f| {
        if (f.glyphIndex(cp) != 0) return primary_id;
    }
    var id: u16 = 0;
    while (id < max_faces) : (id += 1) {
        if (id == primary_id) continue;
        const f = face_mod.faceById(id) orelse continue;
        if (f.glyphIndex(cp) != 0) return id;
    }
    return null;
}

// ── Runs ──────────────────────────────────────────────────────────────

const Run = struct { start: usize, len: usize, face_id: u16, rtl: bool = false };
const max_runs = 48;
const scratch_cap = 768;

/// Next face run starting at `pos`: a maximal span the same face covers.
fn nextRun(text: []const u8, pos: usize, primary_id: u16) Run {
    var face_id = primary_id;
    var chosen = false;
    var i = pos;
    while (i < text.len) {
        const d = shaper.decode(text, i);
        if (!isNeutral(d.cp)) {
            const want = coveringFace(primary_id, d.cp) orelse (if (chosen) face_id else primary_id);
            if (!chosen) {
                face_id = want;
                chosen = true;
            } else if (want != face_id) break;
        }
        i += d.len;
    }
    return .{ .start = pos, .len = i - pos, .face_id = face_id };
}

const Scratch = struct {
    glyphs: [scratch_cap]ShapedGlyph = undefined,
    count: usize = 0,
    /// Run-relative width of the last shaped run.
    width: f32 = 0,
};

/// Shape `text[run.start..][0..run.len]` into `sc` (x relative to the run's own
/// pen start). Returns false when it does not fit in the scratch.
fn shapeRun(text: []const u8, run: *Run, font: FontSpec, sc: *Scratch) bool {
    const f = face_mod.faceById(run.face_id) orelse return false;
    const slot = slotFor(run.face_id, f) orelse return false;
    const buf = buffer orelse blk: {
        const b = hb.hb_buffer_create();
        buffer = b;
        break :blk b;
    };
    hb.hb_buffer_clear_contents(buf);
    hb.hb_buffer_add_utf8(buf, text.ptr, @intCast(text.len), @intCast(run.start), @intCast(run.len));
    hb.hb_buffer_guess_segment_properties(buf);
    // The renderer passes one bidi run at a time: its level decides the direction.
    if (font.rtl) hb.hb_buffer_set_direction(buf, hb.DIRECTION_RTL);
    run.rtl = hb.hb_buffer_get_direction(buf) == hb.DIRECTION_RTL;
    hb.hb_shape(slot.font, buf, null, 0);

    var n: c_uint = 0;
    const infos = hb.hb_buffer_get_glyph_infos(buf, &n);
    const poss = hb.hb_buffer_get_glyph_positions(buf, null);
    if (n > scratch_cap) return false;
    const scale = f.scaleForEm(font.size_px);
    // Joining scripts keep their letters connected: no tracking.
    const spacing: f32 = if (run.rtl) 0 else font.letter_spacing;
    var x: f32 = 0;
    for (0..n) |i| {
        const p = poss[i];
        sc.glyphs[i] = .{
            .glyph = @intCast(@min(infos[i].codepoint, std.math.maxInt(u16))),
            .face = run.face_id,
            .cluster = infos[i].cluster,
            .x = x + @as(f32, @floatFromInt(p.x_offset)) * scale,
            .y = -@as(f32, @floatFromInt(p.y_offset)) * scale,
            .advance = @as(f32, @floatFromInt(p.x_advance)) * scale + spacing,
        };
        x += sc.glyphs[i].advance;
    }
    sc.count = @intCast(n);
    sc.width = x;
    return true;
}

var scratch: Scratch = .{};

/// Shape `text`; same contract as `shaper.shape` (see the file header for the
/// direction stand-in).
pub fn shape(text: []const u8, font: FontSpec, out: []ShapedGlyph) ShapeResult {
    const resolved = face_mod.resolveFace(font.family, font.weight) orelse
        return .{ .count = 0, .width = 0, .consumed = text.len };
    const primary_id = resolved.id;

    var runs: [max_runs]Run = undefined;
    var nruns: usize = 0;
    var p: usize = 0;
    while (p < text.len and nruns < max_runs) {
        const r = nextRun(text, p, primary_id);
        runs[nruns] = r;
        nruns += 1;
        p += r.len;
    }

    var count: usize = 0;
    var x: f32 = 0;
    var consumed: usize = 0;
    var i: usize = 0;
    while (i < nruns) {
        // Direction is only known after hb sees the run: probe it, then group.
        var first = runs[i];
        if (!shapeRun(text, &first, font, &scratch)) break;
        runs[i] = first;
        var j = i + 1;
        if (first.rtl) {
            // Gather the following RTL runs; they are emitted last-to-first.
            while (j < nruns) : (j += 1) {
                var r = runs[j];
                if (!shapeRun(text, &r, font, &scratch)) break;
                if (!r.rtl) break;
                runs[j] = r;
            }
        }
        // Emit runs j-1 .. i (reverse) for RTL groups, else just run i.
        var k = j;
        while (k > i) {
            k -= 1;
            var r = runs[k];
            if (!shapeRun(text, &r, font, &scratch)) return finishPartial(count, x, consumed);
            if (count + scratch.count > out.len) {
                if (count == 0 and scratch.count > 0) {
                    // One run alone overflows `out`: cut it in half at a code
                    // point boundary and let the caller continue from there.
                    return shapeCut(text, r, font, out);
                }
                return finishPartial(count, x, consumed);
            }
            for (scratch.glyphs[0..scratch.count]) |g| {
                var gg = g;
                gg.x += x;
                out[count] = gg;
                count += 1;
            }
            x += scratch.width;
        }
        // Whole group emitted: consumed advances past its last run.
        const last = runs[j - 1];
        consumed = last.start + last.len;
        i = j;
    }
    return .{ .count = count, .width = x, .consumed = if (count == 0 and consumed == 0) text.len else consumed };
}

fn finishPartial(count: usize, x: f32, consumed: usize) ShapeResult {
    return .{ .count = count, .width = x, .consumed = consumed };
}

/// `run` alone yields more glyphs than `out` holds: shape a shorter prefix.
fn shapeCut(text: []const u8, run: Run, font: FontSpec, out: []ShapedGlyph) ShapeResult {
    var len = @min(run.len / 2, out.len);
    while (len > 0) {
        // Back to a code point boundary.
        while (len > 0 and (text[run.start + len] & 0xC0) == 0x80) len -= 1;
        if (len == 0) break;
        var r = Run{ .start = run.start, .len = len, .face_id = run.face_id };
        if (shapeRun(text, &r, font, &scratch) and scratch.count <= out.len) {
            @memcpy(out[0..scratch.count], scratch.glyphs[0..scratch.count]);
            return .{ .count = scratch.count, .width = scratch.width, .consumed = run.start + len };
        }
        len /= 2;
    }
    return .{ .count = 0, .width = 0, .consumed = text.len };
}
