//! Colour picker: a saturation / value square, a hue strip, a hex field,
//! R / G / B fields and a swatch palette. Zero new Cmd variants: the square
//! and the strip are interactive `canvas`es drawn from per-vertex-coloured
//! triangles (`CanvasPrimitive.triangles`), the fields are `text_input`s, the
//! swatches are flat-coloured `button`s.
//!
//! The Model keeps the colour as HSV (so dragging the hue strip does not
//! lose the saturation of a grey) plus the text of the four fields. Every
//! change keeps them in step: dragging or a swatch rewrites the texts; typing a
//! valid hex / channel value updates the colour (and the other fields, but
//! never the field being typed in, so editing is not fought).
//!
//! ```zig
//! const CP = teak.widgets.color_picker;
//! // Model: color: CP.Model = .{}      Msg: color: CP.Msg
//! // update: .color => |s| CP.update(&m.color, s),
//! // canvasMsg: if (CP.canvasMsg(&m.color, ev, opts)) |s| return .{ .color = s };
//! // view: CP.viewWith(&m.color, cb, .{ .focus = focusField, .swatch = swatchMsg }, opts);
//! // keys: CP.charMsg(field, c) / CP.keyMsg(field, key) -> CP.Msg, wrapped as .{ .color = ... }
//! // result: CP.rgb(&m.color) / CP.rgba(&m.color) ([4]f32)
//! ```

const std = @import("std");
const oom = @import("../oom.zig").oom;
const cmd = @import("../cmd.zig");
const text_field = @import("../text_field.zig");
const pointer = @import("../pointer.zig");
const keys = @import("../../input/keys.zig");

pub const Rgb = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,

    pub fn eql(a: Rgb, b: Rgb) bool {
        return a.r == b.r and a.g == b.g and a.b == b.b;
    }
};

pub const Hsv = struct {
    /// Degrees, 0 ..< 360.
    h: f32,
    s: f32,
    v: f32,
};

pub const Field = enum { hex, r, g, b };

const TF = text_field.TextField(8);

/// A 16-colour starter palette (the classic VGA set, softened).
pub const swatches = [16]Rgb{
    .{ .r = 0, .g = 0, .b = 0 },      .{ .r = 128, .g = 128, .b = 128 }, .{ .r = 192, .g = 192, .b = 192 }, .{ .r = 255, .g = 255, .b = 255 },
    .{ .r = 200, .g = 40, .b = 40 },  .{ .r = 240, .g = 120, .b = 40 },  .{ .r = 240, .g = 200, .b = 50 },  .{ .r = 120, .g = 200, .b = 60 },
    .{ .r = 40, .g = 160, .b = 90 },  .{ .r = 40, .g = 180, .b = 190 },  .{ .r = 50, .g = 120, .b = 230 },  .{ .r = 40, .g = 60, .b = 170 },
    .{ .r = 120, .g = 60, .b = 190 }, .{ .r = 200, .g = 70, .b = 190 },  .{ .r = 230, .g = 100, .b = 140 }, .{ .r = 130, .g = 85, .b = 50 },
};

// ── Colour maths (pure) ────────────────────────────────────────────

pub fn hsvToRgb(c: Hsv) Rgb {
    const h = @mod(c.h, 360) / 60;
    const s = std.math.clamp(c.s, 0, 1);
    const v = std.math.clamp(c.v, 0, 1);
    const i: u32 = @intFromFloat(@floor(h));
    const f = h - @floor(h);
    const p = v * (1 - s);
    const q = v * (1 - s * f);
    const t = v * (1 - s * (1 - f));
    const ch: [3]f32 = switch (i % 6) {
        0 => .{ v, t, p },
        1 => .{ q, v, p },
        2 => .{ p, v, t },
        3 => .{ p, q, v },
        4 => .{ t, p, v },
        else => .{ v, p, q },
    };
    return .{ .r = toByte(ch[0]), .g = toByte(ch[1]), .b = toByte(ch[2]) };
}

fn toByte(x: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(x, 0, 1) * 255));
}

