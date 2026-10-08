//! scene_layers: 2.5D in a 3D scene. Three tilted drawing sheets (vector
//! content drawn from ordinary `CanvasPrimitive`s), a translucent annotation
//! layer and image billboards float around a small Kerf-style structure, all
//! in one `viewport3d`: planes and sprites are just more `View` data, drawn
//! by the same pass into the same depth buffer. Orbit with the left mouse
//! button, pan with middle / shift, wheel zooms to the cursor; click a sheet
//! or a marker to select it (CPU ray / screen-quad picking, no GPU readback).
//!
//! Labels over the 3D view are ordinary overlay text anchored at
//! `scene.project(...)` positions plus the viewport's window origin (the
//! canvas `layout` event).

const std = @import("std");
const teak = @import("teak");

const scene = teak.scene;
const Orbit = scene.Orbit;
const Vec3 = scene.mat.Vec3;

// ── Palette (kerf/spec/DESIGN.md) ──────────────────────────────────

pub const paper: [4]f32 = .{ 0.949, 0.937, 0.902, 1 };
const paper2: [4]f32 = .{ 0.914, 0.898, 0.847, 1 };
const vellum: [4]f32 = .{ 0.984, 0.980, 0.961, 1 };
const ink: [4]f32 = .{ 0.102, 0.102, 0.102, 1 };
const ink2: [4]f32 = .{ 0.333, 0.322, 0.294, 1 };
const blue: [4]f32 = .{ 0.114, 0.306, 0.620, 1 };
const red: [4]f32 = .{ 0.784, 0.063, 0.180, 1 };
const grid_blue: [4]f32 = .{ 0.663, 0.757, 0.867, 1 };
const term_bg: [4]f32 = .{ 0.055, 0.071, 0.055, 1 };
const term_fg: [4]f32 = .{ 0.361, 0.949, 0.478, 1 };
const clear: [4]f32 = .{ 0, 0, 0, 0 };

const plex: teak.FontSpec = .{ .size_px = 13, .family = .mono };
const plex_bold: teak.FontSpec = .{ .size_px = 13, .family = .mono, .weight = .bold };
const plex_small: teak.FontSpec = .{ .size_px = 11, .family = .mono, .weight = .bold, .letter_spacing = 1 };

pub const theme: teak.Theme = .{
    .palette = .{ .bg = paper, .bg_panel = paper, .bg_sunken = paper2, .bg_raised = paper, .bg_hover = ink, .bg_press = ink, .fg = ink, .fg_muted = ink2, .accent = blue, .danger = red, .border = ink },
    .typography = .{ .body = plex, .mono = plex, .small = plex, .heading = plex_bold },
    .text_color = ink,
    .heading_color = ink,
    .muted_color = ink2,
    .danger_color = red,
    .panel_bg = paper,
    .button = key_button,
    .divider = .{ .thickness = 1, .color = ink },
    .card = .{ .padding = 10, .gap = 6, .bg = paper, .border = ink, .align_cross = .stretch },
};

const key_button: teak.ButtonStyle = .{ .bg = paper, .hover_bg = ink, .press_bg = ink, .fg = ink, .hover_fg = paper, .press_fg = paper, .press_offset_y = 1, .border = ink, .label_align = .center, .height = 26, .min_width = 0, .h_padding = 12 };
const tab_button: teak.ButtonStyle = .{ .bg = clear, .hover_bg = paper2, .press_bg = paper2, .fg = ink, .label_align = .center, .height = 24, .min_width = 0, .h_padding = 8 };
const row_button: teak.ButtonStyle = .{ .bg = clear, .hover_bg = paper2, .press_bg = paper2, .fg = ink, .label_align = .start, .height = 24, .min_width = 0, .h_padding = 6 };
const row_button_on: teak.ButtonStyle = .{ .bg = ink, .hover_bg = ink, .press_bg = ink, .fg = paper, .label_align = .start, .height = 24, .min_width = 0, .h_padding = 6 };

// ── Scene content ──────────────────────────────────────────────────

pub const scene_id: u32 = 7;
const mesh_key: u32 = 1;
const img_ring: u32 = 1;
const img_bubble: u32 = 2;

/// What can be selected: a sheet (id 1..3), the annotation layer (4) or a marker (11..16).
const Layer = struct { id: u32, name: []const u8, kind: []const u8 };
const layers = [_]Layer{
    .{ .id = 1, .name = "A SECTION", .kind = "SHEET" },
    .{ .id = 2, .name = "B ELEVATION", .kind = "SHEET" },
    .{ .id = 3, .name = "C PLAN", .kind = "SHEET" },
    .{ .id = 4, .name = "ANNOTATIONS", .kind = "LAYER" },
    .{ .id = 11, .name = "DETAIL 1", .kind = "MARKER" },
    .{ .id = 12, .name = "DETAIL 2", .kind = "MARKER" },
    .{ .id = 13, .name = "DETAIL 3", .kind = "MARKER" },
    .{ .id = 14, .name = "DETAIL 4", .kind = "MARKER" },
};

const sheet_size = [2]f32{ 120, 80 };

