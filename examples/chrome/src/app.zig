//! Chrome: a 1970s engineering-workstation shell built only from stock Teak.
//!
//! Shows the layout + styling model end to end: a 40px header bar, a body of
//! three columns (360 fixed | flexible center | 320 fixed) stretched to the
//! full height, a 24px status line, bordered cards, bracket tabs with an
//! underline bar, a fixed-column parts table (`teak.Table`), an underline
//! text field, ink-on-paper buttons that invert on hover, and a floating
//! overlay with a hard offset shadow. All of it is data on the style structs;
//! there is no per-widget state here beyond the Model.

const std = @import("std");
const teak = @import("teak");

// ── Palette and theme ──────────────────────────────────────────────

pub const ink: [4]f32 = .{ 0.10, 0.09, 0.08, 1 };
pub const paper: [4]f32 = .{ 0.93, 0.91, 0.84, 1 };
pub const paper_dark: [4]f32 = .{ 0.87, 0.84, 0.75, 1 };
pub const muted: [4]f32 = .{ 0.42, 0.40, 0.35, 1 };
pub const red: [4]f32 = .{ 0.72, 0.17, 0.10, 1 };
const clear: [4]f32 = .{ 0, 0, 0, 0 };

const plex: teak.FontSpec = .{ .size_px = 13, .family = .mono };
const plex_bold: teak.FontSpec = .{ .size_px = 13, .family = .mono, .weight = .bold, .letter_spacing = 1 };

/// A fully custom theme: a plain literal, no `fromPalette`.
pub const theme: teak.Theme = .{
    .palette = .{
        .bg = paper,
        .bg_panel = paper,
        .bg_sunken = paper,
        .bg_raised = paper,
        .bg_hover = ink,
        .bg_press = ink,
        .fg = ink,
        .fg_muted = muted,
        .accent = red,
        .danger = red,
        .border = ink,
    },
    .typography = .{ .body = plex, .mono = plex, .small = plex, .heading = plex_bold },
    .text_color = ink,
    .heading_color = ink,
    .muted_color = muted,
    .danger_color = red,
    .panel_bg = paper,
    .button = key_button,
    .text_input = .{
        .bg = paper,
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
    },
    .divider = .{ .thickness = 1, .color = ink },
    .card = .{ .padding = 10, .gap = 6, .bg = paper, .border = ink, .align_cross = .stretch },
    .field = .{
        .variant = .underline,
        .fg = ink,
        .border = ink,
        .focus_border = red,
        .cursor = red,
        .selection_bg = .{ 0.72, 0.17, 0.10, 0.25 },
        .height = 26,
        .flex = 0,
    },
};

/// Ink on paper; inverts on hover and press.
const key_button: teak.ButtonStyle = .{
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
};

/// The same, but for the dark header bar.
const header_button: teak.ButtonStyle = .{
    .bg = ink,
    .hover_bg = paper,
    .press_bg = paper,
    .fg = paper,
    .hover_fg = ink,
    .press_fg = ink,
    .border = paper,
    .label_align = .center,
    .height = 26,
    .min_width = 0,
    .h_padding = 12,
};

/// Flat tab label; the underline bar under it marks the selection.
const tab_button: teak.ButtonStyle = .{
    .bg = clear,
    .hover_bg = paper_dark,
    .press_bg = paper_dark,
    .fg = ink,
    .label_align = .center,
    .height = 24,
    .min_width = 0,
    .h_padding = 8,
};

// ── Looks: retro (above) and modern ────────────────────────────────

/// The modern theme: the stock `Theme.modern_light` (rounded, soft shadows,
/// indigo accent) in the default sans typography.
pub const modern_theme: teak.Theme = blk: {
    var t = teak.Theme.modern_light;
    t.card.align_cross = .stretch; // label / value rows span the card
    break :blk t;
};

