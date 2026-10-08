//! Pure data conversions for the Win32 host's clipboard / drag-and-drop
//! (no Win32 calls, so they are unit-tested on every OS): CF_DIB bitmaps to
//! RGBA, nearest-neighbour resizing, and the PNG + thumbnail pair that makes
//! a pasted / dropped image the same `Drop{kind = .image}` the web host
//! produces.

const std = @import("std");
const teak = @import("teak");

/// Largest long side of the PNG handed to the app (the web host's limit).
pub const max_image_side: u32 = 1568;
/// Long side of the `thumb_rgba` preview.
pub const thumb_side: u32 = 64;
/// Refuse bitmaps beyond this many pixels (a hostile / corrupt header).
const max_pixels: u64 = 64 * 1024 * 1024;

pub const Rgba = struct {
    w: u32,
    h: u32,
    /// Tightly packed RGBA8, top row first. Owned by the allocator given.
    pixels: []u8,
};

pub const DibError = error{ UnsupportedDib, CorruptDib, OutOfMemory };

/// Decode a packed DIB (`BITMAPINFOHEADER` + pixels, the payload of CF_DIB):
/// 24 or 32 bits per pixel, uncompressed or `BI_BITFIELDS` (the standard BGRA
/// masks are assumed). Bottom-up rows are flipped. A 32-bit bitmap whose alpha
/// bytes are all zero (the unused byte of `BI_RGB`) is treated as opaque.
pub fn dibToRgba(a: std.mem.Allocator, dib: []const u8) DibError!Rgba {
    if (dib.len < 40) return error.CorruptDib;
    const header_size = std.mem.readInt(u32, dib[0..4], .little);
    const width = std.mem.readInt(i32, dib[4..8], .little);
    const height_raw = std.mem.readInt(i32, dib[8..12], .little);
    const bpp = std.mem.readInt(u16, dib[14..16], .little);
    const compression = std.mem.readInt(u32, dib[16..20], .little);
    const clr_used = std.mem.readInt(u32, dib[32..36], .little);
    if (header_size < 40 or width <= 0 or height_raw == 0) return error.CorruptDib;
    if ((bpp != 24 and bpp != 32) or (compression != 0 and compression != 3)) return error.UnsupportedDib;

    const w: u32 = @intCast(width);
    const bottom_up = height_raw > 0;
    const h: u32 = @intCast(if (bottom_up) height_raw else -@as(i64, height_raw));
    if (@as(u64, w) * h > max_pixels) return error.UnsupportedDib;

    const masks: usize = if (compression == 3 and header_size == 40) 12 else 0;
    const offset = @as(usize, header_size) + masks + @as(usize, clr_used) * 4;
    const stride = (@as(usize, w) * bpp + 31) / 32 * 4;
    if (offset > dib.len or stride * h > dib.len - offset) return error.CorruptDib;
    const bytes = bpp / 8;

    const out = try a.alloc(u8, @as(usize, w) * h * 4);
    errdefer a.free(out);
    var any_alpha = false;
    for (0..h) |row| {
        const src_row = if (bottom_up) h - 1 - row else row;
        const src = dib[offset + src_row * stride ..][0 .. @as(usize, w) * bytes];
        const dst = out[row * w * 4 ..][0 .. @as(usize, w) * 4];
        for (0..w) |x| {
            const p = src[x * bytes ..];
            dst[x * 4 + 0] = p[2];
            dst[x * 4 + 1] = p[1];
            dst[x * 4 + 2] = p[0];
            const al: u8 = if (bytes == 4) p[3] else 255;
            dst[x * 4 + 3] = al;
            if (al != 0) any_alpha = true;
        }
    }
    if (!any_alpha) {
        var i: usize = 3;
        while (i < out.len) : (i += 4) out[i] = 255;
    }
    return .{ .w = w, .h = h, .pixels = out };
}

/// Nearest-neighbour copy of `img` scaled so its long side is at most
/// `max_side` (an unscaled copy when it already fits). Caller frees `pixels`.
pub fn fitLongSide(a: std.mem.Allocator, img: Rgba, max_side: u32) std.mem.Allocator.Error!Rgba {
    const long = @max(img.w, img.h);
    if (long <= max_side) return .{ .w = img.w, .h = img.h, .pixels = try a.dupe(u8, img.pixels) };
    const nw: u32 = @max(1, @as(u32, @intCast(@as(u64, img.w) * max_side / long)));
    const nh: u32 = @max(1, @as(u32, @intCast(@as(u64, img.h) * max_side / long)));
    const out = try a.alloc(u8, @as(usize, nw) * nh * 4);
    for (0..nh) |y| {
        const sy = @as(usize, y) * img.h / nh;
        for (0..nw) |x| {
            const sx = @as(usize, x) * img.w / nw;
            @memcpy(out[(y * nw + x) * 4 ..][0..4], img.pixels[(sy * img.w + sx) * 4 ..][0..4]);
        }
    }
    return .{ .w = nw, .h = nh, .pixels = out };
}

