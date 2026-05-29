//! Shared stb_truetype text backend for the Linux native host.
//!
//! Two consumers, one module, one font — on purpose:
//!   * `StbttRasterizer` is the wgpu *rasterizer provider* (the Linux
//!     counterpart to `raster_gdi.GdiRasterizer`); `native_linux.zig`
//!     binds it into `wgpu_core.Gpu`.
//!   * `Font.measureWidth` / `vMetrics` back the X11 Host's
//!     `TextMeasurer` (`platform/x11.zig`).
//! Layout is driven by the measurer and rendering by the rasterizer, so
//! if they disagreed on metrics the glyphs would clip or mis-place. They
//! share this module — and therefore the same TTF + scale math — so they
//! cannot drift.
//!
//! Pure CPU + libc: no wgpu, no X11. stb's edge-list temporaries go
//! through STBTT_malloc → libc malloc/free (see stb_truetype_impl.c), so
//! the consuming target links libc. v1 loads a single face (monospace by
//! default) and ignores `FontSpec.family`; per-family faces are a future
//! enhancement (the measurer would need matching faces to stay honest).

const std = @import("std");
const teak = @import("teak");

const FontSpec = teak.FontSpec;

const c = @cImport({
    @cInclude("stb_truetype.h");
});

/// Font search order. `TEAK_FONT` (absolute path) overrides everything;
/// otherwise the first readable candidate wins. DejaVuSansMono leads
/// because a monospace face matches the framework's measurement
/// heritage and keeps columns aligned.
const FONT_CANDIDATES = [_][]const u8{
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
    "/usr/share/fonts/dejavu/DejaVuSansMono.ttf",
    "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
};

const MAX_FONT_BYTES: usize = 32 * 1024 * 1024;

/// BGRA8 glyph-run bitmap (`[b, g, r, coverage]` per pixel, top-down),
/// matching `raster_gdi`'s output and ready for a `BGRA8Unorm` texture
/// upload. Mirrors `wgpu_core.Bitmap` structurally; kept local so this
/// module need not import the wgpu layer (`wgpu_core.rasterAndUpload`
/// duck-types the rasterizer's return).
pub const Bitmap = struct {
    pixels: []const u8,
    width: u32,
    height: u32,
};

/// A loaded TTF face. `info` holds pointers into `data`, so `data` must
/// outlive it (owned here; freed by `deinit`).
pub const Font = struct {
    data: []u8,
    info: c.stbtt_fontinfo,
    allocator: std.mem.Allocator,

    pub fn load(allocator: std.mem.Allocator) !Font {
        const data = try readFontFile(allocator);
        errdefer allocator.free(data);

        var info: c.stbtt_fontinfo = undefined;
        const offset = c.stbtt_GetFontOffsetForIndex(data.ptr, 0);
        if (offset < 0 or c.stbtt_InitFont(&info, data.ptr, offset) == 0) {
            return error.FontInitFailed;
        }
        return .{ .data = data, .info = info, .allocator = allocator };
    }

    pub fn deinit(self: *Font) void {
        self.allocator.free(self.data);
        self.* = undefined;
    }

    pub fn scaleForPixelHeight(self: *const Font, size_px: f32) f32 {
        return c.stbtt_ScaleForPixelHeight(&self.info, size_px);
    }

    pub const VMetrics = struct { ascent: f32, descent: f32, line_gap: f32 };

    /// Vertical metrics in pixels at `size_px`. `descent` is returned
    /// positive (distance below baseline) for convenience.
    pub fn vMetrics(self: *const Font, size_px: f32) VMetrics {
        var ascent: c_int = 0;
        var descent: c_int = 0;
        var line_gap: c_int = 0;
        c.stbtt_GetFontVMetrics(&self.info, &ascent, &descent, &line_gap);
        const s = self.scaleForPixelHeight(size_px);
        return .{
            .ascent = @as(f32, @floatFromInt(ascent)) * s,
            .descent = @as(f32, @floatFromInt(-descent)) * s,
            .line_gap = @as(f32, @floatFromInt(line_gap)) * s,
        };
    }

    /// Total advance width of the UTF-8 `text` run, in pixels at `size_px`.
    pub fn measureWidth(self: *const Font, text: []const u8, size_px: f32) f32 {
        const s = self.scaleForPixelHeight(size_px);
        var width: f32 = 0;
        var it = CodepointIterator{ .text = text };
        while (it.next()) |cp| {
            var advance: c_int = 0;
            var lsb: c_int = 0;
            c.stbtt_GetCodepointHMetrics(&self.info, @intCast(cp), &advance, &lsb);
            width += @as(f32, @floatFromInt(advance)) * s;
        }
        return width;
    }
};

