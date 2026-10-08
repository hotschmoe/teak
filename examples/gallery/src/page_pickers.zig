//! Page 6: pickers - colour picker, number spinners.

const std = @import("std");
const teak = @import("teak");
const model = @import("model.zig");
const ui = @import("ui.zig");

const Model = model.Model;
const Msg = model.Msg;
const W = teak.widgets;

pub const color_opts: W.color_picker.Opts = .{};

fn colorFocus(f: W.color_picker.Field) Msg {
    return .{ .focus_set = switch (f) {
        .hex => .color_hex,
        .r => .color_r,
        .g => .color_g,
        .b => .color_b,
    } };
}

fn colorSwatch(i: usize) Msg {
    return .{ .color = .{ .swatch = @intCast(i) } };
}

pub fn view(m: *const Model, cb: anytype) void {
    const pal = cb.theme.palette;
    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 14, .align_cross = .start });

    cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 14, .width = 460, .align_cross = .stretch });
    ui.card(cb, "Colour picker", 0, 0);
    W.color_picker.viewWith(&m.color, cb, .{ .focus = colorFocus, .swatch = colorSwatch }, color_opts);
    const c = W.color_picker.rgb(&m.color);
    cb.textMuted(ui.fmt(cb, "rgb({d}, {d}, {d})", .{ c.r, c.g, c.b }));
    ui.endCard(cb);
    cb.popGroup();

    cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 14, .width = 300, .align_cross = .stretch });
    ui.card(cb, "Number spinner", 0, 0);
    cb.textMuted("Type, arrows, PgUp / PgDn, wheel.");
    model.Spin.viewWith(&m.spin, cb, .{ .focus = Msg{ .focus_set = .spin }, .up = Msg{ .spin_step = .up }, .down = Msg{ .spin_step = .down } });
    cb.text(ui.fmt(cb, "value: {d:.0}", .{model.Spin.value(&m.spin) orelse 0}));
    cb.divider();
    cb.textMuted("Fractional (step 0.05):");
    model.Spin2.viewWith(&m.spin2, cb, .{ .focus = Msg{ .focus_set = .spin2 }, .up = Msg{ .spin2_step = .up }, .down = Msg{ .spin2_step = .down } });
    ui.endCard(cb);
    _ = pal;
    cb.popGroup();

    cb.popGroup();
}
