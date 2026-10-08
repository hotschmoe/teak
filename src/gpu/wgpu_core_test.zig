//! Headless tests for the shared wgpu core: the whole UI frame (solid
//! quads, images, 3D scene composites, MSAA resolve) rendered into an
//! offscreen texture on a surface-less device and read back. Run with
//! `zig build test-gpu`; skipped when no Vulkan device opens.

const std = @import("std");
const teak = @import("teak");
const wgpu_c = @import("wgpu_c.zig");
const wgpu_core = @import("wgpu_core.zig");

const c = wgpu_c.c;

const NoSurface = struct {
    pub const Handle = void;
    pub fn createSurface(_: c.WGPUInstance, _: anytype) !c.WGPUSurface {
        return error.NoSurface;
    }
};

/// Glyph provider with box glyphs: every byte shapes to one glyph (advance 8)
/// that rasterizes as a fully covered 6x8 box sitting on the rect's top edge
/// (ascent 8), so text draws show as solid boxes in the draw color.
const BoxRaster = struct {
    const GlyphBitmap = struct { pixels: []const u8, width: u32, height: u32, bearing_x: i32, bearing_y: i32 };
    pixels: [6 * 8]u8 = @splat(255),

    pub fn init(_: std.mem.Allocator) !BoxRaster {
        return .{};
    }
    pub fn deinit(_: *BoxRaster) void {}
    pub fn shape(_: *BoxRaster, text: []const u8, _: teak.FontSpec, out: []teak.ShapedGlyph) teak.ShapeResult {
        const n = @min(text.len, out.len);
        for (text[0..n], 0..) |ch, i| {
            out[i] = .{ .glyph = ch, .face = 0, .cluster = @intCast(i), .x = @floatFromInt(i * 8), .advance = 8 };
        }
        return .{ .count = n, .width = @floatFromInt(n * 8), .consumed = n };
    }
    pub fn ascent(_: *BoxRaster, _: teak.FontSpec, _: f32) f32 {
        return 8; // device px: the box glyph is a fixed size at any scale
    }
    pub fn rasterizeGlyph(self: *BoxRaster, _: u16, gid: u16, size_px: f32, _: u2) ?GlyphBitmap {
        _ = size_px;
        if (gid == ' ') return .{ .pixels = &.{}, .width = 0, .height = 0, .bearing_x = 0, .bearing_y = 0 };
        return .{ .pixels = &self.pixels, .width = 6, .height = 8, .bearing_x = 0, .bearing_y = -8 };
    }
};

const TestGpu = wgpu_core.Gpu(NoSurface, BoxRaster);

comptime {
    teak.validateGpu(TestGpu);
}

const px: u32 = 64;

const Harness = struct {
    gpu: TestGpu,
    target: c.WGPUTexture,

    fn init(options: teak.gpu.InitOptions) !Harness {
        const instance = wgpu_c.createInstance(c.WGPUInstanceBackend_Vulkan) orelse return error.SkipZigTest;
        const ctx = wgpu_c.requestDevice(instance, null) catch return error.SkipZigTest;
        var gpu = try TestGpu.initFromDevice(instance, null, ctx, px, px, options);
        const target = wgpu_c.createTexture2D(gpu.device, "test-target", .{
            .width = px,
            .height = px,
            .format = gpu.surf_format,
            .usage = c.WGPUTextureUsage_RenderAttachment | c.WGPUTextureUsage_CopySrc,
        }) orelse {
            gpu.deinit();
            return error.TargetFailed;
        };
        return .{ .gpu = gpu, .target = target };
    }

    fn deinit(self: *Harness) void {
        c.wgpuTextureRelease(self.target);
        self.gpu.deinit();
    }

    /// Render the staged frame and return BGRA pixels (caller frees).
    fn frame(self: *Harness, clear: [4]f32) ![]u8 {
        self.gpu.renderToTexture(self.target, px, px, clear);
        const ctx: wgpu_c.DeviceContext = .{ .adapter = self.gpu.adapter, .device = self.gpu.device, .queue = self.gpu.queue };
        return wgpu_c.readTexture(std.testing.allocator, ctx, self.target, px, px, 4);
    }
};

fn at(pixels: []const u8, x: u32, y: u32) [4]u8 {
    return pixels[(y * px + x) * 4 ..][0..4].*;
}

fn tri(x0: f32, y0: f32, x1: f32, y1: f32, x2: f32, y2: f32) [3]teak.Vertex {
    const v = struct {
        fn at(x: f32, y: f32) teak.Vertex {
            return .{ .x = x, .y = y, .r = 1, .g = 1, .b = 1, .a = 1, .u = 0, .v = 0 };
        }
    };
    return .{ v.at(x0, y0), v.at(x1, y1), v.at(x2, y2) };
}

/// How many pixels along a diagonal edge are neither background nor fill.
fn partialPixels(pixels: []const u8) usize {
    var n: usize = 0;
    for (0..px) |y| {
        for (0..px) |x| {
            const g = at(pixels, @intCast(x), @intCast(y))[1];
            if (g > 8 and g < 247) n += 1;
        }
    }
    return n;
}

