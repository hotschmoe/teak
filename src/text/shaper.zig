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
    return .{ .glyph = m.glyph, .face_id = m.face_id, .face = m.face, .len = d.len };
}

/// Shape `text` into `out`. Without any font the result is empty (count 0,
/// width 0, consumed = text.len): there is nothing to draw or measure.
pub fn shape(text: []const u8, font: FontSpec, out: []ShapedGlyph) ShapeResult {
    const resolved = face_mod.resolveFace(font.family, font.weight) orelse
        return .{ .count = 0, .width = 0, .consumed = text.len };
    const primary = resolved.face;
    const primary_id = resolved.id;
    const ligatures = font.letter_spacing == 0 and font.family != .mono and !primary.isFixedPitch();

    var count: usize = 0;
    var pos: usize = 0;
    var x: f32 = 0;
    // The last emitted glyph is finalised when the next unit is known (kerning).
    var pending_raw: f32 = 0;
    var pending_face: ?*const Font = null;
    var pending_glyph: u16 = 0;
    var pending_scale: f32 = 0;

    while (pos < text.len) {
        const u = nextUnit(primary, primary_id, text, pos, font, ligatures);
        if (count > 0) {
            if (pending_face == u.face) {
                const k = u.face.kernUnits(pending_glyph, u.glyph);
                pending_raw += @as(f32, @floatFromInt(k)) * pending_scale;
            }
            x += finish(&out[count - 1], pending_raw, font.snapsAdvance());
        }
        if (count == out.len) {
            return .{ .count = count, .width = x, .consumed = pos };
        }
        const scale = u.face.scaleForEm(font.size_px);
        out[count] = .{
            .glyph = u.glyph,
            .face = u.face_id,
            .cluster = @intCast(pos),
            .x = x,
            .advance = 0,
        };
        pending_raw = @as(f32, @floatFromInt(u.face.advanceUnits(u.glyph))) * scale + font.letter_spacing;
        pending_face = u.face;
        pending_glyph = u.glyph;
        pending_scale = scale;
        count += 1;
        pos += u.len;
    }
    if (count > 0) x += finish(&out[count - 1], pending_raw, font.snapsAdvance());
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
