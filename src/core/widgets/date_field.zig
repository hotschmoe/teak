//! Date field: an ISO text field (`YYYY-MM-DD`) with a calendar popover.
//! Zero new Cmd variants: a `text_input`, a `button`, and a modal-overlay
//! panel of `button`s (a month grid), the Dropdown pattern.
//!
//! No wall clock reaches `view` or `update`: "today" is data the app puts in
//! the Model with `set_today`, typically from a `clock` effect result:
//!
//! ```zig
//! const DF = teak.widgets.date_field;
//! // Model: due: DF.Model = .{}     Msg: due: DF.Msg
//! // update:   .due => |s| DF.update(&m.due, s),
//! // effects:  .{ .clock = .{ .id = 1 } } once;  effectMsg: .clock => |c| .{ .due = .{ .set_today = date.fromUnixMs(c.unix_ms, c.utc_offset_min) } }
//! // view:     DF.viewWith(&m.due, cb, msgs, .{ .list_x = x, .list_y = y, .window_w = w, .window_h = h });
//! // keys:     DF.keyMsg(&m.due, key) / DF.charMsg(c)
//! // result:   m.due.selected (?Date)
//! ```
//!
//! Typing a valid ISO date selects it (the invalid prefix while typing is just
//! text, drawn with a danger border); the popover navigates with the arrow keys
//! (day / week), Page Up / Down (month), Home / End (first / last day of the
//! month), Enter picks, Escape closes.

const std = @import("std");
const cmd = @import("../cmd.zig");
const text_field = @import("../text_field.zig");
const keys = @import("../../input/keys.zig");
const date = @import("date.zig");
const util = @import("util.zig");

pub const Date = date.Date;
const TF = text_field.TextField(10);

pub const Nav = enum { day_prev, day_next, week_prev, week_next, month_prev, month_next, year_prev, year_next, month_start, month_end };

pub const Model = struct {
    text: TF.Model = .{},
    open: bool = false,
    selected: ?Date = null,
    today: ?Date = null,
    /// The keyboard cursor; the popover shows its month.
    cursor: Date = .{ .year = 2000, .month = 1, .day = 1 },
};

pub const Msg = union(enum) {
    /// Edit the text (typing a full valid date selects it).
    edit: TF.Msg,
    toggle,
    close,
    /// Pick a day.
    pick: Date,
    go: Nav,
    /// Pick the keyboard cursor's day (Enter).
    commit,
    /// Pick today (no-op until `set_today` has arrived).
    today,
    clear,
    /// The current local date, from the app's clock effect.
    set_today: Date,
    /// Set the selection programmatically.
    set: ?Date,
};

fn pickDate(model: *Model, d: Date) void {
    model.selected = d;
    model.cursor = d;
    var buf: [10]u8 = undefined;
    model.text.set(date.formatIso(d, &buf));
    model.open = false;
}

pub fn update(model: *Model, msg: Msg) void {
    switch (msg) {
        .edit => |e| {
            TF.update(&model.text, e);
            if (date.parseIso(model.text.content())) |d| {
                model.selected = d;
                model.cursor = d;
            } else if (model.text.content().len == 0) {
                model.selected = null;
            }
        },
        .toggle => {
            if (model.open) {
                model.open = false;
            } else {
                model.open = true;
                model.cursor = model.selected orelse model.today orelse model.cursor;
            }
        },
        .close => model.open = false,
        .pick => |d| pickDate(model, d),
        .go => |n| model.cursor = move(model.cursor, n),
        .commit => if (model.open) pickDate(model, model.cursor),
        .today => if (model.today) |t| pickDate(model, t),
        .clear => {
            model.selected = null;
            model.text.clear();
            model.open = false;
        },
        .set_today => |d| {
            model.today = d;
            // An untouched field opens on today.
            if (model.selected == null and !model.open) model.cursor = d;
        },
        .set => |d| {
            if (d) |v| pickDate(model, v) else {
                model.selected = null;
                model.text.clear();
            }
        },
    }
}