/// wgpu rasterizer provider. Reuses two scratch buffers across calls so a
/// per-frame text run allocates nothing once warmed. The returned
/// `Bitmap` views `bgra` and is valid only until the next `rasterize`.
pub const StbttRasterizer = struct {
    font: Font,
    allocator: std.mem.Allocator,
    cover: std.ArrayListUnmanaged(u8) = .empty,
    bgra: std.ArrayListUnmanaged(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) !StbttRasterizer {
        return .{ .font = try Font.load(allocator), .allocator = allocator };
    }

    pub fn deinit(self: *StbttRasterizer) void {
        self.cover.deinit(self.allocator);
        self.bgra.deinit(self.allocator);
        self.font.deinit();
    }

    pub fn rasterize(
        self: *StbttRasterizer,
        text_bytes: []const u8,
        font_spec: FontSpec,
        color: [4]f32,
        width: u32,
        height: u32,
    ) ?Bitmap {
        if (width == 0 or height == 0) return null;
        const w: usize = width;
        const h: usize = height;
        const total = w * h;

        // Coverage buffer, zeroed (transparent background).
        self.cover.resize(self.allocator, total) catch return null;
        @memset(self.cover.items, 0);

        const scale = self.font.scaleForPixelHeight(font_spec.size_px);
        const vm = self.font.vMetrics(font_spec.size_px);
        const baseline: i32 = @intFromFloat(@round(vm.ascent));

        var pen_x: f32 = 0;
        var it = CodepointIterator{ .text = text_bytes };
        while (it.next()) |cp| {
            var advance: c_int = 0;
            var lsb: c_int = 0;
            c.stbtt_GetCodepointHMetrics(&self.font.info, @intCast(cp), &advance, &lsb);

            var gw: c_int = 0;
            var gh: c_int = 0;
            var xoff: c_int = 0;
            var yoff: c_int = 0;
            const glyph = c.stbtt_GetCodepointBitmap(&self.font.info, scale, scale, @intCast(cp), &gw, &gh, &xoff, &yoff);
            if (glyph != null and gw > 0 and gh > 0) {
                blit(self.cover.items, w, h, glyph, @intCast(gw), @intCast(gh), @as(i32, @intFromFloat(@round(pen_x))) + xoff, baseline + yoff);
                c.stbtt_FreeBitmap(glyph, null);
            }

            pen_x += @as(f32, @floatFromInt(advance)) * scale;
        }

        // Expand coverage → BGRA with the requested color stamped in.
        self.bgra.resize(self.allocator, total * 4) catch return null;
        const b_byte: u8 = @intFromFloat(std.math.clamp(color[2], 0, 1) * 255);
        const g_byte: u8 = @intFromFloat(std.math.clamp(color[1], 0, 1) * 255);
        const r_byte: u8 = @intFromFloat(std.math.clamp(color[0], 0, 1) * 255);
        for (self.cover.items, 0..) |coverage, i| {
            const off = i * 4;
            self.bgra.items[off + 0] = b_byte;
            self.bgra.items[off + 1] = g_byte;
            self.bgra.items[off + 2] = r_byte;
            self.bgra.items[off + 3] = coverage;
        }

        return .{ .pixels = self.bgra.items, .width = width, .height = height };
    }
};

