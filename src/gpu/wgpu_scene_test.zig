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
        var draw = draw_in;
        draw.item_first = 0;
        draw.item_count = @intCast(items.len);
        var enc_desc = std.mem.zeroes(c.WGPUCommandEncoderDescriptor);
        const encoder = c.wgpuDeviceCreateCommandEncoder(self.ctx.device, &enc_desc);
        const size = self.renderer.renderInto(encoder, 0, draw, items, 1) orelse return error.NoTarget;
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

test "scene_common is linked into the gpu test" {
    try std.testing.expectEqual(@as(usize, 176), @sizeOf(common.Globals));
}