/// Frame of each sheet: origin is the top-left as seen from the front; `u`
/// runs right, `v` runs down the page (the canvas y axis).
fn sheetFrame(id: u32) struct { origin: Vec3, u: Vec3, v: Vec3 } {
    // `u`/`v` are world units per sheet unit, so 0.8 draws the 120 x 80 page at 96 x 64 inches.
    return switch (id) {
        // behind the structure, upright, facing +z
        1 => .{ .origin = .{ 0, 80, -30 }, .u = .{ 0.8, 0, 0 }, .v = .{ 0, -0.8, 0 } },
        // beside it on the left, upright, turned about 30 degrees toward the iso camera
        2 => .{ .origin = .{ -76, 80, -4 }, .u = .{ 0.4, 0, 0.693 }, .v = .{ 0, -0.8, 0 } },
        // a plan sheet leaning on the ground in front: page down = toward the viewer, raised at the back
        else => .{ .origin = .{ 0, 20, 62 }, .u = .{ 0.8, 0, 0 }, .v = .{ 0, -0.27, 0.75 } },
    };
}

/// Where each marker floats (model inches).
fn markerPos(id: u32) Vec3 {
    return switch (id) {
        11 => .{ 48, 96, 12 },
        12 => .{ 108, 24, 56 },
        13 => .{ 20, 44, -24 },
        else => .{ -44, 50, 22 },
    };
}

// ── Model / Msg / update ───────────────────────────────────────────

pub const Model = struct {
    cam: Orbit = .{ .target = .{ 48, 40, 30 }, .dist = 270, .yaw = -0.62, .pitch = 0.42 },
    vp: [2]f32 = .{ 800, 600 },
    vp_origin: [2]f32 = .{ 0, 0 },
    selected: u32 = 0,
    hovered: u32 = 0,
    drag_px: f32 = 0,
    annotations: bool = true,

    /// The layer under viewport-local px `(x, y)` (0 = none).
    pub fn pickAt(m: *const Model, x: f32, y: f32, w: f32, h: f32) u32 {
        return pickAtImpl(m, x, y, w, h);
    }
};

pub const Msg = union(enum) {
    view_event: teak.CanvasEvent,
    select: u32,
    preset: Orbit.Preset,
    toggle_annotations,
    noop,
};

pub fn update(m: *Model, msg: Msg) void {
    switch (msg) {
        .view_event => |ev| viewEvent(m, ev),
        .select => |id| m.selected = if (id == m.selected) 0 else id,
        .preset => |p| m.cam.setPreset(p),
        .toggle_annotations => m.annotations = !m.annotations,
        .noop => {},
    }
}

fn viewEvent(m: *Model, ev: teak.CanvasEvent) void {
    switch (ev.kind) {
        .layout => {
            m.vp = .{ ev.w, ev.h };
            m.vp_origin = .{ ev.x, ev.y };
        },
        .down => if (ev.button == .left) {
            m.drag_px = 0;
        },
        .move => if (ev.buttons.any()) {
            m.drag_px += @abs(ev.dx) + @abs(ev.dy);
        } else {
            m.hovered = m.pickAt(ev.x, ev.y, ev.w, ev.h);
        },
        .up => if (ev.button == .left and m.drag_px < 4 and !ev.mods.shift) {
            m.selected = m.pickAt(ev.x, ev.y, ev.w, ev.h);
        },
        .leave => m.hovered = 0,
        .wheel, .key => {},
    }
    _ = m.cam.onEvent(ev, .{});
}

/// The one pointer hook: the scene viewport.
pub fn pointerMsg(m: *const Model, ev: teak.PointerEvent(Msg)) ?Msg {
    if (ev.asCanvas()) |c| return onCanvas(m, c);
    return null;
}

fn onCanvas(_: *const Model, ev: teak.CanvasEvent) ?Msg {
    return if (ev.id == scene_id) Msg{ .view_event = ev } else null;
}

pub fn keyCharMsg(_: *const Model, c: u8) ?Msg {
    return switch (c) {
        '1' => Msg{ .preset = .front },
        '2' => Msg{ .preset = .iso },
        '3' => Msg{ .preset = .top },
        '4' => Msg{ .preset = .right },
        'a', 'A' => .toggle_annotations,
        else => null,
    };
}

pub fn themeFor(_: *const Model) teak.Theme {
    return theme;
}

pub fn camera(m: *const Model) teak.Camera {
    return m.cam.camera(m.vp[0], m.vp[1], .{ .lo = .{ -20, -10, -40 }, .hi = .{ 130, 100, 90 } });
}

// ── Picking (pure: ray / screen quad against the same data the view emits) ──

/// Which layer is under viewport-local px `(x, y)`: markers first (they float
/// in front), then the nearest sheet or the annotation layer. 0 = nothing.
fn pickAtImpl(m: *const Model, x: f32, y: f32, w: f32, h: f32) u32 {
    var buf: [16]teak.SceneSprite = undefined;
    const sprites = markerSprites(m, &buf);
    if (scene.pick.sprites(camera(m), w, h, x, y, sprites)) |s| return s.id;
    var pbuf: [4]teak.ScenePlane = undefined;
    const planes_list = planeFrames(m, &pbuf);
    const ray = scene.pickRay(camera(m), w, h, x, y);
    if (scene.pick.planes(ray, planes_list)) |p| return p.id;
    return 0;
}