/// Everything `view` styles, in one value, so the same layout renders in
/// either look. `retro` is the engineering-workstation look above, field for
/// field; `modernLook` is the rounded one built from `modern_theme`'s tokens.
const Look = struct {
    modern: bool,
    font: teak.FontSpec,
    font_bold: teak.FontSpec,
    /// Fixed-column text (the parts table is built from monospace columns).
    mono: teak.FontSpec,
    mono_bold: teak.FontSpec,
    /// Text on surfaces, secondary text, accent.
    ink: [4]f32,
    paper: [4]f32,
    muted: [4]f32,
    accent: [4]f32,
    // header
    header_bg: [4]f32,
    header_fg: [4]f32,
    header_dim: [4]f32,
    header_button: teak.ButtonStyle,
    // columns
    col_bg: [4]f32,
    col_border: ?[4]f32,
    col_pad: f32,
    col_gap: f32,
    /// Modern: the left column's content sits in one raised card.
    panel: ?teak.GroupStyle,
    center_bg: [4]f32,
    key: teak.ButtonStyle,
    tab: teak.ButtonStyle,
    tab_on: teak.ButtonStyle,
    tab_bar: bool,
    // parts table
    table_box: teak.GroupStyle,
    table_head_bg: ?[4]f32,
    table_head_fg: [4]f32,
    table_sel_bg: ?[4]f32,
    table_sel_fg: [4]f32,
    table_rule: [4]f32,
    field: teak.TextInputStyle,
    // status line and the drawing sheet
    status_bg: [4]f32,
    status_border: ?[4]f32,
    sheet: teak.GroupStyle,
    sheet_grid: [4]f32,
    sheet_line_w: f32,
    sheet_mark: [4]f32,
    // popover
    pop: teak.OverlayStyle(Msg),
};

const retro: Look = .{
    .modern = false,
    .font = plex,
    .font_bold = plex_bold,
    .mono = plex,
    .mono_bold = plex_bold,
    .ink = ink,
    .paper = paper,
    .muted = muted,
    .accent = red,
    .header_bg = ink,
    .header_fg = paper,
    .header_dim = .{ 0.7, 0.68, 0.6, 1 },
    .header_button = header_button,
    .col_bg = paper,
    .col_border = ink,
    .col_pad = 12,
    .col_gap = 10,
    .panel = null,
    .center_bg = paper_dark,
    .key = key_button,
    .tab = tab_button,
    .tab_on = tab_button,
    .tab_bar = true,
    .table_box = .{ .padding = 1, .gap = 0, .border = ink, .align_cross = .stretch },
    .table_head_bg = ink,
    .table_head_fg = paper,
    .table_sel_bg = ink,
    .table_sel_fg = paper,
    .table_rule = paper_dark,
    .field = theme.field,
    .status_bg = paper_dark,
    .status_border = ink,
    .sheet = .{ .width = 200, .height = 120, .flex = 1, .padding = 0, .gap = 0, .bg = paper },
    .sheet_grid = .{ 0.10, 0.09, 0.08, 0.10 },
    .sheet_line_w = 2,
    .sheet_mark = red,
    .pop = .{
        // Overlaps the left column's parts table on purpose: the opaque
        // backdrop must hide the table text beneath it.
        .x = 150,
        .y = 120,
        .width = 300,
        .padding = 12,
        .gap = 6,
        .backdrop = paper,
        .border = ink,
        .border_width = 1,
        .shadow = ink,
        .shadow_offset = .{ 4, 4 },
        .align_cross = .stretch,
    },
};