pub fn rgbToHsv(c: Rgb) Hsv {
    const r = @as(f32, @floatFromInt(c.r)) / 255;
    const g = @as(f32, @floatFromInt(c.g)) / 255;
    const b = @as(f32, @floatFromInt(c.b)) / 255;
    const mx = @max(r, @max(g, b));
    const mn = @min(r, @min(g, b));
    const d = mx - mn;
    var h: f32 = 0;
    if (d > 0) {
        if (mx == r) {
            h = 60 * @mod((g - b) / d, 6);
        } else if (mx == g) {
            h = 60 * ((b - r) / d + 2);
        } else {
            h = 60 * ((r - g) / d + 4);
        }
    }
    return .{ .h = @mod(h, 360), .s = if (mx > 0) d / mx else 0, .v = mx };
}

/// Parse `#rgb`, `#rrggbb` (the `#` is optional, case-insensitive).
pub fn parseHex(text: []const u8) ?Rgb {
    const t = if (text.len > 0 and text[0] == '#') text[1..] else text;
    if (t.len != 3 and t.len != 6) return null;
    var v: [6]u8 = undefined;
    for (t, 0..) |ch, i| v[i] = std.fmt.charToDigit(ch, 16) catch return null;
    if (t.len == 3) return .{ .r = v[0] * 17, .g = v[1] * 17, .b = v[2] * 17 };
    return .{ .r = v[0] * 16 + v[1], .g = v[2] * 16 + v[3], .b = v[4] * 16 + v[5] };
}

/// `#RRGGBB` into `buf` (>= 7 bytes).
pub fn formatHex(c: Rgb, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "#{X:0>2}{X:0>2}{X:0>2}", .{ c.r, c.g, c.b }) catch "";
}

// ── Component ──────────────────────────────────────────────────────

pub const Target = enum { sv, hue };

pub const Model = struct {
    h: f32 = 210,
    s: f32 = 0.65,
    v: f32 = 0.9,
    /// Field texts, indexed by `Field`.
    texts: [4]TF.Model = .{ .{}, .{}, .{}, .{} },
    /// The strip / square being dragged.
    dragging: ?Target = null,
    /// Texts need a first fill (done by `update`/`init` so `.{}` is valid).
    ready: bool = false,
};

pub const Msg = union(enum) {
    /// Pointer on the square (`a` = saturation, `b` = value) or the strip
    /// (`a` = hue as a 0..1 fraction). `begin` marks a press; later events of
    /// the same drag follow while `Model.dragging` is set.
    drag: struct { target: Target, a: f32, b: f32 = 0, begin: bool = false },
    release,
    /// Choose swatch `i` of `swatches`.
    swatch: u8,
    /// Set the colour (e.g. restoring a saved one).
    set: Rgb,
    /// Edit one of the text fields.
    edit: struct { field: Field, msg: TF.Msg },
};

/// A model showing `c`.
pub fn init(c: Rgb) Model {
    var m: Model = .{};
    update(&m, .{ .set = c });
    return m;
}

pub fn rgb(model: *const Model) Rgb {
    return hsvToRgb(.{ .h = model.h, .s = model.s, .v = model.v });
}

/// The colour as an RGBA float colour (alpha 1).
pub fn rgba(model: *const Model) [4]f32 {
    const c = rgb(model);
    return .{ @as(f32, @floatFromInt(c.r)) / 255, @as(f32, @floatFromInt(c.g)) / 255, @as(f32, @floatFromInt(c.b)) / 255, 1 };
}

fn setFromRgb(model: *Model, c: Rgb) void {
    const hsv = rgbToHsv(c);
    // Greys carry no hue: keep the old one so the strip does not jump to red.
    if (hsv.s > 0 and hsv.v > 0) model.h = hsv.h;
    model.s = hsv.s;
    model.v = hsv.v;
}

/// Rewrite every field text except `skip` from the current colour.
fn syncTexts(model: *Model, skip: ?Field) void {
    const c = rgb(model);
    var buf: [16]u8 = undefined;
    if (skip != .hex) model.texts[@backingInt(Field.hex)].set(formatHex(c, &buf));
    const chans = [3]u8{ c.r, c.g, c.b };
    inline for (.{ Field.r, Field.g, Field.b }, 0..) |f, i| {
        if (skip != f) model.texts[@backingInt(f)].set(std.fmt.bufPrint(&buf, "{d}", .{chans[i]}) catch "");
    }
}

