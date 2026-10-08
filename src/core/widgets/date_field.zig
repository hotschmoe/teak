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

test "date field: typing a full valid date selects it; a partial one is just text" {
    var m: Model = .{};
    typeIso(&m, "2026-10-0");
    try testing.expect(m.selected == null);
    try testing.expect(!textValid(&m));
    update(&m, charMsg('8'));
    try testing.expect(m.selected.?.eql(.{ .year = 2026, .month = 10, .day = 8 }));
    try testing.expect(m.cursor.eql(m.selected.?));
    try testing.expect(textValid(&m));
    // an impossible date (Feb 30) stays unselected
    var n: Model = .{};
    typeIso(&n, "2026-02-30");
    try testing.expect(n.selected == null and !textValid(&n));
    // emptying the field clears the selection
    var e: Model = .{};
    update(&e, .{ .set = .{ .year = 2026, .month = 1, .day = 2 } });
    e.text.clear();
    update(&e, .{ .edit = .backspace });
    try testing.expect(e.selected == null);
}

test "date field: opening shows the selected month (else today); picking writes the ISO text and closes" {
    var m: Model = .{};
    update(&m, .{ .set_today = .{ .year = 2026, .month = 10, .day = 8 } });
    update(&m, .toggle);
    try testing.expect(m.open);
    try testing.expect(m.cursor.eql(.{ .year = 2026, .month = 10, .day = 8 }));
    update(&m, .{ .pick = .{ .year = 2026, .month = 11, .day = 3 } });
    try testing.expect(!m.open);
    try testing.expectEqualStrings("2026-11-03", m.text.content());
    update(&m, .toggle); // reopens on the selection, not on today
    try testing.expect(m.cursor.eql(.{ .year = 2026, .month = 11, .day = 3 }));
}

test "date field: keyboard navigation moves the cursor; Enter picks; Escape closes" {
    var m: Model = .{};
    update(&m, .{ .set = .{ .year = 2026, .month = 1, .day = 31 } });
    update(&m, .toggle);
    update(&m, keyMsg(&m, .right).?);
    try testing.expect(m.cursor.eql(.{ .year = 2026, .month = 2, .day = 1 }));
    update(&m, keyMsg(&m, .down).?);
    try testing.expect(m.cursor.eql(.{ .year = 2026, .month = 2, .day = 8 }));
    update(&m, keyMsg(&m, .page_down).?);
    try testing.expect(m.cursor.eql(.{ .year = 2026, .month = 3, .day = 8 }));
    update(&m, keyMsg(&m, .end).?);
    try testing.expect(m.cursor.eql(.{ .year = 2026, .month = 3, .day = 31 }));
    update(&m, keyMsg(&m, .page_up).?); // Mar 31 -> Feb 28 (clamped)
    try testing.expect(m.cursor.eql(.{ .year = 2026, .month = 2, .day = 28 }));
    update(&m, keyMsg(&m, .home).?);
    try testing.expect(m.cursor.eql(.{ .year = 2026, .month = 2, .day = 1 }));
    update(&m, keyMsg(&m, .enter).?);
    try testing.expect(!m.open);
    try testing.expect(m.selected.?.eql(.{ .year = 2026, .month = 2, .day = 1 }));
    // Escape closes without picking
    update(&m, .toggle);
    update(&m, keyMsg(&m, .left).?);
    update(&m, keyMsg(&m, .escape).?);
    try testing.expect(!m.open and m.selected.?.day == 1);
}

test "date field: Down on a closed field opens it; other keys edit the text" {
    var m: Model = .{};
    try testing.expect(keyMsg(&m, .down).? == .toggle);
    try testing.expect(keyMsg(&m, .backspace).? == .edit);
    try testing.expect(keyMsg(&m, .tab) == null);
}

test "date field: Today needs set_today; Clear empties" {
    var m: Model = .{};
    update(&m, .today);
    try testing.expect(m.selected == null);
    update(&m, .{ .set_today = .{ .year = 2026, .month = 10, .day = 8 } });
    update(&m, .toggle);
    update(&m, .today);
    try testing.expectEqualStrings("2026-10-08", m.text.content());
    update(&m, .clear);
    try testing.expect(m.selected == null and m.text.content().len == 0);
}

const TMsg = union(enum) { focus, toggle, close, today, clear, pick: Date, go: Nav };
fn pickMsg(d: Date) TMsg {
    return .{ .pick = d };
}
fn goMsg(n: Nav) TMsg {
    return .{ .go = n };
}
const tmsgs = .{ .focus = TMsg{ .focus = {} }, .toggle = TMsg{ .toggle = {} }, .close = TMsg{ .close = {} }, .today = TMsg{ .today = {} }, .clear = TMsg{ .clear = {} }, .pickMsg = pickMsg, .goMsg = goMsg };

test "date field: closed view is an input and a button; open view adds a 6x7 grid starting on a Monday" {
    var cb = cmd.CmdBuffer(TMsg).init(testing.allocator);
    defer cb.deinit();
    var m: Model = .{};
    viewWith(&m, &cb, tmsgs, .{ .window_w = 600, .window_h = 500 });
    try testing.expectEqual(@as(usize, 4), cb.cmds.items.len);

    cb.reset();
    update(&m, .{ .set = .{ .year = 2026, .month = 10, .day = 8 } });
    update(&m, .toggle);
    viewWith(&m, &cb, tmsgs, .{ .window_w = 600, .window_h = 500, .list_x = 20, .list_y = 60 });
    // first grid button: Monday on/before Oct 1 2026 (a Thursday) = Sep 28
    var picks: usize = 0;
    var first: ?Date = null;
    var last: Date = undefined;
    for (cb.cmds.items) |c| switch (c) {
        .button => |b| switch (b.msg) {
            .pick => |d| {
                picks += 1;
                if (first == null) first = d;
                last = d;
            },
            else => {},
        },
        else => {},
    };
    try testing.expectEqual(@as(usize, 42), picks);
    try testing.expect(first.?.eql(.{ .year = 2026, .month = 9, .day = 28 }));
    try testing.expect(last.eql(.{ .year = 2026, .month = 11, .day = 8 }));
    try testing.expect(cmd.validateBalance(cb.cmds.items) == null);
}

