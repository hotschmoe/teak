//! Page 6: GPU resources - a depth-tested 3D mesh with feature lines, and a
//! generated RGBA image. Both are declared through `resources()` (HARDLINE
//! hatch 8): the app lists data under a key and a revision, the run loop owns
//! the upload.

const std = @import("std");
const teak = @import("teak");
const model = @import("model.zig");
const ui = @import("ui.zig");
const math = @import("math.zig");
const mesh = @import("mesh.zig");

const Model = model.Model;
const Msg = model.Msg;

pub const mesh_key: u32 = 1;
pub const image_key: u32 = 2;
pub const scene_w: f32 = 560;
pub const scene_h: f32 = 340;
const img_n = 64;

/// A plasma-ish gradient, built at comptime so the resource is static data.
const image_rgba: [img_n * img_n * 4]u8 = blk: {
    @setEvalBranchQuota(100_000);
    var px: [img_n * img_n * 4]u8 = undefined;
    for (0..img_n) |y| for (0..img_n) |x| {
        const fx: f32 = @as(f32, @floatFromInt(x)) / img_n;
        const fy: f32 = @as(f32, @floatFromInt(y)) / img_n;
        const i = (y * img_n + x) * 4;
        px[i + 0] = @intFromFloat(255 * fx);
        px[i + 1] = @intFromFloat(255 * fy);
        px[i + 2] = @intFromFloat(255 * (1 - (fx + fy) / 2));
        px[i + 3] = 255;
    };
    break :blk px;
};

const mesh_res = [_]teak.Resource{
    .{ .mesh = .{ .key = mesh_key, .rev = 1, .data = mesh.with_edges } },
    .{ .image = .{ .key = image_key, .rev = 1, .width = img_n, .height = img_n, .rgba = &image_rgba } },
};

pub fn resources(m: *const Model) []const teak.Resource {
    return if (m.page == .scene) &mesh_res else &.{};
}

fn camera(m: *const Model) teak.Camera {
    const target: math.Vec3 = .{ 2.2, 1.4, 0 };
    const el: f32 = 0.35;
    const eye: math.Vec3 = .{
        target[0] + m.distance * @cos(el) * @sin(m.azimuth),
        target[1] + m.distance * @sin(el),
        target[2] + m.distance * @cos(el) * @cos(m.azimuth),
    };
    const proj = math.perspective(0.8, scene_w / scene_h, 0.5, 60);
    const look = math.lookAt(eye, target, .{ 0, 1, 0 });
    return .{ .view_proj = math.mul(proj, look), .eye = eye, .light_dir = .{ -0.5, -1, -0.6 } };
}

pub fn view(m: *const Model, cb: anytype) void {
    const pal = cb.theme.palette;
    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 14, .align_cross = .start });

    cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 14, .width = scene_w + 22, .align_cross = .stretch });
    ui.card(cb, "3D scene", 0, 0);
    cb.scene3d(.{
        .style = .{ .width = scene_w, .height = scene_h },
        .mesh = mesh_key,
        .camera = camera(m),
        .clear = pal.bg_sunken,
        .edge_color = pal.fg,
        .edge_px = 1.5,
        .key = 1,
        .label = "stud wall detail",
    });
    ui.row(cb);
    cb.button(.scene_orbit, if (m.orbiting) "Pause orbit" else "Orbit");
    cb.button(.{ .scene_zoom = -0.8 }, "Zoom +");
    cb.button(.{ .scene_zoom = 0.8 }, "Zoom -");
    cb.textMuted(ui.fmt(cb, "azimuth {d:.2}  distance {d:.1}", .{ m.azimuth, m.distance }));
    ui.endRow(cb);
    ui.endCard(cb);
    cb.popGroup();

    cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 14, .width = 330, .align_cross = .stretch });
    ui.card(cb, "Image", 0, 0);
    ui.row(cb);
    cb.image(image_key, .{ .width = 96, .height = 96 });
    cb.image(image_key, .{ .width = 48, .height = 48, .tint = .{ 1, 0.7, 0.7, 1 } });
    ui.endRow(cb);
    cb.textMuted("A 64x64 RGBA texture;");
    cb.textMuted("the small copy is tinted.");
    ui.endCard(cb);

    ui.card(cb, "Resources hook", 0, 0);
    cb.textMuted("resources(m) lists (key, rev, data).");
    cb.textMuted("New key: upload. New rev: re-upload.");
    cb.textMuted("Gone from the list: released.");
    ui.endCard(cb);
    cb.popGroup();

    cb.popGroup();
}
