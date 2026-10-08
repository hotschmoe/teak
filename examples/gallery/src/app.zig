//! The gallery: every Teak widget on one screen, in three looks.
//!
//! A menu bar, a page list, and six pages of demos. Everything the pages show
//! is stock Teak: the only state is `Model`, the only transitions are `Msg`s,
//! `view` is a pure function of the Model.

const std = @import("std");
const teak = @import("teak");
const theme_mod = @import("theme.zig");
const model_mod = @import("model.zig");
const ui = @import("ui.zig");
const page_controls = @import("page_controls.zig");
const page_inputs = @import("page_inputs.zig");
const page_data = @import("page_data.zig");
const page_overlays = @import("page_overlays.zig");
const page_layout = @import("page_layout.zig");
const page_scene = @import("page_scene.zig");

pub const Model = model_mod.Model;
pub const Msg = model_mod.Msg;
pub const update = model_mod.update;
pub const subscribe = model_mod.subscribe;
pub const Look = model_mod.Look;

const W = teak.widgets;
const MB = model_mod.MB;
const CM = model_mod.CM;
const Toasts = model_mod.Toasts;

pub fn themeFor(m: *const Model) teak.Theme {
    return theme_mod.themeOf(m.look);
}

// ── Menus ──────────────────────────────────────────────────────────

const Item = MB.Item;
const pages_menu = [_]Item{
    .{ .label = "&Controls", .action = .page_controls },
    .{ .label = "&Inputs", .action = .page_inputs },
    .{ .label = "&Data", .action = .page_data },
    .{ .label = "&Overlays", .action = .page_overlays },
    .{ .label = "&Layout", .action = .page_layout },
    .{ .label = "&3D & images", .action = .page_scene },
};
const file_menu = [_]Item{
    .{ .label = "&Reset demo...", .action = .reset },
    .{ .label = "Show &toast", .action = .toast_demo, .shortcut = "Ctrl+T" },
    Item.sep,
    .{ .label = "E&xit", .action = .quit },
};
const look_menu = [_]Item{
    .{ .label = "&Retro", .action = .look_retro },
    .{ .label = "&Dark", .action = .look_dark },
    .{ .label = "&Light", .action = .look_light },
};
const view_menu = [_]Item{
    .{ .label = "&Go to", .children = &pages_menu },
    .{ .label = "&Theme", .children = &look_menu },
    Item.sep,
    .{ .label = "Re&fresh", .action = .refresh, .shortcut = "F5" },
};
const help_menu = [_]Item{
    .{ .label = "&Keyboard shortcuts", .action = .shortcuts },
    .{ .label = "&About Teak gallery", .action = .about },
};
pub const menus = [_]Item{
    .{ .label = "&File", .children = &file_menu },
    .{ .label = "&View", .children = &view_menu },
    .{ .label = "&Help", .children = &help_menu },
};
const ctx_props = [_]Item{
    .{ .label = "&Name" },
    .{ .label = "&Size" },
};
pub const context_items = [_]Item{
    .{ .label = "&Copy", .action = .copy, .shortcut = "Ctrl+C" },
    .{ .label = "&Paste", .action = .paste, .shortcut = "Ctrl+V" },
    .{ .label = "Select &all", .action = .select_all, .shortcut = "Ctrl+A" },
    Item.sep,
    .{ .label = "&Refresh", .action = .refresh },
    .{ .label = "P&roperties", .children = &ctx_props },
    .{ .label = "&Delete", .action = .properties, .enabled = false },
};

fn wrapMenu(s: MB.Msg) Msg {
    return .{ .menubar = s };
}
fn wrapCtx(s: CM.Msg) Msg {
    return .{ .ctx = s };
}
fn wrapRun(a: model_mod.Action) Msg {
    return .{ .run = a };
}
pub const bar_msgs = .{ .menu = wrapMenu, .run = wrapRun };
pub const ctx_msgs = .{ .menu = wrapCtx, .run = wrapRun };

// ── View ───────────────────────────────────────────────────────────

