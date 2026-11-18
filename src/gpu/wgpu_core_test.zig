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
    sdf: [16 * 16]u8 = undefined,
    rgba: [12 * 12 * 4]u8 = undefined,

    pub fn init(_: std.mem.Allocator) !BoxRaster {
        return .{};
    }
    pub fn deinit(_: *BoxRaster) void {}
    pub fn shape(_: *BoxRaster, text: []const u8, _: teak.FontSpec, out: []teak.ShapedGlyph) teak.ShapeResult {
        // One glyph per byte (advance 8); a 4-byte UTF-8 sequence is ONE unmapped glyph (an
        // emoji: glyph 0, advance 16).
        var n: usize = 0;
        var i: usize = 0;
        var x: f32 = 0;
        while (i < text.len and n < out.len) : (n += 1) {
            const emoji = text[i] >= 0xF0 and i + 4 <= text.len;
            const adv: f32 = if (emoji) 16 else 8;
            out[n] = .{ .glyph = if (emoji) 0 else text[i], .face = 0, .cluster = @intCast(i), .x = x, .advance = adv };
            x += adv;
            i += if (emoji) 4 else 1;
        }
        return .{ .count = n, .width = x, .consumed = i };
    }
    /// A 16x16 distance field of an 8x8 box (texels 4..12): byte = 128 + 16 * signed distance.
    pub const sdf_em: f32 = 16;
    pub fn rasterizeSdf(self: *BoxRaster, _: u16, gid: u16) ?GlyphBitmap {
        if (gid == ' ') return .{ .pixels = &.{}, .width = 0, .height = 0, .bearing_x = 0, .bearing_y = 0 };
        for (0..16) |y| for (0..16) |x| {
            const fx: f32 = @as(f32, @floatFromInt(x)) + 0.5;
            const fy: f32 = @as(f32, @floatFromInt(y)) + 0.5;
            const inside = @min(@min(fx - 4, 12 - fx), @min(fy - 4, 12 - fy));
            self.sdf[y * 16 + x] = @intFromFloat(std.math.clamp(128 + 16 * inside, 0, 255));
        };
        return .{ .pixels = &self.sdf, .width = 16, .height = 16, .bearing_x = 0, .bearing_y = -12 };
    }
    /// A 12x12 colour glyph: left half red, right half green, fully opaque (straight alpha RGBA).
    pub fn rasterizeColor(self: *BoxRaster, _: []const u8, _: teak.FontSpec, _: f32) ?GlyphBitmap {
        for (0..12) |y| for (0..12) |x| {
            const o = (y * 12 + x) * 4;
            self.rgba[o..][0..4].* = if (x < 6) .{ 255, 0, 0, 255 } else .{ 0, 255, 0, 255 };
        };
        return .{ .pixels = &self.rgba, .width = 12, .height = 12, .bearing_x = 0, .bearing_y = -12 };
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





fn colored(d: teak.TextDraw, rgba: [4]f32) teak.TextDraw {
    var out = d;
    out.color = rgba;
    return out;
}







fn scalable(d: teak.TextDraw, size: f32) teak.TextDraw {
    var out = d;
    out.font = .{ .size_px = size, .scalable = true };
    out.rect_w = 64;
    out.rect_h = 64;
    return out;
}






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