test "MSAA antialiases a diagonal edge; the default pass does not" {
    const t = tri(0, 0, 64, 0, 0, 64);

    var plain = try Harness.init(.{});
    defer plain.deinit();
    plain.gpu.uploadVertices(&t);
    const flat = try plain.frame(.{ 0, 0, 0, 1 });
    defer std.testing.allocator.free(flat);
    try std.testing.expectEqual(@as(usize, 0), partialPixels(flat));
    try std.testing.expectEqual(@as(u8, 255), at(flat, 4, 4)[1]); // inside
    try std.testing.expectEqual(@as(u8, 0), at(flat, 60, 60)[1]); // outside

    var smooth = try Harness.init(.{ .msaa = true });
    defer smooth.deinit();
    smooth.gpu.uploadVertices(&t);
    const aa = try smooth.frame(.{ 0, 0, 0, 1 });
    defer std.testing.allocator.free(aa);
    try std.testing.expect(partialPixels(aa) > 30); // ~one per row/column along the edge
    try std.testing.expectEqual(@as(u8, 255), at(aa, 4, 4)[1]);
    try std.testing.expectEqual(@as(u8, 0), at(aa, 60, 60)[1]);
}

fn flatQuadMesh() struct { v: [4]teak.MeshVertex, i: [6]u32 } {
    const n = [3]f32{ 0, 0, 1 };
    const col = [4]f32{ 1, 0, 0, 1 };
    return .{
        .v = .{
            .{ .pos = .{ -1, -1, 0.5 }, .normal = n, .color = col },
            .{ .pos = .{ 1, -1, 0.5 }, .normal = n, .color = col },
            .{ .pos = .{ 1, 1, 0.5 }, .normal = n, .color = col },
            .{ .pos = .{ -1, 1, 0.5 }, .normal = n, .color = col },
        },
        .i = .{ 0, 1, 2, 0, 2, 3 },
    };
}

fn sceneAt(mesh: teak.MeshHandle, x: f32, y: f32, w: f32, h: f32, clip_x: f32) teak.SceneDraw {
    return .{
        .mesh = mesh,
        .rect_x = x,
        .rect_y = y,
        .rect_w = w,
        .rect_h = h,
        .clip_x = clip_x,
        .clip_y = 0,
        .clip_w = 1000,
        .clip_h = 1000,
        .camera = .{ .eye = .{ 0, 0, 5 }, .light_dir = .{ 0, 0, -1 } },
        .clear = .{ 0, 0.5, 0, 1 },
    };
}

test "a scene is rendered offscreen and composited at its rect, honouring clip" {
    var h = try Harness.init(.{});
    defer h.deinit();

    const q = flatQuadMesh();
    const mesh = h.gpu.uploadMesh(.{ .vertices = &q.v, .indices = &q.i });
    try std.testing.expect(mesh != teak.MESH_HANDLE_NONE);

    // A 32x32 scene at (16, 16); its red quad covers the whole target.
    h.gpu.renderScenes(&.{sceneAt(mesh, 16, 16, 32, 32, 0)}, &.{});
    const full = try h.frame(.{ 0, 0, 0, 1 });
    defer std.testing.allocator.free(full);
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, at(full, 30, 30)); // scene (red, BGRA)
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 255 }, at(full, 4, 4)); // UI background
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 255 }, at(full, 50, 50));
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, at(full, 16, 16)); // exact pixel placement
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 255 }, at(full, 15, 15));

    // Same scene clipped by a scroll container starting at x = 32.
    h.gpu.renderScenes(&.{sceneAt(mesh, 16, 16, 32, 32, 32)}, &.{});
    const clipped = try h.frame(.{ 0, 0, 0, 1 });
    defer std.testing.allocator.free(clipped);
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 255 }, at(clipped, 20, 30)); // clipped away
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, at(clipped, 40, 30)); // still visible

    // No scenes staged: nothing composited.
    h.gpu.renderScenes(&.{}, &.{});
    const none = try h.frame(.{ 0, 0, 0, 1 });
    defer std.testing.allocator.free(none);
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 255 }, at(none, 30, 30));
}

test "images upload, draw and release (slot reuse)" {
    var h = try Harness.init(.{});
    defer h.deinit();

    const red_px: [4][4]u8 = @splat(.{ 255, 0, 0, 255 }); // 2x2 RGBA
    const img = h.gpu.uploadImage(std.mem.asBytes(&red_px), 2, 2);
    try std.testing.expect(img != teak.TEXTURE_HANDLE_NONE);

    h.gpu.uploadImages(&.{.{
        .rect_x = 8,
        .rect_y = 8,
        .rect_w = 16,
        .rect_h = 16,
        .handle = img,
        .tint = .{ 1, 1, 1, 1 },
        .clip_x = 0,
        .clip_y = 0,
        .clip_w = 64,
        .clip_h = 64,
    }});
    const pixels = try h.frame(.{ 0, 0, 0, 1 });
    defer std.testing.allocator.free(pixels);
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, at(pixels, 12, 12)); // red, BGRA order

    h.gpu.releaseImage(img);
    const again = h.gpu.uploadImage(std.mem.asBytes(&red_px), 2, 2);
    try std.testing.expectEqual(img, again);
}