fn move(d: Date, n: Nav) Date {
    return switch (n) {
        .day_prev => date.addDays(d, -1),
        .day_next => date.addDays(d, 1),
        .week_prev => date.addDays(d, -7),
        .week_next => date.addDays(d, 7),
        .month_prev => date.addMonths(d, -1),
        .month_next => date.addMonths(d, 1),
        .year_prev => date.addYears(d, -1),
        .year_next => date.addYears(d, 1),
        .month_start => .{ .year = d.year, .month = d.month, .day = 1 },
        .month_end => .{ .year = d.year, .month = d.month, .day = date.daysInMonth(d.year, d.month) },
    };
}

/// True when the text is empty or a complete valid date.
pub fn textValid(model: *const Model) bool {
    const t = model.text.content();
    return t.len == 0 or date.parseIso(t) != null;
}

// ── Keys ───────────────────────────────────────────────────────────

pub fn charMsg(c: u8) Msg {
    return .{ .edit = .{ .char = c } };
}

/// The Msg for a key: calendar navigation while open, text editing otherwise
/// (Down on a closed field opens the calendar).
pub fn keyMsg(model: *const Model, key: keys.SpecialKey) ?Msg {
    if (model.open) {
        switch (key) {
            .left => return .{ .go = .day_prev },
            .right => return .{ .go = .day_next },
            .up => return .{ .go = .week_prev },
            .down => return .{ .go = .week_next },
            .page_up => return .{ .go = .month_prev },
            .page_down => return .{ .go = .month_next },
            .home => return .{ .go = .month_start },
            .end => return .{ .go = .month_end },
            .enter => return .commit,
            .escape => return .close,
            else => {},
        }
    } else if (key == .down) return .toggle;
    const W = union(enum) { m: TF.Msg };
    const wrapped = text_field.textFieldSpecial(W, "m", key) orelse return null;
    return .{ .edit = wrapped.m };
}

// ── View ───────────────────────────────────────────────────────────

pub const ViewOpts = struct {
    /// Window position of the popover's top-left (the field's bottom-left).
    list_x: f32 = 0,
    list_y: f32 = 0,
    window_w: f32,
    window_h: f32,
    cell_w: f32 = 34,
    cell_h: f32 = 28,
};

/// Width of the popover panel for `o`.
pub fn panelWidth(o: ViewOpts) f32 {
    return 7 * o.cell_w + 2 * panel_pad;
}

const panel_pad: f32 = 8;
const panel_gap: f32 = 4;

