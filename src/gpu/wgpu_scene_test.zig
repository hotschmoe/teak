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

test "depth test, lighting, clear colour and line quads render correctly" {
    var fx = try Fixture.init(true);
    defer fx.deinit();

    const red = [3]f32{ 1, 0, 0 };
    const blue = [3]f32{ 0, 0, 1 };
    // Far blue quad over the whole target, listed AFTER the near red quad
    // that covers only the left half: with a working depth test red wins on
    // the left even though blue is drawn later.
    const verts = [_]teak.MeshVertex{
        vert(-1, -1, 0.2, red),  vert(0, -1, 0.2, red),  vert(0, 1, 0.2, red),  vert(-1, 1, 0.2, red),
        vert(-1, -1, 0.8, blue), vert(1, -1, 0.8, blue), vert(1, 1, 0.8, blue), vert(-1, 1, 0.8, blue),
    };
    const indices = [_]u32{ 0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7 };
    // A green segment across the top quarter, nearer than both quads.
    const green = [4]f32{ 0, 1, 0, 1 };
    const lines = [_]teak.LineVertex{
        .{ .pos = .{ -0.8, 0.5, 0.05 }, .color = green },
        .{ .pos = .{ 0.8, 0.5, 0.05 }, .color = green },
    };

    const mesh = fx.renderer.uploadMesh(.{ .vertices = &verts, .indices = &indices, .lines = &lines });
    try std.testing.expect(mesh != teak.MESH_HANDLE_NONE);

    const pixels = try fx.render(drawFor(mesh));
    defer std.testing.allocator.free(pixels);

    try expectNear(px(pixels, 16, 48), .{ 0, 0, 255 }, 4); // near red wins on the left
    try expectNear(px(pixels, 48, 48), .{ 255, 0, 0 }, 4); // far blue on the right
    try expectNear(px(pixels, 32, 16), .{ 0, 255, 0 }, 4); // line sits in front of faces
    try expectNear(px(pixels, 32, 17), .{ 0, 255, 0 }, 4); // ... 4 px wide
    try expectNear(px(pixels, 16, 24), .{ 0, 0, 255 }, 4); // ... and no wider (row 24 is the red face)
    try std.testing.expectEqual(@as(u8, 255), px(pixels, 16, 48)[3]);
}

test "an unchanged scene is not re-rendered; a changed clear colour is" {
    var fx = try Fixture.init(false);
    defer fx.deinit();

    const verts = [_]teak.MeshVertex{ vert(-1, -1, 0.5, .{ 1, 1, 1 }), vert(1, -1, 0.5, .{ 1, 1, 1 }), vert(0, 1, 0.5, .{ 1, 1, 1 }) };
    const mesh = fx.renderer.uploadMesh(.{ .vertices = &verts, .indices = &.{ 0, 1, 2 } });

    const first = try fx.render(drawFor(mesh));
    std.testing.allocator.free(first);
    const sig = fx.renderer.target(0).?.signature;
    const gen = fx.renderer.target(0).?.generation;

    const again = try fx.render(drawFor(mesh));
    std.testing.allocator.free(again);
    try std.testing.expectEqual(sig, fx.renderer.target(0).?.signature);
    try std.testing.expectEqual(gen, fx.renderer.target(0).?.generation);

    var changed = drawFor(mesh);
    changed.clear = .{ 0.5, 0, 0, 1 };
    const px_changed = try fx.render(changed);
    defer std.testing.allocator.free(px_changed);
    try std.testing.expect(sig != fx.renderer.target(0).?.signature);
    try expectNear(px(px_changed, 1, 1), .{ 0, 0, 128 }, 3); // corner outside the triangle shows the clear colour
}