test "the image cache grows past 64 slots and every image draws in one frame" {
    var h = try Harness.init(.{});
    defer h.deinit();

    // 200 distinct 1x1 images, each a different red level, drawn as a
    // 14x14 grid of 4px cells (cell i at column i%14, row i/14).
    const n = 200;
    var handles: [n]teak.TextureHandle = undefined;
    var draws: [n]teak.ImageDraw = undefined;
    for (0..n) |i| {
        const rgba = [4]u8{ @intCast(50 + i), 0, 0, 255 };
        handles[i] = h.gpu.uploadImage(&rgba, 1, 1);
        try std.testing.expect(handles[i] != teak.TEXTURE_HANDLE_NONE);
        draws[i] = .{
            .rect_x = @floatFromInt((i % 14) * 4),
            .rect_y = @floatFromInt((i / 14) * 4),
            .rect_w = 4,
            .rect_h = 4,
            .handle = handles[i],
            .tint = .{ 1, 1, 1, 1 },
            .clip_x = 0,
            .clip_y = 0,
            .clip_w = 64,
            .clip_h = 64,
        };
    }
    h.gpu.uploadImages(&draws);
    const pixels = try h.frame(.{ 0, 0, 0, 1 });
    defer std.testing.allocator.free(pixels);
    for (0..n) |i| {
        const got = at(pixels, @intCast((i % 14) * 4 + 2), @intCast((i / 14) * 4 + 2));
        try std.testing.expectEqual(@as(u8, @intCast(50 + i)), got[2]); // red channel (BGRA)
    }

    // Releasing in the middle and re-uploading reuses the freed slot.
    h.gpu.releaseImage(handles[100]);
    const again = h.gpu.uploadImage(&[4]u8{ 1, 2, 3, 255 }, 1, 1);
    try std.testing.expectEqual(handles[100], again);
    for (handles) |hd| h.gpu.releaseImage(hd);
}

fn textAt(x: f32, y: f32, w: f32, h: f32, content: []const u8) teak.TextDraw {
    return .{
        .rect_x = x,
        .rect_y = y,
        .rect_w = w,
        .rect_h = h,
        .content = content,
        .font = .{},
        .color = .{ 1, 1, 1, 1 },
        .clip_x = 0,
        .clip_y = 0,
        .clip_w = px,
        .clip_h = px,
    };
}

fn solidQuad(out: *[6]teak.Vertex, x0: f32, y0: f32, x1: f32, y1: f32, rgb: [3]f32) void {
    const v = struct {
        fn at(x: f32, y: f32, col: [3]f32) teak.Vertex {
            return .{ .x = x, .y = y, .r = col[0], .g = col[1], .b = col[2], .a = 1, .u = 0, .v = 0 };
        }
    };
    out.* = .{ v.at(x0, y0, rgb), v.at(x1, y0, rgb), v.at(x0, y1, rgb), v.at(x1, y0, rgb), v.at(x1, y1, rgb), v.at(x0, y1, rgb) };
}

test "overlay layering: an opaque overlay hides base text and images, overlay text stays on top" {
    var h = try Harness.init(.{});
    defer h.deinit();

    // Overlay panel: opaque red 0..40. Base text A (8,8) lies under it;
    // overlay text B (8,24) is part of the overlay layer; image under it.
    var quad: [6]teak.Vertex = undefined;
    solidQuad(&quad, 0, 0, 40, 40, .{ 1, 0, 0 });
    const texts = [_]teak.TextDraw{ textAt(8, 8, 16, 8, "ba"), textAt(8, 24, 16, 8, "ov") };
    const green_px: [4][4]u8 = @splat(.{ 0, 255, 0, 255 });
    const img = h.gpu.uploadImage(std.mem.asBytes(&green_px), 2, 2);
    const images = [_]teak.ImageDraw{.{
        .rect_x = 24,
        .rect_y = 8,
        .rect_w = 8,
        .rect_h = 8,
        .handle = img,
        .tint = .{ 1, 1, 1, 1 },
        .clip_x = 0,
        .clip_y = 0,
        .clip_w = px,
        .clip_h = px,
    }};

    // Without a split everything is drawn by kind: the base text and the
    // base image paint OVER the overlay's quad (the bug).
    h.gpu.uploadVertices(&quad);
    h.gpu.uploadText(&texts);
    h.gpu.uploadImages(&images);
    const by_kind = try h.frame(.{ 0, 0, 0, 1 });
    defer std.testing.allocator.free(by_kind);
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, at(by_kind, 12, 11)); // base text on top of the quad
    try std.testing.expectEqual([4]u8{ 0, 255, 0, 255 }, at(by_kind, 28, 11)); // base image too

    // With the split: base text (1) and image (1) end before the overlay.
    h.gpu.setOverlayStart(.{ .verts = 0, .text = 1, .images = 1, .scenes = 0 });
    h.gpu.uploadVertices(&quad);
    h.gpu.uploadText(&texts);
    h.gpu.uploadImages(&images);
    const layered = try h.frame(.{ 0, 0, 0, 1 });
    defer std.testing.allocator.free(layered);
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, at(layered, 12, 11)); // red quad hides base text (BGRA)
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, at(layered, 28, 11)); // ... and the base image
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, at(layered, 12, 27)); // overlay text is on top of the quad
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 255 }, at(layered, 50, 50)); // outside everything
}

