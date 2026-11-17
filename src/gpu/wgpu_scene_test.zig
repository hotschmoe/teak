//! Headless tests for the native scene renderer: render a mesh into an
//! offscreen target on a surface-less wgpu device, read the pixels back,
//! and assert on them. Run with `zig build test-gpu`. It needs a Vulkan
//! device (the instance is restricted to Vulkan so wgpu cannot fall back to
//! a GL software adapter); the tests skip, rather than fail, when none
//! opens. Note wgpu-native cannot open Chromium's SwiftShader ICD
//! (`VK_ICD_FILENAMES=.../vk_swiftshader_icd.json` fails at device
//! creation); a real driver such as the Mali Vulkan ICD works.

const std = @import("std");
const teak = @import("teak");
const wgpu_c = @import("wgpu_c.zig");
const wgpu_scene = @import("wgpu_scene.zig");
const common = @import("scene_common.zig");

const c = wgpu_c.c;
const bgra = c.WGPUTextureFormat_BGRA8Unorm;

const Fixture = struct {
    instance: c.WGPUInstance,
    ctx: wgpu_c.DeviceContext,
    renderer: wgpu_scene.Renderer,

    fn init(msaa: bool) !Fixture {
        const instance = wgpu_c.createInstance(c.WGPUInstanceBackend_Vulkan) orelse return error.SkipZigTest;
        const ctx = wgpu_c.requestDevice(instance, null) catch return error.SkipZigTest;
        const renderer = try wgpu_scene.Renderer.init(ctx.device, ctx.queue, bgra, msaa);
        return .{ .instance = instance, .ctx = ctx, .renderer = renderer };
    }

    fn deinit(self: *Fixture) void {
        self.renderer.deinit();
        self.ctx.release();
        c.wgpuInstanceRelease(self.instance);
    }

    /// Render `draw` into scene slot 0 and read its pixels back (BGRA).
    fn render(self: *Fixture, draw: teak.SceneDraw) ![]u8 {
        return self.renderItems(draw, &.{});
    }

    /// Same with placed items (`draw.item_count` is set from the slice).
    fn renderItems(self: *Fixture, draw_in: teak.SceneDraw, items: []const teak.SceneItem) ![]u8 {
        return self.renderFull(draw_in, items, &.{}, wgpu_scene.NoImages{});
    }

    /// Items, sprites and an image source (sprites sample `images.viewOf`).
    fn renderFull(self: *Fixture, draw_in: teak.SceneDraw, items: []const teak.SceneItem, sprites: []const teak.SceneSprite, images: anytype) ![]u8 {
        var draw = draw_in;
        draw.sprite_first = 0;
        draw.sprite_count = @intCast(sprites.len);
        draw.item_first = 0;
        draw.item_count = @intCast(items.len);
        var enc_desc = std.mem.zeroes(c.WGPUCommandEncoderDescriptor);
        const encoder = c.wgpuDeviceCreateCommandEncoder(self.ctx.device, &enc_desc);
        const size = self.renderer.renderInto(encoder, 0, draw, items, sprites, images, 1) orelse return error.NoTarget;
        var cb_desc = std.mem.zeroes(c.WGPUCommandBufferDescriptor);
        const cmd = c.wgpuCommandEncoderFinish(encoder, &cb_desc);
        c.wgpuCommandEncoderRelease(encoder);
        c.wgpuQueueSubmit(self.ctx.queue, 1, &cmd);
        c.wgpuCommandBufferRelease(cmd);
        const t = self.renderer.target(0).?;
        return wgpu_c.readTexture(std.testing.allocator, self.ctx, t.color, size.w, size.h, 4);
    }
};

const target_px: u32 = 64;

fn px(pixels: []const u8, x: u32, y: u32) [4]u8 {
    return pixels[(y * target_px + x) * 4 ..][0..4].*;
}

fn vert(x: f32, y: f32, z: f32, rgb: [3]f32) teak.MeshVertex {
    return .{ .pos = .{ x, y, z }, .normal = .{ 0, 0, 1 }, .color = .{ rgb[0], rgb[1], rgb[2], 1 } };
}