test "mesh table: invalid data rejected, release frees the slot" {
    var fx = try Fixture.init(false);
    defer fx.deinit();

    const v: [3]teak.MeshVertex = @splat(vert(0, 0, 0, .{ 1, 1, 1 }));
    try std.testing.expectEqual(teak.MESH_HANDLE_NONE, fx.renderer.uploadMesh(.{ .vertices = &v, .indices = &.{ 0, 1, 7 } }));
    try std.testing.expectEqual(teak.MESH_HANDLE_NONE, fx.renderer.uploadMesh(.{ .vertices = &v, .indices = &.{ 0, 1 } }));

    const a = fx.renderer.uploadMesh(.{ .vertices = &v, .indices = &.{ 0, 1, 2 } });
    try std.testing.expect(a != teak.MESH_HANDLE_NONE);
    fx.renderer.releaseMesh(a);
    const b = fx.renderer.uploadMesh(.{ .vertices = &v, .indices = &.{ 0, 1, 2 } });
    try std.testing.expectEqual(a, b); // slot reused
    fx.renderer.releaseMesh(b);
    fx.renderer.releaseMesh(b); // double release is harmless
}

test "a scene with no mesh renders just its clear colour" {
    var fx = try Fixture.init(true);
    defer fx.deinit();
    var d = drawFor(teak.MESH_HANDLE_NONE);
    d.clear = .{ 0, 0.5, 0, 1 };
    const pixels = try fx.render(d);
    defer std.testing.allocator.free(pixels);
    try expectNear(px(pixels, 10, 10), .{ 0, 128, 0 }, 3);
    try expectNear(px(pixels, 60, 60), .{ 0, 128, 0 }, 3);
}

/// A +z facing quad centred on the origin covering x,y in [-h, h], white.
fn quadMesh(fx: *Fixture, h: f32, rgb: [3]f32, lines: []const teak.LineVertex) teak.MeshHandle {
    const verts = [_]teak.MeshVertex{ vert(-h, -h, 0.5, rgb), vert(h, -h, 0.5, rgb), vert(h, h, 0.5, rgb), vert(-h, h, 0.5, rgb) };
    return fx.renderer.uploadMesh(.{ .vertices = &verts, .indices = &.{ 0, 1, 2, 0, 2, 3 }, .lines = lines });
}

fn shift(x: f32, y: f32) [12]f32 {
    return .{ 1, 0, 0, x, 0, 1, 0, y, 0, 0, 1, 0 };
}

test "items: one mesh placed twice by transform (one instanced draw), gap stays clear" {
    var fx = try Fixture.init(false);
    defer fx.deinit();
    const mesh = quadMesh(&fx, 0.25, .{ 1, 1, 1 }, &.{});
    const items = [_]teak.SceneItem{
        .{ .mesh = mesh, .transform = shift(-0.5, 0) },
        .{ .mesh = mesh, .transform = shift(0.5, 0) },
    };
    const pixels = try fx.renderItems(drawFor(0), &items);
    defer std.testing.allocator.free(pixels);
    try expectNear(px(pixels, 16, 32), .{ 255, 255, 255 }, 3); // x = -0.5 -> px 16
    try expectNear(px(pixels, 48, 32), .{ 255, 255, 255 }, 3);
    try expectNear(px(pixels, 32, 32), .{ 0, 0, 0 }, 3); // between them
    try expectNear(px(pixels, 16, 8), .{ 0, 0, 0 }, 3); // outside vertically
}

test "items: tint multiplies, highlight blends, unlit skips shading, hidden is skipped" {
    var fx = try Fixture.init(false);
    defer fx.deinit();
    const mesh = quadMesh(&fx, 0.2, .{ 1, 1, 1 }, &.{});
    var d = drawFor(0);
    d.highlight_color = .{ 0, 0, 1, 1 };
    d.highlight_mix = 1;
    d.camera.light_dir = .{ 0, 0, 1 }; // travels away from the viewer: faces get ambient only (0.35)
    const items = [_]teak.SceneItem{
        .{ .mesh = mesh, .transform = shift(-0.6, 0.5), .tint = .{ 1, 0, 0, 1 }, .flags = .{ .unlit = true } }, // pure red
        .{ .mesh = mesh, .transform = shift(0.0, 0.5), .flags = .{ .highlight = true, .unlit = true } }, // pure blue
        .{ .mesh = mesh, .transform = shift(0.6, 0.5) }, // lit: 0.35 grey
        .{ .mesh = mesh, .transform = shift(0.0, -0.5), .flags = .{ .hidden = true } },
    };
    const pixels = try fx.renderItems(d, &items);
    defer std.testing.allocator.free(pixels);
    try expectNear(px(pixels, 13, 16), .{ 0, 0, 255 }, 3); // bgr of red
    try expectNear(px(pixels, 32, 16), .{ 255, 0, 0 }, 3); // blue
    try expectNear(px(pixels, 51, 16), .{ 89, 89, 89 }, 4); // 0.35 * 255
    try expectNear(px(pixels, 32, 48), .{ 0, 0, 0 }, 3); // hidden item draws nothing

    // Flat material applies to every item without the per-item flag.
    d.material = .flat;
    const flat = try fx.renderItems(d, items[2..3]);
    defer std.testing.allocator.free(flat);
    try expectNear(px(flat, 51, 16), .{ 255, 255, 255 }, 3);
}