const modern: Look = blk: {
    const t = modern_theme;
    const p = t.palette;
    const soft = [4]f32{ p.accent[0], p.accent[1], p.accent[2], 0.12 };
    break :blk .{
        .modern = true,
        .font = .{ .size_px = 14, .family = .sans },
        .font_bold = .{ .size_px = 14, .family = .sans, .weight = .bold },
        .mono = .{ .size_px = 13, .family = .mono },
        .mono_bold = .{ .size_px = 13, .family = .mono, .weight = .bold },
        .ink = p.fg,
        .paper = p.bg_panel,
        .muted = p.fg_muted,
        .accent = p.accent,
        .header_bg = .{ 0.106, 0.122, 0.165, 1 },
        .header_fg = .{ 1, 1, 1, 1 },
        .header_dim = .{ 0.62, 0.66, 0.74, 1 },
        .header_button = .{
            .bg = .{ 1, 1, 1, 0.08 },
            .hover_bg = .{ 1, 1, 1, 0.18 },
            .press_bg = .{ 1, 1, 1, 0.26 },
            .fg = .{ 1, 1, 1, 1 },
            .radius = t.tokens.radii(.md),
            .label_align = .center,
            .height = 28,
            .min_width = 0,
            .h_padding = 14,
        },
        .col_bg = p.bg,
        .col_border = null,
        .col_pad = 16,
        .col_gap = 14,
        .panel = .{ .padding = 16, .gap = 12, .flex = 1, .bg = p.bg_panel, .radius = t.tokens.radii(.lg), .soft_shadow = t.tokens.shadowAt(2), .align_cross = .stretch },
        .center_bg = .{ 0.914, 0.929, 0.957, 1 },
        .key = t.button,
        .tab = .{ .bg = clear, .hover_bg = .{ p.accent[0], p.accent[1], p.accent[2], 0.08 }, .press_bg = soft, .fg = p.fg_muted, .radius = t.tokens.radii(.md), .label_align = .center, .height = 30, .min_width = 0, .h_padding = 14 },
        .tab_on = .{ .bg = soft, .hover_bg = soft, .press_bg = soft, .fg = p.accent, .radius = t.tokens.radii(.md), .label_align = .center, .height = 30, .min_width = 0, .h_padding = 14 },
        .tab_bar = false,
        .table_box = .{ .padding = 4, .gap = 0, .border = p.border, .radius = t.tokens.radii(.md), .bg = p.bg_panel, .align_cross = .stretch },
        .table_head_bg = null,
        .table_head_fg = p.fg_muted,
        .table_sel_bg = soft,
        .table_sel_fg = p.fg,
        .table_rule = .{ 0.93, 0.94, 0.96, 1 },
        .field = t.text_input,
        .status_bg = p.bg_panel,
        .status_border = null,
        .sheet = .{ .flex = 1, .padding = 0, .gap = 0, .bg = .{ 1, 1, 1, 1 }, .radius = t.tokens.radii(.lg), .soft_shadow = t.tokens.shadowAt(2), .align_cross = .stretch },
        .sheet_grid = .{ 0.31, 0.42, 0.93, 0.08 },
        .sheet_line_w = 2.5,
        .sheet_mark = p.accent,
        .pop = .{
            .x = 640,
            .y = 96,
            .width = 280,
            .padding = 16,
            .gap = 8,
            .backdrop = p.bg_panel,
            .border = p.border,
            .border_width = 1,
            .radius = t.tokens.radii(.lg),
            .soft_shadow = t.tokens.shadowAt(3),
            .align_cross = .stretch,
        },
    };
};

fn lookFor(is_modern: bool) *const Look {
    return if (is_modern) &modern else &retro;
}

// ── Data ───────────────────────────────────────────────────────────

const Part = struct { name: []const u8, qty: u32, len_mm: f32 };
const parts = [_]Part{
    .{ .name = "BRACKET-L-100", .qty = 4, .len_mm = 100.0 },
    .{ .name = "BASE-PLATE", .qty = 1, .len_mm = 240.5 },
    .{ .name = "SPACER-M6", .qty = 12, .len_mm = 8.0 },
    .{ .name = "GUSSET-45-DEG-REINFORCED", .qty = 2, .len_mm = 64.25 },
    .{ .name = "BOLT-M6X20", .qty = 24, .len_mm = 20.0 },
    .{ .name = "WASHER-M6", .qty = 48, .len_mm = 1.6 },
};

const parts_table: teak.Table = .{
    .columns = &.{
        .{ .title = "PART", .chars = 15 },
        .{ .title = "QTY", .chars = 3, .cell_align = .right },
        .{ .title = "LEN MM", .chars = 7, .cell_align = .right },
    },
};

const materials = [_][]const u8{
    "6061-T6 ALUMINUM", "7075-T6 ALUMINUM", "304 STAINLESS",     "316 STAINLESS",
    "1018 MILD STEEL",  "4140 CHROMOLY",    "TI-6AL-4V",         "C360 BRASS",
    "C110 COPPER",      "DELRIN (POM)",     "ABS",               "NYLON 6/6",
    "PEEK",             "G10 / FR4",        "BLACK OXIDE 12L14",
};

/// Searchable material picker (a `teak.Combobox`: query field + filtered overlay list).
const Material = teak.Combobox(24);
/// The list anchors itself under the input (`auto_anchor`): no window coordinates.
const material_opts: teak.ComboboxViewOpts = .{
    .list_width = 336,
    .max_visible = 6,
    .input_style = theme.field,
};

const tab_names = [_][]const u8{ "PARTS", "NOTES", "DIFF" };

// ── Model / Msg / update ───────────────────────────────────────────