// ── Layers as View data ────────────────────────────────────────────

/// The planes without content (frames only): enough for picking.
fn planeFrames(m: *const Model, buf: *[4]teak.ScenePlane) []const teak.ScenePlane {
    var n: usize = 0;
    for ([_]u32{ 1, 2, 3 }) |id| {
        const f = sheetFrame(id);
        buf[n] = .{ .origin = f.origin, .u = f.u, .v = f.v, .size = sheet_size, .id = id };
        n += 1;
    }
    if (m.annotations) {
        buf[n] = annotationPlane(&.{});
        n += 1;
    }
    return buf[0..n];
}

fn annotationPlane(content: []const teak.CanvasPrimitive) teak.ScenePlane {
    // A clear sheet standing in front of the structure, facing +z, y up the page.
    return .{ .origin = .{ -4, 86, 58 }, .u = .{ 0.85, 0, 0 }, .v = .{ 0, -0.85, 0 }, .size = .{ 116, 70 }, .content = content, .opacity = 0.85, .layer = 2, .id = 4 };
}

fn markerSprites(m: *const Model, buf: []teak.SceneSprite) []const teak.SceneSprite {
    const ids = [_]u32{ 11, 12, 13, 14 };
    var n: usize = 0;
    for (ids) |id| {
        const lit = m.selected == id;
        buf[n] = .{
            .pos = markerPos(id),
            .image = if (id == 11 or id == 14) img_bubble else img_ring,
            .size = .{ 30, 30 },
            .size_in = .screen_px,
            .tint = if (lit) .{ 0.114, 0.306, 0.62, 1 } else if (m.hovered == id) .{ 1, 0.55, 0.3, 1 } else .{ 0.78, 0.063, 0.18, 1 },
            .id = id,
        };
        n += 1;
    }
    return buf[0..n];
}

fn sheetPlane(a: std.mem.Allocator, m: *const Model, id: u32) teak.ScenePlane {
    const f = sheetFrame(id);
    const picked = m.selected == id;
    return .{
        .origin = f.origin,
        .u = f.u,
        .v = f.v,
        .size = sheet_size,
        .content = sheetContent(a, id, picked or m.hovered == id, picked),
        .background = vellum,
        .layer = if (picked) 1 else 0,
        .id = id,
    };
}

const Prims = std.ArrayList(teak.CanvasPrimitive);
const Pt = teak.CanvasPoint;

fn rectOutline(a: std.mem.Allocator, prims: *Prims, x0: f32, y0: f32, x1: f32, y1: f32, color: [4]f32, thick: f32) void {
    const pts = a.dupe(Pt, &.{ .{ .x = x0, .y = y0 }, .{ .x = x1, .y = y0 }, .{ .x = x1, .y = y1 }, .{ .x = x0, .y = y1 }, .{ .x = x0, .y = y0 } }) catch return;
    prims.append(a, .{ .polyline = .{ .points = pts, .color = color, .thickness = thick } }) catch {};
}

/// 45 degree hatch inside a rect (axis-aligned clip done by hand).
fn hatch(a: std.mem.Allocator, prims: *Prims, x0: f32, y0: f32, x1: f32, y1: f32, gap: f32, color: [4]f32) void {
    var segs: std.ArrayList([4]f32) = .empty;
    var d = x0 - (y1 - y0);
    while (d < x1) : (d += gap) {
        // line y = (x - d) + y0, clipped to the rect
        var ax = d;
        var ay = y0;
        var bx = d + (y1 - y0);
        var by = y1;
        if (ax < x0) {
            ay += x0 - ax;
            ax = x0;
        }
        if (bx > x1) {
            by -= bx - x1;
            bx = x1;
        }
        if (ax < bx and ay < by) segs.append(a, .{ ax, ay, bx, by }) catch return;
    }
    prims.append(a, .{ .lines = .{ .segs = segs.items, .color = color, .thickness = 0.9, .key = 0 } }) catch {};
}

fn dimension(a: std.mem.Allocator, prims: *Prims, x0: f32, y0: f32, x1: f32, y1: f32, color: [4]f32) void {
    const pts = a.dupe(Pt, &.{ .{ .x = x0, .y = y0 }, .{ .x = x1, .y = y1 } }) catch return;
    prims.append(a, .{ .polyline = .{ .points = pts, .color = color, .thickness = 1.0 } }) catch {};
    for ([_][2]f32{ .{ x0, y0 }, .{ x1, y1 } }) |p| {
        prims.append(a, .{ .marker = .{ .x = p[0], .y = p[1], .size = 3, .color = color } }) catch {};
    }
}