/// Copy a `gw × gh` single-channel glyph bitmap into the `w × h` coverage
/// buffer at (`dst_x`, `dst_y`), clipping to bounds. `max` so overlapping
/// glyphs (rare at our spacing) don't erase each other's coverage.
fn blit(dst: []u8, w: usize, h: usize, src: [*c]const u8, gw: usize, gh: usize, dst_x: i32, dst_y: i32) void {
    var gy: usize = 0;
    while (gy < gh) : (gy += 1) {
        const dy = dst_y + @as(i32, @intCast(gy));
        if (dy < 0 or dy >= @as(i32, @intCast(h))) continue;
        var gx: usize = 0;
        while (gx < gw) : (gx += 1) {
            const dx = dst_x + @as(i32, @intCast(gx));
            if (dx < 0 or dx >= @as(i32, @intCast(w))) continue;
            const di = @as(usize, @intCast(dy)) * w + @as(usize, @intCast(dx));
            const sv = src[gy * gw + gx];
            if (sv > dst[di]) dst[di] = sv;
        }
    }
}

/// Minimal UTF-8 → codepoint iterator that degrades to byte-as-codepoint
/// on malformed input rather than erroring (a stray byte should not blank
/// a whole label).
const CodepointIterator = struct {
    text: []const u8,
    i: usize = 0,

    fn next(self: *CodepointIterator) ?u21 {
        if (self.i >= self.text.len) return null;
        const first = self.text[self.i];
        const len = std.unicode.utf8ByteSequenceLength(first) catch {
            self.i += 1;
            return first;
        };
        if (self.i + len > self.text.len) {
            self.i += 1;
            return first;
        }
        const cp = std.unicode.utf8Decode(self.text[self.i .. self.i + len]) catch {
            self.i += 1;
            return first;
        };
        self.i += len;
        return cp;
    }
};

fn readFontFile(allocator: std.mem.Allocator) ![]u8 {
    // libc getenv (this module always links libc for stb); non-allocating.
    if (std.c.getenv("TEAK_FONT")) |env_ptr| {
        const env_path = std.mem.span(env_ptr);
        if (env_path.len > 0) {
            if (readAbsolute(allocator, env_path)) |bytes| return bytes else |_| {}
        }
    }
    for (FONT_CANDIDATES) |path| {
        if (readAbsolute(allocator, path)) |bytes| return bytes else |_| {}
    }
    return error.FontNotFound;
}

/// Read an absolute path via libc stdio. The module already links libc
/// (stb needs it), and Zig 0.16's `std.fs`/`std.Io` file API now requires
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

test "stbtt: loads a font and rasterizes non-empty coverage" {
    var rast = StbttRasterizer.init(std.testing.allocator) catch |e| {
        // No system font on this builder — skip rather than fail. On the
        // dev/CI box DejaVuSansMono is present, so this path is not taken.
        std.debug.print("skipping stbtt test: {s}\n", .{@errorName(e)});
        return;
    };
    defer rast.deinit();

    const bmp = rast.rasterize("Hi", .{ .family = .mono, .size_px = 24 }, .{ 1, 1, 1, 1 }, 48, 32) orelse
        return error.RasterizeFailed;
    try std.testing.expectEqual(@as(u32, 48), bmp.width);
    try std.testing.expectEqual(@as(u32, 32), bmp.height);
    try std.testing.expectEqual(@as(usize, 48 * 32 * 4), bmp.pixels.len);

    // At least one pixel must carry coverage in the alpha channel.
    var inked = false;
    var i: usize = 3;
    while (i < bmp.pixels.len) : (i += 4) {
        if (bmp.pixels[i] > 0) {
            inked = true;
            break;
        }
    }
    try std.testing.expect(inked);
}

test "stbtt: measureWidth is positive and grows with length" {
    var font = Font.load(std.testing.allocator) catch return;
    defer font.deinit();
    const w1 = font.measureWidth("i", 24);
    const w3 = font.measureWidth("iii", 24);
    try std.testing.expect(w1 > 0);
    try std.testing.expect(w3 > w1);
}