pub const ImageParts = struct {
    png: []u8,
    w: u32,
    h: u32,
    thumb: []u8,
    thumb_w: u32,
    thumb_h: u32,
};

/// The PNG (long side <= `max_image_side`) and RGBA thumbnail of a decoded
/// bitmap, ready to fill a `Drop`. Caller frees `png` and `thumb`.
pub fn imageParts(a: std.mem.Allocator, img: Rgba) !ImageParts {
    const fit = try fitLongSide(a, img, max_image_side);
    defer a.free(fit.pixels);
    const png = try teak.headless.encodePng(a, fit.pixels, fit.w, fit.h);
    errdefer a.free(png);
    const th = try fitLongSide(a, fit, thumb_side);
    return .{ .png = png, .w = fit.w, .h = fit.h, .thumb = th.pixels, .thumb_w = th.w, .thumb_h = th.h };
}

fn testDib(a: std.mem.Allocator, w: i32, h: i32, bpp: u16, pixels: []const u8) ![]u8 {
    const stride = (@as(usize, @intCast(w)) * bpp + 31) / 32 * 4;
    const rows: usize = @intCast(@abs(h));
    const dib = try a.alloc(u8, 40 + stride * rows);
    @memset(dib, 0);
    std.mem.writeInt(u32, dib[0..4], 40, .little);
    std.mem.writeInt(i32, dib[4..8], w, .little);
    std.mem.writeInt(i32, dib[8..12], h, .little);
    std.mem.writeInt(u16, dib[12..14], 1, .little);
    std.mem.writeInt(u16, dib[14..16], bpp, .little);
    @memcpy(dib[40..][0..pixels.len], pixels);
    return dib;
}

test "dibToRgba flips a bottom-up 24-bit bitmap and swaps BGR to RGB" {
    const a = std.testing.allocator;
    // 2x2, rows padded to 8 bytes. Bottom row first: (B,G,R) = blue, white.
    const px = [_]u8{
        255, 0, 0, 255, 255, 255, 0, 0, // bottom row: blue, white, pad
        0, 0, 255, 0, 255, 0, 0, 0, // top row: red, green, pad
    };
    const dib = try testDib(a, 2, 2, 24, &px);
    defer a.free(dib);
    const img = try dibToRgba(a, dib);
    defer a.free(img.pixels);
    try std.testing.expectEqual(@as(u32, 2), img.w);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255 }, img.pixels);
}

test "dibToRgba: a 32-bit bitmap with all-zero alpha is opaque; real alpha is kept" {
    const a = std.testing.allocator;
    const zero_alpha = try testDib(a, 1, 1, 32, &.{ 10, 20, 30, 0 });
    defer a.free(zero_alpha);
    const o = try dibToRgba(a, zero_alpha);
    defer a.free(o.pixels);
    try std.testing.expectEqualSlices(u8, &.{ 30, 20, 10, 255 }, o.pixels);
    const with_alpha = try testDib(a, 1, 1, 32, &.{ 10, 20, 30, 128 });
    defer a.free(with_alpha);
    const p = try dibToRgba(a, with_alpha);
    defer a.free(p.pixels);
    try std.testing.expectEqualSlices(u8, &.{ 30, 20, 10, 128 }, p.pixels);
}

test "dibToRgba rejects truncated, unsupported and absurd bitmaps" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.CorruptDib, dibToRgba(a, "short"));
    const good = try testDib(a, 4, 4, 32, &(@as([64]u8, @splat(1))));
    defer a.free(good);
    try std.testing.expectError(error.CorruptDib, dibToRgba(a, good[0 .. good.len - 1]));
    const bad_bpp = try testDib(a, 1, 1, 16, &.{ 0, 0 });
    defer a.free(bad_bpp);
    try std.testing.expectError(error.UnsupportedDib, dibToRgba(a, bad_bpp));
    const huge = try testDib(a, 1, 1, 32, &.{ 0, 0, 0, 0 });
    defer a.free(huge);
    std.mem.writeInt(i32, huge[4..8], 100_000, .little);
    std.mem.writeInt(i32, huge[8..12], 100_000, .little);
    try std.testing.expectError(error.UnsupportedDib, dibToRgba(a, huge));
}

test "imageParts bounds the PNG and thumbnail and keeps the aspect ratio" {
    const a = std.testing.allocator;
    const w = 3136; // twice the PNG limit
    const h = 1568;
    const pixels = try a.alloc(u8, w * h * 4);
    defer a.free(pixels);
    @memset(pixels, 200);
    const parts = try imageParts(a, .{ .w = w, .h = h, .pixels = pixels });
    defer a.free(parts.png);
    defer a.free(parts.thumb);
    try std.testing.expectEqual(@as(u32, 1568), parts.w);
    try std.testing.expectEqual(@as(u32, 784), parts.h);
    try std.testing.expectEqual(@as(u32, 64), parts.thumb_w);
    try std.testing.expectEqual(@as(u32, 32), parts.thumb_h);
    try std.testing.expectEqual(@as(usize, 64 * 32 * 4), parts.thumb.len);
    try std.testing.expect(std.mem.startsWith(u8, parts.png, "\x89PNG"));
}
