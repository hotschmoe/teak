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
const FontWeight = text.FontWeight;

pub const Palette = struct {
    /// Window / scene background — what the empty window draws as.
    bg: [4]f32,
    /// Elevated panel / card surface. Slightly distinct from `bg` so a
    /// modal card or section panel reads as a separate layer. Consumed
    /// by `GroupStyle.bg` to paint readable card backgrounds over a dim
    /// overlay scrim (the help-modal idiom).
    bg_panel: [4]f32,
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
    /// Non-fatal warning / caution text (amber). Defaulted so palettes
    /// written before it existed still compile; every built-in sets it.
    warning: [4]f32 = .{ 0.92, 0.66, 0.20, 1.0 },
};

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

/// Shape and depth vocabulary next to the palette's colours: corner radii,
/// stroke width, a spacing scale and shadow elevations. The retro look is
/// the default (square corners, no soft shadows); `modern_tokens` is the
/// rounded, softly-lit one. Widget styles derived by `fromPaletteTokens`
/// read these, and apps can read them too (`theme.tokens.space[2]`) to keep
/// custom layouts on the same scale.
pub const Tokens = struct {
    /// Corner radii: small (inputs, checkboxes), medium (buttons), large (cards, popovers).
    radius_sm: f32 = 0,
    radius_md: f32 = 0,
    radius_lg: f32 = 0,
    /// Stroke width of borders and rules.
    border_width: f32 = 1,
    /// Thickness of the keyboard focus ring drawn around the navigated widget
    /// (colour: `Palette.accent`). Same value in the retro and modern looks.
    focus_ring_width: f32 = 2,
    /// Spacing scale for padding and gaps: xs, sm, md, lg, xl.
    space: [5]f32 = .{ 4, 8, 12, 16, 24 },
    /// Elevation steps 0..3 as soft shadows (step 0 and a retro theme: none).
    elevation: [4]?cmd.Shadow = .{ null, null, null, null },

    pub const Size = enum { sm, md, lg };

    pub fn radii(self: Tokens, size: Size) cmd.Radii {
        return cmd.Radii.all(switch (size) {
            .sm => self.radius_sm,
            .md => self.radius_md,
            .lg => self.radius_lg,
        });
    }

    pub fn shadowAt(self: Tokens, level: u2) ?cmd.Shadow {
        return self.elevation[level];
    }
};

/// Rounded corners, thin strokes and soft shadows: the "modern app" look.
pub const modern_tokens: Tokens = .{
    .radius_sm = 5,
    .radius_md = 8,
    .radius_lg = 14,
    .border_width = 1,
    .space = .{ 4, 8, 12, 16, 24 },
    .elevation = .{
        null,
        .{ .dx = 0, .dy = 1, .blur = 3, .color = .{ 0.06, 0.09, 0.16, 0.14 } },
        .{ .dx = 0, .dy = 4, .blur = 14, .color = .{ 0.06, 0.09, 0.16, 0.14 } },
        .{ .dx = 0, .dy = 12, .blur = 28, .color = .{ 0.06, 0.09, 0.16, 0.20 } },
    },
};

