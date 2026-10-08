//! The gallery's looks. Retro is the chrome example's ink-on-paper palette
//! (square, bordered, inverting on hover); Dark and Light are the stock
//! presets with a slightly tightened button. Switching is one Msg: the
//! runtime reads `themeFor` every frame and the clear colour follows
//! `palette.bg`.

const std = @import("std");
const teak = @import("teak");

pub const Look = enum { retro, dark, light };

pub const ink: [4]f32 = .{ 0.10, 0.09, 0.08, 1 };
pub const paper: [4]f32 = .{ 0.93, 0.91, 0.84, 1 };
pub const paper_light: [4]f32 = .{ 0.96, 0.94, 0.88, 1 };
pub const paper_dark: [4]f32 = .{ 0.87, 0.84, 0.75, 1 };
pub const muted: [4]f32 = .{ 0.42, 0.40, 0.35, 1 };
pub const red: [4]f32 = .{ 0.72, 0.17, 0.10, 1 };

const plex: teak.FontSpec = .{ .size_px = 13, .family = .mono };
const plex_bold: teak.FontSpec = .{ .size_px = 13, .family = .mono, .weight = .bold, .letter_spacing = 1 };

const retro_palette: teak.theme.Palette = .{
    .bg = paper,
    .bg_panel = paper_light,
    .bg_sunken = paper_light,
    .bg_raised = paper,
    .bg_hover = ink,
    .bg_press = ink,
    .fg = ink,
    .fg_muted = muted,
    .accent = red,
    .danger = red,
    .border = ink,
};

fn retro() teak.Theme {
    var t = teak.Theme.fromPalette(retro_palette);
    t.typography = .{ .body = plex, .mono = plex, .small = plex, .heading = plex_bold };
    t.button = .{
        .bg = paper,
        .hover_bg = ink,
        .press_bg = ink,
        .fg = ink,
        .hover_fg = paper,
        .press_fg = paper,
        .press_offset_y = 1,
        .border = ink,
        .label_align = .center,
        .height = 26,
        .min_width = 0,
        .h_padding = 12,
        .disabled_bg = paper_dark,
        .disabled_fg = muted,
    };
    t.text_input = .{
        .bg = paper_light,
        .fg = ink,
        .border = ink,
        .focus_border = red,
        .cursor = ink,
        .border_width = 1,
        .selection_bg = .{ 0.10, 0.09, 0.08, 0.25 },
        .disabled_bg = paper_dark,
        .disabled_fg = muted,
        .disabled_border = muted,
        .height = 26,
        .flex = 0,
        .min_width = 160,
    };
    t.field = .{
        .variant = .underline,
        .fg = ink,
        .border = ink,
        .focus_border = red,
        .cursor = red,
        .selection_bg = .{ 0.72, 0.17, 0.10, 0.25 },
        .height = 26,
        .flex = 0,
    };
    t.card = .{ .padding = 10, .gap = 6, .bg = paper_light, .border = ink, .align_cross = .stretch };
    t.divider = .{ .thickness = 1, .color = ink };
    t.checkbox.box_bg = paper_light;
    t.checkbox.check = red;
    t.radio.box_bg = paper_light;
    t.radio.dot = red;
    t.slider.track_bg = paper_dark;
    t.slider.track_fill = ink;
    t.slider.thumb = red;
    return t;
}

/// Compact variants of the stock presets (the stock button is 36 px tall).
fn stock(base: teak.Theme) teak.Theme {
    var t = base;
    t.button.height = 28;
    t.button.min_width = 0;
    t.button.h_padding = 12;
    t.button.label_align = .center;
    t.button.border = base.palette.border;
    t.text_input.height = 28;
    t.text_input.flex = 0;
    t.text_input.min_width = 160;
    t.card = .{ .padding = 12, .gap = 8, .bg = base.palette.bg_panel, .border = base.palette.border, .align_cross = .stretch };
    return t;
}

pub fn themeOf(look: Look) teak.Theme {
    return switch (look) {
        .retro => retro(),
        .dark => stock(teak.Theme.dark_default),
        .light => stock(teak.Theme.light_default),
    };
}