test "overlay layering: base content below the split still draws in painter order" {
    var h = try Harness.init(.{});
    defer h.deinit();
    // Base: blue quad (0..20) then base text over it; overlay: red quad
    // (10..30) that hides the part of both it overlaps.
    var quads: [12]teak.Vertex = undefined;
    solidQuad(quads[0..6], 0, 0, 20, 20, .{ 0, 0, 1 });
    solidQuad(quads[6..12], 10, 10, 30, 30, .{ 1, 0, 0 });
    const texts = [_]teak.TextDraw{textAt(2, 2, 16, 8, "ba")};
    h.gpu.setOverlayStart(.{ .verts = 6, .text = 1, .images = 0, .scenes = 0 });
    h.gpu.uploadVertices(&quads);
    h.gpu.uploadText(&texts);
    const f = try h.frame(.{ 0, 0, 0, 1 });
    defer std.testing.allocator.free(f);
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, at(f, 5, 5)); // base text over the base quad
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, at(f, 5, 15)); // base quad, no text there (BGRA blue)
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, at(f, 25, 25)); // overlay quad
}

test "initOffscreen: renderFrame presents to the offscreen target and readFrame returns RGBA" {
    var gpu = TestGpu.initOffscreen(px, px, .{ .msaa = true }) catch |e| switch (e) {
        error.AdapterFailed, error.DeviceFailed, error.InstanceCreateFailed => return error.SkipZigTest,
        else => return e,
    };
    defer gpu.deinit();

    var quad: [6]teak.Vertex = undefined;
    solidQuad(&quad, 8, 8, 40, 40, .{ 1, 0.5, 0 });
    gpu.uploadVertices(&quad);
    gpu.renderFrame(.{ 0, 0, 1, 1 });
    const rgba = try gpu.readFrame(std.testing.allocator);
    defer std.testing.allocator.free(rgba);
    try std.testing.expectEqual(@as(usize, px * px * 4), rgba.len);
    const inside = rgba[(20 * px + 20) * 4 ..][0..4].*;
    try std.testing.expectEqual(@as(u8, 255), inside[0]); // R first: RGBA, not BGRA
    try std.testing.expect(inside[1] >= 126 and inside[1] <= 129);
    try std.testing.expectEqual(@as(u8, 0), inside[2]);
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, rgba[(50 * px + 50) * 4 ..][0..4].*); // clear colour

    // Resizing recreates the target; the next frame has the new size.
    gpu.resize(32, 32);
    gpu.uploadVertices(&quad);
    gpu.renderFrame(.{ 0, 1, 0, 1 });
    const small = try gpu.readFrame(std.testing.allocator);
    defer std.testing.allocator.free(small);
    try std.testing.expectEqual(@as(usize, 32 * 32 * 4), small.len);
}

test "readFrame on a windowed (non-offscreen) Gpu is an error" {
    var h = try Harness.init(.{});
    defer h.deinit();
    try std.testing.expectError(error.NotOffscreen, h.gpu.readFrame(std.testing.allocator));
}

fn colored(d: teak.TextDraw, rgba: [4]f32) teak.TextDraw {
    var out = d;
    out.color = rgba;
    return out;
}

test "atlas text: glyph boxes land at the pen, take the draw colour, and are scissored by the clip" {
    var h = try Harness.init(.{});
    defer h.deinit();
    var red = colored(textAt(4, 4, 24, 8, "ab"), .{ 1, 0, 0, 1 });
    red.clip_w = 15; // clip x 0..15 cuts the second glyph (12..18) after 3 px
    const green = colored(textAt(4, 30, 16, 8, "c"), .{ 0, 1, 0, 1 });
    h.gpu.uploadText(&.{ red, green });
    const f = try h.frame(.{ 0, 0, 0, 1 });
    defer std.testing.allocator.free(f);
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, at(f, 5, 5)); // first glyph, red (BGRA)
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 255 }, at(f, 3, 5)); // left of the pen
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 255 }, at(f, 10, 5)); // gap between boxes (6 wide, advance 8)
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, at(f, 13, 5)); // second glyph inside the clip
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 255 }, at(f, 16, 5)); // second glyph beyond the clip
    try std.testing.expectEqual([4]u8{ 0, 255, 0, 255 }, at(f, 6, 33)); // per-glyph colour
    try std.testing.expectEqual(@as(u32, 0), h.gpu.text.dropped);
    // Repeating the same glyphs hits the atlas: no new page, no regrowth.
    try std.testing.expectEqual(@as(usize, 1), h.gpu.text.atlas.pageCount());
}

test "atlas text: exhausting max_atlas_pages drops glyphs, keeps rendering, and recovers next frame" {
    var h = try Harness.init(.{ .max_atlas_pages = 1 });
    defer h.deinit();
    // 100 sizes x 128 glyphs = 12800 distinct 6x8 cells (8x10 padded) > one 1 MiB page.
    var content: [128]u8 = undefined;
    for (&content, 0..) |*ch, i| ch.* = @intCast(i + 33);
    var draws: [100]teak.TextDraw = undefined;
    for (&draws, 0..) |*d, i| {
        d.* = textAt(0, 0, 64, 8, &content);
        d.font.size_px = 10 + @as(f32, @floatFromInt(i)) * 0.25;
    }
    h.gpu.uploadText(&draws);
    try std.testing.expect(h.gpu.text.dropped > 0);
    const f = try h.frame(.{ 0, 0, 0, 1 });
    defer std.testing.allocator.free(f);
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, at(f, 2, 2)); // still drew what fit
    // A calm frame afterwards recycles the page (gen bump) and renders again.
    h.gpu.uploadText(&.{textAt(4, 4, 16, 8, "a")});
    try std.testing.expectEqual(@as(u32, 0), h.gpu.text.dropped);
    const g = try h.frame(.{ 0, 0, 0, 1 });
    defer std.testing.allocator.free(g);
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, at(g, 5, 5));
}

