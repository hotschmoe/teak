//! Theme: bundled style + typography defaults consulted by un-styled
//! convenience emitters.
//!
//! HARDLINE-wise this lives at the same layer as `TransientState` /
//! `TextMeasurer` — a piece of presentation context that the view layer
//! can read but that does NOT participate in state transitions. The
//! framework reads it through `CmdBuffer.theme`; `view` never takes it
//! as a parameter (signature stability per §1).
//!
//! Threading rule: an app picks (or builds) a Theme and assigns it to
//! `cb.theme` before the per-frame `view()` call. Components emitting
//! `cb.button(msg, label)` (no explicit style) pick up the theme's
//! `button` style; `cb.buttonStyled(msg, label, custom)` still wins.

const std = @import("std");
const cmd = @import("cmd.zig");
const text = @import("text.zig");

const FontSpec = text.FontSpec;
const FontFamily = text.FontFamily;

// ── Palette ────────────────────────────────────────────────────────
//
// A small token vocabulary the per-widget styles compose against.
// Apps that want a brand color set rebuild a Theme using these tokens
// as a starting point; widget styles are derived from the palette
// rather than hand-tuned per widget (preserving family resemblance
// when switching dark/light).

pub const Palette = struct {
    /// Window / panel background.
    bg: [4]f32,
    /// Sunken bg used for inputs, scroll wells.
    bg_sunken: [4]f32,
    /// Raised bg used for buttons and the "card" surface.
    bg_raised: [4]f32,
    /// One step brighter than bg_raised — hover.
    bg_hover: [4]f32,
    /// One step darker than bg_raised — press.
    bg_press: [4]f32,
    /// Primary text color.
    fg: [4]f32,
    /// Dimmer text (placeholders, units, secondary labels).
    fg_muted: [4]f32,
    /// Accent (focus rings, selected backgrounds, slider fill).
    accent: [4]f32,
    /// Error / validation text.
    danger: [4]f32,
    /// Subtle border / divider color.
    border: [4]f32,
};

// ── Typography ─────────────────────────────────────────────────────

pub const Typography = struct {
    /// Body text default. Used by `cb.text(...)` when no per-cmd font.
    body: FontSpec = .{ .size_px = 14, .family = .sans },
    /// Heading. Apps emit via the `headingFont` helper or `cb.heading(...)`.
    heading: FontSpec = .{ .size_px = 18, .family = .sans },
    /// Monospace for numerics, code, columnar data.
    mono: FontSpec = .{ .size_px = 14, .family = .mono },
    /// Small / caption — units suffixes, validation messages.
    small: FontSpec = .{ .size_px = 12, .family = .sans },
};

// ── Theme ──────────────────────────────────────────────────────────

pub const Theme = struct {
    palette: Palette,
    typography: Typography,

    /// Color used by `cb.text(...)` when no per-cmd color override.
    text_color: [4]f32,
    /// Color used by `cb.heading(...)`.
    heading_color: [4]f32,
    /// Color used by `cb.textMuted(...)`.
    muted_color: [4]f32,
    /// Color used by `cb.textDanger(...)`.
    danger_color: [4]f32,

    button: cmd.ButtonStyle,
    text_input: cmd.TextInputStyle,
    checkbox: cmd.CheckboxStyle,
    radio: cmd.RadioStyle,
    slider: cmd.SliderStyle,
    divider: cmd.DividerStyle,

    /// Apps that want a non-default starting point can branch from
    /// these and override specific fields.
    pub const dark_default: Theme = fromPalette(dark_palette);
    pub const light_default: Theme = fromPalette(light_palette);

    /// Build a Theme by deriving widget styles from a palette. Apps
    /// that want a custom brand palette call this and then optionally
    /// tweak individual style fields.
    pub fn fromPalette(p: Palette) Theme {
        return .{
            .palette = p,
            .typography = .{},
            .text_color = p.fg,
            .heading_color = p.fg,
            .muted_color = p.fg_muted,
            .danger_color = p.danger,
            .button = .{
                .bg = p.bg_raised,
                .hover_bg = p.bg_hover,
                .press_bg = p.bg_press,
                .fg = p.fg,
                .corner_radius = 4,
            },
            .text_input = .{
                .bg = p.bg_sunken,
                .fg = p.fg,
                .border = p.border,
                .focus_border = p.accent,
                .cursor = p.fg,
                .corner_radius = 4,
                .flex = 1,
                .min_width = 120,
            },
            .checkbox = .{
                .box_bg = p.bg_sunken,
                .box_border = p.border,
                .check = p.accent,
                .fg = p.fg,
                .size = 18,
                .label_gap = 8,
            },
            .radio = .{
                .box_bg = p.bg_sunken,
                .box_border = p.border,
                .dot = p.accent,
                .fg = p.fg,
                .size = 18,
                .label_gap = 8,
            },
            .slider = .{
                .track_bg = p.bg_sunken,
                .track_fill = p.accent,
                .thumb = p.fg,
                .track_height = 6,
                .thumb_size = 16,
                .flex = 1,
                .min_width = 120,
            },
            .divider = .{
                .thickness = 1,
                .color = p.border,
            },
        };
    }
};

