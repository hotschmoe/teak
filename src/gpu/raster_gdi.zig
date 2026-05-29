//! GDI glyph rasterizer — the Windows "rasterizer provider" consumed by
//! `wgpu_core.Gpu(Surface, Rasterizer)`. Produces a `core.Bitmap`
//! (BGRA8, top-down, `[b, g, r, coverage]` per pixel) that `wgpu_core`
//! uploads into a `BGRA8Unorm` texture. The stb_truetype counterpart for
//! Linux lives in `raster_stbtt.zig`.
//!
//! All Win32/GDI `extern` blocks live here and are only ever compiled
//! when `native.zig` binds this rasterizer for a Windows target — the
//! Linux translation unit never sees them, so no comptime gating is
//! needed.
//!
//! Lifetime contract: `rasterize` returns a view into an internal DIB
//! that stays valid until the *next* `rasterize` (or `deinit`) call. The
//! caller must upload the pixels before rasterizing again.

const std = @import("std");
const teak = @import("teak");
const Bitmap = @import("wgpu_core.zig").Bitmap;

const FontSpec = teak.FontSpec;
const FontFamily = teak.FontFamily;

// ── Win32 types + GDI externs ──────────────────────────────────────

const WINAPI = std.builtin.CallingConvention.winapi;
const BOOL = c_int;
const UINT = c_uint;
const DWORD = c_ulong;
const HANDLE = *anyopaque;
const HDC = *anyopaque;
const HBITMAP = *anyopaque;
const HFONT = *anyopaque;
const LPCWSTR = [*:0]const u16;
const COLORREF = DWORD;

const RECT = extern struct {
    left: c_long,
    top: c_long,
    right: c_long,
    bottom: c_long,
};

const BITMAPINFOHEADER = extern struct {
    biSize: DWORD = @sizeOf(BITMAPINFOHEADER),
    biWidth: c_long = 0,
    biHeight: c_long = 0,
    biPlanes: u16 = 1,
    biBitCount: u16 = 32,
    biCompression: DWORD = 0, // BI_RGB
    biSizeImage: DWORD = 0,
    biXPelsPerMeter: c_long = 0,
    biYPelsPerMeter: c_long = 0,
    biClrUsed: DWORD = 0,
    biClrImportant: DWORD = 0,
};

const BITMAPINFO = extern struct {
    bmiHeader: BITMAPINFOHEADER,
    bmiColors: [4]u8 = [_]u8{0} ** 4, // placeholder for the palette tail
};

const FW_NORMAL: c_int = 400;
const DEFAULT_CHARSET: DWORD = 1;
const OUT_TT_PRECIS: DWORD = 4;
const CLIP_DEFAULT_PRECIS: DWORD = 0;
const CLEARTYPE_QUALITY: DWORD = 5;
const DEFAULT_PITCH: DWORD = 0;
const DIB_RGB_COLORS: UINT = 0;
const TRANSPARENT_BK: c_int = 1;
const DT_LEFT: UINT = 0x0000;
const DT_TOP: UINT = 0x0000;
const DT_SINGLELINE: UINT = 0x0020;
const DT_NOPREFIX: UINT = 0x0800;

extern "user32" fn GetDC(?HANDLE) callconv(WINAPI) ?HDC;
extern "user32" fn ReleaseDC(?HANDLE, HDC) callconv(WINAPI) c_int;
extern "user32" fn DrawTextW(HDC, LPCWSTR, c_int, *RECT, UINT) callconv(WINAPI) c_int;
extern "gdi32" fn CreateCompatibleDC(?HDC) callconv(WINAPI) ?HDC;
extern "gdi32" fn DeleteDC(HDC) callconv(WINAPI) BOOL;
extern "gdi32" fn CreateDIBSection(?HDC, *const BITMAPINFO, UINT, *?*anyopaque, ?HANDLE, DWORD) callconv(WINAPI) ?HBITMAP;
extern "gdi32" fn CreateFontW(
    c_int,
    c_int,
    c_int,
    c_int,
    c_int,
    DWORD,
    DWORD,
    DWORD,
    DWORD,
    DWORD,
    DWORD,
    DWORD,
    DWORD,
    LPCWSTR,
) callconv(WINAPI) ?HFONT;
extern "gdi32" fn SelectObject(HDC, HANDLE) callconv(WINAPI) ?HANDLE;
extern "gdi32" fn DeleteObject(HANDLE) callconv(WINAPI) BOOL;
extern "gdi32" fn SetTextColor(HDC, COLORREF) callconv(WINAPI) COLORREF;
extern "gdi32" fn SetBkMode(HDC, c_int) callconv(WINAPI) c_int;

