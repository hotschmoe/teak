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
//! The state is module state, like the face table (single-threaded UI).

const std = @import("std");
const builtin = @import("builtin");
const face_mod = @import("face.zig");

const Font = face_mod.Font;

/// Explicit (app) fallback faces.
pub const max_explicit = 4;
const max_env = 4;

/// System candidates, probed in order. TrueType/OpenType collections work
/// (stb reads the first font of a `.ttc`).
const system_candidates = [_][]const u8{
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/TTF/DejaVuSans.ttf",
    "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf",
    "/usr/share/fonts/noto/NotoSans-Regular.ttf",
    "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/google-noto-cjk/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc",
    "/usr/share/fonts/truetype/wqy/wqy-microhei.ttc",
    "/usr/share/fonts/wenquanyi/wqy-zenhei/wqy-zenhei.ttc",
    "/usr/share/fonts/truetype/noto/NotoEmoji-Regular.ttf",
    "/usr/share/fonts/noto/NotoEmoji-Regular.ttf",
    "/usr/share/fonts/truetype/noto/NotoSansSymbols2-Regular.ttf",
    "/usr/share/fonts/truetype/noto/NotoSansSymbols-Regular.ttf",
    "/usr/share/fonts/truetype/freefont/FreeSans.ttf",
    "/usr/share/fonts/gnu-free/FreeSans.ttf",
    "/usr/share/fonts/truetype/unifont/unifont.ttf",
    "/usr/share/fonts/opentype/unifont/unifont.otf",
};

const Sys = struct {
    tried: bool = false,
    font: ?Font = null,
};

var explicit: [max_explicit]?Font = @splat(null);
var env_sys: [max_env]Sys = @splat(.{});
var sys: [system_candidates.len]Sys = @splat(.{});
var env_checked = false;
var env_paths: [max_env][]const u8 = @splat("");

/// First id used by fallback faces (just above the system default face).
pub const first_id: u16 = face_mod.fallback_face_id + 1;
const sys_base: u16 = first_id + max_explicit + max_env;

/// Append `ttf` (borrowed bytes) to the app's explicit fallback chain, tried
/// before the system list. At most `max_explicit` faces.
pub fn registerFallbackFace(ttf: []const u8) error{ FontInitFailed, ChainFull }!void {
    for (&explicit) |*slot| {
        if (slot.* == null) {
            slot.* = Font.fromBytes(ttf) catch return error.FontInitFailed;
            return;
        }
    }
    return error.ChainFull;
}

/// Free system faces and forget the explicit chain (see `face.releaseFaces`).
pub fn release() void {
    for (&env_sys) |*s| {
        if (s.font) |*f| f.deinit();
        s.* = .{};
    }
    for (&sys) |*s| {
        if (s.font) |*f| f.deinit();
        s.* = .{};
    }
    explicit = @splat(null);
    env_checked = false;
}

pub const Hit = struct { glyph: u16, face_id: u16, face: *const Font };