test "items: section plane discards the cut-away half of faces and edges" {
    var fx = try Fixture.init(false);
    defer fx.deinit();
    const green = [4]f32{ 0, 1, 0, 1 };
    const lines = [_]teak.LineVertex{ .{ .pos = .{ -0.8, 0.5, 0.05 }, .color = green }, .{ .pos = .{ 0.8, 0.5, 0.05 }, .color = green } };
    const mesh = quadMesh(&fx, 0.9, .{ 1, 1, 1 }, &lines);
    var d = drawFor(0);
    const items = [_]teak.SceneItem{.{ .mesh = mesh }};
    // keep x <= 0 (n = +x, d = 0)
    d.cut = .{ .plane = .{ 1, 0, 0, 0 } };
    const pixels = try fx.renderItems(d, &items);
    defer std.testing.allocator.free(pixels);
    try expectNear(px(pixels, 16, 48), .{ 255, 255, 255 }, 3); // kept half
    try expectNear(px(pixels, 48, 48), .{ 0, 0, 0 }, 3); // cut half
    try expectNear(px(pixels, 16, 16), .{ 0, 255, 0 }, 4); // edge on the kept side
    try expectNear(px(pixels, 48, 16), .{ 0, 0, 0 }, 3); // edge cut away too
}

test "items: edges follow the item transform; no_edges skips an item's lines" {
    var fx = try Fixture.init(false);
    defer fx.deinit();
    const green = [4]f32{ 0, 1, 0, 1 };
    const lines = [_]teak.LineVertex{ .{ .pos = .{ -0.2, 0, 0.05 }, .color = green }, .{ .pos = .{ 0.2, 0, 0.05 }, .color = green } };
    const mesh = quadMesh(&fx, 0.01, .{ 0, 0, 0 }, &lines);
    const items = [_]teak.SceneItem{
        .{ .mesh = mesh, .transform = shift(-0.5, 0.5) },
        .{ .mesh = mesh, .transform = shift(0.5, 0.5), .flags = .{ .no_edges = true } },
        .{ .mesh = mesh, .transform = shift(0.5, -0.5) },
    };
    const pixels = try fx.renderItems(drawFor(0), &items);
    defer std.testing.allocator.free(pixels);
    try expectNear(px(pixels, 16, 16), .{ 0, 255, 0 }, 4); // item 0 line at (-0.5, 0.5)
    try expectNear(px(pixels, 48, 16), .{ 0, 0, 0 }, 3); // item 1 has no_edges
    try expectNear(px(pixels, 48, 48), .{ 0, 255, 0 }, 4); // item 2 line at (0.5, -0.5)
    try expectNear(px(pixels, 16, 48), .{ 0, 0, 0 }, 3);
}

