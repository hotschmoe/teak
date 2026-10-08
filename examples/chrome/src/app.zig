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
    /// 0 = hidden, 1 = fully shown. Drives the popover's slide-in / slide-out
    /// (a `teak.anim.Tween` in the Model; advanced by `.frame` Msgs while it
    /// is active). Starts settled at 1 because the popover starts open.
    help_slide: teak.anim.Tween(f32) = .still(1),
};

pub const Msg = union(enum) {
    select_tab: u8,
    select_part: u8,
    focus_name,
    name_char: u8,
    name_backspace,
    toggle_help,
    /// Frame time in ms, delivered by `animationMsg` while an animation runs.
    frame: u32,
    noop,
};

pub fn update(m: *Model, msg: Msg) void {
    switch (msg) {
        .select_tab => |t| m.tab = @min(t, tab_names.len - 1),
        .select_part => |p| m.selected = @intCast(@min(p, parts.len - 1)),
        .focus_name => m.name_focused = true,
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
        .frame => |dt| m.help_slide.advance(dt),
        .noop => {},
    }
}

// ── View ───────────────────────────────────────────────────────────

pub fn view(m: *const Model, cb: anytype) void {
    // Root: the window-sized paper sheet; every direct child fills its width.
    cb.pushGroup(.{ .padding = 0, .gap = 0, .bg = paper, .align_cross = .stretch });
    header(cb);
    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 0, .flex = 1, .align_cross = .stretch });
    leftColumn(m, cb);
    centerColumn(cb);
    rightColumn(cb);
    cb.popGroup();
    statusLine(cb);
    cb.popGroup();

    if (m.help_open or m.help_slide.active()) helpPopover(cb, m.help_slide.value());
}

fn header(cb: anytype) void {
    cb.pushGroup(.{ .direction = .horizontal, .pad_x = 12, .pad_y = 0, .gap = 14, .height = 40, .bg = ink, .align_cross = .center });
    cb.textStyled("KERF", plex_bold, paper);
    cb.textStyled("DWG 0417-B   REV C", plex, .{ 0.7, 0.68, 0.6, 1 });
    cb.spacer(1);
    cb.buttonStyled(.noop, "FILE", header_button);
    cb.buttonStyled(.noop, "EXPORT", header_button);
    cb.buttonStyled(.toggle_help, "HELP", header_button);
    cb.popGroup();
}

fn leftColumn(m: *const Model, cb: anytype) void {
    cb.pushGroup(.{ .width = 360, .padding = 12, .gap = 10, .bg = paper, .border = ink, .align_cross = .stretch });

    // Bracket tabs with an underline bar under the selected one.
    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 4 });
    for (tab_names, 0..) |name, i| {
        const on = m.tab == i;
        const label = if (on) std.fmt.allocPrint(cb.arena.allocator(), "[{s}]", .{name}) catch name else name;
        cb.pushGroup(.{ .padding = 0, .gap = 0, .align_cross = .stretch });
        cb.buttonStyled(.{ .select_tab = @intCast(i) }, label, tab_button);
        cb.pushGroup(.{ .padding = 0, .gap = 0, .height = 3, .bg = if (on) ink else null });
        cb.popGroup();
        cb.popGroup();
    }
    cb.popGroup();

    // Parts table: header band, rule, rows; the selected row is inverted.
    // Padding 1 keeps the rows inside the 1px border (the border takes no layout space).
    cb.pushGroup(.{ .padding = 1, .gap = 0, .border = ink, .align_cross = .stretch });
    parts_table.header(cb, .{ .font = plex_bold, .color = paper, .bg = ink });
    for (parts, 0..) |p, i| {
        const a = cb.arena.allocator();
        const qty = std.fmt.allocPrint(a, "{d}", .{p.qty}) catch "?";
        const len = std.fmt.allocPrint(a, "{d:.2}", .{p.len_mm}) catch "?";
        const picked = m.selected == i;
        parts_table.row(cb, &.{ p.name, qty, len }, .{
            .font = plex,
            .color = if (picked) paper else ink,
            .bg = if (picked) ink else null,
            .rule = paper_dark,
        });
    }
    cb.popGroup();

    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 8, .justify = .space_between });
    const prev: u8 = if (m.selected == 0) parts.len - 1 else m.selected - 1;
    const next: u8 = if (m.selected + 1 >= parts.len) 0 else m.selected + 1;
    cb.buttonStyled(.{ .select_part = prev }, "< PREV", key_button);
    cb.buttonStyled(.{ .select_part = next }, "NEXT >", key_button);
    cb.popGroup();

    // Typed-form fields: underline variant (focusable) and boxed (read-only).
    cb.textMuted("NAME");
    cb.textInputStyled(.focus_name, m.name[0..m.name_len], m.name_len, theme.field);
    cb.textMuted("MATERIAL");
    cb.textInputDisabled(.noop, "6061-T6 ALUMINUM", 0);

    cb.spacer(1);
    cb.textMuted("6 PARTS  /  91 PIECES");
    cb.popGroup();
}