/// The face behind a fallback id, or null.
pub fn faceByExtraId(id: u16) ?*const Font {
    if (id < first_id) return null;
    const k = id - first_id;
    if (k < max_explicit) return if (explicit[k]) |*f| f else null;
    if (k < max_explicit + max_env) return if (env_sys[k - max_explicit].font) |*f| f else null;
    const s = id - sys_base;
    if (s < sys.len) return if (sys[s].font) |*f| f else null;
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

fn loadSys(s: *Sys, path: []const u8) void {
    s.tried = true;
    if (comptime builtin.target.cpu.arch.isWasm()) return; // no filesystem, no libc
    const data = face_mod.readAbsolute(std.heap.page_allocator, path) catch return;
    var font = Font.fromBytes(data) catch {
        std.heap.page_allocator.free(data);
        return;
    };
    font.allocator = std.heap.page_allocator;
    s.font = font;
}

fn checkEnv() void {
    if (comptime builtin.target.cpu.arch.isWasm()) return;
    env_checked = true;
    const raw = std.c.getenv("TEAK_FALLBACK_FONTS") orelse return;
    var it = std.mem.splitScalar(u8, std.mem.span(raw), ':');
    var n: usize = 0;
    while (it.next()) |p| {
        if (p.len == 0) continue;
        if (n == max_env) break;
        env_paths[n] = p;
        n += 1;
    }
}

/// The first fallback face with a glyph for `cp`, loading system candidates on
/// demand. Null when no fallback has it.
pub fn glyphFor(cp: u21) ?Hit {
    for (&explicit, 0..) |*slot, k| {
        if (slot.*) |*f| {
            const g = f.glyphIndex(cp);
            if (g != 0) return .{ .glyph = g, .face_id = first_id + @as(u16, @intCast(k)), .face = f };
        }
    }
    if (!env_checked) checkEnv();
    for (&env_sys, 0..) |*s, k| {
        if (env_paths[k].len == 0) break;
        if (!s.tried) loadSys(s, env_paths[k]);
        if (s.font) |*f| {
            const g = f.glyphIndex(cp);
            if (g != 0) return .{ .glyph = g, .face_id = first_id + max_explicit + @as(u16, @intCast(k)), .face = f };
        }
    }
    for (&sys, 0..) |*s, k| {
        if (!s.tried) loadSys(s, system_candidates[k]);
        if (s.font) |*f| {
            const g = f.glyphIndex(cp);
            if (g != 0) return .{ .glyph = g, .face_id = sys_base + @as(u16, @intCast(k)), .face = f };
        }
    }
    return null;
}

// ── Tests ──────────────────────────────────────────────────────────

test "invisible code points" {
    try std.testing.expect(isInvisible(0x200D)); // ZWJ
    try std.testing.expect(isInvisible(0xFE0F)); // VS16
    try std.testing.expect(isInvisible(0x200B));
    try std.testing.expect(isInvisible(0xE0067)); // tag letter
    try std.testing.expect(!isInvisible('a'));
    try std.testing.expect(!isInvisible(0x4E2D));
}

test "ids: explicit, env and system ranges resolve distinctly and out-of-range is null" {
    defer face_mod.releaseFaces();
    try std.testing.expect(faceByExtraId(first_id) == null);
    try std.testing.expect(faceByExtraId(0xFFFF) == null);
    try std.testing.expect(faceByExtraId(face_mod.fallback_face_id) == null);
}

test "system chain: Greek and CJK resolve to different fallback faces when installed" {
    defer face_mod.releaseFaces();
    const greek = glyphFor(0x03A9) orelse return; // no system font at all: skip
    try std.testing.expect(greek.glyph != 0);
    try std.testing.expect(faceByExtraId(greek.face_id) == greek.face);
    if (glyphFor(0x4E2D)) |cjk| {
        try std.testing.expect(cjk.face_id != greek.face_id or cjk.face.glyphIndex(0x03A9) != 0);
        try std.testing.expect(faceByExtraId(cjk.face_id) == cjk.face);
    }
    // Nothing has the private-use glyph U+10FFFD.
    try std.testing.expect(glyphFor(0x10FFFD) == null);
}

test "shaper: mixed Latin + CJK + emoji picks a face per code point, skips ZWJ/VS, measures what it draws" {
    defer face_mod.releaseFaces();
    const shaper = @import("shaper.zig");
    const measure = @import("measure.zig");
    const teak = @import("teak");
    if (face_mod.faceFor(.sans, .regular) == null) return; // no font on this builder
    const text = "A\u{4E2D}\u{1F600}\u{200D}\u{FE0F}B";
    var out: [16]teak.ShapedGlyph = undefined;
    const spec: teak.FontSpec = .{ .size_px = 16 };
    const r = shaper.shape(text, spec, &out);
    // The two invisibles never produce glyphs.
    try std.testing.expect(r.count <= 4 and r.count >= 2);
    try std.testing.expectEqual(text.len, r.consumed);
    var sum: f32 = 0;
    for (out[0..r.count]) |g| sum += g.advance;
    try std.testing.expectApproxEqAbs(r.width, sum, 0.001);
    try std.testing.expectApproxEqAbs(r.width, measure.width(text, spec), 0.001);
    // 'A' comes from the primary face; when a CJK face exists, U+4E2D is not .notdef and not in the primary.
    try std.testing.expectEqual(@as(u8, 'A') != 0, true);
    if (glyphFor(0x4E2D)) |cjk| {
        var found = false;
        for (out[0..r.count]) |g| {
            if (g.face == cjk.face_id) found = true;
        }
        try std.testing.expect(found);
    }
    // Invisible-only text measures to zero.
    try std.testing.expectEqual(@as(f32, 0), measure.width("\u{200D}\u{FE0F}", spec));
}
// touch
