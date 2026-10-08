//! Font faces for the `teak-text` module: the stb_truetype `Font` wrapper,
//! the (family, weight) face table and the system-font fallback. Shared by the
//! shaper, the measurer and the rasterizer so they cannot drift.
//!
//! Faces: an app registers up to three per family, one per weight, with
//! `registerFace` (the X11 `Host.registerFont`; the bytes are typically an
//! `@embedFile`). A request takes the registered weight nearest the one
//! asked for (lighter wins a tie); a family with no registered face falls
//! back to a system monospace TTF (`TEAK_FONT` overrides the search).
//!
//! The table is module state (this module is instantiated once and shared
//! by the Host and the Gpu; they have no other common object). The UI is
//! single-threaded.
//!
//! Pure CPU + libc: no wgpu, no X11. stb's edge-list temporaries go
//! through STBTT_malloc -> libc malloc/free (see stb_truetype_impl.c), so
//! the consuming target links libc.

const std = @import("std");
const builtin = @import("builtin");
const teak = @import("teak");

pub const c = @import("stb-c");

/// Font search order. `TEAK_FONT` (absolute path) overrides everything;
/// otherwise the first readable candidate wins. DejaVuSansMono leads
/// because a monospace face matches the framework's measurement
/// heritage and keeps columns aligned.
const FONT_CANDIDATES = [_][]const u8{
    "C:\\Windows\\Fonts\\consola.ttf",
    "C:\\Windows\\Fonts\\cour.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
    "/usr/share/fonts/dejavu/DejaVuSansMono.ttf",
    "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
};

const MAX_FONT_BYTES: usize = 32 * 1024 * 1024;

/// A TTF face. `info` holds pointers into `data`, which must outlive it:
/// either owned here (a system font; freed by `deinit`) or borrowed from the
/// app (a registered face: static bytes, never freed).
pub const Font = struct {
    data: []const u8,
    info: c.stbtt_fontinfo,
    /// Set when `data` was allocated by `loadSystem`.
    allocator: ?std.mem.Allocator = null,
    /// Glyph id and advance (font units) of every ASCII code point, filled at
    /// load: the shaper's hot path never touches the cmap/hmtx tables for it.
    ascii_gid: [128]u16 = @splat(0),
    ascii_adv: [128]u16 = @splat(0),

    /// Wrap `ttf` without copying it. The bytes must stay alive and unchanged.
    pub fn fromBytes(ttf: []const u8) !Font {
        var info: c.stbtt_fontinfo = undefined;
        const offset = c.stbtt_GetFontOffsetForIndex(ttf.ptr, 0);
        if (offset < 0 or c.stbtt_InitFont(&info, ttf.ptr, offset) == 0) {
            return error.FontInitFailed;
        }
        var font: Font = .{ .data = ttf, .info = info };
        for (0..128) |cp| {
            const g = font.glyphIndexSlow(@intCast(cp));
            font.ascii_gid[cp] = g;
            font.ascii_adv[cp] = @intCast(@max(0, font.advanceUnits(g)));
        }
        return font;
    }

    /// Load the system fallback face (`TEAK_FONT`, else the candidate list).
    pub fn loadSystem(allocator: std.mem.Allocator) !Font {
        const data = try readFontFile(allocator);
        errdefer allocator.free(data);
        var font = try fromBytes(data);
        font.allocator = allocator;
        return font;
    }

    pub fn deinit(self: *Font) void {
        if (self.allocator) |a| a.free(self.data);
        self.* = undefined;
    }

    /// Font units -> pixels with `size_px` as the EM size, like CSS `px` and
    /// GDI's negative `CreateFont` height (not stb's ascent-to-descent height,
    /// which makes the same size_px smaller than on the other backends).
    pub fn scaleForEm(self: *const Font, size_px: f32) f32 {
        return c.stbtt_ScaleForMappingEmToPixels(&self.info, size_px);
    }

    pub const VMetrics = struct { ascent: f32, descent: f32, line_gap: f32 };

    /// Vertical metrics in pixels at `size_px`. `descent` is returned
    /// positive (distance below baseline) for convenience.
    pub fn vMetrics(self: *const Font, size_px: f32) VMetrics {
        var ascent: c_int = 0;
        var descent: c_int = 0;
        var line_gap: c_int = 0;
        c.stbtt_GetFontVMetrics(&self.info, &ascent, &descent, &line_gap);
        const s = self.scaleForEm(size_px);
        return .{
            .ascent = @as(f32, @floatFromInt(ascent)) * s,
            .descent = @as(f32, @floatFromInt(-descent)) * s,
            .line_gap = @as(f32, @floatFromInt(line_gap)) * s,
        };
    }

    /// Glyph id for `cp` (0 = the face has no glyph).
    pub fn glyphIndex(self: *const Font, cp: u21) u16 {
        if (cp < 128) return self.ascii_gid[cp];
        return self.glyphIndexSlow(cp);
    }

    fn glyphIndexSlow(self: *const Font, cp: u21) u16 {
        const g = c.stbtt_FindGlyphIndex(&self.info, @intCast(cp));
        return if (g < 0 or g > std.math.maxInt(u16)) 0 else @intCast(g);
    }

    /// Horizontal advance of glyph `gid`, in font units.
    pub fn advanceUnits(self: *const Font, gid: u16) i32 {
        var advance: c_int = 0;
        var lsb: c_int = 0;
        c.stbtt_GetGlyphHMetrics(&self.info, gid, &advance, &lsb);
        return advance;
    }

    /// Kerning between two glyphs of this face, in font units (legacy `kern`
    /// table or GPOS pair adjustment, whichever stb finds).
    pub fn kernUnits(self: *const Font, left: u16, right: u16) i32 {
        return c.stbtt_GetGlyphKernAdvance(&self.info, left, right);
    }

    /// True when the face has one advance for every glyph probed ('i' and 'W').
    /// Ligatures are skipped on such faces so they cannot break a grid.
    pub fn isFixedPitch(self: *const Font) bool {
        const i = self.glyphIndex('i');
        const w = self.glyphIndex('W');
        if (i == 0 or w == 0) return false;
        return self.advanceUnits(i) == self.advanceUnits(w);
    }
};