pub fn view(m: *const Model, cb: anytype) void {
    const pal = cb.theme.palette;
    const body_h = m.win_h - ui.menu_h - ui.status_h;

    cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 0, .align_cross = .stretch, .bg = pal.bg });

    MB.viewWith(&m.menubar, cb, &menus, bar_msgs, .{ .window_w = m.win_w, .window_h = m.win_h, .bar_height = ui.menu_h });

    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 0, .height = body_h, .align_cross = .stretch });
    sidebar(m, cb);
    cb.pushGroup(.{ .direction = .vertical, .padding = ui.pad, .gap = 12, .flex = 1, .bg = pal.bg });
    ui.heading(cb, m.page.title());
    switch (m.page) {
        .controls => page_controls.view(m, cb),
        .inputs => page_inputs.view(m, cb),
        .data => page_data.view(m, cb),
        .overlays => page_overlays.view(m, cb),
        .layout => page_layout.view(m, cb),
        .scene => page_scene.view(m, cb),
    }
    cb.popGroup();
    cb.popGroup();

    // Status line.
    cb.pushGroup(.{ .direction = .horizontal, .padding = 4, .pad_x = 12, .gap = 16, .height = ui.status_h, .bg = pal.bg_panel, .border = pal.border, .align_cross = .center });
    cb.textMuted(if (m.last_action) |a| ui.fmt(cb, "last action: {s}", .{@tagName(a)}) else "ready");
    cb.spacer(1);
    cb.textMuted(ui.fmt(cb, "look: {s}", .{@tagName(m.look)}));
    cb.popGroup();

    cb.popGroup();

    W.tooltip.view(&m.tip, cb, &page_overlays.tip_texts, .{ .window_w = m.win_w, .window_h = m.win_h });
    CM.viewWith(&m.ctx, cb, &context_items, ctx_msgs, .{ .window_w = m.win_w, .window_h = m.win_h });
    Toasts.viewWith(&m.toasts, cb, .{ .dismissMsg = dismissToast }, .{ .window_w = m.win_w, .window_h = m.win_h - ui.status_h });
    dialogs(m, cb);
}

fn dialogs(m: *const Model, cb: anytype) void {
    const o: W.dialog.Opts = .{ .window_w = m.win_w, .window_h = m.win_h, .title = "", .confirm_label = "OK" };
    const msgs = .{ .confirm = Msg{ .dialog_confirm = {} }, .cancel = Msg{ .dialog_cancel = {} } };
    switch (m.dialog) {
        .none => {},
        .about => {
            var d = o;
            d.title = "About Teak gallery";
            d.message = "Every Teak widget, built from flat commands.";
            d.cancel_label = null;
            W.dialog.view(cb, d, msgs);
        },
        .shortcuts => {
            var d = o;
            d.title = "Keyboard shortcuts";
            d.cancel_label = null;
            W.dialog.begin(cb, d, msgs);
            cb.text("F10 / Alt      menu bar");
            cb.text("Tab            next field");
            cb.text("Enter / Esc    confirm / cancel");
            cb.text("Ctrl+Z / Y     undo / redo in fields");
            W.dialog.end(cb, d, msgs);
        },
        .confirm_reset => {
            var d = o;
            d.title = "Reset the demo?";
            d.message = "Every control returns to its initial value.";
            d.confirm_label = "Reset";
            d.danger = true;
            W.dialog.view(cb, d, msgs);
        },
    }
}

fn dismissToast(id: u32) Msg {
    return .{ .toast = .{ .dismiss = id } };
}

fn sidebar(m: *const Model, cb: anytype) void {
    const pal = cb.theme.palette;
    cb.pushGroup(.{ .direction = .vertical, .padding = 10, .gap = 6, .width = ui.sidebar_w, .bg = pal.bg_panel, .border = pal.border, .align_cross = .stretch });
    cb.heading("TEAK GALLERY");
    cb.divider();
    for (std.enums.values(model_mod.Page)) |p| {
        var st = cb.theme.button;
        st.label_align = .start;
        if (m.page == p) {
            st.bg = pal.fg;
            st.fg = pal.bg;
            st.hover_bg = pal.fg;
            st.hover_fg = pal.bg;
        }
        cb.buttonStyled(.{ .go = p }, p.title(), st);
    }
    cb.spacer(1);
    cb.divider();
    cb.textMuted("Look");
    for (std.enums.values(Look)) |l| {
        var st = cb.theme.button;
        st.label_align = .start;
        if (m.look == l) {
            st.bg = pal.fg;
            st.fg = pal.bg;
            st.hover_bg = pal.fg;
            st.hover_fg = pal.bg;
        }
        cb.buttonStyled(.{ .look = l }, @tagName(l), st);
    }
    cb.popGroup();
}