test "date field: an invalid text draws a danger border" {
    var cb = cmd.CmdBuffer(TMsg).init(testing.allocator);
    defer cb.deinit();
    var m: Model = .{};
    typeIso(&m, "2026-1");
    viewWith(&m, &cb, tmsgs, .{ .window_w = 600, .window_h = 500 });
    try testing.expectEqual(cb.theme.palette.danger, cb.cmds.items[1].text_input.style.border);
}

test "date field: snapshot golden (open, October 2026, the 8th selected)" {
    var cb = cmd.CmdBuffer(TMsg).init(testing.allocator);
    defer cb.deinit();
    var m: Model = .{};
    update(&m, .{ .set_today = .{ .year = 2026, .month = 10, .day = 12 } });
    update(&m, .{ .set = .{ .year = 2026, .month = 10, .day = 8 } });
    update(&m, .toggle);
    cb.pushGroup(.{ .padding = 0, .gap = 0 });
    viewWith(&m, &cb, tmsgs, .{ .window_w = 400, .window_h = 400, .list_x = 10, .list_y = 40 });
    cb.popGroup();
    var rects: [160]engine.Rect = undefined;
    const n = cb.cmds.items.len;
    engine.LayoutEngine.doLayout(rects[0..n], cb.cmds.items, 400, 400, text_mod.monoMeasurer());
    try snapshot.expectSnapshot(cb.cmds.items, rects[0..n], .{},
        \\group (0,0,400,400) vertical
        \\  group (0,0,150,28) horizontal
        \\    text_input (0,0,120,28) "2026-10-08" cursor=10
        \\    button (122,0,28,28) "^"
        \\  overlay (0,0,400,400) layer=1 [modal]
        \\  overlay (10,40,254,300) layer=1 shadow
        \\    group (10,40,254,300) vertical bg border
        \\      group (18,48,238,28) horizontal
        \\        button (18,48,34,28) "<<"
        \\        button (52,48,34,28) "<"
        \\        group (86,52,120,20) horizontal
        \\          text (86,52,120,20) "October 2026"
        \\        button (206,48,34,28) ">"
        \\        button (240,48,34,28) ">>"
        \\      group (18,80,238,28) horizontal
        \\        group (18,80,34,28) horizontal
        \\          text (25,84,20,20) "Mo"
        \\        group (52,80,34,28) horizontal
        \\          text (59,84,20,20) "Tu"
        \\        group (86,80,34,28) horizontal
        \\          text (93,84,20,20) "We"
        \\        group (120,80,34,28) horizontal
        \\          text (127,84,20,20) "Th"
        \\        group (154,80,34,28) horizontal
        \\          text (161,84,20,20) "Fr"
        \\        group (188,80,34,28) horizontal
        \\          text (195,84,20,20) "Sa"
        \\        group (222,80,34,28) horizontal
        \\          text (229,84,20,20) "Su"
        \\      group (18,112,238,28) horizontal
        \\        button (18,112,34,28) "28"
        \\        button (52,112,34,28) "29"
        \\        button (86,112,34,28) "30"
        \\        button (120,112,34,28) "1"
        \\        button (154,112,34,28) "2"
        \\        button (188,112,34,28) "3"
        \\        button (222,112,34,28) "4"
        \\      group (18,144,238,28) horizontal
        \\        button (18,144,34,28) "5"
        \\        button (52,144,34,28) "6"
        \\        button (86,144,34,28) "7"
        \\        button (120,144,34,28) "8"
        \\        button (154,144,34,28) "9"
        \\        button (188,144,34,28) "10"
        \\        button (222,144,34,28) "11"
        \\      group (18,176,238,28) horizontal
        \\        button (18,176,34,28) "12"
        \\        button (52,176,34,28) "13"
        \\        button (86,176,34,28) "14"
        \\        button (120,176,34,28) "15"
        \\        button (154,176,34,28) "16"
        \\        button (188,176,34,28) "17"
        \\        button (222,176,34,28) "18"
        \\      group (18,208,238,28) horizontal
        \\        button (18,208,34,28) "19"
        \\        button (52,208,34,28) "20"
        \\        button (86,208,34,28) "21"
        \\        button (120,208,34,28) "22"
        \\        button (154,208,34,28) "23"
        \\        button (188,208,34,28) "24"
        \\        button (222,208,34,28) "25"
        \\      group (18,240,238,28) horizontal
        \\        button (18,240,34,28) "26"
        \\        button (52,240,34,28) "27"
        \\        button (86,240,34,28) "28"
        \\        button (120,240,34,28) "29"
        \\        button (154,240,34,28) "30"
        \\        button (188,240,34,28) "31"
        \\        button (222,240,34,28) "1"
        \\      group (18,272,238,28) horizontal
        \\        button (18,272,34,28) "2"
        \\        button (52,272,34,28) "3"
        \\        button (86,272,34,28) "4"
        \\        button (120,272,34,28) "5"
        \\        button (154,272,34,28) "6"
        \\        button (188,272,34,28) "7"
        \\        button (222,272,34,28) "8"
        \\      group (18,304,238,28) horizontal
        \\        button (118,304,66,28) "Today"
        \\        button (190,304,66,28) "Clear"
        \\
    );
}