fn centerColumn(cb: anytype) void {
    cb.pushGroup(.{ .padding = 12, .gap = 8, .flex = 1, .bg = paper_dark, .align_cross = .stretch });

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
        prims.append(a, .{ .hline = .{ .y = g, .color = .{ 0.10, 0.09, 0.08, 0.10 } } }) catch unreachable;
        prims.append(a, .{ .vline = .{ .x = g, .color = .{ 0.10, 0.09, 0.08, 0.10 } } }) catch unreachable;
    }
    const outline = a.dupe(teak.CanvasPoint, &.{
        .{ .x = 140, .y = 120 }, .{ .x = 460, .y = 120 }, .{ .x = 460, .y = 200 },
        .{ .x = 380, .y = 200 }, .{ .x = 380, .y = 340 }, .{ .x = 140, .y = 340 },
        .{ .x = 140, .y = 120 },
    }) catch unreachable;
    prims.append(a, .{ .polyline = .{ .points = outline, .color = ink, .thickness = 2 } }) catch unreachable;
    prims.append(a, .{ .marker = .{ .x = 140, .y = 120, .size = 8, .color = red } }) catch unreachable;
    prims.append(a, .{ .marker = .{ .x = 380, .y = 340, .size = 8, .color = red } }) catch unreachable;
    cb.canvasLabeled(.{ .width = 200, .height = 120, .flex = 1, .bg = paper }, prims.items, "drawing sheet");

    cb.popGroup();
}

fn rightColumn(cb: anytype) void {
    cb.pushGroup(.{ .width = 320, .padding = 12, .gap = 12, .bg = paper, .border = ink, .align_cross = .stretch });

    cb.pushGroup(cb.theme.card);
    cb.heading("PROPERTIES");
    cb.divider();
    property(cb, "LENGTH", "240.50 MM");
    property(cb, "WIDTH", "120.00 MM");
    property(cb, "MASS", "0.412 KG");
    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 8, .justify = .space_between });
    cb.button(.noop, "APPLY");
    cb.button(.noop, "RESET");
    cb.popGroup();
    cb.popGroup();

    cb.pushGroup(cb.theme.card);
    cb.heading("NOTES");
    cb.divider();
    cb.textMuted("1. BREAK ALL SHARP EDGES.");
    cb.textMuted("2. DIMENSIONS IN MM.");
    cb.textMuted("3. FINISH: ANODIZE CLEAR.");
    cb.popGroup();

    cb.popGroup();
}

fn property(cb: anytype, label: []const u8, value: []const u8) void {
    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 0, .justify = .space_between });
    cb.textMuted(label);
    cb.text(value);
    cb.popGroup();
}

fn statusLine(cb: anytype) void {
    cb.pushGroup(.{ .direction = .horizontal, .pad_x = 12, .pad_y = 0, .gap = 16, .height = 24, .bg = paper_dark, .border = ink, .align_cross = .center });
    cb.textStyled("READY", plex_bold, ink);
    cb.textMuted("X 120.50   Y 044.00   UNITS MM");
    cb.spacer(1);
    cb.textMuted("SNAP ON   GRID 10");
    cb.popGroup();
}

/// Floating key-help panel: opaque paper backdrop + ink border + a hard
/// 4px offset shadow, non-modal so the sheet underneath stays live.
fn helpPopover(cb: anytype, slide: f32) void {
    // Slide down into place while the border and shadow fade in from paper.
    const border = teak.anim.lerp([4]f32, paper, ink, std.math.clamp(slide, 0, 1));
    const rise = (1 - slide) * 70;
    cb.pushOverlay(.{
        // Overlaps the left column's parts table on purpose: the opaque
        // backdrop must hide the table text beneath it.
        .x = 150,
        .y = 120 - rise,
        .width = 300,
        .padding = 12,
        .gap = 6,
        .backdrop = paper,
        .border = border,
        .border_width = 1,
        .shadow = border,
        .shadow_offset = .{ 4, 4 },
        .align_cross = .stretch,
    });
    cb.heading("QUICK KEYS");
    cb.divider();
    cb.text("L   LINE");
    cb.text("A   ARC");
    cb.text("D   DIMENSION");
    cb.text("ESC CANCEL");
    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 0, .justify = .end });
    cb.buttonStyled(.toggle_help, "CLOSE", key_button);
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

pub fn keyCharMsg(m: *const Model, c: u8) ?Msg {
    if (!m.name_focused) return null;
    return .{ .name_char = c };
}

pub fn keySpecialMsg(m: *const Model, key: teak.SpecialKey) ?Msg {
    if (!m.name_focused) return null;
    return switch (key) {
        .backspace => .name_backspace,
        else => null,
    };
}

/// Lets `teak.run` draw the focus rule + caret on the name field.
pub fn focusedMsg(m: *const Model) ?Msg {
    return if (m.name_focused) Msg.focus_name else null;
}

/// `teak.run` calls this each frame; the whole look lives in `theme`.
pub fn themeFor(_: *const Model) teak.Theme {
    return theme;
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