// ── Face table ─────────────────────────────────────────────────────

const family_count = std.enums.values(teak.FontFamily).len;
const weight_count = std.enums.values(teak.FontWeight).len;

const Registry = struct {
    faces: [family_count][weight_count]?Font = @splat(@splat(null)),
    /// System fallback, loaded on first use. `fallback_tried` stops a missing
    /// font from being searched for again every frame.
    fallback: ?Font = null,
    fallback_tried: bool = false,
};

var registry: Registry = .{};

/// Register `ttf` as the face for (`family`, `weight`), replacing an earlier
/// one. The bytes are borrowed: keep them alive (an `@embedFile` slice is).
pub fn registerFace(family: teak.FontFamily, weight: teak.FontWeight, ttf: []const u8) error{FontInitFailed}!void {
    registry.faces[@backingInt(family)][@backingInt(weight)] = Font.fromBytes(ttf) catch return error.FontInitFailed;
}

/// Forget every registered face and the loaded fallback.
pub fn releaseFaces() void {
    if (registry.fallback) |*f| f.deinit();
    registry = .{};
}

/// Face-table index of (`family`, `weight`); also the `ShapedGlyph.face` value.
pub fn faceId(family: teak.FontFamily, weight: teak.FontWeight) u16 {
    return @intCast(@as(usize, @backingInt(family)) * weight_count + @backingInt(weight));
}

/// Face-table index reserved for the system fallback face.
pub const fallback_face_id: u16 = family_count * weight_count;

/// The face behind a `ShapedGlyph.face` id, or null when nothing is registered there.
pub fn faceById(id: u16) ?*const Font {
    if (id == fallback_face_id) {
        if (registry.fallback) |*f| return f;
        return null;
    }
    if (id > fallback_face_id) return null;
    const fam = id / weight_count;
    const w = id % weight_count;
    if (registry.faces[fam][w]) |*f| return f;
    return null;
}

/// The id `faceFor` resolved to (registered weight, system fallback or the
/// any-registered last resort). Null only when no font exists at all.
pub fn resolveFace(family: teak.FontFamily, weight: teak.FontWeight) ?struct { face: *const Font, id: u16 } {
    const f = faceFor(family, weight) orelse return null;
    // faceFor returns a pointer into the registry; recover which slot.
    for (&registry.faces, 0..) |*row, fi| {
        for (row, 0..) |*slot, wi| {
            if (slot.*) |*p| {
                if (p == f) return .{ .face = f, .id = @intCast(fi * weight_count + wi) };
            }
        }
    }
    return .{ .face = f, .id = fallback_face_id };
}