/// Drawing-sheet content in sheet units (y down): frame, title block and a
/// view that differs per sheet. Pure data from `id` and the highlight state.
fn sheetContent(a: std.mem.Allocator, id: u32, lit: bool, picked: bool) []const teak.CanvasPrimitive {
    var p: Prims = .empty;
    const w = sheet_size[0];
    const h = sheet_size[1];
    const frame_color = if (picked) blue else ink;
    rectOutline(a, &p, 3, 3, w - 3, h - 3, frame_color, if (picked) 2.4 else 1.5);
    // title block
    p.append(a, .{ .filled_rect = .{ .x = 3, .y = h - 13, .w = w - 6, .h = 10, .color = if (lit) .{ 0.90, 0.93, 0.98, 1 } else .{ 0.93, 0.91, 0.84, 1 } } }) catch {};
    rectOutline(a, &p, 3, h - 13, w - 3, h - 3, frame_color, 1.1);
    for ([_]f32{ 40, 84 }) |x| {
        const pts = a.dupe(Pt, &.{ .{ .x = x, .y = h - 13 }, .{ .x = x, .y = h - 3 } }) catch continue;
        p.append(a, .{ .polyline = .{ .points = pts, .color = frame_color, .thickness = 1.0 } }) catch {};
    }
    // faint blueprint grid
    var g: f32 = 10;
    while (g < w - 3) : (g += 10) {
        p.append(a, .{ .vline = .{ .x = g, .color = .{ 0.663, 0.757, 0.867, 0.28 }, .thickness = 0.8 } }) catch {};
    }
    g = 10;
    while (g < h - 13) : (g += 10) {
        p.append(a, .{ .hline = .{ .y = g, .color = .{ 0.663, 0.757, 0.867, 0.28 }, .thickness = 0.8 } }) catch {};
    }
    switch (id) {
        1 => { // SECTION: footing + stem + sill, hatched concrete
            rectOutline(a, &p, 30, 48, 90, 60, ink, 1.6);
            hatch(a, &p, 30, 48, 90, 60, 3, ink2);
            rectOutline(a, &p, 52, 16, 68, 48, ink, 1.6);
            hatch(a, &p, 52, 16, 68, 48, 3, ink2);
            rectOutline(a, &p, 48, 12, 72, 16, ink, 1.6);
            dimension(a, &p, 30, 66, 90, 66, red);
            dimension(a, &p, 98, 16, 98, 60, red);
            p.append(a, .{ .marker = .{ .x = 60, .y = 54, .size = 3.5, .color = blue } }) catch {};
        },
        2 => { // ELEVATION: three stud bays and a plate
            rectOutline(a, &p, 20, 14, 100, 58, ink, 1.6);
            var x: f32 = 28;
            while (x < 96) : (x += 16) {
                const pts = a.dupe(Pt, &.{ .{ .x = x, .y = 14 }, .{ .x = x, .y = 58 } }) catch continue;
                p.append(a, .{ .polyline = .{ .points = pts, .color = ink, .thickness = 1.2 } }) catch {};
            }
            rectOutline(a, &p, 20, 14, 100, 20, ink, 1.6);
            dimension(a, &p, 20, 64, 100, 64, red);
        },
        else => { // PLAN: footprint with a bolt circle
            rectOutline(a, &p, 24, 14, 96, 54, ink, 1.6);
            rectOutline(a, &p, 40, 26, 80, 42, ink2, 1.2);
            var k: usize = 0;
            while (k < 4) : (k += 1) {
                const px: f32 = if (k % 2 == 0) 30 else 90;
                const py: f32 = if (k < 2) 20 else 48;
                p.append(a, .{ .marker = .{ .x = px, .y = py, .size = 4, .color = red } }) catch {};
            }
            dimension(a, &p, 24, 62, 96, 62, red);
        },
    }
    return p.items;
}

/// A hand-drawn grid + callout box on the translucent annotation layer.
fn annotationContent(a: std.mem.Allocator, lit: bool) []const teak.CanvasPrimitive {
    var p: Prims = .empty;
    const c = if (lit) blue else grid_blue;
    rectOutline(a, &p, 2, 2, 114, 68, c, 1.2);
    var g: f32 = 14;
    while (g < 114) : (g += 14) {
        p.append(a, .{ .vline = .{ .x = g, .color = .{ c[0], c[1], c[2], 0.45 }, .thickness = 0.8 } }) catch {};
    }
    g = 14;
    while (g < 68) : (g += 14) {
        p.append(a, .{ .hline = .{ .y = g, .color = .{ c[0], c[1], c[2], 0.45 }, .thickness = 0.8 } }) catch {};
    }
    p.append(a, .{ .filled_rect = .{ .x = 6, .y = 6, .w = 30, .h = 8, .color = .{ c[0], c[1], c[2], 0.5 } } }) catch {};
    return p.items;
}

// ── Resources: one mesh, two generated marker images ───────────────

const marker_px = 48;