pub fn update(model: *Model, msg: Msg) void {
    if (!model.ready) {
        model.ready = true;
        syncTexts(model, null);
    }
    switch (msg) {
        .drag => |d| {
            if (d.begin) model.dragging = d.target;
            if (model.dragging != d.target) return;
            switch (d.target) {
                .sv => {
                    model.s = std.math.clamp(d.a, 0, 1);
                    model.v = std.math.clamp(d.b, 0, 1);
                },
                .hue => model.h = std.math.clamp(d.a, 0, 1) * 359.999,
            }
            syncTexts(model, null);
        },
        .release => model.dragging = null,
        .swatch => |i| if (i < swatches.len) {
            setFromRgb(model, swatches[i]);
            syncTexts(model, null);
        },
        .set => |c| {
            setFromRgb(model, c);
            syncTexts(model, null);
        },
        .edit => |e| {
            const t = &model.texts[@backingInt(e.field)];
            TF.update(t, e.msg);
            const parsed: ?Rgb = switch (e.field) {
                .hex => parseHex(t.content()),
                else => blk: {
                    const n = std.fmt.parseInt(u16, t.content(), 10) catch break :blk null;
                    if (n > 255) break :blk null;
                    var c = rgb(model);
                    switch (e.field) {
                        .r => c.r = @intCast(n),
                        .g => c.g = @intCast(n),
                        .b => c.b = @intCast(n),
                        .hex => unreachable,
                    }
                    break :blk c;
                },
            };
            if (parsed) |c| {
                setFromRgb(model, c);
                syncTexts(model, e.field); // never rewrite the field being typed in
            }
        },
    }
}

/// True when the text of `field` currently parses (draw it as invalid otherwise).
pub fn fieldValid(model: *const Model, field: Field) bool {
    const t = model.texts[@backingInt(field)].content();
    return switch (field) {
        .hex => parseHex(t) != null,
        else => if (std.fmt.parseInt(u16, t, 10)) |n| n <= 255 else |_| false,
    };
}

pub fn fieldText(model: *const Model, field: Field) []const u8 {
    return model.texts[@backingInt(field)].content();
}

// ── Pointer + keys ─────────────────────────────────────────────────

pub const Opts = struct {
    /// Square size.
    sv_w: f32 = 200,
    sv_h: f32 = 160,
    /// Strip thickness (the strip is `sv_w` wide).
    hue_h: f32 = 16,
    /// `CanvasCmd.id`s of the square and strip.
    sv_id: u32 = 0xC1,
    hue_id: u32 = 0xC2,
};

/// Map a pointer event on the square or strip to a `Msg` (null for others).
pub fn canvasMsg(model: *const Model, ev: pointer.CanvasEvent, o: Opts) ?Msg {
    const target: Target = if (ev.id == o.sv_id) .sv else if (ev.id == o.hue_id) .hue else return null;
    const w = if (ev.w > 0) ev.w else if (target == .sv) o.sv_w else o.sv_w;
    const h = if (ev.h > 0) ev.h else if (target == .sv) o.sv_h else o.hue_h;
    switch (ev.kind) {
        .down => {
            if (ev.button != .left) return null;
            return pick(target, ev, w, h, true);
        },
        .move => {
            if (model.dragging != target) return null;
            return pick(target, ev, w, h, false);
        },
        .up => return if (ev.button == .left) .release else null,
        .leave, .wheel, .layout, .key => return null,
    }
}

fn pick(target: Target, ev: pointer.CanvasEvent, w: f32, h: f32, begin: bool) Msg {
    return switch (target) {
        .sv => .{ .drag = .{ .target = .sv, .a = ev.x / w, .b = 1 - ev.y / h, .begin = begin } },
        .hue => .{ .drag = .{ .target = .hue, .a = ev.x / w, .begin = begin } },
    };
}

pub fn charMsg(field: Field, c: u8) Msg {
    return .{ .edit = .{ .field = field, .msg = .{ .char = c } } };
}

/// The Msg for a special key typed into `field` (null when it maps to none).
pub fn keyMsg(field: Field, key: keys.SpecialKey) ?Msg {
    const W = union(enum) { m: TF.Msg };
    const wrapped = text_field.textFieldSpecial(W, "m", key) orelse return null;
    return .{ .edit = .{ .field = field, .msg = wrapped.m } };
}

