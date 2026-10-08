//! Page 6: pickers - colour picker, number spinners.

const std = @import("std");
const teak = @import("teak");
const model = @import("model.zig");
const ui = @import("ui.zig");

const Model = model.Model;
const Msg = model.Msg;
const W = teak.widgets;

pub const color_opts: W.color_picker.Opts = .{};

fn datePick(d: W.date.Date) Msg {
    return .{ .date = .{ .pick = d } };
}
fn dateGo(n: W.date_field.Nav) Msg {
    return .{ .date = .{ .go = n } };
}

/// The date field is the first widget of the first card in the second column,
/// so its position follows from fixed sizes (see `ui.cardBodyY`).
fn dateOpts(m: *const Model, cb: anytype) W.date_field.ViewOpts {
    return .{
        .list_x = ui.content_x + 460 + 14 + ui.card_pad,
        .list_y = ui.cardBodyY(ui.content_y) + cb.theme.text_input.height + 2,
        .window_w = m.win_w,
        .window_h = m.win_h,
    };
}

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
    ui.card(cb, "Date field", 0, 0);
    W.date_field.viewWith(&m.date, cb, .{
        .focus = Msg{ .focus_set = .date },
        .toggle = Msg{ .date = .toggle },
        .close = Msg{ .date = .close },
        .today = Msg{ .date = .today },
        .clear = Msg{ .date = .clear },
        .pickMsg = datePick,
        .goMsg = dateGo,
    }, dateOpts(m, cb));
    cb.textMuted(if (m.date.selected) |d| ui.fmt(cb, "{s}, day {d} of the year", .{ W.date.month_names[d.month - 1], W.date.toDays(d) - W.date.toDays(.{ .year = d.year, .month = 1, .day = 1 }) + 1 }) else "type YYYY-MM-DD or pick");
    cb.textMuted(if (m.date.today != null) "today: from a clock effect" else "today: unknown (no clock result yet)");
    ui.endCard(cb);

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