/// The field: `[YYYY-MM-DD       ] [v]`, then the calendar when open.
/// `msgs`: `.focus`, `.toggle`, `.close`, `.today`, `.clear` (AppMsgs) and the
/// comptime fns `.pickMsg(Date)` / `.goMsg(Nav)`.
pub fn viewWith(model: *const Model, cb: anytype, msgs: anytype, o: ViewOpts) void {
    const pal = cb.theme.palette;
    var inp = cb.theme.text_input;
    if (!textValid(model)) inp.border = pal.danger;
    var btn = cb.theme.button;
    btn.min_width = 28;
    btn.h_padding = 4;
    btn.height = cb.theme.text_input.height;
    btn.label_align = .center;

    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 2, .align_cross = .center });
    cb.textInputSelected(msgs.focus, model.text.content(), model.text.cursor, model.text.selection_anchor, inp);
    cb.buttonStyled(msgs.toggle, if (model.open) "^" else "v", btn);
    cb.popGroup();

    if (!model.open) return;
    util.scrim(cb, msgs.close, o.window_w, o.window_h);

    const pw = panelWidth(o);
    const ph = panelPad2() + o.cell_h * 9 + panel_gap * 8;
    cb.pushOverlay(.{
        .x = std.math.clamp(o.list_x, 0, @max(0, o.window_w - pw)),
        .y = std.math.clamp(o.list_y, 0, @max(0, o.window_h - ph)),
        .width = pw,
        .padding = 0,
        .gap = 0,
        .shadow = .{ 0, 0, 0, 0.35 },
        .shadow_offset = .{ 3, 3 },
    });
    cb.pushGroup(.{ .direction = .vertical, .padding = panel_pad, .gap = panel_gap, .bg = pal.bg_panel, .border = pal.border, .width = pw, .align_cross = .stretch });

    const cur = model.cursor;
    // Header: << < October 2026 > >>
    var nav = cb.theme.button;
    nav.min_width = o.cell_w;
    nav.height = o.cell_h;
    nav.h_padding = 2;
    nav.label_align = .center;
    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 0, .align_cross = .center });
    cb.buttonStyled(msgs.goMsg(.year_prev), "<<", nav);
    cb.buttonStyled(msgs.goMsg(.month_prev), "<", nav);
    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 0, .flex = 1, .justify = .center });
    cb.textStyled(util.frameFmt(cb, "{s} {d}", .{ date.month_names[cur.month - 1], cur.year }), cb.theme.typography.body, pal.fg);
    cb.popGroup();
    cb.buttonStyled(msgs.goMsg(.month_next), ">", nav);
    cb.buttonStyled(msgs.goMsg(.year_next), ">>", nav);
    cb.popGroup();

    // Weekday headings.
    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 0 });
    for (date.weekday_short) |w| {
        cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 0, .width = o.cell_w, .height = o.cell_h, .justify = .center, .align_cross = .center });
        cb.textStyled(w, cb.theme.typography.body, pal.fg_muted);
        cb.popGroup();
    }
    cb.popGroup();

    // 6 x 7 grid, Monday first, starting on or before the 1st.
    const first: Date = .{ .year = cur.year, .month = cur.month, .day = 1 };
    const lead: i64 = date.weekday(first);
    var row: i64 = 0;
    while (row < 6) : (row += 1) {
        cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 0 });
        var col: i64 = 0;
        while (col < 7) : (col += 1) {
            const d = date.addDays(first, row * 7 + col - lead);
            cb.buttonStyled(msgs.pickMsg(d), util.frameFmt(cb, "{d}", .{d.day}), dayStyle(cb, model, d, o));
        }
        cb.popGroup();
    }

    // Footer.
    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 6, .justify = .end });
    var foot = cb.theme.button;
    foot.height = o.cell_h;
    foot.label_align = .center;
    foot.min_width = 0;
    if (model.today != null) cb.buttonStyled(msgs.today, "Today", foot) else cb.buttonStyledDisabled(msgs.today, "Today", foot);
    cb.buttonStyled(msgs.clear, "Clear", foot);
    cb.popGroup();

    cb.popGroup();
    cb.popOverlay();
}

fn panelPad2() f32 {
    return 2 * panel_pad;
}

fn dayStyle(cb: anytype, model: *const Model, d: Date, o: ViewOpts) cmd.ButtonStyle {
    const pal = cb.theme.palette;
    var st = cb.theme.button;
    st.min_width = o.cell_w;
    st.height = o.cell_h;
    st.h_padding = 2;
    st.label_align = .center;
    st.border = null;
    st.bg = pal.bg_panel;
    st.hover_bg = pal.bg_hover;
    const in_month = d.month == model.cursor.month;
    st.fg = if (in_month) pal.fg else pal.fg_muted;
    if (model.selected) |s| if (s.eql(d)) {
        st.bg = pal.fg;
        st.fg = pal.bg;
        st.hover_bg = pal.fg;
        st.hover_fg = pal.bg;
    };
    if (model.today) |t| if (t.eql(d)) {
        st.border = pal.accent;
        st.border_width = 1;
    };
    if (model.cursor.eql(d)) {
        st.border = pal.fg;
        st.border_width = 2;
    }
    return st;
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;
const component = @import("../component.zig");
const snapshot = @import("../snapshot.zig");
const engine = @import("../../layout/engine.zig");
const text_mod = @import("../text.zig");

fn typeIso(m: *Model, s: []const u8) void {
    for (s) |c| update(m, charMsg(c));
}






const TMsg = union(enum) { focus, toggle, close, today, clear, pick: Date, go: Nav };
fn pickMsg(d: Date) TMsg {
    return .{ .pick = d };
}
fn goMsg(n: Nav) TMsg {
    return .{ .go = n };
}
const tmsgs = .{ .focus = TMsg{ .focus = {} }, .toggle = TMsg{ .toggle = {} }, .close = TMsg{ .close = {} }, .today = TMsg{ .today = {} }, .clear = TMsg{ .clear = {} }, .pickMsg = pickMsg, .goMsg = goMsg };