/// A ring (outline circle) and a filled bubble with a notch, white on
/// transparent so the sprite tint colours them.
fn markerImage(comptime bubble: bool) [marker_px * marker_px * 4]u8 {
    @setEvalBranchQuota(200_000);
    var out: [marker_px * marker_px * 4]u8 = undefined;
    const c: f32 = @as(f32, marker_px - 1) / 2.0;
    for (0..marker_px) |yy| for (0..marker_px) |xx| {
        const dx = @as(f32, @floatFromInt(xx)) - c;
        const dy = @as(f32, @floatFromInt(yy)) - c;
        const r = @sqrt(dx * dx + dy * dy);
        // coverage with ~1px feather
        const outer = std.math.clamp(c - 1 - r + 0.5, 0, 1);
        var cov: f32 = outer;
        if (!bubble) {
            const inner = std.math.clamp(r - (c - 7) + 0.5, 0, 1);
            cov = outer * inner;
            // a centre dot
            cov = @max(cov, std.math.clamp(3.5 - r + 0.5, 0, 1));
        } else {
            // knock out a small cross so it reads as a callout bubble
            const bar = @min(@abs(dx), @abs(dy));
            if (@abs(dx) < c * 0.62 and @abs(dy) < c * 0.62 and bar < 2.2) cov *= 1 - std.math.clamp(2.2 - bar + 0.5, 0, 1);
        }
        const o = (yy * marker_px + xx) * 4;
        out[o + 0] = 255;
        out[o + 1] = 255;
        out[o + 2] = 255;
        out[o + 3] = @intFromFloat(cov * 255);
    };
    return out;
}

const ring_rgba = markerImage(false);
const bubble_rgba = markerImage(true);

const structure = buildStructure();

const resources_list = [_]teak.Resource{
    .{ .mesh = .{ .key = mesh_key, .rev = 1, .data = structure.data() } },
    .{ .image = .{ .key = img_ring, .rev = 1, .width = marker_px, .height = marker_px, .rgba = &ring_rgba } },
    .{ .image = .{ .key = img_bubble, .rev = 1, .width = marker_px, .height = marker_px, .rgba = &bubble_rgba } },
};

pub fn resources(_: *const Model) []const teak.Resource {
    return &resources_list;
}

/// Boxes with outlined edges, built at comptime: footing, stem, sill plate,
/// a stud wall and a slab beside it.
const Box = struct { lo: Vec3, hi: Vec3, color: [3]f32 };
const boxes = [_]Box{
    .{ .lo = .{ 0, 0, 0 }, .hi = .{ 96, 12, 48 }, .color = .{ 0.62, 0.62, 0.6 } }, // footing
    .{ .lo = .{ 36, 12, 8 }, .hi = .{ 60, 44, 40 }, .color = .{ 0.7, 0.7, 0.68 } }, // stem wall
    .{ .lo = .{ 32, 44, 4 }, .hi = .{ 64, 48, 44 }, .color = .{ 0.74, 0.62, 0.45 } }, // sill plate
    .{ .lo = .{ 36, 48, 10 }, .hi = .{ 42, 78, 14 }, .color = .{ 0.82, 0.7, 0.5 } }, // studs
    .{ .lo = .{ 48, 48, 10 }, .hi = .{ 54, 78, 14 }, .color = .{ 0.82, 0.7, 0.5 } },
    .{ .lo = .{ 56, 48, 10 }, .hi = .{ 62, 78, 14 }, .color = .{ 0.82, 0.7, 0.5 } },
    .{ .lo = .{ 34, 78, 8 }, .hi = .{ 64, 82, 18 }, .color = .{ 0.74, 0.62, 0.45 } }, // top plate
};

const Structure = struct {
    verts: [boxes.len * 24]teak.MeshVertex,
    idx: [boxes.len * 36]u32,
    lines: [boxes.len * 24]teak.LineVertex,

    fn data(self: *const Structure) teak.MeshData {
        return .{ .vertices = &self.verts, .indices = &self.idx, .lines = &self.lines };
    }
};