// ── Hooks ──────────────────────────────────────────────────────────

/// Frame time while a toast is sliding in or out.
pub fn animationMsg(_: *const Model, dt_ms: u32) ?Msg {
    return .{ .toast = .{ .frame = dt_ms } };
}

pub fn windowMsg(_: *const Model, w: f32, h: f32) ?Msg {
    return .{ .window = .{ w, h } };
}

pub fn sliderMsg(_: *const Model, grab: Msg, value: f32) ?Msg {
    return switch (grab) {
        .slider_grab => |id| .{ .slider_set = .{ .id = id, .v = value } },
        else => null,
    };
}

pub fn keyCharMsg(m: *const Model, c: u8) ?Msg {
    if (MB.isActive(&m.menubar)) return MB.charMsg(&m.menubar, c, &menus, bar_msgs);
    if (CM.isOpen(&m.ctx)) return CM.charMsg(&m.ctx, c, &context_items, ctx_msgs);
    if (m.dialog != .none) return null;
    const f = m.focus orelse return null;
    return switch (f) {
        .name => teak.textFieldChar(Msg, "name", c),
        .search => teak.textFieldChar(Msg, "search", c),
        .qty => teak.textFieldChar(Msg, "qty", c),
        .combo => .{ .combo = model_mod.Combo.charMsg(c) },
        .area => .{ .area = model_mod.Area.charMsg(c) },
    };
}

pub fn keySpecialMsg(m: *const Model, key: teak.SpecialKey) ?Msg {
    if (m.dialog != .none) return dialogKey(m, key);
    if (MB.keyMsg(&m.menubar, key, &menus, bar_msgs)) |r| return r;
    if (MB.isActive(&m.menubar)) return null;
    if (CM.isOpen(&m.ctx)) return CM.keyMsg(&m.ctx, key, &context_items, ctx_msgs);
    if (model_mod.Drop.keyMsg(&m.drop, key, page_inputs.sizes.len, .{})) |d| return .{ .drop = d };
    if (model_mod.Toasts.keyMsg(&m.toasts, key)) |t| return .{ .toast = t };
    if (m.page == .layout) if (model_mod.Tabs.keyMsg(&m.tabs, key, tab_labels.len)) |t| return .{ .tabs = t };
    const f = m.focus orelse return null;
    return switch (f) {
        .name => teak.textFieldSpecial(Msg, "name", key),
        .search => teak.textFieldSpecial(Msg, "search", key),
        .qty => teak.textFieldSpecial(Msg, "qty", key),
        .combo => if (model_mod.Combo.keyMsg(&m.combo, key, &page_inputs.woods, page_inputs.combo_key_opts)) |c| Msg{ .combo = c } else null,
        .area => if (model_mod.Area.keyMsg(key)) |a| Msg{ .area = a } else null,
    };
}

pub const tab_labels = page_layout.tab_labels;

fn dialogKey(m: *const Model, key: teak.SpecialKey) ?Msg {
    return W.dialog.keyMsg(key, .{ .confirm = Msg{ .dialog_confirm = {} }, .cancel = Msg{ .dialog_cancel = {} } }, m.dialog != .about and m.dialog != .shortcuts);
}

/// A press on blank space clears the text-field focus (the loop reports it as
/// `kind = .down` with `hit == null`; widgets with a Msg report that instead).
pub fn pointerMsg(m: *const Model, ev: teak.PointerEvent(Msg)) ?Msg {
    if (ev.kind == .down and ev.isBlank() and m.focus != null) return .focus_clear;
    return null;
}

pub fn focusedMsg(m: *const Model) ?Msg {
    const f = m.focus orelse return null;
    return switch (f) {
        .combo => .{ .combo = .focus },
        .area => .{ .area = .focus },
        else => .{ .focus_set = f },
    };
}

/// Tab moved the keyboard focus off the text fields: stop typing into them.
pub fn blurMsg(m: *const Model) ?Msg {
    return if (m.focus != null) .blur else null;
}

/// Pointer, wheel, resolved motion and metrics for the text area.
pub fn textMsg(_: *const Model, ev: teak.TextEvent) ?Msg {
    return if (ev.id == model_mod.area_id) Msg{ .area = model_mod.Area.eventMsg(ev) } else null;
}

pub fn scrollMsg(_: *const Model, id: u32, _: f32, dy: f32) ?Msg {
    if (id == page_data.list_id) return Msg{ .list_scroll_by = dy };
    if (id == page_data.note_id) return Msg{ .note_scroll_by = dy };
    return null;
}