/// The face for a request: the registered weight of `family` nearest to
/// `weight` (lighter on a tie), else the system fallback, else any
/// registered face. Null only when no font exists at all.
pub fn faceFor(family: teak.FontFamily, weight: teak.FontWeight) ?*const Font {
    const row = &registry.faces[@backingInt(family)];
    const want: i32 = @backingInt(weight);
    var best: ?usize = null;
    var best_dist: i32 = std.math.maxInt(i32);
    for (row, 0..) |face, i| {
        if (face == null) continue;
        const dist = @as(i32, @intCast(i)) - want;
        const abs = if (dist < 0) -dist else dist;
        // `row` runs light to heavy, so a strict `<` keeps the lighter on a tie.
        if (abs < best_dist) {
            best = i;
            best_dist = abs;
        }
    }
    if (best) |i| return &row[i].?;

    if (!registry.fallback_tried) {
        registry.fallback_tried = true;
        registry.fallback = Font.loadSystem(std.heap.page_allocator) catch null;
        if (registry.fallback == null) std.log.warn("teak: no font found (register one or set TEAK_FONT); text will not draw", .{});
    }
    if (registry.fallback) |*f| return f;
    for (&registry.faces) |*r| {
        for (r) |*face| {
            if (face.*) |*f| return f;
        }
    }
    return null;
}

/// Windows system fonts tried in order, relative to `<WINDIR>\Fonts`:
/// Consolas (monospace, Vista+), then Courier New, Lucida Console, and the
/// proportional UI faces as a last resort.
const WINDOWS_FONT_FILES = [_][]const u8{ "consola.ttf", "cour.ttf", "lucon.ttf", "segoeui.ttf", "arial.ttf" };

/// The `i`th Windows font candidate under `windir` (e.g. `C:\Windows`) written
/// into `buf`; null past the end of the list or when `buf` is too small.
/// Pure so the probe order is testable on any OS.
pub fn windowsFontCandidate(buf: []u8, windir: []const u8, i: usize) ?[]const u8 {
    if (i >= WINDOWS_FONT_FILES.len) return null;
    return std.fmt.bufPrint(buf, "{s}\\Fonts\\{s}", .{ std.mem.trimEnd(u8, windir, "\\/"), WINDOWS_FONT_FILES[i] }) catch null;
}

fn readFontFile(allocator: std.mem.Allocator) ![]u8 {
    // libc getenv (this module always links libc for stb); non-allocating.
    if (std.c.getenv("TEAK_FONT")) |env_ptr| {
        const env_path = std.mem.span(env_ptr);
        if (env_path.len > 0) {
            if (readAbsolute(allocator, env_path)) |bytes| return bytes else |_| {}
        }
    }
    if (builtin.os.tag == .windows) {
        const windir = if (std.c.getenv("WINDIR")) |w| std.mem.span(w) else "C:\\Windows";
        var buf: [1024]u8 = undefined;
        var i: usize = 0;
        while (windowsFontCandidate(&buf, windir, i)) |path| : (i += 1) {
            if (readAbsolute(allocator, path)) |bytes| return bytes else |_| {}
        }
        return error.FontNotFound;
    }
    for (FONT_CANDIDATES) |path| {
        if (readAbsolute(allocator, path)) |bytes| return bytes else |_| {}
    }
    return error.FontNotFound;
}

/// Read an absolute path via libc stdio. The module already links libc
/// (stb needs it), and Zig's `std.fs`/`std.Io` file API now requires
/// threading an `Io` handle from `main` — impractical for a font load
/// deep inside backend init — so libc `fopen`/`fread` is the pragmatic,
/// churn-proof choice. Reads in chunks; no `fseek`/`fstat` dependency.
fn readAbsolute(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var path_buf: [4096]u8 = undefined;
    if (path.len + 1 > path_buf.len) return error.PathTooLong;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(&path_buf);

    const file = std.c.fopen(path_z, "rb") orelse return error.OpenFailed;
    defer _ = std.c.fclose(file);

    var list: std.ArrayListUnmanaged(u8) = .empty;
    errdefer list.deinit(allocator);
    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        const n = std.c.fread(&chunk, 1, chunk.len, file);
        if (n == 0) break;
        if (list.items.len + n > MAX_FONT_BYTES) return error.FontTooLarge;
        try list.appendSlice(allocator, chunk[0..n]);
    }
    if (list.items.len == 0) return error.EmptyFont;
    return try list.toOwnedSlice(allocator);
}

test "windowsFontCandidate probes monospace faces first under the given Windows dir" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("D:\\Win\\Fonts\\consola.ttf", windowsFontCandidate(&buf, "D:\\Win", 0).?);
    try std.testing.expectEqualStrings("D:\\Win\\Fonts\\cour.ttf", windowsFontCandidate(&buf, "D:\\Win\\", 1).?);
    try std.testing.expect(windowsFontCandidate(&buf, "D:\\Win", WINDOWS_FONT_FILES.len) == null);
    var tiny: [4]u8 = undefined;
    try std.testing.expect(windowsFontCandidate(&tiny, "D:\\Win", 0) == null);
}