fn buildStructure() Structure {
    @setEvalBranchQuota(100_000);
    var s: Structure = undefined;
    const faces = [6]struct { n: Vec3, a: Vec3, b: Vec3 }{
        .{ .n = .{ 1, 0, 0 }, .a = .{ 0, 1, 0 }, .b = .{ 0, 0, 1 } },
        .{ .n = .{ -1, 0, 0 }, .a = .{ 0, 0, 1 }, .b = .{ 0, 1, 0 } },
        .{ .n = .{ 0, 1, 0 }, .a = .{ 0, 0, 1 }, .b = .{ 1, 0, 0 } },
        .{ .n = .{ 0, -1, 0 }, .a = .{ 1, 0, 0 }, .b = .{ 0, 0, 1 } },
        .{ .n = .{ 0, 0, 1 }, .a = .{ 1, 0, 0 }, .b = .{ 0, 1, 0 } },
        .{ .n = .{ 0, 0, -1 }, .a = .{ 0, 1, 0 }, .b = .{ 1, 0, 0 } },
    };
    for (boxes, 0..) |bx, bi| {
        const cx = (bx.lo[0] + bx.hi[0]) / 2;
        const cy = (bx.lo[1] + bx.hi[1]) / 2;
        const cz = (bx.lo[2] + bx.hi[2]) / 2;
        const hx = (bx.hi[0] - bx.lo[0]) / 2;
        const hy = (bx.hi[1] - bx.lo[1]) / 2;
        const hz = (bx.hi[2] - bx.lo[2]) / 2;
        const col = [4]f32{ bx.color[0], bx.color[1], bx.color[2], 1 };
        for (faces, 0..) |f, fi| {
            const signs = [4][2]f32{ .{ -1, -1 }, .{ 1, -1 }, .{ 1, 1 }, .{ -1, 1 } };
            const base: u32 = @intCast(bi * 24 + fi * 4);
            for (signs, 0..) |sg, k| {
                var pos: Vec3 = undefined;
                const half = Vec3{ hx, hy, hz };
                const ctr = Vec3{ cx, cy, cz };
                for (0..3) |ax| pos[ax] = ctr[ax] + half[ax] * (f.n[ax] + sg[0] * f.a[ax] + sg[1] * f.b[ax]);
                s.verts[bi * 24 + fi * 4 + k] = .{ .pos = pos, .normal = f.n, .color = col };
            }
            const tri = [6]u32{ 0, 1, 2, 0, 2, 3 };
            for (tri, 0..) |t, k| s.idx[bi * 36 + fi * 6 + k] = base + t;
        }
        // 12 edges
        var e: usize = 0;
        for (0..8) |i| {
            for (0..3) |axis| {
                if (i & (@as(usize, 1) << @intCast(axis)) != 0) continue;
                var a: Vec3 = undefined;
                var b: Vec3 = undefined;
                for (0..3) |k| {
                    const hi = i & (@as(usize, 1) << @intCast(k)) != 0;
                    a[k] = if (hi) bx.hi[k] else bx.lo[k];
                    b[k] = if (k == axis) bx.hi[k] else a[k];
                }
                a[axis] = bx.lo[axis];
                const ink_c = [4]f32{ 0.1, 0.1, 0.1, 1 };
                s.lines[bi * 24 + e * 2] = .{ .pos = a, .color = ink_c };
                s.lines[bi * 24 + e * 2 + 1] = .{ .pos = b, .color = ink_c };
                e += 1;
            }
        }
    }
    return s;
}

// ── View ───────────────────────────────────────────────────────────

pub fn view(m: *const Model, cb: anytype) void {
    cb.pushGroup(.{ .padding = 0, .gap = 0, .bg = paper, .align_cross = .stretch });
    header(cb);
    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 0, .flex = 1, .align_cross = .stretch });
    centerColumn(m, cb);
    sideColumn(m, cb);
    cb.popGroup();
    statusBar(m, cb);
    cb.popGroup();
    labels(m, cb);
}

fn header(cb: anytype) void {
    cb.pushGroup(.{ .direction = .horizontal, .pad_x = 12, .pad_y = 0, .gap = 12, .height = 40, .bg = ink, .align_cross = .center });
    cb.textStyled("KERF", .{ .size_px = 22, .family = .mono, .weight = .bold, .letter_spacing = 4 }, paper);
    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 3, .align_cross = .center });
    for (0..3) |_| {
        cb.pushGroup(.{ .padding = 0, .gap = 0, .width = 6, .height = 14, .bg = paper });
        cb.popGroup();
    }
    cb.popGroup();
    cb.textStyled("2.5D LAYERS", plex, .{ 0.72, 0.70, 0.64, 1 });
    cb.popGroup();
    cb.pushGroup(.{ .padding = 0, .gap = 0, .height = 2, .bg = ink });
    cb.popGroup();
}

fn centerColumn(m: *const Model, cb: anytype) void {
    cb.pushGroup(.{ .padding = 12, .gap = 8, .flex = 1, .bg = paper2, .align_cross = .stretch });
    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 4, .align_cross = .center });
    for ([_]struct { l: []const u8, p: Orbit.Preset }{ .{ .l = "[FRONT]", .p = .front }, .{ .l = "[ISO]", .p = .iso }, .{ .l = "[TOP]", .p = .top }, .{ .l = "[RIGHT]", .p = .right } }) |b| {
        cb.buttonStyled(.{ .preset = b.p }, b.l, tab_button);
    }
    cb.spacer(1);
    cb.buttonStyled(.toggle_annotations, if (m.annotations) "[ANNOTATIONS ON]" else "[ANNOTATIONS OFF]", tab_button);
    cb.popGroup();
    viewport(m, cb);
    cb.popGroup();
}

fn viewport(m: *const Model, cb: anytype) void {
    const a = cb.arena.allocator();
    const planes_buf = a.alloc(teak.ScenePlane, 4) catch return;
    var n: usize = 0;
    for ([_]u32{ 1, 2, 3 }) |id| {
        planes_buf[n] = sheetPlane(a, m, id);
        n += 1;
    }
    if (m.annotations) {
        var ap = annotationPlane(annotationContent(a, m.selected == 4));
        if (m.hovered == 4 or m.selected == 4) ap.opacity = 1;
        planes_buf[n] = ap;
        n += 1;
    }
    const sprites_buf = a.alloc(teak.SceneSprite, 4) catch return;
    const sprites = markerSprites(m, sprites_buf);

    cb.pushGroup(.{ .padding = 1, .gap = 0, .flex = 1, .border = ink, .bg = paper, .align_cross = .stretch });
    cb.viewport3d(.{
        .style = .{ .width = 480, .height = 320, .flex = 1 },
        .view = .{
            .items = &.{.{ .mesh = mesh_key, .id = 100 }},
            .planes = planes_buf[0..n],
            .sprites = sprites,
            .grid = .{
                .offset = -1,
                .spacing = 12,
                .minor = .{ 0.827, 0.878, 0.933, 1 },
                .major = .{ 0.663, 0.757, 0.867, 1 },
                .axis_a = .{ 0.784, 0.063, 0.18, 0.8 },
                .axis_b = .{ 0.114, 0.306, 0.62, 0.8 },
            },
        },
        .camera = camera(m),
        .clear = paper,
        .edge_color = .{ 1, 1, 1, 1 },
        .edge_px = 1.25,
        .id = scene_id,
        .pointer = true,
        .label = "2.5D scene",
    });
    cb.popGroup();
}