test "atlas text: scale 2 places glyphs in device pixels and scales solids as vectors" {
    var h = try Harness.init(.{ .scale = 2 });
    defer h.deinit();
    var quad: [6]teak.Vertex = undefined;
    solidQuad(&quad, 20, 20, 30, 30, .{ 0, 0, 1 }); // logical -> device 40..60
    h.gpu.uploadVertices(&quad);
    // Logical (4,4) is device (8,8); the 6x8 box covers device 8..14 x 8..16.
    var d = textAt(4, 4, 16, 8, "a");
    d.clip_w = 32;
    d.clip_h = 32;
    h.gpu.uploadText(&.{d});
    const f = try h.frame(.{ 0, 0, 0, 1 });
    defer std.testing.allocator.free(f);
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, at(f, 9, 9));
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 255 }, at(f, 5, 9));
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, at(f, 50, 50)); // blue (BGRA) quad scaled 2x
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 255 }, at(f, 35, 50));
}

test "HiDPI scale 2: a 3D scene renders at device resolution (hard edge, no magnification blur)" {
    var h = try Harness.init(.{ .scale = 2, .scene_msaa = false });
    defer h.deinit();
    // Two quads meeting at x = 0.12 (an odd fraction of the target), red on
    // the left, green on the right: only a device-resolution target puts the
    // seam at device x = 19; a logical target magnified 2x puts it at 20.
    const n = [3]f32{ 0, 0, 1 };
    const red = [4]f32{ 1, 0, 0, 1 };
    const green = [4]f32{ 0, 1, 0, 1 };
    const v = [8]teak.MeshVertex{
        .{ .pos = .{ -1, -1, 0.5 }, .normal = n, .color = red },
        .{ .pos = .{ 0.12, -1, 0.5 }, .normal = n, .color = red },
        .{ .pos = .{ 0.12, 1, 0.5 }, .normal = n, .color = red },
        .{ .pos = .{ -1, 1, 0.5 }, .normal = n, .color = red },
        .{ .pos = .{ 0.12, -1, 0.5 }, .normal = n, .color = green },
        .{ .pos = .{ 1, -1, 0.5 }, .normal = n, .color = green },
        .{ .pos = .{ 1, 1, 0.5 }, .normal = n, .color = green },
        .{ .pos = .{ 0.12, 1, 0.5 }, .normal = n, .color = green },
    };
    const idx = [12]u32{ 0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7 };
    const mesh = h.gpu.uploadMesh(.{ .vertices = &v, .indices = &idx });
    // Logical (4,4)-(14,14) is device (8,8)-(28,28); the seam falls at device x = 19.
    h.gpu.renderScenes(&.{sceneAt(mesh, 4, 4, 10, 10, 0)});
    const f = try h.frame(.{ 0, 0, 0, 1 });
    defer std.testing.allocator.free(f);
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, at(f, 8, 8)); // red (BGRA)
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, at(f, 18, 20)); // last red column
    try std.testing.expectEqual([4]u8{ 0, 255, 0, 255 }, at(f, 19, 20)); // first green column
    try std.testing.expectEqual([4]u8{ 0, 255, 0, 255 }, at(f, 27, 27));
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 255 }, at(f, 7, 8)); // outside the scene
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 255 }, at(f, 28, 27));
}

test "HiDPI scale 2: a 1-logical-px line is exactly 2 device px wide with hard edges" {
    var h = try Harness.init(.{ .scale = 2 });
    defer h.deinit();
    var line: [6]teak.Vertex = undefined;
    solidQuad(&line, 10, 4, 11, 28, .{ 1, 1, 1 }); // logical x 10..11 -> device 20..22
    h.gpu.uploadVertices(&line);
    const f = try h.frame(.{ 0, 0, 0, 1 });
    defer std.testing.allocator.free(f);
    const white = [4]u8{ 255, 255, 255, 255 };
    const bg = [4]u8{ 0, 0, 0, 255 };
    try std.testing.expectEqual(bg, at(f, 19, 30));
    try std.testing.expectEqual(white, at(f, 20, 30));
    try std.testing.expectEqual(white, at(f, 21, 30));
    try std.testing.expectEqual(bg, at(f, 22, 30));
}