pub fn pasteMsg(field: Field, bytes: []const u8) Msg {
    return .{ .edit = .{ .field = field, .msg = .{ .replace_selection = bytes } } };
}

// ── View ───────────────────────────────────────────────────────────

const TV = cmd.CanvasPrimitive.TriVertex;

fn vtx(x: f32, y: f32, c: [3]f32, a: f32) TV {
    return .{ .x = x, .y = y, .r = c[0], .g = c[1], .b = c[2], .a = a };
}

fn rgbF(c: Rgb) [3]f32 {
    return .{ @as(f32, @floatFromInt(c.r)) / 255, @as(f32, @floatFromInt(c.g)) / 255, @as(f32, @floatFromInt(c.b)) / 255 };
}

/// The square: white -> pure hue left to right, then a transparent -> black
/// overlay top to bottom.
fn svPrimitives(cb: anytype, model: *const Model, o: Opts) []const cmd.CanvasPrimitive {
    const a = cb.arena.allocator();
    const hue = rgbF(hsvToRgb(.{ .h = model.h, .s = 1, .v = 1 }));
    const w = o.sv_w;
    const h = o.sv_h;
    const white: [3]f32 = .{ 1, 1, 1 };
    const black: [3]f32 = .{ 0, 0, 0 };
    const tris = a.alloc(TV, 12) catch return &.{};
    // base: white -> hue
    tris[0] = vtx(0, 0, white, 1);
    tris[1] = vtx(w, 0, hue, 1);
    tris[2] = vtx(0, h, white, 1);
    tris[3] = vtx(w, 0, hue, 1);
    tris[4] = vtx(w, h, hue, 1);
    tris[5] = vtx(0, h, white, 1);
    // overlay: transparent -> black
    tris[6] = vtx(0, 0, black, 0);
    tris[7] = vtx(w, 0, black, 0);
    tris[8] = vtx(0, h, black, 1);
    tris[9] = vtx(w, 0, black, 0);
    tris[10] = vtx(w, h, black, 1);
    tris[11] = vtx(0, h, black, 1);

    const prims = a.alloc(cmd.CanvasPrimitive, 5) catch return &.{};
    prims[0] = .{ .triangles = .{ .verts = tris, .key = 1000 + @as(u64, @intFromFloat(model.h * 10)) } };
    // marker: a black square ring with a white one inside it
    const mx = model.s * w;
    const my = (1 - model.v) * h;
    prims[1] = .{ .filled_rect = .{ .x = mx - 6, .y = my - 6, .w = 12, .h = 12, .color = .{ 0, 0, 0, 1 } } };
    prims[2] = .{ .filled_rect = .{ .x = mx - 5, .y = my - 5, .w = 10, .h = 10, .color = .{ 1, 1, 1, 1 } } };
    const c = rgba(model);
    prims[3] = .{ .filled_rect = .{ .x = mx - 4, .y = my - 4, .w = 8, .h = 8, .color = .{ 0, 0, 0, 1 } } };
    prims[4] = .{ .filled_rect = .{ .x = mx - 3, .y = my - 3, .w = 6, .h = 6, .color = c } };
    return prims;
}

