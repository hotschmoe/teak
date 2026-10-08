//! SimpleShaper: UTF-8 -> positioned glyph ids for Latin and unshaped scripts
//! (docs/features/text-engine.md 5.2). Pure over the `face.zig` table; no
//! allocation.
//!
//! Per code point: cmap lookup (falling back to other registered weights of
//! the family when the primary face lacks the glyph), then fi/fl/ff/ffi/ffl
//! ligatures when the face has the presentation-form glyphs, then pair kerning
//! (stb: legacy `kern` + GPOS pair adjustment). No GSUB, no mark attachment,
//! no bidi: output is logical order, one cluster per code point (ligatures
//! cluster their sources).
//!
//! Kerning is folded into the previous glyph's advance, so `x` of each glyph is
//! its pen position and `sum(advance) == width`.

const std = @import("std");
const teak = @import("teak");
const face_mod = @import("face.zig");

const Font = face_mod.Font;
const ShapedGlyph = teak.ShapedGlyph;
const ShapeResult = teak.ShapeResult;
const FontSpec = teak.FontSpec;

const replacement: u21 = 0xFFFD;

/// One decoded code point and the number of source bytes it used.
/// Malformed input yields U+FFFD for exactly one byte; never reads out of bounds.
pub fn decode(text: []const u8, i: usize) struct { cp: u21, len: u3 } {
    const first = text[i];
    if (first < 0x80) return .{ .cp = first, .len = 1 };
    const n = std.unicode.utf8ByteSequenceLength(first) catch return .{ .cp = replacement, .len = 1 };
    if (i + n > text.len) return .{ .cp = replacement, .len = 1 };
    const cp = std.unicode.utf8Decode(text[i .. i + n]) catch return .{ .cp = replacement, .len = 1 };
    return .{ .cp = cp, .len = @intCast(n) };
}

const Unit = struct {
    glyph: u16,
    face_id: u16,
    face: *const Font,
    len: usize,
    /// Advance in font units, or null to ask the face (non-ASCII, ligatures).
    adv: ?u16 = null,
    /// A code point no face has, from a full-width script: one em wide, so the
    /// glyph a fallback rasterizer draws for it does not overlap its neighbours.
    wide: bool = false,
    /// A combining mark: zero advance, centred over the preceding base glyph.
    mark: bool = false,
};

/// Glyph for `cp`: the primary face, else another registered weight of the same
/// family. Missing everywhere yields the primary face's glyph 0 (.notdef).
fn mapGlyph(primary: *const Font, primary_id: u16, family: teak.FontFamily, cp: u21) struct { glyph: u16, face_id: u16, face: *const Font } {
    const g = primary.glyphIndex(cp);
    if (g != 0) return .{ .glyph = g, .face_id = primary_id, .face = primary };
    var w: u8 = 0;
    while (w < 3) : (w += 1) {
        const id = face_mod.faceId(family, @fromBackingInt(@intCast(w)));
        if (id == primary_id) continue;
        const f = face_mod.faceById(id) orelse continue;
        const alt = f.glyphIndex(cp);
        if (alt != 0) return .{ .glyph = alt, .face_id = id, .face = f };
    }
    return .{ .glyph = 0, .face_id = primary_id, .face = primary };
}

/// Longest ligature starting at `text[i]` ('f' followed by f/i/l) that the face
/// has a glyph for: returns glyph and source bytes, or null.
fn ligatureAt(face: *const Font, text: []const u8, i: usize) ?struct { glyph: u16, len: usize } {
    // All sources are ASCII, so byte comparison is exact.
    const rest = text[i..];
    if (rest.len < 2 or rest[0] != 'f') return null;
    const Lig = struct { src: []const u8, cp: u21 };
    const table = [_]Lig{
        .{ .src = "ffi", .cp = 0xFB03 },
        .{ .src = "ffl", .cp = 0xFB04 },
        .{ .src = "ff", .cp = 0xFB00 },
        .{ .src = "fi", .cp = 0xFB01 },
        .{ .src = "fl", .cp = 0xFB02 },
    };
    for (table) |l| {
        if (!std.mem.startsWith(u8, rest, l.src)) continue;
        const g = face.glyphIndex(l.cp);
        if (g != 0) return .{ .glyph = g, .len = l.src.len };
    }
    return null;
}

fn nextUnit(primary: *const Font, primary_id: u16, text: []const u8, i: usize, font: FontSpec, ligatures: bool) Unit {
    if (ligatures) {
        if (ligatureAt(primary, text, i)) |lig| {
            return .{ .glyph = lig.glyph, .face_id = primary_id, .face = primary, .len = lig.len };
        }
    }
    const d = decode(text, i);
    const m = mapGlyph(primary, primary_id, font.family, d.cp);
    const adv: ?u16 = if (d.cp < 128 and m.face == primary) primary.ascii_adv[d.cp] else null;
    return .{ .glyph = m.glyph, .face_id = m.face_id, .face = m.face, .len = d.len, .adv = adv, .wide = m.glyph == 0 and isWide(d.cp), .mark = isCombining(d.cp) };
}

