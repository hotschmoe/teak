//! Page 1: the basic controls - buttons, selection, switches, sliders, text styles.

const std = @import("std");
const teak = @import("teak");
const model = @import("model.zig");
const ui = @import("ui.zig");

const Model = model.Model;
const Msg = model.Msg;
const W = teak.widgets;

pub fn view(m: *const Model, cb: anytype) void {
    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 14, .align_cross = .start });

    // Column 1
    cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 14, .width = 330, .align_cross = .stretch });
    ui.card(cb, "Buttons", 0, 0);
    ui.row(cb);
    cb.button(.clicked, "Click me");
    cb.buttonDisabled(.clicked, "Disabled");
    var danger = cb.theme.button;
    danger.border = cb.theme.palette.danger;
    danger.fg = cb.theme.palette.danger;
    cb.buttonStyled(.clicked, "Danger", danger);
    ui.endRow(cb);
    cb.textMuted(ui.fmt(cb, "clicked {d} times", .{m.clicks}));
    ui.endCard(cb);

    ui.card(cb, "Checkbox & radio", 0, 0);
    cb.checkbox(.check_a, m.check_a, "Enable notifications");
    cb.checkbox(.check_b, m.check_b, "Remember me");
    cb.divider();
    cb.radio(.{ .radio = 0 }, m.radio == 0, "Small");
    cb.radio(.{ .radio = 1 }, m.radio == 1, "Medium");
    cb.radio(.{ .radio = 2 }, m.radio == 2, "Large");
    ui.endCard(cb);
    cb.popGroup();

    // Column 2
    cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 14, .width = 330, .align_cross = .stretch });
    ui.card(cb, "Toggle switch", 0, 0);
    W.toggle.view(cb, Msg{ .toggle_wifi = {} }, m.wifi, "Wi-Fi");
    W.toggle.view(cb, Msg{ .toggle_sound = {} }, m.sound, "Sound");
    W.toggle.view(cb, Msg{ .toggle_dark_hint = {} }, m.dark_hint, "Dark hint");
    ui.endCard(cb);

    ui.card(cb, "Sliders", 0, 0);
    ui.row(cb);
    cb.text("Volume");
    cb.spacer(1);
    cb.textMuted(ui.fmt(cb, "{d:.0}%", .{m.volume * 100}));
    ui.endRow(cb);
    cb.slider(.{ .slider_grab = .volume }, m.volume);
    ui.row(cb);
    cb.text("Mix");
    cb.spacer(1);
    cb.textMuted(ui.fmt(cb, "{d:.0}%", .{m.mix * 100}));
    ui.endRow(cb);
    cb.slider(.{ .slider_grab = .mix }, m.mix);
    ui.endCard(cb);
    cb.popGroup();

    // Column 3
    cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 14, .width = 370, .align_cross = .stretch });
    ui.card(cb, "Text styles", 0, 0);
    cb.heading("Heading");
    cb.text("Body text");
    cb.textMuted("Muted text");
    cb.textDanger("Danger text");
    cb.textMono("Mono text 0123456789");
    cb.divider();
    cb.richTextStyled(.{ .content = rich_text, .spans = richSpans(cb), .default_color = cb.theme.palette.fg, .default_font = cb.theme.typography.body });
    ui.endCard(cb);

    ui.card(cb, "Divider & disabled input", 0, 0);
    cb.textInputDisabled(.focus_clear, "read-only value", 0);
    ui.endCard(cb);
    cb.popGroup();

    cb.popGroup();
}

const rich_text = "Rich text mixes bold, red and mono spans.";

fn at(needle: []const u8) u32 {
    return @intCast(std.mem.indexOf(u8, rich_text, needle).?);
}

fn richSpans(cb: anytype) []const teak.RichTextSpan {
    const pal = cb.theme.palette;
    const body = cb.theme.typography.body;
    var bold = body;
    bold.weight = .bold;
    var mono = body;
    mono.family = .mono;
    const spans = cb.arena.allocator().alloc(teak.RichTextSpan, 3) catch return &.{};
    spans[0] = .{ .start = at("bold"), .end = at("bold") + 4, .color = pal.fg, .font = bold, .bold = true, .italic = false };
    spans[1] = .{ .start = at("red"), .end = at("red") + 3, .color = .{ 0.82, 0.25, 0.18, 1 }, .font = body, .bold = false, .italic = false };
    spans[2] = .{ .start = at("mono"), .end = at("mono") + 4, .color = .{ 0.2, 0.5, 0.85, 1 }, .font = mono, .bold = false, .italic = false };
    return spans;
}