fn huePrimitives(cb: anytype, model: *const Model, o: Opts) []const cmd.CanvasPrimitive {
    const a = cb.arena.allocator();
    const stops = [7]Rgb{
        .{ .r = 255, .g = 0, .b = 0 },
        .{ .r = 255, .g = 255, .b = 0 },
        .{ .r = 0, .g = 255, .b = 0 },
        .{ .r = 0, .g = 255, .b = 255 },
        .{ .r = 0, .g = 0, .b = 255 },
        .{ .r = 255, .g = 0, .b = 255 },
        .{ .r = 255, .g = 0, .b = 0 },
    };
    const seg = o.sv_w / 6;
    const tris = a.alloc(TV, 36) catch return &.{};
    for (0..6) |i| {
        const x0 = seg * @as(f32, @floatFromInt(i));
        const x1 = x0 + seg;
        const c0 = rgbF(stops[i]);
        const c1 = rgbF(stops[i + 1]);
        const t = tris[i * 6 ..][0..6];
        t[0] = vtx(x0, 0, c0, 1);
        t[1] = vtx(x1, 0, c1, 1);
        t[2] = vtx(x0, o.hue_h, c0, 1);
        t[3] = vtx(x1, 0, c1, 1);
        t[4] = vtx(x1, o.hue_h, c1, 1);
        t[5] = vtx(x0, o.hue_h, c0, 1);
    }
    const prims = a.alloc(cmd.CanvasPrimitive, 3) catch return &.{};
    prims[0] = .{ .triangles = .{ .verts = tris, .key = 1 } };
    const x = model.h / 360 * o.sv_w;
    prims[1] = .{ .filled_rect = .{ .x = x - 3, .y = 0, .w = 6, .h = o.hue_h, .color = .{ 0, 0, 0, 1 } } };
    prims[2] = .{ .filled_rect = .{ .x = x - 2, .y = 1, .w = 4, .h = o.hue_h - 2, .color = .{ 1, 1, 1, 1 } } };
    return prims;
}

/// The whole picker. `msgs.focus(field)` and `msgs.swatch(i)` are comptime
/// fns building the app's Msgs (the focus Msg of a field's `text_input`, and
/// the swatch click). Interactive canvases need the app's `canvasMsg` hook.
pub fn viewWith(model: *const Model, cb: anytype, msgs: anytype, o: Opts) void {
    const pal = cb.theme.palette;
    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 14, .align_cross = .start });

    // Left: square + strip.
    cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 8 });
    cb.canvasInteractive(.{ .width = o.sv_w, .height = o.sv_h }, svPrimitives(cb, model, o), o.sv_id, "saturation and value");
    cb.canvasInteractive(.{ .width = o.sv_w, .height = o.hue_h }, huePrimitives(cb, model, o), o.hue_id, "hue");
    cb.popGroup();

    // Right: preview, fields, swatches.
    cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 6 });
    const cur = rgba(model);
    const prev = cb.arena.allocator().alloc(cmd.CanvasPrimitive, 2) catch oom();
    prev[0] = .{ .filled_rect = .{ .x = 0, .y = 0, .w = 96, .h = 36, .color = pal.border } };
    prev[1] = .{ .filled_rect = .{ .x = 1, .y = 1, .w = 94, .h = 34, .color = cur } };
    cb.canvasLabeled(.{ .width = 96, .height = 36 }, prev, "current colour");

    var st = cb.theme.text_input;
    st.flex = 0;
    st.min_width = 96;
    inline for (.{ Field.hex, Field.r, Field.g, Field.b }) |f| {
        var s = st;
        if (!fieldValid(model, f)) s.border = pal.danger;
        if (f != .hex) s.min_width = 96;
        cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 8, .align_cross = .center });
        cb.textMuted(switch (f) {
            .hex => "Hex",
            .r => "R  ",
            .g => "G  ",
            .b => "B  ",
        });
        const t = &model.texts[@backingInt(f)];
        cb.textInputSelected(msgs.focus(f), t.content(), t.cursor, t.selection_anchor, s);
        cb.popGroup();
    }

    // Swatches: 8 x 2 flat buttons.
    var i: usize = 0;
    while (i < swatches.len) : (i += 8) {
        cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 2 });
        for (swatches[i .. i + 8], i..) |sw, k| {
            const col: [4]f32 = .{ rgbF(sw)[0], rgbF(sw)[1], rgbF(sw)[2], 1 };
            var b = cb.theme.button;
            b.min_width = 22;
            b.height = 22;
            b.h_padding = 0;
            b.bg = col;
            b.hover_bg = col;
            b.press_bg = col;
            b.border = if (rgb(model).eql(sw)) pal.accent else pal.border;
            b.border_width = if (rgb(model).eql(sw)) 2 else 1;
            cb.buttonStyled(msgs.swatch(k), "", b);
        }
        cb.popGroup();
    }
    cb.popGroup();

    cb.popGroup();
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;
const component = @import("../component.zig");
const snapshot = @import("../snapshot.zig");
const engine = @import("../../layout/engine.zig");
const text_mod = @import("../text.zig");

fn expectRgb(want: Rgb, got: Rgb) !void {
    try testing.expectEqual(want, got);
}