/// Identity view_proj: vertex positions are clip-space coordinates (x, y in
/// -1..1, depth z in 0..1). The eye sits on +z and the light travels along
/// -z, so +z-facing triangles are fully lit and show their vertex colour.
fn drawFor(mesh: teak.MeshHandle) teak.SceneDraw {
    return .{
        .mesh = mesh,
        .rect_x = 0,
        .rect_y = 0,
        .rect_w = target_px,
        .rect_h = target_px,
        .clip_x = 0,
        .clip_y = 0,
        .clip_w = target_px,
        .clip_h = target_px,
        .camera = .{ .eye = .{ 0, 0, 5 }, .light_dir = .{ 0, 0, -1 } },
        .clear = .{ 0, 0, 0, 1 },
        .edge_color = .{ 1, 1, 1, 1 },
        .edge_px = 4,
    };
}

fn expectNear(actual: [4]u8, bgr: [3]u8, tol: u8) !void {
    for (0..3) |i| {
        const d = @as(i32, actual[i]) - @as(i32, bgr[i]);
        if (@abs(d) > tol) {
            std.debug.print("pixel b,g,r,a = {any}, expected b,g,r ~ {any}\n", .{ actual, bgr });
            return error.PixelMismatch;
        }
    }
}





/// A +z facing quad centred on the origin covering x,y in [-h, h], white.
fn quadMesh(fx: *Fixture, h: f32, rgb: [3]f32, lines: []const teak.LineVertex) teak.MeshHandle {
    const verts = [_]teak.MeshVertex{ vert(-h, -h, 0.5, rgb), vert(h, -h, 0.5, rgb), vert(h, h, 0.5, rgb), vert(-h, h, 0.5, rgb) };
    return fx.renderer.uploadMesh(.{ .vertices = &verts, .indices = &.{ 0, 1, 2, 0, 2, 3 }, .lines = lines });
}

fn shift(x: f32, y: f32) [12]f32 {
    return .{ 1, 0, 0, x, 0, 1, 0, y, 0, 0, 1, 0 };
}






/// Ortho top-down camera (preset `top`) over a 64 px square: 8.77 px per world unit.
fn topCamera() teak.Camera {
    var o = teak.scene.Orbit{ .dist = 10, .projection = .ortho };
    o.setPreset(.top);
    var cam = o.camera(target_px, target_px, null);
    cam.light_dir = .{ 0, 0, 0 };
    return cam;
}

fn chan(p: [4]u8, which: enum { b, g, r }) u8 {
    return p[@backingInt(which)];
}



/// Closed cube of half-size `h` (shared vertices, outward CCW), white.
fn cubeMesh(fx: *Fixture, h: f32) teak.MeshHandle {
    var verts: [8]teak.MeshVertex = undefined;
    for (&verts, 0..) |*v, i| {
        const sx: f32 = if (i & 1 == 0) -h else h;
        const sy: f32 = if (i & 2 == 0) -h else h;
        const sz: f32 = if (i & 4 == 0) -h else h;
        v.* = .{ .pos = .{ sx, sy, sz }, .normal = .{ 0, 1, 0 }, .color = .{ 1, 1, 1, 1 } };
    }
    const idx = [36]u32{ 0, 2, 3, 0, 3, 1, 4, 5, 7, 4, 7, 6, 0, 1, 5, 0, 5, 4, 2, 6, 7, 2, 7, 3, 0, 4, 6, 0, 6, 2, 1, 3, 7, 1, 7, 5 };
    return fx.renderer.uploadMesh(.{ .vertices = &verts, .indices = &idx });
}



fn planeAt(z: f32, rgba: [4]f32, layer: i16, size: f32) teak.ScenePlane {
    return .{
        .origin = .{ -size / 2, -size / 2, z },
        .u = .{ 1, 0, 0 },
        .v = .{ 0, 1, 0 },
        .size = .{ size, size },
        .background = rgba,
        .layer = layer,
    };
}



/// Image source over one view (a solid-colour texture made by the test).
const OneImage = struct {
    view: c.WGPUTextureView,
    pub fn hasImage(_: OneImage, h: u32) bool {
        return h == 3;
    }
    pub fn viewOf(self: OneImage, h: u32) ?c.WGPUTextureView {
        return if (h == 3) self.view else null;
    }
};