test "HiDPI scale 2: an image drawn 1 texel per device pixel keeps every texel sharp" {
    var h = try Harness.init(.{ .scale = 2 });
    defer h.deinit();
    // 4x4 checker of pure red / green texels (RGBA).
    var rgba: [4 * 4 * 4]u8 = undefined;
    for (0..16) |i| {
        const red = ((i % 4) + (i / 4)) % 2 == 0;
        rgba[i * 4 ..][0..4].* = if (red) .{ 255, 0, 0, 255 } else .{ 0, 255, 0, 255 };
    }
    const img = h.gpu.uploadImage(&rgba, 4, 4);
    try std.testing.expect(img != teak.TEXTURE_HANDLE_NONE);
    // 2x2 logical px at (4,4) = 4x4 device px at (8,8): exactly 1:1.
    h.gpu.uploadImages(&.{.{
        .rect_x = 4,
        .rect_y = 4,
        .rect_w = 2,
        .rect_h = 2,
        .handle = img,
        .tint = .{ 1, 1, 1, 1 },
        .clip_x = 0,
        .clip_y = 0,
        .clip_w = 32,
        .clip_h = 32,
    }});
    const f = try h.frame(.{ 0, 0, 0, 1 });
    defer std.testing.allocator.free(f);
    for (0..4) |y| {
        for (0..4) |x| {
            const want: [4]u8 = if ((x + y) % 2 == 0) .{ 0, 0, 255, 255 } else .{ 0, 255, 0, 255 }; // BGRA
            try std.testing.expectEqual(want, at(f, @intCast(8 + x), @intCast(8 + y)));
        }
    }
}

// ── SDF quads: rounded rects, borders, gradients, soft shadows ─────

const sdf = teak.render.sdf;
const full_clip = teak.Rect{ .x = 0, .y = 0, .w = px, .h = px };

fn stage(h: *Harness, specs: []const sdf.Spec) !void {
    var verts: std.ArrayList(teak.Vertex) = .empty;
    defer verts.deinit(std.testing.allocator);
    for (specs) |sp| sdf.emitRect(&verts, std.testing.allocator, sp, full_clip);
    h.gpu.uploadVertices(verts.items);
}

fn sdfFrame(options: teak.gpu.InitOptions, clear: [4]f32, specs: []const sdf.Spec) ![]u8 {
    var h = try Harness.init(options);
    defer h.deinit();
    try stage(&h, specs);
    return h.frame(clear);
}

test "sdf: corner radius cuts the corner with an antialiased arc; edges stay crisp" {
    const pixels = try sdfFrame(.{}, .{ 0, 0, 0, 1 }, &.{.{
        .rect = .{ .x = 8, .y = 8, .w = 40, .h = 40 },
        .radii = teak.Radii.all(12),
        .fill = .{ 1, 1, 1, 1 },
    }});
    defer std.testing.allocator.free(pixels);
    try std.testing.expectEqual(@as(u8, 0), at(pixels, 8, 8)[1]); // the square corner is gone
    try std.testing.expectEqual(@as(u8, 0), at(pixels, 10, 10)[1]);
    try std.testing.expectEqual(@as(u8, 255), at(pixels, 14, 14)[1]); // inside the arc
    try std.testing.expectEqual(@as(u8, 255), at(pixels, 28, 28)[1]);
    // straight edges: full coverage right up to the rect, none outside
    try std.testing.expectEqual(@as(u8, 255), at(pixels, 8, 28)[1]);
    try std.testing.expectEqual(@as(u8, 0), at(pixels, 7, 28)[1]);
    try std.testing.expectEqual(@as(u8, 255), at(pixels, 47, 28)[1]);
    try std.testing.expectEqual(@as(u8, 0), at(pixels, 48, 28)[1]);
    // pixel (11, 11): its centre is ~0.02 px outside the r=12 arc -> about half coverage
    const edge = at(pixels, 11, 11)[1];
    try std.testing.expect(edge > 60 and edge < 200);
    // per-corner radii: only the top-left rounded
    const mixed = try sdfFrame(.{}, .{ 0, 0, 0, 1 }, &.{.{
        .rect = .{ .x = 8, .y = 8, .w = 40, .h = 40 },
        .radii = .{ .tl = 16 },
        .fill = .{ 1, 1, 1, 1 },
    }});
    defer std.testing.allocator.free(mixed);
    try std.testing.expectEqual(@as(u8, 0), at(mixed, 8, 8)[1]);
    try std.testing.expectEqual(@as(u8, 255), at(mixed, 47, 8)[1]); // top-right stays square
    try std.testing.expectEqual(@as(u8, 255), at(mixed, 8, 47)[1]);
    try std.testing.expectEqual(@as(u8, 255), at(mixed, 47, 47)[1]);
}

test "sdf: border is an inside stroke of the requested width over the fill" {
    const pixels = try sdfFrame(.{}, .{ 0, 0, 0, 1 }, &.{.{
        .rect = .{ .x = 8, .y = 8, .w = 40, .h = 40 },
        .radii = teak.Radii.all(8),
        .fill = .{ 1, 1, 1, 1 },
        .border_width = 4,
        .border = .{ 1, 0, 0, 1 },
    }});
    defer std.testing.allocator.free(pixels);
    // BGRA: red border = (0, 0, 255); the stroke is x = 8..12 on the straight left edge
    for ([_]u32{ 8, 9, 10, 11 }) |x| try std.testing.expectEqual(@as([3]u8, .{ 0, 0, 255 }), at(pixels, x, 28)[0..3].*);
    try std.testing.expectEqual(@as([3]u8, .{ 255, 255, 255 }), at(pixels, 12, 28)[0..3].*); // fill resumes
    try std.testing.expectEqual(@as(u8, 0), at(pixels, 7, 28)[1]); // nothing outside
    // along the top edge too
    try std.testing.expectEqual(@as([3]u8, .{ 0, 0, 255 }), at(pixels, 28, 10)[0..3].*);
    try std.testing.expectEqual(@as([3]u8, .{ 255, 255, 255 }), at(pixels, 28, 12)[0..3].*);
}

