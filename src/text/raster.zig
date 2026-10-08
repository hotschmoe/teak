//! Native glyph rasterizer provider for the wgpu text path. `wgpu_core.Gpu`
//! is generic over this contract (duck-typed, like the Surface provider):
//!
//!   init(Allocator) !Self / deinit
//!   shape(self, text, FontSpec, []ShapedGlyph) ShapeResult   -- one shaper for layout and render
//!   ascent(self, FontSpec, scale) f32                        -- baseline offset at device size
//!   rasterizeGlyph(self, face, gid, size_px, bin) ?GlyphBitmap
//!
//! Glyphs are rasterized one at a time at the physical pixel size with a
//! quarter-pixel x offset (`bin`), into an R8 coverage bitmap the atlas packs.

const std = @import("std");
const teak = @import("teak");
const face_mod = @import("face.zig");
const shaper = @import("shaper.zig");

const c = face_mod.c;

/// R8 glyph coverage, tightly packed, top-down. `bearing_x`/`bearing_y` locate
/// the bitmap's top-left relative to the pen on the baseline (y grows down, so
/// `bearing_y` is usually negative). A zero-size bitmap is a blank glyph.
/// `pixels` is valid until the next `rasterizeGlyph`.
pub const GlyphBitmap = struct {
    pixels: []const u8,
    width: u32,
    height: u32,
    bearing_x: i32,
    bearing_y: i32,
};

/// SDF glyphs are rasterized once at this em size (px), with `sdf_padding` px of
/// distance field around the outline: value `sdf_onedge` (of 255) is the edge,
/// `sdf_dist_scale` byte steps per source pixel. Drawn at any size by scaling the quad.
const sdf_source_em: f32 = 32;
const sdf_padding: c_int = 6;
const sdf_onedge: u8 = 128;
const sdf_dist_scale: f32 = 32;

pub const StbttRasterizer = struct {
    /// Source em size of `rasterizeSdf` bitmaps (px).
    pub const sdf_em: f32 = sdf_source_em;

    allocator: std.mem.Allocator,
    cover: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) !StbttRasterizer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *StbttRasterizer) void {
        self.cover.deinit(self.allocator);
    }

    /// Changes whenever the face table does; the text stage drops cached runs.
    pub fn epoch(_: *const StbttRasterizer) u64 {
        return face_mod.epoch;
    }

    pub fn shape(_: *StbttRasterizer, text: []const u8, font: teak.FontSpec, out: []teak.ShapedGlyph) teak.ShapeResult {
        return shaper.shape(text, font, out);
    }

    /// Ascent in px of `font` at `font.size_px * scale` (0 with no font).
    pub fn ascent(_: *StbttRasterizer, font: teak.FontSpec, scale: f32) f32 {
        const r = face_mod.resolveFace(font.family, font.weight) orelse return 0;
        return r.face.vMetrics(font.size_px * scale).ascent;
    }

    /// The glyph's signed distance field at `sdf_em` (padding included in the
    /// bitmap; bearings are in source px at that size, relative to the baseline pen).
    /// Blank glyphs return a zero-size bitmap. `pixels` is valid until the next call.
    pub fn rasterizeSdf(self: *StbttRasterizer, face: u16, gid: u16) ?GlyphBitmap {
        const f = face_mod.faceById(face) orelse return null;
        const s = f.scaleForEm(sdf_source_em);
        var w: c_int = 0;
        var h: c_int = 0;
        var xoff: c_int = 0;
        var yoff: c_int = 0;
        const px = c.stbtt_GetGlyphSDF(&f.info, s, gid, sdf_padding, sdf_onedge, sdf_dist_scale, &w, &h, &xoff, &yoff);
        if (px == null or w <= 0 or h <= 0) return .{ .pixels = &.{}, .width = 0, .height = 0, .bearing_x = xoff, .bearing_y = yoff };
        defer c.stbtt_FreeSDF(px, null);
        const n: usize = @as(usize, @intCast(w)) * @as(usize, @intCast(h));
        self.cover.resize(self.allocator, n) catch return null;
        @memcpy(self.cover.items, px[0..n]);
        return .{ .pixels = self.cover.items, .width = @intCast(w), .height = @intCast(h), .bearing_x = xoff, .bearing_y = yoff };
    }

    pub fn rasterizeGlyph(self: *StbttRasterizer, face: u16, gid: u16, size_px: f32, bin: u2) ?GlyphBitmap {
        const f = face_mod.faceById(face) orelse return null;
        const s = f.scaleForEm(size_px);
        const shift: f32 = @as(f32, @floatFromInt(bin)) * 0.25;
        var x0: c_int = 0;
        var y0: c_int = 0;
        var x1: c_int = 0;
        var y1: c_int = 0;
        c.stbtt_GetGlyphBitmapBoxSubpixel(&f.info, gid, s, s, shift, 0, &x0, &y0, &x1, &y1);
        const w = x1 - x0;
        const h = y1 - y0;
        if (w <= 0 or h <= 0) return .{ .pixels = &.{}, .width = 0, .height = 0, .bearing_x = x0, .bearing_y = y0 };
        const n: usize = @as(usize, @intCast(w)) * @as(usize, @intCast(h));
        self.cover.resize(self.allocator, n) catch return null;
        @memset(self.cover.items, 0);
        c.stbtt_MakeGlyphBitmapSubpixel(&f.info, self.cover.items.ptr, w, h, w, s, s, shift, 0, gid);
        return .{
            .pixels = self.cover.items,
            .width = @intCast(w),
            .height = @intCast(h),
            .bearing_x = x0,
            .bearing_y = y0,
        };
    }
};

