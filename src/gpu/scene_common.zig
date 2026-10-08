//! Backend-independent half of 3D scene rendering: uniform packing, target
//! sizing, the change-detection signature, and the composite quad. Both
//! `wgpu_scene.zig` (native) and `web.zig` (zunk) call these so the two
//! backends agree on layout, pixel snapping and when a scene has to be
//! re-rendered. Pure functions over `teak` data; no GPU types.

const std = @import("std");
const teak = @import("teak");

const SceneDraw = teak.SceneDraw;
const Rect = teak.Rect;
const Vertex = teak.Vertex;

/// Samples per pixel of MSAA scene targets.
pub const msaa_samples: u32 = 4;

/// At most this many scenes are rendered per frame; extras are dropped.
pub const max_scenes: usize = 16;

/// Upper bound on one scene target dimension (device pixels).
pub const max_target_dim: u32 = 8192;

/// Pull line quads toward the camera by this much NDC depth so they win
/// the depth test against the faces they outline.
pub const line_depth_bias: f32 = 1e-4;

/// Uniform block of `shaders/scene.wgsl` (`struct Globals`). 176 bytes.
pub const Globals = extern struct {
    view_proj: [16]f32,
    eye: [4]f32,
    light_dir: [4]f32,
    edge_color: [4]f32,
    /// x, y: target size in device pixels; z: line width in device
    /// pixels; w: line depth bias.
    viewport: [4]f32,
    /// Section plane `n.xyz, d`; fragments with `dot(n, p) + d > 0` are discarded when `misc.z` is set.
    clip: [4]f32,
    /// rgb = highlight colour, w = blend amount for `highlight` items.
    highlight: [4]f32,
    /// x = 1 for flat material (0 Lambert), z = 1 when the cut is enabled.
    misc: [4]f32,
};

/// `scale` = device pixels per logical pixel (1 on native; devicePixelRatio
/// on web, where teak's coordinates are CSS pixels).
pub fn globals(draw: SceneDraw, size: TargetSize, scale: f32) Globals {
    const e = draw.camera.eye;
    const l = draw.camera.light_dir;
    return .{
        .view_proj = draw.camera.view_proj,
        .eye = .{ e[0], e[1], e[2], 0 },
        .light_dir = .{ l[0], l[1], l[2], 0 },
        .edge_color = draw.edge_color,
        .viewport = .{
            @floatFromInt(size.w),
            @floatFromInt(size.h),
            @max(draw.edge_px, 0) * scale,
            line_depth_bias,
        },
        .clip = if (draw.cut) |c| c.plane else .{ 0, 0, 0, 0 },
        .highlight = .{ draw.highlight_color[0], draw.highlight_color[1], draw.highlight_color[2], draw.highlight_mix },
        .misc = .{
            if (draw.material == .flat) 1 else 0,
            0,
            if (draw.cut != null) 1 else 0,
            0,
        },
    };
}

pub const TargetSize = struct { w: u32, h: u32 };

/// The slice of the flat item list that belongs to `draw` (empty for a
/// legacy single-mesh scene, and clamped if the ranges are inconsistent).
pub fn itemsOf(draw: SceneDraw, items: []const teak.SceneItem) []const teak.SceneItem {
    if (draw.item_count == 0 or draw.item_first >= items.len) return &.{};
    const end = @min(items.len, @as(usize, draw.item_first) + draw.item_count);
    return items[draw.item_first..end];
}

/// Device-pixel size of the offscreen target for a scene occupying a
/// `rect_w x rect_h` logical rect; null when empty or non-finite.
pub fn targetSize(rect_w: f32, rect_h: f32, scale: f32) ?TargetSize {
    if (!(rect_w > 0 and rect_h > 0 and scale > 0)) return null;
    const w = @ceil(rect_w * scale);
    const h = @ceil(rect_h * scale);
    if (!std.math.isFinite(w) or !std.math.isFinite(h)) return null;
    const max: f32 = @floatFromInt(max_target_dim);
    return .{ .w = @intFromFloat(@min(w, max)), .h = @intFromFloat(@min(h, max)) };
}