test "sdf: soft shadow falls off with distance, stays outside the rect, offsets and spreads" {
    const clear = [4]f32{ 1, 1, 1, 1 };
    const rect = teak.Rect{ .x = 20, .y = 20, .w = 24, .h = 24 };
    const pixels = try sdfFrame(.{}, clear, &.{.{
        .rect = rect,
        .radii = teak.Radii.all(4),
        .fill = .{ 1, 1, 1, 1 },
        .shadow = .{ .dx = 0, .dy = 0, .blur = 16, .color = .{ 0, 0, 0, 1 } },
    }});
    defer std.testing.allocator.free(pixels);
    // sample a column going right from the rect's right edge (x = 44) at mid height
    var prev: u8 = 0;
    for ([_]u32{ 44, 46, 48, 52, 56, 62 }) |x| {
        const v = at(pixels, x, 32)[1];
        try std.testing.expect(v >= prev); // brightens (shadow fades) monotonically
        prev = v;
    }
    try std.testing.expect(at(pixels, 44, 32)[1] < 150); // dark next to the edge (about half of the colour)
    try std.testing.expect(at(pixels, 62, 32)[1] > 235); // almost gone ~2 sigma away... clear colour
    try std.testing.expectEqual(@as(u8, 255), at(pixels, 32, 32)[1]); // inside: the fill, shadow clipped out

    // offset moves it: a +8 px dy shadow is darker below than above
    const off = try sdfFrame(.{}, clear, &.{.{
        .rect = rect,
        .fill = .{ 1, 1, 1, 1 },
        .shadow = .{ .dx = 0, .dy = 8, .blur = 8, .color = .{ 0, 0, 0, 1 } },
    }});
    defer std.testing.allocator.free(off);
    try std.testing.expect(at(off, 32, 46)[1] + 40 < at(off, 32, 17)[1]);
    // spread grows it
    const spread = try sdfFrame(.{}, clear, &.{.{
        .rect = rect,
        .fill = .{ 1, 1, 1, 1 },
        .shadow = .{ .dx = 0, .dy = 0, .blur = 2, .spread = 6, .color = .{ 0, 0, 0, 1 } },
    }});
    defer std.testing.allocator.free(spread);
    try std.testing.expect(at(spread, 47, 32)[1] < 40); // 3 px outside the rect, still inside the 6 px spread
    try std.testing.expect(at(spread, 56, 32)[1] > 240);
}

test "sdf: linear gradient runs from the first stop to the second across the rect" {
    const pixels = try sdfFrame(.{}, .{ 0, 0, 0, 1 }, &.{ .{
        .rect = .{ .x = 4, .y = 4, .w = 24, .h = 56 },
        .gradient = teak.Gradient.vertical(.{ 1, 0, 0, 1 }, .{ 0, 0, 1, 1 }),
    }, .{
        .rect = .{ .x = 34, .y = 4, .w = 26, .h = 56 },
        .gradient = teak.Gradient.horizontal(.{ 0, 1, 0, 1 }, .{ 1, 1, 1, 1 }),
    } });
    defer std.testing.allocator.free(pixels);
    // BGRA. Vertical: red at the top row, blue at the bottom row, purple mid-way
    const top = at(pixels, 16, 4);
    const bot = at(pixels, 16, 59);
    const mid = at(pixels, 16, 32);
    try std.testing.expect(top[2] > 245 and top[0] < 12);
    try std.testing.expect(bot[0] > 245 and bot[2] < 12);
    try std.testing.expect(mid[2] > 100 and mid[2] < 155 and mid[0] > 100 and mid[0] < 155);
    // Horizontal green -> white: left column has no red, right column nearly white
    try std.testing.expect(at(pixels, 34, 30)[2] < 12);
    try std.testing.expect(at(pixels, 59, 30)[2] > 245);
    try std.testing.expect(at(pixels, 47, 30)[2] > 100 and at(pixels, 47, 30)[2] < 155);
}

test "sdf: radial gradient is the first stop at the centre and the second at the edge" {
    const pixels = try sdfFrame(.{}, .{ 0, 0, 0, 1 }, &.{.{
        .rect = .{ .x = 4, .y = 4, .w = 56, .h = 56 },
        .gradient = .{ .from = .{ 1, 1, 1, 1 }, .to = .{ 0, 0, 0, 1 }, .kind = .radial },
    }});
    defer std.testing.allocator.free(pixels);
    try std.testing.expect(at(pixels, 32, 32)[1] > 240);
    try std.testing.expect(at(pixels, 5, 32)[1] < 25);
    try std.testing.expect(at(pixels, 20, 32)[1] > at(pixels, 10, 32)[1]);
}

