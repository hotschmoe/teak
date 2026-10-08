//! wgpu rasterizer provider for the native text path (string -> BGRA bitmap).
//! Places glyphs from the shared `SimpleShaper`, so pens match the measurer.
//! Superseded by the glyph-atlas path (text-engine PR4).

const std = @import("std");
const teak = @import("teak");
const face_mod = @import("face.zig");
const shaper = @import("shaper.zig");

const FontSpec = teak.FontSpec;
const c = face_mod.c;

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

/// wgpu rasterizer provider. Reuses two scratch buffers across calls so a
/// per-frame text run allocates nothing once warmed. The returned
/// `Bitmap` views `bgra` and is valid only until the next `rasterize`.
pub const StbttRasterizer = struct {
    allocator: std.mem.Allocator,
    cover: std.ArrayListUnmanaged(u8) = .empty,
    bgra: std.ArrayListUnmanaged(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) !StbttRasterizer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *StbttRasterizer) void {
        self.cover.deinit(self.allocator);
        self.bgra.deinit(self.allocator);
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

        const face = face_mod.faceFor(font_spec.family, font_spec.weight) orelse return null;
        const vm = face.vMetrics(font_spec.size_px);
        var pen_x: f32 = 0;
        const baseline: i32 = @intFromFloat(@round(vm.ascent));

        var glyphs: [128]teak.ShapedGlyph = undefined;
        var pos: usize = 0;
        while (pos < text_bytes.len) {
            // Same shaper as the measurer, so pens agree with layout.
            const res = shaper.shape(text_bytes[pos..], font_spec, &glyphs);
            if (res.consumed == 0) break;
            for (glyphs[0..res.count]) |g| {
                const gface = face_mod.faceById(g.face) orelse face;
                var gw: c_int = 0;
                var gh: c_int = 0;
                var xoff: c_int = 0;
                var yoff: c_int = 0;
                const gscale = gface.scaleForEm(font_spec.size_px);
                const bmp = c.stbtt_GetGlyphBitmap(&gface.info, gscale, gscale, g.glyph, &gw, &gh, &xoff, &yoff);
                if (bmp != null and gw > 0 and gh > 0) {
                    blit(self.cover.items, w, h, bmp, @intCast(gw), @intCast(gh), @as(i32, @intFromFloat(@round(pen_x + g.x))) + xoff, baseline + yoff);
                }
                if (bmp != null) c.stbtt_FreeBitmap(bmp, null);
            }
            pen_x += res.width;
            pos += res.consumed;
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

test "stbtt: the system fallback rasterizes non-empty coverage" {
    defer face_mod.releaseFaces();
    var rast = StbttRasterizer.init(std.testing.allocator) catch unreachable;
    defer rast.deinit();
    // No system font on this builder: skip rather than fail.
    if (face_mod.faceFor(.mono, .regular) == null) return;

    const bmp = rast.rasterize("Hi", .{ .family = .mono, .size_px = 24 }, .{ 1, 1, 1, 1 }, 48, 32) orelse
        return error.RasterizeFailed;
    try std.testing.expectEqual(@as(u32, 48), bmp.width);
    try std.testing.expectEqual(@as(u32, 32), bmp.height);
    try std.testing.expectEqual(@as(usize, 48 * 32 * 4), bmp.pixels.len);

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