/// Logical-pixel rect the composite quad covers: top-left snapped to the
/// device pixel grid and sized to the target, so the target maps 1:1 onto
/// screen pixels (no resampling blur).
pub fn compositeRect(draw: SceneDraw, size: TargetSize, scale: f32) Rect {
    return .{
        .x = @round(draw.rect_x * scale) / scale,
        .y = @round(draw.rect_y * scale) / scale,
        .w = @as(f32, @floatFromInt(size.w)) / scale,
        .h = @as(f32, @floatFromInt(size.h)) / scale,
    };
}

/// The six vertices that composite the scene's target into the UI pass,
/// clipped like an image; null when fully clipped.
pub fn compositeQuad(draw: SceneDraw, size: TargetSize, scale: f32) ?[6]Vertex {
    const clip: Rect = .{ .x = draw.clip_x, .y = draw.clip_y, .w = draw.clip_w, .h = draw.clip_h };
    return teak.vertex.clippedTexturedQuad(compositeRect(draw, size, scale), clip, .{ 1, 1, 1, 1 });
}

/// Hash of everything that affects the rendered pixels (not the rect's
/// position or the clip). Equal signatures mean the previous render of the
/// slot can be reused. `mesh_version` distinguishes re-uploads that happen
/// to land in the same mesh slot; `content` is `scene_pass.Plan.contentHash`
/// (the placed items and the versions of the meshes they use).
pub fn signature(draw: SceneDraw, size: TargetSize, scale: f32, content: u64) u64 {
    const g = globals(draw, size, scale);
    var h = std.hash.Wyhash.init(0);
    h.update(std.mem.asBytes(&g));
    h.update(std.mem.asBytes(&draw.clear));
    h.update(std.mem.asBytes(&content));
    if (draw.grid) |gr| {
        h.update("grid");
        h.update(std.mem.asBytes(&@backingInt(gr.plane)));
        for ([_]f32{ gr.offset, gr.spacing, gr.fade_dist }) |f| h.update(std.mem.asBytes(&f));
        h.update(std.mem.asBytes(&gr.major_every));
        for ([_][4]f32{ gr.minor, gr.major, gr.axis_a, gr.axis_b }) |col| h.update(std.mem.asBytes(&col));
    }
    if (draw.gizmo) |gz| {
        h.update("gizmo");
        h.update(std.mem.asBytes(&@backingInt(gz.corner)));
        for ([_]f32{ gz.size_px, gz.margin_px }) |f| h.update(std.mem.asBytes(&f));
        for (gz.colors) |col| h.update(std.mem.asBytes(&col));
    }
    if (draw.cut) |ct| {
        h.update("cut");
        h.update(std.mem.asBytes(&ct.cap_color));
        h.update(std.mem.asBytes(&ct.outline_px));
        h.update(&.{@intFromBool(ct.cap)});
    }
    return h.final();
}

fn testDraw() SceneDraw {
    return .{
        .mesh = 1,
        .rect_x = 10.4,
        .rect_y = 20,
        .rect_w = 100.2,
        .rect_h = 50,
        .clip_x = 0,
        .clip_y = 0,
        .clip_w = 1000,
        .clip_h = 1000,
    };
}

test "Globals is 176 bytes (matches the WGSL uniform block)" {
    try std.testing.expectEqual(@as(usize, 176), @sizeOf(Globals));
}

test "targetSize scales and rounds up, rejects empty and clamps huge" {
    const s = targetSize(100.2, 50, 2).?;
    try std.testing.expectEqual(@as(u32, 201), s.w);
    try std.testing.expectEqual(@as(u32, 100), s.h);
    try std.testing.expect(targetSize(0, 10, 1) == null);
    try std.testing.expect(targetSize(10, 10, 0) == null);
    try std.testing.expect(targetSize(std.math.nan(f32), 10, 1) == null);
    try std.testing.expectEqual(max_target_dim, targetSize(1e9, 10, 1).?.w);
}

test "globals converts edge width to device pixels" {
    const g = globals(testDraw(), .{ .w = 200, .h = 100 }, 2);
    try std.testing.expectEqual(@as(f32, 200), g.viewport[0]);
    try std.testing.expectEqual(@as(f32, 3), g.viewport[2]); // 1.5 logical px * 2
}

