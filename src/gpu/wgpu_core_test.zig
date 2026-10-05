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

const NoRaster = struct {
    pub fn init(_: std.mem.Allocator) !NoRaster {
        return .{};
    }
    pub fn deinit(_: *NoRaster) void {}
    pub fn rasterize(_: *NoRaster, _: []const u8, _: teak.FontSpec, _: [4]f32, _: u32, _: u32) ?wgpu_core.Bitmap {
        return null;
    }
};

const TestGpu = wgpu_core.Gpu(NoSurface, NoRaster);

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
    h.gpu.renderScenes(&.{sceneAt(mesh, 16, 16, 32, 32, 0)});
    const full = try h.frame(.{ 0, 0, 0, 1 });
    defer std.testing.allocator.free(full);
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, at(full, 30, 30)); // scene (red, BGRA)
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 255 }, at(full, 4, 4)); // UI background
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 255 }, at(full, 50, 50));
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, at(full, 16, 16)); // exact pixel placement
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 255 }, at(full, 15, 15));

    // Same scene clipped by a scroll container starting at x = 32.
    h.gpu.renderScenes(&.{sceneAt(mesh, 16, 16, 32, 32, 32)});
    const clipped = try h.frame(.{ 0, 0, 0, 1 });
    defer std.testing.allocator.free(clipped);
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 255 }, at(clipped, 20, 30)); // clipped away
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, at(clipped, 40, 30)); // still visible

    // No scenes staged: nothing composited.
    h.gpu.renderScenes(&.{});
    const none = try h.frame(.{ 0, 0, 0, 1 });
    defer std.testing.allocator.free(none);
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 255 }, at(none, 30, 30));
}

test "images upload, draw and release (slot reuse)" {
    var h = try Harness.init(.{});
    defer h.deinit();

    const red_px = [_]u8{ 255, 0, 0, 255 } ** 4; // 2x2 RGBA
    const img = h.gpu.uploadImage(&red_px, 2, 2);
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
    const again = h.gpu.uploadImage(&red_px, 2, 2);
    try std.testing.expectEqual(img, again);
}