const FACE_SANS = std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI");
const FACE_SERIF = std.unicode.utf8ToUtf16LeStringLiteral("Cambria");
const FACE_MONO = std.unicode.utf8ToUtf16LeStringLiteral("Cascadia Mono");

fn fontFaceUtf16(family: FontFamily) LPCWSTR {
    return switch (family) {
        .sans => FACE_SANS,
        .serif => FACE_SERIF,
        .mono => FACE_MONO,
    };
}

const FontCacheEntry = struct {
    family: FontFamily,
    size_px: u16,
    hfont: HFONT,
};

// ── GdiRasterizer ──────────────────────────────────────────────────

pub const GdiRasterizer = struct {
    /// Memory DC for rasterization. Separate from the Host's measurement
    /// DC — keeps Host and Gpu decoupled.
    dc: HDC,
    font_cache: [8]FontCacheEntry,
    font_cache_len: usize,
    /// DIB + its replaced bitmap from the most recent `rasterize`. Held
    /// alive so the returned `Bitmap.pixels` stays valid until the next
    /// call; freed by `releaseCurrent`.
    cur_hbmp: ?HBITMAP,
    cur_old_bmp: ?HANDLE,

    /// `_allocator` is accepted for parity with the stb_truetype
    /// rasterizer (which owns a font buffer); GDI sources everything from
    /// the OS and ignores it.
    pub fn init(_: std.mem.Allocator) !GdiRasterizer {
        const screen_dc = GetDC(null) orelse return error.GetDcFailed;
        defer _ = ReleaseDC(null, screen_dc);
        const dc = CreateCompatibleDC(screen_dc) orelse return error.CreateDcFailed;
        return .{
            .dc = dc,
            .font_cache = undefined,
            .font_cache_len = 0,
            .cur_hbmp = null,
            .cur_old_bmp = null,
        };
    }

    pub fn deinit(self: *GdiRasterizer) void {
        self.releaseCurrent();
        for (self.font_cache[0..self.font_cache_len]) |e| {
            _ = DeleteObject(e.hfont);
        }
        _ = DeleteDC(self.dc);
    }

    fn releaseCurrent(self: *GdiRasterizer) void {
        if (self.cur_hbmp) |prev| {
            if (self.cur_old_bmp) |ob| _ = SelectObject(self.dc, ob);
            _ = DeleteObject(prev);
            self.cur_hbmp = null;
            self.cur_old_bmp = null;
        }
    }

    /// Rasterize `text_bytes` into a `width × height` BGRA8 bitmap with
    /// the glyphs filled in `color` and alpha = coverage. White glyphs
    /// are drawn on a zeroed background, then a post-pass derives
    /// coverage from luminance and stamps the target color. Returns null
    /// on font / DIB failure.
    pub fn rasterize(
        self: *GdiRasterizer,
        text_bytes: []const u8,
        font: FontSpec,
        color: [4]f32,
        width: u32,
        height: u32,
    ) ?Bitmap {
        self.releaseCurrent();

        const hfont = self.getOrCreateFont(font) orelse return null;

        // CreateDIBSection with negative height yields top-down rows,
        // matching wgpu's texture-upload row order.
        var bi = BITMAPINFO{
            .bmiHeader = .{
                .biWidth = @intCast(width),
                .biHeight = -@as(c_long, @intCast(height)),
                .biPlanes = 1,
                .biBitCount = 32,
                .biCompression = 0, // BI_RGB
            },
        };
        var pixels: ?*anyopaque = null;
        const hbmp = CreateDIBSection(self.dc, &bi, DIB_RGB_COLORS, &pixels, null, 0) orelse return null;
        const pixel_bytes: [*]u8 = @ptrCast(pixels orelse {
            _ = DeleteObject(hbmp);
            return null;
        });

        // Select the DIB + font; remember the replaced bitmap so
        // `releaseCurrent` can restore it before deleting the DIB.
        const old_bmp = SelectObject(self.dc, hbmp);
        self.cur_hbmp = hbmp;
        self.cur_old_bmp = old_bmp;
        _ = SelectObject(self.dc, hfont);
        _ = SetTextColor(self.dc, 0x00FFFFFF); // BGR white
        _ = SetBkMode(self.dc, TRANSPARENT_BK);

        var rect = RECT{
            .left = 0,
            .top = 0,
            .right = @intCast(width),
            .bottom = @intCast(height),
        };

        var utf16_buf: [1024]u16 = undefined;
        const utf16_len = std.unicode.utf8ToUtf16Le(&utf16_buf, text_bytes) catch 0;
        if (utf16_len > 0) {
            _ = DrawTextW(
                self.dc,
                @ptrCast(&utf16_buf),
                @intCast(utf16_len),
                &rect,
                DT_LEFT | DT_TOP | DT_SINGLELINE | DT_NOPREFIX,
            );
        }

        // Post-pass: convert grayscale-in-BGR into alpha, then stamp the
        // target color into BGR.
        const total_pixels = @as(usize, width) * @as(usize, height);
        const r_byte: u8 = @intFromFloat(std.math.clamp(color[0], 0, 1) * 255);
        const g_byte: u8 = @intFromFloat(std.math.clamp(color[1], 0, 1) * 255);
        const b_byte: u8 = @intFromFloat(std.math.clamp(color[2], 0, 1) * 255);
        var i: usize = 0;
        while (i < total_pixels) : (i += 1) {
            const off = i * 4;
            // CreateDIBSection stores BGRA little-endian (B, G, R, A).
            const bb = pixel_bytes[off + 0];
            const gg = pixel_bytes[off + 1];
            const rr = pixel_bytes[off + 2];
            const coverage = @max(@max(bb, gg), rr);
            pixel_bytes[off + 0] = b_byte;
            pixel_bytes[off + 1] = g_byte;
            pixel_bytes[off + 2] = r_byte;
            pixel_bytes[off + 3] = coverage;
        }

        return Bitmap{
            .pixels = pixel_bytes[0 .. total_pixels * 4],
            .width = width,
            .height = height,
        };
    }

    fn getOrCreateFont(self: *GdiRasterizer, font: FontSpec) ?HFONT {
        const size_px: u16 = @intFromFloat(font.size_px);
        for (self.font_cache[0..self.font_cache_len]) |*e| {
            if (e.family == font.family and e.size_px == size_px) return e.hfont;
        }
        if (self.font_cache_len >= self.font_cache.len) return null;

        const hfont = CreateFontW(
            -@as(c_int, @intCast(size_px)),
            0,
            0,
            0,
            FW_NORMAL,
            0,
            0,
            0,
            DEFAULT_CHARSET,
            OUT_TT_PRECIS,
            CLIP_DEFAULT_PRECIS,
            CLEARTYPE_QUALITY,
            DEFAULT_PITCH,
            fontFaceUtf16(font.family),
        ) orelse return null;

        self.font_cache[self.font_cache_len] = .{
            .family = font.family,
            .size_px = size_px,
            .hfont = hfont,
        };
        self.font_cache_len += 1;
        return hfont;
    }
};