test "composite quad is device-pixel snapped and 1:1 with the target" {
    const d = testDraw();
    const size = targetSize(d.rect_w, d.rect_h, 1).?;
    const q = compositeQuad(d, size, 1).?;
    try std.testing.expectEqual(@as(f32, 10), q[0].x); // 10.4 snapped
    try std.testing.expectEqual(@as(f32, 20), q[0].y);
    try std.testing.expectEqual(@as(f32, 10 + 101), q[1].x); // width = ceil(100.2)
    try std.testing.expectEqual(@as(f32, 0), q[0].u);
    try std.testing.expectEqual(@as(f32, 1), q[4].u);
}

test "composite quad honours the scroll clip" {
    var d = testDraw();
    d.clip_x = 60; // crop the left part away
    d.clip_w = 1000;
    const size = targetSize(d.rect_w, d.rect_h, 1).?;
    const q = compositeQuad(d, size, 1).?;
    try std.testing.expectEqual(@as(f32, 60), q[0].x);
    try std.testing.expect(q[0].u > 0.4 and q[0].u < 0.6);
    d.clip_x = 500;
    try std.testing.expect(compositeQuad(d, size, 1) == null);
}

test "signature ignores position, reacts to camera, clear, mesh version, size" {
    const base = testDraw();
    const size = targetSize(base.rect_w, base.rect_h, 1).?;
    const sig = signature(base, size, 1, 1);

    var moved = base;
    moved.rect_x += 50;
    moved.clip_w = 5;
    try std.testing.expectEqual(sig, signature(moved, size, 1, 1));

    var cam = base;
    cam.camera.view_proj[12] = 0.5;
    try std.testing.expect(sig != signature(cam, size, 1, 1));

    var clr = base;
    clr.clear[0] = 0.5;
    try std.testing.expect(sig != signature(clr, size, 1, 1));

    try std.testing.expect(sig != signature(base, size, 1, 2));
    try std.testing.expect(sig != signature(base, .{ .w = size.w + 1, .h = size.h }, 1, 1));
}

test "signature reacts to grid, gizmo, cut, material and highlight" {
    const base = testDraw();
    const size = targetSize(base.rect_w, base.rect_h, 1).?;
    const sig = signature(base, size, 1, 1);
    var d = base;
    d.grid = .{};
    const with_grid = signature(d, size, 1, 1);
    try std.testing.expect(sig != with_grid);
    d.grid.?.spacing = 24;
    try std.testing.expect(with_grid != signature(d, size, 1, 1));
    d = base;
    d.gizmo = .{};
    try std.testing.expect(sig != signature(d, size, 1, 1));
    d = base;
    d.cut = .{ .plane = .{ 0, 1, 0, 0 } };
    const with_cut = signature(d, size, 1, 1);
    try std.testing.expect(sig != with_cut);
    d.cut.?.plane[3] = 1;
    try std.testing.expect(with_cut != signature(d, size, 1, 1));
    d = base;
    d.material = .flat;
    try std.testing.expect(sig != signature(d, size, 1, 1));
    d = base;
    d.highlight_color[0] = 0.9;
    try std.testing.expect(sig != signature(d, size, 1, 1));
}

test "globals carries the cut plane, enable flag, material and highlight" {
    var d = testDraw();
    const size = targetSize(d.rect_w, d.rect_h, 1).?;
    try std.testing.expectEqual(@as(f32, 0), globals(d, size, 1).misc[2]);
    d.cut = .{ .plane = .{ 0, 1, 0, -2 } };
    d.material = .flat;
    d.highlight_mix = 0.25;
    const g = globals(d, size, 1);
    try std.testing.expectEqual(@as(f32, -2), g.clip[3]);
    try std.testing.expectEqual(@as(f32, 1), g.misc[2]);
    try std.testing.expectEqual(@as(f32, 1), g.misc[0]);
    try std.testing.expectEqual(@as(f32, 0.25), g.highlight[3]);
}

test "itemsOf slices the flat list and clamps bad ranges" {
    const items = [_]teak.SceneItem{ .{ .mesh = 1 }, .{ .mesh = 2 }, .{ .mesh = 3 } };
    var d = testDraw();
    try std.testing.expectEqual(@as(usize, 0), itemsOf(d, &items).len);
    d.item_first = 1;
    d.item_count = 2;
    try std.testing.expectEqual(@as(u32, 2), itemsOf(d, &items)[0].mesh);
    d.item_count = 9;
    try std.testing.expectEqual(@as(usize, 2), itemsOf(d, &items).len);
    d.item_first = 7;
    try std.testing.expectEqual(@as(usize, 0), itemsOf(d, &items).len);
}