/// Full-width code points (CJK ideographs, kana, hangul, full-width forms).
/// A handful of range compares instead of `teak.unicode`'s tables: the wasm
/// build ships this shaper and the tables would cost ~16 KB gzip.
fn isWide(cp: u21) bool {
    return (cp >= 0x1100 and cp <= 0x115F) or (cp >= 0x2E80 and cp <= 0x303E) or
        (cp >= 0x3041 and cp <= 0x33FF) or (cp >= 0x3400 and cp <= 0x4DBF) or
        (cp >= 0x4E00 and cp <= 0x9FFF) or (cp >= 0xA960 and cp <= 0xA97F) or
        (cp >= 0xAC00 and cp <= 0xD7A3) or (cp >= 0xF900 and cp <= 0xFAFF) or
        (cp >= 0xFF01 and cp <= 0xFF60) or (cp >= 0xFFE0 and cp <= 0xFFE6) or
        (cp >= 0x1F300 and cp <= 0x1F64F) or (cp >= 0x1F680 and cp <= 0x1F6FF) or (cp >= 0x1F900 and cp <= 0x1FAFF) or
        (cp >= 0x20000 and cp <= 0x3FFFD);
}

/// Combining marks the shaper centres over their base and gives no advance:
/// the combining-diacritics blocks plus joiners and variation selectors.
/// (`teak.unicode.graphemeBreakClass == .extend` is the exhaustive property;
/// see `isWide` for why this is a range list.)
fn isCombining(cp: u21) bool {
    return (cp >= 0x0300 and cp <= 0x036F) or (cp >= 0x1AB0 and cp <= 0x1AFF) or
        (cp >= 0x1DC0 and cp <= 0x1DFF) or (cp >= 0x20D0 and cp <= 0x20FF) or
        (cp >= 0xFE00 and cp <= 0xFE0F) or (cp >= 0xFE20 and cp <= 0xFE2F) or
        cp == 0x200C or cp == 0x200D or cp == 0x0483 or cp == 0x0484 or cp == 0x0485 or cp == 0x0486 or
        (cp >= 0x0591 and cp <= 0x05BD) or (cp >= 0x064B and cp <= 0x065F);
}

/// Shape `text` into `out`. Without any font the result is empty (count 0,
/// width 0, consumed = text.len): there is nothing to draw or measure.
pub fn shape(text: []const u8, font: FontSpec, out: []ShapedGlyph) ShapeResult {
    const resolved = face_mod.resolveFace(font.family, font.weight) orelse
        return .{ .count = 0, .width = 0, .consumed = text.len };
    const primary = resolved.face;
    const primary_id = resolved.id;
    const primary_scale = primary.scaleForEm(font.size_px);
    const ligatures = font.letter_spacing == 0 and font.family != .mono and !primary.isFixedPitch();

    var count: usize = 0;
    var pos: usize = 0;
    var x: f32 = 0;
    // The last base glyph is finalised when the next base is known (kerning);
    // combining marks emitted after it do not disturb that.
    var have_pending = false;
    var pending_idx: usize = 0;
    var pending_raw: f32 = 0;
    var pending_face: ?*const Font = null;
    var pending_glyph: u16 = 0;
    var pending_scale: f32 = 0;

    while (pos < text.len) {
        const u = nextUnit(primary, primary_id, text, pos, font, ligatures);
        if (u.mark) {
            // Zero advance, centred over the base (the font's own vertical
            // placement is kept). A mark the face lacks is dropped rather than
            // drawn as a missing-glyph box.
            if (u.glyph != 0) {
                if (count == out.len) {
                    if (have_pending) x += finish(&out[pending_idx], pending_raw, font.snapsAdvance());
                    return .{ .count = count, .width = x, .consumed = pos };
                }
                const scale = if (u.face == primary) primary_scale else u.face.scaleForEm(font.size_px);
                const centre = if (have_pending) out[pending_idx].x + pending_raw * 0.5 else x;
                out[count] = .{
                    .glyph = u.glyph,
                    .face = u.face_id,
                    .cluster = @intCast(pos),
                    .x = centre - u.face.inkCenterUnits(u.glyph) * scale,
                    .advance = 0,
                };
                count += 1;
            }
            pos += u.len;
            continue;
        }
        if (have_pending) {
            if (pending_face == u.face) {
                const k = u.face.kernUnits(pending_glyph, u.glyph);
                pending_raw += @as(f32, @floatFromInt(k)) * pending_scale;
            }
            x += finish(&out[pending_idx], pending_raw, font.snapsAdvance());
        }
        if (count == out.len) {
            return .{ .count = count, .width = x, .consumed = pos };
        }
        const scale = if (u.face == primary) primary_scale else u.face.scaleForEm(font.size_px);
        out[count] = .{
            .glyph = u.glyph,
            .face = u.face_id,
            .cluster = @intCast(pos),
            .x = x,
            .advance = 0,
        };
        pending_raw = if (u.wide) font.size_px + font.letter_spacing else @as(f32, @floatFromInt(u.adv orelse @as(u16, @intCast(@max(0, u.face.advanceUnits(u.glyph)))))) * scale + font.letter_spacing;
        pending_face = u.face;
        pending_glyph = u.glyph;
        pending_scale = scale;
        pending_idx = count;
        have_pending = true;
        count += 1;
        pos += u.len;
    }
    if (have_pending) x += finish(&out[pending_idx], pending_raw, font.snapsAdvance());
    return .{ .count = count, .width = x, .consumed = pos };
}

fn finish(g: *ShapedGlyph, raw: f32, snap: bool) f32 {
    const adv = if (snap) @round(raw) else raw;
    g.advance = adv;
    return adv;
}

/// The `teak.Shaper` interface value for the built-in shaper. Stateless.
pub fn shaper() teak.Shaper {
    const S = struct {
        fn call(_: *anyopaque, text: []const u8, font: FontSpec, out: []ShapedGlyph) ShapeResult {
            return shape(text, font, out);
        }
    };
    return .{ .ctx = undefined, .shape_fn = &S.call };
}