/// Sheet titles as 2D text anchored at each sheet's top-left, projected.
fn labels(m: *const Model, cb: anytype) void {
    const cam = camera(m);
    for ([_]u32{ 1, 2, 3 }) |id| {
        const f = sheetFrame(id);
        const p = scene.project(cam, m.vp[0], m.vp[1], f.origin) orelse continue;
        const lit = m.selected == id;
        const lx = std.math.clamp(p[0] + 6, 8, @max(8, m.vp[0] - 110));
        const ly = std.math.clamp(p[1] - 22, 8, @max(8, m.vp[1] - 30));
        cb.pushOverlay(.{
            .x = m.vp_origin[0] + 1 + lx,
            .y = m.vp_origin[1] + 1 + ly,
            .padding = 4,
            .gap = 0,
            .backdrop = if (lit) blue else paper,
            .border = ink,
            .border_width = 1,
        });
        cb.textStyled(layers[id - 1].name, plex_small, if (lit) paper else ink);
        cb.popOverlay();
    }
}

fn sideColumn(m: *const Model, cb: anytype) void {
    const a = cb.arena.allocator();
    cb.pushGroup(.{ .width = 300, .padding = 12, .gap = 10, .bg = paper, .border = ink, .align_cross = .stretch });
    cb.heading("LAYERS");
    cb.pushGroup(.{ .padding = 1, .gap = 0, .border = ink, .align_cross = .stretch });
    for (layers) |l| {
        const row = std.fmt.allocPrint(a, "{s:<7}{s}", .{ l.kind, l.name }) catch l.name;
        cb.buttonStyled(.{ .select = l.id }, row, if (m.selected == l.id) row_button_on else row_button);
    }
    cb.popGroup();
    cb.pushGroup(cb.theme.card);
    cb.heading("INSPECTOR");
    cb.divider();
    if (layerById(m.selected)) |l| {
        prop(cb, "KIND", l.kind);
        prop(cb, "NAME", l.name);
        prop(cb, "ID", std.fmt.allocPrint(a, "{d}", .{l.id}) catch "");
        if (l.id <= 3) {
            prop(cb, "SIZE", "10'-0\" x 6'-8\"");
            prop(cb, "SIDES", "DOUBLE");
        } else if (l.id == 4) {
            prop(cb, "OPACITY", "85%");
        } else {
            prop(cb, "SIZE", "30 PX (SCREEN)");
        }
    } else {
        cb.textMuted("NOTHING SELECTED");
        cb.textMuted("CLICK A SHEET OR MARKER");
    }
    cb.popGroup();
    cb.spacer(1);
    cb.textMuted("DRAG ORBIT  SHIFT PAN  WHEEL ZOOM");
    cb.popGroup();
}

fn layerById(id: u32) ?Layer {
    for (layers) |l| if (l.id == id) return l;
    return null;
}

fn prop(cb: anytype, label: []const u8, value: []const u8) void {
    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 0, .justify = .space_between });
    cb.textMuted(label);
    cb.text(value);
    cb.popGroup();
}