pub const MAX_NAME = 24;
const default_name_text = "BASE-PLATE";
const default_name: [MAX_NAME]u8 = blk: {
    var buf: [MAX_NAME]u8 = @splat(0);
    @memcpy(buf[0..default_name_text.len], default_name_text);
    break :blk buf;
};

pub const Model = struct {
    tab: u8 = 0,
    selected: u8 = 1,
    name: [MAX_NAME]u8 = default_name,
    name_len: u8 = default_name_text.len,
    name_focused: bool = false,
    help_open: bool = true,
    /// The modern look (`StyleToggle` in the header) instead of the retro one.
    modern: bool = false,
    /// 0 = hidden, 1 = fully shown. Drives the popover's slide-in / slide-out
    /// (a `teak.anim.Tween` in the Model; advanced by `.frame` Msgs while it
    /// is active). Starts settled at 1 because the popover starts open.
    help_slide: teak.anim.Tween(f32) = .still(1),
    material: Material.Model = .{ .selected = 0 },
};

pub const Msg = union(enum) {
    select_tab: u8,
    select_part: u8,
    focus_name,
    /// A press on blank space: drop the text focus.
    blur,
    name_char: u8,
    name_backspace,
    toggle_help,
    toggle_style,
    /// Frame time in ms, delivered by `animationMsg` while an animation runs.
    frame: u32,
    material: Material.Msg,
    noop,
};

pub fn update(m: *Model, msg: Msg) void {
    switch (msg) {
        .select_tab => |t| m.tab = @min(t, tab_names.len - 1),
        .select_part => |p| m.selected = @intCast(@min(p, parts.len - 1)),
        .focus_name => {
            m.name_focused = true;
            m.material.open = false;
        },
        .blur => {
            m.name_focused = false;
            m.material.open = false;
        },
        .material => |mm| {
            if (mm == .focus) m.name_focused = false;
            Material.update(&m.material, mm);
        },
        .name_char => |c| if (m.name_len < MAX_NAME) {
            m.name[m.name_len] = c;
            m.name_len += 1;
        },
        .name_backspace => if (m.name_len > 0) {
            m.name_len -= 1;
        },
        .toggle_help => {
            m.help_open = !m.help_open;
            // Opening eases out over 400 ms; closing slides out faster.
            if (m.help_open) m.help_slide.start(1, 400, .out_cubic) else m.help_slide.start(0, 160, .in_cubic);
        },
        .toggle_style => m.modern = !m.modern,
        .frame => |dt| m.help_slide.advance(dt),
        .noop => {},
    }
}

const material_msgs = .{
    .focus = Msg{ .material = .focus },
    .close = Msg{ .material = .close },
    .selectMsg = materialSelect,
};

fn materialSelect(i: usize) Msg {
    return .{ .material = .{ .select = i } };
}

// ── View ───────────────────────────────────────────────────────────

pub fn view(m: *const Model, cb: anytype) void {
    const l = lookFor(m.modern);
    // Root: the window-sized sheet; every direct child fills its width.
    cb.pushGroup(.{ .padding = 0, .gap = 0, .bg = l.col_bg, .align_cross = .stretch });
    header(m, cb, l);
    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 0, .flex = 1, .align_cross = .stretch });
    leftColumn(m, cb, l);
    centerColumn(cb, l);
    rightColumn(cb, l);
    cb.popGroup();
    statusLine(cb, l);
    cb.popGroup();

    if (m.help_open or m.help_slide.active()) helpPopover(cb, l, m.help_slide.value());
}

fn header(m: *const Model, cb: anytype, l: *const Look) void {
    cb.pushGroup(.{ .direction = .horizontal, .pad_x = 12, .pad_y = 0, .gap = 14, .height = 40, .bg = l.header_bg, .align_cross = .center });
    cb.textStyled("KERF", l.font_bold, l.header_fg);
    cb.textStyled("DWG 0417-B   REV C", l.font, l.header_dim);
    cb.spacer(1);
    cb.buttonStyled(.toggle_style, if (m.modern) "RETRO" else "MODERN", l.header_button);
    cb.buttonStyled(.noop, "FILE", l.header_button);
    cb.buttonStyled(.noop, "EXPORT", l.header_button);
    cb.buttonStyled(.toggle_help, "HELP", l.header_button);
    cb.popGroup();
}