test "rasterizeSdf: edge value at the outline, ~0 far outside, ~255 deep inside" {
    defer face_mod.releaseFaces();
    var rast = StbttRasterizer.init(std.testing.allocator) catch unreachable;
    defer rast.deinit();
    const r = face_mod.resolveFace(.mono, .regular) orelse return;
    const bmp = rast.rasterizeSdf(r.id, r.face.glyphIndex('I')) orelse return error.SdfFailed;
    try std.testing.expect(bmp.width > 2 * sdf_padding and bmp.height > 2 * sdf_padding);
    try std.testing.expectEqual(@as(usize, bmp.width * bmp.height), bmp.pixels.len);
    // The padded corner is far outside the glyph: low; the centre of the stem is inside: high.
    try std.testing.expect(bmp.pixels[0] < 40);
    const cx = bmp.width / 2;
    const cy = bmp.height / 2;
    try std.testing.expect(bmp.pixels[cy * bmp.width + cx] > sdf_onedge);
    const sp = rast.rasterizeSdf(r.id, r.face.glyphIndex(' ')).?;
    try std.testing.expectEqual(@as(u32, 0), sp.width);
}

test "rasterizeGlyph: ink for 'H', blank for space, bins shift coverage" {
    defer face_mod.releaseFaces();
    var rast = StbttRasterizer.init(std.testing.allocator) catch unreachable;
    defer rast.deinit();
    // No system font on this builder: skip rather than fail.
    const r = face_mod.resolveFace(.mono, .regular) orelse return;
    const h_gid = r.face.glyphIndex('H');
    const bmp = rast.rasterizeGlyph(r.id, h_gid, 24, 0) orelse return error.RasterizeFailed;
    try std.testing.expect(bmp.width > 0 and bmp.height > 0);
    try std.testing.expectEqual(@as(usize, bmp.width * bmp.height), bmp.pixels.len);
    var ink: u32 = 0;
    for (bmp.pixels) |p| ink += p;
    try std.testing.expect(ink > 0);
    try std.testing.expect(bmp.bearing_y < 0);
    const sp = rast.rasterizeGlyph(r.id, r.face.glyphIndex(' '), 24, 0).?;
    try std.testing.expectEqual(@as(u32, 0), sp.width);
    var first: [4096]u8 = undefined;
    const n1 = @min(first.len, bmp.pixels.len);
    @memcpy(first[0..n1], bmp.pixels[0..n1]);
    const shifted = rast.rasterizeGlyph(r.id, h_gid, 24, 2).?;
    try std.testing.expect(!std.mem.eql(u8, first[0..n1], shifted.pixels[0..@min(n1, shifted.pixels.len)]));
}