// ── Built-in palettes ──────────────────────────────────────────────

pub const dark_palette: Palette = .{
    .bg = .{ 0.08, 0.08, 0.10, 1.0 },
    .bg_sunken = .{ 0.12, 0.12, 0.14, 1.0 },
    .bg_raised = .{ 0.25, 0.25, 0.28, 1.0 },
    .bg_hover = .{ 0.35, 0.35, 0.40, 1.0 },
    .bg_press = .{ 0.15, 0.15, 0.18, 1.0 },
    .fg = .{ 0.92, 0.92, 0.94, 1.0 },
    .fg_muted = .{ 0.62, 0.62, 0.68, 1.0 },
    .accent = .{ 0.30, 0.55, 1.00, 1.0 },
    .danger = .{ 0.95, 0.45, 0.40, 1.0 },
    .border = .{ 0.35, 0.35, 0.40, 1.0 },
};

pub const light_palette: Palette = .{
    .bg = .{ 0.96, 0.96, 0.97, 1.0 },
    .bg_sunken = .{ 1.00, 1.00, 1.00, 1.0 },
    .bg_raised = .{ 0.88, 0.88, 0.92, 1.0 },
    .bg_hover = .{ 0.82, 0.82, 0.88, 1.0 },
    .bg_press = .{ 0.74, 0.74, 0.80, 1.0 },
    .fg = .{ 0.10, 0.10, 0.12, 1.0 },
    .fg_muted = .{ 0.42, 0.42, 0.48, 1.0 },
    .accent = .{ 0.18, 0.45, 0.95, 1.0 },
    .danger = .{ 0.85, 0.25, 0.20, 1.0 },
    .border = .{ 0.72, 0.72, 0.78, 1.0 },
};

// ── Tests ──────────────────────────────────────────────────────────

test "Theme.dark_default derives button bg from palette" {
    const t = Theme.dark_default;
    try std.testing.expectEqual(dark_palette.bg_raised, t.button.bg);
    try std.testing.expectEqual(dark_palette.bg_hover, t.button.hover_bg);
    try std.testing.expectEqual(dark_palette.bg_press, t.button.press_bg);
    try std.testing.expectEqual(dark_palette.fg, t.button.fg);
}

test "Theme.light_default has light bg" {
    const t = Theme.light_default;
    // Light bg means R+G+B should be > 2 (i.e. brighter than dark's ~0.24).
    const sum = t.palette.bg[0] + t.palette.bg[1] + t.palette.bg[2];
    try std.testing.expect(sum > 2.0);
}

test "Theme.fromPalette: custom accent flows into slider track_fill + input focus_border" {
    var p = dark_palette;
    p.accent = .{ 1.0, 0.5, 0.0, 1.0 }; // bright orange
    const t = Theme.fromPalette(p);
    try std.testing.expectEqual(@as([4]f32, .{ 1.0, 0.5, 0.0, 1.0 }), t.slider.track_fill);
    try std.testing.expectEqual(@as([4]f32, .{ 1.0, 0.5, 0.0, 1.0 }), t.text_input.focus_border);
    try std.testing.expectEqual(@as([4]f32, .{ 1.0, 0.5, 0.0, 1.0 }), t.checkbox.check);
    try std.testing.expectEqual(@as([4]f32, .{ 1.0, 0.5, 0.0, 1.0 }), t.radio.dot);
}

test "Theme.typography has body, heading, mono, small" {
    const t = Theme.dark_default;
    try std.testing.expectEqual(FontFamily.sans, t.typography.body.family);
    try std.testing.expectEqual(FontFamily.sans, t.typography.heading.family);
    try std.testing.expectEqual(FontFamily.mono, t.typography.mono.family);
    try std.testing.expectEqual(FontFamily.sans, t.typography.small.family);
    try std.testing.expect(t.typography.heading.size_px > t.typography.body.size_px);
    try std.testing.expect(t.typography.small.size_px < t.typography.body.size_px);
}