fn leftColumn(m: *const Model, cb: anytype, l: *const Look) void {
    cb.pushGroup(.{ .width = 360, .padding = l.col_pad, .gap = l.col_gap, .bg = l.col_bg, .border = l.col_border, .align_cross = .stretch });
    if (l.panel) |panel| cb.pushGroup(panel);

    // Tabs: bracket tabs with an underline bar (retro) or pill tabs (modern).
    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 4 });
    for (tab_names, 0..) |name, i| {
        const on = m.tab == i;
        if (l.tab_bar) {
            const label = if (on) std.fmt.allocPrint(cb.arena.allocator(), "[{s}]", .{name}) catch name else name;
            cb.pushGroup(.{ .padding = 0, .gap = 0, .align_cross = .stretch });
            cb.buttonStyled(.{ .select_tab = @intCast(i) }, label, l.tab);
            cb.pushGroup(.{ .padding = 0, .gap = 0, .height = 3, .bg = if (on) l.ink else null });
            cb.popGroup();
            cb.popGroup();
        } else {
            cb.buttonStyled(.{ .select_tab = @intCast(i) }, name, if (on) l.tab_on else l.tab);
        }
    }
    cb.popGroup();

    // Parts table: header band, rule, rows; the selected row is highlighted.
    // Retro padding 1 keeps the rows inside the 1px border (the border takes no layout space).
    cb.pushGroup(l.table_box);
    parts_table.header(cb, .{ .font = l.mono_bold, .color = l.table_head_fg, .bg = l.table_head_bg });
    for (parts, 0..) |p, i| {
        const a = cb.arena.allocator();
        const qty = std.fmt.allocPrint(a, "{d}", .{p.qty}) catch "?";
        const len = std.fmt.allocPrint(a, "{d:.2}", .{p.len_mm}) catch "?";
        const picked = m.selected == i;
        parts_table.row(cb, &.{ p.name, qty, len }, .{
            .font = l.mono,
            .color = if (picked) l.table_sel_fg else l.ink,
            .bg = if (picked) l.table_sel_bg else null,
            .rule = l.table_rule,
        });
    }
    cb.popGroup();

    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 8, .justify = .space_between });
    const prev: u8 = if (m.selected == 0) parts.len - 1 else m.selected - 1;
    const next: u8 = if (m.selected + 1 >= parts.len) 0 else m.selected + 1;
    cb.buttonStyled(.{ .select_part = prev }, "< PREV", l.key);
    cb.buttonStyled(.{ .select_part = next }, "NEXT >", l.key);
    cb.popGroup();

    // Typed-form fields: underline variant (focusable) and the material combobox.
    cb.textMuted("NAME");
    cb.textInputStyled(.focus_name, m.name[0..m.name_len], m.name_len, l.field);
    cb.textMuted("MATERIAL");
    Material.viewWith(&m.material, cb, &materials, material_msgs, optsFor(m));

    cb.spacer(1);
    cb.textMuted("6 PARTS  /  91 PIECES");
    if (l.panel != null) cb.popGroup();
    cb.popGroup();
}

fn optsFor(m: *const Model) teak.ComboboxViewOpts {
    var o = material_opts;
    if (m.modern) {
        o.list_width = 296; // the modern panel's card inset
        o.input_style = modern.field;
    }
    return o;
}

fn centerColumn(cb: anytype, l: *const Look) void {
    cb.pushGroup(.{ .padding = if (l.modern) 16 else 12, .gap = 8, .flex = 1, .bg = l.center_bg, .align_cross = .stretch });

    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 6 });
    for ([_][]const u8{ "SELECT", "LINE", "ARC", "DIMENSION" }) |label| cb.button(.noop, label);
    cb.spacer(1);
    cb.textMuted("SCALE 1:2");
    cb.popGroup();

    // Drafting sheet: a grid and a part outline, drawn as canvas primitives.
    const a = cb.arena.allocator();
    var prims: std.ArrayList(teak.CanvasPrimitive) = .empty;
    var g: f32 = 0;
    while (g < 1600) : (g += 40) {
        prims.append(a, .{ .hline = .{ .y = g, .color = l.sheet_grid } }) catch unreachable;
        prims.append(a, .{ .vline = .{ .x = g, .color = l.sheet_grid } }) catch unreachable;
    }
    const outline = a.dupe(teak.CanvasPoint, &.{
        .{ .x = 140, .y = 120 }, .{ .x = 460, .y = 120 }, .{ .x = 460, .y = 200 },
        .{ .x = 380, .y = 200 }, .{ .x = 380, .y = 340 }, .{ .x = 140, .y = 340 },
        .{ .x = 140, .y = 120 },
    }) catch unreachable;
    prims.append(a, .{ .polyline = .{ .points = outline, .color = l.ink, .thickness = l.sheet_line_w } }) catch unreachable;
    prims.append(a, .{ .marker = .{ .x = 140, .y = 120, .size = 8, .color = l.sheet_mark } }) catch unreachable;
    prims.append(a, .{ .marker = .{ .x = 380, .y = 340, .size = 8, .color = l.sheet_mark } }) catch unreachable;
    if (l.modern) {
        // Rounded sheet card with the drawing inside it (the canvas itself is a plain rect).
        cb.pushGroup(l.sheet);
        cb.canvasLabeled(.{ .width = 200, .height = 120, .flex = 1, .bg = null }, prims.items, "drawing sheet");
        cb.popGroup();
    } else {
        cb.canvasLabeled(.{ .width = 200, .height = 120, .flex = 1, .bg = paper }, prims.items, "drawing sheet");
    }

    cb.popGroup();
}