test "items: re-placing an item changes the signature; an identical frame does not" {
    var fx = try Fixture.init(false);
    defer fx.deinit();
    const mesh = quadMesh(&fx, 0.2, .{ 1, 1, 1 }, &.{});
    var items = [_]teak.SceneItem{.{ .mesh = mesh }};
    const a = try fx.renderItems(drawFor(0), &items);
    std.testing.allocator.free(a);
    const sig = fx.renderer.target(0).?.signature;
    const b = try fx.renderItems(drawFor(0), &items);
    std.testing.allocator.free(b);
    try std.testing.expectEqual(sig, fx.renderer.target(0).?.signature);
    items[0].flags.highlight = true;
    const c2 = try fx.renderItems(drawFor(0), &items);
    std.testing.allocator.free(c2);
    try std.testing.expect(sig != fx.renderer.target(0).?.signature);
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

test "grid: axis and minor lines appear, cells stay clear, a mesh above occludes it" {
    var fx = try Fixture.init(true);
    defer fx.deinit();
    var d = drawFor(0);
    d.camera = topCamera();
    d.grid = .{ .spacing = 1, .major_every = 5 };

    const pixels = try fx.render(d);
    defer std.testing.allocator.free(pixels);
    // x axis: the v = 0 line through the centre is the (red) axis_a line
    // (the 1.5 px line straddles rows 32 and 33)
    const axis_r = @as(u32, chan(px(pixels, 45, 32), .r)) + chan(px(pixels, 45, 33), .r);
    const axis_b = @as(u32, chan(px(pixels, 45, 32), .b)) + chan(px(pixels, 45, 33), .b);
    // (a plain minor line is bluish white, b > r; the axis tips r above b)
    try std.testing.expect(axis_r > 80 and axis_r > axis_b + 10);
    // z axis: the u = 0 line is axis_b (blue)
    const zb = @as(u32, chan(px(pixels, 31, 52), .b)) + chan(px(pixels, 32, 52), .b);
    const zr = @as(u32, chan(px(pixels, 31, 52), .r)) + chan(px(pixels, 32, 52), .r);
    try std.testing.expect(zb > zr + 40);
    // mid-cell is the clear colour; an integer line (x = 1 -> px ~ 40.8) is not
    try expectNear(px(pixels, 36, 52), .{ 0, 0, 0 }, 4);
    const minor = px(pixels, 40, 52);
    try std.testing.expect(@as(u32, minor[0]) + minor[1] + minor[2] > 60);

    // A quad above the plane covering the centre hides the grid there.
    const verts = [_]teak.MeshVertex{
        .{ .pos = .{ -2, 1, -2 }, .normal = .{ 0, 1, 0 }, .color = .{ 1, 1, 1, 1 } },
        .{ .pos = .{ 2, 1, -2 }, .normal = .{ 0, 1, 0 }, .color = .{ 1, 1, 1, 1 } },
        .{ .pos = .{ 2, 1, 2 }, .normal = .{ 0, 1, 0 }, .color = .{ 1, 1, 1, 1 } },
        .{ .pos = .{ -2, 1, 2 }, .normal = .{ 0, 1, 0 }, .color = .{ 1, 1, 1, 1 } },
    };
    const mesh = fx.renderer.uploadMesh(.{ .vertices = &verts, .indices = &.{ 0, 1, 2, 0, 2, 3 } });
    const items = [_]teak.SceneItem{.{ .mesh = mesh }};
    const occluded = try fx.renderItems(d, &items);
    defer std.testing.allocator.free(occluded);
    try expectNear(px(occluded, 32, 32), .{ 255, 255, 255 }, 4); // quad, not the axis crossing
    try expectNear(px(occluded, 46, 32), .{ 255, 255, 255 }, 4);
    // beyond the quad (x = 2.9 -> px 57.4) the axis shows again
    try std.testing.expect(@as(u32, chan(px(occluded, 60, 32), .r)) + chan(px(occluded, 60, 33), .r) > 80);
}

test "gizmo: axis triad lands in its corner, shafts follow the view, nothing outside" {
    var fx = try Fixture.init(true);
    defer fx.deinit();
    var o = teak.scene.Orbit{ .dist = 10 };
    o.setPreset(.front);
    var d = drawFor(0);
    d.camera = o.camera(target_px, target_px, null);
    d.gizmo = .{ .corner = .bottom_left, .size_px = 32, .margin_px = 0 };

    const pixels = try fx.render(d);
    defer std.testing.allocator.free(pixels);
    // gizmo square is x 0..32, y 32..64; origin at (16, 48); +x right (red), +y up (green)
    const xs = px(pixels, 22, 48);
    try std.testing.expect(chan(xs, .r) > 120 and chan(xs, .g) < 80);
    const ys = px(pixels, 16, 40);
    try std.testing.expect(chan(ys, .g) > 80 and chan(ys, .r) < 90);
    try expectNear(px(pixels, 50, 50), .{ 0, 0, 0 }, 3);
    try expectNear(px(pixels, 50, 10), .{ 0, 0, 0 }, 3);
    try expectNear(px(pixels, 16, 10), .{ 0, 0, 0 }, 3); // above the gizmo square

    // Corner choice moves it.
    d.gizmo.?.corner = .top_right;
    const moved = try fx.render(d);
    defer std.testing.allocator.free(moved);
    try std.testing.expect(chan(px(moved, 48 + 6, 16), .r) > 120); // origin (48, 16)
    try expectNear(px(moved, 22, 48), .{ 0, 0, 0 }, 3);
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

test "section cut: stencil-parity cap fills the cut face, per-item colour, outline, open shells" {
    var fx = try Fixture.init(true);
    defer fx.deinit();
    const mesh = cubeMesh(&fx, 1);
    var d = drawFor(0);
    d.camera = topCamera(); // looking down -y; 8.77 px per unit
    // keep y <= 0.2: the top half is cut away, the viewer sees the inside of the solid
    d.cut = .{ .plane = .{ 0, 1, 0, -0.2 }, .cap_color = .{ 0, 0.5, 0, 1 }, .outline_px = 2, .outline_color = .{ 0, 0, 1, 1 } };

    // 1. default cap colour (green), outline, nothing outside the footprint
    var items = [_]teak.SceneItem{.{ .mesh = mesh }};
    const capped = try fx.renderItems(d, &items);
    defer std.testing.allocator.free(capped);
    const mid = px(capped, 32, 32);
    try std.testing.expect(chan(mid, .g) >= 80 and chan(mid, .g) <= 140 and chan(mid, .r) < 20); // 0.5 green (hatch darkens to 0.35)
    try expectNear(px(capped, 32 + 20, 32 + 20), .{ 0, 0, 0 }, 3); // outside the +-1 footprint (8.77 px)
    // outline: the +x boundary at x = 1 -> px 40.8
    var found_outline = false;
    for (39..43) |xx| {
        const q = px(capped, @intCast(xx), 32);
        if (chan(q, .b) > 150 and chan(q, .g) < 60) found_outline = true;
    }
    try std.testing.expect(found_outline);

    // 2. per-item cap colour overrides the cut's
    items[0].cap_color = .{ 1, 0, 0, 1 };
    const red = try fx.renderItems(d, &items);
    defer std.testing.allocator.free(red);
    const rmid = px(red, 32, 32);
    try std.testing.expect(chan(rmid, .r) >= 170 and chan(rmid, .g) < 20);

    // 3. no_cap (an open shell): no cap fill, the outline is still drawn
    items[0].flags.no_cap = true;
    const nocap = try fx.renderItems(d, &items);
    defer std.testing.allocator.free(nocap);
    const nmid = px(nocap, 32, 32);
    try std.testing.expect(!(chan(nmid, .r) >= 170 and chan(nmid, .g) < 20));
    var outline_still = false;
    for (39..43) |xx| {
        const q = px(nocap, @intCast(xx), 32);
        if (chan(q, .b) > 150 and chan(q, .g) < 60) outline_still = true;
    }
    try std.testing.expect(outline_still);

    // 4. Cut with cap = false shows the inside faces (white-ish), no cap colour
    items[0].flags.no_cap = false;
    d.cut.?.cap = false;
    const hollow = try fx.renderItems(d, &items);
    defer std.testing.allocator.free(hollow);
    const hmid = px(hollow, 32, 32);
    try std.testing.expect(!(chan(hmid, .r) >= 170 and chan(hmid, .g) < 20));
    try std.testing.expect(chan(hmid, .g) > 100);
}

test "section cut: a plane that misses the item draws no cap and no outline" {
    var fx = try Fixture.init(false);
    defer fx.deinit();
    const mesh = cubeMesh(&fx, 1);
    var d = drawFor(0);
    d.camera = topCamera();
    d.cut = .{ .plane = .{ 0, 1, 0, -3 }, .cap_color = .{ 1, 0, 0, 1 }, .outline_px = 2 }; // keep y <= 3: everything kept
    const items = [_]teak.SceneItem{.{ .mesh = mesh }};
    const pixels = try fx.renderItems(d, &items);
    defer std.testing.allocator.free(pixels);
    const mid = px(pixels, 32, 32); // the cube's lit top face, no red cap
    try std.testing.expect(chan(mid, .g) > 100 and chan(mid, .r) > 100);
    try std.testing.expect(!(chan(mid, .r) >= 170 and chan(mid, .g) < 20));
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

test "planes: opaque sheets depth-test, layers stack coplanar sheets, content tessellates" {
    var fx = try Fixture.init(true);
    defer fx.deinit();
    var d = drawFor(0);

    // a far red sheet behind a nearer blue one covering only the left part
    var list = [_]teak.ScenePlane{ planeAt(0.8, .{ 1, 0, 0, 1 }, 0, 1.6), planeAt(0.3, .{ 0, 0, 1, 1 }, 0, 0.8) };
    list[1].origin = .{ -0.8, -0.4, 0.3 };
    d.planes = &list;
    const a = try fx.render(d);
    defer std.testing.allocator.free(a);
    try expectNear(px(a, 48, 32), .{ 0, 0, 255 }, 4); // right of the blue sheet (x=0.5): the red one
    try expectNear(px(a, 16, 32), .{ 255, 0, 0 }, 4); // left: blue in front (bgr)
    try expectNear(px(a, 2, 2), .{ 0, 0, 0 }, 3); // outside both

    // coplanar: the higher layer wins whichever is listed first
    list = .{ planeAt(0.5, .{ 1, 0, 0, 1 }, 1, 1.2), planeAt(0.5, .{ 0, 0, 1, 1 }, 0, 1.2) };
    const b = try fx.render(d);
    defer std.testing.allocator.free(b);
    try expectNear(px(b, 32, 32), .{ 0, 0, 255 }, 4); // layer 1 (red) on top
    list = .{ planeAt(0.5, .{ 1, 0, 0, 1 }, 0, 1.2), planeAt(0.5, .{ 0, 0, 1, 1 }, 1, 1.2) };
    const c2 = try fx.render(d);
    defer std.testing.allocator.free(c2);
    try expectNear(px(c2, 32, 32), .{ 255, 0, 0 }, 4); // layer 1 (blue) on top

    // content: a filled rect in plane-local units (y up = +v) on a white sheet
    const prims = [_]teak.CanvasPrimitive{.{ .filled_rect = .{ .x = 0, .y = 0, .w = 0.5, .h = 0.5, .color = .{ 0, 1, 0, 1 } } }};
    var content = [_]teak.ScenePlane{planeAt(0.5, .{ 1, 1, 1, 1 }, 0, 1.6)};
    content[0].content = &prims;
    d.planes = &content;
    const e = try fx.render(d);
    defer std.testing.allocator.free(e);
    // local (0..0.5, 0..0.5) is x in -0.8..-0.3, y in -0.8..-0.3 -> pixels x 6..22, y (flipped) 39..58
    try expectNear(px(e, 12, 48), .{ 0, 255, 0 }, 4);
    try expectNear(px(e, 40, 16), .{ 255, 255, 255 }, 4);
}

test "planes: translucent sheets blend back to front and do not write depth" {
    var fx = try Fixture.init(true);
    defer fx.deinit();
    var d = drawFor(0);
    // two half-opaque sheets: red at z=0.2, blue at z=0.6; the eye at +z sees blue nearer; clear is black
    var list = [_]teak.ScenePlane{ planeAt(0.2, .{ 1, 0, 0, 1 }, 0, 1.6), planeAt(0.6, .{ 0, 0, 1, 1 }, 0, 1.6) };
    list[0].opacity = 0.5;
    list[1].opacity = 0.5;
    d.planes = &list;
    d.camera.eye = .{ 0, 0, 5 };
    const a = try fx.render(d);
    defer std.testing.allocator.free(a);
    // drawn far (red) then near (blue): red*0.5 = (.5,0,0); blue 0.5 over that = r .25, b .5
    const q = px(a, 32, 32);
    try std.testing.expect(chan(q, .b) > 110 and chan(q, .b) < 145);
    try std.testing.expect(chan(q, .r) > 50 and chan(q, .r) < 80);
    // the listing order does not matter: sorting is by distance from the eye
    std.mem.swap(teak.ScenePlane, &list[0], &list[1]);
    const b = try fx.render(d);
    defer std.testing.allocator.free(b);
    try std.testing.expect(std.meta.eql(px(b, 32, 32), q));
    // eye on the other side: the red sheet is now nearer, so it ends up on top
    d.camera.eye = .{ 0, 0, -5 };
    const c2 = try fx.render(d);
    defer std.testing.allocator.free(c2);
    const q2 = px(c2, 32, 32);
    try std.testing.expect(chan(q2, .r) > 110 and chan(q2, .r) < 145 and chan(q2, .b) > 50 and chan(q2, .b) < 80);
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

test "sprites: screen_px quads keep their pixel size, tint multiplies, anchor offsets" {
    var fx = try Fixture.init(true);
    defer fx.deinit();
    // 2x2 white image
    const tex = wgpu_c.createTexture2D(fx.ctx.device, "test-sprite", .{ .width = 2, .height = 2, .format = c.WGPUTextureFormat_RGBA8Unorm, .usage = c.WGPUTextureUsage_TextureBinding | c.WGPUTextureUsage_CopyDst }).?;
    defer c.wgpuTextureRelease(tex);
    const white: [16]u8 = @splat(255);
    var dst = std.mem.zeroes(c.WGPUTexelCopyTextureInfo);
    dst.texture = tex;
    dst.aspect = c.WGPUTextureAspect_All;
    var layout = std.mem.zeroes(c.WGPUTexelCopyBufferLayout);
    layout.bytesPerRow = 8;
    layout.rowsPerImage = 2;
    const extent = c.WGPUExtent3D{ .width = 2, .height = 2, .depthOrArrayLayers = 1 };
    c.wgpuQueueWriteTexture(fx.ctx.queue, &dst, &white, white.len, &layout, &extent);
    const view = wgpu_c.createView2D(tex, "test-sprite-view", c.WGPUTextureFormat_RGBA8Unorm).?;
    defer c.wgpuTextureViewRelease(view);
    const imgs = OneImage{ .view = view };

    var d = drawFor(0); // identity camera: positions are clip space; px = 32 + 32 * x
    const sprites = [_]teak.SceneSprite{
        // 20x10 px centred at the origin, tinted red
        .{ .pos = .{ 0, 0, 0.5 }, .image = 3, .size = .{ 20, 10 }, .tint = .{ 1, 0, 0, 1 } },
        // bottom-left anchored 8x8 at (-0.75, 0.5) -> extends up and right of px (8, 16)
        .{ .pos = .{ -0.75, 0.5, 0.5 }, .image = 3, .size = .{ 8, 8 }, .anchor = .{ 0, 0 }, .tint = .{ 0, 1, 0, 1 } },
        // an unknown image draws nothing
        .{ .pos = .{ 0.5, -0.5, 0.5 }, .image = 77, .size = .{ 16, 16 } },
    };
    const a = try fx.renderFull(d, &.{}, &sprites, imgs);
    defer std.testing.allocator.free(a);
    try expectNear(px(a, 32, 32), .{ 0, 0, 255 }, 4); // red, centre
    try expectNear(px(a, 23, 32), .{ 0, 0, 255 }, 4); // within 10 px half width (22..42)
    try expectNear(px(a, 20, 32), .{ 0, 0, 0 }, 4); // just outside on the left
    try expectNear(px(a, 32, 26), .{ 0, 0, 0 }, 4); // above the 10 px height (27..37)
    try expectNear(px(a, 12, 12), .{ 0, 255, 0 }, 4); // anchored sprite: x 8..16, y 8..16 -> green
    try expectNear(px(a, 6, 12), .{ 0, 0, 0 }, 4); // left of its anchor
    try expectNear(px(a, 48, 48), .{ 0, 0, 0 }, 4); // unknown image

    // a sprite behind a mesh quad is depth-tested away (z 0.9 vs quad at 0.5)
    const mesh = quadMesh(&fx, 0.5, .{ 0, 0, 1 }, &.{});
    const behind = [_]teak.SceneSprite{.{ .pos = .{ 0, 0, 0.9 }, .image = 3, .size = .{ 20, 10 } }};
    d.camera.light_dir = .{ 0, 0, -1 };
    const b = try fx.renderFull(d, &.{.{ .mesh = mesh }}, &behind, imgs);
    defer std.testing.allocator.free(b);
    try expectNear(px(b, 32, 32), .{ 255, 0, 0 }, 4); // the blue quad (bgr), not white
}

test "scene_common is linked into the gpu test" {
    try std.testing.expectEqual(@as(usize, 208), @sizeOf(common.Globals));
}