fn statusBar(m: *const Model, cb: anytype) void {
    const a = cb.arena.allocator();
    cb.pushGroup(.{ .direction = .horizontal, .pad_x = 12, .pad_y = 0, .gap = 14, .height = 24, .bg = term_bg, .align_cross = .center });
    cb.textStyled("READY", plex_bold, term_fg);
    cb.textStyled("|", plex, term_fg);
    cb.textStyled("3 SHEETS  1 ANNOT  4 MARKERS", plex, term_fg);
    cb.textStyled("|", plex, term_fg);
    const sel = if (layerById(m.selected)) |l| l.name else "-";
    cb.textStyled(std.fmt.allocPrint(a, "SEL {s}", .{sel}) catch "", plex, term_fg);
    if (layerById(m.hovered)) |l| {
        cb.textStyled("|", plex, term_fg);
        cb.textStyled(std.fmt.allocPrint(a, "HOVER {s}", .{l.name}) catch "", plex, term_fg);
    }
    cb.spacer(1);
    const deg = 180.0 / std.math.pi;
    cb.textStyled(std.fmt.allocPrint(a, "YAW {d:.0}  PITCH {d:.0}", .{ m.cam.yaw * deg, m.cam.pitch * deg }) catch "", plex, term_fg);
    cb.popGroup();
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "structure mesh is valid and its edges are segment pairs" {
    try structure.data().validate();
    try testing.expectEqual(@as(usize, boxes.len * 12), structure.data().segmentCount());
}

test "marker images are white with a coverage alpha: ring is hollow, bubble solid" {
    const c = marker_px / 2;
    const at = struct {
        fn alpha(img: []const u8, x: usize, y: usize) u8 {
            return img[(y * marker_px + x) * 4 + 3];
        }
    }.alpha;
    try testing.expect(at(&ring_rgba, c, c) > 200); // the centre dot
    try testing.expectEqual(@as(u8, 0), at(&ring_rgba, c + 8, c)); // hollow between dot and ring
    try testing.expect(at(&ring_rgba, c + 17, c) > 200); // the ring itself
    try testing.expectEqual(@as(u8, 0), at(&ring_rgba, 0, 0)); // outside the circle
    try testing.expect(at(&bubble_rgba, c + 10, c + 10) > 200); // solid disc
    try testing.expectEqual(@as(u8, 255), bubble_rgba[0]); // white rgb
}

test "markers and sheets pick by screen position and ray; markers win over sheets" {
    var m: Model = .{};
    update(&m, .{ .view_event = .{ .id = scene_id, .kind = .layout, .x = 12, .y = 86, .w = 900, .h = 600 } });
    try testing.expectEqual([2]f32{ 12, 86 }, m.vp_origin);
    const cam = camera(&m);
    // click at the projected centre of each sheet
    for ([_]u32{ 1, 2, 3 }) |id| {
        const f = sheetFrame(id);
        const centre = scene.mat.add(f.origin, scene.mat.add(scene.mat.scale(f.u, sheet_size[0] / 2), scene.mat.scale(f.v, sheet_size[1] / 2)));
        const s = scene.project(cam, 900, 600, centre).?;
        const hit = m.pickAt(s[0], s[1], 900, 600);
        // a nearer layer (the annotation sheet or a marker) may cover the centre, never another sheet
        try testing.expect(hit == id or hit == 4 or hit >= 11);
    }
    // a marker's own pixel selects it, even where a sheet is behind it
    const mp = scene.project(cam, 900, 600, markerPos(12)).?;
    try testing.expectEqual(@as(u32, 12), m.pickAt(mp[0], mp[1], 900, 600));
    // empty space picks nothing
    try testing.expectEqual(@as(u32, 0), m.pickAt(2, 2, 900, 600));
}

test "click selects, a second click on the same row deselects, drag does not pick" {
    var m: Model = .{};
    update(&m, .{ .view_event = .{ .id = scene_id, .kind = .layout, .w = 900, .h = 600 } });
    const mp = scene.project(camera(&m), 900, 600, markerPos(11)).?;
    update(&m, .{ .view_event = .{ .id = scene_id, .kind = .down, .button = .left, .x = mp[0], .y = mp[1], .w = 900, .h = 600 } });
    update(&m, .{ .view_event = .{ .id = scene_id, .kind = .up, .button = .left, .x = mp[0], .y = mp[1], .w = 900, .h = 600 } });
    try testing.expectEqual(@as(u32, 11), m.selected);
    update(&m, .{ .select = 11 });
    try testing.expectEqual(@as(u32, 0), m.selected);
    // a drag past the slop orbits instead of picking
    const yaw = m.cam.yaw;
    update(&m, .{ .view_event = .{ .id = scene_id, .kind = .down, .button = .left, .x = mp[0], .y = mp[1], .w = 900, .h = 600 } });
    update(&m, .{ .view_event = .{ .id = scene_id, .kind = .move, .dx = 30, .buttons = .{ .left = true }, .w = 900, .h = 600 } });
    update(&m, .{ .view_event = .{ .id = scene_id, .kind = .up, .button = .left, .x = mp[0], .y = mp[1], .w = 900, .h = 600 } });
    try testing.expectEqual(@as(u32, 0), m.selected);
    try testing.expect(m.cam.yaw != yaw);
}

test "view: one viewport3d with sheets, annotation layer, sprites; selection raises the sheet's layer" {
    var m: Model = .{};
    m.selected = 2;
    var cb = teak.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();
    cb.theme = theme;
    view(&m, &cb);
    try testing.expect(teak.validateBalance(cb.cmds.items) == null);
    var scenes: usize = 0;
    for (cb.cmds.items) |c| switch (c) {
        .scene3d => |s| {
            scenes += 1;
            try testing.expectEqual(@as(usize, 4), s.view.planes.len); // 3 sheets + annotations
            try testing.expectEqual(@as(usize, 4), s.view.sprites.len);
            try testing.expectEqual(@as(i16, 1), s.view.planes[1].layer); // sheet 2 selected
            try testing.expectEqual(@as(i16, 0), s.view.planes[0].layer);
            try testing.expect(s.view.planes[0].content.len > 10);
            try testing.expect(s.view.grid != null);
        },
        else => {},
    };
    try testing.expectEqual(@as(usize, 1), scenes);
    update(&m, .toggle_annotations);
    cb.reset();
    cb.theme = theme;
    view(&m, &cb);
    for (cb.cmds.items) |c| switch (c) {
        .scene3d => |s| try testing.expectEqual(@as(usize, 3), s.view.planes.len),
        else => {},
    };
}