fn rightColumn(cb: anytype, l: *const Look) void {
    cb.pushGroup(.{ .width = 320, .padding = l.col_pad, .gap = if (l.modern) 16 else 12, .bg = l.col_bg, .border = l.col_border, .align_cross = .stretch });

    cb.pushGroup(cb.theme.card);
    cb.heading("PROPERTIES");
    cb.divider();
    property(cb, "LENGTH", "240.50 MM");
    property(cb, "WIDTH", "120.00 MM");
    property(cb, "MASS", "0.412 KG");
    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 8, .justify = .space_between });
    if (l.modern) {
        cb.buttonStyled(.noop, "APPLY", cb.theme.button_primary);
    } else {
        cb.button(.noop, "APPLY");
    }
    cb.button(.noop, "RESET");
    cb.popGroup();
    cb.popGroup();

    cb.pushGroup(cb.theme.card);
    cb.heading("NOTES");
    cb.divider();
    // Wrapped paragraphs: they take the card's width, re-wrap when the window
    // or the card changes, and grow the card's height with their line count.
    cb.paragraphStyled("1. BREAK ALL SHARP EDGES AND DEBURR HOLES; NO BURRS ABOVE 0.1 MM ON MATING FACES.", plex, muted, .{});
    cb.paragraphStyled("2. DIMENSIONS IN MM, TOLERANCES PER ISO 2768-M UNLESS NOTED.", plex, muted, .{});
    cb.paragraphStyled("3. FINISH: ANODIZE CLEAR, 10-15 MICRON; MASK THE BORE BEFORE COATING.", plex, muted, .{ .max_lines = 2 });
    // A shrinking row: the tag keeps its width, the paragraph beside it gives
    // way (and re-wraps) as the column narrows.
    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 8, .align_cross = .start });
    cb.buttonStyled(.noop, "REV C", l.key);
    cb.paragraphStyled("SUPERSEDES REV B; RE-INSPECT ALL FIRST-ARTICLE PARTS.", plex, ink, .{});
    cb.popGroup();
    cb.popGroup();

    cb.popGroup();
}

fn property(cb: anytype, label: []const u8, value: []const u8) void {
    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 0, .justify = .space_between });
    cb.textMuted(label);
    cb.text(value);
    cb.popGroup();
}

fn statusLine(cb: anytype, l: *const Look) void {
    cb.pushGroup(.{ .direction = .horizontal, .pad_x = 12, .pad_y = 0, .gap = 16, .height = 24, .bg = l.status_bg, .border = l.status_border, .align_cross = .center });
    cb.textStyled("READY", l.font_bold, l.ink);
    cb.textMuted("X 120.50   Y 044.00   UNITS MM");
    cb.spacer(1);
    cb.textMuted("SNAP ON   GRID 10");
    cb.popGroup();
}