pub fn scrollLayoutMsg(_: *const Model, id: u32, _: f32, vh: f32, _: f32, ch: f32) ?Msg {
    if (id == page_data.list_id) return Msg{ .list_extent = .{ vh, ch } };
    if (id == page_data.note_id) return Msg{ .note_extent = .{ vh, ch } };
    return null;
}

pub fn hoverMsg(m: *const Model, ev: teak.PointerEvent(Msg)) ?Msg {
    if (m.dialog != .none or m.menubar.st.open or CM.isOpen(&m.ctx)) return null;
    return .{ .tip = W.tooltip.hoverMsg(Msg, ev, &page_overlays.tip_targets, 550) };
}

pub fn contextMsg(m: *const Model, ev: teak.PointerEvent(Msg)) ?Msg {
    if (m.dialog != .none or m.menubar.st.open) return null;
    if (ev.x < ui.sidebar_w or ev.y < ui.menu_h or ev.y > m.win_h - ui.status_h) return null;
    return .{ .ctx = CM.openAt(ev.x, ev.y) };
}

pub fn canvasMsg(m: *const Model, ev: teak.CanvasEvent) ?Msg {
    if (W.split.canvasMsg(&m.split, ev, page_layout.split_opts)) |s| return .{ .split = s };
    return null;
}

pub const resources = page_scene.resources;

pub fn windowTitle(m: *const Model) ?[]const u8 {
    _ = m;
    return "Teak gallery";
}

const testing = std.testing;

fn layoutAll(m: *const Model, cb: *teak.CmdBuffer(Msg), rects: []teak.Rect) []teak.Rect {
    cb.theme = themeFor(m);
    view(m, cb);
    const n = cb.cmds.items.len;
    teak.LayoutEngine.doLayout(rects[0..n], cb.cmds.items, m.win_w, m.win_h, teak.monoMeasurer());
    return rects[0..n];
}

test "every page in every look builds a balanced command buffer that lays out" {
    var rects: [4096]teak.Rect = undefined;
    for (std.enums.values(model_mod.Page)) |page| for (std.enums.values(Look)) |look| {
        var cb = teak.CmdBuffer(Msg).init(testing.allocator);
        defer cb.deinit();
        var m: Model = .{};
        m.page = page;
        m.look = look;
        _ = layoutAll(&m, &cb, &rects);
        try testing.expect(teak.validateBalance(cb.cmds.items) == null);
    };
}

test "overlays: open menu, context menu, dialog and toasts balance too" {
    var rects: [4096]teak.Rect = undefined;
    var m: Model = .{ .page = .overlays };
    update(&m, .{ .menubar = .{ .goto = .{ .active = true, .hot = 1, .open = true, .depth = 1, .sel = .{ 1, 0, 0, 0 } } } });
    update(&m, .{ .ctx = CM.openAt(400, 300) });
    update(&m, .{ .dialog = .shortcuts });
    update(&m, .{ .toast_push = .{ .kind = .danger } });
    var cb = teak.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();
    _ = layoutAll(&m, &cb, &rects);
    try testing.expect(teak.validateBalance(cb.cmds.items) == null);
}

test "F10 activates the menu bar; mnemonics open menus; Enter runs an item and closes the bar" {
    var m: Model = .{};
    update(&m, keySpecialMsg(&m, .f10).?);
    try testing.expect(m.menubar.st.active);
    update(&m, keyCharMsg(&m, 'v').?); // View
    try testing.expect(m.menubar.st.open and m.menubar.st.hot == 1);
    update(&m, keyCharMsg(&m, 'f').?); // Re&fresh
    try testing.expect(!m.menubar.st.active and !m.menubar.st.open);
    try testing.expectEqual(@as(?model_mod.Action, .refresh), m.last_action);
    try testing.expectEqual(@as(usize, 1), m.toasts.len);
}

test "the theme submenu switches the look and a confirm dialog resets the demo" {
    var m: Model = .{};
    update(&m, .{ .run = .look_dark });
    try testing.expectEqual(Look.dark, m.look);
    update(&m, .{ .check_b = {} });
    update(&m, .{ .run = .reset });
    try testing.expectEqual(model_mod.Dialog.confirm_reset, m.dialog);
    // Enter confirms through the dialog key hook.
    update(&m, keySpecialMsg(&m, .enter).?);
    try testing.expectEqual(model_mod.Dialog.none, m.dialog);
    try testing.expect(!m.check_b);
    try testing.expectEqual(Look.dark, m.look); // the look survives a reset
}