/// Everything the un-styled emitters consult. A plain struct: build one
/// with `fromPalette`, tweak a derived theme, or write a literal from
/// scratch. Only the palette and the five text/panel colors have no
/// default; the widget styles and typography fall back to their own
/// struct defaults, so a custom theme need only override what it cares about.
pub const Theme = struct {
    palette: Palette,
    typography: Typography = .{},

    /// Color used by `cb.text(...)` when no per-cmd color override.
    text_color: [4]f32,
    /// Color used by `cb.heading(...)`.
    heading_color: [4]f32,
    /// Color used by `cb.textMuted(...)`.
    muted_color: [4]f32,
    /// Color used by `cb.textDanger(...)`.
    danger_color: [4]f32,
    /// Color used by `cb.textWarning(...)` (`Palette.warning`). Defaulted
    /// for hand-built themes.
    warning_color: [4]f32 = .{ 0.92, 0.66, 0.20, 1.0 },
    /// Fill for elevated panel / card group backgrounds (assign to
    /// `GroupStyle.bg`). Typical usage is the inner group of a modal
    /// overlay — the dim overlay scrim sits behind, the panel sits on
    /// top with this fill, and text reads against the opaque card.
    panel_bg: [4]f32,

    /// Shape and depth tokens (radii, spacing scale, elevations); see `Tokens`.
    tokens: Tokens = .{},

    button: cmd.ButtonStyle = .{},
    /// The call-to-action button: accent fill, light text.
    button_primary: cmd.ButtonStyle = .{},
    text_input: cmd.TextInputStyle = .{},
    checkbox: cmd.CheckboxStyle = .{},
    radio: cmd.RadioStyle = .{},
    slider: cmd.SliderStyle = .{},
    divider: cmd.DividerStyle = .{},
    /// Bordered panel / card: `cb.pushGroup(cb.theme.card)`.
    card: cmd.GroupStyle = .{},
    /// Underline-variant text input for typed-form fields:
    /// `cb.textInputStyled(msg, content, cursor, cb.theme.field)`.
    field: cmd.TextInputStyle = .{ .variant = .underline },

    /// Apps that want a non-default starting point can branch from
    /// these and override specific fields.
    pub const dark_default: Theme = fromPalette(dark_palette);
    pub const light_default: Theme = fromPalette(light_palette);
    /// Rounded corners, soft shadows, indigo accent (see `modern_tokens`).
    pub const modern_light: Theme = fromPaletteTokens(modern_light_palette, modern_tokens);
    pub const modern_dark: Theme = fromPaletteTokens(modern_dark_palette, modern_tokens);

    /// Build a Theme by deriving widget styles from a palette. Apps
    /// that want a custom brand palette call this and then optionally
    /// tweak individual style fields.
    pub fn fromPalette(p: Palette) Theme {
        return fromPaletteTokens(p, .{});
    }

    /// `fromPalette` with shape tokens: the derived button / input / card
    /// styles get the radii, borders and elevations from `t`.
    pub fn fromPaletteTokens(p: Palette, t: Tokens) Theme {
        const rounded = !t.radii(.md).isZero();
        const input: cmd.TextInputStyle = .{
            .bg = p.bg_sunken,
            .fg = p.fg,
            .border = p.border,
            .focus_border = p.accent,
            .cursor = p.fg,
            .flex = 1,
            .min_width = 120,
            .radius = t.radii(.sm),
            .border_width = if (rounded) t.border_width else 2,
            .disabled_bg = mix(p.bg_sunken, p.bg, 0.5),
            .disabled_fg = mix(p.fg_muted, p.bg, 0.4),
            .disabled_border = mix(p.border, p.bg, 0.5),
        };
        return .{
            .tokens = t,
            .palette = p,
            .typography = .{},
            .text_color = p.fg,
            .heading_color = p.fg,
            .muted_color = p.fg_muted,
            .danger_color = p.danger,
            .warning_color = p.warning,
            .panel_bg = p.bg_panel,
            .button = .{
                .bg = p.bg_raised,
                .hover_bg = p.bg_hover,
                .press_bg = p.bg_press,
                .fg = p.fg,
                .label_align = .center,
                .radius = t.radii(.md),
                .border = if (rounded) p.border else null,
                .border_width = t.border_width,
                .soft_shadow = t.shadowAt(1),
                .disabled_bg = mix(p.bg_raised, p.bg, 0.55),
                .disabled_fg = mix(p.fg_muted, p.bg, 0.4),
            },
            .button_primary = .{
                .bg = p.accent,
                .hover_bg = lighten(p.accent, 0.10),
                .press_bg = lighten(p.accent, -0.10),
                .fg = onAccent(p),
                .label_align = .center,
                .radius = t.radii(.md),
                .soft_shadow = t.shadowAt(1),
            },
            .text_input = input,
            .field = blk: {
                var f = input;
                f.variant = .underline;
                break :blk f;
            },
            .card = .{ .padding = 12, .gap = 8, .bg = p.bg_panel, .border = p.border, .border_width = t.border_width, .radius = t.radii(.lg), .soft_shadow = t.shadowAt(2) },
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

/// `a` -> `b` by `t`, alpha from `a`.
fn mix(a: [4]f32, b: [4]f32, t: f32) [4]f32 {
    return .{ a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] };
}

/// WCAG relative luminance of an sRGB colour.
fn luminance(c: [4]f32) f32 {
    var l: f32 = 0;
    const k = [3]f32{ 0.2126, 0.7152, 0.0722 };
    for (0..3) |i| {
        const v = c[i];
        const lin = if (v <= 0.03928) v / 12.92 else std.math.pow(f32, (v + 0.055) / 1.055, 2.4);
        l += k[i] * lin;
    }
    return l;
}

/// WCAG contrast ratio of two colours (1 .. 21).
pub fn contrast(a: [4]f32, b: [4]f32) f32 {
    const la = luminance(a);
    const lb = luminance(b);
    return (@max(la, lb) + 0.05) / (@min(la, lb) + 0.05);
}

/// Label colour for a filled accent surface: white, or the window colour
/// when that reads better (light accents of dark palettes).
fn onAccent(p: Palette) [4]f32 {
    const white: [4]f32 = .{ 1, 1, 1, 1 };
    return if (contrast(white, p.accent) >= contrast(p.bg, p.accent)) white else p.bg;
}

/// Move a colour toward white (`amount` > 0) or black (< 0), keeping alpha.
fn lighten(c: [4]f32, amount: f32) [4]f32 {
    const target: f32 = if (amount >= 0) 1 else 0;
    const t = @abs(amount);
    return .{ c[0] + (target - c[0]) * t, c[1] + (target - c[1]) * t, c[2] + (target - c[2]) * t, c[3] };
}

pub const dark_palette: Palette = .{
    .bg = .{ 0.08, 0.08, 0.10, 1.0 },
    .bg_panel = .{ 0.15, 0.15, 0.18, 1.0 },
    .bg_sunken = .{ 0.12, 0.12, 0.14, 1.0 },
    .bg_raised = .{ 0.25, 0.25, 0.28, 1.0 },
    .bg_hover = .{ 0.35, 0.35, 0.40, 1.0 },
    .bg_press = .{ 0.15, 0.15, 0.18, 1.0 },
    .fg = .{ 0.92, 0.92, 0.94, 1.0 },
    .fg_muted = .{ 0.68, 0.68, 0.74, 1.0 },
    .accent = .{ 0.30, 0.55, 1.00, 1.0 },
    .danger = .{ 0.95, 0.45, 0.40, 1.0 },
    .border = .{ 0.35, 0.35, 0.40, 1.0 },
    .warning = .{ 0.95, 0.72, 0.30, 1.0 },
};

pub const light_palette: Palette = .{
    .bg = .{ 0.96, 0.96, 0.97, 1.0 },
    .bg_panel = .{ 0.97, 0.97, 0.98, 1.0 },
    .bg_sunken = .{ 1.00, 1.00, 1.00, 1.0 },
    .bg_raised = .{ 0.88, 0.88, 0.92, 1.0 },
    .bg_hover = .{ 0.82, 0.82, 0.88, 1.0 },
    .bg_press = .{ 0.74, 0.74, 0.80, 1.0 },
    .fg = .{ 0.10, 0.10, 0.12, 1.0 },
    .fg_muted = .{ 0.36, 0.36, 0.42, 1.0 },
    .accent = .{ 0.12, 0.38, 0.88, 1.0 },
    .danger = .{ 0.78, 0.18, 0.15, 1.0 },
    .border = .{ 0.72, 0.72, 0.78, 1.0 },
    .warning = .{ 0.70, 0.45, 0.00, 1.0 },
};

pub const modern_light_palette: Palette = .{
    .bg = .{ 0.957, 0.961, 0.973, 1.0 },
    .bg_panel = .{ 1.0, 1.0, 1.0, 1.0 },
    .bg_sunken = .{ 1.0, 1.0, 1.0, 1.0 },
    .bg_raised = .{ 1.0, 1.0, 1.0, 1.0 },
    .bg_hover = .{ 0.945, 0.953, 0.973, 1.0 },
    .bg_press = .{ 0.894, 0.910, 0.941, 1.0 },
    .fg = .{ 0.106, 0.122, 0.165, 1.0 },
    .fg_muted = .{ 0.390, 0.420, 0.480, 1.0 },
    .accent = .{ 0.260, 0.360, 0.850, 1.0 },
    .danger = .{ 0.780, 0.200, 0.220, 1.0 },
    .border = .{ 0.851, 0.863, 0.890, 1.0 },
    .warning = .{ 0.710, 0.450, 0.040, 1.0 },
};

pub const modern_dark_palette: Palette = .{
    .bg = .{ 0.067, 0.075, 0.098, 1.0 },
    .bg_panel = .{ 0.110, 0.122, 0.153, 1.0 },
    .bg_sunken = .{ 0.082, 0.090, 0.118, 1.0 },
    .bg_raised = .{ 0.141, 0.157, 0.192, 1.0 },
    .bg_hover = .{ 0.188, 0.208, 0.251, 1.0 },
    .bg_press = .{ 0.106, 0.118, 0.149, 1.0 },
    .fg = .{ 0.929, 0.937, 0.961, 1.0 },
    .fg_muted = .{ 0.604, 0.631, 0.690, 1.0 },
    .accent = .{ 0.392, 0.490, 0.969, 1.0 },
    .danger = .{ 0.953, 0.435, 0.443, 1.0 },
    .border = .{ 0.204, 0.224, 0.267, 1.0 },
    .warning = .{ 0.960, 0.740, 0.330, 1.0 },
};