/// Floating key-help panel: opaque backdrop + border + a hard 4px offset
/// shadow (retro) or a rounded panel with a soft shadow (modern), non-modal
/// so the sheet underneath stays live. `slide` (0..1) drops it into place
/// while the border and hard shadow fade in from the backdrop.
fn helpPopover(cb: anytype, l: *const Look, slide: f32) void {
    const t = std.math.clamp(slide, 0, 1);
    var ov = l.pop;
    ov.y -= (1 - t) * 70;
    if (ov.border) |c| ov.border = teak.anim.lerp([4]f32, ov.backdrop, c, t);
    if (ov.shadow) |c| ov.shadow = teak.anim.lerp([4]f32, ov.backdrop, c, t);
    cb.pushOverlay(ov);
    cb.heading("QUICK KEYS");
    cb.divider();
    cb.text("L   LINE");
    cb.text("A   ARC");
    cb.text("D   DIMENSION");
    cb.text("ESC CANCEL");
    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 0, .justify = .end });
    cb.buttonStyled(.toggle_help, "CLOSE", l.key);
    cb.popGroup();
    cb.popOverlay();
}

// ── Host integration ───────────────────────────────────────────────

/// Ask for frame callbacks only while the popover is animating; once it
/// settles the run loop goes idle again.
pub fn subscribe(m: *const Model) []const teak.Sub(Msg) {
    return if (m.help_slide.active()) &.{.animation_frame} else &.{};
}

/// The run loop's frame time, as a Msg (never read from a clock in `view`).
pub fn animationMsg(_: *const Model, dt_ms: u32) ?Msg {
    return .{ .frame = dt_ms };
}

/// Clicking empty space clears the focus (no blinking caret left behind).
pub fn pointerMsg(m: *const Model, ev: teak.PointerEvent(Msg)) ?Msg {
    if (ev.kind == .down and ev.isBlank() and (m.name_focused or m.material.open)) return .blur;
    return null;
}

pub fn keyCharMsg(m: *const Model, c: u8) ?Msg {
    if (m.material.open) return .{ .material = Material.charMsg(c) };
    if (!m.name_focused) return if (c == 'm' or c == 'M') Msg.toggle_style else null; // M: retro / modern look
    return .{ .name_char = c };
}

pub fn keySpecialMsg(m: *const Model, key: teak.SpecialKey) ?Msg {
    if (m.material.open) {
        const mm = Material.keyMsg(&m.material, key, &materials, optsFor(m)) orelse return null;
        return .{ .material = mm };
    }
    if (!m.name_focused) return null;
    return switch (key) {
        .backspace => .name_backspace,
        else => null,
    };
}

/// Wheel over the open material list scrolls it.
pub fn wheelMsg(m: *const Model, wheel_dy: f32) ?Msg {
    if (!m.material.open or wheel_dy == 0) return null;
    return .{ .material = Material.scrollByMsg(&m.material, wheel_dy, &materials, optsFor(m)) };
}

/// Lets `teak.run` draw the focus rule + caret on the focused field.
pub fn focusedMsg(m: *const Model) ?Msg {
    if (m.material.open) return Msg{ .material = .focus };
    return if (m.name_focused) Msg.focus_name else null;
}

/// `teak.run` calls this each frame; the whole look lives in `theme`.
pub fn themeFor(m: *const Model) teak.Theme {
    return if (m.modern) modern_theme else theme;
}

// ── Tests ──────────────────────────────────────────────────────────

const test_msr = teak.monoMeasurer();

fn frame(m: *const Model, cb: *teak.CmdBuffer(Msg), rects: []teak.Rect, w: f32, h: f32) []const teak.Rect {
    cb.reset();
    cb.theme = theme;
    view(m, cb);
    teak.LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, w, h, test_msr);
    return rects[0..cb.cmds.items.len];
}

test "view is balanced and fits the rect budget at 1440x900" {
    var m: Model = .{};
    var cb = teak.CmdBuffer(Msg).init(std.testing.allocator);
    defer cb.deinit();
    var rects: [512]teak.Rect = undefined;
    _ = frame(&m, &cb, &rects, 1440, 900);
    try std.testing.expect(teak.validateBalance(cb.cmds.items) == null);
    try std.testing.expect(cb.cmds.items.len < 512);
}