test "tooltips: hovering a target arms Sub.at; the deadline fires and the tip shows" {
    var m: Model = .{};
    const ev: teak.PointerEvent(Msg) = .{ .x = 10, .y = 10, .hit = Msg{ .demo = 0 }, .box = .{ .x = 20, .y = 100, .w = 60, .h = 26 }, .now_ms = 1000 };
    update(&m, hoverMsg(&m, ev).?);
    try testing.expectEqual(@as(usize, 1), subscribe(&m).len);
    try testing.expectEqual(@as(u64, 1550), subscribe(&m)[0].at.deadline_ms);
    update(&m, subscribe(&m)[0].at.msg);
    try testing.expect(m.tip.shown);
    // A click on the target hides it (the demo handler does).
    update(&m, .{ .demo = 0 });
    try testing.expect(!m.tip.shown);
    // An open menu suppresses new tips.
    update(&m, .{ .menubar = .{ .goto = .{ .active = true, .open = true } } });
    try testing.expect(hoverMsg(&m, ev) == null);
}

test "right-click opens the context menu only inside the content area" {
    var m: Model = .{};
    const inside: teak.PointerEvent(Msg) = .{ .x = 600, .y = 400 };
    try testing.expect(contextMsg(&m, inside) != null);
    try testing.expect(contextMsg(&m, .{ .x = 50, .y = 400 }) == null); // sidebar
    try testing.expect(contextMsg(&m, .{ .x = 600, .y = 10 }) == null); // menu bar
}

test "subscriptions are listed only while something needs them" {
    var m: Model = .{};
    try testing.expectEqual(@as(usize, 0), subscribe(&m).len);
    update(&m, .{ .toast_push = .{ .kind = .info } });
    try testing.expectEqual(@as(usize, 2), subscribe(&m).len); // the tick + the slide-in animation
    update(&m, animationMsg(&m, 400).?); // slide finished
    try testing.expectEqual(@as(usize, 1), subscribe(&m).len);
    update(&m, .job_start);
    try testing.expectEqual(@as(usize, 3), subscribe(&m).len);
    var i: usize = 0;
    while (i < 60) : (i += 1) update(&m, .job_tick);
    try testing.expect(!m.job_running);
    try testing.expectEqual(@as(f32, 1), m.job);
}

test "sliders report through sliderMsg; the split drags through canvasMsg" {
    var m: Model = .{};
    update(&m, sliderMsg(&m, .{ .slider_grab = .mix }, 0.25).?);
    try testing.expectEqual(@as(f32, 0.25), m.mix);
    try testing.expect(sliderMsg(&m, .clicked, 0.5) == null);

    const o = page_layout.split_opts;
    update(&m, canvasMsg(&m, .{ .id = o.id, .kind = .down, .button = .left }).?);
    const before = m.split.ratio;
    update(&m, canvasMsg(&m, .{ .id = o.id, .kind = .move, .dx = 40 }).?);
    try testing.expect(m.split.ratio > before);
}

test "the virtual list window follows the scroll offset and clamps at the end" {
    var m: Model = .{};
    update(&m, .{ .list_scroll_by = 1e9 });
    try testing.expectEqual(m.list_content - m.list_viewport, m.list_scroll);
    update(&m, .{ .list_scroll_by = -1e9 });
    try testing.expectEqual(@as(f32, 0), m.list_scroll);
}

test "the Inputs page text area takes focus and typed text (Enter makes a new line)" {
    var m: Model = .{};
    update(&m, .{ .go = .inputs });
    update(&m, .{ .area = .focus });
    try testing.expectEqual(model_mod.Field.area, m.focus.?);
    for ("hi") |c| update(&m, keyCharMsg(&m, c).?);
    update(&m, keySpecialMsg(&m, .enter).?);
    update(&m, keyCharMsg(&m, '!').?);
    try testing.expectEqualStrings("hi\n!", m.area.content());
    try testing.expect(focusedMsg(&m).?.area == .focus);
    const ev: teak.TextEvent = .{ .id = model_mod.area_id, .kind = .metrics };
    try testing.expect(textMsg(&m, ev) != null);
}
