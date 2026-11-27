//! Glyph fallback for the native text path (text-engine section 11, risk 2).
//!
//! When the requested face (and the other weights of its family) lack a glyph,
//! the shaper asks here. The chain, in order:
//!
//!   1. the other REGISTERED families (`registerFace`), nearest family first
//!      (done in `shaper.mapGlyph`, which already knows the face table);
//!   2. the app's explicit fallback faces (`registerFallbackFace`, in order);
//!   3. a generic last-resort list probed from common system paths: faces from
//!      `TEAK_FALLBACK_FONTS` (colon-separated absolute paths) first, then
//!      DejaVu Sans (symbols, Greek, Cyrillic, Hebrew, Arabic), Noto Sans / Noto
//!      Sans CJK / WenQuanYi (CJK), Noto Emoji / Noto Sans Symbols (monochrome
//!      emoji and symbols), FreeSans, Unifont.
//!
//! System faces load lazily, once, the first time a code point needs them
//! (a missing file is remembered, never probed again); a 16 MB CJK collection
//! costs nothing until CJK text appears. No fontconfig, no runtime dependency
//! on any particular font: if nothing has the glyph the primary face's `.notdef`
//! (tofu) is used. Colour emoji fonts (CBDT/COLR) are not rasterizable by stb
//! and are skipped by design: emoji render monochrome when a monochrome emoji
//! face exists (Noto Emoji, DejaVu Sans' pictographs).
//!
//! Faces get ids above `face.fallback_face_id`, so `face.faceById` resolves them
//! for the measurer, the rasterizer and the atlas alike -- measurement and
//! raster agree because both go through the shaper's per-code-point choice.
//!
//! The chain lives in the `TextState` (single-threaded UI).

const teak = @import("teak");
const face_mod = @import("face.zig");
const text_state = @import("text_state.zig");

const Font = face_mod.Font;
const TextState = text_state.TextState;

/// Explicit (app) fallback faces.
pub const max_explicit = 4;
const max_env = 4;

pub const system_count = 20;

const Sys = struct {
    tried: bool = false,
    font: ?Font = null,
};

pub const Chain = struct {
    explicit: [max_explicit]?Font = @splat(null),
    env_sys: [max_env]Sys = @splat(.{}),
    sys: [system_count]Sys = @splat(.{}),
};

/// First id used by fallback faces (just above the system default face).
pub const first_id: u16 = face_mod.fallback_face_id + 1;
const sys_base: u16 = first_id + max_explicit + max_env;

/// Append `ttf` (borrowed bytes) to the app's explicit fallback chain, tried
/// before the system list. At most `max_explicit` faces.
pub fn registerFallbackFace(
    state: *TextState,
    ttf: []const u8,
) error{ FontInitFailed, ChainFull }!void {
    for (&state.chain.explicit) |*slot| {
        if (slot.* == null) {
            slot.* = Font.fromBytes(ttf) catch return error.FontInitFailed;
            state.faces_changed();
            return;
        }
    }
    state.counts.fallback_refused += 1;
    return error.ChainFull;
}

/// Free system faces and forget the explicit chain (see `face.releaseFaces`).
pub fn release(state: *TextState) void {
    const chain = &state.chain;
    for (&chain.env_sys) |*s| {
        if (s.font) |*f| f.deinit();
        s.* = .{};
    }
    for (&chain.sys) |*s| {
        if (s.font) |*f| f.deinit();
        s.* = .{};
    }
    chain.explicit = @splat(null);
    teak.assert(chain.explicit[0] == null and chain.sys[0].font == null);
}

pub const Hit = struct { glyph: u16, face_id: u16, face: *const Font };

/// The face behind a fallback id, or null.
pub fn faceByExtraId(state: *const TextState, id: u16) ?*const Font {
    if (id < first_id) return null;
    const chain = &state.chain;
    const k = id - first_id;
    if (k < max_explicit) return if (chain.explicit[k]) |*f| f else null;
    if (k < max_explicit + max_env) {
        return if (chain.env_sys[k - max_explicit].font) |*f| f else null;
    }
    const s = id - sys_base;
    if (s < chain.sys.len) return if (chain.sys[s].font) |*f| f else null;
    return null;
}

/// Code points that draw nothing and take no space (ZWJ, variation selectors,
/// ZW(N)J/ZWSP, bidi marks, word joiner, BOM, emoji tags, skin-tone-free
/// default-ignorables). The shaper skips them instead of drawing tofu.
pub fn isInvisible(cp: u21) bool {
    return switch (cp) {
        0x00AD, 0x034F, 0x061C, 0x115F, 0x1160, 0x17B4, 0x17B5, 0x180B...0x180F => true,
        0x200B...0x200F, 0x202A...0x202E, 0x2060...0x206F, 0xFE00...0xFE0F, 0xFEFF => true,
        0xE0001, 0xE0020...0xE007F, 0xE0100...0xE01EF => true,
        else => false,
    };
}

fn loadSys(state: *TextState, s: *Sys, index: u16) void {
    s.tried = true;
    s.font = face_mod.load_fallback(state, index) catch return;
}

/// The first fallback face with a glyph for `cp`, loading system candidates on
/// demand. Null when no fallback has it.
pub fn glyphFor(state: *TextState, cp: u21) ?Hit {
    const chain = &state.chain;
    for (&chain.explicit, 0..) |*slot, k| {
        if (slot.*) |*f| {
            const g = f.glyphIndex(cp);
            if (g != 0) return .{ .glyph = g, .face_id = first_id + @as(u16, @intCast(k)), .face = f };
        }
    }
    for (&chain.env_sys, 0..) |*s, k| {
        if (!s.tried) loadSys(state, s, @intCast(k));
        if (s.font) |*f| {
            const g = f.glyphIndex(cp);
            if (g != 0) return .{ .glyph = g, .face_id = first_id + max_explicit + @as(u16, @intCast(k)), .face = f };
        }
    }
    for (&chain.sys, 0..) |*s, k| {
        if (!s.tried) loadSys(state, s, @intCast(max_env + k));
        if (s.font) |*f| {
            const g = f.glyphIndex(cp);
            if (g != 0) return .{ .glyph = g, .face_id = sys_base + @as(u16, @intCast(k)), .face = f };
        }
    }
    return null;
}