test "shell geometry: header 40, status 24, columns 360 / flex / 320" {
    var m: Model = .{ .help_open = false };
    var cb = teak.CmdBuffer(Msg).init(std.testing.allocator);
    defer cb.deinit();
    var rects: [512]teak.Rect = undefined;
    const rs = frame(&m, &cb, &rects, 1440, 900);

    // The three body columns are the 836px-tall groups starting below the header.
    var cols: [3]teak.Rect = undefined;
    var n: usize = 0;
    for (cb.cmds.items, rs) |c, r| {
        if (c == .push_group and r.y == 40 and r.h == 836 and r.w < 1440 and n < 3) {
            cols[n] = r;
            n += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqual(@as(f32, 360), cols[0].w);
    try std.testing.expectEqual(@as(f32, 1440 - 360 - 320), cols[1].w);
    try std.testing.expectEqual(@as(f32, 320), cols[2].w);
    try std.testing.expectEqual(@as(f32, 1120), cols[2].x);
    // Status line: the last 24px-tall group, pinned to the bottom edge.
    var status: ?teak.Rect = null;
    for (cb.cmds.items, rs) |c, r| {
        if (c == .push_group and r.h == 24) status = r;
    }
    try std.testing.expectEqual(@as(f32, 876), status.?.y);
    try std.testing.expectEqual(@as(f32, 1440), status.?.w);
}

test "update: tab, selection wrap, and name editing" {
    var m: Model = .{};
    update(&m, .{ .select_tab = 9 });
    try std.testing.expectEqual(@as(u8, 2), m.tab);
    update(&m, .{ .select_part = 99 });
    try std.testing.expectEqual(@as(u8, parts.len - 1), m.selected);
    update(&m, .focus_name);
    update(&m, .{ .name_char = 'X' });
    try std.testing.expectEqualStrings("BASE-PLATEX", m.name[0..m.name_len]);
    update(&m, .name_backspace);
    try std.testing.expectEqualStrings("BASE-PLATE", m.name[0..m.name_len]);
}

test "help popover: slide tween runs on frame Msgs and settles" {
    var m: Model = .{};
    try std.testing.expect(!m.help_slide.active());
    update(&m, .toggle_help); // close
    try std.testing.expect(!m.help_open and m.help_slide.active());
    try std.testing.expectEqual(@as(usize, 1), subscribe(&m).len);
    update(&m, .{ .frame = 70 });
    try std.testing.expect(m.help_slide.value() < 1 and m.help_slide.value() > 0);
    update(&m, .{ .frame = 100 });
    try std.testing.expect(!m.help_slide.active());
    try std.testing.expectEqual(@as(f32, 0), m.help_slide.value());
    try std.testing.expectEqual(@as(usize, 0), subscribe(&m).len); // idle again
    update(&m, .toggle_help); // reopen
    update(&m, .{ .frame = 1000 });
    try std.testing.expectEqual(@as(f32, 1), m.help_slide.value());
}

test "material combobox: type to filter, arrows + enter select, escape closes" {
    var m: Model = .{ .help_open = false };
    update(&m, .{ .material = .focus });
    try std.testing.expect(m.material.open);
    for ("alu") |c| update(&m, keyCharMsg(&m, c).?);
    update(&m, keySpecialMsg(&m, .down).?);
    update(&m, keySpecialMsg(&m, .enter).?);
    try std.testing.expectEqual(@as(?usize, 1), m.material.selected); // 7075-T6 ALUMINUM
    try std.testing.expect(!m.material.open);
    update(&m, .{ .material = .focus });
    update(&m, keySpecialMsg(&m, .escape).?);
    try std.testing.expect(!m.material.open);
    try std.testing.expectEqual(@as(?usize, 1), m.material.selected);
    // Focusing the name field closes an open list.
    update(&m, .{ .material = .focus });
    update(&m, .focus_name);
    try std.testing.expect(!m.material.open and m.name_focused);
}

test "open material list view is balanced and within the rect budget" {
    var m: Model = .{ .help_open = false };
    update(&m, .{ .material = .focus });
    var cb = teak.CmdBuffer(Msg).init(std.testing.allocator);
    defer cb.deinit();
    var rects: [512]teak.Rect = undefined;
    _ = frame(&m, &cb, &rects, 1440, 900);
    try std.testing.expect(teak.validateBalance(cb.cmds.items) == null);
    try std.testing.expect(cb.cmds.items.len < 512);
}

test "pointerMsg: a blank-space press clears the name focus and closes the list" {
    var m: Model = .{ .name_focused = true };
    const ev: teak.PointerEvent(Msg) = .{ .kind = .down, .button = .left, .x = 600, .y = 500 };
    try std.testing.expect(ev.isBlank());
    update(&m, pointerMsg(&m, ev).?);
    try std.testing.expect(!m.name_focused);
    try std.testing.expect(pointerMsg(&m, ev) == null); // nothing left to clear
}