test "sdf: keeps painter's order with plain quads on both sides, honours alpha" {
    var h = try Harness.init(.{});
    defer h.deinit();
    var verts: std.ArrayList(teak.Vertex) = .empty;
    defer verts.deinit(std.testing.allocator);
    // plain green quad, then a rounded red rect over it, then a plain blue quad over both
    teak.vertex.emitQuad(&verts, std.testing.allocator, .{ .x = 0, .y = 0, .w = 40, .h = 40 }, .{ 0, 1, 0, 1 });
    sdf.emitRect(&verts, std.testing.allocator, .{ .rect = .{ .x = 10, .y = 10, .w = 40, .h = 40 }, .radii = teak.Radii.all(6), .fill = .{ 1, 0, 0, 1 } }, full_clip);
    teak.vertex.emitQuad(&verts, std.testing.allocator, .{ .x = 30, .y = 30, .w = 10, .h = 10 }, .{ 0, 0, 1, 1 });
    h.gpu.uploadVertices(verts.items);
    const pixels = try h.frame(.{ 0, 0, 0, 1 });
    defer std.testing.allocator.free(pixels);
    try std.testing.expectEqual(@as([3]u8, .{ 0, 255, 0 }), at(pixels, 4, 4)[0..3].*); // plain green only
    try std.testing.expectEqual(@as([3]u8, .{ 0, 0, 255 }), at(pixels, 20, 20)[0..3].*); // red over green
    try std.testing.expectEqual(@as([3]u8, .{ 255, 0, 0 }), at(pixels, 35, 35)[0..3].*); // blue over red
    try std.testing.expectEqual(@as(u8, 0), at(pixels, 60, 60)[1]);

    // half-transparent fill blends with what is underneath
    verts.clearRetainingCapacity();
    teak.vertex.emitQuad(&verts, std.testing.allocator, .{ .x = 0, .y = 0, .w = 64, .h = 64 }, .{ 1, 1, 1, 1 });
    sdf.emitRect(&verts, std.testing.allocator, .{ .rect = .{ .x = 10, .y = 10, .w = 40, .h = 40 }, .radii = teak.Radii.all(6), .fill = .{ 0, 0, 0, 0.5 } }, full_clip);
    h.gpu.uploadVertices(verts.items);
    const half = try h.frame(.{ 0, 0, 0, 1 });
    defer std.testing.allocator.free(half);
    const g = at(half, 30, 30)[1];
    try std.testing.expect(g > 120 and g < 135);
}

test "sdf: MSAA does not change fully covered or empty pixels" {
    const pixels = try sdfFrame(.{ .msaa = true }, .{ 0, 0, 0, 1 }, &.{.{
        .rect = .{ .x = 8, .y = 8, .w = 40, .h = 40 },
        .radii = teak.Radii.all(12),
        .fill = .{ 1, 1, 1, 1 },
        .border_width = 2,
        .border = .{ 1, 1, 1, 1 },
    }});
    defer std.testing.allocator.free(pixels);
    try std.testing.expectEqual(@as(u8, 255), at(pixels, 28, 28)[1]);
    try std.testing.expectEqual(@as(u8, 0), at(pixels, 2, 2)[1]);
    try std.testing.expectEqual(@as(u8, 255), at(pixels, 8, 28)[1]);
}

test "sdf: records survive the vertex buffer growing and shrinking between frames (overlay open / close)" {
    // The SDF records are read back from the vertex buffer through a storage
    // bind group. When the buffer is reallocated (a dropdown opens: more
    // vertices) the bind group must follow it, even if the new buffer comes
    // back with the old one's handle; otherwise rects drawn after the growth
    // read records from a stale buffer (missing fills, shifted rects, stray dots).
    var h = try Harness.init(.{});
    defer h.deinit();
    const counts = [_]usize{ 2, 7, 30, 64, 1, 64, 12, 64, 3 };
    for (counts, 0..) |n, frame| {
        var verts: std.ArrayList(teak.Vertex) = .empty;
        defer verts.deinit(std.testing.allocator);
        // a plain quad under everything so the vertex count also moves in odd steps
        teak.vertex.emitQuad(&verts, std.testing.allocator, .{ .x = 0, .y = 0, .w = 1, .h = 1 }, .{ 0, 0, 0, 1 });
        for (0..n) |i| {
            const cx: f32 = @floatFromInt((i % 8) * 8);
            const cy: f32 = @floatFromInt((i / 8) * 8);
            const shade: f32 = @as(f32, @floatFromInt(40 + (i * 3) % 200)) / 255.0;
            sdf.emitRect(&verts, std.testing.allocator, .{
                .rect = .{ .x = cx + 1, .y = cy + 1, .w = 6, .h = 6 },
                .radii = teak.Radii.all(1),
                .fill = .{ shade, 1 - shade, 0.5, 1 },
            }, full_clip);
        }
        h.gpu.uploadVertices(verts.items);
        const pixels = try h.frame(.{ 0, 0, 0, 1 });
        defer std.testing.allocator.free(pixels);
        for (0..n) |i| {
            const x: u32 = @intCast((i % 8) * 8 + 4);
            const y: u32 = @intCast((i / 8) * 8 + 4);
            const want_r: i32 = @intCast(@as(u32, @intFromFloat(@round((@as(f32, @floatFromInt(40 + (i * 3) % 200)) / 255.0) * 255.0))));
            const got = at(pixels, x, y); // BGRA
            std.testing.expect(@abs(@as(i32, got[2]) - want_r) <= 2 and got[3] == 255) catch |e| {
                std.debug.print("frame {d} ({d} rects): rect {d} at ({d},{d}) read {any}, wanted r={d}\n", .{ frame, n, i, x, y, got, want_r });
                return e;
            };
        }
    }
}
